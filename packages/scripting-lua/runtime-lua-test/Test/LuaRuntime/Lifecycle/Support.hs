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
  , taskCaller
  , cmdSource
  , cmdConfig
    -- * Owners
  , lifeSpec
  , startTarget
  , startCaller
  , startCallerWith
  , startCallerIn
  , logicalConfig
  , logicalCommanders
  , grantOver
  , bothPermits
  , target
  , admitCommander
    -- * Commanding
  , ask
  , tell
  , taskLine
  , notYetSupported
  , cmdLines
  , tidValue
  , renderTid
  , awaitCmd
  , receiptResult
  , reserveAll
  , lineCount
  ) where

import Control.Concurrent (yield)
import Control.Exception (throwIO)
import Control.Monad (replicateM, void)
import Data.IORef (atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lifecycle
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed), LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.LuaRuntime.Instance.Support
import qualified Data.Text.Encoding as Text
import Test.LuaRuntime.Scheduled.Support (defaultSchedulerBounds, schedRegistration)
import Test.LuaRuntime.Support (requiredPolicy)

-- | The registration of the instance examples, with the lifecycle bindings in @life@:
-- registered once, and shared by every owner of an example whatever it is granted.
lifeRegistration ∷ IFixture → Registration
lifeRegistration fixture =
  either (error . show) id $
    registration [] (registrationNamespaces (schedRegistration (ifBase fixture)) <> [inst, lifecycleNamespace "life"])
  where
    -- The counter every hook names itself with, as the instance examples' registration has it.
    inst =
      namespace
        "inst"
        [ stateOperation "next" [] [SInteger] $ \_ → do
            n ← atomicModifyIORef' (ifCounter fixture) (\held → (held + 1, held + 1))
            pure [VInteger (fromIntegral n)]
        ]

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
  , "local WAITED = {}"
  , "local function run(p)"
  , "  if p.op == 'result' or p.op == 'forget' then return life[p.op](p.n) end"
  , "  if p.op == 'owners' or p.op == 'self' then return life[p.op]() end"
  , "  if p.op == 'inspect_owner' then return life.inspect_owner({runtime = p.tid.runtime, owner = p.tid.owner}) end"
  , "  if p.op == 'pause_self' then return life.pause(life.self()) end"
  , "  if p.op == 'resume_self' then return life.resume(life.self()) end"
  , "  if p.op == 'stop_self' then return life.stop(life.self()) end"
  , "  if p.op == 'pause_self_inspect' then"
  , "    local r = life.pause(life.self())"
  , "    local seen = life.inspect(life.self())"
  , "    return fmt(r) .. ' ' .. seen.snapshot.status"
  , "  end"
  , "  if p.op == 'pause_self_wait' then"
  , "    local r = life.pause(life.self())"
  , "    " <> record <> "('cmd pause_self_wait ' .. fmt(r))"
  , "    sched.wait_ticks(1)"
  , "    " <> record <> "('post woke')"
  , "    return WAITED"
  , "  end"
  , "  if p.op == 'stop_self_wait' then"
  , "    local r = life.stop(life.self())"
  , "    " <> record <> "('cmd stop_self_wait ' .. fmt(r))"
  , "    sched.wait_ticks(1)"
  , "    " <> record <> "('post woke')"
  , "    return WAITED"
  , "  end"
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
         , "    if r ~= WAITED then " <> record <> "('cmd ' .. p.op .. ' ' .. fmt(r)) end"
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

