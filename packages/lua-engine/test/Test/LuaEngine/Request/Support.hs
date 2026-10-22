{-# LANGUAGE OverloadedStrings #-}

-- | What the M1 request adapter examples share: a rig of real instances on a real supervised
-- scheduled owner with a controlled fake provider and fake lease resources, bindings written
-- the way an engine facade writes them from "Hetoimasia.LuaEngine.Request", and the Lua that
-- calls them.
--
-- The rig is built from the public host and runtime modules alone; no helper of the host's own
-- suites is imported. Nothing sleeps: an example knows what has happened by blocking in STM, on a
-- gate, or on what a script recorded.
module Test.LuaEngine.Request.Support
  ( -- * The rig
    Rig (..)
  , Ask' (..)
  , defaultAsk
  , withRig
  , fatalRig
  , setAsk
  , note
  , history
  , awaitNote
  , awaitHistory
  , lineStarting
  , awaitStarts

    -- * The fake provider
  , Handed (..)
  , handedAt
  , submissionCount
  , answerWith
  , answerData
  , answerTexture
  , answerContentFailure
  , answerWindowFailure
  , finishWork
  , finishAll
  , awaitCancelled
  , cancelCount

    -- * Banks and resources
  , Pool (..)
  , newPool
  , poolLeft
  , poolLog
  , poolCredit

    -- * Owners
  , Timing (..)
  , startRig
  , admitDriver
  , admitModule
  , stopInstance
  , command
  , commandWith
  , grantOne
  , diagnostics
  , awaitDiagnostic
  , awaitPhase
  , awaitGate
  , openGate
  , awaitEnd
  , awaitFailure
  , requestFailureOf
  , leaseSummary
  , awaitLeaseSummary
  , module Hetoimasia.LuaEngine.Request
  , module Hetoimasia.Scripting.Lua.Provider
  , Necessity (..)
  , ScopeSummary (..)
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, finally, fromException, throwIO, tryWithContext)
import Control.Monad (void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import System.Timeout (timeout)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith, unsafeComponent)
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank)
import Hetoimasia.Foundation.Time (DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.LuaEngine.Profile (Profile)
import Hetoimasia.LuaEngine.Request
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  , WorkerStatus (..)
  , awaitSupervised
  , withSupervision
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (Credit (..), CreditEnd, Necessity (..), RequestHandles, admittedHandleType, newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Leases, Ownership (..), ScopeSummary (..), instanceLeases, leaseCapabilityType, newLeases, withLease)
import Hetoimasia.Scripting.Lua.Lending (Lending, newLending)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.HUnit.Lang (HUnitFailure, assertFailure)

-- The rig ----------------------------------------------------------------------------------

-- | What one request-producing binding asks, as the example sets it.
data Ask' = Ask'
  { askNecessityOf ∷ !Necessity
  , askCreditsOf ∷ ![Credit]
  , askWindowsHeld ∷ !(Maybe Int)
    -- ^ Windows the example says the instance holds: a second is a permanent refusal of the window service.
  }

-- | A required request with no credits.
defaultAsk ∷ Ask'
defaultAsk = Ask' RequiredRequest [] Nothing

-- | The fake provider's record of what it was handed.
data Handed = Handed
  { hdIndex ∷ !Int
  , hdCompletion ∷ !Completion
  , hdInfo ∷ !RequestInfo
  , hdRetirement ∷ !(TVar RetirementState)
  }

-- | Everything an example drives.
data Rig = Rig
  { rgProfile ∷ !Profile
  , rgRequests ∷ !M1Requests
  , rgHandles ∷ !RequestHandles
  , rgLending ∷ !Lending
  , rgLeases ∷ !Leases
  , rgLog ∷ !(IORef [Text])
  , rgAsk ∷ !(IORef Ask')
  , rgHanded ∷ !(TVar [Handed])
  , rgCancels ∷ !(TVar [Int])
  , rgGates ∷ !(IORef (Map Text (MVar ())))
  , rgOpened ∷ !(IORef Bool)
    -- ^ Every gate is open, now and for good: set when an example ends however it ends.
  , rgEntered ∷ !(IORef (Map Text (MVar ())))
  , rgIds ∷ !(IORef (Map Text InstanceId))
  , rgTickets ∷ !(IORef (Map Text InstanceTicket))
  }

-- | Run an example over a rig for this profile, the lease capacity per instance, and the real
-- supervision boundary. Whatever way it ends the provider proves all its work over, so a failing
-- example fails instead of waiting for an owner that is right to wait.
withRig ∷ Profile → Int → (Rig → RuntimeControl → LuaRuntime → IO a) → IO a
withRig profile capacity body = do
  handles ← newRequestHandles
  requests ← either (\refused → assertFailure ("the profile was refused: " <> show refused)) pure (m1Requests profile handles)
  lending ← newLending
  leases ← newLeases lending capacity
  rig ←
    Rig profile requests handles lending leases
      <$> newIORef []
      <*> newIORef defaultAsk
      <*> newTVarIO []
      <*> newTVarIO []
      <*> newIORef Map.empty
      <*> newIORef False
      <*> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef Map.empty
  withLoggingLifetime quietLogger $ \lifetime →
    withSupervision lifetime $ \control → do
      runtime ← newLuaRuntime control
      -- The example is bounded: one that waits for what never comes fails, with its gates let go
      -- and the provider's work proved over, instead of waiting for ever.
      outcome ← timeout exampleBound (body rig control runtime) `finally` (writeIORef (rgOpened rig) True >> openGates rig >> finishAll rig)
      maybe (assertFailure "the example did not finish within its bound") pure outcome

-- | An example whose owner is expected to end in a failure of the application's own, which
-- supervision raises at the boundary: answers the failure with its context. A failed assertion or
-- the example's bound is not that failure, and is raised as itself.
fatalRig ∷ Profile → Int → (Rig → RuntimeControl → LuaRuntime → IO ()) → IO (ExceptionWithContext SomeException)
fatalRig profile capacity body =
  tryWithContext @SomeException (withRig profile capacity body) >>= \case
    Left failure@(ExceptionWithContext _ raised)
      | Just (_ ∷ HUnitFailure) ← fromException raised → throwIO raised
      | otherwise → pure failure
    Right () → assertFailure "expected the owner to fail, but the example returned"

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- | Change what the request-producing bindings ask from now on.
setAsk ∷ Rig → (Ask' → Ask') → IO ()
setAsk rig change = atomicModifyIORef' (rgAsk rig) (\held → (change held, ()))

-- | Record that something happened, in the order the scripts and the fakes share.
note ∷ Rig → Text → IO ()
note rig entry = atomicModifyIORef' (rgLog rig) (\held → (entry : held, ()))

-- | What happened, oldest first.
history ∷ Rig → IO [Text]
history rig = reverse <$> readIORef (rgLog rig)

-- | Wait, without sleeping, until this was recorded.
awaitNote ∷ Rig → Text → IO ()
awaitNote rig wanted = awaitHistory rig (wanted `elem`)

-- | Wait until the history satisfies this.
awaitHistory ∷ Rig → ([Text] → Bool) → IO ()
awaitHistory rig wanted = do
  seen ← history rig
  if wanted seen then pure () else yield >> awaitHistory rig wanted

-- | Wait for a line that starts with this, and answer it.
lineStarting ∷ Rig → Text → IO Text
lineStarting rig prefix = do
  seen ← history rig
  case filter (Text.isPrefixOf prefix) seen of
    line : _ → pure line
    [] → yield >> lineStarting rig prefix

-- | Wait until this many requests have been started by commands.
awaitStarts ∷ Rig → Int → IO ()
awaitStarts rig wanted =
  awaitHistory rig (\seen → length [() | line ← seen, Text.isPrefixOf "cmd start" line, Text.isSuffixOf " started" line] >= wanted)

-- The fake provider --------------------------------------------------------------------------

-- | The endpoint of this name, backed by the rig's provider.
fakeEndpoint ∷ Rig → Text → Schema → RequestEndpoint
fakeEndpoint rig name schema =
  RequestEndpoint
    { endpointName = name
    , endpointResult = schema
    , endpointSubmit = \submission → do
        (index, retirement) ← atomically $ do
          held ← readTVar (rgHanded rig)
          retirement ← newTVar ProviderPending
          let index = length held
          writeTVar (rgHanded rig) (held <> [Handed index (submissionCompletion submission) (submissionInfo submission) retirement])
          pure (index, retirement)
        pure
          ProviderWork
            { workCancel = atomically (modifyTVar' (rgCancels rig) (<> [index]))
            , workRetirement = readTVar retirement
            }
    }

-- | The nth request the provider was handed.
handedAt ∷ Rig → Int → IO Handed
handedAt rig index = do
  held ← atomically (readTVar (rgHanded rig))
  case drop index held of
    found : _ → pure found
    [] → assertFailure ("the provider was handed no request " <> show index)

-- | How many requests the provider was handed.
submissionCount ∷ Rig → IO Int
submissionCount rig = length <$> atomically (readTVar (rgHanded rig))

-- | The provider answers the nth request.
answerWith ∷ Rig → Int → ProviderReply → IO ReplyAnswer
answerWith rig index reply = do
  found ← handedAt rig index
  completeRequest (hdCompletion found) reply

-- | The provider answers a data request with this size.
answerData ∷ Rig → Int → Int → IO ReplyAnswer
answerData rig index size = answerWith rig index (ProviderResult (VRecord [("size", VInteger (fromIntegral size))]))

-- | The provider answers a texture request with a resource of this name.
answerTexture ∷ Rig → Int → Text → IO ReplyAnswer
answerTexture rig index name =
  answerWith rig index (ProviderResource (VRecord [("width", VInteger 4), ("height", VInteger 2)]) (Adoption (\_ → resourceFor rig name)))

-- | The provider answers with an expected content failure of this code, whose root and path are named.
answerContentFailure ∷ Rig → Int → Text → IO ReplyAnswer
answerContentFailure rig index code =
  answerWith rig index (ProviderExpected (ExpectedFailure code ("could not read " <> code) (Just "assets") (Just "images/quad.png")))

-- | The provider answers with an expected window failure: no root and no path.
answerWindowFailure ∷ Rig → Int → IO ReplyAnswer
answerWindowFailure rig index =
  answerWith rig index (ProviderExpected (ExpectedFailure "window_error" "the display refused the window" Nothing Nothing))

-- | The provider proves the nth request's work over.
finishWork ∷ Rig → Int → IO ()
finishWork rig index = do
  found ← handedAt rig index
  atomically (writeTVar (hdRetirement found) ProviderComplete)

-- | The provider proves everything it was handed over.
finishAll ∷ Rig → IO ()
finishAll rig = atomically $ do
  held ← readTVar (rgHanded rig)
  mapM_ (\found → writeTVar (hdRetirement found) ProviderComplete) held

-- | Block until the provider has been told of this many withdrawals.
awaitCancelled ∷ Rig → Int → IO ()
awaitCancelled rig wanted = atomically $ do
  held ← readTVar (rgCancels rig)
  if length held >= wanted then pure () else retry

-- | How many withdrawals the provider was told of.
cancelCount ∷ Rig → IO Int
cancelCount rig = length <$> atomically (readTVar (rgCancels rig))

-- Banks and resources ----------------------------------------------------------------------------

-- | A fake bank of credit.
data Pool = Pool
  { plLeft ∷ !(TVar Int)
  , plReleases ∷ !(TVar [Text])
  }

-- | A bank with this much credit.
newPool ∷ Int → IO Pool
newPool room = Pool <$> newTVarIO room <*> newTVarIO []

-- | How much credit is left.
poolLeft ∷ Pool → IO Int
poolLeft = atomically . readTVar . plLeft

-- | How the credit was given back, oldest first.
poolLog ∷ Pool → IO [Text]
poolLog = atomically . readTVar . plReleases

-- | A credit of this pool: one unit, given back when its request ends.
poolCredit ∷ Text → Bool → Pool → Credit
poolCredit name transfers pool =
  Credit
    { creditName = name
    , creditReserve = do
        room ← readTVar (plLeft pool)
        if room > 0 then True <$ writeTVar (plLeft pool) (room - 1) else pure False
    , creditRelease = \end → do
        modifyTVar' (plLeft pool) (+ 1)
        modifyTVar' (plReleases pool) (<> [name <> " " <> Text.pack (show (end ∷ CreditEnd))])
    , creditTransfers = transfers
    }

-- | The fake resource of this name: one part that records its acquisition and its release.
resourceFor ∷ Rig → Text → Assembly Text
resourceFor rig name = do
  _ ← acquirePart name (releaseRank 0) (() <$ note rig ("acquire " <> name)) (\_ → note rig ("release " <> name))
  pure name

-- Owners ---------------------------------------------------------------------------------------------

-- | How the owner's settlements reach Lua.
data Timing = OnArrival | AtAssignedTick
  deriving (Eq, Show)

-- | A required worker whose component recognizes nothing.
requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Service Supervision.Required (unsafeComponent "test.luaengine") (\_ → pure Unrecognized)

-- | The service the facade assembles under @api.request@: handles of one type, and one shape of value.
service ∷ M1Service
service =
  M1Service
    { serviceHandleType = "areq"
    , serviceValue =
        SRecord
          [ ("size", SOptional SInteger)
          , ("texture", SOptional (SCapability "texture"))
          , ("width", SOptional SInteger)
          , ("height", SOptional SInteger)
          ]
    }

-- | The codes the content services supply.
contentCodes ∷ [Text]
contentCodes = ["not_found", "io_error", "too_large", "invalid_image"]

-- | The bindings: request-producing ones written as a facade writes them, and the common
-- operations from the adapter.
bindings ∷ Rig → [Namespace]
bindings rig =
  [ namespace "fx" [recording, blocking]
  , namespace "request" (m1RequestBindings service)
  , namespace
      "fixture"
      [ producing "data" [SText] $ \_ → pure (m1 {askCodes = contentCodes})
      , producing "texture" [SText] $ \_ →
          pure ((m1 {askCodes = contentCodes}) {askLease = Just (InstanceOwned, composeTexture)})
      , producing "window" [SText] $ \_ → pure m1 {askCodes = ["window_error"]}
      , producing "text" [SText] $ \_ → pure (m1 {askCodes = contentCodes})
      , producing "ints" [SText] $ \_ → pure (m1 {askCodes = contentCodes})
      , producing "nested" [SText] $ \_ → pure (m1 {askCodes = contentCodes})
      , recoverableRefusals $
          stateOperation "use" [SCapability "texture"] [SText] $ \arguments → case arguments of
            [VCapability handle] → do
              name ← withLease (rgLeases rig) (capabilityKey handle) pure
              note rig ("use " <> name)
              pure [VText name]
            _ → pure []
      ]
  ]
  where
    m1 = m1Ask RequiredRequest "fixture"
    recording =
      stateOperation "record" [SText] [] $ \arguments → do
        case arguments of
          [VText text] → note rig text
          _ → pure ()
        pure []
    blocking =
      stateOperation "block" [SText] [] $ \arguments → do
        case arguments of
          [VText name] → do
            gateIn (rgEntered rig) name >>= void . (`tryPutMVar` ())
            opened ← readIORef (rgOpened rig)
            gate ← gateIn (rgGates rig) name
            if opened then void (tryPutMVar gate ()) else pure ()
            readMVar gate
          _ → pure ()
        pure []
    composeTexture value key = case value of
      VRecord fields → VRecord (("texture", VCapability (capability "texture" key)) : fields)
      other → other
    -- A request-producing binding written the way a facade writes it: the argument check carries
    -- the permanent refusals (the adapter's, and the service's own), the action asks atomically
    -- and answers the request or the busy record.
    producing name arguments askOf =
      withArgumentCheck check $
        asynchronousNativeRequestIn name (arguments <> [SOptional SInteger]) (m1StartSchemas "areq") $ \context values → do
          ask ← askFor values
          started ← startM1 (rgRequests rig) ask context endpointName' (take 1 values) (note rig ("disposed " <> name))
          pure (m1StartResults "areq" started)
      where
        endpointName' = name
        askFor values = do
          current ← readIORef (rgAsk rig)
          base ← askOf values
          pure
            base
              { askNecessity = askNecessityOf current
              , askOffset = case drop (length arguments) values of
                  [VInteger offset] → Just (offsetFromLua offset)
                  _ → Nothing
              , askCredits = askCreditsOf current
              }
        check owner values = do
          current ← readIORef (rgAsk rig)
          -- The service's own permanent refusal: one window at a time, said apart from busy.
          case (name, askWindowsHeld current) of
            ("window", Just held) | held >= 1 → pure (Just "a second window is not allowed")
            _ → do
              ask ← askFor values
              m1ArgumentCheck (rgRequests rig) (const ask) owner values

-- | The gate of this name, made when first asked for.
gateIn ∷ IORef (Map Text (MVar ())) → Text → IO (MVar ())
gateIn table name = do
  fresh ← newEmptyMVar
  atomicModifyIORef' table $ \held → case Map.lookup name held of
    Just existing → (held, existing)
    Nothing → (Map.insert name fresh held, fresh)

-- | Let every gate go on, those made and those to be made.
openGates ∷ Rig → IO ()
openGates rig = do
  held ← readIORef (rgGates rig)
  mapM_ (void . (`tryPutMVar` ())) held

-- | How long an example may run, in microseconds.
exampleBound ∷ Int
exampleBound = 20 * 1000 * 1000

-- | The Lua the commands run.
driverSource ∷ ModuleSource
driverSource =
  ModuleSource (ModuleRef "driver" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
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
      , "  for _, k in ipairs(keys) do out[#out + 1] = k .. '=' .. fmt(v[k]) end"
      , "  return '{' .. table.concat(out, ',') .. '}'"
      , "end"
      , "local function starter(p)"
      , "  if p.what == 'texture' then return fixture.texture(p.path or 'quad.png', p.offset)"
      , "  elseif p.what == 'window' then return fixture.window(p.path or 'main', p.offset)"
      , "  elseif p.what == 'text' then return fixture.text(p.path or 'a.txt', p.offset)"
      , "  elseif p.what == 'ints' then return fixture.ints(p.path or 'a.ints', p.offset)"
      , "  elseif p.what == 'nested' then return fixture.nested(p.path or 'a.nested', p.offset)"
      , "  else return fixture.data(p.path or 'a.bin', p.offset) end"
      , "end"
      , "local function run(self, p)"
      , "  local key = p.key or 'a'"
      , "  local out = '?'"
      , "  if p.op == 'start' then"
      , "    local r, err = starter(p)"
      , "    if r then self.hs[key] = r out = 'started' else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'pstart' then"
      , "    local ok, r, err = pcall(starter, p)"
      , "    if not ok then out = 'error ' .. tostring(r)"
      , "    elseif r then self.hs[key] = r out = 'started'"
      , "    else out = 'busy:' .. err.code end"
      , "  elseif p.op == 'ready' then out = tostring(request.ready(self.hs[key]))"
      , "  elseif p.op == 'take' then out = fmt(request.take(self.hs[key]))"
      , "  elseif p.op == 'ptake' then"
      , "    local ok, r = pcall(request.take, self.hs[key])"
      , "    if ok then out = fmt(r) else out = 'error ' .. tostring(r) end"
      , "  elseif p.op == 'mutate' then"
      , "    local a = request.take(self.hs[key])"
      , "    a.status = 'mutated'"
      , "    out = fmt(request.take(self.hs[key]))"
      , "  elseif p.op == 'cancel' then out = request.cancel(self.hs[key])"
      , "  elseif p.op == 'wait' then"
      , "    fx.record('waiting ' .. key)"
      , "    out = tostring(select('#', request.wait(self.hs[key])))"
      , "  elseif p.op == 'wait_take' then"
      , "    fx.record('waiting ' .. key)"
      , "    request.wait(self.hs[key])"
      , "    out = fmt(request.take(self.hs[key]))"
      , "  elseif p.op == 'take_use' then"
      , "    local r = request.take(self.hs[key])"
      , "    self.texture = r.value.texture"
      , "    out = fmt(r) .. ' ' .. fixture.use(self.texture)"
      , "  elseif p.op == 'use' then out = fixture.use(self.texture)"
      , "  elseif p.op == 'stash' then OTHER = self.hs[key] out = 'stashed'"
      , "  elseif p.op == 'pother' then"
      , "    local ok, r = pcall(request.take, OTHER)"
      , "    if ok then out = fmt(r) else out = 'error ' .. tostring(r) end"
      , "  elseif p.op == 'late' then"
      , "    fx.block(key)"
      , "    local c = request.cancel(self.hs[key])"
      , "    local ok = pcall(request.take, 42)"
      , "    local ok2 = pcall(request.ready)"
      , "    out = c .. ' ' .. tostring(ok) .. ' ' .. tostring(ok2)"
      , "  elseif p.op == 'noop' then out = 'noop'"
      , "  end"
      , "  fx.record('cmd ' .. p.op .. ' ' .. key .. ' ' .. out)"
      , "end"
      , "function init(self, api)"
      , "  self.hs = {}"
      , "  api.connect('cmd', function(self, event) run(self, event.payload) end)"
      , "end"
      , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
      ]

-- | An instance that waits for a request in @init@ and in @shutdown@, and asks in @shutdown@, with
-- every error caught and recorded.
phaserSource ∷ ModuleSource
phaserSource =
  ModuleSource (ModuleRef "phaser" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
      [ "function init(self, api)"
      , "  self.r = fixture.data('init.bin', nil)"
      , "  local ok, err = pcall(request.wait, self.r)"
      , "  fx.record('init wait ' .. tostring(ok) .. ' ' .. tostring(err))"
      , "end"
      , "function shutdown(self, reason)"
      , "  local ok, err = pcall(request.wait, self.r)"
      , "  fx.record('shutdown wait ' .. tostring(ok) .. ' ' .. tostring(err))"
      , "  local ok2, err2 = pcall(fixture.data, 'late.bin', nil)"
      , "  fx.record('shutdown start ' .. tostring(ok2) .. ' ' .. tostring(err2))"
      , "end"
      ]

-- | An instance's commands, as a record.
commandSource ∷ EventSource
commandSource =
  EventSource
    "cmd"
    (SRecord [("op", SText), ("key", SOptional SText), ("what", SOptional SText), ("path", SOptional SText), ("offset", SOptional SInteger)])

-- | Start an owner with the rig's bindings on this timing.
startRig ∷ Rig → LuaRuntime → Text → Timing → IO ScheduledOwner
startRig rig runtime label timing = do
  let handleType = admittedHandleType (rgHandles rig) "areq"
      registered =
        either (error . ("registration refused: " <>) . show) id $
          registration [handleType, leaseCapabilityType (rgLeases rig) "texture"] (bindings rig)
      vm =
        (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
          { vmRegistration = registered
          , vmPolicy = ["fx", "request", "fixture"]
          , vmOwnerName = label
          , vmModules = [driverSource, phaserSource]
          , vmValueLimits = either (error . show) id (valueLimits 65536 8 4096)
          }
      grant =
        RequestGrant
          [ fakeEndpoint rig "data" (SRecord [("size", SInteger)])
          , fakeEndpoint rig "texture" (SRecord [("width", SInteger), ("height", SInteger)])
          , fakeEndpoint rig "window" SNil
          , fakeEndpoint rig "text" SText
          , fakeEndpoint rig "ints" (SList SInteger)
          , fakeEndpoint rig "nested" (SList (SList SInteger))
          ]
          64
          (if timing == OnArrival then SettleOnArrival else SettleAtAssignedTick Nothing)
      spec =
        (scheduledSpec vm requiredPolicy bounds)
          { scheduledInstances = Just ((defaultInstanceConfig) {instanceBounds = InstanceBounds 8 16 8 8, instanceSources = [commandSource]})
          , scheduledLending = Just (rgLending rig)
          , scheduledLeases = Just (rgLeases rig)
          , scheduledRequestHandles = Just (rgHandles rig)
          , scheduledRequests = Just grant
          }
  startScheduledOwner runtime spec >>= \case
    ScheduledStarted owner → pure owner
    other → assertFailure ("expected an owner, found " <> take 80 (showStart other))
  where
    bounds =
      SchedulerBounds
        { boundActiveTasks = 16
        , boundQueuedAdmissions = 16
        , boundRetainedResults = 32
        , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
        , boundOutstandingGrants = 4
        , boundControlRequests = 8
        , boundServiceBudget = Nothing
        }
    showStart = \case
      ScheduledUnavailable failure → "unavailable: " <> show failure
      ScheduledRejected → "rejected"
      ScheduledEnded → "ended"
      ScheduledStarted _ → "started"

-- | Admit an instance of the driver under this name and wait until it is active.
admitDriver ∷ Rig → ScheduledOwner → Text → IO ()
admitDriver rig owner name = admitModule rig owner name "driver"

-- | Admit an instance of this module under this name and wait until it is active.
admitModule ∷ Rig → ScheduledOwner → Text → Text → IO ()
admitModule rig owner name moduleName = do
  admitInstance (scheduledEndpoint owner) (InstanceRequest (ModuleRef moduleName "1") EventOnly (Just name) OrdinaryClass ["cmd"]) >>= \case
    InstanceAccepted identity ticket → do
      atomicModifyIORef' (rgIds rig) (\held → (Map.insert name identity held, ()))
      atomicModifyIORef' (rgTickets rig) (\held → (Map.insert name ticket held, ()))
    other → assertFailure ("expected the instance accepted, found " <> take 80 (show other))
  awaitPhase rig owner name Active

-- | Ask the instance of this name to stop, expecting the request accepted.
stopInstance ∷ Rig → ScheduledOwner → Text → IO ()
stopInstance rig owner name = do
  identity ← (Map.! name) <$> readIORef (rgIds rig)
  requestInstanceControl (scheduledEndpoint owner) identity InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → assertFailure ("expected the stop accepted, found " <> take 80 (show other))

-- | Tell the driver of this name to do this with the request it keeps under the key.
command ∷ Rig → ScheduledOwner → Text → Text → Text → IO ()
command rig owner name op key = commandWith rig owner name op key Nothing Nothing

-- | The same, naming what to start and the offset to start it with.
commandWith ∷ Rig → ScheduledOwner → Text → Text → Text → Maybe Text → Maybe Int → IO ()
commandWith rig owner name op key what offset = do
  identity ← (Map.! name) <$> readIORef (rgIds rig)
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key)]
            <> [("what", VText found) | Just found ← [what]]
            <> [("offset", VInteger (fromIntegral found)) | Just found ← [offset]]
  deliverEvent (scheduledEndpoint owner) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → assertFailure ("expected the command accepted, found " <> take 80 (show other))

-- | Grant one logical step and wait for the tick to complete.
grantOne ∷ RuntimeControl → ScheduledOwner → IO ()
grantOne control owner = do
  one ← either (\refused → assertFailure (show refused)) pure (durationFromNanoseconds RequirePositive 1)
  _ ← grantScheduledStep (scheduledEndpoint owner) one
  void (awaitTicksComplete control owner)

-- | The owner's request service, read in one transaction.
diagnostics ∷ ScheduledOwner → IO ProviderDiagnostics
diagnostics owner =
  atomically (requestDiagnostics (scheduledEndpoint owner)) >>= maybe (assertFailure "the owner has no request service") pure

-- | Block, in STM, until the owner's request service reads like this.
awaitDiagnostic ∷ ScheduledOwner → (ProviderDiagnostics → Bool) → IO ()
awaitDiagnostic owner wanted = atomically $ do
  found ← requestDiagnostics (scheduledEndpoint owner)
  case found of
    Just reading | wanted reading → pure ()
    _ → retry

-- | Block until an instance is in this phase.
awaitPhase ∷ Rig → ScheduledOwner → Text → InstancePhase → IO ()
awaitPhase rig owner name wanted = do
  identity ← (Map.! name) <$> readIORef (rgIds rig)
  atomically $
    inspectInstance (scheduledEndpoint owner) identity >>= \case
      Just snapshot | snapshotPhase snapshot == wanted → pure ()
      _ → retry

-- | Wait until a script is inside the call that holds this gate.
awaitGate ∷ Rig → Text → IO ()
awaitGate rig name = gateIn (rgEntered rig) name >>= readMVar

-- | Let the call that holds this gate go on.
openGate ∷ Rig → Text → IO ()
openGate rig name = gateIn (rgGates rig) name >>= void . (`tryPutMVar` ())

-- | Wait for the owner to end, and answer how.
awaitEnd ∷ RuntimeControl → ScheduledOwner → IO WorkerStatus
awaitEnd control owner =
  awaitSupervised control $
    scheduledStatus owner >>= \case
      WorkerLive → retry
      status → pure status

-- | The failure an instance settled with, waiting for it to settle.
awaitFailure ∷ Rig → Text → IO (Maybe InstanceFailure)
awaitFailure rig name = do
  ticket ← (Map.! name) <$> readIORef (rgTickets rig)
  settlement ← waitInstance ticket
  pure $ case resultOutcome settlement of
    InstanceFailed failure → Just failure
    _ → Nothing

-- | The endpoint and attributed text of a required request's failure.
requestFailureOf ∷ Maybe InstanceFailure → Maybe (Text, Text)
requestFailureOf failure = case fmap failureError failure of
  Just (ErrorRequest endpoint why) → Just (endpoint, why)
  _ → Nothing

-- | One instance's leases, in one transaction.
leaseSummary ∷ Rig → Text → IO ScopeSummary
leaseSummary rig name = do
  identity ← (Map.! name) <$> readIORef (rgIds rig)
  atomically (instanceLeases (rgLeases rig) identity)

-- | Block, in STM, until an instance's leases satisfy this.
awaitLeaseSummary ∷ Rig → Text → (ScopeSummary → Bool) → IO ()
awaitLeaseSummary rig name wanted = do
  identity ← (Map.! name) <$> readIORef (rgIds rig)
  atomically $ do
    summary ← instanceLeases (rgLeases rig) identity
    if wanted summary then pure () else retry
