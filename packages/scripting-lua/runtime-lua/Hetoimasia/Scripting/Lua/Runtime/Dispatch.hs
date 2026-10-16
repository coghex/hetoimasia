-- | The owner's side: the thread that runs the VM serves its calls, one at a
-- time and to completion, and settles every one of them exactly once.
--
-- 'runOwner' is the worker's run action. It runs 'withVmOwner' on the worker's
-- own thread, so that thread is the VM's execution owner, constructs and
-- initializes the VM inside it, and serves from inside its body.
--
-- = The body
--
-- It resolves the modules the configuration loaded, publishes readiness and
-- opens admission in one transaction, and only then serves. Serving waits for a
-- call or for the stop request, the request first when both are there: a stop
-- is not postponed behind a backlog. A call is dequeued and marked in flight in
-- one transaction, run through 'callEntry' with that module's handle, and
-- settled, with the in-flight mark cleared, in one more. Nothing is settled
-- before it has run and nothing runs twice.
--
-- = What a failure of a call is
--
-- A refused value, a script error, a call to a binding that is not yet
-- supported, an entry point that is gone, and a module the owner did not load
-- are faults of the call: they settle it, as data, and the owner serves the
-- next one. A failure raised by application code is not, whatever its type. A
-- binding's action may throw a 'BoundaryFault' or a 'LuaFault' as easily as
-- anything else, and the exception's type cannot say which it is, so the
-- bridge marks every failure that escapes application code and this module
-- reads the mark, not the type. A marked failure is a failure of the host: it
-- ends the owner, unconverted, and is the worker's primary outcome.
--
-- = Every exit
--
-- Whatever ends the body, including a failure of the application's code and
-- a cancellation, closes admission first, in the same transaction that
-- discards what has not settled: the in-flight call as started, every queued
-- call as not started, each with how the owner exited. That happens before
-- 'withVmOwner' begins to close the VM, because closing can block for as long
-- as a finalizer runs and no call may be accepted meanwhile. A failure that
-- ended the owner is then rethrown as it was, with its own type and context.
module Hetoimasia.Scripting.Lua.Runtime.Dispatch
  ( runOwner
  ) where

import Control.Concurrent.STM (TVar, atomically, orElse, writeTVar)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , tryWithContext
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Worker (StopToken, awaitStopRequest)
import Hetoimasia.Scripting.Lua.Internal.Boundary (moduleChunk)
import Hetoimasia.Scripting.Lua.Internal.Fault (raisedByApplication)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedInternalVm)
import Hetoimasia.Scripting.Lua.Internal.Vm (vmIdentity)
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (..)
  , FaultOperation (CallEntry)
  , FaultReason (ValueRefused)
  , ModuleHandle
  , ModuleRef
  , ModuleSource (sourceIdentity)
  , OwnedVm
  , VmConfig (vmModules, vmOwnerName)
  , callEntry
  , loadedModule
  , withVmOwner
  )
import qualified Hetoimasia.Scripting.Lua.Owner as Owner
import Hetoimasia.Scripting.Lua.Runtime.Admission
  ( finishCall
  , openAdmission
  , shutAndDiscard
  , takeNext
  )
import Hetoimasia.Scripting.Lua.Runtime.Types
import Hetoimasia.Scripting.Lua.Value (Side (Arguments), ValueRefusal (ValueRefusal))
import Hetoimasia.Scripting.Lua.Value (VmIdentity)

-- | The worker's run action for one owner.
--
-- The handoff is where readiness is published: the control, once the VM is
-- initialized and admission is open, and nothing before.
runOwner ∷ StopToken → Control → TVar (Maybe Control) → VmConfig → IO ()
runOwner token control handoff config = do
  outcome ← tryWithContext @SomeException (withVmOwner config (serve token control handoff config))
  -- An exit before the body, a failure of the close itself: nothing of the
  -- calls is left to settle then, and this records how the owner ended.
  mask_ (atomically (shutAndDiscard control (either exitOf (const ExitStopped) outcome)))
  either rethrowIO pure outcome

-- | The body of the owner's lifetime.
serve ∷ StopToken → Control → TVar (Maybe Control) → VmConfig → OwnedVm → IO ()
serve token control handoff config owned = do
  served ← tryWithContext @SomeException $ do
    handles ← Map.fromList . catMaybes <$> traverse (resolve owned) (map sourceIdentity (vmModules config))
    atomically (openAdmission control >> writeTVar handoff (Just control))
    loop handles
  case served of
    Right () → pure ()
    Left failure → do
      -- Before the VM closes: admission ends and what is unsettled is discarded.
      mask_ (atomically (shutAndDiscard control (exitOf failure)))
      rethrowIO failure
  where
    identity = vmIdentity (ownedInternalVm owned)
    label = vmOwnerName config
    loop handles = do
      next ←
        atomically
          ( (Left <$> awaitStopRequest token)
              `orElse` (Right <$> takeNext control)
          )
      case next of
        Left () → atomically (shutAndDiscard control ExitStopped)
        Right call → runOne handles call >> loop handles
    runOne handles call = mask $ \restore → do
      ran ← tryWithContext @SomeException (restore (execute owned identity label handles call))
      case ran of
        Right outcome → atomically (finishCall control call outcome)
        Left failure@(ExceptionWithContext context exception)
          | raisedByApplication context → rethrowIO failure
          | Just fault ← fromException exception → settleFault call (BoundaryFailed fault)
          | Just fault ← fromException exception → settleFault call (LuaFailed fault)
          | otherwise → rethrowIO failure
    settleFault call fault = atomically (finishCall control call (CallFaulted fault))

-- | The handle of a module the configuration loaded.
resolve ∷ OwnedVm → ModuleRef → IO (Maybe (ModuleRef, ModuleHandle))
resolve owned ref = fmap ((,) ref) <$> loadedModule owned ref

-- | Run one call, answering how it settled, or raising what is not the call's
-- own fault.
execute ∷ OwnedVm → VmIdentity → Text → Map ModuleRef ModuleHandle → QueuedCall → IO Outcome
execute owned identity label handles call =
  case Map.lookup (queuedModule call) handles of
    Nothing → pure (CallFaulted (ModuleNotLoaded (queuedModule call)))
    Just handle → case preparedValue (queuedPayload call) of
      OverBound rule →
        pure . CallFaulted . BoundaryFailed $
          BoundaryFault
            { boundaryOwner = label
            , boundaryVm = identity
            , boundaryOperation = CallEntry
            , boundaryModule = Just (queuedModule call)
            , boundaryEntry = Just (queuedEntry call)
            , boundaryBinding = Nothing
            , boundaryChunk = moduleChunk (queuedModule call)
            , boundaryReason = ValueRefused (ValueRefusal Arguments 0 [] rule 0)
            , boundaryEffect = Owner.NoEffect
            , boundaryTraceback = Nothing
            }
      WithinBounds arguments → CallReturned <$> callEntry owned handle (queuedEntry call) arguments

-- | How a failure that ended the owner ends its calls.
exitOf ∷ ExceptionWithContext SomeException → ExitKind
exitOf (ExceptionWithContext _ exception) = case fromException exception of
  Just (_ ∷ SomeAsyncException) → ExitCancelled
  Nothing → ExitFailed
