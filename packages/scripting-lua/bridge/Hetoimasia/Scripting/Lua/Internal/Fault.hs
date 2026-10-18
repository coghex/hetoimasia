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
  , VmReentered (..)
  , VmNotOwned (..)
  , FinalizerRefused (..)
  , FinalizerEvidenceTruncated (..)
  , CloseFault (..)
  , CloseFailure (..)
  , CloseSource (..)
  , closeSourceLabel
    -- * Naming
  , luaComponent
    -- * Where a failure came from
  , fromApplication
  , raisedByApplication
  , CallRefusal (..)
    -- * Reading what a failed call left
  , classify
  , renderFailure
    -- * Bounds
  , diagnosticLimit
  ) where

import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , rethrowIO
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (ExceptionContext, addExceptionAnnotation, getExceptionAnnotations)
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

-- | Marks a failure that application code raised: a binding's action, or the
-- application's own check that a capability is still live.
--
-- The boundary's own faults ('Hetoimasia.Scripting.Lua.Internal.Boundary.BoundaryFault'
-- and 'LuaFault') and a failure of an application's action can have the same
-- type, because an action is free to throw either. Nothing about the exception
-- tells them apart, and an owner's caller has to know which it caught: a fault
-- of the call is the caller's to handle, a failure of the application's own
-- code is a broken host. So the failure of application code is marked where it
-- escapes that code, and everything else is not.
--
-- The mark is an annotation of the exception's context, which keeps the
-- exception's type and value, and is added once however many boundaries it
-- crosses.
data RaisedByApplication = RaisedByApplication

instance ExceptionAnnotation RaisedByApplication where
  displayExceptionAnnotation RaisedByApplication = "raised by application code"

-- | Run application code, marking any failure that escapes it as the
-- application's. The failure is rethrown with its own type, value and context.
fromApplication ∷ IO a → IO a
fromApplication action =
  tryWithContext @SomeException action >>= \case
    Right result → pure result
    Left (ExceptionWithContext context exception)
      | raisedByApplication context → rethrowIO (ExceptionWithContext context exception)
      | otherwise → rethrowIO (ExceptionWithContext (addExceptionAnnotation RaisedByApplication context) exception)

-- | Whether a failure's context says application code raised it.
raisedByApplication ∷ ExceptionContext → Bool
raisedByApplication context = not (null (getExceptionAnnotations context ∷ [RaisedByApplication]))

-- | The engine's own refusal of the call a binding's action is serving, raised
-- by the engine's API from inside that action.
--
-- A failure that escapes an action is the application's and ends the owner, so an
-- action cannot refuse its own call by throwing: whatever it throws is marked as
-- its own. This is the exception for the refusals that are not. The binding's
-- handler catches it around the action, and answers it as a fault of the call
-- ('Hetoimasia.Scripting.Lua.Internal.Boundary.BindingRefused'): recorded on the
-- VM like any other refusal of a call (decision C1), so the invocation's
-- operation raises it whatever the script does with the error it sees, and never
-- marked as a failure of application code. It is not exported by the public
-- library, so application code cannot raise it; only an engine API that checks
-- the condition itself, before it has any effect, does.
newtype CallRefusal = CallRefusal
  { refusalReason ∷ Text
  }
  deriving (Eq, Show)

instance Exception CallRefusal

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

-- | An operation was asked of a VM by one of that VM's own callbacks, and was
-- refused rather than run.
--
-- The operation that ran the callback holds the VM for its whole duration, so
-- the one the callback asked for could only ever wait for its own caller. It is
-- refused before it touches the VM: it runs no Lua and changes nothing. Running
-- Lua from inside a callback of the same VM is outside the callback contract,
-- so this is never a transient condition to retry either.
newtype VmReentered = VmReentered
  { reenteredOperation ∷ Text
  }
  deriving (Eq, Show)

instance Exception VmReentered

-- | An operation was asked of a VM by a thread that is not its execution owner,
-- and was refused rather than run.
--
-- A VM an owner constructed has exactly one execution owner, the thread that
-- runs its protected lifetime, and only that thread may run Lua on it or close
-- it. The refusal is made before the VM's gate is taken: it runs no Lua,
-- changes no state and does not disturb the rightful owner, which goes on
-- using the VM. Another thread holding a reference to the VM, whether it escaped
-- the owner's body or was handed over on purpose, is refused every time, for as
-- long as the VM is open. Once the VM is closed the answer is 'VmClosed'
-- for every thread, since there is nothing left to own.
newtype VmNotOwned = VmNotOwned
  { notOwnedOperation ∷ Text
  }
  deriving (Eq, Show)

instance Exception VmNotOwned

-- | A callback reached from a Lua finalizer during the VM's shutdown was not on
-- the owner's finalizer allowlist, and was refused without running.
--
-- It is raised inside the callback's own frame, so Lua sees an ordinary error
-- it may catch with @pcall@, and it is also recorded for the close: the refusal
-- becomes cleanup evidence ('CloseFault', as 'FromRefusedFinalizer') whether or
-- not the finalizer's script handled the error.
newtype FinalizerRefused = FinalizerRefused
  { refusedCallback ∷ Text
  }
  deriving (Eq, Show)

instance Exception FinalizerRefused

-- | The close recorded fewer finalizer failures than there were: it keeps a
-- bounded number, and says how many it did not keep.
newtype FinalizerEvidenceTruncated = FinalizerEvidenceTruncated
  { droppedFailures ∷ Int
  }
  deriving (Eq, Show)

instance Exception FinalizerEvidenceTruncated

-- | Where one close failure came from.
data CloseSource
  = -- | A Haskell callback a Lua finalizer ran failed.
    FromFinalizer
  | -- | A callback a finalizer reached was refused by the shutdown phase.
    FromRefusedFinalizer
  | -- | Releasing a retained dependency failed after the state was closed.
    FromRelease
  | -- | A failure an earlier operation left recorded and nothing raised.
    FromStrandedOperation
  | -- | Failures beyond the recording bound were dropped.
    FromTruncation
  | -- | Closing a task's suspended coroutine failed: one of its pending
    -- to-be-closed variables raised an error.
    FromCoroutineClose
  deriving (Bounded, Enum, Eq, Show)

-- | The label a close failure of this source is retained under as cleanup
-- evidence.
closeSourceLabel ∷ CloseSource → Text
closeSourceLabel = \case
  FromFinalizer → "lua finalizer"
  FromRefusedFinalizer → "lua finalizer refused"
  FromRelease → "lua release"
  FromStrandedOperation → "lua operation"
  FromTruncation → "lua evidence truncated"
  FromCoroutineClose → "lua coroutine close"

-- | One failure of the close, with where it came from and the context its
-- exception was caught with.
data CloseFailure = CloseFailure
  { closeFailureSource ∷ !CloseSource
  , closeFailureCause ∷ !(ExceptionWithContext SomeException)
  }
  deriving (Show)

-- | Closing the VM failed after the Lua state was closed: a finalizer's
-- callback failed or was refused, or releasing the bridge's retained
-- dependencies failed.
--
-- Every retained release is attempted and every finalizer failure is kept, up
-- to a bound; the failures are collected rather than letting the first one hide
-- the rest, each with the context it was caught with, finalizers' in the order
-- they ran and then the releases'. The Lua state is already closed by the time
-- any of them can be raised.
newtype CloseFault = CloseFault
  { closeFailures ∷ [CloseFailure]
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
