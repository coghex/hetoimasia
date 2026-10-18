-- | What a scheduled owner's tasks, tickets and shared state are made of.
--
-- Nothing here runs Lua or a worker. It is the vocabulary
-- "Hetoimasia.Scripting.Lua.Scheduled" speaks in, and the state its two sides
-- share: the application's callers, who admit tasks and read what they settled
-- as, and the owner's thread, which runs the tasks' segments.
module Hetoimasia.Scripting.Lua.Scheduled.Types
  ( -- * Identity
    ScheduledTaskId (..)

    -- * What a task carries
  , Cursor (..)
  , Invocation (..)

    -- * What a task settles as
  , ScheduledOutcome (..)
  , ScheduledSettlement (..)

    -- * What a request is
  , TaskRequest (..)
  , SegmentContext (..)

    -- * Shared state
  , Cell (..)
  , Control (..)
  , ScheduledEndpoint (..)
  , observeCell
  , forgetCell
  , sweepForgotten
  , settleAll
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', readTVar, writeTVar)
import Control.DeepSeq (NFData (rnf))
import Control.Monad (forM, when)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.Types (Instances)
import Hetoimasia.Scripting.Lua.Lifecycle.State (LifecycleState, abandonAll)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (ServiceClass)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure)
import Hetoimasia.Scripting.Lua.Owner (CallResult (Returned), ModuleRef)
import Hetoimasia.Scripting.Lua.Runtime.Types
  ( CallFault
  , Discard (Discard)
  , ExitKind
  , ExitRecord (..)
  , OwnerId
  , Payload
  , Progress (NotStarted, Started)
  )
import Hetoimasia.Scripting.Lua.Scheduler
  ( Resume
  , Scheduler
  , TaskKind
  , TerminalResult (ResultCancelled, ResultCompleted, ResultFailed)
  , observeTask
  )
import Hetoimasia.Scripting.Lua.Value (Value, ValueLimits)

-- | A task's identity: the owner that issued it and the owner's own number for
-- it.
--
-- Unique within the 'Hetoimasia.Scripting.Lua.Runtime.LuaRuntime' and never
-- issued again, not after the task has settled and been observed and not after
-- its owner has retired: the owner's identity is never reissued and the task
-- numbers an owner issues never rewind. It names a task and grants nothing; it is
-- not an OS thread, a @ThreadId@ or a coroutine, and neither it nor the
-- application's name for the task is authority.
data ScheduledTaskId = ScheduledTaskId
  { taskOwner ∷ !OwnerId
  , taskLocal ∷ !TaskId
  }
  deriving (Eq, Ord, Show)

-- | The application state a task carries between segments.
data Cursor
  = -- | Admitted and not started: what the first segment runs.
    Pending !ModuleRef !Text !Payload
  | -- | Started, and suspended. Its coroutine is on the owner's thread.
    Suspended
  | -- | Finished, with what the entry point answered.
    Finished !CallResult
  | -- | An invocation of a script instance, not begun: the instance's number and what
    -- it runs.
    PendingInvocation !Word64 !Invocation
  | -- | An invocation of a script instance that began and is suspended. Its
    -- coroutine is on the owner's thread.
    HostedInvocation !Word64

-- | What one invocation of a script instance runs.
data Invocation
  = -- | The callback connected to a source, handed the event.
    InvokeEvent !Text !Payload
  | -- | A one-shot's @run@ hook.
    InvokeRun
  | -- | A periodic instance's @update@ hook, handed the logical duration granted or
    -- the elapsed time since the previous update, fixed when it begins.
    InvokeUpdate

instance NFData Invocation where
  rnf = \case
    InvokeEvent source payload → source `seq` rnf payload
    InvokeRun → ()
    InvokeUpdate → ()

instance NFData Cursor where
  rnf = \case
    Pending ref entry payload → ref `seq` entry `seq` rnf payload
    Suspended → ()
    Finished result → result `seq` ()
    PendingInvocation number invocation → number `seq` rnf invocation
    HostedInvocation number → number `seq` ()

