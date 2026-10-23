-- | The owner's side of script instances: the thread that runs the VM makes each
-- instance's @self@, runs its hooks, runs its invocations as scheduled tasks and
-- ends it.
--
-- Everything here runs on the owner's thread, between or inside the scheduler's
-- segments, and none of it is reachable from another thread or from Lua: producers
-- reach the instances through the transactions of "Hetoimasia.Scripting.Lua.Instance.State",
-- and this module is what services what they left.
--
-- = Invocations are scheduled tasks
--
-- An instance has at most one invocation in flight, and it is a task of the owner's
-- scheduler: a callback for an event, or a one-shot's @run@. The scheduler orders it
-- among the owner's other tasks by the owner's policy and service class, runs its
-- segments, and lets it wait or yield. The instance layer admits the next one the
-- moment one finishes, at that segment's boundary, so the order of invocations
-- depends only on the order of admission and never on how long a segment took or
-- where a turn was cut.
--
-- @init@ and @shutdown@ are not tasks. Each is a finite call on the owner's thread,
-- which is what makes a wait or a yield inside one a fault of the hook, as it is
-- for any call.
--
-- = Control
--
-- A request is applied when the owner's thread services its jobs, which the
-- scheduler's turn has it do at each safe boundary, when no task is running, and
-- never inside a segment. Pause, resume and stop of the invocation in flight are done
-- to its task directly ('Hetoimasia.Scripting.Lua.Scheduler.ownerControl'), with no
-- request or reservation of the scheduler's in between: a stop discards what had not
-- begun, revokes the connections, closes the coroutine of the invocation in flight on
-- this thread, and runs @shutdown@ after that close. An invocation that has not run a
-- segment has no coroutine, and is taken back instead: its scheduler task stays as a
-- ghost that does nothing when it is chosen, and neither it nor its close ends the
-- instance.
--
-- = Leases
--
-- An owner given 'Hetoimasia.Scripting.Lua.Lease.Leases' gives each instance a scope
-- before its first hook, and releases what the instance still holds at its end: after
-- its @shutdown@ has run or been skipped and before its record in the VM is let go,
-- on this thread, newest acquisition first. A release that fails does not stop the
-- others, is cleanup evidence on the owner whatever the application's escalation
-- answers, and is kept beside the instance's primary failure in its settlement.
--
-- What a provider still has to retire after that is awaited here: the instance's end
-- is /parked/, with its @shutdown@ run and its holdings released, and settles when its
-- retirements have all completed, so that nothing is reported as stopped or
-- reclaimed merely because Lua stopped. The owner serves on meanwhile, and the
-- owner's own exit waits uninterruptibly for what is parked.
--
-- = Ending
--
-- Every end goes through one place: the instance's admission and connections close
-- first, the coroutine of an invocation in flight is closed and never resumed, the
-- @shutdown@ hook runs once if @init@ had succeeded and Lua entry is safe, the
-- instance's record in the VM is released, and its settlement is written, once. A
-- failure of @shutdown@ is kept beside any primary failure, which stays primary.
-- What closing a coroutine raised is not this module's to keep: it is the
-- scheduler's evidence, and is fatal for the owner whatever the application's
-- escalation answers.
module Hetoimasia.Scripting.Lua.Instance.Run
  ( InstanceHost (..)
  , ExitMode (..)
  , newInstanceHost
  , gateOf
  , awaitInstanceWork
  , serviceInstances
  , serviceBoundary
  , instanceSegment
  , instanceClosed
  , settleEnded
  , reapInvocations
  , retireInstances
  , runningTask
  , recordExit
  , cleanupEndedOwner
  , endOwner
  , definedHooks
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', orElse, readTVar, readTVarIO, retry, swapTVar, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, finally, fromException, mask, mask_, onException, rethrowIO, throwIO, uninterruptibleMask_)
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Foldable (toList, traverse_)
import Hetoimasia.Scripting.Lua.Lifecycle.State (abandonIssued)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Sequence (ViewL (EmptyL, (:<)), viewl, (<|))
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.State
import Hetoimasia.Scripting.Lua.Instance.Types
import Hetoimasia.Scripting.Lua.Lease.State
  ( DrainReport (drainFailures)
  , LeaseHost (lhLeases)
  , Disposals (Disposals, disposalsActions, disposalsInstance, disposalsKey)
  , RetirementEnd (endedFailure, endedInstance, endedLabel)
  , Scope (scopeAwaited, scopeDrained, scopeFailed, scopeNotes)
  , anyPending
  , dissolveScope
  , drainScope
  , finishDisposals
  , noteScope
  , openScope
  , pendingFor
  , readScope
  , renderCaught
  , guarded
  , retirementsReady
  , serviceRetirements
  )
import Hetoimasia.Scripting.Lua.Internal.Module (EntryPoint (entryName), Lead (LeadCaptured), ModuleHandle (handleEntries), callEntryVia, callEntryWith, entryPresent)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedHost)
import Hetoimasia.Scripting.Lua.Internal.Fault (raisedByApplication)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (ReasonCode (ScriptFault), RecoverySafety (RecoverySafe), failureReason)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (ServiceClass (OrdinaryClass))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure (TaskFailure))
import Hetoimasia.Scripting.Lua.Internal.Task (startTaskCaptured, startTaskVia)
import Hetoimasia.Scripting.Lua.Instance.Behavior (behaviorDriverRef, behaviorInit, behaviorShutdown, behaviorUpdate)
import Hetoimasia.Scripting.Lua.Owner
  ( BehaviorShape (shapeInit, shapeShutdown, shapeUpdate)
  , BoundaryFault (boundaryTraceback)
  , CallResult (Returned)
  , Captured (capturedHandle, capturedShape)
  , ExportIdentity (ExportIdentity)
  , ExportOutcome (ExportFailed, ExportReady)
  , FacadeSource (FacadeBuilt, FacadeField, FacadeValue)
  , Hook (HookInit, HookShutdown, HookUpdate)
  , ModuleRef (moduleRefName)
  , OwnedVm
  , Task
  , TaskStart (TaskEntryAbsent, TaskStarted)
  , callEntry
  , resumeTask
  , startTask
  )
import qualified Hetoimasia.Scripting.Lua.Owner as Owner
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Scripting.Lua.Runtime.Types
  ( CallFault (BoundaryFailed, ModuleNotLoaded)
  , Discard (Discard)
  , ExitKind (ExitCancelled, ExitFailed)
  , Payload (WithinBounds)
  , Progress (NotStarted, Started)
  )
import Hetoimasia.Scripting.Lua.Provider.Events (DeliveryStart (..), EventsServed (..), eventRecord, serveEvents, startDelivery)
import Hetoimasia.Scripting.Lua.Provider.Serve (endRequester, raiseFirst, serveTick, serviceProvider)
import Hetoimasia.Scripting.Lua.Provider.State (anyInstanceWorkPending, pendingWorkFor, workWaiting)
import Hetoimasia.Scripting.Lua.Provider.Types (ProviderState, Requester (RequesterInstance))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (CancelCause (CancelledByTaskInvalidation))
import Hetoimasia.Scripting.Lua.Scheduled.Shared (settledOrRaise, waitReportFor)
import Hetoimasia.Scripting.Lua.Scheduled.Types
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (AllowZero)
  , Instant
  , addDuration
  , advanceBaseline
  , durationFromNanoseconds
  , durationNanoseconds
  , elapsedBetween
  , noBaseline
  , readInstant
  )
import Hetoimasia.Scripting.Lua.Scheduler
  ( AdmitAnswer (Admitted)
  , CadenceFault (CadenceAccrualOverflow)
  , CadenceFiring (FiredElapsed, FiredFault, FiredLogical)
  , CadenceKey (CadenceKey)
  , armElapsedCadence
  , armLogicalCadence
  , cadenceAccrued
  , cadenceHeld
  , disarmCadence
  , releaseCadenceHold
  , resetCadenceAccrued
  , schedulerClock
  , startElapsedCadence
  , startLogicalCadence
  , stopCadence
  , releaseWatch
  , setWatch
  , takeNextCadenceFiring
  , tasksReady
  , watchHeld
  , watchKey
  , watchTick
  , BehaviorId (BehaviorId)
  , ControlRequest (RequestPause, RequestResume, RequestStop)
  , ControlResult (ControlAlreadyInState, ControlApplied, ControlNoLongerApplicable)
  , Scheduler
  , SegmentReport (ReportCompleted, ReportFailed, ReportYielded)
  , TaskHost
  , TaskKind (OneShot)
  , TaskOutcome (OutcomeFailed)
  , TaskPhase (PhaseEnded, PhasePaused, PhaseQueued, PhaseReady, PhaseRunning, PhaseWaiting)
  , TaskRun (runTask)
  , TerminalResult (ResultFailed)
  , TaskSpec (..)
  , admissionAvailable
  , admitTask
  , observeTask
  , readTick
  , ownerControl
  , schedulerClosed
  , taskPhase
  )
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VRecord, VText))
import Hetoimasia.Scripting.Lua.Instance.Driver (eventEntry, subscriptionEntry)

-- | Whether the owner may still enter Lua for its instances.
data ExitMode
  = -- | Serving, or exiting in order after a stop request: hooks run.
    Serving
  | -- | Exiting in order: an orderly retirement. Hooks run, with reason @stopped@.
    Orderly
  | -- | Exiting after a host failure or a cancellation: no hook runs and Lua is not
    -- entered for an instance again.
    Unorderly !ExitKind

-- | What an invocation in flight is.
data Live = Live
  { liveSlot ∷ !Word64
  , liveStage ∷ !HookStage
  , liveSequence ∷ !(Maybe Word64)
    -- ^ The sequence of the event an invocation was made for, to know it again.
  , liveWithdrawn ∷ !Bool
    -- ^ The instance took the invocation back before it began.
  , liveDelivery ∷ !Bool
    -- ^ The invocation is a subscription's callback, handed a delivery.
  }

-- | Why an instance is ending.
data EndReason = EndStopped | EndCompleted | EndFailed
  deriving (Eq)

-- | The first failure of an instance: the phase it was in, where, and what.
data Primary = Primary !InstancePhase !HookStage !InstanceError

-- | An instance's ending, from its beginning to its settlement.
data Ending = Ending
  { endReason ∷ !EndReason
  , endPrimary ∷ !(Maybe Primary)
  , endConnections ∷ !Int
  , endUnstarted ∷ !Int
  , endClosed ∷ !Int
    -- ^ Coroutines closed so far: kept as they are counted, so an ending that raised
    -- can still be settled with what it did.
  , endShutdown ∷ !ShutdownRecord
    -- ^ What became of the @shutdown@ hook, recorded when it was decided.
  }

-- | What became of an instance's @shutdown@, recorded once, when it is decided, and read
-- by every path that settles or reports the ending: none recomputes it.
data ShutdownRecord
  = -- | Not decided yet.
    ShutdownUndecided
  | -- | The hook was entered and has not answered: a failure of the host that left it
    -- raised it, and it is not started again.
    ShutdownBegun
  | -- | Decided: what became of it, and the error it raised, if it raised one the
    -- instance can report.
    ShutdownDecided !ShutdownDisposition !(Maybe InstanceError)

-- | The disposition and the failure of the hook a record stands for, for an instance that
-- is, or is not, initialized.
recordedShutdown ∷ Bool → ShutdownRecord → (ShutdownDisposition, Maybe InstanceError)
recordedShutdown initialized = \case
  ShutdownUndecided
    | initialized → (ShutdownSkippedUnsafe, Nothing)
    | otherwise → (ShutdownSkippedNoInit, Nothing)
  ShutdownBegun → (ShutdownRaised, Nothing)
  ShutdownDecided disposition failure → (disposition, failure)

-- | Whether the hook was started: it is not started again, and Lua is not entered for the
-- release of what the instance held after it was cut short.
hookStarted ∷ ShutdownRecord → Bool
hookStarted = \case
  ShutdownBegun → True
  ShutdownDecided disposition _ → disposition == ShutdownRan || disposition == ShutdownRaised
  ShutdownUndecided → False

