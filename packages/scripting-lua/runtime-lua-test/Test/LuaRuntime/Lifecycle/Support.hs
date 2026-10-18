-- | What the lifecycle examples share: the one registration every owner here is built
-- from, a module whose instances call the lifecycle bindings when they are told to, and
-- the helpers that tell them and read what they answered.
--
-- A /commander/ is an instance of that module. It connects to a @cmd@ source and, for
-- each event, calls the binding the event names with the numbers it carries, and
-- records what came back as one line. An example drives it with 'ask' and reads the
-- line, so what a script was told is what is asserted, not what Haskell can see.
-- Every example runs real instances on real supervised scheduled owners, two or more
-- of them, with gates instead of sleeps.
module Test.LuaRuntime.Lifecycle.Support
  ( -- * The registration and the modules
    lifeRegistration
  , commander
  , commanderFailing
  , cmdSource
  , cmdConfig
    -- * Owners
  , lifeSpec
  , startTarget
  , startCaller
  , grantOver
  , bothPermits
  , target
  , admitCommander
    -- * Commanding
  , ask
  , askAs
  , cmdLines
  , tidValue
  , awaitCmd
  , expectLine
  , Ids
  ) where

import Control.Concurrent (yield)
import Control.Exception (throwIO)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lifecycle
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (defaultSchedulerBounds)
import Test.LuaRuntime.Support (requiredPolicy)

-- | What a test names owners and instances by.
type Ids = IFixture

-- | The registration of the instance examples, with the lifecycle bindings in @life@:
-- registered once, and shared by every owner of an example whatever it is granted.
lifeRegistration ∷ IFixture → Registration
lifeRegistration fixture =
  either (error . show) id $
    registration [] (registrationNamespaces (instRegistration fixture) <> [lifecycleNamespace "life"])

tidSchema' ∷ Schema
tidSchema' = SRecord [("runtime", SInteger), ("owner", SInteger), ("id", SInteger)]

