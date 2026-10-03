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
-- accesses each supported image transition synchronizes. A managed resource's
-- barrier arrives with its stages, accesses and layouts already decided
-- ('Hetoimasia.GPU.Vulkan.Native.Recording.useScope').
module Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan
  ( vulkanRecordingOps
  , transitionScopes
  ) where

import Control.Exception (catch, onException, throwIO)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as Unsafe
import Data.Bits ((.&.), (.|.))
import qualified Data.Vector as Vector
import Data.Word (Word32, Word64)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, WordPtr (..), castPtr, plusPtr, ptrToWordPtr, wordPtrToPtr)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10 hiding (ImageLayout, IndexType (..), PushConstantRange (..), Viewport (..))
import qualified Vulkan.Core10 as Core10
import Vulkan.Core11 (PhysicalDeviceProperties2 (..), getPhysicalDeviceProperties2)
import Vulkan.Core12
  ( DescriptorSetLayoutBindingFlagsCreateInfo (..)
  , DescriptorSetVariableDescriptorCountAllocateInfo (..)
  , PhysicalDeviceVulkan12Properties (..)
  )
import Vulkan.Core12.Enums.DescriptorBindingFlagBits
import Vulkan.Core13
  ( DependencyInfo (..)
  , PhysicalDeviceVulkan13Properties (..)
  , ImageMemoryBarrier2 (..)
  , BufferMemoryBarrier2 (..)
  , PipelineRenderingCreateInfo (..)
  , RenderingAttachmentInfo (..)
  , RenderingInfo (..)
  )
import Vulkan.Core13.Enums.AccessFlags2
import Vulkan.Core13.Enums.PipelineStageFlags2
import Vulkan.Core12 (ResolveModeFlagBits (RESOLVE_MODE_NONE))
import Vulkan.Exception (VulkanException (..))
import Vulkan.Extensions.VK_EXT_debug_utils (DebugUtilsLabelEXT (..))
import Vulkan.Zero (zero)

