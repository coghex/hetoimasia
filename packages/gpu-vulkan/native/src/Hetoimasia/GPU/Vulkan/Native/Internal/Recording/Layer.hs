-- | The native layer of the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): every native call it makes, as
-- the open record 'RecordingOps', and the vocabulary of commands, layouts and
-- requests those calls are given — including the engine-defined kinds of
-- managed buffer and image (GRS-2), and the usage flags and memory usage each
-- kind fixes.
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
  , kindFormats
  , ImageDescription (..)
  , fullMipChain
  , ImageQuery (..)
  , ImageLimits (..)
  , ViewRequest (..)
  ) where

import Data.Bits (finiteBitSize, countLeadingZeros, (.|.))
import Data.ByteString (ByteString)
import Data.Int (Int32)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

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
  deriving (Eq, Show)

-- | The shaders of a graphics pipeline, as SPIR-V.
data PipelineShaders = PipelineShaders
  { shaderVertex ∷ !ByteString
  , shaderFragment ∷ !ByteString
  }
  deriving (Eq, Show)

-- | One graphics pipeline for dynamic rendering into one color format:
-- triangle lists, no vertex input, dynamic viewport and scissor.
data PipelineRequest = PipelineRequest
  { requestLayout ∷ !Word64
  , requestShaders ∷ !PipelineShaders
  , requestColorFormat ∷ !Word32
  }
  deriving (Eq, Show)

-- | A readback buffer's native objects: the buffer, its allocation from the
-- device's allocator ("Hetoimasia.GPU.Vulkan.Native.Allocator"), and where
-- that allocation is mapped.
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
  TextureImage → ImageUse (usageSampled .|. usageTransferDestination) (featureSampled .|. featureTransferDestination) UsageTexture aspectColor
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
  { opsCreatePipelineLayout ∷ dev → IO Word64
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
