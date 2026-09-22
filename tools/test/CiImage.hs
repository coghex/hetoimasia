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
import Control.Monad (forM_, void, when)
import Data.Char (isSpace)
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf, sort)
import Json (asArray, asString, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, workflowStepBody, writeFixtureFile)
import System.Directory
  ( canonicalizePath
  , copyFile
  , createDirectoryIfMissing
  , createFileLink
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getCurrentDirectory
  , getPermissions
  , listDirectory
  , removeFile
  , setOwnerExecutable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.IO (IOMode (AppendMode), hPutStr, withBinaryFile)
import System.Info (os)
import System.FilePath (takeDirectory, (</>))
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
  , weston ∷ String
  , vulkanIdentities ∷ [(String, String)]
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
          pythonIn
            fixture
            ( [ checkout fixture </> "tools/ci-image/builder.py", "descriptor"
              , "--image", "ghcr.io/owner/project-ci", "--digest", digestOf 'a'
              , "--fingerprint", first, "--native-manifest", replicate 64 'b'
              , "--ghc", "9.14.1", "--cabal", "3.18.1.0", "--weston", pinnedCompositor
              , "--output", scratch fixture </> "descriptor.json"
              ]
                ++ concat [["--" ++ name, value] | (name, value) ← placeholderVulkan]
            )
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

  describe "the native recipe's patches" $ do
    it "applies every patch in name order, and ends the build when one does not apply" $
      withFixture $ \fixture → do
        recipeDirectory ← copiedRecipe fixture
        clearPatches recipeDirectory
        -- Two patches whose names sort the other way round from the order they
        -- were written, so an example that passes proves the sort and not the
        -- directory listing.
        writeFixtureFile recipeDirectory "patches/0002-second.patch" (appendingPatch ["base", "first"] "second")
        writeFixtureFile recipeDirectory "patches/0001-first.patch" (appendingPatch ["base"] "first")
        let source = scratch fixture </> "source"
        writeFixtureFile source "note.txt" "base\n"
        (applied, _, failures) ← pythonIn fixture [recipeDirectory </> "native.py", "--help"]
        (applied, failures) `shouldBe` (ExitSuccess, "")
        driveApplyPatches fixture recipeDirectory source `shouldReturn` ExitSuccess
        readFile (source </> "note.txt") `shouldReturn` "base\nfirst\nsecond\n"

        -- The same patches against a source they no longer fit: the recipe
        -- stops rather than building something the patch did not reach.
        let stale = scratch fixture </> "stale"
        writeFixtureFile stale "note.txt" "something else entirely\n"
        driveApplyPatches fixture recipeDirectory stale >>= (`shouldNotBe` ExitSuccess)

    it "records every patch, in order and by content, in the native identity" $
      withFixture $ \fixture → do
        recipeDirectory ← copiedRecipe fixture
        clearPatches recipeDirectory
        writeFixtureFile recipeDirectory "patches/0002-second.patch" (appendingPatch ["base", "first"] "second")
        writeFixtureFile recipeDirectory "patches/0001-first.patch" (appendingPatch ["base"] "first")
        recorded ← recordedPatches fixture recipeDirectory
        map fst recorded `shouldBe` ["0001-first.patch", "0002-second.patch"]
        map snd recorded `shouldSatisfy` all ((== 64) . length)
        -- Content, not just name: same names, different bytes, different digests.
        writeFixtureFile recipeDirectory "patches/0001-first.patch" (appendingPatch ["base"] "altered")
        altered ← recordedPatches fixture recipeDirectory
        map fst altered `shouldBe` map fst recorded
        map snd altered `shouldNotBe` map snd recorded

        clearPatches recipeDirectory
        recordedPatches fixture recipeDirectory `shouldReturn` []

    it "moves the recipe fingerprint for an added, changed, reordered, or removed patch" $
      withFixture $ \fixture → do
        recipeDirectory ← copiedRecipe fixture
        clearPatches recipeDirectory
        bare ← recipeFingerprint fixture recipeDirectory
        writeFixtureFile recipeDirectory "patches/0001-first.patch" (appendingPatch ["base"] "first")
        one ← recipeFingerprint fixture recipeDirectory
        one `shouldNotBe` bare
        writeFixtureFile recipeDirectory "patches/0002-second.patch" (appendingPatch ["base", "first"] "second")
        two ← recipeFingerprint fixture recipeDirectory
        two `shouldNotBe` one
        -- The same two patches under swapped names apply in the other order,
        -- and are a different recipe.
        writeFixtureFile recipeDirectory "patches/0001-first.patch" (appendingPatch ["base", "first"] "second")
        writeFixtureFile recipeDirectory "patches/0002-second.patch" (appendingPatch ["base"] "first")
        swapped ← recipeFingerprint fixture recipeDirectory
        swapped `shouldNotBe` two
        clearPatches recipeDirectory
        recipeFingerprint fixture recipeDirectory `shouldReturn` bare

    it "refuses a prefix whose recorded patches are not this configuration's, naming them" $
      withFixture $ \fixture → do
        recipeDirectory ← copiedRecipe fixture
        let prefix = scratch fixture </> "prefix"
        createDirectoryIfMissing True prefix
        -- A manifest exactly as a prefix built before the patch landed would
        -- carry it: this configuration's identity with the patches left out.
        stale ← staleManifest fixture recipeDirectory prefix
        writeFixtureFile prefix "hetoimasia-native-manifest.json" stale
        (result, _, diagnosis) ←
          pythonIn fixture [recipeDirectory </> "native.py", "check", "--prefix", prefix]
        result `shouldNotBe` ExitSuccess
        diagnosis `shouldContain` "patches"
        diagnosis `shouldContain` "0001-wayland-fix-segfault-when-there-is-no-seat.patch"
        diagnosis `shouldContain` "rebuild it with"

  describe "the planner" $ do
    it "declares ci-image and native-manifest from a descriptor that describes the candidate" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        change fixture "src/note.txt" "an ordinary source change\n"
        plan ← planLinux fixture []
        toolchainEntry plan "ci-image" `shouldBe` Just (digest described)
        toolchainEntry plan "native-manifest" `shouldBe` Just (manifest described)
        toolchainEntry plan "ghc" `shouldBe` Just "9.14.1"
        toolchainEntry plan "cabal" `shouldBe` Just "3.18.1.0"
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

    it "declares the descriptor's Vulkan identities as toolchain entries" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        -- Every identity reaches the map, not just the digest that stands for
        -- all of them: a worker compares entry by entry, and a reader of a plan
        -- has to be able to see which loader, driver, layer, and compiler the
        -- image runs against without recomputing anything.
        plan ← planLinux fixture []
        forM_ (vulkanIdentities described) $ \(name, value) →
          (name, toolchainEntry plan name) `shouldBe` (name, Just value)

    it "refuses a descriptor that names no Vulkan identities" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        change fixture "tools/ci-image/descriptor.json" (withoutField "vulkan" (descriptorJson described))
        refusal ← planRaw fixture "HEAD" Nothing linuxPins
        refusedByBuilder refusal "missing 'vulkan'"

    it "refuses a descriptor whose Vulkan identity is not a digest" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        change fixture "tools/ci-image/descriptor.json" (withField "vulkan" "1.3.275" (descriptorJson described))
        refusal ← planRaw fixture "HEAD" Nothing linuxPins
        refusedByBuilder refusal "vulkan is not a 64-digit lowercase hex identity digest"

    it "refuses a descriptor that names a Vulkan input by nothing at all" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        change fixture "tools/ci-image/descriptor.json" (withField "vulkan_driver" "" (descriptorJson described))
        refusal ← planRaw fixture "HEAD" Nothing linuxPins
        refusedByBuilder refusal "vulkan_driver names no identity"

    it "refuses a descriptor that names no compositor version" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        change fixture "tools/ci-image/descriptor.json" (withoutCompositor (descriptorJson described))
        refusal ← planRaw fixture "HEAD" Nothing linuxPins
        refusedByBuilder refusal "missing 'weston'"

    it "refuses a descriptor whose compositor version is not a package revision" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        commitDescriptor fixture described {weston = "not a version"}
        refusal ← planRaw fixture "HEAD" Nothing linuxPins
        refusedByBuilder refusal "is not a package version"

    it "declares the descriptor's compositor revision as a toolchain entry" $
      withFixture $ \fixture → do
        void $ describedImage fixture
        plan ← planLinux fixture []
        toolchainEntry plan "weston" `shouldBe` Just pinnedCompositor
        -- A Darwin plan runs no image and therefore no compositor of the
        -- image's, and declares none.
        (local, darwin, errors) ←
          planRaw fixture "HEAD" Nothing ["--runner-os", "Darwin", "--toolchain", "native-manifest=" ++ replicate 64 '1']
        (local, errors) `shouldBe` (ExitSuccess, "")
        toolchainEntry darwin "weston" `shouldBe` Nothing

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
        toolchainEntry plan "ghc" `shouldBe` Just "9.14.1"

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

  describe "cache environment keys" $ do
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

    forM_ vulkanEntries $ \entry →
      it ("move when the image's " ++ entry ++ " identity moves") $
        withFixture $ \fixture → do
          described ← describedImage fixture
          before ← environmentKey fixture
          -- A changed loader, driver, layer, or compiler is a changed
          -- environment, whatever else stayed the same. If any of these did not
          -- move the key, a cache filled under the old runtime would be
          -- restored into a job running the new one.
          let replacement = if entry == "vulkan" then replicate 64 'd' else "something else entirely"
          change
            fixture
            "tools/ci-image/descriptor.json"
            (withField (descriptorField entry) replacement (descriptorJson described))
          after ← environmentKey fixture
          after `shouldNotBe` before

    it "make a receipt gathered under other Vulkan identities unusable" $
      withFixture $ \fixture → do
        described ← describedImage fixture
        before ← planLinux fixture []
        change
          fixture
          "tools/ci-image/descriptor.json"
          (withField "vulkan_driver" "another driver entirely" (descriptorJson described))
        after ← planLinux fixture []
        -- The toolchain map is one of the compatibility fields an execution has
        -- to match, so this is the whole mechanism: the identities are in the
        -- map, and evidence gathered under one map does not answer a candidate
        -- planned under another.
        problems ← reuseProblems fixture before after
        -- The input identity moves too, because the descriptor is a tracked
        -- file; the toolchain is the one that would still differ if the change
        -- had reached the image without touching the candidate.
        problems `shouldContain` ["records a different toolchain"]
        sameProblems ← reuseProblems fixture before before
        sameProblems `shouldBe` []

  describe "worker verification" $ do
    it "declares exactly the planned map when every entry agrees" $
      withWorker $ \fixture worker → do
        (result, output, errors) ← verify fixture worker
        (result, errors) `shouldBe` (ExitSuccess, "")
        declared ← strictRead (scratch fixture </> "toolchain.txt")
        sort (lines declared)
          `shouldBe` sort
            ( [ "cabal=3.18.1.0"
              , "ci-image=" ++ digestOf 'a'
              , "ghc=9.14.1"
              , "native-manifest=" ++ workerManifest worker
              , "weston=" ++ pinnedCompositor
              ]
                ++ [name ++ "=" ++ value | (name, value) ← workerVulkan worker]
            )
        -- Every Vulkan input is named in the map, not folded away into the one
        -- identity digest beside them: a reader comparing a worker with a
        -- record has to be able to see which loader, driver, layer, and
        -- compiler it ran against.
        sort (map fst (workerVulkan worker)) `shouldBe` sort vulkanEntries
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
        writeFile (workerImage worker </> "image.json") (embeddedImage (replicate 64 '0') pinnedCompositor)
        refusedWorker fixture worker "embeds recipe fingerprint"

    it "refuses an image that embeds no compositor version at all" $
      withWorker $ \fixture worker → do
        current ← fingerprintNow fixture
        writeFile (workerImage worker </> "image.json") ("{\"recipe_fingerprint\": \"" ++ current ++ "\"}\n")
        refusedWorker fixture worker "embeds compositor version None"

    it "refuses an image whose embedded compositor version is malformed" $
      withWorker $ \fixture worker → do
        current ← fingerprintNow fixture
        writeFile (workerImage worker </> "image.json") (embeddedImage current "not a version")
        refusedWorker fixture worker "which is not a package version"

    it "refuses a worker whose installed compositor is not the one its image embeds" $
      withWorker $ \fixture worker → do
        -- The installed package is the authority: an image stamped with one
        -- revision and carrying another is refused rather than believed.
        writeFile (workerStubs worker </> "weston-version") "13.0.0-5build1\n"
        refusedWorker fixture worker "but has weston 13.0.0-5build1 installed"

    it "refuses a worker with no installed compositor package" $
      withWorker $ \fixture worker → do
        removeFile (workerStubs worker </> "weston-version")
        refusedWorker fixture worker "no installed weston package"

    it "refuses a plan whose compositor entry is not the worker's" $
      withWorker $ \fixture worker → do
        patchPlanToolchain fixture (workerPlan worker) "weston" "13.0.0-5build1"
        refusedWorker fixture worker "toolchain entry 'weston'"

    it "refuses a Cabal store outside the fixed image location" $
      withWorker $ \fixture worker → do
        writeFile (workerStubs worker </> "store") "/root/.cabal/store\n"
        refusedWorker fixture worker "resolves its store"

    it "refuses a plan whose Vulkan identity is not the worker's" $
      withWorker $ \fixture worker → do
        patchPlanToolchain fixture (workerPlan worker) "vulkan" (replicate 64 '7')
        refusedWorker fixture worker "toolchain entry 'vulkan'"

    forM_ ["vulkan-loader", "vulkan-driver", "vulkan-layers", "glslang"] $ \entry →
      it ("refuses a plan whose " ++ entry ++ " identity is not the worker's") $
        withWorker $ \fixture worker → do
          patchPlanToolchain fixture (workerPlan worker) entry "something else entirely"
          refusedWorker fixture worker ("toolchain entry '" ++ entry ++ "'")

    it "refuses a worker whose provisioned Vulkan inputs were replaced under an intact manifest" $
      withWorker $ \fixture worker → do
        -- The worker re-reads and re-hashes what the prefix holds. Nothing
        -- about the plan, the descriptor, or the manifest changes here, which
        -- is the point: a container whose loader description was swapped after
        -- the image was stamped declares a different map and is refused.
        let described = workerPrefix worker </> "vulkan/lib/pkgconfig/vulkan.pc"
        existing ← strictRead described
        writeFile described (existing ++ "# a substituted byte\n")
        refusedWorker fixture worker "the native prefix check failed"

  describe "the image workflow's routes" $ do
    it "starts a proof route only on its own dispatch, and image resolution for no proof route" $ do
      -- The routes are read from the workflow's own choice list rather than
      -- named here, so a route added later without excluding it from
      -- `resolve` — which is what would let a proof dispatch reach the
      -- registry — fails this example rather than passing unnoticed.
      workflow ← imageWorkflow
      let routes = choiceOptions workflow "route"
          proofs = filter (/= imageRoute) routes
      routes `shouldContain` [imageRoute]
      proofs `shouldNotBe` []
      let resolving = jobCondition workflow "resolve"
      forM_ proofs $ \route → do
        resolving `shouldContain` ("inputs.route != '" ++ route ++ "'")
        case jobsSelecting workflow route of
          [job] → do
            let condition = jobCondition workflow job
            -- A pull request carries no route input at all, so requiring the
            -- dispatch event is what keeps every proof route out of one.
            condition `shouldContain` "github.event_name == 'workflow_dispatch'"
            condition `shouldContain` ("inputs.route == '" ++ route ++ "'")
          selecting → expectationFailure (route ++ " is selected by " ++ show selecting)

    it "reads each builder output under the name the builder writes it" $ do
      -- The builder writes a GitHub output per identity, hyphenating the
      -- descriptor's own field names as GitHub conventionally does. A job that
      -- read `outputs.vulkan_loader` would therefore read an empty string and
      -- pass every step until the descriptor it composed was rejected for
      -- naming no identity — which is exactly what happened once. Nothing here
      -- may refer to a step output by its underscored spelling.
      workflow ← imageWorkflow
      let referenced =
            [ trimmed (takeWhile (/= ' ') (drop (length marker) piece))
            | line ← lines workflow
            , piece ← tails' line
            , marker `isPrefixOf` piece
            ]
          marker = ".outputs."
          underscored = [name | name ← referenced, '_' `elem` name]
      referenced `shouldSatisfy` (not . null)
      underscored `shouldBe` []

    it "reaches the registry only through the job the proof routes exclude" $ do
      workflow ← imageWorkflow
      -- Excluding `resolve` is only worth anything if nothing that publishes
      -- can start without it.
      jobNeeds workflow "publish" `shouldContain` ["resolve"]
      jobNeeds workflow "descriptor" `shouldContain` ["resolve"]
      jobNeeds workflow "anonymous-pull" `shouldContain` ["descriptor"]
      -- And only that chain may hold the package grant.
      [job | job ← jobNames workflow, "packages: write" `isInfixOf` unlines (jobBlock workflow job)]
        `shouldBe` ["publish"]

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

    it "refuses an existing image whose compositor label is not the pinned revision" $
      withRegistry $ \registry → do
        answer registry [compositorAnswer fingerprintX (replicate 64 'b') "13.0.0-5build1"]
        (resolved, _, errors) ← builder registry "resolve" []
        resolved `shouldBe` ExitFailure 2
        errors `shouldContain` ("its weston label is '13.0.0-5build1', not " ++ pinnedCompositor)
        errors `shouldContain` "never overwritten"
        answer registry ["absent", compositorAnswer fingerprintX (replicate 64 'b') "13.0.0-5build1"]
        (published, _, publishErrors) ← builder registry "publish" ["--context", registryDirectory registry]
        published `shouldBe` ExitFailure 2
        publishErrors `shouldContain` "its weston label is"
        -- The refusal is after the push, on reading the published metadata
        -- back, so the tag is never left described as something it is not.
        calls registry `shouldReturn` ["lookup", "lookup", "build", "validate", "push", "lookup"]

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


    describe "the Vulkan runtime it provisions" $ do
      it "provisions one identity cold and warm, and rebuilds nothing to do it" $
        withNative $ \native → do
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          cold ← nativeManifestNow native []
          coldIdentities ← nativeIdentities native
          archive ← strictRead (nativePrefix native </> "lib/libglfw3.a")
          -- Provisioning again from an unchanged machine. The loader, the two
          -- manifests, the package description, and the wrapper are all
          -- rewritten, and every identity has to come out the same — otherwise
          -- warm reuse would move the toolchain map on every job.
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          nativeManifestNow native [] `shouldReturn` cold
          nativeIdentities native `shouldReturn` coldIdentities
          strictRead (nativePrefix native </> "lib/libglfw3.a") `shouldReturn` archive
          nativeOk native [] ["check", "--prefix", nativePrefix native]

      it "names every Vulkan input in the toolchain map it contributes" $
        withNative $ \native → do
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          identities ← nativeIdentities native
          sort (map fst identities) `shouldBe` sort vulkanEntries
          lookup "vulkan-loader" identities `shouldSatisfy` maybe False (fixtureLoaderVersion `isPrefixOf`)
          lookup "vulkan-layers" identities `shouldSatisfy` maybe False (fixtureLayerName `isPrefixOf`)
          lookup "glslang" identities `shouldSatisfy` maybe False (fixtureGlslangVersion `isPrefixOf`)

      forM_ substitutions $ \substitution →
        it ("refuses a prefix whose " ++ substitutionLabel substitution ++ " was replaced, manifest and all") $
          withNative $ \native → do
            nativeOk native [] ["record", "--prefix", nativePrefix native]
            let recorded = nativePrefix native </> "hetoimasia-native-manifest.json"
            before ← strictRead recorded
            -- The manifest is deliberately left exactly as it was: the point is
            -- that verification reads and hashes the files themselves, so a
            -- substitution under an intact record is caught rather than
            -- believed. A check that trusted the recorded digests would pass
            -- every one of these.
            substitute native (substitutionPath substitution native)
            (refused, _, errors) ← nativeTool native [] ["check", "--prefix", nativePrefix native]
            refused `shouldBe` ExitFailure 1
            errors `shouldContain` substitutionNamed substitution
            strictRead recorded `shouldReturn` before

      it "refuses an input the machine no longer holds, naming what it does hold" $
        withNative $ \native → do
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          -- The loader is gone, but its directory still holds the driver and
          -- layer libraries. Nothing falls back to either: the diagnosis says
          -- what is there and stops.
          let loader = nativeInputs native </> "lib/libvulkan.1.4.2.dylib"
              kept = nativeDirectory native </> "loader.kept"
          copyFile loader kept
          removeFile loader
          (missing, _, listed) ← nativeTool native [] ["record", "--prefix", nativePrefix native]
          missing `shouldBe` ExitFailure 1
          listed `shouldContain` "the pinned loader"
          listed `shouldContain` "does not exist"
          listed `shouldContain` "holds: libFixtureDriver.dylib"
          listed `shouldContain` "nothing else is used instead"
          -- And an empty directory is reported as empty rather than as a list
          -- of nothing, which is the case a reader is most likely to hit.
          removeFile (nativeInputs native </> "share/vulkan/icd.d/fixture_icd.json")
          copyFile kept loader
          (refused, _, errors) ← nativeTool native [] ["record", "--prefix", nativePrefix native]
          refused `shouldBe` ExitFailure 1
          errors `shouldContain` "icd.d is empty"

      it "accepts an override resolving to the qualified input and refuses one that does not" $
        withNative $ \native → do
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          original ← nativeManifestNow native []
          -- A link is not a different input: it is resolved, and the file it
          -- resolves to is what the pin qualifies. The identity still moves,
          -- because a prefix provisioned through a relocated input is a prefix
          -- of that route.
          let link = nativeDirectory native </> "moving-icd.json"
          createFileLink (nativeInputs native </> "share/vulkan/icd.d/fixture_icd.json") link
          let relocated = [("HETOIMASIA_VULKAN_DRIVER_MANIFEST", link)]
          nativeOk native relocated ["record", "--prefix", nativePrefix native]
          nativeOk native relocated ["check", "--prefix", nativePrefix native]
          relocatedManifest ← nativeManifestNow native relocated
          relocatedManifest `shouldNotBe` original
          -- And the same override pointed at something else is refused, which
          -- is what makes the acceptance above a qualification rather than a
          -- waiver.
          writeFileEnsuring
            (nativeDirectory native </> "other-icd.json")
            (unlines (map replaceVersion (lines (fixtureIcd (nativeInputs native)))))
          (refused, _, errors) ←
            nativeTool
              native
              [("HETOIMASIA_VULKAN_DRIVER_MANIFEST", nativeDirectory native </> "other-icd.json")]
              ["record", "--prefix", nativePrefix native]
          refused `shouldBe` ExitFailure 1
          errors `shouldContain` "not the pinned"

      it "runs the pinned compiler through its wrapper, whatever PATH offers" $
        withNative $ \native → do
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          -- An unrelated executable of the same name, ahead of everything on
          -- PATH. The wrapper names its compiler absolutely, so this is never
          -- what runs through it.
          let decoy = nativeDirectory native </> "decoy"
          createDirectoryIfMissing True decoy
          executableFile (decoy </> "glslangValidator") "#!/bin/sh\necho 'Glslang Version: 11:0.0.0'\n"
          let wrapper = nativePrefix native </> "vulkan/bin/glslangValidator"
              ahead = decoy ++ maybe "" (':' :) (lookup "PATH" (nativeEnvironment native))
              shadowed = overriding [("PATH", ahead)] (nativeEnvironment native)
          (ran, version, _) ← run shadowed (nativeDirectory native) wrapper ["--version"]
          ran `shouldBe` ExitSuccess
          version `shouldContain` fixtureGlslangVersion
          version `shouldNotContain` "0.0.0"
          -- And it answers for itself, compiling nothing: the fixture compiler
          -- exits non-zero for every other argument, so a wrapper that passed
          -- this through would fail here.
          (reported, identity, _) ← run shadowed (nativeDirectory native) wrapper ["--hetoimasia-identity"]
          reported `shouldBe` ExitSuccess
          identity `shouldContain` ("glslang " ++ fixtureGlslangVersion)
          identity `shouldContain` "sha256 "

      forM_ ["Darwin", "Linux"] $ \target →
        it ("refuses an unqualified " ++ target ++ " input before it provisions anything") $
          withNative $ \native → do
            -- Pre-provision, and on both platforms. Linux pins package
            -- revisions as well as digests, and dpkg saying a package is
            -- installed is not the same as the file at a path having come from
            -- it — so without the digest an override here would relocate an
            -- input and replace it in one move. Nothing is recorded first:
            -- this is the refusal that happens before a prefix exists at all.
            let elsewhere = nativeDirectory native </> (target ++ "-other-icd.json")
            writeFileEnsuring elsewhere (unlines (map replaceVersion (lines (fixtureIcd (nativeInputs native)))))
            (refused, _, errors) ←
              nativeToolOn
                target
                native
                [("HETOIMASIA_VULKAN_DRIVER_MANIFEST", elsewhere)]
                ["record", "--prefix", nativePrefix native]
            refused `shouldBe` ExitFailure 1
            errors `shouldContain` "not the pinned"
            doesDirectoryExist (nativePrefix native </> "vulkan") `shouldReturn` False
            -- And the same override pointed at the qualified file is accepted,
            -- so the refusal above is the digest talking and not the override.
            nativeOk
              native
              []
              ["record", "--prefix", nativePrefix native]
            (accepted, _, acceptErrors) ←
              nativeToolOn
                target
                native
                [("HETOIMASIA_VULKAN_DRIVER_MANIFEST", nativeInputs native </> "share/vulkan/icd.d/fixture_icd.json")]
                ["record", "--prefix", nativePrefix native]
            (accepted, acceptErrors) `shouldBe` (ExitSuccess, "")

      forM_ ["Darwin", "Linux"] $ \target →
        it ("refuses a substituted " ++ target ++ " source before it provisions anything") $
          withNative $ \native → do
            -- The substitution examples above replace a file beneath a record
            -- that already exists. This one replaces it before any record does,
            -- which is the case a check of the record cannot reach.
            substitute native (nativeInputs native </> "lib/libFixtureDriver.dylib")
            (refused, _, errors) ← nativeToolOn target native [] ["record", "--prefix", nativePrefix native]
            refused `shouldBe` ExitFailure 1
            errors `shouldContain` "a substituted driver binary invalidates the evidence"
            doesDirectoryExist (nativePrefix native </> "vulkan") `shouldReturn` False

      forM_ loaderLinkDamage $ \(label, damage, named) →
        it ("refuses a prefix whose linker-facing loader link was " ++ label) $
          withNative $ \native → do
            -- `-lvulkan` opens `libvulkan.dylib`, not the versioned file beside
            -- it, so the link is the loader's discovery route rather than a
            -- convenience. Hashing only what it points at would accept a prefix
            -- that no longer links, or one that links something else.
            nativeOk native [] ["record", "--prefix", nativePrefix native]
            let link = nativePrefix native </> "vulkan/lib/libvulkan.dylib"
            damage link
            (refused, _, errors) ← nativeTool native [] ["check", "--prefix", nativePrefix native]
            refused `shouldBe` ExitFailure 1
            errors `shouldContain` named

      it "refuses a Vulkan product the prefix does not own" $
        withNative $ \native → do
          nativeOk native [] ["record", "--prefix", nativePrefix native]
          -- A record naming a manifest outside the prefix describes a different
          -- prefix, and hashing that file would say nothing about this one.
          patchManifest native "['vulkan']['driver']['manifest'] = '/elsewhere/icd.json'"
          (refused, _, errors) ← nativeTool native [] ["check", "--prefix", nativePrefix native]
          refused `shouldBe` ExitFailure 1
          errors `shouldContain` "which is not inside"

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

    it "refuses a prefix whose recorded backends are not the ones the archive compiles" $
      withNative $ \native → do
        nativeOk native [] ["record", "--prefix", nativePrefix native]
        -- The manifest is what makes the compiled backends observable, so a
        -- manifest claiming a backend the archive does not carry is refused
        -- rather than believed.
        (patched, _, patchErrors) ←
          run
            (nativeEnvironment native)
            (nativeDirectory native)
            (nativePython native)
            [ "-c"
            , "import json, sys\n\
              \path = sys.argv[1]\n\
              \document = json.load(open(path, encoding='utf-8'))\n\
              \document['backends'] = ['Wayland']\n\
              \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
            , nativePrefix native </> "hetoimasia-native-manifest.json"
            ]
        (patched, patchErrors) `shouldBe` (ExitSuccess, "")
        (result, _, errors) ← nativeTool native [] ["check", "--prefix", nativePrefix native]
        result `shouldBe` ExitFailure 1
        errors `shouldContain` "the manifest records backends ['Wayland']"

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

-- | A writable copy of the shipped native recipe, so an example can vary its
-- patches without touching the checkout it runs from.
copiedRecipe ∷ Fixture → IO FilePath
copiedRecipe fixture = do
  let destination = scratch fixture </> "recipe"
  createDirectoryIfMissing True destination
  (copied, _, errors) ←
    run (environment fixture) (root fixture) "cp" ["-R", checkout fixture </> "tools/native/.", destination]
  (copied, errors) `shouldBe` (ExitSuccess, "")
  pure destination

-- | Remove every patch the copy carries, for an example that supplies its own.
clearPatches ∷ FilePath → IO ()
clearPatches recipeDirectory = do
  let directory = recipeDirectory </> "patches"
  present ← doesDirectoryExist directory
  when present $ do
    names ← listDirectory directory
    forM_ names $ \name → removeFile (directory </> name)

-- | A patch appending one line to a note.txt that currently holds exactly the
-- given lines. Each patch in a sequence is written against what the one before
-- it produced, as a real series of backports is.
appendingPatch ∷ [String] → String → String
appendingPatch existing line =
  unlines $
    [ "--- a/note.txt"
    , "+++ b/note.txt"
    , "@@ -1," ++ show (length existing) ++ " +1," ++ show (length existing + 1) ++ " @@"
    ]
      ++ map (' ' :) existing
      ++ ["+" ++ line]

-- | Drive the recipe's own patch application against a directory, which is
-- what the build does between unpacking and configuring.
driveApplyPatches ∷ Fixture → FilePath → FilePath → IO ExitCode
driveApplyPatches fixture recipeDirectory source = do
  (result, _, _) ←
    pythonIn fixture
      [ "-c"
      , "import sys; sys.path.insert(0, sys.argv[1]); import native; native.apply_patches(sys.argv[2])"
      , recipeDirectory
      , source
      ]
  pure result

-- | The patches this configuration records, by name and digest, in order.
recordedPatches ∷ Fixture → FilePath → IO [(String, String)]
recordedPatches fixture recipeDirectory = do
  (result, output, errors) ← pythonIn fixture [recipeDirectory </> "native.py", "identity"]
  (result, errors) `shouldBe` (ExitSuccess, "")
  case parseJson output >>= field "patches" >>= asArray of
    Nothing → expectationFailure ("no patches in the identity: " ++ output) >> pure []
    Just entries →
      pure
        [ (name, digest)
        | entry ← entries
        , Just name ← [field "name" entry >>= asString]
        , Just digest ← [field "sha256" entry >>= asString]
        ]

-- | The recipe fingerprint the copied recipe reports for itself.
recipeFingerprint ∷ Fixture → FilePath → IO String
recipeFingerprint fixture recipeDirectory = do
  (result, output, errors) ← pythonIn fixture [recipeDirectory </> "native.py", "fingerprint"]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure (takeWhile (/= '\n') output)

-- | This configuration's manifest with the patches left out, which is exactly
-- what a prefix built before a patch landed carries.
staleManifest ∷ Fixture → FilePath → FilePath → IO String
staleManifest fixture recipeDirectory prefix = do
  (result, output, errors) ←
    pythonIn fixture
      [ "-c"
      , unlines
          [ "import json, sys"
          , "sys.path.insert(0, sys.argv[1])"
          , "import native"
          , "pin = native.read_pin()"
          , "identity = native.native_identity(native.host_platform(), pin)"
          , "identity.pop('patches', None)"
          , "print(json.dumps({"
          , "  'schema_version': native.MANIFEST_SCHEMA_VERSION,"
          , "  'library': 'glfw3',"
          , "  'glfw_version': pin['GLFW_VERSION'],"
          , "  'source_url': pin['GLFW_URL'],"
          , "  'source_sha256': pin['GLFW_SHA256'],"
          , "  'recipe_fingerprint': native.recipe_fingerprint(),"
          , "  'identity': identity,"
          , "  'prefix': native.normalized(sys.argv[2]),"
          , "}))"
          ]
      , recipeDirectory
      , prefix
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure output

recipePaths ∷ [FilePath]
recipePaths =
  [ ".github/workflows/ci-image.yml"
  , "tools/ci-image/Dockerfile"
  , "tools/ci-image/builder.py"
  , "tools/ci-image/compositor.pin"
  , "tools/ci-image/provision.sh"
  , "tools/ci-image/registry.py"
  , "tools/ci-image/toolchain.pin"
  , "tools/native/glfw.pin"
  , "tools/native/native.py"
  , "tools/native/vulkan.pin"
  , "tools/native/vulkan.py"
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
descriptorJson described = renderObject (descriptorFields described)

-- | Every field a descriptor carries, as the contract names them.
descriptorFields ∷ Descriptor → [(String, String)]
descriptorFields described =
  [ ("architecture", "\"amd64\"")
  , ("cabal", quoted (cabal described))
  , ("digest", quoted (digest described))
  , ("ghc", quoted (ghc described))
  , ("native_manifest", quoted (manifest described))
  , ("platform", "\"linux\"")
  , ("recipe_fingerprint", quoted (recipe described))
  , ("reference", "\"ghcr.io/owner/project-ci\"")
  , ("schema_version", "2")
  , ("weston", quoted (weston described))
  ]
    ++ [(descriptorField name, quoted value) | (name, value) ← vulkanIdentities described]

-- | A JSON object from its fields, sorted, with the comma discipline handled
-- once rather than at each call site that adds or removes a field.
renderObject ∷ [(String, String)] → String
renderObject fields =
  unlines (["{"] ++ zipWith line [1 ..] (sort fields) ++ ["}"])
  where
    line index (name, value) =
      "  \"" ++ name ++ "\": " ++ value ++ (if index == length fields then "" else ",")

quoted ∷ String → String
quoted value = "\"" ++ value ++ "\""

-- | The descriptor spelling of one toolchain entry: the entry name with its
-- hyphen as an underscore, exactly as the contract derives it.
descriptorField ∷ String → String
descriptorField = map (\character → if character == '-' then '_' else character)

-- | The same descriptor with the compositor field taken out, which is what a
-- descriptor written before the image carried one looks like.
withoutCompositor ∷ String → String
withoutCompositor = withoutField "weston"

-- | The same descriptor with one field removed entirely.
withoutField ∷ String → String → String
withoutField name = renderObject . filter ((/= name) . fst) . objectFields

-- | The same descriptor with one field replaced, for an example that varies a
-- single identity without restating the rest.
withField ∷ String → String → String → String
withField name value =
  renderObject . map (\entry → if fst entry == name then (name, quoted value) else entry) . objectFields

-- | The fields of a rendered object, read back so a variation can be expressed
-- as an edit rather than as a second spelling of the whole document.
objectFields ∷ String → [(String, String)]
objectFields text =
  [ (takeWhile (/= '"') (drop 1 body), dropWhileEnd (== ',') (drop 2 (dropWhile (/= ':') body)))
  | line ← map trimmed (lines text)
  , line /= "{" && line /= "}" && not (null line)
  , let body = line
  ]

-- | The same descriptor written with different bytes.
--
-- Only the layout is removed. An identity such as a driver's name and version
-- carries spaces of its own, and squeezing those out would write a different
-- descriptor rather than the same one differently.
compactDescriptor ∷ Descriptor → String
compactDescriptor = concatMap (dropWhile (== ' ')) . lines . descriptorJson

commitDescriptor ∷ Fixture → Descriptor → IO ()
commitDescriptor fixture = change fixture "tools/ci-image/descriptor.json" . descriptorJson

-- | Commit a descriptor that describes the current recipe.
describedImage ∷ Fixture → IO Descriptor
describedImage fixture = do
  current ← fingerprintNow fixture
  let described =
        Descriptor (digestOf 'a') (replicate 64 'b') current "9.14.1" "3.18.1.0" pinnedCompositor placeholderVulkan
  commitDescriptor fixture described
  pure described

-- | Vulkan identities shaped like a real image's, for the planner examples.
--
-- The planner only carries these into the toolchain map, so what they say does
-- not matter to it; that they are well formed and that a change to any of them
-- reaches the map does. A worker example uses the machine's own identities
-- instead, because there the two sides have to agree.
placeholderVulkan ∷ [(String, String)]
placeholderVulkan =
  [ ("vulkan", replicate 64 'c')
  , ("vulkan-loader", "1.3.275 0123456789ab")
  , ("vulkan-driver", "lvp 1.4.309 cdef01234567")
  , ("vulkan-layers", "VK_LAYER_KHRONOS_validation 1.3.275 89abcdef0123")
  , ("glslang", "15.1.0 456789abcdef")
  ]

descriptorNow ∷ Fixture → IO Descriptor
descriptorNow fixture = do
  text ← strictRead (root fixture </> "tools/ci-image/descriptor.json")
  let value name = maybe (error ("descriptor has no " ++ name)) id (parseJson text >>= field name >>= asString)
  pure
    ( Descriptor
        (value "digest")
        (value "native_manifest")
        (value "recipe_fingerprint")
        (value "ghc")
        (value "cabal")
        (value "weston")
        [(name, value (descriptorField name)) | name ← vulkanEntries]
    )

-- | The toolchain-map entries the Vulkan runtime contributes, in the order a
-- descriptor and a declared map both list them.
vulkanEntries ∷ [String]
vulkanEntries = ["vulkan", "vulkan-loader", "vulkan-driver", "vulkan-layers", "glslang"]

-- | The Ubuntu 24.04 package revision the recipe pins the compositor to.
pinnedCompositor ∷ String
pinnedCompositor = "13.0.0-4build3"

linuxPins ∷ [String]
linuxPins = ["--runner-os", "Linux", "--toolchain", "ghc=9.14.1", "--toolchain", "cabal=3.18.1.0"]

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

-- | Why an execution planned under one toolchain does not answer another.
--
-- Asked of the evidence tool itself rather than restated here, because the
-- compatibility fields are its contract and an example that listed them again
-- would agree with itself while the two drifted apart.
reuseProblems ∷ Fixture → String → String → IO [String]
reuseProblems fixture evidencePlan candidatePlan = do
  let evidencePath = scratch fixture </> "evidence-plan.json"
      candidatePath = scratch fixture </> "candidate-plan.json"
  writeFile evidencePath evidencePlan
  writeFile candidatePath candidatePlan
  (result, output, errors) ←
    pythonIn
      fixture
      [ "-c"
      , unlines
          [ "import json, sys"
          , "sys.path.insert(0, sys.argv[1])"
          , "import receipts"
          , "evidence = receipts.load_plan(sys.argv[2])"
          , "candidate = receipts.load_plan(sys.argv[3])"
          , "print(json.dumps(receipts.compatibility_problems("
          , "    receipts.candidate_identity(candidate),"
          , "    receipts.candidate_identity(evidence),"
          , "    'the earlier execution')))"
          ]
      , checkout fixture </> "tools/validation"
      , evidencePath
      , candidatePath
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure
    [ drop (length prefix) piece
    | raw ← splitOnComma (takeWhile (/= ']') (drop 1 (dropWhile (/= '[') output)))
    , let piece = filter (/= '"') (trimmed raw)
    , let prefix = "the earlier execution "
    , prefix `isPrefixOf` piece
    ]

splitOnComma ∷ String → [String]
splitOnComma text = case break (== ',') text of
  (piece, []) → [piece]
  (piece, _ : rest) → piece : splitOnComma rest

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
-- The image workflow, read as the pipeline loads it
--
-- Deliberately dependency-free, for the reason Sandbox's step reader gives:
-- an example that needed a YAML library installed to read a workflow would be
-- skipped exactly when it mattered. Only the shapes this file actually uses
-- are understood — a job is a two-space key under `jobs:`, and its fields are
-- the four-space keys under it.

ciImageWorkflow ∷ FilePath
ciImageWorkflow = ".github/workflows/ci-image.yml"

-- | The route that publishes. Every other route is a proof route.
imageRoute ∷ String
imageRoute = "image"

-- | Every suffix of a line, so a marker can be found wherever it sits.
tails' ∷ String → [String]
tails' text = text : case text of
  (_ : rest) → tails' rest
  [] → []

imageWorkflow ∷ IO String
imageWorkflow = getCurrentDirectory >>= \here → strictRead (here </> ciImageWorkflow)

-- | The lines of one job, without its own key.
jobBlock ∷ String → String → [String]
jobBlock workflow name =
  takeWhile inside (drop 1 (dropWhile (/= ("  " ++ name ++ ":")) (lines workflow)))
  where
    inside line = null (trimmed line) || "    " `isPrefixOf` line

jobNames ∷ String → [String]
jobNames workflow =
  [ takeWhile (/= ':') (drop 2 line)
  | line ← drop 1 (dropWhile (/= "jobs:") (lines workflow))
  , "  " `isPrefixOf` line
  , not ("   " `isPrefixOf` line)
  , ":" `isInfixOf` line
  ]

-- | One field of a job, as written; the empty string when it has none.
jobField ∷ String → String → String → String
jobField workflow name key =
  case [drop (length key + 1) (trimmed line) | line ← jobBlock workflow name, (key ++ ":") `isPrefixOf` trimmed line] of
    value : _ → trimmed value
    [] → ""

jobCondition ∷ String → String → String
jobCondition workflow name = jobField workflow name "if"

-- | A job's declared dependencies, whether written as one name or a list.
jobNeeds ∷ String → String → [String]
jobNeeds workflow name =
  words (map (\character → if character `elem` ("[]," ∷ String) then ' ' else character) (jobField workflow name "needs"))

-- | The jobs one route selects, by their own condition.
jobsSelecting ∷ String → String → [String]
jobsSelecting workflow route =
  [job | job ← jobNames workflow, ("inputs.route == '" ++ route ++ "'") `isInfixOf` jobCondition workflow job]

-- | The values a workflow-dispatch choice input offers.
choiceOptions ∷ String → String → [String]
choiceOptions workflow name =
  [ trimmed (drop 1 (trimmed line))
  | line ← takeWhile (\line → "- " `isPrefixOf` trimmed line) after
  ]
  where
    declared = dropWhile (/= ("      " ++ name ++ ":")) (lines workflow)
    after = drop 1 (dropWhile (\line → trimmed line /= "options:") declared)

trimmed ∷ String → String
trimmed = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- ---------------------------------------------------------------------------
-- A fake image root and worker

data Worker = Worker
  { workerImage ∷ FilePath
  , workerStubs ∷ FilePath
  , workerPlan ∷ FilePath
  , workerManifest ∷ String
  , workerPrefix ∷ FilePath
  , workerVulkan ∷ [(String, String)]
  }

-- | The Linux packages the Vulkan pin names, with the revision it pins each to.
--
-- Read out of the pin rather than restated here, so a package added to it is
-- answered for by the fixture's dpkg without anyone remembering to add it.
-- Empty off Linux, where the recipe pins digests instead of packages.
linuxPinnedPackages ∷ Fixture → IO [(String, String)]
linuxPinnedPackages fixture = do
  (result, output, errors) ←
    pythonIn
      fixture
      [ "-c"
      , unlines
          [ "import platform, sys"
          , "sys.path.insert(0, sys.argv[1])"
          , "import vulkan"
          , "for package in vulkan.pinned_inputs(platform.system(), vulkan.read_pin())['packages']:"
          , "    print(package['name'], package['version'])"
          ]
      , checkout fixture </> "tools/native"
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure [(name, version) | line ← lines output, [name, version] ← [words line]]

-- | Every toolchain entry the prefix itself yields, as the recipe spells them.
--
-- Read through the recipe rather than restated here: the planner, the image,
-- and the worker all have to arrive at one spelling, and an example that
-- invented a second would pass while the three disagreed.
provisionedIdentities ∷ Fixture → FilePath → IO [(String, String)]
provisionedIdentities fixture prefix = do
  (result, output, errors) ←
    pythonIn fixture [checkout fixture </> "tools/native/native.py", "toolchain", "--prefix", prefix]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure [(name, drop 1 value) | line ← lines output, let (name, value) = break (== '=') line, name /= "native-manifest"]

withWorker ∷ (Fixture → Worker → IO a) → IO a
withWorker action = withFixture $ \fixture → do
  current ← fingerprintNow fixture
  let image = scratch fixture </> "image"
      prefix = image </> "native/glfw"
      stubs = scratch fixture </> "bin"
  fakePrefix prefix
  writeFixtureFile image "image.json" (embeddedImage current pinnedCompositor)
  createDirectoryIfMissing True (image </> "cabal/store")
  (recorded, _, recordErrors) ←
    pythonIn fixture [checkout fixture </> "tools/native/native.py", "record", "--prefix", prefix]
  (recorded, recordErrors) `shouldBe` (ExitSuccess, "")
  hash ← sha256Of fixture (prefix </> "hetoimasia-native-manifest.json")
  -- The Vulkan identities this machine actually provisioned into the fixture
  -- prefix. The descriptor has to name these rather than a placeholder,
  -- because a worker declares what it finds and the two must agree.
  identities ← provisionedIdentities fixture prefix
  commitDescriptor fixture (Descriptor (digestOf 'a') hash current "9.14.1" "3.18.1.0" pinnedCompositor identities)
  plan ← planLinux fixture []
  let planPath = scratch fixture </> "plan.json"
  writeFile planPath plan
  createDirectoryIfMissing True stubs
  writeFile (stubs </> "ghc-version") "9.14.1\n"
  writeFile (stubs </> "cabal-version") "3.18.1.0\n"
  writeFile (stubs </> "weston-version") (pinnedCompositor ++ "\n")
  writeFile (stubs </> "store") (image </> "cabal/store\n")
  -- dpkg answers per package, for the compositor and for each Vulkan package
  -- the recipe pins, and reports one absent once the file standing in for its
  -- installation is gone. Answering every query with one version would let a
  -- worker that checks several packages pass while reading the same one back
  -- each time — which is exactly what it did until Linux said so.
  pinnedPackages ← linuxPinnedPackages fixture
  forM_ pinnedPackages $ \(name, version) → writeFile (stubs </> (name ++ "-version")) (version ++ "\n")
  executableFile
    (stubs </> "dpkg-query")
    ( unlines
        [ "#!/bin/sh"
        , "for argument in \"$@\"; do package=\"$argument\"; done"
        , "answer='" ++ stubs ++ "'/\"$package\"-version"
        , "if [ ! -f \"$answer\" ]; then"
        , "  echo \"dpkg-query: no packages found matching $package\" >&2"
        , "  exit 1"
        , "fi"
        , "cat \"$answer\""
        ]
    )
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
  action fixture (Worker image stubs planPath hash prefix identities)

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

-- | The metadata an image embeds at @/opt/hetoimasia/image.json@: the recipe it
-- was built from and the compositor revision it installed.
embeddedImage ∷ String → String → String
embeddedImage fingerprint compositor =
  "{\"recipe_fingerprint\": \"" ++ fingerprint ++ "\", \"weston\": \"" ++ compositor ++ "\"}\n"

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
labelledAnswer recipeLabel manifestLabel = compositorAnswer recipeLabel manifestLabel pinnedCompositor

compositorAnswer ∷ String → String → String → String
compositorAnswer recipeLabel manifestLabel compositorLabel =
  "{\"digest\": \""
    ++ digestOf 'a'
    ++ "\", \"labels\": {\"org.hetoimasia.ci-image.recipe-fingerprint\": \""
    ++ recipeLabel
    ++ "\", \"org.hetoimasia.ci-image.native-manifest\": \""
    ++ manifestLabel
    ++ "\", \"org.hetoimasia.ci-image.weston\": \""
    ++ compositorLabel
    ++ "\", \"org.hetoimasia.ci-image.ghc\": \"9.14.1\", \"org.hetoimasia.ci-image.cabal\": \"3.18.1.0\""
    ++ concat
      [ ", \"org.hetoimasia.ci-image." ++ name ++ "\": \"" ++ value ++ "\""
      | (name, value) ← placeholderVulkan
      ]
    ++ "}}"

-- | The Vulkan identities the stub transport reports for a candidate it built.
--
-- The builder reads these off the image rather than being told them, so the
-- transport is what supplies them here, exactly as the real one reads them out
-- of the image the recipe stamped.
builtIdentities ∷ String
builtIdentities =
  concat [", \"" ++ descriptorField name ++ "\": \"" ++ value ++ "\"" | (name, value) ← placeholderVulkan]

builder ∷ Registry → String → [String] → IO (ExitCode, String, String)
builder registry command extra =
  run
    (registryEnvironment registry)
    (registryDirectory registry)
    (registryPython registry)
    ( [ registryCheckout registry </> "tools/ci-image/builder.py", command
      , "--image", "ghcr.io/owner/project-ci"
      , "--fingerprint", fingerprintX
      , "--ghc", "9.14.1"
      , "--cabal", "3.18.1.0"
      , "--weston", pinnedCompositor
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
    , "  build) printf '{\"native_manifest\": \"%s\"" ++ builtIdentities ++ "}\\n' \"$(cat \"$state/built-manifest\")\" ;;"
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
  , nativeEnvironment ∷ [(String, String)]
  , nativeRecipe ∷ FilePath
  , nativeInputs ∷ FilePath
  }

-- | One Vulkan input the fixture pins: where the recipe looks for it, and what
-- it holds.
data Input = Input
  { inputPath ∷ FilePath
  , inputContents ∷ String
  }

-- | The Vulkan inputs a fixture prefix is provisioned from.
--
-- Real files with real digests, written into the fixture rather than taken from
-- the machine, so these examples ask the same questions of the recipe on a
-- developer's macOS desktop and on the Linux CI image — neither of which holds
-- the other's loader, driver, layers, or compiler.
fixtureInputs ∷ FilePath → [Input]
fixtureInputs directory =
  [ Input (directory </> "lib/libvulkan.1.4.2.dylib") "a fixture standing in for the loader\n"
  , Input (directory </> "lib/pkgconfig/vulkan.pc") fixtureLoaderPc
  , Input (directory </> "share/vulkan/icd.d/fixture_icd.json") (fixtureIcd directory)
  , Input (directory </> "lib/libFixtureDriver.dylib") "a fixture standing in for the driver\n"
  , Input (directory </> "share/vulkan/explicit_layer.d/VK_LAYER_FIXTURE.json") (fixtureLayer directory)
  , Input (directory </> "lib/libVkLayer_fixture.dylib") "a fixture standing in for the layer\n"
  , Input (directory </> "include/vulkan/vulkan.h") "/* a fixture standing in for the headers */\n"
  ]

fixtureLoaderVersion ∷ String
fixtureLoaderVersion = "1.4.2"

fixtureLayerName ∷ String
fixtureLayerName = "VK_LAYER_FIXTURE"

fixtureGlslangVersion ∷ String
fixtureGlslangVersion = "15.1.0"

fixtureLoaderPc ∷ String
fixtureLoaderPc =
  unlines
    [ "prefix=/fixture"
    , "libdir=${prefix}/lib"
    , "includedir=${prefix}/include"
    , "Name: Vulkan-Loader"
    , "Description: A fixture standing in for the qualified loader"
    , "Version: " ++ fixtureLoaderVersion ++ ".0"
    , "Libs: -L${libdir} -lvulkan"
    ]

fixtureIcd ∷ FilePath → String
fixtureIcd directory =
  unlines
    [ "{"
    , "  \"file_format_version\": \"1.0.0\","
    , "  \"ICD\": {"
    , "    \"library_path\": \"" ++ (directory </> "lib/libFixtureDriver.dylib") ++ "\","
    , "    \"api_version\": \"1.4.2\""
    , "  }"
    , "}"
    ]

fixtureLayer ∷ FilePath → String
fixtureLayer directory =
  unlines
    [ "{"
    , "  \"file_format_version\": \"1.2.0\","
    , "  \"layer\": {"
    , "    \"name\": \"" ++ fixtureLayerName ++ "\","
    , "    \"type\": \"GLOBAL\","
    , "    \"api_version\": \"" ++ fixtureLoaderVersion ++ "\","
    , "    \"implementation_version\": \"1\","
    , "    \"description\": \"A fixture standing in for the validation layer\","
    , "    \"library_path\": \"" ++ (directory </> "lib/libVkLayer_fixture.dylib") ++ "\""
    , "  }"
    , "}"
    ]

-- | The same manifest describing a different driver, for an override that
-- points somewhere the pin does not qualify.
replaceVersion ∷ String → String
replaceVersion line
  | "\"api_version\"" `isInfixOf` line = "    \"api_version\": \"9.9.9\""
  | otherwise = line

-- | A compiler that answers `--version` the way glslang does and compiles
-- nothing, which is all the recipe ever asks of it.
fixtureGlslang ∷ String
fixtureGlslang =
  unlines
    [ "#!/bin/sh"
    , "case \"$1\" in"
    , "  --version) echo 'Glslang Version: 11:" ++ fixtureGlslangVersion ++ "' ;;"
    , "  *) echo 'the fixture compiler compiles nothing' >&2; exit 1 ;;"
    , "esac"
    ]

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
    -- A writable copy of the recipe, whose Vulkan pin names inputs written into
    -- this fixture. The recipe in the checkout pins the machine's own loader,
    -- driver, layers, and compiler, and only one of the two platforms this
    -- suite runs on ever holds a given platform's set; pinning the fixture's
    -- own files is what lets these examples ask the same questions on both.
    let recipe = directory </> "recipe"
        inputs = directory </> "inputs"
        compiler = inputs </> "bin/glslangValidator"
    createDirectoryIfMissing True recipe
    (copied, _, copyErrors) ← run settings here "cp" ["-R", here </> "tools/native/.", recipe]
    (copied, copyErrors) `shouldBe` (ExitSuccess, "")
    forM_ (fixtureInputs inputs) $ \input → writeFileEnsuring (inputPath input) (inputContents input)
    -- The recipe gives a macOS prefix's loader an absolute install name, which
    -- is a real edit to a real Mach-O. Where those tools exist the fixture has
    -- to offer something they can edit, so the stand-in loader is compiled
    -- rather than written; elsewhere the recipe makes no such edit and the
    -- placeholder above is exactly as good.
    when (os == "darwin") $ do
      writeFileEnsuring (inputs </> "loader.c") "int hetoimasia_fixture_loader(void) { return 0; }\n"
      (compiled, _, compileErrors) ←
        run
          settings
          directory
          "cc"
          ["-dynamiclib", "-o", inputs </> "lib/libvulkan.1.4.2.dylib", inputs </> "loader.c"]
      (compiled, compileErrors) `shouldBe` (ExitSuccess, "")
    createDirectoryIfMissing True (takeDirectory compiler)
    executableFile compiler fixtureGlslang
    -- What a Linux identity and a Linux package check ask the machine. Neither
    -- exists on a developer's macOS desktop, and the recipe has to be askable
    -- for either platform from either one.
    writeFile (stubs </> "libc-version") "glibc 2.39\n"
    executableFile (stubs </> "getconf") ("#!/bin/sh\ncat '" ++ stubs </> "libc-version" ++ "'\n")
    executableFile
      (stubs </> "dpkg-query")
      ( unlines
          [ "#!/bin/sh"
          , "for argument in \"$@\"; do package=\"$argument\"; done"
          , "case \"$package\" in"
          , "  fixture-*) echo '1.2.3-4fixture' ;;"
          , "  *) echo \"dpkg-query: no packages found matching $package\" >&2; exit 1 ;;"
          , "esac"
          ]
      )
    pinFixtureInputs interpreter settings directory recipe inputs compiler
    let inherited =
          filter
            ((`notElem` (["CC", "MACOSX_DEPLOYMENT_TARGET", "HETOIMASIA_GLFW_BUILD_TYPE", "PKG_CONFIG_PATH", "HETOIMASIA_NATIVE_PREFIX"] ++ vulkanOverrides ++ ambientBuildVariables)) . fst)
            settings
        path = stubs ++ maybe "" (':' :) (lookup "PATH" inherited)
    action
      ( Native
          directory
          prefix
          (directory </> "dist-newstyle")
          stubs
          interpreter
          (overriding [("PATH", path)] inherited)
          recipe
          inputs
      )

-- | The environment variables that relocate one Vulkan input, cleared from a
-- fixture's inherited environment so a developer's own shell cannot move what
-- an example is describing.
vulkanOverrides ∷ [String]
vulkanOverrides =
  [ "HETOIMASIA_VULKAN_LOADER"
  , "HETOIMASIA_VULKAN_DRIVER_MANIFEST"
  , "HETOIMASIA_VULKAN_LAYER_MANIFEST"
  , "HETOIMASIA_VULKAN_GLSLANG"
  , "HETOIMASIA_VULKAN_PREFIX"
  ]

-- | Rewrite the copied recipe's Vulkan pin to name the fixture's own inputs,
-- each with the digest it actually has.
--
-- The digests are computed rather than written down: the point of the pin is
-- that it names what a file *is*, and a fixture that asserted a digest its own
-- file does not have would be testing the assertion rather than the recipe.
pinFixtureInputs ∷ FilePath → [(String, String)] → FilePath → FilePath → FilePath → FilePath → IO ()
pinFixtureInputs interpreter settings directory recipe inputs compiler = do
  (result, _, errors) ←
    run
      settings
      directory
      interpreter
      [ "-c"
      , unlines
          [ "import hashlib, os, sys"
          , "recipe, inputs, compiler, layer, loader, glslang = sys.argv[1:7]"
          , "digest = lambda path: hashlib.sha256(open(path, 'rb').read()).hexdigest()"
          , "values = {"
          , "  'MACOS_LOADER': os.path.join(inputs, 'lib/libvulkan.1.4.2.dylib'),"
          , "  'MACOS_LOADER_VERSION': loader,"
          , "  'MACOS_LOADER_PC': os.path.join(inputs, 'lib/pkgconfig/vulkan.pc'),"
          , "  'MACOS_INCLUDE': os.path.join(inputs, 'include'),"
          , "  'MACOS_DRIVER_MANIFEST': os.path.join(inputs, 'share/vulkan/icd.d/fixture_icd.json'),"
          , "  'MACOS_DRIVER_NAME': 'fixture',"
          , "  'MACOS_LAYER_MANIFEST': os.path.join(inputs, 'share/vulkan/explicit_layer.d/%s.json' % layer),"
          , "  'MACOS_LAYER_NAME': layer,"
          , "  'MACOS_LAYER_VERSION': loader,"
          , "  'MACOS_GLSLANG': compiler,"
          , "  'MACOS_GLSLANG_VERSION': glslang,"
          , "}"
          , "values['MACOS_LOADER_SHA256'] = digest(values['MACOS_LOADER'])"
          , "values['MACOS_DRIVER_MANIFEST_SHA256'] = digest(values['MACOS_DRIVER_MANIFEST'])"
          , "values['MACOS_DRIVER_LIBRARY_SHA256'] = digest(os.path.join(inputs, 'lib/libFixtureDriver.dylib'))"
          , "values['MACOS_LAYER_MANIFEST_SHA256'] = digest(values['MACOS_LAYER_MANIFEST'])"
          , "values['MACOS_LAYER_LIBRARY_SHA256'] = digest(os.path.join(inputs, 'lib/libVkLayer_fixture.dylib'))"
          , "values['MACOS_GLSLANG_SHA256'] = digest(compiler)"
          , "values['MACOS_LOADER_PC_SHA256'] = digest(values['MACOS_LOADER_PC'])"
          , "# The same inputs under the Linux names, so one fixture recipe can be"
          , "# asked either platform's question. The package entries are fixtures"
          , "# too: dpkg is stubbed, and what matters is that the recipe asks."
          , "linux = {name.replace('MACOS_', 'LINUX_', 1): value for name, value in values.items()}"
          , "linux['LINUX_DRIVER_LIBRARY'] = os.path.join(inputs, 'lib/libFixtureDriver.dylib')"
          , "linux['LINUX_LAYER_LIBRARY'] = os.path.join(inputs, 'lib/libVkLayer_fixture.dylib')"
          , "for role, package in (('LOADER', 'fixture-loader'), ('HEADERS', 'fixture-headers'),"
          , "                      ('DRIVER', 'fixture-driver'), ('LAYER', 'fixture-layer'),"
          , "                      ('GLSLANG', 'fixture-glslang')):"
          , "    linux['LINUX_%s_PACKAGE' % role] = package"
          , "    linux['LINUX_%s_PACKAGE_VERSION' % role] = '1.2.3-4fixture'"
          , "values.update(linux)"
          , "path = os.path.join(recipe, 'vulkan.pin')"
          , "kept = [line for line in open(path, encoding='utf-8').read().splitlines()"
          , "        if not line.startswith(('MACOS_', 'LINUX_'))]"
          , "body = kept + ['%s=%s' % item for item in sorted(values.items())]"
          , "open(path, 'w', encoding='utf-8').write(chr(10).join(body) + chr(10))"
          ]
      , recipe
      , inputs
      , compiler
      , fixtureLayerName
      , fixtureLoaderVersion
      , fixtureGlslangVersion
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

writeFileEnsuring ∷ FilePath → String → IO ()
writeFileEnsuring path contents = do
  createDirectoryIfMissing True (takeDirectory path)
  writeFile path contents

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
nativeTool = nativeToolOn "Darwin"

-- | Drive the fixture recipe for one platform's identity.
--
-- The fixture pins the same files under both platforms' names, so the Linux
-- question can be asked on a macOS desktop and the macOS one on a Linux CI
-- worker. Without that, whichever platform a suite happened to run on would be
-- the only one whose refusals were ever exercised.
nativeToolOn ∷ String → Native → [(String, String)] → [String] → IO (ExitCode, String, String)
nativeToolOn target native overrides arguments =
  run
    (overriding overrides (nativeEnvironment native))
    (nativeDirectory native)
    (nativePython native)
    ((nativeRecipe native </> "native.py") : "--platform" : target : arguments)

nativeOk ∷ Native → [(String, String)] → [String] → IO ()
nativeOk native overrides arguments = do
  (result, _, errors) ← nativeTool native overrides arguments
  (result, errors) `shouldBe` (ExitSuccess, "")

-- | One Vulkan input an example replaces while leaving the manifest alone.
data Substitution = Substitution
  { substitutionLabel ∷ String
  , substitutionNamed ∷ String
  , substitutionPath ∷ Native → FilePath
  }

-- | Each half of each input, on both sides of the prefix boundary.
--
-- A manifest and the binary it names are two inputs, and so are a wrapper and
-- the compiler it runs; replacing the half that is not hashed is exactly how a
-- substitution would otherwise go unnoticed. The sources outside the prefix are
-- held to the pin, the products inside it to the record, and both have to
-- refuse.
substitutions ∷ [Substitution]
substitutions =
  [ Substitution "loader" "the Vulkan loader at" (\native → nativePrefix native </> "vulkan/lib/libvulkan.1.dylib")
  , Substitution "package description" "the loader's package description at" (\native → nativePrefix native </> "vulkan/lib/pkgconfig/vulkan.pc")
  , Substitution "driver manifest" "the driver manifest at" (\native → nativePrefix native </> "vulkan/share/vulkan/icd.d/fixture_icd.json")
  , Substitution "wrapper" "the glslangValidator wrapper at" (\native → nativePrefix native </> "vulkan/bin/glslangValidator")
  , Substitution "layer manifest" ("the " ++ fixtureLayerName ++ " manifest at") (\native → nativePrefix native </> ("vulkan/share/vulkan/explicit_layer.d/" ++ fixtureLayerName ++ ".json"))
  , Substitution "source loader" "no longer qualifies under vulkan.pin" (\native → nativeInputs native </> "lib/libvulkan.1.4.2.dylib")
  , Substitution "driver library" "no longer qualifies under vulkan.pin" (\native → nativeInputs native </> "lib/libFixtureDriver.dylib")
  , Substitution "layer library" "no longer qualifies under vulkan.pin" (\native → nativeInputs native </> "lib/libVkLayer_fixture.dylib")
  , Substitution "glslang compiler" "no longer qualifies under vulkan.pin" (\native → nativeInputs native </> "bin/glslangValidator")
  , Substitution "headers" "the Vulkan headers at" (\native → nativePrefix native </> "vulkan/include/vulkan/vulkan.h")
  , Substitution "source headers" "the recorded header digest" (\native → nativeInputs native </> "include/vulkan/vulkan.h")
  ]

-- | The ways the loader's linker-facing link can stop doing its job.
--
-- Each one leaves the recorded loader itself untouched and every digest in the
-- manifest correct, which is what makes them the cases a content check alone
-- cannot see.
loaderLinkDamage ∷ [(String, FilePath → IO (), String)]
loaderLinkDamage =
  [ ("deleted", removeFile, "linker-facing link is missing")
  , ( "pointed at another library"
    , \link → removeFile link >> createFileLink "libSomethingElse.dylib" link
    , "points at"
    )
  , ( "replaced by a file of its own"
    , \link → do
        target ← canonicalizePath link
        removeFile link
        copyFile target link
    , "linker-facing link is missing"
    )
  ]

-- | Replace a file's bytes while leaving everything that described it alone.
--
-- Written as bytes rather than as text: some of these inputs are real Mach-O
-- libraries, and reading one as a string would fail on this machine's own
-- encoding rather than on anything the recipe does.
substitute ∷ Native → FilePath → IO ()
substitute _ path = withBinaryFile path AppendMode (\handle → hPutStr handle "a substituted byte\n")

-- | The Vulkan toolchain entries the fixture prefix yields.
nativeIdentities ∷ Native → IO [(String, String)]
nativeIdentities native = do
  (result, output, errors) ← nativeTool native [] ["toolchain", "--prefix", nativePrefix native]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure [(name, drop 1 value) | line ← lines output, let (name, value) = break (== '=') line, name /= "native-manifest"]

-- | Edit the recorded manifest in place, for an example describing a record
-- that no longer says what the recipe would write.
patchManifest ∷ Native → String → IO ()
patchManifest native expression = do
  (result, _, errors) ←
    run
      (nativeEnvironment native)
      (nativeDirectory native)
      (nativePython native)
      [ "-c"
      , unlines
          [ "import json, sys"
          , "path = sys.argv[1]"
          , "document = json.load(open(path, encoding='utf-8'))"
          , "document" ++ expression
          , "json.dump(document, open(path, 'w', encoding='utf-8'))"
          ]
      , nativePrefix native </> "hetoimasia-native-manifest.json"
      ]
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
