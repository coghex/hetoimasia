-- | Hspec coverage for binding a carried approval to a proven approved revision.
--
-- The replay proves that a push is exactly Git's clean merge of its starting
-- point with the base, and the tree comparison proves that a push moved
-- nothing; neither proves that the *starting point* was ever entitled to the
-- approval it carries. A delayed dismissal for an earlier push refuses to
-- touch a superseded head — correctly — and leaves @reviewed:approve@
-- standing on a head nobody proved, which the next push then inherits.
--
-- Every example here builds that situation for real: a temporary Git history
-- with the heads the sequence names, a comment feed holding the canonical
-- review markers and carry records the workflow would find, the jobs listings
-- of the runs those records name, and the shipped @review_replay.py@,
-- @review_provenance.py@, and @review_gate.py@ composed exactly as
-- @review-gate.yml@ composes them. No replay verdict is fabricated
-- and no sleep is waited on: the delayed run is simply asked its question
-- after the head it was started for has been superseded.
module ApprovalProvenance (spec) where

import Control.Monad (void)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import DismissalStep (Outcome (..), Repository (..), approval, approvalMarker, pushedHead, settled, withStep)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)

data Fixture = Fixture
  { root ∷ FilePath
  , environment ∷ [(String, String)]
  , checkout ∷ FilePath
  }

-- | One comment in the pull request's feed, by whoever posted it.
data Comment = Comment
  { author ∷ String
  , body ∷ String
  }

-- | The account whose review markers are canonical, and the identity the
-- workflow's own token writes records under.
owner, workflow ∷ String
owner = "coghex"
workflow = "github-actions[bot]"

-- | What the shipped scripts decided about one push, in the workflow's order.
data Decision = Decision
  { replayOutput ∷ String
  , provenanceOutput ∷ String
  , gateResult ∷ ExitCode
  , gateOutput ∷ String
  , gateErrors ∷ String
  }

