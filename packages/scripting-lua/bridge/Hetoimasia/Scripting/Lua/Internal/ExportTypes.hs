-- | What the opt-in export-module facility is made of: identities, limits,
-- opaque references and the record an owner keeps. See
-- "Hetoimasia.Scripting.Lua.Internal.Export" for the operations and the contract.
--
-- Nothing here runs Lua. The references are values that name a slot of one VM's
-- registry tables: Lua never sees one, and every use checks the VM that issued
-- it and that the slot is still live.
module Hetoimasia.Scripting.Lua.Internal.ExportTypes
  ( -- * Identities and limits
    ExportIdentity (..)
  , maxExportIdentityBytes
  , ExportLimits (..)
  , defaultExportLimits
  , ExportSource (..)
    -- * References
  , ExportHandle (..)
  , CaptureHandle (..)
  , Hook (..)
  , hookIndex
  , hookName
    -- * Outcomes
  , ExportOutcome (..)
  , ExportRecord (..)
  , ExportState (..)
  , newExportState
    -- * Facades
  , FacadeSource (..)
    -- * Behaviors
  , CadenceField (..)
  , BehaviorShape (..)
  , BehaviorProblem (..)
  , Captured (..)
  ) where

import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Internal.Boundary (BoundaryFault)
import Hetoimasia.Scripting.Lua.Internal.Value (Value, VmIdentity)

-- | The stable identity an export module is known by within one VM: opaque
-- bytes the caller chose, compared exactly. It is never truncated, hashed or
-- squeezed into a module's name and version, so two distinct supplied identities
-- are two keys however long they share a prefix. It is bounded only by
-- 'maxExportIdentityBytes', and one past that is refused, not shortened.
newtype ExportIdentity = ExportIdentity ByteString
  deriving (Eq, Ord, Show)

-- | An identity is at most this many bytes. A bound that refuses, so that no
-- number of identities makes a record grow without limit.
maxExportIdentityBytes ∷ Int
maxExportIdentityBytes = 4096

-- | The ceilings an owner holds its export modules to: the source a new
-- evaluation may be given, and the identities the owner may hold, failed ones
-- and any in progress included. Both are at least one.
data ExportLimits = ExportLimits
  { exportMaxSourceBytes ∷ !Int
  , exportMaxIdentities ∷ !Int
  }
  deriving (Eq, Show)

-- | One mebibyte of source and 256 identities: the M1 profile's values.
defaultExportLimits ∷ ExportLimits
defaultExportLimits = ExportLimits 1048576 256

-- | An export module as the application supplies it.
data ExportSource = ExportSource
  { exportIdentity ∷ !ExportIdentity
  , exportLabel ∷ !Text
    -- ^ How the module is named in a diagnostic and as its chunk. Bounded
    -- separately from the identity, and cut down for a reader: it is no key.
  , exportText ∷ !ByteString
    -- ^ Lua source text. A precompiled chunk is refused. Not kept after the
    -- evaluation.
  }

-- | A retained export table, known by the VM that issued it and its slot there.
-- A value, not authority: it names a slot of one VM and every use checks that
-- VM.
data ExportHandle = ExportHandle
  { exportHandleVm ∷ !VmIdentity
  , exportHandleSlot ∷ !Int
  , exportHandleIdentity ∷ !ExportIdentity
  }
  deriving (Eq, Show)

-- | A behavior an instance captured: its hook functions, its @self@ and its
-- facade, held by the VM. A value that names a slot of one VM, like the others.
data CaptureHandle = CaptureHandle
  { captureHandleVm ∷ !VmIdentity
  , captureHandleSlot ∷ !Int
  }
  deriving (Eq, Show)

-- | A hook of a behavior.
data Hook = HookInit | HookUpdate | HookShutdown
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The position the C side numbers a hook by.
hookIndex ∷ Hook → Int
hookIndex = fromEnum

-- | The field a hook is in a behavior table.
hookName ∷ Hook → Text
hookName = \case
  HookInit → "init"
  HookUpdate → "update"
  HookShutdown → "shutdown"