-- | What a commander is told: the operation, the identity it names and a number.
cmdSource ∷ EventSource
cmdSource = EventSource "cmd" (SRecord [("op", SText), ("tid", SOptional tidSchema'), ("n", SOptional SInteger)])

-- | Bounds and sources for an owner of commanders.
cmdConfig ∷ InstanceConfig
cmdConfig = (testConfig instanceBounds') {instanceSources = [cmdSource, tickSource]}

-- | The Lua every commander shares: a deterministic rendering of what came back.
prelude ∷ [Text]
prelude =
  [ "local function fmt(v)"
  , "  if type(v) ~= 'table' then return tostring(v) end"
  , "  local keys = {}"
  , "  for k in pairs(v) do keys[#keys + 1] = tostring(k) end"
  , "  table.sort(keys)"
  , "  local out = {}"
  , "  for _, k in ipairs(keys) do"
  , "    local x = v[k]"
  , "    if x == nil then x = v[tonumber(k)] end"
  , "    out[#out + 1] = k .. '=' .. fmt(x)"
  , "  end"
  , "  return '{' .. table.concat(out, ',') .. '}'"
  , "end"
  , "local function run(p)"
  , "  if p.op == 'result' or p.op == 'forget' then return life[p.op](p.n) end"
  , "  if p.op == 'owners' or p.op == 'self' then return life[p.op]() end"
  , "  if p.op == 'inspect_owner' then return life.inspect_owner({runtime = p.tid.runtime, owner = p.tid.owner}) end"
  , "  if p.op == 'pause_self' then return life.pause(life.self()) end"
  , "  if p.op == 'resume_self' then return life.resume(life.self()) end"
  , "  if p.op == 'stop_self' then return life.stop(life.self()) end"
  , "  return life[p.op](p.tid)"
  , "end"
  ]

-- | An instance that calls what it is told to, and records the answer as @cmd <op> <answer>@,
-- then @post <op>@ once the call has returned: so an example sees that the segment
-- that made a request went on, whatever the request was.
commander ∷ ModuleSource
commander =
  hooksModule "commander" $
    prelude
      <> [ "function init(self, api)"
         , "  api.connect('cmd', function(self, event)"
         , "    local p = event.payload"
         , "    local r = run(p)"
         , "    " <> record <> "('cmd ' .. p.op .. ' ' .. fmt(r))"
         , "    " <> record <> "('post ' .. p.op)"
         , "  end)"
         , "end"
         , "function shutdown(self, reason) " <> record <> "('post shutdown ' .. reason) end"
         ]

-- | A commander that adds a field the engine never reads, which the boundary refuses.
commanderFailing ∷ ModuleSource
commanderFailing =
  hooksModule "commanderfailing" $
    prelude
      <> [ "function init(self, api)"
         , "  api.connect('cmd', function(self, event)"
         , "    local p = event.payload"
         , "    local r = life.pause({runtime = p.tid.runtime, owner = p.tid.owner, id = p.tid.id, caller = 1})"
         , "    " <> record <> "('cmd forged ' .. fmt(r))"
         , "  end)"
         , "end"
         ]

-- | The registration, the lifecycle policy and the grant, for an owner of this label.
lifeSpec ∷ IFixture → Text → [ModuleSource] → InstanceConfig → Maybe LifecycleGrant → ScheduledSpec
lifeSpec fixture label modules config grant =
  base
    { scheduledVm = (scheduledVm base) {vmRegistration = lifeRegistration fixture, vmPolicy = vmPolicy (scheduledVm base) <> ["life"]}
    , scheduledLifecycle = grant
    }
  where
    base = instanceSpec fixture label modules config requiredPolicy defaultSchedulerBounds

-- | An owner of instances other owners' commanders are granted.
startTarget ∷ IFixture → LuaRuntime → Text → [ModuleSource] → InstanceConfig → IO ScheduledOwner
startTarget fixture runtime label modules config =
  startWith fixture runtime (lifeSpec fixture label modules config Nothing)

-- | An owner of commanders, granted this.
startCaller ∷ IFixture → LuaRuntime → Text → Maybe LifecycleGrant → IO ScheduledOwner
startCaller fixture runtime label grant =
  startWith fixture runtime (lifeSpec fixture label [commander, commanderFailing] cmdConfig grant)

-- | A grant over this owner, permitting these things, assigning nothing.
grantOver ∷ ScheduledOwner → [Permit] → GrantTarget
grantOver owner permits = GrantTarget (GrantedEndpoint (scheduledEndpoint owner)) permits Nothing

-- | Inspection and control.
bothPermits ∷ [Permit]
bothPermits = [PermitInspect, PermitControl]

-- | A grant over one owner with both permits and the default bounds.
target ∷ ScheduledOwner → LifecycleGrant
target owner = lifecycleGrant [grantOver owner bothPermits]

-- | Admit a commander under this name, granted the @cmd@ source, and wait until it serves.
admitCommander ∷ IFixture → ScheduledOwner → Text → IO ()
admitCommander fixture owner name = do
  _ ← admitWith fixture owner name (InstanceRequest (moduleNamed "commander") EventOnly (Just name) OrdinaryClass ["cmd"])
  awaitPhase fixture owner name Active

-- | The value a script holds for the instance admitted under this name.
tidValue ∷ IFixture → Text → IO Value
tidValue fixture name = instanceIdValue <$> idOf fixture name

-- | The lines the commanders of this fixture have recorded, oldest first.
cmdLines ∷ IFixture → IO [Text]
cmdLines fixture = filter (Text.isPrefixOf "cmd ") <$> logged fixture

-- | Wait until this many lines have been recorded.
awaitCmd ∷ IFixture → Int → IO ()
awaitCmd fixture wanted = do
  seen ← length <$> cmdLines fixture
  if seen >= wanted then pure () else yield >> awaitCmd fixture wanted

-- | Tell the commander of this name to call this operation, naming the instance
-- admitted under another name in the fixture of the target, and answer what it recorded
-- for the call: the answer's text.
ask ∷ IFixture → ScheduledOwner → Text → Text → Maybe Value → Maybe Int → IO Text
ask fixture = askAs fixture fixture

-- | The same, where the instance named is of the other fixture.
askAs ∷ IFixture → IFixture → ScheduledOwner → Text → Text → Maybe Value → Maybe Int → IO Text
askAs fixture _ owner name op tid n = do
  before ← length <$> cmdLines fixture
  identity ← idOf fixture name
  let payload =
        VRecord $
          [("op", VText op)]
            <> [("tid", t) | Just t ← [tid]]
            <> [("n", VInteger (fromIntegral number)) | Just number ← [n]]
  deliverEvent (scheduledEndpoint owner) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → throwIO (userError ("expected the command delivered, found " <> show other))
  awaitCmd fixture (before + 1)
  line ← (!! before) <$> cmdLines fixture
  pure (Text.drop (Text.length ("cmd " <> op <> " ")) line)

-- | Fail unless the answer is this.
expectLine ∷ Text → Text → IO ()
expectLine wanted found
  | wanted == found = pure ()
  | otherwise = throwIO (userError ("expected " <> show wanted <> ", found " <> show found))
