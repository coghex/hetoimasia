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
-- The gate cannot tell its holder's callbacks from anyone else, and a callback
-- runs on a thread of its own while the operation that called it still holds
-- the gate. An operation a callback asks of its own VM would therefore wait for
-- its own caller for ever, with the owner inside a @safe@ call that no
-- cancellation reaches. So the VM keeps the threads that are running its
-- callbacks, and an operation or close asked from one of them is refused with
-- 'VmReentered' before it takes the gate: it runs no Lua and changes nothing.
-- Every other thread still waits for the gate, exactly as before. A thread a
-- callback starts is not one of them, and neither is a callback of another VM;
-- re-entry through either is not detected and stays outside the contract.
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
-- A VM an owner constructed has a second guard the gate does not provide. The
-- gate is mutual exclusion: any thread that takes it may run Lua, so on its own
-- it says nothing about who the VM's one execution owner is. A managed VM
-- therefore records the thread that constructed it, and an operation or a close
-- asked by any other thread is refused with 'VmNotOwned' before the gate is
-- taken, so a refused attempt changes nothing and the rightful owner is not
-- disturbed. A VM made by 'newVm' alone has no such owner and keeps the gate's
-- discipline only.
--
-- The close is the same one whoever asked: a VM whose construction failed part
-- way is closed through 'closeVm', so a partly initialized state is torn down
-- with the same masking, the same retained dependencies and the same evidence
-- as a finished one, and a failure of that close is retained beside the
-- construction's own failure rather than replacing it.
--
-- While a VM is closing, a callback its finalizers reach runs only if the VM's
-- finalizer policy lets it, and the failures recorded then are bounded. See
-- 'FinalizerPolicy' and 'finalizerEvidenceLimit'.
--
-- Nothing in this module is public. It holds the state and hands out stack
-- indices; the package's public library exposes neither.
module Hetoimasia.Scripting.Lua.Internal.Vm
  ( -- * The VM
    Vm
  , Phase (..)
  , newVm
  , closeVm
    -- * Construction
  , VmSpec (..)
  , unmanagedSpec
  , FinalizerPolicy (..)
  , allocateVm
  , openLibraries
  , failConstruction
  , cleanupEvidence
    -- * Finalizers
  , finalizerAllowed
  , finalizerEvidenceLimit
    -- * Operations
  , withOpenVm
    -- * Callbacks
  , runCallback
    -- * Escaped Haskell failures
  , recordEscape
  , raiseEscape
  , discardEscape
    -- * Retained dependencies
  , retainRelease
    -- * Identity and the value boundary's bookkeeping
  , vmIdentity
  , noteActionRun
  , operationActionRuns
  , valuesPrepared
  , markValuesPrepared
  , nextModuleSlot
  , RunContext
  , setRunContext
  , runContext
    -- * Probes
  , vmState
  , vmPhase
  , stackDepth
  , probeReferenceSlot
  ) where

import Control.Concurrent (ThreadId, myThreadId)
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
  , finally
  , fromException
  , mask
  , mask_
  , onException
  , rethrowIO
  , throwIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (unless, when)
import Data.ByteString (useAsCString)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (delete)
import Data.Maybe (maybeToList)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import System.IO.Unsafe (unsafePerformIO)
import Foreign.C (CChar, CInt (CInt), CSize (CSize))
import Foreign.Ptr (Ptr, nullPtr)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure
  ( Operation
  , operation
  , operationText
  , throwFailure
  , withOperationContext
  )
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( CloseFailure (CloseFailure)
  , CloseFault (CloseFault)
  , CloseSource (..)
  , ErrorValue (ErrorAbsent)
  , FaultKind (MemoryExhausted)
  , FinalizerEvidenceTruncated (FinalizerEvidenceTruncated)
  , FinalizerRefused
  , LuaFault (LuaFault)
  , VmClosed (VmClosed)
  , VmNotOwned (VmNotOwned)
  , VmReentered (VmReentered)
  , classify
  , closeSourceLabel
  , luaComponent
  , renderFailure
  )