-- | What the owner's thread holds for its instances, besides what the application
-- shares: the VM, the driver, the coroutines, and how each instance is ending.
data InstanceHost = InstanceHost
  { ihControl ∷ !Control
  , ihInstances ∷ !Instances
  , ihEscalate ∷ InstanceFailure → IO Escalation
  , ihOwned ∷ !OwnedVm
  , ihDriver ∷ !ModuleHandle
  , ihBehaviorDriver ∷ !(Maybe ModuleHandle)
    -- ^ The driver of M1 behavior instances, which runs a captured hook, loaded beside
    -- the instance driver.
  , ihHandles ∷ !(IORef (Map ModuleRef ModuleHandle))
  , ihTasks ∷ !(IORef (Map TaskId Task))
  , ihExtra ∷ !(IORef [(Text, ExceptionWithContext SomeException)])
  , ihLive ∷ !(IORef (Map TaskId Live))
  , ihEndings ∷ !(IORef (Map Word64 Ending))
  , ihCreated ∷ !(IORef (Set.Set Word64))
  , ihEntered ∷ !(IORef (Set.Set Word64))
    -- ^ The M1 behavior instances whose @init@ was entered: what an interrupted @init@
    -- is told apart by from a construction that never ran a hook. The legacy driver's
    -- record ('ihCreated') is not made for a behavior, so progress is not read from it.
  , ihMode ∷ !(IORef ExitMode)
  , ihToFinish ∷ !(IORef (Set.Set Word64))
    -- ^ Instances whose invocation's coroutine the scheduler closed: each is ended
    -- from the owner's own code, not from inside the close, where a failure raised by
    -- a hook would be taken for the close's failure.
  , ihGhosts ∷ !(IORef (Map Word64 TaskId))
    -- ^ The scheduler task an instance took back before it began, by instance: one
    -- at most, brought back into use by the next invocation that is the same.
  , ihHost ∷ !(TaskHost Cursor)
    -- ^ What the scheduler runs segments and closes continuations through.
  , ihBacklog ∷ !(IORef [Job])
    -- ^ The jobs of the batch being serviced that have not begun: if servicing one
    -- raises, the owner's exit still finds the rest, and settles their receipts.
  , ihLeases ∷ !(Maybe LeaseHost)
    -- ^ The owner's leases, when its instances hold any.
  , ihProvider ∷ !(Maybe ProviderState)
    -- ^ The owner's request service, when it was granted one: the requests its instances
    -- own, which an instance's end revokes and its settlement waits for.
  , ihParked ∷ !(IORef (Set.Set Word64))
    -- ^ Instances whose ending has run its hook and released its holdings and waits
    -- for a provider's retirement before it settles.
  , ihFailed ∷ !(IORef Bool)
    -- ^ Whether a cleanup failure of the leases ended the owner: it is how the owner exits,
    -- as a failure and not an order, whatever stopped its loop.
  , ihDue ∷ !(IORef [(ControlSlot, LogicalControl)])
    -- ^ The requests assigned to a tick the owner has reached that have not begun, in
    -- the order of their places: the same, for logical admission.
  }

-- | The host of an owner's instances.
newInstanceHost
  ∷ Control
  → Instances
  → (InstanceFailure → IO Escalation)
  → TaskHost Cursor
  → OwnedVm
  → ModuleHandle
  → Maybe ModuleHandle
  → IORef (Map ModuleRef ModuleHandle)
  → IORef (Map TaskId Task)
  → IORef [(Text, ExceptionWithContext SomeException)]
  → Maybe LeaseHost
  → Maybe ProviderState
  → IO InstanceHost
newInstanceHost control instances escalate host owned driver behaviorDriver handles tasks extra leases provider =
  InstanceHost control instances escalate owned driver behaviorDriver handles tasks extra
    <$> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Set.empty
    <*> newIORef Set.empty
    <*> newIORef Serving
    <*> newIORef Set.empty
    <*> newIORef Map.empty
    <*> pure host
    <*> newIORef []
    <*> pure leases
    <*> pure provider
    <*> newIORef Set.empty
    <*> newIORef False
    <*> newIORef []

-- | Record how the owner exits, for the instances it leaves: the one place that writes it.
-- The first failure or cancellation recorded is how the owner exits, and nothing later (a
-- close interrupted while the owner was already failing, a hook cut short, a cancellation
-- of the retirement) replaces it: what happened afterwards is cleanup evidence on the
-- owner's outcome, not its exit. An orderly exit is no failure, so it gives way to the
-- first one that is. @Nothing@ is an exit in order.
recordExit ∷ InstanceHost → Maybe ExitKind → IO ()
recordExit ih how = modifyIORef' (ihMode ih) $ \held → case (held, how) of
  (Unorderly _, _) → held
  (_, Just kind) → Unorderly kind
  (_, Nothing) → Orderly

-- | What the scheduler answers the instance layer's transactions.
gateOf ∷ Control → Gate
gateOf control =
  Gate
    { gateOpen = do
        closed ← schedulerClosed scheduler
        stopping ← controlStopping control
        pure (not closed && not stopping)
    , gateTick = readTick scheduler
    , gateWatch = watchTick scheduler
    , gateExecution = \task →
        taskPhase scheduler task <&> \case
          Just PhaseRunning → ExecRunning
          Just PhaseWaiting → ExecWaiting
          Just PhasePaused → ExecWaiting
          Just PhaseQueued → ExecReady
          Just PhaseReady → ExecReady
          _ → ExecIdle
    }
  where
    scheduler = controlScheduler control
    (<&>) = flip fmap

-- | Retry until the application has asked something of an instance.
awaitInstanceWork ∷ InstanceHost → STM ()
awaitInstanceWork ih =
  awaitJobs (ihInstances ih)
    `orElse` do
      -- An invocation the scheduler had no room for waits for room: the owner wakes
      -- when it appears, as it does for a grant.
      blocked ← readTVar (insBlocked (ihInstances ih))
      unless blocked retry
      room ← hasRoom ih
      unless room retry
    -- A provider finished retiring something an instance released: the owner wakes to
    -- give the charge back, and to settle an ending that was waiting for it.
    `orElse` maybe retry (retirementsReady . lhLeases) (ihLeases ih)

