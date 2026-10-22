-- | Haskell functions Lua can call, and what happens when one of them fails.
--
-- Installing a callback is deliberately private. The public registration
-- surface -- namespaces of bindings, module identity, per-owner policy -- is
-- "Hetoimasia.Scripting.Lua.Registration" and the owner's configuration, built on
-- 'installBinding'; what this module provides is the trampoline itself, the
-- 'Handler' a registered binding runs as, and the narrow fixture vocabulary this
-- package's own examples need to prove the boundary holds.
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
-- A callback that asks its own VM for an operation -- evaluating a chunk,
-- calling or probing a global, installing a callback, closing -- is refused with
-- 'Hetoimasia.Scripting.Lua.Internal.Fault.VmReentered' instead of waiting for
-- the operation that called it. The refusal is an ordinary failure of the
-- callback's action, so it travels like one.
--
-- A callback reached from a Lua finalizer while its VM is closing runs only if
-- the VM's finalizer policy allows its name; see
-- 'Hetoimasia.Scripting.Lua.Internal.Vm.FinalizerPolicy'. A callback the policy
-- refuses does not run: it fails with
-- 'Hetoimasia.Scripting.Lua.Internal.Fault.FinalizerRefused', which Lua sees as
-- an ordinary error and the close records as cleanup evidence whether or not the
-- finalizer's script caught it. Every callback reached while the VM is closing
-- is reached from a finalizer, because the close is the only thing running Lua
-- then and it refuses every operation.
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
  , Handler
  , Installed
  , installCallback
  , installBinding
  , installImport
  , escapeMarker
  , failedResults
  , suspendResults
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
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Scripting.Lua.Internal.Call (reportFault)
import Hetoimasia.Scripting.Lua.Internal.Marshal (importInstallAt, installBindingAt)
import Hetoimasia.Scripting.Lua.Internal.Fault (FinalizerRefused (FinalizerRefused), classify, luaComponent)
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Phase (Closing)
  , Vm
  , finalizerAllowed
  , raiseEscape
  , recordEscape
  , retainRelease
  , runCallback
  , vmPhase
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
-- Deliberately tiny. Bounded value marshalling is the value boundary's
-- ("Hetoimasia.Scripting.Lua.Internal.Binding"); this is only enough for this
-- package's own examples to observe what a VM did.
data CallbackResult
  = NoResult
  | BooleanResult !Bool
  deriving (Eq, Show)

-- | A Haskell operation Lua may call. It takes no arguments.
type Callback = IO CallbackResult

-- | What runs when Lua calls an installed function, given its Lua state and a
-- function that unmasks an action.
--
-- It is the part of the callback entry that has to touch the stack: it finds its
-- arguments there, and leaves its results on top of them, answering how many. It
-- runs masked, like the rest of the entry, and unmasks only the action the
-- application supplied, so a handler's marshalling is not interruptible. Anything
-- it throws is contained exactly as a callback's own failure is: recorded on the
-- VM with its type and context, and answered to Lua with the failure marker.
--
-- It must follow the rules of the callback entry: an allocating Lua operation is
-- made only inside a protected call (see "Hetoimasia.Scripting.Lua.Internal.Marshal"),
-- never directly.
type Handler = State → (∀ a. IO a → IO a) → IO NumResults

-- | A fixture callback as a handler: no arguments, and a boolean or nothing back.
plainHandler ∷ Callback → Handler
plainHandler action state restore = do
  result ← restore action
  case result of
    NoResult → pure (NumResults 0)
    BooleanResult value → do
      -- Allocates nothing, so it cannot raise a Lua error from inside this
      -- Haskell frame.
      lua_pushboolean state (if value then TRUE else FALSE)
      pure (NumResults 1)

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
  installWith vm [("global", name)] name publishGlobal (plainHandler action) release
  where
    publishGlobal state carried acquired =
      ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(bytes, len) →
        hetoimasia_lua_publish state carried bytes (fromIntegral len ∷ CSize) acquired

