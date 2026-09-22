-- | Haskell functions Lua can call, and what happens when one of them fails.
--
-- Installing a callback is deliberately private. The public registration
-- surface -- module identity, capability namespaces, per-domain policy -- is
-- LUA-3's; what this module provides is the trampoline itself and the narrow
-- fixture vocabulary this package's own examples need to prove the boundary
-- holds.
--
-- The trampoline contains failures raised by the callback's own action. They
-- are caught with their type and context and recorded on the VM, rather than
-- unwinding through the C frame that called in. Once every Haskell frame has
-- returned, the C closure raises a Lua error whose value is a light userdata
-- carrying no message.
--
-- That Lua error is a placeholder, not the failure. Lua may catch it with
-- @pcall@ and carry on to a successful finish; the operation's outer boundary
-- still re-raises the recorded exception, with its original type and context,
-- and adds its own operation to that context.
--
-- Cancellation targets the VM's execution owner, where it is deferred until
-- the native call and the operation's bookkeeping finish. Direct cancellation
-- of a callback thread is unsupported: the runtime's foreign-export prologue
-- and epilogue are outside this containment, and cancellation there can end
-- the process. A trusted callback must not publish its own 'ThreadId' or leave
-- work running past its return.
--
-- A callback borrows whatever Haskell state it closes over. Its release is
-- retained on the VM and run only after the terminal close, because until
-- @lua_close@ returns Lua can still call it. It is retained /before/ the
-- callback is published, so there is no ordering in which Lua can reach a
-- callback whose release is not held: a publication that then fails leaves a
-- release that runs at the close and frees something that was never used, which
-- is the harmless direction of that pair.
module Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (..)
  , Callback
  , Installed
  , installCallback
  , escapeMarker
  ) where

import Control.Exception (ExceptionWithContext, SomeException, mask, tryWithContext)
import qualified Data.ByteString.Unsafe as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Control.Monad (when)
import Foreign.C (CChar, CInt (CInt), CSize (CSize))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.StablePtr (StablePtr, deRefStablePtr, freeStablePtr, newStablePtr)
import Foreign.Storable (peek)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, withOperationContext)
import Hetoimasia.Scripting.Lua.Internal.Call (reportFault)
import Hetoimasia.Scripting.Lua.Internal.Fault (classify, luaComponent)
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Vm
  , raiseEscape
  , recordEscape
  , retainRelease
  , withOpenVm
  )
import Lua
  ( NumResults (NumResults)
  , PreCFunction
  , StackIndex (StackIndex)
  , State (State)
  , StatusCode (StatusCode)
  , lua_gettop
  , lua_pushboolean
  , lua_pushlightuserdata
  , lua_remove
  , lua_settop
  , lua_touserdata
  , data FALSE
  , data LUA_OK
  , data TRUE
  )

-- | Publish a Haskell function as a global, with every allocation the two of
-- them need inside one protected Lua call.
--
-- @safe@: setting a global honours @__newindex@, which can run Lua, which can
-- call back into Haskell.
foreign import ccall safe "hetoimasia_lua_bridge.h hetoimasia_lua_publish"
  hetoimasia_lua_publish
    ∷ State → StablePtr Installed → Ptr CChar → CSize → Ptr CInt → IO StatusCode

-- | What a bridge callback answers Lua with.
--
-- Deliberately tiny. Bounded value marshalling is LUA-3's contract; this is
-- only enough for this package's own examples to observe what a VM did.
data CallbackResult
  = NoResult
  | BooleanResult !Bool
  deriving (Eq, Show)

-- | A Haskell operation Lua may call. It takes no arguments.
type Callback = IO CallbackResult

-- | The value a failed callback raises in Lua's terms.
--
-- A light userdata, and deliberately not a string. Pushing a string allocates,
-- and an allocation failure raises a Lua error; raised here it would longjmp
-- out of a Haskell frame to the protected call outside it, which is undefined
-- rather than an error report. Pushing a light userdata allocates nothing.
--
-- It carries no information, which is the point: it marks that something failed
-- on the Haskell side and is not a rendering of the failure. The failure itself
-- is reported to Haskell, where its type and context survive. A script cannot
-- mistake it for one of its own error values either.
escapeMarker ∷ Ptr ()
escapeMarker = nullPtr

