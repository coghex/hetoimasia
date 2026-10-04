-- | The state of the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): the 'Recording' itself and the
-- three maps it owns — managed records, frame storages and batch records —
-- and the session's shared ring (GRS-4), if it has made one,
-- with the handles, refusals and failures every part of the recording
-- answers in, the checks each operation begins with, and the read-only views
-- of that state.
--
-- This module creates the state ('makeRecording') and defines the only edits
-- made to it ('editManaged', 'editBatch'); the modules that construct,
-- record, discharge, read back and dispose apply those edits, each to the
-- entries its own operation concerns, on the graphics owner's thread. The
-- public module's state table names which module writes what. The helpers
-- that speak to the model ('modelEdit', 'modelAnswer', 'batchHeld') and the
-- one native destruction of a generation ('destroyNative') live here because
-- more than one of those modules needs them. It is private to the package:
-- clients see the handles and the recording only abstractly, through the
-- public module, and never the records or their constructors.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( -- * Records
    ManagedStanding (..)
  , NativeResource (..)
  , PipelineInterface (..)
  , ReadbackContents (..)
  , ManagedRecord (..)
  , BatchStanding (..)
  , BatchRecord (..)
  , StorageOwner (..)

    -- * Tickets (GRS-12)
  , TicketState (..)
  , BatchTicket (..)
  , newTicket
  , readTicket
  , awaitTicket
  , settleTicket

    -- * The recording
  , Recording (..)
  , makeRecording
  , Refusal (..)

    -- * The texture table (GRS-7)
  , TableState (..)
  , SwapState (..)
  , SwapTicket (..)
  , readSwapTicket
  , settleSwap
  , sessionHasFailed
  , failPendingSwaps

    -- * The shared ring (GRS-4)
  , RingSize
  , ringSizeBytes
  , RingSizeRefused (..)
  , validateRingSize
  , RingState (..)
  , ClaimRecord (..)
  , RingClaim (..)
  , claimSize
  , RingView (..)
  , readRing
  , releaseClaims

    -- * Handles
  , PipelineLayout (..)
  , Pipeline (..)
  , FrameStorage (..)
  , Readback (..)
  , Buffer (..)
  , Image (..)
  , Managed (..)
  , Ordered
  , orderedObject

    -- * Failures
  , BatchInvalidationFailed (..)
  , ResourceDestructionFailed (..)
  , ResourcesRetained (..)

    -- * Observation
  , ManagedView (..)
  , readManaged
  , BatchView (..)
  , readBatch
  , readBatches

    -- * Shared steps
  , owned
  , owner
  , checkpointed
  , liveNative
  , destroyNative
  , readbackBuffer
  , batchHeld
  , modelEdit
  , modelAnswer
  , editManaged
  , editBatch
  , isAsynchronous
  , tshow
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (Exception (displayException), SomeAsyncException, SomeException, fromException, throwIO)
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import System.Timeout (timeout)

import Hetoimasia.Foundation.Time (Duration, durationNanoseconds)
import Hetoimasia.GPU.Model (GpuModel, Outcome (..))
import qualified Hetoimasia.GPU.Model as Model
import Hetoimasia.GPU.Model.Access (ResourceKind)
import Hetoimasia.GPU.Model.Budget (BudgetKind)
import Hetoimasia.GPU.Model.TextureTable (TextureHandle, TextureTable)
import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , FrameSlotId
  , IdentityKind (..)
  , Misuse (..)
  , ResourceId
  , SubmissionId
  , TargetId
  , resourceSession
  )
