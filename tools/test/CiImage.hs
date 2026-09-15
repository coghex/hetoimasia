-- | Hspec coverage for the Linux CI image contract and the native recipe.
--
-- Every example drives the shipped tools — @tools/validation/ci_image.py@,
-- @tools/validation/plan.py@, @tools/ci-image/builder.py@, and
-- @tools/native/native.py@ — against temporary Git repositories, a fake image
-- root, a stub registry transport, and stub compilers and SDK probes. Those are
-- stubs because the cases that matter do not happen on demand against the real
-- ones: a registry that errors, a tag a concurrent builder published a moment
-- earlier, and a compiler or SDK upgrade under an unchanged GLFW pin.
--
-- The real registry transport, @tools/ci-image/registry.py@, is not driven
-- here: it only answers the builder's four requests against GHCR and Docker,
-- and the builder workflow's own runs are what exercise it.
module CiImage (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM_, void)
import Data.List (isPrefixOf, sort)
import Json (asArray, asString, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, workflowStepBody, writeFixtureFile)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , findExecutable
  , getCurrentDirectory
  , getPermissions
  , setOwnerExecutable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldNotBe
  , shouldNotContain
  , shouldReturn
  , shouldSatisfy
  )

data Fixture = Fixture
  { root ∷ FilePath
  , scratch ∷ FilePath
  , checkout ∷ FilePath
  , python ∷ FilePath
  , environment ∷ [(String, String)]
  , seeded ∷ String
  }

-- | The descriptor fields an example varies.
data Descriptor = Descriptor
  { digest ∷ String
  , manifest ∷ String
  , recipe ∷ String
  , ghc ∷ String
  , cabal ∷ String
  }

