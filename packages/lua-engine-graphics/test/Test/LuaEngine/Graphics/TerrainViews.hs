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
import Control.Monad (unless, void)
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
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene (..), initialGraphicsScene, ledgerInterests)
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
import Hetoimasia.LuaEngine.Texture (RenderAccount)
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..))
import Hetoimasia.GPU.Vulkan.GLFW (TextureHandle (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures (toBackendHandle)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (TextureRef (..))
import Hetoimasia.Render.TwoD.Material (MaterialRef, defaultMaterial)
import Hetoimasia.Terrain.Coordinate (TileCoord, axisFromInteger, tileCoord)
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
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
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
-- The rig

withViews ∷ (Views → IO a) → IO a
withViews body = do
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
        withTerrain (cpAccount comp) $ \terrain client arena → do
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
          withTerrainViews testConfig ports $ \views →
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
withTerrain ∷ RenderAccount → (Service → Runtime.Client → ArenaLease → IO a) → IO a
withTerrain account body =
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
        arena ← openArena terrain client "views" loamOverGranite >>= either (fail . show) pure >>= await terrain >>= either (fail . show) pure
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
  }

newFakeOwner ∷ Model → IO FakeOwner
newFakeOwner model = FakeOwner model <$> newTVarIO 1 <*> newTVarIO Map.empty <*> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO True <*> newTVarIO 0

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
        start ← readTVar (foNext owner)
        let refs = [chunkRef index 1 | index ← take (length regions) [start ..]]
        writeTVar (foNext owner) (start + fromIntegral (length regions))
        modifyTVar' (foStanding owner) (Map.union (Map.fromList [(ref, ChunkReady) | ref ← refs]))
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

releasedChunks ∷ FakeOwner → IO [ChunkRef]
releasedChunks = readTVarIO . foReleased
