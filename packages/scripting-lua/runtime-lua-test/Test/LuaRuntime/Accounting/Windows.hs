-- | The wait for a scheduled owner's accounting (LUA-31, D-47) on owners that host script
-- instances: what it does not return before, each window on its own, and how it ends when the
-- owner fails or is stopped with an ending still owed.
--
-- A window is the time between the scheduler finishing a grant and the owner having accounted for
-- what the grant's work caused. In each example the others are open, a gate holds the one under
-- test, the wait is parked until the gate opens and returns after it, and where the window lies
-- after the grant finished the example shows tick completion has returned meanwhile.
module Test.LuaRuntime.Accounting.Windows (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException, throwIO)
import Control.Monad (forM_, void)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Accounting.Support
import Test.LuaRuntime.Instance.Lease.Support
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitDiagnostics, awaitEffect, awaitEntered, awaitIdle, awaitScheduledTerminal, releaseGate)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

-- | What a wait ended with, failing if it raised.
answer ∷ PendingWait → IO AccountingWait
answer waiting = resultOf waiting >>= either (\failure → fail ("the wait raised " <> show failure)) pure

-- | The owner's escalation, which waits at a gate and then isolates.
gatedEscalation ∷ Gate → InstanceConfig
gatedEscalation gate' = (testConfig instanceBounds') {instanceEscalate = \_ → passGate gate' >> pure Isolate}

spec ∷ Spec
spec = describe "waiting for a scheduled owner's accounting of the instances it hosts" $ do
  describe "each window on its own" $ do
    it "does not return while the owner closes a stopped instance's coroutine at a boundary after the grants finished" $ bounded $ do
      fixture ← newIFixture
      withBoundary $ \control runtime → do
        owner ← startInstances fixture runtime "closure" [stoppableClosing, holder] (testConfig instanceBounds') requiredPolicy
        _ ← admit fixture owner "c" (moduleNamed "stoppableclosing")
        awaitPhase fixture owner "c" Active
        expectDelivered fixture owner "c" 1
        awaitDiagnosticsWaiting owner
        -- The grant and the stop are both accepted while the owner is held, so the same boundary
        -- finishes the grant, which woke nothing, and applies the stop.
        waiting ←
          do
            holdOwner fixture owner
            grant owner 1
            _ ← expectControl fixture owner "c" InstanceStop
            captured ← beginWait control owner
            awaitPending captured
            releaseOwner fixture
            pure captured
        awaitEntered (sf fixture) "close"
        awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
        isPending waiting >>= (`shouldBe` True)
        releaseGate (sf fixture) "close"
        answer waiting >>= (`shouldBe` AccountingComplete)
        settled ← awaitSettled fixture "c"
        resultOutcome settled `shouldSatisfy` \case InstanceStopped → True; _ → False
        retireScheduled owner

    it "does not return while the owner closes the coroutine of a refused wait" $ bounded $ do
      fixture ← newIFixture
      withBoundary $ \control runtime → do
        owner ← startInstances fixture runtime "refused closure" [refusedClosing] (testConfig instanceBounds') requiredPolicy
        _ ← admit fixture owner "r" (moduleNamed "refusedclosing")
        awaitPhase fixture owner "r" Active
        expectDelivered fixture owner "r" 1
        awaitDiagnosticsWaiting owner
        grant owner 1
        waiting ← beginWait control owner
        awaitEntered (sf fixture) "close"
        awaitPending waiting
        releaseGate (sf fixture) "close"
        answer waiting >>= (`shouldBe` AccountingComplete)
        settled ← awaitSettled fixture "r"
        resultPhase settled `shouldBe` Failed
        retireScheduled owner

    it "does not return while the instance's shutdown runs, which is after tick completion has returned" $ bounded $ do
      fixture ← newIFixture
      withBoundary $ \control runtime → do
        owner ← startInstances fixture runtime "shutdown" [refusedGatedShutdown] (testConfig instanceBounds') requiredPolicy
        _ ← admit fixture owner "s" (moduleNamed "refusedgatedshutdown")
        awaitPhase fixture owner "s" Active
        expectDelivered fixture owner "s" 1
        awaitDiagnosticsWaiting owner
        grant owner 1
        waiting ← beginWait control owner
        awaitEntered (sf fixture) "shutdown"
        -- The grant has finished and the owner is inside the hook.
        awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
        awaitPending waiting
        isPending waiting >>= (`shouldBe` True)
        releaseGate (sf fixture) "shutdown"
        answer waiting >>= (`shouldBe` AccountingComplete)
        settled ← awaitSettled fixture "s"
        resultPhase settled `shouldBe` Failed
        retireScheduled owner

    it "does not return while a provider owes a retirement, and returns when it completes with nothing else happening" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime "retirement" [refusedLeased] leaseConfig requiredPolicy
        _ ← admit base owner "r" (moduleNamed "refusedleased")
        awaitPhase base owner "r" Active
        liveFor fixture "r" 1
        expectDelivered base owner "r" 1
        awaitDiagnosticsWaiting owner
        grant owner 1
        -- The ending is parked on the provider; the grant is finished; the owner is idle.
        awaitSummary fixture "r" ((== 1) . summaryPending)
        awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
        awaitIdle (sf base)
        waiting ← beginWait control owner
        awaitPending waiting
        tickOf base "r" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
        completeRetirement fixture "async-res"
        answer waiting >>= (`shouldBe` AccountingComplete)
        settled ← awaitSettled base "r"
        resultPhase settled `shouldBe` Failed
        retireScheduled owner

    it "does not return while the application's escalation runs, though the instance's settlement can be read" $ bounded $ do
      fixture ← newIFixture
      escalation ← newGate
      withBoundary $ \control runtime → do
        owner ← startInstances fixture runtime "escalation" [refusedAfterTick] (gatedEscalation escalation) requiredPolicy
        _ ← admit fixture owner "e" (moduleNamed "refusedaftertick")
        awaitPhase fixture owner "e" Active
        expectDelivered fixture owner "e" 1
        awaitDiagnosticsWaiting owner
        grant owner 1
        waiting ← beginWait control owner
        awaitGateEntered escalation
        awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
        -- Settled, and readable, while the application is still being told.
        settled ← awaitSettled fixture "e"
        resultPhase settled `shouldBe` Failed
        awaitPending waiting
        isPending waiting >>= (`shouldBe` True)
        openGate escalation
        answer waiting >>= (`shouldBe` AccountingComplete)
        retireScheduled owner

    it "covers the endings already begun when no grant is outstanding, and returns once the application has been told of a failure" $ bounded $ do
      fixture ← newIFixture
      escalation ← newGate
      withBoundary $ \control runtime → do
        owner ← startInstances fixture runtime "no grant" [failCallback] (gatedEscalation escalation) requiredPolicy
        _ ← admit fixture owner "f" (moduleNamed "failcallback")
        awaitPhase fixture owner "f" Active
        expectDelivered fixture owner "f" 1
        awaitGateEntered escalation
        settled ← awaitSettled fixture "f"
        resultPhase settled `shouldBe` Failed
        waiting ← beginWait control owner
        awaitPending waiting
        isPending waiting >>= (`shouldBe` True)
        openGate escalation
        answer waiting >>= (`shouldBe` AccountingComplete)
        -- With every instance ended and told of, a wait returns at once.
        awaitScheduledAccounting control owner >>= (`shouldBe` AccountingComplete)
        retireScheduled owner

  describe "the final boundary of the captured grants" $ do
    it "covers an ending that a grant accepted after the snapshot caused in that boundary, and holds for its retirement while the owner is idle" $ bounded $ do
      fixture ← newLFix 4
      escalation ← newGate
      let base = lfBase fixture
          config = leaseConfig {instanceEscalate = \_ → passGate escalation >> pure Isolate}
          endpoint = scheduledEndpoint
      withBoundary $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime "cutoff" [overflowLeased, windowTasks] config requiredPolicy
        _ ← admit base owner "v" (moduleNamed "overflowleased")
        awaitPhase base owner "v" Active
        liveFor fixture "v" 1
        expectDelivered base owner "v" 1
        -- The victim waits two ticks; the blocker waits one and then holds the owner at a gate.
        awaitDiagnosticsWaiting owner
        admitScheduledTask (endpoint owner) (blockAfterTicks "b" 1) >>= \case
          TaskAccepted _ _ → pure ()
          other → fail ("expected the task accepted, found " <> show other)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 2)
        -- The first grant gives the victim the largest duration there is and wakes the blocker, which
        -- keeps the grant unfinished. The wait captures it, and a second grant is accepted after.
        _ ← grantScheduledStep (endpoint owner) (nanoseconds maxBound)
        awaitEntered (sf base) "b"
        waiting ← beginWait control owner
        awaitPending waiting
        grant owner 1
        -- When the blocker finishes, the same boundary finishes the first grant and applies the second,
        -- which the victim's wait cannot take: the instance fails, in the final boundary, and parks on
        -- the retirement of what it held.
        releaseGate (sf base) "b"
        awaitSummary fixture "v" ((== 1) . summaryPending)
        awaitIdle (sf base)
        awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
        isPending waiting >>= (`shouldBe` True)
        completeRetirement fixture "async-res"
        -- Settled, and the application is being told: still owed.
        awaitGateEntered escalation
        isPending waiting >>= (`shouldBe` True)
        openGate escalation
        answer waiting >>= (`shouldBe` AccountingComplete)
        settled ← awaitSettled base "v"
        resultPhase settled `shouldBe` Failed
        retireScheduled owner

  describe "when its owner ends with an ending owed" $ do
    forM_ [("stopped", retireScheduled), ("cancelled", cancelScheduled)] $ \(label, end) →
      it ("ends with a " <> label <> " owner once it has ended, and never as a completion, though its last ending is accounted for during the exit") $ bounded $ do
        fixture ← newLFix 4
        let base = lfBase fixture
        withBoundary $ \control runtime → providersFinish fixture $ do
          owner ← startLeased fixture runtime ("owed " <> Text.pack label) [asyncHolder] leaseConfig requiredPolicy
          _ ← admit base owner "a" (moduleNamed "asyncholder")
          awaitPhase base owner "a" Active
          liveFor fixture "a" 1
          expectDelivered base owner "a" 1
          awaitEffect (sf base) "again Retiring"
          settleControl base owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
          awaitPhase base owner "a" Stopping
          waiting ← beginWait control owner
          awaitPending waiting
          end owner
          -- The owner stays live until the provider has proved its work over, and a stopping owner
          -- neither completes the wait nor ends it: the ending it owes is not accounted for, and it
          -- has not ended.
          isPending waiting >>= (`shouldBe` True)
          completeRetirement fixture "async-res"
          answer waiting >>= (`shouldBe` AccountingOwnerEnded)
          void (awaitScheduledTerminal control owner)
          awaitScheduledAccounting control owner >>= (`shouldBe` AccountingOwnerEnded)

    forM_ [("an escalating answer", pure Escalate), ("a raising callback", throwIO (Broken "callback"))] $ \(label, told) → do
      let config = (testConfig instanceBounds') {instanceEscalate = \_ → told}
          recognizes failure = isJust (fromException failure ∷ Maybe InstanceEscalated) || brokenIs "callback" failure
      it ("rethrows the fatal failure " <> label <> " ends a required owner with, and never completes") $ bounded $ do
        fixture ← newIFixture
        ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
          owner ← startInstances fixture runtime "required" [refusedAfterTick] config requiredPolicy
          _ ← admit fixture owner "e" (moduleNamed "refusedaftertick")
          awaitPhase fixture owner "e" Active
          expectDelivered fixture owner "e" 1
          awaitDiagnosticsWaiting owner
          grant owner 1
          void (awaitScheduledAccounting control owner)
          throwIO (userError "the wait returned instead of rethrowing the fatal failure")
        raised `shouldSatisfy` \failure → recognizes failure

      it ("ends with an optional owner that " <> label <> " ends, once supervision has handled it, and never as a completion") $ bounded $ do
        fixture ← newIFixture
        withBoundary $ \control runtime → do
          owner ← startInstances fixture runtime "optional" [refusedAfterTick] config (optionalPolicy recognizes)
          _ ← admit fixture owner "e" (moduleNamed "refusedaftertick")
          awaitPhase fixture owner "e" Active
          expectDelivered fixture owner "e" 1
          awaitDiagnosticsWaiting owner
          grant owner 1
          waiting ← beginWait control owner
          answer waiting >>= (`shouldBe` AccountingOwnerEnded)
          awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
