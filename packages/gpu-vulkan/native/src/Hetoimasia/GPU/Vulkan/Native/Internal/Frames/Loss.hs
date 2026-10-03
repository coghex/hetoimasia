-- | Device-loss release for the frames ("Hetoimasia.GPU.Vulkan.Native.Frames"):
-- once the session's device has been lost, letting go of every obligation only
-- that device could have discharged, so that a target's retirement can
-- destroy its synchronization without waiting for work that may never
-- complete.
--
-- This module skips acquired frames — through 'skipFrame', which makes no
-- cleanup submission once the loss is recorded — forgets unsubmitted
-- frame-less batches, removes frame, submission, frame-less submission and
-- presentation records, frees presentation-pool records, marks pending fences
-- and owed semaphores lost, and settles the tickets of frame-less batches it
-- let go of as lost, in the frames' state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State"). It owns no state of
-- its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Loss
  ( releaseFramesToDeviceLoss
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception (mask_)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import qualified Data.Set as Set

import Hetoimasia.GPU.Model (DeviceLossRelease (..), Outcome (..), releaseToDeviceLoss)
import qualified Hetoimasia.GPU.Model as Model
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Abandonment (skipFrame)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchRecord (..)
  , BatchStanding (..)
  , Recording (..)
  , Refusal (..)
  , TicketState (..)
  , owned
  , settleTicket
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (stateRootsModel)

-- | Let go, under the specification's device-loss rule, of every obligation
-- the lost device could have discharged, on every target.
--
-- It is refused unless the loss has been recorded. Then every frame still
-- acquired is skipped: its unsubmitted recording is invalidated and the model
-- skips it, and no cleanup submission is made. The model releases every
-- submission, every presentation and every frame that had left acquisition
-- ('releaseToDeviceLoss'), and so do the records here: each pending fence
-- becomes 'FenceLost' and each owed semaphore 'SemaphoreLost', and each
-- presentation-pool record the released frames and presentations held is
-- free.
--
-- Nothing is waited on, nothing is asked of a fence, and nothing becomes
-- complete: no fence is marked signalled, no submission completed and no
-- presentation retired. What it answers is the model's account of what it let
-- go, and of the frames it could not — one whose skip was refused stays
-- acquired, and retains its target. A second release lets go of nothing more.
releaseFramesToDeviceLoss ∷ Frames q inst msgr phys dev cmd → IO (Either Refusal DeviceLossRelease)
releaseFramesToDeviceLoss frames =
  owned recording $
    atomically (lossObserved frames) >>= \case
      False → pure (Left (RefusedIllegal "the device has not been lost"))
      True → do
        live ← Map.toAscList <$> readTVarIO (framesLive frames)
        for_ [frame | (frame, record) ← live, recordStage record == StageAcquired] (skipFrame frames)
        mask_ . atomically $ do
          -- An unsubmitted frame-less batch can never run on the lost device:
          -- the model lets go of its references, its record goes with no
          -- native invalidation — its storage's destruction frees its
          -- commands under the device-loss rule — and its ticket is lost.
          batches ← Map.toList <$> readTVar (recordingBatches recording)
          for_ [(batch, record) | (batch, record) ← batches, isNothing (batchFrame record), not (submitted (batchStanding record))] $ \(batch, record) → do
            stateRootsModel (framesRoots frames) $ \model → case Model.discardBatch batch model of
              Admitted next → ((), next)
              _ → ((), model)
            for_ (batchTicket record) (`settleTicket` TicketLost)
            modifyTVar' (recordingBatches recording) (Map.delete batch)
          answer ← stateRootsModel (framesRoots frames) $ \model → case releaseToDeviceLoss model of
            Admitted (next, report) → (Right report, next)
            Rejected misuse → (Left (RefusedMisuse misuse), model)
            Backpressure kind → (Left (RefusedBackpressure kind), model)
          for_ answer $ \report → do
            let released = Set.fromList (releasedFrames report)
                submissions = Set.fromList (releasedSubmissions report)
                presentations = Set.fromList (releasedPresentations report)
                freed = \case
                  PoolHeldByFrame frame → frame `Set.member` released
                  PoolHeldByPresentation presentation → presentation `Set.member` presentations
                  PoolFree → False
            modifyTVar' (framesLive frames) (Map.filterWithKey (\frame _ → frame `Set.notMember` released))
            modifyTVar' (framesSubmissions frames) (Map.filterWithKey (\submission _ → submission `Set.notMember` submissions))
            framelessHeld ← readTVar (framesFramelessSubmissions frames)
            for_ [record | (submission, record) ← Map.toList framelessHeld, submission `Set.member` submissions] $ \record →
              for_ (framelessTicket record) (`settleTicket` TicketLost)
            modifyTVar' (framesFramelessSubmissions frames) (Map.filterWithKey (\submission _ → submission `Set.notMember` submissions))
            modifyTVar' (framesFrameless frames) (Map.map (\sync → sync {framelessFenceState = lostFence (framelessFenceState sync)}))
            modifyTVar' (framesPresentations frames) (Map.filterWithKey (\presentation _ → presentation `Set.notMember` presentations))
            modifyTVar' (framesSlots frames) . Map.map $ \sync →
              sync
                { syncAcquireState = lostSemaphore (syncAcquireState sync)
                , syncFenceState = lostFence (syncFenceState sync)
                , syncCleanupState = lostFence (syncCleanupState sync)
                }
            modifyTVar' (framesPool frames) . Map.map $ \sync →
              sync
                { poolRenderedState = lostSemaphore (poolRenderedState sync)
                , poolFenceState = lostFence (poolFenceState sync)
                , poolHolder = if freed (poolHolder sync) then PoolFree else poolHolder sync
                }
          pure answer
  where
    recording = framesRecording frames
    lostFence = \case
      FencePending → FenceLost
      other → other
    lostSemaphore = \case
      SemaphoreSignalOwed → SemaphoreLost
      SemaphoreWaitOwed → SemaphoreLost
      other → other
    submitted = \case
      BatchSubmitted _ → True
      _ → False
