{-# LANGUAGE OverloadedStrings #-}

-- | Terrain views on a real device (TRA-9): the production graphics owner, scene barrier and ledger, the production
-- terrain-view adapter over the real terrain service, the real texture pipeline and instance leases, recorded into a
-- surface-free target (LFE-27) with its own @D32_SFLOAT@ depth image. The display target is the one substitution: the
-- host adopts, holds and retires exactly as it does for a window, and the frames are recorded only through the host's
-- recording boundary ('recordVulkanTargetBatch') with the production world recording ('renderWorldTarget').
--
-- = Judgement
--
-- Every pixel is judged by the independent 2D oracle given #659's pure model of the terrain material
-- ('terrainModel') and the decoded parents, never by the production picker or renderer: a determinate pixel must pass,
-- and enough pixels must be determinate for the judgement to speak. A pick is checked against the same oracle: where
-- the oracle shows only the clear colour, nothing selectable can be under the pixel.
--
-- = Profiles
--
-- 'spec' is the bounded required witness, part of the complete profile and of @--match 'terrain views'@. 'fullSpec' is
-- the broader matrix that @--terrain-views-full@ runs alone: every facing, both zoom endpoints the band allows and a
-- portrait resize, each judged the same way.
module Test.LuaEngine.Graphics.Native.TerrainViews (spec, fullSpec) where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forM, forM_, unless, void)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as BC
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , ImageDescription (..)
  , ImageFormat (Depth32Float, Rgba8Srgb)
  , ImageKind (ColorTarget, DepthTarget)
  , OffscreenTargetId
  , Refusal (..)
  , ResourceUse (..)
  , SceneTargetKey (..)
  , TicketState (..)
  , TransitionSource (..)
  , VulkanAction (..)
  , VulkanHost (..)
  , VulkanSceneState (..)
  , WindowSceneStanding (..)
  , awaitVulkanAction
  , constructImage
  , constructReadback
  , copyTargetToReadback
  , formatCode
  , readConstructedReadback
  , readTicket
  , readVulkanSceneState
  , recordVulkanTargetBatch
  , registerVulkanSceneTarget
  , releaseConstructed
  , submitVulkanAction
  , transitionResource
  , unregisterVulkanSceneTarget
  )
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.TerrainView
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..), textureHandleOf)
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBuilders)
import Hetoimasia.LuaEngine.Texture (RenderAccount)
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (..)
  , Bytes (..)
  , Count (..)
  , CountLimit (..)
  , Profile
  , ProfileSpec (..)
  , fixedM1Profile
  , profileSpec
  , validateProfile
  )
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Oracle (OracleInput (..), Probe (..), TargetSpec (..), Verdict (..), judgeReadback, newOracleWith)
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (R8G8B8A8Srgb))
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (..), Pass (..), Snapshot (..), Target (OffscreenTarget), View (..))
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (validateSnapshotWith)
import Hetoimasia.Render.TwoD.Vulkan.Chunks (RetainedView (..), retainedChunks, retainedViewSTM)
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMarks)
import Hetoimasia.Terrain.Coordinate (axisFromInteger, tileCoord)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle, findSampleDirectory, loadAtlasStyle)
import qualified Hetoimasia.Terrain.Render2D.AtlasFixtures as Fixtures
import qualified Hetoimasia.Terrain.Render2D.Camera as Camera
import Hetoimasia.Terrain.Render2D.Cells (CellConfig (..), defaultCellConfig)
import Hetoimasia.Terrain.Render2D.Material (terrainModel)
import Hetoimasia.Terrain.Render2D.Presentation (defaultLightInput)
import qualified Hetoimasia.Terrain.Runtime as Runtime
import Hetoimasia.Terrain.Runtime.Storage (filesystemOf, minHeadroomBytes, mkStorageConfig)
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), defaultStoreSpec, minAllowanceBytes)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
import Numeric.Natural (Natural)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.HUnit.Lang (assertFailure)
import Test.LuaEngine.Graphics.Composition
import Test.LuaEngine.Graphics.Native.Session (Env (..))
import Test.LuaEngine.Graphics.Native.Spec (within)

