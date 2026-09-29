-- | Completion, presentation retirement and target retirement for the frames
-- ("Hetoimasia.GPU.Vulkan.Native.Frames"): the owner's bounded progress step,
-- which observes pending fences — submission, cleanup and present fences —
-- makes the cleanup submissions closed frames owe, returns images, and
-- records each fact it observed with the model; the finite protected-drain
-- wait that precedes a step; and retiring a target's slot synchronization and
-- presentation pool.
--
-- This module removes frame records, submission records and presentation
-- records, advances slot synchronization and presentation-pool records, frees
-- pool records, and destroys both kinds of synchronization, in the frames'
-- state ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State"). It owns no
-- state of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Progress
  ( progressFrames
  , awaitFrames
  , drainWaitLimit
  , retireTargetFrames
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO)
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
import Control.Monad (forM, unless, void, when)
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, listToMaybe)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), Instant, durationFromNanoseconds, durationNanoseconds)
import Hetoimasia.GPU.Model
  ( CompletionFact (..)
  , Outcome (..)
  , SessionFailureCause (CleanupFailed)
  , modelBudgets
  , recordCompletion
  )
import Hetoimasia.GPU.Model.Budget (progressActionLimit)
import Hetoimasia.GPU.Model.Identity (FrameSlotId, PresentationId, SubmissionId, TargetId, frameTarget, imageIndex, presentationTarget)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Abandonment (cleanupSubmission)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer (FrameOps (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Loss (releaseFramesToDeviceLoss)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State (owner)
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost, failRootsSessionBecause, rootsCall, stateRootsModel)

-- | One bounded owner step: at most the model's progress-action limit of native
-- calls, each recorded in the same masked step that made it.
--
-- * Each outstanding submission's fence — and only a fence a submission made
--   pending — is asked, without waiting, whether it has signalled; one that
--   has is recorded as that submission's completion in the model, which
--   discharges every hold it carried and frees each frame slot that owed
--   nothing else. It frees no presentation-pool record: rendering completion
--   is not presentation retirement.
-- * Each enqueued presentation's present fence is asked the same way; one that
--   has signalled is recorded as that presentation's retirement, which
--   discharges its generation's presentation hold and frees its pool record,
--   whose render-finished semaphore the presentation engine has finished with.
--   Nothing else — a signalled render fence, elapsed time, the image being
--   acquired again — retires a presentation, and a fence that has not
--   signalled yet is simply pending: what it answered before is never read
--   into it.
-- * Each closed frame whose rendering has completed gets its cleanup
--   submission, waiting on its pool record's render-finished semaphore.
-- * Each skipped or closed frame whose cleanup fence has signalled has its
--   image returned through @vkReleaseSwapchainImagesEXT@, its settlement
--   recorded in the model, and its pool record freed.
--
-- The work is one list, and each step starts one place further along it
-- than the last, so a budget smaller than the work still reaches every piece
-- of it in turn: a fence that never signals cannot keep a later submission's
-- completion, a later presentation's retirement, a cleanup or a release from
-- being observed.
--
-- It runs on the graphics owner's thread whatever the target's phase, closing
-- included. A failure is raised only once the whole step has recorded
-- everything that did return: device loss, if one was latched, and otherwise
-- the first 'FrameCleanupFailed', 'FrameEffectUncertain' or
-- 'PresentationUncertain'.
progressFrames ∷ Frames q inst msgr phys dev cmd → Instant → IO Progress
progressFrames frames now = owner recording $ do
  limit ← progressActionLimit . modelBudgets <$> atomically (readModel frames)
  failures ← newIORef []
  completed ← newIORef []
  retired ← newIORef []
  cleanups ← newIORef []
  settled ← newIORef []
  -- After the device's loss no fence is asked: one that answers may answer
  -- for a device that no longer runs anything, and none of it would be
  -- completion. The device-loss release is what lets go of it.
  device ← atomically $ do
    lost ← lossObserved frames
    if lost then pure Nothing else deviceOf frames
  for_ device $ \(handle, family) → do
    -- The step's work, as one list rotated to start one place further on
    -- each step: a budget smaller than the work still reaches every piece of
    -- it in turn, so no pending fence can hold back a later one. Work the
    -- step itself creates — a cleanup owed once a submission completed — is
    -- taken by a further pass while the budget lasts, never repeating a piece
    -- already done this step.
    cursor ← atomically (readTVar (framesCursor frames) <* modifyTVar' (framesCursor frames) (+ 1))
    let pending done = filter ((`notElem` done) . workKey) . rotated cursor <$> atomically (stepWork frames)
        passes done used = do
          work ← take (fromIntegral (limit - used)) <$> pending done
          unless (null work) $ do
            -- A call this step made may itself have lost the device, and then
            -- nothing more is asked of it: the rest of the work waits for the
            -- device-loss release.
            mapM_ (\piece → atomically (lossObserved frames) >>= \lost → unless lost (perform piece)) work
            lost ← atomically (lossObserved frames)
            unless lost (passes (map workKey work <> done) (used + fromIntegral (length work)))
        perform = \case
          ObserveSubmission submission record → do
            fence ← fmap syncFence . Map.lookup (submissionSlot record) <$> readTVarIO (framesSlots frames)
            for_ fence $ \native →
              observe handle native $ \case
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
          ObservePresentation presentation record → do
            let key = (presentationTarget presentation, presentedPool record)
            pool ← Map.lookup key <$> readTVarIO (framesPool frames)
            for_ pool $ \held →
              observe handle (poolFence held) $ \case
                Left failure → do
                  let reason = "vkGetFenceStatus raised: " <> describe failure
                  atomically $ do
                    modifyTVar' (framesPresentations frames) (Map.adjust (\entry → entry {presentedStanding = PresentUncertain reason}) presentation)
                    editPool frames key (\entry → entry {poolFenceState = FenceUncertain reason})
                    failRootsSessionBecause roots CleanupFailed (Text.pack (show presentation) <> ": " <> reason)
                  note failures (unlessLoss failure (PresentationUncertain presentation reason))
                Right False → pure ()
                Right True → do
                  recorded ← atomically (retire presentation key)
                  if recorded
                    then modifyIORef' retired (presentation :)
                    else note failures (toException (PresentationUncertain presentation "the model refused a retirement its present fence proved"))
          MakeCleanup frame record → do
            let key = poolOf frame record
            pool ← Map.lookup key <$> readTVarIO (framesPool frames)
            for_ pool $ \held → mask_ $
              cleanupSubmission frames handle family frame (poolRendered held) StageSettling (editPool frames key (\entry → entry {poolRenderedState = SemaphoreWaitOwed})) >>= \case
                Nothing → modifyIORef' cleanups (frame :)
                Just (ExceptionWithContext _ exception) → note failures exception
          ObserveCleanup frame record → do
            sync ← Map.lookup (slotOf frame) <$> readTVarIO (framesSlots frames)
            let released' =
                  release handle frame record >>= \case
                    Left failure → note failures failure
                    Right () → modifyIORef' settled (frame :)
            for_ sync $ \held → case syncCleanupState held of
              FencePending →
                observe handle (syncCleanup held) $ \case
                  Left failure → do
                    let reason = "vkGetFenceStatus raised: " <> describe failure
                    atomically $ do
                      editFrame frames frame (\entry → entry {recordStage = StageFailed reason})
                      editSlot frames (slotOf frame) (\entry → entry {syncCleanupState = FenceUncertain reason})
                      failRootsSessionBecause roots CleanupFailed ("the cleanup fence of " <> Text.pack (show frame) <> ": " <> reason)
                    note failures (unlessLoss failure (FrameCleanupFailed frame reason))
                  Right False → pure ()
                  Right True → do
                    atomically (editSlot frames (slotOf frame) (\entry → entry {syncCleanupState = FenceSignalled}))
                    released'
              -- Signalled at an earlier step, whose release a cancellation kept it
              -- from reaching.
              FenceSignalled → released'
              _ → pure ()
    passes [] 0
  -- Whatever was not reached this step still has its fences pending.
  slots ← Map.elems <$> readTVarIO (framesSlots frames)
  pool ← Map.elems <$> readTVarIO (framesPool frames)
  let pending = length (filter pendingFence (concatMap (\sync → [syncFenceState sync, syncCleanupState sync]) slots <> map poolFenceState pool))
  released ← readIORef settled
  raised ← reverse <$> readIORef failures
  case [failure | failure ← raised, isLoss failure] <> raised of
    first : _ → throwIO first
    [] → pure ()
  Progress
    <$> (reverse <$> readIORef completed)
    <*> (reverse <$> readIORef retired)
    <*> pure (reverse released)
    <*> (reverse <$> readIORef cleanups)
    <*> pure (fromIntegral pending)
  where
    recording = framesRecording frames
    roots = framesRoots frames
    ops = framesOps frames
    -- Asking a fence and recording its answer are one masked step: a failed
    -- query leaves the fence uncertain, and a cancellation landing between the
    -- two would leave that unrecorded.
    observe handle fence record = mask_ (tryWithContext @SomeException (rootsCall roots "vkGetFenceStatus" (opsFenceSignalled ops handle fence)) >>= record)
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
    -- The present fence signalled: the presentation engine has finished with
    -- the semaphore the presentation waited on, so the record is free, and
    -- the model discharges the presentation's hold on its generation.
    retire presentation key = do
      applied ← stateRootsModel roots $ \model → case recordCompletion now (PresentationRetired presentation) model of
        Admitted next → (True, next)
        _ → (False, model)
      if applied
        then do
          modifyTVar' (framesPresentations frames) (Map.delete presentation)
          editPool frames key $ \entry →
            entry {poolFenceState = FenceSignalled, poolRenderedState = SemaphoreUnsignalled, poolHolder = PoolFree}
        else do
          let reason = "the model refused a retirement its present fence proved"
          modifyTVar' (framesPresentations frames) (Map.adjust (\entry → entry {presentedStanding = PresentUncertain reason}) presentation)
          editPool frames key (\entry → entry {poolFenceState = FenceUncertain reason})
          failRootsSessionBecause roots CleanupFailed (Text.pack (show presentation) <> ": " <> reason)
      pure applied
    release handle frame record = mask_ $ do
      let index = fromIntegral (imageIndex (recordImage record)) ∷ Word32
      tryWithContext @SomeException (rootsCall roots "vkReleaseSwapchainImagesEXT" (opsReleaseImages ops handle (recordSwapchain record) [index])) >>= \case
        Left failure → do
          let reason = "vkReleaseSwapchainImagesEXT raised: " <> describe failure
          atomically $ do
            editFrame frames frame (\entry → entry {recordStage = StageFailed reason})
            failRootsSessionBecause roots CleanupFailed (Text.pack (show frame) <> ": " <> reason)
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
                case recordStage record of
                  StageSkipping → editSlot frames (slotOf frame) (\sync → sync {syncAcquireState = SemaphoreUnsignalled})
                  _ → editPool frames (poolOf frame record) (\sync → sync {poolRenderedState = SemaphoreUnsignalled})
                -- The settlement is what lets go of the frame's pool record.
                freePoolOf frames frame
              else uncertain frames CleanupFailed [frame] "the model refused a settlement the release proved"
            pure applied
          pure (if recorded then Right () else Left (toException (FrameEffectUncertain [frame] "the model refused a settlement the release proved")))
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

-- | The longest a protected-drain wait may block the owner: P-15's 10 ms.
drainWaitLimit ∷ Duration
drainWaitLimit = either (error . show) id (durationFromNanoseconds AllowZero 10000000)

-- | One finite protected-drain step: wait, at most the given duration and
-- never longer than 'drainWaitLimit', for the first pending fence of this
-- step's work — a submission's, a cleanup's or a presentation's — to signal,
-- then run 'progressFrames'.
--
-- The wait is only a way not to spin while retirement drains: it has no effect
-- on the fence, and neither its answer nor its timing is evidence of anything.
-- What the following step observes through each fence's own status is the only
-- evidence, as it is for every other step, so a wait that timed out leaves
-- every obligation, every pool record and every retirement exactly as they
-- were — a timeout is a scheduling outcome, never completion. A wait is made
-- only on a fence a queue operation made pending; with none pending it waits
-- for nothing. A wait that raised raises, a device loss latched as always.
awaitFrames ∷ Frames q inst msgr phys dev cmd → Instant → Duration → IO Progress
awaitFrames frames now timeout = do
  owner (framesRecording frames) $ do
    -- Nothing is waited on after the device's loss: the fence may never
    -- signal.
    device ← atomically $ do
      lost ← lossObserved frames
      if lost then pure Nothing else deviceOf frames
    for_ device $ \(handle, _) → do
      cursor ← readTVarIO (framesCursor frames)
      waited ← atomically $ do
        work ← rotated cursor <$> stepWork frames
        slots ← readTVar (framesSlots frames)
        pool ← readTVar (framesPool frames)
        let fenceOf = \case
              ObserveSubmission _ record → syncFence <$> Map.lookup (submissionSlot record) slots
              ObservePresentation presentation record → poolFence <$> Map.lookup (presentationTarget presentation, presentedPool record) pool
              ObserveCleanup frame _ → case Map.lookup (slotOf frame) slots of
                Just sync | syncCleanupState sync == FencePending → Just (syncCleanup sync)
                _ → Nothing
              MakeCleanup _ _ → Nothing
        pure (listToMaybe [fence | Just fence ← map fenceOf work])
      for_ waited $ \fence →
        rootsCall (framesRoots frames) "vkWaitForFences" (opsWaitFence (framesOps frames) handle fence nanoseconds)
  progressFrames frames now
  where
    nanoseconds ∷ Word64
    nanoseconds = fromIntegral (min (durationNanoseconds timeout) (durationNanoseconds drainWaitLimit))

-- | Destroy a target's slot synchronization and presentation pool, once no
-- frame of the target remains, no presentation of it is waiting for its
-- present fence, and nothing of it is bound, pending or uncertain, and forget
-- them. Anything that remains is retained, and 'FramesRetained' is raised
-- naming it; a destruction that raised is retained too, never attempted again,
-- and fails the session.
retireTargetFrames ∷ Frames q inst msgr phys dev cmd → TargetId → IO ()
retireTargetFrames frames target = owner (framesRecording frames) $ do
  -- Once the device is lost, what it could have discharged is let go of
  -- first, under the device-loss rule, and the synchronization below is then
  -- destroyed without waiting for any of it.
  lost ← atomically (lossObserved frames)
  when lost (void (releaseFramesToDeviceLoss frames))
  live ← Map.keys . Map.filterWithKey (\frame _ → frameTarget frame == target) <$> readTVarIO (framesLive frames)
  presentations ← Map.keys . Map.filterWithKey (\presentation _ → presentationTarget presentation == target) <$> readTVarIO (framesPresentations frames)
  slots ← Map.toAscList . Map.filterWithKey (\(owner', _) _ → owner' == target) <$> readTVarIO (framesSlots frames)
  pool ← Map.toAscList . Map.filterWithKey (\(owner', _) _ → owner' == target) <$> readTVarIO (framesPool frames)
  device ← atomically (deviceOf frames)
  let quiet = null live && null presentations
  slotFailures ← fmap concat . forM slots $ \(key, sync) → case device of
    Just (handle, _) | quiet, idleSlot lost sync → mask_ $ do
      outcome ←
        tryWithContext @SomeException $ do
          rootsCall roots "vkDestroySemaphore" (opsDestroySemaphore ops handle (syncAcquire sync))
          rootsCall roots "vkDestroyFence" (opsDestroyFence ops handle (syncFence sync))
          rootsCall roots "vkDestroyFence" (opsDestroyFence ops handle (syncCleanup sync))
      case outcome of
        Right () → [] <$ atomically (modifyTVar' (framesSlots frames) (Map.delete key))
        Left failure@(ExceptionWithContext _ exception) → do
          let reason = "destroying the synchronization of slot " <> Text.pack (show key) <> " raised: " <> Text.pack (displayException exception)
          atomically $ do
            editSlot frames key (\entry → entry {syncFenceState = FenceUncertain reason, syncCleanupState = FenceUncertain reason, syncDestruction = Just reason})
            failRootsSessionBecause roots CleanupFailed reason
          pure [failure]
    _ → pure []
  poolFailures ← fmap concat . forM pool $ \(key, sync) → case device of
    Just (handle, _) | quiet, idlePool lost sync → mask_ $ do
      outcome ←
        tryWithContext @SomeException $ do
          rootsCall roots "vkDestroySemaphore" (opsDestroySemaphore ops handle (poolRendered sync))
          rootsCall roots "vkDestroyFence" (opsDestroyFence ops handle (poolFence sync))
      case outcome of
        Right () → [] <$ atomically (modifyTVar' (framesPool frames) (Map.delete key))
        Left failure@(ExceptionWithContext _ exception) → do
          let reason = "destroying the presentation-pool record " <> Text.pack (show key) <> " raised: " <> Text.pack (displayException exception)
          atomically $ do
            editPool frames key (\entry → entry {poolFenceState = FenceUncertain reason, poolRenderedState = SemaphoreUncertain reason, poolDestruction = Just reason})
            failRootsSessionBecause roots CleanupFailed reason
          pure [failure]
    _ → pure []
  for_ (slotFailures <> poolFailures) rethrowIO
  remainingSlots ← Map.keys . Map.filterWithKey (\(owner', _) _ → owner' == target) <$> readTVarIO (framesSlots frames)
  remainingPool ← Map.keys . Map.filterWithKey (\(owner', _) _ → owner' == target) <$> readTVarIO (framesPool frames)
  unless (quiet && null remainingSlots && null remainingPool) $
    throwIO (FramesRetained target live (map snd remainingSlots) presentations (map snd remainingPool))
  where
    roots = framesRoots frames
    ops = framesOps frames
    -- Under the device-loss rule a fence or a semaphore is destroyed whatever
    -- it was owed, since that may never arrive; one whose destruction already
    -- raised may already be gone, and is destroyed under no rule.
    idleSlot lost sync
      | isJust (syncDestruction sync) = False
      | lost = True
      | otherwise =
          syncAcquireState sync == SemaphoreUnsignalled
            && syncFenceState sync `elem` [FenceIdle, FenceSignalled]
            && syncCleanupState sync `elem` [FenceIdle, FenceSignalled]
    idlePool lost sync
      | isJust (poolDestruction sync) = False
      | lost = poolHolder sync == PoolFree
      | otherwise =
          poolHolder sync == PoolFree
            && poolRenderedState sync == SemaphoreUnsignalled
            && poolFenceState sync `elem` [FenceIdle, FenceSignalled]

-- | One piece of a progress step's work.
data Work
  = ObserveSubmission !SubmissionId !SubmissionRecord
  | ObservePresentation !PresentationId !PresentationRecord
  | MakeCleanup !FrameSlotId !FrameRecord
  | ObserveCleanup !FrameSlotId !FrameRecord

-- | What identifies a piece of work within one step.
workKey ∷ Work → Either (Either SubmissionId PresentationId) (FrameSlotId, Bool)
workKey = \case
  ObserveSubmission submission _ → Left (Left submission)
  ObservePresentation presentation _ → Left (Right presentation)
  MakeCleanup frame _ → Right (frame, False)
  ObserveCleanup frame _ → Right (frame, True)

-- | Every piece of work there is now, in a fixed order the cursor rotates.
stepWork ∷ Frames q inst msgr phys dev cmd → STM [Work]
stepWork frames = do
  submissions ← readTVar (framesSubmissions frames)
  presentations ← readTVar (framesPresentations frames)
  live ← readTVar (framesLive frames)
  pure $
    [ObserveSubmission submission record | (submission, record) ← Map.toAscList submissions]
      <> [ ObservePresentation presentation record
         | (presentation, record) ← Map.toAscList presentations
         , presentedStanding record == PresentPending
         ]
      <> [ MakeCleanup frame record
         | (frame, record) ← Map.toAscList live
         , StageClosing submission ← [recordStage record]
         , not (Map.member submission submissions)
         ]
      <> [ObserveCleanup frame record | (frame, record) ← Map.toAscList live, abandoningStage (recordStage record)]
  where
    abandoningStage = \case
      StageSkipping → True
      StageSettling → True
      _ → False

-- | The list starting at the cursor's place in it.
rotated ∷ Natural → [a] → [a]
rotated _ [] = []
rotated cursor items = drop offset items <> take offset items
  where
    offset = fromIntegral (cursor `mod` fromIntegral (length items))
