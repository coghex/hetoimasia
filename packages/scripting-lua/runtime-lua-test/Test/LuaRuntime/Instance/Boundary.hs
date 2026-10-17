-- | The boundaries of the owner's service of its instances: where a request is
-- applied, what survives a failure of the host in the middle of servicing, what the
-- scheduler's capacity can refuse, and what a script may and may not reach.
module Test.LuaRuntime.Instance.Boundary (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM, forM_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitFailed), Progress (Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support
  ( awaitDiagnostics
  , awaitEffect
  , awaitEntered
  , awaitScheduledTerminal
  , defaultSchedulerBounds
  , releaseGate
  , request
  )
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, requiredPolicy, withBoundary)

stopped ∷ InstanceOutcome → Bool
stopped = \case InstanceStopped → True; _ → False

spec ∷ Spec
spec = describe "the boundaries of service" $ do
  it "settles every request of a batch, and the ones after it, when ending an instance raises a failure of the host" $ bounded $ do
    fixture ← newIFixture
    receipts ← newIORef []
    ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "batch" [hostShutdown, echoer, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "hostshutdown")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      holdOwner fixture owner
      -- The first stop's hook fails the way the host fails; the others are behind it.
      forM_ [("a", InstanceStop), ("a", InstanceStop), ("b", InstancePause), ("b", InstanceStop)] $ \(name, how) →
        expectControl fixture owner name how >>= \receipt → modifyIORef' receipts (<> [receipt])
      releaseOwner fixture
      awaitScheduledTerminal control owner
    raised `shouldSatisfy` brokenIs "boom"
    held ← readIORef receipts
    -- None is left waiting: the one that began settled as it began, the rest as no
    -- longer applicable.
    results ← forM held pollInstanceControl
    results
      `shouldBe` [ Just ControlApplied
                 , Just ControlNoLongerApplicable
                 , Just ControlNoLongerApplicable
                 , Just ControlNoLongerApplicable
                 ]

  it "keeps a pause and the stop behind it when the scheduler can hold one request at a time, and ends the instance" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      let bounds = defaultSchedulerBounds {boundControlRequests = 1}
      owner ←
        startWith fixture runtime $
          instanceSpec fixture "one reservation" [slow, holder] (testConfig instanceBounds') requiredPolicy bounds
      _ ← admit fixture owner "a" (moduleNamed "slow")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      holdOwner fixture owner
      pause ← expectControl fixture owner "a" InstancePause
      stop ← expectControl fixture owner "a" InstanceStop
      releaseOwner fixture
      results ← forM [pause, stop] waitInstanceControl
      results `shouldBe` [ControlApplied, ControlApplied]
      -- The scheduler refused the second for want of a reservation, and it was asked
      -- again: the instance ends, and is not left paused and stopping for good.
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      terminationClosed (resultTermination settled) `shouldBe` 1
      logCount fixture "shutdown 1 stopped" >>= (`shouldBe` 1)

  it "starts shutdown once even when it raised a failure of the host in a suspended instance's retirement" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "twice" [waitHostShutdown] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "waithostshutdown")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      retireScheduled owner
      awaitScheduledTerminal control owner
    raised `shouldSatisfy` brokenIs "boom"
    logCount fixture "shutdown" >>= (`shouldBe` 1)
    a ← tickOf fixture "a" >>= pollInstance
    fmap resultOutcome a `shouldSatisfy` \case
      Just (InstanceDiscarded (Discard ExitFailed Started)) → True
      _ → False

  it "keeps what closing a coroutine raised when ending its instance raises a failure of the host as well" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext context _ ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "both" [badCloseHostShutdown] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "badclosehostshutdown")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      _ ← settleControl fixture owner "a" InstanceStop
      awaitScheduledTerminal control owner
    -- Supervision receives the closing handler's failure, which was not lost to the
    -- failure the shutdown raised, and the failure of the host beside it.
    let labels = map cleanupFailureLabel (cleanupFailuresInContext context)
    length labels `shouldSatisfy` (>= 2)

  it "applies a request at the next segment boundary, not only when a turn ends: a callback released at a gate does not run on after a stop" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "boundary" [gated] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "gated")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitEntered (sf fixture) "cb"
      -- Accepted while the callback is inside its first segment. When it yields, the
      -- turn has more segments in its quantum, and none of them is this callback's.
      receipt ← expectControl fixture owner "a" InstanceStop
      releaseGate (sf fixture) "cb"
      waitInstanceControl receipt >>= (`shouldBe` ControlApplied)
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      terminationClosed (resultTermination settled) `shouldBe` 1
      logged fixture >>= (`shouldBe` [])

  it "lets only the running instance connect itself: a script that names another instance's number is refused" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "forgery" [forger, echoer] (testConfig instanceBounds') requiredPolicy
      -- The first instance asks to connect the second, whose number it can predict.
      _ ← admit fixture owner "a" (moduleNamed "forger")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      logged fixture >>= (`shouldSatisfy` elem "forged false")
      -- The second connected itself, as it would have, and receives its events.
      expectDelivered fixture owner "b" 1
      awaitEffect (sf fixture) "tick 1 n=1 seq=0 t=0 count=1"

  it "counts an invocation stopped before its first segment as an unstarted one discarded, not as a coroutine closed" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "unbegun" [echoer, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      holdOwner fixture owner
      -- The event is taken and its callback admitted, and the stop is applied before the
      -- callback has run a segment.
      expectDelivered fixture owner "a" 1
      receipt ← expectControl fixture owner "a" InstanceStop
      releaseOwner fixture
      waitInstanceControl receipt >>= (`shouldBe` ControlApplied)
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      let termination = resultTermination settled
      terminationUnstarted termination `shouldBe` 1
      terminationClosed termination `shouldBe` 0
      logged fixture >>= (`shouldBe` ["init 1", "shutdown 1 stopped"])

  it "wakes for an invocation the scheduler had no room for when ordinary work's results are observed" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      let bounds = defaultSchedulerBounds {boundRetainedResults = 2}
      owner ←
        startWith fixture runtime $
          instanceSpec fixture "room" [echoer, plainModule] (testConfig (InstanceBounds 1 1 8 8)) requiredPolicy bounds
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      first ← admitScheduledTask (scheduledEndpoint owner) (request "once" [VText "first"] OrdinaryClass OneShot Nothing) >>= ordinary
      second ← admitScheduledTask (scheduledEndpoint owner) (request "once" [VText "second"] OrdinaryClass OneShot Nothing) >>= ordinary
      -- Both have finished and nobody has read them: they hold every reservation.
      awaitDiagnostics owner (\counts → diagCompleted counts >= 2)
      expectDelivered fixture owner "a" 1
      -- The owner has looked for room for its callback and found none.
      awaitDiagnostics owner (\counts → diagRejected counts >= 1)
      logged fixture >>= (`shouldBe` ["init 1", "first", "second"])
      -- Reading them gives the room back, and the owner wakes for the event alone.
      _ ← waitTask first
      _ ← waitTask second
      awaitEffect (sf fixture) "tick 1 n=1 seq=0 t=0 count=1"
  where
    ordinary = \case
      TaskAccepted _ ticket → pure ticket
      other → fail ("expected the task accepted, found " <> show other)