-- | The required witness.
spec ∷ Env → Spec
spec env = describe "terrain views" $
  it "draws the adopted world into a surface-free target with its depth image, keeps drawing it across the Lua handles' release and an edit, and hands back a real empty revision" $
    within 60 . withRig env $ \rig → do
      view ← attach rig (metricsOf 128 96)
      first' ← awaitAdopted rig 1
      a ← renderJudged rig
      worldTag (rwWorld a) `shouldBe` WorldTag (viewIncarnation view) 1
      chunksA ← pure (worldChunks (rwWorld a))
      -- The original handles go; the view keeps drawing under its own interests.
      command (rgComp rig) (rgVm rig) "i" "release" "colour"
      command (rgComp rig) (rgVm rig) "i" "release" "normal"
      _ ← awaitNoteContaining (rgComp rig) "i release normal"
      -- An edit is prepared, published and adopted as B; A's regions that B does not list retire after A's batches.
      removeAt rig (8, 8, 3)
      _ ← awaitAdopted rig (first' + 1)
      b ← renderJudged rig
      rwRevision b `shouldSatisfy` (> rwRevision a)
      let gone = chunksA `Set.difference` worldChunks (rwWorld b)
      within 20 . atomically' $ do
        live ← liveChunksSTM rig
        unless (Set.null (gone `Set.intersection` live)) retry
      -- The close hands back a real empty revision, which the host adopts.
      handback ← publishedOf rig
      closeView view
      _ ← awaitAdopted rig (handback + 1)
      latest ← adoptedScene rig
      fmap graphicsWorld latest `shouldBe` Just Nothing
      atomically (claimOf (scenesClaims (envScenes env)) (KeyOffscreen (rgTarget rig))) `shouldReturn` Nothing

-- | The broader matrix, run alone by @--terrain-views-full@.
fullSpec ∷ Env → Spec
fullSpec env = describe "terrain views (full)" $ do
  forM_ [FaceSouth, FaceWest, FaceNorth, FaceEast] $ \facing →
    it ("draws every facing exactly: " <> show facing) $
      within 60 . withRig env $ \rig → do
        view ← attach rig (metricsOf 128 96)
        n ← awaitAdopted rig 1
        atomically (updateCamera view (CameraIntent [Camera.SetFacing facing])) `shouldReturn` Right ()
        _ ← awaitAdopted rig (n + 1)
        void (renderJudged rig)
        closeView view
  forM_ [0.5, 2] $ \zoom →
    it ("draws a zoom exactly: " <> show zoom) $
      within 60 . withRig env $ \rig → do
        view ← attach rig (metricsOf 128 96)
        n ← awaitAdopted rig 1
        atomically (updateCamera view (CameraIntent [Camera.SetZoom zoom])) `shouldReturn` Right ()
        _ ← awaitAdopted rig (n + 1)
        void (renderJudged rig)
        closeView view
  it "draws a portrait target exactly, and a pick over the clear background finds nothing" $
    within 60 . withRig env $ \rig → do
      view ← attach rig (metricsOf 64 128)
      _ ← awaitAdopted rig 1
      rendered ← renderJudged rig
      forM_ (rwClear rendered) $ \(x, y) →
        atomically (pickView view (fromIntegral x + 0.5, fromIntegral y + 0.5)) >>= (`shouldSatisfy` (/= PickLoading)) >> pure ()
      clearPicks ← forM (take 64 (rwClear rendered)) $ \(x, y) → atomically (pickView view (fromIntegral x + 0.5, fromIntegral y + 0.5))
      [p | p@(PickHit _) ← clearPicks] `shouldBe` []
      closeView view

-- ---------------------------------------------------------------------------
-- The rig

data Rig = Rig
  { rgEnv ∷ !Env
  , rgComp ∷ !Composition
  , rgVm ∷ !Vm
  , rgTarget ∷ !OffscreenTargetId
  , rgViews ∷ !(TerrainViews SceneTargetKey)
  , rgTerrain ∷ !Runtime.Service
  , rgArena ∷ !Runtime.ArenaLease
  , rgStyle ∷ !AtlasStyle
  , rgKeys ∷ !(Word64, Word64)
    -- ^ The colour and normal parents' lease keys in the instance's scope.
  , rgIdentities ∷ !(Word64, Word64)
    -- ^ Their registrations' complete identities, which the oracle's decoded images are named by.
  , rgMetrics ∷ !(TVar TargetMetrics)
  }

withRig ∷ Env → (Rig → IO a) → IO a
withRig env body = do
  style ← loadAtlasStyle 5 [("loam", "colour.loam"), ("granite", "colour.granite")]
  sample ← findSampleDirectory
  let atlas = sample </> "content" </> "textures" </> "terrain-atlas"
  colourBytes ← ByteString.readFile (atlas </> "colour.png")
  normalBytes ← ByteString.readFile (atlas </> "normal.png")
  let host = envHost env
      graphics = envGraphics env
  target ← atomically (registerVulkanSceneTarget host) >>= either (\refusal → assertFailure ("the target was refused: " <> show refusal)) pure
  metrics ← newTVarIO (metricsOf 128 96)
  flip finally (void (atomically (unregisterVulkanSceneTarget host target))) $
    withComposition terrainProfile [("colour.png", colourBytes), ("normal.png", normalBytes)] (graphicsBackend graphics) $ \comp _ runtime → do
      vm ← startVm comp runtime "terrain-native-vm"
      admit comp vm "i"
      loadParent comp vm "colour" ["coverage"]
      loadParent comp vm "normal" ["data", "coverage", "normal"]
      colourKey ← leaseKey comp vm "colour"
      normalKey ← leaseKey comp vm "normal"
      colourIdentity ← identityOf comp vm "colour"
      normalIdentity ← identityOf comp vm "normal"
      withTerrain (cpAccount comp) $ \terrain client arena → do
        ports ← productionPorts host graphics (envScenes env) terrain client (cpAccount comp) (pure True)
        withTerrainViews config ports $ \views →
          body (Rig env comp vm target views terrain arena style (colourKey, normalKey) (colourIdentity, normalIdentity) metrics)
  where
    config = defaultTerrainViewsConfig {tvCellConfig = defaultCellConfig {ccDepth = 30}}

metricsOf ∷ Int → Int → TargetMetrics
metricsOf w h = TargetMetrics (PixelExtent w h) (PixelExtent w h) 1 1

attach ∷ Rig → TargetMetrics → IO (TerrainView SceneTargetKey)
attach rig metrics = do
  atomically (writeTVar (rgMetrics rig) metrics)
  let host = envHost (rgEnv rig)
      viewTarget = offscreenViewTarget host (rgTarget rig) (isJust <$> standingOf rig) True (Just <$> readTVar (rgMetrics rig))
      (colourKey, normalKey) = rgKeys rig
      axis = either (error . show) id . axisFromInteger
      request =
        AttachRequest
          { attachTarget = viewTarget
          , attachStyle =
              StyleRequest
                { styleLeases = vmLeases (rgVm rig)
                , styleColourLease = colourKey
                , styleNormalLease = normalKey
                , styleManifest = Fixtures.styleManifest (rgStyle rig)
                , styleMaterials = Fixtures.styleMaterialIds (rgStyle rig)
                , styleInstanceTextureBytes = 2500000
                }
          , attachArena = rgArena rig
          , attachAnchor = (axis 8, axis 8, axis 3)
          , attachLight = defaultLightInput
          }
  attaching ← inInstance (rgComp rig) (rgVm rig) "i" (attachView (rgViews rig) request) >>= either (\why → assertFailure ("refused: " <> show why)) pure
  awaitAttach attaching >>= \case
    SettledOk view → pure view
    other → assertFailure ("the attachment did not succeed: " <> show (() <$ settledText other))
  where
    settledText = \case
      SettledRefused why → Just why
      _ → Nothing

standingOf ∷ Rig → STM (Maybe WindowSceneStanding)
standingOf rig = Map.lookup (KeyOffscreen (rgTarget rig)) . sceneWindows <$> readVulkanSceneState (envHost (rgEnv rig))

publishedOf ∷ Rig → IO Natural
publishedOf rig = atomically (maybe 0 (maybe 0 id . windowPublished) <$> standingOf rig)

-- | Wait until the host has adopted at least this revision for the target, and answer the revision it adopted.
awaitAdopted ∷ Rig → Natural → IO Natural
awaitAdopted rig at = within 30 . atomically $
  standingOf rig >>= \case
    Just standing | Just adopted ← windowAdopted standing, adopted >= at → pure adopted
    _ → retry

adoptedScene ∷ Rig → IO (Maybe GraphicsScene)
adoptedScene rig = within 10 $ do
  found ← newIORef Nothing
  _ ← act (envHost (rgEnv rig)) $ VulkanAction $ \construction →
    recordVulkanTargetBatch (envHost (rgEnv rig)) (rgTarget rig) construction (\scene _ _ → writeIORef found (Just scene) >> pure ()) >>= \case
      Left refusal → pure (Left (RefusedIllegal (Text.pack (show refusal))))
      Right _ → pure (Right ())
  readIORef found

-- | The chunks the session's registry holds now.
liveChunksSTM ∷ Rig → STM (Set.Set ChunkRef)
liveChunksSTM rig = Set.fromList . Map.keys . viewStandings <$> retainedViewSTM (graphicsRetained (envGraphics (rgEnv rig)))

atomically' ∷ STM a → IO a
atomically' = atomically

removeAt ∷ Rig → (Integer, Integer, Integer) → IO ()
removeAt rig (x, y, z) = do
  at ← either (assertFailure . show) pure (tileCoord x y z)
  removal ← Runtime.removeAt (rgTerrain rig) (rgArena rig) at Nothing >>= either (assertFailure . show) pure
  void (Runtime.await (rgTerrain rig) removal)

-- ---------------------------------------------------------------------------
-- Rendering and judging

data RenderedWorld = RenderedWorld
  { rwRevision ∷ !Natural
  , rwWorld ∷ !SceneWorld
  , rwClear ∷ ![(Int, Int)]
    -- ^ The pixels the oracle determined show only the clear colour.
  }

-- | Record the adopted world into a fresh colour target and depth image through the host's recording boundary, wait for
-- the batch's own completion, read the colour back and judge every pixel with the independent oracle.
renderJudged ∷ Rig → IO RenderedWorld
renderJudged rig = do
  let env = rgEnv rig
      host = envHost env
      graphics = envGraphics env
  metrics ← readTVarIO (rgMetrics rig)
  let PixelExtent width height = metricsFramebuffer metrics
      bytesWanted = fromIntegral width * fromIntegral height * 4 ∷ Natural
  session ← readRenderSlot (scenesSlot (envScenes env)) >>= maybe (assertFailure "no render session") pure
  made ← act host $ VulkanAction $ \construction → do
    image ← constructImage construction (ImageDescription ColorTarget Rgba8Srgb (fromIntegral width) (fromIntegral height) 1)
    depth ← constructImage construction (ImageDescription DepthTarget Depth32Float (fromIntegral width) (fromIntegral height) 1)
    readback ← constructReadback construction bytesWanted
    pure ((,,) <$> image <*> depth <*> readback)
  (image, depth, readback) ← either (assertFailure . Text.unpack) pure made
  flip finally (void (act host (VulkanAction (\construction → mapM_ (releaseConstructed construction) [image, depth] >> releaseConstructed construction readback >> pure (Right ()))))) $ do
    recorded ← newIORef Nothing
    ticket ← act host $ VulkanAction $ \construction →
      recordVulkanTargetBatch host (rgTarget rig) construction (\scene revision recorder → do
        case graphicsWorld scene of
          Nothing → pure (Left "the adopted scene holds no world")
          Just world → do
            writeIORef recorded (Just (revision, world))
            renderWorldTarget session (hostBuilders host construction) world metrics image (formatCode Rgba8Srgb) depth recorder >>= \case
              Left refusal → pure (Left (Text.pack (show refusal)))
              Right () →
                inOrder
                  [ transitionResource recorder image (FromUse ColorAttachment) TransferRead
                  , copyTargetToReadback recorder image readback
                  ]
                  >>= \case
                    Left refusal → pure (Left (Text.pack (show refusal)))
                    Right () → pure (Right ()))
        >>= \case
          Left refusal → pure (Left (RefusedIllegal (Text.pack (show refusal))))
          Right (batch, Left failure) → pure (Right (batch, Just failure))
          Right (batch, Right ()) → pure (Right (batch, Nothing))
    (batch, failure) ← either (assertFailure . Text.unpack) pure ticket
    completion ← atomically (readTicket batch >>= \state → if state == TicketPending then retry else pure state)
    forM_ failure (assertFailure . Text.unpack)
    completion `shouldBe` TicketComplete
    bytes ← act host (VulkanAction (\construction → readConstructedReadback construction readback 0 bytesWanted)) >>= either (assertFailure . Text.unpack) pure
    (revision, world) ← readIORef recorded >>= maybe (assertFailure "nothing was recorded") pure
    -- The independent judgement: the oracle, given the terrain material's pure model and the decoded parents.
    chunks ← retainedChunks (graphicsRetained graphics)
    marks ← registeredMarks (graphicsTextures graphics)
    let reference = targetRef 1 1
        snapshot = Snapshot [Pass (OffscreenTarget reference) (worldClear world) [worldView world]]
    valid ← either (\why → assertFailure ("the world does not validate: " <> show why)) pure (validateSnapshotWith chunks snapshot)
    let (colourIdentity, normalIdentity) = rgIdentities rig
        decoded = Map.fromList [(textureHandleOf colourIdentity, Fixtures.styleColourImage (rgStyle rig)), (textureHandleOf normalIdentity, Fixtures.styleNormalImage (rgStyle rig))]
        oracle =
          newOracleWith
            (Map.fromList [(material, terrainModel) | material ← Map.keys (viewMaterials (worldView world))])
            OracleInput
              { inputSnapshot = valid
              , inputCutoutMarks = marks
              , inputWindow = Nothing
              , inputOffscreen = Map.singleton reference (TargetSpec metrics R8G8B8A8Srgb (PixelExtent width height))
              , inputTextures = (`Map.lookup` decoded)
              }
        verdicts = [((x, y), judgeReadback oracle (Probe 0 x y) bytes) | y ← [0 .. height - 1], x ← [0 .. width - 1]]
        failed = [(p, v) | (p, v@(OutOfTolerance _)) ← verdicts]
        passedPixels = [p | (p, Passed) ← verdicts]
        ClearColour cr cg cb ca = worldClear world
        clearBytes = map (\c → round (c * 255) ∷ Int) [cr, cg, cb, ca]
        pixelBytes (x, y) = [fromIntegral (ByteString.index bytes ((y * width + x) * 4 + k)) | k ← [0 .. 3]]
        clear = [p | p ← passedPixels, pixelBytes p == clearBytes]
    take 4 failed `shouldBe` []
    length passedPixels `shouldSatisfy` (> (width * height) `div` 2)
    -- the world is drawn: some judged pixel shows terrain, not the clear colour
    length clear `shouldSatisfy` (< length passedPixels)
    pure (RenderedWorld revision world clear)

inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))