import Hetoimasia.Scripting.Lua.Internal.Library
  ( Library
  , libraryModuleName
  , libraryOpener
  )
import Hetoimasia.Scripting.Lua.Internal.Value (VmIdentity (VmIdentity))
import Lua
  ( CFunction
  , StackIndex
  , State (State)
  , StatusCode (StatusCode)
  , fromStackIndex
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
  , vmCallers ∷ !(IORef [ThreadId])
    -- ^ The threads running one of this VM's callbacks right now. Each adds
    -- and removes only itself, and each reads it only to ask whether it is
    -- one, so it needs no gate.
  , vmOwnerThread ∷ !(Maybe ThreadId)
    -- ^ The VM's execution owner, for a VM an owner constructed: the one thread
    -- that may run Lua on it or close it. 'Nothing' for a VM nobody owns.
  , vmFinalizers ∷ !FinalizerPolicy
    -- ^ What a callback a finalizer reaches may do while the VM closes.
  , vmClosingDropped ∷ !(IORef Int)
    -- ^ How many finalizer failures the close did not record, past
    -- 'finalizerEvidenceLimit'.
  , vmIdentity ∷ !VmIdentity
    -- ^ A number no other VM of the process shares. What a handle this VM issues
    -- carries, and what is checked when one is used.
  , vmActionRuns ∷ !(IORef Int)
    -- ^ How many binding actions have started during the operation that is
    -- running. Reset when an operation takes the gate; what a fault reads to say
    -- whether an action may have changed something before it failed.
  , vmValuesReady ∷ !(IORef Bool)
    -- ^ Whether the registry's share of the value boundary has been made.
  , vmModuleSlots ∷ !(IORef Int)
    -- ^ The next module slot. Slots are never reused.
  , vmRunContext ∷ !(IORef (Maybe RunContext))
    -- ^ The module and entry point the running operation is executing, so that a
    -- fault raised under it can say which. Reset when an operation takes the gate.
  }

-- | What a callback reached from a Lua finalizer may do while its VM closes.
data FinalizerPolicy
  = -- | Every callback runs, as it would from anywhere else. What a VM made by
    -- 'newVm' alone has.
    FinalizersUnrestricted
  | -- | Only the named callbacks run. Any other is refused with
    -- 'FinalizerRefused' without running, and the refusal is recorded as close
    -- evidence. The empty set, the default for an owner, runs none.
    FinalizersAllow !(Set Text)

-- | Whether the VM's policy lets this callback run from a finalizer.
finalizerAllowed ∷ Vm → Text → Bool
finalizerAllowed vm name = case vmFinalizers vm of
  FinalizersUnrestricted → True
  FinalizersAllow allowed → name `Set.member` allowed

-- | How many failures a close records from its finalizers, refusals included.
--
-- A finalizer is script-controlled and can fail as often as it can be called,
-- so keeping every failure would let a script decide how much the close
-- remembers. The first this many are kept, in the order they happened, and one
-- further entry says how many were dropped ('FinalizerEvidenceTruncated').
finalizerEvidenceLimit ∷ Int
finalizerEvidenceLimit = 64

-- | How a VM is made, beyond the libraries it opens.
data VmSpec = VmSpec
  { specBudget ∷ !(Maybe Int)
    -- ^ A byte budget the interpreter's allocator holds itself to, for fixtures
    -- that need an allocation failure at a chosen point. 'Nothing' is Lua's own
    -- allocator.
  , specOwner ∷ !(Maybe ThreadId)
    -- ^ The VM's execution owner, if it has one.
  , specFinalizers ∷ !FinalizerPolicy
  }

