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
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe, mapMaybe)
import Json (Json, asArray, asBool, asString, entryFor, field, parseJson)
import Sandbox
  ( fixtureGenerated
  , fixtureIgnore
  , git
  , run
  , sanitizedEnvironment
  , writeFixtureFile
  )
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
  , shouldSatisfy
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
  , runAttempt ∷ Int
  , runStatus ∷ String
  , runConclusion ∷ String
  , runWorkflow ∷ String
  , hasExpired ∷ Bool
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

    it "changes when an included path is renamed, and again when one is deleted" $
      withFixture $ \fixture → do
        before ← identityNow fixture
        void $ gitIn fixture ["mv", "src/note.txt", "src/renamed.txt"]
        void $ gitIn fixture ["commit", "-q", "-m", "Rename an included fixture"]
        -- The path is part of the digest, not merely its contents: a group
        -- reads a file at a location, and moving it is a different tree.
        renamed ← identityNow fixture
        renamed `shouldNotBe` before
        void $ gitIn fixture ["rm", "-q", "docs/consumed.md"]
        void $ gitIn fixture ["commit", "-q", "-m", "Delete a consumed document"]
        deleted ← identityNow fixture
        deleted `shouldNotBe` renamed

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

    it "moves for a validation tool a catalog tried to exempt from its own policy" $
      withFixture $ \fixture → do
        -- `policy_inputs` is catalog data, and the catalog is one of the files
        -- it governs. A candidate that drops the validation tools and the
        -- workflows from its own catalog must not thereby stop its edits to
        -- them from moving the policy the evidence was gathered under.
        change fixture "tools/validation/catalog.json" (fixtureCatalogWith 1 "[\"docs/consumed.md\"]")
        exemptedPolicy ← policyNow fixture
        exemptedInputs ← identityNow fixture
        change fixture "tools/validation/helper.py" "# a revised validation tool\n"
        movedTool ← policyNow fixture
        movedTool `shouldNotBe` exemptedPolicy
        identityNow fixture >>= \moved → moved `shouldNotBe` exemptedInputs
        afterTool ← identityNow fixture
        change fixture ".github/workflows/validation.yml" "name: validation\non: push\n"
        movedWorkflow ← policyNow fixture
        movedWorkflow `shouldNotBe` movedTool
        identityNow fixture >>= \moved → moved `shouldNotBe` afterTool

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
        recordText document "build.pass" "source_run_url" `shouldBe` Just (runUrl 41 1)
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

    it "refuses a receipt whose execution was prepared by something the plan does not declare" $
      withReceipt $ \fixture receipt → do
        -- The same command after a different preparation runs a different
        -- executable, so the receipt describes an execution this plan never
        -- asked for.
        prepared ←
          patched fixture receipt "prepared.json" "preparation"
            "{\"command\": [\"make\"], \"outcome\": \"passed\", \"exit_status\": 0, \
            \\"started_at\": \"2026-09-24T00:00:00.000Z\", \"ended_at\": \"2026-09-24T00:00:01.000Z\", \
            \\"duration_seconds\": 1, \"timeout_seconds\": 60, \"expiry\": null}"
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing prepared]
        refusal fixture plan "build.pass" "records a different preparation from the plan's"

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
        newer ← patched fixture broken "newer-failure.json" "source_run_url" (show (runUrl 42 1))
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
        rejectionText document "build.pass" "source_run_url" `shouldBe` Just (runUrl 42 1)

    it "never reaches past a newer expired artifact for an older pass" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install
          fixture
          plan
          "build.pass"
          [ (passing receipt) {artifactId = 7, createdAt = "2026-09-11T10:00:00Z", runIdentifier = 41}
          , (passing receipt)
              { artifactId = 9
              , createdAt = "2026-09-11T11:00:00Z"
              , runIdentifier = 42
              , hasExpired = True
              }
          ]
        -- An expired newer artifact is unusable, not absent. Filtering it away
        -- before the ordering would silently promote the pass behind it.
        refusal fixture plan "build.pass" "has expired"

    it "refuses a receipt produced by an attempt the run has since moved past" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [(passing receipt) {runAttempt = 2}]
        -- The receipt names attempt 1 while the run is on attempt 2. Whatever
        -- that newer attempt did, this artifact is not its evidence.
        refusal fixture plan "build.pass" "attempt 2"

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
        output `shouldContain` runUrl 41 1
        output `shouldNotContain` "worker engine was skipped"
        summary ← readFile (root fixture </> "summary.md")
        summary `shouldContain` "an earlier execution"
        summary `shouldContain` runUrl 41 1

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

    it "never looks up or records coverage for a group this platform does not build" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        (result, output, _) ← reuse fixture plan
        result `shouldBe` ExitSuccess
        -- Unselected work is not looked up, so the document neither reuses,
        -- refuses, nor reports an obstacle for it. An omission that arrived
        -- with a record beside it would read as coverage.
        output `shouldNotContain` "probe.elsewhere"
        document ← applicability fixture
        recordText document "probe.elsewhere" "source_run_url" `shouldBe` Nothing
        rejectionText document "probe.elsewhere" "source_run_url" `shouldBe` Nothing
        obstacles fixture >>= \recorded → recorded `shouldNotContain` "probe.elsewhere"

    it "refuses a record that offers an earlier execution of a group this platform does not build" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        looked ← reuse fixture plan
        exitOf looked `shouldBe` ExitSuccess
        -- A genuine record reattributed to the inapplicable group: evidence
        -- from a machine this plan is not about. Dropping it silently would
        -- leave the document looking like it vouched for something.
        reattribute fixture (root fixture </> "applicability.json") "probe.elsewhere"
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "workers do not build"

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

    it "refuses a record whose artifact names other evidence than the record's own" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        looked ← reuse fixture plan
        exitOf looked `shouldBe` ExitSuccess
        -- The artifact name is where the group and the identity are stored, so
        -- it is also where a record could be made to describe evidence it did
        -- not come from.
        rename fixture (root fixture </> "applicability.json") "receipt-test.fail-0123456789abcdef"
        (result, _, errors) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "is not named"

    it "refuses a record whose embedded receipt is not a whole receipt" $
      withReceipt $ \fixture receipt → do
        plan ← proseCandidate fixture
        install fixture plan "build.pass" [passing receipt]
        looked ← reuse fixture plan
        exitOf looked `shouldBe` ExitSuccess
        -- A reused execution is held to exactly the contract a fresh one is.
        -- A receipt truncated to the fields the aggregate happens to compare
        -- would otherwise satisfy a group precisely because it was old.
        truncate' fixture (root fixture </> "applicability.json") "plan_identity"
        (result, _, errors) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "plan_identity"

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

  describe "display evidence" $ do
    it "reuses an unchanged display group's receipt and skips the native worker, then executes it again for a changed native input" $
      withNativeReceipt $ \fixture earlier → do
        plan ← proseCandidate fixture
        install fixture plan "test.native" [passing earlier]
        (result, output, _) ← reuse fixture plan
        result `shouldBe` ExitSuccess
        output `shouldContain` "reused=test.native"
        output `shouldContain` "run-native=false"
        output `shouldContain` "groups-native=\n"
        reusedIdentity ← identityOf plan
        change fixture "native/note.txt" "a native input no run has validated\n"
        changed ← planFrom fixture (seeded fixture) "HEAD" "native-changed-plan.json"
        entryText changed "test.native" "reason" `shouldReturn` Just "affected"
        identityOf changed >>= (`shouldNotBe` reusedIdentity)
        install fixture changed "test.native" []
        (again, againOutput, _) ← reuse fixture changed
        again `shouldBe` ExitSuccess
        againOutput `shouldContain` "run-native=true"
        againOutput `shouldContain` "groups-native=test.native\n"

    it "refuses a display receipt produced on another operating system" $
      withNativeReceipt $ \fixture earlier → do
        elsewhere ← patched fixture earlier "native-darwin.json" "runner_os" "\"Darwin\""
        plan ← proseCandidate fixture
        install fixture plan "test.native" [passing elsewhere]
        refusal fixture plan "test.native" "a different runner_os"

    it "refuses a display receipt that another route produced" $
      withNativeReceipt $ \fixture earlier → do
        reclassed ← patched fixture earlier "native-cpu.json" "runner_class" "\"cpu\""
        plan ← proseCandidate fixture
        install fixture plan "test.native" [passing reclassed]
        refusal fixture plan "test.native" "records runner class 'cpu'"
        misrouted ← patched fixture earlier "native-engine.json" "worker" "\"engine\""
        install fixture plan "test.native" [passing misrouted]
        refusal fixture plan "test.native" "records worker 'engine', not 'native'"

    it "invalidates display evidence when the native dependency identity changes" $
      withNativeReceipt $ \fixture earlier → do
        change fixture "README.md" "a prose-only update\n"
        pinned ← planCandidateWith fixture ["--toolchain", "native-manifest=" ++ replicate 64 'a'] (seeded fixture) "HEAD" "HEAD" "pinned.json"
        rebuilt ← planCandidateWith fixture ["--toolchain", "native-manifest=" ++ replicate 64 'b'] (seeded fixture) "HEAD" "HEAD" "rebuilt.json"
        pinnedIdentity ← identityOf pinned
        identityOf rebuilt >>= (`shouldNotBe` pinnedIdentity)
        recorded ←
          patched fixture earlier "native-pinned.json" "toolchain"
            ("{\"ghc\": \"9.14.1\", \"native-manifest\": \"" ++ replicate 64 'a' ++ "\"}")
        install fixture rebuilt "test.native" [passing recorded]
        refusal fixture rebuilt "test.native" "a different toolchain"

    it "invalidates display evidence when the display setup changes" $
      withFixture $ \fixture → do
        change fixture "native/note.txt" "a native input\n"
        before ← identityNow fixture
        change fixture "display/setup.sh" "#!/bin/sh\necho a revised display\n"
        identityNow fixture >>= (`shouldNotBe` before)
        plan ← planFrom fixture "HEAD~1" "HEAD" "display-plan.json"
        entryText plan "test.native" "reason" `shouldReturn` Just "affected"
        entryText plan "test.fail" "reason" `shouldReturn` Just "unaffected"

    it "refuses a restated worker assignment that conflicts with the plan's" $
      withFixture $ \fixture → do
        plan ← proseCandidate fixture
        (result, _, errors) ← reuseWith fixture plan ["--worker", "native=test.fail"]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "conflicts with the plan's validated assignment"

    it "refuses a plan resolved without worker declarations" $
      withFixture $ \fixture → do
        change fixture "README.md" "a prose-only update\n"
        (planned, output, planErrors) ←
          run
            (environment fixture)
            (root fixture)
            "python3"
            [tools fixture </> "plan.py", "--base", seeded fixture, "--head", "HEAD", "--json"]
        (planned, planErrors) `shouldBe` (ExitSuccess, "")
        let inspection = root fixture </> "inspection.json"
        writeFile inspection output
        (result, _, errors) ← reuseWith fixture inspection []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "resolved without worker declarations"

  describe "the checked-in engine routing" $
    -- Each package suite's group took over coverage the root suite's group
    -- used to carry, so each is proven routed, required, and reusable on its
    -- own rather than through the root group's pass.
    forM_ ["test.foundation", "test.runtime", "test.glfw"] $ \packageGroup →
      it ("assigns " ++ packageGroup ++ " to the engine worker, requires it in the aggregate, and reuses its published receipt") $
        withCheckedInRouting $ \fixture workers → do
          -- The workflow publishes every engine group's receipt under the name
          -- the lookup asks for, so a group routed to the worker but never
          -- published could never be reused.
          workflow ← readFile =<< ((</> ".github/workflows/validation.yml") <$> getCurrentDirectory)
          change fixture "README.md" "a prose-only update\n"
          plan ← planRouted fixture workers "routed-plan.json"
          owned ← workerGroups plan "haskell-engine"
          owned `shouldContain` [packageGroup]
          forM_ owned $ \group → do
            workflow `shouldContain` ("name: receipt-" ++ group ++ "-${{ needs.plan.outputs.identity }}")
            workflow `shouldContain` ("path: receipts/" ++ group ++ ".json")
          entryText plan packageGroup "reason" `shouldReturn` Just "floor"
          entryText plan "test.engine" "reason" `shouldReturn` Just "floor"
          -- A worker owns every group it could ever be given; this prose-only
          -- candidate selects only the floor. The groups that actually execute
          -- are the intersection, so a mandatory engine group outside the floor
          -- is routed and published like the rest without being run here.
          selected ← selectedGroups plan
          let engine = filter (`elem` selected) owned
          engine `shouldContain` [packageGroup]

          -- Required: every other engine group passing does not stand in for it.
          writeFixtureFile (stubDirectory fixture) "artifacts.json" "{\"total_count\": 0, \"artifacts\": []}\n"
          exitOf <$> reuseWith fixture plan (restated workers) `shouldReturn` ExitSuccess
          forM_ (filter (/= packageGroup) engine) $ \group →
            exitOf <$> runGroup fixture plan group engineRoute `shouldReturn` ExitSuccess
          (missing, output, _) ← aggregate fixture plan (reportedSuccess workers)
          missing `shouldBe` ExitFailure 1
          output `shouldContain` packageGroup
          output `shouldContain` "neither an execution nor an applicable earlier receipt"
          exitOf <$> runGroup fixture plan packageGroup engineRoute `shouldReturn` ExitSuccess
          exitOf <$> aggregate fixture plan (reportedSuccess workers) `shouldReturn` ExitSuccess

          -- Reusable: a later prose-only candidate takes the published receipt.
          let earlier = root fixture </> "package-earlier.json"
          copyFile (receiptPath fixture packageGroup) earlier
          forM_ engine $ \group → removeFile (receiptPath fixture group)
          change fixture "README.md" "another prose-only update\n"
          later ← planRouted fixture workers "routed-later.json"
          install fixture later packageGroup [passing earlier]
          (looked, lookedUp, _) ← reuseWith fixture later (restated workers)
          looked `shouldBe` ExitSuccess
          lookedUp `shouldContain` ("reused=" ++ packageGroup)
          document ← applicability fixture
          recordText document packageGroup "source_run_url" `shouldBe` Just (runUrl 41 1)

  describe "the checked-in local-only probe classification" $ do
    forM_ ["tools/validation/helper.py", "tools/display/wayland.sh", "unknown/input.bin", "tools/display/x11.sh", "packages/scripting-lua/hazard/Main.hs", "packages/scripting-lua/linux/test/Test/Confinement/Limits.hs"] $ \path →
      it ("keeps local probes unrequested and unrouted after changing " ++ path) $
        withCheckedInRouting $ \fixture workers → do
          change fixture path "changed input\n"
          plan ← planRouted fixture workers "probes-unrequested-plan.json"
          selected ← selectedGroups plan
          owned ← concat <$> mapM (workerGroups plan) ["haskell-engine", "haskell-workflow", "glfw-native", "vulkan"]
          forM_ ["test.x11-helper", "test.wayland-helper", "test.lua-hazard", "test.lua-confinement-linux", "test.macos-confinement"] $ \group → do
            entryText plan group "reason" `shouldReturn` Just "optional-unrequested"
            selected `shouldNotContain` [group]
            owned `shouldNotContain` [group]

    forM_ ["test.x11-helper", "test.wayland-helper", "test.lua-hazard", "test.lua-confinement-linux", "test.macos-confinement"] $ \group →
      it ("selects " ++ group ++ " only through an explicit request with a local owner") $
        withCheckedInRouting $ \fixture workers → do
          change fixture "README.md" "revised ordinary prose\n"
          writeFixtureFile (root fixture) "body.txt" ("```validation-request\n" ++ group ++ "\n```\n")
          let local = workers ++ ["--worker", "local-probes=cpu:" ++ group]
          plan ← planRoutedWith fixture local ["--request-file", root fixture </> "body.txt"] "probe-local-plan.json"
          entryText plan group "reason" `shouldReturn` Just "requested"
          selectedGroups plan >>= (`shouldContain` [group])
          workerGroups plan "local-probes" `shouldReturn` [group]

  describe "the checked-in routing of the Vulkan groups" $ do
    it "routes both Vulkan groups to the one worker providing both classes, and publishes each receipt" $
      withCheckedInRouting $ \fixture workers → do
        workflow ← readFile =<< ((</> ".github/workflows/validation.yml") <$> getCurrentDirectory)
        change fixture "tools/vulkan/run.sh" "a changed runner\n"
        plan ← planRouted fixture workers "vulkan-routing-plan.json"
        workerGroups plan "vulkan" `shouldReturn` ["test.vulkan-headless", "test.vulkan-native"]
        entryText plan "test.vulkan-headless" "runner" `shouldReturn` Just "cpu"
        entryText plan "test.vulkan-native" "runner" `shouldReturn` Just "display"
        forM_ ["test.vulkan-headless", "test.vulkan-native"] $ \group → do
          entryText plan group "reason" `shouldReturn` Just "affected"
          workflow `shouldContain` ("name: receipt-" ++ group ++ "-${{ needs.plan.outputs.identity }}")
          workflow `shouldContain` ("path: receipts/" ++ group ++ ".json")

    it "selects the headless group when a headless suite's source changes, and leaves it off a prose change" $
      withCheckedInRouting $ \fixture workers → do
        -- Planned against the seed each time, so the prose plan comes first:
        -- the source change's range includes it.
        change fixture "README.md" "a prose-only update\n"
        prose ← planRouted fixture workers "vulkan-prose-plan.json"
        entryText prose "test.vulkan-headless" "reason" `shouldReturn` Just "unaffected"
        entryText prose "test.vulkan-native" "reason" `shouldReturn` Just "unaffected"
        change fixture "hetoimasia-gpu-vulkan-glfw/integration-tests/Main.hs" "module Main (main) where\n"
        affected ← planRouted fixture workers "vulkan-headless-plan.json"
        entryText affected "test.vulkan-headless" "reason" `shouldReturn` Just "affected"

    it "executes the native group's preparation before its command, on the Vulkan worker" $
      withCheckedInRouting $ \fixture workers → do
        change fixture "tools/vulkan/run.sh" "a changed runner\n"
        plan ← planRouted fixture workers "vulkan-execution-plan.json"
        let route = ["--worker", "vulkan", "--runner-class", "cpu", "--runner-class", "display"]
        exitOf <$> runGroup fixture plan "test.vulkan-native" route `shouldReturn` ExitSuccess
        receipt ← readFile (receiptPath fixture "test.vulkan-native")
        receipt `shouldContain` "\"preparation\": {"
        receipt `shouldContain` "\"runner_class\": \"display\""

  describe "the checked-in routing of the GPU model group" $ do
    -- `test.vulkan` is the first mandatory group that is neither in the floor
    -- nor owned by a worker of its own, so the floor examples above cannot
    -- simply be extended to cover it: they assert a `floor` reason it does not
    -- have. Routing, selection, required evidence, and reuse are each proved
    -- here on their own instead, with its non-floor status held to throughout.
    it "routes it to the engine worker and publishes its receipt, while leaving it out of the floor" $
      withCheckedInRouting $ \fixture workers → do
        workflow ← readFile =<< ((</> ".github/workflows/validation.yml") <$> getCurrentDirectory)
        change fixture "README.md" "a prose-only update\n"
        plan ← planRouted fixture workers "vulkan-prose-plan.json"
        owned ← workerGroups plan "haskell-engine"
        owned `shouldContain` [vulkanGroup]
        -- Routed but never published would be reusable by nobody.
        workflow `shouldContain` ("name: receipt-" ++ vulkanGroup ++ "-${{ needs.plan.outputs.identity }}")
        workflow `shouldContain` ("path: receipts/" ++ vulkanGroup ++ ".json")
        -- And a prose-only candidate does not carry it, which is what being
        -- outside the mandatory floor means.
        entryText plan vulkanGroup "reason" `shouldReturn` Just "unaffected"
        selected ← selectedGroups plan
        selected `shouldNotContain` [vulkanGroup]

    it "selects it when its own package changes, requires its evidence, and reuses its published receipt" $
      withCheckedInRouting $ \fixture workers → do
        change fixture vulkanSource "-- the model suite's own source\n"
        plan ← planRouted fixture workers "vulkan-affected-plan.json"
        entryText plan vulkanGroup "reason" `shouldReturn` Just "affected"
        selected ← selectedGroups plan
        selected `shouldContain` [vulkanGroup]

        -- Required: every other selected engine group passing does not stand in
        -- for it, and the aggregate says which group is missing.
        writeFixtureFile (stubDirectory fixture) "artifacts.json" "{\"total_count\": 0, \"artifacts\": []}\n"
        exitOf <$> reuseWith fixture plan (restated workers) `shouldReturn` ExitSuccess
        owned ← workerGroups plan "haskell-engine"
        let engine = filter (`elem` selected) owned
        engine `shouldContain` [vulkanGroup]
        forM_ (filter (/= vulkanGroup) engine) $ \group →
          exitOf <$> runGroup fixture plan group engineRoute `shouldReturn` ExitSuccess
        (missing, output, _) ← aggregate fixture plan (reportedSuccess workers)
        missing `shouldBe` ExitFailure 1
        output `shouldContain` vulkanGroup
        output `shouldContain` "neither an execution nor an applicable earlier receipt"
        exitOf <$> runGroup fixture plan vulkanGroup engineRoute `shouldReturn` ExitSuccess
        exitOf <$> aggregate fixture plan (reportedSuccess workers) `shouldReturn` ExitSuccess

        -- Reusable: a later candidate whose only further change is prose still
        -- selects it, against the same inputs, and takes the published receipt.
        let earlier = root fixture </> "vulkan-earlier.json"
        copyFile (receiptPath fixture vulkanGroup) earlier
        forM_ engine $ \group → removeFile (receiptPath fixture group)
        change fixture "README.md" "a prose-only update\n"
        later ← planRouted fixture workers "vulkan-later-plan.json"
        entryText later vulkanGroup "reason" `shouldReturn` Just "affected"
        install fixture later vulkanGroup [passing earlier]
        (looked, lookedUp, _) ← reuseWith fixture later (restated workers)
        looked `shouldBe` ExitSuccess
        lookedUp `shouldContain` ("reused=" ++ vulkanGroup)
        document ← applicability fixture
        recordText document vulkanGroup "source_run_url" `shouldBe` Just (runUrl 41 1)

    it "selects it when a pull request asks for it by name, without promoting it to the floor" $
      withCheckedInRouting $ \fixture workers → do
        change fixture "README.md" "a prose-only update\n"
        writeFixtureFile (root fixture) "body.txt" ("```validation-request\n" ++ vulkanGroup ++ "\n```\n")
        plan ←
          planRoutedWith
            fixture
            workers
            ["--request-file", root fixture </> "body.txt"]
            "vulkan-requested-plan.json"
        entryText plan vulkanGroup "reason" `shouldReturn` Just "requested"
        selectedGroups plan >>= (`shouldContain` [vulkanGroup])
        -- The request is why it runs; the floor is still what it is not in.
        entryText plan "test.engine" "reason" `shouldReturn` Just "floor"

