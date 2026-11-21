-- | Terrain views (TRA-9) on a real device: a view of a real terrain service's arena, styled by the two atlas parents
-- loaded through the texture pipeline, built, published, drawn and retired by the production graphics owner.
--
-- * 'spec' (the @terrain views@ subgroup of every run) opens no window: the view publishes to a surface-free target,
--   which the example draws through the production world recording with a @D32_SFLOAT@ depth image and reads back;
--   an edit is drawn again, and the close hands a real empty revision back and retires every chunk.
-- * 'fullSpec' (@--terrain-views-full@, a session whose windows carry the world depth image) draws a view in a real
--   window: its receipt advances at the presentation's enqueue, through a set of camera changes, and the greatest
--   owner-thread planning time within one frame is recorded against the frame budget.
module Test.LuaEngine.Graphics.Native.TerrainViews (spec, fullSpec) where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forM_, unless, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as Text
import Data.Word (Word64)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec hiding (before)

import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , Image
  , ImageDescription (..)
  , ImageFormat (Depth32Float, Rgba8Srgb)
  , ImageKind (ColorTarget, DepthTarget)
  , OffscreenTargetId
  , Readback
  , ResourceUse (..)
  , SceneTargetKey (..)
  , TicketState (..)
  , TransitionSource (..)
  , VulkanAction (..)
  , VulkanHost (..)
  , VulkanSceneState (..)
  , WindowScenePublication (..)
  , WindowSceneStanding (..)
  , awaitVulkanAction
  , constructImage
  , constructReadback
  , copyTargetToReadback
  , formatCode
  , readConstructedReadback
  , readTicket
  , readVulkanSceneState
  , registerVulkanSceneTarget
  , releaseConstructed
  , submitVulkanAction
  , transitionResource
  , unregisterVulkanSceneTarget
  )
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.TerrainView hiding (styleAssets)
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Graphics.Window.Host (WindowTarget (..))
import Hetoimasia.LuaEngine.Graphics.Window.Port (Port (..), WindowToken (..))
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowRole (PresentationRole))
import Hetoimasia.LuaEngine.Texture (newRenderAccount)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..))
import Hetoimasia.Render.TwoD.Oracle.Readback (readPixel)
import Hetoimasia.Terrain.Coordinate (AxisCoord, axisFromInteger, tileCoord)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), boundPackedTextures, findSampleDirectory, loadAtlasStyle)
import Hetoimasia.Terrain.Render2D.Presentation (defaultLightSettings)
import Hetoimasia.Terrain.Residency (Limits, LimitsSpec (..), mkLimits)
import Data.Maybe (fromMaybe)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Terrain.Cell (mkMaterialId)
import Hetoimasia.Terrain.Render2D.Camera (camZoom)
import Hetoimasia.Terrain.Runtime hiding (closeView, openView)
import Hetoimasia.Terrain.Runtime.Storage (filesystemOf, minHeadroomBytes, mkStorageConfig)
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), defaultStoreSpec, minAllowanceBytes)
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
import Test.LuaEngine.Graphics.Composition (Composition, Files, Vm)
import qualified Test.LuaEngine.Graphics.Composition as Comp
import Test.LuaEngine.Graphics.Native.Session
import Test.LuaEngine.Graphics.Native.Spec (withLoaded)
import Test.LuaEngine.Graphics.Native.Windows (withWindows)
import qualified Test.LuaEngine.Graphics.Windows as Win

-- ---------------------------------------------------------------------------
-- The surface-free target

