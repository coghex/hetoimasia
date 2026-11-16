{-# LANGUAGE OverloadedStrings #-}

-- | Terrain views (TRA-9) over the real terrain service (#640/#665/#690), the real texture pipeline and instance
-- leases, the real #657 coverage and the real #658/#659 planner and material adaptation.
--
-- Injected, and it says so: the texture owner (the fake owner), the host's scene targets and their adoptions (the scene
-- host model, over the fake's own ledger, which is the one the texture backend's release reads), and the graphics owner's
-- chunk building (a fake owner that mints chunk references and holds each upload's standing until the example lets it
-- complete). The evidence is the adapter's ordering, refusals and ownership, never a frame; the native suite's
-- @terrain views@ subgroup draws.
module Test.LuaEngine.Graphics.TerrainViews (spec) where

import Control.Concurrent (forkIO, killThread, myThreadId)
import Control.Exception (MaskingState (Unmasked), getMaskingState)
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forever, unless, void, when)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as BC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Bits (testBit)
import Data.Int (Int64)
import Data.Word (Word32, Word64)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.LuaEngine.Graphics.Scene.Claims (SceneClaims, claimOf, newSceneClaims)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene (..), LedgerReading (..), initialGraphicsScene, ledgerInterests, ledgerReading)
import Hetoimasia.LuaEngine.Graphics.Scene.Publish (HostAnswer (..))
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (generationIdentity)
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
import Hetoimasia.LuaEngine.Texture (RenderAccount, accountCharged, accountLimit, accountRelease, accountReserve)
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Snapshot (Camera (..), Instance, View (..))
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..))
import Hetoimasia.GPU.Vulkan.GLFW (TextureHandle (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures (toBackendHandle)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (TextureRef (..))
import Hetoimasia.Render.TwoD.Material (MaterialRef, defaultMaterial)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord, axisFromInteger, tileCoord)
import qualified Hetoimasia.Terrain.Render2D.Camera as Camera
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle, findSampleDirectory, loadAtlasStyle)
import qualified Hetoimasia.Terrain.Render2D.AtlasFixtures as Fixtures
import Hetoimasia.Terrain.Render2D.Cells (CellConfig (..), CellKey (..), CellPlan, PartKind (..), cellPlanQuads, defaultCellConfig, quadKey, quadPart)
import Hetoimasia.Terrain.Render2D.Presentation (defaultLightInput)
import Hetoimasia.Terrain.Runtime
  ( ArenaLease
  , Config (..)
  , Ports (..)
  , Service
  , alwaysAdmitting
  , await
  , defaultConfig
  , noProbe
  , openArena
  , standaloneSupervisor
  , storagePort
  , withTerrainService
  )
import qualified Hetoimasia.Terrain.Runtime as Runtime
import Hetoimasia.Terrain.Runtime.Storage (filesystemOf, minHeadroomBytes, mkStorageConfig)
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), defaultStoreSpec, minAllowanceBytes)
import Hetoimasia.Terrain.Residency (Bank (StagingBank), Ledger (..), LimitsSpec (..), RegionDemand (..), RegionInfo (..), bankLedger, coverageBox, mkLimits, modelRegions)
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import System.FilePath ((</>))

import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig
import Test.LuaEngine.Graphics.SceneHost
import Numeric.Natural (Natural)

-- | Everything an example holds.
data Views = Views
  { vComp ∷ !Composition
  , vVm ∷ !Vm
  , vFake ∷ !Fake
  , vModel ∷ !Model
  , _vTerrain ∷ !Service
  , vArena ∷ !ArenaLease
  , vViews ∷ !(TerrainViews Int)
  , vOwner ∷ !FakeOwner
  , vClaims ∷ !(SceneClaims Int)
  , _vAccount ∷ !RenderAccount
  , vStyle ∷ !AtlasStyle
  , vColourKey ∷ !Word64
  , vNormalKey ∷ !Word64
  , vClient ∷ !Runtime.Client
    -- ^ The terrain client that holds the arena's lease.
  }

spec ∷ Spec
spec = describe "terrain views" $ do
  eviction
  reuse
  pickConsistency
  races
  lifecycle
  styles
  jumps
  it "attaches under the target's claim, publishes a whole world revision, and picks only from the revision the host adopted" $
    withViews $ \v → do
      view ← attached v 1
      -- The first revision is published under the claim; until the host adopts it a pick is loading.
      revision ← awaitPublished v 1
      atomically (claimOf (vClaims v) 1) >>= (`shouldSatisfy` isJust)
      world ← latestWorld v 1
      worldTag world `shouldBe` WorldTag (viewIncarnation view) 1
      atomically (pickView view (64, 48)) `shouldReturn` PickLoading
      adoptNow (vModel v) 1 `shouldReturn` Adopted revision
      picked ← atomically (pickView view (64, 48))
      picked `shouldSatisfy` (/= PickLoading)
      closeView view

  it "closes with a real empty revision that the host adopts, and retires the view's regions only after that adoption is released" $
    withViews $ \v → do
      view ← attached v 1
      revision ← awaitPublished v 1
      _ ← adoptNow (vModel v) 1
      chunks ← Set.toList . worldChunks <$> latestWorld v 1
      chunks `shouldSatisfy` (not . null)
      closing ← async' (closeView view)
      -- The handback publishes the initial content as a new revision, naming nothing.
      awaitRevision' v 1 (revision + 1)
      latest ← latestScene (vModel v) 1
      fmap graphicsWorld latest `shouldBe` Just Nothing
      closing
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty
      -- The terrain revision is still adopted: nothing is released yet.
      released ← releasedChunks (vOwner v)
      released `shouldBe` []
      -- The empty revision is adopted and the terrain revision's adoption is released: its regions retire.
      adoptNow (vModel v) 1 `shouldReturn` Adopted (revision + 1)
      _ ← releasePass (vModel v)
      bounded (atomically (readTVar (foReleased (vOwner v)) >>= \done → unless (Set.fromList chunks `Set.isSubsetOf` Set.fromList done) retry))

  it "refuses a second view of a claimed target, and a target without the qualified depth, before taking anything" $
    withViews $ \v → do
      _ ← attached v 1
      second ← attachOutcome v (target v 1)
      second `shouldBe` SettledRefused AttachTargetClaimed
      modelWindow (vModel v) 2
      noDepth ← attachOutcome v (target v 2) {vtDepth = False}
      noDepth `shouldBe` SettledRefused AttachNoDepth
      atomically (claimOf (vClaims v) 2) `shouldReturn` Nothing

  it "refuses an M1 publication's claim race the other way: a view cannot claim a target that is not usable, and leaves no interest" $
    withViews $ \v → do
      setUsable (vModel v) 1 False
      outcome ← attachOutcome v (target v 1)
      outcome `shouldBe` SettledRefused AttachTargetUnusable
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty

  it "keeps rebuilding and publishing under the view's own interests after the original Lua handles are released, which then cannot authorize a new view" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      _ ← adoptNow (vModel v) 1
      command (vComp v) (vVm v) "i" "release" "colour"
      command (vComp v) (vVm v) "i" "release" "normal"
      _ ← awaitNoteContaining (vComp v) "i release normal"
      -- the parents stay registered: the view holds them
      atomically ((/= mempty) <$> ledgerInterests (fakeLedger (vFake v))) `shouldReturn` True
      -- a presentation change is prepared and published under the view's interests
      atomically (updatePresentation view noPresentationUpdate {updateAmbient = Just 0.5}) `shouldReturn` Right ()
      _ ← awaitPublished' v 1 (first' + 1)
      -- the released handles cannot authorize another view
      modelWindow (vModel v) 2
      again ← attachOutcome v (target v 2)
      again `shouldSatisfy` \case SettledRefused (AttachStyle (ParentRefused ColourRole _)) → True; _ → False
      closeView view

-- ---------------------------------------------------------------------------
-- Picks and their consistency

