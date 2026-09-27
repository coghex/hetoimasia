-- | Presentation for the frames ("Hetoimasia.GPU.Vulkan.Native.Frames"):
-- 'presentFrame', which validates a submitted frame before any native call,
-- then resets its pool record's present fence, presents its image on the one
-- graphics queue waiting on the record's render-finished semaphore, and
-- records what the presentation engine answered for the swapchain in the same
-- masked step; and 'classifyPresent', the pure reading of that answer.
--
-- This module removes frame records, inserts presentation records, and
-- advances and rebinds presentation-pool records in the frames' state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State"), and reports a
-- suboptimal or out-of-date answer to the generations. It owns no state of its
-- own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Presentation
  ( presentFrame
  , PresentReading (..)
  , classifyPresent
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , displayException
  , fromException
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (unless, void)
import Data.IORef (newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

import Hetoimasia.GPU.Model
  ( FramePhase (FrameSubmitted)
  , FrameView (..)
  , Outcome (..)
  , PresentAnswer (..)
  , PresentOutcome (..)
  , SessionFailureCause (CleanupFailed, UnknownSubmissionEffect)
  , SessionState (SessionRunning)
  , enqueuePresentation
  , frameView
  , sessionState
  )
import Hetoimasia.GPU.Model.Identity (FrameSlotId, IdentityKind (..), Misuse (..), imageGeneration, imageIndex)
import Hetoimasia.GPU.Vulkan.Native.Generations (SwapchainResult (..), noteSwapchainResult)
import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (recoverAllocation, withAllocationAttempt)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer (FrameOps (..), PresentRequest (..), PresentStatus (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State (Refusal (..), owned)
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost, failRootsSession, rootsCall, stateRootsModel)

-- | What a presentation's answer establishes about its effect.
data PresentReading
  = ReadEnqueued !PresentOutcome
    -- ^ The presentation was enqueued, with this answer for the swapchain: the
    -- semaphore wait is the presentation engine's, and the present fence is
    -- pending.
  | ReadNotEnqueued !Text
    -- ^ The specified no-effect failure: nothing was enqueued, and no present
    -- fence.
  | ReadUnknown !Text
    -- ^ What happened cannot be read from the answer.
  deriving (Eq, Show)

-- | Read one presentation's answer: whether the call raised — the failure,
-- recognized by the layer's 'opsNoEffect' when it is the specified no-effect
-- one — and the swapchain's own entry of @pResults@.
--
-- The swapchain's entry is the truth for the swapchain, and it must agree with
-- the call: a call that returned answers success or suboptimal for its one
-- swapchain, and one that raised answers the error it raised with.
--
-- * Success and suboptimal from a call that returned, and out of date and
--   surface lost from one that raised, were enqueued: the specification keeps
--   the queue operations of a presentation the presentation engine rejected
--   out of date or surface lost, and the semaphore waits happen.
-- * Out of memory raised enqueued nothing and no present fence, whatever the
--   entry holds — unless the entry says something other than out of memory or
--   nothing at all, which contradicts it.
-- * Everything else is unknown: an entry the call never wrote is never read as
--   success, and neither is a contradiction, device loss, or a result the
--   profile does not classify.
classifyPresent ∷ (SomeException → Bool) → Maybe SomeException → PresentStatus → PresentReading
classifyPresent noEffect raised status = case raised of
  Just failure
    | noEffect failure → case status of
        PresentStatusUnwritten → ReadNotEnqueued (describe failure)
        PresentStatusOutOfMemory → ReadNotEnqueued (describe failure)
        other → ReadUnknown ("the presentation raised the no-effect " <> describe failure <> ", but the swapchain answered " <> shown other)
    | otherwise → case status of
        PresentStatusOutOfDate → ReadEnqueued PresentationEnqueuedOutOfDate
        PresentStatusSurfaceLost → ReadEnqueued PresentationEnqueuedSurfaceLost
        PresentStatusUnwritten → ReadUnknown ("the presentation raised " <> describe failure <> " and never wrote the swapchain's result")
        other → ReadUnknown ("the presentation raised " <> describe failure <> ", and the swapchain answered " <> shown other)
  Nothing → case status of
    PresentStatusSuccess → ReadEnqueued PresentationEnqueued
    PresentStatusSuboptimal → ReadEnqueued PresentationEnqueuedSuboptimal
    PresentStatusUnwritten → ReadUnknown "the presentation returned and never wrote the swapchain's result"
    other → ReadUnknown ("the presentation returned, but the swapchain answered " <> shown other)
  where
    describe = Text.pack . displayException
    shown ∷ Show a ⇒ a → Text
    shown = Text.pack . show

-- | Present a submitted frame's image on the session's one graphics queue.
--
-- The whole request is validated before any native call: the calling thread;
-- the session, which must not have failed; the frame — acquired by this owner,
-- submitted, and neither presented nor abandoned; the model's acceptance of its presentation, asked of a copy it
-- then discards; and the frame's pool record — bound to it at its reservation,
-- its render-finished semaphore owed the submission's signal, its present fence
-- not pending. Nothing is made, waited for or reserved here: the pool record
-- was reserved and bound when the frame was, so presenting is never refused
-- for capacity. The frame's rendering need not have completed; the
-- presentation waits for it on the device.
--
-- Then, in one masked step, the pool record's present fence is reset — only
-- now, immediately before the one presentation it is passed to — the image is
-- presented to the swapchain it was acquired from, waiting on the record's
-- render-finished semaphore, with that fence chained to it, and what the call
-- did is read by 'classifyPresent' and recorded:
--
-- * enqueued: the model records the presentation, which holds the frame's pool
--   record and its generation's presentation hold until the present fence
--   signals, and frees the frame's slot once its submission has completed too.
--   The frame's record here gives way to the presentation's; the semaphore is
--   the presentation engine's; the fence is pending. A suboptimal, out-of-date
--   or surface-lost answer has requested the target's replacement from the
--   model, and each is reported to the generations so the owner's next step
--   reconciles — a lost surface is replaced (VK-14); the frame's
--   synchronization is not reset. 'PresentedAs' is answered.
-- * not enqueued: nothing changes but the fence, reset and never pending, and
--   never waited on. The frame is still submitted. That is an allocation
--   failure with no effect (VK-14): one reclamation pass runs, and only if it
--   disposed of something is the same frame presented once more. A second
--   failure to enqueue, or none reclaimed, answers 'PresentedNothing', naming
--   the original failure and the pass's evidence; the frame can be presented
--   again or closed.
-- * the fence reset raised: nothing was presented, but the fence is in doubt,
--   so it is retained for ever with its record, admission closes and the
--   session fails, and the failure is re-raised. The frame can still be
--   closed.
-- * unknown: the frame enters the uncertain state, which retains it, its image,
--   its record and every parent for ever and stops admission; the session
--   fails, and 'FrameEffectUncertain' is raised — or the device loss itself.
--
-- A cancellation aimed at the owner is delivered only after that record is
-- made. The call itself may block in the driver: the handoff promises a
-- recorded outcome, not a prompt return, and it never interrupts the call.
presentFrame ∷ Frames q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal Presented)
presentFrame frames frame =
  owned recording $
    attempt >>= \case
      Right (PresentedNothing reason) → recoverNoEffect reason
      other → pure other
  where
    attempt =
      atomically validate >>= \case
        Left refusal → pure (Left refusal)
        Right (record, held, device, family) → present record held device family
    recoverNoEffect reason =
      withAllocationAttempt roots (\allocation → recoverAllocation roots "vkQueuePresentKHR" allocation Nothing reason again) >>= \case
        Right (Right presented) → pure (Right presented)
        Right (Left notRecovered) → pure (Right (PresentedNothing (Text.pack (displayException notRecovered))))
        Left _ → pure (Right (PresentedNothing reason))
    -- The retry is the same frame's presentation, validated again: a refusal
    -- or a second failure to enqueue ends the recovery, and anything it raises
    -- is the caller's as it would have been.
    again =
      attempt >>= \case
        Right (PresentedAs presentation outcome) → pure (Right (PresentedAs presentation outcome))
        Right (PresentedNothing reason) → pure (Left reason)
        Left refusal → pure (Left ("refused on the retry: " <> Text.pack (show refusal)))
    recording = framesRecording frames
    roots = framesRoots frames
    ops = framesOps frames

    validate = do
      live ← Map.lookup frame <$> readTVar (framesLive frames)
      pool ← readTVar (framesPool frames)
      model ← readModel frames
      device ← deviceOf frames
      unknown ← frameMisuse frames model frame (\identity → enqueuePresentation identity PresentationEnqueued)
      pure $ case live of
        Nothing → Left (RefusedMisuse unknown)
        Just record → case recordStage record of
          StageSubmitted _ → do
            -- A failed session makes no new native effect: the frame's exit
            -- is its close.
            unless (sessionState model == SessionRunning) $
              Left (RefusedMisuse SessionAlreadyFailed)
            unless ((viewFramePhase <$> frameView frame model) == Just FrameSubmitted) $
              Left (RefusedMisuse (WrongPhase FrameIdentity))
            -- The model's acceptance, asked of a copy it then discards.
            case enqueuePresentation frame PresentationEnqueued model of
              Rejected misuse → Left (RefusedMisuse misuse)
              Backpressure kind → Left (RefusedBackpressure kind)
              Admitted _ → Right ()
            held ← maybe (Left (RefusedIllegal "the frame holds no presentation-pool record")) Right (Map.lookup (poolOf frame record) pool)
            unless
              ( poolHolder held == PoolHeldByFrame frame
                  && poolRenderedState held == SemaphoreSignalOwed
                  && poolFenceState held `elem` [FenceIdle, FenceSignalled]
              )
              $ Left (RefusedIllegal ("the frame's presentation-pool record is not ready to present: " <> Text.pack (show held)))
            (handle, family) ← maybe (Left RefusedDeviceAbsent) Right device
            pure (record, held, handle, family)
          _ → Left (RefusedMisuse (WrongPhase FrameIdentity))

    present record held device family = mask_ $ do
      let key = poolOf frame record
          fence = poolFence held
          request =
            PresentRequest
              { presentSwapchain = recordSwapchain record
              , presentIndex = fromIntegral (imageIndex (recordImage record))
              , presentWait = poolRendered held
              , presentFence = fence
              }
      tryWithContext @SomeException (rootsCall roots "vkResetFences" (opsResetFence ops device fence)) >>= \case
        Left failure@(ExceptionWithContext _ exception) → do
          -- Nothing was presented and the frame is still submitted; but the
          -- fence itself is in doubt, so it is retained for ever with its
          -- record, and admission stops.
          atomically $ do
            editPool frames key (\entry → entry {poolFenceState = FenceUncertain (Text.pack (displayException exception))})
            failRootsSession roots CleanupFailed
          rethrowIO failure
        Right () → do
          atomically (editPool frames key (\entry → entry {poolFenceState = FenceIdle}))
          status ← newIORef PresentStatusUnwritten
          raised ← tryWithContext @SomeException (rootsCall roots "vkQueuePresentKHR" (opsPresent ops device family request status))
          written ← readIORef status
          let failure = either (\(ExceptionWithContext _ exception) → Just exception) (const Nothing) raised
          case classifyPresent (opsNoEffect ops) failure written of
            ReadEnqueued outcome → enqueued record key outcome
            ReadNotEnqueued reason → pure (Right (PresentedNothing reason))
            ReadUnknown reason → do
              let why = "whether vkQueuePresentKHR enqueued the presentation is unknown: " <> reason
              atomically $ do
                uncertain frames UnknownSubmissionEffect [frame] why
                editPool frames key (\entry → entry {poolFenceState = FenceUncertain why, poolRenderedState = SemaphoreUncertain why})
              case raised of
                Left loss@(ExceptionWithContext _ exception) | isLoss exception → rethrowIO loss
                _ → throwIO (FrameEffectUncertain [frame] why)

    isLoss exception = case fromException exception ∷ Maybe GraphicsDeviceLost of
      Just _ → True
      Nothing → False

    -- Commit a presentation the presentation engine enqueued. The model
    -- accepted this exact presentation a moment ago on this thread, and
    -- nothing else changes it between, so a refusal now is an effect whose
    -- bookkeeping cannot commit.
    enqueued record key outcome = do
      committed ← atomically $ do
        answer ← stateRootsModel roots $ \model → case enqueuePresentation frame outcome model of
          Admitted (next, PresentationTracked presentation) → (Just presentation, next)
          _ → (Nothing, model)
        case answer of
          Nothing → do
            let reason = "the model refused to record a presentation the presentation engine enqueued"
            uncertain frames UnknownSubmissionEffect [frame] reason
            editPool frames key (\entry → entry {poolFenceState = FenceUncertain reason, poolRenderedState = SemaphoreUncertain reason})
            pure (Left reason)
          Just presentation → do
            editPool frames key $ \entry →
              entry
                { poolRenderedState = SemaphoreWaitOwed
                , poolFenceState = FencePending
                , poolHolder = PoolHeldByPresentation presentation
                }
            modifyTVar' (framesLive frames) (Map.delete frame)
            modifyTVar' (framesPresentations frames) $
              Map.insert presentation (PresentationRecord frame (recordImage record) (recordPool record) outcome PresentPending)
            let generation = imageGeneration (recordImage record)
            case outcome of
              PresentationEnqueuedSuboptimal → void (noteSwapchainResult (framesGenerations frames) generation SwapchainSuboptimal)
              PresentationEnqueuedOutOfDate → void (noteSwapchainResult (framesGenerations frames) generation SwapchainOutOfDate)
              PresentationEnqueuedSurfaceLost → void (noteSwapchainResult (framesGenerations frames) generation SwapchainSurfaceLost)
              _ → pure ()
            pure (Right presentation)
      case committed of
        Left reason → throwIO (FrameEffectUncertain [frame] reason)
        Right presentation → pure (Right (PresentedAs presentation outcome))
