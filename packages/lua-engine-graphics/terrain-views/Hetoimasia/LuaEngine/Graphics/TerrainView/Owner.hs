-- | The graphics owner as the terrain views reach it (TRA-9): what one owner step may do with its own hands, and
-- the narrow host capabilities the views use from any thread.
--
-- Every view step runs on the graphics owner's thread, inside one owner action ('Hetoimasia.GPU.Vulkan.GLFW.submitVulkanAction'),
-- between frames. That action lends 'Hands': prepare a chunk, reserve its admission into the session's one retained
-- registry and the host's uploads (spent once by its build, which makes the buffer only then), release a chunk's
-- buffer. Outside a step the views only admit the next step, ask the host's release lane for a barrier, observe a
-- part's admission and a chunk's upload, and read the host's end; each is one transaction that never waits
-- ('OwnerPorts').
--
-- The production capabilities ('productionOwner') are the host's own: no barrier, scene key, device, thread or
-- session of their own. A suite without a device injects its own, whose owner it steps itself.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Owner
  ( Hands (..)
  , Admission (..)
  , Grant (..)
  , Receipt (..)
  , BuildFailure (..)
  , Allocated (..)
  , OwnerPorts (..)
  , ScheduleRefusal (..)
  , StepOutcome (..)
  , ConstructedDisposal (..)
  , productionOwner
  , registryHands
  , registryRoom
  , viewAdmission
  , viewGrant
  , viewReceipt
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Monad (void)
import Control.Exception (SomeAsyncException, displayException, evaluate, fromException, throwIO, try)
import qualified Data.Map.Strict as Map
import Data.Functor ((<&>))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , ActionRefusal (..)
  , Buffer
  , Construction
  , ConstructedDisposal (..)
  , constructedDisposal
  , ImageFormat (Depth32Float)
  , UploadRefusal (UploadOversized)
  , VulkanAction (..)
  , VulkanHost (..)
  , readVulkanAction
  , readVulkanActionGate
  , requestVulkanRelease
  , submitVulkanAction
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBufferUploads, hostBuilders)
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (DeriveBounds), ChunkKind (ChunkWorldDepth), ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialRecord, MaterialRef)
import Hetoimasia.Render.TwoD.Snapshot (Instance)
import Hetoimasia.Render.TwoD.Vulkan (registerMaterial, rendererDepthFormat, rendererRegionWindow)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (bufferUploads), BufferUploads, roomFor)
import Hetoimasia.Render.TwoD.Vulkan.Chunks
  ( BuildRefusal (..)
  , BuildRefused (..)
  , ChunkGrant
  , ChunkStanding
  , PreparedChunk
  , RefusedAllocation (..)
  , Retained
  , abandonChunkGrant
  , admitRetainedChunk
  , chunkBufferOf
  , chunkGrantReceipt
  , claimReceipt
  , receiptNumber
  , receiptsHeld
  , sweepRegistry
  , chunkRoom
  , chunkStandingSTM
  , preparedBytes
  , prepareRetainedChunk
  , releaseChunkNow
  , spendChunkGrant
  )
import qualified Hetoimasia.Render.TwoD.Vulkan.Chunks as Chunks
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMarks)
import Hetoimasia.Terrain.Render2D.Vulkan.Material (terrainMaterial)

-- | Why a prepared part was not admitted: its room is taken for now (the uploads' queue or staging, or the registry's
-- references), and can come free; the part is larger than the whole staging buffer; or an end no wait changes (the
-- uploads closed, the session failed). A refused admission holds and made nothing.
data Admission
  = AdmitLater !Text
  | AdmitOversized !Text
  | AdmitNever !Text
  deriving (Eq, Show)

-- | A part's admission, granted in the owner's transaction together with the target's slot: its reference and its
-- upload's room. Spent once by its build ('grantSpend'), or given back unspent ('grantAbandon'). It lives within the
-- owner step that took it.
data Grant = Grant
  { grantSpend ∷ IO ()
    -- ^ Build the part. Whatever the exit, the outcome is sealed into the grant's receipt before this returns or its
    -- exception goes on.
  , grantAbandon ∷ STM ()
    -- ^ Give the grant back unspent, sealing its receipt as a refusal with no allocation.
  , grantReceipt ∷ !Receipt
  }

