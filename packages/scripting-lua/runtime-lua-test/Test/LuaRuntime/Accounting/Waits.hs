-- | The wait for a scheduled owner's accounting (LUA-31, D-47) on owners that run tasks:
-- what it captures and what it does not, that it needs no slot and leaves nothing behind,
-- that it ends with its owner and never as a false success, and that it changes nothing the
-- owner does.
--
-- Every example coordinates with gates and with threads parked in STM, never a sleep.
module Test.LuaRuntime.Accounting.Waits (spec) where

import Control.Concurrent.STM (atomically, retry)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), finally, throwIO)
import Control.Monad (forM_, replicateM_, void, when)
import Data.IORef (readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Foundation.Worker (GroupStatus (..), Outstanding (..), OutstandingWorker (..))
import Hetoimasia.Runtime.Supervision (Recognition (Recognized), Role (Service), WorkerPolicy (..), WorkerStatus (WorkerLive), workerGroupStatus)
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Owner (vmModules)
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VBoolean, VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Accounting.Support
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

-- | A plain scheduled owner that also loads the module of tasks the windows add.
startPlain ∷ SFixture → LuaRuntime → Text → WorkerPolicy → SchedulerBounds → IO ScheduledOwner
startPlain fixture runtime label policy bounds =
  startScheduled fixture runtime base {scheduledVm = (scheduledVm base) {vmModules = vmModules (scheduledVm base) <> [windowTasks]}}
  where
    base = scheduled fixture label policy bounds

-- | Whether this is the failing owner's worker, which has not yet published its terminal outcome.
awaitingFailing ∷ OutstandingWorker → Bool
awaitingFailing worker = outstandingState worker == AwaitingTerminal && "failing" `Text.isInfixOf` outstandingLabel worker

-- | What a wait ended with, failing if it raised.
answer ∷ PendingWait → IO AccountingWait
answer waiting = resultOf waiting >>= either (\failure → fail ("the wait raised " <> show failure)) pure

-- | A worker policy for an optional worker whose failures are all recognized, and which
-- passes a gate when it classifies one.
classifying ∷ Gate → WorkerPolicy
classifying gate' =
  WorkerPolicy Service Supervision.Optional (unsafeComponent "test.accounting") $ \_ → passGate gate' >> pure Recognized

spec ∷ Spec
spec = describe "waiting for a scheduled owner's accounting" $ do
  describe "what it waits for" $ do
    it "returns for a tick that did no work, and for an owner that was never granted one" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "idle" requiredPolicy defaultSchedulerBounds
        awaitScheduledAccounting control owner >>= (`shouldBe` AccountingComplete)
        grant owner 1
        awaitScheduledAccounting control owner >>= (`shouldBe` AccountingComplete)
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        -- Every grant it captured is finished, and a wait with nothing outstanding returns again.
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 0)
        awaitScheduledAccounting control owner >>= (`shouldBe` AccountingComplete)
        retireScheduled owner

    it "waits for the grants it captured, however many, and for the tasks they woke" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "captured" requiredPolicy defaultSchedulerBounds
        _ ← admitTask' fixture owner "A" (blockAfterTicks "a" 1)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        grant owner 1
        grant owner 1
        waiting ← beginWait control owner
        awaitEntered fixture "a"
        -- The first grant woke the task, which is inside its segment: nothing it captured is finished.
        awaitPending waiting
        isPending waiting >>= (`shouldBe` True)
        releaseGate fixture "a"
        answer waiting >>= (`shouldBe` AccountingComplete)
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 0)
        retireScheduled owner

    it "does not wait for a grant accepted after the ones it captured, which is not even finished" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "isolation" requiredPolicy defaultSchedulerBounds
        _ ← admitTask' fixture owner "A" (request "wait_ticks" [VText "A", VInteger 1] OrdinaryClass OneShot (Just "A"))
        _ ← admitTask' fixture owner "B" (blockAfterTicks "b" 2)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 2)
        -- The owner is held in a segment, so the first grant is not applied while the wait takes its
        -- snapshot, and the second is accepted after it.
        waiting ←
          holdingSafely fixture owner $ do
            grant owner 1
            captured ← beginWait control owner
            awaitPending captured
            grant owner 1
            pure captured
        answer waiting >>= (`shouldBe` AccountingComplete)
        -- The second grant woke B, which is inside its segment: that grant is unfinished, and the global
        -- condition of tick completion is not met, though the wait returned.
        awaitEntered fixture "b"
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        releaseGate fixture "b"
        awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
        retireScheduled owner

    it "keeps the snapshot it took across a supervised outcome handled while it waits" $ bounded $ do
      fixture ← newSFixture
      handled ← newGate
      openGate handled
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "norecapture" requiredPolicy defaultSchedulerBounds
        bystander ← startPlain fixture runtime "bystander" (classifying handled) defaultSchedulerBounds
        _ ← admitTask' fixture owner "A" (request "wait_ticks" [VText "A", VInteger 1] OrdinaryClass OneShot (Just "A"))
        _ ← admitTask' fixture owner "B" (blockAfterTicks "b" 2)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 2)
        waiting ←
          holdingSafely fixture owner $ do
            grant owner 1
            captured ← beginWait control owner
            awaitPending captured
            -- A grant accepted after the snapshot, and then an outcome supervision handles while
            -- the wait is pending: a wait that took its snapshot again would take this grant in.
            grant owner 1
            _ ← admitTask' fixture bystander "bang" (request "host_fail" [VText "bang"] OrdinaryClass OneShot Nothing)
            atomically (scheduledStatus bystander >>= \status → case status of WorkerLive → retry; _ → pure ())
            awaitGateEntered handled
            pure captured
        answer waiting >>= (`shouldBe` AccountingComplete)
        awaitEntered fixture "b"
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        releaseGate fixture "b"
        retireScheduled owner

  describe "what it costs the owner" $ do
    it "needs no task, control or result slot, and works with every bound exhausted" $ bounded $ do
      fixture ← newSFixture
      let bounds =
            defaultSchedulerBounds
              { boundActiveTasks = 2
              , boundQueuedAdmissions = 1
              , boundRetainedResults = 3
              , boundControlRequests = 1
              , boundOutstandingGrants = 2
              }
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "saturated" requiredPolicy bounds
        let endpoint = scheduledEndpoint owner
        a ← admitTask' fixture owner "A" (request "wait_ticks" [VText "A", VInteger 1] OrdinaryClass OneShot (Just "A"))
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        waiting ←
          holdingSafely fixture owner $ do
            -- The holder and A hold both active places; B takes the one queued place; C finds none.
            _ ← admitTask' fixture owner "B" (request "once" [VText "B"] OrdinaryClass OneShot (Just "B"))
            admitScheduledTask endpoint (request "once" [VText "C"] OrdinaryClass OneShot (Just "C")) >>= \case
              TaskQueueFull → pure ()
              other → fail ("expected the queue full, found " <> show other)
            -- One control place, taken and never given back.
            requestTaskControl endpoint (ticketTask a) RequestResume >>= \case
              TaskControlAccepted _ → pure ()
              other → fail ("expected the control accepted, found " <> show other)
            requestTaskControl endpoint (ticketTask a) RequestPause >>= \case
              TaskControlFull → pure ()
              other → fail ("expected the control full, found " <> show other)
            -- Two outstanding grants, and a third is refused.
            grant owner 1
            grant owner 1
            grantScheduledStep endpoint (nanoseconds 1) >>= \case
              GrantFull → pure ()
              other → fail ("expected the grants full, found " <> show other)
            captured ← beginWait control owner
            awaitPending captured
            pure captured
        answer waiting >>= (`shouldBe` AccountingComplete)
        retireScheduled owner

    it "can be made more times than any bound allows, one after another, leaving the owner's counters as they were" $ bounded $ do
      fixture ← newSFixture
      let bounds = defaultSchedulerBounds {boundActiveTasks = 2, boundQueuedAdmissions = 1, boundRetainedResults = 2, boundControlRequests = 1, boundOutstandingGrants = 2}
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "repeated" requiredPolicy bounds
        before ← atomically (scheduledDiagnostics (scheduledEndpoint owner))
        replicateM_ 9 $ awaitScheduledAccounting control owner >>= (`shouldBe` AccountingComplete)
        after ← atomically (scheduledDiagnostics (scheduledEndpoint owner))
        after `shouldBe` before
        -- Each wait after a grant captures that grant and no other.
        forM_ [1 .. 7 :: Int] $ \n → do
          grant owner 1
          awaitScheduledAccounting control owner >>= (`shouldBe` AccountingComplete)
          atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` fromIntegral n)
        retireScheduled owner

    it "leaves nothing behind when it is cancelled, whether it is parked or inside supervision's handling of an outcome" $ bounded $ do
      fixture ← newSFixture
      classifying' ← newGate
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "cancelled" requiredPolicy defaultSchedulerBounds
        bystander ← startPlain fixture runtime "bystander" (classifying classifying') defaultSchedulerBounds
        _ ← admitTask' fixture owner "A" (request "wait_ticks" [VText "A", VInteger 1] OrdinaryClass OneShot (Just "A"))
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        later ←
          holdingSafely fixture owner $ do
            grant owner 1
            -- Parked.
            parked ← beginWait control owner
            awaitPending parked
            cancelWait parked
            -- Inside the classifier of an outcome a wait is handling.
            handling ← beginWait control owner
            awaitPending handling
            _ ← admitTask' fixture bystander "bang" (request "host_fail" [VText "bang"] OrdinaryClass OneShot Nothing)
            awaitGateEntered classifying'
            cancelWait handling
            -- A wait begun afterwards captures the grant, and nothing the cancelled ones did stands in its way.
            beginWait control owner
        openGate classifying'
        answer later >>= (`shouldBe` AccountingComplete)
        retireScheduled owner

  describe "when its owner ends" $ do
    it "ends with an owner that was stopped with a captured grant outstanding, and never reports it complete" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "stopped" requiredPolicy defaultSchedulerBounds
        _ ← admitTask' fixture owner "w" (request "wait_ticks" [VText "w", VInteger 1] OrdinaryClass OneShot (Just "w"))
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        waiting ←
          holdingSafely fixture owner $ do
            grant owner 5
            captured ← beginWait control owner
            awaitPending captured
            retireScheduled owner
            pure captured
        answer waiting >>= (`shouldBe` AccountingOwnerEnded)

    it "ends with a cancelled owner, and with one that had ended before the wait began" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "cancelled owner" requiredPolicy defaultSchedulerBounds
        _ ← admitTask' fixture owner "w" (request "wait_ticks" [VText "w", VInteger 1] OrdinaryClass OneShot (Just "w"))
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        waiting ←
          holdingSafely fixture owner $ do
            grant owner 5
            captured ← beginWait control owner
            awaitPending captured
            cancelQueued owner
            pure captured
        answer waiting >>= (`shouldBe` AccountingOwnerEnded)
        _ ← awaitScheduledTerminal control owner
        awaitScheduledAccounting control owner >>= (`shouldBe` AccountingOwnerEnded)

    it "rethrows a fatal failure of supervision that arrives while it waits, and ends with nothing else" $ bounded $ do
      fixture ← newSFixture
      failure ← expectFatal $ \control runtime → do
        owner ← startPlain fixture runtime "pending" requiredPolicy defaultSchedulerBounds
        other ← startPlain fixture runtime "failing" requiredPolicy defaultSchedulerBounds
        _ ← admitTask' fixture owner "A" (blockAfterTicks "a" 1)
        _ ← admitTask' fixture other "bang" (request "tick_then_fail" [VText "bang"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        awaitDiagnostics other (\counts → diagWaiting counts >= 1)
        -- The first owner's grant is held unfinished at a gate, and the second owner's task fails
        -- the moment its grant wakes it: a fatal failure of supervision, whenever the wait looks.
        flip finally (releaseGate fixture "a") $ do
          grant owner 1
          awaitEntered fixture "a"
          grant other 1
          void (awaitScheduledAccounting control owner)
          throwIO (userError "the wait returned instead of rethrowing the fatal failure")
      let ExceptionWithContext _ raised = failure
      raised `shouldSatisfy` brokenIs "bang"

    it "rethrows a fatal failure that is already published when it is called, ahead of a completion that is ready" $ bounded $ do
      fixture ← newSFixture
      failure ← expectFatal $ \control runtime → do
        owner ← startPlain fixture runtime "ready" requiredPolicy defaultSchedulerBounds
        other ← startPlain fixture runtime "failing" requiredPolicy defaultSchedulerBounds
        _ ← admitTask' fixture other "bang" (request "host_fail" [VText "bang"] OrdinaryClass OneShot Nothing)
        -- The failing owner's worker has published its terminal outcome, and nothing in this thread has
        -- made a supervised call since, so supervision has not handled it: the drain status, the one
        -- read any thread may make, shows it.
        atomically $ do
          status ← workerGroupStatus control
          when (any awaitingFailing (statusOutstanding status)) retry
        -- The wait is ready all the same, and is not what the call answers.
        void (awaitScheduledAccounting control owner)
        throwIO (userError "the wait returned instead of rethrowing the fatal failure")
      let ExceptionWithContext _ raised = failure
      raised `shouldSatisfy` brokenIs "bang"

    it "ends with an owner that failed recognizably, and not with a completion, once supervision has handled it" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        victim ← startPlain fixture runtime "victim" (optionalPolicy (brokenIs "bang")) defaultSchedulerBounds
        _ ← admitTask' fixture victim "bang" (request "tick_then_fail" [VText "bang"] OrdinaryClass OneShot Nothing)
        awaitDiagnostics victim (\counts → diagWaiting counts >= 1)
        waiting ←
          holdingSafely fixture victim $ do
            grant victim 5
            captured ← beginWait control victim
            awaitPending captured
            pure captured
        answer waiting >>= (`shouldBe` AccountingOwnerEnded)

  describe "from a Lua callback" $ do
    it "is refused, like every other wait, naming its operation" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startPlain fixture runtime "probes" requiredPolicy defaultSchedulerBounds
        writeIORef (sfRuntime fixture) (Just runtime)
        writeIORef (sfSupervision fixture) (Just control)
        writeIORef (sfOwner fixture) (Just owner)
        probing ← admitTask' fixture owner "probe" (request "probe" [VText "await_accounting", VText ""] OrdinaryClass OneShot Nothing)
        outcomeOf probing >>= (`shouldBe` Just [VBoolean True]) . taskReturned
        readIORef (sfProbe fixture) >>= (`shouldBe` ["await-scheduled-accounting"])
        retireScheduled owner

  describe "determinism of logical-time work" $ do
    forM_ [WaitEach, WaitDuring, WaitAtEnd, CancelDuring] $ \strategy →
      it ("gives the same segments, durations, effect order and counters with no wait and with " <> show strategy) $ bounded $ do
        baseline ← observe Nothing
        varied ← observe (Just strategy)
        varied `shouldBe` baseline

-- | Where an example waits for the accounting while it runs the workload.
data Strategy
  = -- | Directly, after every grant, once the tick is complete.
    WaitEach
  | -- | On a thread of its own, begun as the grant is made, so it is pending while the tick runs.
    WaitDuring
  | -- | Only after the last grant.
    WaitAtEnd
  | -- | Begun as the grant is made, and cancelled at once.
    CancelDuring
  deriving (Eq, Show)

-- | What one run observed: the effects, the segments and the counters.
data Observation = Observation
  { observedEffects ∷ [Text]
  , observedSegments ∷ [(Maybe Text, Int)]
  , observedDiagnostics ∷ Diagnostics
  }
  deriving (Eq, Show)

-- | Run one workload of logical-time work, a tick at a time, waiting for the accounting in the
-- way this says.
observe ∷ Maybe Strategy → IO Observation
observe strategy = do
  fixture ← newSFixture
  withBoundary $ \control runtime → do
    owner ← startPlain fixture runtime "deterministic" requiredPolicy defaultSchedulerBounds
    let endpoint = scheduledEndpoint owner
        ticker label n every serviceClass kind =
          request "ticker" [VText label, VInteger n, VInteger every] serviceClass kind (Just label)
    _ ← admitTask' fixture owner "A" (ticker "A" 3 1 OrdinaryClass OneShot)
    _ ← admitTask' fixture owner "B" (ticker "B" 2 2 OrdinaryClass OneShot)
    _ ← admitTask' fixture owner "C" (ticker "C" 2 3 BackgroundClass OneShot)
    awaitDiagnostics owner (\counts → diagWaiting counts >= 3)
    let step n = do
          _ ← grantScheduledStep endpoint (nanoseconds n)
          during ← case strategy of
            Just WaitDuring → Just <$> beginWait control owner
            Just CancelDuring → Nothing <$ (beginWait control owner >>= cancelWait)
            _ → pure Nothing
          awaitTicksComplete control owner >>= (`shouldBe` TicksCompleted)
          case (strategy, during) of
            (Just WaitEach, _) → awaitScheduledAccounting control owner >>= (`shouldBe` AccountingComplete)
            (_, Just waiting) → answer waiting >>= (`shouldBe` AccountingComplete)
            _ → pure ()
    mapM_ step [3, 5, 8, 13, 21, 2]
    case strategy of
      Just WaitAtEnd → awaitScheduledAccounting control owner >>= (`shouldBe` AccountingComplete)
      _ → pure ()
    awaitDiagnostics owner (\counts → diagCompleted counts >= 3)
    result ←
      Observation
        <$> taskEffects fixture
        <*> (map (\context → (contextName context, contextSegment context)) <$> segmentsRun fixture)
        <*> atomically (scheduledDiagnostics endpoint)
    retireScheduled owner
    pure result