-- | The portable GPU model group, its package's suite source directory inside
-- the routing fixture, and one file in it. The fixture builds a minimal package
-- per component the checked-in catalog names, so this path is the one that
-- catalog's `component` produces.
vulkanGroup ∷ String
vulkanGroup = "test.vulkan"

vulkanSource ∷ FilePath
vulkanSource = "hetoimasia-gpu-vulkan-model" </> "gpu-model-tests" </> "Model.hs"

-- ---------------------------------------------------------------------------
-- Driving the tools

planFrom ∷ Fixture → String → String → FilePath → IO FilePath
planFrom fixture base head' = planCandidate fixture base head' head'

-- | Resolve a plan with the real planner, under the pinned platform every
-- receipt in these examples is compared against.
planCandidate ∷ Fixture → String → String → String → FilePath → IO FilePath
planCandidate fixture = planCandidateWith fixture []

-- | The same, with extra planner arguments such as another toolchain entry.
planCandidateWith ∷ Fixture → [String] → String → String → String → FilePath → IO FilePath
planCandidateWith fixture extra base head' candidate name = do
  (result, output, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      ( [ tools fixture </> "plan.py"
        , "--base", base
        , "--head", head'
        , "--candidate", candidate
        , "--toolchain", "ghc=9.14.1"
        , "--runner-os", "Linux"
        , "--json"
        ]
          ++ fixtureWorkers
          ++ extra
      )
  (result, errors) `shouldBe` (ExitSuccess, "")
  let target = root fixture </> name
  writeFile target output
  pure target

-- | A prose-only commit on the seeded tree, planned as this candidate.
proseCandidate ∷ Fixture → IO FilePath
proseCandidate fixture = do
  change fixture "README.md" "a prose-only update\n"
  planFrom fixture (seeded fixture) "HEAD" "plan.json"

-- | The fixture's workers: one per group, the display group on the only worker
-- declaring the display runner class.
fixtureWorkers ∷ [String]
fixtureWorkers =
  ["--worker", "engine=cpu:build.pass", "--worker", "extra=cpu:test.fail", "--worker", "native=display:test.native"]

-- | The worker and runner class 'fixtureWorkers' assigns a group to.
routeOf ∷ String → [String]
routeOf group = case group of
  "build.pass" → ["--worker", "engine", "--runner-class", "cpu"]
  "test.native" → ["--worker", "native", "--runner-class", "display"]
  _ → ["--worker", "extra", "--runner-class", "cpu"]

runGroup ∷ Fixture → FilePath → String → [String] → IO (ExitCode, String, String)
runGroup fixture plan group extra =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ( [ "-I"
      , tools fixture </> "run.py"
      , group
      , "--plan", plan
      , "--receipts", receiptsDirectory fixture
      , "--toolchain", "ghc=9.14.1"
      , "--source-run-url", runUrl 41 1
      ]
        ++ (if "--worker" `elem` extra then extra else routeOf group ++ extra)
    )

reuse ∷ Fixture → FilePath → IO (ExitCode, String, String)
reuse fixture plan = reuseWith fixture plan ["--worker", "engine=build.pass", "--worker", "extra=test.fail"]

-- | The lookup with whichever restated workers an example passes.
reuseWith ∷ Fixture → FilePath → [String] → IO (ExitCode, String, String)
reuseWith fixture plan workers =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ( [ tools fixture </> "reuse.py"
      , "--plan", plan
      , "--repo", "owner/project"
      , "--output", root fixture </> "applicability.json"
      , "--gh", stubDirectory fixture </> "gh"
      ]
        ++ workers
    )

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
        ++ (if "--worker" `elem` extra then extra else extra ++ reported)
    )
  where
    reported = ["--worker", "engine=success", "--worker", "extra=success", "--worker", "native=success"]

