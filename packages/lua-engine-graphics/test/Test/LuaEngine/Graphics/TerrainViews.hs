-- | Terrain views (TRA-9) over the production terrain service, with a graphics owner the example steps itself.
--
-- The rig's owner is a queue the example drains: every owner action the views admit is run, with fake hands that
-- describe each chunk with render-2d's own 'buildChunkWith' and record its disposal, until the views ask for nothing
-- more. The release lane is a FIFO queue the example meets; the target records what it was published and adopts
-- what the example says it adopted. The terrain service is the real one, so copies settle on its own owner; an
-- example waits, bounded, for the step its settlement asks for.
--
-- Every assertion is an outcome or one of the design's six guarantees: what was published, what it lists, what was
-- disposed of and when it may be, how each operation settled. None asserts an order, a step count or a timing.
module Test.LuaEngine.Graphics.TerrainViews (spec) where

import Control.Concurrent.STM
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString.Char8 as BC
import Data.Bits (shiftL, (.|.))
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.GPU.Vulkan.GLFW (TicketState (..))
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.TerrainView hiding (styleAssets)
import Hetoimasia.LuaEngine.Graphics.Texture (textureHandleOf)
import Hetoimasia.LuaEngine.Texture (RenderAccount, accountCharged, newRenderAccount)
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (DeriveBounds), Chunk, ChunkKind (ChunkWorldDepth), ChunkRef, buildChunkWith, chunksFrom)
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..))
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..))
import Hetoimasia.Terrain.Cell (mkMaterialId)
import Hetoimasia.Terrain.Coordinate (AxisCoord, axisFromInteger, tileCoord)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), boundPackedTextures, loadAtlasStyle)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (combineCopies, planInputs, plannerRuns)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Coordinate (RegionCoord (..))
import Hetoimasia.Terrain.Render2D.Facts (Demand (..))
import Hetoimasia.Terrain.Changes (ChangeLimits (..))
import Hetoimasia.Terrain.Render2D.Camera (JumpTarget (..))
import Hetoimasia.Terrain.Render2D.Cells (CellDemand (..), CellInputs (..), CellKey (..), CellPlan, CellRequest (..), PartKind (PartFog), cellPlanDemand, cellPlanPending, cellPlanQuads, planCells, quadKey, quadPart)
import Hetoimasia.Terrain.Render2D.Facts (TerrainFacts (..))
import Hetoimasia.Terrain.Render2D.Material (recordLayout)
import Hetoimasia.Terrain.Render2D.Presentation (pushBlockBytes)
import Hetoimasia.Terrain.Render2D.Presentation (LightInput (..), LightSettings, defaultLightInput, defaultLightSettings, mkLightSettings)
import Hetoimasia.Terrain.Runtime hiding (closeView, openView, viewIncarnation)
import Hetoimasia.Terrain.Runtime.Storage (filesystemOf, minHeadroomBytes, mkStorageConfig)
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), defaultStoreSpec, minAllowanceBytes)
import Hetoimasia.Terrain.Residency (Limits, LimitsSpec (..), mkLimits)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec hiding (after, before)
import Test.Support.Owned (withOwnedThread)
import Control.Exception (finally)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- The rig

data Rig = Rig
  { rigViews ∷ TerrainViews Int
  , rigTerrain ∷ !Service
  , rigLease ∷ !ArenaLease
  , rigQueue ∷ !(TVar (Seq (Hands → IO (), TVar (Maybe StepOutcome))))
  , rigQueueOpen ∷ !(TVar Bool)
  , rigLane ∷ !(TVar (Seq (STM (), TVar (Maybe (Either Text ())))))
  , rigLaneCapacity ∷ !(TVar Int)
  , rigStandings ∷ !(TVar (Map.Map ChunkRef ChunkStanding))
  , rigChunks ∷ !(TVar (Map.Map ChunkRef Chunk))
  , rigDisposed ∷ !(TVar [ChunkRef])
  , rigAttempts ∷ !(TVar (Map.Map ChunkRef Int))
  , rigBuildFailure ∷ !(TVar (Maybe BuildFailure))
  , rigDisposeFailure ∷ !(TVar Bool)
  , rigNext ∷ !(TVar Word32)
  , rigLedger ∷ !(SceneLedger Int)
  , rigClaims ∷ !(SceneClaims Int)
  , rigReceipts ∷ !DrawReceipts
  , rigOwnerEnded ∷ !(TVar (Maybe Text))
  , rigStyle ∷ !AtlasStyle
  , rigAccount ∷ !RenderAccount
  , rigDeferDisposal ∷ !(TVar Bool)
  , rigPendingDisposals ∷ !(TVar (Map.Map ChunkRef (TVar ConstructedDisposal)))
  , rigHold ∷ !(TVar (Maybe Word32))
    -- ^ The build of this chunk index waits, once, until the example resumes it.
  , rigEntered ∷ !(TMVar ())
  , rigResume ∷ !(TMVar ())
  , rigStyleReleases ∷ !(TVar Int)
  }

-- | What the host does once the body has ended: everything (its targets retire), everything but retire its targets'
-- adoptions (a live target keeps its scene), or nothing.
data Teardown = TeardownFull | TeardownLive | TeardownNone
  deriving (Eq)

data Options = Options
  { optTeardown ∷ Teardown
    -- ^ The host's teardown, played when the body ends ('TeardownNone' leaves the views' drain waiting).
  , optProfile ∷ ViewProfile
  , optWindow ∷ Word64
  , optRuntime ∷ Config → Config
  }

defaultOptions ∷ Options
defaultOptions = Options TeardownFull smallProfile 196608 id

-- A small profile: enough for the examples' views, small enough that its caps are reachable.
smallProfile ∷ ViewProfile
smallProfile = defaultViewProfile {profileSlots = 64, profileQuads = 8192, profilePending = 4096, profileRegions = 64}

-- A profile of eight slots, which a replacement rebuilding every chunk cannot fit beside the drawn revision.
slotted ∷ ViewProfile
slotted = smallProfile {profileSlots = 8, profileQuads = 4096}

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

colourIdentity, normalIdentity ∷ Word64
colourIdentity = (1 `shiftL` 32) .|. 5
normalIdentity = (1 `shiftL` 32) .|. 6

