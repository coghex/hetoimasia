-- | What a fault on Lua's side of the boundary reports, and the bound on how
-- much of it is reported.
--
-- A Lua error value is arbitrary: a string, a number, a table, a userdata, or a
-- value whose @__tostring@ metamethod is itself arbitrary Lua. Rendering it is
-- therefore a bounded, metamethod-free operation. An existing string is read
-- through @lua_tolstring@ without conversion or allocation and truncated at
-- 'diagnosticLimit' bytes. Numbers are read through non-allocating numeric
-- accessors and formatted in Haskell; other values are reported by their Lua
-- type name alone, never by address. No further Lua runs to produce a
-- diagnostic, so a failing chunk cannot keep executing through its report.
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
    -- * Reading what a failed call left
  , classify
  , renderFailure
    -- * Bounds
  , diagnosticLimit
  ) where

import Control.Exception (Exception, SomeException)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Foreign.C (CSize, peekCString)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (peek)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Lua
  ( StackIndex (StackIndex)
  , State
  , StatusCode
  , lua_gettop
  , lua_isinteger
  , lua_tointegerx
  , lua_tolstring
  , lua_tonumberx
  , lua_type
  , lua_typename
  , data FALSE
  , data LUA_ERRERR
  , data LUA_ERRMEM
  , data LUA_ERRRUN
  , data LUA_ERRSYNTAX
  , data LUA_TNUMBER
  , data LUA_TSTRING
  )

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

-- | A Lua error value, rendered without running any Lua and without any
-- operation that could raise one.
data ErrorValue
  = -- | A string or number error value, and whether 'diagnosticLimit' cut it.
    ErrorMessage !Text !Bool
  | -- | Any other value, by its Lua type name alone.
    --
    -- Not its address. A pointer rendered into text is still the native
    -- address of a Lua value, and this type crosses the package boundary.
    ErrorOpaque !Text
  | -- | The call reported a failure and left no value behind.
    --
    -- Read from the stack: the failing operation restored nothing above the
    -- depth it entered at. It is never inferred from a value's contents.
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

-- | Classify one of Lua's own status codes.
classify ∷ StatusCode → FaultKind
classify status
  | status == LUA_ERRSYNTAX = ChunkRejected
  | status == LUA_ERRRUN = CallFailed
  | status == LUA_ERRMEM = MemoryExhausted
  | status == LUA_ERRERR = HandlerFailed
  | otherwise = UnclassifiedStatus (Text.pack (show status))

-- | Render what a failed call left above the depth it was given, running no Lua
-- and using nothing that can raise one.
--
-- The second half is the constraint that shapes this. A failed call has already
-- returned, so there is no protected frame left; anything here that raised a
-- Lua error would reach Lua's panic function and end the process. So: absence
-- is read from the stack, because an operation that left nothing above its
-- entry depth left no error value and no value's own contents are taken as
-- evidence of that; @lua_tolstring@ is called only on something that is already
-- a string, where it converts nothing and allocates nothing; a number is read
-- with the non-allocating accessors and formatted here; and anything else is
-- named by its Lua type and nothing else. Not by its address: a pointer
-- rendered into text is still one, and this value crosses the package boundary.
renderFailure ∷ State → StackIndex → IO ErrorValue
renderFailure state entry = do
  top ← lua_gettop state
  if top <= entry
    then pure ErrorAbsent
    else do
      kind ← lua_type state index
      if kind == LUA_TSTRING
        then readString
        else
          if kind == LUA_TNUMBER
            then readNumber
            else do
              named ← lua_typename state kind >>= peekName
              pure (ErrorOpaque named)
  where
    index = StackIndex (-1)
    readString = alloca $ \reported → do
      bytes ← lua_tolstring state index reported
      if bytes == nullPtr
        then pure (ErrorOpaque "string")
        else do
          len ← peek reported
          let full = fromIntegral (len ∷ CSize) ∷ Int
              kept = min full diagnosticLimit
          taken ← ByteString.packCStringLen (bytes, kept)
          pure (ErrorMessage (Text.decodeUtf8Lenient taken) (full > diagnosticLimit))
    readNumber = do
      integral ← lua_isinteger state index
      rendered ←
        if integral /= FALSE
          then Text.pack . show <$> lua_tointegerx state index nullPtr
          else Text.pack . show <$> lua_tonumberx state index nullPtr
      pure (ErrorMessage rendered False)
    peekName pointer
      | pointer == nullPtr = pure "unknown"
      | otherwise = Text.pack <$> peekCString pointer