spec ∷ Spec
spec = describe "Approval provenance" $ do
  describe "the reproduced sequences" $ do
    it "removes an approval a clean base merge inherited from an unproven intermediate head" $
      -- Head A was reviewed. Push B added behaviour nobody read; before its
      -- dismissal ran, push C merged the base into B. The replay is genuinely
      -- `keep` — C is exactly Git's merge of B — and it is irrelevant, because
      -- B was never proven.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        unreviewed ← commitFile fixture "src/module.hs" "-- behaviour nobody reviewed\n" "Add behaviour"
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        decision ← decide fixture [approvedBy owner reviewed] unreviewed merged
        field "replay_decision" (replayOutput decision) `shouldBe` Just "keep"
        shouldRemove decision
        gateOutput decision
          `shouldContain` ("reason=the starting point " ++ take 12 unreviewed ++ " is not a proven approved revision")

    it "removes an approval an identical-tree push inherited from an unproven intermediate head" $
      -- The same race with the cheaper proof: C carries exactly B's tree, so
      -- the push changed no tracked file. True, and still not a review of B.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        unreviewed ← commitFile fixture "src/module.hs" "-- behaviour nobody reviewed\n" "Add behaviour"
        repushed ← emptyCommit fixture "Re-push the same tree"
        decision ← decide fixture [approvedBy owner reviewed] unreviewed repushed
        shouldRemove decision

  describe "an earlier invalidation that did not conclude" $ do
    it "refuses the delayed decision for the superseded head, then strips at the next one" $
      -- Both halves of the race in one example: the A→B run answers after C
      -- has landed and is refused, exactly as before; what is new is that
      -- B→C no longer treats the label that refusal left standing as proof.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        unreviewed ← commitFile fixture "src/module.hs" "-- behaviour nobody reviewed\n" "Add behaviour"
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        delayed ← decideAt fixture [approvedBy owner reviewed] reviewed unreviewed merged
        gateResult delayed `shouldBe` ExitFailure 3
        gateErrors delayed `shouldContain` "superseded head"
        next ← decide fixture [approvedBy owner reviewed] unreviewed merged
        shouldRemove next

    it "strips when the earlier carry's mutation failed and recorded nothing" $
      -- The A→M1 update was a legitimate clean merge, but the job that would
      -- have recorded the carry failed. M1 is therefore unproven, and M2
      -- cannot inherit through it however clean it is.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "The first upstream note.\n" "Note upstream"
        first ← mergeBase fixture
        advanceBase fixture "docs/later.md" "A later upstream note.\n" "Note upstream again"
        second ← mergeBase fixture
        decision ← decide fixture [approvedBy owner reviewed] first second
        field "replay_decision" (replayOutput decision) `shouldBe` Just "keep"
        shouldRemove decision

    it "strips when the earlier decision never ran at all" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        unrecorded ← emptyCommit fixture "Re-push whose decision never ran"
        repushed ← emptyCommit fixture "Re-push again"
        decision ← decide fixture [approvedBy owner reviewed] unrecorded repushed
        shouldRemove decision
        gateOutput decision `shouldContain` ("the starting point " ++ take 12 unrecorded)

  describe "the provenance source" $ do
    it "strips when the feed could not be read" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        decision ← decideFrom fixture (root fixture </> "no-such-feed.json") reviewed repushed repushed
        field "provenance" (provenanceOutput decision) `shouldBe` Just "unproven"
        value "provenance_reason" (provenanceOutput decision) `shouldContain` "could not be read"
        shouldRemove decision

    it "strips when the feed is malformed" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        writeFixtureFile (root fixture) "feed.json" "[{\"user\": {\"login\": \"coghex\"}, \"body\": "
        decision ← decideFrom fixture (root fixture </> "feed.json") reviewed repushed repushed
        value "provenance_reason" (provenanceOutput decision) `shouldContain` "not valid JSON"
        shouldRemove decision

    it "strips when the feed is not a list of comments" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        writeFixtureFile (root fixture) "feed.json" "{\"message\": \"Not Found\"}"
        decision ← decideFrom fixture (root fixture </> "feed.json") reviewed repushed repushed
        value "provenance_reason" (provenanceOutput decision) `shouldContain` "not a list of comments"
        shouldRemove decision

    it "accepts the paged feed the workflow fetches" $
      -- `gh api --paginate --slurp` writes a list of pages, not of comments.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        writeFixtureFile (root fixture) "feed.json" ("[" ++ feed [approvedBy owner reviewed] ++ ", []]")
        decision ← decideFrom fixture (root fixture </> "feed.json") reviewed repushed repushed
        shouldKeepFrom reviewed decision

    it "takes no review marker from anyone but the owner" $
      -- A marker is canonical because of who published it, not what it says.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        decision ← decide fixture [approvedBy "somebody-else" reviewed] reviewed repushed
        shouldRemove decision

    it "takes no carry record from anyone but the workflow" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "The first upstream note.\n" "Note upstream"
        first ← mergeBase fixture
        advanceBase fixture "docs/later.md" "A later upstream note.\n" "Note upstream again"
        second ← mergeBase fixture
        recordedRun fixture 1 (Just "success") first
        decision ←
          decide fixture [approvedBy owner reviewed, carriedBy owner 1 reviewed reviewed first] first second
        shouldRemove decision

    it "lists the run attempts the records name" $
      -- The workflow fetches exactly these jobs listings before deciding.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        writeFixtureFile
          (root fixture)
          "feed.json"
          (feed [carriedBy workflow 7 reviewed reviewed repushed, carriedBy workflow 7 reviewed reviewed repushed, carriedBy workflow 9 reviewed repushed repushed])
        (status, listed, errors) ←
          tool fixture "review_provenance.py" ["--list-runs", "--comments", root fixture </> "feed.json"]
        (status, errors) `shouldBe` (ExitSuccess, "")
        lines listed `shouldBe` ["7 1", "9 1"]

    it "lets a later marker withdraw an approval of the same head" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        decision ←
          decide
            fixture
            [approvedBy owner reviewed, Comment owner (approvalMarker reviewed "CHANGES_REQUESTED")]
            reviewed
            repushed
        shouldRemove decision

    it "proves a head approved again after an earlier withdrawal" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        decision ←
          decide
            fixture
            [Comment owner (approvalMarker reviewed "CHANGES_REQUESTED"), approvedBy owner reviewed]
            reviewed
            repushed
        shouldKeepFrom reviewed decision

  describe "the job that recorded a carry" $ do
    it "strips when the recording job failed after posting its record" $
      -- The record is posted while its job is still running. A job that
      -- failed afterwards never confirmed the carry, whatever it posted.
      withFixture $ \fixture → do
        (reviewed, first, second) ← twoUpdates fixture
        recordedRun fixture 1 (Just "failure") first
        decision ← decide fixture [approvedBy owner reviewed, carriedBy workflow 1 reviewed reviewed first] first second
        shouldRemove decision
        gateOutput decision `shouldContain` "dismiss-stale-approval in run 1 attempt 1 was failure, not success"

    it "strips when the recording job was cancelled after posting its record" $
      withFixture $ \fixture → do
        (reviewed, first, second) ← twoUpdates fixture
        recordedRun fixture 1 (Just "cancelled") first
        decision ← decide fixture [approvedBy owner reviewed, carriedBy workflow 1 reviewed reviewed first] first second
        shouldRemove decision
        gateOutput decision `shouldContain` "was cancelled, not success"

    it "strips when the recording job has not concluded" $
      -- Another push's decision can read a record while the job that wrote it
      -- is still running; an unfinished job vouches for nothing yet.
      withFixture $ \fixture → do
        (reviewed, first, second) ← twoUpdates fixture
        recordedRun fixture 1 Nothing first
        decision ← decide fixture [approvedBy owner reviewed, carriedBy workflow 1 reviewed reviewed first] first second
        shouldRemove decision
        gateOutput decision `shouldContain` "was unfinished, not success"

    it "strips when the recording run's jobs could not be fetched" $
      withFixture $ \fixture → do
        (reviewed, first, second) ← twoUpdates fixture
        decision ← decide fixture [approvedBy owner reviewed, carriedBy workflow 1 reviewed reviewed first] first second
        shouldRemove decision
        gateOutput decision `shouldContain` "the jobs of run 1 attempt 1 could not be read"

    it "strips when the recording run was for another head" $
      withFixture $ \fixture → do
        (reviewed, first, second) ← twoUpdates fixture
        recordedRun fixture 1 (Just "success") second
        decision ← decide fixture [approvedBy owner reviewed, carriedBy workflow 1 reviewed reviewed first] first second
        shouldRemove decision
        gateOutput decision `shouldContain` "ran for another head"

    it "strips when the record names a run of some other workflow" $
      withFixture $ \fixture → do
        (reviewed, first, second) ← twoUpdates fixture
        writeFixtureFile (root fixture) "runs/1-1.json" (jobsListing "validation" 1 (Just "success") first)
        decision ← decide fixture [approvedBy owner reviewed, carriedBy workflow 1 reviewed reviewed first] first second
        shouldRemove decision
        gateOutput decision `shouldContain` "is not a review-gate run"

  describe "a canonical review that requested changes" $ do
    it "ends the chain at an inherited head it denied" $
      -- M1 inherited A's approval through a verified carry, and was then
      -- reviewed in its own right and refused. The refusal is terminal: the
      -- carry into it no longer proves anything.
      withFixture $ \fixture → do
        (reviewed, first, second) ← twoUpdates fixture
        recordedRun fixture 1 (Just "success") first
        decision ←
          decide
            fixture
            [ approvedBy owner reviewed
            , carriedBy workflow 1 reviewed reviewed first
            , Comment owner (approvalMarker first "CHANGES_REQUESTED")
            ]
            first
            second
        shouldRemove decision
        gateOutput decision `shouldContain` "its newest canonical review requested changes"

    it "ends a descendant's chain at the denied head it passes through" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "The first upstream note.\n" "Note upstream"
        first ← mergeBase fixture
        advanceBase fixture "docs/later.md" "A later upstream note.\n" "Note upstream again"
        second ← mergeBase fixture
        advanceBase fixture "docs/last.md" "The last upstream note.\n" "Note upstream once more"
        third ← mergeBase fixture
        recordedRun fixture 1 (Just "success") first
        recordedRun fixture 2 (Just "success") second
        decision ←
          decide
            fixture
            [ approvedBy owner reviewed
            , carriedBy workflow 1 reviewed reviewed first
            , carriedBy workflow 2 reviewed first second
            , Comment owner (approvalMarker first "CHANGES_REQUESTED")
            ]
            second
            third
        shouldRemove decision
        gateOutput decision
          `shouldContain` ("traces back to " ++ take 12 first ++ ", and its newest canonical review requested changes")

    it "removes an inherited approval when it denied the pushed head itself" $
      -- A proven starting point and an identical tree, and a reviewer who
      -- refused this very revision: the refusal wins.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        decision ←
          decide
            fixture
            [approvedBy owner reviewed, Comment owner (approvalMarker repushed "CHANGES_REQUESTED")]
            reviewed
            repushed
        field "provenance" (provenanceOutput decision) `shouldBe` Just "proven"
        field "head_verdict" (provenanceOutput decision) `shouldBe` Just "denied"
        shouldRemove decision
        gateOutput decision
          `shouldContain` ("reason=a canonical review requested changes on head " ++ take 12 repushed ++ " itself")

    it "removes an inherited approval when it denied the pushed head after the decision" $
      -- The denial lands between the decision and the mutation. The decision
      -- was to keep; the shipped step re-reads the markers before confirming
      -- it and strips instead, recording no carry.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        decision ← decide fixture [approvedBy owner reviewed] reviewed repushed
        shouldKeepFrom reviewed decision
        let decided name = value name (gateOutput decision)
            proven name = value name (provenanceOutput decision)
            repository =
              settled
                { labelsAfter = []
                , replay = value "replay_decision" (replayOutput decision)
                , -- The step answers for the harness's own event head, so the
                  -- denial has to name that head rather than the Git fixture's.
                  markers = [approvalMarker pushedHead "CHANGES_REQUESTED"]
                , provenance = proven "provenance"
                , provenanceReason = proven "provenance_reason"
                , origin = proven "origin"
                , chain = proven "chain"
                , headVerdict = proven "head_verdict"
                }
        withStep repository (decided "action") (decided "expected") $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")
          unwords (calls outcome) `shouldNotContain` "approval-provenance:v1"
          summary outcome `shouldContain` "requested changes on this head itself"
        (published, verdictOutput, _) ← verdict fixture repushed "success" "false"
        published `shouldBe` ExitFailure 1
        verdictOutput `shouldContain` "is not attached"

    it "is lifted by a later approval of that exact head" $
      withFixture $ \fixture → do
        (reviewed, first, second) ← twoUpdates fixture
        recordedRun fixture 1 (Just "success") first
        decision ←
          decide
            fixture
            [ approvedBy owner reviewed
            , carriedBy workflow 1 reviewed reviewed first
            , Comment owner (approvalMarker first "CHANGES_REQUESTED")
            , approvedBy owner first
            ]
            first
            second
        shouldKeepFrom first decision

  describe "a head that was actually reviewed" $ do
    it "keeps a fresh canonical approval of the pushed head over an unproven starting point" $
      -- The reviewer was faster than the queued run: C itself was approved
      -- before B→C's decision executed. That approval is a new origin, and
      -- B being unproven has nothing to say about it.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        unreviewed ← commitFile fixture "src/module.hs" "-- behaviour nobody reviewed\n" "Add behaviour"
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        decision ← decide fixture [approvedBy owner reviewed, approvedBy owner merged] unreviewed merged
        field "provenance" (provenanceOutput decision) `shouldBe` Just "unproven"
        field "head_verdict" (provenanceOutput decision) `shouldBe` Just "approved"
        shouldKeep decision
        gateOutput decision `shouldContain` ("reason=a canonical review approved head " ++ take 12 merged ++ " itself")

    it "keeps a head approved after an earlier strip as a new origin" $
      -- B was stripped, then reviewed and approved in its own right. The
      -- clean merge that follows carries B's approval, not A's.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        stripped ← commitFile fixture "src/module.hs" "-- behaviour reviewed later\n" "Add behaviour"
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        decision ← decide fixture [approvedBy owner reviewed, approvedBy owner stripped] stripped merged
        shouldKeepFrom stripped decision

  describe "a carry from a proven head" $ do
    it "keeps an identical-tree re-push of a proven head" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        repushed ← emptyCommit fixture "Re-push the reviewed tree"
        decision ← decide fixture [approvedBy owner reviewed] reviewed repushed
        shouldKeepFrom reviewed decision
        gateOutput decision `shouldContain` "reason=the push changed no tracked file"

    it "keeps a clean base merge of a proven head" $
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        decision ← decide fixture [approvedBy owner reviewed] reviewed merged
        shouldKeepFrom reviewed decision
        field "chain" (provenanceOutput decision) `shouldBe` Just reviewed

    it "keeps successive clean base merges each recorded from the previously proven head" $
      -- Three base updates in a row, each one's carry recorded by the job that
      -- confirmed it. The third is proven through both records back to the
      -- revision the reviewer actually read, and the chain says so.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "The first upstream note.\n" "Note upstream"
        first ← mergeBase fixture
        advanceBase fixture "docs/later.md" "A later upstream note.\n" "Note upstream again"
        second ← mergeBase fixture
        advanceBase fixture "docs/last.md" "The last upstream note.\n" "Note upstream once more"
        third ← mergeBase fixture
        recordedRun fixture 1 (Just "success") first
        recordedRun fixture 2 (Just "success") second
        decision ←
          decide
            fixture
            [ approvedBy owner reviewed
            , carriedBy workflow 1 reviewed reviewed first
            , carriedBy workflow 2 reviewed first second
            ]
            second
            third
        shouldKeepFrom reviewed decision
        field "chain" (provenanceOutput decision) `shouldBe` Just (reviewed ++ "," ++ first ++ "," ++ second)
        value "provenance_reason" (provenanceOutput decision) `shouldContain` "through 2 recorded carries"

    it "names the link that could not be proven when a chain is broken" $
      -- The record for M1→M2 exists; the one for A→M1 does not. The reason
      -- has to say that the trace ran out at M1, not merely that M2 failed.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "The first upstream note.\n" "Note upstream"
        first ← mergeBase fixture
        advanceBase fixture "docs/later.md" "A later upstream note.\n" "Note upstream again"
        second ← mergeBase fixture
        advanceBase fixture "docs/last.md" "The last upstream note.\n" "Note upstream once more"
        third ← mergeBase fixture
        recordedRun fixture 2 (Just "success") second
        decision ←
          decide fixture [approvedBy owner reviewed, carriedBy workflow 2 reviewed first second] second third
        shouldRemove decision
        gateOutput decision
          `shouldContain` ( "reason=the carry into " ++ take 12 second ++ " is recorded, but it traces back to "
                              ++ take 12 first ++ ", and it has no canonical approval and no verified carry leads into it"
                          )

    it "still strips a carried head's push that carries more than the merge" $
      -- Provenance is necessary, not sufficient: the push itself still has to
      -- be one the earlier review covers.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        void $ mergeBase fixture
        amended ← commitFile fixture "src/module.hs" "-- one line the review never saw\n" "Amend"
        decision ← decide fixture [approvedBy owner reviewed] reviewed amended
        field "provenance" (provenanceOutput decision) `shouldBe` Just "proven"
        shouldRemove decision

  describe "the composition for the failing sequence" $
    it "removes the label through the shipped step and withholds approval" $
      -- Decision, mutation, verdict: the decision the scripts reach for the
      -- clean-merge race is handed to the step that actually mutates, and the
      -- verdict is then asked with what that step left behind.
      withFixture $ \fixture → do
        reviewed ← approvedWork fixture
        unreviewed ← commitFile fixture "src/module.hs" "-- behaviour nobody reviewed\n" "Add behaviour"
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        decision ← decide fixture [approvedBy owner reviewed] unreviewed merged
        shouldRemove decision
        let decided name = value name (gateOutput decision)
            proven name = value name (provenanceOutput decision)
            repository =
              settled
                { labelsAfter = []
                , replay = value "replay_decision" (replayOutput decision)
                , provenance = proven "provenance"
                , provenanceReason = proven "provenance_reason"
                , origin = proven "origin"
                , chain = proven "chain"
                , headVerdict = proven "head_verdict"
                }
        withStep repository (decided "action") (decided "expected") $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")
          unwords (calls outcome) `shouldNotContain` "approval-provenance:v1"
          summary outcome `shouldContain` "- Starting point: unproven"
          summary outcome `shouldContain` "- Proven origin: not established"
        (published, verdictOutput, _) ← verdict fixture merged "success" "false"
        published `shouldBe` ExitFailure 1
        verdictOutput `shouldContain` "is not attached"

