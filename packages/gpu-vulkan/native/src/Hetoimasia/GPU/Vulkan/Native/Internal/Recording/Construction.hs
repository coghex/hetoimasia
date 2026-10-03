-- | Managed-resource construction and release for the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): pipeline layouts, pipelines and
-- their replacements, frame storages, readback buffers, buffers and images of
-- the engine's kinds (GRS-2), and the session's shared ring (GRS-4), each made
-- in one
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
  ( createStaging
  , createPipelineLayout
  , createPipelineLayoutWith
  , createPipeline
  , createPipelineWith
  , replacePipeline
  , replacePipelineWith
  , checkedRanges
  , createPipelineLayoutFor
  , createCheckedPipeline
  , replaceCheckedPipeline
  , createRing
  , createFrameStorage
  , createFramelessStorage
  , createReadback
  , createBuffer
  , createImage
  , releaseManaged
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar, readTVarIO, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, mask_, onException, rethrowIO, throwIO, tryWithContext)
import Control.Monad (when)
import qualified Data.Text as Text
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.List (nub, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
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
  , PipelineShaders (..)
  , PushConstantRange (..)
  , PushStage (..)
  , ReadbackAllocation (..)
  , RecordingLimits (..)
  , RecordingOps (..)
  , VertexAttribute (..)
  , VertexBinding (..)
  , VertexInput (..)
  , ViewRequest (..)
  , BufferKind (InstanceBuffer, StagingBuffer)
  , bufferKindUse
  , noVertexInput
  , vertexFormatBytes
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
  , PipelineInterface (..)
  , PipelineLayout (..)
  , FrameStorage (..)
  , Readback (..)
  , ReadbackContents (..)
  , Recording (..)
  , Refusal (..)
  , RingSize
  , RingState (..)
  , StorageOwner (..)
  , destroyNative
  , editManaged
  , isAsynchronous
  , liveNative
  , modelAnswer
  , modelEdit
  , owned
  , readbackBuffer
  , ringSizeBytes
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (failingAgain, recoverAllocation)
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface
  ( CheckedShader (..)
  , CheckedShaders (..)
  , InterfaceStage (..)
  , PushMember (..)
  )
import qualified Hetoimasia.GPU.Vulkan.Native.Shader.Interface as Interface
import Hetoimasia.GPU.Vulkan.Native.Naming
  ( NativeObjectKind (..)
  , ShaderStage
  , bufferName
  , commandBufferName
  , commandPoolName
  , framelessBufferName
  , framelessPoolName
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
createPipelineLayout recording = createPipelineLayoutWith recording []

-- | A pipeline layout with no descriptor sets and these push-constant ranges
-- (GRS-4). Before any native call the ranges are validated against the
-- device's @maxPushConstantsSize@ and Vulkan's rules: each names at least one
-- stage, none twice, has a size, and has an offset and size that are
-- multiples of four; and no stage is named by two ranges. A range that
-- reaches past the device's limit is 'RefusedOutOfBounds', naming how far it
-- reaches and the limit; any other invalid range is 'RefusedIllegal'.
createPipelineLayoutWith ∷ Recording q inst msgr phys dev cmd → [PushConstantRange] → IO (Either Refusal PipelineLayout)
createPipelineLayoutWith recording ranges =
  owned recording $ do
    limits ← opsRecordingLimits (recordingOps recording)
    case validatePushRanges (limitPushConstantBytes limits) ranges of
      Left refusal → pure (Left refusal)
      Right () →
        fmap PipelineLayout
          <$> construct recording 0 1 "vkCreatePipelineLayout" (\ops device _ _ → Right . (`NativeLayout` ranges) <$> opsCreatePipelineLayout ops device ranges) Nothing

-- | Whether push-constant ranges are ones a layout may declare.
validatePushRanges ∷ Word32 → [PushConstantRange] → Either Refusal ()
validatePushRanges most ranges = do
  for_ ranges $ \range → do
    let stages = rangeStages range
        reach = toInteger (rangeOffset range) + toInteger (rangeSize range)
    when (null stages) (Left (RefusedIllegal "a push-constant range for no stage"))
    when (length (nub stages) /= length stages) (Left (RefusedIllegal "a push-constant range naming a stage twice"))
    when (rangeSize range == 0) (Left (RefusedIllegal "a push-constant range of no bytes"))
    when (rangeOffset range `mod` 4 /= 0 || rangeSize range `mod` 4 /= 0) $
      Left (RefusedIllegal "a push-constant range whose offset or size is not a multiple of four")
    when (reach > toInteger most) (Left (RefusedOutOfBounds (fromInteger reach) (fromIntegral most)))
  let named = concatMap rangeStages ranges
  when (length (nub named) /= length named) (Left (RefusedIllegal "two push-constant ranges for one stage"))

-- | Whether a vertex input is one a pipeline may declare.
validateVertexInput ∷ RecordingLimits → VertexInput → Either Refusal ()
validateVertexInput limits (VertexInput bindings attributes) = do
  when (length bindings > fromIntegral (limitVertexBindings limits)) $
    Left (RefusedOutOfBounds (fromIntegral (length bindings)) (fromIntegral (limitVertexBindings limits)))
  when (length attributes > fromIntegral (limitVertexAttributes limits)) $
    Left (RefusedOutOfBounds (fromIntegral (length attributes)) (fromIntegral (limitVertexAttributes limits)))
  let numbers = map bindingNumber bindings
      locations = map attributeLocation attributes
  when (length (nub numbers) /= length numbers) (Left (RefusedIllegal "a vertex binding declared twice"))
  when (length (nub locations) /= length locations) (Left (RefusedIllegal "a vertex attribute location declared twice"))
  for_ bindings $ \binding → do
    when (bindingNumber binding >= limitVertexBindings limits) $
      Left (RefusedOutOfBounds (fromIntegral (bindingNumber binding)) (fromIntegral (limitVertexBindings limits)))
    when (bindingStride binding == 0 || bindingStride binding `mod` 4 /= 0) $
      Left (RefusedIllegal "a vertex binding whose stride is not a positive multiple of four")
    when (bindingStride binding > limitVertexStride limits) $
      Left (RefusedOutOfBounds (fromIntegral (bindingStride binding)) (fromIntegral (limitVertexStride limits)))
  for_ attributes $ \attribute → do
    when (attributeLocation attribute >= limitVertexAttributes limits) $
      Left (RefusedOutOfBounds (fromIntegral (attributeLocation attribute)) (fromIntegral (limitVertexAttributes limits)))
    when (attributeOffset attribute > limitVertexAttributeOffset limits) $
      Left (RefusedOutOfBounds (fromIntegral (attributeOffset attribute)) (fromIntegral (limitVertexAttributeOffset limits)))
    when (attributeOffset attribute `mod` 4 /= 0) (Left (RefusedIllegal "a vertex attribute whose offset is not a multiple of four"))
    case [binding | binding ← bindings, bindingNumber binding == attributeBinding attribute] of
      [binding]
        | toInteger (attributeOffset attribute) + toInteger (vertexFormatBytes (attributeFormat attribute)) > toInteger (bindingStride binding) →
            Left (RefusedIllegal "a vertex attribute that does not fit its binding's stride")
        | otherwise → Right ()
      _ → Left (RefusedIllegal "a vertex attribute reading a binding the pipeline does not declare")

-- | A graphics pipeline over the layout, rendering to the color format, with
-- no vertex input. The layout must be live; the pipeline depends on that
-- exact generation, which every batch binding the pipeline retains with it.
createPipeline
  ∷ Recording q inst msgr phys dev cmd → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
createPipeline recording layout shaders format = createPipelineWith recording layout shaders format noVertexInput

-- | 'createPipeline' with a vertex input (GRS-4): bindings, each advancing
-- per vertex or per instance with a stride, and the attributes read from
-- them, for triangle lists. Before any native call it is validated against
-- the device's vertex input limits and Vulkan's rules: binding numbers and
-- attribute locations are each unique and within the device's counts, every
-- attribute reads a declared binding and fits within its stride, and strides
-- and offsets are multiples of four. A value past a device limit is
-- 'RefusedOutOfBounds', naming it and the limit; anything else invalid is
-- 'RefusedIllegal'. Every format offered is one Vulkan requires every device
-- to support for vertex input.
createPipelineWith
  ∷ Recording q inst msgr phys dev cmd → PipelineLayout → PipelineShaders → Word32 → VertexInput → IO (Either Refusal Pipeline)
createPipelineWith recording layout shaders format input = buildPipeline recording layout shaders format input Nothing

-- | Publish a new generation of a pipeline, over the given layout, with no
-- vertex input. The old generation is released: nothing records it again,
-- and every batch that recorded it keeps it, and its layout, until the
-- batch's references end.
replacePipeline
  ∷ Recording q inst msgr phys dev cmd → Pipeline → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
replacePipeline recording old layout shaders format = replacePipelineWith recording old layout shaders format noVertexInput

-- | 'replacePipeline' with a vertex input, validated as 'createPipelineWith'
-- validates one.
replacePipelineWith
  ∷ Recording q inst msgr phys dev cmd → Pipeline → PipelineLayout → PipelineShaders → Word32 → VertexInput → IO (Either Refusal Pipeline)
replacePipelineWith recording (Pipeline old) layout shaders format input = buildPipeline recording layout shaders format input (Just old)

buildPipeline
  ∷ Recording q inst msgr phys dev cmd
  → PipelineLayout
  → PipelineShaders
  → Word32
  → VertexInput
  → Maybe ResourceId
  → IO (Either Refusal Pipeline)
buildPipeline recording (PipelineLayout layout) shaders format input replacing =
  owned recording $
    liveNative recording layout >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeLayout handle ranges) → do
        limits ← opsRecordingLimits (recordingOps recording)
        case validateVertexInput limits input of
          Left refusal → pure (Left refusal)
          Right () →
            fmap Pipeline
              <$> construct
                recording
                0
                1
                "vkCreateGraphicsPipelines"
                ( \ops device _ issued → do
                    naming ← shaderNaming recording issued
                    (\created → Right (NativePipeline created layout format (PipelineInterface handle ranges input)))
                      <$> opsCreatePipeline ops device (PipelineRequest handle shaders format input) naming
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
  existing ← Map.lookup (StorageOfFrame target slot) <$> readTVarIO (recordingStorages recording)
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
              (\ops device _ _ → (\(pool, commands) → Right (NativeStorage (StorageOfFrame target slot) pool commands)) <$> opsCreateStorage ops device queueFamily)
              Nothing
          for_ made (\resource → atomically (modifyTVar' (recordingStorages recording) (Map.insert (StorageOfFrame target slot) resource)))
          pure (FrameStorage <$> made)

-- | A frame-less slot's command storage (GRS-12), made the first time a
-- frame-less batch is opened in the slot and reused, like a frame slot's, by
-- every later batch of that slot. It is named, released and destroyed like a
-- frame storage. A slot has at most one.
createFramelessStorage ∷ Recording q inst msgr phys dev cmd → Natural → IO (Either Refusal FrameStorage)
createFramelessStorage recording slot =
  owned recording $ do
    existing ← Map.lookup (StorageOfFrameless slot) <$> readTVarIO (recordingStorages recording)
    family ← fmap (planQueueFamily . fst) <$> atomically (readRootsDevice (recordingRoots recording))
    case (existing, family) of
      (Just _, _) → pure (Left (RefusedMisuse (DuplicateSubject BatchIdentity)))
      (_, Nothing) → pure (Left RefusedDeviceAbsent)
      (Nothing, Just queueFamily) → do
        made ←
          construct
            recording
            0
            2
            "vkCreateCommandPool"
            (\ops device _ _ → (\(pool, commands) → Right (NativeStorage (StorageOfFrameless slot) pool commands)) <$> opsCreateStorage ops device queueFamily)
            Nothing
        for_ made (\resource → atomically (modifyTVar' (recordingStorages recording) (Map.insert (StorageOfFrameless slot) resource)))
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

-- | The push-constant ranges a pipeline over these checked shaders needs, from
-- their descriptions (GRS-16): one for each stage that declares a block, or
-- one for both when both declare the same block, each spanning its members.
-- A stage that declares none needs none. Refused, before anything native: a
-- vertex shader that is not a vertex description's, or a fragment one that is
-- not a fragment description's, and two stages whose blocks disagree on any
-- member's offset or size, as 'RefusedIncompatible'; a shader declaring a
-- descriptor binding, which no pipeline layout declares yet, as
-- 'RefusedUnsupported'; and members reaching beyond what 32 bits can hold,
-- computed without bound, as 'RefusedOutOfBounds'.
checkedRanges ∷ CheckedShaders → Either Refusal [PushConstantRange]
checkedRanges (CheckedShaders vertex fragment)
  | Interface.interfaceStage vertexInterface /= VertexInterface = Left (RefusedIncompatible "a vertex stage whose shader is not a vertex shader's")
  | Interface.interfaceStage fragmentInterface /= FragmentInterface = Left (RefusedIncompatible "a fragment stage whose shader is not a fragment shader's")
  | not (null (Interface.interfaceDescriptors vertexInterface) && null (Interface.interfaceDescriptors fragmentInterface)) =
      Left (RefusedUnsupported "a shader declaring descriptor bindings, which no pipeline layout declares yet")
  | otherwise = case (Interface.interfacePushConstants vertexInterface, Interface.interfacePushConstants fragmentInterface) of
      ([], []) → Right []
      (members, []) → sequence [spanning [PushVertex] members]
      ([], members) → sequence [spanning [PushFragment] members]
      (vertexMembers, fragmentMembers)
        | vertexMembers == fragmentMembers → sequence [spanning [PushVertex, PushFragment] vertexMembers]
        | otherwise → Left (RefusedIncompatible "vertex and fragment stages whose push-constant blocks disagree")
  where
    vertexInterface = checkedInterface vertex
    fragmentInterface = checkedInterface fragment
    spanning stages members =
      let low = minimum (map pushMemberOffset members)
          high = maximum [toInteger (pushMemberOffset member) + toInteger (pushMemberSize member) | member ← members]
       in if high > toInteger (maxBound ∷ Word32)
            then Left (RefusedOutOfBounds (fromInteger high) (fromIntegral (maxBound ∷ Word32)))
            else Right (PushConstantRange stages low (fromInteger high - low))

-- | A pipeline layout with exactly the push-constant ranges these checked
-- shaders need ('checkedRanges'), validated as 'createPipelineLayoutWith'
-- validates any.
createPipelineLayoutFor ∷ Recording q inst msgr phys dev cmd → CheckedShaders → IO (Either Refusal PipelineLayout)
createPipelineLayoutFor recording shaders = case checkedRanges shaders of
  Left refusal → owned recording (pure (Left refusal))
  Right ranges → createPipelineLayoutWith recording ranges

-- | A graphics pipeline over the layout from checked shaders (GRS-16): its
-- vertex input is the vertex shader's description's, and the layout must
-- declare exactly the push-constant ranges the shaders' descriptions need
-- ('checkedRanges'), compared without regard to order. A layout that
-- declares any other ranges is 'RefusedIncompatible', and every refusal
-- 'checkedRanges' makes is made too, each before any native call; the vertex
-- input is then validated as 'createPipelineWith' validates any. The
-- descriptions stay authoritative: nothing else the caller supplies can give
-- the pipeline other ranges or another input.
createCheckedPipeline
  ∷ Recording q inst msgr phys dev cmd → PipelineLayout → CheckedShaders → Word32 → IO (Either Refusal Pipeline)
createCheckedPipeline recording layout shaders format = checkedPipeline recording layout shaders format Nothing

-- | 'replacePipeline' from checked shaders, checked as 'createCheckedPipeline'
-- checks them.
replaceCheckedPipeline
  ∷ Recording q inst msgr phys dev cmd → Pipeline → PipelineLayout → CheckedShaders → Word32 → IO (Either Refusal Pipeline)
replaceCheckedPipeline recording (Pipeline old) layout shaders format = checkedPipeline recording layout shaders format (Just old)

checkedPipeline
  ∷ Recording q inst msgr phys dev cmd
  → PipelineLayout
  → CheckedShaders
  → Word32
  → Maybe ResourceId
  → IO (Either Refusal Pipeline)
checkedPipeline recording held@(PipelineLayout layout) shaders format replacing =
  owned recording $ case checkedRanges shaders of
    Left refusal → pure (Left refusal)
    Right needed →
      liveNative recording layout >>= \case
        Left refusal → pure (Left refusal)
        Right (NativeLayout _ declared)
          | normalized declared /= normalized needed →
              pure (Left (RefusedIncompatible "a pipeline layout whose push-constant ranges are not the ones its checked shaders declare"))
          | otherwise →
              buildPipeline
                recording
                held
                (PipelineShaders (checkedSpirv (checkedVertex shaders)) (checkedSpirv (checkedFragment shaders)))
                format
                (Interface.interfaceVertexInput (checkedInterface (checkedVertex shaders)))
                replacing
        Right _ → pure (Left RefusedWrongKind)
  where
    normalized ranges = sort [(sort (rangeStages range), rangeOffset range, rangeSize range) | range ← ranges]

-- | Make the session's shared ring (GRS-4, D-33): one host-visible buffer of
-- the configured size, placed through the device's allocator under the
-- instance buffer's usage — vertex and index reads, the frame ring's memory
-- usage — and mapped for its lifetime. A session has at most one: a second
-- is 'RefusedMisuse' with 'DuplicateSubject'. A size larger than the
-- device's @maxBufferSize@ is 'RefusedOutOfBounds' before anything is made;
-- the ring is never made smaller than configured. Its memory is charged as
-- the allocator holds it (D-40), and a block the byte budget cannot hold is
-- 'RefusedBackpressure', having allocated nothing.
--
-- On coherent memory claims are padded to nothing; on non-coherent memory
-- every claim starts on, and is padded to, the device's
-- @nonCoherentAtomSize@, so flushing one claim's writes never reaches into
-- another's. The ring is a managed generation the recording owns: no handle
-- to it is returned, a batch that binds one of its regions retains it, and
-- it is released with every other live generation when the recording
-- retires.
createRing ∷ Recording q inst msgr phys dev cmd → RingSize → IO (Either Refusal ())
createRing recording size =
  owned recording $ do
    existing ← readTVarIO (recordingRing recording)
    most ← opsMaxBufferSize (recordingOps recording)
    case existing of
      Just _ → pure (Left (RefusedMisuse (DuplicateSubject ResourceIdentity)))
      Nothing
        | bytes > most → pure (Left (RefusedOutOfBounds bytes most))
        | otherwise → do
            limits ← opsRecordingLimits (recordingOps recording)
            made ←
              construct
                recording
                0
                2
                "vmaCreateBuffer"
                ( \_ _ attempt _ →
                    allocateBuffer (recordingRoots recording) attempt usage (BufferRequest bytes flags) >>= \case
                      Left refusal → pure (Left (allocationRefused refusal))
                      Right allocated
                        | Just _ ← allocatedMapped allocated → pure (Right (NativeBuffer InstanceBuffer bytes allocated))
                        -- The frame ring's usage requires host-visible memory,
                        -- which is always mapped.
                        | otherwise → do
                            freeBuffer (recordingRoots recording) allocated
                            fail "the ring's memory is not mapped"
                )
                Nothing
            case made of
              Left refusal → pure (Left refusal)
              Right resource → atomically $ do
                managed ← readTVar (recordingManaged recording)
                case managedNative <$> Map.lookup resource managed of
                  Just (NativeBuffer _ _ allocated)
                    | Just mapped ← allocatedMapped allocated → do
                        let mapping = ReadbackAllocation (memoryResource (allocatedMemory allocated)) (allocatedMemory allocated) bytes (allocatedCoherent allocated) mapped
                            atom = if allocatedCoherent allocated then 1 else max 1 (limitNonCoherentAtom limits)
                        writeTVar (recordingRing recording) (Just (RingState resource mapping bytes atom Map.empty 0 0))
                        pure (Right ())
                  _ → pure (Left (RefusedMisuse (StaleIdentity ResourceIdentity)))
  where
    bytes = ringSizeBytes size
    (flags, usage) = bufferKindUse InstanceBuffer

-- | Make a staging buffer for the session's uploads (GRS-6): one host-visible
-- buffer of the configured size, of the staging kind — a transfer source in
-- staging memory — placed through the device's allocator and mapped for its
-- lifetime by a map of its own after the allocating call (D-40), charged as
-- the allocator holds it. A size larger than the device's @maxBufferSize@ is
-- 'RefusedOutOfBounds' before anything is made; a block the byte budget
-- cannot hold is 'RefusedBackpressure', having allocated nothing.
--
-- It is a managed generation the recording owns, as the shared ring is: no
-- handle to it is returned, and it is released with every other live
-- generation when the recording retires. Answers it, its mapping, and the
-- granularity its regions must be padded to: one on coherent memory, and the
-- device's @nonCoherentAtomSize@ otherwise.
createStaging ∷ Recording q inst msgr phys dev cmd → Natural → IO (Either Refusal (ResourceId, ReadbackAllocation, Natural))
createStaging recording bytes =
  owned recording $ do
    most ← opsMaxBufferSize (recordingOps recording)
    if bytes > most
      then pure (Left (RefusedOutOfBounds bytes most))
      else do
        limits ← opsRecordingLimits (recordingOps recording)
        made ←
          construct
            recording
            0
            2
            "vmaCreateBuffer"
            ( \_ _ attempt _ →
                allocateBuffer (recordingRoots recording) attempt usage (BufferRequest bytes flags) >>= \case
                  Left refusal → pure (Left (allocationRefused refusal))
                  Right allocated
                    | Just _ ← allocatedMapped allocated → pure (Right (NativeBuffer StagingBuffer bytes allocated))
                    -- Staging memory is host-visible, and so always mapped.
                    | otherwise → do
                        freeBuffer (recordingRoots recording) allocated
                        fail "the staging buffer's memory is not mapped"
            )
            Nothing
        case made of
          Left refusal → pure (Left refusal)
          Right resource → atomically $ do
            managed ← readTVar (recordingManaged recording)
            pure $ case managedNative <$> Map.lookup resource managed of
              Just (NativeBuffer _ _ allocated)
                | Just mapped ← allocatedMapped allocated →
                    let mapping = ReadbackAllocation (memoryResource (allocatedMemory allocated)) (allocatedMemory allocated) bytes (allocatedCoherent allocated) mapped
                        atom = if allocatedCoherent allocated then 1 else max 1 (limitNonCoherentAtom limits)
                     in Right (resource, mapping, atom)
              _ → Left (RefusedMisuse (StaleIdentity ResourceIdentity))
  where
    (flags, usage) = bufferKindUse StagingBuffer

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
  NativeLayout handle _ → [(ObjectPipelineLayout, handle, pipelineLayoutName resource)]
  NativePipeline handle _ _ _ → [(ObjectPipeline, handle, pipelineName resource)]
  NativeStorage (StorageOfFrame target slot) pool commands →
    [ (ObjectCommandPool, pool, commandPoolName resource target slot)
    , (ObjectCommandBuffer, opsCommandBufferHandle (recordingOps recording) commands, commandBufferName resource target slot)
    ]
  NativeStorage (StorageOfFrameless slot) pool commands →
    [ (ObjectCommandPool, pool, framelessPoolName resource slot)
    , (ObjectCommandBuffer, opsCommandBufferHandle (recordingOps recording) commands, framelessBufferName resource slot)
    ]
  NativeReadback allocation _ → [(ObjectBuffer, allocationBuffer allocation, readbackBufferName resource)]
  NativeBuffer _ _ allocated → [(ObjectBuffer, memoryResource (allocatedMemory allocated), bufferName resource)]
  NativeImage _ memory view → [(ObjectImage, memoryResource memory, imageName resource), (ObjectImageView, view, ownedViewName resource)]

-- | Release a handle: nothing records through it again, and its CPU use —
-- reading a readback included — ends with it. Batches that already recorded
-- it keep it until their own references end.
--
-- The target of an upload still settling (GRS-6) is recordable no longer at
-- once, but released in the model only once its upload settles: an upload
-- not yet started is then cancelled, and one already copying finishes, so its
-- later copies are never stranded and it is never destroyed under them.
releaseManaged ∷ Managed handle ⇒ Recording q inst msgr phys dev cmd → handle → IO (Either Refusal ())
releaseManaged recording handle =
  owned recording $
    liveNative recording resource >>= \case
      Left refusal → pure (Left refusal)
      Right _ → atomically $ do
        uploading ← Set.member resource <$> readTVar (recordingUploading recording)
        if uploading
          then do
            modifyTVar' (recordingReleaseDeferred recording) (Set.insert resource)
            editManaged recording resource (\entry → entry {managedStanding = ManagedReleased})
            pure (Right ())
          else do
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