pickConsistency ∷ Spec
pickConsistency = describe "a pick's consistency reference" $ do
  it "removes through a hit's precondition at the atomic settlement, and refuses it stale after another edit or a newer adoption" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      _ ← adoptNow (vModel v) 1
      -- Reveal some known terrain: a removal at the anchor's surface discovers its neighbours.
      revealAt v (8, 8, 3)
      known ← currentHit v view
      -- A valid reference reaches the settlement and removes.
      removed ← removeWith v (pickRefCell known) (Just (pickPrecondition view known))
      removed `shouldBe` Right True
      -- That edit made the reference stale: the same precondition is refused, and nothing changes.
      again ← currentHit v view
      _ ← removeWith v (pickRefCell again) Nothing
      removeWith v (pickRefCell again) (Just (pickPrecondition view again)) >>= (`shouldBe` Left Runtime.StaleView)
      -- A reference picked from a revision the host has since replaced is stale even with the content and knowledge
      -- unchanged: discovery has settled, so only the adoption moves.
      quiescent v
      fresh ← currentHit v view
      atomically (updatePresentation view noPresentationUpdate {updateAmbient = Just 0.4}) `shouldReturn` Right ()
      newer ← publishedRevision (vModel v) 1 >>= \now → awaitPublished' v 1 (now + 1)
      adoptNow (vModel v) 1 `shouldReturn` Adopted newer
      quiescentRevisions ← Runtime.arenaStatus (_vTerrain v) (vArena v) >>= either (fail . show) pure
      Runtime.preconditionKnowledge (pickPrecondition view fresh) `shouldBe` Just (Runtime.statusKnowledgeRevision quiescentRevisions)
      removeWith v (pickRefCell fresh) (Just (pickPrecondition view fresh)) >>= (`shouldBe` Left Runtime.StaleView)
      closeView view

  it "refuses a pick's removal once a load moves the residency generation, and removes through one picked from the revision made at the new generation" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      _ ← adoptNow (vModel v) 1
      revealAt v (8, 8, 3)
      quiescent v
      hit ← currentHit v view
      -- one load elsewhere: content and knowledge are unchanged, only residency moved
      held ← Runtime.arenaStatus (_vTerrain v) (vArena v) >>= either (fail . show) pure
      moveResidency v
      moved ← Runtime.arenaStatus (_vTerrain v) (vArena v) >>= either (fail . show) pure
      (Runtime.statusContentRevision moved, Runtime.statusKnowledgeRevision moved) `shouldBe` (Runtime.statusContentRevision held, Runtime.statusKnowledgeRevision held)
      removeWith v (pickRefCell hit) (Just (pickPrecondition view hit)) >>= (`shouldBe` Left Runtime.StaleView)
      -- the view prepares again for the new generation; a hit from that revision is valid
      fresh ← currentHit v view
      generation ← generationNow v
      pickResidency (pickRefIdentity fresh) `shouldBe` generation
      removeWith v (pickRefCell fresh) (Just (pickPrecondition view fresh)) >>= (`shouldBe` Right True)
      closeView view

-- The first visible known part of the adopted frame, scanning the target's pixel centres.
adoptedHit ∷ Views → TerrainView Int → IO (PickRef Int)
adoptedHit _ view = do
  found ← atomically $ do
    answers ← mapM (pickView view) [(x + 0.5, y + 0.5) | y ← [0, 4 .. 92], x ← [0, 4 .. 124]]
    case [ref | PickHit ref ← answers] of
      ref : _ → pure ref
      [] → retry
  pure found

-- A hit from a revision planned at the arena's current content and knowledge, adopted: discovery commits after an edit,
-- so the first plan after one can already be a knowledge revision behind, and the view prepares again.
currentHit ∷ Views → TerrainView Int → IO (PickRef Int)
currentHit v = currentHitOn v 1

currentHitOn ∷ Views → Int → TerrainView Int → IO (PickRef Int)
currentHitOn v window view = bounded go
  where
    go = do
      _ ← adoptNow (vModel v) window
      _ ← releasePass (vModel v)
      hit ← adoptedHit v view
      status ← Runtime.arenaStatus (_vTerrain v) (vArena v) >>= either (fail . show) pure
      generation ← generationNow v
      let precondition = pickPrecondition view hit
      if Runtime.preconditionContent precondition == Runtime.statusContentRevision status
        && Runtime.preconditionKnowledge precondition == Just (Runtime.statusKnowledgeRevision status)
        && pickResidency (pickRefIdentity hit) == generation
        then pure hit
        else do
          now ← publishedRevision (vModel v) window
          awaitRevision (vModel v) window (now + 1)
          go

-- The zoom a world's view draws with, and the zoom of the first plan (the camera's default, 1).
zoomOf ∷ SceneWorld → Float
zoomOf = cameraZoom . viewCamera . worldView

zoomOfFirst ∷ Float
zoomOfFirst = 1

-- Each cell of a plan by what its quads make it: ordinary (a whole known cell), fog (only the blank fog) or mixed (a
-- known solid, with or without its fog cover), keyed by its place in the rotated view frame.
cellMembership ∷ CellPlan → Map (Integer, Integer, Integer, Integer) PartKind
cellMembership plan = Map.fromListWith strongest [(place (quadKey quad), quadPart quad) | quad ← cellPlanQuads plan]
  where
    place (CellKey a b c d _) = (a, b, c, d)
    strongest x y
      | x == PartKnown || y == PartKnown = PartKnown
      | x == PartOrdinary || y == PartOrdinary = PartOrdinary
      | otherwise = PartFog

-- What the view's adopted revision answers at every fourth pixel centre: the hit's cell and part, or the outcome.
picksOver ∷ TerrainView Int → STM [Either String (TileCoord, PartKind)]
picksOver view = mapM (fmap answer . pickView view) [(x + 0.5, y + 0.5) | y ← [0, 4 .. 92], x ← [0, 4 .. 124]]
  where
    answer = \case
      PickHit ref → Right (pickRefCell ref, pickRefPart ref)
      PickNoHit → Left "no_hit"
      PickLoading → Left "loading"

-- The arena's residency generation now.
generationNow ∷ Views → IO Word64
generationNow v = Runtime.inspectArena (_vTerrain v) (vArena v) >>= maybe (fail "the arena lease is gone") (pure . fromIntegral . Runtime.viewGeneration)

-- Move the arena's residency generation by one completed load and nothing else: another holder's demand for a region
-- far from every view's camera, waited for until the generation moves, then withdrawn.
moveResidency ∷ Views → IO ()
moveResidency v = do
  start ← generationNow v
  other ← Runtime.openView (_vTerrain v) (vClient v) >>= either (fail . show) pure
  demand ← either (fail . show) pure (RegionDemand (RegionCoord 40 40 0) <$> coverageBox 0 16 0 16 0 32)
  _ ← Runtime.setViewDemand (_vTerrain v) other (vArena v) [demand] >>= either (fail . show) pure
  bounded . atomically $
    Runtime.inspectArenaSTM (_vTerrain v) (vArena v) >>= \case
      Just arena | fromIntegral (Runtime.viewGeneration arena) /= start → pure ()
      _ → retry
  Runtime.closeView (_vTerrain v) other

-- Wait until the arena's discovery has nothing pending, so its revisions stay where they are.
quiescent ∷ Views → IO ()
quiescent v = bounded . atomically $
  Runtime.arenaStatusSTM (_vTerrain v) (vArena v) >>= \case
    Right status | Runtime.statusDiscovery status == Runtime.DiscoveryIdle → pure ()
    _ → retry

revealAt ∷ Views → (Integer, Integer, Integer) → IO ()
revealAt v (x, y, z) = do
  now ← publishedRevision (vModel v) 1
  _ ← removeWith v (tileAt x y z) Nothing
  -- the edit makes the view prepare and publish again; the host adopts it
  newer ← awaitPublished' v 1 (now + 1)
  adoptNow (vModel v) 1 `shouldReturn` Adopted newer
  void (releasePass (vModel v))

