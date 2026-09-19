-- | Hspec coverage for the validation planner.
--
-- Every example runs @tools/validation/plan.py@ itself against a temporary Git
-- repository and a fixture catalog, so the assertions describe the planner's
-- real selection behaviour rather than a reimplementation of it.
module Validation (spec) where

import Control.Monad (void)
import Data.List (isInfixOf)
import Json (asArray, asBool, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory, removeFile, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (WriteMode), hClose, hPutStr, hSetEncoding, latin1, openFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldSatisfy)

data Fixture = Fixture
  { root ∷ FilePath
  , planner ∷ FilePath
  , environment ∷ [(String, String)]
  , seeded ∷ String
  , initial ∷ String
  }

-- | Selection facts for one catalog group: its reason, whether it was selected,
-- and whether its own inputs changed.
data Selection = Selection String Bool Bool
  deriving (Eq, Show)

spec ∷ Spec
spec = describe "Validation planner" $ do
  describe "input derivation" $ do
    it "selects a consumer through a transitive local library dependency" $
      withFixture $ \fixture → do
        change fixture "packages/alpha/src/Alpha.hs" "module Alpha (alpha) where\nalpha :: Int\nalpha = 2\n"
        plan ← planJson fixture []
        selectionOf plan "test.demo" `shouldBe` Just (Selection "affected" True True)
        selectionOf plan "test.harness" `shouldBe` Just (Selection "unaffected" False False)

    it "follows a sublibrary dependency to that library's own sources" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "packages/alpha/extra/Extra.hs" (extraModule 1)
        change fixture "packages/alpha/alpha.cabal" (alphaPackage ++ extraLibrary)
        change fixture "demo.cabal" sublibraryDemoPackage
        base ← revision fixture "HEAD"
        change fixture "packages/alpha/extra/Extra.hs" (extraModule 2)
        plan ← planJsonAt fixture base []
        selectionOf plan "test.harness" `shouldBe` Just (Selection "affected" True True)
        selectionOf plan "test.demo" `shouldBe` Just (Selection "unaffected" False False)

    it "accepts an operating-system conditional that declares only link fields" $
      withFixture $ \fixture → do
        change fixture "packages/alpha/alpha.cabal" (alphaPackage ++ linkConditionals)
        plan ← planJson fixture []
        selectionOf plan "test.demo" `shouldBe` Just (Selection "affected" True True)

    it "rejects an operating-system conditional that declares anything but link or buildability fields" $
      withFixture $ \fixture → do
        change fixture "packages/alpha/alpha.cabal"
          (alphaPackage ++ unlines ["    if os(linux)", "        build-depends: containers"])
        (result, _, errors) ← planRaw fixture (seeded fixture) []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "may declare only buildable, extra-libraries, frameworks"

    it "accepts an operating-system conditional that decides whether a component is built" $
      withFixture $ \fixture → do
        change fixture "packages/alpha/alpha.cabal" (alphaPackage ++ platformOnlyLibrary)
        change fixture "demo.cabal" platformOnlyDemoPackage
        base ← revision fixture "HEAD"
        writeFixtureFile (root fixture) "packages/alpha/platform/Platform.hs" (platformModule 1)
        change fixture "packages/alpha/platform/Platform.hs" (platformModule 2)
        plan ← planJsonAt fixture base []
        -- A component that this platform does not build still has its sources
        -- counted, so the group that owns it is reported as affected wherever
        -- the plan is taken. Silently dropping them would make a Darwin-only
        -- probe look identical to a tree that never touched it.
        selectionOf plan "test.harness" `shouldBe` Just (Selection "affected" True True)

    it "rejects a conditional on anything but the operating system" $
      withFixture $ \fixture → do
        change fixture "packages/alpha/alpha.cabal"
          (alphaPackage ++ unlines ["    if flag(fast)", "        extra-libraries: m"])
        (result, _, errors) ← planRaw fixture (seeded fixture) []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "conditional or brace-delimited Cabal syntax is not supported"

    it "selects a test suite through its executable build-tool dependency" $
      withFixture $ \fixture → do
        change fixture "app/Main.hs" "module Main (main) where\nmain :: IO ()\nmain = putStrLn \"revised\"\n"
        plan ← planJson fixture []
        selectionOf plan "test.demo" `shouldBe` Just (Selection "affected" True True)
        selectionOf plan "test.harness" `shouldBe` Just (Selection "unaffected" False False)

    it "treats a build configuration change as affecting every Cabal consumer" $
      withFixture $ \fixture → do
        change fixture "cabal.project" (projectFile ++ "optimization: 1\n")
        plan ← planJson fixture []
        selectionOf plan "test.demo" `shouldBe` Just (Selection "affected" True True)
        selectionOf plan "test.harness" `shouldBe` Just (Selection "affected" True True)
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "optional-unrequested" False False)

    it "counts both endpoints of a rename as changed inputs" $
      withFixture $ \fixture → do
        renameFile (root fixture </> "packages/alpha/src/Alpha.hs") (root fixture </> "packages/alpha/src/Beta.hs")
        commit fixture "rename the library module"
        plan ← planJson fixture []
        classificationOf plan "packages/alpha/src/Alpha.hs" `shouldBe` Just "consumed"
        classificationOf plan "packages/alpha/src/Beta.hs" `shouldBe` Just "consumed"
        selectionOf plan "test.demo" `shouldBe` Just (Selection "affected" True True)

    it "counts a deleted source file as a changed input of its group" $
      withFixture $ \fixture → do
        removeFile (root fixture </> "test/Main.hs")
        commit fixture "drop the suite entry point"
        plan ← planJson fixture []
        classificationOf plan "test/Main.hs" `shouldBe` Just "consumed"
        selectionOf plan "test.demo" `shouldBe` Just (Selection "affected" True True)

    it "derives inputs from the base revision when the head no longer declares them" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "cabal.project" "packages:\n  .\n"
        void $ git (environment fixture) (root fixture) ["rm", "-r", "-q", "packages"]
        commit fixture "retire the local library"
        plan ← planJson fixture []
        classificationOf plan "packages/alpha/src/Alpha.hs" `shouldBe` Just "consumed"

  describe "path classification" $ do
    it "selects only the floor for a documentation-only change" $
      withFixture $ \fixture → do
        change fixture "docs/prose.md" "revised prose\n"
        plan ← planJson fixture []
        classificationOf plan "docs/prose.md" `shouldBe` Just "non-affecting"
        selectionOf plan "build.all" `shouldBe` Just (Selection "floor" True False)
        selectionOf plan "test.demo" `shouldBe` Just (Selection "unaffected" False False)
        selectionOf plan "test.harness" `shouldBe` Just (Selection "unaffected" False False)
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "optional-unrequested" False False)

    it "lets an explicitly consumed Markdown input outrank its prose class" $
      withFixture $ \fixture → do
        change fixture "docs/consumed.md" "revised fixture document\n"
        plan ← planJson fixture []
        classificationOf plan "docs/consumed.md" `shouldBe` Just "consumed"
        selectionOf plan "test.harness" `shouldBe` Just (Selection "affected" True True)
        selectionOf plan "test.demo" `shouldBe` Just (Selection "unaffected" False False)

    it "widens non-optional coverage for an unknown input and reports the path" $
      withFixture $ \fixture → do
        change fixture "assets/table.bin" "0\n"
        plan ← planJson fixture []
        unknownInputs plan `shouldBe` Just ["assets/table.bin"]
        selectionOf plan "build.all" `shouldBe` Just (Selection "floor" True True)
        selectionOf plan "test.demo" `shouldBe` Just (Selection "unknown-input" True True)
        selectionOf plan "test.harness" `shouldBe` Just (Selection "unknown-input" True True)

    it "keeps an optional group unselected under unknown-input fallback" $
      withFixture $ \fixture → do
        change fixture "assets/table.bin" "0\n"
        plan ← planJson fixture []
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "optional-unrequested" False False)

    it "keeps an optional group unselected when a shared harness input changes" $
      withFixture $ \fixture → do
        change fixture "tools/shared.sh" "#!/bin/sh\necho revised\n"
        plan ← planJson fixture []
        selectionOf plan "test.harness" `shouldBe` Just (Selection "affected" True True)
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "optional-unrequested" False True)

  describe "definition changes" $ do
    it "marks an optional group's inputs changed when its own definition changes" $
      withFixture $ \fixture → do
        change fixture "tools/validation/catalog.json" revisedOptionalCatalog
        plan ← planJson fixture []
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "optional-unrequested" False True)

    it "keeps an explicitly requested group's changed definition visible" $
      withFixture $ \fixture → do
        change fixture "tools/validation/catalog.json" revisedOptionalCatalog
        writeFixtureFile (root fixture) "request.md" (requestBlock ["probe.slow"])
        plan ← planJson fixture ["--request-file", root fixture </> "request.md"]
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "requested" True True)

    it "counts an input a group declared at the base but no longer declares" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "tools/validation/catalog.json" retiredInputCatalog
        writeFixtureFile (root fixture) "docs/consumed.md" "revised fixture document\n"
        commit fixture "retire a declared input and change it"
        plan ← planJson fixture []
        classificationOf plan "docs/consumed.md" `shouldBe` Just "consumed"
        selectionOf plan "test.harness" `shouldBe` Just (Selection "affected" True True)

  describe "requests" $ do
    it "adds a requested group without removing floor coverage or inventing changed inputs" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "request.md" (requestBlock ["test.harness"])
        plan ← planJsonAt fixture (seeded fixture) ["--request-file", root fixture </> "request.md"]
        selectionOf plan "build.all" `shouldBe` Just (Selection "floor" True False)
        selectionOf plan "test.harness" `shouldBe` Just (Selection "requested" True False)
        selectionOf plan "test.demo" `shouldBe` Just (Selection "unaffected" False False)

    it "runs an optional group only when it is explicitly requested" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "request.md" (requestBlock ["probe.slow"])
        plan ← planJsonAt fixture (seeded fixture) ["--request-file", root fixture </> "request.md"]
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "requested" True False)

    it "selects every Hspec group including optional ones for an all-hspec request" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "request.md" (requestBlock ["all-hspec"])
        plan ← planJsonAt fixture (seeded fixture) ["--request-file", root fixture </> "request.md"]
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "requested" True False)
        selectionOf plan "test.demo" `shouldBe` Just (Selection "requested" True False)
        selectionOf plan "test.harness" `shouldBe` Just (Selection "requested" True False)
        selectionOf plan "build.all" `shouldBe` Just (Selection "floor" True False)

    it "rejects an unknown requested group" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "request.md" (requestBlock ["test.absent"])
        (result, _, errors) ← planRaw fixture (seeded fixture) ["--request-file", root fixture </> "request.md"]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "test.absent"

    it "rejects a malformed request block" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "request.md" "```validation-request\ntest.demo\n"
        (result, _, errors) ← planRaw fixture (seeded fixture) ["--request-file", root fixture </> "request.md"]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "never closed"

    it "rejects a malformed validation-request info string" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "request.md" "```validation-request please\nprobe.slow\n```\n"
        (result, _, errors) ← planRaw fixture (seeded fixture) ["--request-file", root fixture </> "request.md"]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "malformed validation-request info string"

    it "ignores a validation-request example nested inside an outer fence" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "request.md" nestedExample
        plan ← planJsonAt fixture (seeded fixture) ["--request-file", root fixture </> "request.md"]
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "optional-unrequested" False False)

    it "reads a real request that follows a documentation example" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "request.md" (nestedExample ++ requestBlock ["test.harness"])
        plan ← planJsonAt fixture (seeded fixture) ["--request-file", root fixture </> "request.md"]
        selectionOf plan "test.harness" `shouldBe` Just (Selection "requested" True False)
        selectionOf plan "probe.slow" `shouldBe` Just (Selection "optional-unrequested" False False)

    it "rejects an all-hspec request that matches no Hspec group" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "fixtures/no-hspec.json" noHspecCatalog
        writeFixtureFile (root fixture) "request.md" (requestBlock ["all-hspec"])
        (result, _, errors) ← planRaw fixture (seeded fixture)
          [ "--catalog", root fixture </> "fixtures/no-hspec.json"
          , "--request-file", root fixture </> "request.md"
          ]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "all-hspec"

  describe "catalog validation" $ do
    it "accepts the fixture catalog through --catalog-check" $
      withFixture $ \fixture → do
        (result, output, _) ← planner' fixture ["--catalog-check"]
        result `shouldBe` ExitSuccess
        output `shouldContain` "is valid"

    it "names a group that is missing its optional classification" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "fixtures/missing-optional.json" missingOptionalCatalog
        (result, _, errors) ← planner' fixture
          ["--catalog-check", "--catalog", root fixture </> "fixtures/missing-optional.json"]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "'probe.slow'"
        errors `shouldContain` "'optional'"

    it "rejects a duplicate group id and an unresolvable component" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "fixtures/broken.json" brokenCatalog
        (result, _, errors) ← planner' fixture
          ["--catalog-check", "--catalog", root fixture </> "fixtures/broken.json"]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "duplicates an earlier group id"
        errors `shouldContain` "does not exist in the local package graph"

    it "validates the catalog before planning" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "fixtures/missing-optional.json" missingOptionalCatalog
        (result, _, errors) ← planRaw fixture (seeded fixture)
          ["--catalog", root fixture </> "fixtures/missing-optional.json"]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "'probe.slow'"

    it "reports a head revision that carries no catalog" $
      withFixture $ \fixture → do
        (result, _, errors) ← planRawBetween fixture (initial fixture) (initial fixture) []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "tools/validation/catalog.json does not exist"

    it "refuses a catalog that is not valid UTF-8 instead of repairing it" $
      withFixture $ \fixture → do
        writeLatin1 (root fixture </> "fixtures/invalid.json") "{\"schema_version\": 1, \"\xff\": 1}\n"
        (result, _, errors) ← planner' fixture
          ["--catalog-check", "--catalog", root fixture </> "fixtures/invalid.json"]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "is not valid UTF-8"

    it "refuses package metadata that is not valid UTF-8 while planning" $
      withFixture $ \fixture → do
        writeLatin1 (root fixture </> "packages/alpha/alpha.cabal") (alphaPackage ++ "-- \xff\n")
        commit fixture "corrupt the package description"
        (result, _, errors) ← planRaw fixture (seeded fixture) []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "is not valid UTF-8"

  describe "revisions" $ do
    it "plans against a base revision that predates the catalog and the package graph" $
      withFixture $ \fixture → do
        (result, output, _) ← planRawBetween fixture (initial fixture) (seeded fixture) ["--json"]
        result `shouldBe` ExitSuccess
        (parseJson output >>= field "base_package_metadata" >>= asString) `shouldBe` Just "absent"

    it "reports an unresolvable revision instead of an unchanged-input plan" $
      withFixture $ \fixture → do
        (result, _, errors) ← planRawBetween fixture "refs/heads/absent" (seeded fixture) []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "refs/heads/absent"

  describe "explanations" $
    it "explains every group in the default prose output" $
      withFixture $ \fixture → do
        change fixture "docs/prose.md" "revised prose\n"
        (result, output, _) ← planRaw fixture (seeded fixture) []
        result `shouldBe` ExitSuccess
        output `shouldContain` "build.all"
        output `shouldContain` "optional-unrequested"
        output `shouldSatisfy` isInfixOf "explained omission"

