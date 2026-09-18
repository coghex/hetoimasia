-- | The VM: what the bridge owns for one Lua interpreter, and the discipline
-- every operation on it runs under.
--
-- One VM is one @lua_State@ with one execution owner. That ownership is
-- enforced by a gate rather than assumed: every operation holds the gate for
-- its duration, so two Haskell threads cannot be inside the same state at once,
-- and an operation asked of a closing or closed VM is refused instead of
-- reaching a state that is being or has been freed.
--
-- An operation runs masked. Not because anything in it blocks -- the only
-- waiting it does is the @safe@ foreign call, which no asynchronous exception
-- can interrupt anyway -- but because of the instant after that call returns. A
-- cancellation that arrived while the thread was inside Lua is delivered at the
-- first opportunity once it is out, and that opportunity falls between the call
-- and the bookkeeping that follows it: restoring the stack, and taking the
-- failure a callback recorded. Delivered there it would leave the stack deep
-- and the failure behind for the next, unrelated operation to raise. Masking
-- the operation moves the delivery to the boundary, after the bookkeeping. The
-- gate is still taken interruptibly, so a caller waiting for a VM that is busy
-- can be cancelled.
--
-- Close is terminal and happens once, and the phase says which of those two it
-- is. It becomes 'Closing' before @lua_close@ is entered and 'Closed' only once
-- the teardown has finished, and the one caller that runs the teardown holds
-- the gate throughout; a second caller waits for it rather than being told the
-- VM is closed while Lua is still running a finalizer. Retained dependencies
-- are released after @lua_close@ has returned, because the finalizers it runs
-- -- including the @__gc@ that frees each pushed Haskell function's stable
-- pointer -- are still executing until it does.
--
-- A Haskell exception that reaches a callback is not thrown through the C
-- frame. The trampoline records it here and signals an ordinary Lua error; the
-- operation that was running reads the record back and re-raises the original
-- exception with the context it was caught with, whatever Lua did with the
-- error in between. The first escape is the one kept: a later failure inside
-- the same operation never displaces the failure that started it. An escape
-- from a finalizer during the close belongs to no operation, so the close
-- drains it and reports it among the close's own failures.
--
-- Nothing in this module is public. It holds the state and hands out stack
-- indices; the package's public library exposes neither.
module Hetoimasia.Scripting.Lua.Internal.Vm
  ( -- * The VM
    Vm
  , Phase (..)
  , newVm
  , closeVm
    -- * Operations
  , withOpenVm
    -- * Escaped Haskell failures
  , recordEscape
  , raiseEscape
  , discardEscape
    -- * Retained dependencies
  , retainRelease
    -- * Probes
  , vmState
  , vmPhase
  , stackDepth
  , probeReferenceSlot
  ) where

import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , mask
  , mask_
  , onException
  , rethrowIO
  , throwIO
  , try
  )
import Control.Monad (unless)
import Data.ByteString (useAsCString)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C (CChar, CInt (CInt))
import Foreign.Ptr (Ptr, nullPtr)
import Hetoimasia.Foundation.Failure
  ( Operation
  , operation
  , operationText
  , throwFailure
  )
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( CloseFault (CloseFault)
  , ErrorValue (ErrorAbsent)
  , FaultKind (MemoryExhausted)
  , LuaFault (LuaFault)
  , VmClosed (VmClosed)
  , classify
  , luaComponent
  , renderFailure
  )
import Hetoimasia.Scripting.Lua.Internal.Library
  ( Library
  , libraryModuleName
  , libraryOpener
  )
import Lua
  ( CFunction
  , StackIndex
  , State (State)
  , StatusCode (StatusCode)
  , fromStackIndex
  , lua_close
  , lua_gettop
  , lua_pushboolean
  , lua_settop
  , luaL_ref
  , luaL_unref
  , data FALSE
  , data LUA_OK
  , data LUA_REGISTRYINDEX
  )

