-- | Managed rendering resources and the scoped recorder above the roots and
-- the generations (VK-11): the renderer-facing boundary of D-26, P-1 and
-- D-28.
--
-- A renderer never holds a native handle. It holds opaque managed handles —
-- a 'PipelineLayout', a 'Pipeline', a frame slot's 'FrameStorage', a
-- 'Readback' buffer — each naming one generation of one managed resource by
-- the GPU model's 'ResourceId', and it records through a 'Recorder' that
-- 'recordFrame' lends it for one consumer action. Every native call goes
-- through an open native layer, 'RecordingOps', whose production form is
-- "Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan"; the headless examples
-- supply a stand-in.
--
-- = Retention
--
-- Every recording operation first validates the calling thread, the handles
-- it names, the frame's generation and the recorder's state, and then
-- registers the exact resource generations it references — its own and the
-- transitive dependencies of the binding, such as a pipeline's layout — as
-- recorded references of the batch in the model ('extendBatch'), before the
-- native call that could capture them. A refusal at any of those steps makes
-- no native call. The union is taken per operation, so a subject used by
-- several commands, or reached through several bindings, is retained once. A
-- batch never looks a resource up again: a replacement published after
-- recording leaves the batch naming the generation it recorded, and a
-- released handle, or one whose generation was replaced, records nothing more.
--
-- = Batches
--
-- 'recordFrame' reserves one batch in the model against an acquired frame,
-- retaining the frame's swapchain generation and its frame slot's storage,
-- begins that storage's command buffer, runs the consumer exactly once, and
-- seals the batch. Each frame slot has one storage and one live batch at a
-- time. A consumer that raises, a cancellation, or rendering left open leaves
-- the batch partial: its commands and every reference it took stay owned, it
-- can never be submitted, and only 'discardBatch' or 'resetFrameRecorder'
-- ends it. Both invalidate the native commands first — the storage's pool is
-- reset — and only then discharge the batch's own references in the model; an
-- invalidation that raised retains everything, the session fails with
-- 'CleanupFailed', and 'BatchInvalidationFailed' is raised. Neither settles
-- any acquisition or presentation obligation of the frame.
--
-- = Release and destruction
--
-- 'releaseManaged' ends a handle's logical use and its CPU use in the model
-- together: nothing can record through it, or read it, again. Batches that
-- already recorded it are untouched. 'disposeResources' destroys, on the
-- owner's thread, every released generation the model reports every hold of
-- ended — never a pipeline layout while a pipeline built over it remains — and
-- records each disposal with the model; a destruction that raised is
-- uncertain, never retried, and fails the session.
--
-- = Readback
--
-- A readback buffer is host-visible memory, mapped once. 'copyToReadback'
-- records the copy of the frame's image — which its generation must have made
-- a transfer source, as only generations built for a verification capture do
-- ("Hetoimasia.GPU.Vulkan.Native.Generations.newGenerationsCapturing"), and
-- which must already be in the transfer-source layout — and after it a buffer
-- barrier from the transfer write to the host read. Bytes are exposed only
-- with completion evidence: the batch that wrote them was recorded as
-- submitted ('noteBatchSubmitted'), and the buffer owes no recorded reference
-- and no submitted use. Non-coherent memory is
-- invalidated over the atom-aligned range before it is read and flushed over
-- that range after 'fillReadback' writes it; 'mappedRange' is that range. A
-- write while any batch or submission holds the buffer is refused.
--
-- = State
--
-- +-------------------+-------------+------------------------------------+--------+-----------------------------+-----------------------------+
-- | State             | Owner       | Readers and writers                | Thread | Lifetime                    | Reset or disposal           |
-- +===================+=============+====================================+========+=============================+=============================+
-- | Managed records   | This module | Construction inserts; release,     | Owner  | Construction until the      | Removed once the model      |
-- |                   |             | replacement and disposal advance   |        | model records the disposal  | records it; kept uncertain  |
-- +-------------------+-------------+------------------------------------+--------+-----------------------------+-----------------------------+
-- | Frame storages    | This module | Construction inserts; disposal     | Owner  | As its managed record       | As its managed record       |
-- |                   |             | removes                            |        |                             |                             |
-- +-------------------+-------------+------------------------------------+--------+-----------------------------+-----------------------------+
-- | Batch records     | This module | 'recordFrame' inserts; discard and | Owner  | Recording until invalidated | Removed after the native    |
-- |                   |             | reset remove                       |        |                             | invalidation returned       |
-- +-------------------+-------------+------------------------------------+--------+-----------------------------+-----------------------------+
-- | A recorder        | Its         | The consumer, inside 'recordFrame' | Owner  | One consumer action         | Closed when the action ends |
-- |                   | 'recordFrame'|                                   |        |                             |                             |
-- +-------------------+-------------+------------------------------------+--------+-----------------------------+-----------------------------+
--
-- Every operation belongs to the thread that created the 'Recording' — the
-- graphics owner — and any other thread is refused with 'RefusedNotOwner'.
module Hetoimasia.GPU.Vulkan.Native.Recording
  ( -- * The native layer
    RecordingOps (..)
  , PipelineRequest (..)
  , PipelineShaders (..)
  , ReadbackAllocation (..)
  , NativeCommand (..)
  , ImageLayout (..)
  , ClearColor (..)
  , Viewport (..)
  , Rect (..)

    -- * The recording
  , Recording
  , newRecording
  , Refusal (..)

    -- * Managed resources
  , PipelineLayout
  , Pipeline
  , FrameStorage
  , Readback
  , Managed (managedResource)
  , createPipelineLayout
  , createPipeline
  , replacePipeline
  , createFrameStorage
  , createReadback
  , releaseManaged

    -- * Recording
  , Recorder
  , recorderBatch
  , recordFrame
  , transitionImage
  , supportedTransition
  , beginRendering
  , endRendering
  , bindPipeline
  , setViewport
  , setScissor
  , draw
  , copyToReadback
  , readbackBytesFor

    -- * Batches
  , discardBatch
  , resetFrameRecorder
  , noteBatchSubmitted

    -- * Readback
  , readReadback
  , fillReadback
  , mappedRange

    -- * Disposal
  , disposeResources
  , retireRecording

    -- * Observation
  , ManagedStanding (..)
  , ManagedView (..)
  , readManaged
  , BatchStanding (..)
  , BatchView (..)
  , readBatch
  , readBatches

    -- * Failures
  , BatchInvalidationFailed (..)
  , ResourceDestructionFailed (..)
  , ResourcesRetained (..)
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Applicative ((<|>))
import Control.Monad (forM, unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Foldable (for_)
import Data.Int (Int32)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64, Word8)
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model
  ( DisposalResult (..)
  , EvidenceSource (..)
  , FramePhase (..)
  , FrameView (..)
  , GpuModel
  , HoldKind (..)
  , HoldView (..)
  , Outcome (..)
  , SessionFailureCause (CleanupFailed)
  , TargetPhase (..)
  , TargetView (..)
  , TurnReport (..)
  , beginAllocation
  , modelBudgets
  , createResource
  , disposalEligible
  , endResourceCpuUse
  , extendBatch
  , frameView
  , holdView
  , rebuildResource
  , recordAllocationFailure
  , abandonAllocation
  , recordBatch
  , releaseResource
  , resetRecorder
  , runProgressTurn
  , silentEvidence
  , submissionCarries
  )
import qualified Hetoimasia.GPU.Model as Model
import Hetoimasia.GPU.Model.Budget (BudgetKind, frameSlotLimit)
import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , FrameSlotId
  , HoldSubject (..)
  , IdentityKind (..)
  , Misuse (..)
  , ResourceId
  , SubmissionId
  , TargetId
  , frameSlotNumber
  , frameTarget
  , generationTarget
  , imageGeneration
  , imageIndex
  , resourceSession
  , targetSession
  )
import Hetoimasia.GPU.Vulkan.Native.Generations (GenerationView (..), Generations, TargetGenerationsView (..), readTargetGenerations)
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent (..), SurfaceFormat (..), imageUsageTransferSource)
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( Roots
  , failRootsSession
  , readRootsDevice
  , rootsCall
  , rootsSessionIdentity
  , stateRootsModel
  )

-- ---------------------------------------------------------------------------
-- The native layer

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
  , opsCreatePipeline ∷ dev → PipelineRequest → IO Word64
    -- ^ Builds and destroys its own shader modules; the pipeline is the only
    -- thing it leaves.
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
  }

