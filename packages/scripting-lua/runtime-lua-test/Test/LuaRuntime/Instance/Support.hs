-- | What the script-instance examples share: the scheduled-owner fixture, a
-- registration that adds a counter the hooks name themselves with, modules of
-- hooks written in Lua, and the coordination the examples use instead of sleeping.
--
-- Every example runs real instances on a real supervised scheduled owner, under the
-- injected clock and the fake timer of "Test.LuaRuntime.Scheduled.Support". An
-- example knows what an instance has reached by blocking in STM on its snapshot, or
-- on a gate a binding opens, and never by guessing how long anything takes.
module Test.LuaRuntime.Instance.Support
  ( -- * The fixture
    IFixture (..)
  , newIFixture
  , sf
    -- * The modules
  , echoer
  , slow
  , closing
  , badClose
  , badInit
  , yieldInit
  , badShutdown
  , yieldShutdown
  , failCallback
  , failBoth
  , failClose
  , badWait
  , waitBadShutdown
  , paced
  , holder
  , oneShot
  , gateInit
  , gateShutdown
  , gateFail
  , shared
  , sharedState
  , noHooks
  , hostFailing
  , hostShutdown
  , closeKilled
  , delayedEcho
  , killShutdown
  , gateOneShot
  , initValue
  , shutdownValue
  , hostShutdownBang
  , waitHostShutdown
  , badCloseHostShutdown
  , gated
  , closingGated
  , newestFirst
  , forger
  , direct
  , plainModule
  , moduleNamed
    -- * Configurations
  , instanceBounds'
  , testConfig
  , tickSource
  , instanceSpec
  , startInstances
  , startWith
  , withLimits
    -- * Admitting and driving
  , admit
  , admitWith
  , expectAccepted
  , idOf
  , tickOf
  , tickEvent
  , deliverTick
  , expectDelivered
  , askControl
  , expectControl
  , askUntilTaken
  , settleControl
    -- * Waiting
  , awaitPhase
  , awaitQueued
  , awaitSettled
  , awaitCount
  , holdOwner
  , releaseOwner
  , grantOne
  , awaitDiagnosticsWaiting
  , phaseOf
  , snapshotOf
  , logged
  , logCount
  , failureOf'
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import qualified Data.Text as Text
import Hetoimasia.Runtime.Supervision (RuntimeControl, WorkerPolicy)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled hiding (Policy (..))
import Hetoimasia.Scripting.Lua.Scheduler (Candidate (candidateTask), Policy (..), servable)
import Hetoimasia.Scripting.Lua.Value
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Scheduled.Support
  ( SFixture
  , awaitDiagnostics
  , awaitEntered
  , defaultSchedulerBounds
  , releaseGate
  , effects
  , newSFixture
  , schedRegistration
  , scheduled
  , startScheduled
  )

-- The fixture ------------------------------------------------------------------

-- | The scheduled-owner fixture, a counter the hooks name themselves with, and
-- what the examples admitted by name.
data IFixture = IFixture
  { ifBase ∷ !SFixture
  , ifCounter ∷ !(IORef Int)
  , ifIds ∷ !(IORef (Map Text InstanceId))
  , ifTickets ∷ !(IORef (Map Text InstanceTicket))
  }

newIFixture ∷ IO IFixture
newIFixture = IFixture <$> newSFixture <*> newIORef 0 <*> newIORef Map.empty <*> newIORef Map.empty

sf ∷ IFixture → SFixture
sf = ifBase

-- The modules --------------------------------------------------------------------

record ∷ Text
record = "fx.record"

-- | A module of hooks: its identity, its source and the hooks it declares. Every
-- hook is declared, and the ones the source does not define are absent.
hooksModule ∷ Text → [Text] → ModuleSource
hooksModule name source = ModuleSource (ModuleRef name "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries

-- | Reacts to @tick@ events: names itself, keeps a count in its own @self@.
echoer ∷ ModuleSource
echoer =
  hooksModule
    "echoer"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.count = 0"
    , "  " <> record <> "('init ' .. self.id)"
    , "  api.connect('tick', function(self, event)"
    , "    self.count = self.count + 1"
    , "    " <> record <> "('tick ' .. self.id .. ' n=' .. event.payload.n .. ' seq=' .. event.sequence .. ' t=' .. event.tick .. ' count=' .. self.count)"
    , "  end)"
    , "end"
    , "function update(self, dt) " <> record <> "('update') end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Its callback waits for a tick between two records.
slow ∷ ModuleSource
slow =
  hooksModule
    "slow"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('begin ' .. self.id .. ' ' .. event.payload.n)"
    , "    sched.wait_ticks(1)"
    , "    " <> record <> "('end ' .. self.id .. ' ' .. event.payload.n)"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Its callback holds a variable with a closing handler while it waits.
closing ∷ ModuleSource
closing =
  hooksModule
    "closing"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() " <> record <> "('closed ' .. self.id) end})"
    , "    " <> record <> "('begin ' .. self.id .. ' ' .. event.payload.n)"
    , "    sched.wait_ticks(1)"
    , "    " <> record <> "('end ' .. self.id .. ' ' .. event.payload.n)"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | The same, but the closing handler raises.