-- ---------------------------------------------------------------------------
-- Asserting a decision

shouldRemove ∷ Decision → IO ()
shouldRemove decision = do
  (gateResult decision, gateErrors decision) `shouldBe` (ExitSuccess, "")
  field "action" (gateOutput decision) `shouldBe` Just "remove"
  field "expected" (gateOutput decision) `shouldBe` Just "removed"

shouldKeep ∷ Decision → IO ()
shouldKeep decision = do
  (gateResult decision, gateErrors decision) `shouldBe` (ExitSuccess, "")
  field "action" (gateOutput decision) `shouldBe` Just "none"
  field "expected" (gateOutput decision) `shouldBe` Just "kept"

-- | Kept, with the carried review traced to the revision it was granted at.
shouldKeepFrom ∷ String → Decision → IO ()
shouldKeepFrom granted decision = do
  shouldKeep decision
  field "provenance" (provenanceOutput decision) `shouldBe` Just "proven"
  field "origin" (provenanceOutput decision) `shouldBe` Just granted

field ∷ String → String → Maybe String
field name = lookup name . map split . lines
  where split line = let (key, rest) = break (== '=') line in (key, drop 1 rest)

value ∷ String → String → String
value name output = fromMaybe "" (field name output)

-- ---------------------------------------------------------------------------
-- Running the shipped scripts the way the workflow does

