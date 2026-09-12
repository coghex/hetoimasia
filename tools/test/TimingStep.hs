-- | Hspec coverage for what a failure to collect run timings does to the
-- required verdict.
--
-- @tools/validation/timings.py@ never decides anything: a job whose timings
-- are unavailable is a reporting gap. The step that collects them, though,
-- runs immediately before the step that decides the verdict, and that step
-- carries the default success condition — so for as long as the collection
-- step could fail, an unanswered API call suppressed a verdict every other
-- input was present to decide.
--
-- These examples extract that step's own @run@ body out of
-- @.github/workflows/validation.yml@ and execute it against a stubbed @gh@,
-- so what is asserted is the shell that actually ships rather than a
-- restatement of it. The stub is what makes the cases reachable at all: an
-- API that answers with an error, and one that answers with something no
-- report can read, do not occur on demand against a real repository. The real
-- aggregate then runs against real receipts in the same working directory and
-- writes to the same job summary, which is what proves the gap changed the
-- report and not the result.
module TimingStep (spec) where

import Control.Monad (void)
import Data.List (isPrefixOf)
import Sandbox
  ( fixtureGenerated
  , fixtureIgnore
  , git
  , run
  , sanitizedEnvironment
  , workflowStepBody
  , writeFixtureFile
  )
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
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
  , shouldNotContain
  , shouldSatisfy
  )

data Fixture = Fixture
  { root ∷ FilePath
  , tools ∷ FilePath
  , environment ∷ [(String, String)]
  , seeded ∷ String
  }

spec ∷ Spec
spec = describe "Run timing collection" $ do
  it "renders the timings the API did answer with" $
    -- The ordinary path, so what follows is a statement about failure rather
    -- than about a step that stopped reporting altogether.
    withFixture $ \fixture → do
      answering fixture listing
      outcome ← timingStep fixture
      exitOf outcome `shouldBe` ExitSuccess
      published ← publishedSummary fixture
      published `shouldContain` "| plan |"
      published `shouldNotContain` "Unavailable"

  describe "a job listing it cannot collect" $ do
    it "lets successful evidence still reach a passing verdict" $
      -- The whole point: the API is down, every input the verdict needs is
      -- present, and `build-test` concludes from the aggregate alone.
      withFixture $ \fixture → do
        plan ← passingEvidence fixture
        refusing fixture 7
        outcome ← timingStep fixture
        exitOf outcome `shouldBe` ExitSuccess
        outputOf outcome `shouldContain` "::warning::"
        outputOf outcome `shouldContain` "the API call listing this run's jobs exited 7"
        (verdict, decided, _) ← following outcome (verdictStep fixture plan)
        verdict `shouldBe` ExitSuccess
        decided `shouldContain` "verdict: passed"
        published ← publishedSummary fixture
        published `shouldContain` "Unavailable: the API call listing this run's jobs exited 7."
        published `shouldContain` "Timings are ancillary"
        published `shouldContain` "## Validation verdict"

    it "lets a failing receipt still reach a failing verdict" $
      -- The mirror image, and the reason tolerance here is not a weakening:
      -- what the gap removes is the report, not any gate.
      withFixture $ \fixture → do
        plan ← failingEvidence fixture
        refusing fixture 7
        outcome ← timingStep fixture
        exitOf outcome `shouldBe` ExitSuccess
        (verdict, decided, _) ← following outcome (verdictStep fixture plan)
        verdict `shouldBe` ExitFailure 1
        decided `shouldContain` "test.fail"
        decided `shouldContain` "verdict: failed"
        published ← publishedSummary fixture
        published `shouldContain` "Unavailable: the API call listing this run's jobs exited 7."
        published `shouldContain` "## Validation verdict"

    it "names a listing the report refused to read rather than omitting the table" $
      -- `timings.py` exits 2 on a response that is not a JSON object, which
      -- under the old `set -e` body never ran at all: the shell had already
      -- left on the `gh` failure. This one answers, so the refusal is the
      -- report's own.
      withFixture $ \fixture → do
        plan ← passingEvidence fixture
        answering fixture "<html>a proxy error page</html>\n"
        outcome ← timingStep fixture
        exitOf outcome `shouldBe` ExitSuccess
        outputOf outcome `shouldContain` "tools/validation/timings.py exited 2"
        (verdict, decided, _) ← following outcome (verdictStep fixture plan)
        verdict `shouldBe` ExitSuccess
        decided `shouldContain` "verdict: passed"
        published ← publishedSummary fixture
        published `shouldContain` "Unavailable: tools/validation/timings.py exited 2"
        published `shouldContain` "## Validation verdict"

    it "treats an empty response the same way" $
      withFixture $ \fixture → do
        plan ← passingEvidence fixture
        answering fixture ""
        outcome ← timingStep fixture
        exitOf outcome `shouldBe` ExitSuccess
        outputOf outcome `shouldContain` "tools/validation/timings.py exited 2"
        (verdict, _, _) ← following outcome (verdictStep fixture plan)
        verdict `shouldBe` ExitSuccess
        published ← publishedSummary fixture
        published `shouldContain` "Unavailable: tools/validation/timings.py exited 2"

    it "reports a listing that is a JSON document naming no jobs as an empty table" $
      -- Not a failure: the API answered, and answered something readable. The
      -- report renders what it was given rather than inventing a gap.
      withFixture $ \fixture → do
        answering fixture "{\"total_count\": 0, \"jobs\": []}\n"
        outcome ← timingStep fixture
        exitOf outcome `shouldBe` ExitSuccess
        published ← publishedSummary fixture
        published `shouldContain` "## Run timings"
        published `shouldNotContain` "Unavailable"

  it "leaves the verdict step's own condition in place" $ do
    -- The tolerance belongs to the timing step and nowhere else. Moving it
    -- onto the verdict step instead — an `if: always()` there — would make the
    -- verdict run after a failed plan requirement or a failed read of the pull
    -- request's current state, which are the gates that must keep skipping it.
    checkout ← getCurrentDirectory
    workflow ← readFile (checkout </> ".github/workflows/validation.yml")
    stepOptions workflow "Decide the verdict" `shouldSatisfy` all (not . ("if:" `isPrefixOf`))
    stepOptions workflow "Read the pull request's current state"
      `shouldSatisfy` all (not . ("continue-on-error:" `isPrefixOf`))

