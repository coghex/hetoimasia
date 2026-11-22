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
  , BufferUploads (..)
  , BufferUploadRefusal (..)
  , noBufferUploads
  , bufferUploadsOf
  ) where

import Control.Concurrent.STM (STM)
import Data.ByteString (ByteString)
import Data.Text (Text)
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
import Hetoimasia.GPU.Vulkan.Native.Uploads
  ( UploadGrant
  , UploadRefusal (UploadClosed)
  , UploadTicket
  , Uploads
  , reserveUpload
  , submitUploadGranted
  , ungated
  , uploadRoom
  )
import Numeric.Natural (Natural)
import Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( SwapTicket
  , TableConfig
  , TextureHandle
  )

data Builders q inst msgr phys dev cmd = Builders
  { buildRing ∷ RingSize → StorageWindow → IO (Either Refusal ())
    -- ^ The shared ring, with the storage-table window the batches' clip tables
    -- (R2D-12) and material records (R2D-11) are bound through.
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
  , bufferUploads ∷ BufferUploads
    -- ^ The room a fresh vertex buffer's upload needs, reserved before the buffer
    -- is made, and the upload that spends it.
  , releaseBuffer ∷ Buffer → IO (Either Refusal ())
    -- ^ Release a managed buffer: nothing records through it again, batches that
    -- already recorded it keep it until their own references end, and an upload
    -- still settling into it is cancelled or finishes first.
  }

-- | The bounded staging uploads as a retained chunk's build reaches them: room
-- for an upload of a byte length is observed or reserved in one decision the
-- host's uploads make for every caller, before the vertex buffer is made, and
-- the reservation is spent once by the upload that fills the buffer, or
-- abandoned.
data BufferUploads = BufferUploads
  { roomFor ∷ Natural → STM (Either BufferUploadRefusal ())
    -- ^ Whether an upload of this many bytes would be reserved now, read-only.
  , reserveRoom ∷ Natural → STM (Either BufferUploadRefusal UploadGrant)
    -- ^ Reserve its queue place and staging region; a refusal reserves nothing.
  , uploadGranted ∷ UploadGrant → Buffer → ByteString → IO (Either BufferUploadRefusal UploadTicket)
    -- ^ Spend the reservation on the upload that fills a fresh vertex buffer of
    -- exactly its bytes: admission copies the bytes before it returns and never
    -- waits, and the ticket says where the upload stands. A refusal before
    -- binding leaves the reservation to be spent or abandoned; once bound, a
    -- failed or cancelled copy, or a refusal before the upload is queued, gives
    -- its place and region back and consumes it, so abandoning it changes
    -- nothing. An unspent reservation is given back through the uploads that
    -- issued it ('returnUploadGrant'), not through this record.
  }

-- | Why the uploads did not answer room or an upload: the host's uploads are
-- configured and not yet made (their startup can make them: a later attempt can
-- succeed); the host has none, or their startup failed, with its cause (no wait
-- changes it); or the uploads themselves refused, as they say.
data BufferUploadRefusal
  = BufferUploadsNotReady
  | BufferUploadsUnavailable !Text
  | BufferUploadRefused !UploadRefusal
  deriving (Eq, Show)

-- | Uploads that admit nothing: a construction that records no chunk's buffer.
noBufferUploads ∷ BufferUploads
noBufferUploads =
  BufferUploads
    { roomFor = \_ → pure closed
    , reserveRoom = \_ → pure closed
    , uploadGranted = \_ _ _ → pure closed
    }
  where
    closed = Left (BufferUploadRefused UploadClosed)

-- | A session's own uploads, ungated.
bufferUploadsOf ∷ Uploads q inst msgr phys dev cmd → BufferUploads
bufferUploadsOf uploads =
  BufferUploads
    { roomFor = fmap refused . uploadRoom uploads
    , reserveRoom = fmap refused . reserveUpload uploads
    , uploadGranted = \grant buffer bytes → refused <$> submitUploadGranted ungated uploads grant buffer bytes
    }
  where
    refused ∷ Either UploadRefusal a → Either BufferUploadRefusal a
    refused = either (Left . BufferUploadRefused) Right
