{-# LANGUAGE MultiWayIf #-}
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

import Control.Concurrent (killThread, myThreadId, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (MaskingState (Unmasked), getMaskingState)
import Control.Concurrent.STM
import Data.Unique (newUnique)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import GHC.Conc (unsafeIOToSTM)
import Control.Exception (SomeException, displayException, evaluate, finally, throwIO, try)
import Control.Monad (forM, forM_, forever, join, unless, void, when)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as BC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Bits (testBit)
import Data.Int (Int64)
import Test.Support.Owned (withOwnedThread)
import Data.Word (Word32, Word64)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.LuaEngine.Graphics.Keeper (Keeper, keepWork, keeperHolding, withKeeper)
import Hetoimasia.LuaEngine.Graphics.Scene.Claims (SceneClaims, claimOf, newSceneClaims)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene (..), LedgerReading (..), initialGraphicsScene, ledgerAdopted, ledgerInterests, ledgerNewestAdopted, ledgerNewestTargets, ledgerReading, ledgerReleased, newSceneLedger)
import Hetoimasia.LuaEngine.Graphics.Scene.Publish (HostAnswer (..))
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView
import Hetoimasia.LuaEngine.Graphics.TerrainView.Qualification (pickViewWith, withAdoptedPlan)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (changesExpansion, changesExpansionBound, generationIdentity, knowledgeExpansionBound)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner (buildRegions, keepBuilt, releaseEach)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Service (planDemandHeld, planHeld)
import System.IO.Unsafe (unsafePerformIO)
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
import Hetoimasia.LuaEngine.Texture (RenderAccount, accountCharged, accountLimit, accountRelease, accountReserve, m1RenderAccountBytes)
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Snapshot (Camera (..), Instance, View (..))
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..))
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadState (UploadCancelled))
import Hetoimasia.GPU.Vulkan.GLFW (TextureHandle (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures (toBackendHandle)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (TextureRef (..))
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), MaterialRef, RecordLayout (..), defaultMaterial, materialFacts)
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord (..), axisFromInteger, axisValue, tileCoord)
import qualified Hetoimasia.Terrain.Render2D.Camera as Camera
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle, findSampleDirectory, loadAtlasStyle)
import qualified Hetoimasia.Terrain.Render2D.AtlasFixtures as Fixtures
import Hetoimasia.Terrain.Render2D.Cells (CellConfig (..), CellKey (..), CellPlan, PartKind (..), cellPlanDemand, cellPlanPending, cellPlanQuads, quadKey, quadPart)
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
import Hetoimasia.Terrain.Residency (Bank (StagingBank), Ledger (..), LimitsSpec (..), RegionDemand (..), RegionInfo (..), bankLedger, coverageBox, mkLimits, modelJobs, modelRegions)
import Hetoimasia.Terrain.Changes (changesBytes, changesFromIntervals)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
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
  , vMetrics ∷ !(TVar TargetMetrics)
    -- ^ What every test target draws at; an example changes it as a resize or a content-scale change would.
  , vTaking ∷ !(TVar Bool)
    -- ^ The session's admission the views are given: an example closes it as the session's end would.
  , vIssuer ∷ !TargetIssuer
    -- ^ The host identity the views' ports and every test target carry.
  , vKeeper ∷ !Keeper
    -- ^ The session's keeper, which outlives the views' scope.
  , vPorts ∷ !(TerrainViewsPorts Int)
    -- ^ The ports the views were made with, for an example that makes a further views scope in the same session.
  }