spec ∷ Spec
spec = describe "CI image" $ do
  describe "the recipe fingerprint" $ do
    it "moves for every recipe input, a new input, and a mode change, and never for the descriptor" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        let start = recipe described
        final ← foldlM' start recipePaths $ \previous path → do
          appendCommitted fixture path "# revised\n"
          moved ← fingerprintNow fixture
          (path, moved) `shouldNotBe` (path, previous)
          pure moved
        change fixture "tools/ci-image/extra.pin" "EXTRA=1\n"
        added ← fingerprintNow fixture
        added `shouldNotBe` final
        void $ gitIn fixture ["update-index", "--chmod=+x", "tools/ci-image/provision.sh"]
        void $ gitIn fixture ["commit", "-q", "-m", "Make the provisioning script executable"]
        executable ← fingerprintNow fixture
        executable `shouldNotBe` added
        change fixture "tools/ci-image/descriptor.json" (descriptorJson described {digest = digestOf 'f'})
        change fixture "src/note.txt" "an ordinary source change\n"
        change fixture "README.md" "ordinary prose\n"
        fingerprintNow fixture `shouldReturn` executable

    it "needs no descriptor for a first build, and never stages one" $
      withFixture $ \fixture → do
        first ← fingerprintNow fixture
        first `shouldSatisfy` ((== 64) . length)
        (built, written, errors) ←
          pythonIn fixture
            [ checkout fixture </> "tools/ci-image/builder.py", "descriptor"
            , "--image", "ghcr.io/owner/project-ci", "--digest", digestOf 'a'
            , "--fingerprint", first, "--native-manifest", replicate 64 'b'
            , "--ghc", "9.12.2", "--cabal", "3.16.1.0"
            , "--output", scratch fixture </> "descriptor.json"
            ]
        (built, errors) `shouldBe` (ExitSuccess, "")
        written `shouldContain` first
        void $ describedImage fixture
        (staged, listing, stageErrors) ←
          pythonIn fixture
            [ checkout fixture </> "tools/ci-image/builder.py", "stage"
            , "--repo-root", root fixture, "--revision", "HEAD"
            , "--output", scratch fixture </> "context"
            ]
        (staged, stageErrors) `shouldBe` (ExitSuccess, "")
        sort (lines listing) `shouldBe` sort recipePaths
        doesFileExist (scratch fixture </> "context/tools/ci-image/descriptor.json") `shouldReturn` False
        doesFileExist (scratch fixture </> "context/src/note.txt") `shouldReturn` False

  describe "the planner" $ do
    it "declares ci-image and native-manifest from a descriptor that describes the candidate" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        change fixture "src/note.txt" "an ordinary source change\n"
        plan ← planLinux fixture []
        toolchainEntry plan "ci-image" `shouldBe` Just (digest described)
        toolchainEntry plan "native-manifest" `shouldBe` Just (manifest described)
        toolchainEntry plan "ghc" `shouldBe` Just "9.12.2"
        toolchainEntry plan "cabal" `shouldBe` Just "3.16.1.0"
        (parseJson plan >>= field "ci_image" >>= field "reference" >>= asString)
          `shouldBe` Just "ghcr.io/owner/project-ci"
        -- A candidate that touches no image input is still selected exactly
        -- as before: the floor, and the group whose input it changed.
        selected plan `shouldBe` Just ["build.pass", "test.src"]

    it "refuses a descriptor whose recipe fingerprint no longer matches, naming the builder" $
      withFixture $ \fixture → do
        void $ describedImage fixture
        appendCommitted fixture "tools/native/glfw.pin" "GLFW_EXTRA=1\n"
        refusal ← planRaw fixture "HEAD" Nothing linuxPins
        refusedByBuilder refusal "recipe fingerprint"

    forM_
      [ ("native-manifest hash", \d → d {manifest = "not-a-hash"}, "native_manifest")
      , ("GHC version", \d → d {ghc = "9.10.1"}, "ghc 9.10.1")
      , ("Cabal version", \d → d {cabal = "3.14.1.1"}, "cabal 3.14.1.1")
      ]
      $ \(label, alter, named) →
        it ("refuses a descriptor whose " ++ label ++ " disagrees, before anything executes") $
          withFixture $ \fixture → do
            described ← describedImage fixture
            commitDescriptor fixture (alter described)
            refusal ← planRaw fixture "HEAD" Nothing linuxPins
            refusedByBuilder refusal named

    it "reads the descriptor from the integration candidate rather than the head" $
      withFixture $ \fixture → do
        void $ describedImage fixture
        contribution ← revision fixture "HEAD"
        void $ gitIn fixture ["checkout", "-q", "-b", "upstream", seeded fixture]
        appendCommitted fixture "tools/ci-image/Dockerfile" "# an upstream recipe change\n"
        void $ gitIn fixture ["checkout", "-q", "master"]
        void $ gitIn fixture ["merge", "-q", "--no-edit", "upstream"]
        candidate ← revision fixture "HEAD"
        (headOnly, _, headErrors) ← planRaw fixture contribution Nothing linuxPins
        (headOnly, headErrors) `shouldBe` (ExitSuccess, "")
        refusal ← planRaw fixture contribution (Just candidate) linuxPins
        refusedByBuilder refusal "recipe fingerprint"

    it "keeps the declared toolchain for a candidate with no image recipe" $
      withFixture $ \fixture → do
        void $ gitIn fixture ["rm", "-r", "-q", "tools/ci-image", "tools/native", ".github/workflows/ci-image.yml"]
        void $ gitIn fixture ["commit", "-q", "-m", "Retire the image recipe"]
        plan ← planLinux fixture []
        toolchainEntry plan "ci-image" `shouldBe` Nothing
        toolchainEntry plan "ghc" `shouldBe` Just "9.12.2"

    it "never lets a local plan claim the Linux image digest" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        (local, plan, errors) ←
          planRaw fixture "HEAD" Nothing ["--runner-os", "Darwin", "--toolchain", "native-manifest=" ++ replicate 64 '1']
        (local, errors) `shouldBe` (ExitSuccess, "")
        toolchainEntry plan "ci-image" `shouldBe` Nothing
        toolchainEntry plan "native-manifest" `shouldBe` Just (replicate 64 '1')
        (claimed, _, claimErrors) ←
          planRaw fixture "HEAD" Nothing ["--runner-os", "Darwin", "--toolchain", "ci-image=" ++ digest described]
        claimed `shouldBe` ExitFailure 2
        claimErrors `shouldContain` "only Linux workers run that image"

  describe "cache environment keys" $
    it "move with the image identity and never with the commit carrying the descriptor" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        first ← environmentKey fixture
        change fixture "tools/ci-image/descriptor.json" (compactDescriptor described)
        change fixture "README.md" "revised prose\n"
        environmentKey fixture `shouldReturn` first
        commitDescriptor fixture described {digest = digestOf 'c'}
        image ← environmentKey fixture
        image `shouldNotBe` first
        commitDescriptor fixture described {manifest = replicate 64 'd'}
        native ← environmentKey fixture
        native `shouldNotBe` first
        native `shouldNotBe` image

  describe "worker verification" $ do
    it "declares exactly the planned map when every entry agrees" $
      withWorker $ \fixture worker → do
        (result, output, errors) ← verify fixture worker
        (result, errors) `shouldBe` (ExitSuccess, "")
        declared ← strictRead (scratch fixture </> "toolchain.txt")
        sort (lines declared)
          `shouldBe` sort
            [ "cabal=3.16.1.0"
            , "ci-image=" ++ digestOf 'a'
            , "ghc=9.12.2"
            , "native-manifest=" ++ workerManifest worker
            ]
        planned ← environmentOfPlan fixture (workerPlan worker)
        output `shouldContain` ("environment=" ++ planned)

    it "refuses a worker running another compiler" $
      withWorker $ \fixture worker → do
        writeFile (workerStubs worker </> "ghc-version") "9.12.1\n"
        refusedWorker fixture worker "toolchain entry 'ghc'"

    it "refuses a worker running another Cabal" $
      withWorker $ \fixture worker → do
        writeFile (workerStubs worker </> "cabal-version") "3.14.1.1\n"
        refusedWorker fixture worker "toolchain entry 'cabal'"

    it "refuses a worker whose actual native manifest is not the planned one, naming the builder" $
      withWorker $ \fixture worker → do
        described ← descriptorNow fixture
        commitDescriptor fixture described {manifest = replicate 64 'e'}
        plan ← planLinux fixture []
        writeFile (workerPlan worker) plan
        (result, _, errors) ← verify fixture worker
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "native manifest this container carries"
        errors `shouldContain` "toolchain entry 'native-manifest'"
        errors `shouldContain` "run the ci-image builder"

    it "refuses a plan whose ci-image entry is not the worker's" $
      withWorker $ \fixture worker → do
        patchPlanToolchain fixture (workerPlan worker) "ci-image" (digestOf '9')
        refusedWorker fixture worker "toolchain entry 'ci-image'"

    it "refuses an image embedding another recipe fingerprint" $
      withWorker $ \fixture worker → do
        writeFile (workerImage worker </> "image.json") ("{\"recipe_fingerprint\": \"" ++ replicate 64 '0' ++ "\"}\n")
        refusedWorker fixture worker "embeds recipe fingerprint"

    it "refuses a Cabal store outside the fixed image location" $
      withWorker $ \fixture worker → do
        writeFile (workerStubs worker </> "store") "/root/.cabal/store\n"
        refusedWorker fixture worker "resolves its store"

  describe "the image builder" $ do
    it "returns a validated hit without building or pushing" $
      withRegistry $ \registry → do
        answer registry [hitAnswer]
        (result, output, errors) ← builder registry "resolve" []
        (result, errors) `shouldBe` (ExitSuccess, "")
        output `shouldContain` "\"status\": \"hit\""
        output `shouldContain` digestOf 'a'
        answer registry [hitAnswer]
        (published, publishOutput, _) ← builder registry "publish" ["--context", registryDirectory registry]
        published `shouldBe` ExitSuccess
        publishOutput `shouldContain` "\"published\": false"
        calls registry `shouldReturn` ["lookup", "lookup"]

    it "publishes a confirmed miss once, after rechecking" $
      withRegistry $ \registry → do
        answer registry ["absent"]
        (resolved, resolvedOutput, _) ← builder registry "resolve" []
        resolved `shouldBe` ExitSuccess
        resolvedOutput `shouldContain` "\"status\": \"miss\""
        answer registry ["absent", hitAnswer]
        (result, output, errors) ← builder registry "publish" ["--context", registryDirectory registry]
        (result, errors) `shouldBe` (ExitSuccess, "")
        output `shouldContain` "\"status\": \"published\""
        calls registry `shouldReturn` ["lookup", "lookup", "build", "validate", "push", "lookup"]

    it "returns the image a concurrent builder published instead of overwriting its tag" $
      withRegistry $ \registry → do
        answer registry ["absent"]
        (resolved, resolvedOutput, _) ← builder registry "resolve" []
        resolved `shouldBe` ExitSuccess
        resolvedOutput `shouldContain` "\"status\": \"miss\""
        -- Another builder held the publication group first and finished while
        -- this one waited; the recheck is what finds it.
        answer registry [hitAnswer]
        (result, output, _) ← builder registry "publish" ["--context", registryDirectory registry]
        result `shouldBe` ExitSuccess
        output `shouldContain` "\"published\": false"
        calls registry >>= \made → made `shouldNotContain` ["push"]

    it "treats a lookup error as neither a hit nor a miss, and publishes nothing" $
      withRegistry $ \registry → do
        answer registry ["error"]
        (resolved, _, resolveErrors) ← builder registry "resolve" []
        resolved `shouldBe` ExitFailure 2
        resolveErrors `shouldContain` "a registry error is not a miss"
        answer registry ["error"]
        (published, _, _) ← builder registry "publish" ["--context", registryDirectory registry]
        published `shouldBe` ExitFailure 2
        calls registry >>= \made → made `shouldNotContain` ["build"]

    it "refuses an existing image whose metadata does not describe the fingerprint, and publishes nothing" $
      withRegistry $ \registry → do
        answer registry [labelledAnswer (replicate 64 '7') (replicate 64 'b')]
        (resolved, _, errors) ← builder registry "resolve" []
        resolved `shouldBe` ExitFailure 2
        errors `shouldContain` "never overwritten"
        answer registry [labelledAnswer fingerprintX "not-a-hash"]
        (published, _, publishErrors) ← builder registry "publish" ["--context", registryDirectory registry]
        published `shouldBe` ExitFailure 2
        publishErrors `shouldContain` "native manifest label"
        calls registry >>= \made → made `shouldNotContain` ["push"]

    it "publishes nothing when the candidate fails validation" $
      withRegistry $ \registry → do
        answer registry ["absent"]
        writeFile (registryDirectory registry </> "validate-status") "1\n"
        (result, _, errors) ← builder registry "publish" ["--context", registryDirectory registry]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "failed validation"
        calls registry >>= \made → made `shouldNotContain` ["push"]

  describe "dependency cache seeding" $ do
    it "seeds a missing default-branch cache when every test worker was skipped by reuse" $
      seedDecision [("EVENT_NAME", "push"), ("ENGINE", "false"), ("LOOKUP", "success"), ("HIT", "")]
        `shouldReturn` "true"

    it "does not seed a cache that already exists" $
      seedDecision [("EVENT_NAME", "push"), ("ENGINE", "false"), ("LOOKUP", "success"), ("HIT", "true")]
        `shouldReturn` "false"

    it "leaves seeding to an engine worker that runs anyway" $
      seedDecision [("EVENT_NAME", "push"), ("ENGINE", "true"), ("LOOKUP", "skipped"), ("HIT", "")]
        `shouldReturn` "false"

    it "never seeds from a pull request, whose cache no other pull request restores" $
      seedDecision [("EVENT_NAME", "pull_request"), ("ENGINE", "false"), ("LOOKUP", "skipped"), ("HIT", "")]
        `shouldReturn` "false"

    it "seeds rather than assumes when the lookup did not answer" $
      seedDecision [("EVENT_NAME", "push"), ("ENGINE", "false"), ("LOOKUP", "failure"), ("HIT", "")]
        `shouldReturn` "true"

    it "builds only dependencies and executes no validation group" $ do
      here ← getCurrentDirectory
      workflow ← strictRead (here </> ".github/workflows/validation.yml")
      let job = takeWhile (not . isPrefixOf "  build-test:") (dropWhile (not . isPrefixOf "  seed-dependencies:") (lines workflow))
      unlines job `shouldContain` "--only-dependencies"
      unlines job `shouldNotContain` "run.py"

  describe "native prefix identity" $ do
    forM_ variations $ \variation →
      it ("rejects the old prefix and linked products when only the " ++ variationLabel variation ++ " changes") $
        withNative $ \native → do
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          original ← nativeManifestNow native []
          nativeOk native [] ["prepare", "--prefix", nativePrefix native, "--build-dir", nativeBuild native]
          variationApply variation native
          let changed = variationEnvironment variation
          (refused, _, errors) ← nativeTool native changed ["check", "--prefix", nativePrefix native]
          refused `shouldBe` ExitFailure 1
          errors `shouldContain` ("native " ++ variationField variation)
          -- The rebuild under the changed configuration is a different native
          -- identity, and products linked against the original are refused.
          nativeOk native changed ["record", "--prefix", nativePrefix native]
          rebuilt ← nativeManifestNow native changed
          rebuilt `shouldNotBe` original
          (stale, _, staleErrors) ←
            nativeTool native changed ["check", "--prefix", nativePrefix native, "--build-dir", nativeBuild native]
          stale `shouldBe` ExitFailure 1
          staleErrors `shouldContain` "linked against native manifest"
          -- An identical complete configuration is the same identity again.
          variationRevert variation native
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          nativeManifestNow native [] `shouldReturn` original
          nativeOk native [] ["check", "--prefix", nativePrefix native, "--build-dir", nativeBuild native]

    it "refuses an absent prefix even when a system GLFW is visible" $
      withNative $ \native → do
        let system = nativeDirectory native </> "system"
        writeFixtureFile system "glfw3.pc" (glfwPc "/usr" "3.3.10" "-lm")
        (result, _, errors) ←
          nativeTool native [("PKG_CONFIG_PATH", system)] ["check", "--prefix", nativeDirectory native </> "absent"]
        result `shouldBe` ExitFailure 1
        errors `shouldContain` "no private GLFW prefix"
        errors `shouldContain` "3.3.10"

    it "refuses a prefix whose metadata was replaced by a system GLFW" $
      withNative $ \native → do
        nativeOk native [] ["record", "--prefix", nativePrefix native]
        writeFile (nativePrefix native </> "lib/pkgconfig/glfw3.pc") (glfwPc "/usr" "3.3.10" "-lm")
        (result, _, errors) ← nativeTool native [] ["check", "--prefix", nativePrefix native]
        result `shouldBe` ExitFailure 1
        errors `shouldContain` "resolves glfw3 from"

    it "reports a change in the generated link requirements as manifest drift" $
      withNative $ \native → do
        nativeOk native [] ["record", "--prefix", nativePrefix native]
        writeFile (nativePrefix native </> "lib/pkgconfig/glfw3.pc") (glfwPc (nativePrefix native) "3.4.0" "-lm -ldl")
        (result, _, errors) ← nativeTool native [] ["check", "--prefix", nativePrefix native]
        result `shouldBe` ExitFailure 1
        errors `shouldContain` "native manifest drift"

    it "fails clearly when pkg-config is missing" $
      withNative $ \native → do
        (result, _, errors) ← nativeTool native [("PATH", nativeDirectory native </> "empty")] ["check", "--prefix", nativePrefix native]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "brew install cmake pkgconf"

