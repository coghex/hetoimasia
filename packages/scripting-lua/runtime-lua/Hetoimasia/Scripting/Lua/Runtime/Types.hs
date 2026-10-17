-- | What the runtime adapter's owners, calls and settlements are made of.
--
-- Nothing here runs Lua or touches a worker. It is the vocabulary
-- "Hetoimasia.Scripting.Lua.Runtime" speaks in and the state its two sides
-- share: the application's callers, who submit calls and read what they
-- settled as, and the owner's thread, which runs the calls and settles them.
module Hetoimasia.Scripting.Lua.Runtime.Types
  ( -- * Identity
    OwnerId (..)
  , ownerSequence

    -- * Bounds
  , CallBounds (..)
  , BoundViolation (..)
  , OwnerBoundsRefused (..)

    -- * What a call settles as
  , Settlement (..)
  , Outcome (..)
  , CallFault (..)
  , callFaultEffect
  , Discard (..)
  , ExitKind (..)
  , Progress (..)
  , ExitRecord (..)

    -- * Refusals
  , CallbackWaitRefused (..)

    -- * Shared state
  , Payload (..)
  , QueuedCall (..)
  , Slot (..)
  , Phase (..)
  , Control (..)
  ) where

import Control.Concurrent.STM (STM, TVar)
import Control.DeepSeq (NFData (rnf))
import Control.Exception (Exception)
import Data.Text (Text)
import Data.Unique (Unique, hashUnique)
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Channel (ChannelControl)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault
  , CallResult
  , Effect (LuaRan, NoEffect)
  , LuaFault
  , ModuleRef
  , boundaryEffect
  )
import Hetoimasia.Scripting.Lua.Value (Value (..), ValueLimits, ValueRule)

-- | A number that names one owner among those one runtime boundary created.
--
-- Issued once, in order, and never again: not after the owner it named has
-- stopped, failed or been retired. It is unique within the 'LuaRuntime' that
-- issued it, and two runtimes never issue equal ones. It names an owner and
-- grants nothing: authority is exactly the policy the owner was configured
-- with, and neither this number nor the application's label for the owner
-- changes it.
data OwnerId = OwnerId !Unique !Word64
  deriving (Eq, Ord)

instance Show OwnerId where
  show (OwnerId scope number) = "owner " <> show number <> " of runtime " <> show (hashUnique scope)

-- | The position of an owner among those its runtime issued, from 1.
ownerSequence ∷ OwnerId → Word64
ownerSequence (OwnerId _ number) = number

-- | The two bounds an owner is configured with, both at least one.
data CallBounds = CallBounds
  { boundQueuedCalls ∷ !Int
    -- ^ How many accepted calls may wait for the owner's thread to start them.
  , boundResults ∷ !Int
    -- ^ How many results may be reserved at once: a reservation is taken when a
    -- call is accepted and held while it waits, runs, and sits settled but not
    -- yet observed.
  }
  deriving (Eq, Show)

-- | A bound that is below one.
data BoundViolation
  = QueuedCallsBelowOne !Int
  | ResultsBelowOne !Int
  deriving (Eq, Show)

-- | A configuration's bounds were refused, and nothing was started: no worker
-- and no VM. Every violation, not the first.
newtype OwnerBoundsRefused = OwnerBoundsRefused [BoundViolation]
  deriving (Eq, Show)

instance Exception OwnerBoundsRefused

-- | What became of one accepted call, with the owner that settled it.
data Settlement = Settlement
  { settledOwner ∷ !OwnerId
  , settledLabel ∷ !Text
    -- ^ The application's own name for the owner ('Hetoimasia.Scripting.Lua.Owner.vmOwnerName').
  , settledOutcome ∷ !Outcome
  }
  deriving (Show)

-- | How a call settled. Exactly one of these, once.
data Outcome
  = -- | The entry point ran and answered, or is optional and absent.
    CallReturned !CallResult
  | -- | The call failed across the boundary, and the owner went on.
    CallFaulted !CallFault
  | -- | The owner exited before the call settled.
    CallDiscarded !Discard
  deriving (Show)

-- | A failure of a call that is the call's own, handed to its caller as data.
--
-- A failure raised by the application's own code (a binding's action, its
-- liveness check) is never one of these, whatever its type: it is a failure of
-- the host and goes to supervision.
data CallFault
  = BoundaryFailed !BoundaryFault
    -- ^ A refused value, a script error, a call to a binding that is not yet
    -- supported, an entry point that is gone.
  | LuaFailed !LuaFault
  | -- | The owner loaded no module with this identity. Nothing ran.
    ModuleNotLoaded !ModuleRef
  deriving (Show)

-- | Whether anything had happened by the time of the fault.
callFaultEffect ∷ CallFault → Effect
callFaultEffect = \case
  BoundaryFailed fault → boundaryEffect fault
  LuaFailed _ → LuaRan
  ModuleNotLoaded _ → NoEffect