spec ∷ Spec
spec = describe "terrain views" $ do
  stages
  eviction
  reuse
  pickConsistency
  races
  lifecycle
  styles
  jumps
  hardening
  stagesAndReaders
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
      withOwnedThread (closeView view) $ \_ closing → do
        -- The handback publishes the initial content as a new revision, naming nothing.
        awaitRevision' v 1 (revision + 1)
        latest ← latestScene (vModel v) 1
        fmap graphicsWorld latest `shouldBe` Just Nothing
        bounded closing
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

  it "refuses a pick's removal once the target is revoked or resized while the same revision stays adopted" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      _ ← adoptNow (vModel v) 1
      revealAt v (8, 8, 3)
      quiescent v
      hit ← currentHit v view
      -- the target is revoked: the reference is stale, and the edit is not made
      setUsable (vModel v) 1 False
      removeWith v (pickRefCell hit) (Just (pickPrecondition view hit)) >>= (`shouldBe` Left Runtime.StaleView)
      setUsable (vModel v) 1 True
      -- the target is resized: the adopted revision is unchanged, but it was planned for the old metrics
      atomically (modifyTVar' (vMetrics v) (\m → m {metricsFramebuffer = PixelExtent 160 96}))
      removeWith v (pickRefCell hit) (Just (pickPrecondition view hit)) >>= (`shouldBe` Left Runtime.StaleView)
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
  it "refuses an attachment whose parent was released between its retention and the commit, taking no claim and no interest" $ do
    commits ← newCommitHold
    withViewsConfig testConfig {tvBeforeAttachCommit = holdCommit commits} $ \v → do
      first' ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 1))) >>= either (fail . show) pure
      _ ← bounded (awaitAttach first')
      -- The worker is held just before the second attachment's commit.
      armCommitHold commits
      modelWindow (vModel v) 2
      second ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= either (fail . show) pure
      awaitCommitHeld commits
      -- The instance releases the colour parent before the worker reaches the second commit.
      command (vComp v) (vVm v) "i" "release" "colour"
      _ ← awaitNoteContaining (vComp v) "i release colour"
      bounded (atomically (readFake (vFake v) >>= check . not . Set.null . readingMarkedNow))
      openCommitHold commits
      bounded (awaitAttach second) `shouldReturn` SettledRefused AttachParentReleased
      atomically (claimOf (vClaims v) 2) `shouldReturn` Nothing

  it "cancels a queued attachment: it settles cancelled once, takes no claim, and a late cancel changes nothing" $ do
    commits ← newCommitHold
    withViewsConfig testConfig {tvBeforeAttachCommit = holdCommit commits} $ \v → do
      -- The worker is held inside the first attachment, so the second stays queued.
      armCommitHold commits
      first' ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 1))) >>= either (fail . show) pure
      awaitCommitHeld commits
      modelWindow (vModel v) 2
      second ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= either (fail . show) pure
      cancelAttach (vViews v) second `shouldReturn` True
      cancelAttach (vViews v) second `shouldReturn` False
      openCommitHold commits
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
-- Stages, the owner's tickets and the copies

stages ∷ Spec
stages = describe "stages and the owner" $ do
  it "waits for room on the owner's queue instead of giving up a build, and builds once the queue drains, with no other event" $
    withViews $ \v → do
      atomically (writeTVar (foCapacity (vOwner v)) 0)
      view ← attached v 1
      bounded (atomically (readView view >>= check . readingWaiting))
      atomically (readView view) >>= (`shouldBe` Nothing) . readingPublished
      atomically (writeTVar (foCapacity (vOwner v)) 64)
      _ ← awaitPublished v 1
      atomically (terrainViewsFailures (vViews v)) `shouldReturn` []
      closeView view

  it "keeps retiring through a full owner queue: a release due while the queue is full is made once it drains, never abandoned" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      chunks ← Set.toList . worldChunks <$> latestWorld v 1
      atomically (writeTVar (foCapacity (vOwner v)) 0)
      closeView view
      -- the empty handback is adopted and the terrain revision's adoption released: the release is due, the queue full
      _ ← adoptNow (vModel v) 1
      _ ← releasePass (vModel v)
      -- every region is behind its met barrier, waiting only for room on the owner
      bounded . atomically $ do
        retiring ← terrainViewsRetiring (vViews v)
        check (Set.fromList chunks `Set.isSubsetOf` Set.fromList [chunk | (chunk, "met") ← retiring])
      atomically (terrainViewsFailures (vViews v)) `shouldReturn` []
      atomically (writeTVar (foCapacity (vOwner v)) 64)
      bounded (atomically (readTVar (foReleased (vOwner v)) >>= \done → check (Set.fromList chunks `Set.isSubsetOf` Set.fromList done)))
      atomically (terrainViewsFailures (vViews v)) `shouldReturn` []

  it "waits for room on a full release lane without asking again in a loop, while another view goes on" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      chunks ← Set.toList . worldChunks <$> latestWorld v 1
      modelWindow (vModel v) 2
      peer ← attached v 2
      _ ← awaitPublished v 2
      atomically (writeTVar (foLaneFull (vOwner v)) True)
      asked ← readTVarIO (foBarrierAsks (vOwner v))
      closeView view
      -- the peer publishes three more revisions while the lane stays full
      forM_ [1 .. 3 ∷ Int] $ \k → do
        now ← publishedRevision (vModel v) 2
        atomically (updateCamera peer (CameraIntent [Camera.Pan (if even k then 1 else -1) 0])) `shouldReturn` Right ()
        newer ← awaitPublished' v 2 (now + 1)
        adoptNow (vModel v) 2 `shouldReturn` Adopted newer
        void (releasePass (vModel v))
      readTVarIO (foBarrierAsks (vOwner v)) >>= (`shouldSatisfy` (<= asked + 1))
      atomically (writeTVar (foLaneFull (vOwner v)) False)
      _ ← adoptNow (vModel v) 1
      _ ← releasePass (vModel v)
      bounded (atomically (readTVar (foReleased (vOwner v)) >>= \done → check (Set.fromList chunks `Set.isSubsetOf` Set.fromList done)))
      closeView peer

  it "keeps a failed release as evidence once per region, never asks it again, and keeps its GPU bytes charged" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      chunks ← Set.toList . worldChunks <$> latestWorld v 1
      atomically (writeTVar (foReleaseFailure (vOwner v)) (Just "injected: the buffer could not be freed"))
      closeView view
      _ ← adoptNow (vModel v) 1
      _ ← releasePass (vModel v)
      let injected = length . filter (Text.isInfixOf "injected: the buffer could not be freed") <$> terrainViewsFailures (vViews v)
      bounded (atomically (injected >>= check . (== length chunks)))
      -- later work on the service asks nothing of them again
      modelWindow (vModel v) 2
      other ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= either (fail . show) pure >>= bounded . awaitAttach >>= \case
        SettledOk view' → pure view'
        other' → fail (show other')
      _ ← awaitPublished v 2
      atomically injected `shouldReturn` length chunks
      released ← releasedChunks (vOwner v)
      filter (`elem` chunks) released `shouldBe` []
      atomically (terrainViewsGpuCharged (vViews v)) >>= (`shouldSatisfy` (> 0))
      closeView other

  it "charges the facts it keeps for its camera and its kept demand for as long as it keeps them, after publication and after an abandoned preparation" $
    -- a granule of 64 bytes, so the account's charge follows the view's need closely
    withViewsConfig testConfig {tvAccountGranule = 64} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      let covered = do
            reading ← readView view
            demand ← viewDemand view
            pure (reading, maybe 0 (\(visible, prefetch) → length visible + length prefetch) demand)
      (published, demanded) ← atomically covered
      -- the facts are charged at their inputs' bytes (each region's, and its knowledge's expansion), and the demand at
      -- its coordinates
      readingFactsBytes published `shouldSatisfy` (>= 25872 * fromIntegral (readingAdmitted published))
      readingDemandBytes published `shouldSatisfy` (>= 32 * fromIntegral demanded)
      readingCpuBytes published `shouldSatisfy` (>= readingNeedBytes published)
      -- a superseded preparation held at the owner is abandoned: the facts it settled are still kept, and charged
      atomically (writeTVar (foGate (vOwner v)) False)
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (readTVar (foWaiting (vOwner v)) >>= check . (> 0)))
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (readView view >>= check . (== 0) . readingStagedBytes))
      abandoned ← atomically (readView view)
      readingFactsBytes abandoned `shouldSatisfy` (> 0)
      readingCpuBytes abandoned `shouldSatisfy` (>= readingNeedBytes abandoned)
      atomically (writeTVar (foGate (vOwner v)) True)
      closeView view

  it "keeps a failed release's description charged after the service's end, and says how much" $ do
    result ← newTVarIO Nothing
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      atomically (writeTVar (foReleaseFailure (vOwner v)) (Just "injected: the buffer could not be freed"))
      closeView view
      _ ← adoptNow (vModel v) 1
      _ ← releasePass (vModel v)
      bounded (atomically (terrainViewsFailures (vViews v) >>= check . any ("injected" `Text.isInfixOf`)))
      atomically (writeTVar result (Just (vViews v, _vAccount v)))
    Just (views, account) ← readTVarIO result
    failures ← atomically (terrainViewsFailures views)
    let kept = [read (Text.unpack (Text.takeWhile (/= ' ') (Text.drop (Text.length "failed releases keep ") f))) ∷ Integer | f ← failures, "failed releases keep " `Text.isPrefixOf` f]
    kept `shouldSatisfy` (\k → length k == 1 && all (> 0) k)
    charged ← atomically (accountCharged account)
    toInteger charged `shouldSatisfy` (>= sum kept)

  it "admits at most its cap of regions, leaving the rest of its visible demand pending, and its cost figures follow admission's obligations" $
    withViewsConfig testConfig {tvAdmitRegions = 4} $ \v → do
      tvAdmitRegions defaultTerrainViewsConfig `shouldBe` 2048
      -- the most: each region's knowledge of more than one class in every column with a run for each of its 32 levels
      -- (256 x (96 + 80 x 32) bytes), and the removal index at its most for one region occurrence, before the merged
      -- change limit is checked: an entry for each of its 256 columns and 16 runs in each (256 x 48 + 4096 x 16 bytes)
      knowledgeExpansionBound `shouldBe` 679936
      changesExpansionBound 1 `shouldBe` 77824
      let regions = tvAdmitRegions defaultTerrainViewsConfig
      admittedCostBound defaultTerrainViewsConfig
        `shouldBe` (uniformInputsCost regions + knowledgeExpansionBound * fromIntegral regions + changesExpansionBound regions)
      preparationCost defaultTerrainViewsConfig 1 `shouldSatisfy` (> uniformInputsCost 1 + knowledgeExpansionBound)
      -- terrain uniform per region and unedited: the default cap's copies and inputs fit the production bank
      uniformInputsCost regions `shouldSatisfy` (<= m1RenderAccountBytes)
      view ← attached v 1
      reading ← bounded . atomically $ readView view >>= \r → if readingUnadmitted r > 0 && readingStagedBytes r == 0 && readingPhase r == PhasePublished then pure r else retry
      readingAdmitted reading `shouldSatisfy` (\n → n > 0 && n <= 4)
      readingPendingRegions reading `shouldSatisfy` (> 0)
      -- at its cap there is nothing more to admit: it takes no more steps, and publishes nothing more
      quiescent v
      _ ← releasePass (vModel v)
      settled ← atomically (readView view)
      _ ← releasePass (vModel v)
      later ← atomically (readView view)
      (readingSteps later, readingPublished later) `shouldBe` (readingSteps settled, readingPublished settled)
      closeView view

  it "sleeps at its two-pin limit while its intent changes and a peer makes progress, then publishes once the host adopts" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      second ← awaitPublished' v 1 (first' + 1)
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (readView view >>= check . readingWaiting))
      steps ← readingSteps <$> atomically (readView view)
      -- newer intents, and a peer attached, published and moved, take none of its steps
      modelWindow (vModel v) 2
      peer ← attached v 2
      p1 ← awaitPublished v 2
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 0.5])) `shouldReturn` Right ()
      atomically (updateCamera peer (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      _ ← awaitPublished' v 2 (p1 + 1)
      readingSteps <$> atomically (readView view) `shouldReturn` steps
      publishedRevision (vModel v) 1 `shouldReturn` second
      -- the host adopts: a pin is free and it publishes
      adoptNow (vModel v) 1 `shouldReturn` Adopted second
      _ ← awaitPublished' v 1 (second + 1)
      closeView peer
      closeView view

  it "sleeps while its target has no metrics, however its peers move, and prepares once it has them" $ do
    metricsVar ← newTVarIO Nothing
    withViews $ \v → do
      let blind = (target v 1) {vtMetrics = readTVar metricsVar}
      view ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v blind)) >>= either (fail . show) pure >>= bounded . awaitAttach >>= \case
        SettledOk view' → pure view'
        _ → fail "the attachment did not succeed"
      bounded (atomically (readView view >>= check . (> 0) . readingSteps))
      steps ← readingSteps <$> atomically (readView view)
      modelWindow (vModel v) 2
      peer ← attached v 2
      _ ← awaitPublished v 2
      readingSteps <$> atomically (readView view) `shouldReturn` steps
      publishedRevision (vModel v) 1 `shouldReturn` 0
      atomically (readTVar (vMetrics v) >>= writeTVar metricsVar . Just)
      _ ← awaitPublished v 1
      closeView peer
      closeView view

  it "keeps an unpublished region's GPU bytes charged until its upload has ended and its release is answered" $
    withViews $ \v → do
      atomically (writeTVar (foHoldUploads (vOwner v)) True)
      view ← attached v 1
      bounded (atomically (readTVar (foStanding (vOwner v)) >>= check . elem ChunkUploading . Map.elems))
      fresh ← Map.keys <$> readTVarIO (foStanding (vOwner v))
      closeView view
      -- retirements go before any view's step: once another view has published, they have been tried
      atomically (writeTVar (foHoldUploads (vOwner v)) False)
      modelWindow (vModel v) 2
      peer ← attached v 2
      _ ← awaitPublished v 2
      charged ← atomically (terrainViewsGpuCharged (vViews v))
      releasedChunks (vOwner v) `shouldReturn` []
      -- the unpublished regions' uploads end: they are released, and only then are their bytes returned
      atomically (modifyTVar' (foStanding (vOwner v)) (\standings → foldr (Map.adjust (const ChunkReady)) standings fresh))
      bounded (atomically (readTVar (foReleased (vOwner v)) >>= \done → check (Set.fromList fresh `Set.isSubsetOf` Set.fromList done)))
      -- the fake records a release when its action runs; the service returns the bytes when it takes the answer, in the
      -- transaction that also takes the chunks off its retiring list: that is what is waited for
      bounded (atomically (terrainViewsRetiring (vViews v) >>= check . all ((`notElem` fresh) . fst)))
      atomically (terrainViewsGpuCharged (vViews v)) >>= (`shouldSatisfy` (< charged))
      closeView peer

  it "copies a viewport larger than the retained bank can reserve at once, one batch at a time" $
    withViewsTerrain HostFirst (\c → c {configRetainedBytes = 1024 * 1024}) loamOverGranite testConfig {tvCopyRegions = 1} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      reading ← atomically (readView view)
      readingRetainedRegions reading `shouldSatisfy` (> 0)
      atomically (terrainViewsFailures (vViews v)) `shouldReturn` []
      closeView view

  it "hands a copy in flight to cleanup when the worker is cancelled, so the terrain service's end is not held" $ do
    seam ← newStageSeam
    withViewsConfig testConfig {tvOnStage = seamHook seam} $ \v → do
      -- the second entry into copying has its first batch's request in flight
      armSeam seam 1 "copying" 2 SeamKill
      _ ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 1))) >>= either (fail . show) pure
      awaitSeamFired seam
    -- the whole scope, the terrain service's included, has ended: no borrow kept its drain waiting

  it "starts its copies again when an edit commits between two batches, and publishes the edited arena" $ do
    seam ← newStageSeam
    editDone ← newTVarIO False
    withViewsConfig testConfig {tvCopyRegions = 1, tvOnStage = seamHook seam} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      -- between the first batch's take and the second's request, an edit far from the view commits
      armSeamAfter seam 1 "copying" 2 (SeamRun (void (removeWith v (tileAt 300 300 3) Nothing) >> atomically (writeTVar editDone True)))
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (readTVar editDone >>= check))
      hit ← currentHit v view
      status ← Runtime.arenaStatus (_vTerrain v) (vArena v) >>= either (fail . show) pure
      pickContent (pickRefIdentity hit) `shouldBe` Runtime.statusContentRevision status
      atomically (readView view) >>= (`shouldSatisfy` (> 0)) . readingRestarts
      closeView view

  it "keeps publishing while an edit lands at every step of a panning camera: its copies start again, and publications keep up" $
    withViewsConfig testConfig {tvCopyRegions = 1} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      let tagNow = tagRevision . worldTag <$> latestWorld v 1
          steps = 8 ∷ Integer
      published0 ← publishedRevision (vModel v) 1
      attempts0 ← tagNow
      forM_ [1 .. steps] $ \k → do
        atomically (updateCamera view (CameraIntent [Camera.Pan (if even k then 1 else -1) 0])) `shouldReturn` Right ()
        _ ← removeWith v (tileAt (300 + k) 300 3) Nothing
        void (currentHit v view)
      published ← subtract published0 <$> publishedRevision (vModel v) 1
      attempts ← subtract attempts0 <$> tagNow
      published `shouldSatisfy` (>= fromIntegral steps)
      attempts `shouldSatisfy` (<= 3 * fromIntegral published)
      closeView view

  it "hands a close mid-copy to cleanup exactly once: the request in flight is cancelled and nothing is left" $ do
    seam ← newStageSeam
    opened ← newTVarIO False
    withViewsConfig testConfig {tvOnStage = seamHook seam} $ \v → do
      armSeam seam 1 "copying" 2 (SeamHold opened)
      view ← attached v 1
      awaitSeamFired seam
      withOwnedThread (closeView view) $ \_ closed → do
        bounded (atomically (viewClosing view >>= check))
        atomically (writeTVar opened True)
        bounded closed
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty
      -- the request that was in flight holds nothing of the terrain service any more
      bounded (atomically (Runtime.inspectRegionalSTM (_vTerrain v) >>= check . null))
      atomically (terrainViewsFailures (vViews v)) `shouldReturn` []

  it "hands a close mid-build to cleanup exactly once: the build in flight is collected when it answers, and released" $
    withViews $ \v → do
      atomically (writeTVar (foGate (vOwner v)) False)
      view ← attached v 1
      bounded (atomically (readTVar (foWaiting (vOwner v)) >>= check . (> 0)))
      closeView view
      atomically (writeTVar (foGate (vOwner v)) True)
      bounded (atomically (readTVar (foBuilt (vOwner v)) >>= check . (> 0)))
      built ← Map.keys <$> readTVarIO (foInstances (vOwner v))
      bounded (atomically (readTVar (foReleased (vOwner v)) >>= \done → check (Set.fromList built `Set.isSubsetOf` Set.fromList done)))
      bounded (atomically (terrainViewsGpuCharged (vViews v) >>= check . (== 0)))
      atomically (terrainViewsFailures (vViews v)) `shouldReturn` []

  it "hands a service stop mid-upload to cleanup exactly once: the regions are released once their uploads end" $ do
    ownerRef ← newTVarIO Nothing
    let endUploads = readTVarIO ownerRef >>= mapM_ (\owner → atomically (writeTVar (foHoldUploads owner) False >> modifyTVar' (foStanding owner) (Map.map (const ChunkReady))))
    result ← newTVarIO Nothing
    withViewsConfig testConfig {tvStopping = endUploads} $ \v → do
      atomically (writeTVar ownerRef (Just (vOwner v)))
      atomically (writeTVar (foHoldUploads (vOwner v)) True)
      _ ← attached v 1
      bounded (atomically (readTVar (foStanding (vOwner v)) >>= check . elem ChunkUploading . Map.elems))
      atomically (writeTVar result (Just (vOwner v, vViews v)))
    Just (owner, views) ← readTVarIO result
    built ← Map.keys <$> readTVarIO (foInstances owner)
    released ← releasedChunks owner
    Set.fromList built `shouldSatisfy` (`Set.isSubsetOf` Set.fromList released)
    atomically (terrainViewsGpuCharged views) `shouldReturn` 0

  forM_ ["requested", "reserved", "submitted", "answered", "abandoned"] $ \point →
    it ("hands everything on when its worker is cancelled between two transfers, after the one that " <> point <> ": every chunk built is released once and no GPU byte stays charged") $ do
      armed ← newTVarIO True
      ownerRef ← newTVarIO Nothing
      -- the worker is cancelled right after the named transfer's transaction, as a cancellation of its thread would
      let cancelAt _ name = when (name == Text.pack point) $ do
            fire ← atomically (readTVar armed <* writeTVar armed False)
            when fire (myThreadId >>= killThread)
          openGate = readTVarIO ownerRef >>= mapM_ (\owner → atomically (writeTVar (foGate owner) True))
      result ← newTVarIO Nothing
      withViewsConfig testConfig {tvOnTransfer = cancelAt, tvStopping = openGate} $ \v → do
        atomically (writeTVar ownerRef (Just (vOwner v)))
        when (point == "abandoned") (atomically (writeTVar (foGate (vOwner v)) False))
        view ← attached v 1
        -- a build in flight is superseded, so its stage is abandoned
        when (point == "abandoned") $ do
          bounded (atomically (readTVar (foWaiting (vOwner v)) >>= check . (> 0)))
          atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
        bounded (atomically (readTVar armed >>= check . not))
        atomically (writeTVar result (Just (vOwner v, vViews v)))
      Just (owner, views) ← readTVarIO result
      built ← Map.keys <$> readTVarIO (foInstances owner)
      released ← releasedChunks owner
      Set.fromList released `shouldBe` Set.fromList built
      length released `shouldBe` Set.size (Set.fromList released)
      atomically (terrainViewsGpuCharged views) `shouldReturn` 0

  it "retires the chunks a stopped build made, keeping their charges until their uploads end and their releases answer" $
    withViews $ \v → do
      let owner = vOwner v
      -- the build makes its first region, whose upload stays under way, then fails at the second
      atomically (writeTVar (foHoldUploads owner) True >> writeTVar (foStopAfter owner) (Just (1, False)))
      view ← attached v 1
      bounded (atomically (readTVar (foBuilt owner) >>= check . (>= 1)))
      first' ← bounded . atomically $ readTVar (foInstances owner) >>= maybe retry pure . fmap fst . Map.lookupMin
      bounded (atomically (terrainViewsFailures (vViews v) >>= check . any ("could not be built" `Text.isInfixOf`)))
      -- its upload has not ended: it is not released, and its bytes stay charged
      atomically (terrainViewsRetiring (vViews v)) >>= (`shouldSatisfy` elem first' . map fst)
      atomically (terrainViewsGpuCharged (vViews v)) >>= (`shouldSatisfy` (> 0))
      releasedChunks owner >>= (`shouldNotContain` [first'])
      -- once every upload ends it is released exactly once, and the view publishes from a later build
      atomically (writeTVar (foHoldUploads owner) False >> modifyTVar' (foStanding owner) (Map.map (const ChunkReady)))
      bounded (atomically (readTVar (foReleased owner) >>= check . elem first'))
      _ ← awaitPublished v 1
      released ← releasedChunks owner
      length (filter (== first') released) `shouldBe` 1
      closeView view

  it "serves another view's attachment and close while a view is held mid-plan" $ do
    seam ← newStageSeam
    opened ← newTVarIO False
    reopened ← newTVarIO False
    -- the holds open when the service stops, so a failing example still ends
    let openAll = atomically (writeTVar opened True >> writeTVar reopened True)
    withViewsConfig testConfig {tvStepsPerQuantum = 1, tvCellConfig = (viewCells 250), tvOnStage = seamHook seam, tvStopping = openAll} $ \v → do
      modelWindow (vModel v) 3
      third ← attached v 3
      _ ← awaitPublished v 3
      -- the long view (incarnation 2) is held as it enters its second planning quantum
      armSeam seam 2 "planning" 2 (SeamHold opened)
      long ← attached v 1
      awaitSeamFired seam
      -- an attachment and a close are asked for while it plans
      modelWindow (vModel v) 2
      asked ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= either (fail . show) pure
      withOwnedThread (closeView third) $ \_ closed → do
        bounded (atomically (viewClosing third >>= check))
        -- it may take one more quantum, then it is held again: whatever its plan still needs, the attachment and the
        -- close complete meanwhile, so neither waits for the plan
        atomically (writeTVar (ssFired seam) False)
        armSeam seam 2 "planning" 3 (SeamHold reopened)
        atomically (writeTVar opened True)
        settled ← bounded (awaitAttach asked)
        bounded closed
        atomically (writeTVar reopened True)
        case settled of
          SettledOk second → closeView second
          other → expectationFailure (show other)
      _ ← awaitPublished v 1
      closeView long

  it "charges a preparation's inputs before it plans: at its first quantum the view already holds them, as the facts it keeps" $ do
    seam ← newStageSeam
    opened ← newTVarIO False
    withViewsConfig testConfig {tvOnStage = seamHook seam, tvStopping = atomically (writeTVar opened True)} $ \v → do
      armSeam seam 1 "planning" 1 (SeamHold opened)
      view ← attached v 1
      awaitSeamFired seam
      reading ← atomically (readView view)
      -- at least one region's inputs, held as the kept facts' charge, before the planner has made anything
      readingFactsBytes reading `shouldSatisfy` (>= 25872)
      readingCpuBytes reading `shouldSatisfy` (>= readingStagedBytes reading + readingFactsBytes reading)
      atomically (writeTVar opened True)
      _ ← awaitPublished v 1
      closeView view

  it "waits in its plan, growing it no further, while the account cannot hold the next quantum's growth" $ do
    seam ← newStageSeam
    takenVar ← newTVarIO 0
    -- a fine granule, so the view holds no spare room of its own beside its need
    withViewsConfig testConfig {tvStepsPerQuantum = 1, tvAccountGranule = 64, tvOnStage = seamHook seam} $ \v → do
      -- once the copies and their inputs are admitted (with room for a quantum then), another consumer leaves the
      -- account a granule and a half: room for no quantum
      let squeeze = atomically $ do
            held ← accountCharged (_vAccount v)
            let room = accountLimit (_vAccount v) - held - 3 * 512 * 1024
            ok ← accountReserve (_vAccount v) room
            writeTVar takenVar (if ok then room else 0)
      armSeam seam 1 "planning" 1 (SeamRun squeeze)
      view ← attached v 1
      bounded (atomically (readView view >>= \r → check (readingWaiting r && readingPhase r == PhasePreparing)))
      atomically (seamCount seam 1 "planning") >>= (`shouldSatisfy` (<= 2))
      atomically (readView view) >>= (`shouldBe` Nothing) . readingPublished
      taken ← readTVarIO takenVar
      taken `shouldSatisfy` (> 0)
      atomically (accountRelease (_vAccount v) taken)
      _ ← awaitPublished v 1
      closeView view

  it "keeps a retiring region's CPU description charged after its view closes, until its release is answered" $
    withViews $ \v → do
      -- what the account holds beside the terrain service's own staging
      let besideTerrain = do
            charged ← accountCharged (_vAccount v)
            model ← Runtime.inspectModelSTM (_vTerrain v)
            let staging = bankLedger model StagingBank
            pure (charged - (ledgerOccupied staging + ledgerReserved staging))
      before' ← atomically besideTerrain
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      closeView view
      -- the adoption still lists the view's regions: their descriptions stay charged
      atomically besideTerrain >>= (`shouldSatisfy` (> before'))
      _ ← adoptNow (vModel v) 1
      _ ← releasePass (vModel v)
      bounded (atomically (besideTerrain >>= check . (== before')))

-- A seam over the views' stage entries: it counts each view's entries into each stage, and at one chosen entry holds
-- the worker until the example opens it, cancels the worker there, or runs an action there.
data StageSeam = StageSeam
  { ssCounts ∷ !(TVar (Map (Word64, Text.Text) Int))
  , ssArmed ∷ !(TVar (Maybe (Word64, Text.Text, Int, SeamAct)))
  , ssFired ∷ !(TVar Bool)
  }

data SeamAct = SeamHold !(TVar Bool) | SeamKill | SeamRun !(IO ())

newStageSeam ∷ IO StageSeam
newStageSeam = StageSeam <$> newTVarIO Map.empty <*> newTVarIO Nothing <*> newTVarIO False

seamHook ∷ StageSeam → Word64 → Text.Text → IO ()
seamHook seam view stage = do
  act ← atomically $ do
    modifyTVar' (ssCounts seam) (Map.insertWith (+) (view, stage) 1)
    count ← Map.findWithDefault 0 (view, stage) <$> readTVar (ssCounts seam)
    readTVar (ssArmed seam) >>= \case
      Just (v', s', n, a) | v' == view && s' == stage && n == count → Just a <$ (writeTVar (ssArmed seam) Nothing >> writeTVar (ssFired seam) True)
      _ → pure Nothing
  case act of
    Just (SeamHold opened) → atomically (readTVar opened >>= check)
    Just SeamKill → myThreadId >>= killThread
    Just (SeamRun action) → action
    Nothing → pure ()

armSeam ∷ StageSeam → Word64 → Text.Text → Int → SeamAct → IO ()
armSeam seam view stage n act = atomically (writeTVar (ssArmed seam) (Just (view, stage, n, act)))

-- Arm the seam at the view's n-th entry into the stage from now.
armSeamAfter ∷ StageSeam → Word64 → Text.Text → Int → SeamAct → IO ()
armSeamAfter seam view stage n act = atomically $ do
  now ← seamCount seam view stage
  writeTVar (ssArmed seam) (Just (view, stage, now + n, act))

awaitSeamFired ∷ StageSeam → IO ()
awaitSeamFired seam = bounded (atomically (readTVar (ssFired seam) >>= check))

seamCount ∷ StageSeam → Word64 → Text.Text → STM Int
seamCount seam view stage = Map.findWithDefault 0 (view, stage) <$> readTVar (ssCounts seam)

-- ---------------------------------------------------------------------------
-- Residency under the view's own camera demand: eviction and reload at the full region extent

eviction ∷ Spec
eviction = describe "eviction" $ do
  it "pans away, has an original region evicted by another holder's pressure, and back: it reloads, and the view publishes the same plan and picks again" $
    withViewsTerrain HostFirst tightTerrain stripes testConfig $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      demandResident v view
      hit ← currentHit v view
      plan ← adoptedPlanOf view
      picks ← atomically (picksOver view)
      instances ← drawnInstances v 1
      Just (firstVisible, _) ← atomically (viewDemand view)
      let original = Set.fromList firstVisible
      -- pan away three regions at a time until the view's demand no longer names any original region: they keep no
      -- interest and become the bank's candidates
      let away k = do
            now ← publishedRevision (vModel v) 1
            atomically (updateCamera view (CameraIntent [Camera.Pan 48 0])) `shouldReturn` Right ()
            newer ← awaitPublished' v 1 (now + 1)
            -- the host adopts each step, so the view's pins move on
            adoptNow (vModel v) 1 `shouldReturn` Adopted newer
            _ ← releasePass (vModel v)
            demandResident v view
            Just (visibleNow, prefetchNow) ← atomically (viewDemand view)
            if Set.null (Set.intersection original (Set.fromList (visibleNow <> prefetchNow))) || k >= 8 then pure k else away (k + 1)
      pans ← away (1 ∷ Int)
      Just (visibleAway, prefetchAway) ← atomically (viewDemand view)
      Set.intersection original (Set.fromList (visibleAway <> prefetchAway)) `shouldBe` Set.empty
      -- another holder presses the bank with batches of regions far away, each batch replacing the last, until a region
      -- of the view's first demand, named by its coordinate, has been evicted
      other ← Runtime.openView (_vTerrain v) (vClient v) >>= either (fail . show) pure
      let press k
            | k > 40 = pure Set.empty
            | otherwise = do
                let batch = [RegionCoord (200 + 4 * k + i) j (-1) | i ← [0 .. 3], j ← [0, 1]]
                demands ← either (fail . show) pure (traverse (\r → RegionDemand r <$> coverageBox 0 16 0 16 0 32) batch)
                _ ← Runtime.setViewDemand (_vTerrain v) other (vArena v) demands >>= either (fail . show) pure
                bounded . atomically $ Runtime.inspectModelSTM (_vTerrain v) >>= \model →
                  check (all (`elem` map regionCoord (modelRegions model)) batch)
                -- the loads move the residency generation and the view publishes again; the host adopts what it
                -- publishes, as a presenting host does (a view keeps at most two revisions pinned)
                _ ← adoptNow (vModel v) 1
                _ ← releasePass (vModel v)
                gone ← Set.difference original <$> residentRegions v
                if Set.null gone then press (k + 1) else pure gone
      evicted ← press (0 ∷ Int64)
      evicted `shouldSatisfy` (not . Set.null)
      Runtime.closeView (_vTerrain v) other
      quiescent v
      _ ← currentHit v view
      -- back to the first camera: the evicted regions load again under the view's own demand
      back ← publishedRevision (vModel v) 1
      atomically (updateCamera view (CameraIntent [Camera.Pan (-48 * fromIntegral pans) 0])) `shouldReturn` Right ()
      returned ← awaitPublished' v 1 (back + 1)
      adoptNow (vModel v) 1 `shouldReturn` Adopted returned
      _ ← releasePass (vModel v)
      bounded (atomically (Runtime.inspectModelSTM (_vTerrain v) >>= \model → check (original `Set.isSubsetOf` Set.fromList (map regionCoord (modelRegions model)))))
      again ← currentHit v view
      -- the residency generation moved, and the view caught up with it; what it draws and picks is what it was
      pickResidency (pickRefIdentity again) `shouldNotBe` pickResidency (pickRefIdentity hit)
      replanned ← adoptedPlanOf view
      cellMembership replanned `shouldBe` cellMembership plan
      atomically (picksOver view) `shouldReturn` picks
      drawnInstances v 1 `shouldReturn` instances
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
    withViewsOn pillarOverPlain testConfig {tvCellConfig = (viewCells 250)} $ \v → do
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

  it "follows a surface above the band it first copied: the surface's regions are copied in the next round, and the camera lands on it" $
    withViewsOn pillarOverPlain testConfig {tvCellConfig = (viewCells 250)} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      -- the pillar's top is level 99, three regions above the anchor's band at level 3: following adopts it
      camera ← atomically (viewCameraState view)
      fmap axisValue (Camera.camSurface camera) `shouldBe` Just 99
      axisValue (Camera.camClip camera) `shouldSatisfy` (> 99)
      closeView view

  it "asks a build refused as upload pressure again once an upload settles, with no new intent, adoption or account change" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      quiescent v
      demandResident v view
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      _ ← releasePass (vModel v)
      -- an upload is under way and holds the staging buffer: every build is refused as pressure while it is
      atomically (setUploads (vOwner v) [7] >> writeTVar (foPressured (vOwner v)) True)
      built ← readTVarIO (foBuilt (vOwner v))
      -- an edit in view rebuilds its region, the camera unchanged
      removeWith v (tileAt 9 9 3) Nothing `shouldReturn` Right True
      quiescent v
      bounded (atomically (readView view >>= \r → check (readingWaiting r && readingStagedBytes r == 0)))
      readTVarIO (foBuilt (vOwner v)) `shouldReturn` built
      publishedRevision (vModel v) 1 `shouldReturn` first'
      -- it sleeps while the upload is under way
      steps ← readingSteps <$> atomically (readView view)
      _ ← releasePass (vModel v)
      readingSteps <$> atomically (readView view) `shouldReturn` steps
      -- the upload settles: nothing else changes, and the build is asked again and published
      atomically (setUploads (vOwner v) [])
      _ ← awaitPublished' v 1 (first' + 1)
      closeView view

  it "keeps an upload that failed as evidence and the previous revision published" $ do
    ownerRef ← newTVarIO Nothing
    -- the held uploads end when the service stops, so a failing example still ends
    let endUploads = readTVarIO ownerRef >>= mapM_ (\owner → atomically (writeTVar (foHoldUploads owner) False >> modifyTVar' (foStanding owner) (Map.map (\s' → if s' == ChunkUploading then ChunkReady else s'))))
    withViewsConfig testConfig {tvStopping = endUploads} $ \v → do
      atomically (writeTVar ownerRef (Just (vOwner v)))
      view ← attached v 1
      first' ← awaitPublished v 1
      previous ← latestWorld v 1
      -- the next build's uploads stay under way; then one of them fails
      atomically (writeTVar (foHoldUploads (vOwner v)) True)
      built ← readTVarIO (foBuilt (vOwner v))
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (readTVar (foBuilt (vOwner v)) >>= check . (> built)))
      -- one of the new chunks' uploads fails, the others complete; a later build's uploads stay under way
      failing ← bounded . atomically $ readTVar (foStanding (vOwner v)) >>= maybe retry (pure . fst) . Map.lookupMin . Map.filter (== ChunkUploading)
      atomically (modifyTVar' (foStanding (vOwner v)) (Map.mapWithKey (\k s' → if k == failing then ChunkFailed UploadCancelled else if s' == ChunkUploading then ChunkReady else s')))
      bounded (atomically (terrainViewsFailures (vViews v) >>= check . any ("upload failed" `Text.isInfixOf`)))
      publishedRevision (vModel v) 1 `shouldReturn` first'
      worldTag <$> latestWorld v 1 `shouldReturn` worldTag previous
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
      original ← adoptedPlanOf view
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
      replanned ← adoptedPlanOf fresh
      let membership = cellMembership original
      cellMembership replanned `shouldBe` membership
      -- the revealed cavity leaves ordinary, fog and mixed cells in the view (19, 10 and 2 with this source)
      [length [() | kind ← Map.elems membership, kind == wanted] | wanted ← [PartOrdinary, PartFog, PartKnown]] `shouldSatisfy` all (> 0)
      atomically (picksOver fresh) `shouldReturn` originalPicks
      drawnInstances v 2 `shouldReturn` originalInstances
      closeView fresh

  it "refuses an attachment whose arena lease is released between its early checks and its commit, taking nothing" $ do
    seam ← newTVarIO (pure ())
    withViewsConfig testConfig {tvBeforeAttachCommit = join (atomically (readTVar seam <* writeTVar seam (pure ())))} $ \v → do
      atomically (writeTVar seam (void (Runtime.releaseLease (_vTerrain v) (vArena v))))
      attachOutcome v (target v 1) >>= (`shouldSatisfy` \case SettledRefused (AttachArena _) → True; _ → False)
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty

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
    commits ← newCommitHold
    queued ← newTVarIO Nothing
    withViewsConfig testConfig {tvBeforeAttachCommit = holdCommit commits, tvStopping = openCommitHold commits} $ \v → do
      first' ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 1))) >>= either (fail . show) pure
      _ ← bounded (awaitAttach first')
      -- the worker is held inside a second attachment while a third is queued and the scope ends
      armCommitHold commits
      modelWindow (vModel v) 3
      _ ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 3))) >>= either (fail . show) pure
      awaitCommitHeld commits
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
    hostModel ← newTVarIO Nothing
    -- the host adopts whatever is published and releases what that supersedes, for as long as the example runs, the
    -- views' scope exit included
    let step = forever $ do
          model ← atomically (readTVar hostModel >>= maybe retry pure)
          atomically (modelCapture model >>= id >>= check . not)
          _ ← adoptNow model 1
          releasePass model
    (views, owner, claims) ← withOwnedThread step $ \_ _ → withViewsOrdered ViewsFirst loamOverGranite testConfig $ \v → do
      _ ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      atomically (writeTVar hostModel (Just (vModel v)))
      pure (vViews v, vOwner v, vClaims v)
    atomically (terrainViewsFailures views) `shouldReturn` []
    built ← Map.keys <$> readTVarIO (foInstances owner)
    released ← releasedChunks owner
    Set.fromList released `shouldBe` Set.fromList built
    atomically (claimOf claims 1) `shouldReturn` Nothing

  it "rethrows a cancellation of its worker instead of recording it: the worker ends, attachments stop, and every view is closed" $ do
    armed ← newTVarIO False
    -- the next stage the worker enters cancels it there, as a cancellation of the worker's thread would
    let cancelAt _ stage = when (stage == "planning") $ do
          fire ← atomically (readTVar armed <* writeTVar armed False)
          when fire (myThreadId >>= killThread)
    (views, claims) ← withViewsConfig testConfig {tvOnStage = cancelAt} $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      quiescent v
      atomically (writeTVar armed True)
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      -- the worker took the cancellation at the next plan
      bounded (atomically (readTVar armed >>= check . not))
      modelWindow (vModel v) 2
      settled ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= \case
        Left refusal → pure (SettledRefused refusal)
        Right attaching → bounded (awaitAttach attaching)
      settled `shouldSatisfy` \case SettledRefused AttachStopped → True; _ → False
      -- the worker's end closed the view: its claim handed back with a real empty revision after the one it published
      bounded (atomically (viewClosed view >>= check))
      publishedRevision (vModel v) 1 `shouldReturn` (first' + 1)
      atomically (terrainViewsFailures (vViews v)) `shouldReturn` []
      pure (vViews v, vClaims v)
    atomically (claimOf claims 1) `shouldReturn` Nothing
    atomically (terrainViewsFailures views) `shouldReturn` []

  it "closes a live view when its worker is cancelled, so a close from the body returns and the scope exits" $ do
    armed ← newTVarIO False
    let cancelAt _ stage = when (stage == "planning") $ do
          fire ← atomically (readTVar armed <* writeTVar armed False)
          when fire (myThreadId >>= killThread)
    withViewsConfig testConfig {tvOnStage = cancelAt} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      atomically (writeTVar armed True)
      atomically (updateCamera view (CameraIntent [Camera.ZoomBy 2])) `shouldReturn` Right ()
      bounded (atomically (readTVar armed >>= check . not))
      -- the worker is gone: the close is answered all the same
      bounded (closeView view)
      atomically (viewClosed view) `shouldReturn` True
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing

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
  it "lands a far jump on a quiescent arena with no other camera or terrain event, and publishes the destination" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      -- nothing more will happen on its own: the view's demand is resident, no load is in flight, and the view has
      -- published for the arena as it now is
      demandResident v view
      bounded (atomically (Runtime.inspectModelSTM (_vTerrain v) >>= check . null . modelJobs))
      first' ← currentHit v view >> publishedRevision (vModel v) 1
      axis ← pure (either (error . show) id . axisFromInteger)
      -- the destination's facts are held by no copy the view has: its demand must be asked for and prepared
      far ← atomically (jumpView view (JumpRequest (axis 4000, axis 4000) Nothing)) >>= either (fail . show) pure
      bounded (atomically (jumpSettled far >>= maybe retry pure)) `shouldReturn` SettledOk JumpLanded
      newer ← awaitPublished' v 1 (first' + 1)
      adoptNow (vModel v) 1 `shouldReturn` Adopted newer
      hit ← currentHit v view
      let cell = pickRefCell hit
      (abs (axisValue (tileX cell) - 4000) <= 4, abs (axisValue (tileY cell) - 4000) <= 4) `shouldBe` (True, True)
      closeView view

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
-- Wakes, ownership and limits

hardening ∷ Spec
hardening = describe "wakes, ownership and limits" $ do
  it "asks a build refused as upload pressure again when an upload that started after its submission settles before its wait" $ do
    armed ← newTVarIO Nothing
    -- right after the pressured build's answer is read, before the view installs its wait, the upload settles
    let settleAt _ name = when (name == "answered") . atomically $
          readTVar armed >>= mapM_ (\owner → setUploads owner [] >> writeTVar armed Nothing)
    withViewsConfig testConfig {tvOnTransfer = settleAt} $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      quiescent v
      demandResident v view
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      _ ← releasePass (vModel v)
      let owner = vOwner v
      atomically (setUploads owner [7] >> writeTVar (foPressured owner) True)
      -- an edit in view rebuilds its region, the camera unchanged; its build is refused as pressure, and it waits once
      -- the terrain service is quiet, so nothing but an upload can change what it waits on
      removeWith v (tileAt 9 9 3) Nothing `shouldReturn` Right True
      quiescent v
      bounded (atomically (Runtime.inspectModelSTM (_vTerrain v) >>= check . null . modelJobs))
      bounded (atomically (readView view >>= \r → check (readingWaiting r && readingStagedBytes r == 0)))
      -- that upload settles: the build is asked again, submitted with no upload under way, and waits at the owner
      atomically (writeTVar (foGate owner) False >> setUploads owner [])
      bounded (atomically (readTVar (foWaiting owner) >>= check . (> 0)))
      -- an upload starts after the submission, the build is refused as pressure, and that upload settles before the
      -- wait: an upload settled since the submission, so the build is asked again
      atomically (setUploads owner [8] >> writeTVar armed (Just owner) >> writeTVar (foGate owner) True)
      _ ← awaitPublished' v 1 (first' + 1)
      isNothing <$> readTVarIO armed `shouldReturn` True
      closeView view

  it "waits on a copy the account cannot hold without asking again, until another consumer releases room" $
    withViews $ \v → do
      taken ← atomically $ do
        held ← accountCharged (_vAccount v)
        let room = accountLimit (_vAccount v) - held - 64
        ok ← accountReserve (_vAccount v) room
        pure (if ok then room else 0)
      taken `shouldSatisfy` (> 0)
      view ← attached v 1
      bounded (atomically (Runtime.inspectModelSTM (_vTerrain v) >>= check . null . modelJobs))
      bounded (atomically (readView view >>= check . readingWaiting))
      steps ← readingSteps <$> atomically (readView view)
      -- the worker serves another attachment meanwhile (refused: the target is claimed), and takes no step of this
      -- view: its copy's own release is not a change it waits for
      attachOutcome v (target v 1) >>= (`shouldSatisfy` \case SettledRefused AttachTargetClaimed → True; _ → False)
      readingSteps <$> atomically (readView view) `shouldReturn` steps
      atomically (accountRelease (_vAccount v) taken)
      _ ← awaitPublished v 1
      closeView view

  it "waits on a copy refused for the terrain service's retained bank, and copies once another caller's request settles to its footprint while it keeps the borrow" $ do
    gate ← newTVarIO False
    armed ← newTVarIO False
    held ← newTVarIO False
    -- once armed, the terrain service's owner waits before its next commit: another caller's request holds its whole
    -- reservation until the example lets it settle
    let probe = Runtime.Probe $ \case
          Runtime.PointBeforeCommit _ → do
            first' ← atomically (readTVar armed <* writeTVar armed False)
            when first' $ do
              atomically (writeTVar held True)
              atomically (readTVar gate >>= check)
          _ → pure ()
        -- room for two pending one-region reservations' worth less a byte: while the other caller's request holds its
        -- reservation, no copy of the view's fits; once it settles to its footprint, one does
        reservation = Runtime.regionSnapshotReservation 1 + 160
        bank = 2 * reservation - 1
    withViewsProbed HostFirst probe (\c → c {configRetainedBytes = bank}) loamOverGranite testConfig {tvCopyRegions = 1} $ \v → do
      atomically (writeTVar armed True)
      other ← Runtime.requestRegionSnapshot (_vTerrain v) (vArena v) [RegionCoord 0 0 0] >>= either (fail . show) pure
      bounded (atomically (readTVar held >>= check))
      view ← attached v 1
      bounded (atomically (readView view >>= check . readingWaiting))
      atomically (readView view) >>= (`shouldBe` Nothing) . readingPublished
      -- the other request settles and keeps its borrow: only the retained bank moves, and the view copies and publishes
      atomically (writeTVar gate True)
      borrow ← Runtime.await (_vTerrain v) other >>= either (fail . show) pure
      -- the borrow goes back on every exit: a borrower that never returns would keep the terrain service's end waiting
      (`finally` Runtime.releaseRegionBorrow (_vTerrain v) borrow) $ do
        _ ← awaitPublished v 1
        closeView view

  it "takes and releases a copy that settles between an abandoning close's probe and its cancellation, leaving the terrain service nothing" $ do
    gate ← newTVarIO False
    armed ← newTVarIO False
    held ← newTVarIO False
    terrainRef ← newTVarIO Nothing
    cancelled ← newTVarIO False
    -- once armed, the terrain service's owner waits before its next commit (the view's first copy's settlement): the
    -- copy stays unsettled until the example lets it go
    let probe = Runtime.Probe $ \case
          Runtime.PointBeforeCommit _ → do
            first' ← atomically (readTVar armed <* writeTVar armed False)
            when first' $ do
              atomically (writeTVar held True)
              atomically (readTVar gate >>= check)
          _ → pure ()
        -- the close's cleanup found the copy unsettled: it settles now, before the cancellation (a bounded wait that
        -- needs no asynchronous exception, since the cleanup runs uninterruptibly)
        atCancel 0 "cancelling" = do
          atomically (writeTVar gate True)
          deadline ← registerDelay 20000000
          settled ← readTVarIO terrainRef >>= \case
            Nothing → pure False
            Just terrain →
              atomically $
                (True <$ (Runtime.inspectRegionalSTM terrain >>= check . (\cs → not (null cs) && all (isJust . Runtime.regionalChargeFootprint) cs)))
                  `orElse` (False <$ (readTVar deadline >>= check))
          atomically (writeTVar cancelled settled)
        atCancel _ _ = pure ()
    withViewsProbed HostFirst probe id loamOverGranite testConfig {tvOnTransfer = atCancel} $ \v → do
      atomically (writeTVar terrainRef (Just (_vTerrain v)) >> writeTVar armed True)
      view ← attached v 1
      bounded (atomically (readTVar held >>= check))
      bounded (closeView view)
      readTVarIO cancelled `shouldReturn` True
      bounded (atomically (Runtime.inspectRegionalSTM (_vTerrain v) >>= check . null))
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing

  it "hands what only the host can still prove to the session's keeper at its scope's exit: the scope returns, and the keeper releases the chunks once the host can" $
    withViews $ \v → do
      let owner = vOwner v
      modelWindow (vModel v) 2
      -- a further views scope in the same session: its view publishes, then closes with the release lane held
      (inner, view) ← withTerrainViews testConfig (vPorts v) $ \views → do
        view ← inInstance (vComp v) (vVm v) "i" (attachView views (requestFor v (target v 2))) >>= either (fail . show) pure >>= bounded . awaitAttach >>= \case
          SettledOk view' → pure view'
          _ → fail "the attachment did not succeed"
        _ ← awaitPublished v 2
        atomically (writeTVar (foLaneFull owner) True)
        bounded (closeView view)
        pure (views, view)
      -- the scope returned with its retirements unproved: the keeper holds them, still charged; the view's own CPU
      -- dependencies went with its close
      atomically (keeperHolding (vKeeper v)) `shouldReturn` 1
      atomically (terrainViewsGpuCharged inner) >>= (`shouldSatisfy` (> 0))
      atomically (viewHoldsStyle view) `shouldReturn` False
      -- the host can prove them once its lane has room and the window's target has gone
      atomically (writeTVar (foLaneFull owner) False)
      removeWindow (vModel v) 2
      bounded (atomically (keeperHolding (vKeeper v) >>= check . (== 0)))
      atomically (terrainViewsGpuCharged inner) `shouldReturn` 0

  it "cancels and collects an abandoned copy however the hook before its cancellation ends, leaving the terrain service no regional charge" $ do
    gate ← newTVarIO False
    armed ← newTVarIO False
    held ← newTVarIO False
    -- once armed, the terrain service's owner waits before its next commit: the view's first copy stays unsettled
    let probe = Runtime.Probe $ \case
          Runtime.PointBeforeCommit _ → do
            first' ← atomically (readTVar armed <* writeTVar armed False)
            when first' $ do
              atomically (writeTVar held True)
              atomically (readTVar gate >>= check)
          _ → pure ()
        -- the hook before the cancellation raises
        atCancel 0 "cancelling" = throwIO (userError "the cancelling hook raised")
        atCancel _ _ = pure ()
    withViewsProbed HostFirst probe id loamOverGranite testConfig {tvOnTransfer = atCancel} $ \v → (`finally` atomically (writeTVar gate True)) $ do
      atomically (writeTVar armed True)
      view ← attached v 1
      bounded (atomically (readTVar held >>= check))
      -- the close records the hook's failure and still ends, with its one result
      outcome ← try (bounded (closeView view))
      case outcome of
        Left (TerrainViewCloseFailed why) → why `shouldSatisfy` ("the cancelling hook raised" `Text.isInfixOf`)
        Right () → expectationFailure "the close reported no failure"
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      -- the copy was cancelled (or, settled, released): once the owner goes on, nothing regional is left
      atomically (writeTVar gate True)
      bounded (atomically (Runtime.inspectRegionalSTM (_vTerrain v) >>= check . null))

  it "keeps the claim, and the chunks and interests of the scene still shown, when the empty publication raises, and gives every close waiter the same failure" $
    withViews $ \v → do
      armed ← newTVarIO False
      let base = target v 1
          raising = base {vtPublish = \scene → readTVar armed >>= \raise → if raise then throwSTM (userError "the empty publication raised") else vtPublish base scene}
      view ← attachOutcome v raising >>= \case
        SettledOk view' → pure view'
        _ → fail "the attachment did not succeed"
      _ ← awaitPublished v 1
      quiescent v
      atomically (writeTVar armed True)
      withOwnedThread (void (try (closeView view) ∷ IO (Either TerrainViewCloseFailed ()))) $ \_ otherDone → do
        first' ← try (bounded (closeView view))
        bounded otherDone
        second' ← try (closeView view)
        case (first', second') of
          (Left (TerrainViewCloseFailed a), Left (TerrainViewCloseFailed b)) → do
            a `shouldBe` b
            a `shouldSatisfy` ("could not be handed back" `Text.isInfixOf`)
          _ → expectationFailure "a close waiter did not read the failure"
      -- the target's claim and the shown scene's interests and chunks stay, as evidence
      atomically (claimOf (vClaims v) 1) >>= (`shouldSatisfy` isJust)
      atomically (ledgerInterests (fakeLedger (vFake v))) >>= (`shouldSatisfy` (not . null))
      atomically (terrainViewsUnhanded (vViews v)) >>= (`shouldSatisfy` ((== 1) . length))
      -- what did not depend on the handback went: the demand, the parents' CPU coverage
      atomically (viewDemand view) `shouldReturn` Nothing
      atomically (viewHoldsStyle view) `shouldReturn` False

  it "closes the runtime view an attachment opened when it is cancelled before its commit, so its slot is free at once" $
    withViewsTerrain HostFirst (\c → c {configMaxViews = 1}) loamOverGranite testConfig {tvBeforeAttachCommit = myThreadId >>= killThread} $ \v → do
      outcome ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 1))) >>= either (fail . show) pure >>= bounded . awaitAttach
      outcome `shouldSatisfy` \case SettledRefused AttachStopped → True; _ → False
      runtimeView ← Runtime.openView (_vTerrain v) (vClient v) >>= either (fail . show) pure
      Runtime.closeView (_vTerrain v) runtimeView
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty

  it "closes a view whose worker is cancelled between the close's handback and its end, so a close from the body returns" $ do
    seam ← newStageSeam
    withViewsConfig testConfig {tvOnTransfer = seamHook seam} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      armSeam seam (viewIncarnation view) "closed" 1 SeamKill
      bounded (closeView view)
      awaitSeamFired seam
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (viewHoldsStyle view) `shouldReturn` False

  it "retires the chunk a build made before its builder raised, keeping its charges until its upload ends and its release answers" $
    withViews $ \v → do
      let owner = vOwner v
      atomically (writeTVar (foHoldUploads owner) True >> writeTVar (foRaiseAt owner) (Just 1))
      view ← attached v 1
      bounded (atomically (terrainViewsFailures (vViews v) >>= check . any ("raised" `Text.isInfixOf`)))
      first' ← bounded . atomically $ readTVar (foInstances owner) >>= maybe retry pure . fmap fst . Map.lookupMin
      atomically (terrainViewsRetiring (vViews v)) >>= (`shouldSatisfy` elem first' . map fst)
      atomically (terrainViewsGpuCharged (vViews v)) >>= (`shouldSatisfy` (> 0))
      releasedChunks owner >>= (`shouldNotContain` [first'])
      atomically (writeTVar (foHoldUploads owner) False >> modifyTVar' (foStanding owner) (Map.map (const ChunkReady)))
      bounded (atomically (readTVar (foReleased owner) >>= check . elem first'))
      _ ← awaitPublished v 1
      released ← releasedChunks owner
      length (filter (== first') released) `shouldBe` 1
      closeView view

  it "answers a build whose action ended without answering with the chunks it recorded, for the caller to retire" $ do
    built ← newTVarIO []
    let ticket = keepBuilt built (pure (Just (NotRun "the action raised")))
    atomically ticket `shouldReturn` Just (NotRun "the action raised")
    atomically (writeTVar built [chunkRef 2 1, chunkRef 1 1])
    atomically ticket >>= \case
      Just (Answered (Left (BuildFailed chunks _))) → chunks `shouldBe` [chunkRef 1 1, chunkRef 2 1]
      other → expectationFailure ("the recorded chunks were not answered: " <> show other)

  it "never accepts a candidate whose records exceed the renderer's storage window: a region that never fits is a typed refusal, a larger whole waits, and a window that holds it publishes" $ do
    -- a target large enough for its plan's records to span several render regions
    let windowed bytes body = withViews $ \v → do
          atomically (writeTVar (foRegionWindow (vOwner v)) bytes >> writeTVar (vMetrics v) (TargetMetrics (PixelExtent 1024 768) (PixelExtent 1024 768) 1 1))
          view ← attached v 1
          body v view
        -- the view's outcome: its refusal, or a publication when the window held the candidate
        refusalOf view =
          bounded . atomically $
            (readView view >>= maybe retry (pure . Right) . readingWindow)
              `orElse` (readView view >>= maybe retry (pure . Left) . readingPublished)
        expectRefusal view = refusalOf view >>= \case
          Right refusal → pure refusal
          Left revision → expectationFailure ("the candidate was published (revision " <> show revision <> ")") >> fail "unreachable"
    -- a window too small for any region: the largest region's records are a typed refusal; nothing is built or published
    unitBytes ← windowed 17 $ \v view → do
      refusal ← expectRefusal view
      publishedRevision (vModel v) 1 `shouldReturn` 0
      readTVarIO (foBuilt (vOwner v)) `shouldReturn` 0
      closeView view
      case refusal of
        UnitExceedsWindow _ bytes window → (window `shouldBe` 17) >> pure bytes
        other → expectationFailure ("not a region's refusal: " <> show other) >> fail "unreachable"
    -- a window that holds the largest region alone but not the whole: it waits, and says what the whole needs
    need ← windowed unitBytes $ \v view → do
      refusal ← expectRefusal view
      publishedRevision (vModel v) 1 `shouldReturn` 0
      closeView view
      case refusal of
        EnvelopeExceedsWindow needed window → (window `shouldBe` unitBytes) >> pure needed
        other → expectationFailure ("not the whole's wait: " <> show other) >> fail "unreachable"
    need `shouldSatisfy` (> unitBytes)
    -- the control: a window that holds the whole publishes it
    windowed need $ \v view → do
      _ ← awaitPublished v 1
      atomically (readView view) >>= (`shouldBe` Nothing) . readingWindow
      closeView view

  it "refuses a style whose mapping gives no region to a material of the arena's palette, before taking anything" $
    withViews $ \v → do
      let request = requestFor v (target v 1)
          kept = take 1 (Fixtures.styleMaterialIds (vStyle v))
          partial = request {attachStyle = (attachStyle request) {styleMaterials = kept}}
      outcome ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) partial) >>= \case
        Left refusal → pure (SettledRefused refusal)
        Right attaching → bounded (awaitAttach attaching)
      case outcome of
        SettledRefused (AttachStyle (StyleMissingMaterials missing)) → do
          missing `shouldSatisfy` (not . null)
          [material | material ← missing, material `elem` map fst kept] `shouldBe` []
        SettledRefused other → expectationFailure ("refused otherwise: " <> Text.unpack (describeAttachRefusal other))
        _ → expectationFailure "the attachment was not refused"
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty

  it "refuses a configuration beyond its hard maxima before its worker starts, and takes the maxima and smaller settings" $ do
    let mib = 1024 * 1024
        refused config = withViewsConfig config (\_ → expectationFailure "the service was made") `shouldThrow` \(TerrainViewsRefused _) → True
    terrainViewsLimits `shouldBe` (8, 2, 128 * mib, 128 * mib)
    refused testConfig {tvMaxViews = 9}
    refused testConfig {tvCpuPins = 3}
    refused testConfig {tvGpuBytes = 128 * mib + 1}
    -- the one injected render account: at its maximum it is taken, one byte beyond it is not
    terrainViewsRefusal testConfig (128 * mib) `shouldBe` Nothing
    terrainViewsRefusal testConfig (128 * mib + 1) `shouldSatisfy` isJust
    -- the maxima themselves (the suite's own configuration and account), and smaller settings, zero GPU bytes included
    (tvMaxViews testConfig, tvCpuPins testConfig, tvGpuBytes testConfig) `shouldBe` (8, 2, 128 * mib)
    withViewsConfig testConfig (\v → attached v 1 >>= closeView)
    withViewsConfig testConfig {tvMaxViews = 1, tvCpuPins = 1, tvGpuBytes = 0} (\_ → pure ())

  it "refuses a target another host issued, before taking anything, the caller's style parents included" $
    withViews $ \v → do
      foreign' ← TargetIssuer <$> newUnique
      let request = requestFor v ((target v 1) {vtIssuer = foreign'})
      outcome ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) request)
      either (`shouldBe` AttachTargetForeign) (const (expectationFailure "a foreign target was taken")) outcome
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty
      -- the same request with this host's target is taken
      view ← attached v 1
      closeView view

  it "refuses an attachment through another client's lease on the same arena, before taking anything" $
    withViews $ \v → do
      other ← Runtime.registerClient (_vTerrain v) >>= either (fail . show) pure
      lease ← Runtime.attachArena (_vTerrain v) other "views" >>= either (fail . show) pure >>= Runtime.await (_vTerrain v) >>= either (fail . show) pure
      let request = (requestFor v (target v 1)) {attachArena = lease}
      outcome ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) request) >>= either (fail . show) pure >>= bounded . awaitAttach
      outcome `shouldSatisfy` \case SettledRefused (AttachArena _) → True; _ → False
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (ledgerInterests (fakeLedger (vFake v))) `shouldReturn` mempty

  it "closes an idle view whose arena lease is revoked, handing its target back, with no close or new intent" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      _ ← Runtime.releaseLease (_vTerrain v) (vArena v)
      bounded (atomically (viewClosed view >>= check))
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (terrainViewsFailures (vViews v)) >>= (`shouldSatisfy` any ("arena authority" `Text.isInfixOf`))

  it "closes an idle view whose target incarnation ends, with no close or new intent, publishing nothing to it" $
    withViews $ \v → do
      view ← attached v 1
      published ← awaitPublished v 1
      quiescent v
      setUsable (vModel v) 1 False
      bounded (atomically (viewClosed view >>= check))
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      publishedRevision (vModel v) 1 `shouldReturn` published

  it "cancels a jump only through the view it belongs to: another view's handle changes nothing" $
    withViews $ \v → do
      modelWindow (vModel v) 2
      a ← attached v 1
      b ← attached v 2
      _ ← awaitPublished v 1
      _ ← awaitPublished v 2
      axis ← pure (either (error . show) id . axisFromInteger)
      jumpA ← atomically (jumpView a (JumpRequest (axis 4000, axis 4000) Nothing)) >>= either (fail . show) pure
      jumpB ← atomically (jumpView b (JumpRequest (axis 4100, axis 4100) Nothing)) >>= either (fail . show) pure
      atomically (cancelJumpView b jumpA) `shouldReturn` False
      atomically (jumpSettled jumpA) >>= (`shouldNotBe` Just SettledCancelled)
      bounded (atomically (jumpSettled jumpA >>= maybe retry pure)) `shouldReturn` SettledOk JumpLanded
      bounded (atomically (jumpSettled jumpB >>= maybe retry pure)) `shouldReturn` SettledOk JumpLanded
      closeView a
      closeView b

  it "charges each pinned plan for its own demand, beside its quads and its pending spans" $
    withViews $ \v → do
      view ← attached v 1
      published ← awaitPublished v 1
      quiescent v
      demandResident v view
      adoptNow (vModel v) 1 `shouldReturn` Adopted published
      plan ← adoptedPlanOf view
      reading ← atomically (readView view)
      readingPins reading `shouldBe` 1
      planDemandHeld (cellPlanDemand plan) `shouldSatisfy` (> 0)
      readingPinnedBytes reading `shouldBe` planHeld (length (cellPlanQuads plan)) (length (cellPlanPending plan)) + planDemandHeld (cellPlanDemand plan)
      closeView view

  it "keeps no style or demand reachable through a closed view's handle" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      atomically (viewHoldsStyle view) `shouldReturn` True
      atomically (viewDemand view) >>= (`shouldSatisfy` isJust)
      closeView view
      atomically (viewHoldsStyle view) `shouldReturn` False
      atomically (viewDemand view) `shouldReturn` Nothing

  it "keeps no newest-adoption entry for a target once its last adoption is released, and makes one again on a later adoption" $ do
    ledger ← newSceneLedger
    forM_ [1 .. 20 ∷ Int] $ \window → ledgerAdopted ledger window 1 initialGraphicsScene
    atomically (ledgerNewestTargets ledger) `shouldReturn` 20
    forM_ [1 .. 20 ∷ Int] $ \window → ledgerReleased ledger window 1
    atomically (ledgerNewestTargets ledger) `shouldReturn` 0
    atomically (ledgerNewestAdopted ledger 3) `shouldReturn` Nothing
    ledgerAdopted ledger 3 2 initialGraphicsScene
    atomically (fmap fst <$> ledgerNewestAdopted ledger 3) `shouldReturn` Just 2

-- ---------------------------------------------------------------------------
-- Stages, waits and readers

stagesAndReaders ∷ Spec
stagesAndReaders = describe "stages, waits and readers" $ do
  it "closes a view whose arena lease is revoked while its uploads are held, handing its target back" $
    withViews $ \v → do
      let owner = vOwner v
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      demandResident v view
      -- the held uploads end on every exit, so a failure is reported rather than holding the scope's end
      let endUploads = atomically (writeTVar (foHoldUploads owner) False >> modifyTVar' (foStanding owner) (Map.map (const ChunkReady)))
      (`finally` endUploads) $ do
        atomically (writeTVar (foHoldUploads owner) True)
        -- an edit's rebuild is built and its uploads held: the view waits in its uploading stage
        removeWith v (tileAt 9 9 3) Nothing `shouldReturn` Right True
        bounded (atomically (readTVar (foStanding owner) >>= check . elem ChunkUploading . Map.elems))
        _ ← Runtime.releaseLease (_vTerrain v) (vArena v)
        bounded (atomically (viewClosed view >>= check))
        atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
        atomically (terrainViewsFailures (vViews v)) >>= (`shouldSatisfy` any ("arena authority" `Text.isInfixOf`))

  it "keeps two views that cannot fund their first copies asleep until room returns, however each other's copies come and go" $
    withViews $ \v → do
      taken ← atomically $ do
        held ← accountCharged (_vAccount v)
        let room = accountLimit (_vAccount v) - held - 64
        ok ← accountReserve (_vAccount v) room
        pure (if ok then room else 0)
      taken `shouldSatisfy` (> 0)
      modelWindow (vModel v) 2
      a ← attached v 1
      b ← attached v 2
      bounded (atomically (Runtime.inspectModelSTM (_vTerrain v) >>= check . null . modelJobs))
      bounded (atomically ((&&) <$> (readingWaiting <$> readView a) <*> (readingWaiting <$> readView b) >>= check))
      let stepsOf = atomically ((,) <$> (readingSteps <$> readView a) <*> (readingSteps <$> readView b))
      stepsBefore ← stepsOf
      -- the worker serves another attachment meanwhile (refused: the target is claimed), and takes no step of either
      attachOutcome v (target v 1) >>= (`shouldSatisfy` \case SettledRefused AttachTargetClaimed → True; _ → False)
      stepsOf `shouldReturn` stepsBefore
      atomically (accountRelease (_vAccount v) taken)
      _ ← awaitPublished v 1
      _ ← awaitPublished v 2
      closeView a
      closeView b

  it "charges the planner's expanded knowledge of its copied regions with their inputs" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      bounded (atomically (readView view >>= check . (== 0) . readingStagedBytes))
      reading ← atomically (readView view)
      -- each copied region's fixed inputs, and more for a region whose knowledge is more than one class
      readingFactsBytes reading `shouldSatisfy` (> 25872 * fromIntegral (readingAdmitted reading))
      closeView view

  it "keeps a plan read under the view's reader pinned, charged and counted against its pin limit until the reader lets go" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      _ ← releasePass (vModel v)
      quiescent v
      demandResident v view
      inside ← newEmptyMVar
      gate ← newEmptyMVar
      withOwnedThread (withAdoptedPlan view (\plan → putMVar inside (isJust plan) >> takeMVar gate)) $ \_ readerDone → do
        takeMVar inside `shouldReturn` True
        -- an edit publishes a second revision, which the host adopts: the first stays pinned and charged, being read
        removeWith v (tileAt 9 9 3) Nothing `shouldReturn` Right True
        second ← awaitPublished' v 1 (first' + 1)
        adoptNow (vModel v) 1 `shouldReturn` Adopted second
        _ ← releasePass (vModel v)
        bounded (atomically (readView view >>= check . (== 2) . readingPins))
        -- a third revision would need a third pin: it waits while the reader holds the first
        removeWith v (tileAt 10 9 3) Nothing `shouldReturn` Right True
        bounded (atomically (readView view >>= check . readingWaiting))
        publishedRevision (vModel v) 1 `shouldReturn` second
        putMVar gate ()
        bounded readerDone
        _ ← awaitPublished' v 1 (second + 1)
        pure ()
      closeView view

  it "records a zoom and a facing asked for before its first facts, and publishes its first revision with them" $ do
    seam ← newStageSeam
    opened ← newTVarIO False
    withViewsConfig testConfig {tvOnStage = seamHook seam} $ \v → do
      armSeam seam 1 "copying" 1 (SeamHold opened)
      view ← attached v 1
      awaitSeamFired seam
      -- the held copy goes on on every exit, so a failure is reported rather than holding the scope's end
      (`finally` atomically (writeTVar opened True)) $ do
        atomically (updateCamera view (CameraIntent [Camera.SetZoom 2])) `shouldReturn` Right ()
        atomically (updateCamera view (CameraIntent [Camera.SetFacing FaceEast])) `shouldReturn` Right ()
        -- a pan follows the surface: it waits for the facts
        atomically (updateCamera view (CameraIntent [Camera.Pan 1 0])) `shouldReturn` Left IntentBusy
      _ ← awaitPublished v 1
      world ← latestWorld v 1
      cameraZoom (viewCamera (worldView world)) `shouldBe` 2
      Camera.camFacing <$> atomically (viewCameraState view) `shouldReturn` FaceEast
      closeView view

  it "keeps a plan read across its view's close, with its pin, its charge and its style, until the reader lets go, and hands the target back at once" $
    withViews $ \v → do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      _ ← releasePass (vModel v)
      quiescent v
      inside ← newEmptyMVar
      gate ← newEmptyMVar
      withOwnedThread (withAdoptedPlan view (\plan → putMVar inside (isJust plan) >> takeMVar gate)) $ \_ readerDone → do
        takeMVar inside `shouldReturn` True
        (`finally` void (tryPutMVar gate ())) $ do
          bounded (closeView view)
          atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
          -- the read plan's pin, its bytes and the parents its coverage reads stay while it is read
          reading ← atomically (readView view)
          readingPins reading `shouldBe` 1
          readingPinnedBytes reading `shouldSatisfy` (> 0)
          atomically (viewHoldsStyle view) `shouldReturn` True
          -- a reader cannot start on a closed view
          withAdoptedPlan view (pure . isJust) `shouldReturn` False
        bounded readerDone
      reading ← atomically (readView view)
      readingPins reading `shouldBe` 0
      atomically (viewHoldsStyle view) `shouldReturn` False

  it "wakes a preparation waiting on its pins when one reader starts as another ends, with no adoption between" $ do
    armed ← newTVarIO False
    held ← newTVarIO False
    opened ← newTVarIO False
    -- the worker is held inside another view's close, once armed, so both readers change before it looks again
    let holdAt _ name = when (name == "closed") $ do
          holding ← atomically (readTVar armed <* writeTVar armed False)
          when holding $ atomically (writeTVar held True) >> atomically (readTVar opened >>= check)
    withViewsConfig testConfig {tvOnTransfer = holdAt} $ \v → (`finally` atomically (writeTVar opened True)) $ do
      view ← attached v 1
      first' ← awaitPublished v 1
      adoptNow (vModel v) 1 `shouldReturn` Adopted first'
      _ ← releasePass (vModel v)
      quiescent v
      demandResident v view
      insideA ← newEmptyMVar
      gateA ← newEmptyMVar
      withOwnedThread (withAdoptedPlan view (\_ → putMVar insideA () >> takeMVar gateA)) $ \_ readerADone → (`finally` void (tryPutMVar gateA ())) $ do
        takeMVar insideA
        removeWith v (tileAt 9 9 3) Nothing `shouldReturn` Right True
        second ← awaitPublished' v 1 (first' + 1)
        adoptNow (vModel v) 1 `shouldReturn` Adopted second
        _ ← releasePass (vModel v)
        bounded (atomically (readView view >>= check . (== 2) . readingPins))
        -- a third revision needs a third pin: it waits while reader A holds the first
        removeWith v (tileAt 10 9 3) Nothing `shouldReturn` Right True
        bounded (atomically (readView view >>= check . readingWaiting))
        modelWindow (vModel v) 2
        other ← attached v 2
        _ ← awaitPublished v 2
        atomically (writeTVar armed True)
        withOwnedThread (closeView other) $ \_ otherClosed → do
          bounded (atomically (readTVar held >>= check))
          -- reader B starts on the adopted second revision and reader A ends: the readers' total and the adoption are
          -- what they were, but the first revision's pin can now go
          insideB ← newEmptyMVar
          gateB ← newEmptyMVar
          withOwnedThread (withAdoptedPlan view (\_ → putMVar insideB () >> takeMVar gateB)) $ \_ readerBDone → (`finally` void (tryPutMVar gateB ())) $ do
            takeMVar insideB
            putMVar gateA ()
            bounded readerADone
            atomically (writeTVar opened True)
            bounded otherClosed
            _ ← awaitPublished' v 1 (second + 1)
            putMVar gateB ()
            bounded readerBDone
      closeView view

  it "closes every view and hands its target back once the session's admission closes, while the scope's body runs on" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      atomically (writeTVar (vTaking v) False)
      bounded (atomically (viewClosed view >>= check))
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (viewHoldsStyle view) `shouldReturn` False
      modelWindow (vModel v) 2
      outcome ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2)))
      either (`shouldBe` AttachStopped) (const (expectationFailure "an attachment was taken after the admission closed")) outcome

  it "ends every view while the scope's body runs once the graphics owner ends, with the session admission open, a build waiting for room" $
    withViews $ \v → do
      let owner = vOwner v
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      demandResident v view
      -- the owner's action queue is full: an edit's rebuild waits for room, with no ticket
      atomically (writeTVar (foCapacity owner) 0)
      removeWith v (tileAt 9 9 3) Nothing `shouldReturn` Right True
      bounded (atomically (readView view >>= check . readingWaiting))
      -- the owner ends; the session still takes work
      atomically (readTVar (vTaking v)) `shouldReturn` True
      atomically (writeTVar (foEnded owner) True)
      bounded (atomically (viewClosed view >>= check))
      atomically (claimOf (vClaims v) 1) `shouldReturn` Nothing
      atomically (viewHoldsStyle view) `shouldReturn` False
      -- what the owner can no longer prove is kept as evidence; no attachment is taken any more
      bounded (atomically (terrainViewsRetiring (vViews v) >>= check . null))
      modelWindow (vModel v) 2
      outcome ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2)))
      case outcome of
        Left AttachStopped → pure ()
        Right attaching → bounded (awaitAttach attaching) >>= \case
          SettledRefused AttachStopped → pure ()
          _ → expectationFailure "an attachment was taken after the owner ended"
        Left other → expectationFailure ("an attachment was refused for another reason: " <> show other)

  it "closes a view before the attachments queued behind it, however many there are" $ do
    commits ← newCommitHold
    order ← newIORef ([] ∷ [Text.Text])
    let note event = atomicModifyIORef' order (\seen → (seen <> [event], ()))
        noteClose _ name = when (name == "closed") (note "close")
    withViewsConfig testConfig {tvBeforeAttachCommit = holdCommit commits, tvOnTransfer = noteClose} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      -- the worker is held inside an attachment to a second window while requests for the first queue behind it
      armCommitHold commits
      modelWindow (vModel v) 2
      second ← inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v (target v 2))) >>= either (fail . show) pure
      awaitCommitHeld commits
      let noted = (target v 1) {vtUsable = unsafeIOToSTM (note "attach") >> vtUsable (target v 1)}
      queued ← forM [1 .. 3 ∷ Int] $ \_ → inInstance (vComp v) (vVm v) "i" (attachView (vViews v) (requestFor v noted)) >>= either (fail . show) pure
      withOwnedThread (closeView view) $ \_ closed → do
        bounded (atomically (viewClosing view >>= check))
        openCommitHold commits
        bounded closed
      settled ← mapM (bounded . awaitAttach) (second : queued)
      take 1 <$> readIORef order `shouldReturn` ["close"]
      forM_ settled $ \case
        SettledOk opened' → closeView opened'
        _ → pure ()

  it "joins its worker and ends its views however its stopping hook ends, raising the hook's failure after" $ do
    stopped ← newTVarIO Nothing
    let raising = throwIO (userError "the stopping hook raised")
    outcome ← try . withViewsConfig testConfig {tvStopping = raising} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      atomically (writeTVar stopped (Just (view, vViews v)))
    case outcome of
      Left (failure ∷ SomeException) → displayException failure `shouldContain` "the stopping hook raised"
      Right () → expectationFailure "the stopping hook's failure was not raised"
    Just (view, views) ← readTVarIO stopped
    -- the scope's end ran the service's end before it raised: the view is closed and its regions retired
    atomically (viewClosed view) `shouldReturn` True
    atomically (terrainViewsRetiring views) `shouldReturn` []

  it "completes a close that fails at the service's end: the view leaves the service closed and its parents are released" $ do
    armed ← newTVarIO False
    kept ← newTVarIO Nothing
    -- the only close of the view is the service's end's: it waits at its seam until the stopping hook (run by the
    -- scope's release, after the service took no more work) has armed the failure, so the two meet in one order
    let raiseAt _ name = when (name == "closed") $ do
          atomically (readTVar armed >>= check)
          throwIO (userError "the close's seam raised")
    withViewsConfig testConfig {tvOnTransfer = raiseAt, tvStopping = atomically (writeTVar armed True)} $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      atomically (writeTVar kept (Just (view, vViews v)))
    Just (view, views) ← readTVarIO kept
    atomically (viewClosed view) `shouldReturn` True
    atomically (viewHoldsStyle view) `shouldReturn` False
    atomically (terrainViewsFailures views) >>= (`shouldSatisfy` any ("the close's hook failed after its main step" `Text.isInfixOf`))
    atomically (viewCloseOutcome view) >>= (`shouldSatisfy` \case Just (CloseFailed _) → True; _ → False)

  it "charges the removal index its copies' removed intervals make, at the index's own figures, before making it" $
    withViews $ \v → do
      -- fragmented removals: cells in several columns, and separated cells in one column (a cell already air removes
      -- nothing, so the example counts those that did)
      removals ← forM ([tileAt x 9 3 | x ← [9 .. 14]] <> [tileAt 9 9 z | z ← [5, 7]]) $ \tile → removeWith v tile Nothing
      length (filter (== Right True) removals) `shouldSatisfy` (>= 3)
      request ← Runtime.requestRegionSnapshot (_vTerrain v) (vArena v) [RegionCoord 0 0 0] >>= either (fail . show) pure
      borrow ← Runtime.await (_vTerrain v) request >>= either (fail . show) pure
      -- the copy is read while it is borrowed, and let go however the checks end
      charged ← (`finally` Runtime.releaseRegionBorrow (_vTerrain v) borrow) $ do
        let snapshot = Runtime.regionBorrowSnapshot borrow
            removed = [interval | region ← Runtime.regionSnapshotRegions snapshot, Runtime.PartReady intervals ← [Runtime.regionTerrain snapshot region], interval ← intervals]
            charged' = changesExpansion snapshot
        index ← either (fail . show) pure (changesFromIntervals (tvChangeLimits testConfig) removed)
        changesBytes index `shouldSatisfy` (>= 3 * 64)
        charged' `shouldSatisfy` (>= fromIntegral (changesBytes index))
        pure charged'
      -- a view whose copies hold those removals is charged for the index beside each region's fixed inputs
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      bounded (atomically (readView view >>= check . (== 0) . readingStagedBytes))
      reading ← atomically (readView view)
      readingFactsBytes reading `shouldSatisfy` (>= 25872 * fromIntegral (readingAdmitted reading) + charged)
      closeView view

  it "charges a removed run crossing two regions once in each of their copies, within both advertised bounds" $
    withViews $ \v → do
      -- one removed run from level -1 to level 0: regions z = -1 and z = 0 each clip it
      forM_ [tileAt 9 9 (-1), tileAt 9 9 0] $ \tile → removeWith v tile Nothing `shouldReturn` Right True
      charges ← forM [RegionCoord 0 0 (-1), RegionCoord 0 0 0] $ \region → do
        request ← Runtime.requestRegionSnapshot (_vTerrain v) (vArena v) [region] >>= either (fail . show) pure
        borrow ← Runtime.await (_vTerrain v) request >>= either (fail . show) pure
        (`finally` Runtime.releaseRegionBorrow (_vTerrain v) borrow) $ do
          let snapshot = Runtime.regionBorrowSnapshot borrow
              removed = [interval | r ← Runtime.regionSnapshotRegions snapshot, Runtime.PartReady intervals ← [Runtime.regionTerrain snapshot r], interval ← intervals]
          length removed `shouldBe` 1
          pure $! changesExpansion snapshot
      -- before coalescing each copy charges its clipped interval: 64 bytes each, 128 in all, where the merged index (a
      -- limit of one interval takes it) would be 64
      charges `shouldBe` [64, 64]
      sum charges `shouldSatisfy` (<= changesExpansionBound 2)
      admittedInputsCost testConfig 2 `shouldSatisfy` (>= uniformInputsCost 2 + sum charges)
      preparationCost testConfig 2 `shouldSatisfy` (>= admittedInputsCost testConfig 2)

  it "makes and forces a pick while its adopted plan is read: no field of a kept result is evaluated after the pin goes" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      quiescent v
      _ ← adoptNow (vModel v) 1
      _ ← releasePass (vModel v)
      let points = [(x + 0.5, y + 0.5) | y ← [0, 4 .. 92], x ← [0, 4 .. 124]]
      point ← bounded . atomically $ do
        results ← mapM (\p → (p,) <$> pickView view p) points
        case [p | (p, PickHit _) ← results] of
          p : _ → pure p
          [] → retry
      inside ← newIORef True
      seen ← newIORef ([] ∷ [Bool])
      let mark ∷ ∀ a. a → a
          mark x = unsafePerformIO $ do
            _ ← evaluate x
            readIORef inside >>= \now → atomicModifyIORef' seen (\marks → (now : marks, ()))
            pure x
      result ← atomically (pickViewWith mark view point)
      writeIORef inside False
      closeView view
      -- whatever is left of the kept result is evaluated now, after the pin has gone
      length (show result) `shouldSatisfy` (> 0)
      marks ← readIORef seen
      marks `shouldSatisfy` (not . null)
      marks `shouldSatisfy` and

  it "answers each chunk of a release on its own: a raise is that chunk's failure, and the chunks after it are released" $ do
    released ← newIORef ([] ∷ [ChunkRef])
    let releaseOne chunk
          | chunk == chunkRef 2 1 = throwIO (userError "the release raised")
          | otherwise = Right () <$ atomicModifyIORef' released (\seen → (seen <> [chunk], ()))
    outcomes ← releaseEach releaseOne [chunkRef 1 1, chunkRef 2 1, chunkRef 3 1]
    map (either (const False) (const True)) outcomes `shouldBe` [True, False, True]
    readIORef released `shouldReturn` [chunkRef 1 1, chunkRef 3 1]

  it "takes a manual pan asked before its first facts, and publishes its first revision with the slice and the pan" $ do
    let axis = either (error . show) id . axisFromInteger
    seam ← newStageSeam
    opened ← newTVarIO False
    withViewsConfig testConfig {tvOnStage = seamHook seam} $ \v → do
      armSeam seam 1 "copying" 1 (SeamHold opened)
      view ← attached v 1
      awaitSeamFired seam
      before' ← atomically (viewCameraState view)
      (`finally` atomically (writeTVar opened True)) $ do
        -- a slice makes the camera manual: its pan follows nothing, so it needs no facts; an invalid pan is refused
        atomically (updateCamera view (CameraIntent [Camera.SelectSlice (axis 5), Camera.Pan 3 0])) `shouldReturn` Right ()
        atomically (updateCamera view (CameraIntent [Camera.Pan (0 / 0) 0])) >>= (`shouldSatisfy` either (const True) (const False))
      _ ← awaitPublished v 1
      after' ← atomically (viewCameraState view)
      Camera.camMode after' `shouldBe` Camera.Manual (axis 5)
      axisValue (Camera.camAnchorX after') `shouldBe` axisValue (Camera.camAnchorX before') + 3
      closeView view

  it "never wakes its worker for another holder's loads while its views wait mid-stage: the selection watches no terrain state" $ do
    evaluations ← newIORef (0 ∷ Int)
    withViews $ \v → do
      let owner = vOwner v
          -- the target's retirement cell is read once a view each time the worker's selection is evaluated, so this
          -- counts the evaluations, woken or re-run
          counted = (target v 1) {vtRetired = unsafeIOToSTM (atomicModifyIORef' evaluations (\n → (n + 1, ()))) >> vtRetired (target v 1)}
      view ← attachOutcome v counted >>= \case
        SettledOk view' → pure view'
        _ → fail "the attachment did not succeed"
      _ ← awaitPublished v 1
      quiescent v
      demandResident v view
      -- an edit's rebuild waits at the owner: the view is mid-stage, its build in flight (let go on every exit)
      (`finally` atomically (writeTVar (foGate owner) True)) $ do
        atomically (writeTVar (foGate owner) False)
        removeWith v (tileAt 9 9 3) Nothing `shouldReturn` Right True
        bounded (atomically (readTVar (foWaiting owner) >>= check . (> 0)))
        quiescent v
        bounded (atomically (Runtime.inspectModelSTM (_vTerrain v) >>= check . null . modelJobs))
        before' ← readIORef evaluations
        -- another holder copies ten distant regions, one at a time: every request writes the terrain service's state
        bounded . forM_ [1 .. 10 ∷ Int] $ \i → do
          request ← Runtime.requestRegionSnapshot (_vTerrain v) (vArena v) [RegionCoord (40 + fromIntegral i) 40 0] >>= either (fail . show) pure
          Runtime.await (_vTerrain v) request >>= either (fail . show) (Runtime.releaseRegionBorrow (_vTerrain v))
        afterLoads ← readIORef evaluations
        (afterLoads - before') `shouldSatisfy` (<= 2)
      closeView view

  it "answers no hit for a point outside the target before any adoption and after a resize, not loading" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      -- nothing adopted yet: inside is loading, outside is no hit
      atomically (pickView view (10, 10)) `shouldReturn` PickLoading
      atomically (pickView view (500, 500)) `shouldReturn` PickNoHit
      atomically (pickView view (-1, 10)) `shouldReturn` PickNoHit
      -- a resize: the adopted plan is for the old metrics, so inside is loading and outside the new bounds is no hit
      atomically (modifyTVar' (vMetrics v) (\m → m {metricsLogical = PixelExtent 64 48, metricsFramebuffer = PixelExtent 64 48}))
      atomically (pickView view (100, 80)) `shouldReturn` PickNoHit
      atomically (pickView view (10, 10)) `shouldReturn` PickLoading
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
withViewsTerrain order = withViewsProbed order noProbe

-- The rig over a terrain service whose owner reports its points to this probe.
withViewsProbed ∷ EndOrder → Runtime.Probe → (Config → Config) → SourceSpec → TerrainViewsConfig → (Views → IO a) → IO a
withViewsProbed order probe terrainConfig source config body = do
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
        withTerrainProbed probe terrainConfig source (cpAccount comp) $ \terrain client arena → do
          claims ← newSceneClaims
          metricsVar ← newTVarIO metrics
          taking ← newTVarIO True
          issuer ← TargetIssuer <$> newUnique
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
                  , portTaking = readTVar taking
                  , portIssuer = issuer
                  }
          -- the session's keeper runs while the fake owner does, and outlives the views' scope
          withOwnedThread (fakeOwnerLoop owner) $ \_ _ → withKeeper $ \keeper → do
            let ports' = ports {portOwner = (portOwner ports) {ownerKeep = keepWork keeper}}
                run' views = body (Views comp vm fake model terrain arena views owner claims (cpAccount comp) style colourKey normalKey client metricsVar taking issuer keeper ports')
            result ← case order of
              HostFirst → withTerrainViews config ports' (\views → run' views `finally` dissolve model)
              ViewsFirst → withTerrainViews config ports' run' `finally` dissolve model
            -- the session lives on until its keeper has done what the views handed it
            bounded (atomically (keeperHolding keeper >>= check . (== 0)))
            pure result

-- Small enough for a quick example: a 128 x 96 target and a 30-level band, which reaches the surface below the followed
-- camera's 25 levels of headroom.
-- The views' own cell configuration (their step bound included) with this band depth.
viewCells ∷ Integer → CellConfig
viewCells depth = (tvCellConfig defaultTerrainViewsConfig) {ccDepth = depth}

testConfig ∷ TerrainViewsConfig
testConfig = defaultTerrainViewsConfig {tvCellConfig = (viewCells 30)}

metrics ∷ TargetMetrics
metrics = TargetMetrics (PixelExtent 128 96) (PixelExtent 128 96) 1 1

-- A seam that holds the worker just before an attachment's commit, once armed, until the example opens it.
data CommitHold = CommitHold !(TVar Bool) !(TVar Bool) !(TVar Bool)

newCommitHold ∷ IO CommitHold
newCommitHold = CommitHold <$> newTVarIO False <*> newTVarIO False <*> newTVarIO False

holdCommit ∷ CommitHold → IO ()
holdCommit (CommitHold armed held opened) = do
  holding ← atomically (readTVar armed <* writeTVar armed False)
  when holding $ do
    atomically (writeTVar held True)
    atomically (readTVar opened >>= check)

armCommitHold ∷ CommitHold → IO ()
armCommitHold (CommitHold armed _ _) = atomically (writeTVar armed True)

awaitCommitHeld ∷ CommitHold → IO ()
awaitCommitHeld (CommitHold _ held _) = bounded (atomically (readTVar held >>= check))

openCommitHold ∷ CommitHold → IO ()
openCommitHold (CommitHold _ _ opened) = atomically (writeTVar opened True)

-- The scene host model's window as a view target.
target ∷ Views → Int → ViewTarget Int
target v window =
  let (publishing, usable) = modelTarget (vModel v) window
   in ViewTarget
        { vtKey = window
        , vtIssuer = vIssuer v
        , vtUsable = usable
        , vtRetired = not <$> usable
        , vtPublish = \scene → (== HostAccepted) <$> publishing scene
        , vtDepth = True
        , vtMetrics = Just <$> readTVar (vMetrics v)
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
withTerrainProbed ∷ Runtime.Probe → (Config → Config) → SourceSpec → RenderAccount → (Service → Runtime.Client → ArenaLease → IO a) → IO a
withTerrainProbed probe terrainConfig source account body =
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
      withTerrainService config (Ports alwaysAdmitting (standaloneSupervisor group) quiet probe (storagePort group storage directory)) $ \terrain → do
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
-- when asked; its barrier is the scene host model's own. Its actions are queued and run by its own thread, as the host's
-- owner runs them, so the adapter's worker only ever reads their tickets.
data FakeOwner = FakeOwner
  { foModel ∷ !Model
  , foNext ∷ !(TVar Word32)
  , foStanding ∷ !(TVar (Map ChunkRef ChunkStanding))
  , foReleased ∷ !(TVar [ChunkRef])
  , foBuilt ∷ !(TVar Int)
  , foGate ∷ !(TVar Bool)
    -- ^ While closed, a build waits at the owner: the build stays in flight.
  , foWaiting ∷ !(TVar Int)
    -- ^ Builds waiting at the closed gate.
  , foFailure ∷ !(TVar (Maybe Text.Text))
    -- ^ While set, a build fails with this reason, as the owner's would.
  , foInstances ∷ !(TVar (Map ChunkRef [Instance]))
    -- ^ What each chunk was built from.
  , foHoldUploads ∷ !(TVar Bool)
    -- ^ While set, a new chunk's upload stays under way until the example completes it.
  , foEnded ∷ !(TVar Bool)
    -- ^ Once set, the owner takes no more actions, as a closed host's: submissions are refused gone, queued actions do
    -- not run and a barrier not yet met is never met.
  , foQueue ∷ !(TVar [FakeAction])
  , foCapacity ∷ !(TVar Int)
    -- ^ How many actions the queue holds; a submission beyond it is refused busy.
  , foLaneFull ∷ !(TVar Bool)
    -- ^ While set, the release lane is full: a barrier request is refused busy.
  , foReleaseFailure ∷ !(TVar (Maybe Text.Text))
    -- ^ While set, every chunk of the next release action fails with this reason (once).
  , foReleaseActions ∷ !(TVar Int)
    -- ^ Release actions the owner ran.
  , foBarrierAsks ∷ !(TVar Int)
    -- ^ Barrier requests made, admitted or refused.
  , foStopAfter ∷ !(TVar (Maybe (Int, Bool)))
    -- ^ While set, the next build makes this many regions, then stops: as pressure ('True') or as a failure (once).
  , foUploads ∷ !(TVar [Natural])
  , foSettled ∷ !(TVar Natural)
    -- ^ How many uploads have settled: grows as 'setUploads' drops one from 'foUploads'.
    -- ^ The uploads the owner reports unsettled, by number: the example settles them.
  , foPressured ∷ !(TVar Bool)
    -- ^ While set, a build is refused as upload pressure for as long as 'foUploads' names an upload.
  , foReleaseRaise ∷ !(TVar Bool)
    -- ^ While set, the next release action ends without answering, as one that raised (once); the owner goes on.
  , foRegionWindow ∷ !(TVar Word64)
    -- ^ The renderer's storage window the owner reports: unbounded unless an example sets it.
  , foRaiseAt ∷ !(TVar (Maybe Int))
    -- ^ While set, the next build makes this many regions and then its builder raises (once).
  }

data FakeAction
  = FakeBuild ![RegionBuild] !(TVar (Maybe (Answer (Either BuildFailure [ChunkRef]))))
  | FakeRelease ![ChunkRef] !(TVar (Maybe (Answer [Either Text.Text ()])))

newFakeOwner ∷ Model → IO FakeOwner
newFakeOwner model =
  FakeOwner model
    <$> newTVarIO 1
    <*> newTVarIO Map.empty
    <*> newTVarIO []
    <*> newTVarIO 0
    <*> newTVarIO True
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO Map.empty
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO []
    <*> newTVarIO 64
    <*> newTVarIO False
    <*> newTVarIO Nothing
    <*> newTVarIO 0
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO []
    <*> newTVarIO 0
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO maxBound
    <*> newTVarIO Nothing

-- The owner's thread: runs queued actions in order. A build waits at the gate; an ended owner answers what it did not
-- run.
fakeOwnerLoop ∷ FakeOwner → IO ()
fakeOwnerLoop owner = forever $ do
  action ← atomically $ readTVar (foQueue owner) >>= \case
    next : rest → next <$ writeTVar (foQueue owner) rest
    [] → retry
  case action of
    FakeBuild regions answer → do
      atomically (modifyTVar' (foWaiting owner) (+ 1))
      atomically ((readTVar (foGate owner) >>= check) `orElse` (readTVar (foEnded owner) >>= check))
      raise ← atomically (readTVar (foRaiseAt owner) <* writeTVar (foRaiseAt owner) Nothing)
      case raise of
        -- the production build loop, over a builder that makes this many regions and then raises
        Just count → do
          atomically (modifyTVar' (foWaiting owner) (subtract 1))
          made ← newTVarIO (0 ∷ Int)
          let builder region = do
                index ← atomically (readTVar made <* modifyTVar' made (+ 1))
                if index >= count
                  then throwIO (userError "the fake builder raised")
                  else
                    atomically (mintChunks owner [region]) >>= \case
                      [chunk] → pure (Right chunk)
                      _ → throwIO (userError "the fake owner minted no chunk")
          -- as the host's owner would: an action that raises ends unanswered, and what it recorded is kept
          built ← newTVarIO []
          result ← try (buildRegions builder (\chunk → atomically (modifyTVar' built (chunk :))) regions)
          answered ← atomically . keepBuilt built . pure . Just $ case result of
            Left (raised ∷ SomeException) → NotRun (Text.pack ("the fake owner's action raised: " <> displayException raised))
            Right value → Answered value
          atomically (writeTVar answer answered)
        Nothing → atomically $ do
         modifyTVar' (foWaiting owner) (subtract 1)
         ended ← readTVar (foEnded owner)
         failure ← readTVar (foFailure owner)
         pressured ← (&&) <$> readTVar (foPressured owner) <*> (not . null <$> readTVar (foUploads owner))
         stop ← if pressured then pure (Just (0, True)) else readTVar (foStopAfter owner) <* writeTVar (foStopAfter owner) Nothing
         let make = mintChunks owner
         result ← case (ended, failure, stop) of
           (True, _, _) → pure (NotRun "the owner ended")
           (_, Just why, _) → pure (Answered (Left (BuildFailed [] why)))
           (_, _, Just (count, pressure)) → do
             refs ← make (take count regions)
             pure (Answered (Left ((if pressure then BuildPressure else BuildFailed) refs "the fake owner stopped the build")))
           _ → Answered . Right <$> make regions
         writeTVar answer (Just result)
    FakeRelease chunks answer → atomically $ do
      ended ← readTVar (foEnded owner)
      raised ← readTVar (foReleaseRaise owner) <* writeTVar (foReleaseRaise owner) False
      failure ← readTVar (foReleaseFailure owner) <* writeTVar (foReleaseFailure owner) Nothing
      modifyTVar' (foReleaseActions owner) (+ 1)
      result ← case (ended, failure) of
        (True, _) → pure (NotRun "the owner ended")
        _ | raised → pure (NotRun "the fake owner's release action raised")
        (_, Just why) → pure (Answered (map (const (Left why)) chunks))
        _ → do
          modifyTVar' (foStanding owner) (\held → foldr Map.delete held chunks)
          modifyTVar' (foReleased owner) (<> chunks)
          pure (Answered (map (const (Right ())) chunks))
      writeTVar answer (Just result)

-- The plan of the revision the host adopted, read under the view's reader once there is one.
adoptedPlanOf ∷ TerrainView Int → IO CellPlan
adoptedPlanOf view = do
  bounded (atomically (readView view >>= check . isJust . readingAdoptedResidency))
  withAdoptedPlan view pure >>= maybe (fail "no adopted plan") pure

-- The uploads the owner reports unsettled are these now: each one dropped has settled.
setUploads ∷ FakeOwner → [Natural] → STM ()
setUploads owner new = do
  old ← readTVar (foUploads owner)
  modifyTVar' (foSettled owner) (+ fromIntegral (length [u | u ← old, u `notElem` new]))
  writeTVar (foUploads owner) new

-- Mint a chunk for each region, ready at once unless the example holds uploads.
mintChunks ∷ FakeOwner → [RegionBuild] → STM [ChunkRef]
mintChunks owner made = do
  start ← readTVar (foNext owner)
  let refs = [chunkRef index 1 | index ← take (length made) [start ..]]
  writeTVar (foNext owner) (start + fromIntegral (length made))
  holding ← readTVar (foHoldUploads owner)
  modifyTVar' (foStanding owner) (Map.union (Map.fromList [(ref, if holding then ChunkUploading else ChunkReady) | ref ← refs]))
  modifyTVar' (foInstances owner) (Map.union (Map.fromList (zip refs (map buildInstances made))))
  modifyTVar' (foBuilt owner) (+ length made)
  pure refs

fakeViewOwner ∷ FakeOwner → ViewOwner
fakeViewOwner owner =
  ViewOwner
    { ownerMaterial = material
    , ownerDepthQualified = True
    , ownerRegionWindow = readTVar (foRegionWindow owner)
    , ownerBuild = \regions → submitFake (FakeBuild regions)
    , ownerRelease = \chunks → submitFake (FakeRelease chunks)
    , ownerBarrier = \_ → do
        modifyTVar' (foBarrierAsks owner) (+ 1)
        ended ← readTVar (foEnded owner)
        full ← readTVar (foLaneFull owner)
        if
          | ended → pure (Left OwnerGone)
          | full → pure (Left OwnerBusy)
          | otherwise → do
              met ← modelCapture (foModel owner)
              pure . Right $ do
                gone ← readTVar (foEnded owner)
                done ← met
                pure (if done then Just True else if gone then Just False else Nothing)
    , ownerRoom = (&&) <$> (not <$> readTVar (foEnded owner)) <*> ((<) <$> (length <$> readTVar (foQueue owner)) <*> readTVar (foCapacity owner))
    , ownerReleaseRoom = (&&) <$> (not <$> readTVar (foEnded owner)) <*> (not <$> readTVar (foLaneFull owner))
    , ownerStanding = \chunk → Map.lookup chunk <$> readTVar (foStanding owner)
    , ownerUploadsSettled = readTVar (foSettled owner)
    , ownerKeep = \_ → pure False
    , ownerEnd = readTVar (foEnded owner) >>= check
    }
  where
    -- a material whose records take room, as the terrain material's do, so the renderer's storage window binds
    material ∷ MaterialRef
    material = materialRef 7 (materialFacts defaultMaterial) {factRecordLayout = RecordLayout 2 2}
    submitFake ∷ (TVar (Maybe (Answer a)) → FakeAction) → STM (Either OwnerRefusal (Ticket a))
    submitFake make = do
      ended ← readTVar (foEnded owner)
      queued ← length <$> readTVar (foQueue owner)
      capacity ← readTVar (foCapacity owner)
      if
        | ended → pure (Left OwnerGone)
        | queued >= capacity → pure (Left OwnerBusy)
        | otherwise → do
            answer ← newTVar Nothing
            modifyTVar' (foQueue owner) (<> [make answer])
            pure (Right (readTVar answer))

-- The instances of every chunk the window's latest world lists, in the world's order.
drawnInstances ∷ Views → Int → IO [[Instance]]
drawnInstances v window = do
  world ← latestWorld v window
  built ← readTVarIO (foInstances (vOwner v))
  pure [Map.findWithDefault [] chunk built | chunk ← Set.toList (worldChunks world)]

releasedChunks ∷ FakeOwner → IO [ChunkRef]
releasedChunks = readTVarIO . foReleased
