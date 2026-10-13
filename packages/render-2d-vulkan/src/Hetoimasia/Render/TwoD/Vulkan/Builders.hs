-- | The constructions the recorder, the texture registry and the chunk registry
-- need from their host (R2D-7, R2D-8, R2D-10), as the host lends them inside an
-- owner-thread action or a frame.
--
-- The record is the package's whole seam to the host: the window integration
-- fills it from the 'Construction' it lends, the headless examples from the
-- backend's own recording, and nothing else in the package names a host. Its
-- type parameters are the host session's, which only a batch's recorder names.
module Hetoimasia.Render.TwoD.Vulkan.Builders
  ( Builders (..)
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( Buffer
  , Image
  , ImageFormat
  , Pipeline
  , PipelineBlend
  , PipelineDepth
  , PipelineLayout
  , Refusal
  , RingSize
  , StorageWindow
  )
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders)
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadRefusal, UploadTicket)
import Numeric.Natural (Natural)
import Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( SwapTicket
  , TableConfig
  , TextureHandle
  )

data Builders q inst msgr phys dev cmd = Builders
  { buildRing ∷ RingSize → StorageWindow → IO (Either Refusal ())
    -- ^ The shared ring, with the storage-table window the batches' clip
    -- tables are bound through (R2D-12).
  , buildStorageTable ∷ IO (Either Refusal ())
    -- ^ The session's storage table, set 2 over the ring's window, once; it
    -- needs the ring made with a window.
  , buildTable ∷ TableConfig → IO (Either Refusal ())
  , buildTableLayout ∷ CheckedShaders → IO (Either Refusal PipelineLayout)
    -- ^ A shader-sampled table pipeline layout that also holds the storage
    -- table's set 2: one that declares no sampler offset, over these shaders.
  , buildPipeline ∷ PipelineLayout → CheckedShaders → Word32 → PipelineBlend → IO (Either Refusal Pipeline)
    -- ^ A pipeline over the layout for a colour format's @VkFormat@ code, which
    -- declares no depth.
  , buildDepthPipeline ∷ PipelineLayout → CheckedShaders → Word32 → PipelineBlend → PipelineDepth → IO (Either Refusal Pipeline)
    -- ^ The same, declaring the depth a pass with a depth attachment has
    -- (R2D-9).
  , buildDepthFormat ∷ IO (Either Refusal ImageFormat)
    -- ^ The session's depth format: what the backend chooses for depth targets.
  , buildImageFormat ∷ Image → IO (Either Refusal ImageFormat)
    -- ^ The format the backend holds for a live image, which a depth image's
    -- maker's declaration is checked against.
  , registerImage ∷ Image → IO (Either Refusal TextureHandle)
    -- ^ Register an uploaded texture with the table, answering the backend's
    -- handle for it.
  , swapImage ∷ TextureHandle → Image → IO (Either Refusal SwapTicket)
    -- ^ Give a live handle a replacement texture whose upload is admitted or
    -- complete (GRS-9).
  , releaseImage ∷ TextureHandle → IO (Either Refusal ())
    -- ^ Release a handle in the table: it resolves to the placeholder from the
    -- next version on, and its image is destroyed once no batch holds a
    -- version that maps it.
  , buildVertexBuffer ∷ Natural → IO (Either Refusal Buffer)
    -- ^ A device-local vertex buffer of this many bytes, which a retained chunk's
    -- cutout instances are uploaded into (R2D-10). Never asked for zero bytes.
  , uploadBuffer ∷ Buffer → ByteString → IO (Either UploadRefusal UploadTicket)
    -- ^ Admit the upload that fills a fresh buffer through the bounded staging
    -- buffer: admission copies the bytes before it returns and never waits, and
    -- the ticket says where the upload stands.
  , releaseBuffer ∷ Buffer → IO (Either Refusal ())
    -- ^ Release a managed buffer: nothing records through it again, batches that
    -- already recorded it keep it until their own references end, and an upload
    -- still settling into it is cancelled or finishes first.
  }
