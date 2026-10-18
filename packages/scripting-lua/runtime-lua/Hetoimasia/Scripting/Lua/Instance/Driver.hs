-- | The instance layer's part of the VM: a module the owner loads beside the
-- application's, and the bindings its @api@ and its updates reach the owner through.
--
-- An instance's @self@ and the functions it connected are values of the VM: they
-- have an identity and a lifetime of their own, and cannot cross the value boundary
-- as copies. The driver keeps them in the VM, in a table only it reaches, by the
-- instance's number, and runs the application's hooks on them: a hook is looked up
-- by the host in its own module and handed to the driver, which calls it with
-- the instance's @self@ ('Hetoimasia.Scripting.Lua.Internal.Module.Lead'). A script
-- cannot reach the table, so it cannot forge or erase another instance's state, and
-- cannot reach its own record except through the @self@ and @api@ it is handed.
--
-- The bindings @hetoimasia_instance.subscribe@ and @unsubscribe@ are an instance's
-- subscriptions to a provider's events (LUA-26): the function a script subscribes is kept in the
-- VM beside its connections, by the subscription's number, and a delivery reaches it through
-- the entry point of its endpoint, which is looked up when the owner services the delivery and
-- never called by a producer.
--
-- The binding @hetoimasia_instance.delta@ hands the driver an update's @dt@, in seconds,
-- and a negative number for anything else, so a one-shot's @run@ and an update go through
-- one entry point that takes the instance's number alone. The binding
-- @hetoimasia_instance.connect@ tells the owner that an instance
-- connected a function to a source. The owner records the connection when it is
-- made, whichever thread the event arrives from, so it can accept events for an
-- instance whose @init@ is still running, and revoke what it connected whichever
-- way the instance ends.
module Hetoimasia.Scripting.Lua.Instance.Driver
  ( driverRef
  , driverSource
  , driverNamespaceName
  , connectNamespace
  , hookEntries
  , eventEntry
  , subscriptionEntry
  ) where

import Control.Concurrent.STM (atomically)
import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance.State (connectSource, takeDelta)
import Hetoimasia.Scripting.Lua.Instance.Types (EventSource (..), Instances)
import Hetoimasia.Scripting.Lua.Owner (EntryPoint (..), ModuleRef (..), ModuleSource (..), Requirement (..))
import Hetoimasia.Scripting.Lua.Provider.Subscribe (forgottenBy, subscribeTo, unsubscribeFrom)
import Hetoimasia.Scripting.Lua.Registration (Namespace, asynchronousNativeRequestIn, namespace, stateOperation)
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (VBoolean, VFloat, VInteger, VList, VText))

-- | The driver's module.
driverRef ∷ ModuleRef
driverRef = ModuleRef "hetoimasia.instance" "1"

-- | The namespace the owner's bindings are installed in.
driverNamespaceName ∷ Text
driverNamespaceName = "hetoimasia_instance"

-- | The entry point of the driver that delivers to the callbacks connected to a
-- source.
eventEntry ∷ Text → Text
eventEntry source = "event_" <> source

-- | The entry point of the driver that delivers to the callbacks subscribed to an event
-- endpoint.
subscriptionEntry ∷ Text → Text
subscriptionEntry endpoint = "subscription_" <> endpoint

-- | The hooks a module that hosts instances declares, each optional: @init@ runs
-- once, @update@ runs when a periodic instance's interval makes one due,
-- @shutdown@ runs once on the way out, and @run@ is a one-shot's body. Declared
-- with no arguments: the driver hands each its @self@ and what else it takes.
hookEntries ∷ [EntryPoint]
hookEntries = [EntryPoint name Optional [] [] | name ← ["init", "update", "shutdown", "run"]]