-- ---------------------------------------------------------------------------
-- Records

-- | Where one managed generation stands. It only advances.
data ManagedStanding
  = ManagedLive
  | ManagedReleased
    -- ^ Released and its CPU use ended: it records nothing more, and is
    -- destroyed once the model reports every hold ended.
  | ManagedReplaced !ResourceId
    -- ^ A newer generation was published; this one is released, as above.
  | ManagedDestroyedPending
    -- ^ Destroyed natively; the model has not yet recorded the disposal.
  | ManagedUncertain !Text
    -- ^ Its destruction raised. It is never attempted again.
  deriving (Eq, Show)

data NativeResource cmd
  = NativeLayout !Word64
  | NativePipeline !Word64 !ResourceId !Word32
    -- ^ The pipeline, the layout generation it was built over, and the color
    -- format it renders to.
  | NativeStorage !TargetId !Natural !Word64 !cmd
    -- ^ The target and frame slot it serves, its pool and its command buffer.
  | NativeReadback !ReadbackAllocation !ReadbackContents

-- | What a readback buffer's bytes are.
data ReadbackContents
  = ContentsUndefined
  | ContentsHostWritten
  | ContentsCopyRecorded !BatchId
    -- ^ A batch records a copy into it that no submission is known to carry.
  | ContentsCopySubmitted !SubmissionId
    -- ^ A submission carried the copying batch ('noteBatchSubmitted'); the
    -- bytes exist once it has completed. This outlives the batch's record.
  deriving (Eq, Show)

data ManagedRecord cmd = ManagedRecord
  { managedNative ∷ !(NativeResource cmd)
  , managedStanding ∷ !ManagedStanding
  }

-- | Where one batch stands in this module's own record.
data BatchStanding
  = BatchRecording
    -- ^ Its consumer is running.
  | BatchSealed
    -- ^ Recorded completely: submittable, or discardable.
  | BatchPartial !Text
    -- ^ Recording ended exceptionally, or unbalanced. Its commands and
    -- references stay owned; it can only be discarded.
  | BatchUncertain !Text
    -- ^ Resetting its storage raised. Everything is retained.
  | BatchSubmitted !SubmissionId
    -- ^ The model submitted it as this record ('noteBatchSubmitted'). It is
    -- never reset or discarded here again.
  deriving (Eq, Show)

data BatchRecord = BatchRecord
  { batchFrame ∷ !FrameSlotId
  , batchStorage ∷ !ResourceId
  , batchStanding ∷ !BatchStanding
  , batchCommands ∷ !Natural
    -- ^ How many commands reached the native layer.
  , batchReadbacks ∷ ![ResourceId]
  }

-- | The managed resources and batches of one session, over its roots and its
-- generations.
data Recording q inst msgr phys dev cmd = Recording
  { recordingOps ∷ !(RecordingOps dev cmd)
  , recordingRoots ∷ !(Roots q inst msgr phys dev)
  , recordingGenerations ∷ !(Generations q inst msgr phys dev)
  , recordingOwner ∷ !ThreadId
  , recordingManaged ∷ !(TVar (Map ResourceId (ManagedRecord cmd)))
  , recordingStorages ∷ !(TVar (Map (TargetId, Natural) ResourceId))
  , recordingBatches ∷ !(TVar (Map BatchId BatchRecord))
  }

-- | A recording over these roots and generations, owned by the calling
-- thread, which must be the graphics owner's.
newRecording
  ∷ RecordingOps dev cmd
  → Roots q inst msgr phys dev
  → Generations q inst msgr phys dev
  → IO (Recording q inst msgr phys dev cmd)
newRecording ops roots generations = do
  thread ← myThreadId
  Recording ops roots generations thread <$> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO Map.empty

-- | Why an operation made no native call.
data Refusal
  = RefusedNotOwner
    -- ^ Called from a thread other than the graphics owner's.
  | RefusedDeviceAbsent
  | RefusedMisuse !Misuse
    -- ^ A foreign, unknown, stale, consumed or duplicated identity, or one in
    -- the wrong phase: released, replaced, or a frame not acquired.
  | RefusedBackpressure !BudgetKind
  | RefusedRecorderClosed
    -- ^ The recorder was used after its consumer action ended.
  | RefusedIllegal !Text
    -- ^ The recorder's state does not admit the command.
  | RefusedUnsupported !Text
    -- ^ The command is outside the supported vocabulary.
  | RefusedNoStorage
    -- ^ The frame's slot has no live storage to record into.
  | RefusedIncompatible !Text
  | RefusedOutOfBounds !Natural !Natural
    -- ^ What was asked for, and what there is.
  | RefusedNotWritten !Text
    -- ^ No completion evidence exposes the bytes.
  | RefusedInUse
    -- ^ A batch or a submission still holds what would be changed in place.
  | RefusedWrongKind
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Handles

newtype PipelineLayout = PipelineLayout ResourceId
  deriving (Eq, Ord, Show)

newtype Pipeline = Pipeline ResourceId
  deriving (Eq, Ord, Show)

newtype FrameStorage = FrameStorage ResourceId
  deriving (Eq, Ord, Show)

newtype Readback = Readback ResourceId
  deriving (Eq, Ord, Show)

-- | A managed handle: the one generation of one managed resource it names.
class Managed handle where
  managedResource ∷ handle → ResourceId

instance Managed PipelineLayout where
  managedResource (PipelineLayout resource) = resource

instance Managed Pipeline where
  managedResource (Pipeline resource) = resource

instance Managed FrameStorage where
  managedResource (FrameStorage resource) = resource

instance Managed Readback where
  managedResource (Readback resource) = resource

-- ---------------------------------------------------------------------------
-- Failures

-- | Resetting a batch's storage raised. The batch, its commands and every
-- reference it took are retained, and the session has failed.
data BatchInvalidationFailed = BatchInvalidationFailed ![BatchId] !Text
  deriving (Eq, Show)

instance Exception BatchInvalidationFailed where
  displayException (BatchInvalidationFailed batches reason) =
    "invalidating the recorded commands of " <> show batches <> " did not complete: " <> Text.unpack reason

-- | A managed resource's destruction raised. It is retained, never attempted
-- again, and the session has failed with 'CleanupFailed'.
data ResourceDestructionFailed = ResourceDestructionFailed !ResourceId !Text
  deriving (Eq, Show)

instance Exception ResourceDestructionFailed where
  displayException (ResourceDestructionFailed resource reason) =
    "destroying " <> show resource <> " did not complete: " <> Text.unpack reason

-- | Retirement found managed resources it could not destroy: holds that have
-- not ended, or a destruction that was uncertain. They, and the device above
-- them, are retained.
newtype ResourcesRetained = ResourcesRetained [ResourceId]
  deriving (Eq, Show)

instance Exception ResourcesRetained where
  displayException (ResourcesRetained retained) = "managed resources are retained: " <> show retained

-- ---------------------------------------------------------------------------
-- Construction

-- | A pipeline layout with no descriptor sets and no push constants.
createPipelineLayout ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal PipelineLayout)
createPipelineLayout recording =
  fmap PipelineLayout
    <$> construct recording 0 1 "vkCreatePipelineLayout" (\ops device → NativeLayout <$> opsCreatePipelineLayout ops device) Nothing

-- | A graphics pipeline over the layout, rendering to the color format. The
-- layout must be live; the pipeline depends on that exact generation, which
-- every batch binding the pipeline retains with it.
createPipeline
  ∷ Recording q inst msgr phys dev cmd → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
createPipeline recording layout shaders format = buildPipeline recording layout shaders format Nothing

-- | Publish a new generation of a pipeline, over the given layout. The old
-- generation is released: nothing records it again, and every batch that
-- recorded it keeps it, and its layout, until the batch's references end.
replacePipeline
  ∷ Recording q inst msgr phys dev cmd → Pipeline → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
replacePipeline recording (Pipeline old) layout shaders format = buildPipeline recording layout shaders format (Just old)

buildPipeline
  ∷ Recording q inst msgr phys dev cmd
  → PipelineLayout
  → PipelineShaders
  → Word32
  → Maybe ResourceId
  → IO (Either Refusal Pipeline)