withRig ∷ Options → (Rig → IO a) → IO a
withRig options body =
  withSystemTempDirectory "hetoimasia-terrain-views" $ \dir → do
    let directory = BC.pack dir
        quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))
    name ← filesystemOf directory >>= either (\f → fail ("cannot name the test filesystem: " <> show f)) pure
    storage ← either (fail . show) pure (mkStorageConfig [name] minHeadroomBytes)
    style ← loadAtlasStyle 7 [("loam", "colour.loam"), ("granite", "colour.granite")]
    -- The camera's runtime demand is bounded to a few regions: the views' copies do not depend on residency, and a
    -- routine example need not wait for the loads of a whole camera's demand.
    let config = optRuntime options defaultConfig {configStore = defaultStoreSpec {specAllowanceBytes = toInteger minAllowanceBytes}, configLimits = cameraLimits}
    withWorkerGroup $ \group →
      withTerrainService config (Ports alwaysAdmitting (standaloneSupervisor group) quiet noProbe (storagePort group storage directory)) $ \terrain → do
        client ← registerClient terrain >>= either (fail . show) pure
        lease ← openArena terrain client "main" source >>= either (fail . show) pure >>= await terrain >>= either (fail . show) pure
        queue ← newTVarIO Seq.empty
        queueOpen ← newTVarIO True
        lane ← newTVarIO Seq.empty
        laneCapacity ← newTVarIO 64
        standings ← newTVarIO Map.empty
        chunks ← newTVarIO Map.empty
        disposed ← newTVarIO []
        attempts ← newTVarIO Map.empty
        buildFailure ← newTVarIO Nothing
        disposeFailure ← newTVarIO False
        next ← newTVarIO 1
        ledger ← newSceneLedger
        claims ← newSceneClaims
        receipts ← newDrawReceipts
        ownerEnded ← newTVarIO Nothing
        account ← newRenderAccount (128 * 1024 * 1024)
        deferDisposal ← newTVarIO False
        pendingDisposals ← newTVarIO Map.empty
        hold ← newTVarIO Nothing
        entered ← newEmptyTMVarIO
        resume ← newEmptyTMVarIO
        styleReleases ← newTVarIO 0
        initial ← prepare initialGraphicsScene
        let owner =
              OwnerPorts
                { ownerSchedule = \step → do
                    ended ← readTVar ownerEnded
                    accepting ← readTVar queueOpen
                    case ended of
                      Just why → pure (Left (ScheduleEnded why))
                      Nothing
                        | not accepting → pure (Left ScheduleBusy)
                        | otherwise → do
                            outcome ← newTVar Nothing
                            modifyTVar' queue (|> (step, outcome))
                            pure (Right (readTVar outcome))
                , ownerRelease = \after → do
                    room ← readTVar laneCapacity
                    held ← Seq.length <$> readTVar lane
                    if held >= room
                      then pure (Left "the release lane is full")
                      else do
                        answer ← newTVar Nothing
                        modifyTVar' lane (|> (after, answer))
                        pure (Right (readTVar answer))
                , ownerStanding = \chunk → Map.lookup chunk <$> readTVar standings
                , ownerMaterial = materialRef 11 (MaterialFacts True recordLayout (fromIntegral pushBlockBytes))
                , ownerRegionWindow = optWindow options
                , ownerDepthQualified = True
                , ownerEnded = readTVar ownerEnded
                }
            ports = TerrainViewsPorts owner ledger claims receipts initial terrain client account
        ending ← newTVarIO False
        -- When the body has ended, the host's own teardown is played by this thread: the barriers are met and the
        -- owner's actions run, and (unless the targets stay live) every target's adoptions are released, so the views'
        -- drain completes.
        let retireTargets = optTeardown options == TeardownFull
            teardown = do
              atomically (readTVar ending >>= check)
              let loop = do
                    atomically $ do
                      queued ← readTVar queue
                      asked ← readTVar lane
                      records ← readingRecords <$> ledgerReading ledger
                      check (not (Seq.null queued && Seq.null asked && (null records || not retireTargets)))
                    when retireTargets $ do
                      records ← readingRecords <$> atomically (ledgerReading ledger)
                      forM_ records $ \((key, revision), count) → forM_ [1 .. count] (\_ → ledgerReleased ledger key revision)
                    entries ← atomically (readTVar lane <* writeTVar lane Seq.empty)
                    forM_ entries $ \(after, answer) → atomically (writeTVar answer (Just (Right ())) >> after)
                    steps ← atomically (readTVar queue <* writeTVar queue Seq.empty)
                    forM_ steps $ \(step, outcome) → step fakeHands >> atomically (writeTVar outcome (Just StepRan))
                    loop
              loop
            rig views = Rig views terrain lease queue queueOpen lane laneCapacity standings chunks disposed attempts buildFailure disposeFailure next ledger claims receipts ownerEnded style account deferDisposal pendingDisposals hold entered resume styleReleases
            fakeHands = hands (rig (error "the teardown's hands read no service"))
        withOwnedThread (when (optTeardown options /= TeardownNone) teardown) $ \_ _ →
          withTerrainViews defaultTerrainViewsConfig {tvProfile = optProfile options} ports $ \views →
            body (rig views) `finally` atomically (writeTVar ending True)

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

-- The fake hands: a chunk is render-2d's own description of its instances under the material's records, ready at
-- once unless the example says otherwise.
hands ∷ Rig → Hands
hands rig =
  Hands
    { handBuild = \instances records → do
      upcoming ← readTVarIO (rigNext rig)
      held ← atomically $ do
        hold ← readTVar (rigHold rig)
        if hold == Just upcoming then True <$ (writeTVar (rigHold rig) Nothing >> putTMVar (rigEntered rig) ()) else pure False
      when held (atomically (takeTMVar (rigResume rig)))
      atomically $ do
        failure ← readTVar (rigBuildFailure rig)
        case failure of
          Just why → pure (Left why)
          Nothing → case buildChunkWith noCutoutMarks ChunkWorldDepth DeriveBounds (Map.singleton material records) instances of
            Left refusals → pure (Left (BuildFailed (Text.pack (show refusals))))
            Right described → do
              index ← readTVar (rigNext rig)
              writeTVar (rigNext rig) (index + 1)
              let chunk = chunkRef index 1
              modifyTVar' (rigChunks rig) (Map.insert chunk described)
              modifyTVar' (rigStandings rig) (Map.insert chunk ChunkReady)
              pure (Right chunk)
    , handDispose = \chunk → atomically $ do
        modifyTVar' (rigAttempts rig) (Map.insertWith (+) chunk 1)
        failing ← readTVar (rigDisposeFailure rig)
        if failing
          then pure (Left "the backend refused the release")
          else do
            modifyTVar' (rigChunks rig) (Map.delete chunk)
            modifyTVar' (rigStandings rig) (Map.delete chunk)
            modifyTVar' (rigDisposed rig) (chunk :)
            deferred ← readTVar (rigDeferDisposal rig)
            if deferred
              then do
                standing ← newTVar DisposalPending
                modifyTVar' (rigPendingDisposals rig) (Map.insert chunk standing)
                pure (Right (readTVar standing))
              else pure (Right (pure DisposalDone))
    }
  where
    material = materialRef 11 (MaterialFacts True recordLayout (fromIntegral pushBlockBytes))

-- Run the owner until the views ask for nothing more: every queued action, with the fake hands.
runOwner ∷ Rig → IO ()
runOwner rig = go (100000 ∷ Int)
  where
    go 0 = expectationFailure "the owner never became idle"
    go n =
      atomically (Seq.viewl <$> readTVar (rigQueue rig) >>= \case
        Seq.EmptyL → pure Nothing
        next Seq.:< rest → Just next <$ writeTVar (rigQueue rig) rest) >>= \case
        Nothing → pure ()
        Just (step, outcome) → do
          step (hands rig)
          atomically (writeTVar outcome (Just StepRan))
          go (n - 1)

-- The owner's exit begins: it takes no more actions, and refuses the ones queued.
endRigOwner ∷ Rig → Text → IO ()
endRigOwner rig why = atomically $ do
  writeTVar (rigOwnerEnded rig) (Just why)
  queued ← readTVar (rigQueue rig)
  writeTVar (rigQueue rig) Seq.empty
  forM_ queued $ \(_, outcome) → writeTVar outcome (Just (StepRefused why))

-- Wait, bounded, for a condition the views' own threads bring about.
eventually ∷ STM Bool → IO ()
eventually condition = timeout 10000000 (atomically (condition >>= check)) >>= maybe (expectationFailure "the condition never held") pure

