-- | Tasks: a module's entry point run as a Lua coroutine on its VM's owner.
--
-- A task is the host's way to run script code that gives control back. The owner
-- starts it with bounded arguments and runs it a segment at a time: each segment
-- ends when the script returns, yields, or waits, and the owner decides when the
-- next begins. Nothing here is a scheduler. It runs no clock, keeps no queue and
-- picks no order; it reports what the script asked for and waits to be told to
-- go on.
--
-- = Where a task lives
--
-- A task is a Lua thread of the owner's VM, anchored in a table the bridge keeps
-- in the registry until it ends, so that the collector cannot take it while the
-- host holds the handle. Every operation on it is an operation of the VM, made
-- by the VM's one execution owner and holding its gate: starting, resuming and
-- closing a task from another thread is refused with
-- 'Hetoimasia.Scripting.Lua.Internal.Fault.VmNotOwned', from one of the VM's own
-- callbacks with 'Hetoimasia.Scripting.Lua.Internal.Fault.VmReentered', and
-- after the VM has closed with 'Hetoimasia.Scripting.Lua.Internal.Fault.VmClosed'.
-- A handle is a value that names a slot of one VM and is checked against it on
-- every use; Lua never sees one, and it is never a 'Value'.
--
-- = Yielding and waiting
--
-- A script gives control back through a scheduler operation the owner's policy
-- grants (see 'Hetoimasia.Scripting.Lua.Internal.Registration.yieldOperation').
-- The binding's handler decides, in Haskell, whether the call can reach the
-- scheduler at all; the yield itself is made afterwards, in C, once every Haskell
-- frame has returned, because @lua_yield@ unwinds with a @longjmp@ exactly as
-- @lua_error@ does and that must never cross a Haskell frame. A call that cannot
-- reach the scheduler -- from an entry point called once, a module's chunk, a
-- finalizer, a coroutine the script created, a metamethod -- is refused as a
-- typed fault of the call, never run, so a script can never suspend something
-- the host is not resuming. A coroutine that yields with no scheduler operation,
-- by calling @coroutine.yield@ itself, would be suspended to no one: that is a
-- fault too.
--
-- = A segment's end
--
-- Whichever way a segment ends, a Haskell failure that reached a callback during
-- it is raised in preference to what Lua reported, even if the script caught the
-- stand-in with @pcall@ or @coroutine.resume@ and went on to yield or return:
-- the same precedence 'Hetoimasia.Scripting.Lua.Internal.Module.callEntry' gives
-- it. A segment that ends in any fault leaves nothing behind: the host closes
-- the coroutine, running its pending to-be-closed variables, and the task cannot
-- be resumed again.
--
-- = Closing
--
-- A suspended task can be closed, which runs its pending to-be-closed variables
-- on the owner's thread. An error one of them raises is reported with the close,
-- and the task is closed all the same: closing is terminal, so a failed close is
-- not tried again and a second close of any task is harmless. A VM that is
-- closed with tasks still suspended closes each of them first, attempting every
-- one whatever another does, and keeps the failures as the close's evidence.
module Hetoimasia.Scripting.Lua.Internal.Task
  ( Task
  , taskModule
  , taskEntry
  , TaskStart (..)
  , TaskStep (..)
  , WaitRequest (..)
  , startTask
  , startTaskVia
  , startTaskCaptured
  , resumeTask
  , closeTask
  , liveTaskReferences
    -- * For the module loader, which runs coroutines of its own beside tasks
  , Cleanup (..)
  , cleanUp
  , closeAnchored
  , evidenceOf
  , raising
  ) where