buildPipeline recording (PipelineLayout layout) shaders format replacing =
  liveNative recording layout >>= \case
    Left refusal → pure (Left refusal)
    Right (NativeLayout handle) →
      fmap Pipeline
        <$> construct
          recording
          0
          1
          "vkCreateGraphicsPipelines"
          (\ops device → (\created → NativePipeline created layout format) <$> opsCreatePipeline ops device (PipelineRequest handle shaders format))
          replacing
    Right _ → pure (Left RefusedWrongKind)

-- | A frame slot's command storage: a pool on the session's queue family and
-- its one primary command buffer. A slot has at most one; 'recordFrame'
-- records every frame of that slot into it.
--
-- The target must be one of this session's, still admitted or suspended, and
-- the slot one its frame budget can issue; anything else is refused before
-- any native call.
createFrameStorage ∷ Recording q inst msgr phys dev cmd → TargetId → Natural → IO (Either Refusal FrameStorage)
createFrameStorage recording target slot = do
  existing ← Map.lookup (target, slot) <$> readTVarIO (recordingStorages recording)
  model ← atomically (stateRootsModel (recordingRoots recording) (\current → (current, current)))
  let limit = frameSlotLimit (modelBudgets model)
      unusable = case Model.targetView target model of
        _ | targetSession target /= rootsSessionIdentity (recordingRoots recording) → Just (RefusedMisuse (ForeignIdentity TargetIdentity))
        Nothing → Just (RefusedMisuse (StaleIdentity TargetIdentity))
        Just view
          | viewTargetPhase view `notElem` [TargetAdmitted, TargetSuspended] → Just (RefusedMisuse (WrongPhase TargetIdentity))
          | slot >= limit → Just (RefusedOutOfBounds slot limit)
          | otherwise → Nothing
  case (existing, unusable) of
    (_, Just refused) → pure (Left refused)
    (Just _, _) → pure (Left (RefusedMisuse (DuplicateSubject FrameIdentity)))
    (Nothing, Nothing) → do
      family ← fmap (planQueueFamily . fst) <$> atomically (readRootsDevice (recordingRoots recording))
      case family of
        Nothing → pure (Left RefusedDeviceAbsent)
        Just queueFamily → do
          made ←
            construct
              recording
              0
              2
              "vkCreateCommandPool"
              (\ops device → (\(pool, commands) → NativeStorage target slot pool commands) <$> opsCreateStorage ops device queueFamily)
              Nothing
          for_ made (\resource → atomically (modifyTVar' (recordingStorages recording) (Map.insert (target, slot) resource)))
          pure (FrameStorage <$> made)

-- | A host-visible readback buffer of this many bytes, mapped for its
-- lifetime. 'readbackBytesFor' is what one frame's copy needs.
createReadback ∷ Recording q inst msgr phys dev cmd → Natural → IO (Either Refusal Readback)
createReadback recording bytes
  | bytes == 0 = pure (Left (RefusedOutOfBounds 0 0))
  | otherwise =
      fmap Readback
        <$> construct
          recording
          bytes
          2
          "vkCreateBuffer"
          (\ops device → (\allocation → NativeReadback allocation ContentsUndefined) <$> opsCreateReadback ops device bytes)
          Nothing

-- | Reserve the accounting, make the native object, and turn the reservation
-- into a managed generation — or into a new generation of the one being
-- replaced — in one masked step. A creation that raised created nothing: its
-- reservation is given back, and the failure is re-raised.
construct
  ∷ Recording q inst msgr phys dev cmd
  → Natural
  → Natural
  → Text
  → (RecordingOps dev cmd → dev → IO (NativeResource cmd))
  → Maybe ResourceId
  → IO (Either Refusal ResourceId)
construct recording bytes objects name create replacing =
  owned recording $
    atomically (readRootsDevice roots) >>= \case
      Nothing → pure (Left RefusedDeviceAbsent)
      Just (_, device) → do
        -- A replacement's predecessor must still be this module's current,
        -- live generation; the model checks the same before rebuilding.
        predecessor ← case replacing of
          Nothing → pure (Right ())
          Just old → fmap (const ()) <$> liveNative recording old
        case predecessor of
          Left refusal → pure (Left refusal)
          Right () → mask_ $ do
            reserved ← atomically (modelAnswer roots (beginAllocation bytes objects))
            case reserved of
              Left refusal → pure (Left refusal)
              Right allocation →
                tryWithContext @SomeException (rootsCall roots name (create (recordingOps recording) device)) >>= \case
                  Left failure → do
                    atomically $ do
                      modelEdit roots (recordAllocationFailure allocation)
                      modelEdit roots (abandonAllocation allocation)
                    rethrowIO failure
                  Right native → do
                    committed ← atomically $ do
                      answer ← case replacing of
                        Nothing → modelAnswer roots (createResource allocation)
                        Just old → modelAnswer roots (rebuildResource old allocation)
                      case answer of
                        Right resource → do
                          modifyTVar' (recordingManaged recording) (Map.insert resource (ManagedRecord native ManagedLive))
                          for_ replacing $ \old → do
                            -- The rebuild released the old generation; its CPU
                            -- use ends with it, since no handle may record it.
                            modelEdit roots (endResourceCpuUse old)
                            editManaged recording old (\entry → entry {managedStanding = ManagedReplaced resource})
                          pure (Right resource)
                        Left refusal → do
                          modelEdit roots (abandonAllocation allocation)
                          pure (Left refusal)
                    case committed of
                      Right resource → pure (Right resource)
                      Left refusal → do
                        -- The model refused to record what now exists, so
                        -- nothing can reference it: destroy it at once.
                        destroyNative recording device native
                        pure (Left refusal)
  where
    roots = recordingRoots recording

-- | Release a handle: nothing records through it again, and its CPU use —
-- reading a readback included — ends with it. Batches that already recorded
-- it keep it until their own references end.
releaseManaged ∷ Managed handle ⇒ Recording q inst msgr phys dev cmd → handle → IO (Either Refusal ())
releaseManaged recording handle =
  owned recording $
    liveNative recording resource >>= \case
      Left refusal → pure (Left refusal)
      Right _ → atomically $ do
        released ← modelAnswer roots (fmap (\next → (next, ())) . releaseResource resource)
        case released of
          Left refusal → pure (Left refusal)
          Right () → do
            modelEdit roots (endResourceCpuUse resource)
            editManaged recording resource (\entry → entry {managedStanding = ManagedReleased})
            pure (Right ())
  where
    resource = managedResource handle
    roots = recordingRoots recording

-- ---------------------------------------------------------------------------
-- Recording

data RecorderState = RecorderState
  { stateLayout ∷ !ImageLayout
  , stateRendering ∷ !Bool
  , statePipeline ∷ !(Maybe ResourceId)
  , stateViewport ∷ !Bool
  , stateScissor ∷ !Bool
  }

-- | The frame a recorder renders into, as the generation that owns its image
-- describes it.
data FrameImage = FrameImage
  { frameImageHandle ∷ !Word64
  , frameImageView ∷ !Word64
  , frameImageExtent ∷ !SurfaceExtent
  , frameImageFormat ∷ !Word32
  , frameImageCapturable ∷ !Bool
    -- ^ Whether its generation made it a transfer source.
  }

-- | A recorder lent to one consumer action. Every command checks that the
-- action is still running; one kept past it records nothing.
data Recorder q inst msgr phys dev cmd = Recorder
  { recorderRecording ∷ !(Recording q inst msgr phys dev cmd)
  , recorderBatch ∷ !BatchId
    -- ^ The batch this recorder records into.
  , recorderCommands ∷ !cmd
  , recorderFrame ∷ !FrameImage
  , recorderOpen ∷ !(IORef Bool)
  , recorderState ∷ !(IORef RecorderState)
  }

-- | Record one batch for an acquired frame, running the consumer exactly once
-- with a recorder that is closed when it returns or raises.
--
-- Before anything native, the frame must be acquired in the model, with its
-- image's generation still recordable; its slot must have a live storage with
-- no batch of its own outstanding; and the model must admit the batch, which
-- reserves its record and retains the frame's generation and the storage. The
-- batch is sealed only if the consumer returns with rendering ended; otherwise
-- it is left partial and owned, and whatever the consumer raised is re-raised.
recordFrame
  ∷ Recording q inst msgr phys dev cmd
  → FrameSlotId
  → (Recorder q inst msgr phys dev cmd → IO a)
  → IO (Either Refusal (BatchId, a))
recordFrame recording frame consumer =
  owned recording $
    -- The frame is checked before anything is done for its slot: a stale or
    -- foreign frame must fail before the slot's storage is touched.
    (atomically (frameAcquired recording frame) >>= \case
      Left refusal → pure (Left refusal)
      Right () → retireCompleted recording frame) >>= \case
      Left refusal → pure (Left refusal)
      Right () →
        checkFrame recording frame >>= \case
          Left refusal → pure (Left refusal)
          Right (storage, commands, image) → mask $ \restore → do
            admitted ← atomically $ do
              answer ← modelAnswer roots (recordBatch frame [storage])
              for_ answer $ \batch →
                modifyTVar' (recordingBatches recording) (Map.insert batch (BatchRecord frame storage BatchRecording 0 []))
              pure answer
            case admitted of
              Left refusal → pure (Left refusal)
              Right batch → do
                opened ← newIORef True
                state ← newIORef (RecorderState LayoutUndefined False Nothing False False)
                let recorder = Recorder recording batch commands image opened state
                    partial reason = atomically (editBatch recording batch (\entry → entry {batchStanding = BatchPartial reason}))
                began ← tryWithContext @SomeException (rootsCall roots "vkBeginCommandBuffer" (opsBeginCommands (recordingOps recording) commands))
                case began of
                  Left failure@(ExceptionWithContext _ exception) → do
                    writeIORef opened False
                    partial ("beginning the command buffer raised: " <> Text.pack (displayException exception))
                    rethrowIO failure
                  Right () → do
                    ran ← tryWithContext @SomeException (restore (consumer recorder))
                    writeIORef opened False
                    case ran of
                      Left failure@(ExceptionWithContext _ exception) → do
                        -- A command that failed has already said why the batch
                        -- is partial; that reason stands.
                        standing ← atomically (fmap batchStanding . Map.lookup batch <$> readTVar (recordingBatches recording))
                        when (standing == Just BatchRecording) $
                          partial
                            ( (if isAsynchronous exception then "a cancellation ended the consumer: " else "the consumer raised: ")
                                <> Text.pack (displayException exception)
                            )
                        rethrowIO failure
                      Right value → do
                        rendering ← stateRendering <$> readIORef state
                        standing ← atomically (fmap batchStanding . Map.lookup batch <$> readTVar (recordingBatches recording))
                        if standing /= Just BatchRecording
                          then pure (Left (RefusedIllegal "a command failed during recording, so the batch was not sealed"))
                          else if rendering
                          then do
                            partial "the consumer left rendering open"
                            pure (Left (RefusedIllegal "the consumer left rendering open, so the batch was not sealed"))
                          else
                            tryWithContext @SomeException (rootsCall roots "vkEndCommandBuffer" (opsEndCommands (recordingOps recording) commands)) >>= \case
                              Left failure@(ExceptionWithContext _ exception) → do
                                partial ("ending the command buffer raised: " <> Text.pack (displayException exception))
                                rethrowIO failure
                              Right () → do
                                atomically (editBatch recording batch (\entry → entry {batchStanding = BatchSealed}))
                                pure (Right (batch, value))
  where
    roots = recordingRoots recording

-- | Free the frame's slot of batches whose submission has completed. A
-- submitted batch keeps its record, and its storage, until the submission
-- that carried it completes — its commands may be executing until then — and
-- the model answers that the submission is no longer outstanding only once it
-- has. Then the storage is reset, which invalidates the executed commands so
-- the buffer can be begun again, and the record goes. A readback the batch
-- copied into keeps its own evidence ('ContentsCopySubmitted').
retireCompleted ∷ Recording q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal ())
retireCompleted recording frame = do
  (storage, completed) ← atomically $ do
    model ← stateRootsModel roots (\current → (current, current))
    batches ← Map.toList <$> readTVar (recordingBatches recording)
    managed ← readTVar (recordingManaged recording)
    -- Only a live storage is reset: a released one is refused by 'checkFrame'
    -- before anything native happens, and its completed batches go when it is
    -- destroyed.
    storage ←
      (\slot → slot >>= \resource → case managedStanding <$> Map.lookup resource managed of
          Just ManagedLive → Just resource
          _ → Nothing)
        . Map.lookup (frameTarget frame, frameSlotNumber frame)
        <$> readTVar (recordingStorages recording)
    pure
      ( storage
      , [ batch
        | (batch, record) ← batches
        , Just (batchStorage record) == storage
        , BatchSubmitted submission ← [batchStanding record]
        , submissionCarries submission batch model == Nothing
        ]
      )
  case (storage, completed) of
    (Just resource, _ : _) → invalidate recording resource completed Admitted
    _ → pure (Right ())
  where
    roots = recordingRoots recording

-- | Whether the model holds this frame acquired: its identity resolves —
-- this session's, this slot's current use — and it has an image. Any other
-- answer is the model's own classification of the misuse.
frameAcquired ∷ Recording q inst msgr phys dev cmd → FrameSlotId → STM (Either Refusal ())
frameAcquired recording frame = do
  model ← stateRootsModel (recordingRoots recording) (\model → (model, model))
  pure $ case frameView frame model of
    Nothing → Left (RefusedMisuse (case recordBatch frame [] model of
      Rejected misuse → misuse
      _ → UnknownIdentity FrameIdentity))
    Just view
      | viewFramePhase view /= FrameAcquired → Left (RefusedMisuse (WrongPhase FrameIdentity))
      | otherwise → Right ()

-- | Everything 'recordFrame' checks before it asks the model for a batch.
checkFrame
  ∷ Recording q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal (ResourceId, cmd, FrameImage))