-- | Decide one push whose head is still current, from a feed of comments.
decide ∷ Fixture → [Comment] → String → String → IO Decision
decide fixture comments before after = decideAt fixture comments before after after

-- | Decide one push, answering after the pull request has reached `current`.
decideAt ∷ Fixture → [Comment] → String → String → String → IO Decision
decideAt fixture comments before after current = do
  writeFixtureFile (root fixture) "feed.json" (feed comments)
  decideFrom fixture (root fixture </> "feed.json") before after current

decideFrom ∷ Fixture → FilePath → String → String → String → IO Decision
decideFrom fixture feedPath before after current = do
  (replayStatus, replayed, replayErrors) ←
    tool fixture "review_replay.py" ["--before", before, "--after", after, "--base", "master"]
  (replayStatus, replayErrors) `shouldBe` (ExitSuccess, "")
  (provenanceStatus, proven, provenanceErrors) ←
    tool
      fixture
      "review_provenance.py"
      ["--before", before, "--after", after, "--comments", feedPath, "--runs", root fixture </> "runs", "--owner", owner]
  (provenanceStatus, provenanceErrors) `shouldBe` (ExitSuccess, "")
  beforeTree ← tree fixture before
  afterTree ← tree fixture after
  (status, output, errors) ←
    tool
      fixture
      "review_gate.py"
      [ "dismissal"
      , "--event-head"
      , after
      , "--current-head"
      , current
      , "--before-tree"
      , beforeTree
      , "--after-tree"
      , afterTree
      , "--replay-decision"
      , value "replay_decision" replayed
      , "--replay-reason"
      , value "replay_reason" replayed
      , "--provenance"
      , value "provenance" proven
      , "--provenance-reason"
      , value "provenance_reason" proven
      , "--head-verdict"
      , value "head_verdict" proven
      , "--label-attached"
      , "true"
      ]
  pure (Decision replayed proven status output errors)

