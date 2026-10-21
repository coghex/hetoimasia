-- | The state the two owners' bindings borrow, built before either owner and outliving both.
--
-- = Ownership
--
-- Every field is one of the sample's own values, never a Lua value and never a handle into a VM (the
-- gameplay workspaces' leases are the engine's, held in 'sharedLeases', and a script holds only a handle to
-- one). It is created by 'newShared' on the application thread before any owner starts, is borrowed by
-- the bindings the owners are registered with, and is dropped with the session. Who writes what:
--
-- * 'sharedCommitted' and 'sharedTick': the driver, on the application thread, once per tick — it makes the
--   tick's candidate before granting the tick and replaces the committed world when the tick has completed.
--   Between the two the gameplay owner's bindings, which run on the owner's callback thread, are the
--   candidate's only writers. A failure or a stop discards the candidate.
-- * 'sharedPublication': set once by the driver when the first snapshot is made; read by the UI owner's
--   capture and by the driver.
-- * 'sharedView': the UI owner's thread, at the start of each of its segments. The UI's bindings read it,
--   on a thread of the owner's own, one segment at a time.
-- * 'sharedQueue', 'sharedCounts': any thread, through the transactions of "Hetoimasia.Sample.LuaDomains.Queue"
--   and this module.
-- * 'sharedSession': the gameplay owner's escalation callback, the driver and whoever stops the session
--   ("Hetoimasia.Sample.LuaDomains.Session").
-- * 'sharedInput', 'sharedUpdates', 'sharedUiNotes', 'sharedUiFailure': the UI owner's bindings and its
--   escalation callback only.
-- * 'sharedControls', 'sharedControlsInFlight', 'sharedControlSeq', 'sharedControlTicks', 'sharedReceipts':
--   the UI's control bindings and the assignment the lifecycle grant asks for, both on the UI owner's
--   callback thread; the driver reads them.
-- * 'sharedWorkspaces': the workspace bindings' acquire and release, on the gameplay owner's threads.
-- * 'sharedTasks', 'sharedTaskAdmitting': whoever admits a task, the task's own watcher, and whoever reads the tasks'
--   settlements (the driver, the application thread's stop). An admission hands the task over in one transaction that
--   waits for nothing; whoever learns a settlement tells it in one transaction that also records its fault and takes
--   the task off the registry, so a settlement is told once however many of them learn it.
-- * 'sharedStopsIssued', 'sharedOnFailure': the gameplay owner's escalation callback, the task watchers, the driver
--   and whoever asks for the stop; asking is claimed and recorded without waiting.
-- * 'sharedWaitDepth', 'sharedWaitThreads': the application thread, which makes the supervised waits the sample
--   makes, one at a time.
--
-- The UI never reads 'sharedCommitted' or 'sharedTick'; gameplay never reads 'sharedView' or the
-- snapshot. Each owner's namespaces are the only way its VM reaches any of this
-- ("Hetoimasia.Sample.LuaDomains.Registration").
module Hetoimasia.Sample.LuaDomains.Shared
  ( Shared (..)
  , SharedSetup (..)
  , newShared
  , AdmissionDefect (..)
  , publishInitial
  , publisherOf
  , readerOf
    -- * The UI's operations
  , captureView
  , currentView
  , submit
  , noteMalformed
  , ScriptedInput (..)
  , pollInput
  , noteUpdate
  , UiNotes (..)
  , noteBusy
  , noteRetry
  , noteSaw
  , controlBegin
  , controlFinish
  , controlNote
  , controlSettled
  , abandonReceipts
  , assignControl
    -- * Gameplay's operations
  , StageAnswer (..)
  , gameplayWorld
  , gameplayStage
  , gameplayDraw
  , gameplayBegan
  , gameplayFinish
  , failSession
  , TaskEntry (..)
  , enterTaskAdmission
  , leaveTaskAdmission
  , taskAdmissionsDrained
  , takesTasks
  , handOffTask
  , tasksHeld
  , supervisedWait
    -- * Workspaces
  , Workspace (..)
  , openWorkspace
  , writeWorkspace
  , readWorkspace
    -- * Tasks
  , Watched (..)
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Data.IORef (IORef, newIORef)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVar
  , newTVarIO
  , readTVar
  , retry
  , throwSTM
  , writeTVar
  )
import Control.Exception (Exception, bracket_)
import Control.Monad (when)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( SnapshotPublisher
  , SnapshotReader
  , newSnapshot
  , observedValue
  , readSnapshot
  , snapshotReader
  )
import Hetoimasia.Foundation.Resource (acquirePart, releaseRank)
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds (boundPendingControls, boundSessionTasks))
import Hetoimasia.Sample.LuaDomains.Candidate (Candidate (..), Move, StagingRefusal, begin, draw, finish, stage)
import Hetoimasia.Sample.LuaDomains.Intention (Answer (..), FullCause (..), Submitted, validate)
import Hetoimasia.Sample.LuaDomains.Queue (AdmitAt (..), Queue, admitNext, closeQueue, hasTickLeft, isClosed, newQueue, nextUnstarted)
import Hetoimasia.Sample.LuaDomains.Session (SessionState, failedNow, newSessionState, recordFailure, stopRequestedNow)
import Hetoimasia.Sample.LuaDomains.Snapshot (GameSnapshot, SessionFailure, initialSnapshot)
import Hetoimasia.Sample.LuaDomains.Tally
  ( ControlCounts (..)
  , Counts
  , Workspaces (..)
  , bumpAnswer
  , bumpOffered
  , bumpSettled
  , countAnswer
  , noControls
  , noCounts
  , noWorkspaces
  )
