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
-- A request is applied when the owner's thread services its jobs, which it does
-- between turns and never inside a segment. Pause and resume of the invocation in
-- flight are the scheduler's own pause and resume of its task, which it applies
-- before it chooses anything else. A stop discards what had not begun, revokes the
-- connections, asks the scheduler to stop the invocation in flight, which closes
-- its coroutine on this thread, and runs @shutdown@ after that close.
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
  , instanceSegment
  , instanceClosed
  , reapInvocations
  , retireInstances
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, fromException, mask_, rethrowIO, throwIO, try, tryWithContext)
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Sequence (ViewL (EmptyL, (:<)), viewl)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.State
import Hetoimasia.Scripting.Lua.Instance.Types
import Hetoimasia.Scripting.Lua.Internal.Module (EntryPoint (entryName), ModuleHandle (handleEntries), callEntryVia, entryDefined)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedHost)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (ReasonCode (ScriptFault), RecoverySafety (RecoverySafe), failureReason)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure (TaskFailure))
import Hetoimasia.Scripting.Lua.Internal.Task (startTaskVia)
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (boundaryTraceback)
  , CallResult (Returned)
  , ModuleRef
  , OwnedVm
  , Task
  , TaskStart (TaskEntryAbsent, TaskStarted)
  , callEntry
  , resumeTask
  , startTask
  )
import qualified Hetoimasia.Scripting.Lua.Owner as Owner
import Hetoimasia.Scripting.Lua.Runtime.Types
  ( CallFault (BoundaryFailed, ModuleNotLoaded)
  , Discard (Discard)
  , ExitKind (ExitFailed)
  , Payload (WithinBounds)
  , Progress (NotStarted, Started)
  )
import Hetoimasia.Scripting.Lua.Scheduled.Shared (settledOrRaise, waitReport)
import Hetoimasia.Scripting.Lua.Scheduled.Types
import Hetoimasia.Scripting.Lua.Scheduler
  ( AdmitAnswer (Admitted)
  , BehaviorId (BehaviorId)
  , ControlAnswer (ControlAccepted)
  , ControlRequest (RequestPause, RequestResume, RequestStop)
  , ControlResult (ControlAlreadyInState, ControlApplied, ControlNoLongerApplicable)
  , ControlTicket (forgetControl)
  , Scheduler
  , SegmentReport (ReportCompleted, ReportFailed, ReportYielded)
  , TaskKind (OneShot)
  , TaskPhase (PhaseEnded, PhasePaused, PhaseQueued, PhaseReady, PhaseRunning, PhaseWaiting)
  , TaskRun (runTask)
  , TaskSpec (..)
  , admitTask
  , observeTask
  , readTick
  , requestControl
  , schedulerClosed
  , taskPhase
  )
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VRecord, VText))
import Hetoimasia.Scripting.Lua.Instance.Driver (eventEntry)

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
  }

-- | What the owner's thread holds for its instances, besides what the application
-- shares: the VM, the driver, the coroutines, and how each instance is ending.
data InstanceHost = InstanceHost
  { ihControl ∷ !Control
  , ihInstances ∷ !Instances
  , ihEscalate ∷ InstanceFailure → IO Escalation
  , ihOwned ∷ !OwnedVm
  , ihDriver ∷ !ModuleHandle
  , ihHandles ∷ !(IORef (Map ModuleRef ModuleHandle))
  , ihTasks ∷ !(IORef (Map TaskId Task))
  , ihExtra ∷ !(IORef [(Text, ExceptionWithContext SomeException)])
  , ihLive ∷ !(IORef (Map TaskId Live))
  , ihEndings ∷ !(IORef (Map Word64 Ending))
  , ihCreated ∷ !(IORef (Set.Set Word64))
  , ihMode ∷ !(IORef ExitMode)
  }

-- | The host of an owner's instances.
newInstanceHost
  ∷ Control
  → Instances
  → (InstanceFailure → IO Escalation)
  → OwnedVm
  → ModuleHandle
  → IORef (Map ModuleRef ModuleHandle)
  → IORef (Map TaskId Task)
  → IORef [(Text, ExceptionWithContext SomeException)]
  → IO InstanceHost
newInstanceHost control instances escalate owned driver handles tasks extra =
  InstanceHost control instances escalate owned driver handles tasks extra
    <$> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Set.empty
    <*> newIORef Serving

