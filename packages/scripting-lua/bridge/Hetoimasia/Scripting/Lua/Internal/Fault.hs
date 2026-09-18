-- | What a fault on Lua's side of the boundary reports, and the bound on how
-- much of it is reported.
--
-- A Lua error value is arbitrary: a string, a number, a table, a userdata, or a
-- value whose @__tostring@ metamethod is itself arbitrary Lua. Rendering it is
-- therefore a bounded, metamethod-free operation. A string or a number is read
-- through @lua_tolstring@, which converts neither through a metamethod, and
-- truncated at 'diagnosticLimit' bytes; anything else is reported by its type
-- name and its address alone. No further Lua runs to produce a diagnostic, so a
-- failing chunk cannot keep executing through the report of its own failure.
--
-- Nothing here holds a Lua state, a stack index, or a registry reference: a
-- fault outlives the call that raised it, and the VM it came from may already
-- be closed when it is inspected.
module Hetoimasia.Scripting.Lua.Internal.Fault
  ( -- * Faults
    LuaFault (..)
  , FaultKind (..)
  , ErrorValue (..)
    -- * Lifetime failures
  , VmClosed (..)
  , CloseFault (..)
    -- * Naming
  , luaComponent
    -- * Bounds
  , diagnosticLimit
  ) where

import Control.Exception (Exception, SomeException)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)

-- | This package's component name, used for every failure it raises.
luaComponent ∷ Component
luaComponent = unsafeComponent "scripting.lua"

-- | How many bytes of a Lua error value are reported.
--
-- A Lua error message is written by the failing script, so its length is not
-- this package's to trust. The limit is generous enough that a real message
-- survives whole and small enough that a hostile one cannot become the
-- diagnostic.
diagnosticLimit ∷ Int
diagnosticLimit = 1024

-- | A Lua error value, rendered without running any Lua.
data ErrorValue
  = -- | A string or number error value, and whether 'diagnosticLimit' cut it.
    ErrorMessage !Text !Bool
  | -- | Any other value: its Lua type name and its address, nothing more.
    ErrorOpaque !Text !Text
  | -- | The call reported a failure but left no value behind.
    ErrorAbsent
  deriving (Eq, Show)

-- | Which Lua operation failed, as Lua's own status code classified it.
data FaultKind
  = -- | The chunk was not accepted: a syntax error.
    ChunkRejected
  | -- | The chunk or function ran and raised an error.
    CallFailed
  | -- | Lua could not allocate.
    MemoryExhausted
  | -- | The message handler itself failed, so no diagnostic came from it.
    HandlerFailed
  | -- | A status code this binding does not classify, kept as it printed.
    UnclassifiedStatus !Text
  deriving (Eq, Show)

-- | A fault raised on Lua's side of the boundary.
--
-- It is an ordinary Haskell exception: Lua's own error propagation was
-- contained by the protected call, and nothing unwound Haskell through the C
-- frame to produce it.
data LuaFault = LuaFault
  { faultKind ∷ !FaultKind
  , faultChunk ∷ !Text
    -- ^ The chunk or global the failing operation named.
  , faultValue ∷ !ErrorValue
  }
  deriving (Eq, Show)

instance Exception LuaFault

-- | An operation was asked of a VM whose close is terminal.
--
-- Close is one-way: this is never a transient condition to retry.
newtype VmClosed = VmClosed
  { closedOperation ∷ Text
  }
  deriving (Eq, Show)

instance Exception VmClosed

-- | Releasing the bridge's retained dependencies failed after the Lua state
-- was closed.
--
-- Every retained release is attempted; the failures are collected rather than
-- letting the first one hide the rest, and the Lua state is already closed by
-- the time any of them can be raised.
newtype CloseFault = CloseFault
  { closeFailures ∷ [SomeException]
  }
  deriving (Show)

instance Exception CloseFault