-- Remove a cell through the terrain service with an optional precondition: whether it changed, or the failure.
removeWith ∷ Views → TileCoord → Maybe Runtime.Precondition → IO (Either Runtime.Failure Bool)
removeWith v at precondition = do
  removal ← Runtime.removeAt (_vTerrain v) (vArena v) at precondition >>= either (fail . show) pure
  Runtime.await (_vTerrain v) removal >>= \case
    Right answer → pure (Right (Runtime.removeChangedFlag answer))
    Left (Runtime.Failed why) → pure (Left why)
    Left other → fail (show other)

tileAt ∷ Integer → Integer → Integer → TileCoord
tileAt x y z = either (error . show) id (tileCoord x y z)

-- ---------------------------------------------------------------------------
-- Attachment races and intent

races ∷ Spec
races = describe "attachment and intent" $ do
  it "refuses an attachment whose parent was released between its retention and the commit, taking no claim and no interest" $
    withViews $ \v → do
      -- Hold the worker inside the owner while the first view builds, then queue a second view.
      atomically (writeTVar (foGate (vOwner v)) False)
      first' ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 1))) >>= either (fail . show) pure
      bounded (atomically (readTVar (foWaiting (vOwner v)) >>= check . (> 0)))
      modelWindow (vModel v) 2
      second ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= either (fail . show) pure
      -- The instance releases the colour parent before the worker reaches the second commit.
      command (vComp v) (vVm v) "i" "release" "colour"
      _ ← awaitNoteContaining (vComp v) "i release colour"
      bounded (atomically (readFake (vFake v) >>= check . not . Set.null . readingMarkedNow))
      atomically (writeTVar (foGate (vOwner v)) True)
      _ ← bounded (awaitAttach first')
      bounded (awaitAttach second) `shouldReturn` SettledRefused AttachParentReleased
      atomically (claimOf (vClaims v) 2) `shouldReturn` Nothing

  it "cancels a queued attachment: it settles cancelled once, takes no claim, and a late cancel changes nothing" $
    withViews $ \v → do
      atomically (writeTVar (foGate (vOwner v)) False)
      first' ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 1))) >>= either (fail . show) pure
      bounded (atomically (readTVar (foWaiting (vOwner v)) >>= check . (> 0)))
      modelWindow (vModel v) 2
      second ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= either (fail . show) pure
      cancelAttach (vViews v) second `shouldReturn` True
      cancelAttach (vViews v) second `shouldReturn` False
      atomically (writeTVar (foGate (vOwner v)) True)
      _ ← bounded (awaitAttach first')
      bounded (awaitAttach second) `shouldReturn` SettledCancelled
      atomically (claimOf (vClaims v) 2) `shouldReturn` Nothing

  it "discards a plan whose intent was superseded while its regions were being built, and publishes the newer intent's plan instead" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      -- Hold the next build inside the owner, change the intent meanwhile, then let the build finish.
      -- (a zoom moves every quad, so its regions are built anew)
      atomically (writeTVar (foGate (vOwner v)) False)
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (readTVar (foWaiting (vOwner v)) >>= check . (> 0)))
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      atomically (writeTVar (foGate (vOwner v)) True)
      -- The next publication is the newer intent's: zoom 4, never the superseded zoom 2.
      awaitRevision' v 1 (first' + 1)
      world ← latestWorld v 1
      zoomOf world `shouldBe` 4 * zoomOfFirst
      closeView view

  it "applies camera and presentation updates all or nothing: an invalid update changes nothing and publishes nothing" $
    withViews $ \v → do
      view ← attached v 1
      published ← awaitPublished v 1
      atomically (updatePresentation view noPresentationUpdate {updateAmbient = Just 0.5, updateHaze = Just 2}) >>= (`shouldSatisfy` isInvalid)
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2, Camera.ZoomBy (0 / 0)])) >>= (`shouldSatisfy` isInvalid)
      atomically (readView view) >>= (`shouldBe` Just published) . fmap fromIntegral . readingPublished
      -- a valid update is recorded intent: it publishes a new revision later
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      _ ← awaitPublished' v 1 (published + 1)
      -- nothing is adopted, so the superseded regions wait behind the barrier: that delays no close
      closeView view
  where
    isInvalid = \case Left (IntentInvalid _) → True; _ → False

-- ---------------------------------------------------------------------------
-- Residency under the view's own camera demand: eviction and reload at the full region extent

eviction ∷ Spec
eviction = describe "eviction" $ do
  it "pans away until the view's regions are evicted and back: they reload, and the view publishes the same plan and picks again" $
    withViewsTerrain HostFirst tightTerrain stripes testConfig $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      hit ← currentHit v view
      plan ← atomically (adoptedPlan view) >>= maybe (fail "no adopted plan") pure
      picks ← atomically (picksOver view)
      instances ← drawnInstances v 1
      original ← residentRegions v
      -- pan east three regions at a time until one of the view's first regions has been evicted (a region the camera
      -- demands stores at most about 37 KB, and each step demands about eight new ones)
      let away k = do
            now ← publishedRevision (vModel v) 1
            atomically (updateCamera view (CameraIntent [Camera.Pan 48 0])) `shouldReturn` Right ()
            _ ← awaitPublished' v 1 (now + 1)
            _ ← adoptNow (vModel v) 1
            _ ← releasePass (vModel v)
            -- the step's demand loads before the camera moves on, so the bank fills step by step
            demandResident v view
            gone ← Set.difference original <$> residentRegions v
            if not (Set.null gone) || k >= 60 then pure (k, gone) else away (k + 1)
      (pans, evicted) ← away (1 ∷ Int)
      evicted `shouldSatisfy` (not . Set.null)
      -- back to the first camera: the evicted regions load again under the view's demand
      atomically (updateCamera view (CameraIntent [Camera.Pan (-48 * fromIntegral pans) 0])) `shouldReturn` Right ()
      bounded (atomically (Runtime.inspectModelSTM (_vTerrain v) >>= \model → check (original `Set.isSubsetOf` Set.fromList (map regionCoord (modelRegions model)))))
      again ← currentHit v view
      -- the residency generation moved, and the view caught up with it; what it draws and picks is what it was
      pickResidency (pickRefIdentity again) `shouldNotBe` pickResidency (pickRefIdentity hit)
      replanned ← atomically (adoptedPlan view) >>= maybe (fail "no adopted plan") pure
      cellMembership replanned `shouldBe` cellMembership plan
      atomically (picksOver view) `shouldReturn` picks
      drawnInstances v 1 `shouldReturn` instances
      closeView view

  it "keeps every region of the view's visible demand resident while another holder's demand evicts others, the far background included" $
    withViewsTerrain HostFirst (tightTerrainHolding 64) pillarOverStripes testConfig {tvCellConfig = defaultCellConfig {ccDepth = 250}} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      Just (visible, _) ← atomically (viewDemand view)
      let protectedSet = Set.fromList visible
          far = Set.filter (\region → abs (regionX region) > 1 || abs (regionY region) > 1) protectedSet
      far `shouldSatisfy` (not . Set.null)
      -- the view's demand loads (a view publishes from copies, so it does not wait for this)
      bounded (atomically (Runtime.inspectModelSTM (_vTerrain v) >>= \model → check (protectedSet `Set.isSubsetOf` Set.fromList (map regionCoord (modelRegions model)))))
      -- another holder demands batches of heavy regions far away, each batch replacing the last, until the bank has
      -- evicted some of them
      other ← Runtime.openView (_vTerrain v) (vClient v) >>= either (fail . show) pure
      let press k seen evictedSoFar
            | k > 40 = pure evictedSoFar
            | otherwise = do
                let batch = [RegionCoord (100 + 8 * k + i) j (-1) | i ← [0 .. 7], j ← [0 .. 3]]
                demands ← either (fail . show) pure (traverse (\r → RegionDemand r <$> coverageBox 0 16 0 16 0 32) batch)
                _ ← Runtime.setViewDemand (_vTerrain v) other (vArena v) demands >>= either (fail . show) pure
                bounded . atomically $ Runtime.inspectModelSTM (_vTerrain v) >>= \model →
                  check (all (`elem` map regionCoord (modelRegions model)) batch)
                here ← residentRegions v
                -- the view's visible demand, far background included, is never what the bank gives up
                (protectedSet `Set.isSubsetOf` here) `shouldBe` True
                let seen' = seen <> Set.fromList batch
                    evicted = Set.difference seen' here
                if Set.null evicted then press (k + 1) seen' evicted else pure evicted
      evicted ← press (0 ∷ Int64) Set.empty Set.empty
      evicted `shouldSatisfy` (not . Set.null)
      Runtime.closeView (_vTerrain v) other
      closeView view