-- | What the scheduler answers the instance layer's transactions.
gateOf ∷ Control → Gate
gateOf control =
  Gate
    { gateOpen = do
        closed ← schedulerClosed scheduler
        stopping ← controlStopping control
        pure (not closed && not stopping)
    , gateTick = readTick scheduler
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
awaitInstanceWork = awaitJobs . ihInstances

scheduler' ∷ InstanceHost → Scheduler Cursor
scheduler' = controlScheduler . ihControl

-- Servicing -----------------------------------------------------------------------------

-- | Service what the application asked, in the order it asked: make new instances
-- and run their @init@, look at queues, and apply requests. Then look again at every
-- queue, so an invocation the scheduler had no room for is retried at the next
-- wake.
serviceInstances ∷ InstanceHost → IO ()
serviceInstances ih = do
  reapInvocations ih
  jobs ← atomically (takeJobs (ihInstances ih))
  forM_ jobs $ \case
    JobStart number → withCell ih number (startInstance ih)
    JobDispatch number → withCell ih number $ \cell → do
      atomically (modifyTVar' (icState cell) (\state → state {isDispatchQueued = False}))
      dispatch ih cell
    JobControl number request receipt → do
      found ← lookupCell ih number
      case found of
        Just cell → applyControl ih cell request receipt
        Nothing → atomically (settleReceipt receipt ControlNoLongerApplicable)
  cells ← Map.elems <$> readTVarIO (insCells (ihInstances ih))
  forM_ cells (dispatch ih)

lookupCell ∷ InstanceHost → Word64 → IO (Maybe ICell)
lookupCell ih number = Map.lookup number <$> readTVarIO (insCells (ihInstances ih))

-- | Run an action on an instance that has not settled.
withCell ∷ InstanceHost → Word64 → (ICell → IO ()) → IO ()
withCell ih number action = do
  found ← lookupCell ih number
  forM_ found $ \cell → do
    settled ← isJust <$> readTVarIO (icResult cell)
    unless settled (action cell)

-- | Give the scheduler's result storage back for every invocation that has ended.
reapInvocations ∷ InstanceHost → IO ()
reapInvocations ih = do
  live ← readIORef (ihLive ih)
  gone ← atomically . fmap concat . forM (Map.keys live) $ \task →
    taskPhase (scheduler' ih) task >>= \case
      Just (PhaseEnded _) → [task] <$ observeTask (scheduler' ih) task
      Nothing → pure [task]
      _ → pure []
  modifyIORef' (ihLive ih) (\held → foldr Map.delete held gone)

-- Starting ----------------------------------------------------------------------------

-- | Make an instance and run its @init@.
startInstance ∷ InstanceHost → ICell → IO ()
startInstance ih cell = do
  state ← readTVarIO (icState cell)
  unless (isStopped state) $ do
    handles ← readIORef (ihHandles ih)
    case Map.lookup (icModule cell) handles of
      Nothing → failInstance ih cell Initializing StageInit (ErrorFault (ModuleNotLoaded (icModule cell)))
      Just handle → do
        runnable ← case icKind cell of
          RunOnce → hookAvailable ih handle "run"
          EventOnly → pure True
        if not runnable
          then failInstance ih cell Initializing StageInit (ErrorMissingEntry "run")
          else do
            made ← settledOrRaise (ihExtra ih) (callEntry (ihOwned ih) (ihDriver ih) "create" [VInteger (fromIntegral (icId cell))])
            case made of
              Left fault → failInstance ih cell Initializing StageInit (ErrorFault fault)
              Right _ → do
                modifyIORef' (ihCreated ih) (Set.insert (icId cell))
                declared ← hookAvailable ih handle "init"
                ran ←
                  if declared
                    then settledOrRaise (ihExtra ih) (callEntryVia (ownedHost (ihOwned ih)) (ihDriver ih) "init" handle "init" [VInteger (fromIntegral (icId cell))])
                    else pure (Right (Returned []))
                case ran of
                  Left fault → failInstance ih cell Initializing StageInit (ErrorFault fault)
                  Right _ → do
                    atomically . modifyTVar' (icState cell) $ \current →
                      if isStopped current
                        then current
                        else current {isPhase = Active, isInitialized = True}
                    dispatch ih cell

-- | Whether a module defines a hook, as an entry point it declares and defines.
hookAvailable ∷ InstanceHost → ModuleHandle → Text → IO Bool
hookAvailable ih handle name
  | name `notElem` map entryName (handleEntries handle) = pure False
  | otherwise = entryDefined (ownedHost (ihOwned ih)) handle name

-- Invocations ----------------------------------------------------------------------------

-- | Admit the instance's next invocation as a task, if it has one and may start it.
--
-- A one-shot's @run@ comes first, then the events in the order they were accepted.
-- One at a time: an instance with an invocation in flight, paused, ending or still
-- initializing admits none.
dispatch ∷ InstanceHost → ICell → IO ()
dispatch ih cell = do
  -- What the scheduler holds for invocations that ended is given back first, so
  -- admitting the next one needs room for one more and not for every one before it.
  reapInvocations ih
  started ← atomically $ do
    state ← readTVar (icState cell)
    if isPhase state /= Active || isJust (isActive state)
      then pure Nothing
      else do
        let next = case icKind cell of
              RunOnce | not (isRunStarted state) → Just (InvokeRun, StageRun, isQueue state)
              _ → case viewl (isQueue state) of
                event :< rest →
                  Just
                    ( InvokeEvent (queuedSource event) (WithinBounds [record event])
                    , StageEvent (queuedSource event)
                    , rest
                    )
                EmptyL → Nothing
        case next of
          Nothing → pure Nothing
          Just (invocation, stage, rest) → do
            let spec =
                  TaskSpec
                    { specBehavior = BehaviorId (behavior stage)
                    , specEntry = entry stage
                    , specName = icName cell
                    , specClass = icClass cell
                    , specKind = OneShot
                    , specCursor = PendingInvocation (icId cell) invocation
                    }
            admitTask (scheduler' ih) spec >>= \case
              Admitted task → do
                writeTVar (icState cell) $
                  state
                    { isActive = Just task
                    , isQueue = rest
                    , isRunStarted = isRunStarted state || stage == StageRun
                    }
                pure (Just (task, stage))
              _ → pure Nothing
  forM_ started $ \(task, stage) →
    modifyIORef' (ihLive ih) (Map.insert task (Live (icId cell) stage))
  where
    record event =
      VRecord
        [ ("source", VText (queuedSource event))
        , ("sequence", VInteger (fromIntegral (queuedSequence event)))
        , ("tick", VInteger (fromIntegral (queuedTick event)))
        , ("payload", queuedPayload event)
        ]
    entry = \case
      StageEvent source → eventEntry source
      _ → "run"
    behavior stage = Text.pack (show (icModule cell)) <> "/" <> entry stage

-- | Run one segment of an instance's invocation, on behalf of the scheduler.
--
-- An instance that is paused or ending is not entered: the task asks the scheduler
-- to pause or stop it, which it is already about to, and yields. That is how the
-- scheduler's own control is the one that freezes or closes a task that was waiting
-- in its queue when the request was applied.
instanceSegment ∷ InstanceHost → TaskRun Cursor → Word64 → Maybe Invocation → IO (SegmentReport Cursor)
instanceSegment ih run number starting = do
  found ← lookupCell ih number
  held ← Map.lookup (runTask run) <$> readIORef (ihLive ih)
  case (found, held) of
    (Just cell, Just live) → do
      settled ← isJust <$> readTVarIO (icResult cell)
      state ← readTVarIO (icState cell)
      if settled
        then pure (ReportCompleted (Finished (Returned [])))
        else
          if isStopped state
            then hold cell RequestStop
            else
              if isPhase state == Paused
                then hold cell RequestPause
                else mask_ (go cell (liveStage live))
    _ → pure (ReportCompleted (Finished (Returned [])))
  where
    cursor = maybe (HostedInvocation number) (PendingInvocation number) starting
    hold _ request = do
      asked ← atomically (requestControl (scheduler' ih) (runTask run) request)
      case asked of
        ControlAccepted ticket → atomically (forgetControl ticket)
        _ → pure ()
      pure (ReportYielded cursor)
    go cell stage = do
      let slot = VInteger (fromIntegral number)
      outcome ← case starting of
        Just (InvokeEvent source (WithinBounds [event])) →
          begin $ startTask (ihOwned ih) (ihDriver ih) (eventEntry source) [slot, event]
        Just (InvokeEvent _ _) → pure (Left (ErrorMissingEntry "an event"))
        Just InvokeRun → do
          handles ← readIORef (ihHandles ih)
          case Map.lookup (icModule cell) handles of
            Nothing → pure (Left (ErrorFault (ModuleNotLoaded (icModule cell))))
            Just handle → begin $ startTaskVia (ownedHost (ihOwned ih)) (ihDriver ih) "run" handle "run" [slot]
        Nothing → do
          held ← Map.lookup (runTask run) <$> readIORef (ihTasks ih)
          case held of
            Nothing → pure (Left (ErrorRefusedWait (TaskFailure (failureReason ScriptFault "the invocation's continuation is not held by its owner") RecoverySafe)))
            Just task → do
              resumed ← settledOrRaise (ihExtra ih) (resumeTask (ihOwned ih) task)
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
          Owner.Waiting request → pure (waitReport (HostedInvocation number) request)
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
  atomically (modifyTVar' (icState cell) (\state → state {isActive = Nothing}))
  case stage of
    StageRun → beginStop ih cell EndCompleted Nothing
    _ → dispatch ih cell

-- | An invocation failed: the instance fails with it, and ends.
invocationFailed ∷ InstanceHost → ICell → HookStage → InstanceError → IO ()
invocationFailed ih cell stage failure = do
  phase ← isPhase <$> readTVarIO (icState cell)
  atomically (modifyTVar' (icState cell) (\state → state {isActive = Nothing}))
  beginStop ih cell EndFailed (Just (Primary phase stage failure))

-- | A coroutine of the scheduler was closed, by a stop or by the owner's own: the
-- instance whose invocation it was is ended, after its coroutine, which is already
-- closed.
instanceClosed ∷ InstanceHost → TaskId → IO ()
instanceClosed ih task = do
  held ← Map.lookup task <$> readIORef (ihLive ih)
  forM_ held $ \live → withCell ih (liveSlot live) $ \cell → do
    atomically (modifyTVar' (icState cell) (\state → state {isActive = Nothing}))
    beginEnding' ih cell EndStopped Nothing
    finishEnding ih cell 1

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
            atomically (modifyTVar' (icState cell) (\current → current {isPhase = Paused}))
            forM_ (isActive state) (`schedulerControl` RequestPause)
            settle ControlApplied
          (Active, InstanceResume) → settle ControlAlreadyInState
          (Paused, InstancePause) → settle ControlAlreadyInState
          (Paused, InstanceResume) → do
            atomically (modifyTVar' (icState cell) (\current → current {isPhase = Active}))
            case isActive state of
              Just task → schedulerControl task RequestResume
              Nothing → dispatch ih cell
            settle ControlApplied
          (_, InstanceStop) → do
            beginStop ih cell EndStopped Nothing
            settle ControlApplied
          _ → settle ControlAlreadyInState
  where
    schedulerControl task how = do
      asked ← atomically (requestControl (scheduler' ih) task how)
      case asked of
        ControlAccepted ticket → atomically (forgetControl ticket)
        _ → pure ()

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
  state ← readTVarIO (icState cell)
  beginEnding' ih cell reason primary
  case isActive state of
    Just task → do
      asked ← atomically (requestControl (scheduler' ih) task RequestStop)
      case asked of
        ControlAccepted ticket → atomically (forgetControl ticket)
        _ → pure ()
    Nothing → finishEnding ih cell 0

-- | Record how an instance is ending, once, and close what it accepts.
beginEnding' ∷ InstanceHost → ICell → EndReason → Maybe Primary → IO ()
beginEnding' ih cell reason primary = do
  (connections, unstarted, already) ← atomically (beginEnding cell)
  unless already $
    modifyIORef' (ihEndings ih) (Map.insert (icId cell) (Ending reason primary connections unstarted))

-- | Finish ending an instance: its @shutdown@ hook, once, the release of its
-- record in the VM, and its settlement, once. The application is then told if it
-- failed.
finishEnding ∷ InstanceHost → ICell → Int → IO ()
finishEnding ih cell closed = do
  settled ← isJust <$> readTVarIO (icResult cell)
  unless settled $ do
    ending ← Map.findWithDefault (Ending EndStopped Nothing 0 0) (icId cell) <$> readIORef (ihEndings ih)
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
    (disposition, shutdownFailure) ←
      case handle of
        _ | not (isInitialized state) → pure (ShutdownSkippedNoInit, Nothing)
        Just module' | safe → do
          available ← hookAvailable ih module' "shutdown"
          if not available
            then pure (ShutdownAbsent, Nothing)
            else do
              ran ← settledOrRaise (ihExtra ih) (callEntryVia (ownedHost (ihOwned ih)) (ihDriver ih) "shutdown" module' "shutdown" [slot, VText reasonText])
              pure $ case ran of
                Left fault → (ShutdownRaised, Just (ErrorFault fault))
                Right _ → (ShutdownRan, Nothing)
        _ → pure (ShutdownSkippedUnsafe, Nothing)
    when (created && safe) $ do
      -- A release that fails is cleanup evidence, kept for the owner's end: nothing
      -- the application's escalation answers can hide it.
      released ← tryWithContext @SomeException (callEntry (ihOwned ih) (ihDriver ih) "release" [slot])
      case released of
        Right _ → pure ()
        Left failure@(ExceptionWithContext _ raised)
          | isJust (fromException raised ∷ Maybe SomeAsyncException) → rethrowIO failure
          | otherwise → modifyIORef' (ihExtra ih) (<> [("lua instance release", failure)])
    let failure = case (endPrimary ending, shutdownFailure) of
          (Just (Primary phase stage err), secondary) → Just (describe phase stage err [(StageShutdown, e) | Just e ← [secondary]])
          (Nothing, Just err) → Just (describe Stopping StageShutdown err [])
          (Nothing, Nothing) → Nothing
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
        (terminal, outcome) = case (mode, failure) of
          (Unorderly kind, _) → (Stopped, InstanceDiscarded (Discard kind (if isInitialized state || created then Started else NotStarted)))
          (_, Just failed) → (Failed, InstanceFailed failed)
          (_, Nothing) → case endReason ending of
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
            , resultTermination = Termination (endConnections ending) (endUnstarted ending) closed disposition
            }
    won ← atomically (settleInstance (ihInstances ih) cell settlement)
    modifyIORef' (ihEndings ih) (Map.delete (icId cell))
    modifyIORef' (ihCreated ih) (Set.delete (icId cell))
    -- The application is told of a failure after the instance has ended, so what it
    -- decides cannot undo the settlement.
    case (won, failure, mode) of
      (True, Just _, Unorderly _) → pure ()
      (True, Just failed, _) → do
        decision ← ihEscalate ih failed
        when (decision == Escalate) $ throwIO (InstanceEscalated failed)
      _ → pure ()

-- Exit ---------------------------------------------------------------------------------------

-- | The owner's exit: every instance not yet ended ends.
--
-- Called once the scheduler has stopped and has closed every coroutine it held,
-- each of which ended its instance through 'instanceClosed'. In order, an
-- instance still live is stopped through the ordinary path, with reason @stopped@;
-- after a failure or a cancellation no hook runs, and it settles as discarded. A
-- request the owner never applied settles as no longer applicable.
retireInstances ∷ InstanceHost → IO ()
retireInstances ih = do
  jobs ← atomically (takeJobs (ihInstances ih))
  forM_ jobs $ \case
    JobControl _ _ receipt → atomically (settleReceipt receipt ControlNoLongerApplicable)
    _ → pure ()
  mode ← readIORef (ihMode ih)
  cells ← Map.elems <$> readTVarIO (insCells (ihInstances ih))
  -- Each instance ends on its own: what one raises (a host failure from its hook, or
  -- the application's escalation) is kept for the owner's outcome and does not leave
  -- another unended, and none is left unsettled whatever was raised.
  failures ← forM cells $ \cell → do
    ended ← try @SomeException $ do
      settled ← isJust <$> readTVarIO (icResult cell)
      unless settled $ case mode of
        Unorderly _ → discard ih cell
        _ → beginEnding' ih cell EndStopped Nothing >> finishEnding ih cell 0
    case ended of
      Left failure → [failure] <$ discardUnsettled ih cell
      Right () → pure []
  forM_ (take 1 (concat failures)) throwIO

-- | Settle an instance that is still unsettled as discarded, because its end could
-- not be carried through.
discardUnsettled ∷ InstanceHost → ICell → IO ()
discardUnsettled ih cell = do
  state ← readTVarIO (icState cell)
  let settlement =
        InstanceSettlement
          { resultInstance = InstanceId (controlOwner (ihControl ih)) (icId cell)
          , resultOwner = controlLabel (ihControl ih)
          , resultName = icName cell
          , resultModule = icModule cell
          , resultPhase = Stopped
          , resultOutcome = InstanceDiscarded (Discard ExitFailed (if isInitialized state then Started else NotStarted))
          , resultTermination = Termination 0 0 0 ShutdownSkippedUnsafe
          }
  void (atomically (settleInstance (ihInstances ih) cell settlement))

-- | Settle an instance as discarded, whatever it was doing.
discard ∷ InstanceHost → ICell → IO ()
discard ih cell = do
  settled ← isJust <$> readTVarIO (icResult cell)
  unless settled $ do
    beginEnding' ih cell EndStopped Nothing
    finishEnding ih cell 0
