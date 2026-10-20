-- | What the accounting-wait examples share: a wait running on a thread of its own,
-- as an application thread would block in it, and the modules of Lua the windows
-- need.
--
-- Every example runs real instances or tasks on a real supervised scheduled owner
-- under the injected clock and the fake timer of "Test.LuaRuntime.Scheduled.Support".
-- An example knows a wait is pending by the thread being parked in STM, and what the
-- owner has reached by blocking on a gate a binding opens, never by sleeping.
module Test.LuaRuntime.Accounting.Support
  ( -- * A wait on a thread of its own
    PendingWait
  , beginWait
  , awaitPending
  , isPending
  , resultOf
  , cancelWait
    -- * Gates the application's own code waits at
  , Gate
  , newGate
  , passGate
  , awaitGateEntered
  , openGate
    -- * The modules
  , refusedAfterTick
  , refusedGatedShutdown
  , refusedClosing
  , stoppableClosing
  , closeRaises
  , retiresOnStop
  , retiresThenFails
  , retiresThenFailsLast
  , drainsBroken
  , stabilize
  , refusedLeased
  , overflowLeased
  , failsAfterTick
    -- * The tasks
  , windowTasks
  , windowTasksRef
  , closesGated
  , refusedClosing'
  , blockAfterTicks
    -- * Grants
  , grant
    -- * Holding the owner
  , holdingSafely
  , releasing
    -- * Owners
  , startPlain
    -- * Examples that expect the wait to end with a failure
  , failingWait
  , retainedFailure
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread, yield)
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar, tryReadMVar)
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import System.Timeout (Timeout)
import Test.LuaRuntime.Support (withBoundary)
import Control.Exception (SomeException, finally, fromException, mask_, onException, throwIO, try)
import Control.Monad (forM_)
import Data.Word (Word64)
import Hetoimasia.Runtime.Supervision (RuntimeControl, WorkerPolicy)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Test.LuaRuntime.Instance.Support (hooksModule, record)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Scheduled.Support (SFixture, admitTask', awaitEntered, releaseGate, request, scheduled, startScheduled)

-- A wait on a thread of its own -----------------------------------------------------

-- | A wait for the owner's accounting, running on a thread of its own, and what it
-- ended with.
data PendingWait = PendingWait
  { waitingThread ∷ !ThreadId
  , waitingResult ∷ !(MVar (Either SomeException AccountingWait))
  }

-- | Begin a wait on a thread of its own. Its snapshot is taken when that thread runs,
-- so an example that needs the snapshot before something else happens waits for the
-- wait to be pending first.
beginWait ∷ RuntimeControl → ScheduledOwner → IO PendingWait
beginWait control owner = do
  result ← newEmptyMVar
  -- Masked until the wait runs, so that a cancellation which arrives first still ends in a result.
  thread ← mask_ (forkIOWithUnmask (\unmask → try (unmask (awaitScheduledAccounting control owner)) >>= putMVar result))
  pure (PendingWait thread result)

-- | Block until the wait is parked in STM. Its snapshot has been taken by then, and it
-- has not returned: a thread parked in a transaction is a wait that did not find its
-- condition.
--
-- A wait that has already ended is not pending, and an example that expects one parked fails at
-- once and does not loop on a thread that has finished.
awaitPending ∷ PendingWait → IO ()
awaitPending waiting = do
  ended ← tryReadMVar (waitingResult waiting)
  case ended of
    Just result → ioError (userError ("the wait ended before it was seen parked: " <> either show show result))
    Nothing →
      threadStatus (waitingThread waiting) >>= \case
        ThreadBlocked BlockedOnSTM → pure ()
        _ → yield >> awaitPending waiting

-- | Whether the wait has not ended.
isPending ∷ PendingWait → IO Bool
isPending waiting = maybe True (const False) <$> tryReadMVar (waitingResult waiting)

-- | What the wait ended with, waiting for it.
resultOf ∷ PendingWait → IO (Either SomeException AccountingWait)
resultOf = readMVar . waitingResult

-- | Cancel the wait, as an asynchronous exception on its thread, and wait until it has ended.
cancelWait ∷ PendingWait → IO ()
cancelWait waiting = killThread (waitingThread waiting) >> () <$ resultOf waiting

-- Gates --------------------------------------------------------------------------------

-- | A gate the application's own code waits at: an escalation callback, a classifier of
-- outcomes. It is entered, and then passed when the example opens it.
data Gate = Gate !(MVar ()) !(MVar ())

newGate ∷ IO Gate
newGate = Gate <$> newEmptyMVar <*> newEmptyMVar

-- | Reach the gate, and wait until it is opened.
passGate ∷ Gate → IO ()
passGate (Gate entered proceed) = () <$ tryPutMVar entered () >> readMVar proceed

-- | Block until something has reached the gate.
awaitGateEntered ∷ Gate → IO ()
awaitGateEntered (Gate entered _) = readMVar entered

-- | Let everything at the gate, and everything that comes to it, go on.
openGate ∷ Gate → IO ()
openGate (Gate _ proceed) = () <$ tryPutMVar proceed ()

-- Modules ------------------------------------------------------------------------------

-- | A callback that waits a tick and then waits for no ticks, which the scheduler
-- refuses: the instance fails in the boundary, not in the segment.
refusedAfterTick ∷ ModuleSource
refusedAfterTick =
  hooksModule
    "refusedaftertick"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    sched.wait_ticks(1)"
    , "    sched.wait_ticks(0)"
    , "  end)"
    , "end"
    ]

