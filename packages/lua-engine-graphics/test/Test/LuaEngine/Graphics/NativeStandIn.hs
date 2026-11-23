-- | A headless native session for the terrain views' examples that need the renderer's own registry and the backend's
-- own uploads (test-only, approved for this suite on 2026-11-22): the backend's roots, recording, frames and uploads
-- over stand-in native calls, so a granted part is admitted, spent, released and destroyed by the production code, with
-- no device, display or loader call.
--
-- Handles are numbers and nothing fails unless an example asks: the next write into mapped memory raises
-- ('failNextWrite'). The recording takes its owner-thread calls only from the thread that made it, so the stand-in
-- keeps a native thread of its own and every call that needs the owner runs there ('onNative'), whichever thread asks.
-- Released buffers are destroyed only when an example disposes of them ('disposeNow'), so a destruction can be held
-- pending across steps.
--
-- It is this suite's own fixture over the backend's public seam ("Hetoimasia.GPU.Vulkan.Native.Roots", @Recording@,
-- @Frames@, @Uploads@, @Allocator@): it imports no other suite's helpers.
module Test.LuaEngine.Graphics.NativeStandIn
  ( StandIn
  , withStandIn
  , standInBuilders
  , standInUploads
  , standInDisposal
  , failNextWrite
  , settleUploads
  , disposeNow
  , submittedBatch
  , discardedBatch
  , completeBatches
  ) where