-- Limits at the full region extent with the smallest resident bank the minimum-budget rule accepts with four-region
-- holds (about 3.5 MB; the bank scales with the hold bound), so a hundred or so of the camera's regions evict. A view's
-- copies follow the hold bound.
tightTerrain ∷ Config → Config
tightTerrain = tightTerrainHolding 4

-- The same with this hold bound (64 regions: a 21.5 MB bank, for a view whose demand is too wide for four-region
-- copies to keep up with).
tightTerrainHolding ∷ Integer → Config → Config
tightTerrainHolding holdBound config = config {configLimits = limits, configRetainedBytes = retained}
  where
    spec' resident staging =
      LimitsSpec
        { specResidentBytes = resident
        , specEditBytes = 4096
        , specStagingBytes = staging
        , specLoadJobs = 4
        , specQueuedCommands = 6
        , specPinsPerView = 2
        , specAgingQuanta = 3
        , specQueryRegions = 4
        , specExtentX = 16
        , specExtentY = 16
        , specExtentZ = 32
        , specHoldRegions = holdBound
        , specCameraRegions = 64
        }
    valid resident staging = either (const Nothing) Just (mkLimits (spec' resident staging))
    firstOf = fromMaybe (error "no valid limits") . listToMaybe
    smallest = firstOf [r | r ← [100000, 200000 .. 400000000], Just _ ← [valid r 400000000]]
    retained = 4 * 1024 * 1024
    stagingFor resident = firstOf [t | t ← [100000, 200000 .. 400000000], Just _ ← [valid resident t]]
    limits = fromMaybe (error "invalid limits") (valid smallest (3 * stagingFor smallest + toInteger retained))

-- Wait until every region of the view's latest visible demand is resident.
demandResident ∷ Views → TerrainView Int → IO ()
demandResident v view = bounded . atomically $ do
  demand ← viewDemand view
  case demand of
    Nothing → retry
    Just (visible, _) → do
      model ← Runtime.inspectModelSTM (_vTerrain v)
      check (Set.fromList visible `Set.isSubsetOf` Set.fromList (map regionCoord (modelRegions model)))

-- The regions the terrain service holds resident.
residentRegions ∷ Views → IO (Set.Set RegionCoord)
residentRegions v = Set.fromList . map regionCoord . modelRegions <$> Runtime.inspectModel (_vTerrain v)

-- ---------------------------------------------------------------------------
-- Reuse and coherent replacement

reuse ∷ Spec
reuse = describe "retained regions" $ do
  it "never publishes a plan whose residency generation moved after its copies were labelled: the next published revision carries the new generation" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      _ ← adoptNow (vModel v) 1
      quiescent v
      -- the next plan's copies are labelled; its build is held at the owner
      let openGate = atomically (writeTVar (foGate (vOwner v)) True)
      atomically (writeTVar (foGate (vOwner v)) False)
      generation ← (`finally` openGate) $ do
        atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
        bounded (atomically (readTVar (foWaiting (vOwner v)) >>= check . (> 0)))
        moveResidency v
        generationNow v
      newer ← awaitPublished' v 1 (first' + 1)
      adoptNow (vModel v) 1 `shouldReturn` Adopted newer
      hit ← adoptedHit v view
      pickResidency (pickRefIdentity hit) `shouldBe` generation
      closeView view

  it "reuses every region across frames and across a presentation-only change, building nothing again" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      chunks ← worldChunks <$> latestWorld v 1
      built ← readTVarIO (foBuilt (vOwner v))
      -- frames: adoptions and their releases build nothing
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      _ ← releasePass (vModel v)
      -- a presentation-only change publishes a new revision over the same regions
      atomically (updatePresentation view noPresentationUpdate {updateAmbient = Just 0.5}) `shouldReturn` Right ()
      _ ← awaitPublished' v 1 (first' + 1)
      worldChunks <$> latestWorld v 1 `shouldReturn` chunks
      readTVarIO (foBuilt (vOwner v)) `shouldReturn` built
      closeView view

  it "never exposes a partial frame while an edit's rebuild uploads: the old revision stays published and pickable until the whole new one is ready" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      old ← latestWorld v 1
      atomically (writeTVar (foHoldUploads (vOwner v)) True)
      _ ← removeWith v (tileAt 8 8 3) Nothing
      -- the rebuild's chunks are built and still uploading: nothing new is published, and picks use the old frame
      bounded (atomically (readTVar (foStanding (vOwner v)) >>= check . elem ChunkUploading . Map.elems))
      publishedRevision (vModel v) 1 `shouldReturn` first'
      (worldTag <$> latestWorld v 1) `shouldReturn` worldTag old
      atomically (pickView view (64, 48)) >>= (`shouldSatisfy` (/= PickLoading))
      -- the uploads complete: the new revision is published whole, every chunk it lists ready
      atomically $ do
        writeTVar (foHoldUploads (vOwner v)) False
        modifyTVar' (foStanding (vOwner v)) (Map.map (const ChunkReady))
      _ ← awaitPublished' v 1 (first' + 1)
      new ← latestWorld v 1
      standings ← readTVarIO (foStanding (vOwner v))
      [Map.lookup chunk standings | chunk ← Set.toList (worldChunks new)] `shouldSatisfy` all (== Just ChunkReady)
      closeView view

  it "names every borrow's residency generation in the plan's identity, never relabelling one as another" $ do
    generationIdentity [7, 7, 7] `shouldBe` 7
    let mixed = generationIdentity [7, 9]
    mixed `shouldBe` generationIdentity [9, 7, 9]
    mixed `shouldSatisfy` (\g → g /= 7 && g /= 9 && testBit g 63)
    generationIdentity [7, 10] `shouldNotBe` mixed

-- ---------------------------------------------------------------------------
-- Close orders, limits and the service's end