-- ---------------------------------------------------------------------------
-- Running the shipped steps

-- | The step's own result, and the log it wrote while producing it.
data Outcome = Outcome ExitCode String

exitOf ∷ Outcome → ExitCode
exitOf (Outcome result _) = result

outputOf ∷ Outcome → String
outputOf (Outcome _ output) = output

-- | Extract the shipped timing step and run it where the aggregate runs.
timingStep ∷ Fixture → IO Outcome
timingStep fixture = do
  checkout ← getCurrentDirectory
  body ← workflowStepBody checkout ".github/workflows/validation.yml" "Record the run timings"
  writeFixtureFile (scratch fixture) "timing-step.sh" body
  (result, output, errors) ←
    run (stepEnvironment fixture) (root fixture) "bash" [scratch fixture </> "timing-step.sh"]
  -- A workflow command is an annotation on stdout; `gh` and `timings.py` write
  -- their own diagnostics to stderr, and both belong to the same step log.
  pure (Outcome result (output ++ errors))

-- | What the runner does next, and only when the previous step succeeded.
--
-- That condition is the entire mechanism this issue is about, so it is stated
-- here rather than assumed: an example that ran the aggregate unconditionally
-- would pass just as happily against the body that used to fail.
following ∷ Outcome → IO (ExitCode, String, String) → IO (ExitCode, String, String)
following outcome next = case exitOf outcome of
  ExitSuccess → next
  result → do
    expectationFailure
      ( "the timing step exited "
          ++ show result
          ++ ", so the runner would have skipped the verdict step:\n"
          ++ outputOf outcome
      )
    pure (result, "", "")

-- | The verdict step's own work: the real aggregate, writing to the same job
-- summary the timing step just wrote its gap into.
verdictStep ∷ Fixture → FilePath → IO (ExitCode, String, String)
verdictStep fixture plan =
  run
    (environment fixture)
    (root fixture)
    "python3"
    [ tools fixture </> "aggregate.py"
    , "--plan", plan
    , "--receipts", receiptsDirectory fixture
    , "--summary", summaryPath fixture
    ]

-- | The environment the runner gives a step, with the stub `gh` in front of
-- the real one and the job summary pointed at the fixture's own file.
stepEnvironment ∷ Fixture → [(String, String)]
stepEnvironment fixture = overrides ++ filter keep (environment fixture)
  where
    overrides =
      [ ("PATH", stubDirectory fixture ++ ":/usr/bin:/bin:/usr/sbin:/sbin")
      , ("GH_TOKEN", "stub-token")
      , ("REPOSITORY", "coghex/hetoimasia")
      , ("RUN_ID", "34650000001")
      , ("RUN_ATTEMPT", "2")
      , ("GITHUB_STEP_SUMMARY", summaryPath fixture)
      ]
    -- Every one of those has to *replace* the inherited entry rather than sit
    -- in front of it: Bash resolves a duplicate environment entry to the later
    -- one. That is not hypothetical for `GITHUB_STEP_SUMMARY` — the runner
    -- sets it, so these examples would otherwise write the fixture's gap into
    -- the real job summary and then assert against an empty file, failing only
    -- on CI.
    keep (name, _) = name `notElem` map fst overrides