act ∷ VulkanHost GraphicsScene → VulkanAction (Either Refusal a) → IO (Either Text a)
act host action =
  atomically (submitVulkanAction host action) >>= \case
    Left refusal → pure (Left ("refused: " <> Text.pack (show refusal)))
    Right ticket →
      atomically (awaitVulkanAction ticket) >>= \case
        ActionReturned (Right value) → pure (Right value)
        ActionReturned (Left refusal) → pure (Left (Text.pack (show refusal)))
        _ → pure (Left "the action raised or was refused")

-- ---------------------------------------------------------------------------
-- The parents and the terrain

loadParent ∷ Composition → Vm → Text → [Text] → IO ()
loadParent comp vm key policy = do
  commandLoadPolicy comp vm "i" key (key <> ".png") False policy
  command comp vm "i" "wait_take" key
  taken ← awaitNoteContaining comp ("i wait_take " <> key <> " ")
  taken `shouldSatisfy` Text.isInfixOf "status=success"

identityOf ∷ Composition → Vm → Text → IO Word64
identityOf comp vm key = do
  command comp vm "i" "use" key
  line ← awaitNoteContaining comp ("i use " <> key <> " ")
  pure (read (Text.unpack (last (Text.words line))))

leaseKey ∷ Composition → Vm → Text → IO Word64
leaseKey comp vm key = do
  command comp vm "i" "lease" key
  line ← awaitNoteContaining comp ("i lease " <> key <> " ")
  pure (read (Text.unpack (last (Text.words line))))