verdict ∷ Fixture → String → String → String → IO (ExitCode, String, String)
verdict fixture current dismissal attached =
  tool
    fixture
    "review_gate.py"
    [ "verdict"
    , "--event-action"
    , "synchronize"
    , "--event-head"
    , current
    , "--current-head"
    , current
    , "--dismissal-result"
    , dismissal
    , "--label-attached"
    , attached
    ]

tool ∷ Fixture → String → [String] → IO (ExitCode, String, String)
tool fixture name arguments =
  run (environment fixture) (root fixture) "python3" ((checkout fixture </> "tools/validation" </> name) : arguments)

-- ---------------------------------------------------------------------------
-- The comment feed

approvedBy ∷ String → String → Comment
approvedBy login granted = Comment login (approvalMarker granted "APPROVE")

-- | The record the mutation job writes after confirming a carry, naming the
-- run (always its first attempt here) that wrote it.
carriedBy ∷ String → Int → String → String → String → Comment
carriedBy login recording origin' before after =
  Comment
    login
    ( "Carried `" ++ approval ++ "` from `" ++ take 12 before ++ "` to `" ++ take 12 after ++ "`.\n\n"
        ++ "<!-- approval-provenance:v1 origin=" ++ origin' ++ " before=" ++ before ++ " after=" ++ after
        ++ " run=" ++ show recording ++ " attempt=1 -->"
    )