import Hetoimasia.Sample.LuaDomains.World (World, initialWorld)
import Hetoimasia.Scripting.Lua.Instance (ControlSlot (..))
import Hetoimasia.Scripting.Lua.Lease (Leases, Lease, acquireOwned)
import Hetoimasia.Scripting.Lua.Lending (Lending)
import Hetoimasia.Scripting.Lua.Lifecycle (ControlRequestInfo)
import Hetoimasia.Scripting.Lua.Scheduled (ScheduledTicket)

-- | What a session's shared state is made from.
data SharedSetup = SharedSetup
  { setupBounds ∷ !Bounds
  , setupSession ∷ !Word64
  , setupSeed ∷ !Word64
  , setupFinal ∷ !(Maybe Word64)
  , setupInput ∷ ![ScriptedInput]
  , setupLending ∷ !Lending
  , setupLeases ∷ !Leases
  , setupAssignHook ∷ !(IO ())
    -- ^ Run by a control's assignment after it has decided the place and before it returns, in the
    -- interval before the engine admits the request: the window a test holds to show what the driver
    -- does in it. Nothing in production.
  , setupScenario ∷ !Text
  }

-- | The sample's shared state, owned as the module header says.
data Shared = Shared
  { sharedBounds ∷ !Bounds
  , sharedQueue ∷ !Queue
  , sharedCommitted ∷ !(TVar World)
  , sharedTick ∷ !(TVar (Maybe Candidate))
  , sharedCounts ∷ !(TVar Counts)
  , sharedPublication ∷ !(TVar (Maybe (SnapshotPublisher GameSnapshot)))
  , sharedView ∷ !(TVar GameSnapshot)
  , sharedInput ∷ !(TVar [ScriptedInput])
  , sharedUpdates ∷ !(TVar Int)
  , sharedSession ∷ !(TVar SessionState)
  , sharedLending ∷ !Lending
  , sharedLeases ∷ !Leases
  , sharedWorkspaces ∷ !(TVar Workspaces)
  , sharedControls ∷ !(TVar ControlCounts)
  , sharedControlsInFlight ∷ !(TVar Int)
  , sharedControlSeq ∷ !(TVar (Map Word64 Word64))
  , sharedControlTicks ∷ !(TVar (Set Word64))
  , sharedReceipts ∷ !(TVar Int)
  , sharedUiNotes ∷ !(TVar UiNotes)
  , sharedUiFailure ∷ !(TVar (Maybe SessionFailure))
  , sharedTasks ∷ !(TVar [Watched])
    -- ^ The tasks the session admitted and has not yet been told the settlement of, oldest first. An admission puts its
    -- task here in one transaction that waits for nothing, so an accepted task is tracked whatever interrupts its
    -- admitter; a settlement is told, its fault recorded and its task taken off in one transaction.
  , sharedTaskAdmitting ∷ !(TVar Int)
    -- ^ The task admissions between the check that the session takes tasks and the task's being watched.
  , sharedStopsIssued ∷ !(TVar [Int])
    -- ^ The gameplay instances (by position) a stop has been claimed for and requested of, in the one step.
  , sharedTaskSeq ∷ !(TVar Int)
    -- ^ The next task's number.
  , sharedGranting ∷ !(TVar Bool)
    -- ^ Whether the driver is issuing a grant: it checks that the session still runs and sets this in one transaction, issues
    -- the grant, and clears it. Recording a failure or a stop waits while it is set, so a grant is issued wholly before the
    -- failure or the stop is recorded, or not at all.
  , sharedWaitDepth ∷ !(TVar (Int, Int))
    -- ^ How many of those waits are pending now, and the most there have been at once: never more than one.
  , sharedWaitThreads ∷ !(TVar (Set ThreadId))
    -- ^ The threads that have made one of those waits.
  , sharedOnFailure ∷ !(IORef (IO ()))
    -- ^ What the owner's escalation callback and a task's watcher run after they tell the session of a failure:
    -- asking every instance and task to stop, which never waits. Set once the session's owners exist.
  , sharedAssignHook ∷ !(IO ())
  , sharedScenario ∷ !Text
  , sharedClosed ∷ !(TVar Bool)
    -- ^ Whether the snapshot's publication has ended, which retirement does last.
  }

