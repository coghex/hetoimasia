-- | The boundaries of the owner's service of its instances: where a request is
-- applied, what survives a failure of the host in the middle of servicing, what the
-- scheduler's capacity can refuse, and what a script may and may not reach.
module Test.LuaRuntime.Instance.Boundary (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM, forM_, void)
import Control.Concurrent.STM (atomically)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitFailed), Progress (Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support
  ( SFixture (sfObserver)
  , awaitDiagnostics
  , cancelQueued
  , awaitEffect
  , awaitEntered
  , awaitScheduledTerminal
  , defaultSchedulerBounds
  , releaseGate
  , request
  )
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

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

  it "keeps what closing a coroutine raised beside the failure of the host that ending its instance raised, and takes neither for the other" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext context raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "both" [badCloseHostShutdown] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "badclosehostshutdown")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      _ ← settleControl fixture owner "a" InstanceStop
      awaitScheduledTerminal control owner
    -- The failure of the host, raised by the shutdown, is the owner's own, as it is
    -- for an instance with nothing to close; the closing handler's failure is cleanup
    -- evidence beside it, which the failure of the host did not take with it.
    raised `shouldSatisfy` brokenIs "boom"
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` (not . null)

  it "leaves an optional owner unavailable, not fatal, when a shutdown raises a failure of the host that its policy recognizes, as for an instance with nothing to close" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "recognized" [waitHostShutdown] (testConfig instanceBounds') (optionalPolicy (brokenIs "boom"))
      _ ← admit fixture owner "a" (moduleNamed "waithostshutdown")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      _ ← settleControl fixture owner "a" InstanceStop
      -- Raised from the owner's own code, not from inside the coroutine's close, so it
      -- is not taken for a failure of the close, which no policy can recognize.
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)

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

  it "ends an instance only by the task that is its invocation in flight: a task it took back, closed first, ends nothing" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      -- Run the newest ready task first, so a task the instance took back stays behind
      -- its replacement and the scheduler closes it first, by identity, at retirement.
      let spec' = (instanceSpec fixture "ghost" [closingGated, holder] (testConfig instanceBounds') requiredPolicy defaultSchedulerBounds) {scheduledPolicy = newestFirst}
      owner ← startWith fixture runtime spec'
      _ ← admit fixture owner "a" (moduleNamed "closinggated")
      awaitPhase fixture owner "a" Active
      holdOwner fixture owner
      -- Admitted, taken back by a pause and admitted again by a resume, before any
      -- segment of it ran: a ghost task and its replacement.
      expectDelivered fixture owner "a" 1
      pause ← expectControl fixture owner "a" InstancePause
      resume ← expectControl fixture owner "a" InstanceResume
      releaseOwner fixture
      forM_ [pause, resume] waitInstanceControl
      awaitEntered (sf fixture) "cb"
      -- The replacement is inside its first segment, at a gate, when the owner retires.
      retireScheduled owner
      releaseGate (sf fixture) "cb"
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      terminationClosed (resultTermination settled) `shouldBe` 1
      -- Its coroutine was closed, once, before the hook, which ran once.
      logged fixture >>= (`shouldBe` ["closed 1", "shutdown 1 stopped"])

  it "begins nothing more once the owner is asked to stop in the middle of a batch: the rest stay unstarted" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "halted batch" [gateInit, echoer, holder] (testConfig instanceBounds') requiredPolicy
      holdOwner fixture owner
      _ ← admit fixture owner "g" (moduleNamed "gateinit")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      releaseOwner fixture
      -- The first one's init waits at its gate, inside the batch; the owner is asked to stop.
      awaitEntered (sf fixture) "init"
      retireScheduled owner
      releaseGate (sf fixture) "init"
      _ ← awaitScheduledTerminal control owner
      -- The second was not begun: no init, and it settles as stopped without one.
      b ← awaitSettled fixture "b"
      resultOutcome b `shouldSatisfy` stopped
      terminationShutdown (resultTermination b) `shouldBe` ShutdownSkippedNoInit
      logged fixture >>= (`shouldBe` ["init done 1", "shutdown 1 stopped"])

  it "counts an invocation the scheduler still holds in its queue as an unstarted one discarded when the owner retires" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \control runtime → do
      let bounds = defaultSchedulerBounds {boundActiveTasks = 1}
      owner ←
        startWith fixture runtime $
          instanceSpec fixture "retired queued" [echoer, plainModule] (testConfig instanceBounds') requiredPolicy bounds
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      _ ← admitScheduledTask (scheduledEndpoint owner) (request "waits" [VText "w"] OrdinaryClass OneShot Nothing) >>= ordinary
      awaitDiagnosticsWaiting owner
      expectDelivered fixture owner "a" 1
      awaitDiagnostics owner (\counts → diagQueued counts >= 1)
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      settled ← awaitSettled fixture "a"
      resultOutcome settled `shouldSatisfy` stopped
      let termination = resultTermination settled
      terminationUnstarted termination `shouldBe` 1
      terminationClosed termination `shouldBe` 0

  it "uses the task it took back again when the invocation is the same, so pausing and resuming over and over admits nothing new" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      let bounds = defaultSchedulerBounds {boundActiveTasks = 1}
      owner ←
        startWith fixture runtime $
          instanceSpec fixture "ghosts" [echoer, plainModule] (testConfig instanceBounds') requiredPolicy bounds
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      _ ← admitScheduledTask (scheduledEndpoint owner) (request "waits" [VText "w"] OrdinaryClass OneShot Nothing) >>= ordinary
      awaitDiagnosticsWaiting owner
      expectDelivered fixture owner "a" 1
      awaitDiagnostics owner (\counts → diagQueued counts >= 1)
      before ← atomically (scheduledDiagnostics (scheduledEndpoint owner))
      forM_ [1 .. 5 ∷ Int] $ \_ → do
        settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
        settleControl fixture owner "a" InstanceResume >>= (`shouldBe` ControlApplied)
      after ← atomically (scheduledDiagnostics (scheduledEndpoint owner))
      -- The same task was brought back each time: the scheduler admitted nothing more.
      diagAdmitted after `shouldBe` diagAdmitted before
      diagQueued after `shouldBe` diagQueued before

  it "does not let the application control an instance's invocation through the task controls, whatever it learned of its identity" $ bounded $ do
    fixture ← newIFixture
    seen ← newIORef Nothing
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "own tasks" [slow] (testConfig instanceBounds') requiredPolicy
      writeIORef (sfObserver (sf fixture)) (\context → writeIORef seen (Just (contextTask context)))
      _ ← admit fixture owner "a" (moduleNamed "slow")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      task ← readIORef seen >>= maybe (fail "no segment was observed") pure
      -- Told to the application by the observer, and of no use to it.
      requestTaskControl (scheduledEndpoint owner) task RequestPause >>= (`shouldSatisfy` \case TaskControlUnknown → True; _ → False)
      requestTaskControl (scheduledEndpoint owner) task RequestStop >>= (`shouldSatisfy` \case TaskControlUnknown → True; _ → False)
      snapshotOf fixture owner "a" >>= (`shouldSatisfy` \held → fmap snapshotExecution held == Just ExecWaiting)

  it "keeps the queue within its bound when an unstarted invocation is taken back by a pause" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      let bounds = defaultSchedulerBounds {boundActiveTasks = 1}
      owner ←
        startWith fixture runtime $
          instanceSpec fixture "bounded pause" [echoer, plainModule] (testConfig instanceBounds' {boundInvocationQueue = 2}) requiredPolicy bounds
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      _ ← admitScheduledTask (scheduledEndpoint owner) (request "waits" [VText "w"] OrdinaryClass OneShot Nothing) >>= ordinary
      awaitDiagnosticsWaiting owner
      -- The first event's callback is queued behind the occupied slot, still unstarted:
      -- it holds a place in the queue of two, so one more is taken and the next refused.
      expectDelivered fixture owner "a" 1
      awaitDiagnostics owner (\counts → diagQueued counts >= 1)
      expectDelivered fixture owner "a" 2
      deliverTick fixture owner "a" 3 >>= (`shouldBe` DeliveryQueueFull)
      settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
      snapshotOf fixture owner "a"
        >>= (`shouldSatisfy` \held → fmap (\x → (snapshotQueued x, snapshotQueueBound x)) held == Just (2, 2))
      deliverTick fixture owner "a" 4 >>= (`shouldBe` DeliveryQueueFull)

  it "keeps what an ending counted when the owner is cancelled while its shutdown waits: connections revoked, events discarded" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "cancelled hook" [gateShutdown, holder] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "gateshutdown")
      awaitPhase fixture owner "a" Active
      settleControl fixture owner "a" InstancePause >>= (`shouldBe` ControlApplied)
      forM_ [1, 2] (expectDelivered fixture owner "a")
      -- The stop's hook waits at its gate; the owner is cancelled meanwhile.
      receipt ← expectControl fixture owner "a" InstanceStop
      awaitEntered (sf fixture) "shutdown"
      cancelQueued owner
      releaseGate (sf fixture) "shutdown"
      _ ← waitInstanceControl receipt
      settled ← awaitSettled fixture "a"
      let termination = resultTermination settled
      (terminationConnections termination, terminationUnstarted termination) `shouldBe` (1, 2)

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