-- ---------------------------------------------------------------------------
-- The stub GitHub and the evidence beside it

-- | Answer the job listing with this document.
answering ∷ Fixture → String → IO ()
answering fixture document = writeFixtureFile (stubDirectory fixture) "listing" document

-- | Refuse to answer it at all, the way an API error reaches the step.
refusing ∷ Fixture → Int → IO ()
refusing fixture status =
  writeFixtureFile (stubDirectory fixture) "refusal" (show status ++ "\n")

-- | A run whose selected group passed, and the plan its verdict is about.
passingEvidence ∷ Fixture → IO FilePath
passingEvidence fixture = do
  change fixture "README.md" "revised prose\n"
  plan ← planAgainst fixture
  (executed, _, errors) ← runGroup fixture plan "build.pass"
  (executed, errors) `shouldBe` (ExitSuccess, "")
  pure plan

-- | The same run with the failing group selected too, so the aggregate has a
-- real obstacle to report.
failingEvidence ∷ Fixture → IO FilePath
failingEvidence fixture = do
  change fixture "src/note.txt" "revised source\n"
  plan ← planAgainst fixture
  (passed, _, _) ← runGroup fixture plan "build.pass"
  passed `shouldBe` ExitSuccess
  (failed, _, _) ← runGroup fixture plan "test.fail"
  failed `shouldBe` ExitFailure 1
  pure plan