-- | The jobs listing of one recording run's first attempt, as the workflow
-- fetches it: the mutation job at the given head with the given conclusion,
-- or none when it has not finished.
recordedRun ∷ Fixture → Int → Maybe String → String → IO ()
recordedRun fixture recording conclusion headSha =
  writeFixtureFile
    (root fixture)
    ("runs/" ++ show recording ++ "-1.json")
    (jobsListing "review-gate" recording conclusion headSha)

jobsListing ∷ String → Int → Maybe String → String → String
jobsListing workflowName recording conclusion headSha =
  "{\"total_count\": 3, \"jobs\": [{\"name\": \"decide-dismissal\", \"conclusion\": \"success\"}, "
    ++ "{\"name\": \"dismiss-stale-approval\", \"workflow_name\": " ++ quoted workflowName
    ++ ", \"run_id\": " ++ show recording ++ ", \"run_attempt\": 1, \"head_sha\": " ++ quoted headSha
    ++ ", \"conclusion\": " ++ maybe "null" quoted conclusion ++ "}, "
    ++ "{\"name\": \"review-approved\", \"conclusion\": \"success\"}]}"

-- | The feed as GitHub returns it, in posting order.
feed ∷ [Comment] → String
feed comments = "[" ++ commaSeparated (zipWith render [1 ..] comments) ++ "]"
  where
    render ∷ Int → Comment → String
    render number comment =
      "{\"id\": " ++ show number
        ++ ", \"created_at\": \"2026-09-11T00:00:" ++ pad number ++ "Z\""
        ++ ", \"user\": {\"login\": " ++ quoted (author comment) ++ ", \"type\": \"User\"}"
        ++ ", \"body\": " ++ quoted (body comment) ++ "}"
    pad number = let text = show number in replicate (2 - length text) '0' ++ text
    commaSeparated = foldr (\item rest → if null rest then item else item ++ ", " ++ rest) ""

