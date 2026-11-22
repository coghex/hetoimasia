-- | Terrain views (TRA-9) over the production terrain service, with a graphics owner the example steps itself.
--
-- The rig's owner is a queue the example drains: every owner action the views admit is run, with fake hands that
-- prepare each chunk with the renderer's own 'prepareRetainedChunk' and record its disposal, until the views ask for nothing
-- more. The release lane is a FIFO queue the example meets; the target records what it was published and adopts
-- what the example says it adopted. The terrain service is the real one, so copies settle on its own owner; an
-- example waits, bounded, for the step its settlement asks for.
--
-- Every assertion is an outcome or one of the design's six guarantees: what was published, what it lists, what was
-- disposed of and when it may be, how each operation settled. None asserts an order, a step count or a timing.
module Test.LuaEngine.Graphics.TerrainViews (spec) where

import Control.Concurrent.STM
import Control.Monad (forM, forM_, unless, void, when)
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
import Hetoimasia.Foundation.Admission (admissionToken, closeAdmission, newAdmissionIO)
import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.GPU.Vulkan.GLFW (Refusal (RefusedDeviceAbsent), UploadRefusal (UploadClosed), UploadState (UploadLost), UploadsUnavailable (..), VulkanUploadRefusal (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostUploadAnswer)
import Hetoimasia.Render.TwoD.Vulkan.Builders (BufferUploadRefusal (..))
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.TerrainView.Internal hiding (styleAssets)
import Hetoimasia.LuaEngine.Graphics.Texture (textureHandleOf)
import Hetoimasia.LuaEngine.Texture (RenderAccount, accountCharged, newRenderAccount)
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (DeriveBounds), Chunk, ChunkKind (ChunkWorldDepth), ChunkRef, chunksFrom)
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (cutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Snapshot (Instance (instanceTexture))
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..))
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import Hetoimasia.Render.TwoD.Vulkan.Chunks (BuildRefusal (BuildRaised, BuildUploadsNotReady), BuildRefused (..), ChunkStanding (..), RefusedAllocation (NoAllocation), Retained, chunkStandingSTM, newRetained, prepareRetainedChunk, preparedChunk, receiptsHeld)
import qualified Hetoimasia.Render.TwoD.Vulkan.Chunks as Chunks
import Hetoimasia.Render.TwoD.Vulkan.Builders (bufferUploads)
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRefIndex)
import Test.LuaEngine.Graphics.NativeStandIn (StandIn, completeBatches, discardedBatch, disposeNow, failNextWrite, settleUploads, standInBuilders, standInDisposal, submittedBatch, withStandIn)
import Hetoimasia.Terrain.Cell (mkMaterialId)
import Hetoimasia.Terrain.Coordinate (AxisCoord, axisFromInteger, axisValue, tileCoord)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), boundPackedTextures, loadAtlasStyle)
import qualified Hetoimasia.Terrain.Render2D.AtlasFixtures as Fixture
import qualified Hetoimasia.Terrain.Render2D.AtlasAssets as Atlas
import Hetoimasia.Asset.Image.DataMap (coverageHeight, coverageWidth)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (combineCopies, planInputs, plannerRuns)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Coordinate (RegionCoord (..))
import Hetoimasia.Terrain.Changes (ChangeLimits (..))
import Hetoimasia.Terrain.Render2D.Camera (CameraConfig (..), JumpTarget (..), camAnchorX, camAnchorY, camRef, camSurface)
import Hetoimasia.Terrain.Render2D.Cells (CellConfig (..), CellInputs (..), CellLimits (..), CellKey (..), CellPlan, CellRequest (..), PartKind (PartFog), cellPlanPending, cellPlanQuads, planCells, quadKey, quadPart)
import Hetoimasia.Terrain.Render2D.Facts (TerrainFacts (..))
import Hetoimasia.Terrain.Render2D.Material (recordLayout)
import Hetoimasia.Terrain.Render2D.Presentation (pushBlockBytes)
import Hetoimasia.Terrain.Render2D.Presentation (LightInput (..), LightSettings, defaultLightInput, defaultLightSettings, mkLightSettings)
import Hetoimasia.Terrain.Runtime hiding (closeView, openView, viewIncarnation)
import Hetoimasia.Terrain.Runtime.Storage (filesystemOf, minHeadroomBytes, mkStorageConfig)
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), defaultStoreSpec, minAllowanceBytes)
import Hetoimasia.Terrain.Residency (Limits, LimitsSpec (..), RegionDemand (..), ViewInfo (..), mkLimits, modelViews)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec hiding (after, before, it)
import qualified Test.Hspec as Hspec
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Hetoimasia.GLFW.Window (Attribute (..), ContentScale (..), Extent (..))
import Hetoimasia.LuaEngine.Graphics.Window.Host (WindowGeometry (..), geometryOfAttributes)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), ExceptionWithContext (ExceptionWithContext), SomeException, displayException, finally, rethrowIO, throwIO, toException, try, tryWithContext)
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
  , rigUnavailable ∷ !(TVar (Set.Set RegionCoord))
    -- ^ Regions whose terrain part the views read as unavailable at their copy boundary (a storage fault).
  , rigAdmission ∷ !(TVar (Maybe Admission))
    -- ^ How the host's uploads answer a part's admission, observed or reserved alike: 'Nothing' admits.
  , rigAdmitBudget ∷ !(TVar (Maybe Int))
    -- ^ When set, how many more grants the uploads give before their room is taken ('AdmitLater').
  , rigGrants ∷ !(TVar Int)
    -- ^ Grants reserved and not yet spent or given back.
  , rigUploading ∷ !(TVar Bool)
    -- ^ Whether a chunk built now is uploading (the example settles it), rather than ready at once.
  , rigDemandRefused ∷ !(TVar (Maybe Text))
    -- ^ A refusal the demand boundary answers in place of the terrain service's.
  , rigBuildAttempts ∷ !(TVar Int)
    -- ^ How many granted builds the fake hands spent: each makes a buffer.
  , rigFailNext ∷ !(TVar [Maybe BuildFailure])
    -- ^ The outcomes of the next builds, in order: a failure, or a build as usual.
  , rigRaising ∷ !(TVar (Maybe SomeException))
    -- ^ When set: the next granted build's constructor raises it before making a buffer: sealed with no allocation and
    -- the cause, then raised.
  , rigRaiseSealed ∷ !(TVar (Maybe SomeException))
    -- ^ What the next failed build raises once sealed: its receipt is sealed, then the exception goes on.
  , rigReceiptNext ∷ !(TVar Word64)
    -- ^ The next receipt's key.
  , rigRegistry ∷ !(TVar (Map.Map Word64 (TVar (Maybe (Either BuildFailure ChunkRef)))))
    -- ^ The receipts the fake renderer holds unclaimed, by key: sealed once they hold an outcome.
  , rigAfterSeal ∷ !(TVar (Maybe (STM ())))
    -- ^ When set: run once in the next build's sealing transaction.
  , rigFault ∷ !(TVar (Maybe (HeldTarget, HeldFault, Bool)))
    -- ^ When set: the next build's seal makes this target's version read fail, for the rest of that owner step (and
    -- notes that it fired); the step's end clears it.
  , rigCountGate ∷ !(TVar (Maybe (Int → Bool, TMVar [RegionCoord], TMVar ())))
    -- ^ When set: the first held copy whose counted total satisfies the test names its batch here, once its total is
    -- counted, and waits until the example resumes it.
  , rigNative ∷ !(Maybe Native)
    -- ^ The native stand-in, for an example whose hands are the renderer's registry over the backend's own uploads.
  , rigBeforeCollect ∷ !(TVar (Maybe (IO ())))
    -- ^ When set: run once on the owner's thread after the next build's revalidation succeeded, before its collection.
  }

-- | An example's native stand-in: the session, the renderer's registry the production hands admit into
-- ('registryHands'), and what the example controls of them.
data Native = Native
  { nativeStandIn ∷ !StandIn
  , nativeRetained ∷ !Retained
  , nativeDisposing ∷ !(TVar Bool)
    -- ^ Whether the owner's turns destroy released buffers (a destruction is held pending while not).
  , nativeHoldClaim ∷ !(TVar Bool)
    -- ^ When set: the next grant's receipt answers no claim (it reads as unsealed) until the example lets it go.
  , nativeClaimsHeld ∷ !(TVar (Set.Set Word64))
    -- ^ The receipts whose claims are held, by key.
  , nativeGrants ∷ !(TVar [(Word64, ChunkRef)])
    -- ^ Every grant's receipt key and reference, oldest first.
  , nativeAdmitted ∷ !(TVar Word32)
    -- ^ How many grants the registry gave: the next is held when 'rigHold' names its ordinal.
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
  , optCells ∷ CellConfig → CellConfig
  , optCamera ∷ CameraConfig → CameraConfig
  , optNative ∷ Bool
    -- ^ Whether the hands are the renderer's registry over the native stand-in's uploads, rather than the fake's.
  }

defaultOptions ∷ Options
defaultOptions = Options TeardownFull smallProfile 196608 id id id False

-- A small profile: enough for the examples' views, small enough that its caps are reachable.
smallProfile ∷ ViewProfile
smallProfile = defaultViewProfile {profileSlots = 64, profileQuads = 8192, profilePending = 4096, profileRegions = 64}

-- A profile of six slots, which a zoomed-out replacement cannot fit beside the drawn revision.
slotted ∷ ViewProfile
slotted = smallProfile {profileSlots = 6, profileQuads = 3072}

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
        unavailable ← newTVarIO Set.empty
        admission ← newTVarIO Nothing
        admitBudget ← newTVarIO Nothing
        grants ← newTVarIO 0
        uploading ← newTVarIO False
        demandRefused ← newTVarIO Nothing
        buildAttempts ← newTVarIO 0
        failNext ← newTVarIO []
        raising ← newTVarIO Nothing
        raiseSealed ← newTVarIO Nothing
        receiptNext ← newTVarIO 0
        registry ← newTVarIO Map.empty
        afterSeal ← newTVarIO Nothing
        fault ← newTVarIO Nothing
        countGate ← newTVarIO Nothing
        beforeCollect ← newTVarIO Nothing
        initial ← prepare initialGraphicsScene
        withNativeOf (optNative options) $ \native → do
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
                 , ownerStanding = \chunk → maybe (Map.lookup chunk <$> readTVar standings) (\held → chunkStandingSTM (nativeRetained held) chunk) native
                 , ownerMaterial = materialRef 11 (MaterialFacts True recordLayout (fromIntegral pushBlockBytes))
                 , ownerRegionWindow = optWindow options
                 , ownerDepthQualified = True
                 , ownerRoom = \prepared → case native of
                     Nothing → roomOf admission admitBudget
                     Just held → roomOf admission admitBudget >>= either (pure . Left) (const (registryRoom (bufferUploads (standInBuilders (nativeStandIn held))) (nativeRetained held) prepared))
                 , ownerReceiptsHeld = case native of
                     Just held → receiptsHeld (nativeRetained held)
                     Nothing → do
                       cells ← Map.elems <$> readTVar registry
                       sealed ← length . filter isJust <$> mapM readTVar cells
                       pure (length cells, sealed)
                 , ownerEnded = readTVar ownerEnded
                 }
             hooks =
               CopyHooks
                 { hookUnavailable = readTVar unavailable
                 , hookCounting = \batch total → do
                     gate ← atomically $
                       readTVar countGate >>= \case
                         Just (crosses, counting, resumed) | crosses total → Just (counting, resumed) <$ writeTVar countGate Nothing
                         _ → pure Nothing
                     forM_ gate $ \(counting, resumed) → atomically (putTMVar counting batch) >> atomically (takeTMVar resumed)
                 , hookDemandRefused = \_ → readTVar demandRefused
                 , hookCollecting = atomically (readTVar beforeCollect <* writeTVar beforeCollect Nothing) >>= sequence_
                 }
             ports = TerrainViewsPorts owner ledger claims receipts initial terrain client account hooks
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
                     forM_ native settleNative
                     loop
               loop
             rig views = Rig views terrain lease queue queueOpen lane laneCapacity standings chunks disposed attempts buildFailure disposeFailure next ledger claims receipts ownerEnded style account deferDisposal pendingDisposals hold entered resume styleReleases unavailable admission admitBudget grants uploading demandRefused buildAttempts failNext raising raiseSealed receiptNext registry afterSeal fault countGate native beforeCollect
             fakeHands = stepHands (rig (error "the teardown's hands read no service"))
         withOwnedThread (when (optTeardown options /= TeardownNone) teardown) $ \_ _ →
           withTerrainViews (configOf options) ports $ \views →
             body (rig views) `finally` atomically (writeTVar ending True)

-- The native stand-in an example asked for, for the length of the body.
withNativeOf ∷ Bool → (Maybe Native → IO a) → IO a
withNativeOf False body = body Nothing
withNativeOf True body =
  withStandIn $ \standIn → do
    native ← Native standIn <$> newRetained <*> newTVarIO True <*> newTVarIO False <*> newTVarIO Set.empty <*> newTVarIO [] <*> newTVarIO 0
    body (Just native)