-- | A session's state: the world at its seed, an empty queue (of a finite session's ticks, if it is
-- finite), this fake input, and nothing published yet.
newShared ∷ SharedSetup → IO Shared
newShared setup = do
  let bounds = setupBounds setup
      world = initialWorld bounds (setupSession setup) (setupSeed setup)
      first = initialSnapshot world Nothing
  Shared bounds
    <$> newQueue bounds (setupFinal setup)
    <*> newTVarIO world
    <*> newTVarIO Nothing
    <*> newTVarIO noCounts
    <*> newTVarIO Nothing
    <*> newTVarIO first
    <*> newTVarIO (setupInput setup)
    <*> newTVarIO 0
    <*> newSessionState
    <*> pure (setupLending setup)
    <*> pure (setupLeases setup)
    <*> newTVarIO noWorkspaces
    <*> newTVarIO noControls
    <*> newTVarIO 0
    <*> newTVarIO Map.empty
    <*> newTVarIO Set.empty
    <*> newTVarIO 0
    <*> newTVarIO (UiNotes 0 0 [])
    <*> newTVarIO Nothing
    <*> newTVarIO []
    <*> newTVarIO 0
    <*> newTVarIO []
    <*> newTVarIO 0
    <*> newTVarIO False
    <*> newTVarIO (0, 0)
    <*> newTVarIO Set.empty
    <*> newIORef (pure ())
    <*> pure (setupAssignHook setup)
    <*> pure (setupScenario setup)
    <*> newTVarIO False

-- | The sample's own defect, raised as a failure of the host and never counted away: the admission seam
-- answered the UI's path something it cannot, or a publication was asked for before there was one.
newtype AdmissionDefect = AdmissionDefect Text
  deriving (Eq, Show)

instance Exception AdmissionDefect

-- | Make the snapshot holding the initial world, now that the gameplay behavior's identity is known,
-- and let the UI read it. Once.
publishInitial ∷ Shared → Maybe (Int64, Int64, Int64) → IO ()
publishInitial shared identity = do
  world ← atomically (readTVar (sharedCommitted shared))
  let first = initialSnapshot world identity
  publisher ← newSnapshot =<< prepare first
  atomically $ do
    held ← readTVar (sharedPublication shared)
    case held of
      Nothing → writeTVar (sharedPublication shared) (Just publisher) >> writeTVar (sharedView shared) first
      Just _ → throwSTM (AdmissionDefect "the first snapshot was made twice")

