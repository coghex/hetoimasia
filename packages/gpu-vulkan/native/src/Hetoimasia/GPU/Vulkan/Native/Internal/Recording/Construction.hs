-- | Managed-resource construction and release for the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): pipeline layouts, pipelines and
-- their replacements, frame storages, readback buffers, and buffers and
-- images of the engine's kinds (GRS-2), each made in one
-- masked step that reserves the model's accounting, makes the native object,
-- turns the reservation into a managed generation and names that generation
-- before its handle is returned; and 'releaseManaged', which ends a handle's
-- use.
--
-- This module inserts managed records and frame storages into the recording's
-- state ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State") and advances
-- a record to released or replaced; it owns no state of its own. Destroying a
-- released generation is the disposal's ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Disposal"),
-- except for an object the model refused to record, which nothing can
-- reference and which is destroyed here at once.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction
  ( createPipelineLayout
  , createPipeline
  , replacePipeline
  , createFrameStorage
  , createReadback
  , createBuffer
  , createImage
  , releaseManaged
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVarIO)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, mask_, onException, rethrowIO, throwIO, tryWithContext)
import Control.Monad (when)
import qualified Data.Text as Text
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model
  ( Outcome (..)
  , TargetPhase (..)
  , TargetView (..)
  , abandonAllocation
  , beginAllocation
  , createResource
  , endResourceCpuUse
  , modelBudgets
  , rebuildResource
  , SessionFailureCause (CleanupFailed)
  , recordAllocationFailure
  , releaseResource
  , requireInitialization
  )
