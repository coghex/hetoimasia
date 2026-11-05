-- | Hspec coverage for the guard against new unowned thread and process starts in test sources (#584).
--
-- @tools/validation/owned_starts.py@ finds every call to a start primitive in the repository's test sources and fails one
-- that is neither made through the shared facility, nor in the checked-in per-file baseline, nor in a named exempt helper.
-- Every example runs the guard itself against a temporary tree, so the assertions describe what ships. The fixtures are small
-- package descriptions and sources; the three named sites of the issue are reproduced from the code they were found in.
--
-- The last group runs the guard on this repository: the tree passes, the baseline has not grown relative to the review base,
-- the three named sites are no longer in it, and (the planner coverage) every directory and package description the guard
-- scans is an input of the group that runs it, so a change anywhere it scans selects it.
module OwnedStarts (spec) where

import Control.Monad (forM_, void)
import Data.List (isPrefixOf, isSuffixOf)
import Json (Json (..), asArray, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, workflowStepBody, writeFixtureFile)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, getCurrentDirectory, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)

-- | The guard's own configuration for a fixture: the real primitives, optional components and exemptions.
config ∷ String → String → String → String
config testOnly excluded exempt =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"primitives\": [\"forkIO\", \"forkOS\", \"forkOn\", \"forkIOWithUnmask\", \"forkFinally\", \"createProcess\", \"createProcess_\", \"withCreateProcess\", \"spawnProcess\", \"spawnCommand\", \"callProcess\", \"callCommand\", \"readProcess\", \"readProcessWithExitCode\", \"readCreateProcess\", \"readCreateProcessWithExitCode\"],"
    , "  \"test_only_components\": [" <> testOnly <> "],"
    , "  \"excluded_components\": [" <> excluded <> "],"
    , "  \"exempt\": [" <> exempt <> "]"
    , "}"
    ]

plainConfig ∷ String
plainConfig = config "" "" ""

-- | A baseline: a file and its count each.
baseline ∷ [(FilePath, Int)] → String
baseline entries =
  "{\"schema_version\": 1, \"files\": {" <> concatMap' ", " [show path <> ": " <> show count | (path, count) ← entries] <> "}}\n"
  where
    concatMap' separator = foldr1' separator
    foldr1' _ [] = ""
    foldr1' _ [only] = only
    foldr1' separator (first : rest) = first <> separator <> foldr1' separator rest

-- | The package every fixture has: one package, one test suite whose sources are in @pkg/test@.
packageDescription ∷ String
packageDescription =
  unlines
    [ "cabal-version: 3.0"
    , "name: pkg"
    , "version: 0.1.0.0"
    , "build-type: Simple"
    , ""
    , "test-suite spec"
    , "    type: exitcode-stdio-1.0"
    , "    main-is: Main.hs"
    , "    hs-source-dirs: test"
    , "    default-language: GHC2024"
    , "    build-depends: base"
    ]

-- | A fixture tree: the project, one package, the guard's configuration and baseline, and the given sources.
tree ∷ String → [(FilePath, Int)] → [(FilePath, String)] → [(FilePath, String)]
tree configuration entries sources =
  [ ("cabal.project", "packages:\n  pkg\n")
  , ("pkg/pkg.cabal", packageDescription)
  , ("tools/validation/owned_starts.json", configuration)
  , ("tools/validation/owned_starts_baseline.json", baseline entries)
  ]
    <> sources

source ∷ [String] → String
source body = unlines (["module Main (main) where", ""] <> body)

withTree ∷ [(FilePath, String)] → (FilePath → IO a) → IO a
withTree files action = withSystemTempDirectory "hetoimasia-owned-starts" $ \directory → do
  forM_ files $ uncurry (writeFixtureFile directory)
  action directory

-- | Run the guard against a fixture tree.
guard' ∷ FilePath → [String] → IO (ExitCode, String, String)
guard' directory arguments = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  run (("PYTHONDONTWRITEBYTECODE", "1") : settings) checkout "python3" (["-I", "-W", "error", checkout </> "tools/validation/owned_starts.py", "--root", directory] <> arguments)

-- | The guard's check on a fixture tree, answering whether it passed and what it said.
checked ∷ [(FilePath, String)] → IO (Bool, String)
checked files = withTree files $ \directory → do
  (result, _, errors) ← guard' directory ["check"]
  pure (result == ExitSuccess, errors)

