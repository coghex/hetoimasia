-- | What the opt-in admission examples share: a policy the bindings read, fake banks and a fake
-- lease resource the provider's replies carry, a namespace of bindings that start, read, take,
-- cancel and wait for requests through "Hetoimasia.Scripting.Lua.Admission", the modules of
-- Lua that call them, and the coordination the examples use instead of sleeping.
--
-- Every example runs real instances on a real supervised scheduled owner that lends its
-- collection, holds leases and answers the liveness of request handles, under the injected
-- clock and fake timer of "Test.LuaRuntime.Scheduled.Support". The provider is the fake of
-- "Test.LuaRuntime.Request.Support": it records what it was handed, answers when an example
-- tells it to, from the example's own thread, and reports its retirement as the example sets it.
-- The policy a request is admitted under is the fixture's, read by the bindings from a variable
-- the example sets before it commands anything; no script can reach it.
module Test.LuaRuntime.Admission.Support
  ( -- * The fixture
    AFix (..)
  , newAFix
  , Policy (..)
  , defaultPolicy
  , setPolicy
  , note
  , history
  , historyCount

    -- * The fake banks and resources
  , Bank' (..)
  , newBank
  , bankAvailable
  , bankLog
  , bankCredit
  , answerResource
  , answerFailure
  , answerExpected
  , releaseLog
  , resourceFor

    -- * The modules
  , admitter
  , initAdmitter
  , updateAdmitter
  , initWaiter
  , shutdownStarter
  , oneShotStarter
  , shutdownBlocker

    -- * Owners
  , acmdSource
  , aConfig
  , admissionGrant
  , admissionSpec
  , startAdmitting
  , admitAdmitter
  , acommand
  , acommandWith
  , awaitNote
  , awaitHistory
  , awaitStarts
  , settleAll

    -- * Reading
  , leaseSummary
  , awaitLeaseSummary
  , heldBy
  , lineStarting
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (finally)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank)
import Hetoimasia.Runtime.Supervision (WorkerPolicy)
import Hetoimasia.Scripting.Lua.Admission
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Lending (Lending, newLending)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Request (requestHandleValue, startRequest)
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled hiding (Policy (..))
import Hetoimasia.Scripting.Lua.Value
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfLog), defaultSchedulerBounds, schedRegistration, startScheduled)
import Test.LuaRuntime.Support (Gated (..), failExample)

-- The fixture --------------------------------------------------------------------------------

-- | What every request is admitted under, read when the binding runs.
data Policy = Policy
  { polNecessity ∷ !Necessity
  , polCodes ∷ ![Text]
  , polCredits ∷ ![Credit]
  , polLease ∷ !(Maybe Ownership)
  , polPerInstance ∷ !Int
  , polPerVm ∷ !Int
  , polCeiling ∷ !Word64
  , polSource ∷ !Text
  , polDisposal ∷ !(Maybe (IO ()))
    -- ^ What the request's work needs disposed of once the provider has proved it over, if not just noting it.
  , polCombine ∷ !(Maybe (Value → Word64 → Value))
    -- ^ How the value a script is handed for an adopted resource holds its lease's handle.
  , polReplyBytes ∷ !Int
    -- ^ The bytes a reply's record may take beside the owner's limits.
  }

-- | A required request with the failure codes @not_found@ and @io_error@, no credit and no
-- lease, four per instance and eight per VM, and the numeric ceiling of the profile.
defaultPolicy ∷ Policy
defaultPolicy =
  Policy RequiredRequest ["not_found", "io_error"] [] Nothing 4 8 9223372036854775807 "example" Nothing (Just (\value key → VRecord [("v", value), ("lease", VCapability (capability "res" key))])) 65536

-- | The instance fixture, the handles the owner leases and answers liveness through, the fake
-- provider and the policy.
data AFix = AFix
  { afBase ∷ !IFixture
  , afLending ∷ !Lending
  , afLeases ∷ !Leases
  , afHandles ∷ !RequestHandles
  , afFake ∷ !Fake
  , afPolicy ∷ !(IORef Policy)
  }