-- | The same, with a @shutdown@ that waits at the @shutdown@ gate.
refusedGatedShutdown ∷ ModuleSource
refusedGatedShutdown =
  hooksModule
    "refusedgatedshutdown"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    sched.wait_ticks(1)"
    , "    sched.wait_ticks(0)"
    , "  end)"
    , "end"
    , "function shutdown(self, reason)"
    , "  " <> record <> "('shutdown ' .. self.id .. ' ' .. reason)"
    , "  fx.block('shutdown')"
    , "  " <> record <> "('shutdown done ' .. self.id)"
    , "end"
    ]

-- | The same, holding a variable whose closing handler waits at the @close@ gate: the
-- scheduler closes the refused coroutine inside the segment.
refusedClosing ∷ ModuleSource
refusedClosing =
  hooksModule
    "refusedclosing"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() fx.block('close') end})"
    , "    sched.wait_ticks(1)"
    , "    sched.wait_ticks(0)"
    , "  end)"
    , "end"
    ]

-- | A callback that waits two ticks holding a variable whose closing handler waits at
-- the @close@ gate. Stopped by a control, its coroutine is closed by the owner at a
-- boundary.
stoppableClosing ∷ ModuleSource
stoppableClosing =
  hooksModule
    "stoppableclosing"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() fx.block('close') end})"
    , "    sched.wait_ticks(2)"
    , "  end)"
    , "end"
    ]

-- | A callback that waits two ticks holding a variable whose closing handler raises: stopped by a
-- control, the instance ends and the failure of closing its coroutine is cleanup evidence that
-- ends the owner.
closeRaises ∷ ModuleSource
closeRaises =
  hooksModule
    "closeraises"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() error('close boom') end})"
    , "    sched.wait_ticks(2)"
    , "  end)"
    , "end"
    ]

-- | Holds an asynchronously retired resource named for it, which its stop leaves pending.
retiresOnStop ∷ ModuleSource
retiresOnStop =
  hooksModule
    "retiresonstop"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_async('res-stop')"
    , "  api.connect('tick', function(self, event) end)"
    , "end"
    ]

-- | Holds a resource whose release the example breaks, which its drain at the end of the instance
-- raises; its @shutdown@ waits at the @shutdown@ gate, which holds the ending open before the drain.
drainsBroken ∷ ModuleSource
drainsBroken =
  hooksModule
    "drainsbroken"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open('drain-res')"
    , "  api.connect('tick', function(self, event) end)"
    , "end"
    , "function shutdown(self, reason) fx.block('shutdown') end"
    ]

-- | Holds an asynchronously retired resource named for it, and fails when it is delivered an event,
-- which leaves the resource pending and the application to be told.
retiresThenFails ∷ ModuleSource
retiresThenFails = retiresThenFailsOn "retiresthenfails" "res-fail"

-- | The same, over a resource of its own, for a second instance that fails.
retiresThenFailsLast ∷ ModuleSource
retiresThenFailsLast = retiresThenFailsOn "retiresthenfailslast" "res-fail-last"