import Control.Concurrent.STM (STM, TQueue, TVar, atomically, modifyTVar', newEmptyTMVarIO, newTQueueIO, newTVarIO, putTMVar, readTQueue, readTVar, readTVarIO, takeTMVar, writeTQueue, writeTVar)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forever, join, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Functor ((<&>))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant, scriptedSource, zeroDuration)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.GLFW (ConstructedDisposal (..))
import Hetoimasia.GPU.Vulkan.Native.Allocator
  ( AllocatorOps (..)
  , BoundMemory (..)
  , BufferRequest (..)
  , Creation (..)
  , ImageRequest (..)
  , MemoryEvents (..)
  , MemoryProperty (..)
  , MemoryRequirements (..)
  , MemoryTypeOffer (..)
  , Placement (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Frames (AcquireResult (..), FrameOps (..), Frames, newFrames, progressFrames, recordFramelessIn, withFramelessScope)
import Hetoimasia.GPU.Vulkan.Native.Generations (newGenerations)
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Profile
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots
import Hetoimasia.GPU.Vulkan.Native.Uploads (Uploads, UploadsView (..), newUploads, progressUploads, readUploads, validateUploadConfig)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Test.Support.Owned (withOwnedThread)

-- | The stand-in session.
data StandIn = StandIn
  { standRecording ∷ !(Recording () Int Int Text Int Word64)
  , standFrames ∷ !(Frames () Int Int Text Int Word64)
  , standUploads ∷ !(Uploads () Int Int Text Int Word64)
  , standFences ∷ !(TVar (Map Word64 Bool))
  , standWriting ∷ !(TVar (Maybe SomeException))
  , standJobs ∷ !(TQueue (IO ()))
  }

-- | A session on a native thread of its own for the length of the body.
withStandIn ∷ (StandIn → IO a) → IO a
withStandIn body = do
  jobs ← newTQueueIO
  made ← newEmptyTMVarIO
  let native = do
        session ← try @SomeException (make jobs)
        atomically (putTMVar made session)
        forever (join (atomically (readTQueue jobs)))
  withOwnedThread native $ \_ _ → atomically (takeTMVar made) >>= either (throwIO @SomeException) pure >>= body

-- Run an owner-thread call on the stand-in's native thread, and answer its result (or raise its exception) here.
onNative ∷ StandIn → IO a → IO a
onNative standIn action = do
  box ← newEmptyTMVarIO
  atomically (writeTQueue (standJobs standIn) (try @SomeException action >>= atomically . putTMVar box))
  atomically (takeTMVar box) >>= either throwIO pure

make ∷ TQueue (IO ()) → IO StandIn
make jobs = do
  fences ← newTVarIO Map.empty
  handles ← newTVarIO 1000
  memory ← newTVarIO Map.empty
  writing ← newTVarIO Nothing
  budgets ← either (fail . show) pure (validateBudgets defaultBudgetRequest {requestedFrameSlots = 2, requestedProgressActions = 32})
  roots ← newRoots (rootOps handles) budgets (scriptedSource (pure (scriptedInstant zeroDuration)))
  _ ← startRoots roots (InstanceRequest [] [] [])
  _ ← startRootsDevice roots
  generations ← newGenerations roots
  recording ← newRecording (recordingOps memory handles writing) roots generations
  frames ← newFrames (frameOps fences handles) recording
  uploads ← newUploads frames (either (error . show) id (validateUploadConfig 1048576 262144 8)) >>= either (fail . show) pure
  pure (StandIn recording frames uploads fences writing jobs)

-- | The renderer's constructions over the stand-in: a vertex buffer made, uploaded into through the session's own
-- uploads and released by the backend, each on the native thread. Nothing else is made.
standInBuilders ∷ StandIn → Render.Builders () Int Int Text Int Word64
standInBuilders standIn =
  Render.Builders
    { Render.buildRing = \_ _ → refused
    , Render.buildStorageTable = refused
    , Render.buildTable = \_ → refused
    , Render.buildTableLayout = \_ → refused
    , Render.buildPipeline = \_ _ _ _ → refused
    , Render.buildDepthPipeline = \_ _ _ _ _ → refused
    , Render.buildDepthFormat = refused
    , Render.buildImageFormat = \_ → refused
    , Render.registerImage = \_ → refused
    , Render.swapImage = \_ _ → refused
    , Render.releaseImage = \_ → refused
    , Render.buildVertexBuffer = \bytes → onNative standIn (createBuffer (standRecording standIn) (BufferDescription VertexBuffer bytes))
    , Render.bufferUploads = standInUploads standIn
    , Render.releaseBuffer = onNative standIn . releaseManaged (standRecording standIn)
    }
  where
    refused ∷ IO (Either Refusal a)
    refused = pure (Left (RefusedIllegal "the terrain views' stand-in makes only vertex buffers"))

-- | The session's own uploads, ungated.
standInUploads ∷ StandIn → Render.BufferUploads
standInUploads = Render.bufferUploadsOf . standUploads

-- | Where a buffer's physical destruction stands, as the backend's managed record says.
standInDisposal ∷ StandIn → Buffer → STM ConstructedDisposal
standInDisposal standIn buffer =
  readManagedStanding (standRecording standIn) (managedResource buffer) <&> \case
    Nothing → DisposalDone
    Just (ManagedUncertain why) → DisposalFailed why
    Just _ → DisposalPending

-- | The next write into mapped memory raises this, once, before it writes.
failNextWrite ∷ StandIn → SomeException → STM ()
failNextWrite standIn = writeTVar (standWriting standIn) . Just

-- | Record and complete every queued upload: the owner's turns, with every submission's fence signalled.
settleUploads ∷ StandIn → IO ()
settleUploads standIn = onNative standIn (go (32 ∷ Int))
  where
    go 0 = fail "the stand-in's uploads did not settle in 32 turns"
    go remaining = do
      _ ← progressUploads (standUploads standIn) >>= either (fail . show) pure
      atomically (modifyTVar' (standFences standIn) (Map.map (const True)))
      _ ← progressFrames (standFrames standIn) later
      _ ← progressUploads (standUploads standIn) >>= either (fail . show) pure
      left ← uploadsUnsettled <$> atomically (readUploads (standUploads standIn))
      when (not (null left)) (go (remaining - 1))

-- | A frame-less batch, recorded with nothing and submitted: its ticket is pending until the stand-in completes it
-- ('completeBatches').
submittedBatch ∷ StandIn → IO BatchTicket
submittedBatch standIn =
  onNative standIn . withFramelessScope (standFrames standIn) $ \scope →
    recordFramelessIn scope (\_ → pure ()) >>= either (fail . show) (pure . fst)

-- | A frame-less batch recorded and then discarded before its submission: its ticket says so.
discardedBatch ∷ StandIn → IO BatchTicket
discardedBatch standIn =
  onNative standIn $ do
    held ← newIORef Nothing
    _ ← try @SomeException . withFramelessScope (standFrames standIn) $ \scope → do
      recordFramelessIn scope (\_ → pure ()) >>= either (fail . show) (writeIORef held . Just . fst)
      throwIO (userError "the scope ends before it submits")
    readIORef held >>= maybe (fail "no batch was recorded") pure

-- | Complete every submitted batch: its fence signals and the frames observe it.
completeBatches ∷ StandIn → IO ()
completeBatches standIn =
  onNative standIn $ do
    atomically (modifyTVar' (standFences standIn) (Map.map (const True)))
    void (progressFrames (standFrames standIn) later)

-- | Destroy every released buffer whose holds have ended, as the owner's disposal does.
disposeNow ∷ StandIn → IO ()
disposeNow standIn = onNative standIn (void (disposeResources (standRecording standIn) later))

later ∷ Instant
later = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero 1000000))

fresh ∷ TVar Word64 → IO Word64
fresh handles = atomically $ do
  next ← readTVar handles
  writeTVar handles (next + 1)
  pure next

-- ---------------------------------------------------------------------------
-- The native calls

rootOps ∷ TVar Word64 → RootOps () Int Int Text Int
rootOps handles =
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
    , opsDeviceOffers = \_ _ → pure [device]
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
          { opsSurfaceOffer = \_ _ → pure offer
          , opsCreateSwapchain = \_ _ → fresh handles
          , opsSwapchainImages = \_ _ → sequence [fresh handles, fresh handles, fresh handles]
          , opsCreateImageView = \_ _ _ → fresh handles
          , opsDestroyImageView = \_ _ → pure ()
          , opsDestroySwapchain = \_ _ → pure ()
          }
    }
  where
    device =
      DeviceOffer
        { offerDevice = "stand-in device"
        , offerDeviceName = "stand-in device"
        , offerDriverName = "stand-in driver"
        , offerDriverInfo = "stand-in"
        , offerSubPixelPrecisionBits = 8
        , offerDeviceApiVersion = packApiVersion 1 3 0
        , offerDeviceExtensions = [swapchainExtension, swapchainMaintenance1Extension]
        , offerDynamicRendering = True
        , offerSynchronization2 = True
        , offerSwapchainMaintenance1 = True
        , offerBindless = allBindlessFeatures
        , offerTextureCompressionBC = True
        , offerQueueFamilies = [QueueFamilyOffer 0 True True]
        }
    offer =
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

-- Every creation opens a dedicated block of its own size, and every destruction frees it.
allocatorOps ∷ TVar Word64 → IO AllocatorOps
allocatorOps handles = do
  held ← newIORef (Map.empty ∷ Map Word64 Natural)
  let create size kind placement
        | placement == InHeldMemory = pure (MemoryEvents 0 0 0 0, NotPlaced)
        | otherwise = do
            resource ← fresh handles
            allocation ← fresh handles
            block ← fresh handles
            atomicModifyIORef' held (\sizes → (Map.insert allocation size sizes, ()))
            pure (MemoryEvents 1 size 0 0, Created (BoundMemory resource allocation block 0 size kind))
      destroy bound = do
        size ← atomicModifyIORef' held (\sizes → (Map.delete (memoryAllocation bound) sizes, Map.findWithDefault 0 (memoryAllocation bound) sizes))
        pure (MemoryEvents 0 0 1 size)
      imageSize request = fromIntegral (requestImageWidth request) * fromIntegral (requestImageHeight request) * 4
  pure
    AllocatorOps
      { allocatorMemoryTypes =
          [ MemoryTypeOffer 0 [DeviceLocal] 65536
          , MemoryTypeOffer 1 [HostVisible, HostCoherent] 65536
          ]
      , allocatorBufferRequirements = \request → pure (MemoryRequirements (requestBufferSize request) 0x3)
      , allocatorCreateBuffer = \request kind placement → create (requestBufferSize request) kind placement
      , allocatorDestroyBuffer = destroy
      , allocatorImageRequirements = \request → pure (MemoryRequirements (imageSize request) 0x3)
      , allocatorCreateImage = \request kind placement → create (imageSize request) kind placement
      , allocatorDestroyImage = destroy
      , allocatorMap = \bound → pure (memoryAllocation bound)
      , allocatorUnmap = \_ → pure ()
      , allocatorFlush = \_ _ → pure ()
      , allocatorInvalidate = \_ _ → pure ()
      , allocatorName = \_ _ → pure ()
      , allocatorDestroy = do
          sizes ← readIORef held
          pure (MemoryEvents 0 0 (fromIntegral (Map.size sizes)) (sum (Map.elems sizes)))
      }

recordingOps ∷ TVar (Map Word64 ByteString) → TVar Word64 → TVar (Maybe SomeException) → RecordingOps Int Word64
recordingOps memory handles writing =
  RecordingOps
    { opsCreatePipelineLayout = \_ _ _ → fresh handles
    , opsDestroyPipelineLayout = \_ _ → pure ()
    , opsCreatePipeline = \_ _ _ → fresh handles
    , opsDestroyPipeline = \_ _ → pure ()
    , opsCreateStorage = \_ _ → (,) <$> fresh handles <*> fresh handles
    , opsResetStorage = \_ _ → pure ()
    , opsDestroyStorage = \_ _ → pure ()
    , opsReadMapped = \allocation offset size → do
        bytes ← Map.findWithDefault ByteString.empty (allocationMapped allocation) <$> readTVarIO memory
        pure (ByteString.take (fromIntegral size) (ByteString.drop (fromIntegral offset) bytes))
    , opsUploadQueued = pure ()
    , opsWriteMapped = \allocation offset bytes → do
        atomically (readTVar writing <* writeTVar writing Nothing) >>= mapM_ throwIO
        atomically . modifyTVar' memory $
          Map.alter
            ( \held →
                let current = maybe (ByteString.replicate (fromIntegral (allocationSize allocation)) 0) id held
                 in Just (ByteString.take (fromIntegral offset) current <> bytes <> ByteString.drop (fromIntegral offset + ByteString.length bytes) current)
            )
            (allocationMapped allocation)
    , opsBeginCommands = \_ → pure ()
    , opsEndCommands = \_ → pure ()
    , opsRecord = \_ _ → pure ()
    , opsCommandBufferHandle = id
    , opsImageSupport = \_ → pure (Just (ImageLimits 16384 16384 15 (2 ^ (31 ∷ Int))))
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

-- A submission's fence signals once the stand-in settles the uploads.
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
    , opsSubmit = \_ _ _ fence → atomically (modifyTVar' fences (Map.insert fence False))
    , opsNoEffect = const False
    , opsReleaseImages = \_ _ _ → pure ()
    , opsPresent = \_ _ _ _ → pure ()
    , opsWaitFence = \_ handle _ → atomically (Map.findWithDefault False handle <$> readTVar fences)
    }
