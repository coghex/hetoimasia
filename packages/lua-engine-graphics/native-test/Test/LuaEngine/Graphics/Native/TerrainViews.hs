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
module Test.LuaEngine.Graphics.Native.TerrainViews (spec, fullSpec, overlapSpec, Holding, newHolding) where

import Control.Concurrent.STM
import Control.Exception (finally, onException)
import Control.Monad (forM, forM_, unless, void)
import Data.Foldable (for_)
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
import Hetoimasia.GPU.Model.Identity (BatchId)
import Hetoimasia.GPU.Vulkan.Native.Frames (CompletionHold (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (ticketBatch)
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
import Hetoimasia.Render.TwoD.Snapshot (Camera (..), ClearColour (..), Pass (..), Snapshot (..), Target (OffscreenTarget), View (..))
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (validateSnapshotWith)
import Hetoimasia.Render.TwoD.Vulkan.Chunks (RetainedView (..), retainedChunks, retainedViewSTM)
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMarks)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), axisFromInteger, tileCoord)
import Hetoimasia.Terrain.Residency (RegionDemand (..), RegionInfo (..), coverageBox, modelRegions)
import System.Timeout (timeout)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle, findSampleDirectory, loadAtlasStyle)
import qualified Hetoimasia.Terrain.Render2D.AtlasFixtures as Fixtures
import qualified Hetoimasia.Terrain.Render2D.Camera as Camera
import Hetoimasia.Terrain.Render2D.Cells (CellConfig (..), PartKind (..), TargetRect (..), cellPlanQuads, quadCell, quadPart, quadTarget)
import Hetoimasia.Terrain.Render2D.Material (terrainModel)
import Hetoimasia.Terrain.Render2D.Presentation (defaultLightInput)
import qualified Hetoimasia.Terrain.Runtime as Runtime
import Hetoimasia.Terrain.Runtime.Storage (filesystemOf, minHeadroomBytes, mkStorageConfig)
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), defaultStoreSpec, minAllowanceBytes)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import qualified Data.Text.IO as Text
import qualified Test.LuaEngine.Graphics.Png as Png
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
      a ← renderJudged rig "required A"
      worldTag (rwWorld a) `shouldBe` WorldTag (viewIncarnation view) 1
      chunksA ← pure (worldChunks (rwWorld a))
      -- The original handles go; the view keeps drawing under its own interests.
      command (rgComp rig) (rgVm rig) "i" "release" "colour"
      command (rgComp rig) (rgVm rig) "i" "release" "normal"
      _ ← awaitNoteContaining (rgComp rig) "i release normal"
      -- An edit is prepared, published and adopted as B; A's regions that B does not list retire after A's batches.
      removeAt rig (8, 8, 3)
      _ ← awaitAdopted rig (first' + 1)
      b ← renderJudged rig "required B"
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

-- | The broader matrix, run alone by @--terrain-views-full@. Every rendering is judged pixel by pixel by the oracle;
-- the picks are judged against the plan the host adopted (the oracle names colours, not the quad that wins a pixel): at
-- every judged terrain pixel that exactly one quad of a known part covers, the pick is a hit of that quad's cell.
fullSpec ∷ Env → Spec
fullSpec env = describe "terrain views (full)" $ do
  forM_ [FaceSouth, FaceWest, FaceNorth, FaceEast] $ \facing →
    it ("draws every facing exactly, and picks what it draws: " <> show facing) $
      within 60 . withRig env $ \rig → do
        view ← attach rig (metricsOf 128 96)
        n ← awaitAdopted rig 1
        atomically (updateCamera view (CameraIntent [Camera.SetFacing facing])) `shouldReturn` Right ()
        _ ← awaitAdopted rig (n + 1)
        rendered ← renderJudged rig ("facing " <> Text.pack (show facing))
        pickAgreement view rendered >>= notePicks
        closeView view
  forM_ [0.125, 0.5, 2, 8] $ \zoom →
    it ("draws a zoom exactly, the endpoints included: " <> show zoom) $
      within 60 . withRig env $ \rig → do
        view ← attach rig (metricsOf 128 96)
        n ← awaitAdopted rig 1
        atomically (updateCamera view (CameraIntent [Camera.SetZoom zoom])) `shouldReturn` Right ()
        _ ← awaitAdopted rig (n + 1)
        rendered ← renderJudged rig ("zoom " <> Text.pack (show zoom))
        pickAgreement view rendered >>= notePicks
        closeView view
  it "draws a portrait target exactly, and a pick over the clear background finds nothing" $
    within 60 . withRig env $ \rig → do
      view ← attach rig (metricsOf 64 128)
      _ ← awaitAdopted rig 1
      rendered ← renderJudged rig "portrait"
      clearPicks ← forM (take 64 (rwClear rendered)) $ \(x, y) → atomically (pickView view (fromIntegral x + 0.5, fromIntegral y + 0.5))
      [p | p@(PickHit _) ← clearPicks] `shouldBe` []
      pickAgreement view rendered >>= notePicks
      closeView view
  it "draws an adopted view again after its target is resized, at the new metrics, and picks what it draws" $
    within 60 . withRig env $ \rig → do
      view ← attach rig (metricsOf 128 96)
      n ← awaitAdopted rig 1
      _ ← renderJudged rig "before the resize"
      atomically (writeTVar (rgMetrics rig) (metricsOf 96 128))
      _ ← awaitAdopted rig (n + 1)
      rendered ← renderJudged rig "after the resize"
      pickAgreement view rendered >>= notePicks
      closeView view
  it "draws a lower background far outside the camera's radius exactly" $
    within 60 . withRigOn pillarOverPlain (\c → c {tvCellConfig = (tvCellConfig c) {ccDepth = 250}}) env $ \rig → do
      view ← attach rig (metricsOf 128 96)
      _ ← awaitAdopted rig 1
      Just (visible, _) ← atomically (viewDemand view)
      [r | r ← visible, abs (regionX r) > 1 || abs (regionY r) > 1] `shouldSatisfy` (not . null)
      rendered ← renderJudged rig "background"
      pickAgreement view rendered >>= notePicks
      closeView view
  it "draws a revealed cavity's ordinary, fog and mixed cells exactly" $
    within 60 . withRigOn cavitySource id env $ \rig → do
      view ← attach rig (metricsOf 128 96)
      _ ← awaitAdopted rig 1
      let axis = either (error . show) id . axisFromInteger
          sliced = do
            now ← publishedOf rig
            landing ← atomically (jumpView view (JumpRequest (axis 8, axis 8) (Just (axis 2)))) >>= either (assertFailure . show) pure
            within 20 (atomically (jumpSettled landing >>= maybe retry pure)) `shouldReturn` SettledOk JumpLanded
            void (awaitAdopted rig (now + 1))
      sliced
      -- the removal above the sealed cavity opens it, and the view is cut through it again
      now ← publishedOf rig
      removeAt rig (8, 8, 3)
      _ ← awaitAdopted rig (now + 1)
      sliced
      parts ← within 20 . atomically $ do
        plan ← adoptedPlan view >>= maybe retry pure
        let found = Set.fromList (map quadPart (cellPlanQuads plan))
        if Set.fromList [PartFog, PartKnown, PartOrdinary] `Set.isSubsetOf` found then pure found else retry
      Set.size parts `shouldBe` 3
      rendered ← renderJudged rig "mixed"
      pickAgreement view rendered >>= notePicks
      closeView view
  it "keeps the adopted image when a replacement is refused as stale, then draws the replacement once it is made again" $ do
    stage ← newTVarIO (Nothing ∷ Maybe (Text.Text, TVar Bool))
    held ← newTVarIO False
    -- every gate opens when the example ends, however it ends, so the views' worker is never left parked in the hook
    -- and a failure is reported rather than hanging the teardown
    released ← newTVarIO False
    let hook _ entered = do
          wait ← atomically $ readTVar stage >>= \case
            Just (wanted, opened) | wanted == entered → Just opened <$ (writeTVar stage Nothing >> writeTVar held True)
            _ → pure Nothing
          forM_ wait $ \opened → atomically ((||) <$> readTVar opened <*> readTVar released >>= check)
        awaitHeld what =
          timeout 20000000 (atomically (readTVar held >>= check))
            >>= maybe (assertFailure ("the views' worker did not reach " <> what <> " within 20 seconds")) pure
    within 90 . withRigOn loamOverGranite (\c → c {tvOnStage = hook}) env $ \rig → (`finally` atomically (writeTVar released True)) $ do
      view ← attach rig (metricsOf 128 96)
      _ ← awaitAdopted rig 1
      -- the runtime's background loads are settled first: the view's whole demand is resident, so nothing but the far
      -- view below moves the residency generation, and the view is idle with what it published adopted
      settleBackground rig view
      n ← publishedOf rig
      before' ← renderJudged rig "the adopted image"
      -- the replacement is held as its uploads end, the arena's residency moves under it, and its publication is
      -- refused as stale; the next preparation is held as it starts copying again
      uploaded ← newTVarIO False
      atomically (writeTVar stage (Just ("uploading", uploaded)))
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      awaitHeld "the replacement's uploading stage"
      moveResidency rig
      again ← newTVarIO False
      atomically (writeTVar held False >> writeTVar stage (Just ("copying", again)) >> writeTVar uploaded True)
      awaitHeld "the copying stage of the preparation after the stale refusal"
      publishedOf rig `shouldReturn` n
      kept ← renderJudged rig "kept after the stale replacement"
      worldTag (rwWorld kept) `shouldBe` worldTag (rwWorld before')
      atomically (writeTVar again True)
      _ ← awaitAdopted rig (n + 1)
      rendered ← renderJudged rig "the replacement"
      zoomOf (rwWorld rendered) `shouldBe` 2
      closeView view


-- | The asserted overlap witness (owner decision S, #645 comment 6924532805), on a host whose test-only completion hold
-- is set: A's batch is held from its recording, B is adopted, A's own chunks stay held by the production ledger and the
-- terrain GPU bank while a step has observed A's batch pending since B's adoption; the hold lets go, A's batch
-- completes on its fence, and A's own chunks retire. Both images are judged. Every hold is let go on every exit.
overlapSpec ∷ Holding → Env → Spec
overlapSpec holding env = describe "terrain views (full)" $
  it "keeps a superseded revision's own chunks held while its batch is held in GPU use after a newer one is adopted, and retires them once the batch completes" $
    (`finally` atomically (writeTVar (holdingSet holding) Set.empty)) . within 60 . withRig env $ \rig → do
      view ← attach rig (metricsOf 128 96)
      n ← awaitAdopted rig 1
      chunksA ← worldChunks . snd <$> adoptedWorld rig
      heldA ← renderSubmitWith rig (Just holding) "A, held in GPU use"
      -- B: an edit's rebuild, adopted on the target
      removeAt rig (8, 8, 3)
      _ ← awaitAdopted rig (n + 1)
      seenAtB ← readTVarIO (holdingSeen holding)
      -- a step has observed A's batch pending since B's adoption
      within 20 (atomically (readTVar (holdingSeen holding) >>= check . (> seenAtB)))
      chunksB ← worldChunks . snd <$> adoptedWorld rig
      let onlyA = chunksA `Set.difference` chunksB
      onlyA `shouldSatisfy` (not . Set.null)
      (stillPending, live, held, gpu) ← atomically $
        (,,,) <$> prInFlight heldA <*> liveChunksSTM rig <*> (and <$> mapM (ledgerChunkHeld (scenesLedger (envScenes (rgEnv rig)))) (Set.toList onlyA)) <*> terrainViewsGpuCharged (rgViews rig)
      stillPending `shouldBe` True
      onlyA `Set.isSubsetOf` live `shouldBe` True
      held `shouldBe` True
      gpu `shouldSatisfy` (> 0)
      -- the hold lets go: A's batch completes on its fence, its image is judged, and its own chunks retire
      atomically (writeTVar (holdingSet holding) Set.empty)
      a ← renderFinish heldA
      worldChunks (rwWorld a) `shouldBe` chunksA
      within 20 . atomically $ liveChunksSTM rig >>= check . Set.null . Set.intersection onlyA
      _ ← renderJudged rig "B, after A's batch"
      evidenceNote ("terrain views (overlap): " <> Text.pack (show (Set.size onlyA)) <> " chunks of A held through B's adoption while A's batch was held; retired after its completion")
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
  , rgClient ∷ !Runtime.Client
  }

withRig ∷ Env → (Rig → IO a) → IO a
withRig = withRigOn loamOverGranite id

-- The rig over this source, its views configured further by this.
withRigOn ∷ SourceSpec → (TerrainViewsConfig → TerrainViewsConfig) → Env → (Rig → IO a) → IO a
withRigOn source configure env body = do
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
      withTerrain source (cpAccount comp) $ \terrain client arena → do
        ports ← productionPorts host graphics (envScenes env) terrain client (cpAccount comp) (pure True)
        withTerrainViews (configure config) ports $ \views →
          body (Rig env comp vm target views terrain arena style (colourKey, normalKey) (colourIdentity, normalIdentity) metrics client)
  where
    -- the views' own cell configuration (their step bound included) with a 30-level band
    config = defaultTerrainViewsConfig {tvCellConfig = (tvCellConfig defaultTerrainViewsConfig) {ccDepth = 30}}

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
  , rwDrawn ∷ ![(Int, Int)]
    -- ^ The pixels the oracle judged that show terrain.
  }

-- | Record the adopted world into a fresh colour target and depth image through the host's recording boundary, wait for
-- the batch's own completion, read the colour back and judge every pixel with the independent oracle.
renderJudged ∷ Rig → Text → IO RenderedWorld
renderJudged rig name = renderSubmit rig name >>= renderFinish

-- A render recorded and submitted, not yet waited for: its batch may still be in flight.
data PendingRender = PendingRender
  { prInFlight ∷ !(STM Bool)
    -- ^ Whether the batch has not completed yet.
  , prFinish ∷ !(IO RenderedWorld)
  }

renderFinish ∷ PendingRender → IO RenderedWorld
renderFinish = prFinish

-- | Record the adopted world into a fresh colour target and depth image and submit the batch, without waiting for it.
renderSubmit ∷ Rig → Text → IO PendingRender
renderSubmit rig = renderSubmitWith rig Nothing

-- A completion hold over a set of batch ids (the host's test-only 'CompletionHold'), counting each owner step that
-- observed a held batch.
data Holding = Holding
  { holdingSet ∷ !(TVar (Set.Set BatchId))
  , holdingSeen ∷ !(TVar Int)
  }

newHolding ∷ IO (Holding, CompletionHold)
newHolding = do
  held ← newTVarIO Set.empty
  seen ← newTVarIO 0
  pure (Holding held seen, CompletionHold (\batch → Set.member batch <$> readTVar held) (\_ → modifyTVar' seen (+ 1)))

-- | 'renderSubmit', with the batch held from inside the action that records it (so no owner step can observe it
-- before it is held) when a hold is given.
renderSubmitWith ∷ Rig → Maybe Holding → Text → IO PendingRender
renderSubmitWith rig holding name = do
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
  let release = void (act host (VulkanAction (\construction → mapM_ (releaseConstructed construction) [image, depth] >> releaseConstructed construction readback >> pure (Right ()))))
  (`onException` release) $ do
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
                  , transitionResource recorder image (FromUse TransferRead) ColorAttachment
                  ]
                  >>= \case
                    Left refusal → pure (Left (Text.pack (show refusal)))
                    Right () → pure (Right ()))
        >>= \case
          Left refusal → pure (Left (RefusedIllegal (Text.pack (show refusal))))
          Right (batch, outcome) → do
            for_ holding $ \h → atomically (modifyTVar' (holdingSet h) (Set.insert (ticketBatch batch)))
            pure (Right (batch, either Just (const Nothing) outcome))
    (batch, failure) ← either (assertFailure . Text.unpack) pure ticket
    -- the registry as the batch was recorded: the world is judged against what it drew with, whatever is released
    -- after its batch completes
    chunks ← retainedChunks (graphicsRetained graphics)
    marks ← registeredMarks (graphicsTextures graphics)
    pure . PendingRender ((== TicketPending) <$> readTicket batch) . (`finally` release) $ do
     completion ← atomically (readTicket batch >>= \state → if state == TicketPending then retry else pure state)
     forM_ failure (assertFailure . Text.unpack)
     completion `shouldBe` TicketComplete
     bytes ← act host (VulkanAction (\construction → readConstructedReadback construction readback 0 bytesWanted)) >>= either (assertFailure . Text.unpack) pure
     (revision, world) ← readIORef recorded >>= maybe (assertFailure "nothing was recorded") pure
     -- The independent judgement: the oracle, given the terrain material's pure model and the decoded parents.
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
     -- The evidence: the lossless readback and the machine-readable comparison, under the run's evidence directory.
     let indeterminate = length [() | (_, ProbeIndeterminate _) ← verdicts]
         byteAt x y k = fromIntegral (ByteString.index bytes ((y * width + x) * 4 + k))
         png = Png.rgba8 width height (\x y → (byteAt x y 0, byteAt x y 1, byteAt x y 2, byteAt x y 3))
         record =
           Text.unlines
             [ "{"
             , "  \"name\": \"" <> name <> "\","
             , "  \"revision\": " <> Text.pack (show revision) <> ","
             , "  \"view\": " <> Text.pack (show (tagView (worldTag world))) <> ", \"plan\": " <> Text.pack (show (tagRevision (worldTag world))) <> ","
             , "  \"framebuffer\": [" <> Text.pack (show width) <> ", " <> Text.pack (show height) <> "],"
             , "  \"chunks\": " <> Text.pack (show (Set.size (worldChunks world))) <> ","
             , "  \"pixels\": " <> Text.pack (show (width * height)) <> ", \"passed\": " <> Text.pack (show (length passedPixels)) <> ", \"failed\": " <> Text.pack (show (length failed)) <> ", \"indeterminate\": " <> Text.pack (show indeterminate) <> ","
             , "  \"clear_pixels\": " <> Text.pack (show (length clear)) <> ","
             , "  \"judge\": \"render-2d oracle with terrainModel and the decoded parents\","
             , "  \"completion\": \"the batch's own ticket reported complete before the readback was read\""
             , "}"
             ]
     directory ← lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE"
     forM_ directory $ \place → do
       let folder = place </> "terrain-views"
           stem = Text.unpack (Text.map (\c → if c `elem` (['a' .. 'z'] <> ['0' .. '9']) then c else '-') (Text.toLower name))
       createDirectoryIfMissing True folder
       ByteString.writeFile (folder </> stem <> ".png") png
       Text.writeFile (folder </> stem <> ".json") record
     take 4 failed `shouldBe` []
     -- enough of the image is decided for the judgement to speak: a minified view leaves more texel boundaries to the
     -- oracle's refusal, so the floor is a quarter of the pixels, not half
     length passedPixels `shouldSatisfy` (> (width * height) `div` 4)
     -- the world is drawn: some judged pixel shows terrain, not the clear colour
     length clear `shouldSatisfy` (< length passedPixels)
     pure (RenderedWorld revision world clear [p | p ← passedPixels, p `notElem` clear])

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

-- The picks judged against the adopted plan (the oracle names colours, not the quad that wins a pixel). At every
-- judged terrain pixel whose containing quads in the plan are all known parts, the pick is a hit, and its cell is the
-- cell of one of those quads: the frontmost, unless that quad's texel is a cutout there and a rearward one shows. Answers
-- how many pixels were judged (at least one) and how many named the frontmost quad's cell.
pickAgreement ∷ TerrainView SceneTargetKey → RenderedWorld → IO (Int, Int)
pickAgreement view rendered = do
  plan ← atomically (adoptedPlan view) >>= maybe (assertFailure "no adopted plan") pure
  -- nearest first, the order the pick examines them in
  let nearestFirst = reverse (cellPlanQuads plan)
      contains (x, y) quad =
        let TargetRect l t r b = quadTarget quad
            px = fromIntegral x + 1 / 2 ∷ Double
            py = fromIntegral y + 1 / 2 ∷ Double
         in realToFrac l <= px && px < realToFrac r && realToFrac t <= py && py < realToFrac b
      judged =
        [ (p, cells)
        | p ← rwDrawn rendered
        , let containing = filter (contains p) nearestFirst
        , not (null containing)
        , all ((/= PartFog) . quadPart) containing
        , Just cells ← [mapM quadCell containing]
        ]
  answers ← forM judged $ \(p@(x, y), cells) → (,,) p cells <$> atomically (pickView view (fromIntegral x + 0.5, fromIntegral y + 0.5))
  [(p, take 3 cells, answer) | (p, cells, answer) ← answers, not (hitAmong cells answer)] `shouldBe` []
  length judged `shouldSatisfy` (> 0)
  pure (length judged, length [() | (_, front : _, PickHit ref) ← answers, pickRefCell ref == front])
  where
    hitAmong cells = \case
      PickHit ref → pickRefCell ref `elem` cells
      _ → False

notePicks ∷ (Int, Int) → IO ()
notePicks (judged, front) = evidenceNote ("picks judged from the adopted plan: " <> Text.pack (show judged) <> " pixels, " <> Text.pack (show front) <> " naming the frontmost quad's cell")

-- The adopted scene's world.
adoptedWorld ∷ Rig → IO (Natural, SceneWorld)
adoptedWorld rig = do
  revision ← awaitAdopted rig 1
  adoptedScene rig >>= \case
    Just scene | Just world ← graphicsWorld scene → pure (revision, world)
    _ → assertFailure "the adopted scene holds no world"

-- Wait until the view's whole visible demand is resident and the view is idle with what it published adopted.
settleBackground ∷ Rig → TerrainView SceneTargetKey → IO ()
settleBackground rig view = within 30 . atomically $ do
  demand ← viewDemand view
  model ← Runtime.inspectModelSTM (rgTerrain rig)
  reading ← readView view
  standing ← standingOf rig
  let resident = Set.fromList (map regionCoord (modelRegions model))
      hostSettled = maybe False (\st → isJust (windowAdopted st) && windowAdopted st == windowPublished st) standing
  case demand of
    Just (visible, _)
      | Set.fromList visible `Set.isSubsetOf` resident
      , readingStagedBytes reading == 0
      , isJust (readingPublished reading)
      , hostSettled →
          pure ()
    _ → retry

zoomOf ∷ SceneWorld → Float
zoomOf = cameraZoom . viewCamera . worldView

-- Move the arena's residency generation by one completed load far from the view.
moveResidency ∷ Rig → IO ()
moveResidency rig = do
  let generationNow = fmap Runtime.viewGeneration <$> Runtime.inspectArenaSTM (rgTerrain rig) (rgArena rig)
  start ← atomically generationNow
  other ← Runtime.openView (rgTerrain rig) (rgClient rig) >>= either (assertFailure . show) pure
  demand ← either (assertFailure . show) pure (RegionDemand (RegionCoord 40 40 0) <$> coverageBox 0 16 0 16 0 32)
  _ ← Runtime.setViewDemand (rgTerrain rig) other (rgArena rig) [demand] >>= either (assertFailure . show) pure
  within 20 (atomically (generationNow >>= check . (/= start)))
  Runtime.closeView (rgTerrain rig) other

evidenceNote ∷ Text → IO ()
evidenceNote = Text.putStrLn

-- A plain of loam whose top is level -1, and one pillar of granite rising to level 99 at the camera's column.
pillarOverPlain ∷ SourceSpec
pillarOverPlain =
  SourceSpec
    { specMaterials = ["loam", "granite"]
    , specLayers = [LayerSpec {layerMin = Nothing, layerMax = Just 0, layerMaterial = "loam", layerShape = 0}]
    , specPatches = [PatchSpec {patchX = 8, patchY = 8, patchMin = 0, patchMax = 100, patchValue = SpecSolid "granite" 0}]
    }

-- A sealed one-column cavity at (8, 8), levels 1 and 2, with shaped cells around it on both levels.
cavitySource ∷ SourceSpec
cavitySource =
  loamOverGranite
    { specPatches =
        [PatchSpec {patchX = 8, patchY = 8, patchMin = 1, patchMax = 3, patchValue = SpecAir}]
          <> [ PatchSpec {patchX = x, patchY = y, patchMin = z, patchMax = z + 1, patchValue = SpecSolid "loam" shape}
             | (((x, y), z), shape) ← zip [(c, z) | z ← [1, 2], c ← [(7, 8), (9, 8), (8, 7), (8, 9)]] [1 .. 8]
             ]
    }

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

withTerrain ∷ SourceSpec → RenderAccount → (Runtime.Service → Runtime.Client → Runtime.ArenaLease → IO a) → IO a
withTerrain source account body =
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
        arena ← Runtime.openArena terrain client "views" source >>= either (fail . show) pure >>= Runtime.await terrain >>= either (fail . show) pure
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
