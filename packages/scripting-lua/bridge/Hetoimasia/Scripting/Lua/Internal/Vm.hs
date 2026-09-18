-- | The VM: what the bridge owns for one Lua interpreter, and the discipline
-- every operation on it runs under.
--
-- One VM is one @lua_State@ with one execution owner. That ownership is
-- enforced by a gate rather than assumed: every operation takes the gate for
-- its duration, so two Haskell threads cannot be inside the same state at once,
-- and an operation asked of a closed VM is refused instead of reaching a freed
-- state.
--
-- Close is terminal and happens once. The gate is set to 'Closed' before
-- @lua_close@ runs and under a mask, so a cancellation delivered around the
-- close can neither retry a partially completed close nor reopen the VM, and a
-- second close is a no-op rather than a double free. Retained dependencies are
-- released only after @lua_close@ has returned, because the Lua finalizers it
-- runs -- including the @__gc@ that frees each pushed Haskell function's stable
-- pointer -- are still executing until it does.
--
-- A Haskell exception that reaches a callback is not thrown through the C
-- frame. The trampoline records it here and signals an ordinary Lua error; the
-- outer boundary reads the record back and re-raises the original exception
-- with the context it was caught with, whatever Lua did with the error in
-- between. The first escape is the one kept: a later failure inside the same
-- operation never displaces the failure that started it.
--
-- Nothing in this module is public. It holds the state, hands out stack
-- indices, and allocates registry references; the package's public library
-- exposes none of them.
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
    -- * Retained dependencies
  , retainRelease
    -- * Registry references
  , withTemporaryReference
  , outstandingReferences
    -- * Probes
  , vmState
  , vmPhase
  , stackDepth
  , probeReferenceSlot
  ) where

