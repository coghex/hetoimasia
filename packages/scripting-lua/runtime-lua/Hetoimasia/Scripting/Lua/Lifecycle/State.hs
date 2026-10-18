-- | What an owner granted lifecycle services holds: who it may inspect and control, and
-- the receipts of the requests its scripts made.
--
-- This is a hidden module of the adapter. "Hetoimasia.Scripting.Lua.Lifecycle" is what an
-- application reads and what the bindings run over; the scheduled owner holds the
-- state ('LifecycleState') in its control, so that its exit can abandon the receipts, and
-- an instance's end can abandon its own, without the instance layer knowing what a binding
-- is. Every operation here is one STM transaction that never blocks.
--
-- = Who is the caller
--
-- The state is the owner's own and is handed to the bindings its scripts call as the
-- owner's 'Hetoimasia.Scripting.Lua.Registration.LifecycleContext', which the host
-- library delivers from the owner's configuration and not from anything a script
-- supplied. The caller's instance is the one whose Lua the owner is running
-- ('insRunning'), read on a call, and is never a field of a value a script passed.
module Hetoimasia.Scripting.Lua.Lifecycle.State
  ( -- * Authority
    Permit (..)
  , ControlRequestInfo (..)
  , AssignControl
  , Target (..)

    -- * The state
  , LifecycleState (..)
  , LuaReceipt (..)
  , Issuer (..)
  , callerOf
  , callerInstance

    -- * Receipts
  , abandonIssued
  , sweepEndedTasks
  , abandonAll
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', readTVar, readTVarIO, writeTVar)
import Control.Monad (forM_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.State (Gate, forgetReceipt)
import Hetoimasia.Scripting.Lua.Instance.Types
  ( ControlSlot
  , InstanceControl
  , InstanceControlReceipt
  , InstanceId
  , Instances (insRunning)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Runtime.Types (OwnerId)
import Hetoimasia.Scripting.Lua.Scheduler (Scheduler, TaskPhase (PhaseEnded), taskPhase)
import Hetoimasia.Scripting.Lua.Value (ValueLimits)

-- | What a grant permits of an owner it covers.
data Permit
  = -- | Reading snapshots of its instances.
    PermitInspect
  | -- | Requesting that its instances pause, resume or stop.
    PermitControl
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | What the application is told of a request when it assigns the place the request
-- takes in a logically admitting owner's input sequence: who made it and of what, all
-- of it the engine's own knowledge and none of it a value a script supplied.
data ControlRequestInfo = ControlRequestInfo
  { requestCaller ∷ !OwnerId
    -- ^ The owner whose script made the request.
  , requestCallerInstance ∷ !(Maybe InstanceId)
    -- ^ The instance whose code made it: 'Nothing' for a task.
  , requestTarget ∷ !InstanceId
  , requestOperation ∷ !InstanceControl
  }
  deriving (Eq, Show)

-- | The application's assignment of a request to a tick and a sequence (D-23): run on
-- the caller's thread, before the request is admitted, and never to block. 'Nothing'
-- refuses the request as unassigned. What it raises is a failure of the host.
type AssignControl = ControlRequestInfo → IO (Maybe ControlSlot)

-- | An owner a grant covers, resolved: what the requests and snapshots go through.
data Target = Target
  { targetOwner ∷ !OwnerId
  , targetLabel ∷ !Text
  , targetInstances ∷ !Instances
  , targetGate ∷ Gate
    -- ^ Lazy: an owner covering itself is given its own gate as it is made.
  , targetPermits ∷ !(Set Permit)
  , targetAssign ∷ !(Maybe AssignControl)
  }

-- | Who made a request, as the engine knows it and never as a script says: the instance
-- whose Lua the owner was running, or else the task it was running, or nothing it could name.
-- Each reads the receipts of its own requests and no one else's.
data Issuer
  = IssuedByInstance !Word64
  | IssuedByTask !TaskId
  | IssuedByNobody
  deriving (Eq, Show)

-- | A request's receipt, as a script holds it: the engine's receipt, and who made the
-- request, who alone may read it.
data LuaReceipt = LuaReceipt
  { luaIssuer ∷ !Issuer
  , luaReceipt ∷ !InstanceControlReceipt
  }

-- | Everything one owner's lifecycle services share: who it is, whom it may reach, and
-- the receipts of what its scripts asked.
data LifecycleState = LifecycleState
  { lifeOwner ∷ !OwnerId
  , lifeLabel ∷ !Text
  , lifeLimits ∷ !ValueLimits
    -- ^ What a result may carry: a snapshot never exceeds it.
  , lifeInstances ∷ !(Maybe Instances)
    -- ^ The caller's own instances, when it hosts any: where the instance whose code is
    -- running is read.
  , lifeTargets ∷ [Target]
    -- ^ The owners the grant covers, in the order it names them. Lazy: see 'targetGate'.
  , lifeReceiptBound ∷ !Int
    -- ^ How many receipts the owner's scripts hold at once.
  , lifeSnapshotBound ∷ !Int
    -- ^ The most instances one inspection of an owner answers.
  , lifeReceipts ∷ !(TVar (Map Word64 LuaReceipt))
    -- ^ The receipts held, by their numbers: bounded by 'lifeReceiptBound', and nothing
    -- else is kept of a request once its receipt has been read or abandoned.
  , lifeNext ∷ !(TVar Word64)
    -- ^ The next receipt number: never rewinds, so a number is never read for another
    -- request.
  , lifeTask ∷ !(TVar (Maybe TaskId))
    -- ^ The task the owner is running a segment of, set around each segment by the owner's
    -- own thread: who a call from a task that is no instance's was made by.
  , lifeClosed ∷ !(TVar Bool)
    -- ^ Set once the owner's exit has abandoned every receipt: nothing is issued after it,
    -- so no receipt outlives the abandonment that would have released it.
  }

-- | Who is calling: the instance whose code the owner is running, else the task. Never from
-- a script.
callerOf ∷ LifecycleState → IO Issuer
callerOf state = do
  instance' ← maybe (pure Nothing) (readTVarIO . insRunning) (lifeInstances state)
  case instance' of
    Just number → pure (IssuedByInstance number)
    Nothing → maybe IssuedByNobody IssuedByTask <$> readTVarIO (lifeTask state)

-- | The instance whose code the owner is running, if one.
callerInstance ∷ LifecycleState → IO (Maybe Word64)
callerInstance state =
  callerOf state <&> \case
    IssuedByInstance number → Just number
    _ → Nothing
  where
    (<&>) = flip fmap

-- | Abandon the receipts an instance holds, once it has ended: nobody can read them
-- again. Each gives its reservation back as it settles, or now if it has; no request is
-- undone.
abandonIssued ∷ LifecycleState → Word64 → STM ()
abandonIssued state number = do
  held ← readTVar (lifeReceipts state)
  let (mine, rest) = Map.partition ((== IssuedByInstance number) . luaIssuer) held
  forM_ mine (forgetReceipt . luaReceipt)
  writeTVar (lifeReceipts state) rest

-- | Abandon the receipts of the tasks that have ended or that the scheduler no longer knows:
-- nobody can read them again, and a long-lived owner's short-lived tasks would otherwise fill
-- the table. Answers whether it abandoned any.
sweepEndedTasks ∷ Scheduler v → LifecycleState → STM Bool
sweepEndedTasks scheduler state = do
  held ← readTVar (lifeReceipts state)
  gone ← fmap concat . traverse (\(number, receipt) → ended number receipt) $ Map.toList held
  forM_ gone $ \(_, receipt) → forgetReceipt (luaReceipt receipt)
  writeTVar (lifeReceipts state) (foldr (Map.delete . fst) held gone)
  pure (not (null gone))
  where
    ended number receipt = case luaIssuer receipt of
      IssuedByTask task →
        taskPhase scheduler task <&> \case
          Nothing → [(number, receipt)]
          Just (PhaseEnded _) → [(number, receipt)]
          Just _ → []
      _ → pure []
    (<&>) = flip fmap

-- | Abandon every receipt: the owner is exiting, and its scripts will read none. Taken
-- out of the table in the transaction that abandons them, so each is abandoned once.
abandonAll ∷ LifecycleState → STM ()
abandonAll state = do
  writeTVar (lifeClosed state) True
  held ← readTVar (lifeReceipts state)
  forM_ held (forgetReceipt . luaReceipt)
  modifyTVar' (lifeReceipts state) (const Map.empty)