lifecycle ∷ Spec
lifecycle = describe "close orders and limits" $ do
  it "leaves the target's latest value alone when a view that never published closes, and releases its claim and interests" $
    withViewsConfig testConfig {tvGpuBytes = 0} $ \v → do
      -- With no GPU-data bank, nothing can be published: the view holds its claim and interests and stays pending.
      view ← attached v 1
      atomically (readView view) >>= (`shouldBe` Nothing) . readingPublished
      atomically (pickView view (64, 48)) `shouldReturn` PickLoading
      closeView view
      publishedRevision (vModel v) 1 `shouldReturn` 0
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty

  it "publishes nothing when the target incarnation has ended before the close" $
    withViews $ \v → do
      view ← attached v 1
      published ← awaitPublished v 1
      setUsable (vModel v) 1 False
      closeView view
      publishedRevision (vModel v) 1 `shouldReturn` published
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing

  it "waits without publishing while another consumer fills the shared account, and publishes once it releases" $
    withViews $ \v → do
      -- Another consumer of the session's one account takes all but a few bytes of what is left.
      taken ← atomically $ do
        held ← accountCharged (_vAccount v)
        let room = accountLimit (_vAccount v) - held - 64
        ok ← accountReserve (_vAccount v) room
        pure (if ok then room else 0)
      taken `shouldSatisfy` (> 0)
      view ← attached v 1
      bounded (atomically (readView view >>= check . readingWaiting))
      atomically (readView view) >>= (`shouldBe` Nothing) . readingPublished
      -- The account is released: the view prepares again and publishes, with no new intent.
      atomically (accountRelease (_vAccount v) taken)
      _ ← awaitPublished v 1
      closeView view

  it "holds at most two pinned revisions: a third waits for the newest to be adopted, then publishes with no new intent" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      -- A second revision is published and not adopted: the adopted and the published one are pinned.
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      second ← awaitPublished' v 1 (first' + 1)
      bounded (atomically (readView view >>= check . (== 2) . readingPins))
      -- A third intent cannot pin a third revision: it waits.
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (readView view >>= check . readingWaiting))
      publishedRevision (vModel v) 1 `shouldReturn` second
      -- The host adopts the second; the first unpins and the third publishes.
      adoptNow (vModel v) 1 `shouldReturn` Adopted second
      _ ← awaitPublished' v 1 (second + 1)
      atomically (readView view) >>= (`shouldSatisfy` (<= 2)) . readingPins
      closeView view

  it "retires a revision superseded before any adoption only behind the barrier, never as if it had been adopted" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      chunksA ← worldChunks <$> latestWorld v 1
      -- B replaces A before the host adopted either (a zoom rebuilds every region).
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      second ← awaitPublished' v 1 (first' + 1)
      chunksB ← worldChunks <$> latestWorld v 1
      let onlyA = chunksA `Set.difference` chunksB
      onlyA `shouldSatisfy` (not . Set.null)
      -- A's regions wait for the barrier (the target has not adopted what was published): none is released.
      released ← Set.fromList <$> releasedChunks (vOwner v)
      Set.intersection onlyA released `shouldBe` Set.empty
      -- The host adopts B; the barrier is met, no adoption ever listed A, and A's regions are released.
      adoptNow (vModel v) 1 `shouldReturn` Adopted second
      bounded (atomically (readTVar (foReleased (vOwner v)) >>= \done → unless (onlyA `Set.isSubsetOf` Set.fromList done) retry))
      closeView view

  it "keeps a revision adopted under two attachments until both adoptions are released" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      chunksA ← worldChunks <$> latestWorld v 1
      adoptFor (vModel v) 1 1 `shouldReturn` Adopted first'
      adoptFor (vModel v) 1 2 `shouldReturn` Adopted first'
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      second ← awaitPublished' v 1 (first' + 1)
      chunksB ← worldChunks <$> latestWorld v 1
      let onlyA = chunksA `Set.difference` chunksB
      -- The first attachment moves to B and releases A: the second still holds A, so nothing of A is released.
      adoptFor (vModel v) 1 1 `shouldReturn` Adopted second
      _ ← releasePass (vModel v)
      held ← atomically (ledgerReading (fakeLedger (vFake v)))
      (onlyA `Set.isSubsetOf` readingChunks held) `shouldBe` True
      released ← Set.fromList <$> releasedChunks (vOwner v)
      Set.intersection onlyA released `shouldBe` Set.empty
      -- The second moves too: A's last adoption is released and its regions with it.
      adoptFor (vModel v) 1 2 `shouldReturn` Adopted second
      _ ← releasePass (vModel v)
      bounded (atomically (readTVar (foReleased (vOwner v)) >>= \done → unless (onlyA `Set.isSubsetOf` Set.fromList done) retry))
      closeView view

  it "demands, retains and draws a lower background far outside the camera's radius but inside the projected viewport" $
    withViewsOn pillarOverPlain testConfig {tvCellConfig = defaultCellConfig {ccDepth = 250}} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      Just (visible, _) ← atomically (viewDemand view)
      -- The camera follows the pillar's top at (8, 8); the plain 100 levels below shows about two chunks behind it.
      let anchorChunk = (0, 0)
          outsideRadius region = abs (regionX region - fst anchorChunk) > 1 || abs (regionY region - snd anchorChunk) > 1
          far = filter outsideRadius visible
      far `shouldSatisfy` (not . null)
      -- They were copied and planned: the published plan has nothing pending, which a demand bounded by the camera's
      -- radius cannot reach (the plain in view would stay pending, as loading).
      reading ← atomically (readView view)
      readingPendingRegions reading `shouldBe` 0
      readingRetainedRegions reading `shouldSatisfy` (> 0)
      closeView view

  it "keeps a failed build as evidence, never as busy or success, and the previous view stays until a build succeeds" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      previous ← latestWorld v 1
      atomically (writeTVar (foFailure (vOwner v)) (Just "injected: the device refused the buffer"))
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (terrainViewsFailures (vViews v) >>= check . any (Text.isInfixOf "injected: the device refused the buffer")))
      bounded (atomically (readView view >>= check . readingWaiting))
      publishedRevision (vModel v) 1 `shouldReturn` first'
      latestWorld v 1 >>= (`shouldBe` worldTag previous) . worldTag
      -- The owner recovers: the next intent is built and published.
      atomically (writeTVar (foFailure (vOwner v)) Nothing)
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 0.5])) `shouldReturn` Right ()
      _ ← awaitPublished' v 1 (first' + 1)
      closeView view

  it "reproduces the ordinary, fog and mixed plan and the picks in a fresh view attached after a cavity's reveal, from its own copies of the store" $
    withViewsOn cavitySource testConfig $ \v → do
      -- The same camera intent for both views, whatever their history: a jump to the cavity's column at the exact level 2
      -- (manual mode), so the cut runs through the cavity.
      let axis = either (error . show) id . axisFromInteger
          sliced view window = do
            now ← publishedRevision (vModel v) window
            landing ← atomically (jumpView view (JumpRequest (axis 8, axis 8) (Just (axis 2)))) >>= either (fail . show) pure
            bounded (atomically (jumpSettled landing >>= maybe retry pure)) `shouldReturn` SettledOk JumpLanded
            void (awaitPublished' v window (now + 1))
      view ← attached v 1
      _ ← awaitPublished v 1
      sliced view 1
      -- the removal above the sealed cavity opens it: discovery reveals its air and walls
      now ← publishedRevision (vModel v) 1
      removeWith v (tileAt 8 8 3) Nothing `shouldReturn` Right True
      _ ← awaitPublished' v 1 (now + 1)
      quiescent v
      sliced view 1
      hit ← currentHitOn v 1 view
      original ← atomically (adoptedPlan view) >>= maybe (fail "no adopted plan") pure
      originalPicks ← atomically (picksOver view)
      originalInstances ← drawnInstances v 1
      closeView view
      -- a separate view incarnation on another target, attached after the reveal committed and given the same intent:
      -- it is handed nothing of the first view's and requests its own copies from the arena's store
      modelWindow (vModel v) 2
      fresh ← attached v 2
      _ ← awaitPublished v 2
      sliced fresh 2
      again ← currentHitOn v 2 fresh
      pickViewId (pickRefIdentity again) `shouldNotBe` pickViewId (pickRefIdentity hit)
      let versions identity = (pickArena identity, pickContent identity, pickKnowledge identity)
      versions (pickRefIdentity again) `shouldBe` versions (pickRefIdentity hit)
      replanned ← atomically (adoptedPlan fresh) >>= maybe (fail "no adopted plan") pure
      let membership = cellMembership original
      cellMembership replanned `shouldBe` membership
      -- the revealed cavity leaves ordinary, fog and mixed cells in the view (19, 10 and 2 with this source)
      [length [() | kind ← Map.elems membership, kind == wanted] | wanted ← [PartOrdinary, PartFog, PartKnown]] `shouldSatisfy` all (> 0)
      atomically (picksOver fresh) `shouldReturn` originalPicks
      drawnInstances v 2 `shouldReturn` originalInstances
      closeView fresh

  it "refuses an attachment through a released arena lease before taking anything, and a view's close leaves its arena open" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      closeView view
      -- The view's close did not close the arena: its lease still reads it.
      Runtime.arenaStatus (_vTerrain v) (vArena v) >>= (`shouldSatisfy` either (const False) (const True))
      _ ← Runtime.releaseLease (_vTerrain v) (vArena v)
      modelWindow (vModel v) 2
      attachOutcome v (target v 2) >>= (`shouldSatisfy` \case SettledRefused (AttachArena _) → True; _ → False)
      atomically (claimOf (vClaims v) 2) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty

  it "charges the shared account in whole granules: a pan whose need stays within one leaves the account untouched" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      quiescent v
      held ← readingCpuBytes <$> atomically (readView view)
      held `shouldSatisfy` (\bytes → bytes > 0 && bytes `mod` tvAccountGranule testConfig == 0)
      -- What the account holds beside the terrain service's own staging (whose charge is exactly the model's staging
      -- use): the coverage planes and the view's granules.
      let besideTerrain = do
            charged ← accountCharged (_vAccount v)
            model ← Runtime.inspectModelSTM (_vTerrain v)
            let staging = bankLedger model StagingBank
            pure (charged - (ledgerOccupied staging + ledgerReserved staging))
      before' ← atomically besideTerrain
      atomically (updateCamera view (CameraIntent [Camera.Pan 1 0])) `shouldReturn` Right ()
      _ ← awaitPublished' v 1 (first' + 1)
      -- the view's charge did not move, so nothing but the terrain service's own staging touched the account
      atomically (readView view) >>= (`shouldBe` held) . readingCpuBytes
      atomically besideTerrain `shouldReturn` before'
      closeView view

  it "settles an attachment still queued at the service's end as stopped, releasing what it retained, while the view being built is discarded" $ do
    gateRef ← newTVarIO Nothing
    let releaseGate = readTVarIO gateRef >>= mapM_ (\gate → atomically (writeTVar gate True))
    queued ← newTVarIO Nothing
    withViewsConfig testConfig {tvStopping = releaseGate} $ \v → do
      atomically (writeTVar gateRef (Just (foGate (vOwner v))))
      atomically (writeTVar (foGate (vOwner v)) False)
      first' ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 1))) >>= either (fail . show) pure
      _ ← bounded (awaitAttach first')
      bounded (atomically (readTVar (foWaiting (vOwner v)) >>= check . (> 0)))
      modelWindow (vModel v) 2
      second ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= either (fail . show) pure
      atomically (writeTVar queued (Just second))
    -- the scope has ended: the queued attachment settled once, as stopped
    Just second ← readTVarIO queued
    atomically (attachSettled second) `shouldReturn` Just (SettledRefused AttachStopped)

  it "runs its body with the caller's masking state, never masked by the scope" $
    withViews (\_ → getMaskingState) `shouldReturn` Unmasked

  it "ends the scope's exit when the graphics owner ends first, keeping the retirements it can no longer prove as evidence" $ do
    (views, built) ← withViewsOrdered ViewsFirst loamOverGranite testConfig $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      closeView view
      -- the empty handback is adopted, but the host never releases the revision before it: the ledger still holds its
      -- chunks when the owner ends
      adoptNow (vModel v) 1 `shouldReturn` Adopted (first' + 1)
      atomically (writeTVar (foEnded (vOwner v)) True)
      built ← Map.keys <$> readTVarIO (foInstances (vOwner v))
      pure (vViews v, built)
    built `shouldSatisfy` (not . null)
    failures ← atomically (terrainViewsFailures views)
    failures `shouldSatisfy` any (Text.isPrefixOf "retirement could not be proved")

  it "ends the scope's exit when the views end first while the host keeps presenting, releasing every chunk" $ do
    stepper ← newTVarIO Nothing
    (views, owner, claims) ← (`finally` (readTVarIO stepper >>= mapM_ killThread)) . withViewsOrdered ViewsFirst loamOverGranite testConfig $ \v → do
      _ ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      -- the host adopts whatever is published and releases what that supersedes, for as long as the example runs
      let step = forever $ do
            atomically (modelCapture (vModel v) >>= id >>= check . not)
            _ ← adoptNow (vModel v) 1
            releasePass (vModel v)
      thread ← forkIO step
      atomically (writeTVar stepper (Just thread))
      pure (vViews v, vOwner v, vClaims v)
    atomically (terrainViewsFailures views) `shouldReturn` []
    built ← Map.keys <$> readTVarIO (foInstances owner)
    released ← releasedChunks owner
    Set.fromList released `shouldBe` Set.fromList built
    atomically (claimOf claims 1) `shouldReturn` Nothing

  it "rethrows a cancellation of its worker instead of recording it: the worker ends, attachments stop, and the scope's exit still closes every view" $ do
    (views, claims) ← withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      quiescent v
      atomically (writeTVar (foCancelNext (vOwner v)) True)
      -- a zoom changes every region, so the next plan builds
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      -- the worker took the cancellation inside its next build
      bounded (atomically (readTVar (foCancelNext (vOwner v)) >>= check . not))
      modelWindow (vModel v) 2
      settled ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= \case
        Left refusal → pure (SettledRefused refusal)
        Right attaching → bounded (awaitAttach attaching)
      settled `shouldSatisfy` \case SettledRefused AttachStopped → True; _ → False
      publishedRevision (vModel v) 1 `shouldReturn` first'
      atomically (terrainViewsFailures (vViews v)) `shouldReturn` []
      pure (vViews v, vClaims v)
    -- the scope's exit ran the service's end itself: the view's claim is handed back
    atomically (claimOf claims 1) `shouldReturn` Nothing
    atomically (terrainViewsFailures views) `shouldReturn` []

  it "refuses an attachment beyond the service's views, before taking anything" $
    withViewsConfig testConfig {tvMaxViews = 1} $ \v → do
      _ ← attached v 1
      modelWindow (vModel v) 2
      attachOutcome v (target v 2) `shouldReturn` SettledRefused AttachTooManyViews
      atomically (claimOf (vClaims v) 2) `shouldReturn` Nothing

  it "closes every view at the service's end, handing each claim back with a real empty revision" $ do
    claims ← newTVarIO Nothing
    withViews $ \v → do
      _ ← attached v 1
      published ← awaitPublished v 1
      atomically (writeTVar claims (Just (vClaims v, vModel v, published)))
    Just (claimTable, model, published) ← readTVarIO claims
    atomically (claimOf claimTable 1) `shouldReturn` Nothing
    _ ← pure model
    published `shouldSatisfy` (> 0)

-- ---------------------------------------------------------------------------
-- Style refusals

styles ∷ Spec
styles = describe "style refusals" $ do
  it "refuses a style whose parents swap roles, or exceed the instance's texture bytes, or whose mapping misses a material, as typed non-busy refusals with nothing held" $
    withViews $ \v → do
      let base = requestFor v (target v 1)
          withStyle change = base {attachStyle = change (attachStyle base)}
          outcome request = inInstance (vComp v) (vVm v) "i" (attachView (vViews v) request) >>= \case
            Left refusal → pure (Just refusal)
            Right _ → pure Nothing
      swapped ← outcome (withStyle (\style → style {styleColourLease = styleNormalLease style, styleNormalLease = styleColourLease style}))
      swapped `shouldSatisfy` \case Just (AttachStyle (ParentRefused ColourRole _)) → True; _ → False
      tight ← outcome (withStyle (\style → style {styleInstanceTextureBytes = 4096}))
      tight `shouldSatisfy` \case Just (AttachStyle (StyleExceedsTextureBytes _ 4096)) → True; _ → False
      missing ← outcome (withStyle (\style → style {styleMaterials = [(material, "colour.unknown") | (material, _) ← styleMaterials style]}))
      missing `shouldSatisfy` \case Just (AttachStyle (StyleMapping _)) → True; _ → False
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty
      -- The refusals held nothing: the same instance's valid style attaches.
      void (attached v 1)

-- ---------------------------------------------------------------------------
-- Jumps

jumps ∷ Spec
jumps = describe "jumps" $ do
  it "settles a jump exactly once: a landed jump moves the camera, a newer jump supersedes a pending one, and a cancelled one stays" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      axis ← pure (either (error . show) id . axisFromInteger)
      -- a nearby destination whose facts are held lands
      near ← atomically (jumpView view (JumpRequest (axis 9, axis 9) Nothing)) >>= either (fail . show) pure
      bounded (atomically (jumpSettled near >>= maybe retry pure)) `shouldReturn` SettledOk JumpLanded
      -- a far destination waits for its facts; a newer jump supersedes it without moving the camera for it
      far ← atomically (jumpView view (JumpRequest (axis 4000, axis 4000) Nothing)) >>= either (fail . show) pure
      newer ← atomically (jumpView view (JumpRequest (axis 4100, axis 4100) Nothing)) >>= either (fail . show) pure
      atomically (jumpSettled far) `shouldReturn` Just (SettledOk JumpSuperseded)
      -- the newer one is cancelled and settles cancelled, once
      cancelled ← atomically (cancelJumpView view newer)
      when cancelled $ atomically (jumpSettled newer) `shouldReturn` Just SettledCancelled
      atomically (cancelJumpView view newer) `shouldReturn` False
      closeView view

-- ---------------------------------------------------------------------------
-- The rig

withViews ∷ (Views → IO a) → IO a
withViews = withViewsConfig testConfig

withViewsConfig ∷ TerrainViewsConfig → (Views → IO a) → IO a
withViewsConfig = withViewsOn loamOverGranite

withViewsOn ∷ SourceSpec → TerrainViewsConfig → (Views → IO a) → IO a
withViewsOn = withViewsOrdered HostFirst

-- | Which ends first at the scope's exit: the scene host (its windows dissolved, every adoption released) or the views
-- (the host model stays, and the example decides what it does while the views end).
data EndOrder = HostFirst | ViewsFirst

withViewsOrdered ∷ EndOrder → SourceSpec → TerrainViewsConfig → (Views → IO a) → IO a
withViewsOrdered order = withViewsTerrain order id

withViewsTerrain ∷ EndOrder → (Config → Config) → SourceSpec → TerrainViewsConfig → (Views → IO a) → IO a
withViewsTerrain order terrainConfig source config body = do
  style ← loadAtlasStyle 5 [("loam", "colour.loam"), ("granite", "colour.granite")]
  sample ← findSampleDirectory
  let atlas = sample </> "content" </> "textures" </> "terrain-atlas"
  colourBytes ← ByteString.readFile (atlas </> "colour.png")
  normalBytes ← ByteString.readFile (atlas </> "normal.png")
  fake ← newFake defaultFakeConfig {fcStagingBytes = 4 * 1024 * 1024}
  bounded . withFakeOwner fake $
    withBackendOnRaw fake $ \rig →
      withComposition terrainProfile [("colour.png", colourBytes), ("normal.png", normalBytes)] (rigPort rig) $ \comp _ runtime → do
        model ← newModel (fakeLedger fake)
        setBarrier fake (modelCapture model)
        modelWindow model 1
        vm ← startVm comp runtime "terrain-vm"
        admit comp vm "i"
        loadParent comp vm "colour" ["coverage"]
        loadParent comp vm "normal" ["data", "coverage", "normal"]
        colourKey ← leaseKey comp vm "colour"
        normalKey ← leaseKey comp vm "normal"
        withTerrain terrainConfig source (cpAccount comp) $ \terrain client arena → do
          claims ← newSceneClaims
          owner ← newFakeOwner model
          initial ← prepare initialGraphicsScene
          let ports =
                TerrainViewsPorts
                  { portOwner = fakeViewOwner owner
                  , portReleased = \handle →
                      let TextureHandle index generation = toBackendHandle handle
                       in Set.member (TextureRef index generation) . readingMarkedNow <$> readFake fake
                  , portLedger = fakeLedger fake
                  , portClaims = claims
                  , portInitial = initial
                  , portTerrain = terrain
                  , portClient = client
                  , portAccount = cpAccount comp
                  , portTaking = pure True
                  }
          let run views = body (Views comp vm fake model terrain arena views owner claims (cpAccount comp) style colourKey normalKey client)
          case order of
            HostFirst → withTerrainViews config ports (\views → run views `finally` dissolve model)
            ViewsFirst → withTerrainViews config ports run `finally` dissolve model

-- Small enough for a quick example: a 128 x 96 target and a 30-level band, which reaches the surface below the followed
-- camera's 25 levels of headroom.
testConfig ∷ TerrainViewsConfig
testConfig = defaultTerrainViewsConfig {tvCellConfig = defaultCellConfig {ccDepth = 30}}

metrics ∷ TargetMetrics
metrics = TargetMetrics (PixelExtent 128 96) (PixelExtent 128 96) 1 1

-- The scene host model's window as a view target.
target ∷ Views → Int → ViewTarget Int
target v window =
  let (publishing, usable) = modelTarget (vModel v) window
   in ViewTarget
        { vtKey = window
        , vtUsable = usable
        , vtPublish = \scene → (== HostAccepted) <$> publishing scene
        , vtDepth = True
        , vtMetrics = pure (Just metrics)
        }

-- The request of a view of the arena on this window, with the instance's style.
requestFor ∷ Views → ViewTarget Int → AttachRequest Int
requestFor v viewTarget =
  AttachRequest
    { attachTarget = viewTarget
    , attachStyle =
        StyleRequest
          { styleLeases = vmLeases (vVm v)
          , styleColourLease = vColourKey v
          , styleNormalLease = vNormalKey v
          , styleManifest = Fixtures.styleManifest (vStyle v)
          , styleMaterials = Fixtures.styleMaterialIds (vStyle v)
          , styleInstanceTextureBytes = 2500000
          }
    , attachArena = vArena v
    , attachAnchor = (axis 8, axis 8, axis 3)
    , attachLight = defaultLightInput
    }
  where
    axis = either (error . show) id . axisFromInteger

attachOutcome ∷ Views → ViewTarget Int → IO (Settled (TerrainView Int))
attachOutcome v viewTarget =
  inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v viewTarget)) >>= \case
    Left refusal → pure (SettledRefused refusal)
    Right attaching → do
      settled ← bounded (awaitAttach attaching)
      failures ← atomically (terrainViewsFailures (vViews v))
      failures `shouldBe` []
      pure settled

