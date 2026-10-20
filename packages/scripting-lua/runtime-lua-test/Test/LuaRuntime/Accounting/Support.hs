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
  , refusedLeased
  , overflowLeased
  , failsAfterTick
    -- * The tasks
  , windowTasks
  , windowTasksRef
  , blockAfterTicks
    -- * Grants
  , grant
    -- * Holding the owner
  , holdingSafely
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (SomeException, mask_, onException, try)
import Data.Word (Word64)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Test.LuaRuntime.Instance.Support (hooksModule, record)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Scheduled.Support (SFixture, admitTask', awaitEntered, releaseGate, request)
import Test.LuaRuntime.Support (awaitBlockedOnSTM)

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
awaitPending ∷ PendingWait → IO ()
awaitPending = awaitBlockedOnSTM . waitingThread

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
        ]
    )
    [EntryPoint "block_after" Required [SText, SInteger] [SInteger]]

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