-- | How an admitted task settled. Exactly one of these, once.
data ScheduledOutcome
  = -- | The entry point ran and answered, or is optional and absent.
    SettledReturned !CallResult
  | -- | A fault of the task, returned as data: a script error, a refused value, a
    -- call to a binding that is not yet supported, a missing entry point, a
    -- module the owner did not load. The owner went on serving its other tasks.
    SettledFaulted !CallFault
  | -- | The scheduler refused what a segment asked for (a wait for no ticks or no
    -- time, or one that cannot be represented) and failed the task, which is
    -- recoverable and not a worker failure.
    SettledRefused !TaskFailure
  | -- | Cancelled by a stop request, its coroutine closed.
    SettledCancelled
  | -- | The owner exited before the task settled.
    SettledDiscarded !Discard
  deriving (Show)

-- | What became of one admitted task, with the owner that settled it.
data ScheduledSettlement = ScheduledSettlement
  { settledOwner ∷ !OwnerId
  , settledLabel ∷ !Text
    -- ^ The application's own name for the owner.
  , settledTask ∷ !ScheduledTaskId
  , settledOutcome ∷ !ScheduledOutcome
  }
  deriving (Show)

-- | What an application admits as one task.
data TaskRequest = TaskRequest
  { requestModule ∷ !ModuleRef
    -- ^ A module the owner loaded at initialization.
  , requestEntry ∷ !Text
  , requestArguments ∷ [Value]
    -- ^ Bounded by the owner's value limits, checked on the producer's thread.
  , requestClass ∷ !ServiceClass
  , requestKind ∷ !TaskKind
  , requestName ∷ !(Maybe Text)
    -- ^ The application's readable name. No authority.
  }

-- | What the owner tells the application's own code before it runs a segment, on
-- the owner's thread. A script is not handed this: a resumed coroutine receives no
-- value. An application whose bindings should answer a script's question about
-- its tick or its granted duration keeps what it is told here where they read it.
data SegmentContext = SegmentContext
  { contextTask ∷ !ScheduledTaskId
  , contextName ∷ !(Maybe Text)
  , contextClass ∷ !ServiceClass
  , contextKind ∷ !TaskKind
  , contextSegment ∷ !Int
    -- ^ How many segments the task had run before this one.
  , contextResume ∷ !(Maybe Resume)
    -- ^ What the wait that just ended earned: the tick reached and the logical
    -- duration granted since it began, or the time elapsed.
  }
  deriving (Show)

-- | The place one ticket reads its settlement.
data Cell = Cell
  { cellTask ∷ !TaskId
  , cellOutcome ∷ !(TVar (Maybe ScheduledSettlement))
    -- ^ Written once: the first observation, or the owner's exit.
  , cellForgotten ∷ !(TVar Bool)
  }

-- | Everything one scheduled owner's two sides share.
data Control = Control
  { controlOwner ∷ !OwnerId
  , controlLabel ∷ !Text
  , controlLimits ∷ !ValueLimits
  , controlScheduler ∷ !(Scheduler Cursor)
  , controlCells ∷ !(TVar (Map TaskId Cell))
    -- ^ A cell for every ticket not yet observed: bounded by the reservations.
  , controlFaults ∷ !(TVar (Map TaskId CallFault))
    -- ^ The faults of tasks that faulted, until their results are observed.
  , controlStarted ∷ !(TVar (Set TaskId))
    -- ^ Tasks that have begun a segment.
  , controlClosing ∷ !(TVar Bool)
    -- ^ Set when the owner begins to exit by failure or cancellation, to close
    -- admission, grants and control at once, as a stop request does.
  , controlExit ∷ !(TVar (Maybe ExitRecord))
  , controlStopping ∷ !(STM Bool)
    -- ^ Whether the owner has been asked to stop, or has begun to exit.
  , controlInstances ∷ !(Maybe Instances)
    -- ^ The owner's script instances, when it hosts any.
  , controlLifecycle ∷ !(Maybe LifecycleState)
    -- ^ What the owner's lifecycle services hold, when it was granted them: the receipts of
    -- what its scripts asked, which its exit abandons.
  }

-- | Where an owner's tasks are admitted. Any thread may hold and use it.
newtype ScheduledEndpoint = ScheduledEndpoint Control