-- | Where a granted build's sealed outcome waits for one claimant: the view that collects it, or a sweep in its place.
data Receipt = Receipt
  { receiptKey ∷ !Word64
    -- ^ Unique among the registry's receipts.
  , receiptOutcome ∷ STM (Maybe (Either BuildFailure ChunkRef))
    -- ^ The build's sealed outcome, the one projection every reader uses: nothing while it is unsealed, then the
    -- outcome, before and after its claim.
  , receiptClaim ∷ STM (Maybe (Either BuildFailure ChunkRef))
    -- ^ Take the sealed outcome's ownership, once: nothing while it is unsealed or after another claimant took it.
  }

-- | Why a granted build failed, with what became of the vertex buffer it made.
data BuildFailure = BuildFailed !Text !Allocated

-- | What a failed build left of its vertex buffer: none was made; one was made and released (by the build's cleanup,
-- or by its construction before it raised), and a reading of its physical destruction says when its capacity is free;
-- or one whose release failed or raised, with the cause: its capacity stays charged.
data Allocated
  = NotAllocated
  | -- | The buffer's identity, and a reading of its physical destruction.
    AllocatedDisposing !Text (STM ConstructedDisposal)
  | -- | The cause, which names the buffer when it is known.
    AllocatedFailed !Text

-- | What one owner step may do on the owner's thread.
data Hands = Hands
  { handPrepare ∷ [Instance] → [MaterialRecord] → IO (Either Text PreparedChunk)
    -- ^ Prepare one chunk of a depth-enabled world layer: its instances (each naming the terrain material) and the
    -- records they index, routed and encoded, its exact upload bytes known. Nothing is reserved or made.
  , handReserve ∷ PreparedChunk → STM (Either Admission Grant)
    -- ^ Reserve a prepared chunk's reference and upload room, in the caller's transaction: the decision 'ownerRoom'
    -- observes.
  , handSweepReceipts ∷ STM [(Word64, Either BuildFailure ChunkRef)]
    -- ^ The registry's teardown sweep: claim every sealed receipt its collector has not, with its key, read as a view
    -- reads it.
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
  , ownerRoom ∷ PreparedChunk → STM (Either Admission ())
    -- ^ Whether a prepared chunk would be admitted now, read-only: the decision 'handReserve' makes.
  , ownerReceiptsHeld ∷ STM (Int, Int)
    -- ^ How many admitted builds' receipts the registry still holds unclaimed, and how many of those are sealed.
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
      , ownerRoom = registryRoom (hostBufferUploads host) retained
      , ownerReceiptsHeld = receiptsHeld retained
      , ownerEnded = fmap (Text.pack . show) <$> readVulkanActionGate (vulkanController host)
      }
  where
    retained = graphicsRetained graphics
    hands ∷ MaterialRef → Construction q inst msgr phys dev cmd → Hands
    hands material construction = registryHands prepare (constructedDisposal construction) (hostBuilders host construction) retained
      where
        prepare instances records = do
          marks ← registeredMarks (graphicsTextures graphics)
          -- evaluated here, on this step: the description and its encoded bytes are made now
          either (Left . Text.pack . show) Right <$> evaluate (prepareRetainedChunk marks ChunkWorldDepth DeriveBounds (Map.singleton material records) instances)
    refusalText = \case
      ReleaseQueueFull → "the release lane is full"
      other → show other

-- | The hands over a renderer's registry, its constructions (whose uploads a part's room is reserved in) and a reading
-- of a buffer's physical destruction, preparing parts as given: a part is admitted into the registry and the uploads
-- in the caller's transaction, its grant is the renderer's ('viewGrant'), the teardown sweep is the registry's, and a
-- chunk's release is the renderer's. The production hands are these over the host's.
registryHands
  ∷ ([Instance] → [MaterialRecord] → IO (Either Text PreparedChunk))
  → (Buffer → STM ConstructedDisposal)
  → Builders q inst msgr phys dev cmd
  → Retained
  → Hands