-- | Whether a VM still accepts operations, and if not, why.
data Phase
  = Open
  | -- | One caller is inside the teardown. Operations are refused and another
    -- close waits; the VM is not yet closed.
    Closing
  | -- | The teardown has finished. Terminal.
    Closed
  deriving (Eq, Show)

-- | One Lua interpreter and everything the bridge owns beside it.
data Vm = Vm
  { vmState ∷ !State
    -- ^ The interpreter. Reachable only from this package's bridge.
  , vmGate ∷ !(MVar ())
    -- ^ Held for the duration of every operation, and for the whole teardown.
  , vmPhaseRef ∷ !(IORef Phase)
    -- ^ Read under the gate. An 'IORef' rather than the gate's own contents so
    -- that advancing it can never block or be interrupted.
  , vmEscape ∷ !(IORef (Maybe (ExceptionWithContext SomeException)))
    -- ^ The first Haskell failure that reached a callback during whatever is
    -- running, waiting to be re-raised by it.
  , vmClosingEscapes ∷ !(IORef [ExceptionWithContext SomeException])
    -- ^ Every Haskell failure that reached a callback during the close, newest
    -- first. The close is not one operation: @lua_close@ runs every pending
    -- finalizer, and each is a separate thing that can fail, so keeping the
    -- first would be dropping the rest.
  , vmReleases ∷ !(IORef [IO ()])
    -- ^ Dependencies the bridge retains for as long as Lua can call back into
    -- Haskell, released after @lua_close@ and never before.
  , vmFinished ∷ !(MVar ())
    -- ^ Filled once, when the teardown has completed. What a second close
    -- waits on.
  }

-- | The interpreter's current phase.
vmPhase ∷ Vm → IO Phase
vmPhase = readIORef . vmPhaseRef

-- | The interpreter's current stack depth.
--
-- A probe for this package's own fixtures: an operation restores the depth it
-- entered at, and this is how that is observed.
stackDepth ∷ Vm → IO Int
stackDepth vm = fromIntegral . fromStackIndex <$> lua_gettop (vmState vm)

-- | Which registry slot a temporary reference would take right now.
--
-- A probe for this package's own fixtures. The registry keeps released slots on
-- a free list and hands the most recently released one back first, so taking a
-- reference before an operation and again after it answers the same slot only
-- if the operation left the registry as it found it. The bridge itself takes no
-- registry reference at all, so the answer should never move.
probeReferenceSlot ∷ Vm → IO CInt
probeReferenceSlot vm = do
  let state = vmState vm
  entry ← lua_gettop state
  lua_pushboolean state FALSE
  reference ← luaL_ref state LUA_REGISTRYINDEX
  luaL_unref state LUA_REGISTRYINDEX reference
  lua_settop state entry
  pure reference

-- | Create a VM and open exactly the named standard libraries, in order.
--
-- The empty list is supported and opens none: a VM with no standard library is
-- a VM, not a degenerate case. @luaL_openlibs@ is never called, so there is no
-- path here whose only option is the full standard library.
--
-- A library that fails to open leaves no state behind: the interpreter is
-- closed before the failure is raised.
newVm ∷ [Library] → IO Vm
newVm libraries = mask_ $ do
  -- The one Lua operation that cannot be protected, because there is no state
  -- yet to protect it with. It reports an allocation failure by answering a
  -- null state rather than by raising, which is why it is the entry used.
  state ← hetoimasia_lua_newstate
  unless (stateReachable state) $
    throwFailure
      luaComponent
      newOperation
      []
      (LuaFault MemoryExhausted "new-state" ErrorAbsent)
  gate ← newMVar ()
  phase ← newIORef Open
  escape ← newIORef Nothing
  closing ← newIORef []
  releases ← newIORef []
  finished ← newEmptyMVar
  let vm = Vm state gate phase escape closing releases finished
  opened ← try (traverse_ (openLibrary state) libraries)
  case opened of
    Right () → pure vm
    Left failure → do
      lua_close state
      throwIO (failure ∷ SomeException)

