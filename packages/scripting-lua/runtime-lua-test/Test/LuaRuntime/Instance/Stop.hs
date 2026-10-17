-- | How an instance ends: through the one path every end takes, whatever began it,
-- and what each way revokes, discards and runs; and what an owner's own end does
-- to the instances it still holds.
module Test.LuaRuntime.Instance.Stop (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM, forM_)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerStopped))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitCancelled, ExitFailed), Progress (NotStarted, Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect, awaitScheduledTerminal, cancelQueued)
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, requiredPolicy, withBoundary)

stopped ∷ InstanceOutcome → Bool
stopped = \case InstanceStopped → True; _ → False

spec ∷ Spec
spec = describe "stopping" $ do
  it "retires each live instance in order, with the reason stopped, before the VM is closed: a paused one, a suspended one and an idle one" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "retire" [echoer, closing] (testConfig instanceBounds') requiredPolicy
      forM_ [("a", "echoer"), ("b", "closing"), ("c", "echoer")] $ \(name, ref) → admit fixture owner name (moduleNamed ref)
      forM_ ["a", "b", "c"] $ \name → awaitPhase fixture owner name Active
      expectDelivered fixture owner "b" 1
      awaitDiagnosticsWaiting owner
      settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
      retireScheduled owner
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      settlements ← forM ["a", "b", "c"] (awaitSettled fixture)
      forM_ settlements $ \settled → do
        resultOutcome settled `shouldSatisfy` stopped
        terminationShutdown (resultTermination settled) `shouldBe` ShutdownRan
      map (terminationClosed . resultTermination) settlements `shouldBe` [0, 1, 0]
      entries ← logged fixture
      -- Each hook ran once, and the suspended callback was closed before its hook.
      forM_ ["shutdown 1 stopped", "shutdown 2 stopped", "shutdown 3 stopped", "closed 2"] $ \entry →
        length (filter (== entry) entries) `shouldBe` 1
      let position entry = length (takeWhile (/= entry) entries)
      position "closed 2" `shouldSatisfy` (< position "shutdown 2 stopped")

  it "counts what each end revoked and discarded: an idle stop, a failed callback with events queued, and the owner's retirement" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "counts" [echoer, failCallback, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "idle" (moduleNamed "echoer")
      _ ← admit fixture owner "failing" (moduleNamed "failcallback")
      _ ← admit fixture owner "kept" (moduleNamed "echoer")
      awaitPhase fixture owner "idle" Active
      awaitPhase fixture owner "failing" Active
      awaitPhase fixture owner "kept" Active
      settleControl fixture owner "idle" InstanceStop >>= (`shouldBe` ControlApplied)
      idle ← awaitSettled fixture "idle"
      terminationConnections (resultTermination idle) `shouldBe` 1
      terminationUnstarted (resultTermination idle) `shouldBe` 0
      -- Three events are accepted while the owner is held; the first one fails and
      -- the other two never begin.
      holdOwner fixture owner
      forM_ [1, 2, 3] (expectDelivered fixture owner "failing")
      releaseOwner fixture
      failing ← awaitSettled fixture "failing"
      resultPhase failing `shouldBe` Failed
      let termination = resultTermination failing
      terminationConnections termination `shouldBe` 1
      terminationUnstarted termination `shouldBe` 2
      terminationShutdown termination `shouldBe` ShutdownRan
      -- What the owner's retirement revokes is counted the same way.
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      kept ← awaitSettled fixture "kept"
      resultOutcome kept `shouldSatisfy` stopped
      terminationConnections (resultTermination kept) `shouldBe` 1

  it "never runs shutdown again for a repeated stop or for the owner's retirement after it" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "once" [echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      _ ← awaitSettled fixture "a"
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      logCount fixture "shutdown 1 stopped" >>= (`shouldBe` 1)
      logCount fixture "shutdown 1 completed" >>= (`shouldBe` 0)

  it "runs shutdown once for a one-shot stopped while its run waits, and never resumes the run" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "stopped one-shot" [oneShot] (testConfig instanceBounds') requiredPolicy
      _ ← admitWith fixture owner "a" (InstanceRequest (moduleNamed "oneshot") RunOnce (Just "a") OrdinaryClass ["tick"])
      awaitEffect (sf fixture) "run begin 1"
      awaitDiagnosticsWaiting owner
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      terminationClosed (resultTermination settled) `shouldBe` 1
      logged fixture >>= (`shouldBe` ["init 1", "run begin 1", "shutdown 1 stopped"])

  it "runs no hook and settles as discarded when the owner is cancelled, however far each instance had come" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "cancelled" [echoer, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "begun" (moduleNamed "echoer")
      awaitPhase fixture owner "begun" Active
      -- One more is admitted while the owner is held, so it is accepted and not begun.
      holdOwner fixture owner
      _ ← admit fixture owner "unbegun" (moduleNamed "echoer")
      cancelQueued owner
      releaseOwner fixture
      begun ← awaitSettled fixture "begun"
      unbegun ← awaitSettled fixture "unbegun"
      resultOutcome begun `shouldSatisfy` \case InstanceDiscarded (Discard ExitCancelled Started) → True; _ → False
      resultOutcome unbegun `shouldSatisfy` \case InstanceDiscarded (Discard ExitCancelled NotStarted) → True; _ → False
      terminationShutdown (resultTermination begun) `shouldBe` ShutdownSkippedUnsafe
      -- Only what ran before ran: no shutdown, and nothing for the one never begun.
      logged fixture >>= (`shouldBe` ["init 1"])

  it "stops an instance accepted and not yet begun when the owner retires, running none of its hooks" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "unbegun" [echoer, holder] (testConfig instanceBounds') requiredPolicy
      holdOwner fixture owner
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      retireScheduled owner
      releaseOwner fixture
      _ ← awaitScheduledTerminal control owner
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      terminationShutdown (resultTermination settled) `shouldBe` ShutdownSkippedNoInit
      logged fixture >>= (`shouldBe` [])

  it "settles every instance when a hook raises a failure of the host as the owner retires: that one as discarded, the owner's failure unconverted" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "host shutdown" [hostShutdown, echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "hostshutdown")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      retireScheduled owner
      awaitScheduledTerminal control owner
    raised `shouldSatisfy` brokenIs "boom"
    a ← tickOf fixture "a" >>= pollInstance
    fmap resultOutcome a `shouldSatisfy` \case
      Just (InstanceDiscarded (Discard ExitFailed Started)) → True
      _ → False
    -- The owner is failing, so no hook runs for the instance after it: it is discarded.
    b ← tickOf fixture "b" >>= pollInstance
    fmap resultOutcome b `shouldSatisfy` \case
      Just (InstanceDiscarded (Discard ExitFailed Started)) → True
      _ → False
    logCount fixture "shutdown 2 stopped" >>= (`shouldBe` 0)