-- ---------------------------------------------------------------------------
-- The fixture repository

withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  here ← getCurrentDirectory
  settings ← sanitizedEnvironment
  interpreter ← findExecutable "python3" >>= maybe (fail "python3 is not on PATH") pure
  withSystemTempDirectory "hetoimasia-ci-image" $ \temporary → do
    directory ← canonicalizePath temporary
    let repository = directory </> "repository"
        outside = directory </> "scratch"
        fixture = Fixture repository outside here interpreter settings ""
    createDirectoryIfMissing True repository
    createDirectoryIfMissing True outside
    void $ git settings repository ["init", "-q", "-b", "master"]
    mapM_ (uncurry (writeFixtureFile repository)) (projectFiles ++ [(path, "# fixture " ++ path ++ "\n") | path ← recipePaths])
    void $ git settings repository ["add", "-A", "."]
    void $ git settings repository ["commit", "-q", "-m", "Seed a project with an image recipe"]
    seed ← revision fixture "HEAD"
    action fixture {seeded = seed}

recipePaths ∷ [FilePath]
recipePaths =
  [ ".github/workflows/ci-image.yml"
  , "tools/ci-image/Dockerfile"
  , "tools/ci-image/builder.py"
  , "tools/ci-image/provision.sh"
  , "tools/ci-image/registry.py"
  , "tools/ci-image/toolchain.pin"
  , "tools/native/glfw.pin"
  , "tools/native/native.py"
  , "tools/validation/ci_image.py"
  ]

