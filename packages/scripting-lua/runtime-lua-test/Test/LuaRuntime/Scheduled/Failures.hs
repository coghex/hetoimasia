-- | Host failures and retirement on failure (requirements 12, 14 and 16): what the
-- application's own code raises ends the owner, unconverted, under its policy,
-- whatever its type; a script fault is only its task's; and a failure or a
-- cancellation retires the owner's coroutines as a stop does, keeping what closing
-- them raised as cleanup evidence beside the primary outcome.
module Test.LuaRuntime.Scheduled.Failures (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import Control.Monad (forM)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerCleanupFailed (WorkerCleanupFailed), WorkerStatus (WorkerStopped, WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault)
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitCancelled, ExitFailed), ExitRecord (exitKind, exitNotStarted, exitStarted), Progress (NotStarted, Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

blockThenFail ∷ Value → Value → TaskRequest
blockThenFail name kind = request "block_then_fail" [name, kind] OrdinaryClass OneShot Nothing

spec ∷ Spec
spec = describe "host failures, failure and cancellation" $ do
  it "ends only an optional owner whose classifier recognizes the failure, settling its tasks as discarded, while another owner goes on" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \control runtime → do
      victim ← startScheduled fixture runtime (scheduled fixture "victim" (optionalPolicy (brokenIs "bang")) defaultSchedulerBounds)
      bystander ← startScheduled fixture runtime (scheduled fixture "bystander" requiredPolicy defaultSchedulerBounds)
      running ← admitTask' fixture victim "running" (blockThenFail (VText "v") (VText "bang"))
      awaitEntered fixture "v"
      queued ← forM [1, 2 ∷ Int] $ \n → admitTask' fixture victim "queued" (request "echo" [VInteger (fromIntegral n)] OrdinaryClass OneShot Nothing)
      releaseGate fixture "v"
      awaitScheduledTerminal control victim >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
      -- No caller received the failure: the task that was running settled as
      -- discarded, started, and the others as not started.
      outcomeOf running >>= (`shouldSatisfy` \case SettledDiscarded (Discard ExitFailed Started) → True; _ → False)
      forM queued outcomeOf >>= mapM_ (`shouldSatisfy` \case SettledDiscarded (Discard ExitFailed NotStarted) → True; _ → False)
      atomically (scheduledExitRecord victim) >>= \case
        Just record → (exitKind record, exitStarted record, exitNotStarted record) `shouldBe` (ExitFailed, 1, 2)
        Nothing → fail "the owner recorded no exit"
      -- The other owner is untouched.
      served ← admitTask' fixture bystander "served" (request "echo" [VInteger 9] OrdinaryClass OneShot Nothing)
      outcomeOf served >>= (`shouldBe` Just [VInteger 9]) . taskReturned
      retireScheduled bystander

  it "is fatal, as for any worker, for the same failure in a required owner" $ bounded $ do
    fixture ← newSFixture
    ExceptionWithContext _ failure ← expectFatal $ \control runtime → do
      owner ← startScheduled fixture runtime (scheduled fixture "required" requiredPolicy defaultSchedulerBounds)
      _ ← admitTask' fixture owner "bang" (request "host_fail" [VText "bang"] OrdinaryClass OneShot Nothing)
      awaitScheduledTerminal control owner
    failure `shouldSatisfy` brokenIs "bang"

  it "treats a boundary fault a binding's action threw as a failure of the host, by where it was raised and not by its type" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \control runtime → do
      let recognizesBoundary failure = isJust (fromException failure ∷ Maybe BoundaryFault)
      owner ← startScheduled fixture runtime (scheduled fixture "boundary" (optionalPolicy recognizesBoundary) defaultSchedulerBounds)
      ticket ← admitTask' fixture owner "boundary" (request "host_fail" [VText "boundary"] OrdinaryClass OneShot Nothing)
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
      -- Not returned to its caller as a fault of the task.
      outcomeOf ticket >>= (`shouldSatisfy` \case SettledDiscarded _ → True; _ → False)

  it "keeps what closing the coroutines raised beside a host failure, and is fatal even for an optional owner that recognizes it" $ bounded $ do
    fixture ← newSFixture
    ExceptionWithContext context failure ← expectFatal $ \control runtime → do
      owner ← startScheduled fixture runtime (scheduled fixture "evidence" (optionalPolicy (const True)) defaultSchedulerBounds)
      _ ← admitTask' fixture owner "bad" (request "closes_badly" [VText "b"] OrdinaryClass OneShot Nothing)
      awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
      _ ← admitTask' fixture owner "bang" (request "host_fail" [VText "bang"] OrdinaryClass OneShot Nothing)
      awaitScheduledTerminal control owner
    failure `shouldSatisfy` brokenIs "bang"
    length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
    effects fixture >>= (`shouldSatisfy` elem "b closing")

  it "is fatal for an optional owner that recognizes everything when a plain stop's coroutine close fails" $ bounded $ do
    fixture ← newSFixture
    ExceptionWithContext context _ ← expectFatal $ \control runtime → do
      owner ← startScheduled fixture runtime (scheduled fixture "optional stop" (optionalPolicy (const True)) defaultSchedulerBounds)
      _ ← admitTask' fixture owner "bad" (request "closes_badly" [VText "b"] OrdinaryClass OneShot Nothing)
      awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
      retireScheduled owner
      awaitScheduledTerminal control owner
    length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)

  describe "cancellation" $ do
    it "retires the coroutines as a stop does, settling the tasks as discarded by a cancellation" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "cancelled" requiredPolicy defaultSchedulerBounds)
        suspended ← admitTask' fixture owner "suspended" (request "closes_cleanly" [VText "a"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        stuck ← admitTask' fixture owner "stuck" (request "block_in" [VText "s"] OrdinaryClass OneShot Nothing)
        awaitEntered fixture "s"
        unstarted ← admitTask' fixture owner "unstarted" (request "echo" [VInteger 1] OrdinaryClass OneShot Nothing)
        cancelScheduled owner
        -- A cancellation is never delivered inside Lua: it lands when the segment
        -- returns.
        releaseGate fixture "s"
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
        outcomeOf suspended >>= (`shouldSatisfy` \case SettledDiscarded (Discard ExitCancelled Started) → True; _ → False)
        outcomeOf unstarted >>= (`shouldSatisfy` \case SettledDiscarded (Discard ExitCancelled NotStarted) → True; _ → False)
        -- The segment that was running returned, and the cancellation landed behind
        -- it: Lua or a binding had run, so the task is discarded as started.
        outcomeOf stuck >>= (`shouldSatisfy` \case SettledDiscarded (Discard ExitCancelled Started) → True; _ → False)
        effects fixture >>= (`shouldSatisfy` elem "a closed")
        atomically (scheduledExitRecord owner) >>= \case
          Just record → exitKind record `shouldBe` ExitCancelled
          Nothing → fail "the owner recorded no exit"

    it "keeps a closing failure as cleanup evidence on a cancelled owner, which is fatal" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext context failure ← expectFatal $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "cancelled badly" requiredPolicy defaultSchedulerBounds)
        _ ← admitTask' fixture owner "bad" (request "closes_badly" [VText "b"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        cancelScheduled owner
        awaitScheduledTerminal control owner
      -- A worker that was cancelled and whose cleanup failed ends fatally, as the
      -- foundation says such a worker does, with what closing the coroutine raised
      -- retained as evidence on it.
      failure `shouldSatisfy` \caught → case fromException caught of
        Just (WorkerCleanupFailed _) → True
        _ → False
      length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