-- | Install a Haskell operation as a global of this VM.
--
-- @release@ is the callback's borrowed dependency: it is retained and run only
-- after the VM's terminal close, never while Lua could still call back.
installCallback ∷ HasCallStack ⇒ Vm → Text → Callback → IO () → IO ()
installCallback vm name action release =
  withOperationContext luaComponent installOperation [("global", name)] $
    withOpenVm vm installOperation $ \state → do
      entry ← lua_gettop state
      retainRelease vm release
      -- Both allocations publication needs -- the userdata that carries the
      -- function and the string that names it -- happen inside one protected
      -- call, so memory exhaustion here is a status rather than a panic.
      status ←
        ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(bytes, len) →
          alloca $ \acquired → do
            carried ← newStablePtr (Installed vm action)
            reported ←
              hetoimasia_lua_publish state carried bytes (fromIntegral len ∷ CSize) acquired
            -- Freed here only when Lua never took it. Once the userdata holds
            -- it, its @__gc@ is the owner and freeing it here would be a second
            -- free of the same pointer.
            owned ← peek acquired
            when (owned == (0 ∷ CInt)) (freeStablePtr carried)
            pure reported
      if status /= LUA_OK
        then reportFault vm state entry installOperation (classify status) name
        else do
          lua_settop state entry
          -- The globals table can carry a @__newindex@ metamethod, so
          -- publishing a global can run Lua, which can call a Haskell function
          -- that fails.
          raiseEscape vm

-- | What a carrier's stable pointer holds: the VM the callback belongs to, and
-- the callback itself.
data Installed = Installed !Vm !Callback

-- | This package's entry from Lua into Haskell.
--
-- It runs on a thread of the runtime's own making, created for this call and
-- ending with it. That thread is not a cancellation endpoint: cancellation
-- targets a VM's execution owner, and a callback thread is machinery the owner
-- does not address. A trusted callback must not publish its own 'ThreadId' for
-- something else to cancel, and must not leave work running past its own
-- return.
--
-- What this does contain is a failure the callback's own action raises. The
-- action runs unmasked, so it is interruptible for its own purposes and its
-- failure -- of any type, with the context it carried -- is caught here rather
-- than unwinding through the C frame that called in. It is recorded on the VM
-- and answered with a negative result count, which the C closure turns into a
-- Lua error once every Haskell frame has returned. The owner's boundary
-- re-raises it with its own type and context, whatever Lua did with the
-- placeholder.
--
-- Everything after the action is masked, which narrows the window in which an
-- exception could unwind through C to the runtime's own prologue and epilogue
-- around this function. It does not close it, and the contract does not claim
-- it does: a cancellation aimed at this thread from outside can still end the
-- process. A registration surface must preserve the trusted-callback rules
-- above: no publishing the callback thread's identity and no work left running
-- past its return. This does not prohibit LUA-3's planned registration surface.
hetoimasiaEnter ∷ PreCFunction
hetoimasiaEnter state = mask $ \restore → do
  -- The C closure put the carrier below the call's own arguments.
  carrier ← lua_touserdata state (StackIndex 1)
  lua_remove state (StackIndex 1)
  if carrier == nullPtr
    then do
      lua_pushlightuserdata state escapeMarker
      pure failedResults
    else do
      stored ← peek (castPtr carrier)
      Installed vm action ← deRefStablePtr stored
      outcome ← tryWithContext (restore action)
      results ← case outcome ∷ Either (ExceptionWithContext SomeException) CallbackResult of
        Right NoResult → pure (NumResults 0)
        Right (BooleanResult value) → do
          -- Allocates nothing, so it cannot raise a Lua error from inside this
          -- Haskell frame.
          lua_pushboolean state (if value then TRUE else FALSE)
          pure (NumResults 1)
        Left captured → do
          recordEscape vm captured
          lua_pushlightuserdata state escapeMarker
          pure failedResults
      pure results

foreign export ccall "hetoimasia_lua_enter" hetoimasiaEnter ∷ PreCFunction

-- | The result count that means "the value on top is the failure marker".
--
-- Negative, because no real call returns a negative number of results.
failedResults ∷ NumResults
failedResults = NumResults (-1)

installOperation ∷ Operation
installOperation = operation "install-callback"