-- | Install a handler as @namespace.name@, in a namespace table that already
-- exists. The handler is reached by the name @namespace.name@, which is the name
-- the VM's finalizer policy knows it by.
--
-- Nothing is borrowed from the Haskell side that outlives the handler, so there
-- is no release to retain.
--
-- A @yielding@ binding suspends the running coroutine, with no values, when its
-- handler returns without failing: the handler decides, and the yield itself is
-- made in C once every Haskell frame has returned, exactly as the error is.
installBinding ∷ HasCallStack ⇒ Vm → Text → Text → Bool → Handler → IO ()
installBinding vm space name yielding handler =
  installWith vm [("binding", qualified)] qualified publish handler (pure ())
  where
    qualified = space <> "." <> name
    publish state carried acquired = installBindingAt state carried space name yielding acquired

-- | Install the handler every module's @import@ reaches, as a carrier kept in the
-- registry. Each module's @import@ is a closure made over it and over the module's
-- own context, so one handler serves every module of the VM.
--
-- It is reached by the name @import@, which is the name the VM's finalizer policy
-- knows it by. Like a binding it borrows nothing that outlives the handler.
--
-- Unlike a binding's, the handler may answer 'suspendResults': the C closure then
-- suspends the running coroutine once every Haskell frame has returned, to be
-- resumed with the dependency's exports or an error to raise.
installImport ∷ HasCallStack ⇒ Vm → Handler → IO ()
installImport vm handler =
  installWith vm [("binding", "import")] "import" importInstallAt handler (pure ())

-- | The installation both public forms share: the release is retained before the
-- function is published, and the stable pointer is freed here only when Lua
-- never took it.
installWith
  ∷ HasCallStack
  ⇒ Vm
  → [(Text, Text)]
  → Text
  → (State → StablePtr Installed → Ptr CInt → IO StatusCode)
  → Handler
  → IO ()
  → IO ()
installWith vm context name publish handler release =
  withOperationContext luaComponent installOperation context $
    withOpenVm vm installOperation $ \state → do
      entry ← lua_gettop state
      retainRelease vm release
      -- Every allocation publication needs happens inside one protected call,
      -- so memory exhaustion here is a status rather than a panic.
      status ←
        alloca $ \acquired → do
          carried ← newStablePtr (Installed vm name handler)
          reported ← publish state carried acquired
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

-- | What a carrier's stable pointer holds: the VM the callback belongs to, the
-- name it was installed under, and what runs when it is called.
data Installed = Installed !Vm !Text !Handler

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
-- past its return. A registered binding's 'Handler' keeps them: it publishes no
-- identity and leaves nothing running.
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
      Installed vm name handler ← deRefStablePtr stored
      -- While the VM closes, only a callback its finalizer policy names runs.
      phase ← vmPhase vm
      let refused = phase == Closing && not (finalizerAllowed vm name)
      -- Marked as this VM's caller while it runs, so that asking the same VM
      -- for an operation fails here instead of waiting on the caller's gate.
      -- A refused callback never runs: its refusal is the failure, recorded
      -- like any other that reached a callback.
      outcome ←
        if refused
          then tryWithContext (throwFailure luaComponent refusedOperation [("callback", name)] (FinalizerRefused name))
          else runCallback vm (tryWithContext (handler state restore))
      results ← case outcome ∷ Either (ExceptionWithContext SomeException) NumResults of
        Right produced → pure produced
        Left captured → do
          recordEscape vm captured
          lua_pushlightuserdata state escapeMarker
          pure failedResults
      pure results

foreign export ccall "hetoimasia_lua_enter" hetoimasiaEnter ∷ PreCFunction

-- | The result count that means "raise the value on top as a Lua error".
--
-- Negative, because no real call returns a negative number of results. The value
-- is the failure marker when the failure was recorded on the VM. A handler that
-- leaves a message instead, which it builds with a protected push, raises an
-- ordinary Lua error that records nothing: a script can catch it, and the call
-- it was caught in succeeds.
failedResults ∷ NumResults
failedResults = NumResults (-1)

-- | The result count that means "suspend the running coroutine inside an @import@".
-- Negative, like 'failedResults', and distinct from it: no real call returns either.
suspendResults ∷ NumResults
suspendResults = NumResults (-2)

installOperation ∷ Operation
installOperation = operation "install-callback"

refusedOperation ∷ Operation
refusedOperation = operation "finalizer-callback"