projectFiles ∷ [(FilePath, String)]
projectFiles =
  [ ("cabal.project", "packages:\n  .\n")
  , ( "demo.cabal"
    , unlines
        [ "cabal-version: 3.16"
        , "name: demo"
        , "version: 0.1.0.0"
        , "build-type: Simple"
        , ""
        , "executable demo"
        , "    main-is: Main.hs"
        , "    hs-source-dirs: app"
        , "    default-language: GHC2024"
        , "    build-depends: base"
        ]
    )
  , ("app/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("src/note.txt", "a fixture the source group consumes\n")
  , ("README.md", "prose\n")
  , ("tools/validation/catalog.json", catalog)
  ]

catalog ∷ String
catalog =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"policy_version\": 1,"
    , "  \"policy_inputs\": [\"tools/validation/\", \".github/workflows/\"],"
    , "  \"non_affecting_paths\": [\"*.md\"],"
    , "  \"floor\": [\"build.pass\"],"
    , "  \"groups\": ["
    , "    {\"id\": \"build.pass\", \"description\": \"Passes.\", \"command\": [\"true\"], \"component\": null,"
    , "     \"inputs\": [], \"framework\": \"none\", \"runner\": \"cpu\", \"timeout_seconds\": 60,"
    , "     \"category\": \"build\", \"optional\": false},"
    , "    {\"id\": \"test.src\", \"description\": \"Reads src.\", \"command\": [\"true\"], \"component\": null,"
    , "     \"inputs\": [\"src/\", \"tools/ci-image/\", \"tools/native/\"], \"framework\": \"hspec\", \"runner\": \"cpu\","
    , "     \"timeout_seconds\": 60, \"category\": \"test\", \"optional\": false}"
    , "  ]"
    , "}"
    ]