badClose ∷ ModuleSource
badClose =
  hooksModule
    "badclose"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() " <> record <> "('closing ' .. self.id) error('close boom') end})"
    , "    sched.wait_ticks(1)"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Connects, and then fails in @init@. Every other hook records, so an example
-- sees that none ran.
badInit ∷ ModuleSource
badInit =
  hooksModule
    "badinit"
    [ "function init(self, api)"
    , "  " <> record <> "('init')"
    , "  api.connect('tick', function(self, event) " <> record <> "('callback') end)"
    , "  error('init boom')"
    , "end"
    , "function update(self, dt) " <> record <> "('update') end"
    , "function run(self, api) " <> record <> "('run') end"
    , "function shutdown(self, reason) " <> record <> "('shutdown') end"
    ]

-- | Yields in @init@, where nothing can suspend.
yieldInit ∷ ModuleSource
yieldInit =
  hooksModule
    "yieldinit"
    [ "function init(self, api) sched.yield() end"
    , "function shutdown(self, reason) " <> record <> "('shutdown') end"
    ]

-- | Raises in @shutdown@.
badShutdown ∷ ModuleSource
badShutdown =
  hooksModule
    "badshutdown"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event) " <> record <> "('tick ' .. self.id) end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. reason) error('shutdown boom') end"
    ]

-- | Waits in @shutdown@, where nothing can suspend.
yieldShutdown ∷ ModuleSource
yieldShutdown =
  hooksModule
    "yieldshutdown"
    [ "function init(self, api) api.connect('tick', function(self, event) end) end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. reason) sched.wait_ticks(1) end"
    ]

-- | A callback that raises.
failCallback ∷ ModuleSource
failCallback =
  hooksModule
    "failcallback"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('failing ' .. self.id)"
    , "    error('callback boom')"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | A callback that raises, and a @shutdown@ that raises too.
failBoth ∷ ModuleSource
failBoth =
  hooksModule
    "failboth"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) error('callback boom') end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. reason) error('shutdown boom') end"
    ]

-- | A callback that raises while it holds a closing handler that raises too: the
-- script's own error is the primary failure, and what closing its coroutine raised
-- is cleanup.
failClose ∷ ModuleSource
failClose =
  hooksModule
    "failclose"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() error('close boom') end})"
    , "    error('callback boom')"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. reason) end"
    ]

-- | A callback that waits, and a @shutdown@ that raises.
waitBadShutdown ∷ ModuleSource
waitBadShutdown =
  hooksModule
    "waitbadshutdown"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) sched.wait_ticks(1) end)"
    , "end"
    , "function shutdown(self, reason) error('shutdown boom') end"
    ]

-- | A callback that waits for no ticks, which the scheduler refuses.
badWait ∷ ModuleSource
badWait =
  hooksModule
    "badwait"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event) sched.wait_ticks(0) end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Callbacks that cost time on the injected clock and yield between two records:
-- their order against another instance's depends on the scheduler alone.
paced ∷ ModuleSource
paced =
  hooksModule
    "paced"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    fx.delay()"
    , "    " <> record <> "('begin ' .. self.id .. ' ' .. event.payload.n)"
    , "    sched.yield()"
    , "    fx.delay()"
    , "    " <> record <> "('end ' .. self.id .. ' ' .. event.payload.n)"
    , "  end)"
    , "end"
    ]

-- | A callback that holds the owner at a gate, so that what an example does
-- meanwhile is all accepted before the owner serves any of it.
holder ∷ ModuleSource
holder =
  hooksModule
    "holder"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) fx.block('hold') end)"
    , "end"
    ]

