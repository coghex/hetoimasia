-- | Hspec coverage for the validation runner and the aggregate.
--
-- Every example drives the real @tools/validation/run.py@ and
-- @tools/validation/aggregate.py@ against a temporary Git repository, a fixture
-- catalog, and a plan resolved by the real planner, so the assertions describe
-- the published verdict's actual failure contract rather than a restatement of
-- it. The fixture groups run @true@, @false@, and a sleeping shell so an
-- execution's outcome is decided by the test rather than by a compiler.
module Execution (spec) where

import Control.Concurrent (threadDelay)
import Control.Monad (void)
import Data.Maybe (isNothing)
import Json (Json (..), asBool, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)

data Fixture = Fixture
  { root ∷ FilePath
  , tools ∷ FilePath
  , environment ∷ [(String, String)]
  , seeded ∷ String
  , initial ∷ String
  }

spec ∷ Spec
spec = describe "Validation execution" $ do
  describe "the runner" $ do
    it "records a failing command as a non-zero receipt" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        plan ← planAgainst fixture (seeded fixture)
        head' ← revision fixture "HEAD"
        (result, _, _) ← runGroup fixture "test.fail" plan []
        result `shouldBe` ExitFailure 1
        receipt ← readReceipt fixture "test.fail"
        stringField receipt "outcome" `shouldBe` Just "failed"
        numberField receipt "exit_status" `shouldBe` Just 1
        stringField receipt "group" `shouldBe` Just "test.fail"
        stringField receipt "head_commit" `shouldBe` Just head'
        -- The contract later slices consume, asserted by name: a whole-document
        -- comparison would churn on every addition without proving any of them
        -- is present.
        filter (isNothing . stringField receipt) requiredReceiptFields `shouldBe` []
        numberField receipt "duration_seconds" `shouldSatisfy` maybe False (>= 0)

    it "distinguishes the pull request's head from the commit that executed" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        head' ← revision fixture "HEAD"
        plan ← planAgainst fixture (seeded fixture)
        -- A pull request is validated on an integration candidate that is
        -- neither endpoint, so the receipt records both rather than implying
        -- that the head itself ran.
        (result, _, _) ←
          runGroup
            fixture
            "build.pass"
            plan
            ["--executed-commit", integrationCommit, "--executed-tree", integrationTree]
        result `shouldBe` ExitSuccess
        receipt ← readReceipt fixture "build.pass"
        stringField receipt "head_commit" `shouldBe` Just head'
        stringField receipt "executed_commit" `shouldBe` Just integrationCommit
        stringField receipt "executed_tree" `shouldBe` Just integrationTree

    it "enforces the catalog timeout and reaps the command's descendants" $
      withFixture $ \fixture → do
        change fixture "slow/note.txt" "revised slow input\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, _, _) ← runGroup fixture "smoke.slow" plan []
        result `shouldBe` ExitFailure 1
        receipt ← readReceipt fixture "smoke.slow"
        stringField receipt "outcome" `shouldBe` Just "timeout"
        -- The sleeping grandchild outlives its shell unless the runner ends the
        -- whole process group. Its death is asynchronous, so this polls for it
        -- within a bound instead of assuming an instant the kernel never
        -- promised.
        child ← readFile (root fixture </> "child.pid")
        reaped fixture (takeWhile (/= '\n') child) 50 `shouldReturn` True

    it "kills a descendant that ignores the termination signal" $
      withFixture $ \fixture → do
        change fixture "stubborn/note.txt" "revised stubborn input\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, _, _) ← runGroup fixture "smoke.stubborn" plan []
        result `shouldBe` ExitFailure 1
        receipt ← readReceipt fixture "smoke.stubborn"
        stringField receipt "outcome" `shouldBe` Just "timeout"
        -- The shell exits on SIGTERM while the child it started ignores the
        -- signal entirely, so the leader's exit says nothing about the group.
        -- Only a kill aimed at the group reaches this process.
        child ← readFile (root fixture </> "child.pid")
        reaped fixture (takeWhile (/= '\n') child) 50 `shouldReturn` True

    it "refuses a group the plan explained away, leaving no receipt behind" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, _, errors) ← runGroup fixture "test.fail" plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "did not select"
        doesFileExist (receiptPath fixture "test.fail") `shouldReturn` False

  describe "the aggregate" $ do
    it "fails a selected group that produced no receipt" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "build.pass"
        output `shouldContain` "neither an execution nor an applicable earlier receipt"

    it "passes omitted unaffected and optional groups without receipts" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitSuccess
        output `shouldContain` "unaffected"
        output `shouldContain` "optional-unrequested"
        output `shouldContain` "verdict: passed"

    it "fails one failing group even when every other group passed" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        plan ← planAgainst fixture (seeded fixture)
        (passed, _, _) ← runGroup fixture "build.pass" plan []
        passed `shouldBe` ExitSuccess
        (failed, _, _) ← runGroup fixture "test.fail" plan []
        failed `shouldBe` ExitFailure 1
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "test.fail"
        output `shouldContain` "verdict: failed"

    it "refuses a receipt that names another plan" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        current ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" current []
        executed `shouldBe` ExitSuccess
        -- The same head, compared against a different base, is a different
        -- question and therefore a different plan.
        other ← planInto fixture (initial fixture) "other-plan.json"
        (result, output, _) ← aggregate fixture other []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "names plan"

    it "refuses a receipt that names another head" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        patchReceipt fixture "build.pass" "head_commit" (initial fixture)
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "names head"

    it "refuses a malformed receipt rather than reading past it" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        writeFile (receiptPath fixture "build.pass") "{ not a receipt\n"
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "malformed"

    it "refuses a plan that registers no groups" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "empty.json" emptyPlan
        (result, _, errors) ← aggregate fixture (root fixture </> "empty.json") []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "registers no groups"

    it "refuses a plan whose selected list omits a group it flagged" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        -- Dropping the floor from `selected` while its own flag stays true
        -- would let every worker skip it and the aggregate excuse it.
        patchPlan fixture plan "selected" "[]"
        (result, _, errors) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "does not match the groups it flags as selected"

    it "refuses a plan that names a selected group twice" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        patchPlan fixture plan "selected" "[\"build.pass\", \"build.pass\"]"
        (result, _, errors) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "more than once"

    it "reports a malformed plan as a diagnostic rather than a verdict" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "broken.json" "{ not a plan\n"
        (result, _, errors) ← aggregate fixture (root fixture </> "broken.json") []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "not valid JSON"

    it "fails a worker that was cancelled while its groups were selected" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan ["--worker", "floor=cancelled:build.pass"]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "worker floor was cancelled"

    it "fails a worker that concluded failure even with every receipt passing" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        -- A job can fail after its groups passed, so a passing receipt in an
        -- artifact cannot vouch for the job that produced it.
        (result, output, _) ← aggregate fixture plan ["--worker", "floor=failure:build.pass"]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "worker floor was failure"

    it "fails a worker that was skipped while its groups were selected" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan ["--worker", "floor=skipped:build.pass"]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "worker floor was skipped"

    it "accepts a worker skipped because the plan selected none of its groups" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, _, _) ←
          aggregate
            fixture
            plan
            [ "--worker"
            , "floor=success:build.pass"
            , "--worker"
            , "extra=skipped:test.fail,smoke.slow"
            ]
        result `shouldBe` ExitSuccess

  describe "publication freshness" $ do
    it "refuses to answer for a head the pull request has moved past" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan ["--expect-head", initial fixture]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "head is now"

    it "refuses to satisfy a request edited after the plan was resolved" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        writeFixtureFile (root fixture) "body.txt" (requestBlock ["probe.optional"])
        (result, output, _) ←
          aggregate fixture plan ["--expect-request-file", root fixture </> "body.txt"]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "now asks for"

    it "accepts a plan that still describes the pull request" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        head' ← revision fixture "HEAD"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        writeFixtureFile (root fixture) "body.txt" "Ordinary prose with no request.\n"
        (result, _, _) ←
          aggregate
            fixture
            plan
            [ "--expect-head"
            , head'
            , "--expect-base"
            , seeded fixture
            , "--expect-request-file"
            , root fixture </> "body.txt"
            ]
        result `shouldBe` ExitSuccess

  describe "the comparison range" $ do
    it "compares a pull request across its merge base" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        head' ← revision fixture "HEAD"
        (result, output, _) ←
          resolveRange fixture ["--event", "pull_request", "--base-sha", seeded fixture, "--head-sha", head']
        result `shouldBe` ExitSuccess
        output `shouldContain` ("base=" ++ seeded fixture)
        output `shouldContain` ("head=" ++ head')

    it "compares a push from the commit it actually started at" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        head' ← revision fixture "HEAD"
        (result, output, _) ←
          resolveRange fixture ["--event", "push", "--before", seeded fixture, "--after", head']
        result `shouldBe` ExitSuccess
        output `shouldContain` ("base=" ++ seeded fixture)

    it "compares a history-replacing push against the history it replaced" $
      withFixture $ \fixture → do
        -- `before` changed a consumed source; `after` abandons that line and
        -- edits prose instead. Their merge base predates both, so a range taken
        -- from it sees only the prose and would omit the group whose input the
        -- push reverted. The event's own `before` is what makes the removal
        -- visible.
        change fixture "src/note.txt" "a source change this push discards\n"
        before ← revision fixture "HEAD"
        void $ git (environment fixture) (root fixture) ["reset", "-q", "--hard", seeded fixture]
        change fixture "README.md" "prose only\n"
        after ← revision fixture "HEAD"
        (result, output, _) ←
          resolveRange fixture ["--event", "push", "--before", before, "--after", after]
        result `shouldBe` ExitSuccess
        output `shouldContain` ("base=" ++ before)
        -- Planned from that range the discarded source counts, so the group
        -- that consumes it is selected rather than quietly dropped.
        plan ← planInto fixture before "divergent.json"
        selectionOf plan "test.fail" `shouldReturn` Just (Selection "affected" True True)
        -- Planned from the merge base instead, the same push looks like prose.
        merged ← planInto fixture (seeded fixture) "merged.json"
        selectionOf merged "test.fail" `shouldReturn` Just (Selection "unaffected" False False)

    it "refuses a push whose starting commit is unavailable" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        head' ← revision fixture "HEAD"
        (missing, _, absent) ←
          resolveRange fixture ["--event", "push", "--before", "", "--after", head']
        missing `shouldBe` ExitFailure 2
        absent `shouldContain` "names no starting commit"
        (unknown, _, errors) ←
          resolveRange
            fixture
            ["--event", "push", "--before", "6c1f2a0d4b8e3f57a9c0d1e2b3a4f5061728394a", "--after", head']
        unknown `shouldBe` ExitFailure 2
        errors `shouldContain` "starting commit"

  describe "the planner's own failure" $
    it "produces a diagnostic and no plan when the request is invalid" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        writeFixtureFile (root fixture) "body.txt" (requestBlock ["group.absent"])
        (result, _, errors) ←
          run
            (environment fixture)
            (root fixture)
            "python3"
            [ tools fixture </> "plan.py"
            , "--base"
            , seeded fixture
            , "--head"
            , "HEAD"
            , "--request-file"
            , root fixture </> "body.txt"
            , "--json"
            ]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "group.absent"

-- | Selection facts for one catalog group: its reason, whether it was
-- selected, and whether its own inputs changed.
data Selection = Selection String Bool Bool
  deriving (Eq, Show)

selectionOf ∷ FilePath → String → IO (Maybe Selection)
selectionOf plan identifier = do
  document ← parseJson <$> readFile plan
  pure $ do
    entry ← document >>= field "groups" >>= entryFor "id" identifier
    reason ← field "reason" entry >>= asString
    selected ← field "selected" entry >>= asBool
    changed ← field "inputs_changed" entry >>= asBool
    pure (Selection reason selected changed)

-- | Every field a receipt must carry for a later slice to attribute it.
requiredReceiptFields ∷ [String]
requiredReceiptFields =
  [ "group"
  , "outcome"
  , "started_at"
  , "ended_at"
  , "plan_identity"
  , "head_commit"
  , "executed_commit"
  , "executed_tree"
  , "runner_os"
  , "runner_arch"
  , "input_identity"
  , "policy_version"
  , "source_run_url"
  ]

-- | Stand-ins for a merge candidate that is neither endpoint of the plan.
integrationCommit, integrationTree ∷ String
integrationCommit = "1111111111111111111111111111111111111111"
integrationTree = "2222222222222222222222222222222222222222"

-- ---------------------------------------------------------------------------
-- Driving the tools

planAgainst ∷ Fixture → String → IO FilePath
planAgainst fixture base = planInto fixture base "plan.json"

-- | Resolve a plan with the real planner and keep it where the runner and the
-- aggregate both read it from.
planInto ∷ Fixture → String → FilePath → IO FilePath
planInto fixture base name = do
  (result, output, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [tools fixture </> "plan.py", "--base", base, "--head", "HEAD", "--json"]
  (result, errors) `shouldBe` (ExitSuccess, "")
  let target = root fixture </> name
  writeFile target output
  pure target

runGroup ∷ Fixture → String → FilePath → [String] → IO (ExitCode, String, String)
runGroup fixture group plan extra =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ( [ tools fixture </> "run.py"
      , group
      , "--plan"
      , plan
      , "--receipts"
      , receiptsDirectory fixture
      ]
        ++ extra
    )

resolveRange ∷ Fixture → [String] → IO (ExitCode, String, String)
resolveRange fixture arguments =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ((tools fixture </> "range.py") : "--repo-root" : root fixture : arguments)

aggregate ∷ Fixture → FilePath → [String] → IO (ExitCode, String, String)
aggregate fixture plan extra =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ( [ tools fixture </> "aggregate.py"
      , "--plan"
      , plan
      , "--receipts"
      , receiptsDirectory fixture
      ]
        ++ extra
    )

-- ---------------------------------------------------------------------------
-- Reading and tampering with receipts

receiptsDirectory ∷ Fixture → FilePath
receiptsDirectory fixture = root fixture </> "receipts"

receiptPath ∷ Fixture → String → FilePath
receiptPath fixture group = receiptsDirectory fixture </> (group ++ ".json")

readReceipt ∷ Fixture → String → IO (Maybe Json)
readReceipt fixture group = parseJson <$> readFile (receiptPath fixture group)

stringField ∷ Maybe Json → String → Maybe String
stringField document name = document >>= field name >>= asString

numberField ∷ Maybe Json → String → Maybe Double
numberField document name = case document >>= field name of
  Just (JNumber value) → Just value
  _ → Nothing

-- | Replace one string field, so an otherwise genuine receipt can claim the
-- wrong provenance without hand-writing the whole document.
patchReceipt ∷ Fixture → String → String → String → IO ()
patchReceipt fixture group name value = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json,sys\n\
        \path, key, value = sys.argv[1:4]\n\
        \document = json.load(open(path, encoding='utf-8'))\n\
        \document[key] = value\n\
        \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
      , receiptPath fixture group
      , name
      , value
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

-- | Replace one top-level field of a plan with a literal JSON document, so an
-- otherwise genuine plan can contradict itself.
patchPlan ∷ Fixture → FilePath → String → String → IO ()
patchPlan fixture plan name value = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json,sys\n\
        \path, key, value = sys.argv[1:4]\n\
        \document = json.load(open(path, encoding='utf-8'))\n\
        \document[key] = json.loads(value)\n\
        \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
      , plan
      , name
      , value
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

-- | A structurally valid plan that registers nothing. Every worker would skip
-- and every group would be vacuously accounted for.
emptyPlan ∷ String
emptyPlan =
  unlines
    [ "{"
    , "  \"schema_version\": 2,"
    , "  \"policy_version\": \"eeee\","
    , "  \"catalog_policy_version\": 1,"
    , "  \"input_identity\": \"ffff\","
    , "  \"runner_os\": \"Linux\","
    , "  \"toolchain\": {},"
    , "  \"base\": {\"commit\": \"aaaa\", \"tree\": \"bbbb\"},"
    , "  \"head\": {\"commit\": \"cccc\", \"tree\": \"dddd\"},"
    , "  \"candidate\": {\"commit\": \"cccc\", \"tree\": \"dddd\"},"
    , "  \"request\": {\"ids\": [], \"all_hspec\": false, \"resolved\": []},"
    , "  \"groups\": [],"
    , "  \"selected\": []"
    , "}"
    ]

-- | Whether a process identifier has stopped existing, polled within a bound.
reaped ∷ Fixture → String → Int → IO Bool
reaped _ _ 0 = pure False
reaped fixture pid attempts = do
  (result, _, _) ← run (environment fixture) (root fixture) "kill" ["-0", pid]
  case result of
    ExitFailure _ → pure True
    ExitSuccess → threadDelay 100000 >> reaped fixture pid (attempts - 1)

-- ---------------------------------------------------------------------------
-- The fixture repository

withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-execution" $ \directory → do
    let fixture =
          Fixture directory (checkout </> "tools/validation") settings "" ""
    void $ git settings directory ["init", "-b", "master"]
    writeFixtureFile directory "README.md" "fixture\n"
    void $ git settings directory ["add", "."]
    void $ git settings directory ["commit", "-q", "-m", "Seed a project without validation"]
    firstCommit ← revision fixture "HEAD"
    mapM_ (uncurry (writeFixtureFile directory)) fixtureFiles
    void $ git settings directory ["add", "."]
    void $ git settings directory ["commit", "-q", "-m", "Seed the fixture project"]
    secondCommit ← revision fixture "HEAD"
    createDirectoryIfMissing True (directory </> "receipts")
    action fixture {seeded = secondCommit, initial = firstCommit}

revision ∷ Fixture → String → IO String
revision fixture name =
  takeWhile (/= '\n') <$> git (environment fixture) (root fixture) ["rev-parse", name]

change ∷ Fixture → FilePath → String → IO ()
change fixture path contents = do
  writeFixtureFile (root fixture) path contents
  void $ git (environment fixture) (root fixture) ["add", "-A", "."]
  void $ git (environment fixture) (root fixture) ["commit", "-q", "-m", "Change " ++ path]

requestBlock ∷ [String] → String
requestBlock entries =
  unlines (["Some pull request prose.", "", "```validation-request"] ++ entries ++ ["```"])

fixtureFiles ∷ [(FilePath, String)]
fixtureFiles =
  [ ("cabal.project", "packages:\n  .\n")
  , ("demo.cabal", demoPackage)
  , ("app/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("src/note.txt", "a source the failing group consumes\n")
  , ("slow/note.txt", "an input the slow group consumes\n")
  , ("stubborn/note.txt", "an input the stubborn group consumes\n")
  , ("probe/note.txt", "an input the optional group consumes\n")
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

-- | A catalog whose commands decide their own outcome, so an example can
-- exercise a pass, a failure, and an exhausted budget without a compiler.
fixtureCatalog ∷ String
fixtureCatalog =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"policy_version\": 1,"
    , "  \"policy_inputs\": [\"tools/validation/catalog.json\"],"
    , "  \"non_affecting_paths\": [\"*.md\", \".gitignore\", \"LICENSE\"],"
    , "  \"floor\": [\"build.pass\"],"
    , "  \"groups\": ["
    , groupDocument "build.pass" "[\"true\"]" "[]" "none" "build" "60" "false" ++ ","
    , groupDocument "test.fail" "[\"false\"]" "[\"src/\"]" "hspec" "test" "60" "false" ++ ","
    , groupDocument "smoke.slow" slowCommand "[\"slow/\"]" "none" "smoke" "1" "false" ++ ","
    , groupDocument "smoke.stubborn" stubbornCommand "[\"stubborn/\"]" "none" "smoke" "1" "false" ++ ","
    , groupDocument "probe.optional" "[\"true\"]" "[\"probe/\"]" "hspec" "probe" "60" "true"
    , "  ]"
    , "}"
    ]

-- | A shell that backgrounds a long sleep and records it, so an example can ask
-- whether the timeout reached the descendant rather than only the shell.
slowCommand ∷ String
slowCommand = "[\"sh\", \"-c\", \"sleep 300 & echo $! > child.pid; wait\"]"

-- | A shell that exits on SIGTERM while the child it started ignores it, so an
-- example can tell a group-wide kill apart from one aimed at the leader.
stubbornCommand ∷ String
stubbornCommand =
  "[\"sh\", \"-c\", \"(trap '' TERM; sleep 300) & echo $! > child.pid; wait\"]"

groupDocument ∷ String → String → String → String → String → String → String → String
groupDocument identifier command inputs framework category timeout optional =
  init $
    unlines
      [ "    {"
      , "      \"id\": \"" ++ identifier ++ "\","
      , "      \"description\": \"Fixture group " ++ identifier ++ ".\","
      , "      \"command\": " ++ command ++ ","
      , "      \"component\": null,"
      , "      \"inputs\": " ++ inputs ++ ","
      , "      \"framework\": \"" ++ framework ++ "\","
      , "      \"runner\": \"cpu\","
      , "      \"timeout_seconds\": " ++ timeout ++ ","
      , "      \"category\": \"" ++ category ++ "\","
      , "      \"optional\": " ++ optional
      , "    }"
      ]