-- | Tasks that call the lifecycle bindings, for an owner whose scripts are not instances: a
-- task has no instance to name, so what it holds is its owner's.
taskCaller ∷ ModuleSource
taskCaller =
  ModuleSource
    (ModuleRef "taskcaller" "1")
    (Text.encodeUtf8 (Text.unlines (take 14 prelude <> body)))
    [EntryPoint "who" Required [] [], EntryPoint "pause" Required [tidSchema'] [], EntryPoint "result" Required [SInteger] []]
  where
    body =
      [ "function who() " <> record <> "('cmd who ' .. fmt(life.self())) end"
      , "function pause(tid) " <> record <> "('cmd pause ' .. fmt(life.pause(tid))) end"
      , "function result(n) " <> record <> "('cmd result ' .. fmt(life.result(n))) end"
      ]

-- | The given registration, the lifecycle policy and the grant, for an owner of this label.
lifeSpec ∷ IFixture → Registration → Text → [ModuleSource] → InstanceConfig → Maybe LifecycleGrant → ScheduledSpec
lifeSpec fixture given label modules config grant =
  base
    { scheduledVm = (scheduledVm base) {vmRegistration = given, vmPolicy = vmPolicy (scheduledVm base) <> ["life"]}
    , scheduledLifecycle = grant
    }
  where
    base = instanceSpec fixture label modules config requiredPolicy defaultSchedulerBounds

-- | An owner of instances other owners' commanders are granted.
startTarget ∷ IFixture → LuaRuntime → Text → [ModuleSource] → InstanceConfig → IO ScheduledOwner
startTarget fixture runtime label modules config =
  startWith fixture runtime (lifeSpec fixture (lifeRegistration fixture) label modules config Nothing)

-- | An owner of commanders and the task module, granted this.
startCaller ∷ IFixture → LuaRuntime → Text → Maybe LifecycleGrant → IO ScheduledOwner
startCaller fixture runtime = startCallerWith fixture (lifeRegistration fixture) runtime

-- | The same, from a registration built once and given to several owners.
startCallerWith ∷ IFixture → Registration → LuaRuntime → Text → Maybe LifecycleGrant → IO ScheduledOwner
startCallerWith fixture given runtime label grant =
  startWith fixture runtime (lifeSpec fixture given label [commander, commanderFailing, taskCaller] cmdConfig grant)

-- | An owner of commanders of this configuration, granted this.
startCallerIn ∷ IFixture → LuaRuntime → Text → InstanceConfig → Maybe LifecycleGrant → IO ScheduledOwner
startCallerIn fixture runtime label config grant =
  startWith fixture runtime (lifeSpec fixture (lifeRegistration fixture) label [commander, commanderFailing, taskCaller] config grant)

-- | Bounds and sources for an owner that admits the controls made through a grant logically.
logicalConfig ∷ InstanceConfig
logicalConfig = (testConfig instanceBounds') {instanceControlAdmission = AdmitLogically}

-- | The same for an owner of commanders.
logicalCommanders ∷ InstanceConfig
logicalCommanders = cmdConfig {instanceControlAdmission = AdmitLogically}

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

-- | The numbers of a value a script holds, as the script's own rendering shows them.
renderTid ∷ Value → Text
renderTid = \case
  VRecord [("runtime", VInteger runtime), ("owner", VInteger owner), ("id", VInteger local)] →
    "{id=" <> Text.pack (show local) <> ",owner=" <> Text.pack (show owner) <> ",runtime=" <> Text.pack (show runtime) <> "}"
  other → Text.pack (show other)

-- | Read a receipt until it is no longer pending.
receiptResult ∷ IFixture → ScheduledOwner → Text → Int → IO Text
receiptResult fixture owner name number = do
  answer ← ask fixture owner name "result" Nothing (Just number)
  if answer == "pending" then yield >> receiptResult fixture owner name number else pure answer

-- | Ask, this many times, that the instance be paused: every answer, in order.
reserveAll ∷ IFixture → ScheduledOwner → Text → Value → Int → IO [Text]
reserveAll fixture owner name tid count = replicateM count (ask fixture owner name "pause" (Just tid) Nothing)

-- | How many lines the commanders have recorded that start with this.
lineCount ∷ IFixture → Text → IO Int
lineCount fixture prefix = length . filter (Text.isPrefixOf prefix) <$> logged fixture

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

-- | Tell the commander of this name to call this operation, without waiting for it.
tell ∷ IFixture → ScheduledOwner → Text → Text → Maybe Value → Maybe Int → IO ()
tell fixture owner name op tid n = do
  identity ← idOf fixture name
  let payload =
        VRecord $
          [("op", VText op)]
            <> [("tid", t) | Just t ← [tid]]
            <> [("n", VInteger (fromIntegral number)) | Just number ← [n]]
  deliverEvent (scheduledEndpoint owner) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → throwIO (userError ("expected the command delivered, found " <> show other))

-- | Tell the commander of this name to call this operation, naming this instance and
-- this number when it takes them, and answer what it recorded for the call: the
-- answer's text, as the script rendered it.
ask ∷ IFixture → ScheduledOwner → Text → Text → Maybe Value → Maybe Int → IO Text
ask fixture owner name op tid n = do
  before ← length <$> cmdLines fixture
  tell fixture owner name op tid n
  awaitCmd fixture (before + 1)
  line ← (!! before) <$> cmdLines fixture
  pure (Text.drop (Text.length ("cmd " <> op <> " ")) line)

-- | Whether an instance's settlement is its failure with a call refused as not yet supported.
notYetSupported ∷ InstanceSettlement → Bool
notYetSupported settlement = case failureOf' settlement of
  Just failure → case failureError failure of
    ErrorFault (BoundaryFailed fault) → boundaryReason fault == NotYetSupported LifecycleOperation
    _ → False
  Nothing → False

-- | Run an entry of the task module as a task of the owner, wait for it to settle, and answer
-- what it recorded: the line's text after the entry's name, as the script rendered it.
taskLine ∷ IFixture → ScheduledOwner → Text → [Value] → IO Text
taskLine fixture owner entry arguments = do
  before ← length <$> cmdLines fixture
  admitScheduledTask (scheduledEndpoint owner) (TaskRequest (ModuleRef "taskcaller" "1") entry arguments OrdinaryClass OneShot Nothing) >>= \case
    TaskAccepted _ ticket → void (waitTask ticket)
    other → throwIO (userError ("expected the task accepted, found " <> show other))
  awaitCmd fixture (before + 1)
  line ← (!! before) <$> cmdLines fixture
  pure (Text.drop (Text.length ("cmd " <> entry <> " ")) line)
