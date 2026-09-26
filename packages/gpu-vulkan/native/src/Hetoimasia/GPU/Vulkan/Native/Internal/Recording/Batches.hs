-- | The batch lifecycle of the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording") once recording has ended:
-- discarding one unsubmitted batch, resetting a frame's recorder, recording
-- that the model submitted a sealed batch, and freeing a slot of batches whose
-- submission has completed. Each invalidation resets the storage's pool first
-- and only then discharges in the model, as one masked step ('invalidate'); a
-- reset that raised retains every batch it named and fails the session.
--
-- This module advances and removes the batch records the recorder
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder") inserted, and
-- advances the contents of the readback buffers those batches copied into; the
-- records themselves are the recording's state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State"). It owns no state
-- of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches
  ( discardBatch
  , resetFrameRecorder
  , noteBatchSubmitted
  , retireCompleted
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, mask_, rethrowIO, throwIO, tryWithContext)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text

import Hetoimasia.GPU.Model
  ( FramePhase (..)
  , FrameView (..)
  , GpuModel
  , Outcome (..)
  , SessionFailureCause (CleanupFailed)
  , frameView
  , resetRecorder
  , submissionCarries
  )
import qualified Hetoimasia.GPU.Model as Model
import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , FrameSlotId
  , IdentityKind (..)
  , Misuse (..)
  , ResourceId
  , SubmissionId
  , frameSlotNumber
  , frameTarget
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer (RecordingOps (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchInvalidationFailed (..)
  , BatchRecord (..)
  , BatchStanding (..)
  , ManagedRecord (..)
  , ManagedStanding (..)
  , NativeResource (..)
  , ReadbackContents (..)
  , Recording (..)
  , Refusal (..)
  , batchHeld
  , editBatch
  , editManaged
  , isAsynchronous
  , modelAnswer
  , owned
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (failRootsSession, readRootsDevice, rootsCall, stateRootsModel)

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
-- never reset or discarded by the recording again.
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
