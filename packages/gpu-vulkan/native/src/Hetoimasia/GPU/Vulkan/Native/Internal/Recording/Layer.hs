-- | The native layer of the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): every native call it makes, as
-- the open record 'RecordingOps', and the vocabulary of commands, layouts and
-- requests those calls are given — including the engine-defined kinds of
-- managed buffer and image (GRS-2), and the usage flags and memory usage each
-- kind fixes; how each use the GPU model's ordering rules name (GRS-3)
-- maps onto Vulkan's layouts, stages and accesses; and what a pipeline layout
-- and a pipeline declare of their interface, push-constant ranges and vertex
-- input (GRS-4).
--
-- This module holds no state and makes no call: it is the shape of the layer,
-- which "Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan" implements over the
-- real device and the headless examples implement over a stand-in. Every
-- other part of the recording names a native call only through this record.
-- It is private to the package; clients reach every name here through the
-- public recording module, which re-exports them unchanged.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( RecordingOps (..)
  , PipelineRequest (..)
  , PipelineShaders (..)
  , ReadbackAllocation (..)
  , RecordingLimits (..)
  , NativeCommand (..)
  , nativeName
  , ImageLayout (..)
  , supportedTransition
  , ClearColor (..)
  , Viewport (..)
  , Rect (..)

    -- * Buffers and images
  , BufferKind (..)
  , bufferKindUse
  , BufferDescription (..)
  , ImageKind (..)
  , ImageUse (..)
  , imageKindUse
  , ImageFormat (..)
  , formatCode
  , formatNeedsCompressionBC
  , FormatBlock (..)
  , formatBlock
  , levelExtent
  , levelRows
  , levelBytes
  , kindFormats
  , ImageDescription (..)
  , fullMipChain
  , ImageQuery (..)
  , ImageLimits (..)
  , ViewRequest (..)

    -- * Pipeline interfaces (GRS-4)
  , PushStage (..)
  , pushStageBit
  , PushConstantRange (..)
  , InputRate (..)
  , VertexFormat (..)
  , vertexFormatCode
  , vertexFormatBytes
  , vertexFormatComponentBytes
  , VertexBinding (..)
  , VertexAttribute (..)
  , VertexInput (..)
  , noVertexInput
  , IndexType (..)
  , indexTypeBytes

    -- * Ordering managed resources (GRS-3)
  , AccessScope (..)
  , BarrierObject (..)
  , bufferResourceKind
  , imageResourceKind
  , useScope
  , useLayout
  , resourceBarrier
  ) where

import Data.Bits (countLeadingZeros, finiteBitSize, shiftR, (.|.))
import Data.ByteString (ByteString)
import Data.Int (Int32)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model.Access (Barrier (..), ResourceKind (..), ResourceUse (..))
import Hetoimasia.GPU.Vulkan.Native.Allocator (BoundMemory, MemoryUsage (..))
import Hetoimasia.GPU.Vulkan.Native.Naming (ShaderStage)
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent)

-- | The layouts the supported commands move a frame's image through.
data ImageLayout
  = LayoutUndefined
    -- ^ Whatever the image held before this batch; its contents are not kept.
  | LayoutColorAttachment
  | LayoutTransferSource
  | LayoutPresentSource
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The transitions 'transitionImage' supports: into rendering from anything,
-- and out of rendering to the copy or to presentation, and from the copy to
-- presentation. Any other pair is an unsupported command, refused at the
-- interface.
supportedTransition ∷ ImageLayout → ImageLayout → Bool
supportedTransition from to =
  (from, to)
    `elem` [ (LayoutUndefined, LayoutColorAttachment)
           , (LayoutColorAttachment, LayoutTransferSource)
           , (LayoutColorAttachment, LayoutPresentSource)
           , (LayoutTransferSource, LayoutPresentSource)
           ]

-- | A linear color the render area is cleared to.
data ClearColor = ClearColor !Float !Float !Float !Float
  deriving (Eq, Show)

