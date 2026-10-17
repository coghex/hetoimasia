-- | Host failures and retirement on failure (requirements 12, 14 and 16): what the
-- application's own code raises ends the owner, unconverted, under its policy,
-- whatever its type; a script fault is only its task's; and a failure or a
-- cancellation retires the owner's coroutines as a stop does, keeping what closing
-- them raised as cleanup evidence beside the primary outcome.
module Test.LuaRuntime.Scheduled.Failures (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException, throwIO)
import Control.Monad (forM, forM_, void, when)
import Data.IORef (writeIORef)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerCleanupFailed (WorkerCleanupFailed), WorkerStatus (WorkerStopped, WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault)
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitCancelled, ExitFailed), ExitRecord (exitKind, exitNotStarted, exitStarted), Progress (NotStarted, Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (FakeTimer (ftOnCancel), nanoseconds)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

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

  it "leaves no admitted task unsettled when admissions race the owner's failure: admission closes as the owner begins to exit" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \control runtime → do
      victim ← startScheduled fixture runtime (scheduled fixture "racing" (optionalPolicy (brokenIs "bang")) defaultSchedulerBounds {boundQueuedAdmissions = 4096, boundRetainedResults = 8192})
      let endpoint = scheduledEndpoint victim
      _ ← admitTask' fixture victim "bang" (request "block_then_fail" [VText "r", VText "bang"] OrdinaryClass OneShot Nothing)
      awaitEntered fixture "r"
      done ← newEmptyMVar
      _ ← forkIO $ do
        -- Admitting as fast as it can, from the moment the owner is let go, until
        -- admission closes.
        let go held = admitScheduledTask endpoint (request "echo" [VInteger 1] OrdinaryClass OneShot Nothing) >>= \case
              TaskAccepted _ ticket → go (ticket : held)
              TaskQueueFull → go held
              TaskAdmissionClosed → pure held
        go [] >>= putMVar done
      releaseGate fixture "r"
      tickets ← takeMVar done
      _ ← awaitScheduledTerminal control victim
      -- Every task the owner accepted settled: none was accepted too late to be.
      forM_ tickets $ \ticket → outcomeOf ticket >>= (`shouldSatisfy` \case SettledDiscarded _ → True; SettledReturned _ → True; _ → False)

  it "treats an identity another owner issued as unknown, whatever its number" $ bounded $ do
    fixture ← newSFixture
    withBoundary $ \_ runtime → do
      one ← startScheduled fixture runtime (scheduled fixture "one" requiredPolicy defaultSchedulerBounds)
      two ← startScheduled fixture runtime (scheduled fixture "two" requiredPolicy defaultSchedulerBounds)
      theirs ← admitTask' fixture one "foreign" (request "forever" [VText "x"] OrdinaryClass Looped Nothing)
      -- The first task each owner issues has the same local number; the identities
      -- differ, and neither owner's control reaches the other's task.
      _ ← admitTask' fixture two "own" (request "forever" [VText "y"] OrdinaryClass Looped Nothing)
      requestTaskControl (scheduledEndpoint two) (ticketTask theirs) RequestStop >>= \case
        TaskControlUnknown → pure ()
        other → fail ("expected the identity to be unknown, found " <> show other)
      retireScheduled one
      retireScheduled two

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

  describe "cleanup evidence" $ do
    let failsThenCloseFails yields = request "fails_then_close_fails" [VText "g", VInteger yields] OrdinaryClass OneShot Nothing
        scriptFaultWithEvidence yields = it ("keeps what closing the coroutine raised when the script's own error ended the " <> (if yields == 0 then "first" else "resumed") <> " segment, and the task still settles as faulted") $ bounded $ do
          fixture ← newSFixture
          ExceptionWithContext context _ ← expectFatal $ \control runtime → do
            owner ← startScheduled fixture runtime (scheduled fixture "evidence" (optionalPolicy (const True)) defaultSchedulerBounds)
            ticket ← admitTask' fixture owner "g" (failsThenCloseFails yields)
            -- The failure of the close is fatal, so the owner ends: its task has
            -- settled as the script's fault all the same.
            _ ← awaitScheduledTerminal control owner
            outcomeOf ticket >>= (`shouldSatisfy` \case SettledFaulted _ → True; _ → False)
          -- Even an optional owner that recognizes everything ends fatally.
          length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
    scriptFaultWithEvidence 0
    scriptFaultWithEvidence 1

    it "closes a coroutine the scheduler found inside a segment when the application's observer failed, before the VM is closed" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        writeIORef (sfObserver fixture) $ \context →
          when (contextSegment context >= 1) (throwIO (Broken "observer"))
        owner ← startScheduled fixture runtime (scheduled fixture "observer" (optionalPolicy (brokenIs "observer")) defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "t" (request "closes_cleanly" [VText "t"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        -- A recognized failure of an optional owner, not the refusal of a close run
        -- in the VM's own teardown, where state operations are not allowed.
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
        effects fixture >>= (`shouldSatisfy` elem "t closed")
        outcomeOf ticket >>= (`shouldSatisfy` \case SettledDiscarded (Discard ExitFailed Started) → True; _ → False)

    it "keeps every close's failure when one close is interrupted, the interruption among them, so that a plain stop is not a benign cancellation" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "interrupted" requiredPolicy defaultSchedulerBounds)
        _ ← admitTask' fixture owner "killed" (request "close_killed" [VText "k"] OrdinaryClass OneShot Nothing)
        _ ← admitTask' fixture owner "bad" (request "closes_badly" [VText "b"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 2)
        retireScheduled owner
        awaitScheduledTerminal control owner
      -- Both closes ran, in identity order, and both failures are retained.
      effects fixture >>= (`shouldSatisfy` \logged → "k closing" `elem` logged && "b closing" `elem` logged)
      length (cleanupFailuresInContext context) `shouldSatisfy` (>= 2)

    it "keeps an interrupted close as evidence when a task-level stop made it, so an optional owner that recognizes everything is fatal" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "task stop" (optionalPolicy (const True)) defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "killed" (request "close_killed" [VText "k"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        _ ← requestTaskControl (scheduledEndpoint owner) (ticketTask ticket) RequestStop
        awaitScheduledTerminal control owner
      effects fixture >>= (`shouldSatisfy` elem "k closing")
      length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)

    it "keeps both the timer's failure and an interrupted close's when the stop met both" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "both" requiredPolicy defaultSchedulerBounds)
        _ ← admitTask' fixture owner "killed" (request "close_killed" [VText "k"] OrdinaryClass OneShot Nothing)
        _ ← admitTask' fixture owner "sleeper" (request "sleep" [VText "s", VInteger 5000000000] OrdinaryClass OneShot Nothing)
        awaitRegistrations fixture 1
        writeIORef (ftOnCancel (sfTimer fixture)) (ioError (userError "cancel failed"))
        retireScheduled owner
        awaitScheduledTerminal control owner
      let labels = map cleanupFailureLabel (cleanupFailuresInContext context)
      labels `shouldSatisfy` elem "lua timer cancel"
      labels `shouldSatisfy` elem "lua task close"

    it "keeps the close failures of an owner whose timer's cancellation throws, ending it fatally, with its control receipts settled" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "timer" requiredPolicy defaultSchedulerBounds)
        _ ← admitTask' fixture owner "sleeper" (request "sleep" [VText "s", VInteger 5000000000] OrdinaryClass OneShot Nothing)
        awaitRegistrations fixture 1
        writeIORef (ftOnCancel (sfTimer fixture)) (ioError (userError "cancel failed"))
        retireScheduled owner
        awaitScheduledTerminal control owner
      length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)

    it "ends the owner at the first failure of cleanup, so repeated failing closes keep nothing for as long as it serves" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "first" requiredPolicy defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "bad" (request "closes_badly" [VText "b"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        receipt ← requestTaskControl (scheduledEndpoint owner) (ticketTask ticket) RequestStop
        case receipt of
          TaskControlAccepted held → void (waitControl held)
          other → fail ("the request was not accepted: " <> show other)
        -- The close of the stopped task failed: the owner is ending, not serving on.
        awaitScheduledTerminal control owner
      length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)

  describe "cancellation" $ do
    it "keeps the result of a task that finished in a resumed segment a cancellation was queued during" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "resumed" requiredPolicy defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "r" (request "resumes_then_blocks" [VText "r", VText "g"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        awaitEntered fixture "g"
        cancelScheduled owner
        releaseGate fixture "g"
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
        outcomeOf ticket >>= (`shouldBe` Just [VInteger 7]) . taskReturned

    it "keeps the failures of closing the ended coroutine of a task whose resumed segment failed when a cancellation was queued during it" $ bounded $ do
      fixture ← newSFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "resumed fault" (optionalPolicy (const True)) defaultSchedulerBounds)
        _ ← admitTask' fixture owner "r" (request "resumes_blocks_fails" [VText "r", VText "g"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        awaitEntered fixture "g"
        cancelScheduled owner
        releaseGate fixture "g"
        awaitScheduledTerminal control owner
      -- A cancelled owner whose cleanup failed ends fatally, not benignly.
      length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)

    it "closes a coroutine whose task a cancellation interrupted as it first yielded, before the VM, so its close may use a state operation" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "first segment" requiredPolicy defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "a" (request "blocks_then_suspends" [VText "a", VText "g"] OrdinaryClass OneShot Nothing)
        awaitEntered fixture "g"
        cancelScheduled owner
        releaseGate fixture "g"
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
        effects fixture >>= (`shouldSatisfy` elem "a closed")
        outcomeOf ticket >>= (`shouldSatisfy` \case SettledDiscarded (Discard ExitCancelled Started) → True; _ → False)

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
        -- The segment that was running returned and finished the task, and the
        -- cancellation landed behind it: a task that completed keeps its result.
        outcomeOf stuck >>= (`shouldBe` Just []) . taskReturned
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