-- | A one-shot: @run@ waits a tick between two records, and @shutdown@ is told why.
oneShot ∷ ModuleSource
oneShot =
  hooksModule
    "oneshot"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  " <> record <> "('init ' .. self.id)"
    , "  api.connect('tick', function(self, event) " <> record <> "('late ' .. self.id) end)"
    , "end"
    , "function run(self, api)"
    , "  " <> record <> "('run begin ' .. self.id)"
    , "  sched.wait_ticks(1)"
    , "  " <> record <> "('run end ' .. self.id)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | @init@ connects and then waits at a gate before it returns.
gateInit ∷ ModuleSource
gateInit =
  hooksModule
    "gateinit"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event) " <> record <> "('tick ' .. self.id .. ' n=' .. event.payload.n) end)"
    , "  fx.block('init')"
    , "  " <> record <> "('init done ' .. self.id)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | @shutdown@ waits at a gate: an owner retiring it is held in the hook.
gateShutdown ∷ ModuleSource
gateShutdown =
  hooksModule
    "gateshutdown"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event) end)"
    , "end"
    , "function shutdown(self, reason)"
    , "  " <> record <> "('shutdown ' .. self.id .. ' ' .. reason)"
    , "  fx.block('shutdown')"
    , "  " <> record <> "('shutdown done ' .. self.id)"
    , "end"
    ]

-- | @init@ connects, waits at a gate, and then fails.
gateFail ∷ ModuleSource
gateFail =
  hooksModule
    "gatefail"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) " <> record <> "('tick') end)"
    , "  fx.block('init')"
    , "  error('init boom')"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown') end"
    ]

-- | A module that keeps state of its own, shared by every instance of it, beside
-- the @self@ each instance has.
shared ∷ ModuleSource
shared =
  hooksModule
    "shared"
    [ "local calls = 0"
    , "function sharedCount() calls = calls + 1 return calls end"
    , "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.mine = 0"
    , "  api.connect('tick', function(self, event)"
    , "    self.mine = self.mine + 1"
    , "    " <> record <> "('shared ' .. self.id .. ' mine=' .. self.mine .. ' all=' .. sharedCount())"
    , "  end)"
    , "end"
    ]

-- | The identity the shared module is loaded under.
sharedState ∷ ModuleRef
sharedState = ModuleRef "shared" "1"

-- | Defines no hook at all.
noHooks ∷ ModuleSource
noHooks = hooksModule "nohooks" ["local unused = 0"]

-- | A callback that fails the way the host fails: through a binding that throws.
hostFailing ∷ ModuleSource
hostFailing =
  hooksModule
    "hostfailing"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) fx.fail('boom') end)"
    , "end"
    ]

-- | A @shutdown@ that fails the way the host fails.
hostShutdown ∷ ModuleSource
hostShutdown =
  hooksModule
    "hostshutdown"
    [ "function init(self, api) api.connect('tick', function(self, event) end) end"
    , "function shutdown(self, reason) fx.fail('boom') end"
    ]

-- | The same, failing with another failure of the host.
hostShutdownBang ∷ ModuleSource
hostShutdownBang =
  hooksModule
    "hostshutdownbang"
    [ "function init(self, api) api.connect('tick', function(self, event) end) end"
    , "function shutdown(self, reason) fx.fail('bang') end"
    ]

-- | Callbacks that cost time on the injected clock and record: one segment each.
delayedEcho ∷ ModuleSource
delayedEcho =
  hooksModule
    "delayedecho"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    fx.delay()"
    , "    " <> record <> "('tick ' .. self.id .. ' n=' .. event.payload.n)"
    , "  end)"
    , "end"
    ]

-- | A callback that waits holding a closing handler that is cut short as a
-- cancellation is, and a @shutdown@ that records.
closeKilled ∷ ModuleSource
closeKilled =
  hooksModule
    "closekilled"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() " <> record <> "('closing ' .. self.id) fx.fail('kill') end})"
    , "    sched.wait_ticks(1)"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | A @shutdown@ that is cut short as a cancellation is.
killShutdown ∷ ModuleSource
killShutdown =
  hooksModule
    "killshutdown"
    [ "function init(self, api) api.connect('tick', function(self, event) end) end"
    , "function shutdown(self, reason) fx.fail('kill') end"
    ]

-- | A one-shot whose @init@ connects and waits at a gate, and whose @run@ records.
gateOneShot ∷ ModuleSource
gateOneShot =
  hooksModule
    "gateoneshot"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event) " <> record <> "('tick ' .. self.id .. ' n=' .. event.payload.n) end)"
    , "  fx.block('init')"
    , "end"
    , "function run(self, api) " <> record <> "('run ' .. self.id) end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | A module whose @init@ is present and is not a function.