checkFrame recording frame = atomically $ do
  model ← stateRootsModel roots (\model → (model, model))
  case frameView frame model of
    Nothing → pure (Left (RefusedMisuse (misuseOf model)))
    Just view
      | viewFramePhase view /= FrameAcquired → pure (Left (RefusedMisuse (WrongPhase FrameIdentity)))
      | otherwise → case viewFrameImage view of
          Nothing → pure (Left (RefusedMisuse (WrongPhase FrameIdentity)))
          Just image → do
            storages ← readTVar (recordingStorages recording)
            managed ← readTVar (recordingManaged recording)
            batches ← readTVar (recordingBatches recording)
            generations ← readTargetGenerations (recordingGenerations recording) (generationTarget (imageGeneration image))
            let located = do
                  storage ← maybe (Left RefusedNoStorage) Right (Map.lookup (frameTarget frame, frameSlotNumber frame) storages)
                  commands ← case Map.lookup storage managed of
                    Just (ManagedRecord (NativeStorage _ _ _ commands) ManagedLive) → Right commands
                    _ → Left RefusedNoStorage
                  -- One storage, one outstanding batch: the slot's previous
                  -- batch must be discarded or reset first.
                  when (any ((== storage) . batchStorage) (Map.elems batches)) $
                    Left (RefusedMisuse (DuplicateSubject FrameIdentity))
                  native ← maybe (Left (RefusedMisuse (StaleIdentity GenerationIdentity))) Right $ do
                    targetView ← generations
                    generation ← lookup (imageGeneration image) [(viewGeneration each, each) | each ← viewGenerations targetView]
                    let index = fromIntegral (imageIndex image)
                    handle ← nth index (viewImages generation)
                    imageView ← nth index (viewImageViews generation)
                    let plan = viewPlan generation
                    pure (FrameImage handle imageView (planExtent plan) (surfaceFormat (planFormat plan)) (planUsage plan .&. imageUsageTransferSource /= 0))
                  pure (storage, commands, native)
            pure located
  where
    roots = recordingRoots recording
    -- The model's own classification of a frame it cannot resolve: asking it
    -- to record against the frame, and keeping only the refusal, changes
    -- nothing.
    misuseOf model = case recordBatch frame [] model of
      Rejected misuse → misuse
      _ → UnknownIdentity FrameIdentity
    nth index list = case drop index list of
      entry : _ | index >= 0 → Just entry
      _ → Nothing

-- | Run one command: check the recorder is open and on the owner's thread,
-- decide the command against the recorder's state and the handles it names,
-- retain what it references in the model, and only then record it. The
-- retention and the native call are one masked step, so a cancellation can
-- land only before the first or after the second.
command
  ∷ Recorder q inst msgr phys dev cmd
  → (RecorderState → Either Refusal (RecorderState, [ResourceId], NativeCommand))
  → IO (Either Refusal ())
