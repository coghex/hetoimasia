-- | What a scheduled owner's segment runners share: reading what a wait asked for,
-- closing a suspended coroutine, running an action of the VM so that a fault of the
-- task is told from a failure of the host, and how an exit ends tasks.
--
-- Nothing here is new behaviour. It is the code "Hetoimasia.Scripting.Lua.Scheduled.Run"
-- had, moved so that the segments of plain tasks and of script instances use the one
-- definition.
module Hetoimasia.Scripting.Lua.Scheduled.Shared
  ( countOf
  , durationOf
  , closeSuspended
  , settledOrRaise
  , exitOf
  , waitReport
  , waitReportFor
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , catch
  , fromException
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Concurrent.STM (atomically)
import Control.Monad (when)
import Data.IORef (IORef, modifyIORef', readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds, zeroDuration)
import Hetoimasia.Scripting.Lua.Internal.Fault (raisedByApplication)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Owner
  ( OwnedVm
  , Task
  , WaitRequest (waitArguments, waitKind)
  , closeTask
  )
import Hetoimasia.Scripting.Lua.Registration (WaitKind (WaitElapsed, WaitLogical, WaitSettlement))
import Hetoimasia.Scripting.Lua.Runtime.Types
  ( CallFault (BoundaryFailed, LuaFailed)
  , ExitKind (ExitCancelled, ExitFailed)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (ReasonCode (ValidationFault), RecoverySafety (RecoverySafe), failureReason)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure (TaskFailure))
import Hetoimasia.Scripting.Lua.Provider.State (WaitStatus (WaitPending, WaitRefused, WaitSettled), waitStatus)
import Hetoimasia.Scripting.Lua.Provider.Types (ProviderState, Requester)
import Hetoimasia.Scripting.Lua.Scheduler (SegmentReport (ReportFailed, ReportWaitElapsed, ReportWaitRefused, ReportWaitRequest, ReportWaitTicks, ReportYielded), WaitRefusal (WaitRequestRefused))
import Hetoimasia.Scripting.Lua.Value (Value (VCapability, VInteger), capabilityKey)

-- | A wait's first argument as a whole number of ticks. Anything that is not a
-- non-negative integer is read as none, which the scheduler refuses as a wait for
-- no ticks: the operation's schema is what keeps a script from asking.
countOf ∷ [Value] → Word64
countOf = \case
  [VInteger n] | n >= 0 → fromIntegral n
  _ → 0

-- | A wait's first argument as nanoseconds, read the same way.
durationOf ∷ [Value] → Duration
durationOf = \case
  [VInteger n] | n >= 0, Right duration ← durationFromNanoseconds AllowZero (toInteger n) → duration
  _ → zeroDuration

-- | Close a suspended task's coroutine, once, on this thread. A failure of the
-- close is raised, for the scheduler to keep as evidence.
--
-- The scheduler keeps a synchronous failure of the close, but an asynchronous
-- exception that reaches it is raised unrecorded, and the coroutine is closed
-- and forgotten by then: it is kept here, by task, before it goes on.
closeSuspended ∷ OwnedVm → IORef (Map TaskId Task) → IORef [(TaskId, SomeException)] → TaskId → IO ()
closeSuspended owned tasks kept identity = do
  held ← Map.lookup identity <$> readIORef tasks
  case held of
    Nothing → pure ()
    Just task → do
      modifyIORef' tasks (Map.delete identity)
      closeTask owned task `catch` \(failure ∷ SomeException) → do
        when (isJust (fromException failure ∷ Maybe SomeAsyncException)) $
          modifyIORef' kept (<> [(identity, failure)])
        throwIO failure

-- | Run one action of the VM, answering the fault of the task it raised, or
-- raising what is not the task's own.
--
-- A task's fault can be raised with the failures of closing its coroutine, which
-- the script's own error did not stop: those are cleanup evidence, kept, and no
-- part of the task's outcome.
settledOrRaise ∷ IORef [(Text, ExceptionWithContext SomeException)] → IO a → IO (Either CallFault a)
settledOrRaise extra action = do
  ran ← tryWithContext @SomeException action
  case ran of
    Right value → pure (Right value)
    Left failure@(ExceptionWithContext context exception)
      | raisedByApplication context → rethrowIO failure
      | Just fault ← fromException exception → retained context >> pure (Left (BoundaryFailed fault))
      | Just fault ← fromException exception → retained context >> pure (Left (LuaFailed fault))
      | otherwise → rethrowIO failure
  where
    retained context =
      modifyIORef' extra (<> [(cleanupFailureLabel found, cleanupFailureException found) | found ← cleanupFailuresInContext context])

-- | How a failure that ended the owner ends its tasks.
exitOf ∷ ExceptionWithContext SomeException → ExitKind
exitOf (ExceptionWithContext _ exception) = case fromException exception of
  Just (_ ∷ SomeAsyncException) → ExitCancelled
  Nothing → ExitFailed

-- | What a wait the script asked for tells the scheduler, with the cursor the task
-- is left with.
--
-- A wait for a request's settlement names the request by the key of the handle the
-- script gave, which the value boundary has already checked is a live handle of the
-- type the operation declares. An argument that is anything else is not a wait: it
-- fails the task, which a validated registration never makes happen.
waitReport ∷ v → WaitRequest → SegmentReport v
waitReport cursor request = case waitKind request of
  WaitLogical → ReportWaitTicks cursor (countOf (waitArguments request))
  WaitElapsed → ReportWaitElapsed cursor (durationOf (waitArguments request))
  WaitSettlement → case waitArguments request of
    [VCapability handle] → ReportWaitRequest cursor (capabilityKey handle)
    _ → ReportFailed (TaskFailure (failureReason ValidationFault "a wait for a request without a request handle") RecoverySafe)

-- | What a wait the script asked for tells the scheduler, for the requester whose code asked it.
--
-- A wait for a request is looked at now, on the owner's thread, with the request service the
-- owner was granted. The request's own requester is the only one that may wait for it; one
-- that is not, a handle that names no request, and an owner with no service are refused, which
-- fails the task and owes its continuation a close, as any refused wait does. A request that
-- has settled already is no wait: the task yields and goes on, still inside the tick it was
-- woken for. One that has not is waited for, and the owner wakes the task, at a safe boundary,
-- when it has.
waitReportFor ∷ Maybe ProviderState → Requester → v → WaitRequest → IO (SegmentReport v)
waitReportFor provider requester cursor request = case waitKind request of
  WaitSettlement → case (provider, waitArguments request) of
    (Just service, [VCapability handle]) →
      atomically (waitStatus service requester (capabilityKey handle)) <&> \case
        WaitRefused _ → ReportWaitRefused cursor WaitRequestRefused
        WaitSettled → ReportYielded cursor
        WaitPending → ReportWaitRequest cursor (capabilityKey handle)
    _ → pure (ReportWaitRefused cursor WaitRequestRefused)
  _ → pure (waitReport cursor request)
  where
    (<&>) = flip fmap