gitIn ∷ Fixture → [String] → IO String
gitIn fixture = git (environment fixture) (root fixture)

revision ∷ Fixture → String → IO String
revision fixture name = takeWhile (/= '\n') <$> gitIn fixture ["rev-parse", name]

change ∷ Fixture → FilePath → String → IO ()
change fixture path contents = do
  writeFixtureFile (root fixture) path contents
  void $ gitIn fixture ["add", "--", path]
  void $ gitIn fixture ["commit", "-q", "-m", "Change " ++ path]

appendCommitted ∷ Fixture → FilePath → String → IO ()
appendCommitted fixture path addition = do
  existing ← strictRead (root fixture </> path)
  change fixture path (existing ++ addition)

pythonIn ∷ Fixture → [String] → IO (ExitCode, String, String)
pythonIn fixture = run (environment fixture) (root fixture) (python fixture)

fingerprintNow ∷ Fixture → IO String
fingerprintNow fixture = do
  (result, output, errors) ←
    pythonIn fixture
      [checkout fixture </> "tools/validation/ci_image.py", "fingerprint", "--repo-root", root fixture, "--revision", "HEAD"]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure (takeWhile (/= '\n') output)

digestOf ∷ Char → String
digestOf character = "sha256:" ++ replicate 64 character

descriptorJson ∷ Descriptor → String
descriptorJson described =
  unlines
    [ "{"
    , "  \"architecture\": \"amd64\","
    , "  \"cabal\": \"" ++ cabal described ++ "\","
    , "  \"digest\": \"" ++ digest described ++ "\","
    , "  \"ghc\": \"" ++ ghc described ++ "\","
    , "  \"native_manifest\": \"" ++ manifest described ++ "\","
    , "  \"platform\": \"linux\","
    , "  \"recipe_fingerprint\": \"" ++ recipe described ++ "\","
    , "  \"reference\": \"ghcr.io/owner/project-ci\","
    , "  \"schema_version\": 1"
    , "}"
    ]

-- | The same descriptor written with different bytes.
compactDescriptor ∷ Descriptor → String
compactDescriptor = filter (`notElem` ['\n', ' ']) . descriptorJson

commitDescriptor ∷ Fixture → Descriptor → IO ()
commitDescriptor fixture = change fixture "tools/ci-image/descriptor.json" . descriptorJson

-- | Commit a descriptor that describes the current recipe.
describedImage ∷ Fixture → IO Descriptor
describedImage fixture = do
  current ← fingerprintNow fixture
  let described = Descriptor (digestOf 'a') (replicate 64 'b') current "9.12.2" "3.16.1.0"
  commitDescriptor fixture described
  pure described

descriptorNow ∷ Fixture → IO Descriptor
descriptorNow fixture = do
  text ← strictRead (root fixture </> "tools/ci-image/descriptor.json")
  let value name = maybe (error ("descriptor has no " ++ name)) id (parseJson text >>= field name >>= asString)
  pure (Descriptor (value "digest") (value "native_manifest") (value "recipe_fingerprint") (value "ghc") (value "cabal"))

linuxPins ∷ [String]
linuxPins = ["--runner-os", "Linux", "--toolchain", "ghc=9.12.2", "--toolchain", "cabal=3.16.1.0"]

planRaw ∷ Fixture → String → Maybe String → [String] → IO (ExitCode, String, String)
planRaw fixture head' candidate extra =
  pythonIn fixture
    ( [ checkout fixture </> "tools/validation/plan.py"
      , "--repo-root", root fixture
      , "--base", seeded fixture
      , "--head", head'
      , "--json"
      , "--worker", "ci=cpu:build.pass,test.src"
      ]
        ++ maybe [] (\commit → ["--candidate", commit]) candidate
        ++ extra
    )

planLinux ∷ Fixture → [String] → IO String
planLinux fixture extra = do
  (result, output, errors) ← planRaw fixture "HEAD" Nothing (linuxPins ++ extra)
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure output

refusedByBuilder ∷ (ExitCode, String, String) → String → IO ()
refusedByBuilder (result, _, errors) named = do
  result `shouldBe` ExitFailure 2
  errors `shouldContain` named
  errors `shouldContain` "run the ci-image builder"

toolchainEntry ∷ String → String → Maybe String
toolchainEntry plan name = parseJson plan >>= field "toolchain" >>= field name >>= asString

selected ∷ String → Maybe [String]
selected plan = parseJson plan >>= field "selected" >>= asArray >>= traverse asString

environmentOfPlan ∷ Fixture → FilePath → IO String
environmentOfPlan fixture plan = do
  (result, output, errors) ← pythonIn fixture [checkout fixture </> "tools/validation/ci_image.py", "outputs", "--plan", plan]
  (result, errors) `shouldBe` (ExitSuccess, "")
  case [drop (length prefix) line | line ← lines output, prefix `isPrefixOf` line] of
    key : _ → pure key
    [] → expectationFailure ("no environment in " ++ output) >> pure ""
  where
    prefix = "environment="

environmentKey ∷ Fixture → IO String
environmentKey fixture = do
  plan ← planLinux fixture []
  let path = scratch fixture </> "environment-plan.json"
  writeFile path plan
  environmentOfPlan fixture path

