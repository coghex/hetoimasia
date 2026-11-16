-- | The graphics owner as a terrain view reaches it (TRA-9): the narrow capability to build and release retained
-- regions on the owner's thread, to ask the host's release barrier, and to read a region's upload.
--
-- The production capability ('productionViewOwner') is the host's own: chunks are built by owner actions over the
-- session's builders into the session's one retained registry, released the same way, and the barrier is the host's
-- release lane ('requestVulkanRelease'), which runs its action only once every revision published before the request
-- has been adopted. It adds no barrier, scene key, device or session of its own. A suite that has no device injects a
-- capability whose owner it controls.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Owner
  ( ViewOwner (..)
  , OwnerRefusal (..)
  , Answer (..)
  , Ticket
  , RegionBuild (..)
  , BuildFailure (..)
  , productionViewOwner
  ) where

import Control.Concurrent.STM (STM, catchSTM, retry, throwSTM)
import Control.Exception (Exception)
import Control.Monad (forM, forM_, void)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.GPU.Vulkan.GLFW (ActionOutcome (..), ActionRefusal (..), ImageFormat (Depth32Float), VulkanAction (..), VulkanHost, readVulkanAction, requestVulkanRelease, submitVulkanAction)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBuilders)
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (DeriveBounds), ChunkKind (ChunkWorldDepth), ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialRecord, MaterialRef)
import Hetoimasia.Render.TwoD.Snapshot (Instance)
import Hetoimasia.Render.TwoD.Vulkan (registerMaterial, rendererDepthFormat)
import Hetoimasia.Render.TwoD.Vulkan.Chunks (BuildRefusal (BuildUploadBackpressure), ChunkStanding, buildRetainedChunkWith, chunkStandingSTM, markChunkReleasedSTM, releaseChunkNow)
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMarks)
import Hetoimasia.Terrain.Render2D.Vulkan.Material (terrainMaterial)

-- | Why a build was refused: temporary pressure (the staging buffer or its queue full now, so asking again later can
-- succeed), or a failure no retry changes, which is kept as evidence.
data BuildFailure
  = BuildPressure !Text
  | BuildFailed !Text
  deriving (Eq, Show)

-- | One region to build: its instances (each naming the terrain material) and the records they index.
data RegionBuild = RegionBuild
  { buildInstances ∷ ![Instance]
  , buildRecords ∷ ![MaterialRecord]
  }

-- | Why the owner did not take an action now: its queue (or, for a barrier, its release lane) is full, which a later
-- step frees ('ownerRoom', 'ownerReleaseRoom' answer when), or it takes no more actions.
data OwnerRefusal = OwnerBusy | OwnerGone
  deriving (Eq, Show)

-- | How an action the owner took ended: it ran and answered, or it never ran or raised (the owner ended, its session
-- failed): a terminal failure, kept as evidence.
data Answer a = Answered !a | NotRun !Text
  deriving (Eq, Show)

-- | An admitted action's answer, read without waiting: 'Nothing' until it has one.
type Ticket a = STM (Maybe (Answer a))

-- | What a view may ask of the graphics owner. Every action is submitted in a transaction that never waits and answers
-- a ticket, so the adapter's worker never waits on the owner: it reads the ticket when it is ready.
data ViewOwner = ViewOwner
  { ownerMaterial ∷ !MaterialRef
    -- ^ The terrain material, registered with the session's renderer.
  , ownerDepthQualified ∷ !Bool
    -- ^ Whether the session's depth format is @D32_SFLOAT@, which the qualified cutout path needs.
  , ownerBuild ∷ [RegionBuild] → STM (Either OwnerRefusal (Ticket (Either BuildFailure [ChunkRef])))
    -- ^ Build these regions on the owner, in one action, each as one retained chunk of a depth-enabled world layer,
    -- answering their references in order. A refusal releases whatever the action built before it.
  , ownerRelease ∷ [ChunkRef] → STM (Either OwnerRefusal (Ticket [Either Text ()]))
    -- ^ Release these chunks' buffers on the owner: only chunks no revision lists or ever listed, or that no adoption
    -- holds behind a met barrier, and only once their upload has ended, so the release is never deferred and its answer
    -- proves the buffer gone.
  , ownerBarrier ∷ [ChunkRef] → STM (Either OwnerRefusal (STM (Maybe Bool)))
    -- ^ Mark these chunks released for publication's check and ask the host's release barrier, in one transaction that
    -- never waits: every revision published before the request must be adopted before it is met. The answer is a
    -- reading of the barrier ('Nothing' while it waits, 'Just True' once met, 'Just False' when the owner will never
    -- meet it).
  , ownerRoom ∷ STM Bool
    -- ^ Whether an action would be admitted now. It writes nothing; a transaction that waits on it wakes when the
    -- owner's queue changes.
  , ownerReleaseRoom ∷ STM Bool
    -- ^ The same for a release request on the host's release lane.
  , ownerStanding ∷ ChunkRef → STM (Maybe ChunkStanding)
    -- ^ A chunk's upload: uploading, ready or failed; 'Nothing' for one never built or since released.
  , ownerEnd ∷ STM ()
    -- ^ Completes once the owner takes no more actions (its admission closed or its session failed) and retries until
    -- then. It writes nothing.
  }