-- Run the owner, waiting (bounded) for the terrain service's settlements that ask for further steps, until the
-- condition holds.
settleUntil ∷ Rig → STM Bool → IO ()
settleUntil rig done =
  timeout 10000000 loop >>= \case
    Just () → pure ()
    Nothing → do
      reading ← atomically (readTerrainViews (rigViews rig))
      views ← atomically (viewReadings (rigViews rig))
      expectationFailure ("the views never settled: " <> show views <> ", occupied " <> show (Map.toList (serviceOccupied reading)) <> ", retiring " <> show (serviceRetiring reading) <> ", failures " <> show (serviceFailures reading))
  where
    loop = do
      runOwner rig
      finished ← atomically done
      unless finished $ do
        atomically (readTVar (rigQueue rig) >>= \q → check (not (Seq.null q)))
        loop

-- A fake target: what it was published, newest first, with the revision the host gave each.
data Target = Target
  { targetKey ∷ !Int
  , targetScenes ∷ !(TVar [(Word64, GraphicsScene)])
  , targetUsable ∷ !(TVar Bool)
  , targetMetrics ∷ !(TVar (Maybe TargetMetrics))
  , targetAccepts ∷ !(TVar Bool)
  , targetAdopted ∷ !(TVar (Maybe Word64))
  , targetAuthority ∷ !(TVar Bool)
  }

metricsOf ∷ Int → Int → TargetMetrics
metricsOf w h = TargetMetrics (PixelExtent w h) (PixelExtent w h) 1 1

newTarget ∷ Int → IO Target
newTarget key = Target key <$> newTVarIO [] <*> newTVarIO True <*> newTVarIO (Just (metricsOf 320 240)) <*> newTVarIO True <*> newTVarIO Nothing <*> newTVarIO True

viewTarget ∷ Target → ViewTarget Int
viewTarget target =
  ViewTarget
    { vtKey = targetKey target
    , vtUsable = readTVar (targetUsable target)
    , vtShowing = not . null <$> readTVar (targetScenes target)
    , vtAuthority = readTVar (targetAuthority target)
    , vtBind = pure ()
    , vtUnbind = pure ()
    , vtPublish = \scene → do
        accepts ← readTVar (targetAccepts target)
        when accepts $ do
          held ← readTVar (targetScenes target)
          writeTVar (targetScenes target) ((fromIntegral (length held) + 1, preparedValue scene) : held)
        pure accepts
    , vtDepth = True
    , vtMetrics = readTVar (targetMetrics target)
    }

-- The host adopts the target's latest revision, and its frames of the one before have completed: that one is released.
adopt ∷ Rig → Target → IO ()
adopt rig target = do
  (scenes, previous) ← atomically ((,) <$> readTVar (targetScenes target) <*> readTVar (targetAdopted target))
  case scenes of
    (revision, scene) : _ | Just revision /= previous → do
      ledgerAdopted (rigLedger rig) (targetKey target) (fromIntegral revision) scene
      forM_ previous (ledgerReleased (rigLedger rig) (targetKey target) . fromIntegral)
      atomically (writeTVar (targetAdopted target) (Just revision))
    _ → pure ()

-- The host adopts the latest revision while a frame of the one before is still in flight: both stay held.
adoptHolding ∷ Rig → Target → IO ()
adoptHolding rig target = do
  scenes ← readTVarIO (targetScenes target)
  case scenes of
    (revision, scene) : _ → do
      ledgerAdopted (rigLedger rig) (targetKey target) (fromIntegral revision) scene
      atomically (writeTVar (targetAdopted target) (Just revision))
    [] → pure ()

-- The host meets every barrier asked so far: what was published before each has been adopted.
meetBarriers ∷ Rig → IO ()
meetBarriers rig = do
  entries ← atomically (readTVar (rigLane rig) <* writeTVar (rigLane rig) Seq.empty)
  forM_ entries $ \(after, answer) → atomically (writeTVar answer (Just (Right ())) >> after)

-- The host refuses every barrier asked so far.
refuseBarriers ∷ Rig → Text → IO ()
refuseBarriers rig why = do
  entries ← atomically (readTVar (rigLane rig) <* writeTVar (rigLane rig) Seq.empty)
  forM_ entries $ \(_, answer) → atomically (writeTVar answer (Just (Left why)))

-- Publish, adopt, meet the barriers and run the owner until nothing more moves.
quiesce ∷ Rig → Target → IO ()
quiesce rig target = do
  runOwner rig
  adopt rig target
  meetBarriers rig
  runOwner rig

-- The latest world the target was published, if its latest scene is one.
latestWorld ∷ Target → STM (Maybe SceneWorld)
latestWorld target =
  readTVar (targetScenes target) >>= \case
    (_, scene) : _ → pure (graphicsWorld scene)
    [] → pure Nothing

publishedAtLeast ∷ TerrainView Int → Word64 → STM Bool
publishedAtLeast view revision = maybe False (>= revision) . readingPublished <$> readView view

styleOf ∷ Rig → IO ViewStyle
styleOf rig = styleWith rig ["loam", "granite"] (pure True)