import Hetoimasia.GPU.Vulkan.Native.Internal.Commands
import Hetoimasia.GPU.Vulkan.Native.Naming (ShaderStage (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( AccessScope (..)
  , BarrierObject (..)
  , ClearColor (..)
  , DescriptorWrite (..)
  , PoolRequest (..)
  , SetLayoutRequest (..)
  , TableSampler (..)
  , lookupBinding
  , tableSamplerBinding
  , tableTextureBinding
  , ImageLayout (..)
  , ImageLimits (..)
  , ImageQuery (..)
  , IndexType (..)
  , InputRate (..)
  , NativeCommand (..)
  , PipelineRequest (..)
  , PipelineShaders (..)
  , PushConstantRange (..)
  , PushStage
  , ReadbackAllocation (..)
  , Rect (..)
  , RecordingLimits (..)
  , RecordingOps (..)
  , VertexAttribute (..)
  , VertexBinding (..)
  , VertexInput (..)
  , ViewRequest (..)
  , Viewport (..)
  , pushStageBit
  , vertexFormatCode
  )


-- | The recording's native layer for the session's physical device. A
-- readback buffer's memory, its mapping and its maintenance are the device
-- allocator's ("Hetoimasia.GPU.Vulkan.Native.Allocator.Vulkan"); this layer
-- only copies bytes through the mapping it is handed. Of the physical device
-- it reads the largest buffer it may create and the largest render area it may
-- render into, once, what it allows pipeline interfaces and mapped memory, and
-- whether it supports an image before one is created.
vulkanRecordingOps ∷ PhysicalDevice → IO (RecordingOps Device CommandBuffer)
vulkanRecordingOps physical = do
  properties ∷ PhysicalDeviceProperties2 '[PhysicalDeviceVulkan12Properties, PhysicalDeviceVulkan13Properties] ← getPhysicalDeviceProperties2 physical
  let (twelve, (thirteen, ())) = properties.next
      largest = fromIntegral thirteen.maxBufferSize
      deviceLimits = properties.properties.limits
      framebuffer = (deviceLimits.maxFramebufferWidth, deviceLimits.maxFramebufferHeight)
      recording =
        RecordingLimits
          { limitPushConstantBytes = deviceLimits.maxPushConstantsSize
          , limitVertexBindings = deviceLimits.maxVertexInputBindings
          , limitVertexAttributes = deviceLimits.maxVertexInputAttributes
          , limitVertexStride = deviceLimits.maxVertexInputBindingStride
          , limitVertexAttributeOffset = deviceLimits.maxVertexInputAttributeOffset
          , limitNonCoherentAtom = fromIntegral deviceLimits.nonCoherentAtomSize
          , limitImageDimension = deviceLimits.maxImageDimension2D
          , limitTableSampledImages = min twelve.maxPerStageDescriptorUpdateAfterBindSampledImages twelve.maxDescriptorSetUpdateAfterBindSampledImages
          , limitTableSamplers = min twelve.maxPerStageDescriptorUpdateAfterBindSamplers twelve.maxDescriptorSetUpdateAfterBindSamplers
          , limitTableResources = twelve.maxPerStageUpdateAfterBindResources
          , limitBoundSets = deviceLimits.maxBoundDescriptorSets
          , limitStorageAlignment = fromIntegral deviceLimits.minStorageBufferOffsetAlignment
          , limitStorageRange = fromIntegral deviceLimits.maxStorageBufferRange
          , limitTablePoolDescriptors = twelve.maxUpdateAfterBindDescriptorsInAllPools
          }
  pure
    RecordingOps
      { opsCreatePipelineLayout = \device layouts ranges →
          (\(PipelineLayout created) → created)
            <$> createPipelineLayout
              device
              ( PipelineLayoutCreateInfo
                  { flags = zero
                  , setLayouts = Vector.fromList (map DescriptorSetLayout layouts)
                  , pushConstantRanges = Vector.fromList [Core10.PushConstantRange (pushStageFlags (rangeStages range)) (rangeOffset range) (rangeSize range) | range ← ranges]
                  }
              )
              Nothing
      , opsDestroyPipelineLayout = \device handle → destroyPipelineLayout device (PipelineLayout handle) Nothing
      , opsCreatePipeline = createPipeline'
      , opsDestroyPipeline = \device handle → destroyPipeline device (Pipeline handle) Nothing
      , opsCreateStorage = \device family → do
          CommandPool pool ← createCommandPool device CommandPoolCreateInfo {next = (), flags = zero, queueFamilyIndex = family} Nothing
          -- The pool exists from here on, and the caller learns its handle only
          -- if this returns: a failure below destroys it before raising.
          buffers ←
            allocateCommandBuffers device CommandBufferAllocateInfo {commandPool = CommandPool pool, level = COMMAND_BUFFER_LEVEL_PRIMARY, commandBufferCount = 1}
              `onException` destroyCommandPool device (CommandPool pool) Nothing
          case Vector.toList buffers of
            [commands] → pure (pool, commands)
            _ → do
              destroyCommandPool device (CommandPool pool) Nothing
              fail "the pool allocated no command buffer"
      , opsResetStorage = \device pool → resetCommandPool device (CommandPool pool) zero
      , opsDestroyStorage = \device pool → destroyCommandPool device (CommandPool pool) Nothing
      , opsReadMapped = \allocation offset size →
          ByteString.packCStringLen (castPtr (mapped allocation `plusPtr` fromIntegral offset), fromIntegral size)
      , opsWriteMapped = \allocation offset bytes →
          Unsafe.unsafeUseAsCStringLen bytes $ \(source, count) →
            copyBytes (castPtr (mapped allocation `plusPtr` fromIntegral offset)) source count
      , opsBeginCommands = \commands →
          beginCommandBufferUnsafe commands CommandBufferBeginInfo {next = (), flags = COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, inheritanceInfo = Nothing}
      , opsEndCommands = endCommandBufferUnsafe
      , opsRecord = recordCommand
      , opsCommandBufferHandle = fromIntegral . ptrToWordPtr . commandBufferHandle
      , opsImageSupport = imageSupport physical
      , opsMaxBufferSize = pure largest
      , opsMaxFramebuffer = pure framebuffer
      , opsRecordingLimits = pure recording
      , opsCreateView = \device request →
          (\(ImageView created) → created)
            <$> createImageView
              device
              ( ImageViewCreateInfo
                  { next = ()
                  , flags = zero
                  , image = Image request.requestViewImage
                  , viewType = IMAGE_VIEW_TYPE_2D
                  , format = Format (fromIntegral request.requestViewFormat)
                  , components = ComponentMapping COMPONENT_SWIZZLE_IDENTITY COMPONENT_SWIZZLE_IDENTITY COMPONENT_SWIZZLE_IDENTITY COMPONENT_SWIZZLE_IDENTITY
                  , subresourceRange = ImageSubresourceRange (ImageAspectFlagBits request.requestViewAspect) 0 request.requestViewMipLevels 0 1
                  }
                  ∷ ImageViewCreateInfo '[]
              )
              Nothing
      , opsDestroyView = \device view → destroyImageView device (ImageView view) Nothing
      , opsCreateSampler = \device sampler → (\(Sampler created) → created) <$> createSampler device (samplerInfo sampler) Nothing
      , opsDestroySampler = \device sampler → destroySampler device (Sampler sampler) Nothing
      , opsCreateSetLayout = createSetLayout
      , opsDestroySetLayout = \device layout → destroyDescriptorSetLayout device (DescriptorSetLayout layout) Nothing
      , opsCreateDescriptorPool = \device request →
          (\(DescriptorPool created) → created) <$> createDescriptorPool device (poolInfo request) Nothing
      , opsDestroyDescriptorPool = \device pool → destroyDescriptorPool device (DescriptorPool pool) Nothing
      , opsAllocateSet = allocateSet
      , opsWriteDescriptors = \device writes → updateDescriptorSets device (Vector.fromList (map descriptorWrite writes)) Vector.empty
      }

-- | One of the texture table's samplers (GRS-7): nearest or linear, clamping
-- to the edge or repeating, linear also between mip levels, never
-- anisotropic, over every level an image has.
samplerInfo ∷ TableSampler → SamplerCreateInfo '[]
samplerInfo sampler =
  (zero ∷ SamplerCreateInfo '[])
    { magFilter = texel
    , minFilter = texel
    , mipmapMode = if linear then SAMPLER_MIPMAP_MODE_LINEAR else SAMPLER_MIPMAP_MODE_NEAREST
    , addressModeU = addressing
    , addressModeV = addressing
    , addressModeW = addressing
    , anisotropyEnable = False
    , maxAnisotropy = 1
    , compareEnable = False
    , minLod = 0
    , maxLod = LOD_CLAMP_NONE
    , borderColor = BORDER_COLOR_FLOAT_TRANSPARENT_BLACK
    , unnormalizedCoordinates = False
    }
  where
    linear = sampler `elem` [LinearClamp, LinearRepeat]
    texel = if linear then FILTER_LINEAR else FILTER_NEAREST
    addressing = if sampler `elem` [NearestRepeat, LinearRepeat] then SAMPLER_ADDRESS_MODE_REPEAT else SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE

-- | One of the table's set layouts: set 0's immutable samplers, then its
-- partially bound, update-after-bind, variable-count array, which may be
-- updated while unused by pending work, in a layout for an update-after-bind
-- pool; or set 1's one dynamic storage buffer.
createSetLayout ∷ Device → SetLayoutRequest → IO Word64
createSetLayout device = \case
  TextureSetLayout samplers capacity →
    (\(DescriptorSetLayout created) → created)
      <$> createDescriptorSetLayout
        device
        ( DescriptorSetLayoutCreateInfo
            { next =
                ( DescriptorSetLayoutBindingFlagsCreateInfo
                    { bindingFlags =
                        Vector.fromList
                          [ zero
                          , DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT
                              .|. DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT
                              .|. DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT
                              .|. DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT
                          ]
                    }
                , ()
                )
            , flags = DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT
            , bindings =
                Vector.fromList
                  [ DescriptorSetLayoutBinding
                      { binding = tableSamplerBinding
                      , descriptorType = DESCRIPTOR_TYPE_SAMPLER
                      , descriptorCount = fromIntegral (length samplers)
                      , stageFlags = SHADER_STAGE_FRAGMENT_BIT
                      , immutableSamplers = Vector.fromList (map Sampler samplers)
                      }
                  , DescriptorSetLayoutBinding
                      { binding = tableTextureBinding
                      , descriptorType = DESCRIPTOR_TYPE_SAMPLED_IMAGE
                      , descriptorCount = capacity
                      , stageFlags = SHADER_STAGE_FRAGMENT_BIT
                      , immutableSamplers = Vector.empty
                      }
                  ]
            }
            ∷ DescriptorSetLayoutCreateInfo '[DescriptorSetLayoutBindingFlagsCreateInfo]
        )
        Nothing
  LookupSetLayout →
    (\(DescriptorSetLayout created) → created)
      <$> createDescriptorSetLayout
        device
        ( DescriptorSetLayoutCreateInfo
            { next = ()
            , flags = zero
            , bindings =
                Vector.singleton
                  DescriptorSetLayoutBinding
                    { binding = lookupBinding
                    , descriptorType = DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC
                    , descriptorCount = 1
                    , stageFlags = SHADER_STAGE_VERTEX_BIT .|. SHADER_STAGE_FRAGMENT_BIT
                    , immutableSamplers = Vector.empty
                    }
            }
            ∷ DescriptorSetLayoutCreateInfo '[]
        )
        Nothing

-- | A pool for exactly one of the table's sets.
poolInfo ∷ PoolRequest → DescriptorPoolCreateInfo '[]
poolInfo = \case
  TexturePool samplers images →
    DescriptorPoolCreateInfo
      { next = ()
      , flags = DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT
      , maxSets = 1
      , poolSizes = Vector.fromList [DescriptorPoolSize DESCRIPTOR_TYPE_SAMPLER samplers, DescriptorPoolSize DESCRIPTOR_TYPE_SAMPLED_IMAGE images]
      }
  LookupPool →
    DescriptorPoolCreateInfo
      { next = ()
      , flags = zero
      , maxSets = 1
      , poolSizes = Vector.singleton (DescriptorPoolSize DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC 1)
      }

-- | One set from the pool, of the layout, with its variable-count binding's
-- count when it has one.
allocateSet ∷ Device → Word64 → Word64 → Maybe Word32 → IO Word64
allocateSet device pool layout variable = do
  sets ← case variable of
    Just count →
      allocateDescriptorSets
        device
        ( DescriptorSetAllocateInfo
            { next = (DescriptorSetVariableDescriptorCountAllocateInfo {descriptorCounts = Vector.singleton count}, ())
            , descriptorPool = DescriptorPool pool
            , setLayouts = Vector.singleton (DescriptorSetLayout layout)
            }
            ∷ DescriptorSetAllocateInfo '[DescriptorSetVariableDescriptorCountAllocateInfo]
        )
    Nothing →
      allocateDescriptorSets
        device
        (DescriptorSetAllocateInfo {next = (), descriptorPool = DescriptorPool pool, setLayouts = Vector.singleton (DescriptorSetLayout layout)} ∷ DescriptorSetAllocateInfo '[])
  case Vector.toList sets of
    [DescriptorSet created] → pure created
    _ → fail "the pool allocated no descriptor set"

-- | One descriptor update: a texture's view into set 0's array, sampled in
-- the shader-read layout textures rest in; or the version ring into set 1.
descriptorWrite ∷ DescriptorWrite → SomeStruct WriteDescriptorSet
descriptorWrite = \case
  WriteSampledImage set element view →
    SomeStruct
      ( WriteDescriptorSet
          { next = ()
          , dstSet = DescriptorSet set
          , dstBinding = tableTextureBinding
          , dstArrayElement = element
          , descriptorCount = 1
          , descriptorType = DESCRIPTOR_TYPE_SAMPLED_IMAGE
          , imageInfo = Vector.singleton (DescriptorImageInfo NULL_HANDLE (ImageView view) IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
          , bufferInfo = Vector.empty
          , texelBufferView = Vector.empty
          }
          ∷ WriteDescriptorSet '[]
      )
  WriteLookupBuffer set buffer range →
    SomeStruct
      ( WriteDescriptorSet
          { next = ()
          , dstSet = DescriptorSet set
          , dstBinding = lookupBinding
          , dstArrayElement = 0
          , descriptorCount = 1
          , descriptorType = DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC
          , imageInfo = Vector.empty
          , bufferInfo = Vector.singleton (DescriptorBufferInfo (Buffer buffer) 0 (fromIntegral range))
          , texelBufferView = Vector.empty
          }
          ∷ WriteDescriptorSet '[]
      )

-- | Whether the physical device supports an optimally tiled two-dimensional
-- image of the query: its format offers every format feature asked for, and
-- the device answers its format properties for the usage — the extent, mip
-- levels and resource size it allows. A combination the device answers
-- @VK_ERROR_FORMAT_NOT_SUPPORTED@ for is unsupported; any other failure is
-- raised.
imageSupport ∷ PhysicalDevice → ImageQuery → IO (Maybe ImageLimits)
imageSupport physical query = do
  let format = Format (fromIntegral query.queryFormat)
      needed = FormatFeatureFlagBits query.queryFeatures
  offered ← (.optimalTilingFeatures) <$> getPhysicalDeviceFormatProperties physical format
  if offered .&. needed /= needed
    then pure Nothing
    else
      ( Just . limits
          <$> getPhysicalDeviceImageFormatProperties physical format IMAGE_TYPE_2D IMAGE_TILING_OPTIMAL (ImageUsageFlagBits query.queryUsage) zero
      )
        `catch` \case
          VulkanException ERROR_FORMAT_NOT_SUPPORTED → pure Nothing
          failure → throwIO failure
  where
    limits properties =
      ImageLimits
        { limitWidth = properties.maxExtent.width
        , limitHeight = properties.maxExtent.height
        , limitMipLevels = properties.maxMipLevels
        , limitResourceSize = fromIntegral properties.maxResourceSize
        }

mapped ∷ ReadbackAllocation → Ptr ()
mapped allocation = wordPtrToPtr (WordPtr (fromIntegral allocation.allocationMapped))

-- | A pipeline for dynamic rendering into one color format: its two shader
-- modules are made, named, used and destroyed here.
createPipeline' ∷ Device → PipelineRequest → (ShaderStage → Word64 → IO ()) → IO Word64
createPipeline' device request name = do
  let shaders = request.requestShaders
      moduleOf code = createShaderModule device ShaderModuleCreateInfo {next = (), flags = zero, code = code} Nothing
      handleOf (ShaderModule handle) = handle
      destroyModule shader = destroyShaderModule device shader Nothing
  vertex ← moduleOf shaders.shaderVertex
  name VertexStage (handleOf vertex) `onException` destroyModule vertex
  fragment ←
    moduleOf shaders.shaderFragment `onException` destroyModule vertex
  name FragmentStage (handleOf fragment) `onException` (destroyModule fragment >> destroyModule vertex)
  let stage kind shader =
        SomeStruct
          PipelineShaderStageCreateInfo {next = (), flags = zero, stage = kind, module' = shader, name = "main", specializationInfo = Nothing}
      info =
        GraphicsPipelineCreateInfo
          { next = (PipelineRenderingCreateInfo {viewMask = 0, colorAttachmentFormats = Vector.singleton (Format (fromIntegral request.requestColorFormat)), depthAttachmentFormat = FORMAT_UNDEFINED, stencilAttachmentFormat = FORMAT_UNDEFINED}, ())
          , flags = zero
          , stageCount = 2
          , stages = Vector.fromList [stage SHADER_STAGE_VERTEX_BIT vertex, stage SHADER_STAGE_FRAGMENT_BIT fragment]
          , vertexInputState =
              Just
                ( SomeStruct
                    PipelineVertexInputStateCreateInfo
                      { next = ()
                      , flags = zero
                      , vertexBindingDescriptions =
                          Vector.fromList
                            [ VertexInputBindingDescription binding.bindingNumber binding.bindingStride (vertexRate binding.bindingRate)
                            | binding ← request.requestVertexInput.inputBindings
                            ]
                      , vertexAttributeDescriptions =
                          Vector.fromList
                            [ VertexInputAttributeDescription attribute.attributeLocation attribute.attributeBinding (Format (fromIntegral (vertexFormatCode attribute.attributeFormat))) attribute.attributeOffset
                            | attribute ← request.requestVertexInput.inputAttributes
                            ]
                      }
                )
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

-- | The stage flags of a push-constant range or a push.
pushStageFlags ∷ [PushStage] → ShaderStageFlags
pushStageFlags = ShaderStageFlagBits . foldr ((.|.) . pushStageBit) 0

vertexRate ∷ InputRate → VertexInputRate
vertexRate = \case
  PerVertex → VERTEX_INPUT_RATE_VERTEX
  PerInstance → VERTEX_INPUT_RATE_INSTANCE

-- | The stages and accesses each supported image transition synchronizes: the
-- source scope, then the destination scope. Entering rendering waits on the
-- color-attachment stage, which is where an acquisition's semaphore wait is
-- made; leaving it makes the attachment writes available to the copy or to
-- presentation.
--
-- A transition to presentation names every stage as its destination, with no
-- access: the presentation engine's read needs no visibility operation, but
-- the layout transition itself must happen before the render-finished
-- semaphore's signal, which the frames make at every stage. A destination of
-- no stage would chain the transition into nothing that follows it, and
-- synchronization validation reports the presentation's read as a hazard
-- (@SYNC-HAZARD-PRESENT-AFTER-WRITE@).
transitionScopes ∷ ImageLayout → ImageLayout → Maybe ((PipelineStageFlags2, AccessFlags2), (PipelineStageFlags2, AccessFlags2))
transitionScopes from to = case (from, to) of
  (LayoutUndefined, LayoutColorAttachment) →
    Just ((PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, ACCESS_2_NONE), (PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT))
  (LayoutColorAttachment, LayoutTransferSource) →
    Just ((PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT), (PIPELINE_STAGE_2_COPY_BIT, ACCESS_2_TRANSFER_READ_BIT))
  (LayoutColorAttachment, LayoutPresentSource) →
    Just ((PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT), (PIPELINE_STAGE_2_ALL_COMMANDS_BIT, ACCESS_2_NONE))
  (LayoutTransferSource, LayoutPresentSource) →
    Just ((PIPELINE_STAGE_2_COPY_BIT, ACCESS_2_NONE), (PIPELINE_STAGE_2_ALL_COMMANDS_BIT, ACCESS_2_NONE))
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
  CommandCopyBuffer source sourceOffset destination destinationOffset size →
    copyBufferUnsafe commands (Buffer source) (Buffer destination) BufferCopy {srcOffset = sourceOffset, dstOffset = destinationOffset, size = size}
  CommandCopyBufferToImage source offset image level row width height →
    copyBufferToImageUnsafe
      commands
      (Buffer source)
      (Image image)
      IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      BufferImageCopy
        { bufferOffset = offset
        , bufferRowLength = 0
        , bufferImageHeight = 0
        , imageSubresource = ImageSubresourceLayers {aspectMask = IMAGE_ASPECT_COLOR_BIT, mipLevel = level, baseArrayLayer = 0, layerCount = 1}
        , imageOffset = Offset3D 0 (fromIntegral row) 0
        , imageExtent = Extent3D width height 1
        }
  CommandCopyImageLevelToBuffer image level width height buffer →
    copyImageToBufferUnsafe
      commands
      (Image image)
      IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
      (Buffer buffer)
      BufferImageCopy
        { bufferOffset = 0
        , bufferRowLength = 0
        , bufferImageHeight = 0
        , imageSubresource = ImageSubresourceLayers {aspectMask = IMAGE_ASPECT_COLOR_BIT, mipLevel = level, baseArrayLayer = 0, layerCount = 1}
        , imageOffset = Offset3D 0 0 0
        , imageExtent = Extent3D width height 1
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
  CommandResourceBarrier object (AccessScope sourceStage sourceAccess) (AccessScope destinationStage destinationAccess) →
    pipelineBarrier2Unsafe
      commands
      DependencyInfo
        { next = ()
        , dependencyFlags = zero
        , memoryBarriers = Vector.empty
        , bufferMemoryBarriers = case object of
            BarrierBuffer buffer →
              Vector.singleton
                ( SomeStruct
                    BufferMemoryBarrier2
                      { next = ()
                      , srcStageMask = PipelineStageFlagBits2 sourceStage
                      , srcAccessMask = AccessFlagBits2 sourceAccess
                      , dstStageMask = PipelineStageFlagBits2 destinationStage
                      , dstAccessMask = AccessFlagBits2 destinationAccess
                      , srcQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , dstQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , buffer = Buffer buffer
                      , offset = 0
                      , size = WHOLE_SIZE
                      }
                )
            BarrierImage {} → Vector.empty
        , imageMemoryBarriers = case object of
            BarrierImage image aspect levels from to →
              Vector.singleton
                ( SomeStruct
                    ImageMemoryBarrier2
                      { next = ()
                      , srcStageMask = PipelineStageFlagBits2 sourceStage
                      , srcAccessMask = AccessFlagBits2 sourceAccess
                      , dstStageMask = PipelineStageFlagBits2 destinationStage
                      , dstAccessMask = AccessFlagBits2 destinationAccess
                      , oldLayout = Core10.ImageLayout (fromIntegral from)
                      , newLayout = Core10.ImageLayout (fromIntegral to)
                      , srcQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , dstQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , image = Image image
                      , subresourceRange = ImageSubresourceRange {aspectMask = ImageAspectFlagBits aspect, baseMipLevel = 0, levelCount = levels, baseArrayLayer = 0, layerCount = 1}
                      }
                )
            BarrierBuffer _ → Vector.empty
        }
  CommandPushConstants layout stages offset bytes → pushConstantsUnsafe commands (PipelineLayout layout) (pushStageFlags stages) offset bytes
  CommandBindDescriptorSets layout sets offsets → bindDescriptorSetsUnsafe commands (PipelineLayout layout) sets offsets
  CommandBindVertexBuffer binding buffer offset → bindVertexBufferUnsafe commands binding (Buffer buffer) offset
  CommandBindIndexBuffer buffer offset kind →
    bindIndexBufferUnsafe commands (Buffer buffer) offset $ case kind of
      Index16 → Core10.INDEX_TYPE_UINT16
      Index32 → Core10.INDEX_TYPE_UINT32
  CommandDrawIndexed indices instances → drawIndexedUnsafe commands indices instances 0 0 0
  CommandBeginLabel name → beginLabelUnsafe commands DebugUtilsLabelEXT {labelName = name, color = (0, 0, 0, 0)}
  CommandEndLabel → endLabelUnsafe commands