-- | How the owner exited, and whether the discarded call had started.
--
-- A call that had started may have run Lua and application bindings, so
-- application state may have changed; a discard never says otherwise. Only a
-- call that never started is known to have done nothing.
data Discard = Discard
  { discardExit ∷ !ExitKind
  , discardProgress ∷ !Progress
  }
  deriving (Eq, Show)

-- | How an owner's lifetime ended, as far as its calls are concerned.
data ExitKind
  = -- | It was asked to stop and did.
    ExitStopped
  | -- | Something other than a call's own fault ended it: a failure of the
    -- application's code, or of the owner itself.
    ExitFailed
  | -- | It was cancelled.
    ExitCancelled
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | Whether a discarded call had started.
data Progress
  = NotStarted
  | -- | The in-flight call when the owner exited.
    Started
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | What an owner's exit discarded, apart from the worker's cleanup evidence,
-- which supervision carries.
data ExitRecord = ExitRecord
  { exitOwner ∷ !OwnerId
  , exitLabel ∷ !Text
  , exitKind ∷ !ExitKind
  , exitNotStarted ∷ !Int
    -- ^ Queued calls discarded without having started.
  , exitStarted ∷ !Int
    -- ^ In-flight calls discarded: none or one.
  }
  deriving (Eq, Show)

-- | A wait for a reply was asked from a thread that is running a Lua callback.
--
-- Raised at once, when the wait executes: it never blocks. A binding or any
-- other callback may submit a call to any owner, since submitting never
-- waits, but waiting for a reply from inside one is a synchronous call into
-- another owner's thread, or into its own, which can deadlock.
newtype CallbackWaitRefused = CallbackWaitRefused
  { refusedOperation ∷ Text
    -- ^ The operation that was refused.
  }
  deriving (Eq, Show)

instance Exception CallbackWaitRefused

-- | What a call carries to the owner, prepared on the producer's thread.
data Payload
  = -- | Arguments fully evaluated and within the owner's value limits.
    WithinBounds ![Value]
  | -- | Arguments that were over the owner's limits. They were not kept: only
    -- the rule they broke is, and the owner settles the call with the fault the
    -- argument check would have raised, without running anything.
    OverBound !ValueRule

instance NFData Payload where
  rnf (WithinBounds values) = rnfValues values
  rnf (OverBound rule) = rule `seq` ()

rnfValues ∷ [Value] → ()
rnfValues = foldr (\value rest → rnfValue value `seq` rest) ()

rnfValue ∷ Value → ()
rnfValue = \case
  VList items → rnfValues items
  VRecord entries → foldr (\(name, value) rest → name `seq` rnfValue value `seq` rest) () entries
  value → value `seq` ()

-- | One accepted call as the owner's queue holds it.
data QueuedCall = QueuedCall
  { queuedModule ∷ !ModuleRef
  , queuedEntry ∷ !Text
  , queuedPayload ∷ !(Prepared Payload)
  , queuedSlot ∷ !Slot
  }

-- | Everything it holds is prepared already, so preparing the queue entry
-- evaluates nothing the producer did not.
instance NFData QueuedCall where
  rnf (QueuedCall ref entry payload slot) = ref `seq` entry `seq` payload `seq` slot `seq` ()

-- | The place a call's settlement is written, once, and read by its caller.
data Slot = Slot
  { slotSettlement ∷ !(TVar (Maybe Settlement))
  , slotReleased ∷ !(TVar Bool)
    -- ^ Whether the reservation this slot holds has been given back. Written
    -- once, by whichever observation or abandonment comes first.
  , slotForgotten ∷ !(TVar Bool)
    -- ^ Whether the caller gave up its interest.
  }

-- | Whether an owner admits calls.
data Phase
  = -- | Constructed, not ready: nothing is admitted and nobody holds an endpoint.
    Opening
  | Admitting
  | -- | Ended. Terminal.
    Shut
  deriving (Eq, Show)

-- | The admission state of one owner: what the endpoint and the owner's thread
-- share.
data Control = Control
  { controlOwner ∷ !OwnerId
  , controlLabel ∷ !Text
  , controlLimits ∷ !ValueLimits
  , controlBounds ∷ !CallBounds
  , controlPhase ∷ !(TVar Phase)
  , controlStopping ∷ !(STM Bool)
    -- ^ Whether the owner's worker has been asked to stop or cancel. Read by
    -- admission, so that a request closes admission at once, even while the
    -- owner's thread is held inside a call and cannot act on it yet.
  , controlChannel ∷ !(ChannelControl QueuedCall)
  , controlOutstanding ∷ !(TVar Int)
    -- ^ Reservations held: accepted calls whose result has not been observed.
  , controlInflight ∷ !(TVar (Maybe QueuedCall))
    -- ^ The call the owner's thread has taken and not yet settled.
  , controlExit ∷ !(TVar (Maybe ExitRecord))
  }
