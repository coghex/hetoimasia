{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The production native layer under "Hetoimasia.GPU.Vulkan.Native.Recording".
--
-- Construction, destruction, the storage's reset and the mapped-memory
-- maintenance are the binding's own calls, which `cabal.project.vulkan` builds
-- @safe@: pipeline creation in particular may compile for a long time. Every
-- command recorded into a batch — and beginning and ending its command buffer
-- — goes through the audited @unsafe@ subset in the private
-- "Hetoimasia.GPU.Vulkan.Native.Internal.Commands". Every decision about what
-- may be recorded, retained or destroyed is the recording's; this module only
-- turns each request into its native call, including which pipeline stages and
-- accesses each supported image transition synchronizes.
module Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan
  ( vulkanRecordingOps
  , transitionScopes
  ) where

import Control.Exception (onException)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as Unsafe
import Data.Bits ((.&.), (.|.))
import Data.List (find)
import qualified Data.Vector as Vector
import Data.Word (Word32, Word64)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, WordPtr (..), castPtr, plusPtr, ptrToWordPtr, wordPtrToPtr)
import Numeric.Natural (Natural)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10 hiding (ImageLayout, Viewport (..))
import qualified Vulkan.Core10 as Core10
import Vulkan.Core13
  ( DependencyInfo (..)
  , ImageMemoryBarrier2 (..)
  , BufferMemoryBarrier2 (..)
  , PipelineRenderingCreateInfo (..)
  , RenderingAttachmentInfo (..)
  , RenderingInfo (..)
  )
import Vulkan.Core13.Enums.AccessFlags2
import Vulkan.Core13.Enums.PipelineStageFlags2
import Vulkan.Core12 (ResolveModeFlagBits (RESOLVE_MODE_NONE))
import Vulkan.Zero (zero)

import Hetoimasia.GPU.Vulkan.Native.Internal.Commands
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ClearColor (..)
  , ImageLayout (..)
  , NativeCommand (..)
  , PipelineRequest (..)
  , PipelineShaders (..)
  , ReadbackAllocation (..)
  , Rect (..)
  , RecordingOps (..)
  , Viewport (..)
  )


-- | The recording's native layer for the session's physical device, whose
-- memory types and non-coherent atom size it reads once.
vulkanRecordingOps ∷ PhysicalDevice → IO (RecordingOps Device CommandBuffer)
vulkanRecordingOps physical = do
  memory ← getPhysicalDeviceMemoryProperties physical
  properties ← getPhysicalDeviceProperties physical
  let atom = fromIntegral properties.limits.nonCoherentAtomSize
  pure
    RecordingOps
      { opsCreatePipelineLayout = \device →
          (\(PipelineLayout created) → created)
            <$> createPipelineLayout device (PipelineLayoutCreateInfo {flags = zero, setLayouts = Vector.empty, pushConstantRanges = Vector.empty}) Nothing
      , opsDestroyPipelineLayout = \device handle → destroyPipelineLayout device (PipelineLayout handle) Nothing
      , opsCreatePipeline = createPipeline'
      , opsDestroyPipeline = \device handle → destroyPipeline device (Pipeline handle) Nothing
      , opsCreateStorage = \device family → do
          CommandPool pool ← createCommandPool device CommandPoolCreateInfo {next = (), flags = zero, queueFamilyIndex = family} Nothing
          buffers ←
            allocateCommandBuffers device CommandBufferAllocateInfo {commandPool = CommandPool pool, level = COMMAND_BUFFER_LEVEL_PRIMARY, commandBufferCount = 1}
          case Vector.toList buffers of
            [commands] → pure (pool, commands)
            _ → do
              destroyCommandPool device (CommandPool pool) Nothing
              fail "the pool allocated no command buffer"
      , opsResetStorage = \device pool → resetCommandPool device (CommandPool pool) zero
      , opsDestroyStorage = \device pool → destroyCommandPool device (CommandPool pool) Nothing
      , opsCreateReadback = createReadback' memory atom
      , opsDestroyReadback = \device allocation → do
          unmapMemory device (DeviceMemory allocation.allocationMemory)
          destroyBuffer device (Buffer allocation.allocationBuffer) Nothing
          freeMemory device (DeviceMemory allocation.allocationMemory) Nothing
      , opsInvalidate = \device allocation range → invalidateMappedMemoryRanges device (Vector.singleton (mappedRangeOf allocation range))
      , opsFlush = \device allocation range → flushMappedMemoryRanges device (Vector.singleton (mappedRangeOf allocation range))
      , opsReadMapped = \allocation offset size →
          ByteString.packCStringLen (castPtr (mapped allocation `plusPtr` fromIntegral offset), fromIntegral size)
      , opsWriteMapped = \allocation offset bytes →
          Unsafe.unsafeUseAsCStringLen bytes $ \(source, count) →
            copyBytes (castPtr (mapped allocation `plusPtr` fromIntegral offset)) source count
      , opsBeginCommands = \commands →
          beginCommandBufferUnsafe commands CommandBufferBeginInfo {next = (), flags = COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, inheritanceInfo = Nothing}
      , opsEndCommands = endCommandBufferUnsafe
      , opsRecord = recordCommand
      }

