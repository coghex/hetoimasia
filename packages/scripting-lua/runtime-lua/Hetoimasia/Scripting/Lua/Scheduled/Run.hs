-- | The owner's side of a scheduled owner: the thread that runs the VM drives the
-- scheduler, runs each task's segments as coroutines, and settles every task
-- exactly once.
--
-- 'runScheduledOwner' is the worker's run action. It runs 'withVmOwnerScoped' on
-- the worker's own thread, so that thread is the VM's execution owner, constructs
-- and initializes the VM inside it, and serves from inside its body.
--
-- = The body
--
-- It resolves the modules the configuration loaded, publishes readiness in one
-- transaction, and only then serves. Serving waits in one place, for whatever
-- the scheduler has to do or the stop request, then runs one scheduler turn, and
-- hands the turn's close failures to the owner's own evidence. A task's segments
-- run through 'startTask' and 'resumeTask'; nothing here chooses an order,
-- measures a deadline or keeps a queue, which is the scheduler's.
--
-- = What a failure of a task is
--
-- A refused value, a script error, a call to a binding that is not yet supported,
-- an entry point that is gone and a module the owner did not load are faults of
-- the task: the task fails as data and the owner serves the others. A failure
-- raised by application code is not, whatever its type: the bridge marks every
-- failure that escapes application code and this module reads the mark, not the
-- type. A marked failure is a failure of the host and ends the owner, unconverted.
--
-- = The collection
--
-- An owner the application gave a 'Lending' handle holds a resource collection
-- owned by a capability, on the owner's thread, around the VM's lifetime:
-- allocated before the VM is constructed and closed after the VM has closed.
-- An owner with no handle holds none and runs as it always did. Each callback of
-- the VM is lent it for its
-- duration ("Hetoimasia.Scripting.Lua.Lending"), so the callbacks of the initial
-- chunks, of a coroutine's closing handlers and of a finalizer-eligible binding
-- while the VM closes all find it open. Its exit releases what remains, newest
-- first, and a release that fails is cleanup evidence on the owner's outcome,
-- beside the VM's own, fatal under any policy.
--
-- = Every exit
--
-- Whatever ends the body, a stop request, a failure of application code or a
-- cancellation, admission and control close first, every ticket not yet settled
-- settles (a finished task keeps its result, any other is discarded with how the
-- owner exited and whether it had begun), and then the scheduler's stop closes
-- every suspended coroutine on this thread, attempting each one whatever another
-- does. Their failures, and any the turns had already kept, are cleanup evidence
-- on the owner's outcome, beside the primary failure if there is one, and are
-- fatal under any policy. All of that happens before 'withVmOwnerScoped' closes
-- the VM, and the collection's own exit follows the VM's.
module Hetoimasia.Scripting.Lua.Scheduled.Run
  ( runScheduledOwner
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', orElse, retry, writeTVar)
import Control.Applicative ((<|>))
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , finally
  , fromException
  , mask
  , mask_
  , rethrowIO
  , someExceptionContext
  , throwIO
  , try
  , tryWithContext
  )
import Control.Monad (forM, forM_, unless, void, when)
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (composeCleanup, withScoped)
import Hetoimasia.Foundation.Resource.OwnedCollection (allocOwnedCollection)
import Hetoimasia.Scripting.Lua.Internal.Boundary (moduleChunk)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedInternalVm)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (ReasonCode (ScriptFault, ValidationFault), RecoverySafety (RecoverySafe), failureReason)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure (TaskFailure))
import Hetoimasia.Scripting.Lua.Internal.Vm (vmIdentity)
import Hetoimasia.Scripting.Lua.Lease.State (LeaseHost (LeaseHost), Leases)
import Hetoimasia.Scripting.Lua.Lending.Loan (Lending, lendingScope)
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (..)
  , CallResult (EntryAbsent, Returned)
  , FaultOperation (StartTask)
  , FaultReason (ValueRefused)
  , ModuleHandle
  , ModuleRef
  , ModuleSource (sourceIdentity)
  , OwnedVm
  , Task
  , TaskStart (TaskEntryAbsent, TaskStarted)
  , TaskStep (Completed, Waiting, Yielded)
  , VmConfig (vmModules, vmOwnerName)
  , loadedModule
  , resumeTask
  , startTask
  , noCallbackScope
  , withVmOwnerScoped
  )
