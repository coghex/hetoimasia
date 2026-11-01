-- | The composition the examples of this package share: a real content root, inventory, read pool and
-- texture pipeline over the real bounded decoder, a real supervised Lua owner whose instances call the
-- pipeline through bindings written the way the engine's graphics facade (LFE-21) will write them, and the
-- Lua that drives them. The one thing injected is the 'TextureBackend' the pipeline is given: the fake
-- owner's in the lifecycle suite, the production adapter's in the native suite.
--
-- Nothing sleeps. An example knows what has happened by blocking in STM on what a script recorded or on a
-- reading, and the whole example is bounded by the caller.
module Test.LuaEngine.Graphics.Composition
  ( -- * The session
    Composition (..)
  , Files
  , withComposition
  , compositionProfile
  , holdReadsOf
  , releaseReadsOf
  , releaseAllReads
  , readsEntered
  , readsFinished

    -- * One VM
  , Vm (..)
  , startVm
  , admit
  , stopInstance
  , command
  , commandLoad
  , ownerOf

    -- * What scripts recorded
  , notes
  , awaitNote
  , awaitNoteContaining
  , awaitEnd
  , awaitFailure
  , instanceFailure
  , awaitPhase
  , awaitLeases
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (finally)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Content (ContentRoot, defaultContentLimits, withContentRoot)
import Hetoimasia.Content.Inventory
  ( Inventory
  , InventorySpec (..)
  , inventoryLimits
  , readVerified
  , scanInventory
  )
import Hetoimasia.Content.Identity (contentKeyPath, logicalPathBytes, rootKey)
import Hetoimasia.Content.ReadPool (ReadPool, poolSpec, withReadPoolUsing)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith)
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
import Hetoimasia.LuaEngine.Texture
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
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Scripting.Lua.Admission (Necessity (..), admittedHandleType, newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Leases, ScopeSummary, instanceLeases, leaseCapabilityType, newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.HUnit.Lang (assertFailure)

-- | The files to create, relative to the content root.
type Files = [(FilePath, ByteString)]

-- | Everything an example shares.
data Composition = Composition
  { cpTree ∷ !FilePath
  , cpRoot ∷ !ContentRoot
  -- ^ The opened content root the inventory was scanned from: the boot checkpoint reads through it, verified.
  , cpInventory ∷ !Inventory
  , cpPool ∷ !ReadPool
  , cpPipeline ∷ !TexturePipeline
  , cpLog ∷ !(TVar [Text])
  , cpIds ∷ !(IORef (Map Text InstanceId))
  , cpTickets ∷ !(IORef (Map Text InstanceTicket))
  , cpEnteredReads ∷ !(TVar [ByteString])
  -- ^ The paths whose reads have reached the pool's reader, in the order they did (injected evidence: a worker borrowed the read).
  , cpFinishedReads ∷ !(TVar [ByteString])
  -- ^ The paths whose reads have returned from the pool's reader, in the order they did.
  , cpHeldReads ∷ !(TVar (Set ByteString))
  -- ^ The paths whose reads wait at the pool's reader until they are let go (injected evidence: a gated read still opens
  -- and hashes a real file once its gate opens). Empty unless an example holds one.
  }

-- | The profile the compositions run under: the fixed M1 profile.
compositionProfile ∷ Profile
compositionProfile = fixedM1Profile

scanSpec ∷ InventorySpec
scanSpec =
  InventorySpec
    { specEntries = 100
    , specSegments = 8
    , specPathBytes = 200
    , specSegmentBytes = 40
    , specFileBytes = 40 * 1024 * 1024
    , specRootBytes = 128 * 1024 * 1024
    , specBufferBytes = 64 * 1024
    }

