-- | Hspec coverage for candidate identity and for reusing earlier evidence.
--
-- Every example drives the real @tools/validation/plan.py@, @run.py@,
-- @reuse.py@, and @aggregate.py@ against a temporary Git repository and a
-- fixture catalog. The GitHub side is a stub @gh@ answering from files beside
-- it, which is what makes the cases that matter reachable at all: a run still
-- in progress, a newer failure sitting in front of an older pass, and an API
-- that does not answer do not happen on demand against a real repository.
module Reuse (spec) where

import Control.Monad (forM_, void)
import Data.Maybe (fromMaybe, mapMaybe)
import Json (Json, asArray, asBool, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , getCurrentDirectory
  , getPermissions
  , removeFile
  , setOwnerExecutable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
  ( Spec
  , describe
  , it
  , shouldBe
  , shouldContain
  , shouldNotBe
  , shouldNotContain
  , shouldReturn
  )

data Fixture = Fixture
  { root ∷ FilePath
  , tools ∷ FilePath
  , environment ∷ [(String, String)]
  , seeded ∷ String
  }

-- | One artifact the stub GitHub offers, with the run that produced it.
data Evidence = Evidence
  { artifactId ∷ Int
  , createdAt ∷ String
  , runIdentifier ∷ Int
  , runStatus ∷ String
  , runConclusion ∷ String
  , runWorkflow ∷ String
  , receiptFile ∷ FilePath
  }

spec ∷ Spec
spec = describe "Validation evidence reuse" $ do
  describe "candidate identity" $ do
    it "is unchanged by a prose edit, a prose rename, and a prose deletion" $
      withFixture $ \fixture → do
        before ← identityNow fixture
        change fixture "README.md" "revised prose\n"
        identityNow fixture `shouldReturn` before
        void $ gitIn fixture ["mv", "README.md", "READING.md"]
        void $ gitIn fixture ["commit", "-q", "-m", "Rename prose"]
        identityNow fixture `shouldReturn` before
        void $ gitIn fixture ["rm", "-q", "READING.md"]
        void $ gitIn fixture ["commit", "-q", "-m", "Delete prose"]
        identityNow fixture `shouldReturn` before

    it "changes for a source, a package description, the project file, a fixture, and a consumed document" $
      withFixture $ \fixture → do
        before ← identityNow fixture
        forM_
          [ ("app/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = mempty\n")
          , ("demo.cabal", demoPackage ++ "    ghc-options: -Wall\n")
          , ("cabal.project", "packages:\n  ./\n")
          , ("src/note.txt", "a revised fixture\n")
          , ("docs/consumed.md", "a revised consumed document\n")
          ]
          $ \(path, contents) → do
            change fixture path contents
            after ← identityNow fixture
            (path, after) `shouldNotBe` (path, before)

    it "changes when an included path's file mode changes" $
      withFixture $ \fixture → do
        before ← identityNow fixture
        void $ gitIn fixture ["update-index", "--chmod=+x", "src/note.txt"]
        void $ gitIn fixture ["commit", "-q", "-m", "Make the fixture executable"]
        -- The content digest is untouched; only the mode moved. An execution
        -- still sees a different tree, so evidence cannot cross it.
        after ← identityNow fixture
        after `shouldNotBe` before

    it "changes the policy identity, and the input identity with it, when the catalog or a workflow changes" $
      withFixture $ \fixture → do
        beforePolicy ← policyNow fixture
        beforeInputs ← identityNow fixture
        change fixture ".github/workflows/validation.yml" "name: validation\non: push\n"
        movedWorkflow ← policyNow fixture
        movedWorkflow `shouldNotBe` beforePolicy
        change fixture "tools/validation/catalog.json" (fixtureCatalog 2)
        movedCatalog ← policyNow fixture
        movedCatalog `shouldNotBe` movedWorkflow
        -- The policy is folded into the input identity, so evidence gathered
        -- under the classification that was replaced cannot be inherited.
        afterInputs ← identityNow fixture
        afterInputs `shouldNotBe` beforeInputs

    it "survives a code change followed by a prose-only push, while selection still reports the code" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "a revised fixture\n"
        coded ← identityNow fixture
        change fixture "README.md" "revised prose\n"
        prosed ← identityNow fixture
        -- This is the case reuse exists for. The contribution diff against the
        -- merge base still contains the code change, so the group stays
        -- selected with its inputs changed; the candidate tree is nevertheless
        -- exactly the one the earlier run already validated.
        prosed `shouldBe` coded
        plan ← planFrom fixture (seeded fixture) "HEAD" "contribution.json"
        entryText plan "test.fail" "reason" `shouldReturn` Just "affected"
        entryFlag plan "test.fail" "inputs_changed" `shouldReturn` Just True

    it "changes when the integration candidate merges an upstream code change" $
      withFixture $ \fixture → do
        change fixture "README.md" "a prose-only contribution\n"
        contribution ← revision fixture "HEAD"
        void $ gitIn fixture ["checkout", "-q", "-b", "upstream", seeded fixture]
        change fixture "src/note.txt" "an upstream fixture change\n"
        void $ gitIn fixture ["checkout", "-q", "master"]
        void $ gitIn fixture ["merge", "-q", "--no-edit", "upstream"]
        candidate ← revision fixture "HEAD"
        -- The contribution is prose, but the tree the workers execute carries
        -- the upstream change. Identity is taken from that tree, never from
        -- the pull request's own head.
        contributed ← identityOf =<< planFrom fixture (seeded fixture) contribution "head.json"
        integrated ←
          identityOf =<< planCandidate fixture (seeded fixture) contribution candidate "candidate.json"
        integrated `shouldNotBe` contributed

  describe "the reuse lookup" $ do
    it "accepts a finished passing receipt for identical inputs and skips the worker that owned it" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        (result, output, _) ← reuse fixture plan
        result `shouldBe` ExitSuccess
        output `shouldContain` "reused=build.pass"
        output `shouldContain` "execute=test.fail"
        output `shouldContain` "run-engine=false"
        output `shouldContain` "run-extra=true"
        document ← applicability fixture
        recordText document "build.pass" "source_run_url" `shouldBe` Just (runUrl 41)
        -- The record preserves the earlier run's own commit rather than
        -- restating this candidate's, so a reused result stays attributable to
        -- the execution that actually happened.
        executed ← textField "executed_commit" receipt
        recordText document "build.pass" "executed_commit" `shouldBe` Just executed

    it "refuses a receipt recorded under another toolchain" $
      withReceipt $ \fixture receipt → do
        other ← patched fixture receipt "other-toolchain.json" "toolchain" "{\"ghc\": \"9.10.1\"}"
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing other]
        refusal fixture plan "build.pass" "a different toolchain"

    it "refuses a receipt whose execution exited non-zero" $
      withReceipt $ \fixture receipt → do
        failed ← patched fixture receipt "failed.json" "outcome" "\"failed\""
        broken ← patched fixture failed "failed.json" "exit_status" "1"
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing broken]
        refusal fixture plan "build.pass" "records failed"

    it "refuses a receipt gathered under another input identity" $
      withReceipt $ \fixture receipt → do
        strange ← patched fixture receipt "strange.json" "input_identity" "\"0123456789abcdef\""
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing strange]
        refusal fixture plan "build.pass" "a different input_identity"

    it "refuses a receipt whose run never finished, and one its run cancelled" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [(passing receipt) {runStatus = "in_progress", runConclusion = ""}]
        refusal fixture plan "build.pass" "rather than completed"
        install fixture plan "build.pass" [(passing receipt) {runConclusion = "cancelled"}]
        refusal fixture plan "build.pass" "concluded 'cancelled'"

    it "refuses an artifact produced by another workflow" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [(passing receipt) {runWorkflow = ".github/workflows/other.yml"}]
        refusal fixture plan "build.pass" "other.yml"

    it "never reaches past a newer failure for an older pass" $
      withReceipt $ \fixture receipt → do
        failed ← patched fixture receipt "newer-failure.json" "outcome" "\"failed\""
        broken ← patched fixture failed "newer-failure.json" "exit_status" "1"
        newer ← patched fixture broken "newer-failure.json" "source_run_url" (show (runUrl 42))
        plan ← proseCandidate fixture
        install
          fixture
          plan
          "build.pass"
          [ (passing receipt) {artifactId = 7, createdAt = "2026-09-11T10:00:00Z", runIdentifier = 41}
          , (passing newer) {artifactId = 9, createdAt = "2026-09-11T11:00:00Z", runIdentifier = 42}
          ]
        (result, output, _) ← reuse fixture plan
        result `shouldBe` ExitSuccess
        output `shouldContain` "execute=build.pass"
        document ← applicability fixture
        -- The older pass is genuine and would have been accepted on its own.
        -- It must stay unused, and the failure it sits behind must stay named.
        rejectionReason document "build.pass" `shouldContain` "records failed"
        recordText document "build.pass" "source_run_url" `shouldBe` Nothing
        rejectionText document "build.pass" "source_run_url" `shouldBe` Just (runUrl 42)

    it "returns the candidate to execution when the lookup cannot answer" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        -- Everything the stub could answer with is removed, so the lookup
        -- fails rather than reporting an absence.
        removeFile (stubDirectory fixture </> "artifacts.json")
        (result, output, _) ← reuse fixture plan
        result `shouldBe` ExitSuccess
        output `shouldContain` "reused="
        output `shouldContain` "execute=build.pass test.fail"
        obstacles fixture >>= \recorded → recorded `shouldContain` "could not be looked up"

  describe "the aggregate and reused evidence" $ do
    it "satisfies a covered group, names its earlier run, and excuses the worker that owned it" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        looked ← reuse fixture plan
        exitOf looked `shouldBe` ExitSuccess
        (executed, _, _) ← runGroup fixture plan "test.fail" []
        executed `shouldBe` ExitFailure 1
        (result, output, _) ←
          aggregate
            fixture
            plan
            ["--worker", "engine=skipped:build.pass", "--worker", "extra=success:test.fail"]
        -- The reused group is satisfied and its worker is excused; the group
        -- that had to execute still decides the verdict on its own merits.
        result `shouldBe` ExitFailure 1
        output `shouldContain` "reused"
        output `shouldContain` runUrl 41
        output `shouldNotContain` "worker engine was skipped"
        summary ← readFile (root fixture </> "summary.md")
        summary `shouldContain` "an earlier execution"
        summary `shouldContain` runUrl 41

    it "fails a selected group with neither an execution nor a record" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        looked ← reuse fixture plan
        exitOf looked `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "test.fail"
        output `shouldContain` "neither an execution nor an applicable earlier receipt"

    it "refuses a record resolved for another plan" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        looked ← reuse fixture plan
        exitOf looked `shouldBe` ExitSuccess
        -- The same candidate compared against a different base is a different
        -- question, and a record resolved for one cannot excuse the other.
        other ← planFrom fixture "HEAD~1" "HEAD" "other.json"
        (result, output, _) ← aggregate fixture other []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "was resolved for plan"

    it "refuses a malformed record rather than reading past it" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        looked ← reuse fixture plan
        exitOf looked `shouldBe` ExitSuccess
        writeFile (root fixture </> "applicability.json") "{ not a record\n"
        (result, _, errors) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "not valid JSON"

    it "lets a fresh failure stand rather than the older pass behind it" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        looked ← reuse fixture plan
        exitOf looked `shouldBe` ExitSuccess
        -- The worker executed the covered group anyway and it failed. The
        -- applicability record must not overrule what just happened.
        (executed, _, _) ← runGroup fixture plan "build.pass" []
        executed `shouldBe` ExitSuccess
        patchInPlace fixture (receiptPath fixture "build.pass") "outcome" "\"failed\""
        patchInPlace fixture (receiptPath fixture "build.pass") "exit_status" "1"
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "build.pass"
        output `shouldContain` "exited 1"

-- ---------------------------------------------------------------------------
-- Driving the tools

planFrom ∷ Fixture → String → String → FilePath → IO FilePath
planFrom fixture base head' = planCandidate fixture base head' head'

-- | Resolve a plan with the real planner, under the pinned platform every
-- receipt in these examples is compared against.
planCandidate ∷ Fixture → String → String → String → FilePath → IO FilePath
planCandidate fixture base head' candidate name = do
  (result, output, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ tools fixture </> "plan.py"
      , "--base", base
      , "--head", head'
      , "--candidate", candidate
      , "--toolchain", "ghc=9.12.2"
      , "--runner-os", "Linux"
      , "--json"
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")
  let target = root fixture </> name
  writeFile target output
  pure target

-- | A prose-only commit on the seeded tree, planned as this candidate.
proseCandidate ∷ Fixture → IO FilePath
proseCandidate fixture = do
  change fixture "README.md" "a prose-only update\n"
  planFrom fixture (seeded fixture) "HEAD" "plan.json"

runGroup ∷ Fixture → FilePath → String → [String] → IO (ExitCode, String, String)
runGroup fixture plan group extra =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ( [ tools fixture </> "run.py"
      , group
      , "--plan", plan
      , "--receipts", receiptsDirectory fixture
      , "--toolchain", "ghc=9.12.2"
      , "--source-run-url", runUrl 41
      ]
        ++ extra
    )

reuse ∷ Fixture → FilePath → IO (ExitCode, String, String)
reuse fixture plan =
  run
    (environment fixture)
    (root fixture)
    "python3"
    [ tools fixture </> "reuse.py"
    , "--plan", plan
    , "--repo", "owner/project"
    , "--output", root fixture </> "applicability.json"
    , "--gh", stubDirectory fixture </> "gh"
    , "--worker", "engine=build.pass"
    , "--worker", "extra=test.fail"
    ]

aggregate ∷ Fixture → FilePath → [String] → IO (ExitCode, String, String)
aggregate fixture plan extra =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ( [ tools fixture </> "aggregate.py"
      , "--plan", plan
      , "--receipts", receiptsDirectory fixture
      , "--applicability", root fixture </> "applicability.json"
      , "--summary", root fixture </> "summary.md"
      ]
        ++ extra
    )

-- | Look one group up, expecting a refusal that names a reason.
refusal ∷ Fixture → FilePath → String → String → IO ()
refusal fixture plan group reason = do
  (result, output, _) ← reuse fixture plan
  result `shouldBe` ExitSuccess
  output `shouldContain` ("execute=" ++ group)
  document ← applicability fixture
  rejectionReason document group `shouldContain` reason

exitOf ∷ (ExitCode, String, String) → ExitCode
exitOf (result, _, _) = result

-- ---------------------------------------------------------------------------
-- The stub GitHub

runUrl ∷ Int → String
runUrl identifier = "https://github.invalid/owner/project/actions/runs/" ++ show identifier

passing ∷ FilePath → Evidence
passing = Evidence 7 "2026-09-11T10:00:00Z" 41 "completed" "success" ".github/workflows/validation.yml"

stubDirectory ∷ Fixture → FilePath
stubDirectory fixture = root fixture </> "gh-stub"

-- | Offer these artifacts for one group, each with the run that produced it.
install ∷ Fixture → FilePath → String → [Evidence] → IO ()
install fixture plan group evidence = do
  identity ← identityOf plan
  writeFixtureFile
    (stubDirectory fixture)
    "artifacts.json"
    ( "{\"total_count\": "
        ++ show (length evidence)
        ++ ", \"artifacts\": ["
        ++ commas [artifactDocument item group identity | item ← evidence]
        ++ "]}\n"
    )
  forM_ evidence $ \item → do
    writeFixtureFile
      (stubDirectory fixture)
      ("run-" ++ show (runIdentifier item) ++ ".json")
      (runDocument item)
    archive fixture (receiptFile item) (group ++ ".json") ("artifact-" ++ show (artifactId item) ++ ".zip")

artifactDocument ∷ Evidence → String → String → String
artifactDocument item group identity =
  "{\"id\": "
    ++ show (artifactId item)
    ++ ", \"name\": \"receipt-"
    ++ group
    ++ "-"
    ++ identity
    ++ "\", \"expired\": false, \"created_at\": \""
    ++ createdAt item
    ++ "\", \"workflow_run\": {\"id\": "
    ++ show (runIdentifier item)
    ++ "}}"

runDocument ∷ Evidence → String
runDocument item =
  "{\"id\": "
    ++ show (runIdentifier item)
    ++ ", \"status\": "
    ++ show (runStatus item)
    ++ ", \"conclusion\": "
    ++ (if null (runConclusion item) then "null" else show (runConclusion item))
    ++ ", \"path\": "
    ++ show (runWorkflow item)
    ++ ", \"html_url\": "
    ++ show (runUrl (runIdentifier item))
    ++ ", \"repository\": {\"full_name\": \"owner/project\"}}\n"

-- | Pack one receipt into an artifact archive the stub can serve.
archive ∷ Fixture → FilePath → String → FilePath → IO ()
archive fixture source member name = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import sys, zipfile\n\
        \target, source, member = sys.argv[1:4]\n\
        \with zipfile.ZipFile(target, 'w') as archive:\n\
        \    archive.write(source, member)\n"
      , stubDirectory fixture </> name
      , source
      , member
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

-- | A stand-in for `gh api` that answers from files beside itself.
stubScript ∷ String
stubScript =
  unlines
    [ "#!/bin/sh"
    , "directory=\"$(dirname \"$0\")\""
    , "path=\"$2\""
    , "case \"$path\" in"
    , "  */zip) rest=\"${path%/zip}\"; file=\"$directory/artifact-${rest##*/}.zip\" ;;"
    , "  */actions/runs/*) file=\"$directory/run-${path##*/}.json\" ;;"
    , "  */actions/artifacts*) file=\"$directory/artifacts.json\" ;;"
    , "  *) echo \"gh stub: unexpected request $path\" >&2; exit 1 ;;"
    , "esac"
    , "if [ ! -f \"$file\" ]; then"
    , "  echo \"gh stub: no canned answer at $file\" >&2"
    , "  exit 1"
    , "fi"
    , "cat \"$file\""
    ]

-- ---------------------------------------------------------------------------
-- Reading the documents

identityNow ∷ Fixture → IO String
identityNow fixture = planFrom fixture (seeded fixture) "HEAD" "identity.json" >>= identityOf

policyNow ∷ Fixture → IO String
policyNow fixture = planFrom fixture (seeded fixture) "HEAD" "identity.json" >>= textField "policy_version"

identityOf ∷ FilePath → IO String
identityOf = textField "input_identity"

textField ∷ String → FilePath → IO String
textField name path = do
  document ← parseJson <$> readFile path
  maybe (fail ("no " ++ name ++ " in " ++ path)) pure (document >>= field name >>= asString)

entryText ∷ FilePath → String → String → IO (Maybe String)
entryText plan group name = do
  document ← parseJson <$> readFile plan
  pure (document >>= field "groups" >>= entryFor "id" group >>= field name >>= asString)

entryFlag ∷ FilePath → String → String → IO (Maybe Bool)
entryFlag plan group name = do
  document ← parseJson <$> readFile plan
  pure (document >>= field "groups" >>= entryFor "id" group >>= field name >>= asBool)

applicability ∷ Fixture → IO (Maybe Json)
applicability fixture = parseJson <$> readFile (root fixture </> "applicability.json")

recordText ∷ Maybe Json → String → String → Maybe String
recordText document group name =
  document >>= field "reused" >>= entryFor "group" group >>= field name >>= asString

rejectionText ∷ Maybe Json → String → String → Maybe String
rejectionText document group name =
  document >>= field "rejected" >>= entryFor "group" group >>= field name >>= asString

rejectionReason ∷ Maybe Json → String → String
rejectionReason document group = fromMaybe "" (rejectionText document group "reason")

obstacles ∷ Fixture → IO String
obstacles fixture = do
  document ← applicability fixture
  pure (unwords (mapMaybe asString (fromMaybe [] (document >>= field "obstacles" >>= asArray))))

-- | Replace one field of a receipt with a literal JSON value, writing the
-- result where the caller asked for it.
patched ∷ Fixture → FilePath → FilePath → String → String → IO FilePath
patched fixture source name key value = do
  let target = root fixture </> name
  patch fixture source target key value
  pure target

patchInPlace ∷ Fixture → FilePath → String → String → IO ()
patchInPlace fixture path key value = patch fixture path path key value

patch ∷ Fixture → FilePath → FilePath → String → String → IO ()
patch fixture source target key value = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json, sys\n\
        \source, target, key, value = sys.argv[1:5]\n\
        \document = json.load(open(source, encoding='utf-8'))\n\
        \document[key] = json.loads(value)\n\
        \json.dump(document, open(target, 'w', encoding='utf-8'))\n"
      , source
      , target
      , key
      , value
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

receiptsDirectory ∷ Fixture → FilePath
receiptsDirectory fixture = root fixture </> "receipts"

receiptPath ∷ Fixture → String → FilePath
receiptPath fixture group = receiptsDirectory fixture </> (group ++ ".json")

commas ∷ [String] → String
commas = foldr1Comma
  where
    foldr1Comma [] = ""
    foldr1Comma [single] = single
    foldr1Comma (first : rest) = first ++ ", " ++ foldr1Comma rest

-- ---------------------------------------------------------------------------
-- The fixture repository

-- | A fixture whose seeded tree has already been executed once, so an example
-- has a genuine receipt to offer as an earlier run's evidence.
withReceipt ∷ (Fixture → FilePath → IO a) → IO a
withReceipt action = withFixture $ \fixture → do
  -- The earlier run validated a real code change, so every later candidate in
  -- these examples still contributes that code relative to the merge base.
  -- That is the shape the whole slice exists for, and it must not be one where
  -- the contribution happens to be prose all the way down.
  change fixture "src/note.txt" "the fixture that earlier run validated\n"
  plan ← planFrom fixture (seeded fixture) "HEAD" "seed-plan.json"
  (result, _, errors) ← runGroup fixture plan "build.pass" []
  (result, errors) `shouldBe` (ExitSuccess, "")
  let earlier = root fixture </> "earlier.json"
  copyFile (receiptPath fixture "build.pass") earlier
  -- The fresh receipt is cleared away: what these examples offer is an earlier
  -- run's artifact, never a file this run happens to have left behind.
  removeFile (receiptPath fixture "build.pass")
  action fixture earlier

withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-reuse" $ \directory → do
    -- The planner declares the platform a receipt must have been produced on,
    -- and the runner records the one it ran on. Pinning both here is what
    -- keeps these examples about evidence rather than about this machine.
    let pinned = ("RUNNER_OS", "Linux") : filter ((/= "RUNNER_OS") . fst) settings
        fixture = Fixture directory (checkout </> "tools/validation") pinned ""
    void $ git pinned directory ["init", "-b", "master"]
    mapM_ (uncurry (writeFixtureFile directory)) fixtureFiles
    writeFixtureFile directory "tools/validation/catalog.json" (fixtureCatalog 1)
    void $ git pinned directory ["add", "."]
    void $ git pinned directory ["commit", "-q", "-m", "Seed the fixture project"]
    seed ← revision fixture "HEAD"
    createDirectoryIfMissing True (receiptsDirectory fixture)
    let stub = stubDirectory fixture </> "gh"
    writeFixtureFile (stubDirectory fixture) "gh" stubScript
    permissions ← getPermissions stub
    setPermissions stub (setOwnerExecutable True permissions)
    action fixture {seeded = seed}

gitIn ∷ Fixture → [String] → IO String
gitIn fixture = git (environment fixture) (root fixture)

revision ∷ Fixture → String → IO String
revision fixture name = takeWhile (/= '\n') <$> gitIn fixture ["rev-parse", name]

-- | Commit exactly one path, so the scratch files these examples write beside
-- the repository never reach the tree identity is taken from.
change ∷ Fixture → FilePath → String → IO ()
change fixture path contents = do
  writeFixtureFile (root fixture) path contents
  void $ gitIn fixture ["add", "--", path]
  void $ gitIn fixture ["commit", "-q", "-m", "Change " ++ path]

fixtureFiles ∷ [(FilePath, String)]
fixtureFiles =
  [ ("cabal.project", "packages:\n  .\n")
  , ("demo.cabal", demoPackage)
  , ("app/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("src/note.txt", "a fixture the failing group consumes\n")
  , ("docs/consumed.md", "a document the failing group consumes\n")
  , ("README.md", "ordinary prose\n")
  , (".github/workflows/validation.yml", "name: validation\n")
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

-- | A catalog whose groups decide their own outcome, and whose policy inputs
-- are the validation tools and the workflows, as this repository's own are.
fixtureCatalog ∷ Int → String
fixtureCatalog policy =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"policy_version\": " ++ show policy ++ ","
    , "  \"policy_inputs\": [\"tools/validation/\", \".github/workflows/\"],"
    , "  \"non_affecting_paths\": [\"*.md\", \".gitignore\", \"LICENSE\"],"
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
    , "      \"inputs\": [\"src/\", \"docs/consumed.md\"],"
    , "      \"framework\": \"hspec\","
    , "      \"runner\": \"cpu\","
    , "      \"timeout_seconds\": 60,"
    , "      \"category\": \"test\","
    , "      \"optional\": false"
    , "    }"
    , "  ]"
    , "}"
    ]
