-- | Idle and stop (requirements 15 and 16): an owner with nothing to run enters no
-- Lua and wakes only for an event, a stop wakes it whatever its tasks wait for, and
-- a stop closes every suspended coroutine on the owner's thread, keeps closing
-- errors as cleanup evidence, discards what had not started and lets a running
-- segment return.
module Test.LuaRuntime.Scheduled.Lifecycle (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, rethrowIO, tryWithContext)
import Control.Monad (forM, replicateM, replicateM_, void)
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerLive, WorkerStopped))
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitStopped), ExitRecord (exitNotStarted, exitStarted), Progress (NotStarted, Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Control.Concurrent.MVar (readMVar)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (fireReg, liveRegs, nanoseconds)
import Test.LuaRuntime.Support (Gated (..), bounded, expectFatal, requiredPolicy, withBoundary, withBoundaryOpening)

-- | Whether the owner's thread is parked in an STM transaction, which is where an
-- idle owner is, and nowhere else it ever blocks without an event to wait for.
parked ∷ SFixture → IO Bool
parked fixture = do
  thread ← readMVar (sfOwnerThread fixture)
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnSTM → pure True
    _ → pure False

spec ∷ Spec
spec = describe "idle and stop" $ do
  describe "an owner with nothing to run" $ do
    it "enters no Lua until an event arrives: paused tasks, an ungranted tick and a future deadline" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \_ runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "idle" requiredPolicy defaultSchedulerBounds)
        let endpoint = scheduledEndpoint owner
        looping ← admitTask' fixture owner "looping" (request "forever" [VText "f"] OrdinaryClass Looped (Just "looping"))
        awaitDiagnostics owner (\counts → diagYielded counts >= 2)
        requestTaskControl endpoint (ticketTask looping) RequestPause >>= \case
          TaskControlAccepted receipt → void (waitControl receipt)
          other → fail ("the pause was not accepted: " <> show other)
        awaitIdle fixture
        -- Paused: no segment runs, however long the owner is left.
        before ← length <$> segmentsRun fixture
        replicateM_ 500 yield
        length <$> segmentsRun fixture >>= (`shouldBe` before)
        parked fixture >>= (`shouldBe` True)
        -- A task that waits for a tick no one has granted.
        waiting ← admitTask' fixture owner "waiting" (request "wait_ticks" [VText "w", VInteger 3] OrdinaryClass OneShot (Just "waiting"))
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        awaitIdle fixture
        beforeTicks ← length <$> segmentsRun fixture
        -- Two grants are not enough: the owner applies them and is idle again.
        mapM_ (grantScheduledStep endpoint . nanoseconds) [5, 7]
        awaitDiagnostics owner (\counts → diagTick counts >= 2)
        awaitIdle fixture
        length <$> segmentsRun fixture >>= (`shouldBe` beforeTicks)
        _ ← grantScheduledStep endpoint (nanoseconds 11)
        _ ← outcomeOf waiting
        -- A future deadline: the owner arms its timer and is idle until it is woken
        -- at, or after, the deadline.
        setClock fixture 1000
        sleeper ← admitTask' fixture owner "sleeper" (request "sleep" [VText "s", VInteger 500] OrdinaryClass OneShot (Just "sleeper"))
        awaitRegistrations fixture 1
        awaitIdle fixture
        beforeDeadline ← length <$> segmentsRun fixture
        replicateM_ 500 yield
        length <$> segmentsRun fixture >>= (`shouldBe` beforeDeadline)
        setClock fixture 1500
        liveRegs (sfTimer fixture) >>= mapM_ fireReg
        _ ← outcomeOf sleeper
        -- The paused task is still paused through all of it, and resumes on request.
        requestTaskControl endpoint (ticketTask looping) RequestResume >>= \case
          TaskControlAccepted receipt → void (waitControl receipt)
          other → fail ("the resume was not accepted: " <> show other)
        awaitDiagnostics owner (\counts → diagYielded counts >= 4)
        retireScheduled owner

    it "is woken by a stop whatever its tasks are waiting for" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "stop wakes" requiredPolicy defaultSchedulerBounds)
        _ ← admitTask' fixture owner "ticks" (request "wait_ticks" [VText "w", VInteger 9] OrdinaryClass OneShot Nothing)
        _ ← admitTask' fixture owner "deadline" (request "sleep" [VText "s", VInteger 999999999] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 2)
        awaitIdle fixture
        retireScheduled owner
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
        -- Nothing fired the timer, and nothing granted a tick.
        liveRegs (sfTimer fixture) >>= (`shouldSatisfy` null)

  describe "stopping the owner" $ do
    it "lets a running segment return, discards what had not started and counts it, and keeps the worker live while a segment is stuck" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "stuck" requiredPolicy defaultSchedulerBounds)
        stuck ← admitTask' fixture owner "stuck" (request "block_in" [VText "s"] OrdinaryClass OneShot Nothing)
        awaitEntered fixture "s"
        unstarted ← replicateM 3 (admitScheduledTask (scheduledEndpoint owner) (request "echo" [VInteger 1] OrdinaryClass OneShot Nothing))
        retireScheduled owner
        -- The stop is requested and the segment has not returned: the worker, its VM
        -- and its dependencies stay live, and nothing is preempted.
        replicateM_ 500 yield
        atomically (scheduledStatus owner) >>= (`shouldSatisfy` \case WorkerLive → True; _ → False)
        atomically (scheduledExitRecord owner) >>= (`shouldSatisfy` isNothing')
        releaseGate fixture "s"
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
        outcomeOf stuck >>= (`shouldSatisfy` \case SettledReturned _ → True; _ → False)
        outcomes ← forM unstarted $ \case
          TaskAccepted _ ticket → outcomeOf ticket
          other → fail ("expected the task to have been accepted, found " <> show other)
        mapM_ (`shouldSatisfy` \case SettledDiscarded (Discard ExitStopped NotStarted) → True; _ → False) outcomes
        atomically (scheduledExitRecord owner) >>= \case
          Just record → (exitNotStarted record, exitStarted record) `shouldBe` (3, 0)
          Nothing → fail "the owner recorded no exit"

    it "closes every suspended coroutine on its own thread, keeps the closing errors as cleanup evidence beside the others, and settles each task" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "closing" requiredPolicy defaultSchedulerBounds)
        clean ← admitTask' fixture owner "clean" (request "closes_cleanly" [VText "a"] OrdinaryClass OneShot Nothing)
        bad ← admitTask' fixture owner "bad" (request "closes_badly" [VText "b"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 2)
        retireScheduled owner
        ended ← tryWithContext @SomeException (awaitScheduledTerminal control owner)
        -- Both were suspended, and both were settled whatever the closing did.
        forM [clean, bad] outcomeOf >>= mapM_ (`shouldSatisfy` \case SettledDiscarded (Discard ExitStopped Started) → True; _ → False)
        effects fixture >>= (`shouldBe` ["a suspended", "b suspended", "a closed", "b closing"])
        either rethrowIO (const (fail "the owner should have ended with the closing error")) ended
      -- The failure of the one close is retained as cleanup evidence on the owner's
      -- outcome, which is fatal.
      length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
  where
    isNothing' = maybe True (const False)