-- A style whose mapping gives a region to these materials, whose parents' leases are live while this says so, and
-- whose release is counted.
styleWith ∷ Rig → [String] → STM Bool → IO ViewStyle
styleWith rig mapped live = do
  textures ← boundPackedTextures (rigStyle rig) (textureHandleOf colourIdentity) (textureHandleOf normalIdentity)
  pure
    ViewStyle
      { styleSnapshot = styleAssets (rigStyle rig)
      , styleBound = textures
      , styleParents = Set.fromList [colourIdentity, normalIdentity]
      , styleMapped = Set.fromList [either (error . show) id (mkMaterialId name) | name ← mapped]
      , styleLive = live
      , styleRelease = atomically (modifyTVar' (rigStyleReleases rig) (+ 1))
      }

openOn ∷ Rig → Target → IO (TerrainView Int)
openOn rig target = do
  style ← styleOf rig
  openView (rigViews rig) (OpenRequest (viewTarget target) (rigLease rig) (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings) >>= \case
    Left why → fail ("the view was refused: " <> show why)
    Right view → pure view

axis ∷ Integer → AxisCoord
axis v = either (error . show) id (axisFromInteger v)

-- A view opened and published once.
withPublished ∷ Options → (Rig → Target → TerrainView Int → IO a) → IO a
withPublished options body =
  withRig options $ \rig → do
    target ← newTarget 1
    view ← openOn rig target
    settleUntil rig (publishedAtLeast view 1)
    body rig target view

-- Every chunk the world lists is one the owner built and has not disposed of, and its snapshot validates against them.
coherent ∷ Rig → SceneWorld → IO ()
coherent rig world = do
  live ← readTVarIO (rigChunks rig)
  Set.toList (worldChunks world) `shouldSatisfy` all (`Map.member` live)
  case Validation.validateSnapshotWith (chunksFrom (Map.toList live)) (worldSnapshot world) of
    Left why → expectationFailure ("the published revision does not validate: " <> show why)
    Right _ → pure ()

brighter, dimmer ∷ LightSettings
brighter = either (error . show) id (mkLightSettings defaultLightInput {inputAmbient = 0.6})
dimmer = either (error . show) id (mkLightSettings defaultLightInput {inputAmbient = 0.4})

-- ---------------------------------------------------------------------------
-- The examples

spec ∷ Spec
spec = describe "terrain views (TRA-9 v2)" $ do
  describe "publication" $ do
    it "publishes one coherent revision whose chunks are all built and ready, and validates against them" $
      withPublished defaultOptions $ \rig target _ → do
        world ← atomically (latestWorld target) >>= maybe (fail "no world was published") pure
        Set.size (worldChunks world) `shouldSatisfy` (> 0)
        coherent rig world
        standings ← readTVarIO (rigStandings rig)
        [Map.lookup chunk standings | chunk ← Set.toList (worldChunks world)] `shouldSatisfy` all (== Just ChunkReady)

    it "keeps every chunk of a lighting-only change: the new revision lists byte-identical regions by the same references" $
      withPublished defaultOptions $ \rig target view → do
        before ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        atomically (configureView view noConfigure {configureLight = Just brighter}) `shouldReturn` Right ()
        settleUntil rig (publishedAtLeast view 2)
        after ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        worldChunks after `shouldBe` worldChunks before
        worldTag after `shouldNotBe` worldTag before

    it "shows a removal: the revision after an edit is planned from the edited version, and unchanged regions keep their chunks" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        before ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        -- a cell beside the followed column, so the cut stays and only its own region's chunks change
        Right removal ← removeAt (rigTerrain rig) (rigLease rig) (either (error . show) id (tileCoord 2 2 1)) Nothing
        _ ← await (rigTerrain rig) removal
        settleUntil rig (publishedAtLeast view 2)
        after ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        coherent rig after
        worldChunks after `shouldNotBe` worldChunks before
        Set.size (Set.intersection (worldChunks after) (worldChunks before)) `shouldSatisfy` (> 0)

  describe "what is drawn" $
    it "draws what the planner plans from the same version, fog and every contributing region included, before and after an edit" $
      withPublished defaultOptions $ \rig target view → do
        let check' = do
              runOwner rig
              world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
              atomically (noteSubmitted (rigReceipts rig) (worldTag world) (worldMetrics world))
              drawn ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
              plan ← maybe (fail "the drawn plan is not pinned") pure (drawnPlanPlan drawn)
              independent ← independentPlan rig drawn
              cellPlanQuads plan `shouldBe` cellPlanQuads independent
              cellPlanPending plan `shouldBe` cellPlanPending independent
              pure plan
        before' ← check'
        -- fog and more than one region contribute to the fixture's plan
        [() | quad ← cellPlanQuads before', quadPart quad == PartFog] `shouldSatisfy` (not . null)
        Set.size (Set.fromList [regionOfKey (quadKey quad) | quad ← cellPlanQuads before']) `shouldSatisfy` (> 1)
        Right removal ← removeAt (rigTerrain rig) (rigLease rig) (either (error . show) id (tileCoord 2 2 1)) Nothing
        _ ← await (rigTerrain rig) removal
        settleUntil rig (publishedAtLeast view 2)
        after' ← check'
        cellPlanQuads after' `shouldNotBe` cellPlanQuads before'

  describe "the draw receipt" $ do
    it "names only a revision whose batch was submitted: adoption alone leaves it as it was" $
      withPublished defaultOptions $ \rig target view → do
        atomically (readingDrawn <$> readView view) `shouldReturn` Nothing
        adopt rig target
        atomically (readingDrawn <$> readView view) `shouldReturn` Nothing
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        atomically (noteSubmitted (rigReceipts rig) (worldTag world) (worldMetrics world))
        drawn ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
        drawnTag (drawnPlanReceipt drawn) `shouldBe` worldTag world
        drawnPlanTarget drawn `shouldBe` 1
        isJust (drawnPlanPlan drawn) `shouldBe` True
        -- a successor that is accepted and adopted but never drawn leaves the receipt where it was
        atomically (configureView view noConfigure {configureLight = Just brighter}) `shouldReturn` Right ()
        settleUntil rig (publishedAtLeast view 2)
        adopt rig target
        again ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
        drawnTag (drawnPlanReceipt again) `shouldBe` worldTag world
        -- the drawn revision's plan stays pinned beside its successor's
        isJust (drawnPlanPlan again) `shouldBe` True

  describe "admission" $ do
    it "refuses a replacement beyond the target's chunk slots and keeps the drawing; the occupancy never exceeds the slots" $
      withPublished defaultOptions {optProfile = slotted} $ \rig target view → do
        quiesce rig target
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        -- a new facing rebuilds every chunk: more than the slots left beside the drawn revision's
        atomically (configureView view noConfigure {configureFacing = Just FaceWest}) `shouldReturn` Right ()
        settleUntil rig (isJust . readingRefusal <$> readView view)
        reading ← atomically (readView view)
        readingRefusal reading `shouldSatisfy` \case
          Just (LimitSlots _ _) → True
          _ → False
        readingPublished reading `shouldBe` published
        atomically (latestWorld target) `shouldReturn` before
        occupied ← atomically (serviceOccupied <$> readTerrainViews (rigViews rig))
        Map.findWithDefault 0 1 occupied `shouldSatisfy` (<= profileSlots slotted)
        readingRefusals reading `shouldBe` 1

    it "refuses a candidate whose records exceed the recorder's window, before building anything" $
      withRig defaultOptions {optWindow = 64} $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitRecorderWindow _ 64) → True
          _ → False)
        atomically (readTVar (targetScenes target)) `shouldReturn` []
        readTVarIO (rigChunks rig) `shouldReturn` Map.empty

    it "refuses when the terrain service refuses the copy, and keeps the drawing" $
      withRig defaultOptions {optRuntime = \c → c {configRetainedBytes = 4096}} $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitRuntime _) → True
          _ → False)
        atomically (readTVar (targetScenes target)) `shouldReturn` []

    it "refuses a candidate whose copies hold more input runs and intervals than the profile allows, across split copies, counting every column's runs" $ do
      -- one region's copy: its knowledge is one class of several runs shared by every column, which the planner is
      -- handed column by column
      (expanded, compressed) ← withRig defaultOptions $ \rig → do
        snapshot ← withRegionSnapshot (rigTerrain rig) (rigLease rig) [RegionCoord 0 0 0] (either (fail . show) pure) >>= either (fail . show) pure
        let classes = [D.regionKnowledgeClasses known | region ← regionSnapshotRegions snapshot, PartReady known ← [regionKnowledge snapshot region]]
        case classes of
          [[shared]] | length shared > 1 → pure (plannerRuns snapshot, length shared)
          _ → fail ("the fixture's region is not one shared multi-run class: " <> show (map (map length) classes))
      expanded `shouldSatisfy` (> compressed * 16)
      -- one region's copy fits; two do not; the compressed count of every region the view copies would
      withRig defaultOptions {optProfile = smallProfile {profileRuns = expanded, profileRequestRegions = 1}} $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitRuns runs limit) → limit == expanded && runs > expanded
          _ → False)

    it "refuses a view when the profile's targets are all open, or the target carries no qualified depth image" $
      withRig defaultOptions {optProfile = smallProfile {profileTargets = 1}} $ \rig → do
        first ← newTarget 1
        second ← newTarget 2
        _ ← openOn rig first
        style ← styleOf rig
        refused ← openView (rigViews rig) (OpenRequest (viewTarget second) (rigLease rig) (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
        either Just (const Nothing) refused `shouldBe` Just OpenTooManyViews
        shallow ← openView (rigViews rig) (OpenRequest ((viewTarget second) {vtDepth = False}) (rigLease rig) (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
        either Just (const Nothing) shallow `shouldBe` Just OpenNoDepth
        atomically (claimOf (rigClaims rig) 2) `shouldReturn` Nothing

    it "reserves the declared allowance once, and returns it when the views end" $
      withRig defaultOptions $ \rig → do
        let allowance = reserveTotal (reservation smallProfile)
        atomically (accountCharged (rigAccount rig)) `shouldReturn` fromInteger allowance
        atomically (serviceReserved <$> readTerrainViews (rigViews rig)) `shouldReturn` allowance

  describe "controls" $ do
    it "settles open at attachment, and refuses a second view of a target the first holds" $
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        atomically (readingStatus <$> readView view) `shouldReturn` ViewOpen
        style ← styleOf rig
        second ← openView (rigViews rig) (OpenRequest (viewTarget target) (rigLease rig) (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
        either Just (const Nothing) second `shouldBe` Just OpenTargetClaimed

    it "settles a move superseded by a camera change once, and its late completion cannot move the camera" $
      withPublished defaultOptions $ \rig _ view → do
        Right move ← atomically (moveView view (JumpTarget (axis 4000) (axis 4000) Nothing))
        atomically (moveSettled move) `shouldReturn` Nothing
        atomically (configureView view noConfigure {configureZoom = Just 2}) `shouldReturn` Right ()
        atomically (moveSettled move) `shouldReturn` Just MoveSuperseded
        settleUntil rig (publishedAtLeast view 2)
        atomically (moveSettled move) `shouldReturn` Just MoveSuperseded

    it "keeps a pending move through a lighting-only update" $
      withPublished defaultOptions $ \_ _ view → do
        Right move ← atomically (moveView view (JumpTarget (axis 4000) (axis 4000) (Just (axis 1))))
        atomically (configureView view noConfigure {configureLight = Just brighter}) `shouldReturn` Right ()
        atomically (moveSettled move) `shouldReturn` Nothing

    it "lands a move once its destination is copied" $
      withPublished defaultOptions $ \rig _ view → do
        Right move ← atomically (moveView view (JumpTarget (axis 70) (axis 70) Nothing))
        settleUntil rig (isJust <$> moveSettled move)
        atomically (moveSettled move) `shouldReturn` Just MoveLanded

    it "applies none of an invalid configure's fields" $
      withPublished defaultOptions $ \_ _ view → do
        before' ← atomically (readView view)
        atomically (configureView view noConfigure {configureZoom = Just (0 / 0), configureLight = Just brighter}) >>= (`shouldSatisfy` \case
          Left (ControlInvalid _) → True
          _ → False)
        after' ← atomically (readView view)
        readingPublished after' `shouldBe` readingPublished before'
        readingStage after' `shouldBe` "idle"

    it "applies none of a busy configure's fields" $
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        -- no step has run: the view has no terrain facts yet
        atomically (configureView view noConfigure {configureZoom = Just 2, configureLight = Just brighter}) `shouldReturn` Left ControlBusy
        runOwner rig

    it "revokes a close at once, with no owner step, even on a minimized target" $
      withPublished defaultOptions $ \rig target view → do
        atomically (writeTVar (rigQueueOpen rig) False)
        atomically (writeTVar (targetMetrics target) (Just (metricsOf 0 0)))
        outcome ← closeView view
        outcome `shouldSatisfy` (`elem` [CloseRetiring, CloseDone])
        atomically (readingStatus <$> readView view) `shouldReturn` ViewEnded EndClosed
        atomically (claimOf (rigClaims rig) 1) `shouldReturn` Nothing
        closeView view `shouldReturn` CloseAlreadyReleased
        atomically (writeTVar (rigQueueOpen rig) True)

  describe "endings" $ do
    it "on close, hands the published claim back with a real empty revision, after which M1 may publish" $
      withPublished defaultOptions $ \rig target view → do
        -- while the view is open its style's two parents are held by interests the texture backend's release reads
        atomically (readingInterests <$> ledgerReading (rigLedger rig)) `shouldReturn` Map.fromList [(colourIdentity, 1), (normalIdentity, 1)]
        _ ← closeView view
        atomically (readingInterests <$> ledgerReading (rigLedger rig)) `shouldReturn` Map.empty
        scenes ← readTVarIO (targetScenes target)
        case scenes of
          (_, scene) : _ → graphicsWorld scene `shouldBe` Nothing
          [] → expectationFailure "nothing was handed back"
        atomically (takeClaim (rigClaims rig) 1 99) `shouldReturn` True

    it "retires a closed view's chunks only once their barrier is met and no adoption holds them" $
      withPublished defaultOptions $ \rig target view → do
        adoptHolding rig target
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        _ ← closeView view
        runOwner rig
        meetBarriers rig
        runOwner rig
        -- the drawn revision is still adopted, its frame in flight: nothing of it is disposed of
        disposed ← readTVarIO (rigDisposed rig)
        Set.toList (worldChunks world) `shouldSatisfy` all (`notElem` disposed)
        -- the handback is adopted and the frame completes
        adopt rig target
        runOwner rig
        after ← readTVarIO (rigDisposed rig)
        Set.toList (worldChunks world) `shouldSatisfy` all (`elem` after)
        atomically (serviceOccupied <$> readTerrainViews (rigViews rig)) `shouldReturn` Map.empty

    it "keeps a retirement behind a full release lane, and drains it once the lane has room, with no caller's kick" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        atomically (writeTVar (rigLaneCapacity rig) 0)
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        _ ← closeView view
        adopt rig target
        runOwner rig
        reading ← atomically (readTerrainViews (rigViews rig))
        serviceRetiring reading `shouldBe` Set.size (worldChunks world)
        -- another component's release leaves the lane: the views' watcher asks for the barrier itself
        atomically (writeTVar (rigLaneCapacity rig) 64)
        eventually (not . Seq.null <$> readTVar (rigLane rig))
        meetBarriers rig
        settleUntil rig ((== 0) . serviceRetiring <$> readTerrainViews (rigViews rig))
        disposed ← readTVarIO (rigDisposed rig)
        Set.toList (worldChunks world) `shouldSatisfy` all (`elem` disposed)

    it "disposes of an in-flight build's chunks when its view closes, and of a failed build's" $
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        atomically (writeTVar (rigBuildFailure rig) (Just (BuildFailed "an injected failure")))
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (writeTVar (rigBuildFailure rig) Nothing)
        _ ← closeView view
        runOwner rig
        readTVarIO (rigChunks rig) `shouldReturn` Map.empty
        atomically (servicePrivate <$> readTerrainViews (rigViews rig)) `shouldReturn` 0

    it "revokes a view whose arena lease is released, and hands its claim back" $
      withPublished defaultOptions $ \rig _ view → do
        releaseLease (rigTerrain rig) (rigLease rig) `shouldReturn` Right ()
        settleUntil rig ((== ViewEnded EndRevoked) . readingStatus <$> readView view)
        atomically (claimOf (rigClaims rig) 1) `shouldReturn` Nothing

    it "ends a view whose target incarnation retired, dropping its claim" $
      withPublished defaultOptions $ \rig target view → do
        -- an idle target retires: the views notice it with no caller's kick
        atomically (writeTVar (targetUsable target) False)
        eventually (not . Seq.null <$> readTVar (rigQueue rig))
        settleUntil rig ((== ViewEnded EndTargetGone) . readingStatus <$> readView view)
        atomically (claimOf (rigClaims rig) 1) `shouldReturn` Nothing

    it "hands a failed handback's chunks to the session's teardown when the service ends while its target still shows them" $ do
      held ← newIORef Nothing
      _ ← withPublished defaultOptions {optTeardown = TeardownLive} $ \rig target view → do
        quiesce rig target
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        atomically (writeTVar (targetAccepts target) False)
        _ ← closeView view
        runOwner rig
        writeIORef held (Just (rigViews rig, rigDisposed rig, world))
      (views, disposedVar, world) ← readIORef held >>= maybe (fail "the rig never started") pure
      -- the scope returned with the live target still adopting the scene: nothing of it was disposed of
      disposed ← readTVarIO disposedVar
      Set.toList (worldChunks world) `shouldSatisfy` all (`notElem` disposed)
      failures ← atomically (serviceFailures <$> readTerrainViews views)
      [chunk | (_, Just chunk, cause) ← failures, "failed handback" `Text.isInfixOf` cause] `shouldMatchList` Set.toList (worldChunks world)

    it "keeps the chunks of a failed handback until the service ends" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        atomically (writeTVar (targetAccepts target) False)
        _ ← closeView view
        runOwner rig
        meetBarriers rig
        runOwner rig
        disposed ← readTVarIO (rigDisposed rig)
        Set.toList (worldChunks world) `shouldSatisfy` all (`notElem` disposed)

    it "keeps a chunk whose release failed, with its identity and cause, while the others go on" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        atomically (writeTVar (rigDisposeFailure rig) True)
        _ ← closeView view
        adopt rig target
        runOwner rig
        meetBarriers rig
        runOwner rig
        failures ← atomically (serviceFailures <$> readTerrainViews (rigViews rig))
        failures `shouldSatisfy` (not . null)
        failures `shouldSatisfy` all (\(_, chunk, cause) → isJust chunk && "release failed" `Text.isInfixOf` cause)
        -- two more steps: no chunk is attempted again, no evidence is added, and the failed chunks keep their slots
        forM_ [1 ∷ Int, 2] $ \_ → atomically (kick (rigViews rig)) >> runOwner rig
        reading ← atomically (readTerrainViews (rigViews rig))
        serviceFailures reading `shouldBe` failures
        attempted ← readTVarIO (rigAttempts rig)
        [Map.lookup chunk attempted | (_, Just chunk, _) ← failures] `shouldSatisfy` all (== Just 1)
        Map.findWithDefault 0 1 (serviceOccupied reading) `shouldBe` length failures
        (serviceRetiring reading, servicePrivate reading) `shouldBe` (0, 0)

  describe "ownership" $ do
    it "hands each chunk on once when its view closes between two builds of a batch" $
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        -- the second chunk of the first batch waits: the first is the built prefix
        first ← readTVarIO (rigNext rig)
        atomically (writeTVar (rigHold rig) (Just (first + 1)))
        stop ← newTVarIO False
        let owner = do
              runOwner rig
              continue ← atomically ((False <$ (readTVar stop >>= check)) `orElse` (True <$ (readTVar (rigQueue rig) >>= check . not . Seq.null)))
              when continue owner
        withOwnedThread (owner `finally` pure ()) $ \_ ended → do
          timeout 10000000 (atomically (takeTMVar (rigEntered rig))) >>= maybe (expectationFailure "no build was held") pure
          _ ← closeView view
          atomically (putTMVar (rigResume rig) ())
          atomically (writeTVar stop True)
          ended
        settleUntil rig (((== 0) . servicePrivate) <$> readTerrainViews (rigViews rig))
        built ← readTVarIO (rigNext rig)
        attempts ← readTVarIO (rigAttempts rig)
        -- every chunk built, the prefix and the one in hand when the view closed, was released exactly once
        [Map.findWithDefault 0 (chunkRef index 1) attempts | index ← [first .. built - 1]] `shouldSatisfy` all (== 1)
        readTVarIO (rigChunks rig) `shouldReturn` Map.empty
        atomically (serviceOccupied <$> readTerrainViews (rigViews rig)) `shouldReturn` Map.empty

    it "waits for the owner's running build before the service returns its reservation, and disposes of what it built" $ do
      box ← newEmptyTMVarIO
      bodyEnded ← newTVarIO False
      seenHeld ← newTVarIO False
      stop ← newTVarIO False
      charged ← newEmptyTMVarIO
      -- the owner and the example's controller outlive the service's scope: the build is held across its exit
      let owner = do
            rig ← atomically (readTMVar box)
            let loop = do
                  runOwner rig
                  continue ← atomically ((False <$ (readTVar stop >>= check)) `orElse` (True <$ (readTVar (rigQueue rig) >>= check . not . Seq.null)))
                  when continue loop
            loop
          controller = do
            rig ← atomically (readTMVar box)
            timeout 10000000 (atomically (takeTMVar (rigEntered rig))) >>= maybe (fail "no build was held") pure
            atomically (writeTVar seenHeld True)
            -- the body has returned and the scope's drain waits for the held step: the reservation is still charged
            atomically (readTVar bodyEnded >>= check)
            atomically (accountCharged (rigAccount rig)) >>= atomically . putTMVar charged
            atomically (putTMVar (rigResume rig) ())
      withOwnedThread owner $ \_ _ →
        withOwnedThread controller $ \_ controllerEnded → do
          withRig defaultOptions {optTeardown = TeardownNone} $ \rig → do
            target ← newTarget 1
            _ ← openOn rig target
            held ← readTVarIO (rigNext rig)
            atomically (writeTVar (rigHold rig) (Just held))
            atomically (putTMVar box rig)
            timeout 10000000 (atomically (readTVar seenHeld >>= check)) >>= maybe (expectationFailure "the build was never held") pure
            atomically (writeTVar bodyEnded True)
          controllerEnded
          atomically (writeTVar stop True)
          rig ← atomically (readTMVar box)
          whileHeld ← atomically (takeTMVar charged)
          whileHeld `shouldSatisfy` (> 0)
          atomically (accountCharged (rigAccount rig)) `shouldReturn` 0
          held ← subtract 1 <$> readTVarIO (rigNext rig)
          readTVarIO (rigChunks rig) `shouldReturn` Map.empty
          -- the chunk the held build made was disposed of exactly once
          Map.lookup (chunkRef held 1) <$> readTVarIO (rigAttempts rig) >>= (`shouldBe` Just 1)

    it "keeps a released chunk's slot until the backend confirms its disposal; a failed disposal keeps it with its cause" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        atomically (writeTVar (rigDeferDisposal rig) True)
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        let chunks = Set.toList (worldChunks world)
        _ ← closeView view
        adopt rig target
        runOwner rig
        meetBarriers rig
        settleUntil rig ((== length chunks) . serviceDisposing <$> readTerrainViews (rigViews rig))
        -- released, not yet destroyed: every slot is still occupied
        atomically (Map.findWithDefault 0 1 . serviceOccupied <$> readTerrainViews (rigViews rig)) `shouldReturn` length chunks
        awaiting ← readTVarIO (rigPendingDisposals rig)
        case chunks of
          refused : rest → do
            atomically $ do
              forM_ rest $ \chunk → forM_ (Map.lookup chunk awaiting) (`writeTVar` DisposalDone)
              forM_ (Map.lookup refused awaiting) (`writeTVar` DisposalFailed "the device refused")
            settleUntil rig ((== 0) . serviceDisposing <$> readTerrainViews (rigViews rig))
            reading ← atomically (readTerrainViews (rigViews rig))
            Map.findWithDefault 0 1 (serviceOccupied reading) `shouldBe` 1
            [cause | (_, Just chunk, cause) ← serviceFailures reading, chunk == refused] `shouldSatisfy` any ("device refused" `Text.isInfixOf`)
          [] → expectationFailure "the world listed no chunk"

    it "counts a closed target whose chunks still occupy slots against the profile's targets until they are disposed of" $
      withRig defaultOptions {optProfile = smallProfile {profileTargets = 1}} $ \rig → do
        first ← newTarget 1
        view ← openOn rig first
        settleUntil rig (publishedAtLeast view 1)
        adoptHolding rig first
        _ ← closeView view
        runOwner rig
        second ← newTarget 2
        style ← styleOf rig
        refused ← openView (rigViews rig) (OpenRequest (viewTarget second) (rigLease rig) (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
        either Just (const Nothing) refused `shouldBe` Just OpenTooManyViews
        -- the handback is adopted, the old frames complete, the chunks go
        adopt rig first
        meetBarriers rig
        settleUntil rig (Map.null . serviceOccupied <$> readTerrainViews (rigViews rig))
        _ ← openOn rig second
        pure ()

    it "counts a target's first build under way against the profile's targets, and its close as retiring" $
      withRig defaultOptions {optProfile = smallProfile {profileTargets = 1}} $ \rig → do
        first ← newTarget 1
        view ← openOn rig first
        index ← readTVarIO (rigNext rig)
        atomically (writeTVar (rigHold rig) (Just index))
        stop ← newTVarIO False
        let owner = do
              runOwner rig
              continue ← atomically ((False <$ (readTVar stop >>= check)) `orElse` (True <$ (readTVar (rigQueue rig) >>= check . not . Seq.null)))
              when continue owner
        second ← newTarget 2
        style ← styleOf rig
        withOwnedThread owner $ \_ ended → do
          timeout 10000000 (atomically (takeTMVar (rigEntered rig))) >>= maybe (expectationFailure "no build was held") pure
          closeView view `shouldReturn` CloseRetiring
          refused ← openView (rigViews rig) (OpenRequest (viewTarget second) (rigLease rig) (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
          either Just (const Nothing) refused `shouldBe` Just OpenTooManyViews
          atomically (putTMVar (rigResume rig) ())
          atomically (writeTVar stop True)
          ended
        settleUntil rig (Map.null . serviceOccupied <$> readTerrainViews (rigViews rig))
        Map.findWithDefault 0 (chunkRef index 1) <$> readTVarIO (rigAttempts rig) >>= (`shouldBe` 1)
        _ ← openOn rig second
        pure ()

    it "pins an adopted successor: a third revision waits while the drawn one and an adopted successor can still be drawn" $
      withPublished defaultOptions $ \rig target view → do
        first ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        adopt rig target
        atomically (noteSubmitted (rigReceipts rig) (worldTag first) (worldMetrics first))
        atomically (configureView view noConfigure {configureLight = Just brighter}) `shouldReturn` Right ()
        settleUntil rig (publishedAtLeast view 2)
        second ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        adoptHolding rig target
        atomically (configureView view noConfigure {configureLight = Just dimmer}) `shouldReturn` Right ()
        settleUntil rig ((== "building (0 to build)") . readingStage <$> readView view)
        runOwner rig
        atomically (readingPublished <$> readView view) `shouldReturn` Just (tagRevision (worldTag second))
        -- a frame draws the adopted successor: its plan is still pinned, and the third revision follows
        atomically (noteSubmitted (rigReceipts rig) (worldTag second) (worldMetrics second))
        drawn ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
        drawnTag (drawnPlanReceipt drawn) `shouldBe` worldTag second
        isJust (drawnPlanPlan drawn) `shouldBe` True
        atomically (kick (rigViews rig))
        settleUntil rig (publishedAtLeast view (tagRevision (worldTag second) + 1))
        again ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
        isJust (drawnPlanPlan again) `shouldBe` True

    it "moves a live view's receipt only: an offscreen batch advances it once complete, never once discarded or after the close" $
      withPublished defaultOptions $ \rig target view → do
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        let receipts = rigReceipts rig
            note = do
              ticket ← newTVarIO TicketPending
              atomically (noteOffscreenBatch receipts (readTVar ticket) (worldTag world) (worldMetrics world))
              pure ticket
        discarded ← note
        atomically (writeTVar discarded TicketDiscarded)
        atomically (readingDrawn <$> readView view) `shouldReturn` Nothing
        complete ← note
        atomically (readingDrawn <$> readView view) `shouldReturn` Nothing
        atomically (writeTVar complete TicketComplete)
        atomically (fmap drawnTag . readingDrawn <$> readView view) `shouldReturn` Just (worldTag world)
        late ← note
        _ ← closeView view
        atomically (writeTVar late TicketComplete)
        atomically (noteSubmitted receipts (worldTag world) (worldMetrics world))
        _ ← atomically (sweepOffscreen receipts)
        atomically (readReceipt receipts (viewIncarnation view)) `shouldReturn` Nothing

  describe "settlement" $ do
    it "ends every view when the owner's exit begins: a pending move settles as ended, and controls are refused" $
      withPublished defaultOptions $ \rig _ view → do
        Right move ← atomically (moveView view (JumpTarget (axis 4000) (axis 4000) (Just (axis 1))))
        endRigOwner rig "its exit began"
        eventually ((== ViewEnded EndStopped) . readingStatus <$> readView view)
        atomically (moveSettled move) `shouldReturn` Just (MoveEnded EndStopped)
        atomically (configureView view noConfigure {configureLight = Just brighter}) `shouldReturn` Left ControlEnded
        target ← newTarget 2
        style ← styleOf rig
        refused ← openView (rigViews rig) (OpenRequest (viewTarget target) (rigLease rig) (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
        either Just (const Nothing) refused `shouldBe` Just OpenStopped

    it "ends a refused barrier's retirement with the host's cause, and the service still drains" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        _ ← closeView view
        adopt rig target
        runOwner rig
        refuseBarriers rig "the lane refused the barrier"
        settleUntil rig ((== 0) . serviceRetiring <$> readTerrainViews (rigViews rig))
        failures ← atomically (serviceFailures <$> readTerrainViews (rigViews rig))
        [chunk | (_, Just chunk, cause) ← failures, "lane refused" `Text.isInfixOf` cause] `shouldMatchList` Set.toList (worldChunks world)

    it "refuses a plan whose visible demand exceeds the profile's regions, never publishing it as loading, and settles a move beyond them with pressure" $
      withRig defaultOptions {optProfile = smallProfile {profileRegions = 1}} $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitRegions visible 1) → visible > 1
          _ → False)
        atomically (latestWorld target) `shouldReturn` Nothing
        Right move ← atomically (moveView view (JumpTarget (axis 70) (axis 70) Nothing))
        settleUntil rig (isJust <$> moveSettled move)
        atomically (moveSettled move) >>= (`shouldSatisfy` \case
          Just (MovePressure (LimitRegions _ 1)) → True
          _ → False)

    it "copies the current visible demand first after a camera move, and publishes it with nothing visible loading" $ do
      -- the regions a first view copies, measured: the second service's profile holds exactly that many
      copied ← withPublished defaultOptions $ \rig target view → do
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        atomically (noteSubmitted (rigReceipts rig) (worldTag world) (worldMetrics world))
        drawn ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
        maybe (fail "no regions") (pure . Set.size) (drawnPlanRegions drawn)
      withPublished defaultOptions {optProfile = smallProfile {profileRegions = copied}} $ \rig target view → do
        Right move ← atomically (moveView view (JumpTarget (axis 70) (axis 70) (Just (axis 1))))
        settleUntil rig (publishedAtLeast view 2)
        atomically (moveSettled move) `shouldReturn` Just MoveLanded
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        atomically (noteSubmitted (rigReceipts rig) (worldTag world) (worldMetrics world))
        drawn ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
        plan ← maybe (fail "the drawn plan is not pinned") pure (drawnPlanPlan drawn)
        demandChunks (cdVisible (cellPlanDemand plan)) `shouldBe` []

    it "refuses a replacement whose plan meets a plan-wide bound, and keeps the drawing" $
      withPublished defaultOptions {optProfile = smallProfile {profileQuads = 4096}} $ \rig target view → do
        quiesce rig target
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        atomically (configureView view noConfigure {configureZoom = Just 0.125}) `shouldReturn` Right ()
        settleUntil rig (isJust . readingRefusal <$> readView view)
        reading ← atomically (readView view)
        readingRefusal reading `shouldSatisfy` \case
          Just (LimitPlan _) → True
          _ → False
        readingPublished reading `shouldBe` published
        atomically (latestWorld target) `shouldReturn` before

    it "refuses an open whose style misses a palette material or whose leases ended, leaving nothing held" $
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        let attempt style = openView (rigViews rig) (OpenRequest (viewTarget target) (rigLease rig) (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
        unmapped ← styleWith rig ["loam"] (pure True) >>= attempt
        either Just (const Nothing) unmapped `shouldSatisfy` \case
          Just (OpenStyle (StyleMissingMaterials [_])) → True
          _ → False
        ended ← styleWith rig ["loam", "granite"] (pure False) >>= attempt
        either Just (const Nothing) ended `shouldBe` Just OpenLeaseEnded
        atomically (writeTVar (targetAuthority target) False)
        windowGone ← styleOf rig >>= attempt
        either Just (const Nothing) windowGone `shouldBe` Just OpenLeaseEnded
        -- each refused style was released, and no claim or GPU interest stayed
        readTVarIO (rigStyleReleases rig) `shouldReturn` 3
        atomically (claimOf (rigClaims rig) 1) `shouldReturn` Nothing
        atomically (readingInterests <$> ledgerReading (rigLedger rig)) `shouldReturn` Map.empty

    it "asks a target with no frame metrics yet for its first frame at open, and plans once it has one" $
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        atomically (writeTVar (targetMetrics target) Nothing)
        view ← openOn rig target
        scenes ← readTVarIO (targetScenes target)
        map (graphicsWorld . snd) scenes `shouldBe` [Nothing]
        -- the frame it asked for is recorded at these metrics: the views notice them with no caller's kick
        atomically (writeTVar (targetMetrics target) (Just (metricsOf 320 240)))
        eventually (not . Seq.null <$> readTVar (rigQueue rig))
        settleUntil rig (publishedAtLeast view 1)

    it "keeps a window's M1 scene on open, and when the first terrain candidate is refused" $
      withRig defaultOptions {optWindow = 64} $ \rig → do
        target ← newTarget 1
        m1 ← prepare initialGraphicsScene
        atomically (writeTVar (targetScenes target) [(1, preparedValue m1)] >> writeTVar (targetMetrics target) Nothing)
        view ← openOn rig target
        -- the scene it shows stays: its frame's metrics, once noticed, start the view
        map fst <$> readTVarIO (targetScenes target) >>= (`shouldBe` [1])
        atomically (writeTVar (targetMetrics target) (Just (metricsOf 320 240)))
        settleUntil rig (isJust . readingRefusal <$> readView view)
        map fst <$> readTVarIO (targetScenes target) >>= (`shouldBe` [1])
        -- closed with its claim never published: returned directly, the M1 scene still shown
        _ ← closeView view
        map fst <$> readTVarIO (targetScenes target) >>= (`shouldBe` [1])

  describe "the service's end" $ do
    it "ends every view, drains its retirements and returns the reservation" $ do
      account ← withRig defaultOptions $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (publishedAtLeast view 1)
        pure (rigAccount rig)
      atomically (accountCharged account) `shouldReturn` 0

    it "returns the terrain service's every borrow when a view closes with a copy under way" $
      withPublished defaultOptions $ \rig _ view → do
        atomically (configureView view noConfigure {configureZoom = Just 2}) `shouldReturn` Right ()
        runOwner rig
        _ ← closeView view
        runOwner rig
        timeout 10000000 (atomically (inspectRetainedChargesSTM (rigTerrain rig) >>= \(held, borrows) → check (held == 0 && null borrows)))
          >>= (`shouldBe` Just ())

    it "answers an interrupted drain: the reservation returns, what was retiring is recorded with the interruption, which is raised after the cleanup" $ do
      held ← newIORef Nothing
      outcome ← timeout 3000000 . withRig defaultOptions {optTeardown = TeardownNone} $ \rig → do
        writeIORef held (Just (rigAccount rig, rigViews rig))
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (publishedAtLeast view 1)
      outcome `shouldBe` Nothing
      (account, views) ← readIORef held >>= maybe (fail "the rig never started") pure
      atomically (accountCharged account) `shouldReturn` 0
      failures ← atomically (serviceFailures <$> readTerrainViews views)
      failures `shouldSatisfy` (not . null)
      failures `shouldSatisfy` all (\(_, _, cause) → "drain was interrupted" `Text.isInfixOf` cause)

    it "ends what the owner can no longer dispose of as failures with the owner's cause" $ do
      failures ← withRig defaultOptions $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (publishedAtLeast view 1)
        atomically (writeTVar (rigQueueOpen rig) False)
        atomically (writeTVar (rigOwnerEnded rig) (Just "the device was lost"))
        pure (rigViews rig)
      atomically (serviceFailures <$> readTerrainViews failures) >>= (`shouldSatisfy` all (\(_, _, cause) → "device was lost" `Text.isInfixOf` cause))

  describe "evidence" $
    it "records the profile's counts, the declared reservation, the occupancy and the peak heap of a full view" $
      withPublished defaultOptions {optProfile = defaultViewProfile} $ \rig target view → do
        quiesce rig target
        reading ← atomically (readTerrainViews (rigViews rig))
        published ← atomically (readingListed <$> readView view)
        enabled ← getRTSStatsEnabled
        peak ← if enabled then Just . max_live_bytes <$> getRTSStats else pure Nothing
        let r = reservation defaultViewProfile
        putStrLn
          ( "EVIDENCE terrain-views profile=" <> show defaultViewProfile
              <> " reservation=" <> show (reserveTotal r)
              <> " occupied=" <> show (Map.toList (serviceOccupied reading))
              <> " chunks=" <> show published
              <> " peak-live-bytes=" <> maybe "unmeasured (+RTS -T)" show peak
          )
        published `shouldSatisfy` (> 0)

-- The plan the planner makes from fresh copies of the drawn plan's regions, at its camera and metrics: what the view
-- must have drawn.
independentPlan ∷ Rig → DrawnPlan Int → IO CellPlan
independentPlan rig drawn = do
  regions ← maybe (fail "no regions") (pure . Set.toList) (drawnPlanRegions drawn)
  camera ← maybe (fail "no camera") pure (drawnPlanCamera drawn)
  metrics ← maybe (fail "no metrics") pure (drawnPlanMetrics drawn)
  copies ← fmap concat . mapM (copyOf . take 64) . takeWhile (not . null) . iterate (drop 64) $ regions
  combined ← either (fail . show) pure (combineCopies copies)
  (facts, knowledge) ← either (fail . show) pure (planInputs (ChangeLimits (profileRuns smallProfile)) combined)
  let config = viewCellConfig defaultTerrainViewsConfig {tvProfile = smallProfile}
      inputs = CellInputs (CellRequest (factsVersions facts) camera (viewSetup metrics) config) facts knowledge (styleAssets (rigStyle rig))
  either (fail . show) pure (planCells inputs)
  where
    copyOf batch =
      withRegionSnapshot (rigTerrain rig) (rigLease rig) batch (either (fail . show) (pure . pure)) >>= either (fail . show) pure

-- The 16 x 16 region of the rotated view frame a quad's key is in, with its level's 32-level region.
regionOfKey ∷ CellKey → (Integer, Integer, Integer)
regionOfKey (CellKey _ z vx vy _) = (vx `div` 16, vy `div` 16, z `div` 32)
