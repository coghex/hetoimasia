-- | Hspec coverage for the review gate's two decisions.
--
-- The workflow reads the pull request's head, the pushed commits' trees, its
-- labels, and the stale-approval job's result from GitHub, and hands them to
-- @tools/validation/review_gate.py@, together with the replay verdict
-- @review_replay.py@ reached in the checkout. These examples drive that tool
-- directly, which is where the composition that actually decides a mutation or
-- a publication lives: a superseded head, an invalidation that never completed,
-- and an absent label each have to keep a green check from appearing; a delayed
-- run must not strip an approval belonging to a newer head; and a replay that
-- came back @keep@ has to survive a push that did change tracked files, which
-- is the whole point of the rule. What the replay verdict *means* about a
-- history is proven against real repositories in "ReviewReplay"; what is proven
-- here is that this composition consumes it — and that it consumes the
-- provenance verdict "ApprovalProvenance" proves the same way: an unproven
-- starting point strips whatever the trees and the replay say, and a canonical
-- approval of the pushed head itself keeps whatever they say.
module ReviewGate (spec) where

import Sandbox (run, sanitizedEnvironment)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain)

-- | Two distinct heads, so an example can say which one a run answers for.
reviewedHead, newerHead ∷ String
reviewedHead = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
newerHead = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

