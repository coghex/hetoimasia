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
