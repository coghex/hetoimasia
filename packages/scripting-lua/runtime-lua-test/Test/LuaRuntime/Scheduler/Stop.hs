-- | The scheduler's own stop and its admission, and the diagnostics (requirement
-- 11): the whole scheduler's stop distinct from a task's, the caps and the
-- answers they give, and counters checked against a scripted workload.
module Test.LuaRuntime.Scheduler.Stop (spec) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, toException, try)
import Control.Monad (when)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduler.Support

request ∷ Rig → TaskId → ControlRequest → IO ControlTicket
request rig identity what =
  atomically (requestControl (rigScheduler rig) identity what) >>= \case
    ControlAccepted ticket → pure ticket
    _ → fail "the request was not accepted"

spec ∷ Spec
spec = describe "stopping the scheduler, admission and diagnostics" $ do
  describe "the scheduler's stop" $ do
    it "closes every live continuation once, records what it ended, and refuses everything after" $ do
      rig ← newRigWith defaultOptions {optBounds = defaultBounds {boundActiveTasks = 4, boundQueuedAdmissions = 2}}
      ready ← admit rig "ready" OrdinaryClass Looped
      waiting ← admit rig "waiting" OrdinaryClass OneShot
      paused ← admit rig "paused" OrdinaryClass Looped
      finished ← admit rig "finished" OrdinaryClass OneShot
      queued ← admit rig "queued" OrdinaryClass OneShot
      loop rig "ready"
      loop rig "paused"
      script rig "waiting" [waitTicks "waiting" 9]
      _ ← request rig paused RequestPause
      _ ← turn rig
      -- A grant and a request that the stop will find outstanding.
      _ ← granted rig 5
      pending ← request rig ready RequestPause
      report ← stopScheduler (rigScheduler rig) (rigHost rig)
      -- Closed in identity order; the finished task has nothing to close.
      map fst <$> closedTasks rig >>= (`shouldBe` [ready, waiting, paused])
      let exit = stopRecord report
      Map.toList (exitTasks exit)
        `shouldBe` [ (ready, DispositionAborted)
                   , (waiting, DispositionAborted)
                   , (paused, DispositionAborted)
                   , (finished, DispositionTerminal OutcomeCompleted)
                   , (queued, DispositionNotAdmitted)
                   ]
      (discardedResults (exitDiscards exit), discardedAdmissions (exitDiscards exit)) `shouldBe` (1, 1)
      stopControlsSettled report `shouldBe` 1
      atomically (pollControl pending) >>= (`shouldSatisfy` \case Just (ControlSettlement ControlNoLongerApplicable Nothing) → True; _ → False)
      -- The grant was discarded, so no one is left waiting for it.
      atomically (stepsOutstanding (rigScheduler rig)) >>= (`shouldBe` 0)
      atomically (schedulerClosed (rigScheduler rig)) >>= (`shouldBe` True)
      atomically (admitTask (rigScheduler rig) (taskSpec "late" OrdinaryClass OneShot)) >>= (`shouldBe` AdmitRefused AdmitClosed)
      granted rig 5 >>= (`shouldBe` GrantClosed)
      atomically (requestControl (rigScheduler rig) ready RequestStop) >>= \case
        ControlClosed → pure ()
        _ → fail "expected the request to be refused as closed"
      after ← turn rig
      (turnSegments after, turnEnd after) `shouldBe` (0, TurnClosed)
      counts ← diagnostics rig
      (diagCancelled counts, diagDiscarded counts) `shouldBe` (3, 2)
      -- A second stop answers the first's record and closes nothing again.
      again ← stopScheduler (rigScheduler rig) (rigHost rig)
      stopRecord again `shouldBe` exit
      length <$> closedTasks rig >>= (`shouldBe` 3)

    it "retains the failure of each close, closes the others all the same, and reports them in the stop's record" $ do
      rig ← newRig
      mapM_ (\name → admit rig name OrdinaryClass Looped >> loop rig name) ["first", "second", "third"]
      _ ← turn rig
      writeFailureAt rig (taskIdAt 1)
      report ← stopScheduler (rigScheduler rig) (rigHost rig)
      map fst <$> closedTasks rig >>= (`shouldBe` [taskIdAt 0, taskIdAt 1, taskIdAt 2])
      map fst (stopCloseFailures report) `shouldBe` [taskIdAt 1]

  describe "a stop that is interrupted" $ do
    it "still attempts every other continuation's close, keeps the interruption as that close's failure, completes, and raises it afterwards" $ do
      rig ← newRig
      mapM_ (\name → admit rig name OrdinaryClass Looped >> loop rig name) ["first", "second", "third"]
      _ ← turn rig
      entered ← newEmptyMVar
      gate ← newEmptyMVar
      writeIORef (rigCloseHook rig) $ \identity →
        when (identity == taskIdAt 0) (putMVar entered () >> takeMVar gate)
      finished ← newEmptyMVar
      stopper ← forkIO (try @SomeException (stopScheduler (rigScheduler rig) (rigHost rig)) >>= putMVar finished)
      takeMVar entered
      -- The first close is blocked, interruptibly, inside the host.
      throwTo stopper ThreadKilled
      outcome ← takeMVar finished
      case outcome of
        Left failure → fromException failure `shouldBe` Just ThreadKilled
        Right _ → fail "the interruption should have been raised after the stop completed"
      map fst <$> closedTasks rig >>= (`shouldBe` [taskIdAt 0, taskIdAt 1, taskIdAt 2])
      atomically (schedulerClosed (rigScheduler rig)) >>= (`shouldBe` True)
      -- The stop is complete and its record keeps the interruption as evidence;
      -- asking again closes nothing.
      again ← stopScheduler (rigScheduler rig) (rigHost rig)
      map fst (stopCloseFailures again) `shouldBe` [taskIdAt 0]
      length <$> closedTasks rig >>= (`shouldBe` 3)

  describe "a timer whose cancellation throws" $ do
    it "does not stop the stop: every close runs, the control requests settle, the failure is raised after, and the report is answered again" $ do
      rig ← newRig
      sleeper ← admit rig "sleeper" OrdinaryClass OneShot
      other ← admit rig "other" OrdinaryClass Looped
      script rig "sleeper" [waitFor "sleeper" 5000000]
      loop rig "other"
      _ ← turn rig
      liveRegs (rigTimer rig) >>= (`shouldSatisfy` ((== 1) . length))
      pending ← request rig other RequestPause
      writeIORef (ftOnCancel (rigTimer rig)) (ioError (userError "cancel failed"))
      outcome ← try @SomeException (stopScheduler (rigScheduler rig) (rigHost rig))
      case outcome of
        Left failure → show failure `shouldBe` show (userError "cancel failed")
        Right _ → fail "the timer's failure should have been raised after the stop completed"
      map fst <$> closedTasks rig >>= (`shouldBe` [sleeper, other])
      atomically (pollControl pending) >>= (`shouldSatisfy` \case Just (ControlSettlement ControlNoLongerApplicable Nothing) → True; _ → False)
      atomically (schedulerClosed (rigScheduler rig)) >>= (`shouldBe` True)
      -- Complete, so asking again answers its record and closes nothing.
      again ← stopScheduler (rigScheduler rig) (rigHost rig)
      stopControlsSettled again `shouldBe` 1
      length <$> closedTasks rig >>= (`shouldBe` 2)

  describe "a timer whose cancellation throws and a close that is interrupted" $ do
    it "keeps the timer's failure in the report that a later call answers, while the interruption is what the stop raises" $ do
      rig ← newRig
      _ ← admit rig "sleeper" OrdinaryClass OneShot
      _ ← admit rig "other" OrdinaryClass Looped
      script rig "sleeper" [waitFor "sleeper" 5000000]
      loop rig "other"
      _ ← turn rig
      writeIORef (ftOnCancel (rigTimer rig)) (ioError (userError "cancel failed"))
      entered ← newEmptyMVar
      gate ← newEmptyMVar
      writeIORef (rigCloseHook rig) $ \identity →
        when (identity == taskIdAt 0) (putMVar entered () >> takeMVar gate)
      finished ← newEmptyMVar
      stopper ← forkIO (try @SomeException (stopScheduler (rigScheduler rig) (rigHost rig)) >>= putMVar finished)
      takeMVar entered
      throwTo stopper ThreadKilled
      takeMVar finished >>= \case
        Left failure → fromException failure `shouldBe` Just ThreadKilled
        Right _ → fail "the interruption should have been raised after the stop completed"
      again ← stopScheduler (rigScheduler rig) (rigHost rig)
      fmap show (stopTimerFailure again) `shouldBe` Just (show (userError "cancel failed"))
      map fst (stopCloseFailures again) `shouldBe` [taskIdAt 0]

  describe "close failures that a turn that ended exceptionally had met" $ do
    let setup = do
          rig ← newRig
          refused ← admit rig "refused" OrdinaryClass OneShot
          _ ← admit rig "broken" OrdinaryClass OneShot
          script rig "refused" [waitTicks "refused" 0]
          script rig "broken" [ioError (userError "host failed")]
          modifyIORef' (rigCloseFailures rig) (Map.insert refused (toException (userError "close failed")))
          -- The refused wait fails its task, whose suspended continuation is
          -- closed and fails to close; then the next task's host raises.
          outcome ← try @SomeException (turn rig)
          either (const (pure ())) (const (fail "the turn should have ended with the host's failure")) outcome
          pure (rig, refused)

    it "are kept for the scheduler's stop, which reports them" $ do
      (rig, refused) ← setup
      report ← stopScheduler (rigScheduler rig) (rigHost rig)
      map fst (stopCloseFailures report) `shouldBe` [refused]
      length <$> closedTasks rig >>= (`shouldBe` 1)

    it "are kept for the next turn, which reports them once" $ do
      (rig, refused) ← setup
      first ← turn rig
      map fst (turnCloseFailures first) `shouldBe` [refused]
      second ← turn rig
      turnCloseFailures second `shouldSatisfy` null
      report ← stopScheduler (rigScheduler rig) (rigHost rig)
      stopCloseFailures report `shouldSatisfy` null

  describe "close failures when a turn's final timer synchronization fails" $ do
    let refusedWithElapsedWaiter = do
          rig ← newRig
          refused ← admit rig "refused" OrdinaryClass OneShot
          _ ← admit rig "sleeper" OrdinaryClass OneShot
          script rig "refused" [waitTicks "refused" 0]
          script rig "sleeper" [waitFor "sleeper" 5000000]
          modifyIORef' (rigCloseFailures rig) (Map.insert refused (toException (userError "close failed")))
          pure (rig, refused)

    it "are kept through a clock failure while the timer is synchronized, for the stop" $ do
      (rig, refused) ← refusedWithElapsedWaiter
      readings ← newIORef (0 ∷ Int)
      -- The first reading places the sleeper's deadline; the second is the timer's.
      writeIORef (rigClockHook rig) $ do
        n ← atomicModifyIORef' readings (\seen → (seen + 1, seen + 1))
        when (n == 2) (ioError (userError "clock down"))
      outcome ← try @SomeException (turn rig)
      either (const (pure ())) (const (fail "the turn should have failed")) outcome
      writeIORef (rigClockHook rig) (pure ())
      report ← stopScheduler (rigScheduler rig) (rigHost rig)
      map fst (stopCloseFailures report) `shouldBe` [refused]

    it "are kept through an interruption while the timer is armed, for the next report" $ do
      (rig, refused) ← refusedWithElapsedWaiter
      entered ← newEmptyMVar
      gate ← newEmptyMVar
      writeIORef (ftOnArm (rigTimer rig)) (putMVar entered () >> takeMVar gate)
      finished ← newEmptyMVar
      driver ← forkIO (try @SomeException (turn rig) >>= putMVar finished)
      takeMVar entered
      thrower ← forkIO (throwTo driver ThreadKilled)
      awaitDelivered thrower
      putMVar gate ()
      _ ← takeMVar finished
      writeIORef (ftOnArm (rigTimer rig)) (pure ())
      next ← turn rig
      map fst (turnCloseFailures next) `shouldBe` [refused]

    it "are not lost to a report that never arrived: a report is acknowledged by the next turn, and until then the stop reports it again" $ do
      (rig, refused) ← refusedWithElapsedWaiter
      first ← turn rig
      map fst (turnCloseFailures first) `shouldBe` [refused]
      report ← stopScheduler (rigScheduler rig) (rigHost rig)
      map fst (stopCloseFailures report) `shouldBe` [refused]

  describe "the owner's one wait" $ do
    it "returns for an admission, a control request, a grant, a timer wake and the owner's stop request, and for nothing else" $ do
      rig ← newRig
      workAvailable rig >>= (`shouldBe` False)
      task ← admit rig "task" OrdinaryClass OneShot
      -- An admission is work: a ready task.
      workAvailable rig >>= (`shouldBe` True)
      script rig "task" [waitFor "task" 5000000]
      _ ← turn rig
      workAvailable rig >>= (`shouldBe` False)
      -- A control request.
      _ ← request rig task RequestPause
      workAvailable rig >>= (`shouldBe` True)
      _ ← turn rig
      workAvailable rig >>= (`shouldBe` False)
      -- A grant.
      _ ← granted rig 5
      workAvailable rig >>= (`shouldBe` True)
      _ ← turn rig
      workAvailable rig >>= (`shouldBe` False)
      -- The timer's wake.
      [armed] ← liveRegs (rigTimer rig)
      fireReg armed
      workAvailable rig >>= (`shouldBe` True)
      _ ← turn rig
      workAvailable rig >>= (`shouldBe` False)
      -- The owner's stop request: a turn then ends at once, starting nothing.
      setStop rig True
      workAvailable rig >>= (`shouldBe` True)
      report ← turn rig
      (turnSegments report, turnEnd report) `shouldBe` (0, TurnStopRequested)

  describe "admission" $ do
    it "answers full at either cap, changes nothing but a counter, and never reissues an identity" $ do
      rig ← newRigWith defaultOptions {optBounds = defaultBounds {boundRetainedResults = 2}}
      first ← admit rig "a" OrdinaryClass OneShot
      _ ← admit rig "b" OrdinaryClass OneShot
      atomically (admitTask (rigScheduler rig) (taskSpec "c" OrdinaryClass OneShot)) >>= (`shouldBe` AdmitRefused (AdmitFull RetainedResults 2))
      diagRejected <$> diagnostics rig >>= (`shouldBe` 1)
      _ ← turnsUntilIdle rig 5
      -- The results are unobserved, and the storage they reserved is still held.
      atomically (admitTask (rigScheduler rig) (taskSpec "d" OrdinaryClass OneShot)) >>= (`shouldBe` AdmitRefused (AdmitFull RetainedResults 2))
      observe rig first >>= (`shouldSatisfy` \case Just (ResultCompleted "a") → True; _ → False)
      observe rig first >>= (`shouldBe` Nothing)
      admit rig "e" OrdinaryClass OneShot >>= (`shouldBe` taskIdAt 2)
      narrow ← newRigWith defaultOptions {optBounds = defaultBounds {boundActiveTasks = 1, boundQueuedAdmissions = 1}}
      _ ← admit narrow "active" OrdinaryClass Looped
      queued ← admit narrow "queued" OrdinaryClass Looped
      phase narrow queued >>= (`shouldBe` Just PhaseQueued)
      atomically (admitTask (rigScheduler narrow) (taskSpec "over" OrdinaryClass Looped)) >>= (`shouldBe` AdmitRefused (AdmitFull QueuedAdmissions 1))

    it "is closed once the owner has been asked to stop" $ do
      rig ← newRig
      setStop rig True
      atomically (admitTask (rigScheduler rig) (taskSpec "late" OrdinaryClass OneShot)) >>= (`shouldBe` AdmitRefused AdmitClosed)

  describe "the diagnostics" $ do
    it "counts a scripted workload exactly" $ do
      let bounds =
            defaultBounds
              { boundActiveTasks = 4
              , boundQueuedAdmissions = 2
              , boundRetainedResults = 5
              , boundQuanta = Quanta (Quantum 2) (Quantum 2) (Quantum 2)
              , boundOutstandingGrants = 2
              , boundControlRequests = 4
              }
      rig ← newRigWith defaultOptions {optBounds = bounds}
      _ ← admit rig "control" ControlClass OneShot
      _ ← admit rig "ordinary" OrdinaryClass Looped
      _ ← admit rig "background" BackgroundClass OneShot
      stopped ← admit rig "stopped" OrdinaryClass OneShot
      _ ← admit rig "queued" OrdinaryClass OneShot
      atomically (admitTask (rigScheduler rig) (taskSpec "rejected" OrdinaryClass OneShot)) >>= (`shouldBe` AdmitRefused (AdmitFull RetainedResults 5))
      script rig "control" [yielded "control"]
      script rig "ordinary" [yielded "ordinary", waitTicks "ordinary" 1]
      script rig "background" [failedWith "background" (TaskFailure (failureReason ScriptFault "boom") RecoverySafe)]
      _ ← request rig stopped RequestStop
      atomically (requestControl (rigScheduler rig) (taskIdAt 999) RequestPause) >>= \case
        ControlUnknownTarget → pure ()
        _ → fail "expected the unknown target to be refused"
      mapM_ (granted rig) [5, 6]
      granted rig 7 >>= (`shouldBe` GrantFull)
      granted rig 0 >>= (`shouldBe` GrantNotPositive)
      first ← turn rig
      turnSegments first `shouldBe` 5
      _ ← observe rig stopped
      second ← turn rig
      turnEnd second `shouldBe` TurnIdle
      _ ← granted rig 8
      _ ← turnsUntilIdle rig 5
      -- Only the stopped task's continuation was closed: the task that failed in its
      -- own segment has a dead continuation, which is the host's.
      map fst <$> closedTasks rig >>= (`shouldBe` [stopped])
      counts ← diagnostics rig
      counts
        `shouldBe` Diagnostics
          { diagOwner = "test-owner"
          , diagAdmitted = 5
          , diagRejected = 1
          , diagQueued = 0
          , diagQueueHighWater = 1
          , diagActive = 0
          , diagActiveHighWater = 4
          , diagCompleted = 3
          , diagYielded = 2
          , diagWaiting = 1
          , diagFailed = 1
          , diagCancelled = 1
          , diagDiscarded = 0
          , diagSegmentsByClass = [(ControlClass, 2), (OrdinaryClass, 4), (BackgroundClass, 1)]
          , diagOverruns = 0
          , diagOverrunSites = []
          , diagOverrunsUnattributed = 0
          , diagRefusedChoices = 0
          , diagRefusedWaits = 0
          , diagControlAccepted = 1
          , diagControlRefused = 1
          , diagGrantsAccepted = 3
          , diagGrantsRefused = 2
          , diagTick = 3
          }

writeFailureAt ∷ Rig → TaskId → IO ()
writeFailureAt rig identity = modifyIORef' (rigCloseFailures rig) (Map.insert identity (toException (userError "close boom")))
