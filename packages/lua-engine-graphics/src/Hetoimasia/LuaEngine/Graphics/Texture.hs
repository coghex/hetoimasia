-- | The graphics adapter of the Lua-first engine's texture requests (LFE-17): a borrowed graphics
-- owner turned into the 'TextureBackend' the texture pipeline (LFE-16) is injected with.
--
-- = What it composes
--
-- 'withTextureGraphics' takes a /running/ 'VulkanHost' (the assembler's: this module starts no device, no
-- thread per texture and no window, and owns no graphics owner), checks that the host was built with the
-- configuration the M1 profile maps to ("Hetoimasia.LuaEngine.Graphics.Texture.Configuration"), makes on
-- the owner's thread the session's one renderer and texture registry, and runs a body over the backend
-- ("Hetoimasia.LuaEngine.Graphics.Texture.Backend") they feed. The renderer and the registry are exposed
-- /as the session's/: a scene adapter (LFE-20) records through them and registers nothing beside them, and
-- the table, which a session has only one of, is never made a second time.
--
-- A texture request settles with the pipeline's opaque identity and the source dimensions, only when its
-- upload has been observed complete and its registration observed to resolve to its own slot of a bound
-- table. That works with zero windows and zero frames: the progress it needs is the owner's own (upload
-- turns, frame-less batches, completion observation), and nothing in this adapter waits for a renderer
-- frame, Lua, a window or a peer instance.
--
-- = Ownership, in one place
--
-- * /The host and its owner/: the assembler's. This scope borrows them and must unwind inside them.
-- * /The renderer and the registry/: made by the bootstrap action, owned by the session's managed
--   resources; the registry's ledger is this scope's state, read by any thread.
-- * /A decoded level/: the pipeline's, charged to its lane, borrowed by the backend until the copy into
--   the owner's bounded staging ended; then the staging copy is the native accounting's until the upload
--   completes.
-- * /A native image/: the backend's from the owner action that made it (it is recorded in the job by that
--   very action), then the table's from its registration; it is destroyed by the owner once nothing holds
--   it. A delivered texture's release is the lease's, once, and its retirement is read from the table.
-- * /The pump/: one worker of the backend's scope.
module Hetoimasia.LuaEngine.Graphics.Texture
  ( -- * Composition
    TextureGraphics (..)
  , withTextureGraphics
  , TextureGraphicsRefused (..)

    -- * Configuration
  , module Hetoimasia.LuaEngine.Graphics.Texture.Configuration

    -- * Identities
  , textureHandleOf
  , textureIdentity

    -- * Observation
  , BackendReading (..)
  ) where

import Control.Concurrent.STM (STM)
import Control.Exception (Exception, ExceptionWithContext, SomeException, throwIO)
import Data.Word (Word64)
import Hetoimasia.GPU.Vulkan.GLFW (Image, TextureHandle (..), UploadTicket, VulkanHost, VulkanHostConfig)
import Hetoimasia.LuaEngine.Graphics.Scene.Configuration (SceneHostProblem, SceneSession (..), checkSceneHostConfig)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (SceneLedger)
import Hetoimasia.LuaEngine.Graphics.Scene.Render (RenderSession (..), fillRenderSlot)
import Hetoimasia.LuaEngine.Graphics.Texture.Backend
  ( BackendReading (..)
  , awaitBackendFailure
  , awaitBound
  , readBackend
  , textureBackend
  , withBackend
  )
import Hetoimasia.LuaEngine.Graphics.Texture.Configuration
import Hetoimasia.LuaEngine.Graphics.Texture.Host (BootstrapRefused, HostSession (..), bootstrapHost, hostPort)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (Port, TextureRef (..), textureIdentity, textureRefOf)
import Hetoimasia.LuaEngine.Texture.Backend (TextureBackend)
import qualified Hetoimasia.Render.Api.Texture as Api
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Textures (Textures, fromBackendHandle)

-- | The adapter, as a body sees it.
data TextureGraphics = TextureGraphics
  { graphicsBackend ∷ !TextureBackend
    -- ^ What the texture pipeline is injected with.
  , graphicsRenderer ∷ !Render.Renderer
    -- ^ The session's one renderer: the ring, the texture table, the storage table and the layout.
  , graphicsTextures ∷ !Textures
    -- ^ The session's one texture registry, whose handles the scene adapters name.
  , graphicsLedger ∷ !(SceneLedger WindowId)
    -- ^ What the adopted scene revisions hold: the release of a delivered texture is gated on it.
  , graphicsConfiguration ∷ !TextureGraphicsConfiguration
  , graphicsPort ∷ !(Port Image UploadTicket)
    -- ^ The adapter seam: the port the backend runs over, for a client that composes a further backend over
    -- the same session (a gated one, in a test) rather than making a second renderer or table.
  , graphicsReading ∷ STM BackendReading
  , graphicsFailure ∷ STM (ExceptionWithContext SomeException)
    -- ^ Retries until the backend has latched a failure of its own.
  }

-- | Why the adapter could not be composed. A structured startup or configuration failure, raised before
-- any texture work is admitted.
data TextureGraphicsRefused
  = -- | The host was not built with the configuration the profile maps to.
    HostConfigurationWrong ![HostProblem]
  | -- | The host was not built for per-window scenes ('configureScenes').
    SceneHostConfigurationWrong ![SceneHostProblem]
  | -- | The session could not be made on the host.
    SessionRefused !BootstrapRefused
  deriving (Eq, Show)

instance Exception TextureGraphicsRefused

-- | Compose the adapter over a borrowed host and run the body. On every exit the backend drains: every
-- accepted upload answers its terminal event and every texture it delivered is proved retired (or failed
-- to be) before the scope returns, and the host's own scopes may unwind only after.
withTextureGraphics ∷ SceneSession → TextureGraphicsConfiguration → VulkanHostConfig scene → VulkanHost scene → (TextureGraphics → IO r) → IO r
withTextureGraphics scenes configuration hostConfig host body =
  case (checkHostConfig configuration hostConfig, checkSceneHostConfig hostConfig) of
    (problems@(_ : _), _) → throwIO (HostConfigurationWrong problems)
    (_, problems@(_ : _)) → throwIO (SceneHostConfigurationWrong problems)
    ([], []) →
      bootstrapHost (configurationRenderer configuration) (scenesLedger scenes) host >>= \case
        Left refusal → throwIO (SessionRefused refusal)
        Right session →
          withBackend (hostPort host session) $ \backend → do
            -- The renderer hook finds the session's renderer here, filled before any window can exist.
            fillRenderSlot (scenesSlot scenes) (RenderSession (sessionRenderer session) (sessionTextures session))
            -- Composition ends when the table's placeholder is bound: texture work needs it, so it is
            -- asked for and waited for here, where a failure of the owner ends the assembly.
            awaitBound backend
            body
              TextureGraphics
                { graphicsBackend = textureBackend backend
                , graphicsRenderer = sessionRenderer session
                , graphicsTextures = sessionTextures session
                , graphicsLedger = sessionLedger session
                , graphicsConfiguration = configuration
                , graphicsPort = hostPort host session
                , graphicsReading = readBackend backend
                , graphicsFailure = awaitBackendFailure backend
                }

-- | The renderer's handle for the identity a texture was delivered with.
textureHandleOf ∷ Word64 → Api.TextureHandle
textureHandleOf identity =
  let TextureRef index generation = textureRefOf identity
   in fromBackendHandle (TextureHandle index generation)