-- The hands an owner step is lent: the native stand-in's when the example has one, the fake's otherwise.
stepHands ∷ Rig → Hands
stepHands rig = maybe (hands rig) (nativeHands rig) (rigNative rig)

-- After a step with the native stand-in: its uploads are recorded and completed, and released buffers are destroyed
-- unless the example holds their destruction.
settleNative ∷ Native → IO ()
settleNative native = do
  settleUploads (nativeStandIn native)
  disposing ← readTVarIO (nativeDisposing native)
  when disposing (disposeNow (nativeStandIn native))

-- The production hands over the renderer's registry and the stand-in's uploads ('registryHands'), with what the example
-- controls of them: the fake's admission answer and budget (cells, read before the registry decides), the ordinal of a
-- grant whose spend waits until resumed (before the renderer's spend begins), the held target's fault armed once the
-- renderer's spend has sealed its outcome, and a receipt whose claim reads as unsealed until the example lets it go.
nativeHands ∷ Rig → Native → Hands
nativeHands rig native =
  production
    { handReserve = \prepared →
        roomOf (rigAdmission rig) (rigAdmitBudget rig) >>= \case
          Left refusal → pure (Left refusal)
          Right () →
            Chunks.admitRetainedChunk (bufferUploads builders) (nativeRetained native) prepared >>= \case
              Left refusal → pure (Left (viewAdmission refusal))
              Right granted → do
                let grant = viewGrant (standInDisposal standIn) builders (nativeRetained native) granted
                    grantedReference = Chunks.chunkGrantReference granted
                modifyTVar' (rigAdmitBudget rig) (fmap (subtract 1))
                ordinal ← stateTVar (nativeAdmitted native) (\count → (count + 1, count + 1))
                let receipt = grantReceipt grant
                    key = receiptKey receipt
                modifyTVar' (nativeGrants native) (<> [(key, grantedReference)])
                holding ← readTVar (nativeHoldClaim native)
                when holding (writeTVar (nativeHoldClaim native) False >> modifyTVar' (nativeClaimsHeld native) (Set.insert key))
                pure . Right $
                  grant
                    { grantSpend = (held ordinal >> grantSpend grant) `finally` atomically arm
                    , grantReceipt = receipt {receiptClaim = readTVar (nativeClaimsHeld native) >>= \claims → if Set.member key claims then pure Nothing else receiptClaim receipt}
                    }
    }
  where
    standIn = nativeStandIn native
    builders = standInBuilders standIn
    production = registryHands prepareOf (standInDisposal standIn) builders (nativeRetained native)
    -- the instances' own textures marked, as the production hands mark the registered art: each part has bytes, and its
    -- build makes and fills a buffer
    prepareOf instances records = pure (either (Left . Text.pack . show) Right (prepareRetainedChunk (cutoutMarks (Set.toList (Set.fromList (map instanceTexture instances)))) ChunkWorldDepth DeriveBounds (Map.singleton material records) instances))
    material = materialRef 11 (MaterialFacts True recordLayout (fromIntegral pushBlockBytes))
    held ordinal = do
      waits ← atomically $ do
        hold ← readTVar (rigHold rig)
        if hold == Just ordinal then True <$ (writeTVar (rigHold rig) Nothing >> putTMVar (rigEntered rig) ()) else pure False
      when waits (atomically (takeTMVar (rigResume rig)))
    arm =
      readTVar (rigFault rig) >>= \case
        Just (faulty, failing, False) → setHeldFault faulty (Just failing) >> writeTVar (rigFault rig) (Just (faulty, failing, True))
        _ → pure ()

-- The views' configuration an example's options give.
configOf ∷ Options → TerrainViewsConfig
configOf options = defaultTerrainViewsConfig {tvProfile = optProfile options, tvCells = optCells options (tvCells defaultTerrainViewsConfig), tvCamera = optCamera options (tvCamera defaultTerrainViewsConfig)}

cameraLimits ∷ Limits
cameraLimits = cameraLimitsWith 4

-- The runtime's limits with this many camera regions.
cameraLimitsWith ∷ Int → Limits
cameraLimitsWith camera =
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
      , specCameraRegions = fromIntegral camera
      }
  where
    mib = 1024 * 1024

-- How the fake host's uploads answer a part's admission: what the example set, or its budget of grants spent.
roomOf ∷ TVar (Maybe Admission) → TVar (Maybe Int) → STM (Either Admission ())
roomOf admission budget = do
  answer ← readTVar admission
  left ← readTVar budget
  pure $ case (answer, left) of
    (Just refusal, _) → Left refusal
    (Nothing, Just 0) → Left (AdmitLater "the uploads' last queue place is taken")
    _ → Right ()

-- The fake hands: a part is prepared by the renderer itself; a grant comes from the fake uploads' answer, and its
-- build makes render-2d's own description of the instances under the material's records, ready at once unless the
-- example says otherwise. A build seals its outcome into its receipt in its own transaction, as the renderer does, and
-- then returns (or, as the example asks, raises); the view collects the receipt.
hands ∷ Rig → Hands
hands rig =
  Hands
    { handPrepare = \instances records →
        pure (either (Left . Text.pack . show) Right (prepareRetainedChunk noCutoutMarks ChunkWorldDepth DeriveBounds (Map.singleton material records) instances))
    , handReserve = \prepared →
        roomOf (rigAdmission rig) (rigAdmitBudget rig) >>= \case
          Left refusal → pure (Left refusal)
          Right () → do
            modifyTVar' (rigAdmitBudget rig) (fmap (subtract 1))
            modifyTVar' (rigGrants rig) (+ 1)
            live ← newTVar True
            cell ← newTVar Nothing
            key ← readTVar (rigReceiptNext rig)
            writeTVar (rigReceiptNext rig) (key + 1)
            modifyTVar' (rigRegistry rig) (Map.insert key cell)
            let giveBack = readTVar live >>= \held → when held (writeTVar live False >> modifyTVar' (rigGrants rig) (subtract 1))
                seal outcome = writeTVar cell (Just outcome)
                receipt =
                  Receipt
                    { receiptKey = key
                    , receiptOutcome = readTVar cell
                    , receiptClaim = claimRigReceipt rig key
                    }
                abandon = readTVar live >>= \held → when held (giveBack >> seal (Left (BuildFailed "BuildAbandoned" NotAllocated)))
            raising ← readTVar (rigRaising rig)
            writeTVar (rigRaising rig) Nothing
            pure . Right $ case raising of
              -- a constructor that raised before any buffer: sealed with its cause, then raised
              Just raised → Grant (atomically (giveBack >> seal (Left (BuildFailed (Text.pack (show (BuildRaised (Text.pack (displayException raised))))) NotAllocated))) >> throwIO raised) abandon receipt
              Nothing → Grant (spend prepared giveBack seal) abandon receipt
    , handSweepReceipts = do
        keys ← Map.keys <$> readTVar (rigRegistry rig)
        concat <$> forM keys (\key → maybe [] (\outcome → [(key, outcome)]) <$> claimRigReceipt rig key)
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
    spend prepared giveBack seal = do
      upcoming ← readTVarIO (rigNext rig)
      held ← atomically $ do
        hold ← readTVar (rigHold rig)
        if hold == Just upcoming then True <$ (writeTVar (rigHold rig) Nothing >> putTMVar (rigEntered rig) ()) else pure False
      when held (atomically (takeTMVar (rigResume rig)))
      raised ← atomically $ do
        receipt ← built
        seal receipt
        readTVar (rigAfterSeal rig) >>= mapM_ id
        writeTVar (rigAfterSeal rig) Nothing
        readTVar (rigFault rig) >>= \case
          Just (faulty, failing, False) → setHeldFault faulty (Just failing) >> writeTVar (rigFault rig) (Just (faulty, failing, True))
          _ → pure ()
        case receipt of
          Left _ → readTVar (rigRaiseSealed rig) <* writeTVar (rigRaiseSealed rig) Nothing
          Right _ → pure Nothing
      mapM_ throwIO raised
      where
       built = do
        modifyTVar' (rigBuildAttempts rig) (+ 1)
        giveBack
        next ← readTVar (rigFailNext rig)
        persistent ← readTVar (rigBuildFailure rig)
        failure ← case next of
          outcome : rest → outcome <$ writeTVar (rigFailNext rig) rest
          [] → pure persistent
        case failure of
          Just why → pure (Left why)
          Nothing → do
            index ← readTVar (rigNext rig)
            writeTVar (rigNext rig) (index + 1)
            uploading ← readTVar (rigUploading rig)
            let chunk = chunkRef index 1
            modifyTVar' (rigChunks rig) (Map.insert chunk (preparedChunk prepared))
            modifyTVar' (rigStandings rig) (Map.insert chunk (if uploading then ChunkUploading else ChunkReady))
            pure (Right chunk)

-- Run the owner until the views ask for nothing more: every queued action, with the fake hands. A step that raises has
-- run (this owner outlives it), and its exception goes on to the example.
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
          -- a target fault armed in this step lasts for this step alone; a step that raises is answered as the host
          -- answers it (which ends the views' owner), and its exception goes on to the example
          ran ← tryWithContext @SomeException (step (stepHands rig))
          atomically disarm
          -- the native stand-in's uploads progress, and its released buffers are destroyed, after each step
          forM_ (rigNative rig) settleNative
          case ran of
            Left failure@(ExceptionWithContext _ raised) → do
              atomically (writeTVar outcome (Just (StepRaised (Text.pack (displayException raised)))))
              rethrowIO failure
            Right () → atomically (writeTVar outcome (Just StepRan)) >> go (n - 1)

    disarm =
      readTVar (rigFault rig) >>= \case
        Just (held, _, True) → setHeldFault held Nothing >> writeTVar (rigFault rig) Nothing
        _ → pure ()

-- Claim a receipt the fake renderer holds, once: its outcome, if sealed; the registry forgets it.
claimRigReceipt ∷ Rig → Word64 → STM (Maybe (Either BuildFailure ChunkRef))
claimRigReceipt rig key =
  Map.lookup key <$> readTVar (rigRegistry rig) >>= \case
    Just cell →
      readTVar cell >>= \case
        Just outcome → Just outcome <$ modifyTVar' (rigRegistry rig) (Map.delete key)
        Nothing → pure Nothing
    Nothing → pure Nothing

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
  timeout 8000000 loop >>= \case
    Just () → pure ()
    Nothing → do
      reading ← atomically (readTerrainViews (rigViews rig))
      views ← atomically (viewReadings (rigViews rig))
      expectationFailure ("the views never settled: " <> show views <> ", occupied " <> show (Map.toList (serviceOccupied reading)) <> ", retiring " <> show (serviceRetiring reading) <> ", failures " <> show (serviceFailures reading))
  where
    loop = do
      runOwner rig
      finished ← atomically done
      -- a step to run, or the condition met by the views' own threads (the watcher's sweep needs no step)
      unless finished $ do
        atomically ((readTVar (rigQueue rig) >>= \q → check (not (Seq.null q))) `orElse` (done >>= check))
        loop

-- A target held in memory (its facts set through its own transitions, what it was published newest first), and the
-- revision the fake host adopted.
data Target = Target
  { targetKey ∷ !Int
  , targetHeld ∷ !HeldTarget
  , targetAdopted ∷ !(TVar (Maybe Word64))
  }

metricsOf ∷ Int → Int → TargetMetrics
metricsOf w h = TargetMetrics (PixelExtent w h) (PixelExtent w h) 1 1

newTarget ∷ Int → IO Target
newTarget key = Target key <$> atomically (newHeldTarget (Just (metricsOf 320 240))) <*> newTVarIO Nothing

viewTarget ∷ Target → ViewTarget Int
viewTarget target = ViewTarget (targetKey target) (HeldSurface (targetHeld target)) True

-- What the target was published, newest first, with the revision it gave each.
targetScenes ∷ Target → STM [(Word64, GraphicsScene)]
targetScenes = heldScenes . targetHeld

-- The host adopts the target's latest revision, and its frames of the one before have completed: that one is released.
adopt ∷ Rig → Target → IO ()
adopt rig target = do
  (scenes, previous) ← atomically ((,) <$> targetScenes target <*> readTVar (targetAdopted target))
  case scenes of
    (revision, scene) : _ | Just revision /= previous → do
      ledgerAdopted (rigLedger rig) (targetKey target) (fromIntegral revision) scene
      forM_ previous (ledgerReleased (rigLedger rig) (targetKey target) . fromIntegral)
      atomically (writeTVar (targetAdopted target) (Just revision))
      noticed rig
    _ → pure ()

-- The host adopts the latest revision while a frame of the one before is still in flight: both stay held.
adoptHolding ∷ Rig → Target → IO ()
adoptHolding rig target = do
  scenes ← atomically (targetScenes target)
  case scenes of
    (revision, scene) : _ → do
      ledgerAdopted (rigLedger rig) (targetKey target) (fromIntegral revision) scene
      atomically (writeTVar (targetAdopted target) (Just revision))
      noticed rig
    [] → pure ()

-- Wait (bounded) until the views' watcher has seen the ledger's latest change, and so asked for any step it needs.
noticed ∷ Rig → IO ()
noticed rig = eventually ((>=) <$> ledgerNoticed (rigViews rig) <*> ledgerChanges (rigLedger rig))

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
  targetScenes target >>= \case
    (_, scene) : _ → pure (graphicsWorld scene)
    [] → pure Nothing

publishedAtLeast ∷ TerrainView Int → Word64 → STM Bool
publishedAtLeast view revision = maybe False (>= revision) . readingPublished <$> readView view

styleOf ∷ Rig → IO ViewStyle
styleOf rig = styleWith rig ["loam", "granite"] True

-- A style whose mapping gives a region to these materials, whose parents' leases are live while this says so, and
-- whose release is counted.
styleWith ∷ Rig → [String] → Bool → IO ViewStyle
styleWith rig mapped live = do
  authority ← newAdmissionIO
  unless live (atomically (closeAdmission authority))
  textures ← boundPackedTextures (rigStyle rig) (textureHandleOf colourIdentity) (textureHandleOf normalIdentity)
  pure
    ViewStyle
      { styleSnapshot = styleAssets (rigStyle rig)
      , styleBound = textures
      , styleParents = Set.fromList [colourIdentity, normalIdentity]
      , styleMapped = Set.fromList [either (error . show) id (mkMaterialId name) | name ← mapped]
      , styleAuthority = [HeldAuthority (admissionToken authority)]
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

-- Every example is bounded ("Test.Support.Bounded"): a hang fails in seconds instead of holding the run.
it ∷ HasCallStack ⇒ String → IO () → Spec
it name = Hspec.it name . bounded

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
    it "draws what the planner plans from complete inputs around F, rotated and cut through fog, before and after an edit" $
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
              pure (cellPlanQuads plan)
        before' ← check'
        -- more than one region contributes to the fixture's plan
        Set.size (Set.fromList [regionOfKey (quadKey quad) | quad ← before']) `shouldSatisfy` (> 1)
        Right removal ← removeAt (rigTerrain rig) (rigLease rig) (either (error . show) id (tileCoord 2 2 1)) Nothing
        _ ← await (rigTerrain rig) removal
        settleUntil rig (publishedAtLeast view 2)
        after' ← check'
        after' `shouldNotBe` before'
        -- rotated, and cut below the surface through undiscovered ground: fog conceals it, still as the oracle plans
        atomically (configureView view noConfigure {configureFacing = Just FaceWest, configureDepth = Just (axis (-10))}) `shouldReturn` Right ()
        settleUntil rig (publishedAtLeast view 3)
        cut ← check'
        [() | quad ← cut, quadPart quad == PartFog] `shouldSatisfy` (not . null)

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
        -- a zoom out rebuilds every chunk: more than the slots left beside the drawn revision's
        atomically (configureView view noConfigure {configureZoom = Just 0.5}) `shouldReturn` Right ()
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
        atomically (targetScenes target) `shouldReturn` []
        readTVarIO (rigChunks rig) `shouldReturn` Map.empty

    it "refuses when the terrain service refuses the copy, and keeps the drawing" $
      withRig defaultOptions {optRuntime = \c → c {configRetainedBytes = 4096}} $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitRuntime _) → True
          _ → False)
        atomically (targetScenes target) `shouldReturn` []

    it "refuses a candidate whose copies hold more input runs and intervals than the profile allows, across split copies, counting every column's runs" $ do
      -- one region's copy: its knowledge is one class of several runs shared by every column, which the planner is
      -- handed column by column
      (expanded, compressed) ← withRig defaultOptions $ \rig → do
        snapshot ← withRegionSnapshot (rigTerrain rig) (rigLease rig) [RegionCoord 0 0 0] (either (fail . show) pure) >>= either (fail . show) pure
        let classes = [D.regionKnowledgeClasses known | region ← regionSnapshotRegions snapshot, PartReady known ← [regionKnowledge snapshot region]]
        case classes of
          [[shared]] | length shared > 1 → pure (plannerRuns Set.empty snapshot, length shared)
          _ → fail ("the fixture's region is not one shared multi-run class: " <> show (map (map length) classes))
      -- every one of the region's 256 columns is charged the shared class's k runs
      expanded `shouldBe` 256 * compressed
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
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 0 0)))
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
        scenes ← atomically (targetScenes target)
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
        atomically (writeTVar (rigBuildFailure rig) (Just (BuildFailed "an injected failure" NotAllocated)))
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
        atomically (setHeldUsable (targetHeld target) False)
        eventually (not . Seq.null <$> readTVar (rigQueue rig))
        settleUntil rig ((== ViewEnded EndTargetGone) . readingStatus <$> readView view)
        atomically (claimOf (rigClaims rig) 1) `shouldReturn` Nothing

    it "hands a failed handback's chunks to the session's teardown when the service ends while its target still shows them" $ do
      held ← newIORef Nothing
      _ ← withPublished defaultOptions {optTeardown = TeardownLive} $ \rig target view → do
        quiesce rig target
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        atomically (setHeldAccepts (targetHeld target) False)
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
        atomically (setHeldAccepts (targetHeld target) False)
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
        readTVarIO (rigGrants rig) `shouldReturn` 0

    it "waits for the owner's running build before the service returns its reservation, and disposes of what it built" $ do
      box ← newEmptyTMVarIO
      viewBox ← newEmptyTMVarIO
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
            -- the gate: the scope's shutdown has ended the view (nothing else ends it here), so the held chunk can only go
            -- to disposal and nothing is published; the drain waits for the held step, and the reservation is still charged
            view ← atomically (readTMVar viewBox)
            atomically (readView view >>= check . (== ViewEnded EndStopped) . readingStatus)
            atomically (accountCharged (rigAccount rig)) >>= atomically . putTMVar charged
            atomically (putTMVar (rigResume rig) ())
      withOwnedThread owner $ \_ _ →
        withOwnedThread controller $ \_ controllerEnded → do
          withRig defaultOptions {optTeardown = TeardownNone} $ \rig → do
            target ← newTarget 1
            view ← openOn rig target
            held ← readTVarIO (rigNext rig)
            atomically (writeTVar (rigHold rig) (Just held))
            atomically (putTMVar viewBox view >> putTMVar box rig)
            timeout 10000000 (atomically (readTVar seenHeld >>= check)) >>= maybe (expectationFailure "the build was never held") pure
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

    it "does not settle a newer move with the refusal of the preparation it overtook" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        index ← readTVarIO (rigNext rig)
        atomically (writeTVar (rigHold rig) (Just index))
        stop ← newTVarIO False
        let owner = do
              runOwner rig
              continue ← atomically ((False <$ (readTVar stop >>= check)) `orElse` (True <$ (readTVar (rigQueue rig) >>= check . not . Seq.null)))
              when continue owner
        -- a rebuild whose first build is held; the move arrives meanwhile, and the build is then refused
        atomically (configureView view noConfigure {configureZoom = Just 0.5}) `shouldReturn` Right ()
        move ← withOwnedThread owner $ \_ ended → do
          timeout 10000000 (atomically (takeTMVar (rigEntered rig))) >>= maybe (expectationFailure "no build was held") pure
          Right move ← atomically (moveView view (JumpTarget (axis 70) (axis 70) (Just (axis 1))))
          atomically (writeTVar (rigBuildFailure rig) (Just (BuildFailed "an injected failure" NotAllocated)) >> putTMVar (rigResume rig) ())
          atomically (writeTVar stop True)
          ended
          pure move
        atomically (moveSettled move) `shouldReturn` Nothing
        atomically (writeTVar (rigBuildFailure rig) Nothing)
        settleUntil rig (isJust <$> moveSettled move)
        atomically (moveSettled move) `shouldReturn` Just MoveLanded

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
      withPublished defaultOptions $ \rig target view → withStandIn $ \standIn → do
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        -- the batches are the backend's own, their tickets read through its reader
        let receipts = rigReceipts rig
            note batch = atomically (noteOffscreenBatch receipts batch (worldTag world) (worldMetrics world))
        discardedBatch standIn >>= note
        atomically (readingDrawn <$> readView view) `shouldReturn` Nothing
        submittedBatch standIn >>= note
        atomically (readingDrawn <$> readView view) `shouldReturn` Nothing
        completeBatches standIn
        atomically (fmap drawnTag . readingDrawn <$> readView view) `shouldReturn` Just (worldTag world)
        submittedBatch standIn >>= note
        _ ← closeView view
        completeBatches standIn
        atomically (noteSubmitted receipts (worldTag world) (worldMetrics world))
        _ ← atomically (sweepOffscreen receipts)
        atomically (readReceipt receipts (viewIncarnation view)) `shouldReturn` Nothing

  describe "copy admission from the destination camera" $ do
    it "refuses a footprint one region over the cap though part of it is already drawn, keeping the drawing" $
      withPublished defaultOptions {optProfile = smallProfile {profileRegions = 163}} $ \rig target view → do
        quiesce rig target
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        atomically (configureView view noConfigure {configureZoom = Just 0.125}) `shouldReturn` Right ()
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) `shouldReturn` Just (LimitRegions 164 163)
        atomically (readingPublished <$> readView view) `shouldReturn` published
        atomically (latestWorld target) `shouldReturn` before

    it "moves between two disjoint footprints that each fit the region cap exactly" $
      withPublished defaultOptions {optProfile = smallProfile {profileRegions = 36}} $ \rig target view → do
        Right move ← atomically (moveView view far)
        settleUntil rig (isJust <$> moveSettled move)
        atomically (moveSettled move) `shouldReturn` Just MoveLanded
        settleUntil rig (publishedAtLeast view 2)
        atomically (readingRefusal <$> readView view) `shouldReturn` Nothing
        camera ← drawLatest rig target view >>= maybe (fail "no camera") pure . drawnPlanCamera
        (axisValue (camAnchorX camera), axisValue (camAnchorY camera)) `shouldBe` (192, 192)

    it "lands a move given exactly the destination's runs, though both views' together exceed them" $
      withPublished defaultOptions {optProfile = smallProfile {profileRuns = 3104}} $ \rig _ view → do
        Right move ← atomically (moveView view far)
        settleUntil rig (publishedAtLeast view 2)
        atomically (moveSettled move) `shouldReturn` Just MoveLanded
        atomically (readingRefusal <$> readView view) `shouldReturn` Nothing

    it "refuses a whole copy that an edit of the drawn footprint takes over the run cap, holding each copy's charge through its count, keeping the drawing" $
      withPublished defaultOptions {optProfile = smallProfile {profileRuns = 3104, profileRequestRegions = 1}} $ \rig target view → do
        quiesce rig target
        let remove z = do
              Right removal ← removeAt (rigTerrain rig) (rigLease rig) (either (error . show) id (tileCoord 2 2 z)) Nothing
              _ ← await (rigTerrain rig) removal
              pure ()
        -- the camera stays. Removing the top cell of column (2, 2) keeps F's copies at 3,104 runs: republished
        remove 1
        settleUntil rig (publishedAtLeast view 2)
        quiesce rig target
        -- the revision before the edit is drawn: its receipt and its pinned camera and metrics
        drawn ← drawLatest rig target view
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        -- the held copy whose count crosses the cap waits at a gate inside its count: its regional charge is observed
        -- there, still taken by the view; resumed, the copy is refused and its charge returned
        counting ← newEmptyTMVarIO
        resumed ← newEmptyTMVarIO
        atomically (writeTVar (rigCountGate rig) (Just ((> 3104), counting, resumed)))
        -- removing the cell below splits that region's knowledge by column, taking F's copies over the cap
        remove 0
        held ← withOwnedThread (settleUntil rig (isJust . readingRefusal <$> readView view)) $ \_ ended → do
          batch ← timeout 10000000 (atomically (takeTMVar counting)) >>= maybe (fail "no count crossed the cap") pure
          charges ← atomically (inspectRegionalSTM (rigTerrain rig))
          atomically (putTMVar resumed ())
          ended
          pure (batch, [charge | charge ← charges, regionalChargeTaken charge, regionalChargeRegions charge == length batch])
        -- the crossing batch's copy was taken by the view and still charged while it was counted
        snd held `shouldSatisfy` (not . null)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitRuns over 3104) → over > 3104
          _ → False)
        atomically (readingPublished <$> readView view) `shouldReturn` published
        atomically (latestWorld target) `shouldReturn` before
        after ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn after the refusal") pure
        (drawnPlanReceipt after, drawnPlanCamera after, drawnPlanMetrics after) `shouldBe` (drawnPlanReceipt drawn, drawnPlanCamera drawn, drawnPlanMetrics drawn)
        -- and returned, once: no regional charge is left
        atomically (inspectRegionalSTM (rigTerrain rig)) `shouldReturn` []
        atomically (inspectRetainedChargesSTM (rigTerrain rig)) >>= (`shouldSatisfy` \(bank, borrows) → bank == 0 && null borrows)

    it "asks the runtime for F first, cut at its camera regions, and the receipt disposes of every key it was given" $
      withPublished defaultOptions $ \rig target view → do
        copied ← drawLatest rig target view >>= maybe (fail "no regions") pure . drawnPlanRegions
        Set.size copied `shouldBe` 36
        asked ← atomically (readingDemand <$> readView view)
        -- four camera regions: all four of F (copied, in any order within F), none of the prefetch
        length asked `shouldBe` 4
        asked `shouldSatisfy` all (`Set.member` copied)
        receipt ← atomically (readingReceipt <$> readView view) >>= maybe (fail "no receipt") pure
        let disposed = Set.fromList (receiptAdmitted receipt <> receiptPending receipt <> receiptExcluded receipt <> receiptTruncated receipt)
        Set.fromList asked `shouldSatisfy` (`Set.isSubsetOf` disposed)
        disposed `shouldSatisfy` (not . Set.null)

    it "gives the one place F leaves to one prefetch region outside F, even when one ring chunk is all the ring may list" $ do
      let ring n c = c {ccLimits = (ccLimits c) {clDemandChunks = n}}
      withPublished defaultOptions {optRuntime = \c → c {configLimits = cameraLimitsWith 37}, optCells = ring 1} $ \rig target view → do
        copied ← drawLatest rig target view >>= maybe (fail "no regions") pure . drawnPlanRegions
        asked ← atomically (readingDemand <$> readView view)
        (length asked, Set.size (Set.fromList asked)) `shouldBe` (37, 37)
        Set.fromList (filter (`Set.member` copied) asked) `shouldBe` copied
        length (filter (`Set.notMember` copied) asked) `shouldBe` 1
      -- no ring chunk at all: only F
      withPublished defaultOptions {optRuntime = \c → c {configLimits = cameraLimitsWith 37}, optCells = ring 0} $ \rig target view → do
        copied ← drawLatest rig target view >>= maybe (fail "no regions") pure . drawnPlanRegions
        asked ← atomically (Set.fromList . readingDemand <$> readView view)
        asked `shouldBe` copied

    it "gives every region of F a runtime place when it has 36, and refuses with a cap of 35" $ do
      withPublished defaultOptions {optRuntime = \c → c {configLimits = cameraLimitsWith 36}} $ \rig target view → do
        copied ← drawLatest rig target view >>= maybe (fail "no regions") pure . drawnPlanRegions
        asked ← atomically (Set.fromList . readingDemand <$> readView view)
        Set.size asked `shouldBe` 36
        asked `shouldBe` copied
      withRig defaultOptions {optProfile = smallProfile {profileRegions = 35}} $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) `shouldReturn` Just (LimitRegions 36 35)
        atomically (latestWorld target) `shouldReturn` Nothing

    it "gives the regions that draw fog runtime places, and charges no anchor region a manual slice does not read" $
      withPublished defaultOptions {optRuntime = \c → c {configLimits = cameraLimitsWith 38}} $ \rig target view → do
        -- a cut at level -10 through the undiscovered ground, 12 levels below the reference, facing south from the
        -- origin: fog conceals the cut. The runtime has a place for each of F's 38 regions
        atomically (configureView view noConfigure {configureDepth = Just (axis (-10))}) `shouldReturn` Right ()
        settleUntil rig (publishedAtLeast view 2)
        drawn ← drawLatest rig target view
        plan ← maybe (fail "the drawn plan is not pinned") pure (drawnPlanPlan drawn)
        copied ← maybe (fail "no regions") pure (drawnPlanRegions drawn)
        -- the world regions of the fog quads' own cells (facing south from the origin, the view frame is the world's)
        let fogRegions = Set.fromList [RegionCoord (fromInteger (vx `div` 16)) (fromInteger (vy `div` 16)) (fromInteger (z `div` 32)) | quad ← cellPlanQuads plan, quadPart quad == PartFog, let CellKey _ z vx vy _ = quadKey quad]
        fogRegions `shouldSatisfy` (not . Set.null)
        asked ← atomically (Set.fromList . readingDemand <$> readView view)
        fogRegions `shouldSatisfy` (`Set.isSubsetOf` asked)
        receipt ← atomically (readingReceipt <$> readView view) >>= maybe (fail "no receipt") pure
        let disposed = Set.fromList (receiptAdmitted receipt <> receiptPending receipt <> receiptExcluded receipt <> receiptTruncated receipt)
        fogRegions `shouldSatisfy` (`Set.isSubsetOf` disposed)
        -- the anchor's own region at the cut holds no cell this camera reads, and only a pending jump with a level
        -- charges an unread anchor region
        Set.member (RegionCoord 0 0 (-1)) copied `shouldBe` False

    it "counts F from geometry, not from the planner's bounded demand listing" $ do
      let unlisted c = c {ccLimits = (ccLimits c) {clDemandChunks = 0}}
      withRig defaultOptions {optCells = unlisted, optProfile = smallProfile {profileRegions = 35}} $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) `shouldReturn` Just (LimitRegions 36 35)

    it "copies nothing and asks the runtime for nothing while nothing can be drawn, then plans once something can" $
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 0 0)))
        view ← openOn rig target
        runOwner rig
        reading ← atomically (readView view)
        (readingDemand reading, readingPublished reading, readingRefusal reading) `shouldBe` ([], Nothing, Nothing)
        atomically (inspectRetainedChargesSTM (rigTerrain rig)) >>= (`shouldSatisfy` (null . snd))
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 320 240)))
        settleUntil rig (publishedAtLeast view 1)

    it "derives its runtime demand from the geometry now: present, empty when minimized, present again on restore, empty again" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        drawn ← drawLatest rig target view
        asked ← atomically (readingDemand <$> readView view)
        asked `shouldSatisfy` (not . null)
        published ← atomically (readingPublished <$> readView view)
        let at metrics expected = do
              atomically (setHeldMetrics (targetHeld target) (Just metrics))
              settleUntil rig ((== expected) . readingDemand <$> readView view)
              reading ← atomically (readView view)
              receipt ← maybe (fail "no receipt") pure (readingReceipt reading)
              -- the runtime disposed of every key it was given
              let disposed = Set.fromList (receiptAdmitted receipt <> receiptPending receipt <> receiptExcluded receipt <> receiptTruncated receipt)
              Set.fromList expected `shouldSatisfy` (`Set.isSubsetOf` disposed)
              (readingPublished reading, readingRefusal reading) `shouldBe` (published, Nothing)
              -- the retained revision and its drawn mapping survive
              kept ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
              (drawnPlanReceipt kept, drawnPlanCamera kept, drawnPlanMetrics kept) `shouldBe` (drawnPlanReceipt drawn, drawnPlanCamera drawn, drawnPlanMetrics drawn)
        at (metricsOf 0 0) []
        at (metricsOf 320 240) asked
        at (metricsOf 0 0) []
        atomically (inspectRetainedChargesSTM (rigTerrain rig)) >>= (`shouldSatisfy` (null . snd))

    it "publishes a first view's clear revision over an M1 scene when its footprint reads nothing, with no copy" $
      withRig defaultOptions {optCamera = \c → c {ccHeadroom = 400}} $ \rig → do
        target ← newTarget 1
        m1 ← prepare initialGraphicsScene
        atomically (void (surfacePublish (HeldSurface (targetHeld target)) m1))
        -- at the world's corner, following a cut 400 levels over the surface: every read is outside the world
        let top = 2 ^ (62 ∷ Int) - 1
        style ← styleOf rig
        view ←
          openView (rigViews rig) (OpenRequest (viewTarget target) (rigLease rig) (pure (Right style)) (axis top, axis top, axis 1) defaultLightSettings)
            >>= either (fail . show) pure
        settleUntil rig (publishedAtLeast view 1)
        world ← atomically (latestWorld target) >>= maybe (fail "the M1 scene was not replaced by a terrain revision") pure
        worldChunks world `shouldBe` Set.empty
        drawn ← drawLatest rig target view
        fmap (null . cellPlanQuads) (drawnPlanPlan drawn) `shouldBe` Just True
        drawnPlanRegions drawn `shouldBe` Just Set.empty
        reading ← atomically (readView view)
        (readingDemand reading, readingRefusal reading) `shouldBe` ([], Nothing)

    it "publishes an empty revision, and withdraws the demand, when a populated view's footprint reads nothing" $
      withPublished defaultOptions $ \rig target view → do
        -- at the world's corner, a slice 400 levels above the reference projects every read outside the world
        let top = 2 ^ (62 ∷ Int) - 1
        Right move ← atomically (moveView view (JumpTarget (axis top) (axis top) Nothing))
        settleUntil rig (isJust <$> moveSettled move)
        atomically (moveSettled move) `shouldReturn` Just MoveLanded
        settleUntil rig (publishedAtLeast view 2)
        atomically (readingDemand <$> readView view) >>= (`shouldSatisfy` (not . null))
        reference ← drawLatest rig target view >>= maybe (fail "no camera") pure . drawnPlanCamera
        atomically (configureView view noConfigure {configureDepth = Just (axis (camRef reference + 399))}) `shouldReturn` Right ()
        settleUntil rig (publishedAtLeast view 3)
        world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
        worldChunks world `shouldBe` Set.empty
        reading ← atomically (readView view)
        (readingDemand reading, readingRefusal reading) `shouldBe` ([], Nothing)
        drawn ← drawLatest rig target view
        fmap (null . cellPlanQuads) (drawnPlanPlan drawn) `shouldBe` Just True
        drawnPlanRegions drawn `shouldBe` Just Set.empty

    it "lands an explicit-Z move on a minimized view without publishing, and prepares the landed camera on restore" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        drawn ← drawLatest rig target view
        published ← atomically (readingPublished <$> readView view)
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 0 0)))
        settleUntil rig (null . readingDemand <$> readView view)
        Right move ← atomically (moveView view (JumpTarget (axis 70) (axis 70) (Just (axis 1))))
        settleUntil rig (isJust <$> moveSettled move)
        atomically (moveSettled move) `shouldReturn` Just MoveLanded
        reading ← atomically (readView view)
        (readingPublished reading, readingDemand reading) `shouldBe` (published, [])
        kept ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
        (drawnPlanReceipt kept, drawnPlanCamera kept, drawnPlanMetrics kept) `shouldBe` (drawnPlanReceipt drawn, drawnPlanCamera drawn, drawnPlanMetrics drawn)
        -- restored: the landed camera is prepared and published
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 320 240)))
        settleUntil rig (publishedAtLeast view (maybe 1 (+ 1) published))
        camera ← drawLatest rig target view >>= maybe (fail "no camera") pure . drawnPlanCamera
        (axisValue (camAnchorX camera), axisValue (camAnchorY camera)) `shouldBe` (70, 70)

    it "settles an explicit-Z move whose destination terrain part is unavailable with pressure, once, keeping the drawing" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        drawn ← drawLatest rig target view
        published ← atomically (readingPublished <$> readView view)
        -- the destination (70, 70, 1) is in region (4, 4, 0): its terrain part reads as a failed page makes it
        atomically (writeTVar (rigUnavailable rig) (Set.singleton (RegionCoord 4 4 0)))
        Right move ← atomically (moveView view (JumpTarget (axis 70) (axis 70) (Just (axis 1))))
        settleUntil rig (isJust <$> moveSettled move)
        atomically (moveSettled move) `shouldReturn` Just (MovePressure (LimitFailure "the jump's destination is not ready"))
        quiesce rig target
        reading ← atomically (readView view)
        (readingPublished reading, readingRefusals reading) `shouldBe` (published, 1)
        kept ← atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure
        (drawnPlanReceipt kept, drawnPlanCamera kept, drawnPlanMetrics kept) `shouldBe` (drawnPlanReceipt drawn, drawnPlanCamera drawn, drawnPlanMetrics drawn)

    it "reports a current refusal once through an unrelated wake, and a changed intent then lands and publishes" $
      withPublished defaultOptions {optProfile = smallProfile {profileRegions = 163}} $ \rig target view → do
        quiesce rig target
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        atomically (configureView view noConfigure {configureZoom = Just 0.125}) `shouldReturn` Right ()
        settleUntil rig (isJust . readingRefusal <$> readView view)
        -- an unrelated wake: the owner is asked for a step and runs, and the target adopts
        atomically (kick (rigViews rig))
        quiesce rig target
        reading ← atomically (readView view)
        (readingRefusal reading, readingRefusals reading, readingPublished reading) `shouldBe` (Just (LimitRegions 164 163), 1, published)
        atomically (latestWorld target) `shouldReturn` before
        -- a changed intent that fits: back to unit zoom, then a move
        atomically (configureView view noConfigure {configureZoom = Just 1}) `shouldReturn` Right ()
        Right move ← atomically (moveView view far)
        settleUntil rig (isJust <$> moveSettled move)
        atomically (moveSettled move) `shouldReturn` Just MoveLanded
        settleUntil rig (publishedAtLeast view (maybe 1 (+ 1) published))
        atomically (readingRefusal <$> readView view) `shouldReturn` Nothing

    it "keeps the installed runtime demand, its receipt and the accepted scene when the host refuses a successor with other demand" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        let runtimeDemand = map (map demandRegion . viewDemand) . modelViews <$> inspectModelSTM (rigTerrain rig)
        before ← atomically (readView view)
        installed ← atomically runtimeDemand
        world ← atomically (latestWorld target)
        -- the host refuses the next publication; the move's destination asks for other regions
        atomically (setHeldAccepts (targetHeld target) False)
        Right move ← atomically (moveView view far)
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) `shouldReturn` Just (LimitFailure "the host refused the publication")
        after ← atomically (readView view)
        (readingDemand after, readingReceipt after, readingPublished after) `shouldBe` (readingDemand before, readingReceipt before, readingPublished before)
        atomically runtimeDemand `shouldReturn` installed
        atomically (latestWorld target) `shouldReturn` world
        -- the move landed at its eligibility; the later publication refusal keeps that result
        atomically (moveSettled move) `shouldReturn` Just MoveLanded

    it "ends a view whose original window authority is revoked while its target stays usable, settling its pending move" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        Right move ← atomically (moveView view far)
        atomically (setHeldAuthority (targetHeld target) False)
        settleUntil rig ((== ViewEnded EndRevoked) . readingStatus <$> readView view)
        atomically (moveSettled move) `shouldReturn` Just (MoveEnded EndRevoked)
        atomically (claimOf (rigClaims rig) 1) `shouldReturn` Nothing
        atomically (surfaceUsable (HeldSurface (targetHeld target))) `shouldReturn` True

    it "keeps the installed demand and its receipt when a publication's demand is unchanged" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        before ← atomically (readView view)
        atomically (configureView view noConfigure {configureLight = Just brighter}) `shouldReturn` Right ()
        settleUntil rig (publishedAtLeast view (maybe 1 (+ 1) (readingPublished before)))
        after ← atomically (readView view)
        (readingDemand after, readingReceipt after, readingInstalls after) `shouldBe` (readingDemand before, readingReceipt before, readingInstalls before)

    it "retires a refusal whose basis no longer applies, and counts a new one once, through successive moves at zero geometry" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 0 0)))
        settleUntil rig (null . readingDemand <$> readView view)
        atomically (writeTVar (rigUnavailable rig) (Set.singleton (RegionCoord 4 4 0)))
        Right first ← atomically (moveView view (JumpTarget (axis 70) (axis 70) (Just (axis 1))))
        settleUntil rig (isJust <$> moveSettled first)
        atomically (moveSettled first) `shouldReturn` Just (MovePressure (LimitFailure "the jump's destination is not ready"))
        atomically ((,) <$> (readingRefusal <$> readView view) <*> (readingRefusals <$> readView view)) `shouldReturn` (Just (LimitFailure "the jump's destination is not ready"), 1)
        -- a ready move elsewhere lands: the first refusal no longer applies
        Right second ← atomically (moveView view (JumpTarget (axis 6) (axis 6) (Just (axis 1))))
        settleUntil rig (isJust <$> moveSettled second)
        atomically (moveSettled second) `shouldReturn` Just MoveLanded
        atomically (readingRefusal <$> readView view) `shouldReturn` Nothing
        -- a new refusal is a new entry
        Right third ← atomically (moveView view (JumpTarget (axis 70) (axis 70) (Just (axis 1))))
        settleUntil rig (isJust <$> moveSettled third)
        atomically (readingRefusals <$> readView view) `shouldReturn` 2

    it "admits no control once the view's authority is revoked, ending its pending move as revoked before the owner steps" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        Right first ← atomically (moveView view far)
        atomically (setHeldAuthority (targetHeld target) False)
        -- before any owner step
        fmap (either Just (const Nothing)) (atomically (moveView view (JumpTarget (axis 6) (axis 6) Nothing))) `shouldReturn` Just ControlEnded
        atomically (moveSettled first) `shouldReturn` Just (MoveEnded EndRevoked)
        atomically (configureView view noConfigure {configureZoom = Just 2}) `shouldReturn` Left ControlEnded
        atomically (configureView view noConfigure {configureLight = Just brighter}) `shouldReturn` Left ControlEnded

    it "names a failed build's buffer, the build's cause and the destruction's when its destruction fails, and keeps its slot across a close and reopen" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        destruction ← newTVarIO DisposalPending
        atomically (writeTVar (rigFailNext rig) [Just (BuildFailed "failed after its buffer" (AllocatedDisposing "buffer 7" (readTVar destruction)))])
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (writeTVar destruction (DisposalFailed "the device was lost"))
        settleUntil rig (not . null . serviceFailures <$> readTerrainViews (rigViews rig))
        let named reading = [cause | (1, Nothing, cause) ← serviceFailures reading, all (`Text.isInfixOf` cause) ["buffer 7", "failed after its buffer", "the device was lost"]]
        failures ← serviceFailures <$> atomically (readTerrainViews (rigViews rig))
        named' ← named <$> atomically (readTerrainViews (rigViews rig))
        length named' `shouldBe` 1
        _ ← closeView view
        runOwner rig
        second ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView second)
        reading ← atomically (readTerrainViews (rigViews rig))
        serviceFailures reading `shouldBe` failures
        Map.findWithDefault 0 1 (serviceOccupied reading) `shouldBe` 1

    it "treats a target whose metrics have an infinite scale as of unknown geometry: no demand" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        atomically (setHeldMetrics (targetHeld target) (Just (TargetMetrics (PixelExtent 320 240) (PixelExtent 320 240) (1 / 0) 1)))
        settleUntil rig (null . readingDemand <$> readView view)
        atomically (readingStatus <$> readView view) `shouldReturn` ViewOpen

    it "follows a removed summit whose new top is in the vertical region below" $
      withPublished defaultOptions $ \rig target view → do
        forM_ [1, 0] $ \z → do
          Right removal ← removeAt (rigTerrain rig) (rigLease rig) (either (error . show) id (tileCoord 0 0 z)) Nothing
          _ ← await (rigTerrain rig) removal
          pure ()
        settleUntil rig ((\reading → maybe False (>= 2) (readingPublished reading) && readingStage reading == "idle") <$> readView view)
        camera ← drawLatest rig target view >>= maybe (fail "no camera") pure . drawnPlanCamera
        (camSurface camera, camRef camera) `shouldBe` (Just (axis (-1)), 0)

    it "never mixes two content versions in one drawn revision when an edit lands between split copies" $
      withRig defaultOptions {optProfile = smallProfile {profileRequestRegions = 1}} $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (Text.isInfixOf " 1 taken" . readingStage <$> readView view)
        Right removal ← removeAt (rigTerrain rig) (rigLease rig) (either (error . show) id (tileCoord 2 2 1)) Nothing
        _ ← await (rigTerrain rig) removal
        settleUntil rig (publishedAtLeast view 1)
        drawn ← drawLatest rig target view
        current ← atomically (inspectArenaSTM (rigTerrain rig) (rigLease rig)) >>= maybe (fail "no arena") pure
        fmap (\(_, content, _, _) → content) (drawnPlanArena drawn) `shouldBe` Just (viewRevision current)

    it "refuses to attach with another client's arena lease of the same terrain service" $
      withRig defaultOptions $ \rig → do
        other ← registerClient (rigTerrain rig) >>= either (fail . show) pure
        alien ← openArena (rigTerrain rig) other "other" source >>= either (fail . show) pure >>= await (rigTerrain rig) >>= either (fail . show) pure
        target ← newTarget 1
        style ← styleOf rig
        refused ← openView (rigViews rig) (OpenRequest (viewTarget target) alien (pure (Right style)) (axis 0, axis 0, axis 1) defaultLightSettings)
        either Just (const Nothing) refused `shouldSatisfy` \case
          Just (OpenArena _) → True
          _ → False
        atomically (claimOf (rigClaims rig) 1) `shouldReturn` Nothing

    it "reports a close from the view's own ownership, not from an earlier view's slots on the target" $
      withPublished defaultOptions $ \rig target first → do
        adoptHolding rig target
        closeView first `shouldReturn` CloseRetiring
        runOwner rig
        second ← openOn rig target
        closeView second `shouldReturn` CloseDone
        atomically (Map.findWithDefault 0 1 . serviceOccupied <$> readTerrainViews (rigViews rig)) >>= (`shouldSatisfy` (> 0))

  describe "chunk-build admission before allocation" $ do
    it "builds nothing while the uploads' last queue place is another's, through unrelated wakes, and completes once room returns, with no caller's kick" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let occupied = Map.findWithDefault 0 1 . serviceOccupied <$> readTerrainViews (rigViews rig)
            wake = atomically (kick (rigViews rig)) >> runOwner rig
        atomically (writeTVar (rigAdmission rig) (Just (AdmitLater "a texture's upload holds the last queue place")))
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (("building" `Text.isPrefixOf`) . readingStage <$> readView view)
        forM_ [1 .. 8 ∷ Int] (const wake)
        -- no buffer made, no grant held, no slot charged
        readTVarIO (rigBuildAttempts rig) `shouldReturn` 0
        readTVarIO (rigGrants rig) `shouldReturn` 0
        atomically occupied `shouldReturn` 0
        atomically (readingPublished <$> readView view) `shouldReturn` Nothing
        -- the room returns: only the watcher asks for the owner's next step
        atomically (writeTVar (rigAdmission rig) Nothing)
        settleUntil rig (publishedAtLeast view 1)
        readTVarIO (rigGrants rig) `shouldReturn` 0
        atomically occupied >>= (`shouldSatisfy` (<= 4))

    it "keeps the parts three free slots hold through the wait for a fourth, and publishes all four once an independent buffer's destruction completes" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let occupied = Map.findWithDefault 0 1 . serviceOccupied <$> readTerrainViews (rigViews rig)
            wake = atomically (kick (rigViews rig)) >> runOwner rig
        destruction ← newTVarIO DisposalPending
        -- a first view's build fails after making its buffer, which awaits its destruction, charged to the target
        atomically (writeTVar (rigFailNext rig) [Just (BuildFailed "an injected failure" (AllocatedDisposing "buffer 5" (readTVar destruction)))])
        target ← newTarget 1
        first ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView first)
        _ ← closeView first
        runOwner rig
        atomically occupied `shouldReturn` 1
        -- a second view of the target: its upload room is taken, then restored before the slot is
        atomically (writeTVar (rigAdmission rig) (Just (AdmitLater "the staging is full")))
        second ← openOn rig target
        settleUntil rig (("building" `Text.isPrefixOf`) . readingStage <$> readView second)
        atomically (writeTVar (rigAdmission rig) Nothing)
        settleUntil rig ((== 4) <$> occupied)
        built ← Map.keys <$> readTVarIO (rigChunks rig)
        length built `shouldBe` 3
        forM_ [1 .. 8 ∷ Int] (const wake)
        atomically ((,) <$> (readingPublished <$> readView second) <*> (readingRefusal <$> readView second)) `shouldReturn` (Nothing, Nothing)
        Map.keys <$> readTVarIO (rigChunks rig) `shouldReturn` built
        atomically occupied `shouldReturn` 4
        -- the destruction completes: its slot frees once, and the four parts publish together within the slots
        atomically (writeTVar destruction DisposalDone)
        settleUntil rig (publishedAtLeast second 1)
        atomically (readingListed <$> readView second) `shouldReturn` 4
        live ← Map.keys <$> readTVarIO (rigChunks rig)
        built `shouldSatisfy` all (`elem` live)
        atomically occupied `shouldReturn` 4

    it "refuses once, though the upload room is taken, when a buffer's failed destruction leaves more parts than slots, retiring the prefix and keeping the loss and the drawing" $
      withPublished defaultOptions {optProfile = smallProfile {profileSlots = 8, profileQuads = 2048}} $ \rig target view → do
        quiesce rig target
        let reading = readTerrainViews (rigViews rig)
            occupied = Map.findWithDefault 0 1 . serviceOccupied <$> reading
            wake = atomically (kick (rigViews rig)) >> runOwner rig
        atomically (readingListed <$> readView view) `shouldReturn` 4
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        destruction ← newTVarIO DisposalPending
        -- a zoom that rebuilds every part, whose first build fails after making its buffer: that buffer awaits its
        -- destruction
        atomically (writeTVar (rigFailNext rig) [Just (BuildFailed "an injected failure" (AllocatedDisposing "buffer 9" (readTVar destruction)))])
        atomically (configureView view noConfigure {configureZoom = Just 2}) `shouldReturn` Right ()
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically occupied `shouldReturn` 5
        -- the next zoom builds two of its four parts, then finds the upload room taken
        atomically (writeTVar (rigAdmitBudget rig) (Just 2))
        atomically (configureView view noConfigure {configureZoom = Just 0.5}) `shouldReturn` Right ()
        settleUntil rig ((== 7) <$> occupied)
        refusals ← atomically (readingRefusals <$> readView view)
        attempts ← readTVarIO (rigBuildAttempts rig)
        -- the buffer's destruction fails: one slot is left for the two remaining parts
        atomically (writeTVar destruction (DisposalFailed "the device was lost"))
        settleUntil rig ((== refusals + 1) . readingRefusals <$> readView view)
        atomically (readingRefusal <$> readView view) `shouldReturn` Just (LimitSlots 4 3)
        -- its two parts retire; the lost buffer keeps its slot and its identity
        settleUntil rig ((== 5) <$> occupied)
        forM_ [1 .. 8 ∷ Int] (const wake)
        atomically (readingRefusals <$> readView view) `shouldReturn` (refusals + 1)
        readTVarIO (rigBuildAttempts rig) `shouldReturn` attempts
        readTVarIO (rigGrants rig) `shouldReturn` 0
        atomically (servicePrivate <$> reading) `shouldReturn` 0
        atomically (readingPublished <$> readView view) `shouldReturn` published
        atomically (latestWorld target) `shouldReturn` before
        failures ← serviceFailures <$> atomically reading
        [cause | (1, Nothing, cause) ← failures] `shouldSatisfy` any (Text.isInfixOf "buffer 9")

    it "refuses a replacement with a part larger than the whole staging once, keeping the scene, with no prefix or grant left; queue pressure on fitting parts keeps the prefix" $
      withPublished defaultOptions {optProfile = smallProfile {profileSlots = 8, profileQuads = 2048}} $ \rig target view → do
        quiesce rig target
        let reading = readTerrainViews (rigViews rig)
            occupied = Map.findWithDefault 0 1 . serviceOccupied <$> reading
            wake = atomically (kick (rigViews rig)) >> runOwner rig
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        refusals ← atomically (readingRefusals <$> readView view)
        -- a zoom that rebuilds every part, and queue pressure after one fitting part: the prefix waits
        atomically (writeTVar (rigAdmitBudget rig) (Just 1))
        atomically (configureView view noConfigure {configureZoom = Just 2}) `shouldReturn` Right ()
        settleUntil rig ((== 5) <$> occupied)
        forM_ [1 .. 4 ∷ Int] (const wake)
        atomically occupied `shouldReturn` 5
        atomically (readingRefusal <$> readView view) `shouldReturn` Nothing
        -- a remaining part is larger than the whole staging
        atomically (writeTVar (rigAdmission rig) (Just (AdmitOversized "a part needs 2048 staging bytes, and the staging buffer holds 1024")))
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitOversized _) → True
          _ → False)
        settleUntil rig ((== 4) <$> occupied)
        forM_ [1 .. 8 ∷ Int] (const wake)
        atomically (readingRefusals <$> readView view) `shouldReturn` (refusals + 1)
        readTVarIO (rigGrants rig) `shouldReturn` 0
        atomically (servicePrivate <$> reading) `shouldReturn` 0
        atomically (readingPublished <$> readView view) `shouldReturn` published
        atomically (latestWorld target) `shouldReturn` before

    it "refuses a candidate one of whose built uploads fails while its next part waits for room, retiring it and keeping the drawing" $
      withPublished defaultOptions {optProfile = smallProfile {profileSlots = 8, profileQuads = 2048}} $ \rig target view → do
        quiesce rig target
        let reading = readTerrainViews (rigViews rig)
            occupied = Map.findWithDefault 0 1 . serviceOccupied <$> reading
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        drawn ← Map.keysSet <$> readTVarIO (rigStandings rig)
        -- a zoom that rebuilds every part: one is built, still uploading, and the next waits for the uploads' room
        atomically (writeTVar (rigUploading rig) True >> writeTVar (rigAdmitBudget rig) (Just 1))
        atomically (configureView view noConfigure {configureZoom = Just 2}) `shouldReturn` Right ()
        settleUntil rig ((== 5) <$> occupied)
        runOwner rig
        attempts ← readTVarIO (rigBuildAttempts rig)
        -- the built part's upload fails: only the watcher asks for a step
        fresh ← filter (`Set.notMember` drawn) . Map.keys <$> readTVarIO (rigStandings rig)
        case fresh of
          [built] → atomically (modifyTVar' (rigStandings rig) (Map.insert built (ChunkFailed UploadLost)))
          _ → expectationFailure ("expected one built part, found " <> show fresh)
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitFailure _) → True
          _ → False)
        settleUntil rig ((== 0) . servicePrivate <$> reading)
        atomically occupied `shouldReturn` 4
        readTVarIO (rigBuildAttempts rig) `shouldReturn` attempts
        readTVarIO (rigGrants rig) `shouldReturn` 0
        atomically (readingPublished <$> readView view) `shouldReturn` published
        atomically (latestWorld target) `shouldReturn` before

    it "settles a pending move as ended when the owner's exit begins inside the step that would settle it, before the watcher records it" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        counting ← newEmptyTMVarIO
        resumed ← newEmptyTMVarIO
        stop ← newTVarIO False
        atomically (writeTVar (rigCountGate rig) (Just (const True, counting, resumed)))
        Right first ← atomically (moveView view far)
        let owner = do
              runOwner rig
              continue ← atomically ((False <$ (readTVar stop >>= check)) `orElse` (True <$ (readTVar (rigQueue rig) >>= check . not . Seq.null)))
              when continue owner
        withOwnedThread owner $ \_ ended → do
          -- the step is under way, inside the destination's copy: the owner's exit begins now
          _ ← timeout 10000000 (atomically (takeTMVar counting)) >>= maybe (fail "no copy was counted") pure
          atomically (writeTVar (rigOwnerEnded rig) (Just "the owner's exit began"))
          atomically (putTMVar resumed ())
          eventually (isJust <$> moveSettled first)
          atomically (writeTVar stop True)
          ended
        atomically (moveSettled first) `shouldReturn` Just (MoveEnded EndStopped)

    it "keeps a failed cleanup's buffer charged across a close and reopen, with the build's cause and the release's" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let reading = readTerrainViews (rigViews rig)
            occupied = Map.findWithDefault 0 1 . serviceOccupied <$> reading
        atomically (writeTVar (rigFailNext rig) [Just (BuildFailed "the upload was refused" (AllocatedFailed "the failed build's buffer 7 raised on its release: the release raised"))])
        target ← newTarget 1
        first ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView first)
        failures ← serviceFailures <$> atomically reading
        [cause | (1, Nothing, cause) ← failures] `shouldSatisfy` any (\cause → all (`Text.isInfixOf` cause) ["buffer 7", "the upload was refused", "the release raised"])
        _ ← closeView first
        runOwner rig
        second ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView second)
        atomically (readingRefusal <$> readView second) `shouldReturn` Just (LimitSlots 4 3)
        atomically occupied `shouldReturn` 1
        serviceFailures <$> atomically reading `shouldReturn` failures

    it "publishes a quiet candidate once its last upload completes between the watcher's readings, with no frame or caller's kick; a failed upload retires the candidate and keeps the drawing" $
      withRig defaultOptions $ \rig → do
        let reading = readTerrainViews (rigViews rig)
            allBuilt = ("building (0 " `Text.isPrefixOf`) . readingStage
            readyAll = readTVarIO (rigStandings rig) >>= \standings → forM_ (Map.keys standings) (\chunk → atomically (modifyTVar' (rigStandings rig) (Map.insert chunk ChunkReady)))
        atomically (writeTVar (rigUploading rig) True)
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (allBuilt <$> readView view)
        runOwner rig
        atomically (readingPublished <$> readView view) `shouldReturn` Nothing
        -- the uploads complete; nothing but the watcher asks for a step
        readyAll
        settleUntil rig (publishedAtLeast view 1)
        quiesce rig target
        before ← atomically (latestWorld target)
        published ← atomically (readingPublished <$> readView view)
        drawn ← Map.keysSet <$> readTVarIO (rigStandings rig)
        -- a zoom's candidate, one of whose uploads fails
        atomically (configureView view noConfigure {configureZoom = Just 2}) `shouldReturn` Right ()
        settleUntil rig (allBuilt <$> readView view)
        fresh ← filter (`Set.notMember` drawn) . Map.keys <$> readTVarIO (rigStandings rig)
        case fresh of
          lost : _ → atomically (modifyTVar' (rigStandings rig) (Map.insert lost (ChunkFailed UploadLost)))
          [] → expectationFailure "the candidate built nothing"
        settleUntil rig (isJust . readingRefusal <$> readView view)
        atomically (readingRefusal <$> readView view) >>= (`shouldSatisfy` \case
          Just (LimitFailure _) → True
          _ → False)
        -- its other uploads end, and the private candidate retires
        readyAll
        settleUntil rig ((== 0) . servicePrivate <$> reading)
        atomically (readingPublished <$> readView view) `shouldReturn` published
        atomically (latestWorld target) `shouldReturn` before

    it "refuses every control in the instant the owner's exit begins, before the watcher records it, ending the pending move once" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        Right first ← atomically (moveView view far)
        (second, camera, light) ← atomically $ do
          writeTVar (rigOwnerEnded rig) (Just "the owner's exit began")
          (,,)
            <$> (fmap (const ()) <$> moveView view (JumpTarget (axis 6) (axis 6) Nothing))
            <*> configureView view noConfigure {configureZoom = Just 2}
            <*> configureView view noConfigure {configureLight = Just brighter}
        (second, camera, light) `shouldBe` (Left ControlEnded, Left ControlEnded, Left ControlEnded)
        atomically (moveSettled first) `shouldReturn` Just (MoveEnded EndStopped)

    it "counts a demand withdrawal the terrain service refuses as a second refusal, keeping the installed list, its receipt and the drawing, through unchanged wakes" $
      withPublished defaultOptions {optProfile = slotted} $ \rig target view → do
        quiesce rig target
        let wake = atomically (kick (rigViews rig)) >> runOwner rig
        -- one recorded zoom refusal
        atomically (configureView view noConfigure {configureZoom = Just 0.5}) `shouldReturn` Right ()
        settleUntil rig (isJust . readingRefusal <$> readView view)
        refused ← atomically (readView view)
        readingRefusals refused `shouldBe` 1
        before ← atomically (latestWorld target)
        -- minimized with the lease live, its withdrawal refused, and no move between
        atomically (writeTVar (rigDemandRefused rig) (Just "the withdrawal is refused") >> setHeldMetrics (targetHeld target) (Just (metricsOf 0 0)))
        settleUntil rig ((== 2) . readingRefusals <$> readView view)
        forM_ [1 .. 8 ∷ Int] (const wake)
        after ← atomically (readView view)
        readingRefusals after `shouldBe` 2
        (readingDemand after, readingReceipt after, readingPublished after) `shouldBe` (readingDemand refused, readingReceipt refused, readingPublished refused)
        atomically (latestWorld target) `shouldReturn` before

  describe "one settlement per chunk-build spend" $ do
    it "settles a build whose constructor raises before allocating once: the cause recorded, slots and grants at their baseline, and a later held build counted at close" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let reading = readTerrainViews (rigViews rig)
        atomically (writeTVar (rigRaising rig) (Just (toException (ErrorCall "the constructor raised"))))
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (isJust . readingRefusal <$> readView view)
        refusal ← atomically (readingRefusal <$> readView view)
        Text.pack (show refusal) `shouldSatisfy` Text.isInfixOf "the constructor raised"
        settled ← atomically reading
        (Map.findWithDefault 0 1 (serviceOccupied settled), serviceFailures settled) `shouldBe` (0, [])
        readTVarIO (rigGrants rig) `shouldReturn` 0
        -- a later real build, held: the view's close counts it as retiring
        index ← readTVarIO (rigNext rig)
        atomically (writeTVar (rigHold rig) (Just index))
        stop ← newTVarIO False
        let owner = do
              runOwner rig
              continue ← atomically ((False <$ (readTVar stop >>= check)) `orElse` (True <$ (readTVar (rigQueue rig) >>= check . not . Seq.null)))
              when continue owner
        atomically (configureView view noConfigure {configureZoom = Just 2}) `shouldReturn` Right ()
        withOwnedThread owner $ \_ ended → do
          timeout 10000000 (atomically (takeTMVar (rigEntered rig))) >>= maybe (expectationFailure "no build was held") pure
          closeView view `shouldReturn` CloseRetiring
          atomically (putTMVar (rigResume rig) () >> writeTVar stop True)
          ended

    it "ends the views' owner when a build is cancelled after its backend released its buffer: the sweep keeps that buffer's slot while its destruction is pending and records both causes" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let reading = readTerrainViews (rigViews rig)
        destruction ← newTVarIO DisposalPending
        -- the build seals the release its construction already made, then its cancellation goes on
        atomically $ do
          writeTVar (rigFailNext rig) [Just (BuildFailed "BuildRaised \"thread killed\"" (AllocatedDisposing "buffer 7" (readTVar destruction)))]
          writeTVar (rigRaiseSealed rig) (Just (toException ThreadKilled))
        target ← newTarget 1
        first ← openOn rig target
        try @AsyncException (settleUntil rig (isJust . readingRefusal <$> readView first)) `shouldReturn` Left ThreadKilled
        -- the raised step ended the views' owner: the view ends, and the sweep collects the build in its place
        eventually ((\now → servicePending now == 0 && not (null (serviceSwept now))) <$> reading)
        atomically (readingStatus <$> readView first) >>= (`shouldSatisfy` (/= ViewOpen))
        swept ← serviceSwept <$> atomically reading
        [why | (1, _, why) ← swept] `shouldSatisfy` any (\why → all (`Text.isInfixOf` why) ["BuildRaised", "thread killed"])
        -- the released buffer's slot is held until its destruction is confirmed
        Map.findWithDefault 0 1 . serviceOccupied <$> atomically reading `shouldReturn` 1

    it "charges one slot for a granted build whose bound upload raised at the mapped write, through the renderer's grant and receipt: its released buffer's destruction is held pending across a close and reopen, and its slot is returned once" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}, optNative = True} $ \rig → do
        native ← maybe (fail "the example needs the native stand-in") pure (rigNative rig)
        let reading = readTerrainViews (rigViews rig)
            occupied = Map.findWithDefault 0 1 . serviceOccupied <$> reading
        -- the owner's turns keep released buffers, and the first build's write into staging raises
        atomically $ do
          writeTVar (nativeDisposing native) False
          failNextWrite (nativeStandIn native) (toException (ErrorCall "the mapped write failed"))
        target ← newTarget 1
        first ← openOn rig target
        -- the view collects the renderer's sealed failure: its refusal names the cause, and the released buffer's slot
        -- stays charged while its destruction is pending
        settleUntil rig (isJust . readingRefusal <$> readView first)
        refusal ← atomically (readingRefusal <$> readView first)
        Text.pack (show refusal) `shouldSatisfy` Text.isInfixOf "the mapped write failed"
        (,) <$> atomically occupied <*> (serviceDisposing <$> atomically reading) `shouldReturn` (1, 1)
        _ ← closeView first
        runOwner rig
        second ← openOn rig target
        settleUntil rig ((== 4) <$> occupied)
        atomically (readingPublished <$> readView second) `shouldReturn` Nothing
        serviceDisposing <$> atomically reading `shouldReturn` 1
        -- the owner destroys it: its slot comes back once, and the reopened view publishes
        atomically (writeTVar (nativeDisposing native) True)
        disposeNow (nativeStandIn native)
        settleUntil rig (publishedAtLeast second 1)
        done ← atomically reading
        listed ← atomically (readingListed <$> readView second)
        (Map.findWithDefault 0 1 (serviceOccupied done), serviceDisposing done, servicePending done) `shouldBe` (listed, 0, 0)
        atomically (receiptsHeld (nativeRetained native)) `shouldReturn` (0, 0)

    it "keeps a buffer whose cleanup raised charged, with the upload's refusal and the release's cause, while a competing view with its own room builds" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let reading = readTerrainViews (rigViews rig)
            occupiedOn key = Map.findWithDefault 0 key . serviceOccupied <$> reading
        atomically $ do
          writeTVar (rigFailNext rig) [Just (BuildFailed "BuildUploadRefused UploadClosed" (AllocatedFailed "the failed build's buffer 7 raised on its release: the release raised"))]
          writeTVar (rigRaiseSealed rig) (Just (toException (ErrorCall "the release raised")))
        target ← newTarget 1
        first ← openOn rig target
        -- the view collects the sealed failure: the failure ledger keeps the buffer, the refusal and the release's cause
        settleUntil rig (isJust . readingRefusal <$> readView first)
        failures ← serviceFailures <$> atomically reading
        [cause | (1, Nothing, cause) ← failures] `shouldSatisfy` any (\cause → all (`Text.isInfixOf` cause) ["buffer 7", "UploadClosed", "the release raised"])
        atomically (occupiedOn 1) `shouldReturn` 1
        readTVarIO (rigGrants rig) `shouldReturn` 0
        -- a competing view of another target, with its own room, builds and publishes; the failed buffer stays charged
        other ← newTarget 2
        second ← openOn rig other
        settleUntil rig (publishedAtLeast second 1)
        atomically (occupiedOn 1) `shouldReturn` 1
        serviceFailures <$> atomically reading `shouldReturn` failures
        readTVarIO (rigGrants rig) `shouldReturn` 0

  describe "the settlement hand-off" $ do
    it "leaves a refused build whose revalidation raises or waits to the sweep, which returns its slot once and keeps the refusal's cause and the revalidation's; the view goes on and publishes" $
      forM_ [(HeldRaises, "its revalidation raised"), (HeldWaits, "its revalidation would wait")] $ \(fault, because) →
        withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
          target ← newTarget 1
          atomically $ do
            writeTVar (rigFailNext rig) [Just (BuildFailed "an injected refusal" NotAllocated)]
            writeTVar (rigFault rig) (Just (targetHeld target, fault, False))
          view ← openOn rig target
          settleUntil rig (publishedAtLeast view 1)
          -- the refused build's slot came back once: the target holds exactly the parts it lists
          reading ← atomically (readTerrainViews (rigViews rig))
          listed ← atomically (readingListed <$> readView view)
          Map.findWithDefault 0 1 (serviceOccupied reading) `shouldBe` listed
          servicePending reading `shouldBe` 0
          serviceFailures reading `shouldBe` []
          [why | (1, _, why) ← serviceSwept reading] `shouldSatisfy` any (\why → all (`Text.isInfixOf` why) ["an injected refusal", because])
          readTVarIO (rigGrants rig) `shouldReturn` 0

    it "ends the views' owner when a refused build's revalidation is cancelled: the sweep returns its slot once and keeps the refusal's cause with the cancellation's" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let reading = readTerrainViews (rigViews rig)
        target ← newTarget 1
        atomically $ do
          writeTVar (rigFailNext rig) [Just (BuildFailed "an injected refusal" NotAllocated)]
          writeTVar (rigFault rig) (Just (targetHeld target, HeldCancelled, False))
        view ← openOn rig target
        try @AsyncException (settleUntil rig (publishedAtLeast view 1)) `shouldReturn` Left ThreadKilled
        eventually ((\now → servicePending now == 0 && not (null (serviceSwept now))) <$> reading)
        now ← atomically reading
        Map.findWithDefault 0 1 (serviceOccupied now) `shouldBe` 0
        [why | (1, _, why) ← serviceSwept now] `shouldSatisfy` any (\why → all (`Text.isInfixOf` why) ["an injected refusal", "thread killed"])
        readTVarIO (rigGrants rig) `shouldReturn` 0

    it "relinquishes a build whose revalidation raised an exception whose description is cancelled, with the fallback cause, before the cancellation ends the views' owner: the sweep returns its slot once" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let reading = readTerrainViews (rigViews rig)
        target ← newTarget 1
        atomically $ do
          writeTVar (rigFailNext rig) [Just (BuildFailed "an injected refusal" NotAllocated)]
          writeTVar (rigFault rig) (Just (targetHeld target, HeldRaisesUnspeakable, False))
        view ← openOn rig target
        try @AsyncException (settleUntil rig (publishedAtLeast view 1)) `shouldReturn` Left ThreadKilled
        eventually ((\now → servicePending now == 0 && not (null (serviceSwept now))) <$> reading)
        now ← atomically reading
        Map.findWithDefault 0 1 (serviceOccupied now) `shouldBe` 0
        [why | (1, _, why) ← serviceSwept now] `shouldSatisfy` any (\why → all (`Text.isInfixOf` why) ["an injected refusal", "its revalidation raised: an exception whose description raised"])
        readTVarIO (rigGrants rig) `shouldReturn` 0

    it "retires a registered build whose revalidation raises in place of its view: the target keeps its scene, the chunk's destruction holds a reopened view back while pending and frees its slot once" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let reading = readTerrainViews (rigViews rig)
            occupied = Map.findWithDefault 0 1 . serviceOccupied <$> reading
        target ← newTarget 1
        m1 ← prepare initialGraphicsScene
        atomically $ do
          void (surfacePublish (HeldSurface (targetHeld target)) m1)
          writeTVar (rigDeferDisposal rig) True
          writeTVar (rigFault rig) (Just (targetHeld target, HeldRaises, False))
          -- once the build is sealed, the uploads' room is taken: the view waits after it
          writeTVar (rigAfterSeal rig) (Just (writeTVar (rigAdmission rig) (Just (AdmitLater "held by the example"))))
        before ← atomically (targetScenes target)
        first ← openOn rig target
        -- the sweep retires the registered chunk privately; its release waits for its destruction
        settleUntil rig ((\now → not (null (serviceSwept now)) && serviceDisposing now >= 1) <$> reading)
        map fst <$> atomically (targetScenes target) `shouldReturn` map fst before
        _ ← closeView first
        atomically (writeTVar (rigAdmission rig) Nothing)
        -- a reopened view holds what free slots it has, and waits for the pending one
        second ← openOn rig target
        settleUntil rig ((== 4) <$> occupied)
        atomically (readingPublished <$> readView second) `shouldReturn` Nothing
        awaiting ← readTVarIO (rigPendingDisposals rig)
        -- confirmed: the slot frees once (and later disposals are immediate)
        atomically (forM_ (Map.elems awaiting) (`writeTVar` DisposalDone) >> writeTVar (rigDeferDisposal rig) False)
        settleUntil rig (publishedAtLeast second 1)
        atomically occupied `shouldReturn` 4
        servicePending <$> atomically reading `shouldReturn` 0

    it "reconciles a refused build's late receipt while a second view's admission holds the reference it gave back: only the first build's entry goes, and the successor's entry and charge survive until it builds" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}, optNative = True} $ \rig → do
        native ← maybe (fail "the example needs the native stand-in") pure (rigNative rig)
        let reading = readTerrainViews (rigViews rig)
        firstTarget ← newTarget 1
        secondTarget ← newTarget 2
        -- one grant, the first view's first build: its write into staging raises (refused, and the renderer gives its
        -- reference back), its revalidation raises (left to the sweep), and its receipt's claim is held
        atomically $ do
          writeTVar (rigAdmitBudget rig) (Just 1)
          failNextWrite (nativeStandIn native) (toException (ErrorCall "the mapped write failed"))
          writeTVar (rigFault rig) (Just (targetHeld firstTarget, HeldRaises, False))
          writeTVar (nativeHoldClaim native) True
        first ← openOn rig firstTarget
        settleUntil rig ((== Just 0) <$> readTVar (rigAdmitBudget rig))
        servicePending <$> atomically reading `shouldReturn` 1
        [(firstKey, given)] ← readTVarIO (nativeGrants native)
        -- the first view ends, so nothing of it admits again; the second view's one grant is held before its spend
        _ ← closeView first
        atomically (writeTVar (rigHold rig) (Just 2) >> writeTVar (rigAdmitBudget rig) (Just 1))
        second ← openOn rig secondTarget
        stop ← newTVarIO False
        let owner = do
              runOwner rig
              continue ← atomically ((False <$ (readTVar stop >>= check)) `orElse` (True <$ (readTVar (rigQueue rig) >>= check . not . Seq.null)))
              when continue owner
        withOwnedThread owner $ \_ ended → do
          timeout 10000000 (atomically (takeTMVar (rigEntered rig))) >>= maybe (expectationFailure "the second admission was never held") pure
          -- the second admission holds the reference the refused build gave back, beside the first's unclaimed receipt
          map (chunkRefIndex . snd) <$> readTVarIO (nativeGrants native) `shouldReturn` [chunkRefIndex given, chunkRefIndex given]
          held ← atomically reading
          (servicePending held, Map.findWithDefault 0 2 (serviceOccupied held)) `shouldBe` (2, 1)
          -- the first receipt's claim is let go: the sweep reconciles it, and only its entry goes
          atomically (modifyTVar' (nativeClaimsHeld native) (Set.delete firstKey))
          eventually ((== 1) . servicePending <$> reading)
          swept ← atomically reading
          Map.findWithDefault 0 2 (serviceOccupied swept) `shouldBe` 1
          [why | (1, _, why) ← serviceSwept swept] `shouldSatisfy` any ("the mapped write failed" `Text.isInfixOf`)
          atomically (writeTVar (rigAdmitBudget rig) Nothing >> putTMVar (rigResume rig) () >> writeTVar stop True)
          ended
        settleUntil rig (publishedAtLeast second 1)
        done ← atomically reading
        listed ← atomically (readingListed <$> readView second)
        (Map.findWithDefault 0 2 (serviceOccupied done), servicePending done) `shouldBe` (listed, 0)

    it "retires a build privately, once, when its target's facts change after its revalidation and before its collection, and the view goes on" $
      withRig defaultOptions {optProfile = smallProfile {profileSlots = 4, profileQuads = 2048}} $ \rig → do
        let reading = readTerrainViews (rigViews rig)
        target ← newTarget 1
        changed ← newTVarIO Nothing
        -- between the two boundaries, outside both transactions: the target's facts move (a new version, same facts)
        atomically . writeTVar (rigBeforeCollect rig) . Just $ do
          built ← subtract 1 <$> readTVarIO (rigNext rig)
          atomically (setHeldUsable (targetHeld target) True >> writeTVar changed (Just (chunkRef built 1)))
        view ← openOn rig target
        settleUntil rig (publishedAtLeast view 1)
        quiesce rig target
        stale ← readTVarIO changed >>= maybe (fail "the seam never ran") pure
        -- the stale part went to private retirement and was released once; its slot is free and the view holds its parts
        filter (== stale) <$> readTVarIO (rigDisposed rig) `shouldReturn` [stale]
        now ← atomically reading
        listed ← atomically (readingListed <$> readView view)
        Map.findWithDefault 0 1 (serviceOccupied now) `shouldBe` listed
        (servicePending now, servicePrivate now, serviceSwept now) `shouldBe` (0, 0, [])

    it "keeps the cause of a refused build no view held when the registry's teardown sweep claims it, though it made no buffer" $ do
      views ← withRig defaultOptions $ \rig → do
        sealed ← newTVarIO (Just (Left (BuildFailed "BuildAbandoned" NotAllocated)))
        atomically (modifyTVar' (rigRegistry rig) (Map.insert 9000 sealed))
        pure (rigViews rig)
      serviceUnheld <$> atomically (readTerrainViews views) `shouldReturn` [(9000, "the build failed: BuildAbandoned; no buffer was made")]

    it "follows a held target's observed zero, then unknown geometry with no new frame, clearing its demand, and restores it with the drawing" $
      withPublished defaultOptions $ \rig target view → do
        quiesce rig target
        asked ← atomically (readingDemand <$> readView view)
        published ← atomically (readingPublished <$> readView view)
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 0 0)))
        settleUntil rig (null . readingDemand <$> readView view)
        atomically (setHeldMetrics (targetHeld target) Nothing)
        settleUntil rig (null . readingDemand <$> readView view)
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 320 240)))
        settleUntil rig ((== asked) . readingDemand <$> readView view)
        atomically (readingPublished <$> readView view) `shouldReturn` published

    it "reads a window's observed geometry as the views do: zero, unknown and a complete extent" $ do
      windowGeometryOf WindowGeometryZero `shouldBe` GeometryZero
      windowGeometryOf WindowGeometryUnknown `shouldBe` GeometryUnknown
      windowGeometryOf (WindowGeometryExtent (metricsOf 320 240)) `shouldBe` GeometryExtent (metricsOf 320 240)

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

    it "refuses a replacement whose plan meets a plan-wide bound, and keeps the drawing" $
      withPublished defaultOptions {optProfile = smallProfile {profileQuads = 256, profileRegions = 512}} $ \rig target view → do
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
        unmapped ← styleWith rig ["loam"] True >>= attempt
        either Just (const Nothing) unmapped `shouldSatisfy` \case
          Just (OpenStyle (StyleMissingMaterials [_])) → True
          _ → False
        ended ← styleWith rig ["loam", "granite"] False >>= attempt
        either Just (const Nothing) ended `shouldBe` Just OpenLeaseEnded
        atomically (setHeldAuthority (targetHeld target) False)
        windowGone ← styleOf rig >>= attempt
        either Just (const Nothing) windowGone `shouldBe` Just OpenLeaseEnded
        -- each refused style was released, and no claim or GPU interest stayed
        readTVarIO (rigStyleReleases rig) `shouldReturn` 3
        atomically (claimOf (rigClaims rig) 1) `shouldReturn` Nothing
        atomically (readingInterests <$> ledgerReading (rigLedger rig)) `shouldReturn` Map.empty

    it "asks a target with no frame metrics yet for its first frame at open, and plans once it has one" $
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        atomically (setHeldMetrics (targetHeld target) Nothing)
        view ← openOn rig target
        scenes ← atomically (targetScenes target)
        map (graphicsWorld . snd) scenes `shouldBe` [Nothing]
        -- the frame it asked for is recorded at these metrics: the views notice them with no caller's kick
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 320 240)))
        eventually (not . Seq.null <$> readTVar (rigQueue rig))
        settleUntil rig (publishedAtLeast view 1)

    it "keeps a window's M1 scene on open, and when the first terrain candidate is refused" $
      withRig defaultOptions {optWindow = 64} $ \rig → do
        target ← newTarget 1
        m1 ← prepare initialGraphicsScene
        atomically (void (surfacePublish (HeldSurface (targetHeld target)) m1) >> setHeldMetrics (targetHeld target) Nothing)
        view ← openOn rig target
        -- the scene it shows stays: its frame's metrics, once noticed, start the view
        map fst <$> atomically (targetScenes target) >>= (`shouldBe` [1])
        atomically (setHeldMetrics (targetHeld target) (Just (metricsOf 320 240)))
        settleUntil rig (isJust . readingRefusal <$> readView view)
        map fst <$> atomically (targetScenes target) >>= (`shouldBe` [1])
        -- closed with its claim never published: returned directly, the M1 scene still shown
        _ ← closeView view
        map fst <$> atomically (targetScenes target) >>= (`shouldBe` [1])

  describe "the host's upload answer to a chunk's build" $
    it "is not ready while configured uploads await the device, and keeps the cause of uploads the host lacks or the device refused" $ do
      let answer ∷ Either VulkanUploadRefusal () → Either BufferUploadRefusal ()
          answer = hostUploadAnswer
      answer (Left (VulkanUploadsUnavailable UploadsNotReady)) `shouldBe` Left BufferUploadsNotReady
      answer (Left (VulkanUploadsUnavailable UploadsNotConfigured)) `shouldBe` Left (BufferUploadsUnavailable "the host configured no uploads")
      answer (Left (VulkanUploadsUnavailable (UploadsRefusedBy RefusedDeviceAbsent))) `shouldBe` Left (BufferUploadsUnavailable "the device refused the uploads: RefusedDeviceAbsent")
      answer (Left (VulkanUploadRefused UploadClosed)) `shouldBe` Left (BufferUploadRefused UploadClosed)
      answer (Right ()) `shouldBe` Right ()

  describe "a style's parents" $
    it "refuses a colour parent supplied in the normal slot, each parent's kind its own, and binds parents of their roles' kinds" $ do
      style ← loadAtlasStyle 7 [("loam", "colour.loam"), ("granite", "colour.granite")]
      let parentOf identity atlas =
            StyleParent
              { parentIdentity = identity
              , parentVersion = Atlas.parentTextureVersion atlas
              , parentWidth = fromIntegral (coverageWidth (Atlas.parentCoverage atlas))
              , parentHeight = fromIntegral (coverageHeight (Atlas.parentCoverage atlas))
              , parentPlane = Atlas.parentCoverage atlas
              , parentEncoding = Atlas.parentProfile atlas
              , parentIsData = Atlas.parentKind atlas == Atlas.DataParent
              , parentLevelCount = Atlas.parentLevels atlas
              }
          colour = parentOf 1 (Fixture.styleColour style)
          normal = parentOf 2 (Fixture.styleNormal style)
          checked = checkStyle maxBound (Fixture.styleManifest style) (Fixture.styleMaterialIds style) colour
      either (Just . describeStyleRefusal) (const Nothing) (checked normal) `shouldBe` Nothing
      -- refused, naming the normal parent as the colour it was supplied as
      case checked normal {parentIsData = False} of
        Left refusal → describeStyleRefusal refusal `shouldSatisfy` (\text → all (`Text.isInfixOf` text) ["normal", "ColourParent"])
        Right _ → expectationFailure "expected the normal slot refused, found the style bound"

  describe "the view's reading of a build receipt" $
    it "reads a registered chunk as built, and a refusal that made no buffer as its cause with no allocation" $ do
      let disposal _ = pure DisposalDone
      either (const Nothing) Just (viewReceipt disposal (Right (chunkRef 3 1))) `shouldBe` Just (chunkRef 3 1)
      case viewReceipt disposal (Left (BuildRefused BuildUploadsNotReady NoAllocation)) of
        Left (BuildFailed cause NotAllocated) → cause `shouldBe` "BuildUploadsNotReady"
        _ → expectationFailure "expected the cause with no allocation"

  describe "a window's geometry" $
    it "is zero for an observed zero dimension whatever else is missing, unknown while incomplete, and an extent only when complete" $ do
      let extent w h = Observed (Extent w h)
          scale = Observed (ContentScale 2 2)
          full = TargetMetrics (PixelExtent 480 320) (PixelExtent 960 640) 2 2
      geometryOfAttributes (extent 480 320) (extent 0 0) scale `shouldBe` WindowGeometryZero
      geometryOfAttributes Unavailable (extent 0 640) Unavailable `shouldBe` WindowGeometryZero
      geometryOfAttributes (extent 0 320) Unavailable Unavailable `shouldBe` WindowGeometryZero
      geometryOfAttributes (extent 480 320) Unavailable scale `shouldBe` WindowGeometryUnknown
      geometryOfAttributes (extent 480 320) (extent 960 640) Unavailable `shouldBe` WindowGeometryUnknown
      geometryOfAttributes (extent 480 320) (extent 960 640) scale `shouldBe` WindowGeometryExtent full
      geometryOfAttributes (extent 480 320) (extent 960 640) (Observed (ContentScale (1 / 0) 2)) `shouldBe` WindowGeometryUnknown
      geometryOfMetrics (Just full {metricsScaleX = 1 / 0}) `shouldBe` GeometryUnknown

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

    it "admits no owner step once its final drain has completed" $ do
      held ← newIORef Nothing
      withRig defaultOptions $ \rig → do
        target ← newTarget 1
        view ← openOn rig target
        settleUntil rig (publishedAtLeast view 1)
        writeIORef held (Just rig)
      rig ← readIORef held >>= maybe (fail "the rig never started") pure
      atomically (readTVar (rigQueue rig) >>= \queued → writeTVar (rigQueue rig) Seq.empty >> pure (Seq.length queued)) >>= (`shouldBe` 0)
      -- a late frame event or ledger callback
      atomically (kick (rigViews rig))
      atomically (Seq.length <$> readTVar (rigQueue rig)) `shouldReturn` 0

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

