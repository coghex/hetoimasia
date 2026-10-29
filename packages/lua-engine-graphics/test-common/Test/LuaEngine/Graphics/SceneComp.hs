-- | The composition the scene publication examples share: a real supervised Lua owner whose instances load
-- textures, open windows, publish scenes and release textures through bindings written the way the engine's graphics
-- facade (LFE-21) will write them, over the real request admission, the real instance leases, the real texture
-- pipeline and the real window provider, and the Lua that drives them.
--
-- The scene publication binding is the library's ('graphicsPublishBindingWith'), installed here under a name of this
-- suite's own: LFE-21 installs the facade's @api.scene.publish@ later, and nothing here pretends to be it. What is
-- injected is the texture backend and the window port (the fake owner's and fake windows in the lifecycle suite, the
-- production host's in the native suite) and the host's answer to a publication.
--
-- Nothing sleeps. An example knows what has happened by blocking in STM on what a script recorded, on a gate the
-- script is held at, or on a reading, and the whole example is bounded by the caller.
module Test.LuaEngine.Graphics.SceneComp
  ( -- * The session
    SceneKit (..)
  , SceneComp (..)
  , withSceneComp

    -- * One VM
  , SceneVm (..)
  , startSceneVm
  , admitScene
  , stopScene
  , command
  , ownersOf
  , publisherOf

    -- * Gates inside a running invocation
  , armGate
  , awaitGate
  , openGate
  , openAllGates

    -- * What scripts recorded
  , sceneNotes
  , awaitSceneNote
  , awaitSceneNoteCount
  , mainStepNow
  , awaitSceneFailure
  , awaitSceneLeases
  , awaitScenePhase
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Monad (unless, when)
import Data.Functor ((<&>))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Typeable (Typeable)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.LuaEngine.Graphics.Scene
  ( GraphicsScene
  , HostAnswer
  , PublishHooks (..)
  , PublishResult (..)
  , ScenePublisher
  , graphicsPublishBindingWith
  , publishRefusalText
  , publishScene
  , scenePublisherOver
  )
import Hetoimasia.LuaEngine.Graphics.Window.Port (Port)
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (CopiedValueBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (CopiedValueDepth, CopiedValueElements)
  , bytesLimit
  , countLimit
  )
import Hetoimasia.LuaEngine.Request
import Hetoimasia.LuaEngine.Scene (SceneLimits, prepareScene, sceneLimits, sceneSchema)
import Hetoimasia.LuaEngine.Texture hiding (PresentationRole)
import qualified Hetoimasia.LuaEngine.Texture as Tex (TextureRole (PresentationRole))
import Hetoimasia.Render.TwoD.Vulkan.Textures (Textures)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (Necessity (..), admittedHandleType, newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Leases, ScopeSummary, instanceLeases, leaseCapabilityType, newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.HUnit.Lang (assertFailure)
import Test.LuaEngine.Graphics.Composition (Composition (..), Files, awaitFailure, compositionProfile, withComposition)

-- | What an example injects: the window port with the capability type it yields, the registry the publisher
-- reads, and what the host answers a publication and says of a window's usability.
data SceneKit target = SceneKit
  { kitPort ∷ !(Port target)
  , kitTextures ∷ !Textures
  , kitPublish ∷ target → Prepared GraphicsScene → IO HostAnswer
  , kitUsable ∷ target → STM Bool
  }

-- | Everything an example shares: the texture composition and the window provider.
data SceneComp target = SceneComp
  { scTexture ∷ !Composition
  , scProvider ∷ !(WindowProvider target)
  , scKit ∷ !(SceneKit target)
  }

-- | Run a body over a window provider of this kit, inside a texture composition of these files and this backend.
withSceneComp
  ∷ Typeable target
  ⇒ SceneKit target
  → WindowConfig
  → Files
  → TextureBackend
  → (SceneComp target → RuntimeControl → LuaRuntime → IO a)
  → IO a
withSceneComp kit config files backend body =
  withComposition compositionProfile files backend $ \composition control runtime →
    withWindowProvider config (kitPort kit) $ \provider →
      body (SceneComp composition provider kit) control runtime

-- | One VM: its owner, its services, its lease scope, and the owners of its instances.
data SceneVm target = SceneVm
  { vmOwner ∷ ScheduledOwner
  , vmTexture ∷ !TextureService
  , vmWindow ∷ !(WindowService target)
  , vmLeases ∷ !Leases
  , vmTextureOwners ∷ !(IORef (Map Text TextureOwner))
  , vmWindowOwners ∷ !(IORef (Map Text WindowOwner))
  , vmGates ∷ !(TVar Gates)
  , vmPublisher ∷ !(ScenePublisher target)
  }

data Gates = Gates
  { gatesArmed ∷ ![Text]
  , gatesEntered ∷ ![Text]
  , gatesOpened ∷ ![Text]
  , gatesAll ∷ !Bool
  }

requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Service Supervision.Required (unsafeComponent "test.luaengine.graphics.scene") (\_ → pure Unrecognized)

textureRequests, windowRequests ∷ Text
textureRequests = "treq"
windowRequests = "wreq"

-- | The window owners and texture owners of the instances, by name.
ownersOf ∷ SceneVm target → Text → IO (TextureOwner, WindowOwner)
ownersOf vm name = (,) <$> ((Map.! name) <$> readIORef (vmTextureOwners vm)) <*> ((Map.! name) <$> readIORef (vmWindowOwners vm))

publisherOf ∷ SceneVm target → ScenePublisher target
publisherOf = vmPublisher

-- | A VM over the composition: its own lease scope and handle registry, one owner settling on arrival.
startSceneVm ∷ ∀ target. Typeable target ⇒ SceneComp target → LuaRuntime → Text → IO (SceneVm target)
startSceneVm comp runtime label = do
  handles ← newRequestHandles
  requests ← either (\refused → assertFailure ("the profile was refused: " <> show refused)) pure (m1Requests compositionProfile handles)
  textureService' ← either (\refused → assertFailure ("the texture service was refused: " <> show refused)) pure (textureService requests (cpPipeline (scTexture comp)))
  let windowService' = windowService requests (scProvider comp)
  limits' ← either (\refused → assertFailure ("the scene limits were refused: " <> show refused)) pure (sceneLimits compositionProfile)
  lending ← newLending
  leases ← newLeases lending 16
  textureOwners ← newIORef Map.empty
  windowOwners ← newIORef Map.empty
  gates ← newTVarIO (Gates [] [] [] False)
  let kit = scKit comp
      publisher = scenePublisherOver (kitTextures kit) (scProvider comp) (kitPublish kit) (kitUsable kit)
      vm' = SceneVm (error "owner not started") textureService' windowService' leases textureOwners windowOwners gates publisher
      registered =
        either (error . ("registration refused: " <>) . show) id $
          registration
            [ admittedHandleType handles textureRequests
            , admittedHandleType handles windowRequests
            , leaseCapabilityType leases textureHandleType
            , leaseCapabilityType leases windowHandleType
            ]
            (bindings comp limits' vm')
      Bytes copied = bytesLimit compositionProfile CopiedValueBytes
      Count depth = countLimit compositionProfile CopiedValueDepth
      Count elements = countLimit compositionProfile CopiedValueElements
      valueLimits' = either (error . show) id (valueLimits (fromIntegral copied) (fromIntegral depth) (fromIntegral elements))
      vm =
        (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
          { vmRegistration = registered
          , vmPolicy = ["fx", "trq", "wrq", "tex", "win", "scn"]
          , vmOwnerName = label
          , vmModules = [driverSource]
          , vmValueLimits = valueLimits'
          }
      grant = RequestGrant [textureEndpoint textureService', windowEndpoint windowService'] 64 SettleOnArrival
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

-- | The bindings: @fx.record@ and @fx.block@, the two services' request operations, @tex.load@, @tex.release@,
-- @win.open@, and the library's scene publication as @scn.publish@. The @who@ names the instance's owners: this is
-- the example's own scaffolding, where the facade would hold the instance's owners in its bindings.
bindings ∷ ∀ target. Typeable target ⇒ SceneComp target → SceneLimits → SceneVm target → [Namespace]
bindings comp limits vm =
  [ namespace "fx" [recording, blocking]
  , namespace "trq" (m1RequestBindings (M1Service textureRequests textureValueSchema))
  , namespace "wrq" (m1RequestBindings (M1Service windowRequests windowValueSchema))
  , namespace "tex" [loading, releasing]
  , namespace "win" [opening]
  , namespace "scn" [graphicsPublishBindingWith (hooksOf vm) "publish" (\_ _ → pure Nothing) (vmPublisher vm) limits (vmLeases vm), fullScene, raced]
  ]
  where
    log' = cpLog (scTexture comp)
    recording =
      stateOperation "record" [SText] [] $ \arguments → do
        case arguments of
          [VText text] → atomically (modifyTVar' log' (text :))
          _ → pure ()
        pure []
    blocking =
      stateOperation "block" [SText] [] $ \arguments → do
        case arguments of
          [VText name] → do
            atomically (modifyTVar' (vmGates vm) (\held → held {gatesEntered = name : gatesEntered held}))
            atomically $ do
              held ← readTVar (vmGates vm)
              unless (gatesAll held || name `elem` gatesOpened held) retry
          _ → pure ()
        pure []
    loading =
      withArgumentCheck checkLoad $
        asynchronousNativeRequestIn "load" [SText, SText] (m1StartSchemas textureRequests) $ \context values → do
          asked ← loadFrom values
          case asked of
            Left why → ioError (userError (Text.unpack why))
            Right request →
              startTexture (vmTexture vm) request context >>= \case
                TextureStarted started → pure (m1StartResults textureRequests started)
                TextureRefused why → pure [VNil, VRecord [("code", VText "refused"), ("message", VText why)]]
    checkLoad owner values =
      loadFrom values >>= \case
        Left why → pure (Just why)
        Right request → textureArgumentCheck (vmTexture vm) (const request) owner values
    releasing =
      recoverableRefusals . releaseOperation "release" textureHandleType [SText] $ \arguments → case arguments of
        [VCapability handle] → do
          answer ← releaseTexture (vmLeases vm) (capabilityKey handle)
          pure [VText (releaseWord answer)]
        _ → pure []
    opening =
      withArgumentCheck checkOpen $
        asynchronousNativeRequestIn "open" [SText, SText, SInteger, SInteger] (m1StartSchemas windowRequests) $ \context values → do
          asked ← openFrom values
          case asked of
            Left why → ioError (userError (Text.unpack why))
            Right ask →
              startWindow (vmWindow vm) ask context >>= \case
                WindowStarted started → pure (m1StartResults windowRequests started)
                WindowRefused why → pure [VNil, VRecord [("code", VText "refused"), ("message", VText why)]]
    checkOpen owner values =
      openFrom values >>= \case
        Left why → pure (Just why)
        Right ask → windowArgumentCheck (vmWindow vm) (const ask) owner values
    -- The largest legal scene, 4,096 sprites of one texture, built in Haskell and prepared by the scene package's own
    -- check, then published through the library's operation. The host's copied-value reader counts one value more
    -- than the scene limits' element bound allows for 4,096 sprites, so the Lua binding takes at most 4,095 (the
    -- finding is reported in the pull request); this binding bypasses only that reader's count.
    fullScene =
      stateOperation "publish_full" [SCapability windowHandleType, SCapability textureHandleType] [] $ \arguments → case arguments of
        [VCapability window, texture] → do
          let sprite index = VRecord [("texture", texture), ("x", VInteger (index `mod` 64)), ("y", VInteger (index `div` 64)), ("width", VInteger 1), ("height", VInteger 1)]
              value = VRecord [("clear", VRecord [("r", VInteger 0), ("g", VInteger 0), ("b", VInteger 0)]), ("sprites", VList (map sprite [0 .. 4095]))]
          prepareScene limits (vmLeases vm) value >>= \case
            Left refusal → ioError (userError (show refusal))
            Right prepared →
              publishScene (vmPublisher vm) (capabilityKey window) prepared >>= \case
                Published → pure []
                Refused refusal → ioError (userError (Text.unpack (publishRefusalText refusal)))
        _ → pure []
    -- A release that lands between the scene's preparation and the publication boundary, on the instance's own thread
    -- where a script's next statement could not: the preparation succeeds, the texture is released, and the
    -- operation is asked to publish the stale preparation. The answer is the operation's, as text.
    raced =
      stateOperation "publish_raced" [SCapability windowHandleType, sceneSchema, SCapability textureHandleType] [SText] $ \arguments → case arguments of
        [VCapability window, scene, VCapability texture] →
          prepareScene limits (vmLeases vm) scene >>= \case
            Left refusal → ioError (userError (show refusal))
            Right prepared → do
              _ ← releaseTexture (vmLeases vm) (capabilityKey texture)
              publishScene (vmPublisher vm) (capabilityKey window) prepared <&> \case
                Published → [VText "published"]
                Refused refusal → [VText ("refused: " <> publishRefusalText refusal)]
        _ → pure []
    loadFrom ∷ [Value] → IO (Either Text TextureRequest)
    loadFrom = \case
      [VText who, VText path] → do
        owners ← readIORef (vmTextureOwners vm)
        pure $ case Map.lookup who owners of
          Nothing → Left ("no texture owner named " <> who)
          Just owner → case textureKey (vmTexture vm) (Text.encodeUtf8 path) of
            Left refused → Left ("address refused: " <> Text.pack (show refused))
            Right key → Right (TextureRequest owner key RequiredRequest)
      _ → pure (Left "a texture owner and a path are required")
    openFrom ∷ [Value] → IO (Either Text WindowAsk)
    openFrom = \case
      [VText who, VText title, VInteger width, VInteger height] → do
        owners ← readIORef (vmWindowOwners vm)
        pure $ case Map.lookup who owners of
          Nothing → Left ("no window owner named " <> who)
          Just owner → either (Left . Text.pack . show) Right (askWindow owner (Text.encodeUtf8 title) width height)
      _ → pure (Left "a window owner, a title, a width and a height are required")

-- | The publication's seams, each a gate the example arms: an armed gate holds the script's invocation inside the
-- publication until the example lets it go, with the rest of the system free to move meanwhile.
hooksOf ∷ SceneVm target → PublishHooks
hooksOf vm = PublishHooks (gate "before-boundary") (gate "before-commit") (gate "after-commit")
  where
    gate name = do
      armed ← (name `elem`) . gatesArmed <$> readTVarIO (vmGates vm)
      when armed $ do
        atomically (modifyTVar' (vmGates vm) (\held → held {gatesEntered = name : gatesEntered held}))
        atomically $ do
          held ← readTVar (vmGates vm)
          unless (gatesAll held || name `elem` gatesOpened held) retry

-- | The Lua the commands run. A scene is described by the texture keys its sprites use, comma separated:
-- @"a,b,a"@ is three sprites, the first and third of texture @a@.
driverSource ∷ ModuleSource
driverSource =
  ModuleSource (ModuleRef "driver" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
      [ "local shared = {}"
      , "local function fmt(v)"
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
      , "local function scene(self, p, textures)"
      , "  local sprites = {}"
      , "  for name in string.gmatch(p.spec or '', '[^,]+') do"
      , "    sprites[#sprites + 1] = {texture = textures[name], x = #sprites * 4, y = 0, width = 4, height = 4}"
      , "  end"
      , "  return {clear = {r = p.clear or 0, g = 0, b = 0}, sprites = sprites}"
      , "end"
      , "local function run(self, p)"
      , "  local key = p.key or 'a'"
      , "  local out = '?'"
      , "  if p.op == 'load' then"
      , "    local r, err = tex.load(p.name, p.spec or 'a.png')"
      , "    if r then trq.wait(r) local t = trq.take(r) if t.status == 'success' then self.ts[key] = t.value.texture out = 'loaded' else out = fmt(t) end"
      , "    else out = 'busy:' .. err.code end"
      , "  elseif p.op == 'open' then"
      , "    local r, err = win.open(p.name, 't', 64, 48)"
      , "    if r then wrq.wait(r) local t = wrq.take(r) if t.status == 'success' then self.ws[key] = t.value out = 'opened' else out = fmt(t) end"
      , "    else out = 'busy:' .. err.code end"
      , "  elseif p.op == 'release' then out = tex.release(self.ts[key])"
      , "  elseif p.op == 'publish' then scn.publish(self.ws[key], scene(self, p, self.ts)) out = 'published'"
      , "  elseif p.op == 'ppublish' then"
      , "    local ok, err = pcall(scn.publish, self.ws[key], scene(self, p, self.ts))"
      , "    out = ok and 'published' or ('error ' .. tostring(err))"
      , "  elseif p.op == 'pbad' then"
      , "    local s = scene(self, {spec = 'a'}, self.ts)"
      , "    if p.spec == 'extra' then s.extra = 1"
      , "    elseif p.spec == 'hole' then s.sprites[2] = nil s.sprites[3] = s.sprites[1]"
      , "    elseif p.spec == 'many' then for i = 1, 4097 do s.sprites[i] = {texture = self.ts.a, x = 0, y = 0, width = 1, height = 1} end"
      , "    elseif p.spec == 'meta' then setmetatable(s, {})"
      , "    elseif p.spec == 'nan' then s.sprites[1].x = 0/0 end"
      , "    local ok, err = pcall(scn.publish, self.ws[key], s)"
      , "    out = ok and 'published' or ('error ' .. tostring(err))"
      , "  elseif p.op == 'publish_full' then scn.publish_full(self.ws[key], self.ts.a) out = 'published'"
      , "  elseif p.op == 'praced' then"
      , "    out = scn.publish_raced(self.ws[key], scene(self, p, self.ts), self.ts.a)"
      , "  elseif p.op == 'mutate' then"
      , "    local s = scene(self, p, self.ts)"
      , "    scn.publish(self.ws[key], s)"
      , "    s.sprites[1].x = 99 s.sprites[1].width = 1 s.clear.r = 200 s.sprites[#s.sprites + 1] = s.sprites[1]"
      , "    out = 'published then mutated'"
      , "  elseif p.op == 'share' then shared.t = self.ts[key] shared.w = self.ws[key] out = 'shared'"
      , "  elseif p.op == 'pforeign_texture' then"
      , "    local ok, err = pcall(scn.publish, self.ws[key], {clear = {r = 0, g = 0, b = 0}, sprites = {{texture = shared.t, x = 0, y = 0, width = 4, height = 4}}})"
      , "    out = ok and 'published' or ('error ' .. tostring(err))"
      , "  elseif p.op == 'pforeign_window' then"
      , "    local ok, err = pcall(scn.publish, shared.w, scene(self, p, self.ts))"
      , "    out = ok and 'published' or ('error ' .. tostring(err))"
      , "  end"
      , "  fx.record(p.name .. ' ' .. p.op .. ' ' .. key .. ' ' .. out)"
      , "end"
      , "function init(self, api)"
      , "  self.ts = {}"
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
        , ("path", SOptional SText)
        , ("spec", SOptional SText)
        , ("clear", SOptional SInteger)
        ]
    )

-- | Admit an instance of the driver under this name, with texture and window owners of that name (a presentation
-- instance's), and wait until it is active.
admitScene ∷ ∀ target. SceneComp target → SceneVm target → Text → IO ()
admitScene comp vm name = do
  textureOwner ← newTextureOwner (cpPipeline (scTexture comp)) Tex.PresentationRole
  windowOwner ← newWindowOwner (scProvider comp) PresentationRole
  atomicModifyIORef' (vmTextureOwners vm) (\held → (Map.insert name textureOwner held, ()))
  atomicModifyIORef' (vmWindowOwners vm) (\held → (Map.insert name windowOwner held, ()))
  admitInstance (scheduledEndpoint (vmOwner vm)) (InstanceRequest (ModuleRef "driver" "1") EventOnly (Just name) OrdinaryClass ["cmd"]) >>= \case
    InstanceAccepted identity ticket → do
      atomicModifyIORef' (cpIds (scTexture comp)) (\held → (Map.insert name identity held, ()))
      atomicModifyIORef' (cpTickets (scTexture comp)) (\held → (Map.insert name ticket held, ()))
    other → assertFailure ("expected the instance accepted, found " <> take 80 (show other))
  awaitScenePhase comp vm name Active

-- | Ask the instance of this name to stop.
stopScene ∷ SceneComp target → SceneVm target → Text → IO ()
stopScene comp vm name = do
  identity ← (Map.! name) <$> readIORef (cpIds (scTexture comp))
  requestInstanceControl (scheduledEndpoint (vmOwner vm)) identity InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → assertFailure ("expected the stop accepted, found " <> take 80 (show other))

-- | Tell the instance of this name to do this with the texture or window it keeps under the key.
command ∷ SceneComp target → SceneVm target → Text → Text → Text → Maybe Text → IO ()
command comp vm name op key spec = do
  identity ← (Map.! name) <$> readIORef (cpIds (scTexture comp))
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key), ("name", VText name)]
            <> [("spec", VText described) | Just described ← [spec]]
  deliverEvent (scheduledEndpoint (vmOwner vm)) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → assertFailure ("expected the command accepted, found " <> take 80 (show other))

-- | Arm this gate: the next publication holds there.
armGate ∷ SceneVm target → Text → IO ()
armGate vm name = atomically (modifyTVar' (vmGates vm) (\held → held {gatesArmed = name : gatesArmed held}))

-- | Block until a script is inside the publication at this gate (@before-boundary@, @before-commit@, @after-commit@).
awaitGate ∷ SceneVm target → Text → IO ()
awaitGate vm name = atomically (readTVar (vmGates vm) >>= \held → unless (name `elem` gatesEntered held) retry)

-- | Let the publication held at this gate go on.
openGate ∷ SceneVm target → Text → IO ()
openGate vm name = atomically (modifyTVar' (vmGates vm) (\held → held {gatesOpened = name : gatesOpened held}))

-- | Let every gate go, now and for good.
openAllGates ∷ SceneVm target → IO ()
openAllGates vm = atomically (modifyTVar' (vmGates vm) (\held → held {gatesAll = True}))

-- | What the scripts recorded, oldest first.
sceneNotes ∷ SceneComp target → IO [Text]
sceneNotes comp = reverse <$> readTVarIO (cpLog (scTexture comp))

-- | Block until a script recorded a line containing this text, and answer the first.
awaitSceneNote ∷ SceneComp target → Text → IO Text
awaitSceneNote comp needle = atomically $ do
  seen ← reverse <$> readTVar (cpLog (scTexture comp))
  case filter (Text.isInfixOf needle) seen of
    found : _ → pure found
    [] → retry

-- | Block until scripts recorded this many lines containing this text.
awaitSceneNoteCount ∷ SceneComp target → Text → Int → IO ()
awaitSceneNoteCount comp needle wanted = atomically $ do
  seen ← readTVar (cpLog (scTexture comp))
  unless (length (filter (Text.isInfixOf needle) seen) >= wanted) retry

-- | Wait until the provider has main-thread work (a window to hand over), then do it: the owner loop's turn.
mainStepNow ∷ SceneComp target → IO ()
mainStepNow comp = do
  atomically (windowMainReady (scProvider comp) >>= \ready → unless ready retry)
  windowMainStep (scProvider comp)

-- | The failure an instance settled with, if it failed, waiting for it to settle.
awaitSceneFailure ∷ SceneComp target → Text → IO (Maybe InstanceFailure)
awaitSceneFailure comp = awaitFailure (scTexture comp)

-- | Block until an instance is in this phase.
awaitScenePhase ∷ SceneComp target → SceneVm target → Text → InstancePhase → IO ()
awaitScenePhase comp vm name wanted = do
  identity ← (Map.! name) <$> readIORef (cpIds (scTexture comp))
  atomically $
    inspectInstance (scheduledEndpoint (vmOwner vm)) identity >>= \case
      Just snapshot | snapshotPhase snapshot == wanted → pure ()
      _ → retry

-- | Block until an instance's leases satisfy this.
awaitSceneLeases ∷ SceneComp target → SceneVm target → Text → (ScopeSummary → Bool) → IO ()
awaitSceneLeases comp vm name wanted = do
  identity ← (Map.! name) <$> readIORef (cpIds (scTexture comp))
  atomically $ do
    summary ← instanceLeases (vmLeases vm) identity
    unless (wanted summary) retry