-- | A VM nobody owns, whose finalizers' callbacks all run, on Lua's allocator:
-- what 'newVm' makes.
unmanagedSpec ∷ VmSpec
unmanagedSpec = VmSpec Nothing Nothing FinalizersUnrestricted

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
-- if the operation left the registry as it found it. The bridge takes no
-- @luaL_ref@ reference of its own, so the answer should never move. A loaded
-- module is kept in a slot of a table the bridge owns instead, so loading one
-- does not move it either; the modules that are live are counted from that table
-- ('Hetoimasia.Scripting.Lua.Internal.Module.liveModuleReferences').
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
-- closed, through the same teardown any close runs, before the failure is
-- raised, and a failure of that close is retained beside it.
newVm ∷ [Library] → IO Vm
newVm libraries = mask_ $ do
  vm ← allocateVm unmanagedSpec
  opened ← tryWithContext (openLibraries vm libraries)
  case opened of
    Right () → pure vm
    Left failure → failConstruction vm failure

-- | Allocate a VM and the control state around it, opening nothing.
--
-- The caller is masked, and the VM is the caller's from this return: whatever
-- the caller does next, closing it is the caller's to do. The one Lua operation
-- that cannot be protected, because there is no state yet to protect it with,
-- reports an allocation failure by answering a null state rather than by
-- raising, which is why it is the entry used.
allocateVm ∷ VmSpec → IO Vm
allocateVm spec = do
  state ← case specBudget spec of
    Nothing → hetoimasia_lua_newstate
    Just limit → hetoimasia_lua_newstate_budgeted (fromIntegral (max 0 limit))
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
  callers ← newIORef []
  dropped ← newIORef 0
  identity ← atomicModifyIORef' identityCounter (\last' → (last' + 1, VmIdentity (last' + 1)))
  runs ← newIORef 0
  ready ← newIORef False
  slots ← newIORef 0
  context ← newIORef Nothing
  pure (Vm state gate phase escape closing releases finished callers (specOwner spec) (specFinalizers spec) dropped identity runs ready slots context)

-- | Open exactly the named standard libraries, in order, as one operation of
-- the VM: under its gate, by its owner, restoring the stack it borrowed.
openLibraries ∷ Vm → [Library] → IO ()
openLibraries vm libraries =
  withOpenVm vm openOperation $ \state → traverse_ (openLibrary state) libraries

-- | End a VM's construction that failed: close the VM through 'closeVm', so a
-- partly initialized state is torn down as a finished one is, and raise the
-- construction's failure with everything the close failed with retained beside
-- it. The failure keeps its own type and context.
failConstruction ∷ Vm → ExceptionWithContext SomeException → IO a
failConstruction vm primary = do
  closed ← tryWithContext (closeVm vm)
  composed ← composeCleanup (Just primary) (either cleanupEvidence (const []) closed)
  rethrowIO (maybe primary id composed)

-- | The cleanup failures a failed close stands for, each under the label of
-- its source, in the order they were recorded.
--
-- A 'CloseFault' stands for each failure it collected, with the context each
-- was caught with; anything else is one failure of the close itself.
cleanupEvidence ∷ ExceptionWithContext SomeException → [(Text, ExceptionWithContext SomeException)]
cleanupEvidence failed@(ExceptionWithContext _ exception) = case fromException exception of
  Just (CloseFault failures) →
    [(closeSourceLabel source, cause) | CloseFailure source cause ← failures]
  Nothing → [("lua close", failed)]

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
-- behind for the next one. An operation asked by one of this VM's own callbacks
-- is refused before any of that.
withOpenVm ∷ HasCallStack ⇒ Vm → Operation → (State → IO a) → IO a
withOpenVm vm name body = mask_ $ do
  refuseReentry vm name
  refuseForeign vm name
  -- Interruptible, and deliberately the only interruptible point: a caller
  -- waiting for a VM that is busy may still be cancelled.
  takeMVar (vmGate vm)
  phase ← readIORef (vmPhaseRef vm)
  case phase of
    Open → do
      let state = vmState vm
      entry ← lua_gettop state
      writeIORef (vmActionRuns vm) 0
      writeIORef (vmRunContext vm) Nothing
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
--
-- A close asked by one of this VM's own callbacks, including one a finalizer
-- runs during the teardown, is refused rather than left waiting for itself.
closeVm ∷ Vm → IO ()
closeVm vm = mask $ \restore → do
  withOperationContext luaComponent closeOperation [] (refuseReentry vm closeOperation)
  withOperationContext luaComponent closeOperation [] (refuseForeign vm closeOperation)
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