import Hetoimasia.GPU.Vulkan.Native.Allocator (BoundMemory (memoryAllocation, memoryResource), MemoryUsage)
import Hetoimasia.GPU.Vulkan.Native.Generations (Generations)
import Hetoimasia.GPU.Vulkan.Native.Internal.Allocation (AllocatedBuffer (..), freeBuffer, freeImage)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( BufferKind (..)
  , ImageDescription (..)
  , ImageFormat
  , ImageKind (..)
  , ImageUse (..)
  , PushConstantRange
  , ReadbackAllocation (..)
  , RecordingOps (..)
  , TableSampler
  , VertexInput
  , bufferResourceKind
  , imageKindUse
  , imageResourceKind
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (Checkpoint (..), Roots, TerminalCause, TerminalReport (reportPrimary), checkpointRoots, readRootsTerminal, rootsCall, rootsSessionIdentity, stateRootsModel)

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
  = NativeLayout !Word64 ![PushConstantRange] !(Maybe Word32)
    -- ^ The layout, the push-constant ranges it declares, and, for a layout
    -- that holds the texture table's two sets (GRS-7), the push-constant
    -- offset its draws' sampler index is at.
  | NativePipeline !Word64 !ResourceId !Word32 !PipelineInterface
    -- ^ The pipeline, the layout generation it was built over, the color
    -- format it renders to, and what it declares of its interface.
  | NativeStorage !StorageOwner !Word64 !cmd
    -- ^ The slot it serves, its pool and its command buffer.
  | NativeReadback !ReadbackAllocation !ReadbackContents
  | NativeBuffer !BufferKind !Natural !AllocatedBuffer
    -- ^ The buffer's kind, its size, and the buffer with its allocation.
  | NativeImage !ImageDescription !BoundMemory !Word64
    -- ^ What the image was created as, the image with its allocation, and
    -- its one owned view.
  | NativeSampler !TableSampler !Word64
    -- ^ One of the texture table's four shared samplers (GRS-7). Each of the
    -- table's native objects is a generation of its own, so a construction
    -- that fails part-way leaves only whole generations, released and
    -- destroyed by the ordinary rules.
  | NativeSetLayout !Word32 !Word64
    -- ^ One of the texture table's descriptor-set layouts, by set number:
    -- set 0's, the samplers and the sampled-image array; set 1's, the lookup
    -- buffer.
  | NativeDescriptorPool !Word32 !Word64
    -- ^ The pool of one of the texture table's sets, by set number. The set
    -- itself is allocated from it afterwards, and freed with it.
  | NativeVersion !Word32
    -- ^ One lookup version of the texture table: its entry in the version
    -- ring, which is part of the ring's buffer and no native object of its
    -- own. A batch that binds the table at this version retains it.

-- | What a pipeline declares of its interface (GRS-4), kept with its
-- generation so a batch checks what it binds, pushes and draws against the
-- pipeline it bound: its layout's native handle and push-constant ranges, and
-- its vertex input.
data PipelineInterface = PipelineInterface
  { interfaceLayout ∷ !Word64
  , interfacePushConstants ∷ ![PushConstantRange]
  , interfaceVertexInput ∷ !VertexInput
  , interfaceTable ∷ !(Maybe Word32)
    -- ^ For a pipeline over a layout holding the texture table (GRS-7), the
    -- push-constant offset of its draws' sampler index.
  }
  deriving (Eq, Show)

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

-- | Where one batch stands in the recording's own record.
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
    -- never reset or discarded by the recording again.
  deriving (Eq, Show)

-- | The slot a command storage serves: a target's frame slot, or a frame-less
-- slot of the session (GRS-12).
data StorageOwner
  = StorageOfFrame !TargetId !Natural
  | StorageOfFrameless !Natural
  deriving (Eq, Ord, Show)

data BatchRecord = BatchRecord
  { batchFrame ∷ !(Maybe FrameSlotId)
    -- ^ The frame it renders, or 'Nothing' for a frame-less batch.
  , batchTicket ∷ !(Maybe (TVar TicketState))
    -- ^ A frame-less batch's completion ticket, which its owner's operations
    -- settle.
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
  , recordingStorages ∷ !(TVar (Map StorageOwner ResourceId))
  , recordingBatches ∷ !(TVar (Map BatchId BatchRecord))
  , recordingRing ∷ !(TVar (Maybe RingState))
    -- ^ The session's shared ring (GRS-4), once made.
  , recordingUploading ∷ !(TVar (Set ResourceId))
    -- ^ The targets of uploads not yet complete (GRS-6): no batch but their
    -- uploads' own may touch one, and none is destroyed, until its upload
    -- has settled. The session's uploads add and remove them; any thread
    -- may read them.
  , recordingReleaseDeferred ∷ !(TVar (Set ResourceId))
    -- ^ Upload targets their owners released while an upload still held them
    -- (GRS-6): already recordable no longer, and released in the model once
    -- that upload settles, so its later copies are not stranded.
  , recordingIndexData ∷ !(TVar (Map ResourceId ByteString))
    -- ^ What a completed upload wrote into each managed index buffer, so an
    -- indexed draw through one can bound its vertex reads (GRS-6). Kept with
    -- the generation, and forgotten with its disposal.
  , recordingFilled ∷ !(TVar (Set ResourceId))
    -- ^ The buffers an upload has been admitted into (GRS-6), never fresh
    -- for another upload — whichever uploads admit it — unless that upload
    -- was cancelled before any copy. Forgotten with the buffer's disposal.
  , recordingTable ∷ !(TVar (Maybe TableState))
    -- ^ The session's texture table (GRS-7), once made.
  }

-- | The session's texture table (GRS-7): the pure bookkeeping of its
-- handles, slots and versions, keeping each texture's image, and the managed
-- generations and native handles behind it. Every generation here is one the
-- recording owns: a batch that binds the table retains the samplers, the
-- layouts, the pools, the version ring and the version it binds, and each is
-- released with every other live generation when the recording retires.
data TableState = TableState
  { tableBook ∷ !(TextureTable ResourceId)
  , tableObjects ∷ ![ResourceId]
    -- ^ The samplers, the set layouts and set 1's pool, which every batch
    -- that binds the table retains.
  , tableTexturePool ∷ !ResourceId
    -- ^ The pool of the current set 0 (GRS-14): a growth replaces it with the
    -- larger set's and releases it, and a batch that bound the table retains
    -- the one it bound, so an older set is destroyed only when no batch
    -- holds it.
  , tableRing ∷ !ResourceId
  , tableVersions ∷ !(Map Word32 ResourceId)
    -- ^ Each ring entry's managed version.
  , tableSetLayoutHandles ∷ ![Word64]
    -- ^ Set 0's layout, then set 1's, as a pipeline layout declares them.
  , tableSets ∷ ![Word64]
    -- ^ The current set 0, then set 1, as a binding binds them.
  , tableMapping ∷ !ReadbackAllocation
    -- ^ Where the version ring is mapped.
  , tableStride ∷ !Natural
    -- ^ The bytes between two versions: one version's entries, padded to
    -- the device's storage-buffer offset alignment and flush granularity.
  , tableEntries ∷ !Word32
    -- ^ How many lookup entries one version holds.
  , tableAtom ∷ !Natural
    -- ^ The flush granularity of the ring's memory: one on coherent memory.
  , tablePlaceholder ∷ !ResourceId
    -- ^ Slot 0's transparent-black image.
  , tablePlaceholderWritten ∷ !Bool
    -- ^ Whether slot 0's descriptor is written: until it is, the table is
    -- not bound.
  , tableTextures ∷ !(Set ResourceId)
    -- ^ Every image a live handle, a pending swap or a retiring slot holds
    -- and the table has not yet released: none is released but through the
    -- table.
  , tableSwapTickets ∷ !(Map ResourceId (TVar SwapState))
    -- ^ Each pending swap's report, by its replacement image (GRS-9).
  }

-- | Where an accepted texture swap stands (GRS-9). It only advances, from
-- 'SwapPending' to exactly one of the others.
data SwapState
  = SwapPending
    -- ^ Accepted: the handle still resolves to what it showed, until the
    -- replacement's upload completes.
  | SwapPublished
    -- ^ The replacement's upload completed: every version published from
    -- now on resolves the handle to it, and the texture it replaced is
    -- released, to be destroyed once no batch retains it.
  | SwapSuperseded
    -- ^ A later swap on the handle replaced this one before it took effect:
    -- the replacement was released and is never shown.
  | SwapAbandoned
    -- ^ The handle was released first: the replacement was released and is
    -- never shown.
  | SwapFailed
    -- ^ The replacement's upload was cancelled or lost, or the session
    -- failed, before it completed: the handle keeps what it showed, and the
    -- replacement was released.
  deriving (Eq, Show)

-- | An accepted swap's report, read from any thread without a native call:
-- its own state, and whether the session has failed.
data SwapTicket = SwapTicket !(TVar SwapState) !(STM Bool)

instance Show SwapTicket where
  show _ = "SwapTicket"

-- | Where the swap stands now. It never waits. A swap still pending in a
-- session that has failed reads 'SwapFailed' from the moment the failure is
-- latched (GRS-9), and the read stores it: a failed session writes no
-- descriptor, so no swap can take effect, and the ticket settles before any
-- drain, wait or cleanup the session's teardown goes on to. Releasing its
-- images still waits for their completion evidence, as ever.
readSwapTicket ∷ SwapTicket → STM SwapState
readSwapTicket (SwapTicket cell failed) =
  readTVar cell >>= \case
    SwapPending →
      failed >>= \case
        True → SwapFailed <$ writeTVar cell SwapFailed
        False → pure SwapPending
    settled → pure settled

-- | Settle a swap's ticket, once (GRS-9): a ticket already settled keeps its
-- outcome, whatever comes after, and once the session has failed every
-- outcome is 'SwapFailed' — a release, a supersession or a refresh after the
-- failure never reports anything else. Every write of a ticket goes through
-- this.
settleSwap ∷ Recording q inst msgr phys dev cmd → TVar SwapState → SwapState → STM ()
settleSwap recording cell outcome =
  readTVar cell >>= \case
    SwapPending → sessionHasFailed recording >>= \gone → writeTVar cell (if gone then SwapFailed else outcome)
    _ → pure ()

-- | Whether the session has failed: its terminal report names a primary.
sessionHasFailed ∷ Recording q inst msgr phys dev cmd → STM Bool
sessionHasFailed recording = isJust . reportPrimary <$> readRootsTerminal (recordingRoots recording)

-- | Fail every texture swap still pending (GRS-9), touching no native object:
-- none can take effect once the session retires. A host's retirement does
-- this first, before any step that may raise or retain, so no ticket is left
-- pending whatever happens to the rest of the teardown; the replacements are
-- released with every other live generation. Doing it again changes nothing.
failPendingSwaps ∷ Recording q inst msgr phys dev cmd → STM ()
failPendingSwaps recording =
  readTVar (recordingTable recording) >>= \case
    Nothing → pure ()
    Just table → do
      for_ (tableSwapTickets table) (\cell → settleSwap recording cell SwapFailed)
      writeTVar (recordingTable recording) (Just table {tableSwapTickets = Map.empty})

-- | The recording's state, owned by the calling thread. The public
-- constructor is "Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Disposal"'s
-- 'Hetoimasia.GPU.Vulkan.Native.Recording.newRecording', which also registers
-- the recording's disposer with the roots.
makeRecording
  ∷ RecordingOps dev cmd
  → Roots q inst msgr phys dev
  → Generations q inst msgr phys dev
  → IO (Recording q inst msgr phys dev cmd)
makeRecording ops roots generations = do
  thread ← myThreadId
  Recording ops roots generations thread
    <$> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Nothing
    <*> newTVarIO Set.empty
    <*> newTVarIO Set.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Set.empty
    <*> newTVarIO Nothing

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
  | RefusedNoMemoryType !MemoryUsage
    -- ^ No memory type the resource allows serves its usage; nothing was
    -- allocated in another type instead.
  | RefusedImageUnsupported !ImageKind !ImageFormat
    -- ^ The kind does not take the format, or the device does not support
    -- the format for the kind's use: its format features, its usage, or the
    -- device feature it needs. Nothing was created.
  | RefusedSessionFailed !TerminalCause
    -- ^ The session has failed, and this is its primary failure: no new
    -- rendering, acquisition, submission or presentation is admitted.
  | RefusedDiagnosticPending
    -- ^ A diagnostic failure has happened whose order the capture cannot yet
    -- say: nothing new is admitted, and a later checkpoint names the primary.
  | RefusedUninitialized
    -- ^ An image that awaits initialization was touched by a batch that does
    -- not initialize it, or before the batch that does was submitted (GRS-3).
  | RefusedOwnerWait
    -- ^ A blocking wait on the graphics owner's thread, whose own return and
    -- progress are what the wait is for (GRS-12).
  | RefusedStaleHandle !TextureHandle
    -- ^ A texture handle released, of an older generation, or never issued
    -- (GRS-7).
  | RefusedConstructionFailed !Text
    -- ^ A construction raised, with the session still running, after settling
    -- everything it made: its reservation given back, or the generation it
    -- could not name released. The recording itself re-raises such a failure;
    -- a caller that confines it to the one frame that needed it — the window
    -- integration's consumer construction — answers it as this refusal, with
    -- what was raised.
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The shared ring (GRS-4)

-- | The size of the session's shared ring, in bytes, as the application
-- configures it: validated once ('validateRingSize') and never clamped.
newtype RingSize = RingSize Natural
  deriving (Eq, Ord, Show)

ringSizeBytes ∷ RingSize → Natural
ringSizeBytes (RingSize bytes) = bytes

-- | Why a configured ring size was refused.
data RingSizeRefused
  = RingSizeNotPositive !Integer
  | RingSizeUnrepresentable !Integer
    -- ^ Larger than any Vulkan size can hold.
  deriving (Eq, Show)

-- | Validate a configured ring size: zero and negative sizes, and ones no
-- @VkDeviceSize@ can hold, are refused, never clamped. Whether the device
-- can make a buffer that large is asked when the ring is made.
validateRingSize ∷ Integer → Either RingSizeRefused RingSize
validateRingSize requested
  | requested <= 0 = Left (RingSizeNotPositive requested)
  | requested > 2 ^ (64 ∷ Int) - 1 = Left (RingSizeUnrepresentable requested)
  | otherwise = Right (RingSize (fromInteger requested))

-- | The session's shared ring: its managed generation and mapping, its size,
-- the granularity its claims are padded to, and the regions batches hold.
data RingState = RingState
  { ringResource ∷ !ResourceId
    -- ^ The ring buffer's managed generation, which a batch binding one of
    -- its regions retains.
  , ringMapping ∷ !ReadbackAllocation
  , ringBytes ∷ !Natural
  , ringAtom ∷ !Natural
    -- ^ One for coherent memory; the device's @nonCoherentAtomSize@
    -- otherwise, so no two claims share an atom a flush covers.
  , ringClaims ∷ !(Map Natural ClaimRecord)
    -- ^ Every region a batch holds, by its claim's number.
  , ringNextClaim ∷ !Natural
    -- ^ The number the next claim is issued: never reissued.
  , ringHead ∷ !Natural
    -- ^ Where the next claim is first tried: the end of the last one.
  }

-- | One region a batch holds.
data ClaimRecord = ClaimRecord
  { claimRecordBatch ∷ !BatchId
  , claimRecordOffset ∷ !Natural
    -- ^ Its start in the ring, aligned as it asked and to the atom.
  , claimRecordSpan ∷ !Natural
    -- ^ The bytes it holds: its size, padded to the atom.
  , claimRecordSize ∷ !Natural
    -- ^ The bytes it asked for, which are all that may be written or bound.
  }
  deriving (Eq, Show)

-- | A claim of one region of the session's ring by one batch. Its number is
-- never reissued, so a claim whose region was reclaimed and handed to
-- another is refused rather than mistaken for the new one.
data RingClaim = RingClaim
  { claimNumber ∷ !Natural
  , claimRing ∷ !ResourceId
  , claimBytes ∷ !Natural
  }
  deriving (Eq, Ord, Show)

-- | The bytes a claim may be written and bound over.
claimSize ∷ RingClaim → Natural
claimSize = claimBytes

-- | The ring as an observer sees it.
data RingView = RingView
  { ringViewResource ∷ !ResourceId
  , ringViewBytes ∷ !Natural
  , ringViewAtom ∷ !Natural
  , ringViewClaims ∷ ![(Natural, ClaimRecord)]
    -- ^ Every region a batch holds, by its claim's number, in order.
  }
  deriving (Eq, Show)

readRing ∷ Recording q inst msgr phys dev cmd → STM (Maybe RingView)
readRing recording =
  fmap (\ring → RingView (ringResource ring) (ringBytes ring) (ringAtom ring) (Map.toAscList (ringClaims ring)))
    <$> readTVar (recordingRing recording)

-- | Reclaim every region these batches hold: for batches whose submission
-- has completed, or that were invalidated without one. Nothing else frees a
-- region.
releaseClaims ∷ Recording q inst msgr phys dev cmd → [BatchId] → STM ()
releaseClaims recording batches =
  modifyTVar' (recordingRing recording) $
    fmap (\ring → ring {ringClaims = Map.filter ((`notElem` batches) . claimRecordBatch) (ringClaims ring)})

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

-- | A managed buffer of one 'BufferKind'.
newtype Buffer = Buffer ResourceId
  deriving (Eq, Ord, Show)

-- | A managed image of one 'ImageKind', with its one owned view.
newtype Image = Image ResourceId
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

instance Managed Buffer where
  managedResource (Buffer resource) = resource

instance Managed Image where
  managedResource (Image resource) = resource

-- | A managed handle the recorder orders and transitions (GRS-3): a buffer
-- or an image.
class Managed handle ⇒ Ordered handle

instance Ordered Buffer

instance Ordered Image

-- | What the ordering rules need of a managed generation: its kind, its
-- native handle, and for an image the aspect and mip levels its barriers
-- cover. Anything other than a buffer or an image has none.
orderedObject ∷ NativeResource cmd → Maybe (ResourceKind, Word64, Maybe (Word32, Word32))
orderedObject = \case
  NativeBuffer kind _ allocated → Just (bufferResourceKind kind, memoryResource (allocatedMemory allocated), Nothing)
  NativeImage description memory _ →
    Just
      ( imageResourceKind (imageKind description)
      , memoryResource memory
      , Just (useAspect (imageKindUse (imageKind description)), imageMipLevels description)
      )
  _ → Nothing

-- ---------------------------------------------------------------------------
-- Tickets

-- | Where a frame-less batch stands, as its ticket reports it (GRS-12). It
-- only ever leaves 'TicketPending', and once terminal it never changes.
data TicketState
  = TicketPending
    -- ^ Recording, sealed, or submitted and not yet observed complete.
  | TicketComplete
    -- ^ Its submission's fence was observed signalled and recorded with the
    -- model.
  | TicketDiscarded
    -- ^ It was discarded without being submitted.
  | TicketLost
    -- ^ The device was lost while it was pending.
  deriving (Eq, Show)

-- | A frame-less batch's completion ticket: it names the batch, whatever
-- slot or storage later serves another, and is read from any thread without a
-- native call. Its outcome outlives the batch's record, its storage's reuse
-- and the session.
data BatchTicket = BatchTicket
  { ticketBatch ∷ !BatchId
  , ticketState ∷ !(TVar TicketState)
  , ticketOwner ∷ !ThreadId
    -- ^ The graphics owner's thread, on which no wait may block.
  }

instance Eq BatchTicket where
  left == right = ticketBatch left == ticketBatch right

instance Show BatchTicket where
  showsPrec precedence ticket = showParen (precedence > 10) (showString "BatchTicket " . showsPrec 11 (ticketBatch ticket))

newTicket ∷ STM (TVar TicketState)
newTicket = newTVar TicketPending

-- | The ticket's state now. It never waits.
readTicket ∷ BatchTicket → STM TicketState
readTicket = readTVar . ticketState

-- | Wait, at most this long, for the ticket to leave 'TicketPending', and
-- answer its state then — still pending if the deadline passed first. The
-- wait is the caller's alone: its expiry, or its cancellation, discards
-- nothing, releases nothing and completes nothing. It is refused on the
-- graphics owner's thread, whose return and progress the batch needs.
awaitTicket ∷ BatchTicket → Duration → IO (Either Refusal TicketState)
awaitTicket ticket limit = do
  current ← myThreadId
  if current == ticketOwner ticket
    then pure (Left RefusedOwnerWait)
    else do
      _ ← timeout microseconds (atomically (readTicket ticket >>= \state → if state == TicketPending then retry else pure state))
      Right <$> atomically (readTicket ticket)
  where
    microseconds = fromInteger (min (toInteger (maxBound ∷ Int)) (toInteger (durationNanoseconds limit) `div` 1000))

-- | Settle a ticket that is still pending; a terminal one is left as it is.
settleTicket ∷ TVar TicketState → TicketState → STM ()
settleTicket ticket state = readTVar ticket >>= \case
  TicketPending → writeTVar ticket state
  _ → pure ()

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
            NativeLayout handle _ Nothing → ("pipeline layout", [handle])
            NativeLayout handle _ (Just _) → ("table pipeline layout", [handle])
            NativePipeline handle _ _ _ → ("pipeline", [handle])
            NativeStorage (StorageOfFrame _ _) pool _ → ("frame storage", [pool])
            NativeStorage (StorageOfFrameless _) pool _ → ("frame-less storage", [pool])
            NativeReadback allocation _ → ("readback", [allocationBuffer allocation, memoryAllocation (allocationMemory allocation)])
            NativeBuffer purpose _ allocated →
              (bufferKindText purpose, [memoryResource (allocatedMemory allocated), memoryAllocation (allocatedMemory allocated)])
            NativeImage description memory imageView →
              (imageKindText (imageKind description), [memoryResource memory, imageView, memoryAllocation memory])
            NativeSampler _ sampler → ("table sampler", [sampler])
            NativeSetLayout _ layout → ("table set layout", [layout])
            NativeDescriptorPool _ pool → ("table pool", [pool])
            NativeVersion entry → ("lookup version", [fromIntegral entry])
       in ManagedView resource (managedStanding record) kind handles
    bufferKindText = \case
      VertexBuffer → "vertex buffer"
      IndexBuffer → "index buffer"
      InstanceBuffer → "instance buffer"
      LookupBuffer → "lookup buffer"
      StagingBuffer → "staging buffer"
    imageKindText = \case
      TextureImage → "texture"
      DepthTarget → "depth target"
      ColorTarget → "color target"

data BatchView = BatchView
  { viewBatch ∷ !BatchId
  , viewBatchFrame ∷ !(Maybe FrameSlotId)
    -- ^ 'Nothing' for a frame-less batch.
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
-- Shared steps

-- | Refuse unless called on the graphics owner's thread.
owned ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal a) → IO (Either Refusal a)
owned recording action = do
  current ← myThreadId
  if current /= recordingOwner recording then pure (Left RefusedNotOwner) else action

-- | Run an ordinary operation behind a safe owner checkpoint: once the session
-- has failed — whatever the cause, and however it was learned: a native call's
-- device loss, the capture's error latch or sink failure, or the model's own
-- escalation — it is refused naming the primary failure, before anything
-- native is done. While a diagnostic failure is pending it is refused as
-- 'RefusedDiagnosticPending'. Only new work passes through here; retirement
-- never does.
checkpointed ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal a) → IO (Either Refusal a)
checkpointed recording action =
  checkpointRoots (recordingRoots recording) >>= \case
    CheckpointFailed primary → pure (Left (RefusedSessionFailed primary))
    CheckpointPending → pure (Left RefusedDiagnosticPending)
    CheckpointClear → action

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

