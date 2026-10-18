-- | What an owner's value boundary is made of, and the fault it reports.
--
-- 'Boundary' is the part of an owner's configuration the marshalling needs once
-- the VM exists: the registration, the limits, the owner's name, and the
-- identity the VM was given, from which the context values are checked in is
-- made.
--
-- 'BoundaryFault' is the typed failure of a load or a call across the boundary
-- (P-4, P-8). It is an ordinary Haskell exception, produced with no Lua run to
-- render it, and it records:
--
-- * the owner, by the name it was configured with and the VM's identity;
-- * the operation that failed, and the module and entry point or the binding
--   (namespace and name) it concerns;
-- * the source chunk, and a bounded traceback when one was captured;
-- * why, as a typed reason; and
-- * whether anything had happened: a refusal made before any Lua or binding
--   action ran is 'NoEffect', a failure after Lua had run is 'LuaRan', and one
--   after a binding's action had run is 'BindingRan', which means state may have
--   been mutated. A fault never claims that recovery is safe; task and session
--   identities arrive with later slices.
module Hetoimasia.Scripting.Lua.Internal.Boundary
  ( Boundary (..)
  , boundaryContext
  , ModuleRef (..)
  , moduleChunk
  , BoundaryFault (..)
  , FaultOperation (..)
  , FaultReason (..)
  , Effect (..)
  , ModuleProblem (..)
  , TaskEnd (..)
  , TaskProblem (..)
  , SuspendRefusal (..)
  , blankFault
  ) where

import Control.Exception (Exception)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Internal.Fault (ErrorValue, FaultKind)
import Hetoimasia.Scripting.Lua.Internal.Registration
  ( BindingKind
  , Registration
  , capabilityNameOf
  , capabilityNumber
  )
import Hetoimasia.Scripting.Lua.Internal.Value
  ( Context (..)
  , ValueLimits
  , ValueRefusal
  , VmIdentity
  )

-- | The value boundary of one owner.
data Boundary = Boundary
  { boundaryOwnerName ∷ !Text
    -- ^ How the owner is named in a fault; chosen by the application.
  , boundaryVmIdentity ∷ !VmIdentity
  , boundaryRegistration ∷ Registration
  , boundaryLimits ∷ !ValueLimits
  }

-- | What checking a value needs of this owner.
boundaryContext ∷ Boundary → Context
boundaryContext boundary =
  Context
    { contextVm = boundaryVmIdentity boundary
    , contextTypeName = capabilityNameOf (boundaryRegistration boundary)
    , contextTypeNumber = capabilityNumber (boundaryRegistration boundary)
    }

-- | A module's identity: its name and its version.
data ModuleRef = ModuleRef
  { moduleRefName ∷ !Text
  , moduleRefVersion ∷ !Text
  }
  deriving (Eq, Ord, Show)

-- | The chunk name a module is loaded under, for a reader and nothing more:
-- control characters are replaced so it can never rewrite a diagnostic.
moduleChunk ∷ ModuleRef → Text
moduleChunk ref = Text.map tame (moduleRefName ref <> "@" <> moduleRefVersion ref)
  where
    tame character
      | character < ' ' || character == '\DEL' || character == '\0' = '.'
      | otherwise = character

-- | What was being done when the fault happened.
data FaultOperation
  = -- | Installing the registration's bindings in the VM.
    InstallBindings
  | LoadModule
  | CallEntry
  | -- | A Lua call to a registered binding.
    CallBinding
  | -- | Starting a task: running a module's entry point as a coroutine, up to
    -- its first yield, wait or return.
    StartTask
  | -- | Running the next segment of a task.
    ResumeTask
  | -- | Closing a suspended task.
    CloseTask
  deriving (Eq, Show)

-- | Whether anything had happened by the time of the fault.
data Effect
  = -- | Refused before any Lua or binding action ran.
    NoEffect
  | -- | Lua had run; no binding action had.
    LuaRan
  | -- | A binding's action had run: state may have been mutated.
    BindingRan
  deriving (Eq, Ord, Show)

-- | A module load that was refused before it ran.
data ModuleProblem
  = -- | An identity the owner already holds.
    DuplicateModule
  | -- | A name or version that is empty, too long or has a control character.
    InvalidModuleIdentity
  | -- | More modules than an owner may hold: the bound.
    TooManyModules !Int
  | -- | A source over the bound, in bytes: the bound.
    SourceTooLarge !Int
  | -- | An entry point name that is not a valid name.
    InvalidEntryName !Text
  | -- | An entry point declared twice.
    DuplicateEntry !Text
  | -- | More entry points than a module may declare: the bound.
    TooManyEntries !Int
  | -- | An entry point declares more arguments or results than the bound.
    EntryArityTooLarge !Text !Int
  | -- | An entry point's schema nests too deep, is too wide, repeats a field or
    -- names a capability type the registration does not declare.
    EntrySchemaRefused !Text
  | -- | A handle that another owner issued.
    ModuleHandleForeign
  | -- | An entry point the module did not declare.
    EntryUndeclared !Text
  deriving (Eq, Show)