quoted ∷ String → String
quoted text = "\"" ++ concatMap escape text ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape character = [character]

-- ---------------------------------------------------------------------------
-- Building a history to ask about

seedModule ∷ String
seedModule =
  unlines
    [ "module Seed (seed) where"
    , ""
    , "seed :: Int"
    , "seed = 1"
    ]

withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  here ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-provenance" $ \directory → do
    let fixture = Fixture directory settings here
    void $ at fixture ["init", "-b", "master", "."]
    writeFixtureFile directory "docs/notes.md" "A seed note.\n"
    writeFixtureFile directory "src/module.hs" seedModule
    void $ commitAll fixture "Seed"
    action fixture

at ∷ Fixture → [String] → IO String
at fixture = git (environment fixture) (root fixture)

commitAll ∷ Fixture → String → IO String
commitAll fixture message = do
  void $ at fixture ["add", "-A"]
  void $ at fixture ["commit", "-m", message]
  revision fixture "HEAD"

revision ∷ Fixture → String → IO String
revision fixture reference = takeWhile (/= '\n') <$> at fixture ["rev-parse", reference]

tree ∷ Fixture → String → IO String
tree fixture reference = revision fixture (reference ++ "^{tree}")

-- | The reviewed work: one branch commit, which is what the review examined.
approvedWork ∷ Fixture → IO String
approvedWork fixture = do
  void $ at fixture ["checkout", "-b", "feature", "master"]
  commitFile fixture "src/module.hs" "-- the approved work\n" "Extend the module"

