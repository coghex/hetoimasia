-- | The composition the window examples of this package share: a real supervised Lua owner whose instances
-- call the window provider through a binding written the way the engine's graphics facade (LFE-21) will
-- write it, over the real request admission, the real instance leases and the real provider, and the Lua
-- that drives them. The one thing injected is the provider's 'Port': the gated fake in the lifecycle suite,
-- the production host's in the native suite.
--
-- Nothing sleeps. An example knows what has happened by blocking in STM on what a script recorded or on a
-- reading, and the whole example is bounded by the caller.
module Test.LuaEngine.Graphics.Windows
  ( -- * The session
    WinComp (..)
  , withWinComp

    -- * One VM
  , WinVm (..)
  , startWinVm
  , admit
  , stopInstance
  , command
  , commandOpen
  , ownerOf

    -- * What scripts recorded
  , notes
  , awaitNoteContaining
  , awaitPhase
  , awaitFailure
  , instanceFailure
  , awaitLeases
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Monad (unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Typeable (Typeable)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith, unsafeComponent)
import Hetoimasia.LuaEngine.Graphics.Window.Port (Port, WindowToken (..))
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (CopiedValueBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (CopiedValueDepth, CopiedValueElements)
  , Profile
  , bytesLimit
  , countLimit
  , fixedM1Profile
  )
import Hetoimasia.LuaEngine.Request
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  , withSupervision
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (admittedHandleType, newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Leases, ScopeSummary, instanceLeases, leaseCapabilityType, newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.HUnit.Lang (assertFailure)

-- | Everything an example shares.
data WinComp target = WinComp
  { wcProvider ∷ !(WindowProvider target)
  , wcLog ∷ !(TVar [Text])
  , wcIds ∷ !(IORef (Map Text InstanceId))
  , wcTickets ∷ !(IORef (Map Text InstanceTicket))
  }

-- | The profile the compositions run under: the fixed M1 profile.
compositionProfile ∷ Profile
compositionProfile = fixedM1Profile

-- | Run a body over a provider of this port and configuration, real supervision and a Lua runtime.
withWinComp ∷ Typeable target ⇒ WindowConfig → Port target → (WinComp target → RuntimeControl → LuaRuntime → IO a) → IO a
withWinComp config port body =
  withWindowProvider config port $ \provider → do
    comp ← WinComp provider <$> newTVarIO [] <*> newIORef Map.empty <*> newIORef Map.empty
    withLoggingLifetime quietLogger $ \lifetime →
      withSupervision lifetime $ \control → do
        runtime ← newLuaRuntime control
        body comp control runtime

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- One VM ---------------------------------------------------------------------------------------------------

-- | One VM: its owner, its service, its lease scope and the window owners of its instances.
data WinVm target = WinVm
  { vmOwner ∷ ScheduledOwner
  , vmService ∷ !(WindowService target)
  , vmLeases ∷ !Leases
  , vmOwners ∷ !(IORef (Map Text WindowOwner))
  , vmLog ∷ !(TVar [Text])
  }

requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Service Supervision.Required (unsafeComponent "test.luaengine.graphics.window") (\_ → pure Unrecognized)

requestHandleType ∷ Text
requestHandleType = "wreq"

-- | A VM over the composition's provider: its own lease scope and handle registry, one owner settling on
-- arrival.
startWinVm ∷ ∀ target. Typeable target ⇒ WinComp target → LuaRuntime → Text → IO (WinVm target)
startWinVm comp runtime label = do
  handles ← newRequestHandles
  requests ← either (\refused → assertFailure ("the profile was refused: " <> show refused)) pure (m1Requests compositionProfile handles)
  let service = windowService requests (wcProvider comp)
  lending ← newLending
  leases ← newLeases lending 16
  owners ← newIORef Map.empty
  let vm' = WinVm (error "owner not started") service leases owners (wcLog comp)
      registered =
        either (error . ("registration refused: " <>) . show) id $
          registration [admittedHandleType handles requestHandleType, leaseCapabilityType leases windowHandleType] (bindings vm')
      Bytes copied = bytesLimit compositionProfile CopiedValueBytes
      Count depth = countLimit compositionProfile CopiedValueDepth
      Count elements = countLimit compositionProfile CopiedValueElements
      limits = either (error . show) id (valueLimits (fromIntegral copied) (fromIntegral depth) (fromIntegral elements))
      vm =
        (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
          { vmRegistration = registered
          , vmPolicy = ["fx", "request", "win"]
          , vmOwnerName = label
          , vmModules = [driverSource]
          , vmValueLimits = limits
          }
      grant = RequestGrant [windowEndpoint service] 64 SettleOnArrival
      spec =
        (scheduledSpec vm requiredPolicy bounds)
          { scheduledInstances = Just (defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8, instanceSources = [commandSource]})
          , scheduledLending = Just lending
          , scheduledLeases = Just leases
          , scheduledRequestHandles = Just handles
          , scheduledRequests = Just grant
          }
  startScheduledOwner runtime spec >>= \case
    ScheduledStarted owner → pure vm' {vmOwner = owner}
    ScheduledUnavailable failure → assertFailure ("the owner was unavailable: " <> show failure)
    ScheduledRejected → assertFailure "the owner was rejected"
    ScheduledEnded → assertFailure "the owner had ended"
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

-- | The window owner of the instance of this name.
ownerOf ∷ WinVm target → Text → IO WindowOwner
ownerOf vm name = (Map.! name) <$> readIORef (vmOwners vm)

-- | The bindings: @fx.record@, the common request operations, and @win.open(who, title, width, height)@ and
-- @win.use(window)@, written the way the facade will write them from "Hetoimasia.LuaEngine.Graphics.Window.Provider".
-- The @who@ names the window owner: this is the example's own scaffolding, where the facade would hold the
-- instance's owner in its binding. It is not an API of the engine.
bindings ∷ ∀ target. Typeable target ⇒ WinVm target → [Namespace]
bindings vm =
  [ namespace "fx" [recording]
  , namespace "request" (m1RequestBindings (M1Service requestHandleType windowValueSchema))
  , namespace "win" [opening, using]
  ]
  where
    service = vmService vm
    recording =
      stateOperation "record" [SText] [] $ \arguments → do
        case arguments of
          [VText text] → atomically (modifyTVar' (vmLog vm) (text :))
          _ → pure ()
        pure []
    opening =
      withArgumentCheck check $
        asynchronousNativeRequestIn "open" [SText, SText, SInteger, SInteger] (m1StartSchemas requestHandleType) $ \context values → do
          asked ← askFrom values
          case asked of
            Left why → ioError (userError (Text.unpack why))
            Right ask →
              startWindow service ask context >>= \case
                WindowStarted started → pure (m1StartResults requestHandleType started)
                WindowRefused why → pure [VNil, VRecord [("code", VText "refused"), ("message", VText why)]]
    check owner values =
      askFrom values >>= \case
        Left why → pure (Just why)
        Right ask → windowArgumentCheck service (const ask) owner values
    using =
      recoverableRefusals $
        stateOperation "use" [SCapability windowHandleType] [SInteger] $ \arguments → case arguments of
          [VCapability handle] →
            withWindowOr @target (vmLeases vm) (capabilityKey handle) (\why → ioError (userError (Text.unpack why))) $ \resource →
              case resourceToken resource of
                WindowToken number → pure [VInteger (fromIntegral number)]
          _ → pure []
    askFrom ∷ [Value] → IO (Either Text WindowAsk)
    askFrom = \case
      [VText who, VText title, VInteger width, VInteger height] → do
        owners ← readIORef (vmOwners vm)
        pure $ case Map.lookup who owners of
          Nothing → Left ("no window owner named " <> who)
          Just owner → either (Left . refusalText') Right (askWindow owner (Text.encodeUtf8 title) width height)
      _ → pure (Left "a window owner, a title, a width and a height are required")
    refusalText' = Text.pack . show

-- | The Lua the commands run.
driverSource ∷ ModuleSource
driverSource =
  ModuleSource (ModuleRef "driver" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
      [ "local function fmt(v)"
      , "  local t = type(v)"
      , "  if t == 'string' then return v end"
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
      , "local function run(self, p)"
      , "  local key = p.key or 'a'"
      , "  local out = '?'"
      , "  if p.op == 'start' then"
      , "    local r, err = win.open(p.name, p.title or 't', p.width or 640, p.height or 480)"
      , "    if r then self.hs[key] = r out = 'started' else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'pstart' then"
      , "    local ok, r, err = pcall(win.open, p.name, p.title or 't', p.width or 640, p.height or 480)"
      , "    if not ok then out = 'error ' .. tostring(r)"
      , "    elseif r then self.hs[key] = r out = 'started'"
      , "    else out = 'busy:' .. err.code end"
      , "  elseif p.op == 'take' then"
      , "    local r = request.take(self.hs[key])"
      , "    if r.status == 'success' then self.ws[key] = r.value end"
      , "    out = fmt(r)"
      , "  elseif p.op == 'ready' then out = tostring(request.ready(self.hs[key]))"
      , "  elseif p.op == 'wait' then request.wait(self.hs[key]) out = 'waited'"
      , "  elseif p.op == 'cancel' then out = request.cancel(self.hs[key])"
      , "  elseif p.op == 'wait_take' then"
      , "    request.wait(self.hs[key])"
      , "    local r = request.take(self.hs[key])"
      , "    if r.status == 'success' then self.ws[key] = r.value end"
      , "    out = fmt(r)"
      , "  elseif p.op == 'use' then out = tostring(win.use(self.ws[key]))"
      , "  elseif p.op == 'puse' then"
      , "    local ok, r = pcall(win.use, self.ws[key])"
      , "    out = ok and tostring(r) or ('error ' .. tostring(r))"
      , "  end"
      , "  fx.record(p.name .. ' ' .. p.op .. ' ' .. key .. ' ' .. out)"
      , "end"
      , "function init(self, api)"
      , "  self.hs = {}"
      , "  self.ws = {}"
      , "  api.connect('cmd', function(self, event) run(self, event.payload) end)"
      , "end"
      , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
      ]

commandSource ∷ EventSource
commandSource =
  EventSource
    "cmd"
    ( SRecord
        [ ("op", SText)
        , ("key", SOptional SText)
        , ("name", SText)
        , ("title", SOptional SText)
        , ("width", SOptional SInteger)
        , ("height", SOptional SInteger)
        ]
    )

-- | Admit an instance of the driver under this name, with a window owner of that name and role, and wait
-- until it is active.
admit ∷ WinComp target → WinVm target → WindowRole → Text → IO ()
admit comp vm role name = do
  owner ← newWindowOwner (wcProvider comp) role
  atomicModifyIORef' (vmOwners vm) (\held → (Map.insert name owner held, ()))
  admitInstance (scheduledEndpoint (vmOwner vm)) (InstanceRequest (ModuleRef "driver" "1") EventOnly (Just name) OrdinaryClass ["cmd"]) >>= \case
    InstanceAccepted identity ticket → do
      atomicModifyIORef' (wcIds comp) (\held → (Map.insert name identity held, ()))
      atomicModifyIORef' (wcTickets comp) (\held → (Map.insert name ticket held, ()))
    other → assertFailure ("expected the instance accepted, found " <> take 80 (show other))
  awaitPhase comp vm name Active

-- | Ask the instance of this name to stop, expecting the request accepted.
stopInstance ∷ WinComp target → WinVm target → Text → IO ()
stopInstance comp vm name = do
  identity ← (Map.! name) <$> readIORef (wcIds comp)
  requestInstanceControl (scheduledEndpoint (vmOwner vm)) identity InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → assertFailure ("expected the stop accepted, found " <> take 80 (show other))

-- | Tell the instance of this name to do this with the request or window it keeps under the key.
command ∷ WinComp target → WinVm target → Text → Text → Text → IO ()
command comp vm name op key = commandWith comp vm name op key Nothing

-- | The same, opening a window of this title and size.
commandOpen ∷ WinComp target → WinVm target → Text → Text → Text → (Int, Int) → IO ()
commandOpen comp vm name key title size = commandWith comp vm name "start" key (Just (title, size))

commandWith ∷ WinComp target → WinVm target → Text → Text → Text → Maybe (Text, (Int, Int)) → IO ()
commandWith comp vm name op key asked = do
  identity ← (Map.! name) <$> readIORef (wcIds comp)
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key), ("name", VText name)]
            <> concat [[("title", VText title), ("width", VInteger (fromIntegral width)), ("height", VInteger (fromIntegral height))] | Just (title, (width, height)) ← [asked]]
  deliverEvent (scheduledEndpoint (vmOwner vm)) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → assertFailure ("expected the command accepted, found " <> take 80 (show other))

-- What scripts recorded -------------------------------------------------------------------------------------

-- | What the scripts recorded, oldest first.
notes ∷ WinComp target → IO [Text]
notes comp = reverse <$> readTVarIO (wcLog comp)

-- | Block until a script recorded a line containing this text, and answer the first.
awaitNoteContaining ∷ WinComp target → Text → IO Text
awaitNoteContaining comp needle = atomically $ do
  seen ← reverse <$> readTVar (wcLog comp)
  case filter (Text.isInfixOf needle) seen of
    found : _ → pure found
    [] → retry

-- | Block until an instance is in this phase.
awaitPhase ∷ WinComp target → WinVm target → Text → InstancePhase → IO ()
awaitPhase comp vm name wanted = do
  identity ← (Map.! name) <$> readIORef (wcIds comp)
  atomically $
    inspectInstance (scheduledEndpoint (vmOwner vm)) identity >>= \case
      Just snapshot | snapshotPhase snapshot == wanted → pure ()
      _ → retry

-- | Block until an instance's leases satisfy this.
awaitLeases ∷ WinComp target → WinVm target → Text → (ScopeSummary → Bool) → IO ()
awaitLeases comp vm name wanted = do
  identity ← (Map.! name) <$> readIORef (wcIds comp)
  atomically $ do
    summary ← instanceLeases (vmLeases vm) identity
    unless (wanted summary) retry

-- | The failure an instance settled with, if it failed, waiting for it to settle.
awaitFailure ∷ WinComp target → Text → IO (Maybe InstanceFailure)
awaitFailure comp name = do
  ticket ← (Map.! name) <$> readIORef (wcTickets comp)
  settlement ← waitInstance ticket
  pure $ case resultOutcome settlement of
    InstanceFailed failure → Just failure
    _ → Nothing

-- | The endpoint and attributed text of a required request's failure.
instanceFailure ∷ Maybe InstanceFailure → Maybe (Text, Text)
instanceFailure failure = case fmap failureError failure of
  Just (ErrorRequest endpoint why) → Just (endpoint, why)
  _ → Nothing