retiresThenFailsOn ∷ Text.Text → Text.Text → ModuleSource
retiresThenFailsOn name resource =
  hooksModule
    name
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_async('" <> resource <> "')"
    , "  api.connect('tick', function(self, event) error('callback boom') end)"
    , "end"
    ]

-- | Give whatever is going to happen a fair chance to, without sleeping: yield this many times,
-- or until the wait has ended. A bound on the looking and never a wait for the result.
stabilize ∷ PendingWait → IO ()
stabilize waiting = go (5000 ∷ Int)
  where
    go 0 = pure ()
    go n = do
      pending ← isPending waiting
      if pending then yield >> go (n - 1) else pure ()

-- | Holds an asynchronously retired resource, and fails by a refused wait after a tick.
refusedLeased ∷ ModuleSource
refusedLeased =
  hooksModule
    "refusedleased"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_async('async-res')"
    , "  api.connect('tick', function(self, event)"
    , "    sched.wait_ticks(1)"
    , "    sched.wait_ticks(0)"
    , "  end)"
    , "end"
    ]

-- | Holds an asynchronously retired resource, and waits two ticks.
overflowLeased ∷ ModuleSource
overflowLeased =
  hooksModule
    "overflowleased"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_async('async-res')"
    , "  api.connect('tick', function(self, event)"
    , "    sched.wait_ticks(2)"
    , "  end)"
    , "end"
    ]

-- | A callback that raises after a tick.
failsAfterTick ∷ ModuleSource
failsAfterTick =
  hooksModule
    "failsaftertick"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    sched.wait_ticks(1)"
    , "    error('callback boom')"
    , "  end)"
    , "end"
    ]

-- Tasks --------------------------------------------------------------------------------

-- | The identity of the module of tasks the windows add.
windowTasksRef ∷ ModuleRef
windowTasksRef = ModuleRef "windowtasks" "1"

-- | Tasks that wait for ticks and then hold the owner at a gate.
windowTasks ∷ ModuleSource
windowTasks =
  ModuleSource
    windowTasksRef
    ( Text.encodeUtf8 . Text.unlines $
        [ "function block_after(name, n)"
        , "  sched.wait_ticks(n)"
        , "  fx.block(name)"
        , "  return 1"
        , "end"
        , "function refused_closing(name)"
        , "  local guard <close> = setmetatable({}, {__close = function() error('close boom') end})"
        , "  fx.block(name)"
        , "  sched.wait_ticks(0)"
        , "end"
        , "function close_at(name)"
        , "  local guard <close> = setmetatable({}, {__close = function() fx.block(name) end})"
        , "  sched.wait_ticks(1)"
        , "end"
        ]
    )
    [EntryPoint "block_after" Required [SText, SInteger] [SInteger], EntryPoint "close_at" Required [SText] [], EntryPoint "refused_closing" Required [SText] []]