-- | The snapshot's publisher. Raising a defect before the first snapshot is made.
publisherOf ∷ Shared → STM (SnapshotPublisher GameSnapshot)
publisherOf shared =
  readTVar (sharedPublication shared) >>= maybe (throwSTM (AdmissionDefect "no snapshot has been made yet")) pure

readerOf ∷ Shared → STM (SnapshotReader GameSnapshot)
readerOf shared = snapshotReader <$> publisherOf shared

-- The UI -----------------------------------------------------------------------

-- | Capture the latest committed snapshot as the view of the UI segment about to begin. The UI
-- owner calls it, on its own thread, as each segment is about to run; every query the segment
-- makes answers from this one capture. Before the first snapshot there is nothing newer than the
-- view the session started with, which stays.
captureView ∷ Shared → IO ()
captureView shared = atomically $
  readTVar (sharedPublication shared) >>= \case
    Nothing → pure ()
    Just publisher → do
      observation ← readSnapshot (snapshotReader publisher)
      writeTVar (sharedView shared) (preparedValue (observedValue observation))

-- | The capture the running UI segment answers from.
currentView ∷ Shared → IO GameSnapshot
currentView shared = atomically (readTVar (sharedView shared))

-- | Submit an intention, as the UI's binding does: apply the application's bounds, then ask the
-- queue for the next tick that has not started, and count the answer, all in one transaction. It
-- never waits, and the answer is the one the script is told.
submit ∷ Shared → Submitted → IO Answer
submit shared submitted = atomically $ do
  answer ← case validate (sharedBounds shared) submitted of
    Left refusal → pure (Refused refusal)
    Right intention →
      admitNext (sharedQueue shared) intention >>= \case
        AdmittedAt place → pure (Accepted place)
        AtFullQueue → pure (Full FullQueue)
        AtFullPlaces → pure (Full FullPlaces)
        AtClosed → pure Closed
        AtLate → throwSTM (AdmissionDefect "the UI's path was answered late")
        AtDuplicate → throwSTM (AdmissionDefect "the UI's path was answered a duplicate place")
  modifyTVar' (sharedCounts shared) (countAnswer (Just answer))
  pure answer

