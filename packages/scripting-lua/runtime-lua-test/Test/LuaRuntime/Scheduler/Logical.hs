-- | Logical time (requirement 7): the tick advances only on an application's
-- grants, grants are bounded and answered full, a waiting task resumes with the
-- tick it reached and the duration granted, and tick completion composes with
-- 'awaitSupervised'.
module Test.LuaRuntime.Scheduler.Logical (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Monad (forever, void)
import Data.Word (Word64)
import Hetoimasia.Runtime.Supervision (awaitSupervised)
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduler.Support
import Test.LuaRuntime.Support (bounded, failExample, withBoundary)

tick ∷ Rig → IO Word64
tick = atomically . readTick . rigScheduler

outstanding ∷ Rig → IO Int
outstanding = atomically . stepsOutstanding . rigScheduler

accepted ∷ GrantAnswer → IO GrantId
accepted = \case
  GrantAccepted grant → pure grant
  other → failExample ("the grant was not accepted: " <> show other)

spec ∷ Spec
spec = describe "logical time" $ do
  it "stays where it is across rounds of scheduling, expired budgets and elapsed deadlines, until a grant" $ do
    rig ← newRigWith defaultOptions {optBounds = defaultBounds {boundServiceBudget = Just (nanoseconds 10)}}
    _ ← admit rig "busy" OrdinaryClass Looped
    _ ← admit rig "sleeper" OrdinaryClass OneShot
    script rig "busy" (repeat (cost rig 10 (yielded "busy")))
    script rig "sleeper" [waitFor "sleeper" 5]
    segments ← runSegments rig 8
    -- The sleeper's deadline passed on the clock and it ran again; the budget
    -- expired turn after turn; none of it moved the tick.
    length (filter (== "sleeper") segments) `shouldBe` 2
    tick rig >>= (`shouldBe` 0)
    _ ← granted rig 7 >>= accepted
    _ ← turn rig
    tick rig >>= (`shouldBe` 1)

  it "answers a grant past the bound as full, a zero duration as not positive, and changes nothing" $ do
    rig ← newRigWith defaultOptions {optBounds = defaultBounds {boundOutstandingGrants = 2}}
    _ ← admit rig "waiter" OrdinaryClass OneShot
    script rig "waiter" [waitTicks "waiter" 9]
    _ ← turn rig
    first ← granted rig 10
    second ← granted rig 20
    first `shouldBe` GrantAccepted (GrantId 0)
    second `shouldBe` GrantAccepted (GrantId 1)
    granted rig 30 >>= (`shouldBe` GrantFull)
    granted rig 0 >>= (`shouldBe` GrantNotPositive)
    outstanding rig >>= (`shouldBe` 2)
    tick rig >>= (`shouldBe` 0)
    counts ← diagnostics rig
    (diagGrantsAccepted counts, diagGrantsRefused counts) `shouldBe` (2, 2)

  it "closes grants when the owner is asked to stop, and when the scheduler has stopped" $ do
    rig ← newRig
    setStop rig True
    granted rig 10 >>= (`shouldBe` GrantClosed)
    setStop rig False
    granted rig 10 >>= (`shouldBe` GrantAccepted (GrantId 0))
    _ ← stopScheduler (rigScheduler rig) (rigHost rig)
    granted rig 10 >>= (`shouldBe` GrantClosed)

  it "hands a waiting task the tick it reached and the logical duration granted since its wait began" $ do
    rig ← newRig
    _ ← admit rig "waiter" OrdinaryClass OneShot
    script rig "waiter" [waitTicks "waiter" 3]
    _ ← turn rig
    mapM_ (granted rig) [5, 7, 11]
    _ ← turnsUntilIdle rig 10
    handed rig >>= (`shouldBe` [("waiter", 0, Nothing), ("waiter", 1, Just (ResumedLogical 3 (nanoseconds 23)))])
    tick rig >>= (`shouldBe` 3)

  it "applies grants strictly in order, one tick each, and frees a slot only when the work they made due has finished" $ do
    rig ← newRigWith defaultOptions {optBounds = (quantaOf1 1) {boundOutstandingGrants = 2}}
    _ ← admit rig "busy" ControlClass Looped
    _ ← admit rig "one" OrdinaryClass OneShot
    _ ← admit rig "two" OrdinaryClass OneShot
    loop rig "busy"
    script rig "one" [waitTicks "one" 1]
    script rig "two" [waitTicks "two" 2]
    _ ← turn rig
    _ ← turn rig
    first ← granted rig 10 >>= accepted
    second ← granted rig 20 >>= accepted
    granted rig 30 >>= (`shouldBe` GrantFull)
    -- Nothing is applied until the owner reaches a boundary.
    tick rig >>= (`shouldBe` 0)
    _ ← turn rig
    -- The first grant was applied and woke "one", which ran and finished it, which
    -- freed its slot; the second was applied behind it and woke "two", which is
    -- ready and has not yet run, so the second grant is still outstanding.
    tick rig >>= (`shouldBe` 2)
    atomically (grantComplete (rigScheduler rig) first) >>= (`shouldBe` True)
    atomically (grantComplete (rigScheduler rig) second) >>= (`shouldBe` False)
    outstanding rig >>= (`shouldBe` 1)
    phase rig (taskIdAt 2) >>= (`shouldBe` Just PhaseReady)
    -- Capacity recovered when the first finished.
    third ← granted rig 40 >>= accepted
    _ ← turn rig
    atomically (grantComplete (rigScheduler rig) second) >>= (`shouldBe` True)
    atomically (grantComplete (rigScheduler rig) third) >>= (`shouldBe` True)
    outstanding rig >>= (`shouldBe` 0)
    tick rig >>= (`shouldBe` 3)
    -- "two" ran after a delay, and still got what its own grant gave it: not the
    -- tick or the duration of the grant applied since.
    handed rig
      >>= \seen →
        filter (\(name, _, _) → name /= "busy") seen
          `shouldBe` [ ("one", 0, Nothing)
                     , ("two", 0, Nothing)
                     , ("one", 1, Just (ResumedLogical 1 (nanoseconds 10)))
                     , ("two", 1, Just (ResumedLogical 2 (nanoseconds 30)))
                     ]

  it "fails a wait whose accumulated duration is not representable, with a typed failure, and applies the rest of the step" $ do
    rig ← newRig
    _ ← admit rig "quick" OrdinaryClass OneShot
    victim ← admit rig "victim" OrdinaryClass OneShot
    script rig "quick" [waitTicks "quick" 1]
    script rig "victim" [waitTicks "victim" 2]
    _ ← turn rig
    _ ← granted rig maxBound
    _ ← turn rig
    -- The first grant reached "quick", whose wait was one tick, and left "victim"
    -- holding the largest duration there is.
    late ← admit rig "late" OrdinaryClass OneShot
    script rig "late" [waitTicks "late" 1]
    _ ← turn rig
    _ ← granted rig 1
    report ← turn rig
    tick rig >>= (`shouldBe` 2)
    phase rig victim >>= (`shouldBe` Just (PhaseEnded OutcomeFailed))
    observe rig victim >>= \case
      Just (ResultFailed failure) → do
        reasonCode (failureReasonOf failure) `shouldBe` ValidationFault
        failureRecovery failure `shouldBe` RecoverySafe
      other → failExample ("expected a failed result, found " <> show other)
    map fst (turnFailures report) `shouldBe` [victim]
    -- "late" began waiting at the first tick and was woken by the second grant, with
    -- exactly what that grant gave it.
    handed rig >>= \seen → [resume | ("late", 1, resume) ← seen] `shouldBe` [Just (ResumedLogical 2 (nanoseconds 1))]
    phase rig late >>= (`shouldBe` Just (PhaseEnded OutcomeCompleted))
    -- The victim ended while its continuation was suspended, so it was closed.
    map fst <$> closedTasks rig >>= (`shouldBe` [victim])

  it "refuses a wait that cannot be represented, and fails its task with a typed failure rather than waiting" $ do
    rig ← newRig
    zeroTicks ← admit rig "zero-ticks" OrdinaryClass OneShot
    zeroTime ← admit rig "zero-time" OrdinaryClass OneShot
    script rig "zero-ticks" [waitTicks "zero-ticks" 0]
    script rig "zero-time" [waitFor "zero-time" 0]
    report ← turn rig
    turnRefusedWaits report `shouldBe` [(zeroTicks, WaitTicksNotPositive), (zeroTime, WaitDurationNotPositive)]
    mapM_ (\identity → phase rig identity >>= (`shouldBe` Just (PhaseEnded OutcomeFailed))) [zeroTicks, zeroTime]
    -- One tick on, a wait for as many ticks as there are would end past the last.
    _ ← granted rig 1
    overflow ← admit rig "overflow" OrdinaryClass OneShot
    script rig "overflow" [waitTicks "overflow" maxBound]
    _ ← turn rig
    _ ← turn rig
    phase rig overflow >>= (`shouldBe` Just (PhaseEnded OutcomeFailed))
    -- And one whose deadline is beyond the end of the clock.
    setClock rig (maxBound - 5)
    late ← admit rig "late" OrdinaryClass OneShot
    script rig "late" [waitFor "late" 10]
    final ← turn rig
    turnRefusedWaits final `shouldBe` [(late, WaitDeadlineOverflow)]
    observe rig late >>= \case
      Just (ResultFailed failure) → reasonDetail (failureReasonOf failure) `shouldSatisfy` (/= mempty)
      other → failExample ("expected a failed result, found " <> show other)
    counts ← diagnostics rig
    diagRefusedWaits counts `shouldBe` 4
    -- Each refused wait left a suspended continuation, which was closed once.
    map fst <$> closedTasks rig >>= (`shouldBe` [zeroTicks, zeroTime, overflow, late])
    -- Nothing waits, so nothing was armed.
    liveRegs (rigTimer rig) >>= (`shouldSatisfy` null)

  it "is observed as step completion through a supervised wait, without blocking a thread of the application's own" $ bounded $ do
    rig ← newRig
    _ ← admit rig "waiter" OrdinaryClass OneShot
    script rig "waiter" [waitTicks "waiter" 2]
    _ ← turn rig
    _ ← granted rig 5
    _ ← granted rig 6
    outstanding rig >>= (`shouldBe` 2)
    withBoundary $ \control _ → do
      done ← newEmptyMVar
      -- The owner's thread: sleep until there is work, then serve it.
      owner ← forkIO (forever (atomically (awaitWork (rigScheduler rig)) >> turn rig))
      void (forkIO (awaitSupervised control (awaitStepsComplete (rigScheduler rig)) >>= putMVar done))
      takeMVar done
      killThread owner
    tick rig >>= (`shouldBe` 2)
    outstanding rig >>= (`shouldBe` 0)
    handed rig >>= (`shouldBe` [("waiter", 0, Nothing), ("waiter", 1, Just (ResumedLogical 2 (nanoseconds 11)))])
  where
    quantaOf1 serviceQuantum = defaultBounds {boundQuanta = Quanta (Quantum serviceQuantum) (Quantum serviceQuantum) (Quantum serviceQuantum)}