-- ---------------------------------------------------------------------------
-- Running the planner

planner' ∷ Fixture → [String] → IO (ExitCode, String, String)
planner' fixture args =
  run (environment fixture) (root fixture) "python3"
    (planner fixture : "--repo-root" : root fixture : args)

planRawBetween ∷ Fixture → String → String → [String] → IO (ExitCode, String, String)
planRawBetween fixture base head' args =
  planner' fixture (["--base", base, "--head", head'] ++ args)

planRaw ∷ Fixture → String → [String] → IO (ExitCode, String, String)
planRaw fixture base args = planRawBetween fixture base "HEAD" args

planJsonAt ∷ Fixture → String → [String] → IO String
planJsonAt fixture base args = do
  (result, output, errors) ← planRaw fixture base (args ++ ["--json"])
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure output

planJson ∷ Fixture → [String] → IO String
planJson fixture args = planJsonAt fixture (seeded fixture) args

-- ---------------------------------------------------------------------------
-- Reading a plan

selectionOf ∷ String → String → Maybe Selection
selectionOf output identifier = do
  document ← parseJson output
  entry ← field "groups" document >>= entryFor "id" identifier
  reason ← field "reason" entry >>= asString
  selected ← field "selected" entry >>= asBool
  changed ← field "inputs_changed" entry >>= asBool
  pure (Selection reason selected changed)

