-- | Abandonment, completion and retirement for the frames
-- ("Hetoimasia.GPU.Vulkan.Native.Frames"): skipping an acquired, unsubmitted
-- frame; closing a submitted frame that will never be presented; the owner's
-- bounded progress step, which observes pending fences, makes the cleanup
-- submissions closed frames owe, returns images and settles their
-- synchronization; and retiring a target's slot synchronization.
--
-- This module advances and removes frame records and submission records, and
-- advances and removes slot synchronization, in the frames' state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State"). It owns no state of
-- its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Abandonment
  ( skipFrame
  , closeUnpresentedFrame
  , closeTargetFrames
  , progressFrames
  , retireTargetFrames
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , displayException
  , fromException
  , mask_
  , rethrowIO
  , throwIO
  , toException
  , tryWithContext
  )
import Control.Monad (forM, unless, when)
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model
  ( CompletionFact (..)
  , GpuModel
  , Outcome (..)
  , SessionFailureCause (CleanupFailed)
  , closeSubmittedFrame
  , frameView
  , modelBudgets
  , recordCompletion
  , skipUnsubmittedFrame
  )
import Hetoimasia.GPU.Model.Budget (progressActionLimit)
import Hetoimasia.GPU.Model.Identity (FrameSlotId, IdentityKind (..), Misuse (..), TargetId, frameTarget, imageIndex)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer (FrameOps (..), SubmitBatch (..), WaitStage (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches (resetFrameRecorder)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchRecord (..)
  , BatchStanding (..)
  , Recording (..)
  , Refusal (..)
  , modelAnswer
  , owned
  , owner
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost, failRootsSession, rootsCall, stateRootsModel)

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
-- A frame any of whose work was submitted is refused as the wrong phase:
-- 'closeUnpresentedFrame' is its exit. A cleanup submission that raised retains
-- the frame, its image and its synchronization for ever, fails the session and
-- raises 'FrameCleanupFailed'.
skipFrame ∷ Frames q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal ())
skipFrame frames frame =
  owned recording $
    atomically checked >>= \case
      Left refusal → pure (Left refusal)
      Right (sync, device, family) → do
        batches ← Map.elems <$> readTVarIO (recordingBatches recording)
        let unsubmitted = [() | record ← batches, batchFrame record == frame, not (submitted (batchStanding record))]
        reset ← if null unsubmitted then pure (Right ()) else resetFrameRecorder recording frame
        case reset of
          Left refusal → pure (Left refusal)
          Right () → mask_ $
            atomically (modelAnswer roots (fmap (\model → (model, ())) . skipUnsubmittedFrame frame)) >>= \case
              Left refusal → pure (Left refusal)
              Right () →
                cleanupSubmission frames device family frame (syncAcquire sync) StageSkipping (\entry → entry {syncAcquireState = SemaphoreWaitOwed})
                  >>= maybe (pure (Right ())) rethrowIO
  where
    recording = framesRecording frames
    roots = framesRoots frames
    checked = do
      live ← Map.lookup frame <$> readTVar (framesLive frames)
      slots ← readTVar (framesSlots frames)
      model ← readModel frames
      device ← deviceOf frames
      pure $ case recordStage <$> live of
        Nothing → Left (RefusedMisuse (frameMisuse model frame skipUnsubmittedFrame))
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
-- image. 'progressFrames' waits for the rendering to actually complete, then
-- settles the render-finished semaphore through a tracked cleanup submission
-- that waits on it, and only once that has completed returns the image and
-- settles the frame. Nothing native happens here.
closeUnpresentedFrame ∷ Frames q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal ())
closeUnpresentedFrame frames frame =
  owned (framesRecording frames) $ atomically $ do
    live ← Map.lookup frame <$> readTVar (framesLive frames)
    model ← readModel frames
    case recordStage <$> live of
      Nothing → pure (Left (RefusedMisuse (frameMisuse model frame closeSubmittedFrame)))
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