-- | A readback buffer's allocation, as the allocation protocol frees, flushes
-- and names it: always mapped.
readbackBuffer ∷ ReadbackAllocation → AllocatedBuffer
readbackBuffer allocation = AllocatedBuffer (allocationMemory allocation) (allocationCoherent allocation) (Just (allocationMapped allocation))

-- | Destroy one managed generation's native objects, each before what it was
-- made from.
destroyNative ∷ Recording q inst msgr phys dev cmd → dev → NativeResource cmd → IO ()
destroyNative recording device = \case
  NativeLayout handle _ _ → rootsCall roots "vkDestroyPipelineLayout" (opsDestroyPipelineLayout ops device handle)
  NativePipeline handle _ _ _ → rootsCall roots "vkDestroyPipeline" (opsDestroyPipeline ops device handle)
  NativeStorage _ pool _ → rootsCall roots "vkDestroyCommandPool" (opsDestroyStorage ops device pool)
  NativeReadback allocation _ → freeBuffer roots (readbackBuffer allocation)
  NativeBuffer _ _ allocated → freeBuffer roots allocated
  -- The view, then the image, then its allocation.
  NativeImage _ memory imageView → do
    rootsCall roots "vkDestroyImageView" (opsDestroyView ops device imageView)
    freeImage roots memory
  NativeSampler _ sampler → rootsCall roots "vkDestroySampler" (opsDestroySampler ops device sampler)
  NativeSetLayout _ layout → rootsCall roots "vkDestroyDescriptorSetLayout" (opsDestroySetLayout ops device layout)
  -- A pool frees the set allocated from it.
  NativeDescriptorPool _ pool → rootsCall roots "vkDestroyDescriptorPool" (opsDestroyDescriptorPool ops device pool)
  NativeVersion _ → pure ()
  where
    roots = recordingRoots recording
    ops = recordingOps recording

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