data Viewport = Viewport
  { viewportX ∷ !Float
  , viewportY ∷ !Float
  , viewportWidth ∷ !Float
  , viewportHeight ∷ !Float
  }
  deriving (Eq, Show)

data Rect = Rect
  { rectX ∷ !Int32
  , rectY ∷ !Int32
  , rectWidth ∷ !Word32
  , rectHeight ∷ !Word32
  }
  deriving (Eq, Show)

-- | One command recorded into a batch's command buffer, exactly as the
-- native layer is asked to record it. Handles are the native ones the
-- managed records hold.
data NativeCommand
  = CommandImageBarrier !Word64 !ImageLayout !ImageLayout
    -- ^ The image, and the layouts it leaves and enters.
  | CommandBeginRendering !Word64 !SurfaceExtent !ClearColor
    -- ^ Dynamic rendering into one color view, cleared, across the extent.
  | CommandEndRendering
  | CommandBindPipeline !Word64
  | CommandSetViewport !Viewport
  | CommandSetScissor !Rect
  | CommandDraw !Word32 !Word32 !Word32 !Word32
    -- ^ Vertex count, instance count, first vertex, first instance.
  | CommandCopyImageToBuffer !Word64 !SurfaceExtent !Word64
    -- ^ The whole color image, tightly packed, into the buffer at offset zero.
  | CommandHostReadBarrier !Word64 !Word64
    -- ^ The buffer and the byte count its transfer write is made visible to
    -- host reads over.
  | CommandBeginLabel !ByteString
    -- ^ Open a command-buffer label region with this name.
  | CommandEndLabel
    -- ^ Close the innermost open label region.
  | CommandResourceBarrier !BarrierObject !AccessScope !AccessScope
    -- ^ One managed buffer or image, the scope its barrier waits for, and the
    -- scope it makes ready (GRS-3).
  | CommandPushConstants !Word64 ![PushStage] !Word32 !ByteString
    -- ^ The pipeline layout, the stages the bytes are for, the offset, and
    -- the bytes (GRS-4).
  | CommandBindVertexBuffer !Word32 !Word64 !Word64
    -- ^ A vertex input binding, the buffer bound to it and the offset into
    -- that buffer.
  | CommandBindIndexBuffer !Word64 !Word64 !IndexType
    -- ^ The buffer, the offset into it, and the indices' type.
  | CommandDrawIndexed !Word32 !Word32
    -- ^ Index count and instance count, from the first index, vertex offset
    -- and instance zero.
  | CommandCopyBuffer !Word64 !Word64 !Word64 !Word64 !Word64
    -- ^ One region from one buffer into another: the source buffer and the
    -- offset into it, the destination buffer and the offset into it, and the
    -- byte count (GRS-6).
  | CommandCopyBufferToImage !Word64 !Word64 !Word64 !Word32 !Word32 !Word32 !Word32
    -- ^ Tightly packed bytes of one buffer into one band of rows of one mip
    -- level of a color image in the transfer-destination layout: the buffer
    -- and the offset into it, the image, the mip level, the band's first row,
    -- and its width and height in texels (GRS-6).
  | CommandCopyImageLevelToBuffer !Word64 !Word32 !Word32 !Word32 !Word64
    -- ^ One whole mip level of a color image in the transfer-source layout —
    -- the image, the level, and its width and height in texels — tightly
    -- packed into the buffer at offset zero (GRS-6).
  deriving (Eq, Show)

-- | The shaders of a graphics pipeline, as SPIR-V.
data PipelineShaders = PipelineShaders
  { shaderVertex ∷ !ByteString
  , shaderFragment ∷ !ByteString
  }
  deriving (Eq, Show)

-- | One graphics pipeline for dynamic rendering into one color format:
-- triangle lists, the vertex input it declares, dynamic viewport and scissor.
data PipelineRequest = PipelineRequest
  { requestLayout ∷ !Word64
  , requestShaders ∷ !PipelineShaders
  , requestColorFormat ∷ !Word32
  , requestVertexInput ∷ !VertexInput
  }
  deriving (Eq, Show)