import Control.Concurrent.MVar (MVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Exception
  ( ExceptionWithContext
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
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C (CInt)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek, poke)
import Hetoimasia.Foundation.Failure
  ( Operation
  , operation
  , operationText
  , throwFailure
  )
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( CloseFault (CloseFault)
  , ErrorValue (ErrorAbsent)
  , FaultKind (ChunkRejected)
  , LuaFault (LuaFault)
  , VmClosed (VmClosed)
  , luaComponent
  )
import Hetoimasia.Scripting.Lua.Internal.Library
  ( Library
  , libraryModuleName
  , libraryOpener
  )
import Lua
  ( State
  , fromStackIndex
  , hsluaL_newstate
  , hsluaL_requiref
  , lua_close
  , lua_gettop
  , lua_pushboolean
  , lua_settop
  , luaL_ref
  , luaL_unref
  , data LUA_OK
  , data LUA_REGISTRYINDEX
  , data TRUE
  , data FALSE
  )

-- | Whether a VM still accepts operations.
data Phase = Open | Closed
  deriving (Eq, Show)

-- | One Lua interpreter and everything the bridge owns beside it.
data Vm = Vm
  { vmState ∷ !State
    -- ^ The interpreter. Reachable only from this package's bridge.
  , vmGate ∷ !(MVar Phase)
    -- ^ Held for the duration of every operation, and set to 'Closed' by the
    -- one close that runs.
  , vmEscape ∷ !(IORef (Maybe (ExceptionWithContext SomeException)))
    -- ^ The first Haskell failure that reached a callback during the operation
    -- in progress, waiting to be re-raised at the boundary.
  , vmReleases ∷ !(IORef [IO ()])
    -- ^ Dependencies the bridge retains for as long as Lua can call back into
    -- Haskell, released after @lua_close@ and never before.
  , vmReferences ∷ !(IORef (Set CInt))
    -- ^ The bridge's own outstanding temporary registry references. A
    -- completed operation leaves this empty.
  }

-- | The interpreter's current phase.
vmPhase ∷ Vm → IO Phase
vmPhase = readMVar . vmGate

-- | The interpreter's current stack depth.
--
-- A probe for this package's own fixtures: an operation restores the depth it
-- entered at, and this is how that is observed.
stackDepth ∷ Vm → IO Int
stackDepth vm = fromIntegral . fromStackIndex <$> lua_gettop (vmState vm)

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
  state ← hsluaL_newstate
  gate ← newMVar Open
  escape ← newIORef Nothing
  releases ← newIORef []
  references ← newIORef Set.empty
  let vm = Vm state gate escape releases references
  opened ← try (traverse_ (openLibrary state) libraries)
  case opened of
    Right () → pure vm
    Left failure → do
      lua_close state
      throwIO (failure ∷ SomeException)

-- | Open one standard library through the binding's protected @requiref@,
-- restoring the stack it borrowed.
openLibrary ∷ State → Library → IO ()
openLibrary state library = do
  entry ← lua_gettop state
  status ←
    useAsCString (libraryModuleName library) $ \name →
      alloca $ \reported → do
        poke reported LUA_OK
        hsluaL_requiref state name (libraryOpener library) TRUE reported
        peek reported
  -- Successful or not, the protected call left exactly one value: the module,
  -- or the error it failed with.
  lua_settop state entry
  unless (status == LUA_OK) $
    throwFailure
      luaComponent
      openOperation
      [("library", showText library)]
      (LuaFault ChunkRejected (showText library) ErrorAbsent)

-- | Run one operation on an open VM, holding the gate for its duration.
--
-- The gate is released on every exit path, including a cancellation, so a
-- failed or interrupted operation never strands the VM.
withOpenVm ∷ Vm → Operation → (State → IO a) → IO a
withOpenVm vm name body = mask $ \restore → do
  phase ← takeMVar (vmGate vm)
  case phase of
    Closed → do
      putMVar (vmGate vm) Closed
      throwFailure luaComponent name [] (VmClosed (operationText name))
    Open → do
      result ← restore (body (vmState vm)) `onException` putMVar (vmGate vm) Open
      putMVar (vmGate vm) Open
      pure result

-- | Close the VM, once and for good.
--
-- The phase becomes 'Closed' before @lua_close@ is entered and the whole close
-- runs masked, so repeated cancellation can neither release the retained
-- dependencies early nor cause a partially completed close to be retried. The
-- dependencies are released after @lua_close@ has returned, because until then
-- Lua's finalizers may still be running. Every release is attempted; their
-- failures are collected into one 'CloseFault' rather than letting the first
-- one hide the rest.
closeVm ∷ Vm → IO ()
closeVm vm = mask_ $ do
  phase ← takeMVar (vmGate vm)
  case phase of
    Closed → putMVar (vmGate vm) Closed
    Open → do
      -- Terminal before the close begins, so nothing that arrives during it
      -- can observe an open VM or start the close again.
      putMVar (vmGate vm) Closed
      lua_close (vmState vm)
      releases ← atomicModifyIORef' (vmReleases vm) (\retained → ([], retained))
      outcomes ← traverse (try @SomeException) (reverse releases)
      let failures = [failure | Left failure ← outcomes]
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
-- The first one is kept. Lua may go on to call the same callback again, and
-- that later failure must not displace the one the caller is owed.
recordEscape ∷ Vm → ExceptionWithContext SomeException → IO ()
recordEscape vm captured =
  atomicModifyIORef'
    (vmEscape vm)
    (\held → (maybe (Just captured) Just held, ()))

-- | Re-raise the recorded Haskell failure, if a callback had one.
--
-- The exception keeps its own type and the context it was caught with; the
-- boundary that calls this adds its operation to that context rather than
-- wrapping the exception. Lua's own handling of the error the trampoline
-- signalled is irrelevant here: a @pcall@ that swallowed it and a chunk that
-- went on to succeed both still arrive at this.
raiseEscape ∷ Vm → IO ()
raiseEscape vm = do
  held ← atomicModifyIORef' (vmEscape vm) (\held → (Nothing, held))
  traverse_ rethrowIO held

-- | The bridge's outstanding temporary registry references.
--
-- Empty after every completed operation, including the ones that faulted.
outstandingReferences ∷ Vm → IO (Set CInt)
outstandingReferences = readIORef . vmReferences

-- | Move the value at the top of the stack into the registry for the duration
-- of an action, and release the reference on every exit path.
--
-- This is how the bridge reads a fault's error value after restoring the stack
-- to the depth the operation entered at: the value survives the restore, and
-- the slot it occupied goes back to the registry's free list whether the action
-- returns, fails, or is cancelled.
withTemporaryReference ∷ Vm → (CInt → IO a) → IO a
withTemporaryReference vm use = mask $ \restore → do
  reference ← luaL_ref (vmState vm) LUA_REGISTRYINDEX
  atomicModifyIORef' (vmReferences vm) (\held → (Set.insert reference held, ()))
  let release = do
        luaL_unref (vmState vm) LUA_REGISTRYINDEX reference
        atomicModifyIORef' (vmReferences vm) (\held → (Set.delete reference held, ()))
  result ← restore (use reference) `onException` release
  release
  pure result

openOperation ∷ Operation
openOperation = operation "open-library"

showText ∷ Show a ⇒ a → Text
showText = Text.pack . show

-- | Which registry slot a temporary reference would take right now.
--
-- A probe for this package's own fixtures. The registry keeps released slots on
-- a free list and hands the most recently released one back first, so taking a
-- reference before an operation and again after it answers the same slot only
-- if the operation released everything it took. It leaves the stack and the
-- registry exactly as it found them.
probeReferenceSlot ∷ Vm → IO CInt
probeReferenceSlot vm = do
  lua_pushboolean (vmState vm) FALSE
  withTemporaryReference vm pure
