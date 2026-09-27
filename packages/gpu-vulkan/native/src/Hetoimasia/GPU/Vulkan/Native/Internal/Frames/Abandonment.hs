-- | Abandonment for the frames ("Hetoimasia.GPU.Vulkan.Native.Frames"):
-- skipping an acquired, unsubmitted frame; closing a submitted frame that will
-- never be presented; closing every live frame of a target; and the tracked
-- cleanup submission both kinds of abandonment make, which the owner's
-- progress step ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Progress") also
-- makes once a closed frame's rendering has completed.
--
-- This module advances frame records, and the semaphore and cleanup-fence
-- states of slot synchronization and presentation-pool records, in the
-- frames' state ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State"). It
-- owns no state of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Abandonment
  ( skipFrame
  , closeUnpresentedFrame
  , closeTargetFrames
  , cleanupSubmission
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar, readTVarIO)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , displayException
  , fromException
  , mask_
  , rethrowIO
  , toException
  , tryWithContext
  )
import Control.Monad (forM)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word32, Word64)

import Hetoimasia.GPU.Model
  ( SessionFailureCause (CleanupFailed)
  , closeSubmittedFrame
  , skipUnsubmittedFrame
  )
import Hetoimasia.GPU.Model.Identity (FrameSlotId, IdentityKind (..), Misuse (..), TargetId, frameTarget)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer (FrameOps (..), SubmitBatch (..), WaitStage (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches (forgetUnsubmittedBatches, resetFrameRecorder)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchRecord (..)
  , BatchStanding (..)
  , Recording (..)
  , Refusal (..)
  , modelAnswer
  , owned
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost, failRootsSession, rootsCall)

-- | Skip an acquired frame nothing of which has been submitted: an ordinary
-- outcome, not a failure. The frame's capability is consumed at once — it
-- records, submits and skips nothing more — and its unsubmitted recording is
-- invalidated natively and only then discharged. A cleanup submission that
-- runs no command and waits on the frame's acquisition semaphore is made with
-- the slot's own cleanup fence, reserved when the slot was, so no budget can
-- refuse it; the image goes back through @vkReleaseSwapchainImagesEXT@ once
-- that fence has signalled, which 'progressFrames' observes. Returning
-- acknowledges the frame's admission to retirement, not its completion. The
-- swapchain is not rebuilt and the target stays available.
--
-- The frame's presentation-pool record, whose render-finished semaphore nothing
-- signalled, is untouched; its settlement frees it.
--
-- A frame any of whose work was submitted is refused as the wrong phase:
-- 'closeUnpresentedFrame' is its exit. A cleanup submission that raised retains
-- the frame, its image and its synchronization for ever, fails the session and
-- raises 'FrameCleanupFailed'.
--
-- After the device's loss no cleanup submission is made — the lost device
-- would never complete one — and no storage is reset against it: the model's
-- skip lets go of the unsubmitted recording, whose batch records go with it,
-- uncertain ones included, and the frame waits, skipped ('StageLost'), for the
-- device-loss release to let it go.
skipFrame ∷ Frames q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal ())
skipFrame frames frame =
  owned recording $
    atomically checked >>= \case
      Left refusal → pure (Left refusal)
      Right (sync, device, family) → do
        batches ← Map.elems <$> readTVarIO (recordingBatches recording)
        let unsubmitted = [() | record ← batches, batchFrame record == frame, not (submitted (batchStanding record))]
        -- After the device's loss nothing is reset against it: the model's
        -- skip lets go of the unsubmitted recording, whose records go with it.
        lost ← atomically (lossObserved frames)
        reset ← if null unsubmitted || lost then pure (Right ()) else resetFrameRecorder recording frame
        case reset of
          Left refusal → pure (Left refusal)
          Right () → mask_ $
            atomically skipped >>= \case
              Left refusal → pure (Left refusal)
              Right True → pure (Right ())
              Right False →
                cleanupSubmission frames device family frame (syncAcquire sync) StageSkipping (editSlot frames (slotOf frame) (\entry → entry {syncAcquireState = SemaphoreWaitOwed}))
                  >>= maybe (pure (Right ())) rethrowIO
  where
    recording = framesRecording frames
    roots = framesRoots frames
    -- The model skips the frame; after the device's loss nothing more is
    -- owed here — a cleanup submission to the lost device would never
    -- complete — and the device-loss release lets it go.
    skipped = do
      answer ← modelAnswer roots (fmap (\model → (model, ())) . skipUnsubmittedFrame frame)
      lost ← lossObserved frames
      case answer of
        Right () | lost → do
          forgetUnsubmittedBatches recording frame
          Right True <$ editFrame frames frame (\record → record {recordStage = StageLost})
        _ → pure (False <$ answer)
    checked = do
      live ← Map.lookup frame <$> readTVar (framesLive frames)
      slots ← readTVar (framesSlots frames)
      model ← readModel frames
      device ← deviceOf frames
      misuse ← frameMisuse frames model frame skipUnsubmittedFrame
      pure $ case recordStage <$> live of
        Nothing → Left (RefusedMisuse misuse)
        Just StageAcquired → case (Map.lookup (slotOf frame) slots, device) of
          (_, Nothing) → Left RefusedDeviceAbsent
          (Nothing, _) → Left (RefusedIllegal "the frame's slot has no synchronization")
          (Just sync, Just (handle, family)) → Right (sync, handle, family)
        Just _ → Left (RefusedMisuse (WrongPhase FrameIdentity))
    submitted = \case
      BatchSubmitted _ → True
      _ → False