initValue ∷ ModuleSource
initValue = hooksModule "initvalue" ["init = 42", "function shutdown(self, reason) " <> record <> "('shutdown') end"]

-- | A module whose @shutdown@ is present and is not a function.
shutdownValue ∷ ModuleSource
shutdownValue = hooksModule "shutdownvalue" ["function init(self, api) api.connect('tick', function(self, event) end) end", "shutdown = 42"]

-- | A callback that waits, and a @shutdown@ that records and then fails the way the
-- host fails.
waitHostShutdown ∷ ModuleSource
waitHostShutdown =
  hooksModule
    "waithostshutdown"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) sched.wait_ticks(1) end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown') fx.fail('boom') end"
    ]

-- | A callback that waits holding a closing handler that raises, and a @shutdown@
-- that fails the way the host fails.
badCloseHostShutdown ∷ ModuleSource
badCloseHostShutdown =
  hooksModule
    "badclosehostshutdown"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() error('close boom') end})"
    , "    sched.wait_ticks(1)"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) fx.fail('boom') end"
    ]

-- | A callback that waits at a gate, yields, and would then record.
gated ∷ ModuleSource
gated =
  hooksModule
    "gated"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event)"
    , "    fx.block('cb')"
    , "    sched.yield()"
    , "    " <> record <> "('after')"
    , "  end)"
    , "end"
    ]

-- | A callback that holds a closing handler, waits at a gate, yields, and would then
-- record: closed before its instance's shutdown, whichever task the scheduler closes
-- first.
closingGated ∷ ModuleSource
closingGated =
  hooksModule
    "closinggated"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() " <> record <> "('closed ' .. self.id) end})"
    , "    fx.block('cb')"
    , "    sched.yield()"
    , "    " <> record <> "('after')"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | A policy that runs the ready task that waited least: a ghost admitted before a
-- task's replacement is chosen after it.
newestFirst ∷ Policy
newestFirst = Policy "newest first" (\view → candidateTask (last (servable view)))

-- | An instance that calls the layer's own binding with the number of the instance
-- admitted after it, to connect that one beforehand.
forger ∷ ModuleSource
forger =
  hooksModule
    "forger"
    [ "function init(self, api)"
    , "  " <> record <> "('forged ' .. tostring(hetoimasia_instance.connect(2, 'tick')))"
    , "end"
    ]

-- | An instance that connects itself through the layer's own binding, not through its
-- api, and so has a connection the owner records and no function to run for it.
direct ∷ ModuleSource
direct = hooksModule "direct" ["function init(self, api) hetoimasia_instance.connect(1, 'tick') end"]

-- | A module of tasks, for the ordinary work an owner of instances may hold.
plainModule ∷ ModuleSource
plainModule =
  ModuleSource
    (ModuleRef "tasks" "1")
    (Text.encodeUtf8 "function once(label) fx.record(label) return 1 end\nfunction waits(label) sched.wait_ticks(5) return 1 end\nfunction holds(label) fx.block(label) return 1 end\n")
    [EntryPoint "once" Required [SText] [SInteger], EntryPoint "waits" Required [SText] [SInteger], EntryPoint "holds" Required [SText] [SInteger]]

-- | The module of this name among those the examples load.
moduleNamed ∷ Text → ModuleRef
moduleNamed name = ModuleRef name "1"

-- Configurations -----------------------------------------------------------------

-- | Eight live instances, sixteen results, a queue of eight and eight controls.
instanceBounds' ∷ InstanceBounds
instanceBounds' = InstanceBounds 8 16 8 8

-- | The @tick@ source: a record with one integer.
tickSource ∷ EventSource
tickSource = EventSource "tick" (SRecord [("n", SInteger)])

-- | These bounds and the @tick@ source, isolating every failure.
testConfig ∷ InstanceBounds → InstanceConfig
testConfig bounds = defaultInstanceConfig {instanceBounds = bounds, instanceSources = [tickSource]}

-- | The registration of the scheduled examples with the @inst@ namespace: a counter
-- every hook names itself with.
instRegistration ∷ IFixture → Registration
instRegistration fixture =
  either (error . show) id $
    registration [] (registrationNamespaces (schedRegistration (ifBase fixture)) <> [inst])
  where
    inst =
      namespace
        "inst"
        [ stateOperation "next" [] [SInteger] $ \_ → do
            n ← atomicModifyIORef' (ifCounter fixture) (\held → (held + 1, held + 1))
            pure [VInteger (fromIntegral n)]
        ]