-- | Look one group up, expecting a refusal that names a reason.
refusal ∷ Fixture → FilePath → String → String → IO ()
refusal fixture plan group reason = do
  (result, output, _) ← reuse fixture plan
  result `shouldBe` ExitSuccess
  [words (drop 8 line) | line ← lines output, take 8 line == ("execute=" ∷ String)]
    `shouldSatisfy` any (group `elem`)
  document ← applicability fixture
  rejectionReason document group `shouldContain` reason

exitOf ∷ (ExitCode, String, String) → ExitCode
exitOf (result, _, _) = result

-- ---------------------------------------------------------------------------
-- The stub GitHub

-- | A receipt's own attribution names the run *and* the attempt, because a
-- run's generic page always shows whichever attempt is newest.
runUrl ∷ Int → Int → String
runUrl identifier attempt = runPage identifier ++ "/attempts/" ++ show attempt

runPage ∷ Int → String
runPage identifier = "https://github.invalid/owner/project/actions/runs/" ++ show identifier

passing ∷ FilePath → Evidence
passing = Evidence 7 "2026-09-11T10:00:00Z" 41 1 "completed" "success" ".github/workflows/validation.yml" False

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
    ++ "\", \"expired\": "
    ++ (if hasExpired item then "true" else "false")
    ++ ", \"created_at\": \""
    ++ createdAt item
    ++ "\", \"workflow_run\": {\"id\": "
    ++ show (runIdentifier item)
    ++ "}}"