-- | A fixture whose instances may each have this much lease capacity charged.
newAFix ∷ Int → IO AFix
newAFix capacity = do
  base ← newIFixture
  lending ← newLending
  leases ← newLeases lending capacity
  handles ← newRequestHandles
  fake ← newFake
  AFix base lending leases handles fake <$> newIORef defaultPolicy

-- | Change the policy requests are admitted under from now on.
setPolicy ∷ AFix → (Policy → Policy) → IO ()
setPolicy fixture change = atomicModifyIORef' (afPolicy fixture) (\held → (change held, ()))

-- | Record that something happened, in the order the hooks and the fakes share.
note ∷ AFix → Text → IO ()
note fixture entry = atomicModifyIORef' (sfLog (sf (afBase fixture))) (\held → (entry : held, ()))

-- | What happened, oldest first.
history ∷ AFix → IO [Text]
history = logged . afBase

-- | How many times this happened.
historyCount ∷ AFix → Text → IO Int
historyCount fixture wanted = length . filter (== wanted) <$> history fixture

-- | Block, without sleeping, until this happened.
awaitNote ∷ AFix → Text → IO ()
awaitNote fixture wanted = do
  seen ← history fixture
  if wanted `elem` seen then pure () else yield >> awaitNote fixture wanted

-- | Block until the history satisfies this.
awaitHistory ∷ AFix → ([Text] → Bool) → IO ()
awaitHistory fixture wanted = do
  seen ← history fixture
  if wanted seen then pure () else yield >> awaitHistory fixture wanted

-- | Block until commands have started this many requests, however many were busy.
awaitStarts ∷ AFix → Int → IO ()
awaitStarts fixture wanted =
  awaitHistory fixture (\seen → length [() | line ← seen, Text.isPrefixOf "cmd start " line, Text.isSuffixOf " started" line] >= wanted)

-- The fake banks and resources -----------------------------------------------------------------

-- | A fake bank of credit: how much is left, and every way it was given back.
data Bank' = Bank'
  { bkLeft ∷ !(TVar Int)
  , bkReleases ∷ !(TVar [Text])
  }

-- | A bank with this much credit.
newBank ∷ Int → IO Bank'
newBank room = Bank' <$> newTVarIO room <*> newTVarIO []

-- | How much credit is left.
bankAvailable ∷ Bank' → IO Int
bankAvailable = atomically . readTVar . bkLeft

-- | How the credit was given back, oldest first: @name end@ for each.
bankLog ∷ Bank' → IO [Text]
bankLog = atomically . readTVar . bkReleases

-- | A credit of this bank: one unit each, given back when its request ends. One that transfers
-- is the resource's: its release is the resource's and the engine does not give it back.
bankCredit ∷ Text → Bool → Bank' → Credit
bankCredit name transfers bank =
  Credit
    { creditName = name
    , creditReserve = do
        room ← readTVar (bkLeft bank)
        if room > 0 then True <$ writeTVar (bkLeft bank) (room - 1) else pure False
    , creditRelease = \end → do
        modifyTVar' (bkLeft bank) (+ 1)
        modifyTVar' (bkReleases bank) (<> [name <> " " <> Text.pack (show end)])
    , creditTransfers = transfers
    }

-- | How the fake resource of this name was acquired and released, for the history.
releaseLog ∷ AFix → Text → [Text] → Bool
releaseLog _ name seen = ("release " <> name) `elem` seen

-- | The fake resource of this name: one part that records its acquisition and its release.
resourceFor ∷ AFix → Text → Assembly Text
resourceFor fixture name = do
  _ ←
    acquirePart
      name
      (releaseRank 0)
      (() <$ note fixture ("acquire " <> name))
      (\_ → note fixture ("release " <> name))
  pure name

-- | The provider answers the nth request with this integer and a resource of this name.
answerResource ∷ AFix → Int → Int → Text → IO ReplyAnswer
answerResource fixture index n name =
  answerWith (afFake fixture) index (ProviderResource (VInteger (fromIntegral n)) (Adoption (\_ → resourceFor fixture name)))

-- | The provider answers the nth request with a failure that has no code its service supplies.
answerFailure ∷ AFix → Int → Text → IO ReplyAnswer
answerFailure fixture index why = answerWith (afFake fixture) index (ProviderFailure why)