-- | How a task ended, once it is not resumable any more.
data TaskEnd
  = -- | Its entry point returned.
    TaskCompleted
  | -- | A segment of it failed. The host closed the coroutine, running its pending
    -- to-be-closed variables, so nothing of it is left.
    TaskFaulted
  | -- | It was closed.
    TaskClosed
  deriving (Eq, Show)

-- | What is wrong with a task handle an operation was given.
data TaskProblem
  = -- | A handle another owner issued.
    TaskForeign
  | -- | A task that has ended and cannot be resumed.
    TaskEnded !TaskEnd
  | -- | A task whose coroutine is not suspended where the host left it: a script
    -- resumed or closed the thread it was running on.
    TaskNotSuspended
  deriving (Eq, Show)

-- | Why a scheduler operation (a yield or a wait) a script called was refused.
--
-- A script can call one from many places; only a call made by the task's own
-- coroutine, while the host is running that task and where Lua could suspend it,
-- reaches the scheduler. Everywhere else it is refused, so it can never suspend
-- something the host is not resuming.
data SuspendRefusal
  = -- | The host is not running a task of this owner: an entry point called
    -- once, an initial chunk, a module load, a finalizer, a close.
    SuspendOutsideTask
  | -- | A task is running, and this is a coroutine its script created.
    SuspendOtherCoroutine
  | -- | The task's own coroutine, but Lua cannot suspend it here: inside a
    -- metamethod, a finalizer, or a library function that calls back.
    SuspendNotYieldable
  deriving (Eq, Show)

-- | Why a call or load across the boundary failed.
data FaultReason
  = -- | A value was refused at the boundary: before the binding ran for an
    -- argument, after it for a result.
    ValueRefused !ValueRefusal
  | -- | A module or entry point was refused before it ran.
    ModuleRefused !ModuleProblem
  | -- | A required entry point was not defined by the module. Whether it was
    -- present as something else is the flag.
    EntryMissing !Bool
  | -- | An entry point is present and is not a function.
    EntryNotAFunction
  | -- | A call to a binding of a kind this slice does not deliver (decision A1).
    NotYetSupported !BindingKind
  | -- | The engine refused the call from inside a binding's action, through its
    -- own API ('Hetoimasia.Scripting.Lua.Internal.Fault.CallRefusal'), before the
    -- action changed anything: why. A fault of the call, never a failure of the
    -- host, whatever the script does with the error it sees.
    BindingRefused !Text
  | -- | A task handle was refused before anything ran.
    TaskRefused !TaskProblem
  | -- | A scheduler operation called where it cannot reach the scheduler.
    SuspendRefused !SuspendRefusal
  | -- | A task's coroutine yielded without a granted scheduler operation: the
    -- script called @coroutine.yield@ itself, which would suspend it to no one.
    UnscheduledYield
  | -- | A script raised an error, or its chunk was rejected, or Lua could not
    -- allocate: Lua's own classification, and the error value rendered under a
    -- bound.
    ScriptFailed !FaultKind !ErrorValue
  | -- | An owner's policy names a namespace the registration does not declare.
    PolicyUnknownNamespace !Text
  | -- | A namespace's name is already a global that is not a table.
    NamespaceTaken !Text
  | -- | The boundary failed in a way only a bug explains: what happened.
    InternalError !Text
  deriving (Eq, Show)

-- | A load or a call across the boundary failed.
data BoundaryFault = BoundaryFault
  { boundaryOwner ∷ !Text
  , boundaryVm ∷ !VmIdentity
  , boundaryOperation ∷ !FaultOperation
  , boundaryModule ∷ !(Maybe ModuleRef)
  , boundaryEntry ∷ !(Maybe Text)
  , boundaryBinding ∷ !(Maybe (Text, Text))
    -- ^ Namespace and name.
  , boundaryChunk ∷ !Text
    -- ^ The source chunk the failing operation names.
  , boundaryReason ∷ !FaultReason
  , boundaryEffect ∷ !Effect
  , boundaryTraceback ∷ !(Maybe Text)
    -- ^ A bounded traceback, when one was captured.
  }
  deriving (Eq, Show)

instance Exception BoundaryFault

-- | A fault of this owner and operation, with nothing else known yet.
blankFault ∷ Boundary → FaultOperation → FaultReason → BoundaryFault
blankFault boundary operation reason =
  BoundaryFault
    { boundaryOwner = boundaryOwnerName boundary
    , boundaryVm = boundaryVmIdentity boundary
    , boundaryOperation = operation
    , boundaryModule = Nothing
    , boundaryEntry = Nothing
    , boundaryBinding = Nothing
    , boundaryChunk = ""
    , boundaryReason = reason
    , boundaryEffect = NoEffect
    , boundaryTraceback = Nothing
    }