-- | Count a call the facade refused for its arity or types, which never reached 'submit'.
noteMalformed ∷ Shared → IO ()
noteMalformed shared = atomically (modifyTVar' (sharedCounts shared) (countAnswer Nothing))

-- | One entry of the fixed fake input: which entity the user nudged, and by how much.
data ScriptedInput = ScriptedInput
  { inputEntity ∷ !Int64
  , inputDx ∷ !Int64
  , inputDy ∷ !Int64
  }
  deriving (Eq, Show)

-- | The next scripted input, taking it from the source.
pollInput ∷ Shared → IO (Maybe ScriptedInput)
pollInput shared = atomically $
  readTVar (sharedInput shared) >>= \case
    [] → pure Nothing
    next : rest → Just next <$ writeTVar (sharedInput shared) rest

-- | A UI update finished.
noteUpdate ∷ Shared → IO ()
noteUpdate shared = atomically (modifyTVar' (sharedUpdates shared) (+ 1))

-- | What the UI behavior says it did besides submitting: how often it showed a busy indication for a
-- full answer, how often it offered an intention again because it had not been accepted, and the
-- statuses it saw, oldest first, each distinct from the one before and at most a few of them.
data UiNotes = UiNotes
  { notesBusy ∷ !Int
  , notesRetried ∷ !Int
  , notesSaw ∷ ![Text]
  }
  deriving (Eq, Show)

noteBusy ∷ Shared → IO ()
noteBusy shared = atomically (modifyTVar' (sharedUiNotes shared) (\notes → notes {notesBusy = notesBusy notes + 1}))

noteRetry ∷ Shared → IO ()
noteRetry shared = atomically (modifyTVar' (sharedUiNotes shared) (\notes → notes {notesRetried = notesRetried notes + 1}))

-- | The UI saw this status in its view. Kept if it differs from the last one seen, and only a few are.
noteSaw ∷ Shared → Text → IO ()
noteSaw shared status = atomically $
  modifyTVar' (sharedUiNotes shared) $ \notes →
    if take 1 (reverse (notesSaw notes)) == [status] || (length (notesSaw notes) >= 8 && status `notElem` ["failed", "stopped"])
      then notes
      else notes {notesSaw = notesSaw notes <> [status]}

-- | The UI is about to ask for a control: until it says it is done, the driver begins no tick, so a
-- request cannot be assigned a tick and then find it begun before the engine admits it. Never waits.
controlBegin ∷ Shared → IO ()
controlBegin shared = atomically $ do
  modifyTVar' (sharedControlsInFlight shared) (+ 1)
  modifyTVar' (sharedControls shared) bumpOffered

-- | The UI has the engine's answer to a request.
controlFinish ∷ Shared → IO ()
controlFinish shared = atomically (modifyTVar' (sharedControlsInFlight shared) (\held → max 0 (held - 1)))

-- | The UI's request was answered: accepted (and its receipt is held), or refused for this reason.
controlNote ∷ Shared → Maybe Text → IO ()
controlNote shared reason = atomically $ do
  modifyTVar' (sharedControls shared) (bumpAnswer reason)
  when (reason == Nothing) (modifyTVar' (sharedReceipts shared) (+ 1))

-- | The UI read an accepted request's settlement, by the engine's word for it, and gave the receipt up.
controlSettled ∷ Shared → Text → IO ()
controlSettled shared kind = atomically $ do
  modifyTVar' (sharedControls shared) (bumpSettled kind)
  modifyTVar' (sharedReceipts shared) (\held → max 0 (held - 1))

-- | The UI behavior ended holding this many receipts it never read: they are reported apart and given
-- no result, and abandoning them cancels nothing the engine had accepted.
abandonReceipts ∷ Shared → IO Int
abandonReceipts shared = atomically $ do
  held ← readTVar (sharedReceipts shared)
  writeTVar (sharedReceipts shared) 0
  modifyTVar' (sharedControls shared) (\counts → counts {controlAbandoned = controlAbandoned counts + held})
  pure held

-- | Where a control the UI asks for belongs: the next tick that has not begun, and the next place among
-- the controls of that tick; declined when the session has failed, is stopping or is closed, or has no tick
-- left (a finite session's last tick has begun, so the next unstarted tick is beyond it). It reads the tick in one transaction with the place it takes, and the driver begins no tick while a
-- request is between this and the engine's admission (the UI's bracket), so the engine never finds the tick
-- begun.
assignControl ∷ Shared → ControlRequestInfo → IO (Maybe ControlSlot)
assignControl shared _ = do
  slot ← atomically $ do
    closed ← isClosed (sharedQueue shared)
    failed ← failedNow (sharedSession shared)
    stopping ← stopRequestedNow (sharedSession shared)
    held ← readTVar (sharedReceipts shared)
    left ← hasTickLeft (sharedQueue shared)
    -- The engine holds a reservation for each accepted control until its receipt is read; the owner has as many
    -- as the pending bound and one more for each instance the stop must reach, so the stop is always admitted.
    if closed || failed || stopping || not left || held >= boundPendingControls (sharedBounds shared)
      then pure Nothing
      else do
        tick ← nextUnstarted (sharedQueue shared)
        sequences ← readTVar (sharedControlSeq shared)
        let order = Map.findWithDefault 0 tick sequences
        writeTVar (sharedControlSeq shared) (Map.insert tick (order + 1) sequences)
        modifyTVar' (sharedControlTicks shared) (Set.insert tick)
        pure (Just (ControlSlot tick order))
  sharedAssignHook shared
  pure slot

-- | Tell the session of a failure: it is recorded, and admission to the queue closes in the same transaction, so no
-- intention is accepted for a tick after the failure that will never run it, whenever the driver gets to publish.
failSession ∷ Shared → SessionFailure → STM ()
failSession shared failure = do
  -- A grant being issued is issued whole before this is recorded: the transaction waits for it (a short call that waits
  -- for nothing), and so no grant is issued once a failure is recorded.
  granting ← readTVar (sharedGranting shared)
  when granting retry
  recordFailure (sharedSession shared) failure
  closeQueue (sharedQueue shared)

-- | Whether the session takes tasks: it has not failed, is not stopping, and its admission is open. Failing, stopping and
-- ending all close the queue in the transaction that records them, so a closed queue is the one answer to all three.
takesTasks ∷ Shared → STM Bool
takesTasks shared = do
  closed ← isClosed (sharedQueue shared)
  failed ← failedNow (sharedSession shared)
  stopping ← stopRequestedNow (sharedSession shared)
  pure (not (closed || failed || stopping))

-- | What entering a task admission answered.
data TaskEntry
  = TaskEntered
  | -- | The session takes no task: it has failed, is stopping or has ended.
    TaskEntryClosed
  | -- | The session holds as many unobserved tasks as 'boundSessionTasks' allows.
    TaskEntryFull
  deriving (Eq, Show)

-- | Enter a task admission, if the session takes tasks and holds fewer than 'boundSessionTasks' that are not yet
-- observed (those watched, and those whose admission is unfinished): the check and the entry are one transaction, and
-- the entry is what the session's ending waits for ('taskAdmissionsDrained'), so no task is admitted to the owner once
-- the session has ended.
enterTaskAdmission ∷ Shared → STM TaskEntry
enterTaskAdmission shared = do
  open ← takesTasks shared
  admitting ← readTVar (sharedTaskAdmitting shared)
  held ← tasksHeld shared
  if not open
    then pure TaskEntryClosed
    else
      if admitting + held >= boundSessionTasks (sharedBounds shared)
        then pure TaskEntryFull
        else do
          writeTVar (sharedTaskAdmitting shared) (admitting + 1)
          pure TaskEntered

-- | The admission entered is over: the task is accepted and watched, or refused.
leaveTaskAdmission ∷ Shared → STM ()
leaveTaskAdmission shared = modifyTVar' (sharedTaskAdmitting shared) (\held → max 0 (held - 1))

-- | Retry until no task admission is between its check and its being watched.
taskAdmissionsDrained ∷ Shared → STM ()
taskAdmissionsDrained shared = do
  held ← readTVar (sharedTaskAdmitting shared)
  when (held > 0) retry

-- | How many tasks the session has admitted and not been told the settlement of.
tasksHeld ∷ Shared → STM Int
tasksHeld shared = length <$> readTVar (sharedTasks shared)

-- | Track a task the owner has accepted: it joins the registry in one transaction that waits for nothing, so a task the
-- owner accepted is tracked and counted whatever interrupts the admitter next.
handOffTask ∷ Shared → Text → ScheduledTicket → STM Watched
handOffTask shared name ticket = do
  number ← readTVar (sharedTaskSeq shared)
  writeTVar (sharedTaskSeq shared) (number + 1)
  stopped ← newTVar False
  let watched = Watched name ticket number stopped
  modifyTVar' (sharedTasks shared) (<> [watched])
  pure watched

-- | Run one of the supervised waits the sample makes, and note which thread made it and how many were pending. The
-- supervision handle is the application thread's: the driver ('Hetoimasia.Sample.LuaDomains.Domains.stepTick') and the
-- stop ('Hetoimasia.Sample.LuaDomains.Domains.stopSession') refuse any other thread, so the waits are that thread's and
-- one at a time (none is nested in another), and what is noted is evidence of it.
supervisedWait ∷ Shared → IO a → IO a
supervisedWait shared wait = do
  here ← myThreadId
  bracket_
    ( atomically $ do
        modifyTVar' (sharedWaitDepth shared) (\(now, most) → (now + 1, max most (now + 1)))
        modifyTVar' (sharedWaitThreads shared) (Set.insert here)
    )
    (atomically (modifyTVar' (sharedWaitDepth shared) (\(now, most) → (now - 1, most))))
    wait

-- Gameplay ---------------------------------------------------------------------

-- | What staging a move answered.
data StageAnswer
  = Staged
  | StageRefused !StagingRefusal
  | -- | No tick is in progress, so there is no batch.
    NoTickInProgress
  deriving (Eq, Show)

-- | Read the world gameplay sees: the tick's candidate, which has the tick's applied intentions in
-- it, and outside a tick the committed world.
gameplayWorld ∷ Shared → IO (World, Maybe Word64)
gameplayWorld shared = atomically $ do
  candidate ← readTVar (sharedTick shared)
  case candidate of
    Just working → pure (candidateWorld working, Just (candidateTick working))
    Nothing → (\world → (world, Nothing)) <$> readTVar (sharedCommitted shared)

-- | Stage a move into the tick's batch.
gameplayStage ∷ Shared → Move → IO StageAnswer
gameplayStage shared move = atomically (withCandidate shared NoTickInProgress $ \candidate →
  case stage (sharedBounds shared) move candidate of
    Left refusal → (StageRefused refusal, candidate)
    Right staged → (Staged, staged))

-- | Draw from the candidate's stream: a value in @[0, n)@, or 'Nothing' for a bound the stream
-- does not accept or when no tick is in progress. A draw advances the candidate's stream only.
gameplayDraw ∷ Shared → Int64 → IO (Maybe Int64)
gameplayDraw shared bound = atomically (withCandidate shared Nothing $ \candidate →
  case draw bound candidate of
    Nothing → (Nothing, candidate)
    Just (value, next) → (Just value, next))

-- | Say gameplay's update has begun in the tick. Answers whether there was a tick.
gameplayBegan ∷ Shared → IO Bool
gameplayBegan shared = atomically (withCandidate shared False (\candidate → (True, begin candidate)))

-- | Say gameplay's work for the tick is done. Answers whether there was a tick to finish.
gameplayFinish ∷ Shared → IO Bool
gameplayFinish shared = atomically (withCandidate shared False (\candidate → (True, finish candidate)))

-- | Run a pure step over the tick's candidate, or answer this when none is in progress.
withCandidate ∷ Shared → a → (Candidate → (a, Candidate)) → STM a
withCandidate shared none step = do
  candidate ← readTVar (sharedTick shared)
  case candidate of
    Nothing → pure none
    Just working → do
      let (answer, next) = step working
      next `seq` writeTVar (sharedTick shared) (Just next)
      pure answer

-- Workspaces -----------------------------------------------------------------------

-- | A gameplay instance's workspace: a small scratch cell the instance's behavior notes into. It is the
-- sample's one leased resource: acquired through the engine's leases, so that it is released whenever the
-- instance ends, however the script behaves.
newtype Workspace = Workspace (TVar Int64)

-- | Acquire a workspace for the calling instance, through the engine's leases. The acquire and the release
-- are counted; a release that raises is counted as failed and never as released, and the failure is the
-- engine's cleanup evidence.
openWorkspace ∷ Shared → IO (Lease Workspace)
openWorkspace shared = acquireOwned (sharedLeases shared) $ \_ → do
  cell ← acquirePart
    "workspace"
    (releaseRank 0)
    ( do
        cell ← newTVarIO 0
        atomically (modifyTVar' (sharedWorkspaces shared) (\held → held {workspacesAcquired = workspacesAcquired held + 1}))
        pure (Workspace cell)
    )
    ( \_ → do
        atomically (modifyTVar' (sharedWorkspaces shared) (\held → held {workspacesReleased = workspacesReleased held + 1}))
    )
  pure cell

-- | Note a value in a workspace.
writeWorkspace ∷ Workspace → Int64 → IO ()
writeWorkspace (Workspace cell) value = atomically (writeTVar cell value)

-- | What a workspace holds.
readWorkspace ∷ Workspace → IO Int64
readWorkspace (Workspace cell) = atomically (readTVar cell)

-- Tasks ------------------------------------------------------------------------------

-- | A task the session admitted to the gameplay owner, watched for a fault by the driver.
data Watched = Watched
  { watchedName ∷ !Text
  , watchedTicket ∷ !ScheduledTicket
  , watchedNumber ∷ !Int
    -- ^ Its place among the tasks the session admitted.
  , watchedStopAsked ∷ !(TVar Bool)
    -- ^ Whether it has been asked to stop: claimed before the request is made, in the one step.
  }

instance Eq Watched where
  a == b = watchedNumber a == watchedNumber b