registryHands prepare disposal builders retained =
  Hands
    { handPrepare = prepare
    , handReserve = \prepared →
        admitRetainedChunk (bufferUploads builders) retained prepared <&> \case
          Left refusal → Left (viewAdmission refusal)
          Right grant → Right (viewGrant disposal builders retained grant)
    , handSweepReceipts = map (fmap (viewReceipt disposal)) <$> sweepRegistry retained
    , handDispose = \chunk → do
        -- the buffer, read before the release forgets the chunk, is what is physically disposed of later
        buffer ← chunkBufferOf retained chunk
        guarded (releaseChunkNow builders retained chunk) >>= pure . \case
          Left raised → Left raised
          Right (Left refusal) → Left (Text.pack (show refusal))
          Right (Right ()) → Right (maybe (pure DisposalDone) disposal buffer)
    }

-- | Whether a prepared part would be admitted into this registry and these uploads now, read-only: the decision
-- 'registryHands' makes.
registryRoom ∷ BufferUploads → Retained → PreparedChunk → STM (Either Admission ())
registryRoom uploads retained prepared = either (Left . viewAdmission) Right <$> chunkRoom (roomFor uploads) retained (preparedBytes prepared)

-- | What the renderer's admission refusal means to a view: room that can come free, a part no staging holds, or an end.
viewAdmission ∷ BuildRefusal → Admission
viewAdmission = \case
  BuildUploadBackpressure pressure → AdmitLater (Text.pack (show pressure))
  BuildReferencesExhausted → AdmitLater "every chunk reference is in use"
  BuildUploadsNotReady → AdmitLater "the host's uploads await its startup"
  BuildUploadsUnavailable cause → AdmitNever cause
  BuildUploadRefused (UploadOversized padded staging) → AdmitOversized ("a part needs " <> Text.pack (show padded) <> " staging bytes, and the staging buffer holds " <> Text.pack (show staging))
  refusal → AdmitNever (Text.pack (show refusal))

-- | A part's grant over the renderer's (the production adapter): its spend is the renderer's, its receipt the
-- renderer's read as a view reads it, and giving it back the renderer's.
viewGrant ∷ (Buffer → STM ConstructedDisposal) → Builders q inst msgr phys dev cmd → Retained → ChunkGrant → Grant
viewGrant disposal builders retained grant =
  Grant
    { grantSpend = void (spendChunkGrant builders retained grant)
    , grantAbandon = abandonChunkGrant retained grant
    , grantReceipt =
        Receipt
          { receiptKey = receiptNumber receipt
          , receiptOutcome = fmap (viewReceipt disposal) <$> Chunks.receiptOutcome receipt
          , receiptClaim = fmap (viewReceipt disposal) <$> claimReceipt receipt
          }
    }
  where
    receipt = chunkGrantReceipt grant

-- | A renderer's build receipt as a view reads it: the chunk, or the cause with what became of the buffer (its
-- identity, and the reading of its destruction or why its release failed).
viewReceipt ∷ (Buffer → STM ConstructedDisposal) → Either BuildRefused ChunkRef → Either BuildFailure ChunkRef
viewReceipt disposal = \case
  Right chunk → Right chunk
  Left (BuildRefused refusal allocation) →
    Left . BuildFailed (Text.pack (show refusal)) $ case allocation of
      NoAllocation → NotAllocated
      AllocationReleased buffer (Right ()) → AllocatedDisposing (Text.pack (show buffer)) (disposal buffer)
      AllocationReleased buffer (Left why) → AllocatedFailed ("the failed build's buffer " <> Text.pack (show buffer) <> " could not be released: " <> Text.pack (show why))
      AllocationReleaseRaised buffer why → AllocatedFailed ("the failed build's buffer " <> Text.pack (show buffer) <> " raised on its release: " <> why)

-- A synchronous failure as its text; an asynchronous one goes on.
guarded ∷ IO a → IO (Either Text a)
guarded action =
  try action >>= \case
    Left failure | Just (_ ∷ SomeAsyncException) ← fromException failure → throwIO failure
    Left failure → pure (Left (Text.pack (displayException failure)))
    Right value → pure (Right value)