-- | One bounded owner step: at most the model's progress-action limit of native
-- calls, each recorded in the same masked step that made it.
--
-- 1. Each outstanding submission's fence — and only a fence a submission made
--    pending — is asked, without waiting, whether it has signalled; one that
--    has is recorded as that submission's completion in the model, which
--    discharges every hold it carried and frees each frame slot that owed
--    nothing else.
-- 2. Each closed frame whose rendering has completed gets its cleanup
--    submission, waiting on its render-finished semaphore.
-- 3. Each skipped or closed frame whose cleanup fence has signalled has its
--    image returned through @vkReleaseSwapchainImagesEXT@, and its settlement
--    recorded in the model.
--
-- It runs on the graphics owner's thread whatever the target's phase, closing
-- included. A failure is raised only once the whole step has recorded
-- everything that did return: device loss, if one was latched, and otherwise
-- the first 'FrameCleanupFailed' or 'FrameEffectUncertain'.
progressFrames ∷ Frames q inst msgr phys dev cmd → Instant → IO Progress
progressFrames frames now = owner recording $ do
  limit ← progressActionLimit . modelBudgets <$> atomically (readModel frames)
  spent ← newIORef (0 ∷ Natural)
  failures ← newIORef []
  completed ← newIORef []
  cleanups ← newIORef []
  settled ← newIORef []
  device ← atomically (deviceOf frames)
  for_ device $ \(handle, family) → do
    let spend action = do
          used ← readIORef spent
          when (used < limit) $ do
            modifyIORef' spent (+ 1)
            action
    -- 1. Outstanding submissions.
    outstanding ← Map.toAscList <$> readTVarIO (framesSubmissions frames)
    for_ outstanding $ \(submission, record) → spend $ do
      fence ← fmap syncFence . Map.lookup (submissionSlot record) <$> readTVarIO (framesSlots frames)
      for_ fence $ \native →
        observe handle native >>= \case
          Left failure → do
            let reason = "vkGetFenceStatus raised: " <> describe failure
            atomically $ do
              uncertain frames CleanupFailed (submissionFrames record) reason
              editSlot frames (submissionSlot record) (\sync → sync {syncFenceState = FenceUncertain reason})
              modifyTVar' (framesSubmissions frames) (Map.delete submission)
            note failures (unlessLoss failure (FrameEffectUncertain (submissionFrames record) reason))
          Right False → pure ()
          Right True → do
            recorded ← atomically (complete submission record)
            if recorded
              then modifyIORef' completed (submission :)
              else note failures (toException (FrameEffectUncertain (submissionFrames record) "the model refused a completion its fence proved"))
    -- 2. Closed frames whose rendering has completed.
    submissions ← readTVarIO (framesSubmissions frames)
    closing ← Map.toAscList . Map.mapMaybe (\record → case recordStage record of
      StageClosing submission | not (Map.member submission submissions) → Just record
      _ → Nothing) <$> readTVarIO (framesLive frames)
    for_ closing $ \(frame, _) → spend $ do
      sync ← Map.lookup (slotOf frame) <$> readTVarIO (framesSlots frames)
      for_ sync $ \held → mask_ $
        cleanupSubmission frames handle family frame (syncRendered held) StageSettling (\entry → entry {syncRenderedState = SemaphoreWaitOwed}) >>= \case
          Nothing → modifyIORef' cleanups (frame :)
          Just (ExceptionWithContext _ exception) → note failures exception
    -- 3. Cleanup fences.
    abandoning ← Map.toAscList . Map.filter (abandoningStage . recordStage) <$> readTVarIO (framesLive frames)
    for_ abandoning $ \(frame, record) → spend $ do
      sync ← Map.lookup (slotOf frame) <$> readTVarIO (framesSlots frames)
      let released' =
            release handle frame record >>= \case
              Left failure → note failures failure
              Right () → modifyIORef' settled (frame :)
      for_ sync $ \held → case syncCleanupState held of
        FencePending →
          observe handle (syncCleanup held) >>= \case
            Left failure → do
              let reason = "vkGetFenceStatus raised: " <> describe failure
              atomically $ do
                editFrame frames frame (\entry → entry {recordStage = StageFailed reason})
                editSlot frames (slotOf frame) (\entry → entry {syncCleanupState = FenceUncertain reason})
                failRootsSession roots CleanupFailed
              note failures (unlessLoss failure (FrameCleanupFailed frame reason))
            Right False → pure ()
            Right True → do
              atomically (editSlot frames (slotOf frame) (\entry → entry {syncCleanupState = FenceSignalled}))
              released'
        -- Signalled at an earlier step, whose release a cancellation kept it
        -- from reaching.
        FenceSignalled → released'
        _ → pure ()
  -- Whatever was not reached this step still has its fences pending.
  pending ← length . filter pendingFence . concatMap (\sync → [syncFenceState sync, syncCleanupState sync]) . Map.elems <$> readTVarIO (framesSlots frames)
  released ← readIORef settled
  raised ← reverse <$> readIORef failures
  case [failure | failure ← raised, isLoss failure] <> raised of
    first : _ → throwIO first
    [] → pure ()
  Progress <$> (reverse <$> readIORef completed) <*> pure (reverse released) <*> (reverse <$> readIORef cleanups) <*> pure (fromIntegral pending)
  where
    recording = framesRecording frames
    roots = framesRoots frames
    ops = framesOps frames
    observe handle fence = mask_ (tryWithContext @SomeException (rootsCall roots "vkGetFenceStatus" (opsFenceSignalled ops handle fence)))
    complete submission record = do
      applied ← stateRootsModel roots $ \model → case recordCompletion now (SubmissionCompleted submission) model of
        Admitted next → (True, next)
        _ → (False, model)
      modifyTVar' (framesSubmissions frames) (Map.delete submission)
      editSlot frames (submissionSlot record) (\sync → sync {syncFenceState = FenceSignalled})
      -- Every wait the submission made has completed with it.
      for_ (submissionFrames record) $ \frame → editSlot frames (slotOf frame) (\sync → sync {syncAcquireState = SemaphoreUnsignalled})
      unless applied $
        uncertain frames CleanupFailed (submissionFrames record) "the model refused a completion its fence proved"
      pure applied
    release handle frame record = mask_ $ do
      let index = fromIntegral (imageIndex (recordImage record)) ∷ Word32
      tryWithContext @SomeException (rootsCall roots "vkReleaseSwapchainImagesEXT" (opsReleaseImages ops handle (recordSwapchain record) [index])) >>= \case
        Left failure → do
          let reason = "vkReleaseSwapchainImagesEXT raised: " <> describe failure
          atomically $ do
            editFrame frames frame (\entry → entry {recordStage = StageFailed reason})
            failRootsSession roots CleanupFailed
          -- The caller notes it; the frame keeps its image.
          pure (Left (unlessLoss failure (FrameCleanupFailed frame reason)))
        Right () → do
          recorded ← atomically $ do
            applied ← stateRootsModel roots $ \model → case recordCompletion now (UnpresentedFrameSettled frame) model of
              Admitted next → (True, next)
              _ → (False, model)
            if applied
              then do
                modifyTVar' (framesLive frames) (Map.delete frame)
                editSlot frames (slotOf frame) $ \sync → case recordStage record of
                  StageSkipping → sync {syncAcquireState = SemaphoreUnsignalled}
                  _ → sync {syncRenderedState = SemaphoreUnsignalled}
              else uncertain frames CleanupFailed [frame] "the model refused a settlement the release proved"
            pure applied
          pure (if recorded then Right () else Left (toException (FrameEffectUncertain [frame] "the model refused a settlement the release proved")))
    abandoningStage = \case
      StageSkipping → True
      StageSettling → True
      _ → False
    pendingFence = \case
      FencePending → True
      _ → False
    describe (ExceptionWithContext _ exception) = Text.pack (displayException exception)
    unlessLoss (ExceptionWithContext _ exception) replacement = case fromException exception ∷ Maybe GraphicsDeviceLost of
      Just _ → exception
      Nothing → toException replacement
    isLoss exception = case fromException exception ∷ Maybe GraphicsDeviceLost of
      Just _ → True
      Nothing → False
    note ∷ IORef [SomeException] → SomeException → IO ()
    note failures exception = modifyIORef' failures (exception :)