mapped ∷ ReadbackAllocation → Ptr ()
mapped allocation = wordPtrToPtr (WordPtr (fromIntegral allocation.allocationMapped))

mappedRangeOf ∷ ReadbackAllocation → (Natural, Natural) → MappedMemoryRange
mappedRangeOf allocation (offset, size) =
  MappedMemoryRange {memory = DeviceMemory allocation.allocationMemory, offset = fromIntegral offset, size = fromIntegral size}

-- | A pipeline for dynamic rendering into one color format: its two shader
-- modules are made, used and destroyed here.
createPipeline' ∷ Device → PipelineRequest → IO Word64
createPipeline' device request = do
  let shaders = request.requestShaders
      moduleOf code = createShaderModule device ShaderModuleCreateInfo {next = (), flags = zero, code = code} Nothing
  vertex ← moduleOf shaders.shaderVertex
  fragment ←
    moduleOf shaders.shaderFragment `onException` destroyShaderModule device vertex Nothing
  let stage kind shader =
        SomeStruct
          PipelineShaderStageCreateInfo {next = (), flags = zero, stage = kind, module' = shader, name = "main", specializationInfo = Nothing}
      info =
        GraphicsPipelineCreateInfo
          { next = (PipelineRenderingCreateInfo {viewMask = 0, colorAttachmentFormats = Vector.singleton (Format (fromIntegral request.requestColorFormat)), depthAttachmentFormat = FORMAT_UNDEFINED, stencilAttachmentFormat = FORMAT_UNDEFINED}, ())
          , flags = zero
          , stageCount = 2
          , stages = Vector.fromList [stage SHADER_STAGE_VERTEX_BIT vertex, stage SHADER_STAGE_FRAGMENT_BIT fragment]
          , vertexInputState = Just (SomeStruct PipelineVertexInputStateCreateInfo {next = (), flags = zero, vertexBindingDescriptions = Vector.empty, vertexAttributeDescriptions = Vector.empty})
          , inputAssemblyState = Just PipelineInputAssemblyStateCreateInfo {flags = zero, topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, primitiveRestartEnable = False}
          , tessellationState = Nothing
          , viewportState = Just (SomeStruct PipelineViewportStateCreateInfo {next = (), flags = zero, viewportCount = 1, viewports = Vector.empty, scissorCount = 1, scissors = Vector.empty})
          , rasterizationState =
              Just
                ( SomeStruct
                    PipelineRasterizationStateCreateInfo
                      { next = ()
                      , flags = zero
                      , depthClampEnable = False
                      , rasterizerDiscardEnable = False
                      , polygonMode = POLYGON_MODE_FILL
                      , cullMode = CULL_MODE_NONE
                      , frontFace = FRONT_FACE_CLOCKWISE
                      , depthBiasEnable = False
                      , depthBiasConstantFactor = 0
                      , depthBiasClamp = 0
                      , depthBiasSlopeFactor = 0
                      , lineWidth = 1
                      }
                )
          , multisampleState =
              Just
                ( SomeStruct
                    PipelineMultisampleStateCreateInfo
                      { next = ()
                      , flags = zero
                      , rasterizationSamples = SAMPLE_COUNT_1_BIT
                      , sampleShadingEnable = False
                      , minSampleShading = 0
                      , sampleMask = Vector.empty
                      , alphaToCoverageEnable = False
                      , alphaToOneEnable = False
                      }
                )
          , depthStencilState = Nothing
          , colorBlendState =
              Just
                ( SomeStruct
                    PipelineColorBlendStateCreateInfo
                      { next = ()
                      , flags = zero
                      , logicOpEnable = False
                      , logicOp = LOGIC_OP_COPY
                      , attachmentCount = 1
                      , attachments =
                          Vector.singleton
                            (zero {colorWriteMask = COLOR_COMPONENT_R_BIT .|. COLOR_COMPONENT_G_BIT .|. COLOR_COMPONENT_B_BIT .|. COLOR_COMPONENT_A_BIT} ∷ PipelineColorBlendAttachmentState)
                      , blendConstants = (0, 0, 0, 0)
                      }
                )
          , dynamicState = Just PipelineDynamicStateCreateInfo {flags = zero, dynamicStates = Vector.fromList [DYNAMIC_STATE_VIEWPORT, DYNAMIC_STATE_SCISSOR]}
          , layout = PipelineLayout request.requestLayout
          , renderPass = NULL_HANDLE
          , subpass = 0
          , basePipelineHandle = NULL_HANDLE
          , basePipelineIndex = -1
          }
          ∷ GraphicsPipelineCreateInfo '[PipelineRenderingCreateInfo]
  created ←
    createGraphicsPipelines device NULL_HANDLE (Vector.singleton (SomeStruct info)) Nothing
      `onException` (destroyShaderModule device fragment Nothing >> destroyShaderModule device vertex Nothing)
  destroyShaderModule device fragment Nothing
  destroyShaderModule device vertex Nothing
  case Vector.toList (snd created) of
    [Pipeline handle] → pure handle
    _ → fail "the device created no pipeline"

-- | A transfer-destination buffer in host-visible memory — cached where the
-- device offers it, which is where a read-back is fast and where memory is
-- most often not coherent — bound, and mapped whole for its lifetime.
createReadback' ∷ PhysicalDeviceMemoryProperties → Natural → Device → Natural → IO ReadbackAllocation
createReadback' memory atom device bytes = do
  Buffer buffer ←
    createBuffer
      device
      BufferCreateInfo {next = (), flags = zero, size = fromIntegral bytes, usage = BUFFER_USAGE_TRANSFER_DST_BIT, sharingMode = SHARING_MODE_EXCLUSIVE, queueFamilyIndices = Vector.empty}
      Nothing
  let destroyedBuffer = destroyBuffer device (Buffer buffer) Nothing
  requirements ← getBufferMemoryRequirements device (Buffer buffer)
  let types = zip [0 ∷ Word32 ..] (Vector.toList memory.memoryTypes)
      allowed index = requirements.memoryTypeBits .&. (2 ^ index) /= 0
      offers flags (index, kind) = allowed index && kind.propertyFlags .&. flags == flags && index < memory.memoryTypeCount
      chosen =
        find (offers (MEMORY_PROPERTY_HOST_VISIBLE_BIT .|. MEMORY_PROPERTY_HOST_CACHED_BIT)) types
          `orElse` find (offers MEMORY_PROPERTY_HOST_VISIBLE_BIT) types
  (index, kind) ← maybe (destroyedBuffer >> fail "no host-visible memory type can back the readback buffer") pure chosen
  DeviceMemory allocated ←
    allocateMemory device MemoryAllocateInfo {next = (), allocationSize = requirements.size, memoryTypeIndex = index} Nothing
      `onException` destroyedBuffer
  let released = freeMemory device (DeviceMemory allocated) Nothing >> destroyedBuffer
  bindBufferMemory device (Buffer buffer) (DeviceMemory allocated) 0 `onException` released
  pointer ← mapMemory device (DeviceMemory allocated) 0 WHOLE_SIZE zero `onException` released
  pure
    ReadbackAllocation
      { allocationBuffer = buffer
      , allocationMemory = allocated
      , allocationSize = bytes
      , allocationMemorySize = fromIntegral requirements.size
      , allocationCoherent = kind.propertyFlags .&. MEMORY_PROPERTY_HOST_COHERENT_BIT /= zero
      , allocationAtom = atom
      , allocationMapped = fromIntegral (ptrToWordPtr pointer)
      }
  where
    orElse (Just found) _ = Just found
    orElse Nothing other = other

-- | The stages and accesses each supported image transition synchronizes: the
-- source scope, then the destination scope. Entering rendering waits on the
-- color-attachment stage, which is where an acquisition's semaphore wait is
-- made; leaving it makes the attachment writes available to the copy or to
-- presentation.
transitionScopes ∷ ImageLayout → ImageLayout → Maybe ((PipelineStageFlags2, AccessFlags2), (PipelineStageFlags2, AccessFlags2))
transitionScopes from to = case (from, to) of
  (LayoutUndefined, LayoutColorAttachment) →
    Just ((PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, ACCESS_2_NONE), (PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT))
  (LayoutColorAttachment, LayoutTransferSource) →
    Just ((PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT), (PIPELINE_STAGE_2_COPY_BIT, ACCESS_2_TRANSFER_READ_BIT))
  (LayoutColorAttachment, LayoutPresentSource) →
    Just ((PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT), (PIPELINE_STAGE_2_NONE, ACCESS_2_NONE))
  (LayoutTransferSource, LayoutPresentSource) →
    Just ((PIPELINE_STAGE_2_COPY_BIT, ACCESS_2_NONE), (PIPELINE_STAGE_2_NONE, ACCESS_2_NONE))
  _ → Nothing

nativeLayout ∷ ImageLayout → Core10.ImageLayout
nativeLayout = \case
  LayoutUndefined → IMAGE_LAYOUT_UNDEFINED
  LayoutColorAttachment → IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
  LayoutTransferSource → IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
  LayoutPresentSource → IMAGE_LAYOUT_PRESENT_SRC_KHR

colorRange ∷ ImageSubresourceRange
colorRange = ImageSubresourceRange {aspectMask = IMAGE_ASPECT_COLOR_BIT, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1}

-- | One command, through the unsafe subset.
recordCommand ∷ CommandBuffer → NativeCommand → IO ()
recordCommand commands = \case
  CommandImageBarrier image from to → case transitionScopes from to of
    Nothing → fail ("no synchronization is defined for " <> show from <> " to " <> show to)
    Just ((sourceStage, sourceAccess), (destinationStage, destinationAccess)) →
      pipelineBarrier2Unsafe
        commands
        DependencyInfo
          { next = ()
          , dependencyFlags = zero
          , memoryBarriers = Vector.empty
          , bufferMemoryBarriers = Vector.empty
          , imageMemoryBarriers =
              Vector.singleton
                ( SomeStruct
                    ImageMemoryBarrier2
                      { next = ()
                      , srcStageMask = sourceStage
                      , srcAccessMask = sourceAccess
                      , dstStageMask = destinationStage
                      , dstAccessMask = destinationAccess
                      , oldLayout = nativeLayout from
                      , newLayout = nativeLayout to
                      , srcQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , dstQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , image = Image image
                      , subresourceRange = colorRange
                      }
                )
          }
  CommandBeginRendering view extent (ClearColor red green blue alpha) →
    beginRenderingUnsafe
      commands
      RenderingInfo
        { next = ()
        , flags = zero
        , renderArea = Rect2D {offset = Offset2D 0 0, extent = Extent2D extent.extentWidth extent.extentHeight}
        , layerCount = 1
        , viewMask = 0
        , colorAttachments =
            Vector.singleton
              ( SomeStruct
                  RenderingAttachmentInfo
                    { next = ()
                    , imageView = ImageView view
                    , imageLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                    , resolveMode = RESOLVE_MODE_NONE
                    , resolveImageView = NULL_HANDLE
                    , resolveImageLayout = IMAGE_LAYOUT_UNDEFINED
                    , loadOp = ATTACHMENT_LOAD_OP_CLEAR
                    , storeOp = ATTACHMENT_STORE_OP_STORE
                    , clearValue = Color (Float32 red green blue alpha)
                    }
              )
        , depthAttachment = Nothing
        , stencilAttachment = Nothing
        }
  CommandEndRendering → endRenderingUnsafe commands
  CommandBindPipeline pipeline → bindPipelineUnsafe commands PIPELINE_BIND_POINT_GRAPHICS (Pipeline pipeline)
  CommandSetViewport viewport →
    setViewportUnsafe
      commands
      Core10.Viewport
        { x = viewport.viewportX
        , y = viewport.viewportY
        , width = viewport.viewportWidth
        , height = viewport.viewportHeight
        , minDepth = 0
        , maxDepth = 1
        }
  CommandSetScissor rect →
    setScissorUnsafe commands Rect2D {offset = Offset2D rect.rectX rect.rectY, extent = Extent2D rect.rectWidth rect.rectHeight}
  CommandDraw vertices instances firstVertex firstInstance → drawUnsafe commands vertices instances firstVertex firstInstance
  CommandCopyImageToBuffer image extent buffer →
    copyImageToBufferUnsafe
      commands
      (Image image)
      IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
      (Buffer buffer)
      BufferImageCopy
        { bufferOffset = 0
        , bufferRowLength = 0
        , bufferImageHeight = 0
        , imageSubresource = ImageSubresourceLayers {aspectMask = IMAGE_ASPECT_COLOR_BIT, mipLevel = 0, baseArrayLayer = 0, layerCount = 1}
        , imageOffset = Offset3D 0 0 0
        , imageExtent = Extent3D extent.extentWidth extent.extentHeight 1
        }
  CommandHostReadBarrier buffer size →
    pipelineBarrier2Unsafe
      commands
      DependencyInfo
        { next = ()
        , dependencyFlags = zero
        , memoryBarriers = Vector.empty
        , bufferMemoryBarriers =
            Vector.singleton
              ( SomeStruct
                  BufferMemoryBarrier2
                    { next = ()
                    , srcStageMask = PIPELINE_STAGE_2_COPY_BIT
                    , srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT
                    , dstStageMask = PIPELINE_STAGE_2_HOST_BIT
                    , dstAccessMask = ACCESS_2_HOST_READ_BIT
                    , srcQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                    , dstQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                    , buffer = Buffer buffer
                    , offset = 0
                    , size = fromIntegral size
                    }
              )
        , imageMemoryBarriers = Vector.empty
        }