-- | Close a frame whose rendering was submitted and that will never be
-- presented — its target is closing, the caller was cancelled, or its
-- presentation was refused. It is not a skip: it keeps its submission and its
-- image. 'Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Progress.progressFrames'
-- waits for the rendering to actually complete, then settles the render-finished
-- semaphore of the frame's pool record through a tracked cleanup submission
-- that waits on it, and only once that has completed returns the image,
-- settles the frame and frees the record. Nothing native happens here. A
-- presentation that enqueued nothing leaves its frame submitted, and this is
-- its exit too.
closeUnpresentedFrame ∷ Frames q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal ())
closeUnpresentedFrame frames frame =
  owned (framesRecording frames) $ atomically $ do
    live ← Map.lookup frame <$> readTVar (framesLive frames)
    model ← readModel frames
    case recordStage <$> live of
      Nothing → Left . RefusedMisuse <$> frameMisuse frames model frame closeSubmittedFrame
      Just (StageSubmitted submission) → do
        closed ← modelAnswer (framesRoots frames) (fmap (\next → (next, ())) . closeSubmittedFrame frame)
        case closed of
          Left refusal → pure (Left refusal)
          Right () → Right () <$ editFrame frames frame (\record → record {recordStage = StageClosing submission})
      Just _ → pure (Left (RefusedMisuse (WrongPhase FrameIdentity)))

-- | Begin abandoning every live frame of a target, as its close requires:
-- skip each acquired one and close each submitted one. Frames already being
-- abandoned are left as they are. Answers what each frame answered.
closeTargetFrames ∷ Frames q inst msgr phys dev cmd → TargetId → IO [(FrameSlotId, Either Refusal ())]
closeTargetFrames frames target = do
  live ← Map.toAscList . Map.filterWithKey (\frame _ → frameTarget frame == target) <$> readTVarIO (framesLive frames)
  fmap concat . forM live $ \(frame, record) → case recordStage record of
    StageAcquired → (\answer → [(frame, answer)]) <$> skipFrame frames frame
    StageSubmitted _ → (\answer → [(frame, answer)]) <$> closeUnpresentedFrame frames frame
    _ → pure []

-- | Make one cleanup submission for a frame: reset the slot's cleanup fence,
-- then submit a batch that runs no command and waits on the semaphore, with
-- that fence. The caller masks. On success the frame enters the stage and the
-- waited semaphore's state is advanced by the given edit; on failure the frame
-- is retained for ever, the session fails, and the failure — device loss as
-- itself, anything else as 'FrameCleanupFailed' — is answered for the caller
-- to raise.
cleanupSubmission
  ∷ Frames q inst msgr phys dev cmd
  → dev
  → Word32
  → FrameSlotId
  → Word64
  → FrameStage
  → STM ()
  → IO (Maybe (ExceptionWithContext SomeException))
cleanupSubmission frames device family frame semaphore stage waiting = do
  held ← Map.lookup key <$> readTVarIO (framesSlots frames)
  case held of
    Nothing → pure Nothing
    Just sync → do
      let fence = syncCleanup sync
      outcome ←
        tryWithContext @SomeException $ do
          rootsCall roots "vkResetFences" (opsResetFence ops device fence)
          rootsCall roots "vkQueueSubmit2" (opsSubmit ops device family [SubmitBatch [semaphore] WaitAtAllCommands [] []] fence)
      case outcome of
        Right () → do
          atomically $ do
            editFrame frames frame (\record → record {recordStage = stage})
            editSlot frames key (\entry → entry {syncCleanupState = FencePending})
            waiting
          pure Nothing
        Left failure@(ExceptionWithContext context exception) → do
          let reason = "the cleanup submission raised: " <> Text.pack (displayException exception)
          atomically $ do
            editFrame frames frame (\record → record {recordStage = StageFailed reason})
            editSlot frames key (\entry → entry {syncCleanupState = FenceUncertain reason})
            failRootsSession roots CleanupFailed
          pure $ Just $ case fromException exception ∷ Maybe GraphicsDeviceLost of
            Just _ → failure
            Nothing → ExceptionWithContext context (toException (FrameCleanupFailed frame reason))
  where
    key = slotOf frame
    roots = framesRoots frames
    ops = framesOps frames

