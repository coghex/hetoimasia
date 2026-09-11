-- | Hspec coverage for the @review-approved@ verdict.
--
-- The workflow reads the pull request's head, its labels, and the
-- stale-approval job's result from GitHub and hands all three to
-- @tools/validation/review_gate.py@. These examples drive that tool directly,
-- which is where the composition that actually decides publication lives: a
-- superseded head, an invalidation decision that never completed, and an
-- absent label each have to keep a green check from appearing.
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

verdict ∷ String → String → String → String → String → IO (ExitCode, String, String)
verdict action eventHead currentHead dismissal attached = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  run
    settings
    checkout
    "python3"
    [ checkout </> "tools/validation/review_gate.py"
    , "--event-action"
    , action
    , "--event-head"
    , eventHead
    , "--current-head"
    , currentHead
    , "--dismissal-result"
    , dismissal
    , "--label-attached"
    , attached
    ]
