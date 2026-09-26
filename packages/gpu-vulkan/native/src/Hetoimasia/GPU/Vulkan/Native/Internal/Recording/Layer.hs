-- | The native layer of the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): every native call it makes, as
-- the open record 'RecordingOps', and the vocabulary of commands, layouts and
-- requests those calls are given.
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
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int32)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

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

-- | A readback buffer's native objects: the buffer, its memory, and how that
-- memory is mapped.
data ReadbackAllocation = ReadbackAllocation
  { allocationBuffer ∷ !Word64
  , allocationMemory ∷ !Word64
  , allocationSize ∷ !Natural
    -- ^ The buffer's size: what may be copied into it and read out of it.
  , allocationMemorySize ∷ !Natural
    -- ^ The memory's size, which bounds every flushed or invalidated range.
  , allocationCoherent ∷ !Bool
  , allocationAtom ∷ !Natural
    -- ^ The device's non-coherent atom size.
  , allocationMapped ∷ !Word64
    -- ^ Where the whole memory is mapped, from offset zero.
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
  , opsCreateReadback ∷ dev → Natural → IO ReadbackAllocation
    -- ^ A transfer-destination buffer of the size, in host-visible memory,
    -- bound and mapped.
  , opsDestroyReadback ∷ dev → ReadbackAllocation → IO ()
  , opsInvalidate ∷ dev → ReadbackAllocation → (Natural, Natural) → IO ()
    -- ^ Invalidate the mapped range: an offset into the memory and a size.
  , opsFlush ∷ dev → ReadbackAllocation → (Natural, Natural) → IO ()
  , opsReadMapped ∷ ReadbackAllocation → Natural → Natural → IO ByteString
  , opsWriteMapped ∷ ReadbackAllocation → Natural → ByteString → IO ()
  , opsBeginCommands ∷ cmd → IO ()
    -- ^ Begin the command buffer for one submission.
  , opsEndCommands ∷ cmd → IO ()
  , opsRecord ∷ cmd → NativeCommand → IO ()
  , opsCommandBufferHandle ∷ cmd → Word64
    -- ^ The command buffer's dispatchable handle, as its pointer's value, to
    -- name it by.
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