-- | Refuse an operation asked by a thread that is running one of this VM's
-- callbacks.
--
-- The operation that ran the callback holds the gate until the callback has
-- returned, so waiting for it would be waiting for ever. Nothing is touched
-- before the refusal: no gate, no stack, no Lua.
refuseReentry ∷ HasCallStack ⇒ Vm → Operation → IO ()
refuseReentry vm name = do
  self ← myThreadId
  callers ← readIORef (vmCallers vm)
  when (self `elem` callers) $
    throwFailure luaComponent name [] (VmReentered (operationText name))

-- | Refuse an operation asked by a thread that is not this VM's execution
-- owner, when it has one.
--
-- Made before the gate is taken and before anything is read from the VM's
-- state, so a refused attempt runs no Lua and leaves no mark: the rightful
-- owner, which may be inside the VM at this very moment, is not disturbed.
refuseForeign ∷ HasCallStack ⇒ Vm → Operation → IO ()
refuseForeign vm name = case vmOwnerThread vm of
  Nothing → pure ()
  Just owner → do
    self ← myThreadId
    phase ← readIORef (vmPhaseRef vm)
    -- A closed VM has nothing left to own: every thread is told it is closed.
    unless (self == owner || phase == Closed) $
      throwFailure luaComponent name [] (VmNotOwned (operationText name))

-- | Run a callback's action with its thread marked as one of this VM's
-- callers, so that what it asks of this same VM is refused rather than left
-- waiting for the operation that called it.
runCallback ∷ Vm → IO a → IO a
runCallback vm action = do
  self ← myThreadId
  atomicModifyIORef' (vmCallers vm) (\callers → (self : callers, ()))
  action
    `finally` atomicModifyIORef' (vmCallers vm) (\callers → (delete self callers, ()))