-- | A task of that module that waits a tick holding a variable whose closing handler waits at this gate.
closesGated ∷ Text.Text → TaskRequest
closesGated gate' =
  TaskRequest
    { requestModule = windowTasksRef
    , requestEntry = "close_at"
    , requestArguments = [VText gate']
    , requestClass = OrdinaryClass
    , requestKind = OneShot
    , requestName = Nothing
    }

-- | A task of that module that holds a variable whose closing handler raises, waits at this gate, and then
-- waits for no ticks, which the scheduler refuses: the scheduler closes its coroutine, and the close fails.
refusedClosing' ∷ Text.Text → TaskRequest
refusedClosing' gate' =
  TaskRequest
    { requestModule = windowTasksRef
    , requestEntry = "refused_closing"
    , requestArguments = [VText gate']
    , requestClass = OrdinaryClass
    , requestKind = OneShot
    , requestName = Nothing
    }

-- | A task of that module: wait this many ticks and then wait at this gate.
blockAfterTicks ∷ Text.Text → Int → TaskRequest
blockAfterTicks gate' ticks =
  TaskRequest
    { requestModule = windowTasksRef
    , requestEntry = "block_after"
    , requestArguments = [VText gate', VInteger (fromIntegral ticks)]
    , requestClass = OrdinaryClass
    , requestKind = OneShot
    , requestName = Nothing
    }

-- Grants -------------------------------------------------------------------------------

-- | Grant a step of this many nanoseconds, expecting it accepted.
grant ∷ ScheduledOwner → Word64 → IO ()
grant owner n =
  grantScheduledStep (scheduledEndpoint owner) (nanoseconds n) >>= \case
    GrantAccepted _ → pure ()
    other → ioError (userError ("expected the grant accepted, found " <> show other))

-- Holding the owner --------------------------------------------------------------------

-- | Run this while the owner is held inside a segment, as "Test.LuaRuntime.Scheduled.Support"'s
-- own helper does, but let the owner go if the body raises, so that a failing example fails and
-- does not hang the protected exit of the boundary it ran in.
holdingSafely ∷ SFixture → ScheduledOwner → IO a → IO a
holdingSafely fixture owner body = do
  ticket ← admitTask' fixture owner "holder" (request "block_in" [VText "holder"] ControlClass OneShot Nothing)
  awaitEntered fixture "holder"
  result ← body `onException` releaseGate fixture "holder"
  releaseGate fixture "holder"
  _ ← waitTask ticket
  pure result

-- | Run this, and however it ends open every gate an example parks the owner at (the gate of a
-- hook, of a closing handler, of a task, of the application's own callback), so that an example
-- that fails fails, and does not leave a protected exit waiting on an owner nothing can wake.
releasing ∷ SFixture → [Gate] → IO a → IO a
releasing fixture gates action =
  action `finally` do
    forM_ ["holder", "hold", "close", "shutdown", "a", "b", "blk", "y", "obs"] (releaseGate fixture)
    forM_ gates openGate

-- Owners ---------------------------------------------------------------------------------

-- | A plain scheduled owner that also loads the module of tasks the windows add.
startPlain ∷ SFixture → LuaRuntime → Text.Text → WorkerPolicy → SchedulerBounds → IO ScheduledOwner
startPlain fixture runtime label policy bounds =
  startScheduled fixture runtime base {scheduledVm = (scheduledVm base) {vmModules = vmModules (scheduledVm base) <> [windowTasks]}}
  where
    base = scheduled fixture label policy bounds

-- Examples that expect the wait to end with a failure -------------------------------------

-- | Run a scenario inside a boundary, which begins a wait and drives the owner to a failure, and
-- require that the wait ended by raising one: the supervised failure, rethrown, and never an answer.
-- The boundary's own end may carry the failure; a timeout of the example's bound is not that failure and is
-- not swallowed, and the outcome is read without blocking.
failingWait ∷ SFixture → [Gate] → (RuntimeControl → LuaRuntime → IO PendingWait) → IO ()
failingWait fixture gates scenario = do
  outcome ← newEmptyMVar
  stalled ← try @SomeException . withBoundary $ \control runtime → releasing fixture gates $ do
    waiting ← scenario control runtime
    resultOf waiting >>= putMVar outcome
  case stalled of
    Left raised | Just (_ ∷ Timeout) ← fromException raised → throwIO raised
    _ → pure ()
  tryReadMVar outcome >>= \case
    Nothing → ioError (userError ("the example recorded no outcome for the wait" <> either (\raised → ": " <> show raised) (const "") stalled))
    Just (Right answered) → ioError (userError ("the wait answered " <> show answered))
    Just (Left _) → pure ()

-- | The scenario leaves the owner holding a cleanup failure it has retained, and parked at this gate, with
-- nothing owed and no grant outstanding. The wait is begun while the owner is still held, before the
-- boundary that retains the failure, so that the owner's acknowledgement at the end of that boundary
-- would answer it if the owner wrongly wrote one; it must stay parked while the owner is parked, and end
-- with the failure once the gate is opened. The scenario returns the owner and what lets it go on, which is
-- handed the action that begins the wait and calls it, while the owner is held, before it lets the owner go.
retainedFailure ∷ SFixture → [Gate] → Text.Text → (RuntimeControl → LuaRuntime → IO (ScheduledOwner, IO PendingWait → IO PendingWait)) → IO ()
retainedFailure fixture gates gate' scenario = failingWait fixture gates $ \control runtime → do
  (owner, go) ← scenario control runtime
  waiting ← go (do w ← beginWait control owner; awaitPending w; pure w)
  awaitEntered fixture gate'
  stabilize waiting
  awaitPending waiting
  releaseGate fixture gate'
  pure waiting