import qualified Hetoimasia.Scripting.Lua.Owner as Owner
import Hetoimasia.Scripting.Lua.Runtime.Types
  ( CallFault (BoundaryFailed, ModuleNotLoaded)
  , ExitKind (ExitCancelled, ExitFailed, ExitStopped)
  , Payload (OverBound, WithinBounds)
  )
import Hetoimasia.Scripting.Lua.Instance.Behavior (behaviorDriverRef)
import Hetoimasia.Scripting.Lua.Instance.Driver (driverRef)
import Hetoimasia.Scripting.Lua.Instance.Run
  ( ExitMode (Unorderly)
  , InstanceHost (ihMode)
  , awaitInstanceWork
  , cleanupEndedOwner
  , definedHooks
  , endOwner
  , instanceClosed
  , instanceSegment
  , newInstanceHost
  , retireInstances
  , recordExit
  , runningTask
  , serviceBoundary
  , serviceInstances
  , settleEnded
  )
import Hetoimasia.Scripting.Lua.Instance.Types (Escalation, InstanceFailure)
import Hetoimasia.Scripting.Lua.Loading.State (closeLoading, loadingWork, retireLoading, serviceLoading)
import Hetoimasia.Scripting.Lua.Provider.Serve (providerBoundary, providerWork, retireProvider)
import Hetoimasia.Scripting.Lua.Provider.State (markClosing, unmarkClosing)
import Hetoimasia.Scripting.Lua.Provider.Types (ProviderState (psTask), Requester (RequesterTask))
import Hetoimasia.Scripting.Lua.Scheduled.Shared (closeSuspended, exitOf, settledOrRaise, waitReportFor)
import Hetoimasia.Scripting.Lua.Lifecycle.State (LifecycleState (lifeTask))
import Hetoimasia.Scripting.Lua.Scheduled.Types
import Hetoimasia.Scripting.Lua.Scheduler
  ( SegmentReport (..)
  , StopReport (stopCloseFailures, stopTimerFailure)
  , TaskHost (..)
  , TaskRun (..)
  , TurnReport (turnCloseFailures, turnRefusedWaits)
  , WaitRefusal
  , awaitWork
  , retainsEvidence
  , serviceTurnWith
  , stopScheduler
  )
import Hetoimasia.Scripting.Lua.Value (Side (Arguments), ValueRefusal (ValueRefusal), VmIdentity)

-- | The worker's run action for one scheduled owner.
--
-- The handoff is where readiness is published: the control, once the VM is
-- initialized and the modules loaded, and nothing before. The stop condition is
-- the one the scheduler was configured with, so admission, grants and control
-- close at the same instant the owner is asked to stop. The collection holds at
-- most @members@ live members.
runScheduledOwner
  ∷ STM Bool
  → Control
  → TVar (Maybe Control)
  → (SegmentContext → IO ())
  → (WaitRefusal → IO ())
  → Maybe (InstanceFailure → IO Escalation)
  → Maybe Lending
  → Maybe Leases
  → Int
  → VmConfig
  → IO ()
runScheduledOwner stopping control handoff observe refused escalate lending leases members config = mask $ \restore → do
  let body = serve stopping control handoff observe refused escalate config
  outcome ←
    tryWithContext @SomeException . restore $ case lending of
      Nothing → withVmOwnerScoped noCallbackScope config (body Nothing)
      -- The collection is allocated first and so released last: after the VM's
      -- close, which is the last thing 'withVmOwnerScoped' does.
      Just handle →
        withScoped (allocOwnedCollection members) $ \(collection, capability) →
          withVmOwnerScoped (lendingScope handle collection capability) config
            -- The owner's thread holds the capability, and with the leases it drains an
            -- instance's holdings through it when the instance ends.
            (body (LeaseHost <$> leases <*> pure collection <*> pure capability))
  -- An exit before the body, or a failure of the close itself: nothing of the
  -- tasks is left to settle then, and this records how the owner ended.
  atomically (settleAll control (either exitOf (const ExitStopped) outcome))
  either rethrowIO pure outcome

