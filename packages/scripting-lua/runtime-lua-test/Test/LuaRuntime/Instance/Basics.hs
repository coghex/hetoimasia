-- | What an instance is and does when nothing goes wrong: its @self@, its hooks
-- and its callbacks, the order they run in, and what a one-shot does.
module Test.LuaRuntime.Instance.Basics (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, void)
import qualified Data.Text as Text
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerStopped))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitDiagnostics, awaitEffect, awaitIdle, awaitScheduledTerminal, segmentsRun)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

stoppedOutcome ∷ InstanceOutcome → Bool
stoppedOutcome = \case InstanceStopped → True; _ → False

spec ∷ Spec
spec = describe "an instance" $ do
  it "runs each event's callback with its own self, in the order the events were accepted" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "basic" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      forM_ [1, 2, 3] (expectDelivered fixture owner "a")
      awaitEffect (sf fixture) "tick 1 n=3 seq=2 t=0 count=3"
      logged fixture
        >>= ( `shouldBe`
                [ "init 1"
                , "tick 1 n=1 seq=0 t=0 count=1"
                , "tick 1 n=2 seq=1 t=0 count=2"
                , "tick 1 n=3 seq=2 t=0 count=3"
                ]
            )
      retireScheduled owner
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stoppedOutcome
      logged fixture >>= (`shouldSatisfy` elem "shutdown 1 stopped")
      -- An update is part of the authoring model and is never due in this slice.
      logCount fixture "update" >>= (`shouldBe` 0)

  it "gives each instance of a module its own self while they share the module's own state" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "shared" [shared] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" sharedState
      _ ← admit fixture owner "b" sharedState
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      forM_ [1, 2] (expectDelivered fixture owner "a")
      awaitEffect (sf fixture) "shared 1 mine=2 all=2"
      expectDelivered fixture owner "b" 1
      awaitEffect (sf fixture) "shared 2 mine=1 all=3"
      logged fixture
        >>= (`shouldBe` ["shared 1 mine=1 all=1", "shared 1 mine=2 all=2", "shared 2 mine=1 all=3"])

  it "ends one instance without ending the others, the module or the VM, and what they share stays valid" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "removal" [shared] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" sharedState
      _ ← admit fixture owner "b" sharedState
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      expectDelivered fixture owner "a" 1
      expectDelivered fixture owner "b" 1
      awaitEffect (sf fixture) "shared 2 mine=1 all=2"
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe'` ControlApplied)
      resultOutcome <$> awaitSettled fixture "a" >>= (`shouldSatisfy` stoppedOutcome)
      -- The other instance and the module's own state are as they were.
      expectDelivered fixture owner "b" 2
      awaitEffect (sf fixture) "shared 2 mine=2 all=3"
      -- And a new instance of the same module starts from a fresh self.
      _ ← admit fixture owner "c" sharedState
      awaitPhase fixture owner "c" Active
      expectDelivered fixture owner "c" 1
      awaitEffect (sf fixture) "shared 3 mine=1 all=4"

  it "ends an instance whose module defines no hook as stopped, with nothing to run" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "bare" [noHooks] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "nohooks")
      awaitPhase fixture owner "a" Active
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe'` ControlApplied)
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stoppedOutcome
      terminationShutdown (resultTermination settled) `shouldBe` ShutdownAbsent
      logged fixture >>= (`shouldBe` [])

  it "runs a one-shot's run to completion after init, and its shutdown with the reason completed" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "oneshot" [oneShot] (testConfig instanceBounds') requiredPolicy
      _ ← admitWith fixture owner "a" (InstanceRequest (moduleNamed "oneshot") RunOnce (Just "a") OrdinaryClass ["tick"])
      awaitEffect (sf fixture) "run begin 1"
      -- A delivery while it runs is accepted, and discarded unstarted when it ends.
      expectDelivered fixture owner "a" 1
      awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
      void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` \case InstanceCompleted → True; _ → False
      resultPhase settled `shouldBe` Completed
      logged fixture >>= (`shouldBe` ["init 1", "run begin 1", "run end 1", "shutdown 1 completed"])
      let termination = resultTermination settled
      terminationConnections termination `shouldBe` 1
      terminationUnstarted termination `shouldBe` 1
      terminationShutdown termination `shouldBe` ShutdownRan

  it "refuses a one-shot whose module defines no run before any hook runs, naming the entry" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "norun" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admitWith fixture owner "a" (InstanceRequest (moduleNamed "echoer") RunOnce (Just "a") OrdinaryClass ["tick"])
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Failed
      case failureOf' settled of
        Just failure → do
          failureStage failure `shouldBe` StageInit
          case failureError failure of
            ErrorMissingEntry entry → entry `shouldBe` "run"
            other → fail ("expected the missing entry, found " <> show other)
        Nothing → fail "expected a failure"
      logged fixture >>= (`shouldBe` [])
      terminationShutdown (resultTermination settled) `shouldBe` ShutdownSkippedNoInit

  it "gives an instance only what it was granted: connecting to a source it was not granted is a script error that fails init" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "ungranted" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admitWith fixture owner "a" (InstanceRequest (moduleNamed "echoer") EventOnly (Just "a") OrdinaryClass [])
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Failed
      failure ← maybe (fail "expected a failure") pure (failureOf' settled)
      failureStage failure `shouldBe` StageInit
      failureMessage failure `shouldSatisfy` Text.isInfixOf "no event source named tick is granted"
      terminationConnections (resultTermination settled) `shouldBe` 0

  it "has an identity unique within the runtime that is never issued again" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      first ← startInstances fixture runtime "first" [echoer] (testConfig instanceBounds') requiredPolicy
      second ← startInstances fixture runtime "second" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture first "a" (moduleNamed "echoer")
      _ ← admit fixture second "b" (moduleNamed "echoer")
      a ← idOf fixture "a"
      b ← idOf fixture "b"
      a `shouldNotBe` b
      -- Not after it ended and was observed, and not after its owner retired.
      settleControl fixture first "a" InstanceStop >>= (`shouldBe'` ControlApplied)
      void (awaitSettled fixture "a")
      _ ← admit fixture first "c" (moduleNamed "echoer")
      c ← idOf fixture "c"
      c `shouldNotBe` a
      instanceLocal c `shouldNotBe` instanceLocal a
      retireScheduled first
      _ ← awaitSettled fixture "c"
      -- The second owner's numbering is its own, and its owner's identity differs.
      instanceOwner a `shouldNotBe` instanceOwner b

  it "reads as a coherent snapshot of its identity, owner, name, phase and queue" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "inspected" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      snapshot ← snapshotOf fixture owner "a"
      identity ← idOf fixture "a"
      case snapshot of
        Just held → do
          snapshotInstance held `shouldBe` identity
          snapshotOwner held `shouldBe` "inspected"
          snapshotName held `shouldBe` Just "a"
          snapshotPhase held `shouldBe` Active
          snapshotExecution held `shouldBe` ExecIdle
          snapshotKind held `shouldBe` EventOnly
          snapshotQueued held `shouldBe` 0
          snapshotConnections held `shouldBe` 1
        Nothing → fail "expected a snapshot"
      all' ← atomically (inspectInstances (scheduledEndpoint owner))
      map snapshotInstance all' `shouldBe` [identity]

  it "leaves an owner whose instances are all idle entering no Lua until something arrives" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "idle" [echoer, slow] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      _ ← admit fixture owner "b" (moduleNamed "slow")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      expectDelivered fixture owner "b" 1
      awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
      -- One instance paused and the other waiting for a tick nobody grants.
      settleControl fixture owner "a" InstancePause >>= (`shouldBe'` ControlApplied)
      awaitIdle (sf fixture)
      before ← length <$> segmentsRun (sf fixture)
      awaitIdle (sf fixture)
      after ← length <$> segmentsRun (sf fixture)
      after `shouldBe` before
      -- An event for the waiting one does not run it either, but a grant does.
      expectDelivered fixture owner "b" 2
      awaitIdle (sf fixture)
      length <$> segmentsRun (sf fixture) >>= (`shouldBe` before)
      void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))
      awaitEffect (sf fixture) "end 2 1"
  where
    shouldBe' = shouldBe
