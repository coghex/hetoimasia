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
  , buildRegions
  , keepBuilt
  , releaseEach
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVar, readTVar)
import Control.Exception (SomeAsyncException, displayException, fromException, mask_, throwIO, try)
import Data.Maybe (fromMaybe)
import Data.Functor ((<&>))
import Control.Monad (forM_, void)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.GPU.Vulkan.GLFW (ActionOutcome (..), ActionRefusal (..), ImageFormat (Depth32Float), VulkanAction (..), VulkanHost, readVulkanAction, readVulkanUploadsSettled, requestVulkanRelease, submitVulkanAction, vulkanActionRoom, vulkanOwnerEnded, vulkanReleaseRoom)
import Numeric.Natural (Natural)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBuilders)
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (DeriveBounds), ChunkKind (ChunkWorldDepth), ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialRecord, MaterialRef)
import Hetoimasia.Render.TwoD.Snapshot (Instance)
import Hetoimasia.Render.TwoD.Vulkan (registerMaterial, rendererDepthFormat, rendererRegionWindow)
import Hetoimasia.Render.TwoD.Vulkan.Chunks (BuildRefusal (..), ChunkStanding, buildRetainedChunkWith, chunkStandingSTM, markChunkReleasedSTM, releaseChunkNow)
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMarks)
import Hetoimasia.Terrain.Render2D.Vulkan.Material (terrainMaterial)

-- | Why a build stopped: temporary pressure (the staging buffer or its queue full now, so asking again later can
-- succeed), or a failure no retry changes, which is kept as evidence. Each names the chunks the action built, in order,
-- before it stopped: they are the caller's to retire, since their uploads may still be running.
data BuildFailure
  = BuildPressure ![ChunkRef] !Text
  | BuildFailed ![ChunkRef] !Text
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
  , ownerRegionWindow ∷ STM Word64
    -- ^ The renderer's storage window: the most bytes of clip tables and material records one batch may bind. A
    -- candidate whose records cannot fit is never accepted.
  , ownerBuild ∷ [RegionBuild] → STM (Either OwnerRefusal (Ticket (Either BuildFailure [ChunkRef])))
    -- ^ Build these regions on the owner, in one action, each as one retained chunk of a depth-enabled world layer,
    -- answering their references in order. A region that cannot be built stops the action, and the failure names the
    -- chunks built before it: nothing is released here, so a chunk whose upload may still run is retired by the caller
    -- like any other.
  , ownerRelease ∷ [ChunkRef] → STM (Either OwnerRefusal (Ticket [Either Text ()]))
    -- ^ Release these chunks' buffers on the owner: only chunks no revision lists or ever listed, or that no adoption
    -- holds behind a met barrier, and only once their upload has ended, so the release is never deferred and its answer
    -- proves the buffer gone. Each chunk is answered on its own: one whose release raised is its own failure, and the
    -- chunks after it are still released.
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
  , ownerUploadsSettled ∷ STM Natural
    -- ^ How many of the session's uploads have settled: it only grows. A build refused as upload pressure is asked
    -- again once it moves past what it was when the build was submitted (one settled since, so the staging buffer or
    -- its queue has room again), even if that upload started after the submission. It writes nothing.
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
      , ownerRegionWindow = pure (rendererRegionWindow (graphicsRenderer graphics))
      , ownerBuild = \regions → do
          -- each chunk is recorded as it is made, so a build the owner's action ends by raising still hands back what
          -- it built ('keepBuilt')
          built ← newTVar []
          submitted ← submit host $ VulkanAction $ \construction → do
            let builders = hostBuilders host construction
            marks ← registeredMarks (graphicsTextures graphics)
            buildRegions
              (\region → buildRetainedChunkWith builders retained marks ChunkWorldDepth DeriveBounds (Map.singleton material (buildRecords region)) (buildInstances region))
              (\chunk → atomically (modifyTVar' built (chunk :)))
              regions
          pure (keepBuilt built <$> submitted)
      , ownerRelease = \chunks → submit host $ VulkanAction $ \construction → releaseEach (\chunk → either (Left . Text.pack . show) Right <$> releaseChunkNow (hostBuilders host construction) retained chunk) chunks
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
      , -- the host's own room projections: its gate, its device and its queue, never a scene or a target, so a wait on
        -- them wakes when room or the gate changes and at no other time
        ownerRoom = vulkanActionRoom host
      , ownerReleaseRoom = vulkanReleaseRoom host
      , ownerStanding = chunkStandingSTM retained
      , -- written only when an upload settles, never by an upload's progress
        ownerUploadsSettled = fromMaybe 0 <$> readVulkanUploadsSettled host
      , -- the host's gate alone: its owner closed or its session failed
        ownerEnd = vulkanOwnerEnded host >>= check
      }
  where
    retained = graphicsRetained graphics

-- | Build the regions in order, recording each chunk as it is made: a region that cannot be built stops the build,
-- naming the chunks made before it (upload backpressure as 'BuildPressure', anything else as 'BuildFailed'), and so
-- does a synchronous exception of the builder, as a failure. Nothing is released here: the chunks are the caller's.
buildRegions ∷ (RegionBuild → IO (Either BuildRefusal ChunkRef)) → (ChunkRef → IO ()) → [RegionBuild] → IO (Either BuildFailure [ChunkRef])
buildRegions build record = go []
  where
    go acc [] = pure (Right (reverse acc))
    -- a chunk's build and its record are one step no cancellation splits: a chunk the builder registered is always in
    -- the record 'keepBuilt' reads
    go acc (region : rest) =
      tryNonAsync (mask_ (build region >>= \built → built <$ either (const (pure ())) record built)) >>= \case
        Left raised → pure (Left (BuildFailed (reverse acc) ("the build raised: " <> Text.pack (displayException raised))))
        Right (Left why) →
          pure . Left $ case why of
            BuildUploadBackpressure _ → BuildPressure (reverse acc) (Text.pack (show why))
            _ → BuildFailed (reverse acc) (Text.pack (show why))
        Right (Right chunk) → go (chunk : acc) rest
    tryNonAsync action =
      try action >>= \case
        Left failure | Just (_ ∷ SomeAsyncException) ← fromException failure → throwIO failure
        result → pure result

-- | Release each chunk in order, answering each one's own outcome: a release that raises synchronously is that chunk's
-- failure, and the chunks after it are still released, since each release is independent of the others.
releaseEach ∷ (ChunkRef → IO (Either Text ())) → [ChunkRef] → IO [Either Text ()]
releaseEach release = mapM $ \chunk →
  try (release chunk) >>= \case
    Left failure | Just (_ ∷ SomeAsyncException) ← fromException failure → throwIO failure
    Left failure → pure (Left ("the release raised: " <> Text.pack (displayException failure)))
    Right outcome → pure outcome

-- | A build's ticket that keeps what was built: when the owner's action ended without answering (it raised, or the
-- owner ended), the chunks it recorded are answered as a failure naming them, for the caller to retire; with none, the
-- outcome stands.
keepBuilt ∷ TVar [ChunkRef] → Ticket (Either BuildFailure [ChunkRef]) → Ticket (Either BuildFailure [ChunkRef])
keepBuilt built ticket =
  ticket >>= \case
    Just (NotRun why) →
      readTVar built <&> \case
        [] → Just (NotRun why)
        chunks → Just (Answered (Left (BuildFailed (reverse chunks) ("the build did not answer: " <> why))))
    other → pure other

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

