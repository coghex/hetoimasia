-- | A headless native layer for this package's recorder examples: the
-- backend's recording and frames over stand-in native calls, so a snapshot is
-- recorded by the backend's own recorder — its claims, retentions and
-- refusals — with no device, display or loader call.
--
-- Handles are numbers, every succeeding native call is a journal entry, and
-- nothing fails unless an example's configuration makes the ring too small.
-- The recorder's commands are read back from the journal exactly as the
-- native layer was asked to record them, the ring's regions from the
-- recording, and what a ring region was written with from the mapped writes.
--
-- It is this package's own fixture over the backend's public seam
-- ("Hetoimasia.GPU.Vulkan.Native.Roots", @Recording@, @Frames@, @Uploads@,
-- @Allocator@): it imports no other suite's helpers.
module Test.Render.TwoD.Vulkan.StandIn
  ( Rig (..)
  , Rec
  , newRig
  , newRigOffering
  , builders
  , newRenderer
  , resetJournal
  , target
  , depthTarget
  , uploadedTexture
  , framelessOnce
  , commandsRecorded
  , pipelinesMade
  , pipelineHandles
  , layoutsMade
  , mappedWrites
  , claimWrites
  , settleUploads
  , ringOffsets
  , refreshTable
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant, scriptedSource, zeroDuration)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.Native.Allocator
  ( AllocatorOps (..)
  , BoundMemory (..)
  , Creation (..)
  , MemoryEvents (..)
  , MemoryProperty (..)
  , MemoryRequirements (..)
  , MemoryTypeOffer (..)
  , Placement (..)
  , BufferRequest (..)
  , ImageRequest (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Frames
  ( AcquireResult (..)
  , FrameOps (..)
  , Frames
  , FramelessScope
  , newFrames
  , progressFrames
  , recordFramelessIn
  , withFramelessScope
  )
import Hetoimasia.GPU.Vulkan.Native.Generations (newGenerations)
import Hetoimasia.GPU.Vulkan.Native.Naming (ShaderStage (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Profile
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots
import Hetoimasia.GPU.Vulkan.Native.TextureTable (TableLayoutOptions (..), TableUse (..), createStorageTable, createTablePipelineLayoutWith, createTextureTable, refreshTextureTable, registerTexture, releaseTexture, swapTexture)
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadRequest (..), Uploads, UploadsView (..), newUploads, progressUploads, readUploads, submitUpload, validateUploadConfig)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render

-- | The recorder a frame-less batch lends.
type Rec = Recorder () Int Int Text Int Word64

data Rig = Rig
  { rigRecording ∷ !(Recording () Int Int Text Int Word64)
  , rigFrames ∷ !(Frames () Int Int Text Int Word64)
  , rigUploads ∷ !(Uploads () Int Int Text Int Word64)
  , rigCommands ∷ !(TVar [NativeCommand])
    -- ^ Newest first.
  , rigWrites ∷ !(TVar [(Word64, Natural, ByteString)])
    -- ^ The mapped address, the offset and the bytes of every write, newest first.
  , rigFences ∷ !(TVar (Map Word64 Bool))
    -- ^ Every fence: whether it has signalled.
  , rigHandles ∷ !(TVar Word64)
  , rigPipelines ∷ !(TVar [(Word64, PipelineRequest)])
    -- ^ The handle and the request of every pipeline made, newest first.
  , rigLayouts ∷ !(TVar [([Word64], [PushConstantRange])])
    -- ^ The descriptor-set layouts and push-constant ranges of every pipeline
    -- layout made, newest first.
  }

-- | A session with a surface-free device and its frames and uploads, with
-- neither a ring nor a texture table yet: 'newRenderer' makes them. The device
-- offers every depth format.
newRig ∷ IO Rig
newRig = newRigOffering [Depth32Float, Depth24, Depth16]

-- | The same over a device that offers only these depth formats, as a depth
-- attachment and a sampled-or-not image of them.
newRigOffering ∷ [ImageFormat] → IO Rig
newRigOffering offered = do
  commands ← newTVarIO []
  writes ← newTVarIO []
  fences ← newTVarIO Map.empty
  handles ← newTVarIO 1000
  pipelines ← newTVarIO []
  layouts ← newTVarIO []
  memory ← newTVarIO Map.empty
  budgets ← either (fail . show) pure (validateBudgets defaultBudgetRequest {requestedFrameSlots = 2, requestedProgressActions = 32})
  roots ← newRoots (rootOps memory handles) budgets (scriptedSource (pure (scriptedInstant zeroDuration)))
  _ ← startRoots roots (InstanceRequest [] [] [])
  _ ← startRootsDevice roots
  generations ← newGenerations roots
  recording ← newRecording (recordingOps offered commands writes pipelines layouts memory handles) roots generations
  frames ← newFrames (frameOps fences handles) recording
  uploads ← newUploads frames (either (error . show) id (validateUploadConfig 1048576 262144 8)) >>= either (fail . show) pure
  pure (Rig recording frames uploads commands writes fences handles pipelines layouts)

-- | Make the renderer as a host does — the ring, the table, the layout — and
-- let the table's placeholder upload complete, so a batch can bind it.
newRenderer ∷ Rig → Render.Configuration → IO Render.Renderer
newRenderer rig configuration = do
  renderer ← Render.makeRenderer (builders rig) configuration >>= either (fail . show) pure
  settleUploads rig
  refreshTable rig
  pure renderer

-- | The renderer's constructions over the rig's recording.
builders ∷ Rig → Render.Builders () Int Int Text Int Word64
builders rig =
  Render.Builders
    { Render.buildRing = \size window → createRingWith (rigRecording rig) size (Just window)
    , Render.buildStorageTable = createStorageTable (rigRecording rig)
    , Render.buildTable = createTextureTable (rigRecording rig) (rigUploads rig)
    , Render.buildTableLayout = \shaders → createTablePipelineLayoutWith (rigRecording rig) shaders (TableLayoutOptions TableShaderSampler True)
    , Render.buildPipeline = createBlendedCheckedPipeline (rigRecording rig)
    , Render.buildDepthPipeline = createDepthCheckedPipeline (rigRecording rig)
    , Render.buildDepthFormat = selectDepthFormat (rigRecording rig)
    , Render.buildImageFormat = imageFormatOf (rigRecording rig)
    , Render.registerImage = registerTexture (rigRecording rig)
    , Render.swapImage = swapTexture (rigRecording rig)
    , Render.releaseImage = releaseTexture (rigRecording rig)
    , Render.buildVertexBuffer = \bytes → createBuffer (rigRecording rig) (BufferDescription VertexBuffer bytes)
    , Render.uploadBuffer = \buffer bytes → submitUpload (rigUploads rig) (UploadBuffer buffer bytes)
    , Render.releaseBuffer = releaseManaged (rigRecording rig)
    }

-- | A colour target of this format and extent, made as the backend makes one.
target ∷ Rig → ImageFormat → Word32 → Word32 → IO Image
target rig format width height =
  createImage (rigRecording rig) (ImageDescription ColorTarget format width height 1) >>= either (fail . show) pure

-- | A depth target of this format and extent, made as the backend makes one.
depthTarget ∷ Rig → ImageFormat → Word32 → Word32 → IO Image
depthTarget rig format width height =
  createImage (rigRecording rig) (ImageDescription DepthTarget format width height 1) >>= either (fail . show) pure

-- | A two-by-two RGBA8 texture of these bytes, made and uploaded, with its
-- upload settled.
uploadedTexture ∷ Rig → ByteString → IO Image
uploadedTexture rig bytes = do
  image ← createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Linear 2 2 1) >>= either (fail . show) pure
  _ ← submitUpload (rigUploads rig) (UploadImage image [bytes]) >>= either (fail . show) pure
  settleUploads rig
  refreshTable rig
  pure image

-- | Record one frame-less batch in a scope of its own, answering what the
-- consumer returned. The batch is submitted when the scope ends.
framelessOnce ∷ Rig → (Rec → IO a) → IO a
framelessOnce rig consumer =
  withFramelessScope (rigFrames rig) $ \scope →
    recordFramelessIn (scope ∷ FramelessScope () Int Int Text Int Word64) consumer >>= either (fail . show) (pure . snd)

-- | Forget the commands and the mapped writes so far, as an example does once
-- its fixture is set up.
resetJournal ∷ Rig → IO ()
resetJournal rig = atomically (writeTVar (rigCommands rig) [] >> writeTVar (rigWrites rig) [])

-- | Every command the native layer was asked to record, oldest first.
commandsRecorded ∷ Rig → IO [NativeCommand]
commandsRecorded rig = reverse <$> readTVarIO (rigCommands rig)

-- | Every pipeline made, oldest first.
pipelinesMade ∷ Rig → IO [PipelineRequest]
pipelinesMade rig = map snd <$> pipelineHandles rig

-- | Every pipeline made with the handle the native layer gave it, oldest first.
pipelineHandles ∷ Rig → IO [(Word64, PipelineRequest)]
pipelineHandles rig = reverse <$> readTVarIO (rigPipelines rig)

-- | The descriptor-set layouts and push-constant ranges of every pipeline layout made, oldest first.
layoutsMade ∷ Rig → IO [([Word64], [PushConstantRange])]
layoutsMade rig = reverse <$> readTVarIO (rigLayouts rig)

-- | Every mapped write, oldest first: the mapped address, the offset and the bytes.
mappedWrites ∷ Rig → IO [(Word64, Natural, ByteString)]
mappedWrites rig = reverse <$> readTVarIO (rigWrites rig)

-- | What each region of the ring a batch holds was written with, in claim
-- order: the region's offset and the bytes of the mapped write that filled it.
claimWrites ∷ Rig → IO [(Natural, ByteString)]
claimWrites rig = do
  claims ← atomically (readRing (rigRecording rig))
  writes ← mappedWrites rig
  pure
    [ (offset, bytes)
    | Just ring ← [claims]
    , (_, record) ← ringViewClaims ring
    , let offset = claimRecordOffset record
    , (_, written, bytes) ← writes
    , written == offset
    , fromIntegral (ByteString.length bytes) == claimRecordSize record
    ]

-- | Where each region of the ring a batch holds starts, in claim order.
ringOffsets ∷ Rig → IO [Natural]
ringOffsets rig =
  atomically (readRing (rigRecording rig)) >>= \case
    Just ring → pure [claimRecordOffset record | (_, record) ← ringViewClaims ring]
    Nothing → fail "the ring was not made"

refreshTable ∷ Rig → IO ()
refreshTable rig = refreshTextureTable (rigRecording rig) >>= either (fail . show) pure

-- | Turn the uploads and complete every pending fence until none is left.
settleUploads ∷ Rig → IO ()
settleUploads rig = go (32 ∷ Int)
  where
    go 0 = fail "the uploads did not settle in 32 turns"
    go remaining = do
      _ ← progressUploads (rigUploads rig) >>= either (fail . show) pure
      complete
      _ ← progressUploads (rigUploads rig) >>= either (fail . show) pure
      left ← uploadsUnsettled <$> atomically (readUploads (rigUploads rig))
      when (not (null left)) (go (remaining - 1))
    complete = do
      atomically (modifyTVar' (rigFences rig) (Map.map (const True)))
      _ ← progressFrames (rigFrames rig) at1
      pure ()
    at1 ∷ Instant
    at1 = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero 1000000))

fresh ∷ TVar Word64 → IO Word64
fresh handles = atomically $ do
  next ← readTVar handles
  writeTVar handles (next + 1)
  pure next

-- ---------------------------------------------------------------------------
-- The roots

rootOps ∷ TVar (Map Word64 ByteString) → TVar Word64 → RootOps () Int Int Text Int
rootOps _ handles =
  RootOps
    { opsInstanceOffer =
        pure
          InstanceOffer
            { offerLoaderVersion = packApiVersion 1 3 296
            , offerInstanceExtensions = [debugUtilsExtension, getSurfaceCapabilities2Extension, surfaceMaintenance1Extension, portabilityEnumerationExtension]
            , offerLayers = []
            , offerLayerExtensions = []
            }
    , opsCreateInstance = \_ → pure 1
    , opsCreateMessenger = \_ → pure 2
    , opsDestroyMessenger = \_ _ → pure ()
    , opsDestroyInstance = \_ → pure ()
    , opsDeviceOffers = \_ _ → pure [standInDevice]
    , opsCreateDevice = \_ _ → pure 3
    , opsDestroyDevice = \_ → pure ()
    , opsCreateAllocator = \_ _ _ → allocatorOps handles
    , opsSurfaceSupport = \_ _ _ _ → pure True
    , opsDeviceLoss = const False
    , opsNativeFailure = const Nothing
    , opsDeviceHandle = fromIntegral
    , opsDeviceQueue = \_ _ → pure 4
    , opsInstrumentation = \_ → pure Nothing
    , opsGenerations =
        GenerationOps
          { opsSurfaceOffer = \_ _ → pure standInOffer
          , opsCreateSwapchain = \_ _ → fresh handles
          , opsSwapchainImages = \_ _ → pure []
          , opsCreateImageView = \_ _ _ → fresh handles
          , opsDestroyImageView = \_ _ → pure ()
          , opsDestroySwapchain = \_ _ → pure ()
          }
    }

-- | One device satisfying the whole profile, with the single queue family that
-- graphics and presentation share.
standInDevice ∷ DeviceOffer Text
standInDevice =
  DeviceOffer
    { offerDevice = "stand-in device"
    , offerDeviceName = "stand-in device"
    , offerDeviceApiVersion = packApiVersion 1 3 0
    , offerDeviceExtensions = [swapchainExtension, swapchainMaintenance1Extension]
    , offerDynamicRendering = True
    , offerSynchronization2 = True
    , offerSwapchainMaintenance1 = True
    , offerBindless = allBindlessFeatures
    , offerTextureCompressionBC = True
    , offerQueueFamilies = [QueueFamilyOffer 0 True True]
    }

standInOffer ∷ SurfaceOffer
standInOffer =
  SurfaceOffer
    { offerCapabilities =
        SurfaceCapabilities
          { capabilityMinImages = 2
          , capabilityMaxImages = 8
          , capabilityCurrentExtent = Just (SurfaceExtent 640 480)
          , capabilityMinExtent = SurfaceExtent 1 1
          , capabilityMaxExtent = SurfaceExtent 4096 4096
          , capabilityUsage = imageUsageColorAttachment
          , capabilityCurrentTransform = 1
          , capabilityCompositeAlpha = compositeAlphaOpaque
          }
    , offerFormats = [SurfaceFormat formatB8G8R8A8Srgb colorSpaceSrgbNonlinear]
    , offerPresentModes = [presentModeFifo]
    }

-- ---------------------------------------------------------------------------
-- The allocator: every creation opens a dedicated block of its own size, and
-- every destruction frees it, so the model's accounting balances.

allocatorOps ∷ TVar Word64 → IO AllocatorOps
allocatorOps handles = do
  held ← newIORef (Map.empty ∷ Map Word64 Natural)
  let create size kind placement
        -- A placement in held memory opens nothing: this allocator holds no
        -- blocks to place into, so the engine asks again to open one.
        | placement == InHeldMemory = pure (MemoryEvents 0 0 0 0, NotPlaced)
        | otherwise = do
            resource ← fresh handles
            allocation ← fresh handles
            block ← fresh handles
            atomicModifyIORef' held (\sizes → (Map.insert allocation size sizes, ()))
            pure (MemoryEvents 1 size 0 0, Created (BoundMemory resource allocation block 0 size kind))
      destroy memory = do
        size ← atomicModifyIORef' held (\sizes → (Map.delete (memoryAllocation memory) sizes, Map.findWithDefault 0 (memoryAllocation memory) sizes))
        pure (MemoryEvents 0 0 1 size)
      imageSize request = fromIntegral (requestImageWidth request) * fromIntegral (requestImageHeight request) * 4
  pure
    AllocatorOps
      { allocatorMemoryTypes =
          [ MemoryTypeOffer 0 [DeviceLocal] 65536
          , MemoryTypeOffer 1 [HostVisible, HostCoherent] 65536
          , MemoryTypeOffer 2 [HostVisible, HostCoherent, HostCached] 65536
          ]
      , allocatorBufferRequirements = \request → pure (MemoryRequirements (requestBufferSize request) 0x7)
      , allocatorCreateBuffer = \request kind placement → create (requestBufferSize request) kind placement
      , allocatorDestroyBuffer = destroy
      , allocatorImageRequirements = \request → pure (MemoryRequirements (imageSize request) 0x7)
      , allocatorCreateImage = \request kind placement → create (imageSize request) kind placement
      , allocatorDestroyImage = destroy
      , allocatorMap = \memory → pure (memoryAllocation memory)
      , allocatorUnmap = \_ → pure ()
      , allocatorFlush = \_ _ → pure ()
      , allocatorInvalidate = \_ _ → pure ()
      , allocatorName = \_ _ → pure ()
      , allocatorDestroy = do
          sizes ← readIORef held
          pure (MemoryEvents 0 0 (fromIntegral (Map.size sizes)) (sum (Map.elems sizes)))
      }

-- ---------------------------------------------------------------------------
-- The recording

recordingOps ∷ [ImageFormat] → TVar [NativeCommand] → TVar [(Word64, Natural, ByteString)] → TVar [(Word64, PipelineRequest)] → TVar [([Word64], [PushConstantRange])] → TVar (Map Word64 ByteString) → TVar Word64 → RecordingOps Int Word64
recordingOps offered commands writes pipelines layouts memory handles =
  RecordingOps
    { opsCreatePipelineLayout = \_ sets ranges → do
        atomically (modifyTVar' layouts ((sets, ranges) :))
        fresh handles
    , opsDestroyPipelineLayout = \_ _ → pure ()
    , opsCreatePipeline = \_ request name → do
        vertex ← fresh handles
        name VertexStage vertex
        fragment ← fresh handles
        name FragmentStage fragment
        handle ← fresh handles
        atomically (modifyTVar' pipelines ((handle, request) :))
        pure handle
    , opsDestroyPipeline = \_ _ → pure ()
    , opsCreateStorage = \_ _ → (,) <$> fresh handles <*> fresh handles
    , opsResetStorage = \_ _ → pure ()
    , opsDestroyStorage = \_ _ → pure ()
    , opsReadMapped = \allocation offset size → do
        bytes ← Map.findWithDefault ByteString.empty (allocationMapped allocation) <$> readTVarIO memory
        pure (ByteString.take (fromIntegral size) (ByteString.drop (fromIntegral offset) bytes))
    , opsWriteMapped = \allocation offset bytes → atomically $ do
        modifyTVar' writes ((allocationMapped allocation, offset, bytes) :)
        modifyTVar' memory $
          Map.alter
            ( \held →
                let current = maybe (ByteString.replicate (fromIntegral (allocationSize allocation)) 0) id held
                 in Just (ByteString.take (fromIntegral offset) current <> bytes <> ByteString.drop (fromIntegral offset + ByteString.length bytes) current)
            )
            (allocationMapped allocation)
    , opsBeginCommands = \_ → pure ()
    , opsEndCommands = \_ → pure ()
    , opsRecord = \_ command → atomically (modifyTVar' commands (command :))
    , opsCommandBufferHandle = id
    , opsImageSupport = \query →
        pure $
          if queryFormat query `elem` map formatCode [format | format ← [Depth32Float, Depth24, Depth16], format `notElem` offered]
            then Nothing
            else Just (ImageLimits 16384 16384 15 (2 ^ (31 ∷ Int)))
    , opsMaxBufferSize = pure (1024 * 1024 * 1024)
    , opsMaxFramebuffer = pure (16384, 16384)
    , opsRecordingLimits = pure (RecordingLimits 128 16 16 2048 2047 64 16384 500000 500000 500000 4 256 134217728 500000 4 4)
    , opsCreateView = \_ _ → fresh handles
    , opsDestroyView = \_ _ → pure ()
    , opsCreateSampler = \_ _ → fresh handles
    , opsDestroySampler = \_ _ → pure ()
    , opsCreateSetLayout = \_ _ → fresh handles
    , opsDestroySetLayout = \_ _ → pure ()
    , opsCreateDescriptorPool = \_ _ → fresh handles
    , opsDestroyDescriptorPool = \_ _ → pure ()
    , opsAllocateSet = \_ _ _ _ → fresh handles
    , opsWriteDescriptors = \_ _ → pure ()
    }

-- ---------------------------------------------------------------------------
-- The frames: a submission's fence signals when the example says so.

frameOps ∷ TVar (Map Word64 Bool) → TVar Word64 → FrameOps Int Word64
frameOps fences handles =
  FrameOps
    { opsCreateSemaphore = \_ → fresh handles
    , opsDestroySemaphore = \_ _ → pure ()
    , opsCreateFence = \_ → do
        handle ← fresh handles
        handle <$ atomically (modifyTVar' fences (Map.insert handle False))
    , opsDestroyFence = \_ handle → atomically (modifyTVar' fences (Map.delete handle))
    , opsResetFence = \_ handle → atomically (modifyTVar' fences (Map.insert handle False))
    , opsFenceSignalled = \_ handle → atomically (Map.findWithDefault False handle <$> readTVar fences)
    , opsAcquireImage = \_ _ _ → pure AcquiringNotReady
    , opsSubmit = \_ _ _ fence → do
        atomically (modifyTVar' fences (Map.insert fence False))
    , opsNoEffect = const False
    , opsReleaseImages = \_ _ _ → pure ()
    , opsPresent = \_ _ _ _ → pure ()
    , opsWaitFence = \_ handle _ → atomically (Map.findWithDefault False handle <$> readTVar fences)
    }
