-- | What the subscription examples share: a fake event provider the examples drive by hand,
-- instances written in Lua that subscribe, unsubscribe and record what their callbacks were
-- handed, owners granted the subscriptions, and the coordination the examples use instead of
-- sleeping.
--
-- Every example runs real instances on a real supervised scheduled owner under the injected
-- clock and fake timer of "Test.LuaRuntime.Scheduled.Support". The provider is a value: it
-- records the subscriptions it was handed, delivers when an example tells it to, from the
-- example's own thread, and reports its retirement as the example sets it. Nothing sleeps; an
-- example knows what has happened by blocking in STM, on a gate, or on what a script recorded.
module Test.LuaRuntime.Subscription.Support
  ( -- * The fake provider
    FakeEvents (..)
  , Subscribed (..)
  , newFakeEvents
  , fakeEventEndpoint
  , ticksEndpoint
  , stateEndpoint
  , awaitSubscribed
  , subscribedCount
  , subscribedAt
  , deliverTo
  , deliverRaw
  , payloadOf
  , finishSubscription
  , finishSubscriptions
  , failRetirement
  , eventsFinish
  , cancelledSubs
  , awaitCancelledSubs
  , onSubscribe
  , onCancelSub

    -- * The instances
  , subSource
  , subConfig
  , subscriber
  , initSubscriber
  , deafSubscriber
  , shutdownSubscriber
  , oneShotSubscriber
  , failingInitSubscriber

    -- * Owners
  , dummyRequests
  , subGrant
  , subscriptionSpec
  , startSubscriber
  , subDiagnostics
  , awaitSubDiagnostic
  , allEndpoints

    -- * Commanding
  , subscriberRequest
  , admitSubscriber
  , command
  , commandWith
  , sync
  , gotLines
  , awaitGot
  , step
  , outstanding
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (finally, throwIO)
import Control.Monad (void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Runtime.Supervision (WorkerPolicy)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (ModuleSource)
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled hiding (Policy (..))
import Hetoimasia.Scripting.Lua.Value
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support (awaitLine)
import Test.LuaRuntime.Scheduled.Support (defaultSchedulerBounds, startScheduled)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)

-- The fake provider --------------------------------------------------------------------

-- | A subscription the provider was handed.
data Subscribed = Subscribed
  { ssIndex ∷ !Int
  , ssFeed ∷ !EventFeed
  , ssInfo ∷ !SubscriptionInfo
  , ssRetirement ∷ !(TVar RetirementState)
  }

-- | A provider the examples drive by hand.
data FakeEvents = FakeEvents
  { feSubs ∷ !(TVar [Subscribed])
  , feCancels ∷ !(TVar [Int])
  , feOnSubscribe ∷ !(IORef (EventSubscription → IO ()))
  , feOnCancel ∷ !(IORef (Int → IO ()))
  }

newFakeEvents ∷ IO FakeEvents
newFakeEvents = FakeEvents <$> newTVarIO [] <*> newTVarIO [] <*> newIORef (\_ → pure ()) <*> newIORef (\_ → pure ())

-- | What the provider does when it is handed a subscription, before it keeps it: an example
-- makes it raise.
onSubscribe ∷ FakeEvents → (EventSubscription → IO ()) → IO ()
onSubscribe fake action = atomicModifyIORef' (feOnSubscribe fake) (const (action, ()))

-- | What the provider does when told interest was withdrawn, after it noted it.
onCancelSub ∷ FakeEvents → (Int → IO ()) → IO ()
onCancelSub fake action = atomicModifyIORef' (feOnCancel fake) (const (action, ()))

-- | The endpoint of this name backed by the fake, delivering @{n = integer}@.
fakeEventEndpoint ∷ FakeEvents → Text → OverloadPolicy → EventEndpoint
fakeEventEndpoint fake name policy =
  EventEndpoint
    { eventName = name
    , eventPayload = SRecord [("n", SInteger)]
    , eventPolicy = policy
    , eventSubscribe = \subscription → do
        readIORef (feOnSubscribe fake) >>= ($ subscription)
        (index, retirement) ← atomically $ do
          held ← readTVar (feSubs fake)
          retirement ← newTVar ProviderPending
          let index = length held
          writeTVar (feSubs fake) (held <> [Subscribed index (subscriptionFeed subscription) (subscriptionInfo subscription) retirement])
          pure (index, retirement)
        pure
          ProviderWork
            { workCancel = do
                atomically (modifyTVar' (feCancels fake) (<> [index]))
                readIORef (feOnCancel fake) >>= ($ index)
            , workRetirement = readTVar retirement
            }
    }

-- | Ordered events.
ticksEndpoint ∷ FakeEvents → EventEndpoint
ticksEndpoint fake = fakeEventEndpoint fake "ticks" OrderedEvents

-- | Replaceable state.
stateEndpoint ∷ FakeEvents → EventEndpoint
stateEndpoint fake = fakeEventEndpoint fake "state" ReplaceableState

-- | Both endpoints.
allEndpoints ∷ FakeEvents → [EventEndpoint]
allEndpoints fake = [ticksEndpoint fake, stateEndpoint fake]

-- | The provider proves every piece of work it was handed over, however an example ends, so an
-- owner that waits for it does not wait for ever.
finishSubscriptions ∷ FakeEvents → IO ()
finishSubscriptions fake = atomically $ do
  held ← readTVar (feSubs fake)
  mapM_ (\found → writeTVar (ssRetirement found) ProviderComplete) held

-- | Run an example, and prove all the provider's work over however it ends.
eventsFinish ∷ FakeEvents → IO a → IO a
eventsFinish fake body = body `finally` finishSubscriptions fake

-- | Block until the provider has been handed this many subscriptions.
awaitSubscribed ∷ FakeEvents → Int → IO ()
awaitSubscribed fake wanted = atomically $ do
  held ← readTVar (feSubs fake)
  if length held >= wanted then pure () else retry

-- | How many subscriptions the provider was handed.
subscribedCount ∷ FakeEvents → IO Int
subscribedCount fake = length <$> atomically (readTVar (feSubs fake))

-- | The nth subscription the provider was handed.
subscribedAt ∷ FakeEvents → Int → IO Subscribed
subscribedAt fake index = do
  held ← atomically (readTVar (feSubs fake))
  case drop index held of
    found : _ → pure found
    [] → throwIO (userError ("the provider was handed no subscription " <> show index))

-- | A delivery's value.
payloadOf ∷ Int → Value
payloadOf n = VRecord [("n", VInteger (fromIntegral n))]

-- | Deliver this value to the nth subscription, at this place.
deliverRaw ∷ FakeEvents → Int → Maybe DueSlot → Value → IO EventAnswer
deliverRaw fake index slot value = do
  found ← subscribedAt fake index
  feedDeliver (ssFeed found) slot value

-- | Deliver @{n}@ to the nth subscription, at this place.
deliverTo ∷ FakeEvents → Int → Maybe DueSlot → Int → IO EventAnswer
deliverTo fake index slot n = deliverRaw fake index slot (payloadOf n)

-- | The provider proves the nth subscription's work over.
finishSubscription ∷ FakeEvents → Int → IO ()
finishSubscription fake index = do
  found ← subscribedAt fake index
  atomically (writeTVar (ssRetirement found) ProviderComplete)

-- | The provider reports the nth subscription's retirement failed.
failRetirement ∷ FakeEvents → Int → RetirementState → IO ()
failRetirement fake index state = do
  found ← subscribedAt fake index
  atomically (writeTVar (ssRetirement found) state)

-- | The subscriptions the provider was told interest in was withdrawn from, in the order.
cancelledSubs ∷ FakeEvents → IO [Int]
cancelledSubs fake = atomically (readTVar (feCancels fake))

-- | Block until the provider has been told about this many withdrawals.
awaitCancelledSubs ∷ FakeEvents → Int → IO ()
awaitCancelledSubs fake wanted = atomically $ do
  held ← readTVar (feCancels fake)
  if length held >= wanted then pure () else retry

-- The instances ---------------------------------------------------------------------------

-- | The commands a script is told, as a record.
subSource ∷ EventSource
subSource =
  EventSource
    "cmd"
    (SRecord [("op", SText), ("key", SOptional SText), ("endpoint", SOptional SText), ("mode", SOptional SText)])

-- | Bounds and sources for an owner of subscribers.
subConfig ∷ InstanceConfig
subConfig = (testConfig instanceBounds') {instanceSources = [subSource, tickSource]}

-- | Lua every subscriber shares: the callback a subscription is given, and what a command does.
prelude ∷ [Text]
prelude =
  [ "local function make(key, mode)"
  , "  return function(self, ev)"
  , "    fx.record('got ' .. key .. ' n=' .. ev.payload.n .. ' seq=' .. ev.sequence .. ' t=' .. ev.tick)"
  , "    if mode == 'gate' then"
  , "      fx.block('cb')"
  , "      fx.record('done ' .. key .. ' n=' .. ev.payload.n)"
  , "    elseif mode == 'wait' then"
  , "      sched.wait_ticks(1)"
  , "      fx.record('done ' .. key .. ' n=' .. ev.payload.n)"
  , "    elseif mode == 'fail' then"
  , "      error('callback boom')"
  , "    end"
  , "  end"
  , "end"
  , "local function command(self, p)"
  , "  local key = p.key or 'a'"
  , "  local out = '?'"
  , "  if p.op == 'subscribe' then"
  , "    self.hs[key] = self.api.subscribe(p.endpoint, make(key, p.mode))"
  , "    out = 'ok'"
  , "  elseif p.op == 'try_subscribe' then"
  , "    local ok, err = pcall(self.api.subscribe, p.endpoint, make(key, p.mode))"
  , "    if ok then self.hs[key] = err out = 'ok' else out = 'refused ' .. tostring(err) end"
  , "  elseif p.op == 'unsubscribe' then"
  , "    out = tostring(self.api.unsubscribe(self.hs[key]))"
  , "  elseif p.op == 'noop' then"
  , "    out = 'noop'"
  , "  elseif p.op == 'block' then"
  , "    fx.block(key)"
  , "    out = 'unblocked'"
  , "  end"
  , "  fx.record('cmd ' .. p.op .. ' ' .. key .. ' ' .. out)"
  , "end"
  , "local function connect(self, api)"
  , "  self.api = api"
  , "  self.hs = {}"
  , "  api.connect('cmd', function(self, event) command(self, event.payload) end)"
  , "end"
  ]

-- | An instance that does what it is told with its subscriptions, and records what its
-- callbacks are handed.
subscriber ∷ ModuleSource
subscriber =
  hooksModule "subscriber" $
    prelude
      <> [ "function init(self, api) connect(self, api) end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | An instance that subscribes in @init@, to both endpoints, and can then be told what to do.
initSubscriber ∷ ModuleSource
initSubscriber =
  hooksModule "initsubscriber" $
    prelude
      <> [ "function init(self, api)"
         , "  connect(self, api)"
         , "  self.hs['t'] = api.subscribe('ticks', make('t', nil))"
         , "  self.hs['s'] = api.subscribe('state', make('s', nil))"
         , "  fx.record('init subscribed')"
         , "end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | An instance that subscribes in @init@ and does nothing at its end: its subscriptions are
-- revoked by the engine without Lua's help.
deafSubscriber ∷ ModuleSource
deafSubscriber =
  hooksModule "deafsubscriber" $
    prelude
      <> [ "function init(self, api)"
         , "  connect(self, api)"
         , "  self.hs['t'] = api.subscribe('ticks', make('t', nil))"
         , "end"
         ]

-- | An instance that subscribes in its @shutdown@ hook, which is past taking subscriptions.
shutdownSubscriber ∷ ModuleSource
shutdownSubscriber =
  hooksModule "shutdownsubscriber" $
    prelude
      <> [ "function init(self, api) connect(self, api) end"
         , "function shutdown(self, reason)"
         , "  fx.record('shutdown ' .. reason)"
         , "  self.api.subscribe('ticks', make('late', nil))"
         , "  fx.record('shutdown after')"
         , "end"
         ]

-- | A one-shot that subscribes in its @run@ and completes: its subscription is the instance's, and
-- is revoked when the instance ends.
oneShotSubscriber ∷ ModuleSource
oneShotSubscriber =
  hooksModule "oneshotsubscriber" $
    prelude
      <> [ "function run(self, api)"
         , "  api.subscribe('ticks', make('r', nil))"
         , "  fx.record('run subscribed')"
         , "end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | An instance that subscribes in @init@ and then fails it.
failingInitSubscriber ∷ ModuleSource
failingInitSubscriber =
  hooksModule "failinginitsubscriber" $
    prelude
      <> [ "function init(self, api)"
         , "  api.subscribe('ticks', make('f', nil))"
         , "  fx.record('init subscribed')"
         , "  error('init boom')"
         , "end"
         ]

-- Owners ----------------------------------------------------------------------------------

-- | A request grant with one endpoint nothing uses: the subscriptions are granted through the
-- request service, whose kind of time is the kind of time its events are admitted in.
dummyRequests ∷ RequestTiming → RequestGrant
dummyRequests timing =
  RequestGrant
    [ RequestEndpoint
        { endpointName = "unused"
        , endpointResult = SInteger
        , endpointSubmit = \_ → pure ProviderWork {workCancel = pure (), workRetirement = pure ProviderComplete}
        }
    ]
    4
    timing

-- | A grant over the fake's endpoints, with room for this many subscriptions and held events.
subGrant ∷ FakeEvents → Int → Int → SubscriptionGrant
subGrant fake subscriptions staging = SubscriptionGrant (allEndpoints fake) subscriptions staging

-- | A specification of an owner of subscribers granted subscriptions.
subscriptionSpec ∷ IFixture → Text → [ModuleSource] → InstanceConfig → RequestTiming → SubscriptionGrant → WorkerPolicy → ScheduledSpec
subscriptionSpec fixture label modules config timing grant worker =
  (instanceSpec fixture label modules config worker defaultSchedulerBounds)
    { scheduledRequests = Just (dummyRequests timing)
    , scheduledSubscriptions = Just grant
    }

-- | Start an owner of subscribers.
startSubscriber ∷ IFixture → LuaRuntime → Text → [ModuleSource] → InstanceConfig → RequestTiming → SubscriptionGrant → WorkerPolicy → IO ScheduledOwner
startSubscriber fixture runtime label modules config timing grant worker =
  startScheduled (ifBase fixture) runtime (subscriptionSpec fixture label modules config timing grant worker)

-- | The owner's subscriptions, read in one transaction.
subDiagnostics ∷ ScheduledOwner → IO SubscriptionDiagnostics
subDiagnostics owner = do
  found ← atomically (subscriptionDiagnostics (scheduledEndpoint owner))
  maybe (throwIO (userError "the owner has no subscriptions")) pure found

-- | Block, in STM, until the owner's subscriptions read like this.
awaitSubDiagnostic ∷ ScheduledOwner → (SubscriptionDiagnostics → Bool) → IO ()
awaitSubDiagnostic owner wanted = atomically $ do
  found ← subscriptionDiagnostics (scheduledEndpoint owner)
  case found of
    Just reading | wanted reading → pure ()
    _ → retry

-- Commanding ---------------------------------------------------------------------------------

-- | An event-only instance of this module, granted the @cmd@ and @tick@ sources and both
-- endpoints.
subscriberRequest ∷ Text → Text → InstanceRequest
subscriberRequest name moduleName = InstanceRequest (moduleNamed moduleName) EventOnly (Just name) OrdinaryClass ["cmd", "tick", "ticks", "state"]

-- | Admit an instance of this module under this name and wait until it is active.
admitSubscriber ∷ IFixture → ScheduledOwner → Text → Text → IO ()
admitSubscriber fixture owner name moduleName = do
  _ ← admitWith fixture owner name (subscriberRequest name moduleName)
  awaitPhase fixture owner name Active

-- | Tell the subscriber of this name to do this under this key.
command ∷ IFixture → ScheduledOwner → Text → Text → Text → IO ()
command fixture owner name op key = commandWith fixture owner name op key Nothing Nothing

-- | The same, with the endpoint and the callback's mode a subscribe is told.
commandWith ∷ IFixture → ScheduledOwner → Text → Text → Text → Maybe Text → Maybe Text → IO ()
commandWith fixture owner name op key endpoint mode = do
  identity ← idOf fixture name
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key)]
            <> [("endpoint", VText found) | Just found ← [endpoint]]
            <> [("mode", VText found) | Just found ← [mode]]
  deliverEvent (scheduledEndpoint owner) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → throwIO (userError ("expected the command accepted, found " <> show other))

-- | Have the owner serve one more thing, and wait until it has: the subscriber of this name is
-- told to do nothing, under this number. When the owner is held at a tick, this shows it is
-- serving invocations all the same.
sync ∷ IFixture → ScheduledOwner → Text → Int → IO ()
sync fixture owner name number = do
  let key = "s" <> Text.pack (show number)
  command fixture owner name "noop" key
  awaitLine fixture ("cmd noop " <> key <> " noop")

-- | What the callbacks were handed, in the order they were: the @got@ lines.
gotLines ∷ IFixture → IO [Text]
gotLines fixture = filter (Text.isPrefixOf "got ") <$> logged fixture

-- | Wait, without sleeping, until the callbacks have been handed this many deliveries.
awaitGot ∷ IFixture → Int → IO ()
awaitGot fixture wanted = do
  seen ← length <$> gotLines fixture
  if seen >= wanted then pure () else yield >> awaitGot fixture wanted

-- | Grant one logical step without waiting for the tick to complete.
step ∷ ScheduledOwner → IO ()
step owner = void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))

-- | How many grants have been accepted and not completed.
outstanding ∷ ScheduledOwner → IO Int
outstanding owner = atomically (ticksOutstanding (scheduledEndpoint owner))