spec ∷ Env → Spec
spec env = describe "terrain views" $
  it "publishes a real arena's coherent revision to a surface-free target, draws it through the production world recording, draws an edit, and retires every chunk after the close's handback" $ do
    files ← atlasFiles
    within 180 . withLoaded env files $ \comp vm → withViews env comp vm $ \views terrain lease style → do
      let host = envHost env
          metrics = TargetMetrics (PixelExtent side side) (PixelExtent side side) 1 1
      target ← atomically (registerVulkanSceneTarget host) >>= either (\refusal → assertFailure ("the target was refused: " <> show refusal)) pure
      usable ← newTVarIO True
      let cleanup = atomically (writeTVar usable False) >> void (atomically (unregisterVulkanSceneTarget host target))
      flip finally cleanup . withImages host (fromIntegral side) $ \images → do
        view ←
          openView views (OpenRequest (offscreenViewTarget host target (readTVar usable) (pure (Just metrics))) lease (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
            >>= either (\why → assertFailure ("the view was refused: " <> show why)) pure
        first ← drawPublished env view target metrics images 1
        coloured (fromIntegral side) first `shouldSatisfy` (> 0)
        -- an edit reaches the idle view through its arena's mark, and the next revision is drawn
        removal ← removeAt terrain lease (either (error . show) id (tileCoord 1 1 1)) Nothing >>= either (\why → assertFailure ("the removal was refused: " <> show why)) pure
        _ ← await terrain removal
        second ← drawPublished env view target metrics images 2
        second `shouldNotBe` first
        -- the close hands a real empty revision back; every chunk retires behind it
        _ ← closeView view
        atomically $ do
          reading ← readTerrainViews views
          check (serviceRetiring reading == 0 && servicePrivate reading == 0 && Map.null (serviceOccupied reading))
        atomically (claimOf (scenesClaims (envScenes env)) (KeyOffscreen target)) >>= (`shouldBe` Nothing)
        atomically (serviceFailures <$> readTerrainViews views) >>= (`shouldBe` [])
        evidence env ("terrain views, surface-free target: a published revision drawn through the production world recording (" <> tshow (coloured (fromIntegral side) first) <> " terrain pixels of " <> tshow (side * side) <> "), an edit drawn again, the close handed back a real empty revision and every chunk retired")
  where
    side = 160

data Images = Images
  { imagesColour ∷ !Image
  , imagesDepth ∷ !Image
  , imagesReadback ∷ !Readback
  , imagesBytes ∷ !Int
  }

withImages ∷ VulkanHost GraphicsScene → Int → (Images → IO a) → IO a
withImages host side body = do
  let bytes = side * side * 4
  made ← act host "making the target's images" $ VulkanAction $ \construction → do
    colour ← constructImage construction (ImageDescription ColorTarget Rgba8Srgb (fromIntegral side) (fromIntegral side) 1)
    depth ← constructImage construction (ImageDescription DepthTarget Depth32Float (fromIntegral side) (fromIntegral side) 1)
    readback ← constructReadback construction (fromIntegral bytes)
    pure ((,,) <$> colour <*> depth <*> readback)
  (colour, depth, readback) ← either (assertFailure . Text.unpack) pure made
  body (Images colour depth readback bytes) `finally` void (act host "releasing the target's images" (VulkanAction (\construction → releaseConstructed construction colour >> releaseConstructed construction depth >> releaseConstructed construction readback)))

-- Wait until the view has published this revision and the target adopted its latest scene, then draw it and read it
-- back. The receipt must name what was drawn.
drawPublished ∷ Env → TerrainView SceneTargetKey → OffscreenTargetId → TargetMetrics → Images → Word64 → IO ByteString
drawPublished env view target metrics images revision = do
  let host = envHost env
  atomically (readView view >>= \reading → check (maybe False (>= revision) (readingPublished reading)))
  atomically $ do
    state ← readVulkanSceneState host
    case Map.lookup (KeyOffscreen target) (sceneWindows state) of
      Just standing | windowAdopted standing == windowPublished standing, windowAdopted standing /= Nothing → pure ()
      _ → retry
  drawn ←
    drawOffscreenView host (envGraphics env) (scenesReceipts (envScenes env)) target metrics (imagesColour images) (formatCode Rgba8Srgb) (imagesDepth images) $ \recorder →
      transitionResource recorder (imagesColour images) (FromUse ColorAttachment) TransferRead >>= \case
        Left refusal → pure (Left refusal)
        Right () →
          copyTargetToReadback recorder (imagesColour images) (imagesReadback images) >>= \case
            Left refusal → pure (Left refusal)
            Right () → transitionResource recorder (imagesColour images) (FromUse TransferRead) ColorAttachment
  (ticket, tag) ← either (\why → assertFailure ("the drawing failed: " <> Text.unpack why)) pure drawn
  completed ← atomically (readTicket ticket >>= \case TicketPending → retry; TicketComplete → pure True; _ → pure False)
  unless completed (assertFailure "the drawing's batch did not complete")
  receipt ← atomically (viewDrawn view) >>= maybe (assertFailure "the receipt did not advance") pure
  drawnTag (drawnPlanReceipt receipt) `shouldBe` tag
  readback ← act host "reading the readback" (VulkanAction (\construction → readConstructedReadback construction (imagesReadback images) 0 (fromIntegral (imagesBytes images))))
  either (assertFailure . Text.unpack) pure readback

-- Pixels that are not the clear colour (opaque black).
coloured ∷ Int → ByteString → Int
coloured side bytes =
  length
    [ ()
    | y ← [0 .. side - 1]
    , x ← [0 .. side - 1]
    , Right (Rgba8 r g b _) ← [readPixel R8G8B8A8Srgb (PixelExtent (fromIntegral side) (fromIntegral side)) bytes x y]
    , (r, g, b) /= (0, 0, 0)
    ]

-- ---------------------------------------------------------------------------
-- The window

fullSpec ∷ Env → Spec
fullSpec env = describe "terrain views (full)" $ do
  it "keeps a window's M1 scene when a view attaches with no kept metrics and its first candidate is refused" $ do
    files ← atlasFiles
    -- a profile of one region: the first candidate's footprint is refused
    let narrow = defaultTerrainViewsConfig {tvProfile = defaultViewProfile {profileRegions = 1}}
    within 300 . withLoaded env files $ \comp vm → withViewsAt narrow env comp vm $ \views _ lease style →
      withWindows env Nothing $ \wcomp wvm _ _ port _ → do
        window ← openWindow wcomp wvm port
        noteWindows env 1
        let receipts = scenesReceipts (envScenes env)
        -- the window shows an M1 scene, drawn
        m1 ← prepare initialGraphicsScene
        shown ←
          targetPublish window m1 >>= \case
            WindowScenePublished _ revision → pure revision
            other → assertFailure ("the M1 scene was not published: " <> show other)
        _ ← within 60 (atomically (latestFrameMetrics receipts (targetAttachment window) >>= maybe retry pure))
        -- the view's metrics come from receipts that keep nothing of the window (its entry evicted): only the live
        -- geometry gives them, with no other frame and no metrics written by the example
        evicted ← newDrawReceipts
        view ←
          openView views (OpenRequest (windowViewTarget (envHost env) True evicted (pure True) window) lease (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
            >>= either (\why → assertFailure ("the view was refused: " <> show why)) pure
        refusal ← within 60 (atomically (readView view >>= maybe retry pure . readingRefusal))
        refusal `shouldSatisfy` \case
          LimitRegions _ 1 → True
          _ → False
        state ← atomically (readVulkanSceneState (envHost env))
        fmap windowPublished (Map.lookup (KeyWindow (targetWindow window)) (sceneWindows state)) `shouldBe` Just (Just shown)
        closeView view `shouldReturn` CloseDone
        state' ← atomically (readVulkanSceneState (envHost env))
        fmap windowPublished (Map.lookup (KeyWindow (targetWindow window)) (sceneWindows state')) `shouldBe` Just (Just shown)
        Win.stopInstance wcomp wvm "w"

  it "draws a view in a real window, advances its receipt at the presentation's enqueue through camera changes, and records the owner-thread planning time within one frame against the frame budget" $ do
    files ← atlasFiles
    within 300 . withLoaded env files $ \comp vm → withViews env comp vm $ \views _ lease style →
      withWindows env Nothing $ \wcomp wvm _ _ port _ → do
        window ← openWindow wcomp wvm port
        noteWindows env 1
        let receipts = scenesReceipts (envScenes env)
        -- opened directly on the fresh window: the open asks it for the first frame its view plans for
        view ←
          openView views (OpenRequest (windowViewTarget (envHost env) True receipts (pure True) window) lease (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
            >>= either (\why → assertFailure ("the view was refused: " <> show why)) pure
        let drawnAt revision = waitFor ("a receipt of revision " <> show revision) $ do
              reading ← readView view
              case readingDrawn reading of
                Just drawn | tagRevision (drawnTag drawn) >= revision → pure drawn
                _ → retry
            waitFor what condition =
              timeout 60000000 (atomically condition) >>= \case
                Just value → pure value
                Nothing → do
                  readings ← atomically (viewReadings views)
                  service ← atomically (readTerrainViews views)
                  frames ← atomically (latestFrameMetrics receipts (targetAttachment window))
                  assertFailure ("waited a minute for " <> what <> ": views " <> show readings <> ", occupied " <> show (Map.toList (serviceOccupied service)) <> ", failures " <> show (serviceFailures service) <> ", frame metrics " <> show frames)
        firstDrawn ← drawnAt 1
        let changes = [noConfigure {configureZoom = Just 0.5}, noConfigure {configureZoom = Just 2}, noConfigure {configureZoom = Just 1}]
        -- each change is drawn: a new revision presented, its pinned camera at the requested zoom
        forM_ changes $ \change → do
          before ← atomically (readingPublished <$> readView view)
          atomically (configureView view change) >>= either (\why → assertFailure ("the change was refused: " <> show why)) pure
          published ← fmap (fromMaybe (Left Nothing)) . timeout 60000000 . atomically $ do
            reading ← readView view
            case (readingRefusal reading, readingPublished reading) of
              (Just limit, _) → pure (Left (Just limit))
              (_, Just revision) | Just revision > before → pure (Right revision)
              _ → retry
          revision ← either (\limit → assertFailure ("the change was not published: " <> maybe "waited a minute" show limit)) pure published
          drawn ← drawnAt revision
          tagRevision (drawnTag drawn) `shouldSatisfy` (>= revision)
          plan ← atomically (viewDrawn view) >>= maybe (assertFailure "the receipt vanished") pure
          fmap camZoom (drawnPlanCamera plan) `shouldBe` configureZoom change
        reading ← atomically (readTerrainViews views)
        let planning = servicePlanningMax reading
            stepPlanning = servicePlanningStepMax reading
            owned = serviceOwnerMax reading
            ownedStep = serviceOwnerStepMax reading
        _ ← closeView view
        Win.stopInstance wcomp wvm "w"
        evidence env
          ( "terrain views, real window: drawn at the presentation's enqueue (first receipt " <> tshow (drawnTag firstDrawn) <> " at "
              <> tshow (drawnMetrics firstDrawn) <> "), then through zoom 0.5, 2 and 1; greatest owner-thread planning time within one frame "
              <> tshow planning <> " ns between two presentations, and in one owner step (one round of the owner, which a frame follows) "
              <> tshow stepPlanning <> " ns; the views' whole work on the owner's thread (planning, camera, builds, publication, retirement) "
              <> tshow owned <> " ns between two presentations and " <> tshow ownedStep <> " ns in one owner step; against the frame budget of "
              <> tshow frameBudget <> " ns (one 60 Hz refresh)"
              <> (if ownedStep <= frameBudget then "" else "; ONE OWNER STEP EXCEEDS THE FRAME BUDGET")
              <> (if owned <= frameBudget then "" else "; THE OWNER'S WORK BETWEEN TWO PRESENTATIONS EXCEEDS THE FRAME BUDGET")
          )

-- One 60 Hz refresh, in nanoseconds: the budget a frame of the owner has.
frameBudget ∷ Word64
frameBudget = 16666667

openWindow ∷ Win.WinComp (WindowTarget GraphicsScene) → Win.WinVm (WindowTarget GraphicsScene) → Port (WindowTarget GraphicsScene) → IO (WindowTarget GraphicsScene)
openWindow wcomp wvm port = do
  Win.admit wcomp wvm PresentationRole "w"
  Win.commandOpen wcomp wvm "w" "a" "terrain view" (480, 320)
  Win.command wcomp wvm "w" "wait_take" "a"
  opened ← Win.awaitNoteContaining wcomp "w wait_take a"
  opened `shouldSatisfy` Text.isInfixOf "status=success"
  Win.command wcomp wvm "w" "use" "a"
  line ← Win.awaitNoteContaining wcomp "w use a"
  token ← either (\_ → assertFailure ("no window identity in " <> Text.unpack line)) (pure . fst) (Text.decimal (last (Text.words line)))
  atomically (portTarget port (WindowToken token)) >>= maybe (assertFailure "the window offered no target") pure

-- ---------------------------------------------------------------------------
-- The composition

-- A terrain service over a temporary directory, an arena of loam over granite, the two atlas parents loaded through the
-- pipeline, and the views over the production ports.
withViews ∷ Env → Composition → Vm → (TerrainViews SceneTargetKey → Service → ArenaLease → ViewStyle → IO a) → IO a
withViews = withViewsAt defaultTerrainViewsConfig

withViewsAt ∷ TerrainViewsConfig → Env → Composition → Vm → (TerrainViews SceneTargetKey → Service → ArenaLease → ViewStyle → IO a) → IO a
withViewsAt viewsConfig env comp vm body =
  withSystemTempDirectory "hetoimasia-native-terrain-views" $ \dir → do
    let directory = BC.pack dir
        quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))
    name ← filesystemOf directory >>= either (\f → assertFailure ("cannot name the test filesystem: " <> show f)) pure
    storage ← either (assertFailure . show) pure (mkStorageConfig [name] minHeadroomBytes)
    atlas ← loadAtlasStyle 7 [("loam", "colour.loam"), ("granite", "colour.granite")]
    Comp.admit comp vm "a"
    colour ← loadOn comp vm "c" "colour.png" []
    normal ← loadOn comp vm "n" "normal.png" ["data"]
    textures ← boundPackedTextures atlas (textureHandleOf (fromIntegral colour)) (textureHandleOf (fromIntegral normal))
    let style =
          ViewStyle
            { styleSnapshot = styleAssets atlas
            , styleBound = textures
            , styleParents = Set.fromList [fromIntegral colour, fromIntegral normal]
            , styleMapped = Set.fromList [either (error . show) id (mkMaterialId material) | material ← ["loam", "granite"]]
            , styleLive = pure True
            , styleRelease = pure ()
            }
        config = defaultConfig {configStore = defaultStoreSpec {specAllowanceBytes = toInteger minAllowanceBytes}, configLimits = cameraLimits}
    withWorkerGroup $ \group →
      withTerrainService config (Ports alwaysAdmitting (standaloneSupervisor group) quiet noProbe (storagePort group storage directory)) $ \terrain → do
        client ← registerClient terrain >>= either (assertFailure . show) pure
        lease ← openArena terrain client "main" source >>= either (assertFailure . show) pure >>= await terrain >>= either (assertFailure . show) pure
        account ← newRenderAccount (128 * 1024 * 1024)
        ports ← productionPorts (envHost env) (envGraphics env) (envScenes env) terrain client account
        withTerrainViews viewsConfig ports $ \views → body views terrain lease style

-- Load this file with these policy words on instance "a" and answer the texture's identity once the request succeeded.
loadOn ∷ Composition → Vm → Text → Text → [Text] → IO Integer
loadOn comp vm key path wordsGiven = do
  Comp.commandLoadPolicy comp vm "a" key path False wordsGiven
  Comp.command comp vm "a" "wait_take" key
  line ← Comp.awaitNoteContaining comp ("a wait_take " <> key)
  line `shouldSatisfy` Text.isInfixOf "status=success"
  Comp.command comp vm "a" "use" key
  used ← Comp.awaitNoteContaining comp ("a use " <> key)
  either (\_ → assertFailure ("the identity was not a number: " <> Text.unpack used)) (pure . fst) (Text.decimal (last (Text.words used)))

-- The committed atlases' two parents, by the names the examples load them under.
atlasFiles ∷ IO Files
atlasFiles = do
  sample ← findSampleDirectory
  let directory = sample </> "content" </> "textures" </> "terrain-atlas"
  colour ← ByteString.readFile (directory </> "colour.png")
  normal ← ByteString.readFile (directory </> "normal.png")
  pure [("colour.png", colour), ("normal.png", normal)]

-- Loam over granite: solid below level 2, air above.
source ∷ SourceSpec
source =
  SourceSpec
    { specMaterials = ["loam", "granite"]
    , specLayers =
        [ LayerSpec {layerMin = Nothing, layerMax = Just (-4), layerMaterial = "granite", layerShape = 0}
        , LayerSpec {layerMin = Just (-4), layerMax = Just 2, layerMaterial = "loam", layerShape = 0}
        ]
    , specPatches = []
    }

-- The camera's runtime demand is bounded to a few regions: the views' copies do not depend on residency.
cameraLimits ∷ Limits
cameraLimits =
  either (error . show) id . mkLimits $
    LimitsSpec
      { specResidentBytes = 256 * mib
      , specEditBytes = 64 * mib
      , specStagingBytes = 128 * mib
      , specLoadJobs = 128
      , specQueuedCommands = 256
      , specPinsPerView = 2
      , specAgingQuanta = 8
      , specQueryRegions = 257
      , specExtentX = 16
      , specExtentY = 16
      , specExtentZ = 32
      , specHoldRegions = 256
      , specCameraRegions = 4
      }
  where
    mib = 1024 * 1024

axis ∷ Integer → AxisCoord
axis v = either (error . show) id (axisFromInteger v)

act ∷ VulkanHost GraphicsScene → Text → VulkanAction (Either e a) → IO (Either Text a)
act host what action =
  atomically (submitVulkanAction host action) >>= \case
    Left refusal → pure (Left (what <> " was refused: " <> tshow refusal))
    Right ticket →
      atomically (awaitVulkanAction ticket) >>= \case
        ActionReturned (Right value) → pure (Right value)
        ActionReturned (Left _) → pure (Left (what <> " was refused"))
        ActionRaised failure → pure (Left (what <> " raised: " <> tshow failure))
        ActionRefused refusal → pure (Left (what <> " was refused before it ran: " <> tshow refusal))

within ∷ Int → IO a → IO a
within seconds action =
  timeout (seconds * 1000000) action >>= \case
    Just value → pure value
    Nothing → assertFailure ("the example did not finish within " <> show seconds <> " seconds")

evidence ∷ Env → Text → IO ()
evidence env line = atomically (modifyTVar' (envEvidence env) (line :))

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
