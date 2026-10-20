-- | What the scheduler gives an owner that serves requests (LUA-7): a tick that does not begin
-- while the owner needs something complete before it, and a wait for a request that the owner
-- ends when it says the request has settled. Scripted segments under an injected clock; none
-- needs a VM and none sleeps.
module Test.LuaRuntime.Scheduler.Requests (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (replicateM_)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduler.Support
import Test.LuaRuntime.Support (failExample)

-- | A step that waits for the request the owner numbers this.
waitRequest ∷ Text → Word64 → Step
waitRequest name key = pure (ReportWaitRequest name key)

spec ∷ Spec
spec = describe "requests" $ do
  describe "a tick the owner needs something complete before" $ do
    it "is not begun by the grant that would reach it, which waits with the grants behind it until the need is met" $ do
      rig ← newRig
      atomically (holdTick (rigScheduler rig) 2)
      replicateM_ 3 (granted rig 10)
      _ ← turnsUntilIdle rig 8
      atomically (readTick (rigScheduler rig)) >>= (`shouldBe` 1)
      atomically (stepsOutstanding (rigScheduler rig)) >>= (`shouldBe` 2)
      -- The owner would sleep: a grant that cannot be applied is no work.
      workAvailable rig >>= (`shouldBe` False)
      atomically (releaseTick (rigScheduler rig) 2)
      workAvailable rig >>= (`shouldBe` True)
      _ ← turnsUntilIdle rig 8
      atomically (readTick (rigScheduler rig)) >>= (`shouldBe` 3)
      atomically (stepsOutstanding (rigScheduler rig)) >>= (`shouldBe` 0)

    it "needs as many releases as holds, and a release past none changes nothing" $ do
      rig ← newRig
      atomically (holdTick (rigScheduler rig) 1 >> holdTick (rigScheduler rig) 1)
      _ ← granted rig 10
      atomically (releaseTick (rigScheduler rig) 1)
      _ ← turnsUntilIdle rig 4
      atomically (readTick (rigScheduler rig)) >>= (`shouldBe` 0)
      atomically (tickIsHeld (rigScheduler rig) 1) >>= (`shouldBe` True)
      atomically (releaseTick (rigScheduler rig) 1 >> releaseTick (rigScheduler rig) 1 >> releaseTick (rigScheduler rig) 7)
      atomically (tickIsHeld (rigScheduler rig) 1) >>= (`shouldBe` False)
      _ ← turnsUntilIdle rig 4
      atomically (readTick (rigScheduler rig)) >>= (`shouldBe` 1)

    it "does not hold a tick that was begun before the need arose" $ do
      rig ← newRig
      _ ← granted rig 10
      _ ← turnsUntilIdle rig 4
      atomically (readTick (rigScheduler rig)) >>= (`shouldBe` 1)
      atomically (holdTick (rigScheduler rig) 1)
      _ ← granted rig 10
      _ ← turnsUntilIdle rig 4
      -- Tick 2 is the next one, and is not held.
      atomically (readTick (rigScheduler rig)) >>= (`shouldBe` 2)

  describe "a wait for a request" $ do
    it "is kept until the owner says the request has settled, and then wakes the task, handed nothing" $ do
      rig ← newRig
      identity ← admit rig "a" OrdinaryClass OneShot
      script rig "a" [waitRequest "a" 7, completed "a"]
      _ ← turnsUntilIdle rig 4
      phase rig identity >>= (`shouldBe` Just PhaseWaiting)
      atomically (wakeRequestWaiters (rigScheduler rig) (\_ → pure False)) >>= (`shouldBe` False)
      phase rig identity >>= (`shouldBe` Just PhaseWaiting)
      atomically (wakeRequestWaiters (rigScheduler rig) (pure . (== 7))) >>= (`shouldBe` True)
      _ ← turnsUntilIdle rig 4
      handed rig >>= (`shouldBe` [("a", 0, Nothing), ("a", 1, Nothing)])
      phase rig identity >>= (`shouldSatisfy` \case Just (PhaseEnded _) → True; _ → False)

    it "wakes the tasks whose requests have settled in the order their waits began, or in the order of the requests named" $ do
      rig ← newRig
      _ ← admit rig "a" OrdinaryClass OneShot
      _ ← admit rig "b" OrdinaryClass OneShot
      _ ← admit rig "c" OrdinaryClass OneShot
      script rig "a" [waitRequest "a" 1, completed "a"]
      script rig "b" [waitRequest "b" 2, completed "b"]
      script rig "c" [waitRequest "c" 3, completed "c"]
      _ ← turnsUntilIdle rig 6
      atomically (wakeRequestWaiters (rigScheduler rig) (\key → pure (key /= 1))) >>= (`shouldBe` True)
      _ ← turnsUntilIdle rig 6
      -- b's wait began before c's.
      ran rig >>= (`shouldBe` ["a", "b", "c", "b", "c"])
      atomically (wakeRequestWaitersOrdered (rigScheduler rig) [1]) >>= (`shouldBe` True)
      _ ← turnsUntilIdle rig 6
      ran rig >>= (`shouldBe` ["a", "b", "c", "b", "c", "a"])

    it "wakes the tasks in the order the requests are named when the owner names them" $ do
      rig ← newRig
      _ ← admit rig "a" OrdinaryClass OneShot
      _ ← admit rig "b" OrdinaryClass OneShot
      script rig "a" [waitRequest "a" 1, completed "a"]
      script rig "b" [waitRequest "b" 2, completed "b"]
      _ ← turnsUntilIdle rig 6
      atomically (wakeRequestWaitersOrdered (rigScheduler rig) [2, 1]) >>= (`shouldBe` True)
      _ ← turnsUntilIdle rig 6
      ran rig >>= (`shouldBe` ["a", "b", "b", "a"])

    it "leaves a task that was paused while it waited with its wait until it is resumed, and wakes it then" $ do
      rig ← newRig
      identity ← admit rig "a" OrdinaryClass OneShot
      script rig "a" [waitRequest "a" 1, completed "a"]
      _ ← turnsUntilIdle rig 4
      ticket ←
        atomically (requestControl (rigScheduler rig) identity RequestPause) >>= \case
          ControlAccepted accepted → pure accepted
          other → failExample ("the request was not accepted: " <> show other)
      _ ← turn rig
      _ ← atomically (pollControl ticket)
      phase rig identity >>= (`shouldBe` Just PhasePaused)
      -- The request settled while it was paused: nothing runs.
      atomically (wakeRequestWaiters (rigScheduler rig) (\_ → pure True)) >>= (`shouldBe` False)
      atomically (wakeRequestWaitersOrdered (rigScheduler rig) [1]) >>= (`shouldBe` False)
      atomically (requestWaiting (rigScheduler rig) (\_ → pure True)) >>= (`shouldBe` False)
      resumed ←
        atomically (requestControl (rigScheduler rig) identity RequestResume) >>= \case
          ControlAccepted accepted → pure accepted
          other → failExample ("the request was not accepted: " <> show other)
      _ ← turn rig
      _ ← atomically (pollControl resumed)
      atomically (requestWaiting (rigScheduler rig) (\_ → pure True)) >>= (`shouldBe` True)
      atomically (wakeRequestWaiters (rigScheduler rig) (\_ → pure True)) >>= (`shouldBe` True)
      _ ← turnsUntilIdle rig 4
      ran rig >>= (`shouldBe` ["a", "a"])

    it "is refused by an owner that cannot make it, failing the task with a typed failure and owing its continuation a close" $ do
      rig ← newRig
      identity ← admit rig "a" OrdinaryClass OneShot
      script rig "a" [pure (ReportWaitRefused "a" WaitRequestRefused)]
      report ← turn rig
      turnRefusedWaits report `shouldBe` [(identity, WaitRequestRefused)]
      phase rig identity >>= (`shouldSatisfy` \case Just (PhaseEnded _) → True; _ → False)
      closedTasks rig >>= (\closed → map fst closed `shouldBe` [identity])

    it "is forgotten with the task, which a stop cancels" $ do
      rig ← newRig
      identity ← admit rig "a" OrdinaryClass OneShot
      script rig "a" [waitRequest "a" 1, completed "a"]
      _ ← turnsUntilIdle rig 4
      ticket ←
        atomically (requestControl (rigScheduler rig) identity RequestStop) >>= \case
          ControlAccepted accepted → pure accepted
          other → failExample ("the request was not accepted: " <> show other)
      _ ← turn rig
      _ ← atomically (pollControl ticket)
      -- Nothing is left waiting for the request.
      atomically (requestWaiting (rigScheduler rig) (\_ → pure True)) >>= (`shouldBe` False)
      atomically (wakeRequestWaiters (rigScheduler rig) (\_ → pure True)) >>= (`shouldBe` False)