-- | Read a ticket's settlement without waiting. Reading a settlement is
-- observing it: the first read that finds the task finished takes its result and
-- gives its reservation back, and every later read answers the same settlement
-- and gives nothing back.
observeCell ∷ Control → Cell → STM (Maybe ScheduledSettlement)
observeCell control cell =
  readTVar (cellOutcome cell) >>= \case
    Just settled → pure (Just settled)
    Nothing →
      observeTask (controlScheduler control) (cellTask cell) >>= \case
        Nothing → pure Nothing
        Just terminal → do
          faults ← readTVar (controlFaults control)
          let settled = settlementOf control (cellTask cell) (Map.lookup (cellTask cell) faults) terminal
          writeTVar (cellOutcome cell) (Just settled)
          modifyTVar' (controlCells control) (Map.delete (cellTask cell))
          modifyTVar' (controlFaults control) (Map.delete (cellTask cell))
          modifyTVar' (controlStarted control) (Set.delete (cellTask cell))
          pure (Just settled)

-- | Withdraw interest in a task's result. A finished one gives its reservation
-- back now; an unfinished one when the owner next sweeps after it finishes.
forgetCell ∷ Control → Cell → STM ()
forgetCell control cell = do
  writeTVar (cellForgotten cell) True
  _ ← observeCell control cell
  pure ()

-- | Give back the reservations of forgotten tickets whose tasks have finished.
-- Answers whether it gave any back.
sweepForgotten ∷ Control → STM Bool
sweepForgotten control = do
  cells ← readTVar (controlCells control)
  mapM_
    ( \cell → do
        forgotten ← readTVar (cellForgotten cell)
        when forgotten (() <$ observeCell control cell)
    )
    (Map.elems cells)
  remaining ← readTVar (controlCells control)
  pure (Map.size remaining < Map.size cells)

settlementOf ∷ Control → TaskId → Maybe CallFault → TerminalResult Cursor → ScheduledSettlement
settlementOf control identity fault terminal =
  ScheduledSettlement
    { settledOwner = controlOwner control
    , settledLabel = controlLabel control
    , settledTask = ScheduledTaskId (controlOwner control) identity
    , settledOutcome = case terminal of
        ResultCompleted (Finished result) → SettledReturned result
        ResultCompleted _ → SettledReturned (Returned [])
        ResultCancelled → SettledCancelled
        ResultFailed failure → maybe (SettledRefused failure) SettledFaulted fault
    }

-- | The owner's exit settles every ticket not yet settled, once, and records
-- what it discarded.
--
-- A task that had finished keeps its result: it is taken from the scheduler now,
-- before the scheduler's own stop drops what is unobserved. Any other task
-- settles as discarded, with how the owner exited and whether it had begun a
-- segment. The first call writes the exit record and later ones change nothing.
settleAll ∷ Control → ExitKind → STM ()
settleAll control kind =
  readTVar (controlExit control) >>= \case
    Just _ → pure ()
    Nothing → do
      -- Nobody will read a receipt the owner's scripts held: each is abandoned, so a
      -- request still waiting gives its reservation back as it settles, and none is undone.
      traverse_ abandonAll (controlLifecycle control)
      cells ← readTVar (controlCells control)
      started ← readTVar (controlStarted control)
      counts ← forM (Map.toList cells) $ \(identity, cell) →
        readTVar (cellOutcome cell) >>= \case
          Just _ → pure (0, 0)
          Nothing →
            observeCell control cell >>= \case
              Just _ → pure (0, 0)
              Nothing → do
                let progress = if Set.member identity started then Started else NotStarted
                    discard = Discard kind progress
                writeTVar (cellOutcome cell) . Just $
                  ScheduledSettlement
                    { settledOwner = controlOwner control
                    , settledLabel = controlLabel control
                    , settledTask = ScheduledTaskId (controlOwner control) identity
                    , settledOutcome = SettledDiscarded discard
                    }
                pure (if progress == NotStarted then (1, 0) else (0, 1))
      let notStarted = sum (map fst counts) ∷ Int
          began = sum (map snd counts) ∷ Int
      writeTVar (controlExit control) . Just $
        ExitRecord (controlOwner control) (controlLabel control) kind notStarted began