-- | Make one cleanup submission for a frame: reset the slot's cleanup fence,
-- then submit a batch that runs no command and waits on the semaphore, with
-- that fence. The caller masks. On success the frame enters the stage and the
-- slot's semaphore state is advanced; on failure the frame is retained for
-- ever, the session fails, and the failure — device loss as itself, anything
-- else as 'FrameCleanupFailed' — is answered for the caller to raise.
cleanupSubmission
  ∷ Frames q inst msgr phys dev cmd
  → dev
  → Word32
  → FrameSlotId
  → Word64
  → FrameStage
  → (SlotSync → SlotSync)
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
            editSlot frames key (waiting . (\entry → entry {syncCleanupState = FencePending}))
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

-- | Destroy a target's slot synchronization, once no frame of the target
-- remains and nothing of it is pending or uncertain, and forget the slots.
-- Anything that remains is retained, and 'FramesRetained' is raised naming it;
-- a destruction that raised is retained too, never attempted again, and fails
-- the session.
retireTargetFrames ∷ Frames q inst msgr phys dev cmd → TargetId → IO ()
retireTargetFrames frames target = owner (framesRecording frames) $ do
  live ← Map.keys . Map.filterWithKey (\frame _ → frameTarget frame == target) <$> readTVarIO (framesLive frames)
  slots ← Map.toAscList . Map.filterWithKey (\(owner', _) _ → owner' == target) <$> readTVarIO (framesSlots frames)
  device ← atomically (deviceOf frames)
  failures ← fmap concat . forM slots $ \(key, sync) → case device of
    Just (handle, _) | null live, idle sync → mask_ $ do
      outcome ←
        tryWithContext @SomeException $ do
          rootsCall roots "vkDestroySemaphore" (opsDestroySemaphore ops handle (syncAcquire sync))
          rootsCall roots "vkDestroySemaphore" (opsDestroySemaphore ops handle (syncRendered sync))
          rootsCall roots "vkDestroyFence" (opsDestroyFence ops handle (syncFence sync))
          rootsCall roots "vkDestroyFence" (opsDestroyFence ops handle (syncCleanup sync))
      case outcome of
        Right () → [] <$ atomically (modifyTVar' (framesSlots frames) (Map.delete key))
        Left failure@(ExceptionWithContext _ exception) → do
          let reason = "destroying the slot's synchronization raised: " <> Text.pack (displayException exception)
          atomically $ do
            editSlot frames key (\entry → entry {syncFenceState = FenceUncertain reason, syncCleanupState = FenceUncertain reason})
            failRootsSession roots CleanupFailed
          pure [failure]
    _ → pure []
  for_ failures rethrowIO
  remaining ← Map.keys . Map.filterWithKey (\(owner', _) _ → owner' == target) <$> readTVarIO (framesSlots frames)
  unless (null live && null remaining) $ throwIO (FramesRetained target live (map snd remaining))
  where
    roots = framesRoots frames
    ops = framesOps frames
    idle sync =
      syncAcquireState sync == SemaphoreUnsignalled
        && syncRenderedState sync == SemaphoreUnsignalled
        && syncFenceState sync `elem` [FenceIdle, FenceSignalled]
        && syncCleanupState sync `elem` [FenceIdle, FenceSignalled]

-- | The model's own classification of a frame this owner holds no record of:
-- asking it to perform the operation, and keeping only the refusal, changes
-- nothing. A frame the model holds that this owner never acquired is unknown
-- to it.
frameMisuse ∷ GpuModel → FrameSlotId → (FrameSlotId → GpuModel → Outcome GpuModel) → Misuse
frameMisuse model frame operation = case frameView frame model of
  Nothing → case operation frame model of
    Rejected misuse → misuse
    _ → UnknownIdentity FrameIdentity
  Just _ → UnknownIdentity FrameIdentity