attached ∷ Views → Int → IO (TerrainView Int)
attached v window =
  attachOutcome v (target v window) >>= \case
    SettledOk view → pure view
    SettledRefused why → expectationFailure ("the attachment was refused: " <> show why) >> fail "unreachable"
    SettledCancelled → expectationFailure "the attachment was cancelled" >> fail "unreachable"

-- Wait for the window's first terrain publication and answer its host revision.
awaitPublished ∷ Views → Int → IO Natural'
awaitPublished v window = awaitPublished' v window 1

awaitPublished' ∷ Views → Int → Natural' → IO Natural'
awaitPublished' v window at = do
  awaitRevision' v window at
  publishedRevision (vModel v) window

awaitRevision' ∷ Views → Int → Natural' → IO ()
awaitRevision' v window at = bounded (awaitRevision (vModel v) window at)

latestWorld ∷ Views → Int → IO SceneWorld
latestWorld v window =
  latestScene (vModel v) window >>= \case
    Just scene | Just world ← graphicsWorld scene → pure world
    _ → expectationFailure "the window holds no world" >> fail "unreachable"

type Natural' = Natural

-- Run an action on its own thread and answer an action that waits for it.
async' ∷ IO () → IO (IO ())
async' action = do
  done ← newEmptyTMVarIO
  _ ← forkIO (action `finally` atomically (putTMVar done ()))
  pure (bounded (atomically (takeTMVar done)))