-- | The body of the owner's lifetime.
serve ∷ STM Bool → Control → TVar (Maybe Control) → (SegmentContext → IO ()) → (WaitRefusal → IO ()) → Maybe (InstanceFailure → IO Escalation) → VmConfig → Maybe LeaseHost → OwnedVm → IO ()
serve stopping control handoff observe refused escalate config leaseHost owned = mask $ \restore → do
  tasks ← newIORef Map.empty
  handlesRef ← newIORef Map.empty
  instanceRef ← newIORef Nothing
  -- What closing coroutines raised, by task, and every other cleanup failure
  -- (a script's own failure that was raised with the failures of closing its
  -- coroutine). Either is fatal evidence, so the first of them ends the owner:
  -- nothing here accumulates for as long as the owner serves.
  kept ← newIORef []
  extra ← newIORef []
  let host =
        TaskHost
          { hostRun = runSegment control observe owned identity label handlesRef tasks extra instanceRef
          , -- The coroutine is closed first. The instance whose invocation it was is
            -- ended after that, whatever the close did: it is told only when the
            -- close was not interrupted, which an exit settles as discarded.
            hostClose = \task → do
              began ← Map.member task <$> readIORef tasks
              instances ← readIORef instanceRef
              closed ← try @SomeException (closeAs control instances task (closeSuspended owned tasks kept task))
              let interrupted = case closed of
                    Left failure | Just (_ ∷ SomeAsyncException) ← fromException failure → True
                    _ → False
              -- The instance is only told its coroutine is closed. Ending it runs a hook,
              -- which is application code, and a failure of that raised here would be
              -- taken by the scheduler for the close's own: it ends the instance later,
              -- from the owner's own code. A close that was interrupted is a cancellation:
              -- no hook runs for any instance after it, and what the close had done is
              -- still counted.
              forM_ instances $ \ih → do
                when interrupted (recordExit ih (Just ExitCancelled))
                instanceClosed ih task began
              either throwIO pure closed
          }
  served ← tryWithContext @SomeException . restore $ do
    handles ← Map.fromList . catMaybes <$> traverse (resolve owned) (map sourceIdentity (vmModules config))
    writeIORef handlesRef handles
    forM_ ((,) <$> controlInstances control <*> escalate) $ \(instances, decide) →
      forM_ (Map.lookup driverRef handles) $ \driver →
        newInstanceHost control instances decide host owned driver (Map.lookup behaviorDriverRef handles) handlesRef tasks extra leaseHost (controlProvider control) >>= writeIORef instanceRef . Just
    -- What each module defines is read now, from the modules as loaded, running none of their
    -- code, and published with readiness: the owner's query answers from it and it never changes.
    defined ← forM (Map.toList (Map.delete behaviorDriverRef (Map.delete driverRef handles))) $ \(ref, handle) → (,) ref <$> definedHooks owned handle
    atomically $ do
      writeTVar (controlHooks control) (Map.fromList defined)
      writeTVar handoff (Just control)
    loop host kept extra instanceRef
  -- The owner is exiting, however it was asked to or made to. Admission, grants
  -- and control close, every unsettled ticket settles, and only then are the
  -- suspended coroutines closed, masked from here on.
  -- Closing admission is a transaction of its own, first and small, so that a
  -- crowd of producers cannot starve the large one that settles the tickets: once
  -- it commits nothing is admitted, and the settlement runs against a state that
  -- no producer is changing.
  atomically (writeTVar (controlClosing control) True >> forM_ (controlLoading control) closeLoading)
  -- Whether Lua may be entered for an instance again: only after an orderly stop.
  heldInstances ← readIORef instanceRef
  let heldInstances0 = heldInstances
  -- A cleanup failure of the instances' leases ended the owner at once: it exits as a
  -- failure, as any cleanup failure ends it, even though what stopped its loop was the
  -- closing the failure itself asked for.
  leaseFailed ← maybe (pure False) cleanupEndedOwner heldInstances0
  let cause = case served of
        Left failure → Just (exitOf failure)
        Right True → Just ExitFailed
        Right False | leaseFailed → Just ExitFailed
        Right False → Nothing
  forM_ heldInstances (`recordExit` cause)
  -- The owner's exit record says how it exited, and it is what the instances left are
  -- discarded as: both read the first way recorded, never one apart from the other.
  firstExit ← traverse (readIORef . ihMode) heldInstances
  atomically . settleAll control $ case firstExit of
    Just (Unorderly kind) → kind
    _ → fromMaybe ExitStopped cause
  stopped ← tryWithContext @SomeException (stopScheduler scheduler host)
  -- A stop that was interrupted is a cancellation however the owner came to exit: the
  -- hooks of the instances that are left do not run.
  forM_ heldInstances $ \ih → case stopped of
    Left (ExceptionWithContext _ raised) | Just (_ ∷ SomeAsyncException) ← fromException raised → recordExit ih (Just ExitCancelled)
    _ → pure ()
  -- A stop that raised, because a close was interrupted or the timer's
  -- cancellation threw, completed first: asking again answers what it recorded.
  stoppedAgain ← case stopped of
    Right done → pure (Right done)
    Left _ → tryWithContext @SomeException (stopScheduler scheduler host)
  let report = either (const Nothing) Just stoppedAgain
      -- What asking again raised is kept too: the first ask's failure is evidence, and so is
      -- this one's, unless it is that same failure.
      askedAgain = [("lua scheduler stop retry", failure) | Left failure@(ExceptionWithContext _ raised) ← [stoppedAgain], Left (ExceptionWithContext _ first) ← [stopped], show raised /= show first]
  -- A coroutine the scheduler did not close, because its task was inside a
  -- segment when the owner ended (the application's observer raised before it
  -- resumed, say), is closed here, before the VM is, where closing it can run the
  -- cleanup a script asked for.
  held ← Map.keys <$> readIORef tasks
  swept ← forM held $ \held' → do
    closed ← try @SomeException (closeAs control heldInstances held' (closeSuspended owned tasks kept held'))
    -- Counted for its instance, which the exit then ends; an interruption of the close
    -- is a cancellation, as it is in the scheduler's stop.
    forM_ heldInstances $ \ih → do
      when (either (isJust . (fromException ∷ SomeException → Maybe SomeAsyncException)) (const False) closed) $
        recordExit ih (Just ExitCancelled)
      instanceClosed ih held' True
    pure (either (\failure → [(held', failure)]) (const []) closed)
  -- What instances are still live ends now, with every coroutine closed and before
  -- the VM is: in order, through the ordinary path, or as discarded.
  retired ← case heldInstances of
    Nothing → pure (Right ())
    Just ih → tryWithContext @SomeException (retireInstances ih)
  -- The owner's requests end with it: every one still held is revoked, the providers are told,
  -- and the owner waits, uninterruptibly, for each to prove its work over before the VM, and
  -- what its work needed, are let go.
  providerEnd ← forM (controlProvider control) $ \service → tryWithContext @SomeException (retireProvider service)
  let (providerTold, providerCleanup) = case providerEnd of
        Just (Right ended) → ended
        Just (Left failure) → ([failure], [])
        Nothing → ([], [])
  -- The owner's module loader ends with it, on this thread and before the VM: its suspended
  -- frames are closed, its source interests withdrawn, and the tick a due chain held is given
  -- back. A failure of that is cleanup evidence, whatever else happened.
  loadingEnd ← forM (controlLoading control) $ \state → retireLoading state owned
  let loadingEvidence = [("lua loader stop", failure) | Just (Left failure) ← [loadingEnd]]
  earlier ← readIORef kept
  others ← readIORef extra
  let closeFailures =
        Map.toList . Map.fromListWith (\_ first → first) $
          earlier <> maybe [] stopCloseFailures report <> concat swept
      -- What the stop itself raised, unless a close's failure already says it.
      timerFailure = report >>= stopTimerFailure
      recorded = map (show . snd) closeFailures <> [show failure | Just failure ← [timerFailure]]
      -- What cancelling the timer raised: the stop went on, and the report keeps it
      -- even when a close's interruption is what the stop raised.
      timerEvidence = askedAgain <> [("lua timer cancel", ExceptionWithContext (someExceptionContext failure) failure) | Just failure ← [timerFailure]]
      interruption =
        [ ("lua scheduler stop", failure)
        | Left failure@(ExceptionWithContext _ raised) ← [stopped]
        , show raised `notElem` recorded
        ]
      earlierPrimary = either Just (const Nothing) served <|> either Just (const Nothing) retired
      -- A provider that raised when told is a failure of the host: the first is the owner's
      -- if nothing failed before it, and every other is kept whole as evidence.
      (primary, providerEvidence) = case (earlierPrimary, providerTold) of
        (Nothing, first : rest) → (Just first, [("lua request cancel", other) | other ← rest])
        (_, told) → (earlierPrimary, [("lua request cancel", other) | other ← told])
      -- What retiring the instances raised, when the owner had failed already: the owner's
      -- failure is the primary, and this is evidence beside it, not lost.
      retirement = [("lua instance retirement", failure) | Left failure ← [retired], isLeft served]
  composed ←
    composeCleanup
      primary
      ( interruption
          <> timerEvidence
          <> others
          <> providerEvidence
          <> providerCleanup
          <> loadingEvidence
          <> retirement
          <> [("lua task close", ExceptionWithContext (someExceptionContext failure) failure) | (_, failure) ← closeFailures]
      )
  maybe (pure ()) rethrowIO composed
  where
    identity = vmIdentity (ownedInternalVm owned)
    label = vmOwnerName config
    scheduler = controlScheduler control
    provider = controlProvider control
    -- What an owner with a request service waits for beside its scheduler's work: a task whose
    -- request has settled, a provider's account that is no longer pending, disposals to run.
    requestWork = maybe retry providerWork provider
    -- What the owner's module loader has been left: a submitted root or an arrived source.
    loaderWork = maybe retry loadingWork (controlLoading control)
    -- Serve until a stop is requested, or until a turn reports a failure of
    -- cleanup: answers whether it was the latter.
    loop host kept extra instanceRef = do
      instances ← readIORef instanceRef
      -- Beside its other work the owner wakes for an accounting wait whose cut is fixed and which
      -- no acknowledgement has answered yet: an idle owner has no boundary to end until it is woken.
      atomically $ case instances of
        Nothing → awaitWork scheduler `orElse` requestWork `orElse` loaderWork `orElse` awaitAcknowledgement control
        Just ih → awaitWork scheduler `orElse` awaitInstanceWork ih `orElse` requestWork `orElse` loaderWork `orElse` awaitAcknowledgement control
      forM_ instances serviceInstances
      -- At each boundary, after the scheduler's work there, the owner accounts for
      -- what ended, looks at what its instances were asked and tries again what the
      -- scheduler had no room for, unless it was asked to stop itself, in which case
      -- its exit settles it. Its requests are looked at after that: the tasks whose
      -- requests have settled are woken, the providers' accounts are polled, and the
      -- requesters whose tasks are gone are ended.
      let atBoundary = do
            instanceStep ← maybe (pure False) serviceBoundary instances
            requestStep ← forM provider $ \service →
              providerBoundary service scheduler (isJust instances) leaseHost extra (forM_ instances endOwner)
            -- The module loader is looked at last at a boundary: what a hook or a settled request
            -- did there is part of what it is asked, and a chain it advances is not a task.
            loadStep ← forM (controlLoading control) $ \state → serviceLoading state owned
            let again = instanceStep || or requestStep || or loadStep
            -- A boundary that finds nothing more to do is the last of its settling: it ends when this
            -- returns. This is the owner's checkpoint, and nothing after it in the boundary can fail. The
            -- sweep of what the providers and the leases had to hand over is the step just made, which
            -- found none; the failures the owner caught were kept by the steps that caught them, or
            -- raised past this point. If it holds none of them, is not stopping, and the boundary finished
            -- the grants a wait captured, it fixes that wait's cut; and then it acknowledges: whatever
            -- wait is pending is answered by an acknowledgement written here, after its cut was fixed, and
            -- by nothing else.
            unless again $ do
              held ← holdsFailure kept extra
              atomically (sealAccounting control >> unless held (acknowledgeAccounting control))
            pure again
      report ← serviceTurnWith atBoundary scheduler host
      forM_ instances settleEnded
      mask_ $ do
        modifyIORef' kept (<> turnCloseFailures report)
        void (atomically (sweepForgotten control))
      -- The application is told of each wait the turn refused, after the refused task and its instance
      -- were accounted for and the turn's cleanup evidence was kept: what it raises is a failure of the
      -- host, which ends the owner as any other does.
      forM_ (turnRefusedWaits report) (refused . snd)
      halt ← atomically stopping
      retained ← (||) <$> (not . null <$> readIORef kept) <*> (not . null <$> readIORef extra)
      if halt || retained
        then pure (retained && not halt)
        else loop host kept extra instanceRef

    -- Whether the owner holds a failure that will end it, or is ending: what the scheduler kept, what the
    -- owner kept, or a stop. An acknowledgement is not written while it does.
    holdsFailure kept extra = do
      scheduled ← atomically ((||) <$> retainsEvidence scheduler <*> stopping)
      kept' ← not . null <$> readIORef kept
      extra' ← not . null <$> readIORef extra
      pure (scheduled || kept' || extra')

-- | Close a task's coroutine as the task, and as its instance if it is an invocation of one.
closeAs ∷ Control → Maybe InstanceHost → TaskId → IO a → IO a
closeAs control instances task action = closing (withTaskNoted control task (maybe action (\ih → runningTask ih task action) instances))
  where
    -- The closing handlers run after the stop began: the task is not taking requests while
    -- they do, as an instance that is stopping is not. Every close of a coroutine is this one.
    closing run = case controlProvider control of
      Nothing → run
      Just service → (atomically (markClosing service task) >> run) `finally` atomically (unmarkClosing service task)

-- | The handle of a module the configuration loaded.
resolve ∷ OwnedVm → ModuleRef → IO (Maybe (ModuleRef, ModuleHandle))
resolve owned ref = fmap ((,) ref) <$> loadedModule owned ref

-- | Run this noting, for the owner's lifecycle services, which task is running, which they tell
-- who a call is from by: set by the owner's own thread, and cleared however it ends. A segment
-- is run so, and so is the closing of a coroutine, which runs the script's own closing handlers.
withTaskNoted ∷ Control → TaskId → IO a → IO a
withTaskNoted control task action
  | Nothing ← controlLifecycle control, Nothing ← controlProvider control = action
  | otherwise = do
      let note value = do
            forM_ (controlLifecycle control) $ \lifecycle → writeTVar (lifeTask lifecycle) value
            forM_ (controlProvider control) $ \service → writeTVar (psTask service) value
      atomically (note (Just task))
      action `finally` atomically (note Nothing)

-- | Run one segment of a task: start it, or resume it, and say how it ended.
--
-- The application is told what the task is about to be handed first. A fault of
-- the task is recorded and fails it; anything else that escapes is a failure of
-- the host and propagates.
runSegment
  ∷ Control
  → (SegmentContext → IO ())
  → OwnedVm
  → VmIdentity
  → Text
  → IORef (Map ModuleRef ModuleHandle)
  → IORef (Map TaskId Task)
  → IORef [(Text, ExceptionWithContext SomeException)]
  → IORef (Maybe InstanceHost)
  → TaskRun Cursor
  → IO (SegmentReport Cursor)
runSegment control observe owned identity label handlesRef tasks extra instanceRef run = withTaskNoted control (runTask run) $ do
  observe
    SegmentContext
      { contextTask = ScheduledTaskId (controlOwner control) (runTask run)
      , contextName = runName run
      , contextClass = runClass run
      , contextKind = runKind run
      , contextSegment = runSegmentNumber run
      , contextResume = runResume run
      }
  case runCursor run of
    PendingInvocation number invocation → hosted number (Just invocation)
    HostedInvocation number → hosted number Nothing
    Pending ref entry payload → do
      started
      handles ← readIORef handlesRef
      case (Map.lookup ref handles, payload) of
        (Nothing, _) → failed (ModuleNotLoaded ref)
        (Just _, OverBound rule) → failed (BoundaryFailed (refusedArguments ref entry rule))
        (Just handle, WithinBounds arguments) →
          -- The coroutine is acquired and published together: a cancellation that
          -- was queued during the segment lands after both, so the task's
          -- coroutine is always somewhere the owner's retirement finds it.
          mask_ $ settledOrRaise extra (startTask owned handle entry arguments) >>= \case
            Left fault → failed fault
            Right TaskEntryAbsent → pure (ReportCompleted (Finished EntryAbsent))
            Right (TaskStarted task step) → do
              modifyIORef' tasks (Map.insert (runTask run) task)
              reported step
    Suspended → do
      started
      held ← Map.lookup (runTask run) <$> readIORef tasks
      case held of
        -- Nothing but a corrupted state leaves a suspended task without its
        -- coroutine; the task fails with a typed failure rather than the owner.
        Nothing →
          pure . ReportFailed $
            TaskFailure (failureReason ValidationFault "the task's continuation is not held by its owner") RecoverySafe
        Just task →
          -- Masked through the outcome's record, as the first segment is: a
          -- cancellation queued while Lua ran lands after the task's result, or
          -- the failures of closing its ended coroutine, are kept.
          mask_ $ settledOrRaise extra (resumeTask owned task) >>= \case
            Left fault → modifyIORef' tasks (Map.delete (runTask run)) >> failed fault
            Right step → reported step
    Finished result → started >> pure (ReportCompleted (Finished result))
  where
    started = atomically (modifyTVar' (controlStarted control) (Set.insert (runTask run)))
    -- An invocation of a script instance: the instance layer runs it.
    hosted number invocation =
      readIORef instanceRef >>= \case
        Just ih → instanceSegment ih run number invocation
        Nothing → pure (ReportCompleted (Finished (Returned [])))
    failed fault = do
      atomically (modifyTVar' (controlFaults control) (Map.insert (runTask run) fault))
      pure (ReportFailed (TaskFailure (failureReason ScriptFault (Text.pack (show fault))) RecoverySafe))
    reported = \case
      Completed values → do
        modifyIORef' tasks (Map.delete (runTask run))
        pure (ReportCompleted (Finished (Returned values)))
      Yielded → pure (ReportYielded Suspended)
      Waiting request → waitReportFor (controlProvider control) (RequesterTask (runTask run)) Suspended request
    refusedArguments ref entry rule =
      BoundaryFault
        { boundaryOwner = label
        , boundaryVm = identity
        , boundaryOperation = StartTask
        , boundaryModule = Just ref
        , boundaryEntry = Just entry
        , boundaryBinding = Nothing
        , boundaryChunk = moduleChunk ref
        , boundaryReason = ValueRefused (ValueRefusal Arguments 0 [] rule 0)
        , boundaryEffect = Owner.NoEffect
        , boundaryTraceback = Nothing
        }
