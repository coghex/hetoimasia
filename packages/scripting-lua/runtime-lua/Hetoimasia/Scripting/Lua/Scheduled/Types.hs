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
  , Accounting (..)
  , newAccounting
  , watchAccounting
  , unwatchAccounting
  , accountingFailed
  , sealAccounting
  , accountingReady
  , endingBegun
  , endingAccounted
  , ScheduledEndpoint (..)
  , observeCell
  , forgetCell
  , sweepForgotten
  , settleAll
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', readTVar, retry, writeTVar)
import Control.DeepSeq (NFData (rnf))
import Control.Monad (forM, when)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.Types (Instances, ModuleHooks)
import Hetoimasia.Scripting.Lua.Lifecycle.State (LifecycleState, abandonAll, sweepEndedTasks)
import Hetoimasia.Scripting.Lua.Provider.Types (ProviderState)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (SubscriptionId, TaskId)
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
  , grantsAccepted
  , grantsFinished
  , retainsEvidence
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
  | -- | The callback subscribed to a provider's event endpoint, handed the delivery: the
    -- endpoint and the subscription. The delivery itself is taken from the subscription as the
    -- first segment is about to run, so until then it is still the subscription's, and
    -- replaceable state can replace it.
    InvokeSubscription !Text !SubscriptionId

instance NFData Invocation where
  rnf = \case
    InvokeEvent source payload → source `seq` rnf payload
    InvokeRun → ()
    InvokeUpdate → ()
    InvokeSubscription endpoint identity → endpoint `seq` identity `seq` ()

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
  , controlProvider ∷ !(Maybe ProviderState)
    -- ^ What the owner's request service holds, when it was granted one: its requests, and the
    -- accounting of its providers' work, which its exit revokes and awaits.
  , controlHooks ∷ !(TVar (Map ModuleRef ModuleHooks))
    -- ^ The hooks each module the owner loaded defines, written once, in the transaction that
    -- publishes readiness, and never changed after it.
  , controlAccounting ∷ !(TVar Accounting)
    -- ^ What the accounting wait ('Hetoimasia.Scripting.Lua.Scheduled.awaitScheduledAccounting')
    -- reads and the owner's thread writes: a constant amount of state, whatever number of waits
    -- were made, and one entry for each instance ending begun and not yet accounted for, which
    -- the instances' own bound limits.
  }

-- | The accounting the owner keeps for the application's wait for it.
--
-- Nothing here is a slot, a ticket or a reservation, and none of it is per wait: the one
-- wait the application thread has pending registers a watch, the owner's thread latches it
-- at the end of the boundary that finished the watched grants, and the wait clears it as it
-- ends, however it ends.
data Accounting = Accounting
  { acWatch ∷ !(Maybe Word64)
    -- ^ The number of grants the pending wait captured: every grant numbered below it must
    -- have finished.
  , acCut ∷ !(Maybe Word64)
    -- ^ Written once for a watch: how many instance endings had begun when the boundary that
    -- finished the watched grants ended, or, for a watch whose grants had finished at a boundary
    -- that had already ended, when it was taken. Every ending numbered up to it is the wait's.
  , acTainted ∷ !Bool
    -- ^ Set, for good, by the owner when the owner holds cleanup evidence that will end it as a
    -- failure (the failure of a close, a release, a settlement) at a point where it could have
    -- accounted for an ending or sealed a boundary: from then on it is exiting, and the wait
    -- neither completes nor ends until it has ended and supervision has handled the outcome.
  , acSealed ∷ !Word64
    -- ^ How many grants had finished when the owner's last boundary ended. Grants finish only
    -- inside a boundary, so a watch whose grants number no more than this is for a boundary
    -- that has ended already.
  , acBegun ∷ !Word64
    -- ^ How many instance endings have begun. Never rewinds.
  , acOpen ∷ !(Map Word64 Word64)
    -- ^ The endings begun and not yet accounted for, by instance number: the ending's number
    -- among those begun. An ending is accounted for once its shutdown has run or been skipped,
    -- what it held is drained, every retirement it owed is complete, it has settled and, if it
    -- failed, the application's escalation has been called and has returned.
  }

-- | An owner's accounting before anything has begun.
newAccounting ∷ Accounting
newAccounting = Accounting Nothing Nothing False 0 0 Map.empty

