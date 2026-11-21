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
  , Allocated (..)
  , OwnerPorts (..)
  , ScheduleRefusal (..)
  , StepOutcome (..)
  , ConstructedDisposal (..)
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
  , ConstructedDisposal (..)
  , constructedDisposal
  , ImageFormat (Depth32Float)
  , VulkanAction (..)
  , VulkanHost (..)
  , readVulkanAction
  , readVulkanActionGate
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
import Hetoimasia.Render.TwoD.Vulkan.Chunks (BuildRefusal (..), BuildRefused (..), ChunkStanding, RefusedAllocation (..), buildRetainedChunkWith, chunkBufferOf, chunkStandingSTM, releaseChunkNow)
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMarks)
import Hetoimasia.Terrain.Render2D.Vulkan.Material (terrainMaterial)

-- | Why a chunk was not built: the staging buffer or its queue is full now (a later step can succeed), or a failure
-- no retry changes; each with what became of the vertex buffer the build made.
data BuildFailure
  = BuildBackpressure !Text !Allocated
  | BuildFailed !Text !Allocated

-- | What a refused build left of its vertex buffer: none was made; one was made and released, and a reading of its
-- physical destruction says when its capacity is free; or one whose release failed, or which is not known to be
-- released (a raised build), with the cause: its capacity stays charged.
data Allocated
  = NotAllocated
  | AllocatedDisposing (STM ConstructedDisposal)
  | AllocatedFailed !Text

-- | What one owner step may do on the owner's thread.
data Hands = Hands
  { handBuild ∷ [Instance] → [MaterialRecord] → IO (Either BuildFailure ChunkRef)
    -- ^ Build one chunk of a depth-enabled world layer: its instances (each naming the terrain material) and the
    -- records they index. A refusal says what became of the buffer it made ('Allocated').
  , handDispose ∷ ChunkRef → IO (Either Text (STM ConstructedDisposal))
    -- ^ Release a chunk's buffer and forget the chunk, answering a reading of the buffer's physical disposal: the
    -- backend destroys it once the batches that recorded it complete, and only then is it done. A chunk without a
    -- buffer is done at once.
  }

-- | Why the owner did not admit a step: its queue is full or its device is not ready (a later admission can
-- succeed), or it takes no more actions (its exit began, or its session failed), with the host's answer.
data ScheduleRefusal = ScheduleBusy | ScheduleEnded !Text
  deriving (Eq, Show)

-- | How an admitted step ended: it ran, the owner refused it before it ran (its exit began, its session failed), or it
-- raised.
data StepOutcome = StepRan | StepRefused !Text | StepRaised !Text
  deriving (Eq, Show)

-- | What the views use of the owner and its host from any thread: each a transaction that never waits.
data OwnerPorts = OwnerPorts
  { ownerSchedule ∷ (Hands → IO ()) → STM (Either ScheduleRefusal (STM (Maybe StepOutcome)))
    -- ^ Admit one owner action that runs this step with the owner's hands, answering a reading of how it ended
    -- ('Nothing' while it is queued or running).
  , ownerRelease ∷ STM () → STM (Either Text (STM (Maybe (Either Text ()))))
    -- ^ Ask the host's FIFO release lane for a barrier: the action runs, with this transaction, once every revision
    -- published before the request has been adopted. The reading is 'Nothing' while it waits, @Just (Right ())@ once
    -- met and @Just (Left why)@, with the host's answer, when the owner will never meet it. A full lane is a 'Left'.
  , ownerStanding ∷ ChunkRef → STM (Maybe ChunkStanding)
    -- ^ A chunk's upload: uploading, ready or failed; 'Nothing' for one never built or since released.
  , ownerMaterial ∷ !MaterialRef
    -- ^ The terrain material, registered with the session's renderer.
  , ownerRegionWindow ∷ !Word64
    -- ^ The renderer's storage window: the most bytes of clip tables and material records one batch binds.
  , ownerDepthQualified ∷ !Bool
    -- ^ Whether the session's depth format is @D32_SFLOAT@.
  , ownerEnded ∷ STM (Maybe Text)
    -- ^ Why the owner takes no more actions, once it does not: its session failed, or its exit began. What can no
    -- longer be disposed of ends with it as cause.
  }