-- | Append to a file on the current branch and commit it.
commitFile ∷ Fixture → FilePath → String → String → IO String
commitFile fixture path addition message = do
  existing ← readFile (root fixture </> path)
  length existing `seq` writeFixtureFile (root fixture) path (existing ++ addition)
  commitAll fixture message

-- | A new commit with exactly its parent's tree: an identical-tree re-push.
emptyCommit ∷ Fixture → String → IO String
emptyCommit fixture message = do
  void $ at fixture ["commit", "--allow-empty", "-m", message]
  revision fixture "HEAD"

-- | Move the base on, leaving the feature branch behind it.
advanceBase ∷ Fixture → FilePath → String → String → IO ()
advanceBase fixture path contents message = do
  void $ at fixture ["checkout", "master"]
  writeFixtureFile (root fixture) path contents
  void $ commitAll fixture message
  void $ at fixture ["checkout", "feature"]

-- | The reviewed head and two successive base updates of it: the first is the
-- carry whose record is under examination, the second the push being decided.
twoUpdates ∷ Fixture → IO (String, String, String)
twoUpdates fixture = do
  reviewed ← approvedWork fixture
  advanceBase fixture "docs/notes.md" "The first upstream note.\n" "Note upstream"
  first ← mergeBase fixture
  advanceBase fixture "docs/later.md" "A later upstream note.\n" "Note upstream again"
  second ← mergeBase fixture
  pure (reviewed, first, second)

-- | The merge a branch update performs: the base into the current head.
mergeBase ∷ Fixture → IO String
mergeBase fixture = do
  void $ at fixture ["merge", "--no-ff", "-m", "Merge master into feature", "master"]
  revision fixture "HEAD"