runDocument ∷ Evidence → String
runDocument item =
  "{\"id\": "
    ++ show (runIdentifier item)
    ++ ", \"run_attempt\": "
    ++ show (runAttempt item)
    ++ ", \"status\": "
    ++ show (runStatus item)
    ++ ", \"conclusion\": "
    ++ (if null (runConclusion item) then "null" else show (runConclusion item))
    ++ ", \"path\": "
    ++ show (runWorkflow item)
    ++ ", \"html_url\": "
    ++ show (runPage (runIdentifier item))
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

-- | Rename the artifact every record in an applicability document came from.
rename ∷ Fixture → FilePath → String → IO ()
rename fixture path name = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json, sys\n\
        \path, name = sys.argv[1:3]\n\
        \document = json.load(open(path, encoding='utf-8'))\n\
        \for record in document['reused']:\n\
        \    record['artifact']['name'] = name\n\
        \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
      , path
      , name
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

-- | Drop one field from every receipt an applicability document carries.
-- | Reattribute every record in an applicability document to another group,
-- moving the three places that name it — the record, the receipt it embeds,
-- and the artifact it came from — so the document is well formed and claims a
-- group it should not.
reattribute ∷ Fixture → FilePath → String → IO ()
reattribute fixture path group = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json, sys\n\
        \path, group = sys.argv[1:3]\n\
        \document = json.load(open(path, encoding='utf-8'))\n\
        \for record in document['reused']:\n\
        \    record['group'] = group\n\
        \    record['receipt']['group'] = group\n\
        \    record['artifact']['name'] = 'receipt-' + group + '-' + document['input_identity']\n\
        \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
      , path
      , group
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