command recorder decide =
  owned recording $
    readIORef (recorderOpen recorder) >>= \case
      False → pure (Left RefusedRecorderClosed)
      True → do
        state ← readIORef (recorderState recorder)
        case decide state of
          Left refusal → pure (Left refusal)
          Right (next, references, native) → mask_ $ do
            retained ←
              if null references
                then pure (Right ())
                else atomically (modelAnswer roots (fmap (\model → (model, ())) . extendBatch batch (unique references)))
            case retained of
              Left refusal → pure (Left refusal)
              Right () →
                tryWithContext @SomeException (rootsCall roots (nativeName native) (opsRecord (recordingOps recording) (recorderCommands recorder) native)) >>= \case
                  -- The command may or may not have reached the buffer, so the
                  -- batch can never be sealed: it is partial, the recorder
                  -- records nothing more, and a consumer that catches this
                  -- cannot change either.
                  Left failure@(ExceptionWithContext _ exception) → do
                    writeIORef (recorderOpen recorder) False
                    atomically $
                      editBatch recording batch $ \entry →
                        entry {batchStanding = BatchPartial (nativeName native <> " raised: " <> Text.pack (displayException exception))}
                    rethrowIO failure
                  Right () → do
                    atomically (editBatch recording batch (\entry → entry {batchCommands = batchCommands entry + 1}))
                    writeIORef (recorderState recorder) next
                    pure (Right ())
  where
    recording = recorderRecording recorder
    roots = recordingRoots recording
    batch = recorderBatch recorder
    unique = Map.keys . Map.fromList . map (\resource → (resource, ()))

-- | Move the frame's image from one layout to another. The recorder tracks
-- the image's layout, so the one it leaves must be the one it is in; only the
-- transitions 'supportedTransition' names are supported, and none inside
-- rendering.
transitionImage ∷ Recorder q inst msgr phys dev cmd → ImageLayout → ImageLayout → IO (Either Refusal ())
transitionImage recorder from to = command recorder $ \state →
  if not (supportedTransition from to)
    then Left (RefusedUnsupported ("the image transition " <> tshow from <> " to " <> tshow to))
    else
      if stateRendering state
        then Left (RefusedIllegal "an image transition inside rendering")
        else
          if stateLayout state /= from
            then Left (RefusedIllegal ("the image is " <> tshow (stateLayout state) <> ", not " <> tshow from))
            else Right (state {stateLayout = to}, [], CommandImageBarrier (frameImageHandle (recorderFrame recorder)) from to)

-- | Begin dynamic rendering into the frame's image view, cleared to the
-- color, across the whole extent. The image must be a color attachment.
beginRendering ∷ Recorder q inst msgr phys dev cmd → ClearColor → IO (Either Refusal ())
beginRendering recorder clear = command recorder $ \state →
  if stateRendering state
    then Left (RefusedIllegal "rendering has already begun")
    else
      if stateLayout state /= LayoutColorAttachment
        then Left (RefusedIllegal ("rendering into an image that is " <> tshow (stateLayout state)))
        else
          let frame = recorderFrame recorder
           in Right (state {stateRendering = True}, [], CommandBeginRendering (frameImageView frame) (frameImageExtent frame) clear)

endRendering ∷ Recorder q inst msgr phys dev cmd → IO (Either Refusal ())
endRendering recorder = command recorder $ \state →
  if not (stateRendering state)
    then Left (RefusedIllegal "ending rendering that has not begun")
    else Right (state {stateRendering = False}, [], CommandEndRendering)

-- | Bind a live pipeline built for the frame's color format. The batch
-- retains the pipeline's generation and, transitively, its layout's.
bindPipeline ∷ Recorder q inst msgr phys dev cmd → Pipeline → IO (Either Refusal ())
bindPipeline recorder (Pipeline pipeline) =
  liveNative (recorderRecording recorder) pipeline >>= \case
    Left refusal → pure (Left refusal)
    Right (NativePipeline handle layout format)
      | format /= frameImageFormat (recorderFrame recorder) →
          pure (Left (RefusedIncompatible ("a pipeline for format " <> tshow format <> " and an image of format " <> tshow (frameImageFormat (recorderFrame recorder)))))
      | otherwise → command recorder $ \state →
          Right (state {statePipeline = Just pipeline}, [pipeline, layout], CommandBindPipeline handle)
    Right _ → pure (Left RefusedWrongKind)

-- | Set the viewport. It must be finite, have area, and lie within the
-- frame's image — which Vulkan guarantees is within every device's viewport
-- dimension and bounds limits, so no device limit needs reading here.
setViewport ∷ Recorder q inst msgr phys dev cmd → Viewport → IO (Either Refusal ())
setViewport recorder viewport = command recorder $ \state →
  let extent = frameImageExtent (recorderFrame recorder)
      values = [viewportX viewport, viewportY viewport, viewportWidth viewport, viewportHeight viewport]
   in if any (\value → isNaN value || isInfinite value) values
        then Left (RefusedIllegal "a viewport that is not finite")
        else
          if viewportWidth viewport <= 0 || viewportHeight viewport <= 0
            then Left (RefusedIllegal "a viewport with no area")
            else
              if viewportX viewport < 0
                || viewportY viewport < 0
                || viewportX viewport + viewportWidth viewport > fromIntegral (extentWidth extent)
                || viewportY viewport + viewportHeight viewport > fromIntegral (extentHeight extent)
                then Left (RefusedIllegal "a viewport outside the frame's image")
                else Right (state {stateViewport = True}, [], CommandSetViewport viewport)

-- | Set the scissor, which must lie within the frame's image, so its offset
-- and extent never overflow.
setScissor ∷ Recorder q inst msgr phys dev cmd → Rect → IO (Either Refusal ())
setScissor recorder rect = command recorder $ \state →
  let extent = frameImageExtent (recorderFrame recorder)
      reach offset size = toInteger offset + toInteger size
   in if rectX rect < 0 || rectY rect < 0
        then Left (RefusedIllegal "a scissor with a negative offset")
        else
          if reach (rectX rect) (rectWidth rect) > toInteger (extentWidth extent)
            || reach (rectY rect) (rectHeight rect) > toInteger (extentHeight extent)
            then Left (RefusedIllegal "a scissor outside the frame's image")
            else Right (state {stateScissor = True}, [], CommandSetScissor rect)

-- | Draw triangles with the bound pipeline, inside rendering, once the
-- viewport and scissor have been set. The batch retains the bound pipeline
-- and its layout again, which it already holds.
draw ∷ Recorder q inst msgr phys dev cmd → Word32 → Word32 → IO (Either Refusal ())
draw recorder vertices instances = do
  bound ← statePipeline <$> readIORef (recorderState recorder)
  layout ← case bound of
    Nothing → pure []
    Just pipeline → either (const []) dependency <$> liveNative (recorderRecording recorder) pipeline
  command recorder $ \state → case statePipeline state of
    Nothing → Left (RefusedIllegal "a draw with no pipeline bound")
    Just pipeline
      | not (stateRendering state) → Left (RefusedIllegal "a draw outside rendering")
      | not (stateViewport state && stateScissor state) → Left (RefusedIllegal "a draw before the viewport and scissor are set")
      | vertices == 0 || instances == 0 → Left (RefusedIllegal "a draw of nothing")
      | vertices `mod` 3 /= 0 → Left (RefusedUnsupported "a draw that is not whole triangles")
      | otherwise → Right (state, pipeline : layout, CommandDraw vertices instances 0 0)
  where
    dependency = \case
      NativePipeline _ layout _ → [layout]
      _ → []

-- | The bytes one copy of an image of this extent needs: four per pixel,
-- tightly packed.
readbackBytesFor ∷ SurfaceExtent → Natural
readbackBytesFor extent = fromIntegral (extentWidth extent) * fromIntegral (extentHeight extent) * 4