-- | The namespace holding the owner's bindings, over the owner's instances.
connectNamespace ∷ Instances → Namespace
connectNamespace instances =
  namespace driverNamespaceName
    [ stateOperation "connect" [SInteger, SText] [SBoolean] $ \case
        [VInteger number, VText source] | number >= 0 →
          (\accepted → [VBoolean accepted]) <$> atomically (connectSource instances (fromIntegral number) source)
        _ → pure [VBoolean False]
    , -- The delta, in seconds, of the update that is about to begin, or a negative one
      -- for anything else: how the one entry point for @run@ and @update@ tells them
      -- apart without a second value across the boundary.
      stateOperation "delta" [SInteger] [SFloat] $ \case
        [VInteger number] | number >= 0 → (\seconds → [VFloat seconds]) <$> atomically (takeDelta instances (fromIntegral number))
        _ → pure [VFloat (-1)]
    , -- An instance's subscriptions are asynchronous requests in the registration's sense: an
      -- owner granted no request service answers them as not yet supported, with the action
      -- never run, and one granted it hands the action its own service.
      asynchronousNativeRequestIn "subscribe" [SInteger, SText] [SInteger] $ \context → \case
        [VInteger slot, VText endpoint] | slot >= 0 →
          (\number → [VInteger (fromIntegral number)]) <$> subscribeTo context (fromIntegral slot) endpoint
        _ → pure [VInteger (-1)]
    , -- The numbers of the subscriptions the engine ended without the script, taken once: the
      -- driver lets go of the callbacks it holds for them.
      asynchronousNativeRequestIn "forgotten" [SInteger] [SList SInteger] $ \context → \case
        [VInteger slot] | slot >= 0 →
          (\numbers → [VList [VInteger (fromIntegral number) | number ← numbers]]) <$> forgottenBy context (fromIntegral slot)
        _ → pure [VList []]
    , asynchronousNativeRequestIn "unsubscribe" [SInteger, SInteger] [SBoolean] $ \context → \case
        [VInteger slot, VInteger number] | slot >= 0 && number >= 0 →
          (\ended → [VBoolean ended]) <$> unsubscribeFrom context (fromIntegral slot) (fromIntegral number)
        _ → pure [VBoolean False]
    ]

-- | The driver as a module: its source, and the entry points the owner calls.
--
-- One entry point for each source the owner offers delivers to the function an
-- instance connected to it, handing it the instance's @self@ and the event; and one for each
-- event endpoint, named with its payload's schema, delivers to the function an instance
-- subscribed to it.
driverSource ∷ [EventSource] → [(Text, Schema)] → ModuleSource
driverSource sources endpoints =
  ModuleSource
    { sourceIdentity = driverRef
    , sourceText = Char8.pack (Text.unpack (Text.unlines (luaBody <> map eventFunction sources <> map (subscriptionFunction . fst) endpoints)))
    , sourceEntries =
        [ entry "create" [SInteger]
        , entry "release" [SInteger]
        , entry "init" [SInteger]
        , -- The one entry point both a one-shot's @run@ and a periodic @update@ go
          -- through, with the one value a one-shot's @run@ always had: the instance's
          -- number. An update is told from a @run@, and handed its delta, by the
          -- binding.
          entry "run" [SInteger]
        , entry "shutdown" [SInteger, SText]
        ]
          <> [ entry (eventEntry (sourceName source)) [SInteger, eventSchema source]
             | source ← sources
             ]
          <> [ entry (subscriptionEntry name) [SInteger, deliverySchema payload]
             | (name, payload) ← endpoints
             ]
    }
  where
    entry name arguments = EntryPoint name Required arguments []
    eventSchema source =
      SRecord
        [ ("source", SText)
        , ("sequence", SInteger)
        , ("tick", SInteger)
        , ("payload", sourcePayload source)
        ]
    deliverySchema payload =
      SRecord
        [ ("source", SText)
        , ("sequence", SInteger)
        , ("tick", SInteger)
        , ("subscription", SInteger)
        , ("payload", payload)
        ]
    subscriptionFunction name =
      "function " <> subscriptionEntry name <> "(slot, event) deliver_subscription(slot, event) end"
    eventFunction source =
      "function "
        <> eventEntry (sourceName source)
        <> "(slot, event) deliver(slot, \""
        <> sourceName source
        <> "\", event) end"