-- | Take the wait's snapshot: how many grants have been accepted, committed in this one
-- transaction, and watch for them. Replaces any earlier watch, which the application's one
-- wait at a time has already cleared.
--
-- If a boundary has ended since the last of those grants finished, the boundary the wait is
-- for is over, and the watch is latched at once: the endings that have begun are the wait's.
-- Otherwise the owner latches it when the boundary that finishes them ends.
watchAccounting ∷ Control → STM ()
watchAccounting control = do
  captured ← grantsAccepted (controlScheduler control)
  modifyTVar' (controlAccounting control) $ \accounting →
    accounting
      { acWatch = Just captured
      , acCut = if acSealed accounting >= captured then Just (acBegun accounting) else Nothing
      }

-- | The owner has caught a failure that will end it, one it raises only after it has settled
-- the others it was settling: from here the accounting is not a success, whichever ending
-- it accounts for next.
accountingFailed ∷ Control → STM ()
accountingFailed control =
  modifyTVar' (controlAccounting control) (\accounting → accounting {acTainted = True})

-- | Clear the watch, whether it was latched or not, as the wait ends.
unwatchAccounting ∷ Control → STM ()
unwatchAccounting control =
  modifyTVar' (controlAccounting control) (\accounting → accounting {acWatch = Nothing, acCut = Nothing})

-- | At the end of a boundary, on the owner's thread: note how many grants have finished and,
-- if that finishes every grant a watch captured, latch it, fixing which endings are its own:
-- those begun by now. Writes nothing when neither changed.
--
-- The flag says whether the owner holds cleanup evidence of its own, beside what the
-- scheduler retains: either will end the owner as a failure, so the accounting is not a
-- success from here on.
sealAccounting ∷ Control → Bool → STM ()
sealAccounting control held = do
  finished ← grantsFinished (controlScheduler control)
  retained ← retainsEvidence (controlScheduler control)
  accounting ← readTVar (controlAccounting control)
  let latched = case (acWatch accounting, acCut accounting) of
        (Just captured, Nothing) | finished >= captured → Just (acBegun accounting)
        _ → acCut accounting
      tainted = acTainted accounting || held || retained
  when (finished /= acSealed accounting || latched /= acCut accounting || tainted /= acTainted accounting) $
    writeTVar (controlAccounting control) accounting {acSealed = finished, acCut = latched, acTainted = tainted}

-- | Whether the latched watch's grants have finished, the boundary has ended, and every
-- ending it covers has been accounted for. Retries until then.
accountingReady ∷ Control → STM ()
accountingReady control = do
  accounting ← readTVar (controlAccounting control)
  when (acTainted accounting) retry
  case acCut accounting of
    Nothing → retry
    Just cut → when (any (<= cut) (Map.elems (acOpen accounting))) retry

-- | An instance's ending has begun. In the transaction that begins it.
endingBegun ∷ Control → Word64 → STM ()
endingBegun control instance' =
  modifyTVar' (controlAccounting control) $ \accounting →
    let number = acBegun accounting + 1
     in accounting {acBegun = number, acOpen = Map.insert instance' number (acOpen accounting)}

-- | An instance's ending has been accounted for. The flag says whether the owner holds
-- cleanup evidence of its own, as for 'sealAccounting'.
endingAccounted ∷ Control → Word64 → Bool → STM ()
endingAccounted control instance' held = do
  retained ← retainsEvidence (controlScheduler control)
  modifyTVar' (controlAccounting control) $ \accounting →
    accounting
      { acOpen = Map.delete instance' (acOpen accounting)
      , acTainted = acTainted accounting || held || retained
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
  -- The receipts of the tasks that ended are abandoned here, as the tickets of forgotten
  -- tasks are given back: on the owner's own thread, as it accounts for what ended.
  lifecycle ← maybe (pure False) (sweepEndedTasks (controlScheduler control)) (controlLifecycle control)
  cells ← readTVar (controlCells control)
  mapM_
    ( \cell → do
        forgotten ← readTVar (cellForgotten cell)
        when forgotten (() <$ observeCell control cell)
    )
    (Map.elems cells)
  remaining ← readTVar (controlCells control)
  pure (lifecycle || Map.size remaining < Map.size cells)

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
