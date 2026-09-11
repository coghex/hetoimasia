-- | Hspec coverage for the review gate's two decisions.
--
-- The workflow reads the pull request's head, the pushed commits' trees, its
-- labels, and the stale-approval job's result from GitHub, and hands them to
-- @tools/validation/review_gate.py@. These examples drive that tool directly,
-- which is where the composition that actually decides a mutation or a
-- publication lives: a superseded head, an invalidation that never completed,
-- and an absent label each have to keep a green check from appearing, and a
-- delayed run must not strip an approval belonging to a newer head.
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
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=remove"
      output `shouldContain` "expected=removed"

    it "keeps an approval when the push left every tree identical" $ do
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-one" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=none"
      output `shouldContain` "expected=kept"

    it "treats an unreadable starting point as a change" $ do
      -- An absent before-tree cannot establish that nothing moved, so the
      -- conservative answer is the one that invalidates the approval.
      (result, output, _) ← dismissal reviewedHead reviewedHead "" "tree-two" "true"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=remove"

    it "asks for no mutation when the label was not attached" $ do
      (result, output, _) ← dismissal reviewedHead reviewedHead "tree-one" "tree-two" "false"
      result `shouldBe` ExitSuccess
      output `shouldContain` "action=none"
      output `shouldContain` "expected=absent"

    it "refuses to touch an approval belonging to a newer head" $ do
      -- A delayed synchronize run whose push has already been superseded would
      -- otherwise strip approval from a head it never examined.
      (result, output, errors) ← dismissal reviewedHead newerHead "tree-one" "tree-two" "true"
      result `shouldBe` ExitFailure 3
      errors `shouldContain` "superseded head"
      output `shouldBe` ""

  it "publishes approval when the label is attached at the current head" $ do
    (result, output, _) ← verdict "synchronize" reviewedHead reviewedHead "success" "true"
    result `shouldBe` ExitSuccess
    output `shouldContain` "review gate is satisfied"

  it "withholds approval when the label is not attached" $ do
    (result, output, _) ← verdict "synchronize" reviewedHead reviewedHead "success" "false"
    result `shouldBe` ExitFailure 1
    output `shouldContain` "is not attached"

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

dismissal ∷ String → String → String → String → String → IO (ExitCode, String, String)
dismissal eventHead currentHead beforeTree afterTree attached =
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