-- ---------------------------------------------------------------------------
-- The parents

loadParent ∷ Composition → Vm → Text.Text → [Text.Text] → IO ()
loadParent comp vm key policy = do
  commandLoadPolicy comp vm "i" key (key <> ".png") False policy
  command comp vm "i" "wait_take" key
  taken ← awaitNoteContaining comp ("i wait_take " <> key <> " ")
  taken `shouldSatisfy` Text.isInfixOf "status=success"

leaseKey ∷ Composition → Vm → Text.Text → IO Word64
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

-- ---------------------------------------------------------------------------
-- The terrain service

-- The real service over private files in a temporary directory, its staging charged to the session's account, with one
-- arena of loam over granite.
withTerrain ∷ (Config → Config) → SourceSpec → RenderAccount → (Service → Runtime.Client → ArenaLease → IO a) → IO a
withTerrain terrainConfig source account body =
  withSystemTempDirectory "hetoimasia-terrain-views" $ \dir → do
    let directory = BC.pack dir
    name ← filesystemOf directory >>= either (\f → fail ("cannot name the test filesystem: " <> show f)) pure
    storage ← either (fail . show) pure (mkStorageConfig [name] minHeadroomBytes)
    withWorkerGroup $ \group → do
      let config =
            terrainConfig
              defaultConfig
                { configStore = defaultStoreSpec {specAllowanceBytes = toInteger minAllowanceBytes}
                , configStagingAccount = Just (renderStagingAccount account)
                }
      withTerrainService config (Ports alwaysAdmitting (standaloneSupervisor group) quiet noProbe (storagePort group storage directory)) $ \terrain → do
        client ← Runtime.registerClient terrain >>= either (fail . show) pure
        arena ← openArena terrain client "views" source >>= either (fail . show) pure >>= await terrain >>= either (fail . show) pure
        body terrain client arena