terrainProfile ∷ Profile
terrainProfile = case validateProfile changed of
  Right profile → profile
  Left refused → error ("the terrain profile is refused: " <> show refused)
  where
    base = profileSpec fixedM1Profile
    counts = [(PngPixels, 294912), (PngAxisMaximum, 768)]
    bytesChanged =
      [ (PngEncodedBytes, 1048576)
      , (PngInflatedScanlineBytes, 2097152)
      , (PngPipelineWorkspaceBytes, 8388608)
      , (TextureBytesPerUiInstance, 2500000)
      , (TextureBytesPerSession, 5000000)
      ]
    changed =
      base
        { specCounts = \limit → maybe (specCounts base limit) Count (lookup limit counts)
        , specBytes = \limit → maybe (specBytes base limit) Bytes (lookup limit bytesChanged)
        }

withTerrain ∷ RenderAccount → (Runtime.Service → Runtime.Client → Runtime.ArenaLease → IO a) → IO a
withTerrain account body =
  withSystemTempDirectory "hetoimasia-terrain-views-native" $ \dir → do
    let directory = BC.pack dir
    name ← filesystemOf directory >>= either (\f → fail ("cannot name the test filesystem: " <> show f)) pure
    storage ← either (fail . show) pure (mkStorageConfig [name] minHeadroomBytes)
    withWorkerGroup $ \group → do
      let config =
            Runtime.defaultConfig
              { Runtime.configStore = defaultStoreSpec {specAllowanceBytes = toInteger minAllowanceBytes}
              , Runtime.configStagingAccount = Just (renderStagingAccount account)
              }
      Runtime.withTerrainService config (Runtime.Ports Runtime.alwaysAdmitting (Runtime.standaloneSupervisor group) quiet Runtime.noProbe (Runtime.storagePort group storage directory)) $ \terrain → do
        client ← Runtime.registerClient terrain >>= either (fail . show) pure
        arena ← Runtime.openArena terrain client "views" loamOverGranite >>= either (fail . show) pure >>= Runtime.await terrain >>= either (fail . show) pure
        body terrain client arena

loamOverGranite ∷ SourceSpec
loamOverGranite =
  SourceSpec
    { specMaterials = ["loam", "granite"]
    , specLayers =
        [ LayerSpec {layerMin = Nothing, layerMax = Just (-3), layerMaterial = "granite", layerShape = 0}
        , LayerSpec {layerMin = Just (-3), layerMax = Just 4, layerMaterial = "loam", layerShape = 0}
        ]
    , specPatches = []
    }

quiet ∷ Logger
quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))