-- | A mapped buffer's native objects — a readback buffer's, or the session's
-- shared ring's (GRS-4): the buffer, its allocation from the device's
-- allocator ("Hetoimasia.GPU.Vulkan.Native.Allocator"), and where that
-- allocation is mapped.
data ReadbackAllocation = ReadbackAllocation
  { allocationBuffer ∷ !Word64
  , allocationMemory ∷ !BoundMemory
    -- ^ The buffer with its allocation, which may share device memory with
    -- others.
  , allocationSize ∷ !Natural
    -- ^ The buffer's size: what may be copied into it and read out of it.
  , allocationCoherent ∷ !Bool
  , allocationMapped ∷ !Word64
    -- ^ Where the allocation is mapped, from its own start, for its lifetime.
  }
  deriving (Eq, Show)

-- | What the device allows the recording's pipeline interfaces and mapped
-- memory, read once from its properties.
data RecordingLimits = RecordingLimits
  { limitPushConstantBytes ∷ !Word32
    -- ^ @maxPushConstantsSize@: how far a push-constant range may reach.
  , limitVertexBindings ∷ !Word32
    -- ^ @maxVertexInputBindings@.
  , limitVertexAttributes ∷ !Word32
    -- ^ @maxVertexInputAttributes@.
  , limitVertexStride ∷ !Word32
    -- ^ @maxVertexInputBindingStride@.
  , limitVertexAttributeOffset ∷ !Word32
    -- ^ @maxVertexInputAttributeOffset@.
  , limitNonCoherentAtom ∷ !Natural
    -- ^ @nonCoherentAtomSize@: the granularity of flushing non-coherent
    -- memory.
  , limitImageDimension ∷ !Word32
    -- ^ @maxImageDimension2D@: the widest level any two-dimensional image
    -- may have, which bounds one block row of an upload (GRS-6).
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Pipeline interfaces (GRS-4)

-- | A shader stage push constants may be declared for and pushed to: the two
-- stages every pipeline has.
data PushStage = PushVertex | PushFragment
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The stage's @VkShaderStageFlagBits@ value.
pushStageBit ∷ PushStage → Word32
pushStageBit = \case
  PushVertex → 0x00000001
  PushFragment → 0x00000010

-- | One push-constant range a pipeline layout declares: the stages it is
-- visible to, and its offset and size in bytes.
data PushConstantRange = PushConstantRange
  { rangeStages ∷ ![PushStage]
  , rangeOffset ∷ !Word32
  , rangeSize ∷ !Word32
  }
  deriving (Eq, Show)

-- | Whether a vertex binding advances per vertex or per instance.
data InputRate = PerVertex | PerInstance
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The formats a vertex attribute may have: every one of them is one Vulkan
-- requires every device to support as a vertex buffer format, so no device
-- is asked.
data VertexFormat
  = VertexFloat
  | VertexFloat2
  | VertexFloat3
  | VertexFloat4
  | VertexUint
  | VertexRgba8Unorm
    -- ^ Four normalized bytes, read as four floats.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The format's @VkFormat@ value.
vertexFormatCode ∷ VertexFormat → Word32
vertexFormatCode = \case
  VertexRgba8Unorm → 37
  VertexUint → 98
  VertexFloat → 100
  VertexFloat2 → 103
  VertexFloat3 → 106
  VertexFloat4 → 109

-- | The bytes one attribute of the format occupies.
vertexFormatBytes ∷ VertexFormat → Word32
vertexFormatBytes = \case
  VertexFloat → 4
  VertexFloat2 → 8
  VertexFloat3 → 12
  VertexFloat4 → 16
  VertexUint → 4
  VertexRgba8Unorm → 4

-- | The bytes one component of an attribute of the format occupies: what the
-- attribute's address in its buffer must be a multiple of.
vertexFormatComponentBytes ∷ VertexFormat → Natural
vertexFormatComponentBytes = \case
  VertexRgba8Unorm → 1
  _ → 4

-- | One vertex input binding a pipeline declares: its number, its stride in
-- bytes, and whether it advances per vertex or per instance.
data VertexBinding = VertexBinding
  { bindingNumber ∷ !Word32
  , bindingStride ∷ !Word32
  , bindingRate ∷ !InputRate
  }
  deriving (Eq, Show)

-- | One vertex attribute a pipeline declares: its shader location, the
-- binding it reads, its format, and its offset into each element.
data VertexAttribute = VertexAttribute
  { attributeLocation ∷ !Word32
  , attributeBinding ∷ !Word32
  , attributeFormat ∷ !VertexFormat
  , attributeOffset ∷ !Word32
  }
  deriving (Eq, Show)

-- | A pipeline's vertex input: its bindings and the attributes read from
-- them, for the triangle-list topology.
data VertexInput = VertexInput
  { inputBindings ∷ ![VertexBinding]
  , inputAttributes ∷ ![VertexAttribute]
  }
  deriving (Eq, Show)

-- | No vertex input: the shader makes its own vertices.
noVertexInput ∷ VertexInput
noVertexInput = VertexInput [] []

-- | The type of the indices an indexed draw reads.
data IndexType = Index16 | Index32
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The bytes one index of the type occupies.
indexTypeBytes ∷ IndexType → Natural
indexTypeBytes = \case
  Index16 → 2
  Index32 → 4

-- ---------------------------------------------------------------------------
-- Buffers and images

-- | What a managed buffer is for. Each kind fixes the buffer's Vulkan usage
-- flags and its memory usage ('bufferKindUse'); a consumer never passes raw
-- flags.
data BufferKind
  = VertexBuffer
    -- ^ Static vertex data, staged into device-local memory.
  | IndexBuffer
    -- ^ Static index data, staged into device-local memory.
  | InstanceBuffer
    -- ^ Per-frame instance data, or the shared ring (D-33): host-visible
    -- memory the device reads directly, bound as vertex, index or instance
    -- data.
  | LookupBuffer
    -- ^ A per-frame lookup table (D-23, D-35): host-visible memory the device
    -- reads as a storage buffer.
  | StagingBuffer
    -- ^ Host-written bytes the device copies from.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A buffer kind's Vulkan usage flags, and the memory usage its allocation
-- is made under.
bufferKindUse ∷ BufferKind → (Word32, MemoryUsage)
bufferKindUse = \case
  VertexBuffer → (bufferVertex .|. bufferTransferDestination, UsageStaticGeometry)
  IndexBuffer → (bufferIndex .|. bufferTransferDestination, UsageStaticGeometry)
  InstanceBuffer → (bufferVertex .|. bufferIndex, UsageFrameRing)
  LookupBuffer → (bufferStorage, UsageFrameRing)
  StagingBuffer → (bufferTransferSource, UsageStaging)
  where
    bufferTransferSource = 0x00000001
    bufferTransferDestination = 0x00000002
    bufferStorage = 0x00000020
    bufferIndex = 0x00000040
    bufferVertex = 0x00000080

-- | A managed buffer to create: its kind, and its size in bytes.
data BufferDescription = BufferDescription
  { bufferKind ∷ !BufferKind
  , bufferBytes ∷ !Natural
  }
  deriving (Eq, Show)

-- | What a managed image is for. Each kind fixes the image's Vulkan usage
-- flags, the format features it needs, its memory usage and the aspect its
-- view covers ('imageKindUse'), and the formats it accepts ('kindFormats').
data ImageKind
  = TextureImage
    -- ^ Sampled by shaders, written only by copies into it (D-16, D-21).
  | DepthTarget
    -- ^ A depth-only attachment (D-36).
  | ColorTarget
    -- ^ A color attachment rendered into offscreen, and copied out of.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What an image kind fixes.
data ImageUse = ImageUse
  { useImageFlags ∷ !Word32
    -- ^ @VkImageUsageFlags@.
  , useFormatFeatures ∷ !Word32
    -- ^ The @VkFormatFeatureFlags@ its format must offer under optimal
    -- tiling: one per usage.
  , useMemory ∷ !MemoryUsage
  , useAspect ∷ !Word32
    -- ^ The @VkImageAspectFlags@ its owned view covers.
  }
  deriving (Eq, Show)

imageKindUse ∷ ImageKind → ImageUse
imageKindUse = \case
  TextureImage → ImageUse (usageSampled .|. usageTransferDestination .|. usageTransferSource) (featureSampled .|. featureTransferDestination .|. featureTransferSource) UsageTexture aspectColor
  DepthTarget → ImageUse usageDepthAttachment featureDepthAttachment UsageTexture aspectDepth
  ColorTarget → ImageUse (usageColorAttachment .|. usageTransferSource) (featureColorAttachment .|. featureTransferSource) UsageTexture aspectColor
  where
    usageTransferSource = 0x00000001
    usageTransferDestination = 0x00000002
    usageSampled = 0x00000004
    usageColorAttachment = 0x00000010
    usageDepthAttachment = 0x00000020
    featureSampled = 0x00000001
    featureColorAttachment = 0x00000080
    featureDepthAttachment = 0x00000200
    featureTransferSource = 0x00004000
    featureTransferDestination = 0x00008000
    aspectColor = 0x00000001
    aspectDepth = 0x00000002

-- | The formats a managed image may have.
data ImageFormat
  = Rgba8Srgb
  | Rgba8Linear
  | Bc7Srgb
  | Bc7Linear
  | Bgra8Srgb
  | Bgra8Linear
  | Depth32Float
  | Depth24
    -- ^ 24-bit depth in a 32-bit word, with no stencil.
  | Depth16
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The format's @VkFormat@ value.
formatCode ∷ ImageFormat → Word32
formatCode = \case
  Rgba8Linear → 37
  Rgba8Srgb → 43
  Bgra8Linear → 44
  Bgra8Srgb → 50
  Depth16 → 124
  Depth24 → 125
  Depth32Float → 126
  Bc7Linear → 145
  Bc7Srgb → 146

-- | Whether the format needs the device's @textureCompressionBC@ feature
-- enabled.
formatNeedsCompressionBC ∷ ImageFormat → Bool
formatNeedsCompressionBC = (`elem` [Bc7Srgb, Bc7Linear])

-- | The formats each kind accepts: textures the ones the upload endpoint
-- takes (D-21), RGBA8 and BC7, each sRGB and linear; color targets RGBA8 and
-- BGRA8, each sRGB and linear; depth targets the depth-only formats (D-36).
-- Whether the device supports one for that use is asked of it separately.
kindFormats ∷ ImageKind → [ImageFormat]
kindFormats = \case
  TextureImage → [Rgba8Srgb, Rgba8Linear, Bc7Srgb, Bc7Linear]
  DepthTarget → [Depth32Float, Depth24, Depth16]
  ColorTarget → [Rgba8Srgb, Rgba8Linear, Bgra8Srgb, Bgra8Linear]

-- | How a color format's texels are stored: the width and height of one
-- block of texels, and the bytes one block takes. An uncompressed format's
-- block is one texel.
data FormatBlock = FormatBlock
  { blockWidth ∷ !Word32
  , blockHeight ∷ !Word32
  , blockBytes ∷ !Natural
  }
  deriving (Eq, Show)

-- | The block a color format stores its texels in: one texel of four bytes
-- for RGBA8 and BGRA8, and four by four texels in sixteen bytes for BC7.
-- 'Nothing' for a depth format, which nothing uploads into or copies out of.
formatBlock ∷ ImageFormat → Maybe FormatBlock
formatBlock = \case
  Rgba8Srgb → Just texel
  Rgba8Linear → Just texel
  Bgra8Srgb → Just texel
  Bgra8Linear → Just texel
  Bc7Srgb → Just bc7
  Bc7Linear → Just bc7
  Depth32Float → Nothing
  Depth24 → Nothing
  Depth16 → Nothing
  where
    texel = FormatBlock 1 1 4
    bc7 = FormatBlock 4 4 16

-- | One mip level's extent: the base extent halved per level, never below
-- one texel.
levelExtent ∷ Word32 → Word32 → Word32 → (Word32, Word32)
levelExtent width height level = (max 1 (width `shiftR` fromIntegral level), max 1 (height `shiftR` fromIntegral level))

-- | One mip level's rows of blocks, and the bytes one row of them takes: a
-- partial block at the right or bottom edge is a whole one.
levelRows ∷ FormatBlock → (Word32, Word32) → (Natural, Natural)
levelRows block (width, height) =
  ( ceilingOf (fromIntegral height) (fromIntegral (blockHeight block))
  , ceilingOf (fromIntegral width) (fromIntegral (blockWidth block)) * blockBytes block
  )
  where
    ceilingOf value granule = (value + granule - 1) `div` granule

-- | The bytes one mip level takes, tightly packed: every row of blocks.
levelBytes ∷ FormatBlock → (Word32, Word32) → Natural
levelBytes block extent = let (rows, row) = levelRows block extent in rows * row

-- | A managed image to create: its kind, its format, its extent, and how many
-- mip levels it has. It is two-dimensional, of one layer and one sample.
data ImageDescription = ImageDescription
  { imageKind ∷ !ImageKind
  , imageFormat ∷ !ImageFormat
  , imageWidth ∷ !Word32
  , imageHeight ∷ !Word32
  , imageMipLevels ∷ !Word32
  }
  deriving (Eq, Show)

-- | How many mip levels a complete chain for this extent has: one more than
-- the base-two logarithm of its larger side, rounded down. No image may have
-- more.
fullMipChain ∷ Word32 → Word32 → Word32
fullMipChain width height
  | largest == 0 = 0
  | otherwise = fromIntegral (finiteBitSize largest - countLeadingZeros largest)
  where
    largest = max width height

-- | What the device is asked about one image before it is created: its
-- format, its usage flags, and the format features the usage needs under
-- optimal tiling.
data ImageQuery = ImageQuery
  { queryFormat ∷ !Word32
  , queryUsage ∷ !Word32
  , queryFeatures ∷ !Word32
  }
  deriving (Eq, Show)

-- | The most a supported image of one query may be: its extent, its mip
-- levels, and the bytes its memory may need (@maxResourceSize@).
data ImageLimits = ImageLimits
  { limitWidth ∷ !Word32
  , limitHeight ∷ !Word32
  , limitMipLevels ∷ !Word32
  , limitResourceSize ∷ !Natural
  }
  deriving (Eq, Show)

-- | An image's one owned view: the whole resource — every mip level of its
-- one layer — in its own format, over the aspect its kind fixes.
data ViewRequest = ViewRequest
  { requestViewImage ∷ !Word64
  , requestViewFormat ∷ !Word32
  , requestViewAspect ∷ !Word32
  , requestViewMipLevels ∷ !Word32
  }
  deriving (Eq, Show)

-- | Every native call the recording makes, over an open device type @dev@ and
-- an open command-buffer type @cmd@.
data RecordingOps dev cmd = RecordingOps
  { opsCreatePipelineLayout ∷ dev → [PushConstantRange] → IO Word64
    -- ^ A pipeline layout with no descriptor sets and these push-constant
    -- ranges, which the recording has already validated.
  , opsDestroyPipelineLayout ∷ dev → Word64 → IO ()
  , opsCreatePipeline ∷ dev → PipelineRequest → (ShaderStage → Word64 → IO ()) → IO Word64
    -- ^ Builds and destroys its own shader modules; the pipeline is the only
    -- thing it leaves. Each module is handed to the naming call right after it
    -- is created, before anything uses it; a naming call that raised destroys
    -- every module made so far before the failure is re-raised.
  , opsDestroyPipeline ∷ dev → Word64 → IO ()
  , opsCreateStorage ∷ dev → Word32 → IO (Word64, cmd)
    -- ^ A command pool on the queue family, and the one primary command buffer
    -- allocated from it.
  , opsResetStorage ∷ dev → Word64 → IO ()
    -- ^ Reset the pool, which invalidates every command recorded into its
    -- buffer: nothing recorded before the reset can be submitted after it.
  , opsDestroyStorage ∷ dev → Word64 → IO ()
    -- ^ Destroy the pool, which frees its command buffer.
  , opsReadMapped ∷ ReadbackAllocation → Natural → Natural → IO ByteString
    -- ^ Copy bytes out of a readback buffer's mapping: an offset into the
    -- buffer and a size. The buffer's memory, its mapping and its maintenance
    -- are the device allocator's.
  , opsWriteMapped ∷ ReadbackAllocation → Natural → ByteString → IO ()
  , opsBeginCommands ∷ cmd → IO ()
    -- ^ Begin the command buffer for one submission.
  , opsEndCommands ∷ cmd → IO ()
  , opsRecord ∷ cmd → NativeCommand → IO ()
  , opsCommandBufferHandle ∷ cmd → Word64
    -- ^ The command buffer's dispatchable handle, as its pointer's value, to
    -- name it by.
  , opsImageSupport ∷ ImageQuery → IO (Maybe ImageLimits)
    -- ^ Whether the physical device supports an optimally tiled
    -- two-dimensional image of the query's format, usage and format
    -- features, and the most such an image may be; 'Nothing' if it does not.
    -- It asks the device and creates nothing.
  , opsMaxBufferSize ∷ IO Natural
    -- ^ The largest buffer the device may create (@maxBufferSize@).
  , opsMaxFramebuffer ∷ IO (Word32, Word32)
    -- ^ The widest and tallest render area the device may render into
    -- (@maxFramebufferWidth@, @maxFramebufferHeight@), which an image's own
    -- limits do not bound (GRS-5).
  , opsRecordingLimits ∷ IO RecordingLimits
    -- ^ What the device allows pipeline interfaces and mapped memory (GRS-4).
  , opsCreateView ∷ dev → ViewRequest → IO Word64
    -- ^ An image's one owned view.
  , opsDestroyView ∷ dev → Word64 → IO ()
  }

-- | The entry point a command is recorded by, as failures name it.
nativeName ∷ NativeCommand → Text
nativeName = \case
  CommandImageBarrier {} → "vkCmdPipelineBarrier2"
  CommandBeginRendering {} → "vkCmdBeginRendering"
  CommandEndRendering → "vkCmdEndRendering"
  CommandBindPipeline _ → "vkCmdBindPipeline"
  CommandSetViewport _ → "vkCmdSetViewport"
  CommandSetScissor _ → "vkCmdSetScissor"
  CommandDraw {} → "vkCmdDraw"
  CommandCopyImageToBuffer {} → "vkCmdCopyImageToBuffer"
  CommandHostReadBarrier {} → "vkCmdPipelineBarrier2"
  CommandBeginLabel _ → "vkCmdBeginDebugUtilsLabelEXT"
  CommandEndLabel → "vkCmdEndDebugUtilsLabelEXT"
  CommandResourceBarrier {} → "vkCmdPipelineBarrier2"
  CommandPushConstants {} → "vkCmdPushConstants"
  CommandBindVertexBuffer {} → "vkCmdBindVertexBuffers"
  CommandBindIndexBuffer {} → "vkCmdBindIndexBuffer"
  CommandDrawIndexed {} → "vkCmdDrawIndexed"
  CommandCopyBuffer {} → "vkCmdCopyBuffer"
  CommandCopyBufferToImage {} → "vkCmdCopyBufferToImage"
  CommandCopyImageLevelToBuffer {} → "vkCmdCopyImageToBuffer"

-- ---------------------------------------------------------------------------
-- Ordering managed resources (GRS-3)

-- | The pipeline stages a use covers and the accesses it makes there, as
-- @VkPipelineStageFlags2@ and @VkAccessFlags2@.
data AccessScope = AccessScope
  { scopeStages ∷ !Word64
  , scopeAccess ∷ !Word64
  }
  deriving (Eq, Show)

-- | What one managed resource's barrier covers.
data BarrierObject
  = BarrierBuffer !Word64
    -- ^ The whole buffer.
  | BarrierImage !Word64 !Word32 !Word32 !Word32 !Word32
    -- ^ The whole image — its view's aspect and every mip level of its one
    -- layer — and the @VkImageLayout@ values it leaves and enters.
  deriving (Eq, Show)

-- | The ordering rules' kind of a managed buffer.
bufferResourceKind ∷ BufferKind → ResourceKind
bufferResourceKind = \case
  VertexBuffer → VertexResource
  IndexBuffer → IndexResource
  InstanceBuffer → InstanceResource
  LookupBuffer → LookupResource
  StagingBuffer → StagingResource

-- | The ordering rules' kind of a managed image.
imageResourceKind ∷ ImageKind → ResourceKind
imageResourceKind = \case
  TextureImage → TextureResource
  DepthTarget → DepthTargetResource
  ColorTarget → ColorTargetResource

-- | The stages and accesses a use of a kind of resource covers: each resting
-- use as the issue fixes it, and the copies into and out of a resource as the
-- transfer stage's reads or writes. Host writes into instance, lookup and
-- staging buffers are made visible by the submission that follows them, so no
-- scope names the host.
useScope ∷ ResourceKind → ResourceUse → AccessScope
useScope kind = \case
  ShaderSampled → AccessScope stageFragmentShader accessShaderSampledRead
  DepthAttachment → AccessScope (stageEarlyFragmentTests .|. stageLateFragmentTests) (accessDepthRead .|. accessDepthWrite)
  ColorAttachment → AccessScope stageColorOutput (accessColorRead .|. accessColorWrite)
  GeometryRead → AccessScope stageVertexInput (if kind == IndexResource then accessIndexRead else accessVertexRead)
  InstanceRead →
    AccessScope (stageVertexInput .|. stageVertexShader .|. stageFragmentShader) (accessVertexRead .|. accessIndexRead .|. accessShaderRead)
  StorageRead → AccessScope (stageVertexShader .|. stageFragmentShader) accessShaderStorageRead
  TransferRead → AccessScope stageTransfer accessTransferRead
  TransferWrite → AccessScope stageTransfer accessTransferWrite
  where
    stageVertexInput = 0x00000004
    stageVertexShader = 0x00000008
    stageFragmentShader = 0x00000080
    stageEarlyFragmentTests = 0x00000100
    stageLateFragmentTests = 0x00000200
    stageColorOutput = 0x00000400
    stageTransfer = 0x00001000
    accessIndexRead = 0x00000002
    accessVertexRead = 0x00000004
    accessShaderRead = 0x00000020
    accessColorRead = 0x00000080
    accessColorWrite = 0x00000100
    accessDepthRead = 0x00000200
    accessDepthWrite = 0x00000400
    accessTransferRead = 0x00000800
    accessTransferWrite = 0x00001000
    accessShaderSampledRead = 0x100000000
    accessShaderStorageRead = 0x200000000

-- | The @VkImageLayout@ an image is in for a use: none for a use only a
-- buffer is put to.
useLayout ∷ ResourceUse → Maybe Word32
useLayout = \case
  ShaderSampled → Just 5
  DepthAttachment → Just 1000241000
  ColorAttachment → Just 2
  TransferRead → Just 6
  TransferWrite → Just 7
  GeometryRead → Nothing
  InstanceRead → Nothing
  StorageRead → Nothing

-- | The native command for one barrier the ordering rules owe, over a buffer,
-- or over an image with its view's aspect and its mip levels. A barrier that
-- discards leaves the undefined layout; its first scope is still the use it
-- waits for.
resourceBarrier ∷ Word64 → Maybe (Word32, Word32) → Barrier k → NativeCommand
resourceBarrier handle image barrier =
  CommandResourceBarrier object (useScope kind (barrierAfter barrier)) (useScope kind (barrierBefore barrier))
  where
    kind = barrierKind barrier
    layout = maybe 0 id . useLayout
    object = case image of
      Nothing → BarrierBuffer handle
      Just (aspect, levels) →
        BarrierImage
          handle
          aspect
          levels
          (if barrierDiscards barrier then 0 else layout (barrierAfter barrier))
          (layout (barrierBefore barrier))