spec ∷ Spec
spec = describe "The unowned-start guard (tools/validation/owned_starts.py)" $ do
  describe "a fixture tree" $ do
    it "passes a tree whose only thread is started through the shared facility" $ do
      (passed, errors) ←
        checked (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = withOwnedThread (pure ()) (\\_ _ -> pure ())"])])
      (passed, errors) `shouldBe` (True, "")

    it "fails a new unowned start, naming the file and the facility to use" $ do
      (passed, errors) ←
        checked (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = forkIO (pure ()) >> pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "pkg/test/Main.hs"
      errors `shouldContain` "1 unowned thread or process start(s) where the baseline allows 0"
      errors `shouldContain` "Test.Support.Owned.withOwnedThread"
      errors `shouldContain` "tools/test-support/src/Test/Support/Owned.hs"

    it "passes a baselined start" $ do
      (passed, errors) ←
        checked (tree plainConfig [("pkg/test/Main.hs", 1)] [("pkg/test/Main.hs", source ["main :: IO ()", "main = forkIO (pure ()) >> pure ()"])])
      (passed, errors) `shouldBe` (True, "")

    it "passes a tree whose only subprocess is started through the shared subprocess facility" $ do
      (passed, errors) ←
        checked
          ( tree
              plainConfig
              []
              [("pkg/test/Main.hs", source ["main :: IO ()", "main = runCaptured (Within 1000000) (proc \"true\" []) \"\" >> withScopedChild (childSpec Unbounded (proc \"true\" [])) (\\_ -> pure ())"])]
          )
      (passed, errors) `shouldBe` (True, "")

    it "fails a new unowned subprocess start, naming the file and the subprocess facility to use" $ do
      (passed, errors) ←
        checked (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = readCreateProcessWithExitCode (proc \"true\" []) \"\" >> pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "pkg/test/Main.hs"
      errors `shouldContain` "1 unowned thread or process start(s) where the baseline allows 0"
      errors `shouldContain` "Test.Support.Subprocess"
      errors `shouldContain` "tools/test-support/src/Test/Support/Subprocess.hs"
      errors `shouldContain` "withScopedChild"
      -- A file that starts no thread is not told to use the thread facility.
      errors `shouldNotContain` "Test.Support.Owned"

    it "passes a baselined subprocess start" $ do
      (passed, errors) ←
        checked (tree plainConfig [("pkg/test/Main.hs", 1)] [("pkg/test/Main.hs", source ["main :: IO ()", "main = readProcess \"true\" [] \"\" >> pure ()"])])
      (passed, errors) `shouldBe` (True, "")

    it "counts a start made with createProcess_, which does not close the handles it is given, as a subprocess start" $ do
      (passed, errors) ←
        checked (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = createProcess_ \"x\" (proc \"true\" []) >> pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "createProcess_@"

    it "fails a start beyond the baseline's count in the same file" $ do
      (passed, errors) ←
        checked (tree plainConfig [("pkg/test/Main.hs", 1)] [("pkg/test/Main.hs", source ["main :: IO ()", "main = forkIO (pure ()) >> forkOS (pure ()) >> pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "2 unowned thread or process start(s) where the baseline allows 1"

    it "fails a stale baseline entry whose site no longer exists" $ do
      (passed, errors) ←
        checked (tree plainConfig [("pkg/test/Main.hs", 1)] [("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "stale baseline entry"
      errors `shouldContain` "the baseline can only shrink"

    it "fails a stale baseline entry for a file that no longer exists" $ do
      (passed, errors) ← checked (tree plainConfig [("pkg/test/Gone.hs", 2)] [("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "pkg/test/Gone.hs: stale baseline entry"

    it "fails a count that fell without the baseline falling with it" $ do
      (passed, errors) ←
        checked (tree plainConfig [("pkg/test/Main.hs", 3)] [("pkg/test/Main.hs", source ["main :: IO ()", "main = forkIO (pure ()) >> forkIO (pure ()) >> pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "stale baseline entry, it allows 3 unowned start(s) but only 2 remain"

  describe "what counts as a start" $ do
    it "ignores comments, string literals, character literals, imports and the module header" $ do
      let body =
            [ "import Control.Concurrent (forkIO)"
            , "import System.Process"
            , "  ( createProcess"
            , "  , proc"
            , "  )"
            , ""
            , "-- forkIO in a line comment, and forkOS"
            , "{- forkIO in a block comment {- nested forkOS -} still a comment -}"
            , "client :: String"
            , "client = \"main = forkIO (pure ()) and createProcess\""
            , "gap :: String"
            , "gap = \"spawnProcess \\"
            , "  \\ callCommand\""
            , "quote :: Char"
            , "quote = '\"'"
            , "name' :: Int"
            , "name' = 1"
            , "main :: IO ()"
            , "main = pure ()"
            ]
      (passed, errors) ← checked (tree plainConfig [] [("pkg/test/Main.hs", unlines ("module Main (main, forkIO) where" : "" : body))])
      (passed, errors) `shouldBe` (True, "")

    it "recognises qualified calls and every primitive of the sweep" $ do
      let body = ["main :: IO ()", "main = do", "  _ <- Control.Concurrent.forkIO (pure ())", "  _ <- Proc.createProcess undefined", "  Proc.callCommand \"x\""]
      (passed, errors) ← checked (tree plainConfig [] [("pkg/test/Main.hs", source body)])
      passed `shouldBe` False
      errors `shouldContain` "3 unowned thread or process start(s)"

    it "does not mistake an operator or a longer name for a start" $ do
      let body = ["main :: IO ()", "main = pure ()", "forkIOLater :: Int", "forkIOLater = 1", "(-->) :: Int -> Int -> Int", "a --> b = a + b -- forkIO"]
      (passed, errors) ← checked (tree plainConfig [] [("pkg/test/Main.hs", source body)])
      (passed, errors) `shouldBe` (True, "")

    it "finds a start in a module whose whole body is indented, while its imports and export list stay ignored" $ do
      let indented =
            unlines
              [ "module Main"
              , "  ( main"
              , "  , forkIO"
              , "  ) where"
              , "  import Control.Concurrent (forkIO)"
              , "  import qualified System.Process as Proc (createProcess)"
              , "  main :: IO ()"
              , "  main = forkIO (pure ()) >> pure ()"
              ]
      (passed, errors) ← checked (tree plainConfig [] [("pkg/test/Main.hs", indented)])
      passed `shouldBe` False
      errors `shouldContain` "pkg/test/Main.hs: 1 unowned thread or process start(s)"

    it "finds a start in an indented module body that has no header, and in one whose later declarations are indented" $ do
      let headerless = unlines ["  import Control.Concurrent", "  main = forkIO (pure ()) >> pure ()"]
          oneLine = unlines ["module Main where", "  import Control.Concurrent", "  helper = pure ()", "  main = forkIO helper >> pure ()"]
      (headerlessPassed, headerlessErrors) ← checked (tree plainConfig [] [("pkg/test/Main.hs", headerless)])
      (onePassed, oneErrors) ← checked (tree plainConfig [] [("pkg/test/Main.hs", oneLine)])
      headerlessPassed `shouldBe` False
      headerlessErrors `shouldContain` "1 unowned thread or process start(s)"
      onePassed `shouldBe` False
      oneErrors `shouldContain` "1 unowned thread or process start(s)"

  -- One row of the scanner's audit against Haskell's syntax (the table in the pull request): either the scanner reads the
  -- construct correctly, with a fixture, or it rejects the file with a clear error. Nothing in the table is passed silently.
  describe "the scanner against Haskell's syntax" $ do
    let found (n ∷ Int) = (False, show n <> " unowned thread or process start(s)")
        clean = (True, "")
        rejected reason = (False, reason)
        rows ∷ [(String, [String], (Bool, String))]
        rows =
          [ ("layout: a semicolon after an import does not hide the declaration that follows it", ["module Main where", "  import Control.Concurrent; main = forkIO (pure ()) >> pure ()"], found 1)
          , ("layout: semicolon-separated imports, one spanning lines, then a declaration on the same line", ["module Main where", "  import A (a,", "    b); import B; main = forkIO (pure ())"], found 1)
          , ("layout: an import list that mentions a primitive is not a start, with or without a semicolon", ["module Main where", "  import Control.Concurrent (forkIO); import System.Process (createProcess)", "  main :: IO ()", "  main = pure ()"], clean)
          , ("explicit braces: a module body in braces is rejected", ["module Main where {", "  import Control.Concurrent; main = forkIO (pure ()) }"], rejected "explicit braces")
          , ("nested block comments: a primitive inside nested comments is not a start", ["main :: IO ()", "main = pure () {- outer {- forkIO -} still comment forkOS -}"], clean)
          , ("nested block comments: code after the comments closes is read", ["main :: IO ()", "main = pure () {- a {- b -} c -} >> forkIO (pure ()) >> pure ()"], found 1)
          , ("string literals: escapes and string gaps hide nothing and show nothing", ["s :: String", "s = \"a \\\" forkIO \\\\\" ++ \"x\\", "  \\y forkOS\"", "main :: IO ()", "main = forkIO (pure ()) >> pure ()"], found 1)
          , ("character literals: a quote character does not open a string", ["c :: Char", "c = '\"'", "main :: IO ()", "main = forkIO (pure ()) >> pure ()"], found 1)
          , ("character literals: a primed name and an escaped quote are not literals", ["f' :: Int", "f' = 1", "q :: Char", "q = '\\''", "main :: IO ()", "main = forkIO (pure ()) >> pure ()"], found 1)
          , ("multi-line strings: rejected", ["s :: String", "s = \"\"\"", "forkIO", "\"\"\"", "main :: IO ()", "main = pure ()"], rejected "multi-line string")
          , ("CPP: both branches of a conditional and a macro that names a primitive are counted", ["#if FLAG", "main = forkIO (pure ())", "#else", "main = forkOS (pure ())", "#endif", "#define STARTER forkIO"], found 3)
          , ("Template Haskell: a file that enables it and names no primitive is accepted", ["{-# LANGUAGE TemplateHaskell #-}", "main :: IO ()", "main = pure ()"], clean)
          , ("Template Haskell: a file that enables it and names a primitive is rejected", ["{-# LANGUAGE TemplateHaskell #-}", "main :: IO ()", "main = forkIO (pure ())"], rejected "TemplateHaskell is on and the source names forkIO")
          , ("quasi-quotes: a file that enables them and names a primitive, even in a comment, is rejected", ["{-# LANGUAGE QuasiQuotes #-}", "-- forkIO", "main :: IO ()", "main = pure ()"], rejected "QuasiQuotes is on and the source names forkIO")
          , ("qualified and aliased imports: a call through the alias is a start", ["import qualified Control.Concurrent as C", "main :: IO ()", "main = C.forkIO (pure ()) >> pure ()"], found 1)
          , ("qualified imports: the full module path is a start too", ["main :: IO ()", "main = Control.Concurrent.forkOS (pure ()) >> pure ()"], found 1)
          , ("backticks: an infix use is a start", ["main :: IO ()", "main = pure () `forkIO` pure ()"], found 1)
          , ("operator sections: a section and a bare reference are starts", ["main :: IO ()", "main = mapM_ (forkIO $) [] >> mapM_ (`forkOS` undefined) []"], found 2)
          , ("operators and longer names: not starts", ["forkIOLater :: Int", "forkIOLater = 1", "(-->) :: Int -> Int -> Int", "a --> b = a + b", "main :: IO ()", "main = pure ()"], clean)
          ]
    forM_ rows $ \(label, body, expected) →
      it label $ do
        (passed, errors) ← checked (tree plainConfig [] [("pkg/test/Main.hs", unlines body)])
        passed `shouldBe` fst expected
        errors `shouldContain` snd expected

    it "rejects a source of a kind it does not read, in a scanned directory" $ do
      (passed, errors) ← checked (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"]), ("pkg/test/Lit.lhs", "> main = forkIO (pure ())\n")])
      passed `shouldBe` False
      errors `shouldContain` "pkg/test/Lit.lhs: a source of a kind the scanner does not read"

    it "rejects a package description that turns on Template Haskell for components it scans" $ do
      let extra = [("pkg/pkg.cabal", packageDescription <> "    default-extensions: TemplateHaskell\n")]
      (passed, errors) ← checked (replacing (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])]) extra)
      passed `shouldBe` False
      errors `shouldContain` "TemplateHaskell is not supported by the scanner"

    it "writes no bytecode beside its sibling modules when run in isolated mode, as the tests and the runner run it" $ do
      checkout ← getCurrentDirectory
      withSystemTempDirectory "hetoimasia-owned-bytecode" $ \copy → do
        modules ← filter (".py" `isSuffixOf`) <$> listDirectory (checkout </> "tools/validation")
        createDirectoryIfMissing True (copy </> "tools/validation")
        forM_ modules $ \name → copyFile (checkout </> "tools/validation" </> name) (copy </> "tools/validation" </> name)
        withTree (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])]) $ \fixture → do
          settings ← sanitizedEnvironment
          -- No PYTHONDONTWRITEBYTECODE: the guard has to switch it off itself, since -I ignores the variable anyway.
          (result, _, errors) ← run settings copy "python3" ["-I", "-W", "error", copy </> "tools/validation/owned_starts.py", "--root", fixture, "check"]
          (result, errors) `shouldBe` (ExitSuccess, "")
          listDirectory (copy </> "tools/validation") >>= (`shouldNotContain` ["__pycache__"])

  describe "which sources are scanned" $ do
    it "covers a test suite declared later without editing the guard's configuration" $ do
      let extra =
            [ ("pkg/pkg.cabal", packageDescription <> "\ntest-suite later\n    type: exitcode-stdio-1.0\n    main-is: Main.hs\n    hs-source-dirs: later\n    default-language: GHC2024\n    build-depends: base\n")
            , ("pkg/later/Main.hs", source ["main :: IO ()", "main = spawnProcess \"true\" [] >> pure ()"])
            , ("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])
            ]
      (passed, errors) ← checked (replacing (tree plainConfig [] []) extra)
      passed `shouldBe` False
      errors `shouldContain` "pkg/later/Main.hs"

    it "covers a source directory only a conditional declares" $ do
      let description =
            unlines
              [ "cabal-version: 3.0"
              , "name: pkg"
              , "version: 0.1.0.0"
              , "build-type: Simple"
              , ""
              , "flag extra"
              , "    manual: True"
              , "    default: False"
              , ""
              , "test-suite spec"
              , "    type: exitcode-stdio-1.0"
              , "    main-is: Main.hs"
              , "    hs-source-dirs: test"
              , "    default-language: GHC2024"
              , "    build-depends: base"
              , "    if flag(extra)"
              , "        hs-source-dirs: conditional"
              ]
      (passed, errors) ←
        checked (replacing (tree plainConfig [] []) [("pkg/pkg.cabal", description), ("pkg/conditional/Main.hs", source ["main :: IO ()", "main = forkOS (pure ()) >> pure ()"]), ("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "pkg/conditional/Main.hs"

    it "covers a library built only for tests, and leaves a named child executable out with its reason" $ do
      let description =
            packageDescription
              <> unlines
                [ ""
                , "library session-harness"
                , "    hs-source-dirs: harness"
                , "    exposed-modules: Harness"
                , "    default-language: GHC2024"
                , "    build-depends: base"
                , ""
                , "executable child-helper"
                , "    main-is: Main.hs"
                , "    hs-source-dirs: child"
                , "    default-language: GHC2024"
                , "    build-depends: base"
                ]
          excluded = "{\"component\": \"pkg:exe:child-helper\", \"reason\": \"a helper executable a suite launches as a child process\"}"
          files =
            [ ("pkg/pkg.cabal", description)
            , ("pkg/harness/Harness.hs", "module Harness where\n\nharness :: IO ()\nharness = forkFinally (pure ()) (\\_ -> pure ()) >> pure ()\n")
            , ("pkg/child/Main.hs", source ["main :: IO ()", "main = forkIO (pure ()) >> pure ()"])
            , ("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])
            ]
      (passed, errors) ← checked (replacing (tree (config "" excluded "") [] []) files)
      passed `shouldBe` False
      errors `shouldContain` "pkg/harness/Harness.hs"
      errors `shouldNotContain` "pkg/child/Main.hs"

    it "fails an exclusion or a test-only listing that names a component no package declares" $ do
      (passed, errors) ←
        checked (tree (config "" "{\"component\": \"pkg:exe:gone\", \"reason\": \"it was removed\"}" "") [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "pkg:exe:gone"

  describe "the exemption of an already-owned helper" $ do
    let exemption count = "{\"file\": \"pkg/test/Main.hs\", \"binding\": \"owned\", \"sites\": " <> show (count ∷ Int) <> ", \"reason\": \"started under mask and joined by its release\"}"
        helper = ["owned :: IO ()", "owned = forkIO (pure ()) >> pure ()"]
    it "passes the helper's own start" $ do
      (passed, errors) ← checked (tree (config "" "" (exemption 1)) [] [("pkg/test/Main.hs", source (["main :: IO ()", "main = owned"] <> helper))])
      (passed, errors) `shouldBe` (True, "")

    it "fails a new raw start elsewhere in a file that contains an exempt helper" $ do
      (passed, errors) ←
        checked (tree (config "" "" (exemption 1)) [] [("pkg/test/Main.hs", source (["main :: IO ()", "main = owned >> forkOS (pure ()) >> pure ()"] <> helper))])
      passed `shouldBe` False
      errors `shouldContain` "1 unowned thread or process start(s) where the baseline allows 0"

    it "fails an exempt helper that gained a start, because its count is exact" $ do
      (passed, errors) ←
        checked (tree (config "" "" (exemption 1)) [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = owned", "owned :: IO ()", "owned = forkIO (pure ()) >> forkIO (pure ()) >> pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "stale exemption"

    it "fails an exemption whose helper no longer starts anything" $ do
      (passed, errors) ← checked (tree (config "" "" (exemption 1)) [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()", "owned :: IO ()", "owned = pure ()"])])
      passed `shouldBe` False
      errors `shouldContain` "stale exemption"

    it "refuses an exemption that gives no reason" $ do
      (passed, errors) ←
        checked (tree (config "" "" "{\"file\": \"pkg/test/Main.hs\", \"binding\": \"owned\", \"sites\": 1, \"reason\": \"\"}") [] [("pkg/test/Main.hs", source (["main :: IO ()", "main = owned"] <> helper))])
      passed `shouldBe` False
      errors `shouldContain` "an exemption needs"

  describe "bootstrapping and the ratchet against the review base" $ do
    it "writes the initial baseline from what it observes, and the check then passes" $
      withTree (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = forkIO (pure ()) >> forkOS (pure ()) >> pure ()"])]) $ \directory → do
        (written, output, _) ← guard' directory ["bootstrap"]
        written `shouldBe` ExitSuccess
        output `shouldContain` "2 start(s) in 1 file(s)"
        (result, _, errors) ← guard' directory ["check"]
        (result, errors) `shouldBe` (ExitSuccess, "")

    it "passes a baseline that did not grow, and one that shrank" $
      withRatchet (baseline [("pkg/test/A.hs", 2), ("pkg/test/B.hs", 1)]) $ \directory base → do
        writeFixtureFile directory "tools/validation/owned_starts_baseline.json" (baseline [("pkg/test/A.hs", 1)])
        (result, _, errors) ← guard' directory ["ratchet", "--base", base]
        (result, errors) `shouldBe` (ExitSuccess, "")

    it "fails a count that grew with the baseline raised to match, though the check itself passes" $
      withRatchet (baseline [("pkg/test/Main.hs", 1)]) $ \directory base → do
        writeFixtureFile directory "pkg/test/Main.hs" (source ["main :: IO ()", "main = forkIO (pure ()) >> forkOS (pure ()) >> pure ()"])
        writeFixtureFile directory "tools/validation/owned_starts_baseline.json" (baseline [("pkg/test/Main.hs", 2)])
        (checkResult, _, checkErrors) ← guard' directory ["check"]
        (checkResult, checkErrors) `shouldBe` (ExitSuccess, "")
        (result, _, errors) ← guard' directory ["ratchet", "--base", base]
        result `shouldBe` ExitFailure 1
        errors `shouldContain` "the baseline grew from 1 to 2; it can only shrink"

    it "fails a new baseline entry the review base does not have" $
      withRatchet (baseline [("pkg/test/Main.hs", 1)]) $ \directory base → do
        writeFixtureFile directory "pkg/test/Other.hs" (source ["other :: IO ()", "other = spawnProcess \"x\" [] >> pure ()"])
        writeFixtureFile directory "tools/validation/owned_starts_baseline.json" (baseline [("pkg/test/Main.hs", 1), ("pkg/test/Other.hs", 1)])
        (result, _, errors) ← guard' directory ["ratchet", "--base", base]
        result `shouldBe` ExitFailure 1
        errors `shouldContain` "pkg/test/Other.hs: a baseline entry (1) that the review base does not have"

    -- The test job's checkout is shallow, so the review base is not there and the example above is pending. The planning job
    -- holds the history, and its step is what enforces the ratchet where a pull request is checked: these run the shipped step.
    describe "the planning job's ratchet step (.github/workflows/validation.yml)" $ do
      let ratchetStep directory base = do
            checkout ← getCurrentDirectory
            body ← workflowStepBody checkout ".github/workflows/validation.yml" "Hold the owned-start baseline against the review base"
            createDirectoryIfMissing True (directory </> "tools/validation")
            -- The guard reads the planner's Cabal reader beside it, so the tools directory's modules go with it.
            modules ← filter (".py" `isSuffixOf`) <$> listDirectory (checkout </> "tools/validation")
            forM_ modules $ \name → copyFile (checkout </> "tools/validation" </> name) (directory </> "tools/validation" </> name)
            settings ← sanitizedEnvironment
            run (("BASE", base) : ("PYTHONDONTWRITEBYTECODE", "1") : settings) directory "bash" ["-c", body]

      it "passes where the baseline did not grow" $ inCheckout $ \_ →
        withRatchet (baseline [("pkg/test/Main.hs", 1)]) $ \directory base → do
          (result, _, errors) ← ratchetStep directory base
          (result, errors) `shouldBe` (ExitSuccess, "")

      it "fails where the baseline grew, so a raised baseline is refused even though the check passes" $ inCheckout $ \_ →
        withRatchet (baseline [("pkg/test/Main.hs", 1)]) $ \directory base → do
          writeFixtureFile directory "pkg/test/Main.hs" (source ["main :: IO ()", "main = forkIO (pure ()) >> forkOS (pure ()) >> pure ()"])
          writeFixtureFile directory "tools/validation/owned_starts_baseline.json" (baseline [("pkg/test/Main.hs", 2)])
          (result, _, errors) ← ratchetStep directory base
          result `shouldBe` ExitFailure 1
          errors `shouldContain` "the baseline grew from 1 to 2; it can only shrink"

      it "fails where the base cannot be resolved, rather than skipping the rule" $ inCheckout $ \_ →
        withRatchet (baseline [("pkg/test/Main.hs", 1)]) $ \directory _ → do
          (result, _, errors) ← ratchetStep directory (replicate 40 'a')
          result `shouldBe` ExitFailure 2
          errors `shouldContain` "cannot resolve the review base"

      it "runs in the job that holds the history, before the plan is resolved" $ inCheckout $ \checkout → do
        workflow ← readFile (checkout </> ".github/workflows/validation.yml")
        let planJob = takeWhile (not . isPrefixOf "  haskell-engine:") (dropWhile (not . isPrefixOf "  plan:") (lines workflow))
            position name = length (takeWhile (/= "      - name: " <> name) planJob)
        planJob `shouldSatisfy` any (== "          fetch-depth: 0")
        planJob `shouldSatisfy` elem "      - name: Hold the owned-start baseline against the review base"
        position "Hold the owned-start baseline against the review base" `shouldSatisfy` (< position "Resolve the plan")

    it "allows the baseline to be established where the review base has none (the explicit bootstrap)" $
      withTree (tree plainConfig [("pkg/test/Main.hs", 1)] [("pkg/test/Main.hs", source ["main :: IO ()", "main = forkIO (pure ()) >> pure ()"])]) $ \directory → do
        settings ← sanitizedEnvironment
        void $ git settings directory ["init", "-q", "-b", "master"]
        writeFixtureFile directory "seed.txt" "seed\n"
        void $ git settings directory ["add", "seed.txt"]
        void $ git settings directory ["commit", "-q", "-m", "seed"]
        base ← takeWhile (/= '\n') <$> git settings directory ["rev-parse", "HEAD"]
        (result, _, errors) ← guard' directory ["ratchet", "--base", base]
        (result, errors) `shouldBe` (ExitSuccess, "")

  describe "the three sites the issue names, as they were before they were owned" $
    it "are reported as violations on a tree with them unconverted" $ do
      let library =
            source
              [ "within120 :: IO ()"
              , "within120 = do"
              , "  -- Cancel the example once the command has begun but before it publishes its endpoint, then let it go on."
              , "  _ <- forkIO (takeMVar began >> throwTo caller UserInterrupt >> putMVar gate ())"
              , "  outcome <- try @SomeException (runWithEnding env folder ended (putMVar began () >> takeMVar gate) (\\_ _ _ -> pure ()))"
              , "  _ <- forkIO $ do"
              , "    readMVar ended"
              , "    blockedSending caller"
              , "    throwTo caller UserInterrupt"
              , "    putMVar gate ()"
              , "  pure ()"
              ]
          childSpec =
            source
              [ "parkedRelease :: IO ()"
              , "parkedRelease = do"
              , "  worker <- forkIO (tryWithContext @SomeException (run defaultBounds (hooks parked gate) body) >>= atomically . putTMVar finished)"
              , "  throwTo worker UserInterrupt"
              ]
      (passed, errors) ←
        checked
          ( tree
              plainConfig
              []
              [ ("pkg/test/Main.hs", source ["main :: IO ()", "main = pure ()"])
              , ("pkg/test/Test/Run/Native/Library.hs", library)
              , ("pkg/test/Test/Run/Native/ChildSpec.hs", childSpec)
              ]
          )
      passed `shouldBe` False
      errors `shouldContain` "pkg/test/Test/Run/Native/Library.hs: 2 unowned thread or process start(s)"
      errors `shouldContain` "pkg/test/Test/Run/Native/ChildSpec.hs: 1 unowned thread or process start(s)"

  describe "this repository" $ do
    -- These read every package of the checkout. A source distribution of the root package does not carry them (it carries
    -- only the guard's own files), so where the project file is absent the examples are pending rather than failing.
    it "passes the guard" $ inCheckout $ \checkout → do
      (result, _, errors) ← guard' checkout ["check"]
      (result, errors) `shouldBe` (ExitSuccess, "")

    it "no longer lists the three named sites' files in the baseline, and has no exempt start in them but the audited scenario thread" $ inCheckout $ \checkout → do
      text ← readFile (checkout </> "tools/validation/owned_starts_baseline.json")
      text `shouldNotContain` "run-native-test/Test/Run/Native/Library.hs"
      text `shouldNotContain` "run-native-test/Test/Run/Native/ChildSpec.hs"

    it "no longer lists, in the baseline, the files whose only starts were subprocess starts that the shared subprocess facility now owns (#588)" $ inCheckout $ \checkout → do
      text ← readFile (checkout </> "tools/validation/owned_starts_baseline.json")
      forM_ converted $ \path → text `shouldNotContain` path

    it "has not grown its baseline relative to the review base" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      (resolved, _, _) ← run settings checkout "git" ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]
      case resolved of
        ExitSuccess → do
          mergeBase ← takeWhile (/= '\n') <$> git settings checkout ["merge-base", "HEAD", "origin/master"]
          (result, _, errors) ← guard' checkout ["ratchet", "--base", mergeBase]
          (result, errors) `shouldBe` (ExitSuccess, "")
        ExitFailure _ → pendingWith "origin/master is not available in this checkout, so the review base cannot be resolved; the ratchet is checked wherever it is"

    it "scans only what the catalog's workflow group lists as inputs, so a change anywhere it scans selects it" $ inCheckout $ \checkout → do
      (result, scope, errors) ← guard' checkout ["scope"]
      (result, errors) `shouldBe` (ExitSuccess, "")
      catalog ← readFile (checkout </> "tools/validation/catalog.json")
      let inputs = do
            document ← parseJson catalog
            entry ← field "groups" document >>= entryFor "id" "test.workflow"
            elements ← field "inputs" entry >>= asArray
            traverse asString elements
          covered path = case inputs of
            Just entries → any (matches path) entries
            Nothing → False
          matches path entry
            | "/" `isSuffixOf'` entry = path == init entry || entry `isPrefixOf` path
            | otherwise = path == entry
          missing =
            [ path
            | line ← lines scope
            , let path = drop 1 (dropWhile (/= ' ') line)
            , not (null path)
            , not (covered path || covered (path <> "/"))
            ]
      inputs `shouldSatisfy` (/= Nothing)
      missing `shouldBe` []

    it "selects the workflow group for an ordinary test-source change outside it, a source-directory declaration and the baseline" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      files ← lines <$> git settings checkout ["-c", "safe.directory=*", "ls-files", "*.cabal", "cabal.project*", "tools/validation/catalog.json"]
      let changedPaths =
            [ "packages/foundation/test/Test/Foundation/Time/Spec.hs"
            , "packages/scripting-lua/hazard-test/Main.hs"
            , "packages/glfw/hetoimasia-glfw.cabal"
            , "tools/validation/owned_starts_baseline.json"
            , "tools/validation/owned_starts.json"
            ]
      forM_ changedPaths $ \changed →
        withSystemTempDirectory "hetoimasia-owned-plan" $ \directory → do
          forM_ [path | path ← files, not ("docs/" `isPrefixOf` path)] $ \path → do
            createDirectoryIfMissing True (directory </> takeDirectory path)
            copyFile (checkout </> path) (directory </> path)
          present ← doesFileExist (directory </> changed)
          if present then pure () else writeFixtureFile directory changed "-- before\n"
          void $ git settings directory ["init", "-q", "-b", "master"]
          void $ git settings directory ["add", "-A", "."]
          void $ git settings directory ["commit", "-q", "-m", "base"]
          base ← takeWhile (/= '\n') <$> git settings directory ["rev-parse", "HEAD"]
          appendFile (directory </> changed) "-- after\n"
          void $ git settings directory ["commit", "-q", "-a", "-m", "head"]
          (result, output, errors) ← run settings checkout "python3" [checkout </> "tools/validation/plan.py", "--repo-root", directory, "--base", base, "--head", "HEAD", "--json"]
          (result, errors) `shouldBe` (ExitSuccess, "")
          case parseJson output >>= field "groups" >>= entryFor "id" "test.workflow" of
            Nothing → expectationFailure ("the plan for " <> changed <> " has no test.workflow group")
            Just entry → do
              (field "selected" entry, field "reason" entry) `shouldSatisfy` \(selected, reason) → selected == Just (JBool True) && reason `elem` [Just (JString "affected"), Just (JString "floor")]
              field "inputs_changed" entry `shouldBe` Just (JBool True)
  where
    isSuffixOf' suffix text = reverse suffix `isPrefixOf` reverse text

-- | Run an example against the checkout, or leave it pending where this is not a checkout of the whole repository.
inCheckout ∷ (FilePath → IO ()) → IO ()
inCheckout example = do
  checkout ← getCurrentDirectory
  present ← doesFileExist (checkout </> "cabal.project")
  if present then example checkout else pendingWith "this is not a checkout of the whole repository (no cabal.project)"

-- | Replace the fixture tree's files of the same path.
replacing ∷ [(FilePath, String)] → [(FilePath, String)] → [(FilePath, String)]
replacing original updates = [entry | entry@(path, _) ← original, path `notElem` map fst updates] <> updates

-- | A git repository whose first commit is a one-start package with the given baseline, handed with that commit.
withRatchet ∷ String → (FilePath → String → IO a) → IO a
withRatchet initialBaseline action = withSystemTempDirectory "hetoimasia-owned-ratchet" $ \directory → do
  forM_
    ( replacing
        (tree plainConfig [] [("pkg/test/Main.hs", source ["main :: IO ()", "main = forkIO (pure ()) >> pure ()"])])
        [("tools/validation/owned_starts_baseline.json", initialBaseline)]
    )
    (uncurry (writeFixtureFile directory))
  settings ← sanitizedEnvironment
  void $ git settings directory ["init", "-q", "-b", "master"]
  void $ git settings directory ["add", "-A", "."]
  void $ git settings directory ["commit", "-q", "-m", "base"]
  base ← takeWhile (/= '\n') <$> git settings directory ["rev-parse", "HEAD"]
  action directory base

-- | The files whose every baselined start was a subprocess start (or a thread that existed only to serve one), converted in #588 and, for
-- the two display-helper suites (which run their helper on a host), in #608: none of them has a baseline entry any more.
converted ∷ [FilePath]
converted =
      [ "packages/asset-image/test/Test/Asset/Image/Bc7Opacity.hs",
      "packages/asset-image/test/Test/Asset/Image/PngDecodeClient.hs",
      "packages/asset-image/test/Test/Asset/Image/PngPreflightClient.hs",
      "packages/content/test/Test/Content/Identity/Boundary.hs",
      "packages/content/test/Test/Content/Inventory/Boundary.hs",
      "packages/content/test/Test/Content/Opacity.hs",
      "packages/content/test/Test/Content/ReadPool/Boundary.hs",
      "packages/foundation/test/Test/Foundation/Messaging/Opacity.hs",
      "packages/foundation/test/Test/Foundation/Resources/Opacity.hs",
      "packages/foundation/test/Test/Foundation/Time/Opacity.hs",
      "packages/foundation/test/Test/Foundation/Workers/Opacity.hs",
      "packages/glfw/native-tests/Test/GLFW/Native/Presence.hs",
      "packages/glfw/test/Test/GLFW/Linking.hs",
      "packages/glfw/test/Test/GLFW/Opacity.hs",
      "packages/gpu-vulkan/glfw/native-test/Test/GPU/Vulkan/Native/Compositor.hs",
      "packages/gpu-vulkan/model/test/Test/GPU/Model/Opacity.hs",
      "packages/gpu-vulkan/native/probe/allocator-parity/Main.hs",
      "packages/gpu-vulkan/native/probe/allocator-parity/Production.hs",
      "packages/lua-engine/test/Test/LuaEngine/Facade/Client.hs",
      "packages/lua-engine/test/Test/LuaEngine/Modules/Client.hs",
      "packages/lua-engine/test/Test/LuaEngine/Scene/Client.hs",
      "packages/lua-engine/test/Test/LuaEngine/Session/Client.hs",
      "packages/lua-engine/test/Test/LuaEngine/Texture/Client.hs",
      "packages/runtime/test/Test/Runtime/Opacity.hs",
      "packages/scripting-lua/hazard-test/Main.hs",
      "packages/scripting-lua/macos/test/Test/MacOS/Driver.hs",
      "packages/scripting-lua/test/Test/Lua/Hazard.hs",
      "packages/scripting-lua/test/Test/Lua/Opacity.hs",
      "samples/lua-domains/test/Test/Domains/Options.hs",
      "samples/lua-domains/test/Test/Domains/Process.hs",
      "test/Test/Engine/Console/Support.hs",
      "tools/test-support/src/Test/Support/ExternalClient.hs",
      "tools/test/RunnerIdentity.hs",
      "tools/test/Sandbox.hs",
      "tools/test/VulkanProof.hs",
      "tools/wayland-test/Main.hs",
      "tools/x11-test/Main.hs"
      ]