-- | Run a body over a composition of these files and this backend: a temporary content root, scanned; the
-- shared read pool; the texture pipeline over the backend; real supervision and a Lua runtime. The backend
-- must outlive the pipeline, so the caller's scope encloses this one.
withComposition ∷ Profile → Files → TextureBackend → (Composition → RuntimeControl → LuaRuntime → IO a) → IO a
withComposition profile files backend body =
  withSystemTempDirectory "hetoimasia-lua-engine-graphics" $ \tree → do
    forM_ files $ \(path, bytes) → do
      createDirectoryIfMissing True (takeDirectory (tree </> path))
      ByteString.writeFile (tree </> path) bytes
    limits ← either (\refused → assertFailure ("scan limits refused: " <> show refused)) pure (inventoryLimits scanSpec)
    root' ← either (\refused → assertFailure ("root key refused: " <> show refused)) pure (rootKey "graphics-test")
    spec ← either (\refused → assertFailure ("texture spec refused: " <> show refused)) pure (textureSpec profile 16)
    pool ← either (\refused → assertFailure ("pool refused: " <> show refused)) pure (uncurry poolSpec (2, 16))
    withContentRoot defaultContentLimits tree $ \root → do
      inventory ← scanInventory limits root' root >>= either (\refused → assertFailure ("scan refused: " <> show refused)) pure
      held ← newTVarIO Set.empty
      entered ← newTVarIO []
      finished ← newTVarIO []
      let gated key allowance = do
            atomically (modifyTVar' entered (<> [logicalPathBytes (contentKeyPath key)]))
            atomically (readTVar held >>= \paths → when (logicalPathBytes (contentKeyPath key) `Set.member` paths) retry)
            readVerified inventory root key allowance
              `finally` atomically (modifyTVar' finished (<> [logicalPathBytes (contentKeyPath key)]))
      withReadPoolUsing pool gated $ \readPool →
        withTexturePipeline spec backend readPool inventory $ \pipeline → do
          composition ← Composition tree root inventory readPool pipeline <$> newTVarIO [] <*> newIORef Map.empty <*> newIORef Map.empty <*> pure entered <*> pure finished <*> pure held
          withLoggingLifetime quietLogger $ \lifetime →
            withSupervision lifetime $ \control → do
              runtime ← newLuaRuntime control
              -- however the body ends, every read it held is let go before the pipeline drains
              body composition control runtime `finally` atomically (writeTVar held Set.empty)

-- | Hold every read of this path at the pool's reader: it starts, and waits there.
holdReadsOf ∷ Composition → ByteString → IO ()
holdReadsOf composition path = atomically (modifyTVar' (cpHeldReads composition) (Set.insert path))

-- | Block until this many reads of this path have reached the pool's reader: a worker has borrowed each (a held one waits there).
readsEntered ∷ Composition → ByteString → Int → IO ()
readsEntered composition path wanted = atomically (readTVar (cpEnteredReads composition) >>= \seen → unless (length (filter (== path) seen) >= wanted) retry)

-- | Block until this many reads of this path have returned from the pool's reader.
readsFinished ∷ Composition → ByteString → Int → IO ()
readsFinished composition path wanted = atomically (readTVar (cpFinishedReads composition) >>= \seen → unless (length (filter (== path) seen) >= wanted) retry)

-- | Let every held read go: what an example's scope does on every way out, so that a failing example never waits on a read it held.
releaseAllReads ∷ Composition → IO ()
releaseAllReads composition = atomically (writeTVar (cpHeldReads composition) Set.empty)

-- | Let the reads of this path go.
releaseReadsOf ∷ Composition → ByteString → IO ()
releaseReadsOf composition path = atomically (modifyTVar' (cpHeldReads composition) (Set.delete path))

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- One VM ---------------------------------------------------------------------------------------------------

-- | One VM: its owner, its service, its lease scope and the texture owners of its instances.
data Vm = Vm
  { vmOwner ∷ ScheduledOwner
  , vmService ∷ !TextureService
  , vmLeases ∷ !Leases
  , vmOwners ∷ !(IORef (Map Text TextureOwner))
  }

requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Service Supervision.Required (unsafeComponent "test.luaengine.graphics") (\_ → pure Unrecognized)

requestHandleType ∷ Text
requestHandleType = "treq"

-- | A VM over the composition's pipeline: its own lease scope and handle registry, one owner settling on
-- arrival.
startVm ∷ Composition → LuaRuntime → Text → IO Vm
startVm composition runtime label = do
  handles ← newRequestHandles
  requests ← either (\refused → assertFailure ("the profile was refused: " <> show refused)) pure (m1Requests compositionProfile handles)
  service ← either (\refused → assertFailure ("the service was refused: " <> show refused)) pure (textureService requests (cpPipeline composition))
  lending ← newLending
  leases ← newLeases lending 16
  owners ← newIORef Map.empty
  let vm' = Vm (error "owner not started") service leases owners
      registered =
        either (error . ("registration refused: " <>) . show) id $
          registration [admittedHandleType handles requestHandleType, leaseCapabilityType leases textureHandleType] (bindings composition vm')
      Bytes copied = bytesLimit compositionProfile CopiedValueBytes
      Count depth = countLimit compositionProfile CopiedValueDepth
      Count elements = countLimit compositionProfile CopiedValueElements
      limits = either (error . show) id (valueLimits (fromIntegral copied) (fromIntegral depth) (fromIntegral elements))
      vm =
        (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
          { vmRegistration = registered
          , vmPolicy = ["fx", "request", "tex"]
          , vmOwnerName = label
          , vmModules = [driverSource]
          , vmValueLimits = limits
          }
      grant = RequestGrant [textureEndpoint service] 64 SettleOnArrival
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

-- | The texture owner of the instance of this name.
ownerOf ∷ Vm → Text → IO TextureOwner
ownerOf vm name = (Map.! name) <$> readIORef (vmOwners vm)

-- | The bindings: @fx.record@, the common request operations, and @tex.load(who, path [, optional])@,
-- @tex.use(texture)@ and @tex.release(texture)@, written the way the facade will write them from
-- "Hetoimasia.LuaEngine.Texture". The @who@ names the texture owner: this is the example's own scaffolding,
-- where the facade would hold the instance's owner in its binding. It is not an API of the engine.
bindings ∷ Composition → Vm → [Namespace]
bindings composition vm =
  [ namespace "fx" [recording]
  , namespace "request" (m1RequestBindings (M1Service requestHandleType textureValueSchema))
  , namespace "tex" [loading, using, releasing]
  ]
  where
    service = vmService vm
    recording =
      stateOperation "record" [SText] [] $ \arguments → do
        case arguments of
          [VText text] → atomically (modifyTVar' (cpLog composition) (text :))
          _ → pure ()
        pure []
    loading =
      withArgumentCheck check $
        asynchronousNativeRequestIn "load" [SText, SText, SOptional SBoolean] (m1StartSchemas requestHandleType) $ \context values → do
          asked ← requestFrom values
          case asked of
            Left why → ioError (userError (Text.unpack why))
            Right request →
              startTexture service request context >>= \case
                TextureStarted started → pure (m1StartResults requestHandleType started)
                TextureRefused why → pure [VNil, VRecord [("code", VText "refused"), ("message", VText why)]]
    check owner values =
      requestFrom values >>= \case
        Left why → pure (Just why)
        Right request → textureArgumentCheck service (const request) owner values
    using =
      recoverableRefusals $
        stateOperation "use" [SCapability textureHandleType] [SInteger] $ \arguments → case arguments of
          [VCapability handle] → do
            view ← withTexture (vmLeases vm) (capabilityKey handle) pure
            pure [VInteger (fromIntegral (viewIdentity view))]
          _ → pure []
    releasing =
      recoverableRefusals . releaseOperation "release" textureHandleType [SText] $ \arguments → case arguments of
        [VCapability handle] → do
          answer ← releaseTexture (vmLeases vm) (capabilityKey handle)
          pure [VText (releaseWord answer)]
        _ → pure []
    requestFrom ∷ [Value] → IO (Either Text TextureRequest)
    requestFrom = \case
      VText who : VText path : rest → do
        owners ← readIORef (vmOwners vm)
        pure $ case Map.lookup who owners of
          Nothing → Left ("no texture owner named " <> who)
          Just owner → case textureKey service (Text.encodeUtf8 path) of
            Left refused → Left ("address refused: " <> Text.pack (show refused))
            Right key →
              Right
                TextureRequest
                  { requestedOwner = owner
                  , requestedKey = key
                  , requestedNecessity = case rest of
                      [VBoolean True] → OptionalRequest
                      _ → RequiredRequest
                  }
      _ → pure (Left "a texture owner and a path are required")

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
      , "    local r, err = tex.load(p.name, p.path or 'a.png', p.optional)"
      , "    if r then self.hs[key] = r out = 'started' else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'take' then"
      , "    local r = request.take(self.hs[key])"
      , "    if r.status == 'success' then self.ts[key] = r.value.texture end"
      , "    out = fmt(r)"
      , "  elseif p.op == 'ptake' then"
      , "    local ok, r = pcall(request.take, self.hs[key])"
      , "    if ok then out = fmt(r) else out = 'error ' .. tostring(r) end"
      , "  elseif p.op == 'cancel' then out = request.cancel(self.hs[key])"
      , "  elseif p.op == 'wait_take' then"
      , "    request.wait(self.hs[key])"
      , "    local r = request.take(self.hs[key])"
      , "    if r.status == 'success' then self.ts[key] = r.value.texture end"
      , "    out = fmt(r)"
      , "  elseif p.op == 'use' then out = tostring(tex.use(self.ts[key]))"
      , "  elseif p.op == 'puse' then"
      , "    local ok, r = pcall(tex.use, self.ts[key])"
      , "    out = ok and tostring(r) or ('error ' .. tostring(r))"
      , "  elseif p.op == 'release' then out = tex.release(self.ts[key])"
      , "  end"
      , "  fx.record(p.name .. ' ' .. p.op .. ' ' .. key .. ' ' .. out)"
      , "end"
      , "function init(self, api)"
      , "  self.hs = {}"
      , "  self.ts = {}"
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
        , ("path", SOptional SText)
        , ("optional", SOptional SBoolean)
        ]
    )

-- | Admit an instance of the driver under this name, with a texture owner of that name, and wait until it
-- is active.
admit ∷ Composition → Vm → Text → IO ()
admit composition vm name = do
  owner ← newTextureOwner (cpPipeline composition) PresentationRole
  atomicModifyIORef' (vmOwners vm) (\held → (Map.insert name owner held, ()))
  admitInstance (scheduledEndpoint (vmOwner vm)) (InstanceRequest (ModuleRef "driver" "1") EventOnly (Just name) OrdinaryClass ["cmd"]) >>= \case
    InstanceAccepted identity ticket → do
      atomicModifyIORef' (cpIds composition) (\held → (Map.insert name identity held, ()))
      atomicModifyIORef' (cpTickets composition) (\held → (Map.insert name ticket held, ()))
    other → assertFailure ("expected the instance accepted, found " <> take 80 (show other))
  awaitPhase composition vm name Active

-- | Ask the instance of this name to stop, expecting the request accepted.
stopInstance ∷ Composition → Vm → Text → IO ()
stopInstance composition vm name = do
  identity ← (Map.! name) <$> readIORef (cpIds composition)
  requestInstanceControl (scheduledEndpoint (vmOwner vm)) identity InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → assertFailure ("expected the stop accepted, found " <> take 80 (show other))

-- | Tell the instance of this name to do this with the request or texture it keeps under the key.
command ∷ Composition → Vm → Text → Text → Text → IO ()
command composition vm name op key = commandWith composition vm name op key Nothing

-- | The same, starting a load of this path, optionally.
commandLoad ∷ Composition → Vm → Text → Text → Text → Bool → IO ()
commandLoad composition vm name key path optional = commandWith composition vm name "start" key (Just (path, optional))

commandWith ∷ Composition → Vm → Text → Text → Text → Maybe (Text, Bool) → IO ()
commandWith composition vm name op key asked = do
  identity ← (Map.! name) <$> readIORef (cpIds composition)
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key), ("name", VText name)]
            <> concat [[("path", VText path)] <> [("optional", VBoolean True) | optional] | Just (path, optional) ← [asked]]
  deliverEvent (scheduledEndpoint (vmOwner vm)) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → assertFailure ("expected the command accepted, found " <> take 80 (show other))

-- What scripts recorded -------------------------------------------------------------------------------------

-- | What the scripts recorded, oldest first.
notes ∷ Composition → IO [Text]
notes composition = reverse <$> readTVarIO (cpLog composition)

-- | Block until a script recorded exactly this line.
awaitNote ∷ Composition → Text → IO ()
awaitNote composition wanted = atomically $ do
  seen ← readTVar (cpLog composition)
  unless (wanted `elem` seen) retry

-- | Block until a script recorded a line containing this text, and answer the first.
awaitNoteContaining ∷ Composition → Text → IO Text
awaitNoteContaining composition needle = atomically $ do
  seen ← reverse <$> readTVar (cpLog composition)
  case filter (Text.isInfixOf needle) seen of
    found : _ → pure found
    [] → retry

-- | Block until an instance is in this phase.
awaitPhase ∷ Composition → Vm → Text → InstancePhase → IO ()
awaitPhase composition vm name wanted = do
  identity ← (Map.! name) <$> readIORef (cpIds composition)
  atomically $
    inspectInstance (scheduledEndpoint (vmOwner vm)) identity >>= \case
      Just snapshot | snapshotPhase snapshot == wanted → pure ()
      _ → retry

-- | Block until an instance's leases satisfy this.
awaitLeases ∷ Composition → Vm → Text → (ScopeSummary → Bool) → IO ()
awaitLeases composition vm name wanted = do
  identity ← (Map.! name) <$> readIORef (cpIds composition)
  atomically $ do
    summary ← instanceLeases (vmLeases vm) identity
    unless (wanted summary) retry

-- | Wait for the owner to end, and answer how.
awaitEnd ∷ RuntimeControl → Vm → IO WorkerStatus
awaitEnd control vm =
  awaitSupervised control $
    scheduledStatus (vmOwner vm) >>= \case
      WorkerLive → retry
      status' → pure status'

-- | The failure an instance settled with, if it failed, waiting for it to settle.
awaitFailure ∷ Composition → Text → IO (Maybe InstanceFailure)
awaitFailure composition name = do
  ticket ← (Map.! name) <$> readIORef (cpTickets composition)
  settlement ← waitInstance ticket
  pure $ case resultOutcome settlement of
    InstanceFailed failure → Just failure
    _ → Nothing

-- | The endpoint and attributed text of a required request's failure.
instanceFailure ∷ Maybe InstanceFailure → Maybe (Text, Text)
instanceFailure failure = case fmap failureError failure of
  Just (ErrorRequest endpoint why) → Just (endpoint, why)
  _ → Nothing