-- | Open one standard library, with the whole @requiref@ inside one protected
-- Lua call, restoring the stack it borrowed.
--
-- The binding's own wrapper allocates the module's name before entering its
-- protected call, so opening a library under memory exhaustion would panic
-- rather than report. What it left behind is read and classified like any other
-- failed call: a library that could not be allocated is 'MemoryExhausted', not
-- a rejected chunk.
openLibrary ∷ State → Library → IO ()
openLibrary state library = do
  entry ← lua_gettop state
  status ←
    useAsCString (libraryModuleName library) $ \name →
      hetoimasia_lua_requiref state name (libraryOpener library) 1
  unless (status == LUA_OK) $ do
    value ← renderFailure state entry
    lua_settop state entry
    throwFailure
      luaComponent
      openOperation
      [("library", showText library)]
      (LuaFault (classify status) (showText library) value)
  -- Successful or not, the protected call left exactly one value: the module,
  -- or the error it failed with.
  lua_settop state entry

-- | Run one operation on an open VM, holding the gate for its duration.
--
-- Masked throughout, for the reason this module's header gives. The gate is
-- released on every exit path, and an operation that leaves by an exception
-- leaves the stack at the depth it entered at and no recorded callback failure
-- behind for the next one.
withOpenVm ∷ Vm → Operation → (State → IO a) → IO a
withOpenVm vm name body = mask_ $ do
  -- Interruptible, and deliberately the only interruptible point: a caller
  -- waiting for a VM that is busy may still be cancelled.
  takeMVar (vmGate vm)
  phase ← readIORef (vmPhaseRef vm)
  case phase of
    Open → do
      let state = vmState vm
      entry ← lua_gettop state
      result ← body state `onException` abandon vm entry
      putMVar (vmGate vm) ()
      pure result
    _ → do
      putMVar (vmGate vm) ()
      throwFailure luaComponent name [] (VmClosed (operationText name))

-- | Leave an operation that failed with the VM as the next one should find it.
abandon ∷ Vm → StackIndex → IO ()
abandon vm entry = do
  lua_settop (vmState vm) entry
  discardEscape vm
  putMVar (vmGate vm) ()

-- | Close the VM, once and for good.
--
-- The caller that finds it open runs the teardown holding the gate; any other
-- caller waits for that one to finish rather than being told the VM is closed
-- while Lua is still inside it. The phase is 'Closing' throughout, so an
-- operation that arrives meanwhile is refused.
--
-- The teardown itself is masked. Repeated cancellation can therefore neither
-- release the retained dependencies early nor leave a partially completed close
-- for a later call to start again.
closeVm ∷ Vm → IO ()
closeVm vm = mask $ \restore → do
  takeMVar (vmGate vm)
  phase ← readIORef (vmPhaseRef vm)
  case phase of
    Open → do
      writeIORef (vmPhaseRef vm) Closing
      outcome ← try (teardown vm)
      writeIORef (vmPhaseRef vm) Closed
      putMVar (vmFinished vm) ()
      putMVar (vmGate vm) ()
      either throwIO pure (outcome ∷ Either SomeException ())
    _ → do
      putMVar (vmGate vm) ()
      -- Interruptible: waiting for someone else's teardown is a wait, and a
      -- cancelled caller is entitled to stop waiting. The teardown itself is
      -- unaffected.
      restore (readMVar (vmFinished vm))