-- | Copy the frame's image, which must be a transfer source, into the
-- readback buffer, and make the write visible to host reads. The buffer must
-- be large enough for the whole image; the batch retains it, and its bytes
-- are undefined until that batch's submission has completed.
copyToReadback ∷ Recorder q inst msgr phys dev cmd → Readback → IO (Either Refusal ())
copyToReadback recorder (Readback readback) =
  liveNative recording readback >>= \case
    Left refusal → pure (Left refusal)
    Right (NativeReadback allocation _) → do
      let frame = recorderFrame recorder
          needed = readbackBytesFor (frameImageExtent frame)
          unfit
            | not (frameImageCapturable frame) = Just (RefusedUnsupported "a copy from an image its generation did not make a transfer source")
            | needed > allocationSize allocation = Just (RefusedOutOfBounds needed (allocationSize allocation))
            | otherwise = Nothing
      -- One writer at a time: a buffer another batch — or an earlier copy in
      -- this one — or a submission still holds would be written again with no
      -- ordering between the two writes, and its contents misattributed.
      holds ← atomically $ do
        model ← stateRootsModel (recordingRoots recording) (\current → (current, current))
        pure (maybe [] viewOutstanding (holdView (ResourceSubject readback) model))
      let busy = any (`elem` [RecordedReferenceOwed, SubmittedUseOwed]) holds
      case unfit <|> (if busy then Just RefusedInUse else Nothing) of
        Just refused → pure (Left refused)
        Nothing → do
          copied ←
            command recorder $ \state →
              if stateRendering state
                then Left (RefusedIllegal "a copy inside rendering")
                else
                  if stateLayout state /= LayoutTransferSource
                    then Left (RefusedIllegal ("copying an image that is " <> tshow (stateLayout state)))
                    else Right (state, [readback], CommandCopyImageToBuffer (frameImageHandle frame) (frameImageExtent frame) (allocationBuffer allocation))
          case copied of
            Left refusal → pure (Left refusal)
            Right () → do
              atomically $ do
                editManaged recording readback $ \entry → case managedNative entry of
                  NativeReadback held _ → entry {managedNative = NativeReadback held (ContentsCopyRecorded (recorderBatch recorder))}
                  _ → entry
                editBatch recording (recorderBatch recorder) (\entry → entry {batchReadbacks = readback : batchReadbacks entry})
              command recorder $ \state →
                Right (state, [readback], CommandHostReadBarrier (allocationBuffer allocation) (fromIntegral needed))
    Right _ → pure (Left RefusedWrongKind)
  where
    recording = recorderRecording recorder

-- ---------------------------------------------------------------------------
-- Batches

-- | Discard one batch that has not been submitted: reset its storage, which
-- invalidates its commands, and only then discharge its own references in the
-- model. A batch still being recorded is refused, and so is one the model no
-- longer holds — a submitted batch's commands may be executing, and resetting
-- its storage then would be invalid — without any native call.
discardBatch ∷ Recording q inst msgr phys dev cmd → BatchId → IO (Either Refusal ())
discardBatch recording batch =
  owned recording $ do
    known ← Map.lookup batch <$> readTVarIO (recordingBatches recording)
    held ← atomically (batchHeld (recordingRoots recording) batch)
    case known of
      Nothing → pure (Left (RefusedMisuse (AlreadyConsumed BatchIdentity)))
      Just record → case batchStanding record of
        BatchRecording → pure (Left (RefusedIllegal "the batch is still being recorded"))
        BatchUncertain _ → pure (Left (RefusedMisuse (WrongPhase BatchIdentity)))
        _
          | not held → pure (Left (RefusedMisuse (AlreadyConsumed BatchIdentity)))
          | otherwise → invalidate recording (batchStorage record) [batch] (\model → Model.discardBatch batch model)

-- | Reset the frame's recorder: invalidate its slot's storage, and only then
-- discard every unsubmitted batch the model holds for the frame. The frame
-- must still be acquired, so nothing its storage recorded has been submitted.
resetFrameRecorder ∷ Recording q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal ())
resetFrameRecorder recording frame =
  owned recording $ do
    batches ← Map.toList <$> readTVarIO (recordingBatches recording)
    phase ← atomically (fmap viewFramePhase . frameView frame <$> stateRootsModel roots (\model → (model, model)))
    let ours = [(batch, record) | (batch, record) ← batches, batchFrame record == frame]
    case phase of
      Nothing → pure (Left (RefusedMisuse (StaleIdentity FrameIdentity)))
      Just current
        | current /= FrameAcquired → pure (Left (RefusedMisuse (WrongPhase FrameIdentity)))
        | any ((== BatchRecording) . batchStanding . snd) ours → pure (Left (RefusedIllegal "the frame's batch is still being recorded"))
        -- An invalidation that raised is never retried, by either path.
        | any (uncertain . batchStanding . snd) ours → pure (Left (RefusedMisuse (WrongPhase BatchIdentity)))
        | otherwise → do
            storage ← Map.lookup (frameTarget frame, frameSlotNumber frame) <$> readTVarIO (recordingStorages recording)
            case storage of
              Nothing → pure (Left RefusedNoStorage)
              Just resource → invalidate recording resource (map fst ours) (resetRecorder frame)
  where
    roots = recordingRoots recording
    uncertain = \case
      BatchUncertain _ → True
      _ → False

-- | Reset a storage's pool, then discharge in the model. The two are one
-- masked step. A reset that raised retains every batch named, fails the
-- session and raises 'BatchInvalidationFailed'.
invalidate
  ∷ Recording q inst msgr phys dev cmd
  → ResourceId
  → [BatchId]
  → (GpuModel → Outcome GpuModel)
  → IO (Either Refusal ())
invalidate recording storage batches discharge =
  atomically (readRootsDevice roots) >>= \case
    Nothing → pure (Left RefusedDeviceAbsent)
    Just (_, device) → do
      pool ← storagePool <$> readTVarIO (recordingManaged recording)
      case pool of
        Nothing → pure (Left RefusedNoStorage)
        Just handle → mask_ $
          tryWithContext @SomeException (rootsCall roots "vkResetCommandPool" (opsResetStorage (recordingOps recording) device handle)) >>= \case
            Left failure@(ExceptionWithContext _ exception) → do
              let reason = Text.pack (displayException exception)
              atomically $ do
                for_ batches (\batch → editBatch recording batch (\entry → entry {batchStanding = BatchUncertain reason}))
                failRootsSession roots CleanupFailed
              if isAsynchronous exception then rethrowIO failure else throwIO (BatchInvalidationFailed batches reason)
            Right () → atomically $ do
              -- The records go only with the model's discharge: a refused
              -- discharge keeps them, so no local record is dropped while the
              -- model still holds its references.
              discharged ← modelAnswer roots (fmap (\model → (model, ())) . discharge)
              case discharged of
                Left refusal → pure (Left refusal)
                Right () → dropRecords
  where
    roots = recordingRoots recording
    storagePool managed = case managedNative <$> Map.lookup storage managed of
      Just (NativeStorage _ _ handle _) → Just handle
      _ → Nothing
    dropRecords = do
      records ← readTVar (recordingBatches recording)
      for_ batches $ \batch → for_ (Map.lookup batch records) $ \record →
        for_ (batchReadbacks record) $ \readback →
          editManaged recording readback $ \entry → case managedNative entry of
            NativeReadback held (ContentsCopyRecorded writer) | writer == batch → entry {managedNative = NativeReadback held ContentsUndefined}
            _ → entry
      modifyTVar' (recordingBatches recording) (\held → foldr Map.delete held batches)
      pure (Right ())

-- | Record that the model submitted this sealed batch as this submission
-- record: the model no longer holds the batch, and the outstanding submission
-- consumed exactly this batch ('submissionCarries') — so a batch reset or
-- skipped in the model, whose frame was then submitted without it, is refused.
-- It is the positive submission evidence 'readReadback' needs, and VK-12's
-- submission path supplies it once the model has accepted a submission and
-- before that submission completes. Nothing native happens, and the batch is
-- never reset or discarded here again.
noteBatchSubmitted ∷ Recording q inst msgr phys dev cmd → BatchId → SubmissionId → IO (Either Refusal ())
noteBatchSubmitted recording batch submission =
  owned recording $ atomically $ do
    record ← Map.lookup batch <$> readTVar (recordingBatches recording)
    held ← batchHeld roots batch
    model ← stateRootsModel roots (\current → (current, current))
    case record of
      Nothing → pure (Left (RefusedMisuse (AlreadyConsumed BatchIdentity)))
      Just entry
        | batchStanding entry /= BatchSealed → pure (Left (RefusedMisuse (WrongPhase BatchIdentity)))
        | held → pure (Left (RefusedMisuse (WrongPhase BatchIdentity)))
        | submissionCarries submission batch model /= Just True →
            pure (Left (RefusedMisuse (WrongParent SubmissionIdentity)))
        | otherwise → do
            editBatch recording batch (\held' → held' {batchStanding = BatchSubmitted submission})
            for_ (batchReadbacks entry) $ \readback →
              editManaged recording readback $ \managed → case managedNative managed of
                NativeReadback allocation (ContentsCopyRecorded writer)
                  | writer == batch → managed {managedNative = NativeReadback allocation (ContentsCopySubmitted submission)}
                _ → managed
            pure (Right ())
  where
    roots = recordingRoots recording

