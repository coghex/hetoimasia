-- | The graphics owner as the terrain views reach it (TRA-9): what one owner step may do with its own hands, and
-- the narrow host capabilities the views use from any thread.
--
-- Every view step runs on the graphics owner's thread, inside one owner action ('Hetoimasia.GPU.Vulkan.GLFW.submitVulkanAction'),
-- between frames. That action lends 'Hands': build a chunk into the session's one retained registry, release a
-- chunk's buffer, read a chunk's upload. Outside a step the views only admit the next step, ask the host's release
-- lane for a barrier, and read the host's end; each is one transaction that never waits ('OwnerPorts').
--
-- The production capabilities ('productionOwner') are the host's own: no barrier, scene key, device, thread or
-- session of their own. A suite without a device injects its own, whose owner it steps itself.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Owner
  ( Hands (..)
  , BuildFailure (..)
  , OwnerPorts (..)
  , productionOwner
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (SomeAsyncException, displayException, fromException, throwIO, try)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , ActionRefusal (..)
  , Construction
  , ImageFormat (Depth32Float)
  , TerminalReport (..)
  , VulkanAction (..)
  , VulkanHost (..)
  , readVulkanAction
  , readVulkanTerminal
  , requestVulkanRelease
  , submitVulkanAction
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBuilders)
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (DeriveBounds), ChunkKind (ChunkWorldDepth), ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialRecord, MaterialRef)
import Hetoimasia.Render.TwoD.Snapshot (Instance)
import Hetoimasia.Render.TwoD.Vulkan (registerMaterial, rendererDepthFormat, rendererRegionWindow)
import Hetoimasia.Render.TwoD.Vulkan.Chunks (BuildRefusal (..), ChunkStanding, buildRetainedChunkWith, chunkStandingSTM, releaseChunkNow)
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMarks)
import Hetoimasia.Terrain.Render2D.Vulkan.Material (terrainMaterial)

-- | Why a chunk was not built: the staging buffer or its queue is full now (a later step can succeed), or a failure
-- no retry changes.
data BuildFailure
  = BuildBackpressure !Text
  | BuildFailed !Text
  deriving (Eq, Show)

-- | What one owner step may do on the owner's thread.
data Hands = Hands
  { handBuild ∷ [Instance] → [MaterialRecord] → IO (Either BuildFailure ChunkRef)
    -- ^ Build one chunk of a depth-enabled world layer: its instances (each naming the terrain material) and the
    -- records they index. A refusal holds nothing.
  , handDispose ∷ ChunkRef → IO (Either Text ())
    -- ^ Release a chunk's buffer and forget it. A buffer still read by a recorded batch is destroyed by the backend
    -- once that batch completes.
  }

-- | What the views use of the owner and its host from any thread: each a transaction that never waits.
data OwnerPorts = OwnerPorts
  { ownerSchedule ∷ (Hands → IO ()) → STM Bool
    -- ^ Admit one owner action that runs this step with the owner's hands; 'False' when the owner's queue refused
    -- it (full, not ready, closed).
  , ownerRelease ∷ STM () → STM (Either Text (STM (Maybe Bool)))
    -- ^ Ask the host's FIFO release lane for a barrier: the action runs, with this transaction, once every revision
    -- published before the request has been adopted. The reading is 'Nothing' while it waits, 'Just True' once
    -- met and 'Just False' when the owner will never meet it. A full lane is a 'Left'.
  , ownerStanding ∷ ChunkRef → STM (Maybe ChunkStanding)
    -- ^ A chunk's upload: uploading, ready or failed; 'Nothing' for one never built or since released.
  , ownerMaterial ∷ !MaterialRef
    -- ^ The terrain material, registered with the session's renderer.
  , ownerRegionWindow ∷ !Word64
    -- ^ The renderer's storage window: the most bytes of clip tables and material records one batch binds.
  , ownerDepthQualified ∷ !Bool
    -- ^ Whether the session's depth format is @D32_SFLOAT@.
  , ownerEnded ∷ STM (Maybe Text)
    -- ^ The owner's terminal failure, once it has one: what can no longer be disposed of ends with it as cause.
  }

-- | The capabilities over the running host and the composed graphics session.
productionOwner ∷ VulkanHost GraphicsScene → TextureGraphics → IO OwnerPorts
productionOwner host graphics = do
  material ← registerMaterial (graphicsRenderer graphics) terrainMaterial
  pure
    OwnerPorts
      { ownerSchedule = \step →
          submitVulkanAction host (VulkanAction (\construction → step (hands material construction))) >>= \case
            Right _ → pure True
            Left _ → pure False
      , ownerRelease = \after →
          requestVulkanRelease host (VulkanAction (\_ → atomically after)) >>= \case
            Left refusal → pure (Left (Text.pack (refusalText refusal)))
            Right ticket →
              pure . Right $
                readVulkanAction ticket >>= \case
                  Nothing → pure Nothing
                  Just (ActionReturned ()) → pure (Just True)
                  Just _ → pure (Just False)
      , ownerStanding = chunkStandingSTM retained
      , ownerMaterial = material
      , ownerRegionWindow = rendererRegionWindow (graphicsRenderer graphics)
      , ownerDepthQualified = rendererDepthFormat (graphicsRenderer graphics) == Just Depth32Float
      , ownerEnded = fmap (Text.pack . show) . reportPrimary <$> readVulkanTerminal (vulkanController host)
      }
  where
    retained = graphicsRetained graphics
    hands ∷ MaterialRef → Construction q inst msgr phys dev cmd → Hands
    hands material construction =
      Hands
        { handBuild = \instances records → do
            marks ← registeredMarks (graphicsTextures graphics)
            guarded (buildRetainedChunkWith (hostBuilders host construction) retained marks ChunkWorldDepth DeriveBounds (Map.singleton material records) instances) >>= pure . \case
              Left raised → Left (BuildFailed raised)
              Right (Left (BuildUploadBackpressure pressure)) → Left (BuildBackpressure (Text.pack (show pressure)))
              Right (Left refusal) → Left (BuildFailed (Text.pack (show refusal)))
              Right (Right chunk) → Right chunk
        , handDispose = \chunk →
            guarded (releaseChunkNow (hostBuilders host construction) retained chunk) >>= pure . \case
              Left raised → Left raised
              Right (Left refusal) → Left (Text.pack (show refusal))
              Right (Right ()) → Right ()
        }
    refusalText = \case
      ReleaseQueueFull → "the release lane is full"
      other → show other

-- A synchronous failure as its text; an asynchronous one goes on.
guarded ∷ IO a → IO (Either Text a)
guarded action =
  try action >>= \case
    Left failure | Just (_ ∷ SomeAsyncException) ← fromException failure → throwIO failure
    Left failure → pure (Left (Text.pack (displayException failure)))
    Right value → pure (Right value)