-- | An owner of this label hosting instances from these modules.
instanceSpec ∷ IFixture → Text → [ModuleSource] → InstanceConfig → WorkerPolicy → SchedulerBounds → ScheduledSpec
instanceSpec fixture label modules config worker bounds =
  base
    { scheduledVm =
        (scheduledVm base)
          { vmRegistration = instRegistration fixture
          , vmPolicy = ["sched", "fx", "inst"]
          , vmModules = modules
          }
    , scheduledInstances = Just config
    }
  where
    base = scheduled (ifBase fixture) label worker bounds

-- | Start an owner with the default scheduler bounds.
startInstances ∷ IFixture → LuaRuntime → Text → [ModuleSource] → InstanceConfig → WorkerPolicy → IO ScheduledOwner
startInstances fixture runtime label modules config worker =
  startScheduled (ifBase fixture) runtime (instanceSpec fixture label modules config worker defaultSchedulerBounds)

-- | The same owner with these limits on every value that crosses for it.
withLimits ∷ ValueLimits → ScheduledSpec → ScheduledSpec
withLimits limits spec = spec {scheduledVm = (scheduledVm spec) {vmValueLimits = limits}}

-- | Start an owner from a specification.
startWith ∷ IFixture → LuaRuntime → ScheduledSpec → IO ScheduledOwner
startWith fixture = startScheduled (ifBase fixture)

-- Admitting and driving ----------------------------------------------------------

-- | Admit an event-only instance of this module granted the @tick@ source,
-- expecting it accepted, under this name.
admit ∷ IFixture → ScheduledOwner → Text → ModuleRef → IO InstanceTicket
admit fixture owner name ref = admitWith fixture owner name (InstanceRequest ref EventOnly (Just name) OrdinaryClass ["tick"])

-- | Admit an instance, expecting it accepted, under this name.
admitWith ∷ IFixture → ScheduledOwner → Text → InstanceRequest → IO InstanceTicket
admitWith fixture owner name instanceRequest =
  admitInstance (scheduledEndpoint owner) instanceRequest >>= expectAccepted fixture name

expectAccepted ∷ IFixture → Text → InstanceAdmission → IO InstanceTicket
expectAccepted fixture name = \case
  InstanceAccepted identity ticket → do
    atomicModifyIORef' (ifIds fixture) (\held → (Map.insert name identity held, ()))
    atomicModifyIORef' (ifTickets fixture) (\held → (Map.insert name ticket held, ()))
    pure ticket
  InstanceFull → throwIO (userError "expected the instance to be accepted, found it full")
  InstanceAdmissionClosed → throwIO (userError "expected the instance to be accepted, found it closed")

-- | The identity an instance was admitted under this name.
idOf ∷ IFixture → Text → IO InstanceId
idOf fixture name = (Map.! name) <$> readIORef (ifIds fixture)

-- | The ticket an instance was admitted under this name.
tickOf ∷ IFixture → Text → IO InstanceTicket
tickOf fixture name = (Map.! name) <$> readIORef (ifTickets fixture)

-- | A @tick@ event's payload.
tickEvent ∷ Int → Value
tickEvent n = VRecord [("n", VInteger (fromIntegral n))]

-- | Deliver a @tick@ event to the instance of this name.
deliverTick ∷ IFixture → ScheduledOwner → Text → Int → IO Delivery
deliverTick fixture owner name n = do
  identity ← idOf fixture name
  deliverEvent (scheduledEndpoint owner) identity "tick" (tickEvent n)

-- | Deliver, expecting it accepted, and answer its sequence.
expectDelivered ∷ IFixture → ScheduledOwner → Text → Int → IO ()
expectDelivered fixture owner name n =
  deliverTick fixture owner name n >>= \case
    DeliveryAccepted _ → pure ()
    other → throwIO (userError ("expected the delivery accepted, found " <> show other))

-- | Ask for control of the instance of this name.
askControl ∷ IFixture → ScheduledOwner → Text → InstanceControl → IO InstanceControlAnswer
askControl fixture owner name request = do
  identity ← idOf fixture name
  requestInstanceControl (scheduledEndpoint owner) identity request

-- | Ask, expecting the request accepted, and answer its receipt.
expectControl ∷ IFixture → ScheduledOwner → Text → InstanceControl → IO InstanceControlReceipt
expectControl fixture owner name request =
  askControl fixture owner name request >>= \case
    InstanceControlAccepted receipt → pure receipt
    other → throwIO (userError ("expected the request accepted, found " <> show other))

