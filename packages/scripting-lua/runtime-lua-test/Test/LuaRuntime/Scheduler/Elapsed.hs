-- | Elapsed time and the owned timer (requirements 7 and 8): a wait woken
-- exactly at its injected deadline and not before, one registration per owner
-- that is re-armed and cancelled, stale and early wakes, and distant deadlines.
-- Every example drives an injected clock and fires wakes by hand.
module Test.LuaRuntime.Scheduler.Elapsed (spec) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), MaskingState (Unmasked), SomeException, getMaskingState, try)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduler.Support
import Test.LuaRuntime.Support (bounded, failExample)

microsecondsOf ∷ Rig → IO [Int]
microsecondsOf rig = map regMicroseconds <$> liveRegs (rigTimer rig)

spec ∷ Spec
spec = describe "elapsed time and the owned timer" $ do
  describe "an elapsed wait" $ do
    it "wakes exactly when the clock reaches its deadline, and not before, with the elapsed time it measured" $ do
      rig ← newRig
      setClock rig 1000
      waiting ← admit rig "sleeper" OrdinaryClass OneShot
      script rig "sleeper" [waitFor "sleeper" 500]
      _ ← turn rig
      phase rig waiting >>= (`shouldBe` Just PhaseWaiting)
      setClock rig 1499
      before ← turn rig
      turnEnd before `shouldBe` TurnIdle
      ran rig >>= (`shouldBe` ["sleeper"])
      setClock rig 1500
      _ ← turn rig
      ran rig >>= (`shouldBe` ["sleeper", "sleeper"])
      handed rig >>= (`shouldBe` [("sleeper", 0, Nothing), ("sleeper", 1, Just (ResumedElapsed (nanoseconds 500)))])

    it "measures the elapsed time when the deadline is found reached, not when it was set" $ do
      rig ← newRig
      setClock rig 2000
      _ ← admit rig "late" OrdinaryClass OneShot
      script rig "late" [waitFor "late" 100]
      _ ← turn rig
      setClock rig 2350
      _ ← turn rig
      handed rig >>= (`shouldBe` [("late", 0, Nothing), ("late", 1, Just (ResumedElapsed (nanoseconds 350)))])

    it "wakes the waiters it finds due in deadline order, and in the order their waits began for one deadline" $ do
      rig ← newRig
      mapM_ (\(name, duration) → admit rig name OrdinaryClass OneShot >> script rig name [waitFor name duration]) [("slow", 300), ("first", 100), ("second", 100)]
      _ ← turn rig
      setClock rig 1000
      _ ← turn rig
      ran rig >>= (`shouldBe` ["slow", "first", "second", "first", "second", "slow"])

  describe "the timer" $ do
    it "holds one registration for the earliest deadline, re-arms it as that changes, and cancels it when nothing waits" $ do
      rig ← newRig
      _ ← admit rig "late" OrdinaryClass OneShot
      _ ← admit rig "early" OrdinaryClass OneShot
      script rig "late" [waitFor "late" 5000000]
      script rig "early" [waitFor "early" 2000000]
      _ ← turn rig
      microsecondsOf rig >>= (`shouldBe` [2000])
      setClock rig 2000000
      [armed] ← liveRegs (rigTimer rig)
      fireReg armed
      workAvailable rig >>= (`shouldBe` True)
      _ ← turn rig
      -- The early waiter ran; the late one is the earliest now.
      microsecondsOf rig >>= (`shouldBe` [3000])
      setClock rig 5000000
      [last'] ← liveRegs (rigTimer rig)
      fireReg last'
      _ ← turn rig
      liveRegs (rigTimer rig) >>= (`shouldSatisfy` null)
      length <$> allRegs (rigTimer rig) >>= (`shouldBe` 2)
      readMost rig >>= (`shouldBe` 1)

    it "is cancelled at stop, and stays disposed: a wake after it is ignored and nothing is armed again" $ do
      rig ← newRig
      _ ← admit rig "sleeper" OrdinaryClass OneShot
      script rig "sleeper" [waitFor "sleeper" 5000000]
      _ ← turn rig
      [armed] ← liveRegs (rigTimer rig)
      _ ← stopScheduler (rigScheduler rig) (rigHost rig)
      liveRegs (rigTimer rig) >>= (`shouldSatisfy` null)
      fireReg armed
      workAvailable rig >>= (`shouldBe` False)
      _ ← turn rig
      length <$> allRegs (rigTimer rig) >>= (`shouldBe` 1)

    it "treats a wake as a prompt to look at the clock, so an early wake readies nothing and the timer is armed again" $ do
      rig ← newRig
      _ ← admit rig "sleeper" OrdinaryClass OneShot
      script rig "sleeper" [waitFor "sleeper" 5000000]
      _ ← turn rig
      [armed] ← liveRegs (rigTimer rig)
      setClock rig 1000000
      fireReg armed
      workAvailable rig >>= (`shouldBe` True)
      report ← turn rig
      turnEnd report `shouldBe` TurnIdle
      ran rig >>= (`shouldBe` ["sleeper"])
      -- The wake was taken, the timer is armed again for what is left, and a second
      -- wake is needed to prompt another look.
      workAvailable rig >>= (`shouldBe` False)
      microsecondsOf rig >>= (`shouldBe` [4000])

    it "ignores a wake that belongs to a registration that was replaced or cancelled" $ do
      rig ← newRig
      _ ← admit rig "slow" OrdinaryClass OneShot
      script rig "slow" [waitFor "slow" 5000000]
      _ ← turn rig
      [replaced] ← liveRegs (rigTimer rig)
      _ ← admit rig "quick" OrdinaryClass OneShot
      script rig "quick" [waitFor "quick" 1000000]
      _ ← turn rig
      -- The earliest deadline changed, so the registration was replaced.
      microsecondsOf rig >>= (`shouldBe` [1000])
      fireReg replaced
      workAvailable rig >>= (`shouldBe` False)
      -- Nothing was readied either: a wake is no evidence a deadline passed.
      _ ← turn rig
      ran rig >>= (`shouldBe` ["slow", "quick"])

    it "converts a remaining duration up to whole microseconds, and clamps a distant deadline to one registration at a time" $ do
      registrationMicroseconds (nanoseconds 1) `shouldBe` 1
      registrationMicroseconds (nanoseconds 1000) `shouldBe` 1
      registrationMicroseconds (nanoseconds 1001) `shouldBe` 2
      registrationMicroseconds (nanoseconds 1500) `shouldBe` 2
      registrationMicroseconds (nanoseconds maxBound) `shouldBe` maxRegistration
      rig ← newRig
      _ ← admit rig "distant" OrdinaryClass OneShot
      let tenHours = 10 * 3600 * 1000 * 1000 * 1000
      script rig "distant" [waitFor "distant" tenHours]
      _ ← turn rig
      microsecondsOf rig >>= (`shouldBe` [maxRegistration])
      -- The registration wakes after an hour; the deadline is not reached, so the
      -- owner looks, finds nothing, and arms again.
      setClock rig (3600 * 1000 * 1000 * 1000)
      [first] ← liveRegs (rigTimer rig)
      fireReg first
      _ ← turn rig
      ran rig >>= (`shouldBe` ["distant"])
      microsecondsOf rig >>= (`shouldBe` [maxRegistration])
      length <$> allRegs (rigTimer rig) >>= (`shouldBe` 2)

    it "arms and cancels a registration with cancellation deferred, so the registration the backend made and the action that cancels it are never separated" $ do
      rig ← newRig
      _ ← admit rig "sleeper" OrdinaryClass OneShot
      _ ← admit rig "quick" OrdinaryClass OneShot
      script rig "sleeper" [waitFor "sleeper" 5000000]
      script rig "quick" [waitFor "quick" 1000000]
      state ← newIORef []
      -- The backend is asked, and its cancel action is run, under a mask: an
      -- asynchronous exception cannot fall between a registration existing and
      -- the timer holding the way to cancel it, nor between taking that way and
      -- using it.
      writeIORef (ftOnArm (rigTimer rig)) (getMaskingState >>= \seen → modifyIORef' state (seen :))
      _ ← turn rig
      readIORef state >>= (`shouldSatisfy` (\seen → not (null seen) && Unmasked `notElem` seen))
      cancelled ← newIORef []
      writeIORef (ftOnCancel (rigTimer rig)) (getMaskingState >>= \seen → modifyIORef' cancelled (seen :))
      -- A new earliest deadline cancels the live registration and arms another.
      script rig "late" [waitFor "late" 500000]
      _ ← admit rig "late" OrdinaryClass OneShot
      _ ← turn rig
      readIORef state >>= (`shouldSatisfy` ((>= 2) . length))
      _ ← stopScheduler (rigScheduler rig) (rigHost rig)
      liveRegs (rigTimer rig) >>= (`shouldSatisfy` null)
      readIORef cancelled >>= (`shouldSatisfy` (\seen → not (null seen) && Unmasked `notElem` seen))

    it "keeps a registration through an interruption while it is being armed: the cancellation waits, and the stop cancels it" $ do
      rig ← newRig
      _ ← admit rig "sleeper" OrdinaryClass OneShot
      script rig "sleeper" [waitFor "sleeper" 5000000]
      entered ← newEmptyMVar
      gate ← newEmptyMVar
      writeIORef (ftOnArm (rigTimer rig)) (putMVar entered () >> takeMVar gate)
      finished ← newEmptyMVar
      driver ← forkIO (try @SomeException (turn rig) >>= putMVar finished)
      takeMVar entered
      -- The backend is blocked inside the arming. The interruption cannot be taken
      -- there: it waits behind the registration, and arrives once the timer holds
      -- the way to cancel it.
      thrower ← forkIO (throwTo driver ThreadKilled)
      awaitDelivered thrower
      putMVar gate ()
      _ ← takeMVar finished
      writeIORef (ftOnArm (rigTimer rig)) (pure ())
      _ ← stopScheduler (rigScheduler rig) (rigHost rig)
      liveRegs (rigTimer rig) >>= (`shouldSatisfy` null)

    it "finishes cancelling a registration through an interruption, so a stop that was interrupted still leaves none live" $ do
      rig ← newRig
      _ ← admit rig "sleeper" OrdinaryClass OneShot
      script rig "sleeper" [waitFor "sleeper" 5000000]
      _ ← turn rig
      liveRegs (rigTimer rig) >>= (`shouldSatisfy` ((== 1) . length))
      entered <- newEmptyMVar
      gate <- newEmptyMVar
      writeIORef (ftOnCancel (rigTimer rig)) (putMVar entered () >> takeMVar gate)
      finished ← newEmptyMVar
      stopper ← forkIO (try @SomeException (stopScheduler (rigScheduler rig) (rigHost rig)) >>= putMVar finished)
      takeMVar entered
      thrower ← forkIO (throwTo stopper ThreadKilled)
      awaitDelivered thrower
      putMVar gate ()
      _ ← takeMVar finished
      atomically (schedulerClosed (rigScheduler rig)) >>= (`shouldBe` True)
      liveRegs (rigTimer rig) >>= (`shouldSatisfy` null)
      writeIORef (ftOnCancel (rigTimer rig)) (pure ())
      _ ← stopScheduler (rigScheduler rig) (rigHost rig)
      liveRegs (rigTimer rig) >>= (`shouldSatisfy` null)

    it "is armed with the system timer and wakes the owner when its time comes, with no sleep in the example" $ bounded $ do
      -- The production seam: the threaded runtime's timer manager and the real
      -- monotonic clock. The example blocks in STM until the wake arrives.
      timer ← newFakeTimer
      let config =
            SchedulerConfig
              { schedLabel = "system"
              , schedScope = scope
              , schedPolicy = fifoPolicy
              , schedBounds = defaultBounds
              , schedClock = monotonicSource
              , schedTimer = systemTimerBackend
              , schedStopRequested = pure False
              }
      _ ← pure timer
      newScheduler config >>= \case
        Left refused → failExample (show refused)
        Right scheduler → do
          seen ← newIORef []
          let host =
                TaskHost
                  { hostRun = \run → do
                      modifyIORef' seen (runResume run :)
                      pure $ case runSegmentNumber run of
                        0 → ReportWaitElapsed "waiter" (nanoseconds 2000000)
                        _ → ReportCompleted "waiter"
                  , hostClose = \_ → pure ()
                  }
          _ ← atomically (admitTask scheduler (taskSpec "waiter" OrdinaryClass OneShot))
          let untilResumed = do
                _ ← serviceTurn scheduler host
                readIORef seen >>= \case
                  [_, _] → pure ()
                  _ → atomically (awaitWork scheduler) >> untilResumed
          untilResumed
          reverse <$> readIORef seen >>= \case
            [Nothing, Just (ResumedElapsed elapsed)] → elapsed `shouldSatisfy` (>= nanoseconds 2000000)
            other → failExample ("unexpected resumes: " <> show other)
          _ ← stopScheduler scheduler host
          pure ()

    it "arms a distant registration with the system timer and cancels it at stop" $ do
      let config =
            SchedulerConfig
              { schedLabel = "system"
              , schedScope = scope
              , schedPolicy = fifoPolicy
              , schedBounds = defaultBounds
              , schedClock = monotonicSource
              , schedTimer = systemTimerBackend
              , schedStopRequested = pure False
              }
          host =
            TaskHost
              { hostRun = \_ → pure (ReportWaitElapsed "waiter" (nanoseconds (3600 * 1000 * 1000 * 1000)))
              , hostClose = \_ → pure ()
              }
      newScheduler config >>= \case
        Left refused → failExample (show refused)
        Right scheduler → do
          _ ← atomically (admitTask scheduler (taskSpec "waiter" OrdinaryClass OneShot))
          report ← serviceTurn scheduler host
          turnSegments report `shouldBe` 1
          stopped ← stopScheduler scheduler host
          stopControlsSettled stopped `shouldBe` 0
          atomically (schedulerClosed scheduler) >>= (`shouldBe` True)
  where
    readMost rig = readIORef (ftMostLive (rigTimer rig))
