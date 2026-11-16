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

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (unless, void, when)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as BC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.LuaEngine.Graphics.Scene.Claims (SceneClaims, claimOf, newSceneClaims)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene (..), LedgerReading (..), initialGraphicsScene, ledgerInterests, ledgerReading)
import Hetoimasia.LuaEngine.Graphics.Scene.Publish (HostAnswer (..))
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView
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
import Hetoimasia.Terrain.Render2D.Cells (CellConfig (..), defaultCellConfig)
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
  }

spec ∷ Spec
spec = describe "terrain views" $ do
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
currentHit v view = bounded go
  where
    go = do
      _ ← adoptNow (vModel v) 1
      _ ← releasePass (vModel v)
      hit ← adoptedHit v view
      status ← Runtime.arenaStatus (_vTerrain v) (vArena v) >>= either (fail . show) pure
      let precondition = pickPrecondition view hit
      if Runtime.preconditionContent precondition == Runtime.statusContentRevision status
        && Runtime.preconditionKnowledge precondition == Just (Runtime.statusKnowledgeRevision status)
        then pure hit
        else do
          now ← publishedRevision (vModel v) 1
          awaitRevision (vModel v) 1 (now + 1)
          go

-- The zoom a world's view draws with, and the zoom of the first plan (the camera's default, 1).
zoomOf ∷ SceneWorld → Float
zoomOf = cameraZoom . viewCamera . worldView

zoomOfFirst ∷ Float
zoomOfFirst = 1

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

  it "reproduces the same plan for a fresh view of the arena from its retained terrain and knowledge" $
    withViews $ \v → do
      view ← attached v 1
      _ ← awaitPublished v 1
      _ ← adoptNow (vModel v) 1
      revealAt v (8, 8, 3)
      quiescent v
      _ ← currentHit v view
      original ← drawnInstances v 1
      closeView view
      modelWindow (vModel v) 2
      fresh ← attached v 2
      bounded (atomically (readView fresh >>= check . (/= Nothing) . readingPublished))
      again ← drawnInstances v 2
      again `shouldBe` original
      closeView fresh

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
withViewsOn source config body = do
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
        withTerrain source (cpAccount comp) $ \terrain client arena → do
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
          withTerrainViews config ports $ \views →
            body (Views comp vm fake model terrain arena views owner claims (cpAccount comp) style colourKey normalKey)
              `finally` dissolve model

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
withTerrain ∷ SourceSpec → RenderAccount → (Service → Runtime.Client → ArenaLease → IO a) → IO a
withTerrain source account body =
  withSystemTempDirectory "hetoimasia-terrain-views" $ \dir → do
    let directory = BC.pack dir
    name ← filesystemOf directory >>= either (\f → fail ("cannot name the test filesystem: " <> show f)) pure
    storage ← either (fail . show) pure (mkStorageConfig [name] minHeadroomBytes)
    withWorkerGroup $ \group → do
      let config =
            defaultConfig
              { configStore = defaultStoreSpec {specAllowanceBytes = toInteger minAllowanceBytes}
              , configStagingAccount = Just (renderStagingAccount account)
              }
      withTerrainService config (Ports alwaysAdmitting (standaloneSupervisor group) quiet noProbe (storagePort group storage directory)) $ \terrain → do
        client ← Runtime.registerClient terrain >>= either (fail . show) pure
        arena ← openArena terrain client "views" source >>= either (fail . show) pure >>= await terrain >>= either (fail . show) pure
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
  }

newFakeOwner ∷ Model → IO FakeOwner
newFakeOwner model = FakeOwner model <$> newTVarIO 1 <*> newTVarIO Map.empty <*> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO True <*> newTVarIO 0 <*> newTVarIO Nothing <*> newTVarIO Map.empty

fakeViewOwner ∷ FakeOwner → ViewOwner
fakeViewOwner owner =
  ViewOwner
    { ownerMaterial = material
    , ownerDepthQualified = True
    , ownerBuild = \regions → do
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
          modifyTVar' (foStanding owner) (Map.union (Map.fromList [(ref, ChunkReady) | ref ← refs]))
          modifyTVar' (foInstances owner) (Map.union (Map.fromList (zip refs (map buildInstances regions))))
          modifyTVar' (foBuilt owner) (+ length regions)
          pure (Just (Right refs))
    , ownerRelease = \chunks → atomically $ do
        modifyTVar' (foStanding owner) (\held → foldr Map.delete held chunks)
        modifyTVar' (foReleased owner) (<> chunks)
        pure (Just (map (const (Right ())) chunks))
    , ownerBarrier = \_ → do
        met ← modelCapture (foModel owner)
        pure (Right ((\done → if done then Just True else Nothing) <$> met))
    , ownerStanding = \chunk → Map.lookup chunk <$> readTVar (foStanding owner)
    }
  where
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