-- | The provider answers the nth request with an expected failure of this code.
answerExpected ∷ AFix → Int → Text → IO ReplyAnswer
answerExpected fixture index code =
  answerWith (afFake fixture) index (ProviderExpected (ExpectedFailure code ("detail of " <> code) (Just "root") (Just "path/to/file")))

-- The registration and the modules ---------------------------------------------------------------

-- | The admission the policy gives a request with this offset, as the bindings read it.
admissionOf ∷ AFix → Maybe Int → IO Admission
admissionOf fixture offset = do
  policy ← readIORef (afPolicy fixture)
  limits ← pure (either (error . show) id (valueLimits (polReplyBytes policy) 8 4096))
  pure $
    (admission (polNecessity policy) (polSource policy) limits (polCeiling policy) (polPerInstance policy) (polPerVm policy))
      { admitOffset = fmap (\given → if given <= 0 then 0 else fromIntegral given) offset
      , admitExpectedCodes = polCodes policy
      , admitCredits = polCredits policy
      , admitLease = polLease policy
      , admitCombine = polCombine policy
      , admitSuccessFrame = \value → [("status", VText "success"), ("value", value)]
      , admitFailureFrame = \found →
          [ ("status", VText "failure")
          , ("error", VRecord ([("code", VText (expectedCode found)), ("message", VText (expectedMessage found))] <> [("root", VText r) | Just r ← [expectedRoot found]] <> [("path", VText p) | Just p ← [expectedPath found]]))
          ]
      }

-- | The offset a start's third argument carries.
offsetOf ∷ [Value] → Maybe Int
offsetOf arguments = case drop 2 arguments of
  [VInteger given] → Just (fromIntegral given)
  _ → Nothing

-- | The bindings: @ad.start@ asks, @ad.ready@, @ad.take@, @ad.cancel@ and @ad.wait@ settle, and
-- @ad.lease_use@ borrows an adopted resource. The bindings are the binding author's view of
-- the API, and none of them does any cleanup of its own.
adNamespace ∷ AFix → Namespace
adNamespace fixture =
  namespace
    "ad"
    [ withArgumentCheck check $
        asynchronousNativeRequestIn "start" [SText, SInteger, SOptional SInteger] startSchemas $ \context arguments → case arguments of
          VText endpoint : VInteger n : _ → do
            ask ← admissionOf fixture (offsetOf arguments)
            disposal ← polDisposal <$> readIORef (afPolicy fixture)
            started ← startAdmitted context ask endpoint [VInteger n] (maybe (note fixture ("disposed " <> Text.pack (show n))) id disposal)
            pure $ case started of
              Started handle → [requestHandleValue "areq" handle, VNil]
              Unavailable bank → [VNil, VRecord [("code", VText "busy"), ("message", VText (renderBank bank))]]
          _ → pure []
    , -- A generic request: no handle is kept, and its result is retained by the model until taken or the instance ends.
      recoverableRefusals $
        asynchronousNativeRequestIn "gen_start" [SText, SInteger] [] $ \context arguments → case arguments of
          [VText endpoint, VInteger n] → [] <$ startRequest context endpoint [VInteger n] (pure ())
          _ → pure []
    , recoverableRefusals $
        asynchronousNativeRequestIn "ready" [SCapability "areq"] [SBoolean] $ \context arguments → case arguments of
          [VCapability handle] → (\settled → [VBoolean settled]) <$> readyAdmitted context (capabilityKey handle)
          _ → pure []
    , recoverableRefusals $
        asynchronousNativeRequestIn "take" [SCapability "areq"] [takeSchema] $ \context arguments → case arguments of
          [VCapability handle] →
            takeAdmitted context (capabilityKey handle) >>= \case
              TakenPending → pure [VRecord [("status", VText "pending")]]
              Taken terminal → pure [terminalRecord terminal]
          _ → pure []
    , recoverableRefusals $
        asynchronousNativeRequestIn "cancel" [SCapability "areq"] [SText] $ \context arguments → case arguments of
          [VCapability handle] →
            cancelAdmitted context (capabilityKey handle) >>= \case
              CancelWon → pure [VText "cancelled"]
              CancelAlreadySettled → pure [VText "already_settled"]
          _ → pure []
    , withPrecondition serving (waitOperation "wait" WaitSettlement [SCapability "areq"])
    , recoverableRefusals $ stateOperation "lease_use" [SCapability "res"] [SText] $ \arguments → case arguments of
        [VCapability handle] → do
          name ← withLease (afLeases fixture) (capabilityKey handle) pure
          note fixture ("use " <> name)
          pure [VText name]
        _ → pure []
    ]
  where
    startSchemas = [SOptional (SCapability "areq"), SOptional (SRecord [("code", SText), ("message", SText)])]
    check owner arguments = case contextRequests owner of
      Nothing → pure Nothing
      Just context → do
        ask ← admissionOf fixture (offsetOf arguments)
        preflightAdmission context ask
    serving owner = case contextRequests owner of
      Nothing → pure Nothing
      Just context →
        callerPhase context >>= \case
          Just CallerServing → pure Nothing
          Just CallerInitializing → pure (Just "wait is not available in init")
          Just CallerEnding → pure (Just "wait is not available in shutdown")
          Nothing → pure (Just "wait is made by an instance")
    takeSchema =
      SRecord
        [ ("status", SText)
        , ("value", SOptional (SRecord [("v", SInteger), ("lease", SOptional (SCapability "res"))]))
        , ("error", SOptional (SRecord [("code", SText), ("message", SText), ("root", SOptional SText), ("path", SOptional SText)]))
        ]
    terminalRecord = \case
      TerminalSuccess value → VRecord [("status", VText "success"), ("value", shaped value)]
      TerminalFailure found →
        VRecord
          [ ("status", VText "failure")
          , ("error", VRecord ([("code", VText (expectedCode found)), ("message", VText (expectedMessage found))] <> [("root", VText r) | Just r ← [expectedRoot found]] <> [("path", VText p) | Just p ← [expectedPath found]]))
          ]
      TerminalCancelled → VRecord [("status", VText "cancelled")]
    shaped = \case
      VInteger n → VRecord [("v", VInteger n)]
      other → other