classificationOf ∷ String → String → Maybe String
classificationOf output path = do
  document ← parseJson output
  entry ← field "changed_paths" document >>= entryFor "path" path
  field "classification" entry >>= asString

unknownInputs ∷ String → Maybe [String]
unknownInputs output = do
  document ← parseJson output
  elements ← field "unknown_inputs" document >>= asArray
  traverse asString elements

-- ---------------------------------------------------------------------------
-- The fixture repository

withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-validation" $ \directory → do
    let fixture = Fixture directory (checkout </> "tools/validation/plan.py") settings "" ""
    void $ git settings directory ["init", "-b", "master"]
    writeFixtureFile directory "README.md" "fixture\n"
    void $ git settings directory ["add", "."]
    void $ git settings directory ["commit", "-q", "-m", "Seed a project without validation"]
    firstCommit ← revision fixture "HEAD"
    mapM_ (uncurry (writeFixtureFile directory)) fixtureFiles
    void $ git settings directory ["add", "."]
    void $ git settings directory ["commit", "-q", "-m", "Seed the fixture project"]
    secondCommit ← revision fixture "HEAD"
    action fixture {seeded = secondCommit, initial = firstCommit}

revision ∷ Fixture → String → IO String
revision fixture name =
  takeWhile (/= '\n') <$> git (environment fixture) (root fixture) ["rev-parse", name]

