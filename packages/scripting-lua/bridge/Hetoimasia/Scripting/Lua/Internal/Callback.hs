-- | Haskell functions Lua can call, and what happens when one of them fails.
--
-- Installing a callback is deliberately private. The public registration
-- surface -- module identity, capability namespaces, per-domain policy -- is
-- LUA-3's; what this module provides is the trampoline itself and the narrow
-- fixture vocabulary this package's own examples need to prove the boundary
-- holds.
--
-- The trampoline is the containment. A Haskell exception must never unwind
-- through the C frame Lua called us from: that frame is not a Haskell frame,
-- and leaving it that way is undefined behaviour rather than an error report.
-- So every failure, synchronous or asynchronous, is caught here with the
-- context it carried, recorded on the VM, and replaced by an ordinary Lua
-- error carrying a fixed message.
--
-- That Lua error is a placeholder, not the failure. Lua may catch it with
-- @pcall@ and carry on to a successful finish; the operation's outer boundary
-- still re-raises the recorded exception, with its original type and context,
-- and adds its own operation to that context. A cancellation delivered to a
-- thread that is inside a callback is handled the same way and is likewise
-- re-raised rather than swallowed -- what it is not is converted into an
-- ordinary Lua error that a script could catch and ignore.
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
  , installCallback
  , escapeMessage
  ) where

import Control.Exception (ExceptionWithContext, SomeException, tryWithContext)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Unsafe as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Foreign.C (CSize)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek, poke)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, withOperationContext)
import Hetoimasia.Scripting.Lua.Internal.Call (classify, reportFault)
import Hetoimasia.Scripting.Lua.Internal.Fault (luaComponent)
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
  , State
  , hslua_error
  , hslua_pushhsfunction
  , hslua_setglobal
  , lua_gettop
  , lua_pushboolean
  , lua_pushlstring
  , lua_settop
  , data FALSE
  , data LUA_OK
  , data TRUE
  )

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

-- | The Lua error a failed callback raises in place of the Haskell exception.
--
-- Fixed, ASCII, and short: it is a marker that something failed on the Haskell
-- side, never a rendering of the failure. The failure itself is reported to
-- Haskell, where its type and context survive.
escapeMessage ∷ ByteString
escapeMessage = "hetoimasia: a Haskell callback failed; see the Haskell boundary"

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
      hslua_pushhsfunction state (trampoline vm action)
      status ←
        ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(bytes, len) →
          alloca $ \reported → do
            poke reported LUA_OK
            hslua_setglobal state bytes (fromIntegral len ∷ CSize) reported
            peek reported
      if status /= LUA_OK
        then reportFault vm state entry installOperation (classify status) name
        else do
          lua_settop state entry
          -- The globals table can carry a @__newindex@ metamethod, so
          -- publishing a global can run Lua, which can call a Haskell function
          -- that fails.
          raiseEscape vm

-- | The C-callable wrapper around one Haskell operation.
--
-- Nothing escapes it. A failure is recorded on the VM and answered to Lua as an
-- ordinary error through the binding's own error protocol, which the C shim
-- turns into @lua_error@ once this function has returned -- so the @longjmp@
-- happens in C, after the Haskell frame is gone, rather than through it.
trampoline ∷ Vm → Callback → PreCFunction
trampoline vm action state = do
  outcome ← tryWithContext action
  case outcome ∷ Either (ExceptionWithContext SomeException) CallbackResult of
    Right NoResult → pure (NumResults 0)
    Right (BooleanResult value) → do
      lua_pushboolean state (if value then TRUE else FALSE)
      pure (NumResults 1)
    Left captured → do
      recordEscape vm captured
      pushEscapeMessage state
      hslua_error state

-- | Push the fixed escape message.
pushEscapeMessage ∷ State → IO ()
pushEscapeMessage state =
  ByteString.unsafeUseAsCStringLen escapeMessage $ \(bytes, len) →
    lua_pushlstring state bytes (fromIntegral len ∷ CSize)

installOperation ∷ Operation
installOperation = operation "install-callback"