-- | The Lua every module shares: a deterministic rendering of what came back, and the commands
-- an instance obeys.
prelude ∷ [Text]
prelude =
  [ "local function fmt(v)"
  , "  local t = type(v)"
  , "  if t ~= 'table' then"
  , "    if t == 'userdata' or t == 'function' then return '<' .. t .. '>' end"
  , "    return tostring(v)"
  , "  end"
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
  , "local function run(self, p)"
  , "  fx.delay()"
  , "  local key = p.key or 'a'"
  , "  local out = '?'"
  , "  if p.op == 'start' then"
  , "    local r, err = ad.start(p.endpoint or 'path', p.n or 0, p.offset)"
  , "    if r then self.hs[key] = r out = 'started' else out = 'busy:' .. err.code end"
  , "  elseif p.op == 'pstart' then"
  , "    local ok, r, err = pcall(ad.start, p.endpoint or 'path', p.n or 0, p.offset)"
  , "    if not ok then out = 'error ' .. tostring(r)"
  , "    elseif r then self.hs[key] = r out = 'started'"
  , "    else out = 'busy:' .. err.code .. ' ' .. err.message end"
  , "  elseif p.op == 'gstart' then"
  , "    ad.gen_start(p.endpoint or 'path', p.n or 0)"
  , "    out = 'started'"
  , "  elseif p.op == 'pgstart' then"
  , "    local ok = pcall(ad.gen_start, p.endpoint or 'path', p.n or 0)"
  , "    out = ok and 'started' or 'refused'"
  , "  elseif p.op == 'ready' then out = tostring(ad.ready(self.hs[key]))"
  , "  elseif p.op == 'take' then out = fmt(ad.take(self.hs[key]))"
  , "  elseif p.op == 'ptake' then"
  , "    local ok, r = pcall(ad.take, self.hs[key])"
  , "    if ok then out = fmt(r) else out = 'error ' .. tostring(r) end"
  , "  elseif p.op == 'pready' then"
  , "    local ok, r = pcall(ad.ready, self.hs[key])"
  , "    if ok then out = tostring(r) else out = 'error ' .. tostring(r) end"
  , "  elseif p.op == 'pcancel' then"
  , "    local ok, r = pcall(ad.cancel, self.hs[key])"
  , "    if ok then out = tostring(r) else out = 'error ' .. tostring(r) end"
  , "  elseif p.op == 'cancel' then out = ad.cancel(self.hs[key])"
  , "  elseif p.op == 'wait' then"
  , "    fx.record('waiting ' .. key)"
  , "    ad.wait(self.hs[key])"
  , "    out = 'woke'"
  , "  elseif p.op == 'pwait' then"
  , "    local ok, r = pcall(ad.wait, self.hs[key])"
  , "    if ok then out = 'woke' else out = 'error ' .. tostring(r) end"
  , "  elseif p.op == 'wait_take' then"
  , "    fx.record('waiting ' .. key)"
  , "    ad.wait(self.hs[key])"
  , "    out = fmt(ad.take(self.hs[key]))"
  , "  elseif p.op == 'take_use' then"
  , "    local r = ad.take(self.hs[key])"
  , "    self.lease = r.value.lease"
  , "    out = fmt(r) .. ' ' .. ad.lease_use(self.lease)"
  , "  elseif p.op == 'use' then out = ad.lease_use(self.lease)"
  , "  elseif p.op == 'drop' then"
  , "    self.hs[key] = nil"
  , "    collectgarbage()"
  , "    out = 'dropped'"
  , "  elseif p.op == 'stash' then"
  , "    OTHER = self.hs[key]"
  , "    out = 'stashed'"
  , "  elseif p.op == 'pother' then"
  , "    local ok, r = pcall(ad.take, OTHER)"
  , "    if ok then out = fmt(r) else out = 'error ' .. tostring(r) end"
  , "  elseif p.op == 'pwait_other' then"
  , "    local ok, r = pcall(ad.wait, OTHER)"
  , "    if ok then out = 'woke' else out = 'error ' .. tostring(r) end"
  , "  elseif p.op == 'start_take_start' then"
  , "    -- A place freed by this take is visible to the next start of the same call."
  , "    local first = fmt(ad.take(self.hs[key]))"
  , "    local r, err = ad.start(p.endpoint or 'path', p.n or 0, p.offset)"
  , "    if r then self.hs['next'] = r out = first .. ' started' else out = first .. ' busy:' .. err.code end"
  , "  elseif p.op == 'late' then"
  , "    -- Held in this call while the provider answers: nothing of the answer is read before the"
  , "    -- script goes on, and what the script does next cannot undo it."
  , "    fx.block(key)"
  , "    local c = ad.cancel(self.hs[key])"
  , "    local ok, err = pcall(ad.take, 42)"
  , "    local ok2, err2 = pcall(ad.ready)"
  , "    out = c .. ' ' .. tostring(ok) .. ' ' .. tostring(ok2)"
  , "  elseif p.op == 'pbad' then"
  , "    local _, arity = pcall(ad.take)"
  , "    local _, kind = pcall(ad.take, 5)"
  , "    local _, wrong = pcall(ad.lease_use, self.hs[key])"
  , "    out = tostring(arity) .. ' | ' .. tostring(kind) .. ' | ' .. tostring(wrong)"
  , "  elseif p.op == 'block' then"
  , "    fx.block(key)"
  , "    out = 'unblocked'"
  , "  elseif p.op == 'boom' then"
  , "    error('script boom')"
  , "  elseif p.op == 'noop' then"
  , "    out = 'noop'"
  , "  end"
  , "  fx.record('cmd ' .. p.op .. ' ' .. key .. ' ' .. out)"
  , "end"
  , "local function connect(self, api) api.connect('cmd', function(self, event) run(self, event.payload) end) end"
  ]