import Control.Exception (ExceptionWithContext, SomeException, rethrowIO, tryWithContext)
import Control.Monad (void, when)
import Data.Maybe (maybeToList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Scripting.Lua.Internal.Boundary
import Hetoimasia.Scripting.Lua.Internal.ExportTypes (CaptureHandle, Hook, hookName)
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( CloseSource (FromCoroutineClose)
  , ErrorValue (ErrorAbsent)
  , FaultKind (CallFailed, MemoryExhausted)
  , LuaFault (LuaFault)
  , classify
  , closeSourceLabel
  , luaComponent
  , renderFailure
  )
import Hetoimasia.Scripting.Lua.Internal.Marshal
import Hetoimasia.Scripting.Lua.Internal.Module
  ( Host (hostVm)
  , ModuleHandle
  , Prepared (..)
  , effectNow
  , faultOf
  , readResults
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Module as Module
import Hetoimasia.Scripting.Lua.Internal.Registration (WaitKind)
import Hetoimasia.Scripting.Lua.Internal.Value
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Suspension (..)
  , escapePending
  , nextTaskSlot
  , operationActionRuns
  , noteTaskEnded
  , noteTaskLive
  , raiseEscape
  , setActiveTask
  , setRunContext
  , takeSuspension
  , vmIdentity
  , withCleanupEscapes
  , withOpenVm
  )
import Lua (StackIndex (StackIndex), State, fromStackIndex, lua_gettop, lua_settop, data LUA_OK)

-- | Where a task is.
data TaskPhase
  = Suspended
  | Ended !TaskEnd

-- | A task: an entry point running as a coroutine of one VM.
--
-- A value that names a slot of one VM, not authority: every use checks the VM,
-- and Lua never sees one.
data Task = Task
  { taskVm ∷ !VmIdentity
  , taskSlot ∷ !Int
  , taskModule ∷ !ModuleRef
  , taskEntry ∷ !Text
  , taskResults ∷ ![Schema]
  , taskPhase ∷ !(IORef TaskPhase)
  }

instance Eq Task where
  a == b = taskPhase a == taskPhase b

instance Show Task where
  show task = "Task " <> show (taskModule task) <> " " <> show (taskEntry task)

-- | What a wait is for, and what the script gave to say.
data WaitRequest = WaitRequest
  { waitKind ∷ !WaitKind
  , waitNamespace ∷ !Text
  , waitBinding ∷ !Text
    -- ^ The scheduler operation the script called, by namespace and name.
  , waitArguments ∷ ![Value]
    -- ^ Its arguments, checked against the operation's schemas and the owner's
    -- limits.
  }
  deriving (Eq, Show)

-- | How a segment of a task ended.
data TaskStep
  = -- | The entry point returned, with its results, checked like those of a
    -- call. The task has ended.
    Completed ![Value]
  | -- | The script yielded. Resume it to go on.
    Yielded
  | -- | The script waits. Resume it when the wait is over; the host waits for
    -- nothing itself.
    Waiting !WaitRequest
  deriving (Eq, Show)

-- | What starting a task came to.
data TaskStart
  = -- | The entry point is optional and the module does not define it. Nothing
    -- ran.
    TaskEntryAbsent
  | -- | The entry point ran to its first yield, wait or return. A task that
    -- returned has ended already and cannot be resumed.
    TaskStarted !Task !TaskStep
  deriving (Eq, Show)

startOperation, resumeOperation, closeOperation :: Operation
startOperation = operation "start-task"
resumeOperation = operation "resume-task"
closeOperation = operation "close-task"

-- | Run a module's entry point as a task, up to its first yield, wait or return.
--
-- The handle, the entry point and its arguments are checked exactly as a call's
-- are, and refused with no effect before anything runs; an optional entry point
-- the module does not define answers 'TaskEntryAbsent' and runs nothing. A
-- failure of the first segment is raised, and leaves no task behind.
startTask ∷ HasCallStack ⇒ Host → ModuleHandle → Text → [Value] → IO TaskStart
startTask = startTaskWith Module.NoLead

-- | Run an entry point as a task through a driver's entry point: the driver's
-- function is what the coroutine runs, handed the entry point first and then the
-- values. See 'Module.Lead'. The task is named for the entry point's own module
-- and entry, which is what a fault and a binding it calls report.
startTaskVia ∷ HasCallStack ⇒ Host → ModuleHandle → Text → ModuleHandle → Text → [Value] → IO TaskStart
startTaskVia host driver driverName = startTaskWith (Module.Lead driver driverName) host

-- | Start a task through a driver's entry point, handing it a captured hook, the
-- capture's @self@ and its facade: see 'Module.LeadCaptured'. A hook the capture has
-- none of answers 'TaskEntryAbsent' and runs nothing; a handle another owner issued,
-- or whose capture was released, is refused before anything runs.
startTaskCaptured ∷ HasCallStack ⇒ Host → ModuleHandle → Text → CaptureHandle → Hook → [Value] → IO TaskStart
startTaskCaptured host driver driverName capture hook = startTaskWith (Module.LeadCaptured driver driverName capture hook) host driver (hookName hook)

startTaskWith ∷ HasCallStack ⇒ Module.Lead → Host → ModuleHandle → Text → [Value] → IO TaskStart
startTaskWith lead host handle name arguments =
  withOperationContext luaComponent startOperation [("module", moduleRefName ref), ("entry", name)] $
    withOpenVm vm startOperation $ \state → do
      entry ← lua_gettop state
      prepared ← Module.prepareEntryWith lead host StartTask startOperation handle name arguments state entry
      case prepared of
        PreparedAbsent → pure TaskEntryAbsent
        PreparedReady declared count → do
          slot ← nextTaskSlot vm
          created ← newTaskCoroutine state slot count
          when (created /= LUA_OK) $ do
            value ← renderFailure state entry
            lua_settop state entry
            -- The collector is held while it is made, so nothing executed.
            throwFailure luaComponent startOperation [] $
              (faultOf host StartTask ref (Just name) (ScriptFailed (classify created) value)) {boundaryEffect = NoEffect}
          lua_settop state entry
          phase ← newIORef Suspended
          let task = Task (vmIdentity vm) slot ref name (Module.entryResults declared) phase
          noteTaskLive vm slot
          TaskStarted task <$> runSegment host StartTask startOperation task True state entry
  where
    vm = hostVm host
    ref = Module.attributedTo lead handle

-- | Run a suspended task's next segment: it goes on from the yield or wait it
-- stopped at, to the next, or to its return.
--
-- Refused with no effect: a task another owner issued, and one that has ended,
-- whether it returned, failed, or was closed.
resumeTask ∷ HasCallStack ⇒ Host → Task → IO TaskStep
resumeTask host task =
  withOperationContext luaComponent resumeOperation [("module", moduleRefName (taskModule task)), ("entry", taskEntry task)] $
    withOpenVm vm resumeOperation $ \state → do
      entry ← lua_gettop state
      requireSuspended host ResumeTask resumeOperation task
      runSegment host ResumeTask resumeOperation task False state entry
  where
    vm = hostVm host

-- | Close a suspended task, running its pending to-be-closed variables on the
-- owner's thread.
--
-- Terminal and idempotent: closing a task that has ended -- returned, failed or
-- been closed -- does nothing. An error a to-be-closed variable raises is the
-- close's fault, and the task is closed all the same, so a second close is
-- harmless and does not report it again.
closeTask ∷ HasCallStack ⇒ Host → Task → IO ()
closeTask host task =
  withOperationContext luaComponent closeOperation [("module", moduleRefName (taskModule task)), ("entry", taskEntry task)] $
    withOpenVm vm closeOperation $ \state → do
      entry ← lua_gettop state
      when (taskVm task /= vmIdentity vm) $
        refuse CloseTask closeOperation TaskForeign
      phase ← readIORef (taskPhase task)
      case phase of
        Ended _ → pure ()
        Suspended → do
          setRunContext vm (moduleRefName (taskModule task), moduleRefVersion (taskModule task), Just (taskEntry task))
          (closing, escapes) ← withCleanupEscapes vm (closeTaskCoroutine state (taskSlot task))
          -- Terminal before anything is raised.
          end host task TaskClosed
          failure ← closeFailure state entry closing
          effect ← effectNow vm
          -- What the close failed with, in the order the failures happened: a
          -- Haskell failure a to-be-closed variable's callback raised outranks the
          -- error Lua reported, and every one is kept, the first as the failure and
          -- the others beside it as cleanup evidence.
          scripted ←
            traverse
              ( \value →
                  captured $
                    throwFailure luaComponent closeOperation [] $
                      (faultOf host CloseTask (taskModule task) (Just (taskEntry task)) (ScriptFailed CallFailed value)) {boundaryEffect = effect}
              )
              (if standIn (closingMarker closing) escapes then Nothing else failure)
          case escapes <> maybeToList scripted of
            [] → pure ()
            primary : others → do
              composed ← composeCleanup (Just primary) [(closeSourceLabel FromCoroutineClose, other) | other ← others]
              maybe (pure ()) rethrowIO composed
  where
    vm = hostVm host
    refuse op name problem =
      throwFailure luaComponent name [] $
        (faultOf host op (taskModule task) (Just (taskEntry task)) (TaskRefused problem)) {boundaryEffect = NoEffect}

-- | How many tasks' coroutines the VM anchors: a probe for this package's own
-- fixtures, which check that none is left behind by an ended task.
liveTaskReferences ∷ Host → IO Int
liveTaskReferences host =
  withOpenVm (hostVm host) (operation "count-tasks") $ \state → do
    entry ← lua_gettop state
    counted ← taskReferences state
    lua_settop state entry
    case counted of
      Right count → pure count
      Left status →
        throwFailure luaComponent (operation "count-tasks") [] $
          blankFault (Module.hostBoundary host) CloseTask (ScriptFailed (classify status) ErrorAbsent)

-- | A task is not resumable if it is another owner's, or it has ended.
requireSuspended ∷ HasCallStack ⇒ Host → FaultOperation → Operation → Task → IO ()
requireSuspended host op name task = do
  when (taskVm task /= vmIdentity (hostVm host)) $ refuse TaskForeign
  phase ← readIORef (taskPhase task)
  case phase of
    Ended how → refuse (TaskEnded how)
    Suspended → pure ()
  where
    refuse problem =
      throwFailure luaComponent name [] $
        (faultOf host op (taskModule task) (Just (taskEntry task)) (TaskRefused problem)) {boundaryEffect = NoEffect}

-- | The task is over: it cannot be resumed, and the VM has no coroutine of it to
-- close.
end ∷ Host → Task → TaskEnd → IO ()
end host task how = do
  writeIORef (taskPhase task) (Ended how)
  noteTaskEnded (hostVm host) (taskSlot task)

-- | What closing a task's coroutine failed with, if it did, read off the stack
-- from where the operation entered.
closeFailure ∷ State → StackIndex → TaskClosing → IO (Maybe ErrorValue)
closeFailure state entry closing
  | closingFailed closing = do
      value ← renderFailure state entry
      lua_settop state entry
      pure (Just value)
  | otherwise = lua_settop state entry >> pure Nothing

-- | Run one segment of a task and say how it ended. The task is suspended before
-- and, unless it returns or fails, after; see the module header for what a
-- failure leaves.
runSegment ∷ HasCallStack ⇒ Host → FaultOperation → Operation → Task → Bool → State → StackIndex → IO TaskStep
runSegment host op name task starting state entry = do
  setRunContext vm (moduleRefName ref, moduleRefVersion ref, Just (taskEntry task))
  thread ← taskThread state slot
  void (takeSuspension vm)
  setActiveTask vm (Just thread)
  segment ← resumeSegment state slot starting (length (taskResults task))
  setActiveTask vm Nothing
  suspension ← takeSuspension vm
  let -- Lua has run by now: a Haskell failure that reached a callback outranks
      -- what is reported, whatever Lua did with its stand-in.
      afterLua ∷ [(Text, ExceptionWithContext SomeException)] → FaultReason → Maybe Text → IO TaskStep
      afterLua evidence reason trace = do
        effect ← effectNow vm
        lua_settop state entry
        raising evidence $ do
          raiseEscape vm
          throwFailure luaComponent name [] $
            (faultOf host op ref (Just (taskEntry task)) reason) {boundaryEffect = effect, boundaryTraceback = trace}
  case segmentOutcome segment of
    SegmentUnresumable → do
      -- The coroutine is not where the host left it: a script resumed or closed
      -- the thread it was running on. Whatever it still holds to close is closed,
      -- which runs script code, so what that did is reported.
      end host task TaskFaulted
      cleanup ← cleanUp host state entry slot
      lua_settop state entry
      runs ← operationActionRuns vm
      let effect
            | runs > 0 = BindingRan
            | cleanupRan cleanup = LuaRan
            | otherwise = NoEffect
      raising (cleanupEvidence cleanup) $ do
        raiseEscape vm
        throwFailure luaComponent name [] $
          (faultOf host op ref (Just (taskEntry task)) (TaskRefused TaskNotSuspended)) {boundaryEffect = effect}
    SegmentArity → do
      end host task TaskCompleted
      let expected = length (taskResults task)
      if segmentStatus segment /= LUA_OK
        then afterLua [] (ScriptFailed MemoryExhausted ErrorAbsent) Nothing
        else afterLua [] (ValueRefused (ValueRefusal Results 0 [] (RuleArity expected (segmentCount segment)) 0)) Nothing
    SegmentCompleted → do
      end host task TaskCompleted
      read' ← readResults host state entry (taskResults task) (segmentCount segment)
      case read' of
        Left (reason, traced) → afterLua [] reason traced
        Right values → do
          lua_settop state entry
          raiseEscape vm
          pure (Completed values)
    SegmentFailed → do
      end host task TaskFaulted
      -- The coroutine is closed apart from the segment, so what closing it raised
      -- is told from what the segment did: the failure is on the stack, with above
      -- it the error closing raised, if that was another.
      cleanup ← cleanUp host state entry slot
      value ← renderFailure state entry
      afterLua (cleanupEvidence cleanup) (ScriptFailed (classify (segmentStatus segment)) value) (segmentTrace segment)
    SegmentYielded → do
      escaped ← escapePending vm
      case suspension of
        Just suspended | not escaped → do
          lua_settop state entry
          pure $ case suspended of
            SuspensionYield → Yielded
            SuspensionWait kind space binding values → Waiting (WaitRequest kind space binding values)
        _ → do
          -- Suspended with no granted operation, or after a failure the script
          -- caught: the task is not suspended where anyone can resume it.
          (closing, escapes) ← withCleanupEscapes vm (closeTaskCoroutine state slot)
          end host task TaskFaulted
          failure ← closeFailure state entry closing
          extra ← evidenceOf (closingMarker closing) escapes failure
          afterLua extra UnscheduledYield Nothing
  where
    vm = hostVm host
    ref = taskModule task
    slot = taskSlot task

-- | Close the coroutine anchored in a slot, running its pending to-be-closed
-- variables on the owner's thread, and answer what closing it failed with as cleanup
-- evidence instead of raising it: each Haskell failure a closing handler's callback
-- raised, and the error Lua reported unless that is only the stand-in for one of them.
-- Terminal: the slot is emptied whatever the close did, so a failed close is not tried
-- again. The caller names what is running, for a fault a handler raises.
closeAnchored ∷ Host → State → StackIndex → Int → IO [(Text, ExceptionWithContext SomeException)]
closeAnchored host state entry slot = do
  (closing, escapes) ← withCleanupEscapes (hostVm host) (closeTaskCoroutine state slot)
  failure ← closeFailure state entry closing
  evidenceOf (closingMarker closing) escapes failure

-- | Close a coroutine that is not suspended where the host left it, keeping what
-- the close raised apart from the failure the operation has pending. Leaves the
-- error the coroutine died with on the stack, if there was one.
cleanUp ∷ Host → State → StackIndex → Int → IO Cleanup
cleanUp host state entry slot = do
  (closing, escapes) ← withCleanupEscapes (hostVm host) (cleanupTaskCoroutine state slot)
  -- The error closing raised is above the one it died with.
  failure ←
    if cleanupDifferent closing
      then do
        value ← renderFailure state entry
        top ← lua_gettop state
        lua_settop state (StackIndex (fromStackIndex top - 1))
        pure (Just value)
      else pure Nothing
  evidence ← evidenceOf (cleanupMarker closing) escapes failure
  pure (Cleanup evidence (cleanupErrored closing || not (null escapes)))

-- | What closing a coroutine raised, and whether it can have run anything.
data Cleanup = Cleanup
  { cleanupEvidence ∷ ![(Text, ExceptionWithContext SomeException)]
  , cleanupRan ∷ !Bool
  }

-- | The failures of closing a coroutine as cleanup evidence: each Haskell failure
-- a callback raised, with the context it was caught with, and the error Lua
-- reported, unless that is only the stand-in for one of them.
evidenceOf ∷ Bool → [ExceptionWithContext SomeException] → Maybe ErrorValue → IO [(Text, ExceptionWithContext SomeException)]
evidenceOf marker escapes failure = do
  scripted ←
    traverse
      (\value → captured (throwFailure luaComponent closeOperation [] (LuaFault CallFailed "task" value)))
      (if standIn marker escapes then Nothing else failure)
  pure [(closeSourceLabel FromCoroutineClose, failureOf) | failureOf ← escapes <> maybeToList scripted]

-- | Whether the error Lua reported for a close is only the marker standing in for
-- a Haskell failure that has been kept. An error of any other kind, an opaque one
-- included, is the script's own and is reported.
standIn ∷ Bool → [ExceptionWithContext SomeException] → Bool
standIn marker escapes = marker && not (null escapes)

-- | The failure an action raises, with the context it was caught with.
captured ∷ IO () → IO (ExceptionWithContext SomeException)
captured action = do
  caught ← tryWithContext @SomeException action
  case caught of
    Left failure → pure failure
    Right () → error "throwFailure returned"

-- | Raise what the action raises, with the evidence of a cleanup that failed
-- beside it.
raising ∷ [(Text, ExceptionWithContext SomeException)] → IO a → IO a
raising [] action = action
raising evidence action = do
  primary ← tryWithContext @SomeException action
  composed ← composeCleanup (either Just (const Nothing) primary) evidence
  case (composed, primary) of
    (Just failure, _) → rethrowIO failure
    (Nothing, Right result) → pure result
    (Nothing, Left failure) → rethrowIO failure
