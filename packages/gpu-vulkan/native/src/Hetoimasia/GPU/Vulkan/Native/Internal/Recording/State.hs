-- | The state of the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): the 'Recording' itself and the
-- three maps it owns — managed records, frame storages and batch records —
-- with the handles, refusals and failures every part of the recording
-- answers in, the checks each operation begins with, and the read-only views
-- of that state.
--
-- This module creates the state ('newRecording') and defines the only edits
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
  , ReadbackContents (..)
  , ManagedRecord (..)
  , BatchStanding (..)
  , BatchRecord (..)

    -- * The recording
  , Recording (..)
  , newRecording
  , Refusal (..)

    -- * Handles
  , PipelineLayout (..)
  , Pipeline (..)
  , FrameStorage (..)
  , Readback (..)
  , Managed (..)

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
  , liveNative
  , destroyNative
  , batchHeld
  , modelEdit
  , modelAnswer
  , editManaged
  , editBatch
  , isAsynchronous
  , tshow
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Exception (Exception (displayException), SomeAsyncException, SomeException, fromException, throwIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model (GpuModel, Outcome (..))
import qualified Hetoimasia.GPU.Model as Model
import Hetoimasia.GPU.Model.Budget (BudgetKind)
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
import Hetoimasia.GPU.Vulkan.Native.Generations (Generations)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer (ReadbackAllocation (..), RecordingOps (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (Roots, rootsCall, rootsSessionIdentity, stateRootsModel)

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
-- Shared steps

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

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