-- | Whether the scheduler would take an invocation now.
hasRoom ∷ InstanceHost → STM Bool
hasRoom ih = admissionAvailable (scheduler' ih) (TaskSpec (BehaviorId "instance") "instance" Nothing OrdinaryClass OneShot (Finished (Returned [])))

scheduler' ∷ InstanceHost → Scheduler Cursor
scheduler' = controlScheduler . ihControl

-- Servicing -----------------------------------------------------------------------------

-- | Service what the application asked, in the order it asked: make new instances
-- and run their @init@, look at queues, and apply requests. Then look again at every
-- queue, so an invocation the scheduler had no room for is retried at the next
-- wake.
serviceInstances ∷ InstanceHost → IO ()
serviceInstances ih = do
  void (settleEnded ih)
  -- What waited for room goes first, in the order of the instances' numbers, ahead of
  -- whatever the batch begins: the room there is is the first blocked instance's, and
  -- not the first job's.
  wasBlocked ← atomically (swapTVar (insBlocked (ihInstances ih)) False)
  early ← halted
  when (wasBlocked && not early) dispatchAll
  -- The jobs pass from the shared inbox to the backlog in one masked step, so a
  -- cancellation cannot land between and lose a batch: whatever is not yet begun is
  -- always in one or the other, where the owner's exit finds it.
  mask_ $ do
    jobs ← atomically (takeJobs (ihInstances ih))
    modifyIORef' (ihBacklog ih) (<> toList jobs)
  mask (drainBacklog ih)
  halting ← halted
  unless halting dispatchAll
  where
    dispatchAll = do
      cells ← Map.elems <$> readTVarIO (insCells (ihInstances ih))
      forM_ cells (dispatch ih)
    -- An owner that was asked to stop begins nothing more: what is left is settled by
    -- its exit, not started now.
    halted = atomically (controlStopping (ihControl ih))

-- | Begin the jobs of the backlog, in order. A job leaves the backlog as it begins, with
-- the handler that settles a request it raised on already installed, so no cancellation
-- lands between. A halt is looked at before each job, so a batch the owner was asked to
-- stop in the middle of is not carried on with: what is left stays where the owner's exit
-- finds it.
drainBacklog ∷ InstanceHost → (∀ a. IO a → IO a) → IO ()
drainBacklog ih restore = do
  halting ← atomically (controlStopping (ihControl ih))
  readIORef (ihBacklog ih) >>= \case
    job : rest | not halting → do
      writeIORef (ihBacklog ih) rest
      restore (run job) `onException` abandon job
      drainBacklog ih restore
    _ → pure ()
  where
    run = \case
      JobStart number → withCell ih number (startInstance ih)
      JobDispatch number → withCell ih number $ \cell → do
        atomically (modifyTVar' (icState cell) (\state → state {isDispatchQueued = False}))
        dispatch ih cell
      JobControl number request receipt → do
        found ← lookupCell ih number
        case found of
          Just cell → applyControl ih cell request receipt
          Nothing → atomically (settleReceipt receipt ControlNoLongerApplicable)
      JobForget number → withCell ih number (forgetStale ih)
    abandon = \case
      JobControl _ _ receipt → atomically (settleReceipt receipt ControlNoLongerApplicable)
      _ → pure ()

-- | The owner's step at a safe boundary, and the one place that decides when what the
-- scheduler had no room for is tried again.
--
-- Whatever a boundary can have released is released first, in one order: invocations
-- that ended are accounted for and give back their active slots and result places,
-- and tickets the application forgot give back theirs. Then, if the application asked
-- anything, or an invocation waits for room and there is room, every instance is
-- looked at in the order of its number, so which invocation takes the room that
-- is there depends on the instances and never on which release made it or where a
-- turn was cut. The scheduler runs this at the boundary after its own work there, so
-- the room that the activations, controls and closes of the boundary freed is used at
-- that boundary, and does the boundary again while this answers that it released or
-- used something: an observed result gives back an active slot that a queued admission
-- waits for, and a control it applied can finish a grant, neither of which anything
-- else at the boundary would then act on before the next segment is chosen. It answers
-- whether it did.
--
-- The release sites of room are these, and each reaches this step before another
-- segment is chosen or a turn ends for budget: an invocation's end (its active slot
-- at the boundary's activation, its result place at the account here), a queued
-- admission's activation (a place of the admission queue), a ticket's observation or
-- forgetting (a result place, by the application at any time, and by the sweep here),
-- an instance's control (a stop or a pause of a begun invocation, whose end is then
-- as any other, and a resume, which looks at the instance), and the end of an instance
-- (its coroutine's close, accounted before the next look). An owner that is stopping
-- admits nothing more, and an invocation the scheduler is still holding for an
-- instance that took it back cannot be released but only chosen.
serviceBoundary ∷ InstanceHost → IO Bool
serviceBoundary ih = do
  halting ← atomically (controlStopping (ihControl ih))
  if halting
    then False <$ reapInvocations ih
    else do
      ended ← settleEnded ih
      swept ← atomically (sweepForgotten (ihControl ih))
      jobs ← readTVarIO (insInbox (ihInstances ih))
      backlog ← readIORef (ihBacklog ih)
      blocked ← readTVarIO (insBlocked (ihInstances ih))
      room ← if blocked then atomically (hasRoom ih) else pure False
      let serve = not (null jobs && null backlog) || room
      when serve (serviceInstances ih)
      -- What the application asked, and what the invocations in flight came to, are
      -- looked at before the cadence points the scheduler reached: a point finds an
      -- instance as the order of its admissions left it.
      cadenced ← serviceCadence ih
      pure (ended || swept || serve || cadenced)

-- | Pause, resume or stop an invocation's task now. This is the owner's own thread,
-- at a boundary, so the scheduler applies it at once, with no reservation to wait
-- for and nothing to ask again.
ownerOp ∷ InstanceHost → TaskId → ControlRequest → IO ()
ownerOp ih task request = void (ownerControl (scheduler' ih) (ihHost ih) task request)

-- | Whether an invocation's coroutine exists: its first segment has run.
hasBegun ∷ InstanceHost → TaskId → IO Bool
hasBegun ih task = Map.member task <$> readIORef (ihTasks ih)

-- | Take back an invocation whose first segment has not run. It has no coroutine, so
-- nothing is closed, and the scheduler's task, which may be waiting for an active slot
-- that other work holds, becomes one that does nothing when it is chosen. The
-- instance is free of it at once.
detach ∷ InstanceHost → ICell → TaskId → IO ()
detach ih cell task = do
  modifyIORef' (ihLive ih) (Map.adjust (\held → held {liveWithdrawn = True}) task)
  modifyIORef' (ihGhosts ih) (Map.insert (icId cell) task)
  atomically (modifyTVar' (icState cell) (\state → state {isActive = Nothing}))

lookupCell ∷ InstanceHost → Word64 → IO (Maybe ICell)
lookupCell ih number = Map.lookup number <$> readTVarIO (insCells (ihInstances ih))

-- | Run an action on an instance that has not settled.
withCell ∷ InstanceHost → Word64 → (ICell → IO ()) → IO ()
withCell ih number action = do
  found ← lookupCell ih number
  forM_ found $ \cell → do
    settled ← isJust <$> readTVarIO (icResult cell)
    unless settled (action cell)

-- | Give the scheduler's result storage back for every invocation that has ended
-- and that the instance layer has accounted for: its instance no longer takes it
-- to be in flight. One the scheduler ended on its own, which the instance has not
-- heard of, is left for 'settleEnded'.
-- Answers whether it gave any back.
reapInvocations ∷ InstanceHost → IO Bool
reapInvocations ih = do
  live ← readIORef (ihLive ih)
  gone ← atomically . fmap concat . forM (Map.toList live) $ \(task, held) →
    taskPhase (scheduler' ih) task >>= \case
      Just (PhaseEnded _) → do
        accounted ← accountedFor ih task held
        if accounted then [(task, True)] <$ observeTask (scheduler' ih) task else pure []
      Nothing → pure [(task, False)]
      _ → pure []
  let tasks = map fst gone
  atomically (modifyTVar' (insTasks (ihInstances ih)) (\held → foldr Set.delete held tasks))
  modifyIORef' (ihLive ih) (\held → foldr Map.delete held tasks)
  modifyIORef' (ihGhosts ih) (Map.filter (`notElem` tasks))
  pure (any snd gone)

-- | Whether the instance layer has accounted for the end of an invocation's task:
-- its instance no longer takes the task to be in flight.
accountedFor ∷ InstanceHost → TaskId → Live → STM Bool
accountedFor ih task held = do
  cells ← readTVar (insCells (ihInstances ih))
  case Map.lookup (liveSlot held) cells of
    Nothing → pure True
    Just cell → (/= Just task) . isActive <$> readTVar (icState cell)

-- | Account for the invocations the scheduler ended without the instance layer
-- ending them: a wait it refused, which fails the task, is the instance's failure.
-- Then give back what ended invocations held.
-- Answers whether it observed or ended anything.
settleEnded ∷ InstanceHost → IO Bool
settleEnded ih = do
  live ← readIORef (ihLive ih)
  observed ← forM (Map.toList live) $ \(task, held) → do
    ended ← atomically $ do
      phase ← taskPhase (scheduler' ih) task
      case phase of
        Just (PhaseEnded _) → do
          accounted ← accountedFor ih task held
          if accounted then pure Nothing else observeTask (scheduler' ih) task
        _ → pure Nothing
    forM_ ended $ \terminal → withCell ih (liveSlot held) $ \cell → case terminal of
      ResultFailed failure → invocationFailed ih cell (liveStage held) (ErrorRefusedWait failure)
      _ → invocationCompleted ih cell (liveStage held)
    pure (isJust ended)
  reaped ← reapInvocations ih
  -- The instances whose coroutines the scheduler closed are ended here, in the owner's
  -- own code, where what a hook raises is the owner's failure and nothing else.
  waiting ← readIORef (ihToFinish ih)
  writeIORef (ihToFinish ih) Set.empty
  forM_ waiting $ \number → withCell ih number (\cell → finishEnding ih cell 0)
  retired ← serviceRetirementsOf ih
  pure (or observed || reaped || not (Set.null waiting) || retired)

-- Starting ----------------------------------------------------------------------------

-- | Make an instance and run its @init@.
startInstance ∷ InstanceHost → ICell → IO ()
startInstance ih cell = case icBehavior cell of
  Just behavior → startBehavior ih cell behavior
  Nothing → startModuleInstance ih cell

-- | Make an M1 behavior instance and run its @init@: on the owner's thread, because
-- the behavior is Lua, find the export module the request names, select, validate and
-- capture the behavior, resolve its cadence from what its table read as, and only then
-- run the captured @init@.
--
-- Every failure before @init@ is the instance's failure at 'StageConstruct', with no
-- hook run and nothing held: what was captured is released as the instance ends, like
-- everything an instance holds. The capture is recorded in the cell in the step that
-- makes it, so no failure or cancellation can leave one nobody will release.
startBehavior ∷ InstanceHost → ICell → BehaviorCell → IO ()
startBehavior ih cell behavior = do
  state ← readTVarIO (icState cell)
  unless (isStopped state) $ do
    forM_ (ihLeases ih) $ \lh → atomically (openScope (lhLeases lh) (icId cell))
    case ihBehaviorDriver ih of
      Nothing → constructFailed (ErrorFault (ModuleNotLoaded behaviorDriverRef))
      Just driver → do
        found ← retrieved (behaviorExport request)
        -- The facade's export module, when it names one, is found as the behavior's is.
        facadeFound ← case behaviorFacade request of
          FacadeData value → pure (Right (FacadeValue value))
          FacadeShared identity key → fmap (\handle → FacadeField handle key) <$> retrieved identity
          FacadeBuilder identity key context → fmap (\handle → FacadeBuilt handle key context) <$> retrieved identity
        case (found, facadeFound) of
          (Left failure, _) → constructFailed failure
          (_, Left failure) → constructFailed failure
          (Right export, Right facade) → do
            made ← mask_ $ do
              attempted ← settledOrRaise (ihExtra ih) (withRunning ih (icId cell) (Owner.captureBehavior owned export (behaviorSelect request) facade))
              case attempted of
                Right (Right capture) →
                  atomically (writeTVar (bcResolved behavior) (Just (BehaviorResolved (capturedHandle capture) (capturedShape capture) EventOnly Nothing)))
                _ → pure ()
              pure attempted
            case made of
              Left fault → constructFailed (ErrorFault fault)
              Right (Left problem) → constructFailed (ErrorBehavior problem)
              Right (Right capture) → resolveCadence driver capture
  where
    owned = ihOwned ih
    request = bcRequest behavior
    constructFailed = failInstance ih cell Initializing StageConstruct
    -- The export module the owner holds under an identity, or why this instance fails.
    retrieved identity = do
      found ← settledOrRaise (ihExtra ih) (withRunning ih (icId cell) (Owner.retrieveExport owned identity))
      pure $ case found of
        Left fault → Left (ErrorFault fault)
        Right Nothing → Left (ErrorExportMissing (identityText identity))
        Right (Just (ExportFailed fault)) → Left (ErrorExportFailed fault)
        Right (Just (ExportReady export)) → Right export
    identityText (ExportIdentity bytes) = Text.take 128 (Text.decodeUtf8Lenient bytes)
    -- The cadence is the application's rule applied to what the table read as, once,
    -- before @init@: an update hook needs an interval and an interval needs an update
    -- hook, and the interval resolves exactly or not at all, as at any admission.
    resolveCadence driver capture =
      case behaviorCadence request shape of
        Left why → constructFailed (ErrorCadence why)
        Right wanted → case (shapeUpdate shape, wanted) of
          (False, Just _) → constructFailed (ErrorCadence "a cadence was given to a behavior that has no update hook")
          (True, Nothing) → constructFailed (ErrorCadence "the behavior has an update hook and no interval")
          (False, Nothing) → initialize driver capture EventOnly Nothing
          (True, Just interval) → case resolveInterval (insTickDuration (ihInstances ih)) interval of
            Left refusal → constructFailed (ErrorCadence (Text.pack (show refusal)))
            Right cadence → initialize driver capture (Periodic interval) (Just cadence)
      where
        shape = capturedShape capture
    initialize driver capture kind cadence = do
      let shape = capturedShape capture
      -- An instance's initialization begins here whether or not its behavior has an @init@, so the
      -- application is told once, here, and not when a hook is entered.
      insOnSegment (ihInstances ih) (InstanceId (controlOwner (ihControl ih)) (icId cell))
      atomically (writeTVar (bcResolved behavior) (Just (BehaviorResolved (capturedHandle capture) shape kind cadence)))
      -- From here a hook may have run: an interruption of @init@ is progress made.
      when (shapeInit shape) $ modifyIORef' (ihEntered ih) (Set.insert (icId cell))
      ran ←
        if shapeInit shape
          then settledOrRaise (ihExtra ih) (withRunning ih (icId cell) (callEntryWith (LeadCaptured driver behaviorInit (capturedHandle capture) HookInit) (ownedHost owned) driver behaviorInit [VInteger (fromIntegral (icId cell))]))
          else pure (Right (Returned []))
      case ran of
        Left fault → failInstance ih cell Initializing StageInit (ErrorFault fault)
        Right _ → do
          atomically . modifyTVar' (icState cell) $ \current →
            if isStopped current
              then current
              else current {isPhase = Active, isInitialized = True}
          problem ← startCadence ih cell
          case problem of
            Just why → failInstance ih cell Active StageUpdate (ErrorCadence why)
            Nothing → dispatch ih cell

-- | Make an instance of a module the owner loaded and run its @init@.
startModuleInstance ∷ InstanceHost → ICell → IO ()
startModuleInstance ih cell = do
  state ← readTVarIO (icState cell)
  unless (isStopped state) $ do
    -- The scope exists before the instance's first hook, so every binding it calls
    -- finds it, @init@'s included.
    forM_ (ihLeases ih) $ \lh → atomically (openScope (lhLeases lh) (icId cell))
    handles ← readIORef (ihHandles ih)
    case Map.lookup (icModule cell) handles of
      Nothing → failInstance ih cell Initializing StageInit (ErrorFault (ModuleNotLoaded (icModule cell)))
      Just handle → do
        runnable ← case icKind cell of
          RunOnce → hookAvailable ih handle "run"
          Periodic _ → hookAvailable ih handle "update"
          EventOnly → pure True
        if not runnable
          then failInstance ih cell Initializing StageInit (ErrorMissingEntry (case icKind cell of Periodic _ → "update"; _ → "run"))
          else do
            made ← settledOrRaise (ihExtra ih) (withRunning ih (icId cell) (callEntry (ihOwned ih) (ihDriver ih) "create" [VInteger (fromIntegral (icId cell))]))
            case made of
              Left fault → failInstance ih cell Initializing StageInit (ErrorFault fault)
              Right _ → do
                modifyIORef' (ihCreated ih) (Set.insert (icId cell))
                declared ← hookAvailable ih handle "init"
                ran ←
                  if declared
                    then settledOrRaise (ihExtra ih) (withSegment ih (icId cell) (callEntryVia (ownedHost (ihOwned ih)) (ihDriver ih) "init" handle "init" [VInteger (fromIntegral (icId cell))]))
                    else pure (Right (Returned []))
                case ran of
                  Left fault → failInstance ih cell Initializing StageInit (ErrorFault fault)
                  Right _ → do
                    atomically . modifyTVar' (icState cell) $ \current →
                      if isStopped current
                        then current
                        else current {isPhase = Active, isInitialized = True}
                    -- A periodic instance's first update is due one interval after this
                    -- point; its demand is registered now, before anything else runs.
                    problem ← startCadence ih cell
                    case problem of
                      Just why → failInstance ih cell Active StageUpdate (ErrorCadence why)
                      Nothing → dispatch ih cell

-- | Run Lua on behalf of this instance, so that a binding its code calls is told
-- which instance is calling and an instance cannot act as another.
withRunning ∷ InstanceHost → Word64 → IO a → IO a
withRunning ih number action = do
  atomically (writeTVar (insRunning (ihInstances ih)) (Just number))
  action `finally` atomically (writeTVar (insRunning (ihInstances ih)) Nothing)

-- | 'withRunning' for the Lua of a hook: the application is told first, on the owner's thread, that
-- this instance's code is about to begin a segment (an @init@, the first segment of an update, a
-- callback or a @run@, every segment a wait resumes, a @shutdown@). What an application samples there
-- is the state of the world as that segment began, and it is stable for the segment. What the
-- callback raises is a failure of the host.
withSegment ∷ InstanceHost → Word64 → IO a → IO a
withSegment ih number action = do
  insOnSegment (ihInstances ih) (InstanceId (controlOwner (ihControl ih)) number)
  withRunning ih number action

-- | Run this on behalf of the instance whose invocation the task is, if it is one: what the
-- scheduler runs of a task that is no segment of it (closing its coroutine, which runs the
-- script's closing handlers) is still the instance's code, and a binding it calls must be told
-- so.
runningTask ∷ InstanceHost → TaskId → IO a → IO a
runningTask ih task action =
  Map.lookup task <$> readIORef (ihLive ih) >>= \case
    Just live → withRunning ih (liveSlot live) action
    Nothing → action

-- | Whether a module has a hook, as an entry point it declares and has. One that is
-- there and is not a function is a hook: running it raises the host's fault for it.
hookAvailable ∷ InstanceHost → ModuleHandle → Text → IO Bool
hookAvailable ih = hookDefined (ihOwned ih)

-- | Whether a module defines a hook: the one definition, which every reading of a module's hooks
-- goes through, the instance's own and the query an application makes of the owner.
hookDefined ∷ OwnedVm → ModuleHandle → Text → IO Bool
hookDefined owned handle name
  | name `notElem` map entryName (handleEntries handle) = pure False
  | otherwise = entryPresent (ownedHost owned) handle name

-- | The optional hooks a module defines, read from the module and running none of its code. On
-- the owner's thread.
definedHooks ∷ OwnedVm → ModuleHandle → IO ModuleHooks
definedHooks owned handle =
  ModuleHooks <$> defined "init" <*> defined "update" <*> defined "shutdown" <*> defined "run"
  where
    defined = hookDefined owned handle

-- | Have the driver let go of the callbacks of subscriptions that ended without the script (an
-- epoch change), on the owner's thread at a safe boundary: the script does not have to unsubscribe
-- a subscription the engine ended, and a VM that holds one holds whatever it captured for as long
-- as the instance lives. The driver's creation entry on a slot that is live is this cleanup, and
-- asks the engine for the numbers itself; an instance that has not been created has nothing to let
-- go of.
forgetStale ∷ InstanceHost → ICell → IO ()
forgetStale ih cell = do
  created ← Set.member (icId cell) <$> readIORef (ihCreated ih)
  state ← readTVarIO (icState cell)
  unless (not created || isTerminal (isPhase state)) $ do
    let slot = VInteger (fromIntegral (icId cell))
    released ← settledOrRaise (ihExtra ih) (withRunning ih (icId cell) (callEntry (ihOwned ih) (ihDriver ih) "create" [slot]))
    case released of
      Left fault → failInstance ih cell (isPhase state) StageRelease (ErrorFault fault)
      Right _ → pure ()

-- Invocations ----------------------------------------------------------------------------

-- | Admit the instance's next invocation as a task, if it has one and may start it.
--
-- A one-shot's @run@ comes first, then the events in the order they were accepted.
-- One at a time: an instance with an invocation in flight, paused, ending or still
-- initializing admits none.
dispatch ∷ InstanceHost → ICell → IO ()
dispatch ih cell = do
  -- A provider that could not preserve an authoritative event of one of the instance's
  -- subscriptions has surfaced a delivery failure: the instance fails with it, once, and
  -- nothing more is begun for it.
  surfaced ← atomically (takeDeliveryFailure cell)
  case surfaced of
    Just (endpoint, reason, phase) → failInstance ih cell phase (StageEvent endpoint) (ErrorDelivery endpoint reason)
    Nothing → do
      -- A required request that reached its eligible settlement with an expected failure fails
      -- its instance here (D-52), at the owner's safe boundary and before any more of its
      -- ordinary work, whether or not its script ever read the request.
      latched ← atomically (takeRequestFailure cell)
      case latched of
        Just (endpoint, reason, phase) → failInstance ih cell phase (StageRequest endpoint) (ErrorRequest endpoint reason)
        Nothing → admitNext ih cell

-- | The instance's delivery failure, if a provider surfaced one and the instance is still taking
-- anything, taken once, with the phase the instance was in.
takeDeliveryFailure ∷ ICell → STM (Maybe (Text, Text, InstancePhase))
takeDeliveryFailure cell = do
  state ← readTVar (icState cell)
  case isDeliveryFailure state of
    Nothing → pure Nothing
    Just (endpoint, reason) → do
      writeTVar (icState cell) state {isDeliveryFailure = Nothing}
      pure (if isStopped state || isTerminal (isPhase state) then Nothing else Just (endpoint, reason, isPhase state))

-- | The instance's latched required-request failure, if the instance is still taking anything,
-- taken once, with the phase the instance was in.
takeRequestFailure ∷ ICell → STM (Maybe (Text, Text, InstancePhase))
takeRequestFailure cell = do
  state ← readTVar (icState cell)
  pure $ case isRequestFailure state of
    -- An instance that is ending is not failed from here: the latch is left where it is, for its settlement to
    -- keep as the failure (or beside the failure) the instance ends with.
    Just _ | isStopped state || isTerminal (isPhase state) → Nothing
    Nothing → Nothing
    -- Read and not cleared: the latch is the instance's until its failure is recorded, and recording it
    -- marks the instance as ending, which is what keeps the latch from being applied twice. A cancellation
    -- between this reading and that recording leaves it where the next boundary, or the settlement, finds it.
    Just (endpoint, reason) → Just (endpoint, reason, isPhase state)

-- | Admit the instance's next invocation as a task, if it has one and may start it.
admitNext ∷ InstanceHost → ICell → IO ()
admitNext ih cell = do
  -- What the scheduler holds for invocations that ended is given back first, so
  -- admitting the next one needs room for one more and not for every one before it.
  void (reapInvocations ih)
  ghost ← Map.lookup (icId cell) <$> readIORef (ihGhosts ih)
  held ← readIORef (ihLive ih)
  started ← atomically $ do
    state ← readTVar (icState cell)
    if isPhase state /= Active || isJust (isActive state)
      then pure Nothing
      else do
        let nextEvent event rest =
              Just
                ( invocationOf event
                , StageEvent (queuedSource event)
                , rest
                , Just event
                , isUpdate state
                )
            -- The events accepted before the update fell due run first, then the update,
            -- then the events accepted after it, so a continuous producer cannot jump
            -- ahead of a due update, and the update never overtakes an earlier event.
            next = case icKind cell of
              RunOnce | not (isRunBegun state) → Just (InvokeRun, StageRun, isQueue state, Nothing, isUpdate state)
              _ → case (isUpdate state, viewl (isQueue state)) of
                (UpdateDue marker, event :< rest) | queuedSequence event < marker → nextEvent event rest
                (UpdateDue marker, _) → Just (InvokeUpdate, StageUpdate, isQueue state, Nothing, UpdateAdmitted marker)
                (_, event :< rest) → nextEvent event rest
                (_, EmptyL) → Nothing
        case next of
          Nothing → pure Nothing
          Just (invocation, stage, rest, event, slot) → do
            let spec =
                  TaskSpec
                    { specBehavior = BehaviorId (behavior invocation)
                    , specEntry = entry invocation
                    , specName = icName cell
                    , specClass = icClass cell
                    , specKind = OneShot
                    , specCursor = PendingInvocation (icId cell) invocation
                    }
            -- The task the instance took back, if this is the same invocation and the
            -- scheduler still holds it unbegun, is the one used again: pausing and
            -- resuming over and over does not leave a ghost behind each time.
            reusable ← case ghost of
              Just task
                | Just live ← Map.lookup task held
                , liveStage live == stage
                , liveSequence live == fmap queuedSequence event → do
                    phase ← taskPhase (scheduler' ih) task
                    pure $ case phase of
                      Just PhaseQueued → Just task
                      Just PhaseReady → Just task
                      _ → Nothing
              _ → pure Nothing
            answer ← case reusable of
              Just task → pure (Admitted task)
              Nothing → admitTask (scheduler' ih) spec
            case answer of
              Admitted task → do
                writeTVar (icState cell) $
                  state
                    { isActive = Just task
                    , isQueue = rest
                    , isPending = event
                    , isUpdate = slot
                    }
                when (isNothing reusable) $ modifyTVar' (insTasks (ihInstances ih)) (Set.insert task)
                pure (Just (task, stage, event, isJust reusable))
              _ → Nothing <$ writeTVar (insBlocked (ihInstances ih)) True
  forM_ started $ \(task, stage, event, revived) →
    if revived
      then do
        modifyIORef' (ihLive ih) (Map.adjust (\live → live {liveWithdrawn = False}) task)
        modifyIORef' (ihGhosts ih) (Map.delete (icId cell))
      else modifyIORef' (ihLive ih) (Map.insert task (Live (icId cell) stage (fmap queuedSequence event) False (maybe False (isJust . queuedSubscription) event)))
  where
    record event =
      VRecord
        [ ("source", VText (queuedSource event))
        , ("sequence", VInteger (fromIntegral (queuedSequence event)))
        , ("tick", VInteger (fromIntegral (queuedTick event)))
        , ("payload", queuedPayload event)
        ]
    -- A subscription's delivery is a reference: its value is taken from the subscription as
    -- the callback's first segment is about to run, not before.
    invocationOf event = case queuedSubscription event of
      Just identity → InvokeSubscription (queuedSource event) identity
      Nothing → InvokeEvent (queuedSource event) (WithinBounds [record event])
    entry = \case
      InvokeSubscription endpoint _ → subscriptionEntry endpoint
      InvokeEvent source _ → eventEntry source
      InvokeUpdate → "update"
      InvokeRun → "run"
    behavior invocation = moduleRefName (icModule cell) <> "/" <> entry invocation

-- | Run one segment of an instance's invocation, on behalf of the scheduler.
--
-- What the application asked was applied at the boundary before this segment was
-- chosen, so an instance whose invocation is chosen is the one that may run. A task
-- the instance took back before it began, or one whose instance has ended, runs
-- nothing.
instanceSegment ∷ InstanceHost → TaskRun Cursor → Word64 → Maybe Invocation → IO (SegmentReport Cursor)
instanceSegment ih run number starting = do
  found ← lookupCell ih number
  held ← Map.lookup (runTask run) <$> readIORef (ihLive ih)
  case (found, held) of
    (Just cell, Just live) → do
      settled ← isJust <$> readTVarIO (icResult cell)
      if settled || liveWithdrawn live
        then pure (ReportCompleted (Finished (Returned [])))
        else mask_ (go cell (liveStage live))
    _ → pure (ReportCompleted (Finished (Returned [])))
  where
    go cell stage = do
      -- Its first segment is about to run: it is no longer an unstarted invocation. A
      -- subscription's delivery is taken from the subscription in the same step, so nothing
      -- replaces its value between its no longer being unstarted and its being taken: from
      -- here the payload is the callback's, and immutable.
      taken ← atomically $ do
        state ← readTVar (icState cell)
        writeTVar (icState cell) state
          { isPending = Nothing
          , isRunBegun = isRunBegun state || stage == StageRun
          , isUpdate = case isUpdate state of
              UpdateAdmitted _ → UpdateNone
              other → other
          , isUpdateRunning = isUpdateRunning state || stage == StageUpdate
          }
        case (starting, ihProvider ih, isPending state) of
          (Just (InvokeSubscription _ identity), Just service, Just reference) | queuedSubscription reference == Just identity →
            fmap ((,) reference) <$> startDelivery service identity
          _ → pure Nothing
      let slot = VInteger (fromIntegral number)
          -- An M1 behavior's update runs the captured hook, which the instance holds
          -- and nothing looks up again, handed the instance's own self and facade.
          startBehaviorUpdate behavior = do
            resolved ← readTVarIO (bcResolved behavior)
            case (resolved, ihBehaviorDriver ih) of
              (Just held, Just driver) →
                updateDelta ih cell >>= \case
                  Left why → pure (Left (ErrorCadence why))
                  Right seconds → do
                    atomically (writeTVar (insDelta (ihInstances ih)) (Just (number, seconds)))
                    begin (withSegment ih number (startTaskCaptured (ownedHost (ihOwned ih)) driver behaviorUpdate (resolvedCapture held) HookUpdate [slot]))
                      `finally` atomically (writeTVar (insDelta (ihInstances ih)) Nothing)
              _ → pure (Left (ErrorFault (ModuleNotLoaded behaviorDriverRef)))
      outcome ← case starting of
        Just (InvokeEvent source (WithinBounds [event])) →
          begin $ withSegment ih number (startTask (ihOwned ih) (ihDriver ih) (eventEntry source) [slot, event])
        Just (InvokeEvent _ _) → pure (Left (ErrorMissingEntry "an event"))
        Just (InvokeSubscription endpoint _) → case taken of
          Just (reference, started) →
            begin . withSegment ih number $
              startTask
                (ihOwned ih)
                (ihDriver ih)
                (subscriptionEntry endpoint)
                [slot, eventRecord endpoint (queuedSequence reference) (queuedTick reference) (startedNumber started) (startedPayload started)]
          -- The subscription ended before its callback began, and the model counted what it
          -- discarded: nothing runs and there is nothing to wait for.
          Nothing → pure (Right Nothing)
        Just InvokeRun → do
          handles ← readIORef (ihHandles ih)
          case Map.lookup (icModule cell) handles of
            Nothing → pure (Left (ErrorFault (ModuleNotLoaded (icModule cell))))
            Just handle → begin $ withSegment ih number (startTaskVia (ownedHost (ihOwned ih)) (ihDriver ih) "run" handle "run" [slot])
        Just InvokeUpdate | Just behavior ← icBehavior cell → startBehaviorUpdate behavior
        Just InvokeUpdate → do
          handles ← readIORef (ihHandles ih)
          case Map.lookup (icModule cell) handles of
            Nothing → pure (Left (ErrorFault (ModuleNotLoaded (icModule cell))))
            Just handle →
              -- Its dt is fixed here, as the invocation begins, and nothing it waits through
              -- or is delayed by changes it.
              updateDelta ih cell >>= \case
                Left why → pure (Left (ErrorCadence why))
                Right seconds → do
                  -- The delta is left for the driver to take through its binding, as the
                  -- update's first segment begins, and is not left behind if that never does.
                  atomically (writeTVar (insDelta (ihInstances ih)) (Just (number, seconds)))
                  begin (withSegment ih number (startTaskVia (ownedHost (ihOwned ih)) (ihDriver ih) "run" handle "update" [slot]))
                    `finally` atomically (writeTVar (insDelta (ihInstances ih)) Nothing)
        Nothing → do
          held ← Map.lookup (runTask run) <$> readIORef (ihTasks ih)
          case held of
            Nothing → pure (Left (ErrorRefusedWait (TaskFailure (failureReason ScriptFault "the invocation's continuation is not held by its owner") RecoverySafe)))
            Just task → do
              resumed ← settledOrRaise (ihExtra ih) (withSegment ih number (resumeTask (ihOwned ih) task))
              case resumed of
                Left fault → do
                  modifyIORef' (ihTasks ih) (Map.delete (runTask run))
                  pure (Left (ErrorFault fault))
                Right step → pure (Right (Just step))
      case outcome of
        Left failure → do
          invocationFailed ih cell stage failure
          pure (ReportFailed (taskFailure failure))
        Right Nothing → do
          -- The entry point is not there: nothing ran, and there is nothing to wait for.
          invocationCompleted ih cell stage
          pure (ReportCompleted (Finished (Returned [])))
        Right (Just step) → case step of
          Owner.Completed _ → do
            modifyIORef' (ihTasks ih) (Map.delete (runTask run))
            invocationCompleted ih cell stage
            pure (ReportCompleted (Finished (Returned [])))
          Owner.Yielded → pure (ReportYielded (HostedInvocation number))
          Owner.Waiting request → waitReportFor (ihProvider ih) (RequesterInstance number) (HostedInvocation number) request
    -- Start a task and keep its coroutine where the owner's retirement finds it:
    -- acquired and published together, masked, so a cancellation lands after both.
    begin start = do
      started ← settledOrRaise (ihExtra ih) start
      case started of
        Left fault → pure (Left (ErrorFault fault))
        Right TaskEntryAbsent → pure (Right Nothing)
        Right (TaskStarted task step) → do
          modifyIORef' (ihTasks ih) (Map.insert (runTask run) task)
          pure (Right (Just step))
    taskFailure failure = TaskFailure (failureReason ScriptFault (renderError failure)) RecoverySafe

-- | An invocation ended without failing: the instance is free for the next one, or
-- is done, if it was a one-shot's @run@.
invocationCompleted ∷ InstanceHost → ICell → HookStage → IO ()
invocationCompleted ih cell stage = do
  atomically $ do
    modifyTVar' (icState cell) (\state → state {isActive = Nothing, isUpdateRunning = isUpdateRunning state && stage /= StageUpdate})
    -- A logical update's dt is the duration granted since the previous update
    -- finished: a finished update begins the accrual again.
    when (stage == StageUpdate) (resetCadenceAccrued (scheduler' ih) (CadenceKey (icId cell)))
  case stage of
    StageRun → beginStop ih cell EndCompleted Nothing
    _ → dispatch ih cell

-- | An invocation failed: the instance fails with it, and ends.
invocationFailed ∷ InstanceHost → ICell → HookStage → InstanceError → IO ()
invocationFailed ih cell stage failure = do
  phase ← isPhase <$> readTVarIO (icState cell)
  atomically (modifyTVar' (icState cell) (\state → state {isActive = Nothing}))
  beginStop ih cell EndFailed (Just (Primary phase stage failure))

-- | A coroutine of the scheduler was closed: by a stop, by the owner's own, or
-- because its task ended while it was suspended, as a task whose wait the scheduler
-- refused does; whether the invocation had begun is told. The instance whose
-- invocation it was ends after its coroutine, which is already closed: as failed,
-- if the scheduler failed the task, and as stopped otherwise.
instanceClosed ∷ InstanceHost → TaskId → Bool → IO ()
instanceClosed ih task began = do
  held ← Map.lookup task <$> readIORef (ihLive ih)
  -- A task the instance took back is a ghost the scheduler may still close: it ends
  -- nothing, and neither does a task that is not the instance's invocation in flight.
  forM_ held $ \live → unless (liveWithdrawn live) $ withCell ih (liveSlot live) $ \cell → do
    current ← (== Just task) . isActive <$> readTVarIO (icState cell)
    when current (endCurrent live cell)
  where
   endCurrent live cell = do
    failed ← atomically $
      taskPhase (scheduler' ih) task >>= \case
        Just (PhaseEnded OutcomeFailed) → observeTask (scheduler' ih) task
        _ → pure Nothing
    phase ← isPhase <$> readTVarIO (icState cell)
    -- Counted as an unstarted invocation if it never ran a segment: ending begins
    -- before the invocation is let go of, so it is among what is discarded.
    case failed of
      Just (ResultFailed failure) →
        beginEnding' ih cell EndFailed (Just (Primary phase (liveStage live) (ErrorRefusedWait failure)))
      _ → beginEnding' ih cell EndStopped Nothing
    atomically (modifyTVar' (icState cell) (\state → state {isActive = Nothing}))
    -- The coroutine is closed and counted; the instance is ended from the owner's own
    -- code, not from inside the close.
    modifyIORef' (ihEndings ih) (Map.adjust (\ending → ending {endClosed = max (endClosed ending) (if began then 1 else 0)}) (icId cell))
    modifyIORef' (ihToFinish ih) (Set.insert (icId cell))

-- Cadence -------------------------------------------------------------------------------

-- | The cadence's key for an instance: the instance's own number.
cadenceKey ∷ ICell → CadenceKey
cadenceKey = CadenceKey . icId

-- | The tick an interval after another, or nothing when that is not a tick.
checkedTick ∷ Word64 → Word64 → Maybe Word64
checkedTick tick interval
  | maxBound - tick < interval = Nothing
  | otherwise = Just (tick + interval)

-- | Register an initialized periodic instance's demand: a logical one at the tick one
-- interval after the tick @init@ succeeded at, with nothing accrued, an elapsed one at
-- the instant one interval after it, with the baseline its @dt@ is measured from.
-- Answers what went wrong, if the first point is not representable.
startCadence ∷ InstanceHost → ICell → IO (Maybe Text)
startCadence ih cell = do
  stopped ← isStopped <$> readTVarIO (icState cell)
  cadence ← cellCadence cell
  case cadence of
    Just (CadenceTicks interval) | not stopped → do
      tick ← atomically (readTick (scheduler' ih))
      case checkedTick tick interval of
        Nothing → pure (Just "the tick the first update is due at is not representable")
        Just target → Nothing <$ atomically (startLogicalCadence (scheduler' ih) (cadenceKey cell) target)
    Just (CadenceElapsed interval) | not stopped → do
      now ← readInstant (schedulerClock (scheduler' ih))
      case addDuration now interval of
        Left _ → pure (Just "the deadline the first update is due at is not representable")
        Right deadline → do
          atomically $ do
            started ← startElapsedCadence (scheduler' ih) (cadenceKey cell) deadline
            when started (modifyTVar' (icState cell) (\state → state {isBaseline = snd (advanceBaseline now noBaseline)}))
          pure Nothing
    _ → pure Nothing

-- | Arm a resumed instance's demand again: a full interval from now, from the tick at
-- which the resume was applied or from the instant it was. An elapsed instance's
-- baseline is rebased to this instant, so its @dt@ excludes the pause.
resumeCadence ∷ InstanceHost → ICell → IO (Maybe Text)
resumeCadence ih cell = cellCadence cell >>= \case
  Just (CadenceTicks interval) → do
    tick ← atomically (readTick (scheduler' ih))
    case checkedTick tick interval of
      Nothing → pure (Just "the tick the next update is due at is not representable")
      Just target → Nothing <$ atomically (armLogicalCadence (scheduler' ih) (cadenceKey cell) target)
  Just (CadenceElapsed interval) → do
    now ← readInstant (schedulerClock (scheduler' ih))
    case addDuration now interval of
      Left _ → pure (Just "the deadline the next update is due at is not representable")
      Right deadline → do
        atomically $ do
          armElapsedCadence (scheduler' ih) (cadenceKey cell) deadline
          modifyTVar' (icState cell) (\state → state {isBaseline = snd (advanceBaseline now (isBaseline state))})
        pure Nothing
  Nothing → pure Nothing

-- | The @dt@ an update begins with, in seconds: for a logical interval the duration
-- granted since the previous update finished (since @init@ succeeded, for the first)
-- less what was granted while the instance was intentionally paused, and for an
-- elapsed one the time between update starts (from @init@, rebased at a resume). The
-- exact duration is converted once, here, which is the only rounding. Fixed as the
-- update begins.
updateDelta ∷ InstanceHost → ICell → IO (Either Text Double)
updateDelta ih cell = cellCadence cell >>= \case
  Just (CadenceTicks _) →
    maybe (Left "the instance's logical accrual is gone") fits <$> atomically (cadenceAccrued (scheduler' ih) (cadenceKey cell))
  Just (CadenceElapsed _) → do
    now ← readInstant (schedulerClock (scheduler' ih))
    sampled ← atomically $ do
      state ← readTVar (icState cell)
      let (elapsed, baseline) = advanceBaseline now (isBaseline state)
      writeTVar (icState cell) state {isBaseline = baseline}
      pure elapsed
    pure (fits sampled)
  Nothing → pure (Left "the instance has no interval")
  where
    fits duration = Right (secondsOf duration)

-- | A duration as a number of seconds, correctly rounded once from its exact count of
-- nanoseconds.
secondsOf ∷ Duration → Double
secondsOf duration = fromRational (toRational (durationNanoseconds duration) / 1000000000)

-- | The first point on a cadence, from this deadline and interval, that is strictly
-- after this reading: ordinary lateness moves the next deadline here, with no burst of
-- refreshes for the points it passed.
nextFuture ∷ Instant → Duration → Instant → Maybe Instant
nextFuture deadline interval now =
  case durationFromNanoseconds AllowZero (toInteger (skipped * step)) of
    Left _ → Nothing
    Right span' → either (const Nothing) Just (addDuration deadline span')
  where
    late = durationNanoseconds (elapsedBetween deadline now)
    step = durationNanoseconds interval
    skipped = late `div` step + 1

-- | Serve the cadence points the scheduler reached, in the order it reached them, and
-- then let go of the ticks whose update cannot run in them. Answers whether it did
-- anything the boundary should look at again.
--
-- Called at a safe boundary, after the grant a point belongs to was applied and before
-- any task that grant woke is chosen: an instance's invocation in flight is in flight
-- here, and a callback the grant resumes is still active.
serviceCadence ∷ InstanceHost → IO Bool
serviceCadence ih = go []
  where
    -- The points are taken one at a time, so those behind the one being served are still the
    -- scheduler's, where a pause, a resume or an ending that comes first can invalidate them.
    go served =
      atomically (takeNextCadenceFiring (scheduler' ih)) >>= \case
        Just (key, firing)
          | key == watchKey → serveWatch ih firing >> go (key : served)
          | otherwise → serveFiring ih (key, firing) >> go (key : served)
        Nothing → do
          -- A tick just served has had no chance to run its update yet: it is looked at the
          -- next time round, which the answer below makes the boundary do.
          released ← settleHolds ih served
          claimed ← settleClaims ih
          pure (not (null served) || released || claimed)

-- | The tick the owner asked to be held at has been reached, and the grant that reached it is
-- held, so no later one is applied until this is done: the controls the application assigned to
-- it, and to any earlier tick, are applied, in the order of their places, and then the grant is
-- let go. It is the first point of its grant, so they are applied before any cadence point of
-- the tick, which then finds the instance as they left it, and so before any task the tick woke.
-- What is queued for a later tick is what the owner next asks to be held at, in the step that
-- takes these, so no request can be queued between.
--
-- The events a provider delivered to the tick are admitted after the controls, in the order of
-- their places, and the grant is not let go until the instances they were admitted to have begun
-- them or cannot ('settleClaims'): the next tick's events are not admitted while this tick's
-- are unstarted, so a value is never replaced before it was seen at its own tick, and a queue
-- that is full is full of what the logical sequence put in it, however fast the owner served.
serveWatch ∷ InstanceHost → CadenceFiring → IO ()
serveWatch ih = \case
  FiredLogical tick → do
    -- The controls are taken and kept where the owner's exit settles them in one masked step.
    mask_ $ do
      taken ← atomically $ do
        due ← takeDueControls (ihInstances ih) tick
        later ← readTVar (insLogical (ihInstances ih))
        -- The requests due at this tick are served in the same step, and the next place
        -- either kind of input waits for is what the owner watches for next: the one watch is
        -- shared, so neither can leave the other without it.
        nextRequest ← maybe (pure Nothing) (`serveTick` tick) (ihProvider ih)
        let nextControl = fst <$> Map.lookupMin (Map.mapKeys controlTick later)
        setWatch (scheduler' ih) (earliest nextControl nextRequest)
        pure due
      modifyIORef' (ihDue ih) (<> taken)
    applyDue ih (const True)
    -- Taken and kept where the instances are looked at in one masked step: they are in the
    -- queues, and the grant waits for them.
    served ← mask_ (maybe (pure []) (\service → servedInstances <$> atomically (serveEvents service tick)) (ihProvider ih))
    forM_ served $ \number → withCell ih number (dispatch ih)
    void (settleClaims ih)
  _ → atomically (releaseWatch (scheduler' ih))

-- | The earlier of two ticks that may not be there.
earliest ∷ Maybe Word64 → Maybe Word64 → Maybe Word64
earliest (Just first) (Just second) = Just (min first second)
earliest first Nothing = first
earliest Nothing second = second

-- | Apply the controls held for this boundary, from the front, for as long as the places
-- they were assigned satisfy the test. Each leaves the list as it begins, with the handler
-- that settles it if applying it raised already installed, so no cancellation lands between:
-- whatever is not begun stays where the owner's exit settles it, and a halt stops the
-- batch as it stops the jobs'.
applyDue ∷ InstanceHost → (ControlSlot → Bool) → IO ()
applyDue ih wanted = mask loop
  where
    loop ∷ (∀ a. IO a → IO a) → IO ()
    loop restore = do
      halting ← atomically (controlStopping (ihControl ih))
      readIORef (ihDue ih) >>= \case
        (slot, control) : rest | wanted slot && not halting → do
          writeIORef (ihDue ih) rest
          restore (applyLogical ih control) `onException` atomically (settleReceipt (logicalReceipt control) ControlNoLongerApplicable)
          loop restore
        _ → pure ()

-- | One request the application assigned to a tick, at that tick's boundary.
applyLogical ∷ InstanceHost → LogicalControl → IO ()
applyLogical ih (LogicalControl number request receipt) = do
  found ← lookupCell ih number
  case found of
    Just cell → applyControl ih cell request receipt
    Nothing → atomically (settleReceipt receipt ControlNoLongerApplicable)

-- | One cadence point.
serveFiring ∷ InstanceHost → (CadenceKey, CadenceFiring) → IO ()
serveFiring ih (CadenceKey number, firing) = withCell ih number $ \cell → do
  state ← readTVarIO (icState cell)
  let accepting = isPhase state == Active && not (isStopped state)
      markDue = atomically (modifyTVar' (icState cell) (\current → current {isUpdate = UpdateDue (isNextSequence current)}))
      unrepresentable what = failInstance ih cell Active StageUpdate (ErrorCadence what)
  case firing of
    FiredFault CadenceAccrualOverflow ->
      failInstance ih cell (isPhase state) StageUpdate (ErrorCadence "the logical duration granted since the previous update finished is not representable")
    FiredLogical tick → do
      -- A logical point makes an update due only if it finds the instance serving and
      -- with no invocation active, whatever the invocation is and wherever it waits:
      -- otherwise it adds nothing, and the grant it held is let go. An invocation that
      -- is active has begun and not finished; one admitted and not yet begun is still
      -- queued, and the update falls due behind it.
      let begun = isJust (isActive state) && isNothing (isPending state) && not (admittedUpdate state)
          free = not begun && isUpdate state == UpdateNone
      if accepting && free
        then markDue >> dispatch ih cell
        else atomically (releaseCadenceHold (scheduler' ih) (cadenceKey cell))
      when accepting $ cellCadence cell >>= \case
        Just (CadenceTicks interval) → case checkedTick tick interval of
          Nothing → unrepresentable "the tick the next update is due at is not representable"
          Just target → atomically (armLogicalCadence (scheduler' ih) (cadenceKey cell) target)
        _ → pure ()
    FiredElapsed deadline now → when accepting $ do
      -- At most one refresh is kept unstarted: demand that finds one is coalesced into it.
      when (isUpdate state == UpdateNone) (markDue >> dispatch ih cell)
      cellCadence cell >>= \case
        Just (CadenceElapsed interval) → case nextFuture deadline interval now of
          Nothing → unrepresentable "the deadline the next update is due at is not representable"
          Just next → atomically (armElapsedCadence (scheduler' ih) (cadenceKey cell) next)
        _ → pure ()

-- | Whether the update is the invocation in flight and has not begun.
admittedUpdate ∷ IState → Bool
admittedUpdate state = case isUpdate state of
  UpdateAdmitted _ → True
  _ → False

-- | Let go of the grants that logical instances' due updates hold when those updates
-- can no longer run in their ticks. The instances whose points were served just now are
-- left for the next look.
settleHolds ∷ InstanceHost → [CadenceKey] → IO Bool
settleHolds ih skip = do
  cells ← Map.elems <$> readTVarIO (insCells (ihInstances ih))
  or <$> forM cells (\cell → cellCadence cell >>= \case
    Just (CadenceTicks _) | cadenceKey cell `notElem` skip → settleHold ih cell
    _ → pure False)

settleHold ∷ InstanceHost → ICell → IO Bool
settleHold ih cell = do
  held ← atomically (cadenceHeld (scheduler' ih) (cadenceKey cell))
  if not held
    then pure False
    else do
      state ← readTVarIO (icState cell)
      release ← holdReleasable ih state
      when release (atomically (releaseCadenceHold (scheduler' ih) (cadenceKey cell)))
      pure release

-- | The one place a tick is claimed for the deliveries of subscriptions and given back.
--
-- __The invariant.__ A tick whose grant is applied is held, by the owner's watch, for as long as
-- any instance has a subscription's delivery that is admitted and unfinished (waiting in its queue,
-- selected for its next invocation, or being run by the invocation in flight) /and/ can make
-- progress in that tick: it is serving, and the invocation in flight is ready to run a segment, or
-- is about to be accounted for or given a place, or nothing is in flight and the next delivery waits
-- its turn, and something is ready to run. An instance whose work is suspended on a wait (a tick, a
-- deadline, a request), or that is paused, stopping, ended or still initializing, cannot, and a tick
-- never waits on it: it claims the ticks it is woken at and later ones, as it becomes able, by
-- the same rule. The claim is computed here from the instances' state as it is, never from a
-- flag set when a delivery was admitted, so no path that changes a delivery's state (admission,
-- dispatch, a yield, a wait, the resume that ends it, a coalesce, an unsubscribe, an epoch change,
-- a pause or a stop, a failure) can leave a tick claimed that nothing needs or unclaimed that
-- something does: each of them changes the state this reads.
--
-- While any instance has such work, the owner also asks to be held at the next tick, so the next
-- grant that is applied finds this function at the boundary that follows it, before any task it woke
-- is chosen. The grant held is given back when no instance can make progress. Answers whether it
-- gave one back.
settleClaims ∷ InstanceHost → IO Bool
settleClaims ih = do
  cells ← Map.elems <$> readTVarIO (insCells (ihInstances ih))
  claims ← forM cells (instanceClaim ih)
  let watching = any fst claims
      progressing = any snd claims
  atomically $ do
    held ← watchHeld (scheduler' ih)
    tick ← readTick (scheduler' ih)
    unless progressing (releaseWatch (scheduler' ih))
    when (watching && tick < maxBound) (watchTick (scheduler' ih) (tick + 1))
    pure (held && not progressing)

-- | What an instance's deliveries of subscriptions claim: whether it has any admitted and
-- unfinished, and whether it can make progress with them in the tick it is at. See 'settleClaims'.
instanceClaim ∷ InstanceHost → ICell → IO (Bool, Bool)
instanceClaim ih cell = do
  state ← readTVarIO (icState cell)
  live ← readIORef (ihLive ih)
  if isTerminal (isPhase state) || isStopped state || isPhase state /= Active
    then pure (False, False)
    else do
      let delivery = isJust . queuedSubscription
          queued = any delivery (toList (isQueue state)) || maybe False delivery (isPending state)
          inFlight = maybe False liveDelivery (isActive state >>= \task → Map.lookup task live)
      if not (queued || inFlight)
        then pure (False, False)
        else do
          stuck ← not <$> atomically (tasksReady (scheduler' ih))
          progress ← case isActive state of
            -- Nothing in flight, so what is queued waits for its turn to be given a place.
            Nothing → pure (not stuck)
            Just task →
              atomically (taskPhase (scheduler' ih) task) <&> \case
                Just PhaseReady → True
                Just PhaseRunning → True
                Just PhaseQueued → not stuck
                -- An invocation that ended is accounted for, and the next one begun, at the
                -- boundary that sees it.
                Just (PhaseEnded _) → True
                _ → False
          pure (True, progress)
  where
    (<&>) = flip fmap

-- | Whether a due update can no longer run in the tick that is waiting for it. A tick
-- never waits on an update that cannot start.
--
-- It keeps its hold while the update can still run in the tick: while it is due or
-- admitted and what is ahead of it, or it, is ready to run segments; and lets go when
-- the instance is paused, stopping or ended, when an invocation queued ahead of it has
-- begun and suspended on a wait, when it has begun and stopped being ready or running,
-- and when nothing at all is ready to run, so what it waits for can never happen.
holdReleasable ∷ InstanceHost → IState → IO Bool
holdReleasable ih state
  | isTerminal (isPhase state) || isStopped state || isPhase state /= Active = pure True
  | isUpdate state == UpdateNone && not (isUpdateRunning state) = pure True
  | otherwise = do
      stuck ← not <$> atomically (tasksReady (scheduler' ih))
      case isActive state of
        -- Due, and not admitted yet: the instance has nothing in flight and the update
        -- waits for its turn to be given a place.
        Nothing → pure stuck
        Just task →
          atomically (taskPhase (scheduler' ih) task) <&> \case
            Just PhaseReady → False
            Just PhaseRunning → False
            Just PhaseQueued → stuck
            -- An invocation that ended is accounted for, and the next one begun, at the
            -- boundary that sees it: an update that ended has finished its work.
            Just (PhaseEnded _) → isUpdateRunning state
            _ → True
  where
    (<&>) = flip fmap

-- Control --------------------------------------------------------------------------------

-- | Apply a request: the instance's own transition, then what it means for the
-- invocation in flight. Settled at once, with what it came to.
applyControl ∷ InstanceHost → ICell → InstanceControl → InstanceControlReceipt → IO ()
applyControl ih cell request receipt = do
  state ← readTVarIO (icState cell)
  let settle = atomically . settleReceipt receipt
  if isTerminal (isPhase state)
    then settle ControlNoLongerApplicable
    else
      if isStopped state
        then settle (if request == InstanceStop then ControlAlreadyInState else ControlNoLongerApplicable)
        else case (isPhase state, request) of
          (Active, InstancePause) → do
            -- Pausing runs no application code, so it is done before it is settled: the
            -- instance is frozen when the request is read as applied.
            atomically (modifyTVar' (icState cell) (\current → current {isPhase = Paused}))
            forM_ (isActive state) (pauseInvocation ih cell)
            -- A paused instance accrues no periodic demand; what it has accrued toward its
            -- dt it keeps.
            atomically (disarmCadence (scheduler' ih) (CadenceKey (icId cell)))
            settle ControlApplied
          (Active, InstanceResume) → settle ControlAlreadyInState
          (Paused, InstancePause) → settle ControlAlreadyInState
          (Paused, InstanceResume) → do
            atomically (modifyTVar' (icState cell) (\current → current {isPhase = Active}))
            -- The first update newly due is one full interval after this resume.
            problem ← resumeCadence ih cell
            case isActive state of
              Just task → ownerOp ih task RequestResume
              Nothing → dispatch ih cell
            settle ControlApplied
            forM_ problem (failInstance ih cell Active StageUpdate . ErrorCadence)
          (_, InstanceStop) → do
            -- Settled as it begins, before anything that can raise: a host failure in
            -- the hook that follows cannot leave the request unsettled.
            beginEnding' ih cell EndStopped Nothing
            settle ControlApplied
            continueStop ih cell
          _ → settle ControlAlreadyInState

-- Ending ---------------------------------------------------------------------------------

-- | Fail an instance at a hook, before it has an invocation in flight.
failInstance ∷ InstanceHost → ICell → InstancePhase → HookStage → InstanceError → IO ()
failInstance ih cell phase stage failure = beginStop ih cell EndFailed (Just (Primary phase stage failure))

-- | Begin ending an instance: its admission and connections close and what had not
-- begun is discarded, and then either its invocation in flight is stopped, which
-- finishes the ending once its coroutine is closed, or nothing is in flight and the
-- ending finishes now.
beginStop ∷ InstanceHost → ICell → EndReason → Maybe Primary → IO ()
beginStop ih cell reason primary = do
  beginEnding' ih cell reason primary
  continueStop ih cell

-- | The rest of a stop once it has begun: the invocation in flight is asked to stop,
-- or nothing is in flight and the ending finishes now.
continueStop ∷ InstanceHost → ICell → IO ()
continueStop ih cell = do
  state ← readTVarIO (icState cell)
  case isActive state of
    Nothing → finishEnding ih cell 0
    Just task → do
      started ← hasBegun ih task
      if started
        then do
          -- Its coroutine is closed on this thread and the instance ended after it, as
          -- the scheduler's own stop does; if the scheduler finds nothing to close, the
          -- ending finishes here.
          ownerOp ih task RequestStop
          settled ← isJust <$> readTVarIO (icResult cell)
          unless settled (finishEnding ih cell 0)
        else do
          -- It has not run a segment: nothing to close. It is an unstarted invocation
          -- discarded, and the instance ends without waiting for the scheduler to
          -- choose a task that may be queued behind work that never ends.
          detach ih cell task
          finishEnding ih cell 0

-- | Freeze the invocation in flight: a suspended one is paused in the scheduler; one
-- that has not run a segment is taken back, with its event, to be started on resume.
pauseInvocation ∷ InstanceHost → ICell → TaskId → IO ()
pauseInvocation ih cell task = do
  started ← hasBegun ih task
  if started
    then ownerOp ih task RequestPause
    else do
      detach ih cell task
      -- An event goes back to the front of the queue; a run needs no putting back, for
      -- it was never anywhere but owed.
      atomically . modifyTVar' (icState cell) $ \state → case (isPending state, isUpdate state) of
        (Just event, _) → state {isQueue = event <| isQueue state, isPending = Nothing}
        (Nothing, UpdateAdmitted marker) → state {isUpdate = UpdateDue marker}
        _ → state

-- | Record how an instance is ending, once, and close what it accepts.
beginEnding' ∷ InstanceHost → ICell → EndReason → Maybe Primary → IO ()
beginEnding' ih cell reason primary = mask_ $ do
  -- Closing admission and recording what that revoked and discarded are one step: a
  -- cancellation cannot land between them and leave the counts unwritten. The
  -- instance's periodic demand is cancelled with it, and a tick its due update held is
  -- let go.
  -- The owner's accounting is told in the same step: an ending that has begun is owed to the
  -- application's wait for the owner's accounting until it has settled and its escalation has
  -- returned, and there is no moment in which it has begun and is not counted.
  (connections, unstarted, already) ← atomically $ do
    begun@(_, _, began) ← beginEnding cell <* stopCadence (scheduler' ih) (CadenceKey (icId cell))
    unless began (endingBegun (ihControl ih) (icId cell))
    pure begun
  unless already $
    modifyIORef' (ihEndings ih) (Map.insert (icId cell) (Ending reason primary connections unstarted 0 ShutdownUndecided))

-- | Finish ending an instance: its @shutdown@ hook, once, the release of its
-- record in the VM, and its settlement, once. The application is then told if it
-- failed.
--
-- What the ending came to is kept in the instance's 'Ending' as it is decided, and
-- 'settleEnding' reads it: coming back to an ending that a failure of the host
-- interrupted finds the hook started, and the primary failure, where they were left.
finishEnding ∷ InstanceHost → ICell → Int → IO ()
finishEnding ih cell closed = do
  settled ← isJust <$> readTVarIO (icResult cell)
  -- An ending parked for a provider's retirement has done everything but settle.
  parked ← Set.member (icId cell) <$> readIORef (ihParked ih)
  unless (settled || parked) $ do
    modifyIORef' (ihEndings ih) . Map.alter (Just . maybe (Ending EndStopped Nothing 0 0 closed ShutdownUndecided) (\held → held {endClosed = max (endClosed held) closed})) $ icId cell
    ending ← Map.findWithDefault (Ending EndStopped Nothing 0 0 closed ShutdownUndecided) (icId cell) <$> readIORef (ihEndings ih)
    state ← readTVarIO (icState cell)
    mode ← readIORef (ihMode ih)
    handles ← readIORef (ihHandles ih)
    created ← Set.member (icId cell) <$> readIORef (ihCreated ih)
    let safe = case mode of
          Unorderly _ → False
          _ → True
        handle = Map.lookup (icModule cell) handles
        slot = VInteger (fromIntegral (icId cell))
        reasonText = case endReason ending of
          EndStopped → "stopped"
          EndCompleted → "completed"
          EndFailed → "failed"
        record = recordShutdown ih cell
        -- Decided once, here, and recorded: a @shutdown@ that was started and raised a
        -- failure of the host is not started again when the owner's exit comes back to
        -- the instance, and is settled as the hook that raised.
        -- An M1 behavior's shutdown is the captured hook, run if the table had one when
        -- it was captured, whatever the table is now.
        decideBehavior behavior = do
          resolved ← readTVarIO (bcResolved behavior)
          case (resolved, ihBehaviorDriver ih) of
            (Just held, Just driver)
              | safe && not (shapeShutdown (resolvedShape held)) → record (ShutdownDecided ShutdownAbsent Nothing)
              | safe → do
                  record ShutdownBegun
                  mask $ \restore → do
                    ran ← restore (settledOrRaise (ihExtra ih) (withSegment ih (icId cell) (callEntryWith (LeadCaptured driver behaviorShutdown (resolvedCapture held) HookShutdown) (ownedHost (ihOwned ih)) driver behaviorShutdown [slot, VText reasonText])))
                    record $ case ran of
                      Left fault → ShutdownDecided ShutdownRaised (Just (ErrorFault fault))
                      Right _ → ShutdownDecided ShutdownRan Nothing
            _ → record (ShutdownDecided ShutdownSkippedUnsafe Nothing)
        decide
          | not (isInitialized state) = record (ShutdownDecided ShutdownSkippedNoInit Nothing)
          | Just behavior ← icBehavior cell = decideBehavior behavior
          | otherwise = case handle of
              Just module' | safe → do
                available ← hookAvailable ih module' "shutdown"
                if not available
                  then record (ShutdownDecided ShutdownAbsent Nothing)
                  else do
                    record ShutdownBegun
                    -- A cancellation lands inside the hook, and leaves it recorded as started,
                    -- or after what it answered is recorded: never between the two.
                    mask $ \restore → do
                      ran ← restore (settledOrRaise (ihExtra ih) (withSegment ih (icId cell) (callEntryVia (ownedHost (ihOwned ih)) (ihDriver ih) "shutdown" module' "shutdown" [slot, VText reasonText])))
                      record $ case ran of
                        Left fault → ShutdownDecided ShutdownRaised (Just (ErrorFault fault))
                        Right _ → ShutdownDecided ShutdownRan Nothing
              _ → record (ShutdownDecided ShutdownSkippedUnsafe Nothing)
    case endShutdown ending of
      ShutdownUndecided → decide
      _ → pure ()
    -- What the instance still holds is released now, whether its hook ran, was skipped
    -- or raised, on this thread and without entering Lua, so Lua being unsafe to enter
    -- does not keep a resource.
    drainInstance ih cell
    -- A drain that failed has ended the owner as a failure, and Lua is not entered again for
    -- the instances it leaves.
    safeStill ← (\held → case held of Unorderly _ → False; _ → True) <$> readIORef (ihMode ih)
    when (created && safe && safeStill && not (hookStarted (endShutdown ending))) $ do
      -- A release that fails is cleanup evidence, kept for the owner's end: nothing
      -- the application's escalation answers can hide it.
      released ← guarded (withRunning ih (icId cell) (callEntry (ihOwned ih) (ihDriver ih) "release" [slot]))
      case released of
        Right _ → pure ()
        Left failure@(ExceptionWithContext context raised)
          | isJust (fromException raised ∷ Maybe SomeAsyncException) → rethrowIO failure
          | raisedByApplication context → rethrowIO failure
          | otherwise → modifyIORef' (ihExtra ih) (<> [("lua instance release", failure)])
    parkOrSettle ih cell

-- | Settle an ending whose hook has run or been skipped and whose holdings are released,
-- unless a provider has yet to retire something it released: then the ending is parked,
-- and settles when every retirement it asked for has completed, not before, whatever Lua
-- did.
parkOrSettle ∷ InstanceHost → ICell → IO ()
parkOrSettle ih cell = do
  waiting ← atomically (pendingOf ih (icId cell))
  if waiting > 0
    then modifyIORef' (ihParked ih) (Set.insert (icId cell))
    else settleEnding ih cell

-- | What an instance's end still waits for: the retirements its leases await, and the work its
-- requests' providers have not proved over.
pendingOf ∷ InstanceHost → Word64 → STM Int
pendingOf ih number = do
  leased ← case ihLeases ih of
    Nothing → pure 0
    Just lh → pendingFor (lhLeases lh) number
  requested ← maybe (pure 0) (`pendingWorkFor` RequesterInstance number) (ihProvider ih)
  pure (leased + requested)

-- | Release what an instance still holds, newest first, whatever the instance's end
-- was and whatever its hook did. A release that fails does not stop another, is
-- cleanup evidence on the owner, is noted for the instance's settlement, and ends the
-- owner. The drain and the record of what it came to are one step a cancellation cannot
-- cut between: a failed slot is not drained again, so a failure that was not recorded
-- would be lost.
drainInstance ∷ InstanceHost → ICell → IO ()
drainInstance ih cell = mask_ $ do
  -- An M1 behavior's capture goes first: its hooks, self and facade are the instance's own.
  releaseCaptured ih cell
  -- Its requests end first, and the providers are told: they are asked to stop before what
  -- the instance's leases hold is released. The instance owns them, whichever invocation
  -- made them, and nothing else ends them but its end.
  told ← case ihProvider ih of
    Nothing → pure []
    Just service → endRequester service (RequesterInstance (icId cell)) CancelledByTaskInvalidation
  forM_ (ihLeases ih) $ \lh → mask_ $ do
    report ← drainScope lh (icId cell)
    forM_ (drainFailures report) $ \failure → do
      note ← renderCaught failure
      modifyIORef' (ihExtra ih) (<> [("lua instance lease", failure)])
      atomically (noteScope (lhLeases lh) (icId cell) note)
    unless (null (drainFailures report)) (endOwner ih)
  -- A provider that raised when told is a failure of the host: raised once everything has
  -- been released, with the others kept whole.
  raiseFirst (ihExtra ih) "lua request cancel" told

-- | Let go of what an M1 behavior instance captured: its hooks, @self@ and facade are
-- no longer held by the VM. Idempotent, and it runs no Lua, so Lua being unsafe to enter
-- does not keep a reference; a coroutine that is running or suspended on them keeps
-- them in Lua itself until it is closed. A release that fails is cleanup evidence on the
-- owner, as any release of an instance's is, and ends it.
releaseCaptured ∷ InstanceHost → ICell → IO ()
releaseCaptured ih cell = forM_ (icBehavior cell) $ \behavior → do
  resolved ← readTVarIO (bcResolved behavior)
  forM_ resolved $ \held → do
    released ← guarded (Owner.releaseBehavior (ihOwned ih) (resolvedCapture held))
    case released of
      Right () → pure ()
      Left failure@(ExceptionWithContext context raised)
        | isJust (fromException raised ∷ Maybe SomeAsyncException) → rethrowIO failure
        | raisedByApplication context → rethrowIO failure
        | otherwise → do
            modifyIORef' (ihExtra ih) (<> [("lua instance behavior release", failure)])
            endOwner ih

-- | A cleanup failure of the leases ends the owner at once, through supervision, with
-- the evidence it was recorded as: admission, grants and control close and the scheduler
-- is asked to stop, so that nothing is begun after it, at this boundary or any other, and
-- the owner exits as a failure. What is left to settle, and the retirements still pending,
-- are settled and awaited by its exit as they are for any exit.
endOwner ∷ InstanceHost → IO ()
endOwner ih = do
  writeIORef (ihFailed ih) True
  -- The owner exits as a failure from now on, whatever order it was in: the instances still
  -- to end have no hook run for them, and their holdings are drained all the same. An
  -- earlier failure or cancellation stays how it exits.
  recordExit ih (Just ExitFailed)
  atomically (writeTVar (controlClosing (ihControl ih)) True)

-- | Whether a cleanup failure of the leases ended the owner.
cleanupEndedOwner ∷ InstanceHost → IO Bool
cleanupEndedOwner = readIORef . ihFailed

-- | Take away the retirements the providers finished, and settle the endings that
-- were waiting for them. A retirement a provider reports failed is cleanup evidence
-- on the owner, fatal whatever the application's escalation answers, and is noted on
-- its instance. Answers whether anything ended.
serviceRetirementsOf ∷ InstanceHost → IO Bool
serviceRetirementsOf ih = do
  requested ← serviceRequestWork ih
  leased ← maybe (pure False) (serviceLeaseRetirements ih) (ihLeases ih)
  parked ← Set.toList <$> readIORef (ihParked ih)
  -- Every ending that is ready settles, whatever settling another raises (the application's
  -- escalation, a failure of the host): the first of the failures is raised once the
  -- others have been settled.
  settledEach ← forM parked $ \number → do
    pending ← atomically (pendingOf ih number)
    if pending > 0
      then pure (False, Nothing)
      else do
        modifyIORef' (ihParked ih) (Set.delete number)
        outcome ← guarded (withCell ih number (settleEnding ih))
        pure (True, either Just (const Nothing) outcome)
  -- None is dropped: the first is raised, and every other is cleanup evidence for the
  -- owner's end, whole, so that supervision receives each of them.
  case [failure | (_, Just failure) ← settledEach] of
    failure : others → do
      modifyIORef' (ihExtra ih) (<> [("lua instance settlement", other) | other ← others])
      rethrowIO failure
    [] → pure ()
  let settled = map fst settledEach
  pure (requested || leased || or settled)

-- | Poll the providers of the requests this owner's instances made, dispose of what their work
-- needed once it is over, and record a retirement that failed, or a disposal that raised, as
-- cleanup evidence that ends the owner. Answers whether any failed.
serviceRequestWork ∷ InstanceHost → IO Bool
serviceRequestWork ih = case ihProvider ih of
  Nothing → pure False
  Just service → mask_ $ do
    -- Servicing takes a failure out of the accounts and answers it once: recording it is the
    -- same masked step, so a cancellation cannot come between and lose it.
    failures ← serviceProvider service
    unless (null failures) $ do
      modifyIORef' (ihExtra ih) (<> failures)
      endOwner ih
    pure (not (null failures))

-- | Take away the retirements the providers of the leases finished, and dispose of what they
-- needed. Answers whether anything ended.
serviceLeaseRetirements ∷ InstanceHost → LeaseHost → IO Bool
serviceLeaseRetirements ih lh = do
  let leases = lhLeases lh
  mask_ $ do
    (ended, disposals) ← atomically (serviceRetirements leases)
    forM_ ended $ \finished → forM_ (endedFailure finished) $ \failure → do
      rendered ← renderCaught failure
      modifyIORef' (ihExtra ih) (<> [("lua lease retirement", failure)])
      forM_ (endedInstance finished) $ \number →
        atomically . noteScope leases number . failureText $
          "the provider's retirement of " <> endedLabel finished <> " failed: " <> rendered
      endOwner ih
    -- What the retirements needed is disposed of now that every one has completed, as a
    -- release is: uninterruptibly, one at a time, a failure of one not stopping the rest.
    forM_ disposals $ \Disposals {disposalsKey = key, disposalsInstance = number, disposalsActions = actions} → do
      failures ← forM actions $ \dispose →
        either Just (const Nothing) <$> guarded (uninterruptibleMask_ dispose)
      forM_ [failure | Just failure ← failures] $ \failure → do
        rendered ← renderCaught failure
        modifyIORef' (ihExtra ih) (<> [("lua lease dependency", failure)])
        atomically . noteScope leases number . failureText $ "disposing what a retirement needed failed: " <> rendered
        endOwner ih
      -- The lease keeps the first failure, which every later release of it answers.
      atomically (finishDisposals leases key (case [failure | Just failure ← failures] of first : _ → Just first; [] → Nothing))
    pure (not (null ended && null disposals))

-- | Record what became of an instance's @shutdown@ in its ending.
recordShutdown ∷ InstanceHost → ICell → ShutdownRecord → IO ()
recordShutdown ih cell record =
  modifyIORef' (ihEndings ih) (Map.adjust (\held → held {endShutdown = record}) (icId cell))

-- | Settle an instance from its ending, once, and tell the application if it failed.
--
-- This is the one place an ending is settled or reported, whether its hooks ran to
-- their ends or a failure of the host cut them short: what failed first, the traceback
-- with it, and what became of the hook are read from the ending's record, and nothing
-- that came after them (the owner's exit, a hook that raised a failure of the host)
-- replaces them. A failure the ending holds settles the instance as failed, whatever
-- the owner's exit was; an owner that exited without one discards it.
settleEnding ∷ InstanceHost → ICell → IO ()
settleEnding ih cell = do
  state ← readTVarIO (icState cell)
  mode ← readIORef (ihMode ih)
  created ← Set.member (icId cell) <$> readIORef (ihCreated ih)
  entered ← Set.member (icId cell) <$> readIORef (ihEntered ih)
  held ← Map.lookup (icId cell) <$> readIORef (ihEndings ih)
  scope ← case ihLeases ih of
    Nothing → pure Nothing
    Just lh → atomically (readScope (lhLeases lh) (icId cell))
  let ending = fromMaybe (Ending EndStopped Nothing 0 0 0 ShutdownUndecided) held
      -- A release or a retirement that failed is kept beside the primary failure, and
      -- is the failure when there is none: it fails the instance as a hook's does.
      releases = [(StageRelease, ErrorRelease note) | note ← maybe [] scopeNotes scope]
      leased = maybe noLeases (\held' → LeaseOutcome (scopeDrained held') (scopeAwaited held') (scopeFailed held')) scope
      (disposition, shutdownFailure) = recordedShutdown (isInitialized state) (endShutdown ending)
      -- An ending that never began has counted nothing: what the state still holds is
      -- what is discarded, counted as an ending counts it.
      counted = case held of
        Just _ → Termination (endConnections ending) (endUnstarted ending) (endClosed ending) disposition
        Nothing → Termination (Set.size (isConnections state)) (unstartedCount (icKind cell) state) 0 disposition
      cutShort = case endShutdown ending of
        ShutdownBegun → True
        _ → False
      exitKind = case mode of
        Unorderly kind → kind
        _ → ExitFailed
      reached = if isInitialized state || created || entered || hookStarted (endShutdown ending) then Started else NotStarted
      -- A required request's failure that was latched and not yet applied when the instance ended is
      -- never lost: it is the failure when nothing else is primary, and evidence beside the primary when
      -- something is.
      latched =
        [ (StageRequest endpoint, ErrorRequest endpoint why)
        | Just (endpoint, why) ← [isRequestFailure state]
        , not (appliedAsPrimary endpoint why)
        ]
      -- The failure the instance already ended with is the latched one, applied by the dispatch: it is
      -- not told again beside itself.
      appliedAsPrimary endpoint why = case endPrimary ending of
        Just (Primary _ _ (ErrorRequest appliedEndpoint appliedWhy)) → appliedEndpoint == endpoint && appliedWhy == why
        _ → False
      failure = case (endPrimary ending, shutdownFailure) of
        (Just (Primary phase stage err), secondary) → Just (describe phase stage err ([(StageShutdown, e) | Just e ← [secondary]] <> latched <> releases))
        (Nothing, secondary) | (stage, err) : rest ← latched → Just (describe (isPhase state) stage err ([(StageShutdown, e) | Just e ← [secondary]] <> rest <> releases))
        (Nothing, Just err) → Just (describe Stopping StageShutdown err releases)
        (Nothing, Nothing) → case releases of
          [] → Nothing
          (stage, err) : rest → Just (describe Stopping stage err rest)
      describe phase stage err secondary =
        InstanceFailure
          { failureInstance = InstanceId (controlOwner (ihControl ih)) (icId cell)
          , failureOwner = controlLabel (ihControl ih)
          , failureName = icName cell
          , failureSource = icModule cell
          , failurePhase = phase
          , failureStage = stage
          , failureError = err
          , failureMessage = renderError err
          , failureTraceback = case err of
              ErrorFault (BoundaryFailed fault) → boundaryTraceback fault
              _ → Nothing
          , failureSecondary = secondary
          }
      (terminal, outcome) = case (failure, mode) of
        (Just failed, _) → (Failed, InstanceFailed failed)
        (Nothing, Unorderly _) → (Stopped, InstanceDiscarded (Discard exitKind reached))
        (Nothing, _) | cutShort → (Stopped, InstanceDiscarded (Discard exitKind Started))
        (Nothing, _) → case endReason ending of
          EndCompleted → (Completed, InstanceCompleted)
          _ → (Stopped, InstanceStopped)
      settlement =
        InstanceSettlement
          { resultInstance = InstanceId (controlOwner (ihControl ih)) (icId cell)
          , resultOwner = controlLabel (ihControl ih)
          , resultName = icName cell
          , resultModule = icModule cell
          , resultPhase = terminal
          , resultOutcome = outcome
          , resultTermination = counted
          , resultLeases = leased
          }
  -- Settling, and the decision that the application is told, are one step a cancellation
  -- cannot cut between: an instance settled as failed is told of, once. The telling is
  -- application code and is interruptible.
  mask $ \restore → do
    -- The instance's end is also the end of its interest in what it asked of other
    -- instances: the receipts it held are abandoned in the step that settles it, so none
    -- is left that nothing can read, and none of what it asked is undone.
    won ← atomically $ do
      settled ← settleInstance (ihInstances ih) cell settlement
      overtakeLogical (ihInstances ih) (icId cell)
      traverse_ (`abandonIssued` icId cell) (controlLifecycle (ihControl ih))
      pure settled
    -- The instance has settled: its scope is dissolved, whatever the application's
    -- decision about its failure comes to.
    forM_ (ihLeases ih) $ \lh → atomically (dissolveScope (lhLeases lh) (icId cell))
    modifyIORef' (ihEndings ih) (Map.delete (icId cell))
    modifyIORef' (ihCreated ih) (Set.delete (icId cell))
    modifyIORef' (ihEntered ih) (Set.delete (icId cell))
    tell restore mode won failure
  where
    -- The ending is accounted for once the application has been told and has answered: not
    -- when the instance settles, which is readable before the telling, and not when the
    -- answer is to escalate or the telling raises, which end the owner and leave the ending
    -- owed.
    tell restore mode won failure = do
      case (won, failure) of
        (True, Just failed) → do
          decision ← restore (ihEscalate ih failed)
          case mode of
            Unorderly _ → pure ()
            _ → when (decision == Escalate) $ throwIO (InstanceEscalated failed)
        _ → pure ()
      when won (atomically (endingAccounted (ihControl ih) (icId cell)))

-- Exit ---------------------------------------------------------------------------------------

-- | The owner's exit: every instance not yet ended ends.
--
-- Called once the scheduler has stopped and has closed every coroutine it held,
-- each of which ended its instance through 'instanceClosed'. In order, an
-- instance still live is stopped through the ordinary path, with reason @stopped@;
-- after a failure or a cancellation no hook runs, and it settles as discarded, unless
-- it had failed already, which settles it as failed with that failure. A request the
-- owner never applied settles as no longer applicable.
retireInstances ∷ InstanceHost → IO ()
retireInstances ih = do
  jobs ← atomically (takeJobs (ihInstances ih))
  backlog ← readIORef (ihBacklog ih)
  writeIORef (ihBacklog ih) []
  forM_ (backlog <> toList jobs) $ \case
    JobControl _ _ receipt → atomically (settleReceipt receipt ControlNoLongerApplicable)
    _ → pure ()
  -- A request assigned to a tick the owner never reached, or one it had taken for a
  -- boundary and not begun, is overtaken by the owner's end like any other: it settles
  -- as no longer applicable, once, and is never applied at a boundary that does not
  -- come.
  held ← readIORef (ihDue ih)
  writeIORef (ihDue ih) []
  waiting ← atomically (takeAllLogical (ihInstances ih))
  forM_ (map snd held <> waiting) $ \control →
    atomically (settleReceipt (logicalReceipt control) ControlNoLongerApplicable)
  cells ← Map.elems <$> readTVarIO (insCells (ihInstances ih))
  -- Each instance ends on its own: what one raises (a host failure from its hook, or
  -- the application's escalation) is kept for the owner's outcome and does not leave
  -- another unended, and none is left unsettled whatever was raised.
  failures ← forM cells $ \cell → do
    ended ← guarded $ do
      settled ← isJust <$> readTVarIO (icResult cell)
      -- The way it ends, in order or as discarded, is the owner's exit mode, which
      -- 'finishEnding' reads.
      unless settled (beginEnding' ih cell EndStopped Nothing >> finishEnding ih cell 0)
    case ended of
      Left failure@(ExceptionWithContext _ raised) → do
        -- What an instance's end raised is a failure of the host, or a cancellation:
        -- the owner is failing, and no hook runs for the instances after it.
        recordExit ih (Just (if isJust (fromException raised ∷ Maybe SomeAsyncException) then ExitCancelled else ExitFailed))
        -- Settled from what its ending recorded, which the failure of the host did not
        -- replace; what telling the application raises is kept beside it.
        again ← guarded (discardUnsettled ih cell)
        pure (failure : [telling | Left telling ← [again]])
      Right () → pure []
  -- An instance whose provider has not finished retiring what it released is parked,
  -- and the owner stays live until it has, through a stop and through a cancellation:
  -- what the provider needs is kept until it says it is safe.
  awaited ← awaitRetirements ih
  -- The first failure is the one raised; every other is cleanup evidence, whole, so
  -- supervision receives each of them and none is chosen over the rest.
  case concat failures <> awaited of
    failure : others → do
      modifyIORef' (ihExtra ih) (<> [("lua instance end", other) | other ← others])
      rethrowIO failure
    [] → pure ()

-- | Wait, uninterruptibly, until every retirement a provider was asked for is complete
-- and every ending that waited for one has settled. Answers what settling raised: a
-- failure of the host, or the application's escalation, each of which leaves the
-- others to settle.
awaitRetirements ∷ InstanceHost → IO [ExceptionWithContext SomeException]
awaitRetirements ih = case (ihLeases ih, ihProvider ih) of
  (Nothing, Nothing) → pure []
  _ → uninterruptibleMask_ (loop [])
  where
    loop raised = do
      served ← guarded (serviceRetirementsOf ih)
      let raised' = raised <> [failure | Left failure ← [served]]
      parked ← Set.toList <$> readIORef (ihParked ih)
      -- An ending whose retirements have all been taken is ready to settle whether or not
      -- anything is left to wait for: the settling that raised, for the application's
      -- escalation or a failure of the host, left the others as they were, and nothing
      -- else will wake the owner for them.
      ready ← or <$> traverse (\number → (== 0) <$> atomically (pendingOf ih number)) parked
      outstanding ← atomically $ do
        leased ← maybe (pure False) (anyPending . lhLeases) (ihLeases ih)
        requested ← maybe (pure False) anyInstanceWorkPending (ihProvider ih)
        pure (leased || requested)
      if ready
        then loop raised'
        else
          if null parked && not outstanding
            then pure raised'
            else do
              atomically $
                maybe retry (retirementsReady . lhLeases) (ihLeases ih)
                  `orElse` maybe retry (\service → workWaiting service >>= \found → unless found retry) (ihProvider ih)
              loop raised'

-- | Settle an instance that is still unsettled, because its end could not be carried
-- through: from what its ending recorded, as any other ending is. What it still holds is
-- released first, and an ending whose provider has yet to retire something is parked like
-- any other: a failure of the host in its hook is no reason to leave a resource live under
-- the collection's own close, where nothing would wait for its provider.
discardUnsettled ∷ InstanceHost → ICell → IO ()
discardUnsettled ih cell = do
  drainInstance ih cell
  parkOrSettle ih cell
