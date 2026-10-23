-- | The upload and registration port the texture pipeline (LFE-16) is injected with, and that the
-- concrete graphics adapter (LFE-17) implements on the protected graphics owner.
--
-- The pipeline decodes a verified PNG into one premultiplied RGBA8 level on the CPU. Turning that
-- level into a texture a renderer can sample is the backend's: allocate, upload, wait for the
-- upload to complete, register the texture so a scene can name it. This module is the whole of what
-- the pipeline asks of it, and of what it must answer, so that the CPU component imports nothing of
-- Vulkan, GLFW, a console or a game.
--
-- = The four facts the port keeps apart
--
-- * /Submitted work/: 'backendUpload' returned an 'UploadWork'. Nothing is usable yet, and the
--   decoded level is /borrowed/: the pipeline keeps it charged to its lane until the backend says
--   it no longer reads it ('sinkBuffersRetired').
-- * /A usable registration/: 'sinkReady' with a 'BackendTexture'. This is the only evidence that
--   permits a request to succeed. A decoded image, an acknowledged submission or an allocated native
--   handle is not it.
-- * /Release requested/: 'textureRelease', called at most once for a texture, revokes the engine's
--   use and starts the backend's retirement. It never waits.
-- * /Actual retirement/: the reading 'textureRelease' answers becomes 'ProviderComplete' only when
--   the backend can prove nothing still uses the texture: no accepted or adopted scene still holds
--   it and the GPU has finished with it. A request to release, a cancellation acknowledgement, a
--   worker's exit and the end of a CPU scope are none of them that proof.
--
-- = Ownership
--
-- Every object changes owner only at an answer of 'SinkTaken'. A sink call that answers 'SinkLate'
-- (the job already ended, or already had that event) took nothing, so what the backend passed
-- stays the backend's to dispose of; the pipeline counts it and never retains it. A backend must
-- deliver exactly one terminal event ('sinkReady', 'sinkFailed' or 'sinkWithdrawn') and exactly one
-- 'sinkBuffersRetired' for every upload it accepted, however the work ended.
--
-- = Threads
--
-- 'backendUpload' is called on the pipeline's decode worker, once the decode finished, and must not
-- block: it hands the work to the backend's own owner and returns. The sink's operations may be called
-- from any thread, at any time after 'backendUpload' was entered (including before it returns), and
-- never block: each is one transaction on the pipeline's state, plus, for 'sinkReady', one
-- non-blocking completion of the request. A sink call never enters Lua.
module Hetoimasia.LuaEngine.Texture.Backend
  ( -- * The backend
    TextureBackend (..)

    -- * What is uploaded
  , Upload (..)
  , UploadWork (..)
  , UploadSink (..)
  , SinkAnswer (..)
  , UploadFailure (..)

    -- * What is delivered
  , BackendTexture (..)
  , RetirementState (..)
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Control.Concurrent.STM (STM)
import Hetoimasia.Scripting.Lua.Provider (RetirementState (..))

-- | The operations the pipeline calls. An implementation is owned by the graphics side and must
-- outlive the pipeline and every texture it delivered: the pipeline cannot wait for a lease it does
-- not own.
newtype TextureBackend = TextureBackend
  { backendUpload ∷ Upload → UploadSink → IO UploadWork
    -- ^ Accept a decoded level for upload and registration. Must not block. It answers through
    -- the sink, from any thread, now or later. What it raises is an engine failure: the pipeline
    -- takes the upload as never accepted (the backend retained nothing) and the failure is fatal.
  }

-- | A decoded level handed to the backend, borrowed until 'sinkBuffersRetired'.
data Upload = Upload
  { uploadSource ∷ !Text
    -- ^ Root and path, for the backend's own diagnostics. Never an identity.
  , uploadWidth ∷ !Word32
  , uploadHeight ∷ !Word32
  , uploadTexels ∷ !ByteString
    -- ^ One tightly packed, top-row-first RGBA8 level of exactly @width * height * 4@ bytes. The
    -- pipeline charges its backing allocation to the lane that owns the upload; it is the level the
    -- decoder produced, not a copy.
  }

-- | What the engine holds of accepted upload work, so that interest in it can end.
newtype UploadWork = UploadWork
  { uploadCancel ∷ IO ()
    -- ^ Withdraw the engine's interest, once. It is not proof the work ended: the backend still owes
    -- the terminal event and 'sinkBuffersRetired', and the engine waits for both.
  }

-- | How the backend answers one upload.
data UploadSink = UploadSink
  { sinkReady ∷ BackendTexture → IO SinkAnswer
    -- ^ The upload completed and the texture is registered and usable.
  , sinkFailed ∷ UploadFailure → IO SinkAnswer
    -- ^ The backend, device or allocator failed. Always fatal, never an image error.
  , sinkWithdrawn ∷ IO SinkAnswer
    -- ^ The backend honoured a cancellation and produced no texture.
  , sinkBuffersRetired ∷ IO SinkAnswer
    -- ^ The backend no longer reads the borrowed level. May precede or follow the terminal event.
  }

-- | Whether the pipeline took what the call carried.
data SinkAnswer
  = -- | Taken: the pipeline owns the texture, or has recorded the event.
    SinkTaken
  | -- | The upload had ended or already had that event: nothing was taken, and the backend still
    -- owns whatever it passed.
    SinkLate
  deriving (Eq, Show)

-- | A backend failure, bounded text only: a native error is not a content failure and is never
-- given a content code.
newtype UploadFailure = UploadFailure Text
  deriving (Eq, Show)

-- | A texture the backend registered.
data BackendTexture = BackendTexture
  { textureIdentity ∷ !Word64
    -- ^ The registration identity a scene names the texture by. The backend's.
  , textureRelease ∷ IO (STM RetirementState)
    -- ^ Request the release, once, and answer the backend's own reading of its retirement, which
    -- only reads. Never waits. What it raises is a cleanup failure: it is retained, the texture is
    -- never reported reclaimed, and release is not retried.
  }