-- The driver's Lua. A hook is called with its instance's @self@ in the same
-- coroutine the driver runs in, so a wait or a yield inside it reaches the
-- scheduler (or is refused, where the hook may not suspend) exactly as it would
-- from a task's entry point.
luaBody ∷ [Text]
luaBody =
  [ "local host = hetoimasia_instance"
  , "local live = {}"
  , ""
  , "local function find(slot)"
  , "  local record = live[slot]"
  , "  if record == nil then error('the instance has ended', 3) end"
  , "  return record"
  , "end"
  , ""
  , "local function connector(slot, record)"
  , "  return function(source, callback)"
  , "    if record.ended then error('api.connect: the instance has ended', 2) end"
  , "    if type(source) ~= 'string' then error('api.connect: an event source is named by a string', 2) end"
  , "    if type(callback) ~= 'function' then error('api.connect: the callback must be a function', 2) end"
  , "    if record.connections[source] ~= nil then error('api.connect: already connected to ' .. source, 2) end"
  , "    if not host.connect(slot, source) then"
  , "      error('api.connect: no event source named ' .. source .. ' is granted to this instance', 2)"
  , "    end"
  , "    record.connections[source] = callback"
  , "  end"
  , "end"
  , ""
  , "-- Let go of the callbacks of subscriptions the engine ended without the script, and of the handles"
  , "-- that named them."
  , "local function sweep(slot, record)"
  , "  for _, number in ipairs(host.forgotten(slot)) do"
  , "    record.subscriptions[number] = nil"
  , "  end"
  , "  for handle, number in pairs(record.handles) do"
  , "    if record.subscriptions[number] == nil then record.handles[handle] = nil end"
  , "  end"
  , "end"
  , ""
  , "local function subscriber(slot, record)"
  , "  return function(endpoint, callback)"
  , "    if record.ended then error('api.subscribe: the instance has ended', 2) end"
  , "    if type(endpoint) ~= 'string' then error('api.subscribe: an event endpoint is named by a string', 2) end"
  , "    if type(callback) ~= 'function' then error('api.subscribe: the callback must be a function', 2) end"
  , "    sweep(slot, record)"
  , "    local number = host.subscribe(slot, endpoint)"
  , "    local handle = {}"
  , "    record.subscriptions[number] = callback"
  , "    record.handles[handle] = number"
  , "    return handle"
  , "  end"
  , "end"
  , ""
  , "local function unsubscriber(slot, record)"
  , "  return function(handle)"
  , "    local number = record.handles[handle]"
  , "    if number == nil then return false end"
  , "    record.handles[handle] = nil"
  , "    record.subscriptions[number] = nil"
  , "    return host.unsubscribe(slot, number)"
  , "  end"
  , "end"
  , ""
  , "-- Creating a slot that is live is the owner's cleanup point for it: it lets go of what ended."
  , "function create(slot)"
  , "  local live_record = live[slot]"
  , "  if live_record ~= nil then"
  , "    sweep(slot, live_record)"
  , "    return"
  , "  end"
  , "  local record = { self = {}, connections = {}, subscriptions = {}, handles = setmetatable({}, { __mode = 'k' }), ended = false }"
  , "  record.api = { connect = connector(slot, record), subscribe = subscriber(slot, record), unsubscribe = unsubscriber(slot, record) }"
  , "  live[slot] = record"
  , "end"
  , ""
  , "function release(slot)"
  , "  local record = live[slot]"
  , "  if record ~= nil then"
  , "    live[slot] = nil"
  , "    record.ended = true"
  , "    record.connections = {}"
  , "    record.subscriptions = {}"
  , "    record.handles = {}"
  , "    record.self = nil"
  , "  end"
  , "end"
  , ""
  , "function init(hook, slot)"
  , "  local record = find(slot)"
  , "  hook(record.self, record.api)"
  , "end"
  , ""
  , "function run(hook, slot)"
  , "  local record = find(slot)"
  , "  local dt = host.delta(slot)"
  , "  if dt < 0 then"
  , "    hook(record.self, record.api)"
  , "  else"
  , "    hook(record.self, dt)"
  , "  end"
  , "end"
  , ""
  , "function shutdown(hook, slot, reason)"
  , "  local record = find(slot)"
  , "  hook(record.self, reason)"
  , "end"
  , ""
  , "local function deliver(slot, source, event)"
  , "  local record = find(slot)"
  , "  local callback = record.connections[source]"
  , "  -- A connection the owner recorded and the instance never made through its api is the"
  , "  -- instance's own fault: its event is not dropped in silence."
  , "  if callback == nil then error('no callback is connected to the source ' .. source, 0) end"
  , "  callback(record.self, event)"
  , "end"
  , ""
  , "local function deliver_subscription(slot, event)"
  , "  local record = find(slot)"
  , "  local callback = record.subscriptions[event.subscription]"
  , "  -- A subscription the owner delivered to and the instance holds no function for is the"
  , "  -- instance's own fault, not dropped in silence."
  , "  if callback == nil then error('no callback is subscribed under ' .. tostring(event.subscription), 0) end"
  , "  callback(record.self, event)"
  , "end"
  , ""
  ]
