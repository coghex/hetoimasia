-- | The boundaries of the owner's service of its instances: where a request is
-- applied, what survives a failure of the host in the middle of servicing, what the
-- scheduler's capacity can refuse, and what a script may and may not reach.
module Test.LuaRuntime.Instance.Boundary (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM, forM_, void)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitFailed), Progress (Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support
  ( awaitDiagnostics
  , cancelQueued
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
    -- And what it had done by then, the coroutine it closed included, is counted.
    fmap (terminationClosed . resultTermination) a `shouldBe` Just 1

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

  it "stops a waiting instance although the scheduler's one control reservation is held by an ordinary task's request nobody has read" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      let bounds = defaultSchedulerBounds {boundControlRequests = 1}
      owner ←
        startWith fixture runtime $
          instanceSpec fixture "held reservation" [slow, plainModule] (testConfig instanceBounds') requiredPolicy bounds
      _ ← admit fixture owner "a" (moduleNamed "slow")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      task ← admitScheduledTask (scheduledEndpoint owner) (request "waits" [VText "w"] OrdinaryClass OneShot Nothing) >>= ordinaryIdentity
      -- The ordinary task's request settles and is not read: it holds the reservation.
      held ← requestTaskControl (scheduledEndpoint owner) task RequestPause >>= \case
        TaskControlAccepted receipt → pure receipt
        other → fail ("expected the request accepted, found " <> show other)
      awaitDiagnostics owner (\counts → diagControlAccepted counts >= 1)
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      terminationClosed (resultTermination settled) `shouldBe` 1
      void (pure held)

  it "stops an instance whose invocation is queued behind active slots that stay occupied, without waiting for them" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      let bounds = defaultSchedulerBounds {boundActiveTasks = 1}
      owner ←
        startWith fixture runtime $
          instanceSpec fixture "queued" [echoer, plainModule] (testConfig instanceBounds') requiredPolicy bounds
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      -- The only active slot is held by an ordinary task that waits for ticks nobody grants.
      _ ← admitScheduledTask (scheduledEndpoint owner) (request "waits" [VText "w"] OrdinaryClass OneShot Nothing) >>= ordinaryIdentity
      awaitDiagnosticsWaiting owner
      expectDelivered fixture owner "a" 1
      -- Admitted behind it, queued for a slot, its callback cannot be chosen.
      awaitDiagnostics owner (\counts → diagQueued counts >= 1)
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      terminationUnstarted (resultTermination settled) `shouldBe` 1
      terminationClosed (resultTermination settled) `shouldBe` 0
      logged fixture >>= (`shouldBe` ["init 1", "shutdown 1 stopped"])

  it "pauses an instance whose invocation is queued behind occupied slots, holds its event, and starts it on resume" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      let bounds = defaultSchedulerBounds {boundActiveTasks = 1}
      owner ←
        startWith fixture runtime $
          instanceSpec fixture "queued pause" [echoer, plainModule] (testConfig instanceBounds') requiredPolicy bounds
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      ticket ← admitScheduledTask (scheduledEndpoint owner) (request "waits" [VText "w"] OrdinaryClass OneShot Nothing) >>= ordinary
      awaitDiagnosticsWaiting owner
      expectDelivered fixture owner "a" 1
      awaitDiagnostics owner (\counts → diagQueued counts >= 1)
      settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
      -- The event is held, unstarted, as it is for any paused instance.
      snapshotOf fixture owner "a" >>= (`shouldSatisfy` \held → fmap (\x → (snapshotQueued x, snapshotExecution x)) held == Just (1, ExecIdle))
      -- Let the ordinary task finish, freeing the slot, and resume.
      grantFive control owner
      _ ← waitTask ticket
      settleControl fixture owner "a" InstanceResume >>= (`shouldBe` ControlApplied)
      awaitEffect (sf fixture) "tick 1 n=1 seq=0 t=0 count=1"

  it "settles every request of a batch the owner was cancelled in the middle of, those it never began included" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "cancelled batch" [echoer, gateInit, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "x" (moduleNamed "echoer")
      awaitPhase fixture owner "x" Active
      holdOwner fixture owner
      -- One batch: an instance whose init waits at a gate, and a request behind it.
      _ ← admit fixture owner "g" (moduleNamed "gateinit")
      receipt ← expectControl fixture owner "x" InstanceStop
      releaseOwner fixture
      awaitEntered (sf fixture) "init"
      cancelQueued owner
      releaseGate (sf fixture) "init"
      -- However the cancellation fell, nothing waits for ever.
      result ← waitInstanceControl receipt
      result `shouldSatisfy` (`elem` [ControlApplied, ControlNoLongerApplicable])
      _ ← awaitSettled fixture "x"
      _ ← awaitSettled fixture "g"
      pure ()

  it "keeps every failure of the host raised as the owner retires its instances, whole, beside the first" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext context raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "two failures" [hostShutdown, hostShutdownBang] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "hostshutdown")
      _ ← admit fixture owner "b" (moduleNamed "hostshutdownbang")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      retireScheduled owner
      awaitScheduledTerminal control owner
    -- One is the owner's failure and the other is cleanup evidence: neither was chosen
    -- over the other and lost.
    let others = map cleanupFailureException (cleanupFailuresInContext context)
        failures = raised : [other | ExceptionWithContext _ other ← others]
    failures `shouldSatisfy` any (brokenIs "boom")
    failures `shouldSatisfy` any (brokenIs "bang")

  it "keeps what an ending counted when its shutdown raises a failure of the host: connections revoked, events discarded" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext _ _ ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "counted" [hostShutdown] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "hostshutdown")
      awaitPhase fixture owner "a" Active
      settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
      forM_ [1, 2] (expectDelivered fixture owner "a")
      retireScheduled owner
      awaitScheduledTerminal control owner
    settled ← tickOf fixture "a" >>= pollInstance
    fmap (resultTermination) settled
      `shouldBe` Just (Termination {terminationConnections = 1, terminationUnstarted = 2, terminationClosed = 0, terminationShutdown = ShutdownRaised})

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
    ordinaryIdentity = \case
      TaskAccepted identity _ → pure identity
      other → fail ("expected the task accepted, found " <> show other)
    grantFive control owner = forM_ [1 .. 5 ∷ Int] (const (grantOne control owner))