spec ∷ Spec
spec = describe "Review gate" $ do
  describe "the stale-approval decision" $ do
    it "removes an attached approval when the push changed tracked files" $ do
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "strip" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=remove"
      output `shouldContain` "expected=removed"

    it "keeps an approval when the push left every tree identical" $ do
      -- Independent of the replay: a re-pushed identical tree changes nothing a
      -- reviewer read, whatever its topology says.
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-one" "strip" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=none"
      output `shouldContain` "expected=kept"

    it "keeps an approval a content-changing push replayed onto the base" $ do
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "keep" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=none"
      output `shouldContain` "expected=kept"

    it "repeats the replay's own reason rather than inventing one" $ do
      -- The job summary is built out of this line, and a decision explained in
      -- the gate's words would describe a rule the gate did not apply.
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "keep" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` ("reason=" ++ replayReason)

    it "treats an unreadable starting point as a change" $ do
      -- An absent before-tree cannot establish that nothing moved, so the
      -- conservative answer is the one that invalidates the approval.
      (result, output, _) ← dismissal reviewedHead reviewedHead "" "tree-two" "strip" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=remove"

    it "still carries an approval when an unreadable starting point replayed" $ do
      -- The tree comparison and the replay are independent proofs. A missing
      -- before-tree only means the cheap one could not answer.
      (result, output, _) ← dismissal reviewedHead reviewedHead "" "tree-two" "keep" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=none"
      output `shouldContain` "expected=kept"

    it "asks for no mutation when the label was not attached" $ do
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "strip" "false"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=none"
      output `shouldContain` "expected=absent"

    it "claims no inheritance for a replay with no approval to inherit" $ do
      -- Eligibility is not approval. Reporting `kept` here would let a summary
      -- describe a review that was never granted.
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "keep" "false"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=none"
      output `shouldContain` "expected=absent"
      output `shouldContain` "was not attached"

    it "refuses to touch an approval belonging to a newer head" $ do
      -- A delayed synchronize run whose push has already been superseded would
      -- otherwise strip approval from a head it never examined.
      (result, output, errors) ← dismissal reviewedHead newerHead "tree-one" "tree-two" "strip" "true"
      result `shouldBe` ExitFailure 3
      errors `shouldContain` "superseded head"
      output `shouldBe` ""

    it "refuses to decide when the label state could not be read" $ do
      -- A failed read is not an absent label. Folding the two together would
      -- dismiss a content-changing push as harmless and leave approval standing.
      (result, output, errors) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "strip" "unknown"
      result `shouldBe` ExitFailure 5
      errors `shouldContain` "unreadable label state is not an absent one"
      output `shouldBe` ""

    it "refuses a replay verdict it does not recognize" $ do
      -- The verdict arrives as a job output. An empty or misspelled one is a
      -- broken wiring, and guessing which way it meant would guess about an
      -- approval.
      (result, _, errors) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "" "true"
      result `shouldBe` ExitFailure 2
      errors `shouldContain` "--replay-decision"

    describe "the starting point's provenance" $ do
      it "removes an approval an identical-tree push inherited from an unproven head" $ do
        -- The trees match, so the cheap proof says nothing moved. It is right,
        -- and irrelevant: nobody proved the head the label was left standing on.
        (result, output, _) ←
          dismissalFrom "unproven" "false" reviewedHead reviewedHead "tree-one" "tree-one" "strip" "true"
        result `shouldBe` ExitSuccess
        output `shouldContain` "action=remove"
        output `shouldContain` "expected=removed"
        output `shouldContain` ("reason=" ++ provenanceReason)

      it "removes an approval a clean replay inherited from an unproven head" $ do
        (result, output, _) ←
          dismissalFrom "unproven" "false" reviewedHead reviewedHead "tree-one" "tree-two" "keep" "true"
        result `shouldBe` ExitSuccess
        output `shouldContain` "action=remove"
        output `shouldContain` ("reason=" ++ provenanceReason)

      it "keeps an approval a canonical review granted to the pushed head itself" $ do
        -- A fresh approval is a new origin. Neither the unproven starting point
        -- nor a replay that strips has anything to say about it.
        (result, output, _) ←
          dismissalFrom "unproven" "true" reviewedHead reviewedHead "tree-one" "tree-two" "strip" "true"
        result `shouldBe` ExitSuccess
        output `shouldContain` "action=none"
        output `shouldContain` "expected=kept"
        output `shouldContain` ("reason=a canonical review approved head " ++ take 12 reviewedHead)

      it "asks for no mutation when the head is approved but no label is attached" $ do
        (result, output, _) ←
          dismissalFrom "unproven" "true" reviewedHead reviewedHead "tree-one" "tree-two" "strip" "false"
        result `shouldBe` ExitSuccess
        output `shouldContain` "action=none"
        output `shouldContain` "expected=absent"

      it "still refuses a superseded head before consulting provenance" $ do
        (result, output, errors) ←
          dismissalFrom "unproven" "true" reviewedHead newerHead "tree-one" "tree-one" "strip" "true"
        result `shouldBe` ExitFailure 3
        errors `shouldContain` "superseded head"
        output `shouldBe` ""

      it "still refuses an unreadable label state before consulting provenance" $ do
        (result, _, errors) ←
          dismissalFrom "unproven" "true" reviewedHead reviewedHead "tree-one" "tree-one" "strip" "unknown"
        result `shouldBe` ExitFailure 5
        errors `shouldContain` "unreadable label state is not an absent one"

      it "refuses a provenance verdict it does not recognize" $ do
        (result, _, errors) ←
          dismissalFrom "" "false" reviewedHead reviewedHead "tree-one" "tree-one" "strip" "true"
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "--provenance"

      it "refuses a head-approval flag it does not recognize" $ do
        (result, _, errors) ←
          dismissalFrom "proven" "" reviewedHead reviewedHead "tree-one" "tree-one" "strip" "true"
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "--head-approved"

  it "publishes approval when the label is attached at the current head" $ do
    (result, output, _) ← verdict "synchronize" reviewedHead reviewedHead "success" "true"
    result `shouldBe` ExitSuccess
    output `shouldContain` "review gate is satisfied"

  it "withholds approval when the label is not attached" $ do
    (result, output, _) ← verdict "synchronize" reviewedHead reviewedHead "success" "false"
    result `shouldBe` ExitFailure 1
    output `shouldContain` "is not attached"

  it "withholds approval when the label state could not be read" $ do
    (result, _, errors) ← verdict "synchronize" reviewedHead reviewedHead "success" "unknown"
    result `shouldBe` ExitFailure 5
    errors `shouldContain` "unreadable label state is not an absent one"

  it "refuses to answer for a head the pull request has moved past" $ do
    (result, _, errors) ← verdict "synchronize" reviewedHead newerHead "success" "true"
    result `shouldBe` ExitFailure 3
    errors `shouldContain` "superseded head"

  it "refuses to publish when the stale-approval decision failed" $ do
    (result, _, errors) ← verdict "synchronize" reviewedHead reviewedHead "failure" "true"
    result `shouldBe` ExitFailure 4
    errors `shouldContain` "stale-approval decision"

  it "refuses to publish when the stale-approval decision was cancelled" $ do
    (result, _, errors) ← verdict "synchronize" reviewedHead reviewedHead "cancelled" "true"
    result `shouldBe` ExitFailure 4
    errors `shouldContain` "cancelled"

  it "refuses to publish when a push skipped the stale-approval decision" $ do
    -- A skipped invalidation on a push is a missing decision, not an approval:
    -- the label sitting there was applied to code this push replaced.
    (result, _, errors) ← verdict "synchronize" reviewedHead reviewedHead "skipped" "true"
    result `shouldBe` ExitFailure 4
    errors `shouldContain` "skipped"

  it "accepts the skipped decision a label event is expected to produce" $ do
    (result, _, _) ← verdict "labeled" reviewedHead reviewedHead "skipped" "true"
    result `shouldBe` ExitSuccess

  it "refuses a label event whose stale-approval copy failed instead of skipping" $ do
    (result, _, errors) ← verdict "unlabeled" reviewedHead reviewedHead "failure" "true"
    result `shouldBe` ExitFailure 4
    errors `shouldContain` "expected to be skipped"

-- | What `review_replay.py` said, quoted verbatim into the gate's own reason.
replayReason ∷ String
replayReason = "the push is exactly Git's clean merge of the approved head with the base"

-- | What `review_provenance.py` said about an unproven starting point.
provenanceReason ∷ String
provenanceReason = "the starting point has no canonical approval and no recorded carry leads into it"

-- | A push from a proven starting point to a head no canonical review named:
-- the situation every example about trees and replays is about.
dismissal
  ∷ String → String → String → String → String → String → IO (ExitCode, String, String)
dismissal = dismissalFrom "proven" "false"

dismissalFrom
  ∷ String
  → String
  → String
  → String
  → String
  → String
  → String
  → String
  → IO (ExitCode, String, String)
dismissalFrom provenance headApproved eventHead currentHead beforeTree afterTree replay attached =
  gate
    [ "dismissal"
    , "--event-head"
    , eventHead
    , "--current-head"
    , currentHead
    , "--before-tree"
    , beforeTree
    , "--after-tree"
    , afterTree
    , "--replay-decision"
    , replay
    , "--replay-reason"
    , replayReason
    , "--provenance"
    , provenance
    , "--provenance-reason"
    , provenanceReason
    , "--head-approved"
    , headApproved
    , "--label-attached"
    , attached
    ]

verdict ∷ String → String → String → String → String → IO (ExitCode, String, String)
verdict action eventHead currentHead decision attached =
  gate
    [ "verdict"
    , "--event-action"
    , action
    , "--event-head"
    , eventHead
    , "--current-head"
    , currentHead
    , "--dismissal-result"
    , decision
    , "--label-attached"
    , attached
    ]

gate ∷ [String] → IO (ExitCode, String, String)
gate arguments = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  run settings checkout "python3" ((checkout </> "tools/validation/review_gate.py") : arguments)