-- | Close the interpreter, then release what its callbacks borrowed.
--
-- Every release is attempted; their failures, and any failure a Haskell
-- finalizer raised while @lua_close@ ran it, are collected into one
-- 'CloseFault' rather than letting the first one hide the rest, each with the
-- context it was caught with and the source it came from. A finalizer's failure
-- belongs to no caller's operation, so nothing else would ever observe it.
teardown ∷ Vm → IO ()
teardown vm = do
  hetoimasia_lua_close (vmState vm)
  -- Every finalizer that failed, in the order they ran, and anything an
  -- operation left behind.
  escaped ← atomicModifyIORef' (vmClosingEscapes vm) (\held → ([], reverse held))
  dropped ← atomicModifyIORef' (vmClosingDropped vm) (\count → (0, count))
  stranded ← takeEscape vm
  releases ← atomicModifyIORef' (vmReleases vm) (\retained → ([], retained))
  -- Each release runs uninterruptibly, as a scope's release does: it is a Haskell
  -- release with a controlled blocking duration, so a cancellation of the owner
  -- waits for it instead of being delivered inside it and mistaken for the
  -- release's own failure. The close above, which runs Lua's finalizers, is not
  -- run that way.
  outcomes ← traverse (uninterruptibleMask_ . tryWithContext @SomeException) (reverse releases)
  truncation ←
    if dropped > 0
      then do
        recorded ← tryWithContext @SomeException (throwIO (FinalizerEvidenceTruncated dropped))
        pure [CloseFailure FromTruncation captured | Left captured ← [recorded ∷ Either (ExceptionWithContext SomeException) ()]]
      else pure []
  let finalizerFailures =
        [CloseFailure (finalizerSource cause) captured | captured@(ExceptionWithContext _ cause) ← escaped]
      strandedFailures = [CloseFailure FromStrandedOperation captured | captured ← maybeToList stranded]
      releaseFailures = [CloseFailure FromRelease captured | Left captured ← outcomes]
      failures = finalizerFailures <> truncation <> strandedFailures <> releaseFailures
  unless (null failures) (throwIO (CloseFault failures))
  where
    finalizerSource cause = case fromException cause of
      Just (_ ∷ FinalizerRefused) → FromRefusedFinalizer
      Nothing → FromFinalizer

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
    Closing → do
      -- Bounded, because a finalizer is script-controlled: the first
      -- 'finalizerEvidenceLimit' failures are kept and the rest only counted.
      kept ←
        atomicModifyIORef'
          (vmClosingEscapes vm)
          (\held → if length held >= finalizerEvidenceLimit then (held, False) else (captured : held, True))
      unless kept (atomicModifyIORef' (vmClosingDropped vm) (\count → (count + 1, ())))
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

closeOperation ∷ Operation
closeOperation = operation "close-vm"

newOperation ∷ Operation
newOperation = operation "new-vm"

-- | Whether the interpreter was allocated at all.
stateReachable ∷ State → Bool
stateReachable (State pointer) = pointer /= nullPtr

-- | A new interpreter, or a null state when one could not be allocated.
foreign import ccall unsafe "hetoimasia_lua_bridge.h hetoimasia_lua_newstate"
  hetoimasia_lua_newstate ∷ IO State

-- | A new interpreter whose allocator refuses to grow past a byte budget, or a
-- null state when one could not be allocated within it.
foreign import ccall unsafe "hetoimasia_lua_bridge.h hetoimasia_lua_newstate_budgeted"
  hetoimasia_lua_newstate_budgeted ∷ CSize → IO State

-- | Close an interpreter, running its finalizers, and release what its
-- allocator owned.
--
-- @safe@: the finalizers it runs include Haskell callbacks, and the close can
-- take as long as they do.
foreign import ccall safe "hetoimasia_lua_bridge.h hetoimasia_lua_close"
  hetoimasia_lua_close ∷ State → IO ()

-- | Open one standard library, with the whole operation inside one protected
-- Lua call.
--
-- @safe@: an opener runs Lua, and a module already in @package.loaded@ can be
-- anything, including something that calls back into Haskell.
foreign import ccall safe "hetoimasia_lua_bridge.h hetoimasia_lua_requiref"
  hetoimasia_lua_requiref ∷ State → Ptr CChar → CFunction → CInt → IO StatusCode

showText ∷ Show a ⇒ a → Text
showText = Text.pack . show

-- | The identities issued so far.
identityCounter ∷ IORef Word64
identityCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE identityCounter #-}

-- | A binding's action is about to start on this VM.
noteActionRun ∷ Vm → IO ()
noteActionRun vm = atomicModifyIORef' (vmActionRuns vm) (\count → (count + 1, ()))

-- | How many binding actions have started during the running operation.
operationActionRuns ∷ Vm → IO Int
operationActionRuns = readIORef . vmActionRuns

-- | Whether the registry's share of the value boundary has been made.
valuesPrepared ∷ Vm → IO Bool
valuesPrepared = readIORef . vmValuesReady

markValuesPrepared ∷ Vm → IO ()
markValuesPrepared vm = writeIORef (vmValuesReady vm) True

-- | The next module slot, never issued twice.
nextModuleSlot ∷ Vm → IO Int
nextModuleSlot vm = atomicModifyIORef' (vmModuleSlots vm) (\slot → (slot + 1, slot + 1))

-- | The module (name, version) and entry point (none while it is loading) an
-- operation is executing.
type RunContext = (Text, Text, Maybe Text)

-- | Say what the running operation is executing.
setRunContext ∷ Vm → RunContext → IO ()
setRunContext vm = writeIORef (vmRunContext vm) . Just

-- | What the running operation is executing, if it is a module.
runContext ∷ Vm → IO (Maybe RunContext)
runContext = readIORef . vmRunContext