-- ---------------------------------------------------------------------------
-- Readback

-- | The range of the mapped memory a flush or an invalidation of these bytes
-- of the buffer covers: its start rounded down and its end rounded up to the
-- non-coherent atom, and the end clamped to the memory's size. Answers the
-- offset and the size.
mappedRange ∷ Natural → Natural → Natural → Natural → (Natural, Natural)
mappedRange atom memorySize offset size = (start, end - start)
  where
    step = max 1 atom
    start = (offset `div` step) * step
    end = min memorySize (((offset + size + step - 1) `div` step) * step)

-- | Read bytes a completed submission wrote. Refused unless the batch that
-- recorded the copy was recorded as submitted ('noteBatchSubmitted') and the
-- buffer owes no recorded reference and no submitted use — which the model
-- discharges only on that submission's completion fact; or unless the host
-- wrote them.
-- Non-coherent memory is invalidated over the aligned range first.
readReadback ∷ Recording q inst msgr phys dev cmd → Readback → Natural → Natural → IO (Either Refusal ByteString)
readReadback recording (Readback readback) offset size =
  owned recording $
    liveNative recording readback >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeReadback allocation contents)
        | offset + size > allocationSize allocation → pure (Left (RefusedOutOfBounds (offset + size) (allocationSize allocation)))
        | otherwise → do
            evidence ← atomically $ do
              model ← stateRootsModel roots (\model → (model, model))
              let holds = maybe [] viewOutstanding (holdView (ResourceSubject readback) model)
                  pending = filter (`elem` [RecordedReferenceOwed, SubmittedUseOwed]) holds
              pure $ case contents of
                ContentsUndefined → Left (RefusedNotWritten "nothing has written the buffer")
                ContentsHostWritten
                  | null pending → Right ()
                  | otherwise → Left RefusedInUse
                -- Positive evidence only: the batch that copies into it was
                -- recorded as submitted ('noteBatchSubmitted'), and the buffer
                -- owes no submitted use, which the model discharges only on
                -- that submission's completion fact. A batch the model merely
                -- no longer holds proves nothing: a skip or a reset in the
                -- model removes one without submitting it.
                ContentsCopyRecorded _
                  | not (null pending) → Left (RefusedNotWritten "a batch or a submission still holds the buffer")
                  | otherwise → Left (RefusedNotWritten "no submission of the batch that copies into it is recorded")
                ContentsCopySubmitted _
                  | not (null pending) → Left (RefusedNotWritten "a batch or a submission still holds the buffer")
                  | otherwise → Right ()
            case evidence of
              Left refusal → pure (Left refusal)
              -- An empty read reads nothing, and its range would be an invalid
              -- one to invalidate.
              Right () | size == 0 → pure (Right ByteString.empty)
              Right () → Right <$> readMapped allocation
      Right _ → pure (Left RefusedWrongKind)
  where
    roots = recordingRoots recording
    readMapped allocation = do
      device ← fmap snd <$> atomically (readRootsDevice roots)
      unless (allocationCoherent allocation) $
        for_ device $ \handle →
          rootsCall roots "vkInvalidateMappedMemoryRanges" $
            opsInvalidate (recordingOps recording) handle allocation (mappedRange (allocationAtom allocation) (allocationMemorySize allocation) offset size)
      opsReadMapped (recordingOps recording) allocation offset size

-- | Fill the whole buffer with one byte from the host — a sentinel a later
-- copy must overwrite — and flush it if the memory is not coherent. Refused
-- while any batch or submission holds the buffer: that would change, in
-- place, data a recorded or submitted use depends on.
fillReadback ∷ Recording q inst msgr phys dev cmd → Readback → Word8 → IO (Either Refusal ())
fillReadback recording (Readback readback) byte =
  owned recording $
    liveNative recording readback >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeReadback allocation _) → do
        held ← atomically $ do
          model ← stateRootsModel roots (\model → (model, model))
          pure (maybe [] viewOutstanding (holdView (ResourceSubject readback) model))
        if any (`elem` [RecordedReferenceOwed, SubmittedUseOwed]) held
          then pure (Left RefusedInUse)
          else mask_ $ do
            -- The bytes are unreadable from before the write changes the first
            -- of them until the write and any flush have both returned, so a
            -- write or flush that raised part-way exposes nothing under the
            -- old contents' evidence.
            atomically (setContents ContentsUndefined)
            opsWriteMapped (recordingOps recording) allocation 0 (ByteString.replicate (fromIntegral (allocationSize allocation)) byte)
            device ← fmap snd <$> atomically (readRootsDevice roots)
            unless (allocationCoherent allocation) $
              for_ device $ \handle →
                rootsCall roots "vkFlushMappedMemoryRanges" $
                  opsFlush (recordingOps recording) handle allocation (mappedRange (allocationAtom allocation) (allocationMemorySize allocation) 0 (allocationSize allocation))
            atomically (setContents ContentsHostWritten)
            pure (Right ())
      Right _ → pure (Left RefusedWrongKind)
  where
    roots = recordingRoots recording
    setContents contents = editManaged recording readback $ \entry → case managedNative entry of
      NativeReadback kept _ → entry {managedNative = NativeReadback kept contents}
      _ → entry

-- ---------------------------------------------------------------------------
-- Disposal

-- | Destroy every released generation whose holds the model reports ended,
-- and record the disposals with the model. A pipeline layout waits for every
-- pipeline built over it to be destroyed first. A destruction that raised is
-- reported, after the whole pass, as 'ResourceDestructionFailed'.
disposeResources ∷ Recording q inst msgr phys dev cmd → Instant → IO [ResourceId]
disposeResources recording now = owner recording (go [])
  where
    roots = recordingRoots recording
    -- Pass after pass, since a pass can make a layout eligible by destroying
    -- its last pipeline, until one destroys nothing. Each pass's destructions
    -- are recorded before the next begins, and a failure is raised only once
    -- everything that did return has been recorded.
    go recorded = do
      (destroyed, failures) ← pass
      unless (null failures) (atomically (failRootsSession roots CleanupFailed))
      settled ← settle []
      for_ failures $ \(resource, reason) → throwIO (ResourceDestructionFailed resource reason)
      if null destroyed then pure (recorded <> settled) else go (recorded <> settled)
    -- A progress turn does bounded work, so turns continue until the model
    -- has recorded every destruction that returned, or a turn does nothing.
    settle recorded = do
      (disposed, acted) ← atomically (progress recording now)
      pending ← any ((== ManagedDestroyedPending) . managedStanding) . Map.elems <$> readTVarIO (recordingManaged recording)
      if not acted || not pending then pure (recorded <> disposed) else settle (recorded <> disposed)
    pass = do
      (candidates, device) ← atomically $ do
        managed ← readTVar (recordingManaged recording)
        model ← stateRootsModel roots (\model → (model, model))
        device ← readRootsDevice roots
        let dependants layout =
              [ () | ManagedRecord (NativePipeline _ over _) standing ← Map.elems managed, over == layout, standing /= ManagedDestroyedPending
              ]
            eligible resource record =
              releasedStanding (managedStanding record)
                && disposalEligible (ResourceSubject resource) model
                && case managedNative record of
                  NativeLayout _ → null (dependants resource)
                  _ → True
        pure (sortOn (kindOrder . managedNative . snd) (Map.toList (Map.filterWithKey eligible managed)), snd <$> device)
      results ← case device of
        Nothing → pure []
        Just handle → forM candidates $ \(resource, record) → (,) resource <$> destroyOne handle resource record
      pure ([resource | (resource, Nothing) ← results], [(resource, reason) | (resource, Just reason) ← results])
    destroyOne device resource record = mask_ $
      tryWithContext @SomeException (destroyNative recording device (managedNative record)) >>= \case
        Right () → Nothing <$ atomically (editManaged recording resource (\entry → entry {managedStanding = ManagedDestroyedPending}))
        Left failure@(ExceptionWithContext _ exception) → do
          let reason = Text.pack (displayException exception)
          atomically (editManaged recording resource (\entry → entry {managedStanding = ManagedUncertain reason}))
          if isAsynchronous exception then rethrowIO failure else pure (Just reason)
    kindOrder = \case
      NativePipeline {} → 0 ∷ Int
      NativeStorage {} → 1
      NativeReadback {} → 2
      NativeLayout _ → 3
    releasedStanding = \case
      ManagedReleased → True
      ManagedReplaced _ → True
      _ → False