-- | Write a file and commit it, so the change is visible to the planner.
change ∷ Fixture → FilePath → String → IO ()
change fixture path contents = do
  writeFixtureFile (root fixture) path contents
  commit fixture ("Change " ++ path)

commit ∷ Fixture → String → IO ()
commit fixture message = do
  void $ git (environment fixture) (root fixture) ["add", "-A", "."]
  void $ git (environment fixture) (root fixture) ["commit", "-q", "-m", message]

requestBlock ∷ [String] → String
requestBlock entries =
  unlines (["Some pull request prose.", "", "```validation-request"] ++ entries ++ ["```", "", "Closing prose."])

-- | Write a file through a byte-preserving encoding, so a fixture can hold the
-- invalid UTF-8 a diagnostic is expected to reject.
writeLatin1 ∷ FilePath → String → IO ()
writeLatin1 path contents = do
  createDirectoryIfMissing True (takeDirectory path)
  handle ← openFile path WriteMode
  hSetEncoding handle latin1
  hPutStr handle contents
  hClose handle

nestedExample ∷ String
nestedExample =
  unlines
    [ "Documented like this:"
    , ""
    , "````markdown"
    , "```validation-request"
    , "probe.slow"
    , "```"
    , "````"
    , ""
    ]

fixtureFiles ∷ [(FilePath, String)]
fixtureFiles =
  [ ("cabal.project", projectFile)
  , ("demo.cabal", demoPackage)
  , ("packages/alpha/alpha.cabal", alphaPackage)
  , ("packages/alpha/src/Alpha.hs", "module Alpha (alpha) where\nalpha :: Int\nalpha = 1\n")
  , ("app/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("test/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("tools/test/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("tools/shared.sh", "#!/bin/sh\necho shared\n")
  , ("docs/consumed.md", "a document the harness suite reads\n")
  , ("docs/prose.md", "ordinary prose\n")
  , ("tools/validation/catalog.json", fixtureCatalog)
  ]

projectFile ∷ String
projectFile = "packages:\n  .\n  packages/alpha\n\n"

demoPackage ∷ String
demoPackage =
  unlines
    [ "cabal-version: 3.16"
    , "name: demo"
    , "version: 0.1.0.0"
    , "synopsis: Fixture package"
    , "description:"
    , "    A fixture description spanning several lines so the planner's"
    , "    multiline field handling is exercised."
    , "build-type: Simple"
    , ""
    , "common language"
    , "    default-language: GHC2024"
    , "    ghc-options: -Wall"
    , ""
    , "executable demo"
    , "    import: language"
    , "    main-is: Main.hs"
    , "    hs-source-dirs: app"
    , "    build-depends:"
    , "        base,"
    , "        alpha"
    , ""
    , "test-suite demo-tests"
    , "    import: language"
    , "    type: exitcode-stdio-1.0"
    , "    main-is: Main.hs"
    , "    hs-source-dirs: test"
    , "    build-tool-depends: demo:demo"
    , "    build-depends:"
    , "        base,"
    , "        alpha"
    , ""
    , "test-suite harness-tests"
    , "    import: language"
    , "    type: exitcode-stdio-1.0"
    , "    main-is: Main.hs"
    , "    hs-source-dirs: tools/test"
    , "    build-depends:"
    , "        base"
    ]

alphaPackage ∷ String
alphaPackage =
  unlines
    [ "cabal-version: 3.16"
    , "name: alpha"
    , "version: 0.1.0.0"
    , "synopsis: Fixture library"
    , "build-type: Simple"
    , ""
    , "library"
    , "    exposed-modules: Alpha"
    , "    hs-source-dirs: src"
    , "    default-language: GHC2024"
    , "    build-depends: base"
    ]

-- | A public sublibrary of the fixture library with a source directory of its own.
extraLibrary ∷ String
extraLibrary =
  unlines
    [ ""
    , "library extra"
    , "    visibility: public"
    , "    exposed-modules: Extra"
    , "    hs-source-dirs: extra"
    , "    default-language: GHC2024"
    , "    build-depends: base"
    ]

extraModule ∷ Int → String
extraModule value = "module Extra (extra) where\nextra :: Int\nextra = " ++ show value ++ "\n"

-- | The fixture package with the harness suite depending on the sublibrary
-- alone, so only that suite consumes the sublibrary's sources.
sublibraryDemoPackage ∷ String
sublibraryDemoPackage = unlines (init (lines demoPackage) ++ ["        base,", "        alpha:extra"])

-- | Link declarations inside operating-system conditionals, including an
-- @else@ block and a multiline field.
linkConditionals ∷ String
linkConditionals =
  unlines
    [ "    if os(darwin)"
    , "        frameworks: Cocoa"
    , "    else"
    , "        extra-libraries:"
    , "            rt"
    , "            m"
    ]

-- | A library stanza that is built on one operating system and not on another.
--
-- The planner reads it for its inputs either way; @buildable@ decides what a
-- compiler does, not what a change touches.
platformOnlyLibrary ∷ String
platformOnlyLibrary =
  unlines
    [ ""
    , "library platform"
    , "    visibility: public"
    , "    exposed-modules: Platform"
    , "    hs-source-dirs: platform"
    , "    default-language: GHC2024"
    , "    build-depends: base"
    , "    if os(darwin)"
    , "        buildable: True"
    , "    else"
    , "        buildable: False"
    ]

platformModule ∷ Int → String
platformModule value =
  "module Platform (platform) where\nplatform :: Int\nplatform = " ++ show value ++ "\n"

-- | The fixture package with the harness suite depending on the platform-only
-- sublibrary, so only that suite consumes its sources.
platformOnlyDemoPackage ∷ String
platformOnlyDemoPackage =
  unlines (init (lines demoPackage) ++ ["        base,", "        alpha:platform"])

fixtureCatalog ∷ String
fixtureCatalog =
  catalogDocument
    [ "    \"build.all\"" ]
    [ groupDocument "build.all" "\"all\"" [] "none" "build" False
    , groupDocument "test.demo" "\"demo:test:demo-tests\"" [] "hspec" "test" False
    , groupDocument "test.harness" "\"demo:test:harness-tests\"" ["tools/shared.sh", "docs/consumed.md"] "hspec" "test" False
    , groupDocument "probe.slow" "null" ["tools/shared.sh", "probe/"] "hspec" "probe" True
    ]

-- | The fixture catalog with the optional group's command redefined.
revisedOptionalCatalog ∷ String
revisedOptionalCatalog =
  catalogDocument
    ["    \"build.all\""]
    [ groupDocument "build.all" "\"all\"" [] "none" "build" False
    , groupDocument "test.demo" "\"demo:test:demo-tests\"" [] "hspec" "test" False
    , groupDocument "test.harness" "\"demo:test:harness-tests\"" ["tools/shared.sh", "docs/consumed.md"] "hspec" "test" False
    , groupDocument "probe.slow" "null" ["tools/shared.sh", "probe/", "probe/extra/"] "hspec" "probe" True
    ]

-- | The fixture catalog with a declared input retired from @test.harness@.
retiredInputCatalog ∷ String
retiredInputCatalog =
  catalogDocument
    ["    \"build.all\""]
    [ groupDocument "build.all" "\"all\"" [] "none" "build" False
    , groupDocument "test.demo" "\"demo:test:demo-tests\"" [] "hspec" "test" False
    , groupDocument "test.harness" "\"demo:test:harness-tests\"" ["tools/shared.sh"] "hspec" "test" False
    , groupDocument "probe.slow" "null" ["tools/shared.sh", "probe/"] "hspec" "probe" True
    ]

noHspecCatalog ∷ String
noHspecCatalog =
  catalogDocument
    [ "    \"build.all\"" ]
    [ groupDocument "build.all" "\"all\"" [] "none" "build" False ]

missingOptionalCatalog ∷ String
missingOptionalCatalog =
  catalogDocument
    [ "    \"build.all\"" ]
    [ groupDocument "build.all" "\"all\"" [] "none" "build" False
    , unlines
        [ "    {"
        , "      \"id\": \"probe.slow\","
        , "      \"description\": \"A group with no optional classification.\","
        , "      \"command\": [\"true\"],"
        , "      \"component\": null,"
        , "      \"inputs\": [],"
        , "      \"framework\": \"hspec\","
        , "      \"runner\": \"cpu\","
        , "      \"timeout_seconds\": 60,"
        , "      \"category\": \"probe\""
        , "    }"
        ]
    ]

brokenCatalog ∷ String
brokenCatalog =
  catalogDocument
    [ "    \"build.all\"" ]
    [ groupDocument "build.all" "\"all\"" [] "none" "build" False
    , groupDocument "test.demo" "\"demo:test:demo-tests\"" [] "hspec" "test" False
    , groupDocument "test.demo" "\"demo:test:absent-tests\"" [] "hspec" "test" False
    ]

catalogDocument ∷ [String] → [String] → String
catalogDocument floorEntries groups =
  unlines
    ( [ "{"
      , "  \"schema_version\": 1,"
      , "  \"policy_version\": 1,"
      , "  \"policy_inputs\": [\"tools/validation/catalog.json\"],"
      , "  \"non_affecting_paths\": [\"*.md\", \".gitignore\", \"LICENSE\"],"
      , "  \"floor\": ["
      ]
        ++ commaSeparated floorEntries
        ++ [ "  ],"
           , "  \"groups\": ["
           ]
        ++ commaSeparated (map trimTrailingNewline groups)
        ++ [ "  ]"
           , "}"
           ]
    )

groupDocument ∷ String → String → [String] → String → String → Bool → String
groupDocument identifier component inputs framework category optional =
  unlines
    [ "    {"
    , "      \"id\": \"" ++ identifier ++ "\","
    , "      \"description\": \"Fixture group " ++ identifier ++ ".\","
    , "      \"command\": [\"true\", \"" ++ identifier ++ "\"],"
    , "      \"component\": " ++ component ++ ","
    , "      \"inputs\": [" ++ jsonStrings inputs ++ "],"
    , "      \"framework\": \"" ++ framework ++ "\","
    , "      \"runner\": \"cpu\","
    , "      \"timeout_seconds\": 60,"
    , "      \"category\": \"" ++ category ++ "\","
    , "      \"optional\": " ++ (if optional then "true" else "false")
    , "    }"
    ]

jsonStrings ∷ [String] → String
jsonStrings entries = intercalate ", " (map (\entry → "\"" ++ entry ++ "\"") entries)

intercalate ∷ String → [String] → String
intercalate _ [] = ""
intercalate _ [single] = single
intercalate separator (element : rest) = element ++ separator ++ intercalate separator rest

commaSeparated ∷ [String] → [String]
commaSeparated [] = []
commaSeparated [single] = [single]
commaSeparated (element : rest) = (element ++ ",") : commaSeparated rest

trimTrailingNewline ∷ String → String
trimTrailingNewline = reverse . dropWhile (== '\n') . reverse