planAgainst ∷ Fixture → IO FilePath
planAgainst fixture = do
  (result, output, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ tools fixture </> "plan.py"
      , "--base", seeded fixture
      , "--head", "HEAD"
      , "--candidate", "HEAD"
      , "--json"
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")
  let target = root fixture </> "plan.json"
  writeFile target output
  pure target

runGroup ∷ Fixture → FilePath → String → IO (ExitCode, String, String)
runGroup fixture plan group =
  run
    (environment fixture)
    (root fixture)
    "python3"
    -- `-I` as every caller passes it: the runner refuses to start otherwise.
    [ "-I"
    , tools fixture </> "run.py"
    , group
    , "--plan", plan
    , "--receipts", receiptsDirectory fixture
    ]

-- ---------------------------------------------------------------------------
-- The fixture project

-- | Where the examples' own scratch lives: a directory the fixture catalog
-- declares generated, so a step script or a stub never reaches the tree the
-- plan's identity is taken from.
scratch, stubDirectory, receiptsDirectory ∷ Fixture → FilePath
scratch fixture = root fixture </> "gh-stub"
stubDirectory = scratch
receiptsDirectory fixture = root fixture </> "receipts"

-- | The one job summary both steps append to, as the runner gives them one.
summaryPath ∷ Fixture → FilePath
summaryPath fixture = scratch fixture </> "summary.md"

publishedSummary ∷ Fixture → IO String
publishedSummary = readFile . summaryPath

withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-timing-step" $ \directory → do
    let fixture = Fixture directory (checkout </> "tools/validation") settings ""
    void $ git settings directory ["init", "-b", "master"]
    mapM_ (uncurry (writeFixtureFile directory)) fixtureFiles
    -- The step runs `tools/validation/timings.py` by a path relative to the
    -- working directory, exactly as the job does, so the fixture project holds
    -- the real report rather than a stand-in for it.
    createDirectoryIfMissing True (directory </> "tools/validation")
    copyFile (tools fixture </> "timings.py") (directory </> "tools/validation/timings.py")
    void $ git settings directory ["add", "."]
    void $ git settings directory ["commit", "-q", "-m", "Seed the fixture project"]
    seed ← revision fixture "HEAD"
    createDirectoryIfMissing True (receiptsDirectory fixture)
    writeFixtureFile (scratch fixture) "summary.md" ""
    writeFixtureFile (stubDirectory fixture) "gh" (stubScript (stubDirectory fixture))
    let stub = stubDirectory fixture </> "gh"
    permissions ← getPermissions stub
    setPermissions stub (setOwnerExecutable True permissions)
    action fixture {seeded = seed}

-- | A `gh` that answers the job listing from the file beside it, or refuses to
-- answer at all when an example asked for a refusal.
stubScript ∷ FilePath → String
stubScript directory =
  unlines
    [ "#!/bin/sh"
    , "if [ -f " ++ show (directory </> "refusal") ++ " ]; then"
    , "  echo 'stub: the job listing is unavailable' >&2"
    , "  exit \"$(cat " ++ show (directory </> "refusal") ++ ")\""
    , "fi"
    , "cat " ++ show (directory </> "listing")
    ]

gitIn ∷ Fixture → [String] → IO String
gitIn fixture = git (environment fixture) (root fixture)

revision ∷ Fixture → String → IO String
revision fixture name = takeWhile (/= '\n') <$> gitIn fixture ["rev-parse", name]

-- | Commit exactly one path, so the scratch these examples write beside the
-- repository never reaches the tree identity is taken from.
change ∷ Fixture → FilePath → String → IO ()
change fixture path contents = do
  writeFixtureFile (root fixture) path contents
  void $ gitIn fixture ["add", "--", path]
  void $ gitIn fixture ["commit", "-q", "-m", "Change " ++ path]

fixtureFiles ∷ [(FilePath, String)]
fixtureFiles =
  [ (".gitignore", fixtureIgnore)
  , ("cabal.project", "packages:\n  .\n")
  , ("demo.cabal", demoPackage)
  , ("app/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("src/note.txt", "a fixture the failing group consumes\n")
  , ("README.md", "ordinary prose\n")
  , (".github/workflows/validation.yml", "name: validation\n")
  , ("tools/validation/catalog.json", fixtureCatalog)
  ]

demoPackage ∷ String
demoPackage =
  unlines
    [ "cabal-version: 3.16"
    , "name: demo"
    , "version: 0.1.0.0"
    , "synopsis: Fixture package"
    , "build-type: Simple"
    , ""
    , "executable demo"
    , "    main-is: Main.hs"
    , "    hs-source-dirs: app"
    , "    default-language: GHC2024"
    , "    build-depends: base"
    ]

-- | A catalog whose groups decide their own outcome, so an example's verdict
-- is decided by the evidence it arranged rather than by a compiler.
fixtureCatalog ∷ String
fixtureCatalog =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"policy_version\": 1,"
    , "  \"policy_inputs\": [\"tools/validation/\", \".github/workflows/\"],"
    , "  \"non_affecting_paths\": [\"*.md\", \".gitignore\", \"LICENSE\"],"
    , "  \"generated_paths\": " ++ fixtureGenerated ++ ","
    , "  \"floor\": [\"build.pass\"],"
    , "  \"groups\": ["
    , "    {"
    , "      \"id\": \"build.pass\","
    , "      \"description\": \"A group that passes.\","
    , "      \"command\": [\"true\"],"
    , "      \"component\": null,"
    , "      \"inputs\": [],"
    , "      \"framework\": \"none\","
    , "      \"runner\": \"cpu\","
    , "      \"timeout_seconds\": 60,"
    , "      \"category\": \"build\","
    , "      \"optional\": false"
    , "    },"
    , "    {"
    , "      \"id\": \"test.fail\","
    , "      \"description\": \"A group that fails.\","
    , "      \"command\": [\"false\"],"
    , "      \"component\": null,"
    , "      \"inputs\": [\"src/\"],"
    , "      \"framework\": \"hspec\","
    , "      \"runner\": \"cpu\","
    , "      \"timeout_seconds\": 60,"
    , "      \"category\": \"test\","
    , "      \"optional\": false"
    , "    }"
    , "  ]"
    , "}"
    ]

-- | The option lines of one named step, as the workflow declares them.
stepOptions ∷ String → String → [String]
stepOptions workflow name =
  case break ((== ("- name: " ++ name)) . trim) (lines workflow) of
    (_, []) → error ("no step named " ++ show name ++ " in the workflow")
    (_, opening : rest) →
      let indent = length (takeWhile (== ' ') opening) + 2
          own line = null (trim line) || length (takeWhile (== ' ') line) >= indent
       in map trim (takeWhile own rest)

trim ∷ String → String
trim = dropWhile (== ' ') . reverse . dropWhile blank . reverse
  where
    blank character = character == ' ' || character == '\r'

-- | A job listing with one finished job in it, as GitHub returns one.
listing ∷ String
listing =
  unlines
    [ "{"
    , "  \"total_count\": 1,"
    , "  \"jobs\": ["
    , "    {"
    , "      \"name\": \"plan\","
    , "      \"status\": \"completed\","
    , "      \"conclusion\": \"success\","
    , "      \"created_at\": \"2026-09-11T12:00:00Z\","
    , "      \"started_at\": \"2026-09-11T12:00:20Z\","
    , "      \"completed_at\": \"2026-09-11T12:01:20Z\","
    , "      \"steps\": []"
    , "    }"
    , "  ]"
    , "}"
    ]