-- | Close the interpreter, then release what its callbacks borrowed.
--
-- Every release is attempted; their failures, and any failure a Haskell
-- finalizer raised while @lua_close@ ran it, are collected into one
-- 'CloseFault' rather than letting the first one hide the rest. A finalizer's
-- failure belongs to no caller's operation, so nothing else would ever observe
-- it.
teardown ∷ Vm → IO ()
teardown vm = do
  lua_close (vmState vm)
  -- Every finalizer that failed, in the order they ran, and anything an
  -- operation left behind.
  escaped ← atomicModifyIORef' (vmClosingEscapes vm) (\held → ([], reverse held))
  stranded ← takeEscape vm
  releases ← atomicModifyIORef' (vmReleases vm) (\retained → ([], retained))
  outcomes ← traverse (try @SomeException) (reverse releases)
  let finalizerFailures =
        [failure | ExceptionWithContext _ failure ← escaped <> maybeToList stranded]
      releaseFailures = [failure | Left failure ← outcomes]
      failures = finalizerFailures <> releaseFailures
  unless (null failures) (throwIO (CloseFault failures))

-- | Retain a dependency's release until after the VM's terminal close.
--
-- A callback borrows what the Haskell side gave it. Releasing that while Lua
-- can still call back is a use-after-free with extra steps, so the release is
-- held here and run only once @lua_close@ has finished running finalizers.
retainRelease ∷ Vm → IO () → IO ()
retainRelease vm release =
  atomicModifyIORef' (vmReleases vm) (\retained → (release : retained, ()))

-- | Record the Haskell failure that reached a callback.
--
-- During an operation the first one is kept: Lua may go on to call the same
-- callback again, and that later failure must not displace the one the caller
-- is owed. During the close every one is kept, because the close is not one
-- operation -- @lua_close@ runs each pending finalizer, and each is separately
-- able to fail.
recordEscape ∷ Vm → ExceptionWithContext SomeException → IO ()
recordEscape vm captured = do
  phase ← readIORef (vmPhaseRef vm)
  case phase of
    Closing →
      atomicModifyIORef' (vmClosingEscapes vm) (\held → (captured : held, ()))
    _ →
      atomicModifyIORef'
        (vmEscape vm)
        (\held → (maybe (Just captured) Just held, ()))

-- | Take the recorded failure, leaving none.
takeEscape ∷ Vm → IO (Maybe (ExceptionWithContext SomeException))
takeEscape vm = atomicModifyIORef' (vmEscape vm) (\held → (Nothing, held))

-- | Drop the recorded failure without raising it.
--
-- For an operation that is already leaving by another exception: the failure it
-- would have raised is owed to that operation and to no later one.
discardEscape ∷ Vm → IO ()
discardEscape vm = () <$ takeEscape vm

-- | Re-raise the recorded Haskell failure, if a callback had one.
--
-- The exception keeps its own type and the context it was caught with; the
-- boundary that calls this adds its operation to that context rather than
-- wrapping the exception. Lua's own handling of the error the trampoline
-- signalled is irrelevant here: a @pcall@ that swallowed it and a chunk that
-- went on to succeed both still arrive at this.
raiseEscape ∷ Vm → IO ()
raiseEscape vm = takeEscape vm >>= traverse_ rethrowIO

openOperation ∷ Operation
openOperation = operation "open-library"

newOperation ∷ Operation
newOperation = operation "new-vm"

-- | Whether the interpreter was allocated at all.
stateReachable ∷ State → Bool
stateReachable (State pointer) = pointer /= nullPtr

-- | A new interpreter, or a null state when one could not be allocated.
foreign import ccall unsafe "hetoimasia_lua_bridge.h hetoimasia_lua_newstate"
  hetoimasia_lua_newstate ∷ IO State

-- | Open one standard library, with the whole operation inside one protected
-- Lua call.
--
-- @safe@: an opener runs Lua, and a module already in @package.loaded@ can be
-- anything, including something that calls back into Haskell.
foreign import ccall safe "hetoimasia_lua_bridge.h hetoimasia_lua_requiref"
  hetoimasia_lua_requiref ∷ State → Ptr CChar → CFunction → CInt → IO StatusCode

showText ∷ Show a ⇒ a → Text
showText = Text.pack . show