truncate' ∷ Fixture → FilePath → String → IO ()
truncate' fixture path key = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json, sys\n\
        \path, key = sys.argv[1:3]\n\
        \document = json.load(open(path, encoding='utf-8'))\n\
        \for record in document['reused']:\n\
        \    record['receipt'].pop(key, None)\n\
        \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
      , path
      , key
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

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

-- | The same for the display group: a native input change an earlier run of the
-- display worker validated.
withNativeReceipt ∷ (Fixture → FilePath → IO a) → IO a
withNativeReceipt action = withFixture $ \fixture → do
  change fixture "native/note.txt" "the native input that earlier run validated\n"
  plan ← planFrom fixture (seeded fixture) "HEAD" "native-seed-plan.json"
  (result, _, errors) ← runGroup fixture plan "test.native" []
  (result, errors) `shouldBe` (ExitSuccess, "")
  let earlier = root fixture </> "native-earlier.json"
  copyFile (receiptPath fixture "test.native") earlier
  removeFile (receiptPath fixture "test.native")
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
  [ (".gitignore", fixtureIgnore)
  , ("cabal.project", "packages:\n  .\n")
  , ("demo.cabal", demoPackage)
  , ("app/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("src/note.txt", "a fixture the failing group consumes\n")
  , ("docs/consumed.md", "a document the failing group consumes\n")
  , ("native/note.txt", "an input the display group consumes\n")
  , ("display/setup.sh", "#!/bin/sh\necho a display\n")
  , ("README.md", "ordinary prose\n")
  , (".github/workflows/validation.yml", "name: validation\n")
  , ("tools/validation/helper.py", "# a validation tool beside the catalog\n")
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
fixtureCatalog policy = fixtureCatalogWith policy "[\"tools/validation/\", \".github/workflows/\"]"

-- | A catalog that declares whichever policy inputs an example needs, so one
-- can declare none of the roots the planner requires anyway.
fixtureCatalogWith ∷ Int → String → String
fixtureCatalogWith policy inputs =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"policy_version\": " ++ show policy ++ ","
    , "  \"policy_inputs\": " ++ inputs ++ ","
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
    , "      \"inputs\": [\"src/\", \"docs/consumed.md\"],"
    , "      \"framework\": \"hspec\","
    , "      \"runner\": \"cpu\","
    , "      \"timeout_seconds\": 60,"
    , "      \"category\": \"test\","
    , "      \"optional\": false"
    , "    },"
    , "    {"
    , "      \"id\": \"test.native\","
    , "      \"description\": \"A group that needs a display.\","
    , "      \"command\": [\"true\"],"
    , "      \"component\": null,"
    , "      \"inputs\": [\"native/\", \"display/\"],"
    , "      \"framework\": \"hspec\","
    , "      \"runner\": \"display\","
    , "      \"timeout_seconds\": 60,"
    , "      \"category\": \"test\","
    , "      \"optional\": false"
    , "    },"
    -- A group whose command targets components no machine here builds. No real
    -- platform reports itself as Plan9, so every plan below omits it as
    -- platform-inapplicable however the host reports itself.
    , "    {"
    , "      \"id\": \"probe.elsewhere\","
    , "      \"description\": \"A group this platform does not build.\","
    , "      \"command\": [\"true\"],"
    , "      \"component\": null,"
    , "      \"inputs\": [\"src/\"],"
    , "      \"framework\": \"hspec\","
    , "      \"runner\": \"cpu\","
    , "      \"timeout_seconds\": 60,"
    , "      \"category\": \"probe\","
    , "      \"optional\": false,"
    , "      \"platforms\": [\"Plan9\"]"
    , "    }"
    , "  ]"
    , "}"
    ]

-- ---------------------------------------------------------------------------
-- The checked-in routing

-- | A fixture carrying this checkout's own catalog, with each group's command
-- replaced by @true@ so an example decides outcomes without a compiler, one
-- minimal package per component the catalog names, and the worker declarations
-- the validation workflow's plan step passes.
withCheckedInRouting ∷ (Fixture → [String] → IO a) → IO a
withCheckedInRouting action = do
  checkout ← getCurrentDirectory
  workflow ← readFile (checkout </> ".github/workflows/validation.yml")
  let workers = concat [["--worker", declaration] | declaration ← mapMaybe planDeclaration (lines workflow)]
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-routing" $ \directory → do
    let pinned = ("RUNNER_OS", "Linux") : filter ((/= "RUNNER_OS") . fst) settings
        fixture = Fixture directory (checkout </> "tools/validation") pinned ""
    writeFixtureFile directory ".gitignore" fixtureIgnore
    writeFixtureFile directory "README.md" "ordinary prose\n"
    writeFixtureFile directory ".github/workflows/validation.yml" workflow
    (seeded', _, errors) ←
      run
        pinned
        directory
        "python3"
        [ "-c"
        , "import json, os, sys\n\
          \catalog = json.load(open(sys.argv[1], encoding='utf-8'))\n\
          \packages = {}\n\
          \for group in catalog['groups']:\n\
          \    group['command'] = ['true']\n\
          \    if group.get('preparation'):\n\
          \        group['preparation']['command'] = ['true']\n\
          \    if group['component'] not in (None, 'all'):\n\
          \        package, kind, name = group['component'].split(':')\n\
          \        packages.setdefault(package, []).append((kind, name))\n\
          \catalog['generated_paths'] = json.loads(sys.argv[2])\n\
          \os.makedirs('tools/validation', exist_ok=True)\n\
          \json.dump(catalog, open('tools/validation/catalog.json', 'w'), indent=2)\n\
          \stanza = {'test': 'test-suite', 'exe': 'executable', 'lib': 'library'}\n\
          \for package, components in packages.items():\n\
          \    os.makedirs(package, exist_ok=True)\n\
          \    with open(os.path.join(package, package + '.cabal'), 'w') as description:\n\
          \        description.write('cabal-version: 3.16\\nname: ' + package + '\\nversion: 0.1.0.0\\nbuild-type: Simple\\n')\n\
          \        for kind, name in components:\n\
          \            description.write('\\n' + stanza[kind] + ' ' + name + '\\n    main-is: Main.hs\\n    hs-source-dirs: ' + name + '\\n    default-language: GHC2024\\n    build-depends: base\\n')\n\
          \open('cabal.project', 'w').write('packages:\\n' + ''.join('  ' + package + '\\n' for package in packages))\n"
        , checkout </> "tools/validation/catalog.json"
        , fixtureGenerated
        ]
    (seeded', errors) `shouldBe` (ExitSuccess, "")
    void $ git pinned directory ["init", "-b", "master"]
    void $ git pinned directory ["add", "."]
    void $ git pinned directory ["commit", "-q", "-m", "Seed the checked-in routing"]
    seed ← revision fixture "HEAD"
    createDirectoryIfMissing True (receiptsDirectory fixture)
    let stub = stubDirectory fixture </> "gh"
    writeFixtureFile (stubDirectory fixture) "gh" stubScript
    permissions ← getPermissions stub
    setPermissions stub (setOwnerExecutable True permissions)
    action fixture {seeded = seed} workers

-- | One worker declaration of the plan step, such as
-- @haskell-engine=cpu:build.all,test.engine@. The aggregate step's result
-- declarations interpolate a job result instead, so they never match.
planDeclaration ∷ String → Maybe String
planDeclaration line = case breakOn "--worker \"" line of
  Just rest
    | '$' `notElem` declaration && ':' `elem` declaration → Just declaration
    where
      declaration = takeWhile (/= '"') rest
  _ → Nothing
  where
    breakOn needle haystack
      | null haystack = Nothing
      | take (length needle) haystack == needle = Just (drop (length needle) haystack)
      | otherwise = breakOn needle (drop 1 haystack)

-- | The engine worker's route, as the workflow's engine job runs a group.
engineRoute ∷ [String]
engineRoute = ["--worker", "haskell-engine", "--runner-class", "cpu"]

-- | The plan's workers as the reuse lookup restates them: groups only.
restated ∷ [String] → [String]
restated = map (\argument → if "=" `isInfixOf` argument then dropClass argument else argument)
  where
    dropClass declaration =
      let (name, rest) = break (== '=') declaration
       in name ++ "=" ++ drop 1 (dropWhile (/= ':') rest)

-- | Every declared worker reporting success, as the aggregate step reports
-- job results.
reportedSuccess ∷ [String] → [String]
reportedSuccess workers =
  concat [["--worker", takeWhile (/= '=') declaration ++ "=success"] | declaration ← workers, '=' `elem` declaration]

-- | Resolve a plan routed to the given worker declarations.
planRouted ∷ Fixture → [String] → FilePath → IO FilePath
planRouted fixture workers = planRoutedWith fixture workers []

-- | The same, with extra planner arguments such as a pull-request body.
planRoutedWith ∷ Fixture → [String] → [String] → FilePath → IO FilePath
planRoutedWith fixture workers extra name = do
  (result, output, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      ( [ tools fixture </> "plan.py"
        , "--base", seeded fixture
        , "--head", "HEAD"
        , "--candidate", "HEAD"
        , "--toolchain", "ghc=9.14.1"
        , "--runner-os", "Linux"
        , "--json"
        ]
          ++ extra
          ++ workers
      )
  (result, errors) `shouldBe` (ExitSuccess, "")
  let target = root fixture </> name
  writeFile target output
  pure target

-- | The groups a plan selected, in its own order.
selectedGroups ∷ FilePath → IO [String]
selectedGroups plan = do
  document ← parseJson <$> readFile plan
  maybe (fail ("no selected groups in " ++ plan)) pure $
    document >>= field "selected" >>= asArray >>= traverse asString

workerGroups ∷ FilePath → String → IO [String]
workerGroups plan worker = do
  document ← parseJson <$> readFile plan
  maybe (fail ("no worker " ++ worker ++ " in " ++ plan)) pure $
    document >>= field "workers" >>= entryFor "name" worker >>= field "groups" >>= asArray >>= traverse asString