-- | One model progress turn answering for this module's resources only,
-- forgetting every one the model recorded as disposed. Answers those, and
-- whether the turn took any action at all.
progress ∷ Recording q inst msgr phys dev cmd → Instant → STM ([ResourceId], Bool)
progress recording now = do
  managed ← readTVar (recordingManaged recording)
  let answer = \case
        ResourceSubject resource → case managedStanding <$> Map.lookup resource managed of
          Just ManagedDestroyedPending → DisposalCompleted
          Just (ManagedUncertain _) → DisposalFailed
          _ → DisposalRefused
        GenerationSubject _ → DisposalRefused
  report ← stateRootsModel (recordingRoots recording) $ \model →
    let (next, turn) = runProgressTurn silentEvidence {disposalEvidence = answer} now model
     in (turn, next)
  let disposed = [resource | ResourceSubject resource ← turnDisposed report]
  modifyTVar' (recordingManaged recording) (\held → foldr Map.delete held disposed)
  modifyTVar' (recordingStorages recording) (Map.filter (`notElem` disposed))
  -- A storage is disposable only once no batch or submission holds it, so a
  -- batch record still naming a destroyed storage is a submitted one whose
  -- submission completed: it goes with its storage. A readback it copied into
  -- keeps its own evidence.
  modifyTVar' (recordingBatches recording) (Map.filter ((`notElem` disposed) . batchStorage))
  pure (disposed, turnActions report > 0)

-- | Release every live handle, destroy every generation whose holds have
-- ended, and raise 'ResourcesRetained' — manufacturing no evidence — if any
-- remains. A batch still outstanding retains what it references.
retireRecording ∷ Recording q inst msgr phys dev cmd → Instant → IO ()
retireRecording recording now = owner recording $ do
  live ← Map.keys . Map.filter ((== ManagedLive) . managedStanding) <$> readTVarIO (recordingManaged recording)
  for_ live $ \resource → atomically $ do
    modelEdit roots (releaseResource resource)
    modelEdit roots (endResourceCpuUse resource)
    editManaged recording resource (\entry → entry {managedStanding = ManagedReleased})
  _ ← disposeResources recording now
  remaining ← Map.keys <$> readTVarIO (recordingManaged recording)
  unless (null remaining) (throwIO (ResourcesRetained remaining))
  where
    roots = recordingRoots recording

-- | Destroy one managed generation's native objects.
destroyNative ∷ Recording q inst msgr phys dev cmd → dev → NativeResource cmd → IO ()
destroyNative recording device = \case
  NativeLayout handle → rootsCall roots "vkDestroyPipelineLayout" (opsDestroyPipelineLayout ops device handle)
  NativePipeline handle _ _ → rootsCall roots "vkDestroyPipeline" (opsDestroyPipeline ops device handle)
  NativeStorage _ _ pool _ → rootsCall roots "vkDestroyCommandPool" (opsDestroyStorage ops device pool)
  NativeReadback allocation _ → rootsCall roots "vkDestroyBuffer" (opsDestroyReadback ops device allocation)
  where
    roots = recordingRoots recording
    ops = recordingOps recording

-- ---------------------------------------------------------------------------
-- Observation

data ManagedView = ManagedView
  { viewResource ∷ !ResourceId
  , viewManagedStanding ∷ !ManagedStanding
  , viewKind ∷ !Text
  , viewNativeHandles ∷ ![Word64]
  }
  deriving (Eq, Show)

readManaged ∷ Recording q inst msgr phys dev cmd → STM [ManagedView]
readManaged recording =
  map view . Map.toAscList <$> readTVar (recordingManaged recording)
  where
    view (resource, record) =
      let (kind, handles) = case managedNative record of
            NativeLayout handle → ("pipeline layout", [handle])
            NativePipeline handle _ _ → ("pipeline", [handle])
            NativeStorage _ _ pool _ → ("frame storage", [pool])
            NativeReadback allocation _ → ("readback", [allocationBuffer allocation, allocationMemory allocation])
       in ManagedView resource (managedStanding record) kind handles

data BatchView = BatchView
  { viewBatch ∷ !BatchId
  , viewBatchFrame ∷ !FrameSlotId
  , viewBatchStanding ∷ !BatchStanding
  , viewBatchCommands ∷ !Natural
  }
  deriving (Eq, Show)

readBatch ∷ Recording q inst msgr phys dev cmd → BatchId → STM (Maybe BatchView)
readBatch recording batch = fmap (batchView batch) . Map.lookup batch <$> readTVar (recordingBatches recording)

readBatches ∷ Recording q inst msgr phys dev cmd → STM [BatchView]
readBatches recording = map (uncurry batchView) . Map.toAscList <$> readTVar (recordingBatches recording)

batchView ∷ BatchId → BatchRecord → BatchView
batchView batch record = BatchView batch (batchFrame record) (batchStanding record) (batchCommands record)

-- ---------------------------------------------------------------------------
-- Helpers

-- | Refuse unless called on the graphics owner's thread.
owned ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal a) → IO (Either Refusal a)
owned recording action = do
  current ← myThreadId
  if current /= recordingOwner recording then pure (Left RefusedNotOwner) else action

-- | Raise unless called on the graphics owner's thread: for the owner's own
-- steps, which answer no refusal.
owner ∷ Recording q inst msgr phys dev cmd → IO a → IO a
owner recording action = do
  current ← myThreadId
  if current /= recordingOwner recording then throwIO (userError "a recording step ran off the graphics owner's thread") else action

-- | The native record of a live generation this recording manages, or why
-- there is none: a foreign session, a generation this recording no longer
-- manages, one replaced by a newer generation, or one released.
liveNative ∷ Recording q inst msgr phys dev cmd → ResourceId → IO (Either Refusal (NativeResource cmd))
liveNative recording resource
  | resourceSession resource /= rootsSessionIdentity (recordingRoots recording) = pure (Left (RefusedMisuse (ForeignIdentity ResourceIdentity)))
  | otherwise =
      (Map.lookup resource <$> readTVarIO (recordingManaged recording)) >>= \case
        Nothing → pure (Left (RefusedMisuse (StaleIdentity ResourceIdentity)))
        Just record → pure $ case managedStanding record of
          ManagedLive → Right (managedNative record)
          ManagedReplaced _ → Left (RefusedMisuse (StaleIdentity ResourceIdentity))
          _ → Left (RefusedMisuse (WrongPhase ResourceIdentity))

-- | Whether the model still holds a batch: recorded, and neither discarded
-- nor submitted. Asking it to discard the batch, and keeping only whether it
-- would, changes nothing.
batchHeld ∷ Roots q inst msgr phys dev → BatchId → STM Bool
batchHeld roots batch = stateRootsModel roots $ \model → case Model.discardBatch batch model of
  Admitted _ → (True, model)
  _ → (False, model)

-- | Apply one model operation whose answer the caller has already decided
-- does not matter: a refusal changes nothing.
modelEdit ∷ Roots q inst msgr phys dev → (GpuModel → Outcome GpuModel) → STM ()
modelEdit roots operation = stateRootsModel roots $ \model → case operation model of
  Admitted next → ((), next)
  _ → ((), model)

-- | Apply one model operation, answering its value or why it was refused. A
-- refusal changes nothing.
modelAnswer ∷ Roots q inst msgr phys dev → (GpuModel → Outcome (GpuModel, a)) → STM (Either Refusal a)
modelAnswer roots operation = stateRootsModel roots $ \model → case operation model of
  Admitted (next, value) → (Right value, next)
  Backpressure kind → (Left (RefusedBackpressure kind), model)
  Rejected misuse → (Left (RefusedMisuse misuse), model)

editManaged ∷ Recording q inst msgr phys dev cmd → ResourceId → (ManagedRecord cmd → ManagedRecord cmd) → STM ()
editManaged recording resource edit = modifyTVar' (recordingManaged recording) (Map.adjust edit resource)

editBatch ∷ Recording q inst msgr phys dev cmd → BatchId → (BatchRecord → BatchRecord) → STM ()
editBatch recording batch edit = modifyTVar' (recordingBatches recording) (Map.adjust edit batch)

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

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