-- One level of loam or granite in turn down to level -64, granite below: every column holds a run per level, so a
-- region below the surface stores about a quarter of a megabyte.
stripes ∷ SourceSpec
stripes =
  SourceSpec
    { specMaterials = ["loam", "granite"]
    , specLayers =
        LayerSpec {layerMin = Nothing, layerMax = Just (-64), layerMaterial = "granite", layerShape = 0}
          : [LayerSpec {layerMin = Just z, layerMax = Just (z + 1), layerMaterial = if even z then "loam" else "granite", layerShape = 0} | z ← [-64 .. -1]]
    , specPatches = []
    }

-- The stripes, and one granite pillar rising to level 99 at the camera's column.
pillarOverStripes ∷ SourceSpec
pillarOverStripes = stripes {specPatches = [PatchSpec {patchX = 8, patchY = 8, patchMin = 0, patchMax = 100, patchValue = SpecSolid "granite" 0}]}

cavitySource ∷ SourceSpec
cavitySource =
  loamOverGranite
    { specPatches =
        [PatchSpec {patchX = 8, patchY = 8, patchMin = 1, patchMax = 3, patchValue = SpecAir}]
          <> [ PatchSpec {patchX = x, patchY = y, patchMin = z, patchMax = z + 1, patchValue = SpecSolid "loam" shape}
             | (((x, y), z), shape) ← zip [(c, z) | z ← [1, 2], c ← [(7, 8), (9, 8), (8, 7), (8, 9)]] [1 .. 8]
             ]
    }

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

-- A plain of loam whose top is level -1, and one pillar of granite rising to level 99 at the camera's column: a
-- camera following the pillar's top looks down on the plain a hundred levels below, far behind the pillar.
pillarOverPlain ∷ SourceSpec
pillarOverPlain =
  SourceSpec
    { specMaterials = ["loam", "granite"]
    , specLayers = [LayerSpec {layerMin = Nothing, layerMax = Just 0, layerMaterial = "loam", layerShape = 0}]
    , specPatches = [PatchSpec {patchX = 8, patchY = 8, patchMin = 0, patchMax = 100, patchValue = SpecSolid "granite" 0}]
    }

quiet ∷ Logger
quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))

-- ---------------------------------------------------------------------------
-- The fake graphics owner

-- | A graphics owner that mints chunk references, each ready at once unless the example holds uploads, and releases them
-- when asked; its barrier is the scene host model's own.
data FakeOwner = FakeOwner
  { foModel ∷ !Model
  , foNext ∷ !(TVar Word32)
  , foStanding ∷ !(TVar (Map ChunkRef ChunkStanding))
  , foReleased ∷ !(TVar [ChunkRef])
  , foBuilt ∷ !(TVar Int)
  , foGate ∷ !(TVar Bool)
    -- ^ While closed, a build waits: the adapter's worker is held inside the owner's action.
  , foWaiting ∷ !(TVar Int)
    -- ^ Builds waiting at the closed gate.
  , foFailure ∷ !(TVar (Maybe Text.Text))
    -- ^ While set, a build fails with this reason, as the owner's would.
  , foInstances ∷ !(TVar (Map ChunkRef [Instance]))
    -- ^ What each chunk was built from.
  , foHoldUploads ∷ !(TVar Bool)
    -- ^ While set, a new chunk's upload stays under way until the example completes it.
  , foEnded ∷ !(TVar Bool)
    -- ^ Once set, the owner takes no more actions, as a closed host's: builds and releases answer 'Nothing' and a
    -- barrier not yet met is never met.
  , foCancelNext ∷ !(TVar Bool)
    -- ^ While set, the next build cancels the thread that asked for it (the adapter's worker), once.
  }

newFakeOwner ∷ Model → IO FakeOwner
newFakeOwner model = FakeOwner model <$> newTVarIO 1 <*> newTVarIO Map.empty <*> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO True <*> newTVarIO 0 <*> newTVarIO Nothing <*> newTVarIO Map.empty <*> newTVarIO False <*> newTVarIO False <*> newTVarIO False

fakeViewOwner ∷ FakeOwner → ViewOwner
fakeViewOwner owner =
  ViewOwner
    { ownerMaterial = material
    , ownerDepthQualified = True
    , ownerBuild = \regions → do
       cancel ← atomically (readTVar (foCancelNext owner) <* writeTVar (foCancelNext owner) False)
       when cancel (myThreadId >>= killThread)
       ended ← readTVarIO (foEnded owner)
       if ended then pure Nothing else buildNow regions
    , ownerRelease = \chunks → atomically $ do
        ended ← readTVar (foEnded owner)
        if ended
          then pure Nothing
          else do
            modifyTVar' (foStanding owner) (\held → foldr Map.delete held chunks)
            modifyTVar' (foReleased owner) (<> chunks)
            pure (Just (map (const (Right ())) chunks))
    , ownerBarrier = \_ → do
        met ← modelCapture (foModel owner)
        pure . Right $ do
          ended ← readTVar (foEnded owner)
          done ← met
          pure (if done then Just True else if ended then Just False else Nothing)
    , ownerStanding = \chunk → Map.lookup chunk <$> readTVar (foStanding owner)
    , ownerEnd = readTVar (foEnded owner) >>= check
    }
  where
    buildNow regions = do
         atomically (modifyTVar' (foWaiting owner) (+ 1))
         atomically (readTVar (foGate owner) >>= check)
         atomically $ do
          modifyTVar' (foWaiting owner) (subtract 1)
          failure ← readTVar (foFailure owner)
          case failure of
           Just why → pure (Just (Left (BuildFailed why)))
           Nothing → do
            start ← readTVar (foNext owner)
            let refs = [chunkRef index 1 | index ← take (length regions) [start ..]]
            writeTVar (foNext owner) (start + fromIntegral (length regions))
            holding ← readTVar (foHoldUploads owner)
            modifyTVar' (foStanding owner) (Map.union (Map.fromList [(ref, if holding then ChunkUploading else ChunkReady) | ref ← refs]))
            modifyTVar' (foInstances owner) (Map.union (Map.fromList (zip refs (map buildInstances regions))))
            modifyTVar' (foBuilt owner) (+ length regions)
            pure (Just (Right refs))
    material ∷ MaterialRef
    material = defaultMaterial

-- The instances of every chunk the window's latest world lists, in the world's order.
drawnInstances ∷ Views → Int → IO [[Instance]]
drawnInstances v window = do
  world ← latestWorld v window
  built ← readTVarIO (foInstances (vOwner v))
  pure [Map.findWithDefault [] chunk built | chunk ← Set.toList (worldChunks world)]

releasedChunks ∷ FakeOwner → IO [ChunkRef]
releasedChunks = readTVarIO . foReleased