-- | What evaluating, or retrieving, an export module answers.
data ExportOutcome
  = -- | The module's export table, held by the VM. The same one every time.
    ExportReady !ExportHandle
  | -- | The identity failed, stickily: evaluating its top level, what it
    -- returned, or its source being past the limit. Exposes no value; the fault
    -- is the first one and is never replaced.
    ExportFailed !BoundaryFault
  deriving (Eq, Show)

-- | What an owner keeps for one identity.
data ExportRecord
  = -- | Being evaluated. Counted against the limit.
    ExportEvaluating
  | ExportHeld !Int
  | ExportBroken !BoundaryFault
  deriving (Eq, Show)

-- | What an owner keeps for its export modules and the behaviors captured from
-- them: one record per identity, never evicted, and the live captures.
data ExportState = ExportState
  { exportLimits ∷ !ExportLimits
  , exportRecords ∷ !(IORef (Map ExportIdentity ExportRecord))
  , exportCaptures ∷ !(IORef (Set Int))
  }

newExportState ∷ ExportLimits → IO ExportState
newExportState limits = ExportState limits <$> newIORef Map.empty <*> newIORef Set.empty

-- | Where a capture's facade comes from: the narrow seam through which the later
-- entry adapter injects the instance-bound services without this facility knowing
-- any of them. Whatever it names becomes the capture's @api@ and @self.api@, the
-- same Lua value, and is an ordinary Lua table in Lua's hands.
data FacadeSource
  = -- | A copy of this value, made fresh for this capture, within the owner's value
    -- limits. Data only: it cannot carry a function or a retained table.
    FacadeValue !Value
  | -- | The table a retained export module holds under this field, used as it is: an
    -- existing facade reference, shared by every capture that names it.
    FacadeField !ExportHandle !Text
  | -- | Built for this capture alone by calling the function a retained export module
    -- holds under this field with a copy of this value (the instance's context),
    -- which returns the facade table. This is how a facade carries closures bound to
    -- its instance. The function is the engine's own, run only after the behavior has
    -- validated and been captured, and what it raises or returns that is no table
    -- fails the capture, releasing it.
    FacadeBuilt !ExportHandle !Text !Value
  deriving (Eq, Show)

-- | How a cadence field of a behavior read, with no conversion applied: the
-- application decides what it accepts.
data CadenceField
  = FieldAbsent
  | FieldInteger !Int64
  | FieldFloat !Double
  | -- | Present and not a number: the Lua type's name.
    FieldOther !Text
  deriving (Eq, Show)

-- | What a validated behavior table holds: which hooks it has, and its cadence
-- fields as they read.
data BehaviorShape = BehaviorShape
  { shapeInit ∷ !Bool
  , shapeUpdate ∷ !Bool
  , shapeShutdown ∷ !Bool
  , shapeEveryTicks ∷ !CadenceField
  , shapeEverySeconds ∷ !CadenceField
  }
  deriving (Eq, Show)

-- | Why a selected behavior was refused. None of these is a failure of the
-- module that holds it: a module with an invalid role it does not select is a
-- valid module.
data BehaviorProblem
  = -- | The export table the handle names is not held.
    BehaviorNoExport
  | -- | The selected field is absent.
    BehaviorMissing
  | -- | The selected field is not a table: its Lua type.
    BehaviorNotTable !Text
  | BehaviorHasMetatable
  | -- | A key that is not text: its Lua type.
    BehaviorNonTextKey !Text
  | -- | A key outside the schema: one of them, bounded.
    BehaviorUnknownKey !ByteString
  | -- | A hook that is neither absent nor a function: the hook and its Lua type.
    BehaviorHookNotFunction !Hook !Text
  deriving (Eq, Show)

-- | A behavior captured: the handle that holds it, and what it read as.
data Captured = Captured
  { capturedHandle ∷ !CaptureHandle
  , capturedShape ∷ !BehaviorShape
  }
  deriving (Eq, Show)
