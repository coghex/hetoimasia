-- | The owner's side of a scheduled owner: the thread that runs the VM drives the
-- scheduler, runs each task's segments as coroutines, and settles every task
-- exactly once.
--
-- 'runScheduledOwner' is the worker's run action. It runs 'withVmOwner' on the
-- worker's own thread, so that thread is the VM's execution owner, constructs and
-- initializes the VM inside it, and serves from inside its body.
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
-- = Every exit
--
-- Whatever ends the body, a stop request, a failure of application code or a
-- cancellation, admission and control close first, every ticket not yet settled
-- settles (a finished task keeps its result, any other is discarded with how the
-- owner exited and whether it had begun), and then the scheduler's stop closes
-- every suspended coroutine on this thread, attempting each one whatever another
-- does. Their failures, and any the turns had already kept, are cleanup evidence
-- on the owner's outcome, beside the primary failure if there is one, and are
-- fatal under any policy. All of that happens before 'withVmOwner' closes the VM.
module Hetoimasia.Scripting.Lua.Scheduled.Run
  ( runScheduledOwner
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', writeTVar)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , someExceptionContext
  , tryWithContext
  )
import Control.Monad (unless)
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds, zeroDuration)
import Hetoimasia.Scripting.Lua.Internal.Boundary (moduleChunk)
import Hetoimasia.Scripting.Lua.Internal.Fault (raisedByApplication)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedInternalVm)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (ReasonCode (ScriptFault, ValidationFault), RecoverySafety (RecoverySafe), failureReason)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure (TaskFailure))
import Hetoimasia.Scripting.Lua.Internal.Vm (vmIdentity)
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
  , WaitRequest (waitArguments, waitKind)
  , closeTask
  , loadedModule
  , resumeTask
  , startTask
  , withVmOwner
  )
import qualified Hetoimasia.Scripting.Lua.Owner as Owner
import Hetoimasia.Scripting.Lua.Registration (WaitKind (WaitElapsed, WaitLogical))
import Hetoimasia.Scripting.Lua.Runtime.Types
  ( CallFault (BoundaryFailed, LuaFailed, ModuleNotLoaded)
  , ExitKind (ExitCancelled, ExitFailed, ExitStopped)
  , Payload (OverBound, WithinBounds)
  )
import Hetoimasia.Scripting.Lua.Scheduled.Types
import Hetoimasia.Scripting.Lua.Scheduler
  ( SegmentReport (..)
  , StopReport (stopCloseFailures)
  , TaskHost (..)
  , TaskRun (..)
  , TurnReport (turnCloseFailures)
  , awaitWork
  , serviceTurn
  , stopScheduler
  )
import Hetoimasia.Scripting.Lua.Value (Side (Arguments), Value (VInteger), ValueRefusal (ValueRefusal), VmIdentity)

-- | The worker's run action for one scheduled owner.
--
-- The handoff is where readiness is published: the control, once the VM is
-- initialized and the modules loaded, and nothing before. The stop condition is
-- the one the scheduler was configured with, so admission, grants and control
-- close at the same instant the owner is asked to stop.
runScheduledOwner
  ∷ STM Bool
  → Control
  → TVar (Maybe Control)
  → (SegmentContext → IO ())
  → VmConfig
  → IO ()
runScheduledOwner stopping control handoff observe config = mask $ \restore → do
  outcome ← tryWithContext @SomeException (restore (withVmOwner config (serve stopping control handoff observe config)))
  -- An exit before the body, or a failure of the close itself: nothing of the
  -- tasks is left to settle then, and this records how the owner ended.
  atomically (settleAll control (either exitOf (const ExitStopped) outcome))
  either rethrowIO pure outcome

-- | The body of the owner's lifetime.
serve ∷ STM Bool → Control → TVar (Maybe Control) → (SegmentContext → IO ()) → VmConfig → OwnedVm → IO ()
serve stopping control handoff observe config owned = mask $ \restore → do
  tasks ← newIORef Map.empty
  handlesRef ← newIORef Map.empty
  kept ← newIORef []
  let host =
        TaskHost
          { hostRun = runSegment control observe owned identity label handlesRef tasks
          , hostClose = closeSuspended owned tasks
          }
  served ← tryWithContext @SomeException . restore $ do
    handles ← Map.fromList . catMaybes <$> traverse (resolve owned) (map sourceIdentity (vmModules config))
    writeIORef handlesRef handles
    atomically (writeTVar handoff (Just control))
    loop host kept
  -- The owner is exiting, however it was asked to or made to. Admission, grants
  -- and control close, every unsettled ticket settles, and only then are the
  -- suspended coroutines closed, masked from here on.
  -- Closing admission is a transaction of its own, first and small, so that a
  -- crowd of producers cannot starve the large one that settles the tickets: once
  -- it commits nothing is admitted, and the settlement runs against a state that
  -- no producer is changing.
  atomically (writeTVar (controlClosing control) True)
  atomically (settleAll control (either exitOf (const ExitStopped) served))
  stopped ← tryWithContext @SomeException (stopScheduler scheduler host)
  earlier ← readIORef kept
  let closeFailures =
        Map.toList . Map.fromListWith (\_ first → first) $
          earlier <> either (const []) stopCloseFailures stopped
      primary = either Just (const Nothing) served
      -- An interruption the scheduler's stop raised after completing, when it was
      -- not the owner's primary failure, is kept beside it.
      interruption = [("lua scheduler stop", failure) | Left failure ← [stopped], isLeft served]
      secondary = case (served, stopped) of
        (Right (), Left failure) → Just failure
        _ → Nothing
  composed ←
    composeCleanup
      (maybe secondary Just primary)
      ( interruption
          <> [("lua task close", ExceptionWithContext (someExceptionContext failure) failure) | (_, failure) ← closeFailures]
      )
  maybe (pure ()) rethrowIO composed
  where
    identity = vmIdentity (ownedInternalVm owned)
    label = vmOwnerName config
    scheduler = controlScheduler control
    loop host kept = do
      atomically (awaitWork scheduler)
      report ← serviceTurn scheduler host
      mask_ $ do
        modifyIORef' kept (<> turnCloseFailures report)
        atomically (sweepForgotten control)
      halt ← atomically stopping
      unless halt (loop host kept)

