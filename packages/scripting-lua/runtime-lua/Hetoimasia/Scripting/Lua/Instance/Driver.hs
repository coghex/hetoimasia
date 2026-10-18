-- | The instance layer's part of the VM: a module the owner loads beside the
-- application's, and the one binding its @api@ reaches the owner through.
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
-- The one binding, @hetoimasia_instance.connect@, tells the owner that an instance
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
  ) where

import Control.Concurrent.STM (atomically)
import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance.State (connectSource)
import Hetoimasia.Scripting.Lua.Instance.Types (EventSource (..), Instances)
import Hetoimasia.Scripting.Lua.Owner (EntryPoint (..), ModuleRef (..), ModuleSource (..), Requirement (..))
import Hetoimasia.Scripting.Lua.Registration (Namespace, namespace, stateOperation)
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (VBoolean, VInteger, VText))

-- | The driver's module.
driverRef ∷ ModuleRef
driverRef = ModuleRef "hetoimasia.instance" "1"

-- | The namespace the owner's one binding is installed in.
driverNamespaceName ∷ Text
driverNamespaceName = "hetoimasia_instance"

-- | The entry point of the driver that delivers to the callbacks connected to a
-- source.
eventEntry ∷ Text → Text
eventEntry source = "event_" <> source

-- | The hooks a module that hosts instances declares, each optional: @init@ runs
-- once, @update@ runs when a periodic instance's interval makes one due,
-- @shutdown@ runs once on the way out, and @run@ is a one-shot's body. Declared
-- with no arguments: the driver hands each its @self@ and what else it takes.
hookEntries ∷ [EntryPoint]
hookEntries = [EntryPoint name Optional [] [] | name ← ["init", "update", "shutdown", "run"]]

-- | The namespace holding the owner's one binding, over the owner's instances.
connectNamespace ∷ Instances → Namespace
connectNamespace instances =
  namespace driverNamespaceName
    [ stateOperation "connect" [SInteger, SText] [SBoolean] $ \case
        [VInteger number, VText source] | number >= 0 →
          (\accepted → [VBoolean accepted]) <$> atomically (connectSource instances (fromIntegral number) source)
        _ → pure [VBoolean False]
    ]

-- | The driver as a module: its source, and the entry points the owner calls.
--
-- One entry point for each source the owner offers delivers to the function an
-- instance connected to it, handing it the instance's @self@ and the event.
driverSource ∷ [EventSource] → ModuleSource
driverSource sources =
  ModuleSource
    { sourceIdentity = driverRef
    , sourceText = Char8.pack (Text.unpack (Text.unlines (luaBody <> map eventFunction sources)))
    , sourceEntries =
        [ entry "create" [SInteger]
        , entry "release" [SInteger]
        , entry "init" [SInteger]
        , entry "run" [SInteger]
        , entry "update" [SInteger, SInteger]
        , entry "shutdown" [SInteger, SText]
        ]
          <> [ entry (eventEntry (sourceName source)) [SInteger, eventSchema source]
             | source ← sources
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
  , "function create(slot)"
  , "  local record = { self = {}, connections = {}, ended = false }"
  , "  record.api = { connect = connector(slot, record) }"
  , "  live[slot] = record"
  , "end"
  , ""
  , "function release(slot)"
  , "  local record = live[slot]"
  , "  if record ~= nil then"
  , "    live[slot] = nil"
  , "    record.ended = true"
  , "    record.connections = {}"
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
  , "  hook(record.self, record.api)"
  , "end"
  , ""
  , "function update(hook, slot, dt)"
  , "  local record = find(slot)"
  , "  hook(record.self, dt)"
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
  ]