-- | An instance that does what it is told with its requests, and records the answers.
admitter ∷ ModuleSource
admitter =
  hooksModule "admitter" $
    prelude
      <> [ "function init(self, api) self.hs = {} connect(self, api) end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | An instance that starts a request in @init@ and records what came back.
initAdmitter ∷ ModuleSource
initAdmitter =
  hooksModule "initadmitter" $
    prelude
      <> [ "function init(self, api)"
         , "  self.hs = {}"
         , "  local r, err = ad.start('path', 1, nil)"
         , "  if r then self.hs['a'] = r fx.record('init started') else fx.record('init busy ' .. err.code) end"
         , "  connect(self, api)"
         , "end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | A periodic instance that starts a request in each update.
updateAdmitter ∷ ModuleSource
updateAdmitter =
  hooksModule "updateadmitter" $
    prelude
      <> [ "function init(self, api) self.hs = {} self.updates = 0 connect(self, api) end"
         , "function update(self, dt)"
         , "  self.updates = self.updates + 1"
         , "  local r, err = ad.start('path', 100 + self.updates, nil)"
         , "  if r then self.hs['u' .. self.updates] = r fx.record('update started u' .. self.updates) else fx.record('update busy ' .. err.code) end"
         , "end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | An instance that starts a request in @init@, and waits for it there with the error caught.
initWaiter ∷ ModuleSource
initWaiter =
  hooksModule "initwaiter" $
    prelude
      <> [ "function init(self, api)"
         , "  self.hs = {}"
         , "  self.hs['a'] = ad.start('path', 1, nil)"
         , "  local ok, err = pcall(ad.wait, self.hs['a'])"
         , "  fx.record('init wait ' .. tostring(ok) .. ' ' .. tostring(err))"
         , "  connect(self, api)"
         , "end"
         , "function shutdown(self, reason)"
         , "  local ok, err = pcall(ad.wait, self.hs['a'])"
         , "  fx.record('shutdown wait ' .. tostring(ok) .. ' ' .. tostring(err))"
         , "end"
         ]

-- | An instance that tries to start a request in its @shutdown@ hook, where none is taken.
shutdownStarter ∷ ModuleSource
shutdownStarter =
  hooksModule "shutdownstarter" $
    prelude
      <> [ "function init(self, api) self.hs = {} connect(self, api) end"
         , "function shutdown(self, reason)"
         , "  local ok, err = pcall(ad.start, 'path', 98, nil)"
         , "  fx.record('shutdown start ' .. tostring(ok) .. ' ' .. tostring(err))"
         , "end"
         ]

-- | An instance whose @shutdown@ is held at the gate @s@, so that its owner's exit is under way while the
-- instance still has its requests.
shutdownBlocker ∷ ModuleSource
shutdownBlocker =
  hooksModule "shutdownblocker" $
    prelude
      <> [ "function init(self, api) self.hs = {} connect(self, api) end"
         , "function shutdown(self, reason)"
         , "  fx.block('s')"
         , "  fx.record('shutdown unblocked')"
         , "end"
         ]

-- | A one-shot instance whose @run@ starts a request and returns.
oneShotStarter ∷ ModuleSource
oneShotStarter =
  hooksModule
    "oneshotstarter"
    [ "function run(self, api)"
    , "  local r, err = ad.start('path', 1, nil)"
    , "  fx.record('run started ' .. tostring(r ~= nil))"
    , "end"
    ]

-- Owners ---------------------------------------------------------------------------------------

-- | The commands an instance is told, as a record.
acmdSource ∷ EventSource
acmdSource =
  EventSource
    "cmd"
    (SRecord [("op", SText), ("key", SOptional SText), ("endpoint", SOptional SText), ("n", SOptional SInteger), ("offset", SOptional SInteger)])

-- | Bounds and sources for an owner of admitters.
aConfig ∷ InstanceConfig
aConfig = (testConfig instanceBounds') {instanceSources = [acmdSource, tickSource]}

-- | A grant over the fake's @path@ and @res@ endpoints, with room for this many.
admissionGrant ∷ AFix → Int → RequestTiming → RequestGrant
admissionGrant fixture bound timing =
  RequestGrant [fakeEndpoint (afFake fixture) "path", fakeEndpoint (afFake fixture) "res"] bound timing

-- | The specification of an owner of admitters: it lends its collection, holds leases, answers the
-- liveness of handles and is granted requests.
admissionSpec ∷ AFix → Text → [ModuleSource] → InstanceConfig → RequestGrant → WorkerPolicy → ScheduledSpec
admissionSpec fixture label modules config grant worker =
  base
    { scheduledVm =
        vm
          { vmRegistration = registered
          , vmPolicy = ["sched", "fx", "ad"]
          , vmModules = modules
          }
    , scheduledInstances = Just config
    , scheduledLending = Just (afLending fixture)
    , scheduledLeases = Just (afLeases fixture)
    , scheduledRequestHandles = Just (afHandles fixture)
    , scheduledRequests = Just grant
    }
  where
    base = scheduledWithBase fixture label worker
    vm = scheduledVm base
    registered =
      either (error . ("registration refused: " <>) . show) id $
        registration
          [admittedHandleType (afHandles fixture) "areq", leaseCapabilityType (afLeases fixture) "res"]
          (registrationNamespaces (schedRegistration (sf (afBase fixture))) <> [adNamespace fixture])

scheduledWithBase ∷ AFix → Text → WorkerPolicy → ScheduledSpec
scheduledWithBase fixture label worker = instanceSpec (afBase fixture) label [] aConfig worker defaultSchedulerBounds

-- | Start an owner of admitters.
startAdmitting ∷ AFix → LuaRuntime → Text → [ModuleSource] → InstanceConfig → RequestGrant → WorkerPolicy → IO ScheduledOwner
startAdmitting fixture runtime label modules config grant worker =
  startScheduled (sf (afBase fixture)) runtime (admissionSpec fixture label modules config grant worker)

-- | Admit an event-only instance of this module under this name and wait until it is active.
admitAdmitter ∷ AFix → ScheduledOwner → Text → Text → IO ()
admitAdmitter fixture owner name moduleName = do
  _ ← admitWith (afBase fixture) owner name (InstanceRequest (moduleNamed moduleName) EventOnly (Just name) OrdinaryClass ["cmd", "tick"])
  awaitPhase (afBase fixture) owner name Active

-- | Tell the admitter of this name to do this with the request it keeps under the key.
acommand ∷ AFix → ScheduledOwner → Text → Text → Text → IO ()
acommand fixture owner name op key = acommandWith fixture owner name op key Nothing Nothing Nothing

-- | The same, with the endpoint, the integer and the offset a start asks with.
acommandWith ∷ AFix → ScheduledOwner → Text → Text → Text → Maybe Text → Maybe Int → Maybe Int → IO ()
acommandWith fixture owner name op key endpoint n offset = do
  identity ← idOf (afBase fixture) name
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key)]
            <> [("endpoint", VText found) | Just found ← [endpoint]]
            <> [("n", VInteger (fromIntegral found)) | Just found ← [n]]
            <> [("offset", VInteger (fromIntegral found)) | Just found ← [offset]]
  deliverEvent (scheduledEndpoint owner) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → failExample ("expected the command accepted, found " <> show other)

-- | The provider proves every piece of work over and every gate a script is held at goes on, however the
-- example ends, so a failing example unwinds instead of leaving the owner inside a call it waits for.
settleAll ∷ AFix → IO a → IO a
settleAll fixture body = body `finally` (openAllGates (afBase fixture) >> finishAll (afFake fixture))

-- Reading ---------------------------------------------------------------------------------------

-- | One instance's leases, in one transaction.
leaseSummary ∷ AFix → Text → IO ScopeSummary
leaseSummary fixture name = do
  identity ← idOf (afBase fixture) name
  atomically (instanceLeases (afLeases fixture) identity)

-- | Block, in STM, until an instance's leases satisfy this.
awaitLeaseSummary ∷ AFix → Text → (ScopeSummary → Bool) → IO ()
awaitLeaseSummary fixture name wanted = do
  identity ← idOf (afBase fixture) name
  atomically $ do
    summary ← instanceLeases (afLeases fixture) identity
    if wanted summary then pure () else retry

-- | How many places the service's ledger holds for this instance.
heldBy ∷ AFix → ScheduledOwner → Text → IO Int
heldBy fixture owner name = do
  identity ← idOf (afBase fixture) name
  d ← diagnostics owner
  pure (Map.findWithDefault 0 (instanceLocal identity) (rdHeldBy d))

-- | Wait, without sleeping, for a line a script recorded that starts with this, and answer it.
lineStarting ∷ AFix → Text → IO Text
lineStarting fixture prefix = do
  seen ← history fixture
  case filter (Text.isPrefixOf prefix) seen of
    line : _ → pure line
    [] → yield >> lineStarting fixture prefix