-- | The handle of a module the configuration loaded.
resolve ∷ OwnedVm → ModuleRef → IO (Maybe (ModuleRef, ModuleHandle))
resolve owned ref = fmap ((,) ref) <$> loadedModule owned ref

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
  → TaskRun Cursor
  → IO (SegmentReport Cursor)
runSegment control observe owned identity label handlesRef tasks run = do
  observe
    SegmentContext
      { contextTask = ScheduledTaskId (controlOwner control) (runTask run)
      , contextName = runName run
      , contextClass = runClass run
      , contextKind = runKind run
      , contextSegment = runSegmentNumber run
      , contextResume = runResume run
      }
  atomically (modifyTVar' (controlStarted control) (Set.insert (runTask run)))
  case runCursor run of
    Pending ref entry payload → do
      handles ← readIORef handlesRef
      case (Map.lookup ref handles, payload) of
        (Nothing, _) → failed (ModuleNotLoaded ref)
        (Just _, OverBound rule) → failed (BoundaryFailed (refusedArguments ref entry rule))
        (Just handle, WithinBounds arguments) →
          settledOrRaise (startTask owned handle entry arguments) >>= \case
            Left fault → failed fault
            Right TaskEntryAbsent → pure (ReportCompleted (Finished EntryAbsent))
            Right (TaskStarted task step) → do
              modifyIORef' tasks (Map.insert (runTask run) task)
              reported step
    Suspended → do
      held ← Map.lookup (runTask run) <$> readIORef tasks
      case held of
        -- Nothing but a corrupted state leaves a suspended task without its
        -- coroutine; the task fails with a typed failure rather than the owner.
        Nothing →
          pure . ReportFailed $
            TaskFailure (failureReason ValidationFault "the task's continuation is not held by its owner") RecoverySafe
        Just task →
          settledOrRaise (resumeTask owned task) >>= \case
            Left fault → modifyIORef' tasks (Map.delete (runTask run)) >> failed fault
            Right step → reported step
    Finished result → pure (ReportCompleted (Finished result))
  where
    failed fault = do
      atomically (modifyTVar' (controlFaults control) (Map.insert (runTask run) fault))
      pure (ReportFailed (TaskFailure (failureReason ScriptFault (Text.pack (show fault))) RecoverySafe))
    reported = \case
      Completed values → do
        modifyIORef' tasks (Map.delete (runTask run))
        pure (ReportCompleted (Finished (Returned values)))
      Yielded → pure (ReportYielded Suspended)
      Waiting request → pure $ case waitKind request of
        WaitLogical → ReportWaitTicks Suspended (countOf (waitArguments request))
        WaitElapsed → ReportWaitElapsed Suspended (durationOf (waitArguments request))
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

-- | A wait's first argument as a whole number of ticks. Anything that is not a
-- non-negative integer is read as none, which the scheduler refuses as a wait for
-- no ticks: the operation's schema is what keeps a script from asking.
countOf ∷ [Value] → Word64
countOf = \case
  [VInteger n] | n >= 0 → fromIntegral n
  _ → 0

-- | A wait's first argument as nanoseconds, read the same way.
durationOf ∷ [Value] → Duration
durationOf = \case
  [VInteger n] | n >= 0, Right duration ← durationFromNanoseconds AllowZero (toInteger n) → duration
  _ → zeroDuration

-- | Close a suspended task's coroutine, once, on this thread. A failure of the
-- close is raised, for the scheduler to keep as evidence.
closeSuspended ∷ OwnedVm → IORef (Map TaskId Task) → TaskId → IO ()
closeSuspended owned tasks identity = do
  held ← Map.lookup identity <$> readIORef tasks
  case held of
    Nothing → pure ()
    Just task → do
      modifyIORef' tasks (Map.delete identity)
      closeTask owned task

-- | Run one action of the VM, answering the fault of the task it raised, or
-- raising what is not the task's own.
settledOrRaise ∷ IO a → IO (Either CallFault a)
settledOrRaise action = do
  ran ← tryWithContext @SomeException action
  case ran of
    Right value → pure (Right value)
    Left failure@(ExceptionWithContext context exception)
      | raisedByApplication context → rethrowIO failure
      | Just fault ← fromException exception → pure (Left (BoundaryFailed fault))
      | Just fault ← fromException exception → pure (Left (LuaFailed fault))
      | otherwise → rethrowIO failure

-- | How a failure that ended the owner ends its tasks.
exitOf ∷ ExceptionWithContext SomeException → ExitKind
exitOf (ExceptionWithContext _ exception) = case fromException exception of
  Just (_ ∷ SomeAsyncException) → ExitCancelled
  Nothing → ExitFailed