import qualified Hetoimasia.GPU.Model as Model
import Hetoimasia.GPU.Model.Budget (frameSlotLimit)
import Hetoimasia.GPU.Model.Identity (AllocationId, IdentityKind (..), Misuse (..), ResourceId, TargetId, targetSession)
import Hetoimasia.GPU.Vulkan.Native.Allocator (BoundMemory (..), BufferRequest (..), ImageRequest (..), MemoryTypeRefused (..), MemoryUsage (UsageReadback))
import Hetoimasia.GPU.Vulkan.Native.Internal.Allocation
  ( AllocatedBuffer (..)
  , AllocationRefusal (..)
  , allocateBuffer
  , allocateImage
  , freeBuffer
  , freeImage
  , nameAllocation
  , nameBuffer
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( BufferDescription (..)
  , ImageDescription (..)
  , ImageLimits (..)
  , ImageQuery (..)
  , ImageUse (..)
  , PipelineRequest (..)
  , PipelineShaders
  , ReadbackAllocation (..)
  , RecordingOps (..)
  , ViewRequest (..)
  , bufferKindUse
  , formatCode
  , formatNeedsCompressionBC
  , fullMipChain
  , imageKindUse
  , kindFormats
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( Buffer (..)
  , Image (..)
  , Managed (..)
  , ManagedRecord (..)
  , ManagedStanding (..)
  , NativeResource (..)
  , Pipeline (..)
  , PipelineLayout (..)
  , FrameStorage (..)
  , Readback (..)
  , ReadbackContents (..)
  , Recording (..)
  , Refusal (..)
  , destroyNative
  , editManaged
  , isAsynchronous
  , liveNative
  , modelAnswer
  , modelEdit
  , owned
  , readbackBuffer
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (failingAgain, recoverAllocation)
import Hetoimasia.GPU.Vulkan.Native.Naming
  ( NativeObjectKind (..)
  , ShaderStage
  , bufferName
  , commandBufferName
  , commandPoolName
  , imageName
  , ownedViewName
  , pipelineLayoutName
  , pipelineName
  , readbackBufferName
  , shaderModuleName
  )
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( NativeFailure (..)
  , Roots
  , failRootsSessionBecause
  , nameRootsObject
  , readRootsDevice
  , readRootsInstrumentation
  , rootsCall
  , rootsNativeFailure
  , rootsSessionIdentity
  , stateRootsModel
  )

-- | A pipeline layout with no descriptor sets and no push constants.
createPipelineLayout ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal PipelineLayout)
createPipelineLayout recording =
  fmap PipelineLayout
    <$> construct recording 0 1 "vkCreatePipelineLayout" (\ops device _ _ → Right . NativeLayout <$> opsCreatePipelineLayout ops device) Nothing

-- | A graphics pipeline over the layout, rendering to the color format. The
-- layout must be live; the pipeline depends on that exact generation, which
-- every batch binding the pipeline retains with it.
createPipeline
  ∷ Recording q inst msgr phys dev cmd → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
createPipeline recording layout shaders format = buildPipeline recording layout shaders format Nothing

-- | Publish a new generation of a pipeline, over the given layout. The old
-- generation is released: nothing records it again, and every batch that
-- recorded it keeps it, and its layout, until the batch's references end.
replacePipeline
  ∷ Recording q inst msgr phys dev cmd → Pipeline → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
replacePipeline recording (Pipeline old) layout shaders format = buildPipeline recording layout shaders format (Just old)

buildPipeline
  ∷ Recording q inst msgr phys dev cmd
  → PipelineLayout
  → PipelineShaders
  → Word32
  → Maybe ResourceId
  → IO (Either Refusal Pipeline)
buildPipeline recording (PipelineLayout layout) shaders format replacing =
  liveNative recording layout >>= \case
    Left refusal → pure (Left refusal)
    Right (NativeLayout handle) →
      fmap Pipeline
        <$> construct
          recording
          0
          1
          "vkCreateGraphicsPipelines"
          ( \ops device _ issued → do
              naming ← shaderNaming recording issued
              (\created → Right (NativePipeline created layout format)) <$> opsCreatePipeline ops device (PipelineRequest handle shaders format) naming
          )
          replacing
    Right _ → pure (Left RefusedWrongKind)

-- | A frame slot's command storage: a pool on the session's queue family and
-- its one primary command buffer. A slot has at most one; 'recordFrame'
-- records every frame of that slot into it.
--
-- The target must be one of this session's, still admitted or suspended, and
-- the slot one its frame budget can issue; anything else is refused before
-- any native call.
createFrameStorage ∷ Recording q inst msgr phys dev cmd → TargetId → Natural → IO (Either Refusal FrameStorage)
createFrameStorage recording target slot = do
  existing ← Map.lookup (target, slot) <$> readTVarIO (recordingStorages recording)
  model ← atomically (stateRootsModel (recordingRoots recording) (\current → (current, current)))
  let limit = frameSlotLimit (modelBudgets model)
      unusable = case Model.targetView target model of
        _ | targetSession target /= rootsSessionIdentity (recordingRoots recording) → Just (RefusedMisuse (ForeignIdentity TargetIdentity))
        Nothing → Just (RefusedMisuse (StaleIdentity TargetIdentity))
        Just view
          | viewTargetPhase view `notElem` [TargetAdmitted, TargetSuspended] → Just (RefusedMisuse (WrongPhase TargetIdentity))
          | slot >= limit → Just (RefusedOutOfBounds slot limit)
          | otherwise → Nothing
  case (existing, unusable) of
    (_, Just refused) → pure (Left refused)
    (Just _, _) → pure (Left (RefusedMisuse (DuplicateSubject FrameIdentity)))
    (Nothing, Nothing) → do
      family ← fmap (planQueueFamily . fst) <$> atomically (readRootsDevice (recordingRoots recording))
      case family of
        Nothing → pure (Left RefusedDeviceAbsent)
        Just queueFamily → do
          made ←
            construct
              recording
              0
              2
              "vkCreateCommandPool"
              (\ops device _ _ → (\(pool, commands) → Right (NativeStorage target slot pool commands)) <$> opsCreateStorage ops device queueFamily)
              Nothing
          for_ made (\resource → atomically (modifyTVar' (recordingStorages recording) (Map.insert (target, slot) resource)))
          pure (FrameStorage <$> made)

-- | A readback buffer of this many bytes, its memory from the device's
-- allocator under the readback usage — host-visible, cached where the device
-- offers it — and mapped for its lifetime. 'readbackBytesFor' is what one
-- frame's copy needs.
--
-- The memory is charged as the allocator holds it (D-40), not as the buffer's
-- own size: the attempt reserves two objects, the buffer and its allocation,
-- and no bytes of its own. A usage no memory type serves is
-- 'RefusedNoMemoryType', and a block the byte budget cannot hold is
-- 'RefusedBackpressure', each having allocated nothing.
createReadback ∷ Recording q inst msgr phys dev cmd → Natural → IO (Either Refusal Readback)
createReadback recording bytes
  | bytes == 0 = pure (Left (RefusedOutOfBounds 0 0))
  | otherwise =
      fmap Readback
        <$> construct
          recording
          0
          2
          "vmaCreateBuffer"
          ( \_ _ attempt _ →
              allocateBuffer (recordingRoots recording) attempt UsageReadback (BufferRequest bytes transferDestination) >>= \case
                Left refusal → pure (Left (allocationRefused refusal))
                Right allocated → case allocatedMapped allocated of
                  Just mapped →
                    pure (Right (NativeReadback (ReadbackAllocation (memoryResource (allocatedMemory allocated)) (allocatedMemory allocated) bytes (allocatedCoherent allocated) mapped) ContentsUndefined))
                  -- The readback usage requires host-visible memory, which
                  -- is always mapped.
                  Nothing → do
                    freeBuffer (recordingRoots recording) allocated
                    fail "the readback buffer's memory is not mapped"
          )
          Nothing

-- | @VK_BUFFER_USAGE_TRANSFER_DST_BIT@: what a readback buffer is used as.
transferDestination ∷ Word32
transferDestination = 0x00000002

-- | A buffer of the description's kind and size. The kind fixes its usage
-- flags and the memory usage its allocation is made under
-- ('bufferKindUse'); its memory comes from the device's allocator and, when
-- host-visible, is mapped for its lifetime. Nothing writes it yet.
--
-- A size of zero, one no Vulkan size can hold, or one larger than the
-- device's @maxBufferSize@ is 'RefusedOutOfBounds' before anything is
-- created. Like a readback, its attempt reserves two objects — the buffer and
-- its allocation — and no bytes of its own: the memory is charged as the
-- allocator holds it (D-40). A usage no memory type serves is
-- 'RefusedNoMemoryType', and a block the byte budget cannot hold is
-- 'RefusedBackpressure', each having allocated nothing.
createBuffer ∷ Recording q inst msgr phys dev cmd → BufferDescription → IO (Either Refusal Buffer)
createBuffer recording (BufferDescription kind bytes)
  | bytes == 0 = pure (Left (RefusedOutOfBounds 0 0))
  | bytes > largestSize = pure (Left (RefusedOutOfBounds bytes largestSize))
  | otherwise =
      owned recording $ do
        most ← opsMaxBufferSize (recordingOps recording)
        if bytes > most
          then pure (Left (RefusedOutOfBounds bytes most))
          else
            fmap Buffer
              <$> construct
                recording
                0
                2
                "vmaCreateBuffer"
                ( \_ _ attempt _ →
                    either (Left . allocationRefused) (Right . NativeBuffer kind bytes)
                      <$> allocateBuffer (recordingRoots recording) attempt usage (BufferRequest bytes flags)
                )
                Nothing
  where
    (flags, usage) = bufferKindUse kind
    -- A @VkDeviceSize@.
    largestSize = 2 ^ (64 ∷ Int) - 1

-- | An image of the description's kind, format, extent and mip levels, and
-- its one owned view: the whole image, in its format, over the aspect its kind
-- fixes. The kind fixes its usage flags, the format features it needs and its
-- memory usage ('imageKindUse'); its memory comes from the device's allocator
-- and is never mapped. It awaits initialization: the first batch that touches
-- it must move it out of the undefined layout ('transitionResource'), and no
-- other batch may use it until that one has been submitted (GRS-3).
--
-- Before anything is created, in this order: a format the kind does not take
-- ('kindFormats') is 'RefusedImageUnsupported'; a zero width, height or mip
-- count is 'RefusedOutOfBounds', and so is more mip levels than the extent's
-- full chain; a BC7 format on a device created without
-- @textureCompressionBC@ is 'RefusedImageUnsupported'; then the device is
-- asked about the format, usage and format features — the one native call
-- before creation — and a combination it does not support is
-- 'RefusedImageUnsupported', and an extent or mip count beyond what it
-- supports for it 'RefusedOutOfBounds'. Once the attempt has its reservation,
-- the image's memory requirements are asked of the device, still creating
-- nothing, and ones beyond the device's largest resource for it
-- (@maxResourceSize@) are 'RefusedOutOfBounds' too, naming both sizes.
--
-- The attempt reserves three objects — the image, its allocation and its view
-- — and no bytes of its own (D-40). A view whose creation raised destroys the
-- image and frees its allocation before the failure is raised, so a creation
-- that raised created nothing; if that cleanup raised too, what it concerned
-- is retained and the session fails with 'CleanupFailed'.
createImage ∷ Recording q inst msgr phys dev cmd → ImageDescription → IO (Either Refusal Image)
createImage recording description =
  owned recording $ case describedRefusal of
    Just refusal → pure (Left refusal)
    Nothing →
      atomically (readRootsDevice roots) >>= \case
        Nothing → pure (Left RefusedDeviceAbsent)
        Just (plan, _)
          | formatNeedsCompressionBC format && not (planTextureCompressionBC plan) → pure (Left unsupported)
          | otherwise →
              opsImageSupport ops (ImageQuery code (useImageFlags use) (useFormatFeatures use)) >>= \case
                Nothing → pure (Left unsupported)
                Just limits
                  | width > limitWidth limits → pure (Left (RefusedOutOfBounds (fromIntegral width) (fromIntegral (limitWidth limits))))
                  | height > limitHeight limits → pure (Left (RefusedOutOfBounds (fromIntegral height) (fromIntegral (limitHeight limits))))
                  | levels > limitMipLevels limits → pure (Left (RefusedOutOfBounds (fromIntegral levels) (fromIntegral (limitMipLevels limits))))
                  | otherwise → fmap Image <$> construct recording 0 3 "vmaCreateImage" (create (limitResourceSize limits)) Nothing
  where
    roots = recordingRoots recording
    ops = recordingOps recording
    ImageDescription kind format width height levels = description
    use = imageKindUse kind
    code = formatCode format
    unsupported = RefusedImageUnsupported kind format
    chain = fullMipChain width height
    describedRefusal
      | format `notElem` kindFormats kind = Just unsupported
      | width == 0 || height == 0 || levels == 0 = Just (RefusedOutOfBounds 0 0)
      | levels > chain = Just (RefusedOutOfBounds (fromIntegral levels) (fromIntegral chain))
      | otherwise = Nothing
    create most native device attempt _ =
      allocateImage roots attempt (useMemory use) (ImageRequest code width height levels (useImageFlags use)) most >>= \case
        Left refusal → pure (Left (allocationRefused refusal))
        Right memory → do
          view ←
            rootsCall roots "vkCreateImageView" (opsCreateView native device (ViewRequest (memoryResource memory) code (useAspect use) levels))
              `onException` undoing roots "destroying the image whose view could not be created" (freeImage roots memory)
          pure (Right (NativeImage description memory view))

-- | What an allocation that made nothing refused with, as the recording
-- answers it.
allocationRefused ∷ AllocationRefusal → Refusal
allocationRefused = \case
  AllocationNoAllocator → RefusedDeviceAbsent
  AllocationNoMemoryType (MemoryTypeRefused kind _) → RefusedNoMemoryType kind
  AllocationBackpressure budget → RefusedBackpressure budget
  AllocationRejected misuse → RefusedMisuse misuse
  AllocationBeyondResource needed most → RefusedOutOfBounds needed most

-- | Undo part of a creation that is raising. A cleanup that raised has an
-- unknown effect: what it concerned is retained — an allocation it did not
-- free still counts against the allocator's destruction — never attempted
-- again, and the session fails with 'CleanupFailed'. The creation's own
-- failure is the one raised, unless the cleanup was cancelled.
undoing ∷ Roots q inst msgr phys dev → Text → IO () → IO ()
undoing roots what cleanup =
  tryWithContext @SomeException cleanup >>= \case
    Right () → pure ()
    Left failure@(ExceptionWithContext _ exception) → do
      atomically (failRootsSessionBecause roots CleanupFailed (what <> " raised: " <> Text.pack (displayException exception)))
      when (isAsynchronous exception) (rethrowIO failure)

-- | The naming call a pipeline's shader modules are given: under the
-- identity the model is about to issue the pipeline, when the roots offer
-- naming, and nothing otherwise.
shaderNaming ∷ Recording q inst msgr phys dev cmd → Maybe ResourceId → IO (ShaderStage → Word64 → IO ())
shaderNaming recording issued =
  readRootsInstrumentation roots >>= \case
    Just (_, instrumentation)
      | Just resource ← issued →
          pure (\stage handle → nameRootsObject roots instrumentation ObjectShaderModule handle (shaderModuleName resource stage))
    _ → pure (\_ _ → pure ())
  where
    roots = recordingRoots recording

-- | Reserve the accounting, make the native object, and turn the reservation
-- into a managed generation — or into a new generation of the one being
-- replaced — in one masked step. The creation is told the identity the model
-- is about to issue the generation, for what it names before that identity
-- exists.
--
-- Every exit that produces no managed generation gives the reservation back,
-- exactly once: a refusal the model answers, and a creation that raised, which
-- created nothing — its failure re-raised unchanged, whether it raised at
-- first or during an out-of-memory recovery, from the retry or the
-- reclamation pass, and whether it was a synchronous failure, device loss or a
-- cancellation. A generation the model recorded, on the first creation or the
-- retry, keeps the reservation as its accounting, even when naming it then
-- raises and releases it.
construct
  ∷ Recording q inst msgr phys dev cmd
  → Natural
  → Natural
  → Text
  → (RecordingOps dev cmd → dev → AllocationId → Maybe ResourceId → IO (Either Refusal (NativeResource cmd)))
  → Maybe ResourceId
  → IO (Either Refusal ResourceId)
construct recording bytes objects name create replacing =
  owned recording $
    atomically (readRootsDevice roots) >>= \case
      Nothing → pure (Left RefusedDeviceAbsent)
      Just (_, device) → do
        -- A replacement's predecessor must still be this recording's current,
        -- live generation; the model checks the same before rebuilding.
        predecessor ← case replacing of
          Nothing → pure (Right ())
          Just old → fmap (const ()) <$> liveNative recording old
        case predecessor of
          Left refusal → pure (Left refusal)
          Right () → mask_ $ do
            reserved ← atomically (modelAnswer roots (beginAllocation bytes objects))
            case reserved of
              Left refusal → pure (Left refusal)
              Right allocation → do
                issued ← atomically $ stateRootsModel roots $ \model →
                  let answer = case replacing of
                        Nothing → createResource allocation model
                        Just old → rebuildResource old allocation model
                   in ( case answer of
                          Admitted (_, resource) → Just resource
                          _ → Nothing
                      , model
                      )
                let creation = rootsCall roots name (create (recordingOps recording) device allocation issued)
                    abandoned = atomically $ do
                      modelEdit roots (recordAllocationFailure allocation)
                      modelEdit roots (abandonAllocation allocation)
                made ← tryWithContext @SomeException creation >>= \case
                  -- A creation that raised created nothing, so its rollback is
                  -- complete: out of memory is recovered as an allocation, with
                  -- one reclamation pass and the creation once more only if the
                  -- model permits the attempt's retry (VK-14). Nothing else is.
                  Left (ExceptionWithContext _ exception)
                    | not (isAsynchronous exception)
                    , rootsNativeFailure roots exception == Just FailedOutOfMemory →
                        tryWithContext @SomeException (recoverAllocation roots name (Just allocation) Nothing (Text.pack (displayException exception)) (failingAgain roots creation)) >>= \case
                          Right (Right native) → pure native
                          Right (Left notRecovered) → abandoned >> throwIO notRecovered
                          -- The retry raised — device loss, a cancellation, a
                          -- failure the roots classify — or the reclamation
                          -- pass did: the retry made nothing either way.
                          Left failure → abandoned >> rethrowIO failure
                  Left failure → abandoned >> rethrowIO failure
                  Right native → pure native
                case made of
                  -- The creation refused, having made nothing and holding no
                  -- reservation: backpressure on the memory it would open, or
                  -- no memory type for it.
                  Left refusal → do
                    atomically (modelEdit roots (abandonAllocation allocation))
                    pure (Left refusal)
                  Right native → do
                    committed ← atomically $ do
                      answer ← case replacing of
                        Nothing → modelAnswer roots (createResource allocation)
                        Just old → modelAnswer roots (rebuildResource old allocation)
                      case answer of
                        Right resource → do
                          modifyTVar' (recordingManaged recording) (Map.insert resource (ManagedRecord native ManagedLive))
                          -- A new image's contents are undefined until the
                          -- batch that initializes it is submitted (GRS-3).
                          case native of
                            NativeImage {} → modelEdit roots (requireInitialization resource)
                            _ → pure ()
                          for_ replacing $ \old → do
                            -- The rebuild released the old generation; its CPU
                            -- use ends with it, since no handle may record it.
                            modelEdit roots (endResourceCpuUse old)
                            editManaged recording old (\entry → entry {managedStanding = ManagedReplaced resource})
                          pure (Right resource)
                        Left refusal → do
                          modelEdit roots (abandonAllocation allocation)
                          pure (Left refusal)
                    case committed of
                      Right resource → nameManaged recording resource native
                      Left refusal → do
                        -- The model refused to record what now exists, so
                        -- nothing can reference it: destroy it at once.
                        destroyNative recording device native
                        pure (Left refusal)
  where
    roots = recordingRoots recording

-- | Name a generation's native objects, when the roots offer naming, and a
-- readback's, a buffer's or an image's allocation inside the device's
-- allocator, before its handle is
-- returned. A naming call that raised releases the generation —
-- nothing can record it, its CPU use ends, and the owner's disposal destroys it
-- like any other released generation — and the failure is re-raised.
nameManaged ∷ Recording q inst msgr phys dev cmd → ResourceId → NativeResource cmd → IO (Either Refusal ResourceId)
nameManaged recording resource native =
  tryWithContext @SomeException naming >>= \case
    Right () → pure (Right resource)
    Left failure → do
      atomically $ do
        modelEdit roots (releaseResource resource)
        modelEdit roots (endResourceCpuUse resource)
        editManaged recording resource (\entry → entry {managedStanding = ManagedReleased})
      rethrowIO failure
  where
    roots = recordingRoots recording
    -- An allocation is named inside the allocator whether or not the device
    -- offers naming; the engine's objects only when it does.
    naming = do
      case native of
        NativeReadback allocation _ → nameBuffer roots (readbackBuffer allocation) (readbackBufferName resource)
        NativeBuffer _ _ allocated → nameBuffer roots allocated (bufferName resource)
        NativeImage _ memory _ → nameAllocation roots memory (imageName resource)
        _ → pure ()
      readRootsInstrumentation roots >>= \case
        Nothing → pure ()
        Just (_, instrumentation) →
          for_ (managedNames recording resource native) (\(kind, handle, name) → nameRootsObject roots instrumentation kind handle name)

-- | What each of a generation's native objects is named.
managedNames ∷ Recording q inst msgr phys dev cmd → ResourceId → NativeResource cmd → [(NativeObjectKind, Word64, ByteString)]
managedNames recording resource = \case
  NativeLayout handle → [(ObjectPipelineLayout, handle, pipelineLayoutName resource)]
  NativePipeline handle _ _ → [(ObjectPipeline, handle, pipelineName resource)]
  NativeStorage target slot pool commands →
    [ (ObjectCommandPool, pool, commandPoolName resource target slot)
    , (ObjectCommandBuffer, opsCommandBufferHandle (recordingOps recording) commands, commandBufferName resource target slot)
    ]
  NativeReadback allocation _ → [(ObjectBuffer, allocationBuffer allocation, readbackBufferName resource)]
  NativeBuffer _ _ allocated → [(ObjectBuffer, memoryResource (allocatedMemory allocated), bufferName resource)]
  NativeImage _ memory view → [(ObjectImage, memoryResource memory, imageName resource), (ObjectImageView, view, ownedViewName resource)]

-- | Release a handle: nothing records through it again, and its CPU use —
-- reading a readback included — ends with it. Batches that already recorded
-- it keep it until their own references end.
releaseManaged ∷ Managed handle ⇒ Recording q inst msgr phys dev cmd → handle → IO (Either Refusal ())
releaseManaged recording handle =
  owned recording $
    liveNative recording resource >>= \case
      Left refusal → pure (Left refusal)
      Right _ → atomically $ do
        released ← modelAnswer roots (fmap (\next → (next, ())) . releaseResource resource)
        case released of
          Left refusal → pure (Left refusal)
          Right () → do
            modelEdit roots (endResourceCpuUse resource)
            editManaged recording resource (\entry → entry {managedStanding = ManagedReleased})
            pure (Right ())
  where
    resource = managedResource handle
    roots = recordingRoots recording