-- | Ask until the answer is not that every reservation is held: a settlement the
-- owner has yet to give back one for.
askUntilTaken ∷ IFixture → ScheduledOwner → Text → InstanceControl → IO InstanceControlAnswer
askUntilTaken fixture owner name request =
  askControl fixture owner name request >>= \case
    InstanceControlFull → yield >> askUntilTaken fixture owner name request
    answer → pure answer

-- | Ask, and wait for what the request came to.
settleControl ∷ IFixture → ScheduledOwner → Text → InstanceControl → IO ControlResult
settleControl fixture owner name request = expectControl fixture owner name request >>= waitInstanceControl

-- Waiting ------------------------------------------------------------------------

-- | The snapshot of the instance of this name, in one transaction.
snapshotOf ∷ IFixture → ScheduledOwner → Text → IO (Maybe InstanceSnapshot)
snapshotOf fixture owner name = do
  identity ← idOf fixture name
  atomically (inspectInstance (scheduledEndpoint owner) identity)

-- | Its phase, if it is still held.
phaseOf ∷ IFixture → ScheduledOwner → Text → IO (Maybe InstancePhase)
phaseOf fixture owner name = fmap snapshotPhase <$> snapshotOf fixture owner name

-- | Block, in STM, until the instance is in this phase.
awaitPhase ∷ IFixture → ScheduledOwner → Text → InstancePhase → IO ()
awaitPhase fixture owner name wanted = do
  identity ← idOf fixture name
  atomically $
    inspectInstance (scheduledEndpoint owner) identity >>= \case
      Just snapshot | snapshotPhase snapshot == wanted → pure ()
      _ → retry

-- | Block, in STM, until the instance holds at least this many unstarted
-- invocations.
awaitQueued ∷ IFixture → ScheduledOwner → Text → Int → IO ()
awaitQueued fixture owner name wanted = do
  identity ← idOf fixture name
  atomically $
    inspectInstance (scheduledEndpoint owner) identity >>= \case
      Just snapshot | snapshotQueued snapshot >= wanted → pure ()
      _ → retry

-- | Block, in STM, until a segment has ended in a wait: an invocation is suspended.
awaitDiagnosticsWaiting ∷ ScheduledOwner → IO ()
awaitDiagnosticsWaiting owner = awaitDiagnostics owner (\counts → diagWaiting counts >= 1)

-- | Grant one logical step of a nanosecond and wait until it has been applied and
-- the work it made due has finished.
grantOne ∷ RuntimeControl → ScheduledOwner → IO ()
grantOne control owner = do
  _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
  _ ← awaitTicksComplete control owner
  pure ()

-- | Hold the owner inside a segment, so that what an example does meanwhile is
-- accepted before the owner serves any of it: an instance of the @holder@ module is
-- delivered an event, and its callback waits at the @hold@ gate. Needs the module
-- loaded and the owner granted nothing else of the @holder@ name.
holdOwner ∷ IFixture → ScheduledOwner → IO ()
holdOwner fixture owner = do
  _ ← admit fixture owner "holder" (moduleNamed "holder")
  awaitPhase fixture owner "holder" Active
  expectDelivered fixture owner "holder" 0
  awaitEntered (sf fixture) "hold"

-- | Let the owner go on.
releaseOwner ∷ IFixture → IO ()
releaseOwner fixture = releaseGate (sf fixture) "hold"

-- | Wait, without sleeping, until the hooks have recorded this many entries.
awaitCount ∷ IFixture → Int → IO ()
awaitCount fixture wanted = do
  seen ← length <$> logged fixture
  if seen >= wanted then pure () else yield >> awaitCount fixture wanted

-- | Wait for the instance's settlement, observing it.
awaitSettled ∷ IFixture → Text → IO InstanceSettlement
awaitSettled fixture name = tickOf fixture name >>= waitInstance

-- | What the hooks recorded, oldest first.
logged ∷ IFixture → IO [Text]
logged = effects . ifBase

-- | How many times the hooks recorded this.
logCount ∷ IFixture → Text → IO Int
logCount fixture wanted = length . filter (== wanted) <$> logged fixture

-- | The failure an instance settled as.
failureOf' ∷ InstanceSettlement → Maybe InstanceFailure
failureOf' settlement = case resultOutcome settlement of
  InstanceFailed failure → Just failure
  _ → Nothing