-- | The capabilities over the running host and the composed graphics session.
productionOwner ∷ VulkanHost GraphicsScene → TextureGraphics → IO OwnerPorts
productionOwner host graphics = do
  material ← registerMaterial (graphicsRenderer graphics) terrainMaterial
  pure
    OwnerPorts
      { ownerSchedule = \step →
          submitVulkanAction host (VulkanAction (\construction → step (hands material construction))) >>= \case
            Left ActionQueueFull → pure (Left ScheduleBusy)
            Left ActionDeviceNotReady → pure (Left ScheduleBusy)
            Left refusal → pure (Left (ScheduleEnded (Text.pack (show refusal))))
            Right ticket →
              pure . Right $
                readVulkanAction ticket >>= \case
                  Nothing → pure Nothing
                  Just (ActionReturned ()) → pure (Just StepRan)
                  Just (ActionRefused why) → pure (Just (StepRefused (Text.pack (show why))))
                  Just (ActionRaised why) → pure (Just (StepRaised (Text.pack (show why))))
      , ownerRelease = \after →
          requestVulkanRelease host (VulkanAction (\_ → atomically after)) >>= \case
            Left refusal → pure (Left (Text.pack (refusalText refusal)))
            Right ticket →
              pure . Right $
                readVulkanAction ticket >>= \case
                  Nothing → pure Nothing
                  Just (ActionReturned ()) → pure (Just (Right ()))
                  Just (ActionRefused why) → pure (Just (Left ("the release lane refused the barrier: " <> Text.pack (show why))))
                  Just (ActionRaised why) → pure (Just (Left ("the barrier raised: " <> Text.pack (show why))))
      , ownerStanding = chunkStandingSTM retained
      , ownerMaterial = material
      , ownerRegionWindow = rendererRegionWindow (graphicsRenderer graphics)
      , ownerDepthQualified = rendererDepthFormat (graphicsRenderer graphics) == Just Depth32Float
      , ownerEnded = fmap (Text.pack . show) <$> readVulkanActionGate (vulkanController host)
      }
  where
    retained = graphicsRetained graphics
    hands ∷ MaterialRef → Construction q inst msgr phys dev cmd → Hands
    hands material construction =
      Hands
        { handBuild = \instances records → do
            marks ← registeredMarks (graphicsTextures graphics)
            guarded (buildRetainedChunkWith (hostBuilders host construction) retained marks ChunkWorldDepth DeriveBounds (Map.singleton material records) instances) >>= pure . \case
              -- raised past the renderer's own handling: whether a buffer was made is not known
              Left raised → Left (BuildFailed raised (AllocatedFailed ("the build raised: " <> raised)))
              Right (Left (BuildRefused refusal allocation)) →
                let allocated = case allocation of
                      NoAllocation → NotAllocated
                      AllocationReleased buffer (Right ()) → AllocatedDisposing (constructedDisposal construction buffer)
                      AllocationReleased _ (Left why) → AllocatedFailed ("the refused build's buffer could not be released: " <> Text.pack (show why))
                 in case refusal of
                      BuildUploadBackpressure pressure → Left (BuildBackpressure (Text.pack (show pressure)) allocated)
                      other → Left (BuildFailed (Text.pack (show other)) allocated)
              Right (Right chunk) → Right chunk
        , handDispose = \chunk → do
            -- the buffer, read before the release forgets the chunk, is what is physically disposed of later
            buffer ← chunkBufferOf retained chunk
            guarded (releaseChunkNow (hostBuilders host construction) retained chunk) >>= pure . \case
              Left raised → Left raised
              Right (Left refusal) → Left (Text.pack (show refusal))
              Right (Right ()) → Right (maybe (pure DisposalDone) (constructedDisposal construction) buffer)
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