strictRead ∷ FilePath → IO String
strictRead path = do
  text ← readFile path
  _ ← evaluate (length text)
  pure text

foldlM' ∷ a → [b] → (a → b → IO a) → IO a
foldlM' start items step = go start items
  where
    go accumulated [] = pure accumulated
    go accumulated (item : rest) = step accumulated item >>= \next → go next rest

executableFile ∷ FilePath → String → IO ()
executableFile path contents = do
  writeFile path contents
  permissions ← getPermissions path
  setPermissions path (setOwnerExecutable True permissions)

overriding ∷ [(String, String)] → [(String, String)] → [(String, String)]
overriding overrides inherited = overrides ++ filter ((`notElem` map fst overrides) . fst) inherited

-- ---------------------------------------------------------------------------
-- A fake image root and worker

data Worker = Worker
  { workerImage ∷ FilePath
  , workerStubs ∷ FilePath
  , workerPlan ∷ FilePath
  , workerManifest ∷ String
  }

withWorker ∷ (Fixture → Worker → IO a) → IO a
withWorker action = withFixture $ \fixture → do
  current ← fingerprintNow fixture
  let image = scratch fixture </> "image"
      prefix = image </> "native/glfw"
      stubs = scratch fixture </> "bin"
  fakePrefix prefix
  writeFixtureFile image "image.json" ("{\"recipe_fingerprint\": \"" ++ current ++ "\"}\n")
  createDirectoryIfMissing True (image </> "cabal/store")
  (recorded, _, recordErrors) ←
    pythonIn fixture [checkout fixture </> "tools/native/native.py", "record", "--prefix", prefix]
  (recorded, recordErrors) `shouldBe` (ExitSuccess, "")
  hash ← sha256Of fixture (prefix </> "hetoimasia-native-manifest.json")
  commitDescriptor fixture (Descriptor (digestOf 'a') hash current "9.12.2" "3.16.1.0")
  plan ← planLinux fixture []
  let planPath = scratch fixture </> "plan.json"
  writeFile planPath plan
  createDirectoryIfMissing True stubs
  writeFile (stubs </> "ghc-version") "9.12.2\n"
  writeFile (stubs </> "cabal-version") "3.16.1.0\n"
  writeFile (stubs </> "store") (image </> "cabal/store\n")
  executableFile (stubs </> "ghc") ("#!/bin/sh\ncat '" ++ stubs </> "ghc-version" ++ "'\n")
  executableFile
    (stubs </> "cabal")
    ( unlines
        [ "#!/bin/sh"
        , "case \"$1\" in"
        , "  --numeric-version) cat '" ++ stubs </> "cabal-version" ++ "' ;;"
        , "  path) cat '" ++ stubs </> "store" ++ "' ;;"
        , "  *) echo \"cabal stub: unexpected $*\" >&2; exit 1 ;;"
        , "esac"
        ]
    )
  action fixture (Worker image stubs planPath hash)

verify ∷ Fixture → Worker → IO (ExitCode, String, String)
verify fixture worker = do
  let inherited = environment fixture
      path = workerStubs worker ++ maybe "" (':' :) (lookup "PATH" inherited)
      settings = overriding [("PATH", path), ("CABAL_DIR", workerImage worker </> "cabal")] inherited
  run
    settings
    (root fixture)
    (python fixture)
    [ checkout fixture </> "tools/validation/ci_image.py", "verify-worker"
    , "--plan", workerPlan worker
    , "--image-root", workerImage worker
    , "--repo-root", checkout fixture
    , "--toolchain-file", scratch fixture </> "toolchain.txt"
    ]

refusedWorker ∷ Fixture → Worker → String → IO ()
refusedWorker fixture worker named = do
  (result, _, errors) ← verify fixture worker
  result `shouldBe` ExitFailure 2
  errors `shouldContain` named