-- A destination away from the origin, region-aligned like it, following the surface as the origin does.
far ∷ JumpTarget
far = JumpTarget (axis 192) (axis 192) Nothing

-- The view's latest revision drawn (its batch said submitted), as the receipt reads it.
drawLatest ∷ Rig → Target → TerrainView Int → IO (DrawnPlan Int)
drawLatest rig target view = do
  world ← atomically (latestWorld target) >>= maybe (fail "no world") pure
  atomically (noteSubmitted (rigReceipts rig) (worldTag world) (worldMetrics world))
  atomically (viewDrawn view) >>= maybe (fail "nothing drawn") pure

-- The plan the planner makes from fresh copies of the drawn plan's regions, at its camera and metrics: what the view
-- must have drawn.
independentPlan ∷ Rig → DrawnPlan Int → IO CellPlan
independentPlan rig drawn = do
  copied ← maybe (fail "no regions") pure (drawnPlanRegions drawn)
  -- complete inputs: F and every region beside it, above and below
  let regions = Set.toList (Set.fromList [RegionCoord (regionX r + dx) (regionY r + dy) (regionZ r + dz) | r ← Set.toList copied, dx ← [-1, 0, 1], dy ← [-1, 0, 1], dz ← [-1, 0, 1]])
  camera ← maybe (fail "no camera") pure (drawnPlanCamera drawn)
  metrics ← maybe (fail "no metrics") pure (drawnPlanMetrics drawn)
  copies ← fmap concat . mapM (copyOf . take 64) . takeWhile (not . null) . iterate (drop 64) $ regions
  combined ← either (fail . show) pure (combineCopies copies)
  (facts, knowledge) ← either (fail . show) pure (planInputs (ChangeLimits (profileRuns smallProfile)) Set.empty combined)
  let config = viewCellConfig defaultTerrainViewsConfig {tvProfile = smallProfile}
      inputs = CellInputs (CellRequest (factsVersions facts) camera (viewSetup metrics) config) facts knowledge (styleAssets (rigStyle rig))
  either (fail . show) pure (planCells inputs)
  where
    copyOf batch =
      withRegionSnapshot (rigTerrain rig) (rigLease rig) batch (either (fail . show) (pure . pure)) >>= either (fail . show) pure

-- The 16 x 16 region of the rotated view frame a quad's key is in, with its level's 32-level region.
regionOfKey ∷ CellKey → (Integer, Integer, Integer)
regionOfKey (CellKey _ z vx vy _) = (vx `div` 16, vy `div` 16, z `div` 32)