-- | The capability over the running host and the composed graphics session.
productionViewOwner ∷ VulkanHost GraphicsScene → TextureGraphics → IO ViewOwner
productionViewOwner host graphics = do
  material ← registerMaterial (graphicsRenderer graphics) terrainMaterial
  pure
    ViewOwner
      { ownerMaterial = material
      , ownerDepthQualified = rendererDepthFormat (graphicsRenderer graphics) == Just Depth32Float
      , ownerBuild = \regions → submit host $ VulkanAction $ \construction → do
          let builders = hostBuilders host construction
          marks ← registeredMarks (graphicsTextures graphics)
          let go acc [] = pure (Right (reverse acc))
              go acc (region : rest) =
                buildRetainedChunkWith builders retained marks ChunkWorldDepth DeriveBounds (Map.singleton material (buildRecords region)) (buildInstances region) >>= \case
                  Left why → do
                    forM_ acc (releaseChunkNow builders retained)
                    pure . Left $ case why of
                      BuildUploadBackpressure _ → BuildPressure (Text.pack (show why))
                      _ → BuildFailed (Text.pack (show why))
                  Right chunk → go (chunk : acc) rest
          go [] regions
      , ownerRelease = \chunks → submit host $ VulkanAction $ \construction → forM chunks (\chunk → either (Left . Text.pack . show) Right <$> releaseChunkNow (hostBuilders host construction) retained chunk)
      , ownerBarrier = \chunks →
          requestVulkanRelease host (VulkanAction (\_ → pure ())) >>= \case
            Left refusal → pure (Left (refusalOf refusal))
            Right ticket → do
              forM_ chunks (void . markChunkReleasedSTM retained)
              pure . Right $
                readVulkanAction ticket >>= \case
                  Nothing → pure Nothing
                  Just (ActionReturned ()) → pure (Just True)
                  Just _ → pure (Just False)
      , ownerRoom = probe (submitVulkanAction host (VulkanAction (\_ → pure ())))
      , ownerReleaseRoom = probe (requestVulkanRelease host (VulkanAction (\_ → pure ())))
      , ownerStanding = chunkStandingSTM retained
      , -- The host's own admission answers whether its owner still takes actions: a probe admitted while it does is
        -- rolled back by the retry, so nothing is queued, and the transaction wakes when the admission changes.
        ownerEnd =
          submitVulkanAction host (VulkanAction (\_ → pure ())) >>= \case
            Left (ActionSessionFailed _) → pure ()
            Left ActionOwnerClosed → pure ()
            _ → retry
      }
  where
    retained = graphicsRetained graphics

-- Submit one action without waiting: a refusal typed as busy (a full queue or lane, or a device not ready yet) or gone
-- (the owner closed, its session failed), or a ticket read without waiting.
submit ∷ VulkanHost scene → VulkanAction r → STM (Either OwnerRefusal (Ticket r))
submit host action =
  submitVulkanAction host action >>= \case
    Left refusal → pure (Left (refusalOf refusal))
    Right ticket →
      pure . Right $
        readVulkanAction ticket >>= \case
          Nothing → pure Nothing
          Just (ActionReturned value) → pure (Just (Answered value))
          Just other → pure (Just (NotRun (Text.pack (outcomeText other))))
  where
    outcomeText = \case
      ActionReturned _ → "returned"
      ActionRaised why → "raised: " <> show why
      ActionRefused why → "refused: " <> show why

refusalOf ∷ ActionRefusal → OwnerRefusal
refusalOf = \case
  ActionQueueFull → OwnerBusy
  ReleaseQueueFull → OwnerBusy
  ActionDeviceNotReady → OwnerBusy
  _ → OwnerGone

-- Whether a submission would be admitted now, written nowhere: the probe's admission is rolled back by the exception
-- that carries its answer out of the transaction, and a transaction that waits on the answer wakes when the queue does.
probe ∷ STM (Either ActionRefusal a) → STM Bool
probe admission = (admission >>= throwSTM . Probe . either (const False) (const True)) `catchSTM` \(Probe room) → pure room

newtype Probe = Probe Bool
  deriving (Show)

instance Exception Probe