patchPlanToolchain ∷ Fixture → FilePath → String → String → IO ()
patchPlanToolchain fixture plan name value = do
  (result, _, errors) ←
    pythonIn
      fixture
      [ "-c"
      , "import json, sys\n\
        \path, name, value = sys.argv[1:4]\n\
        \document = json.load(open(path, encoding='utf-8'))\n\
        \document['toolchain'][name] = value\n\
        \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
      , plan
      , name
      , value
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

sha256Of ∷ Fixture → FilePath → IO String
sha256Of fixture path = do
  (result, output, errors) ←
    pythonIn fixture ["-c", "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())", path]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure (takeWhile (/= '\n') output)

-- | A prefix shaped like the recipe's output, with a placeholder archive. Its
-- metadata is read by the real pkg-config, which is all a check consults.
fakePrefix ∷ FilePath → IO ()
fakePrefix prefix = do
  writeFixtureFile prefix "lib/libglfw3.a" "!<arch>\n"
  writeFixtureFile prefix "include/GLFW/glfw3.h" "/* fixture */\n"
  writeFixtureFile prefix "lib/pkgconfig/glfw3.pc" (glfwPc prefix "3.4.0" "-lm")

glfwPc ∷ FilePath → String → String → String
glfwPc prefix version private =
  unlines
    [ "prefix=" ++ prefix
    , "exec_prefix=${prefix}"
    , "includedir=${prefix}/include"
    , "libdir=${exec_prefix}/lib"
    , ""
    , "Name: GLFW"
    , "Description: A fixture standing in for the recipe's generated metadata"
    , "Version: " ++ version
    , "Libs: -L${libdir} -lglfw3"
    , "Libs.private: " ++ private
    , "Cflags: -I${includedir}"
    ]

-- ---------------------------------------------------------------------------
-- The stub registry

data Registry = Registry
  { registryDirectory ∷ FilePath
  , registryTool ∷ FilePath
  , registryPython ∷ FilePath
  , registryCheckout ∷ FilePath
  , registryEnvironment ∷ [(String, String)]
  }

fingerprintX ∷ String
fingerprintX = replicate 64 '3'

withRegistry ∷ (Registry → IO a) → IO a
withRegistry action = do
  here ← getCurrentDirectory
  settings ← sanitizedEnvironment
  interpreter ← findExecutable "python3" >>= maybe (fail "python3 is not on PATH") pure
  withSystemTempDirectory "hetoimasia-registry" $ \directory → do
    let tool = directory </> "registry"
    executableFile tool registryStub
    writeFile (directory </> "built-manifest") (replicate 64 'b' ++ "\n")
    writeFile (directory </> "calls") ""
    action (Registry directory tool interpreter here (("REGISTRY_STATE", directory) : settings))

answer ∷ Registry → [String] → IO ()
answer registry answers = do
  writeFile (registryDirectory registry </> "lookups") "0\n"
  forM_ (zip [1 ∷ Int ..] answers) $ \(index, contents) →
    writeFile (registryDirectory registry </> ("lookup-" ++ show index)) (contents ++ "\n")

hitAnswer ∷ String
hitAnswer = labelledAnswer fingerprintX (replicate 64 'b')

labelledAnswer ∷ String → String → String
labelledAnswer recipeLabel manifestLabel =
  "{\"digest\": \""
    ++ digestOf 'a'
    ++ "\", \"labels\": {\"org.hetoimasia.ci-image.recipe-fingerprint\": \""
    ++ recipeLabel
    ++ "\", \"org.hetoimasia.ci-image.native-manifest\": \""
    ++ manifestLabel
    ++ "\", \"org.hetoimasia.ci-image.ghc\": \"9.12.2\", \"org.hetoimasia.ci-image.cabal\": \"3.16.1.0\"}}"

builder ∷ Registry → String → [String] → IO (ExitCode, String, String)
builder registry command extra =
  run
    (registryEnvironment registry)
    (registryDirectory registry)
    (registryPython registry)
    ( [ registryCheckout registry </> "tools/ci-image/builder.py", command
      , "--image", "ghcr.io/owner/project-ci"
      , "--fingerprint", fingerprintX
      , "--ghc", "9.12.2"
      , "--cabal", "3.16.1.0"
      , "--registry", registryTool registry
      ]
        ++ extra
    )

calls ∷ Registry → IO [String]
calls registry = lines <$> strictRead (registryDirectory registry </> "calls")

-- | A registry transport answering lookups from scripted files, in order, and
-- recording every request it receives.
registryStub ∷ String
registryStub =
  unlines
    [ "#!/bin/sh"
    , "state=\"$REGISTRY_STATE\""
    , "echo \"$1\" >> \"$state/calls\""
    , "case \"$1\" in"
    , "  lookup)"
    , "    count=$(( $(cat \"$state/lookups\") + 1 ))"
    , "    echo \"$count\" > \"$state/lookups\""
    , "    answer=\"$state/lookup-$count\""
    , "    if [ ! -f \"$answer\" ]; then echo \"registry stub: no scripted answer $count\" >&2; exit 2; fi"
    , "    case \"$(head -n 1 \"$answer\")\" in"
    , "      absent) exit 3 ;;"
    , "      error) echo \"registry stub: the manifest endpoint answered 500\" >&2; exit 2 ;;"
    , "    esac"
    , "    cat \"$answer\" ;;"
    , "  build) printf '{\"native_manifest\": \"%s\"}\\n' \"$(cat \"$state/built-manifest\")\" ;;"
    , "  validate) exit \"$(cat \"$state/validate-status\" 2>/dev/null || echo 0)\" ;;"
    , "  push) ;;"
    , "  *) echo \"registry stub: unexpected request $1\" >&2; exit 2 ;;"
    , "esac"
    ]

-- ---------------------------------------------------------------------------
-- The seeding decision, as the workflow ships it

seedDecision ∷ [(String, String)] → IO String
seedDecision overrides = do
  here ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-seed" $ \directory → do
    body ← workflowStepBody here ".github/workflows/validation.yml" "Decide whether to seed the dependency cache"
    writeFile (directory </> "step.sh") body
    writeFile (directory </> "output") ""
    writeFile (directory </> "summary") ""
    let step =
          overriding
            ( overrides
                ++ [ ("IMAGE", "ghcr.io/owner/project-ci@" ++ digestOf 'a')
                   , ("GITHUB_OUTPUT", directory </> "output")
                   , ("GITHUB_STEP_SUMMARY", directory </> "summary")
                   ]
            )
            settings
    (result, _, errors) ← run step directory "bash" [directory </> "step.sh"]
    (result, errors) `shouldBe` (ExitSuccess, "")
    summary ← strictRead (directory </> "summary")
    summary `shouldContain` "Dependency cache seed"
    output ← strictRead (directory </> "output")
    case [drop 5 line | line ← lines output, "seed=" `isPrefixOf` line] of
      [value] → pure value
      _ → expectationFailure ("the step wrote no single seed output:\n" ++ output) >> pure ""

-- ---------------------------------------------------------------------------
-- The native recipe helper

data Native = Native
  { nativeDirectory ∷ FilePath
  , nativePrefix ∷ FilePath
  , nativeBuild ∷ FilePath
  , nativeStubs ∷ FilePath
  , nativePython ∷ FilePath
  , nativeCheckout ∷ FilePath
  , nativeEnvironment ∷ [(String, String)]
  }

data Variation = Variation
  { variationLabel ∷ String
  , variationField ∷ String
  , variationEnvironment ∷ [(String, String)]
  , variationApply ∷ Native → IO ()
  , variationRevert ∷ Native → IO ()
  }

variations ∷ [Variation]
variations =
  [ probeVariation "C compiler" "c_compiler" "cc-version" "clang version 99.0.0" "clang version 21.0.0"
  , probeVariation "SDK" "sdk" "sdk-version" "27.0" "26.5"
  , probeVariation "architecture" "architecture" "arch" "x86_64" "arm64"
  , Variation "deployment target" "deployment_target" [("MACOSX_DEPLOYMENT_TARGET", "14.0")] (const (pure ())) (const (pure ()))
  , Variation "build options" "build_options" [("HETOIMASIA_GLFW_BUILD_TYPE", "Debug")] (const (pure ())) (const (pure ()))
  , Variation "SDK selected through SDKROOT" "environment" [("SDKROOT", "/fixture/SDKs/MacOSX27.sdk")] (const (pure ())) (const (pure ()))
  , Variation "compiler flags" "environment" [("CFLAGS", "-O0 -g")] (const (pure ())) (const (pure ()))
  ]
  where
    probeVariation label name file changed original =
      Variation
        label
        name
        []
        (\native → writeFile (nativeStubs native </> file) (changed ++ "\n"))
        (\native → writeFile (nativeStubs native </> file) (original ++ "\n"))

withNative ∷ (Native → IO a) → IO a
withNative action = do
  here ← getCurrentDirectory
  settings ← sanitizedEnvironment
  interpreter ← findExecutable "python3" >>= maybe (fail "python3 is not on PATH") pure
  withSystemTempDirectory "hetoimasia-native" $ \temporary → do
    directory ← canonicalizePath temporary
    let stubs = directory </> "bin"
        prefix = directory </> "prefix"
    createDirectoryIfMissing True stubs
    createDirectoryIfMissing True (directory </> "empty")
    fakePrefix prefix
    forM_
      [ ("cc-version", "clang version 21.0.0")
      , ("cc-machine", "arm64-apple-darwin")
      , ("sdk-version", "26.5")
      , ("sdk-build", "25F70")
      , ("arch", "arm64")
      ]
      $ \(file, contents) → writeFile (stubs </> file) (contents ++ "\n")
    let answering file = "cat '" ++ (stubs </> file) ++ "'"
    executableFile (stubs </> "cc") $
      unlines ["#!/bin/sh", "case \"$1\" in", "  --version) " ++ answering "cc-version" ++ " ;;", "  -dumpmachine) " ++ answering "cc-machine" ++ " ;;", "esac"]
    executableFile (stubs </> "uname") $ unlines ["#!/bin/sh", answering "arch"]
    executableFile (stubs </> "xcrun") $
      unlines
        [ "#!/bin/sh"
        , "case \"$*\" in"
        , "  *--show-sdk-path) echo /fixture/SDKs/MacOSX.sdk ;;"
        , "  *--show-sdk-version) " ++ answering "sdk-version" ++ " ;;"
        , "  *--show-sdk-build-version) " ++ answering "sdk-build" ++ " ;;"
        , "esac"
        ]
    let inherited =
          filter
            ((`notElem` (["CC", "MACOSX_DEPLOYMENT_TARGET", "HETOIMASIA_GLFW_BUILD_TYPE", "PKG_CONFIG_PATH", "HETOIMASIA_NATIVE_PREFIX"] ++ ambientBuildVariables)) . fst)
            settings
        path = stubs ++ maybe "" (':' :) (lookup "PATH" inherited)
    action (Native directory prefix (directory </> "dist-newstyle") stubs interpreter here (overriding [("PATH", path)] inherited))

-- | The ambient variables the native identity records, cleared from the
-- inherited environment so a developer's own shell cannot move a fixture's
-- identity.
ambientBuildVariables ∷ [String]
ambientBuildVariables =
  [ "CFLAGS", "CMAKE_GENERATOR", "CMAKE_OSX_ARCHITECTURES", "CMAKE_OSX_DEPLOYMENT_TARGET"
  , "CMAKE_OSX_SYSROOT", "CMAKE_PREFIX_PATH", "CMAKE_TOOLCHAIN_FILE", "CPATH", "CPPFLAGS"
  , "C_INCLUDE_PATH", "LDFLAGS", "LIBRARY_PATH", "SDKROOT"
  ]

nativeTool ∷ Native → [(String, String)] → [String] → IO (ExitCode, String, String)
nativeTool native overrides arguments =
  run
    (overriding overrides (nativeEnvironment native))
    (nativeDirectory native)
    (nativePython native)
    ((nativeCheckout native </> "tools/native/native.py") : "--platform" : "Darwin" : arguments)

nativeOk ∷ Native → [(String, String)] → [String] → IO ()
nativeOk native overrides arguments = do
  (result, _, errors) ← nativeTool native overrides arguments
  (result, errors) `shouldBe` (ExitSuccess, "")

nativeManifestNow ∷ Native → [(String, String)] → IO String
nativeManifestNow native overrides = do
  (result, output, errors) ← nativeTool native overrides ["toolchain", "--prefix", nativePrefix native]
  (result, errors) `shouldBe` (ExitSuccess, "")
  case [drop (length prefix) line | line ← lines output, prefix `isPrefixOf` line] of
    hash : _ → pure hash
    [] → expectationFailure ("no native-manifest entry in " ++ output) >> pure ""
  where
    prefix = "native-manifest="
