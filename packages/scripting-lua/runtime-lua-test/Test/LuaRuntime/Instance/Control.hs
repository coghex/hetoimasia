-- | What the application's requests do to an instance: pause and the events it
-- retains, resume and the order it restores, stop and what it closes before the
-- hook, repeated and contradictory requests, and every refusal.
module Test.LuaRuntime.Instance.Control (spec) where

import Control.Monad (forM, forM_, replicateM_)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect, awaitEntered, awaitIdle, cancelQueued, releaseGate)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

spec ∷ Spec
spec = describe "control" $ do
  it "freezes a callback suspended at a wait when paused, runs nothing while paused, and resumes it ahead of the retained events, with new ones behind" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "pause" [slow] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "slow")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      forM_ [2, 3] (expectDelivered fixture owner "a")
      settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
      snapshotOf fixture owner "a"
        >>= (`shouldSatisfy` \held → fmap snapshotPhase held == Just Paused && fmap snapshotExecution held == Just ExecWaiting)
      -- The wait ends, and nothing runs: the continuation is frozen where it is.
      grantOne control owner
      expectDelivered fixture owner "a" 4
      awaitIdle (sf fixture)
      logged fixture >>= (`shouldBe` ["begin 1 1"])
      snapshotOf fixture owner "a" >>= (`shouldSatisfy` \held → fmap snapshotQueued held == Just 3)
      -- Resumed, the suspended callback finishes before another starts, the retained
      -- events follow in the order they were accepted, and a new one is behind them.
      settleControl fixture owner "a" InstanceResume >>= (`shouldBe` ControlApplied)
      awaitEffect (sf fixture) "begin 1 2"
      expectDelivered fixture owner "a" 5
      replicateM_ 4 (grantOne control owner)
      awaitEffect (sf fixture) "end 1 5"
      logged fixture
        >>= ( `shouldBe`
                [ "begin 1 1"
                , "end 1 1"
                , "begin 1 2"
                , "end 1 2"
                , "begin 1 3"
                , "end 1 3"
                , "begin 1 4"
                , "end 1 4"
                , "begin 1 5"
                , "end 1 5"
                ]
            )

  it "stops while paused: it closes the suspended callback before shutdown, discards what had not begun with counts, and runs shutdown once" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "stop paused" [closing, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "closing")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      forM_ [2, 3] (expectDelivered fixture owner "a")
      settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
      -- Two requests are taken together, while the owner is held: the first begins the
      -- stop and the second finds it begun.
      holdOwner fixture owner
      first ← expectControl fixture owner "a" InstanceStop
      second ← expectControl fixture owner "a" InstanceStop
      releaseOwner fixture
      results ← forM [first, second] waitInstanceControl
      -- The stop ends the instance as it is applied, so the second finds it ended.
      results `shouldBe` [ControlApplied, ControlNoLongerApplicable]
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Stopped
      resultOutcome settled `shouldSatisfy` \case InstanceStopped → True; _ → False
      let termination = resultTermination settled
      terminationConnections termination `shouldBe` 1
      terminationUnstarted termination `shouldBe` 2
      terminationClosed termination `shouldBe` 1
      terminationShutdown termination `shouldBe` ShutdownRan
      -- Closed, and not resumed, before the hook; and the hook ran once.
      logged fixture >>= (`shouldBe` ["begin 1 1", "closed 1", "shutdown 1 stopped"])

  it "settles contradictory requests in the order accepted, and none resurrects an instance or undoes a stop" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "contradictions" [slow, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "slow")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      holdOwner fixture owner
      let asked =
            [ InstancePause
            , InstancePause
            , InstanceResume
            , InstanceResume
            , InstanceStop
            , InstanceResume
            , InstancePause
            , InstanceStop
            ]
      receipts ← forM asked (expectControl fixture owner "a")
      releaseOwner fixture
      results ← forM receipts waitInstanceControl
      results
        `shouldBe` [ ControlApplied
                   , ControlAlreadyInState
                   , ControlApplied
                   , ControlAlreadyInState
                   , ControlApplied
                   , ControlNoLongerApplicable
                   , ControlNoLongerApplicable
                   , ControlNoLongerApplicable
                   ]
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Stopped
      logCount fixture "shutdown 1 stopped" >>= (`shouldBe` 1)
      -- Ended, it is a stale target, and nothing a late request says changes that.
      askControl fixture owner "a" InstanceResume >>= (`shouldSatisfy` \case InstanceControlUnknown → True; _ → False)
      askControl fixture owner "a" InstanceStop >>= (`shouldSatisfy` \case InstanceControlUnknown → True; _ → False)
      deliverTick fixture owner "a" 2 >>= (`shouldBe` DeliveryUnknownTarget)

  it "settles a request that finds its instance already ended as no longer applicable, not as already in that state" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "ended first" [echoer, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      holdOwner fixture owner
      -- Nothing is in flight, so the first stop ends the instance as it is applied.
      receipts ← forM [InstanceStop, InstanceStop, InstanceResume] (expectControl fixture owner "a")
      releaseOwner fixture
      results ← forM receipts waitInstanceControl
      results `shouldBe` [ControlApplied, ControlNoLongerApplicable, ControlNoLongerApplicable]

  it "refuses what it cannot take: an identity it never issued, another owner's, a full set of reservations, a closed owner" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "refusals" [echoer, gateShutdown] (testConfig instanceBounds' {boundInstanceControls = 1}) requiredPolicy
      other ← startInstances fixture runtime "other" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      _ ← admit fixture owner "closing" (moduleNamed "gateshutdown")
      _ ← admit fixture other "elsewhere" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "closing" Active
      a ← idOf fixture "a"
      elsewhere ← idOf fixture "elsewhere"
      let endpoint = scheduledEndpoint owner
          unknown = \case InstanceControlUnknown → True; _ → False
      requestInstanceControl endpoint elsewhere InstancePause >>= (`shouldSatisfy` unknown)
      requestInstanceControl endpoint (InstanceId (instanceOwner a) 9999) InstancePause >>= (`shouldSatisfy` unknown)
      -- One reservation, held until its settlement is observed or abandoned.
      held ← expectControl fixture owner "a" InstancePause
      askControl fixture owner "a" InstanceResume >>= (`shouldSatisfy` \case InstanceControlFull → True; _ → False)
      waitInstanceControl held >>= (`shouldBe` ControlApplied)
      taken ← expectControl fixture owner "a" InstanceResume
      waitInstanceControl taken >>= (`shouldBe` ControlApplied)
      -- Abandoned, it gives its reservation back as it settles.
      forgottenReceipt ← expectControl fixture owner "a" InstancePause
      forgetInstanceControl forgottenReceipt
      askUntilTaken fixture owner "a" InstanceResume >>= (`shouldSatisfy` \case InstanceControlAccepted _ → True; _ → False)
      -- An owner that has begun to retire takes no more, with an instance still in its hook.
      retireScheduled owner
      awaitEntered (sf fixture) "shutdown"
      askControl fixture owner "closing" InstancePause >>= (`shouldSatisfy` \case InstanceControlClosed → True; _ → False)
      releaseGate (sf fixture) "shutdown"

  it "settles a request the owner never applied, once, as no longer applicable, whether the owner retired or failed" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      retiring ← startInstances fixture runtime "retiring" [echoer, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture retiring "a" (moduleNamed "echoer")
      awaitPhase fixture retiring "a" Active
      holdOwner fixture retiring
      receipt ← expectControl fixture retiring "a" InstancePause
      retireScheduled retiring
      releaseOwner fixture
      waitInstanceControl receipt >>= (`shouldBe` ControlNoLongerApplicable)
      pollInstanceControl receipt >>= (`shouldBe` Just ControlNoLongerApplicable)
    -- The same when the owner is cancelled while it is held, on a fixture of its own.
    failing ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances failing runtime "cancelled" [echoer, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit failing owner "a" (moduleNamed "echoer")
      awaitPhase failing owner "a" Active
      holdOwner failing owner
      receipt ← expectControl failing owner "a" InstanceStop
      cancelQueued owner
      releaseOwner failing
      waitInstanceControl receipt >>= (`shouldBe` ControlNoLongerApplicable)
      settled ← awaitSettled failing "a"
      resultOutcome settled `shouldSatisfy` \case InstanceDiscarded _ → True; _ → False
