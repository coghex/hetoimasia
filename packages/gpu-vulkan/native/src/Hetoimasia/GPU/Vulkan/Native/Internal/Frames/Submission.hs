-- | Submission for the frames ("Hetoimasia.GPU.Vulkan.Native.Frames"):
-- 'submitFrames', which validates a whole request of sealed batches before any
-- native call, then resets one fence, submits every batch on the one graphics
-- queue in the caller's order, and records what the call did — one
-- completion obligation shared by every frame of the request — in the same
-- masked step.
--
-- This module advances frame records, slot synchronization and the
-- render-finished semaphores of presentation-pool records, and inserts
-- submission records, in the frames' state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State"), and records each
-- batch as submitted with the recording
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches"). It owns no
-- state of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Submission
  ( submitFrames
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, fromException, mask_, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM, unless)
import Data.Foldable (for_)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model
  ( FramePhase (FrameAcquired)
  , FrameView (..)
  , Outcome (..)
  , SessionFailureCause (CleanupFailed, UnknownSubmissionEffect)
  , SubmitAnswer (..)
  , SubmitOutcome (..)
  , frameView
  , outcomeModel
  , resetSubmissionFence
  )
import qualified Hetoimasia.GPU.Model as Model
import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , FrameSlotId
  , IdentityKind (..)
  , Misuse (..)
  , TargetId
  , batchSession
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer (FrameOps (..), SubmitBatch (..), WaitStage (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (recoverAllocation, withAllocationAttempt)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches (noteBatchSubmitted)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchRecord (..)
  , BatchStanding (..)
  , ManagedRecord (..)
  , NativeResource (..)
  , Recording (..)
  , Refusal (..)
  , batchHeld
  , checkpointed
  , owned
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost, failRootsSessionBecause, rootsCall, rootsSessionIdentity, stateRootsModel)

-- | One frame of a validated request.
data Member cmd = Member
  { memberBatch ∷ !BatchId
  , memberFrame ∷ !FrameSlotId
  , memberCommands ∷ !cmd
  , memberSync ∷ !SlotSync
  , memberPool ∷ !(TargetId, Natural)
    -- ^ The presentation-pool record the frame holds, whose render-finished
    -- semaphore its batch signals.
  , memberRendered ∷ !Word64
  }

-- | Submit sealed batches, each of its own acquired frame, as one native
-- submission on the session's one graphics queue, in the order given.
--
-- The whole request is validated before any native call: the calling thread,
-- each batch — this session's, sealed, still held by the model and never
-- submitted, and no batch or frame named twice — each frame — acquired by this
-- owner, with its acquisition semaphore owed a signal and the render-finished
-- semaphore of the pool record it holds idle — and the model's acceptance of the whole submission, asked
-- without changing it. A refusal makes no native call.
--
-- Then, in one masked step: the model notes each frame's fence reset, the
-- first frame's slot fence is reset — only now, immediately before the
-- submission it will be passed to — the batches are submitted, each waiting on
-- its frame's acquisition semaphore and signalling the render-finished
-- semaphore of its frame's pool record, and what the call did is recorded:
--
-- * it returned: one submission record in the model that every frame shares,
--   every batch recorded as submitted by it, and the fence pending;
-- * the fence reset raised: nothing was submitted and every frame is still
--   acquired, but the fence is retained for ever as uncertain, admission
--   closes and the session fails, and the failure is re-raised;
-- * it raised a specified no-effect failure: nothing is pending, the fence was
--   reset and is not waited on, and every frame is still acquired with its
--   batch sealed. That is an allocation failure with no effect (VK-14): one
--   reclamation pass runs, and only if it disposed of something is the same
--   request — the same sealed batches, no consumer run again — validated and
--   submitted once more. A second no-effect failure, or none reclaimed, is
--   'SubmittedNothing', naming the original failure and the pass's evidence;
-- * it raised anything else: the effect is unknown. Every frame enters the
--   model's uncertain-effect state, which retains all its parents and stops
--   admission, the session fails, and 'FrameEffectUncertain' is raised — or
--   'Hetoimasia.GPU.Vulkan.Native.Roots.GraphicsDeviceLost', when that is what
--   it was, so the loss is what the caller sees first.
submitFrames ∷ Frames q inst msgr phys dev cmd → NonEmpty BatchId → IO (Either Refusal Submitted)
submitFrames frames request =
  owned recording . checkpointed recording $
    attempt >>= \case
      Right (SubmittedNothing reason) → recoverNoEffect reason
      other → pure other
  where
    attempt =
      atomically validate >>= \case
        Left refusal → pure (Left refusal)
        Right (members, device, family) → submit members device family
    recoverNoEffect reason =
      withAllocationAttempt roots (\allocation → recoverAllocation roots "vkQueueSubmit2" allocation Nothing reason again) >>= \case
        Right (Right submitted) → pure (Right submitted)
        Right (Left notRecovered) → pure (Right (SubmittedNothing (Text.pack (displayException notRecovered))))
        Left _ → pure (Right (SubmittedNothing reason))
    -- The retry is the same request, validated again: a refusal or a second
    -- no-effect failure ends the recovery, and anything it raises — an
    -- unknown effect, device loss — is the caller's as it would have been.
    again =
      attempt >>= \case
        Right (SubmittedAs submission) → pure (Right (SubmittedAs submission))
        Right (SubmittedNothing reason) → pure (Left reason)
        Left refusal → pure (Left ("refused on the retry: " <> Text.pack (show refusal)))
    recording = framesRecording frames
    roots = framesRoots frames
    ops = framesOps frames
    batches = NonEmpty.toList request

    validate
      | any ((/= rootsSessionIdentity roots) . batchSession) batches = pure (Left (RefusedMisuse (ForeignIdentity BatchIdentity)))
      | length (nub batches) /= length batches = pure (Left (RefusedMisuse (DuplicateSubject BatchIdentity)))
      | otherwise = do
          records ← readTVar (recordingBatches recording)
          managed ← readTVar (recordingManaged recording)
          live ← readTVar (framesLive frames)
          slots ← readTVar (framesSlots frames)
          pool ← readTVar (framesPool frames)
          model ← readModel frames
          device ← deviceOf frames
          members ← forM batches $ \batch → do
            held ← batchHeld roots batch
            pure $ case Map.lookup batch records of
              Nothing → Left (RefusedMisuse (AlreadyConsumed BatchIdentity))
              Just record → case batchStanding record of
                BatchSubmitted _ → Left (RefusedMisuse (AlreadyConsumed BatchIdentity))
                BatchSealed
                  | not held → Left (RefusedMisuse (AlreadyConsumed BatchIdentity))
                  | otherwise → do
                      -- A frame-less batch is submitted by itself, never with frames.
                      frame ← maybe (Left (RefusedMisuse (WrongParent BatchIdentity))) Right (batchFrame record)
                      frameRecord ← case Map.lookup frame live of
                        Just acquired@FrameRecord {recordStage = StageAcquired} → Right acquired
                        Just _ → Left (RefusedMisuse (WrongPhase FrameIdentity))
                        Nothing → Left (RefusedMisuse (UnknownIdentity FrameIdentity))
                      case viewFramePhase <$> frameView frame model of
                        Just FrameAcquired → Right ()
                        _ → Left (RefusedMisuse (WrongPhase FrameIdentity))
                      commands ← case managedNative <$> Map.lookup (batchStorage record) managed of
                        Just (NativeStorage _ _ buffer) → Right buffer
                        _ → Left RefusedNoStorage
                      sync ← maybe (Left (RefusedIllegal "the frame's slot has no synchronization")) Right (Map.lookup (slotOf frame) slots)
                      unless (syncAcquireState sync == SemaphoreSignalOwed) $
                        Left (RefusedIllegal ("the frame's synchronization is not ready to submit: " <> Text.pack (show sync)))
                      let key = poolOf frame frameRecord
                      record' ← maybe (Left (RefusedIllegal "the frame holds no presentation-pool record")) Right (Map.lookup key pool)
                      unless (poolHolder record' == PoolHeldByFrame frame && poolRenderedState record' == SemaphoreUnsignalled) $
                        Left (RefusedIllegal ("the frame's presentation-pool record is not ready to submit: " <> Text.pack (show record')))
                      pure (Member batch frame commands sync key (poolRendered record'))
                _ → Left (RefusedMisuse (WrongPhase BatchIdentity))
          pure $ do
            resolved ← sequence members
            let framesOf = map memberFrame resolved
            unless (length (nub framesOf) == length framesOf) (Left (RefusedMisuse (DuplicateSubject FrameIdentity)))
            nonEmpty ← maybe (Left (RefusedMisuse EmptySubmission)) Right (NonEmpty.nonEmpty resolved)
            let leader = memberSync (NonEmpty.head nonEmpty)
            unless (syncFenceState leader `elem` [FenceIdle, FenceSignalled]) $
              Left (RefusedIllegal ("the submission fence is not idle: " <> Text.pack (show (syncFenceState leader))))
            -- The model's acceptance of the whole request, asked of a copy it
            -- then discards.
            case Model.submitFrames framesOf SubmissionAccepted model of
              Rejected misuse → Left (RefusedMisuse misuse)
              Backpressure kind → Left (RefusedBackpressure kind)
              Admitted _ → Right ()
            (handle, family) ← maybe (Left RefusedDeviceAbsent) Right device
            pure (nonEmpty, handle, family)

    submit request' device family = mask_ $ do
      let members = NonEmpty.toList request'
          framesOf = map memberFrame members
          first = NonEmpty.head request'
          key = slotOf (memberFrame first)
          fence = syncFence (memberSync first)
          native =
            [ SubmitBatch
                { submitWaits = [syncAcquire (memberSync member)]
                , submitWaitStage = WaitAtColorOutput
                , submitCommands = [memberCommands member]
                , submitSignals = [memberRendered member]
                }
            | member ← members
            ]
      atomically $ for_ framesOf $ \frame → stateRootsModel roots $ \model → case resetSubmissionFence frame model of
        Admitted next → ((), next)
        _ → ((), model)
      tryWithContext @SomeException (rootsCall roots "vkResetFences" (opsResetFence ops device fence)) >>= \case
        Left failure@(ExceptionWithContext _ exception) → do
          -- Nothing was submitted, and every frame is still acquired; but the
          -- fence itself is now in doubt, so it is retained for ever, and
          -- native synchronization safety being unknown, admission stops and
          -- the session fails.
          atomically $ do
            answered Model.submitFrames framesOf SubmissionFailedWithoutEffect
            editSlot frames key (\sync → sync {syncFenceState = FenceUncertain (Text.pack (displayException exception))})
            failRootsSessionBecause roots CleanupFailed ("resetting the submission fence of slot " <> Text.pack (show key) <> " raised: " <> Text.pack (displayException exception))
          rethrowIO failure
        Right () → do
          atomically (editSlot frames key (\sync → sync {syncFenceState = FenceIdle}))
          tryWithContext @SomeException (rootsCall roots "vkQueueSubmit2" (opsSubmit ops device family native fence)) >>= \case
            Right () → accepted members key
            Left failure@(ExceptionWithContext _ exception)
              | opsNoEffect ops exception → do
                  atomically (answered Model.submitFrames framesOf SubmissionFailedWithoutEffect)
                  pure (Right (SubmittedNothing (Text.pack (displayException exception))))
              | otherwise → do
                  let reason = "vkQueueSubmit2 raised, so whether it submitted is unknown: " <> Text.pack (displayException exception)
                  atomically $ do
                    answered Model.submitFrames framesOf SubmissionEffectUncertain
                    uncertain frames UnknownSubmissionEffect framesOf reason
                    editSlot frames key (\sync → sync {syncFenceState = FenceUncertain reason})
                    for_ members $ \member → do
                      editSlot frames (slotOf (memberFrame member)) (\sync → sync {syncAcquireState = SemaphoreUncertain reason})
                      editPool frames (memberPool member) (\held → held {poolRenderedState = SemaphoreUncertain reason})
                  case fromException exception ∷ Maybe GraphicsDeviceLost of
                    Just _ → rethrowIO failure
                    Nothing → throwIO (FrameEffectUncertain framesOf reason)

    -- Commit a submission that returned. The model accepted this exact
    -- request a moment ago on this thread, and nothing else changes it
    -- between, so a refusal now is an effect whose bookkeeping cannot commit.
    accepted members key = do
      let framesOf = map memberFrame members
      committed ← atomically $ do
        answer ← stateRootsModel roots $ \model → case Model.submitFrames framesOf SubmissionAccepted model of
          Admitted (next, SubmissionRecorded submission) → (Just submission, next)
          _ → (Nothing, model)
        case answer of
          Nothing → pure Nothing
          Just submission → do
            for_ members $ \member → do
              editFrame frames (memberFrame member) (\record → record {recordStage = StageSubmitted submission})
              editSlot frames (slotOf (memberFrame member)) (\sync → sync {syncAcquireState = SemaphoreWaitOwed})
              editPool frames (memberPool member) (\held → held {poolRenderedState = SemaphoreSignalOwed})
            editSlot frames key (\sync → sync {syncFenceState = FencePending})
            modifyTVar' (framesSubmissions frames) (Map.insert submission (SubmissionRecord key framesOf))
            pure (Just submission)
      case committed of
        Nothing → do
          -- The refusal left the model as it was: the unknown effect is
          -- recorded in a transaction of its own.
          let reason = "the model refused to record a submission the queue accepted"
          atomically $ do
            answered Model.submitFrames framesOf SubmissionEffectUncertain
            uncertain frames UnknownSubmissionEffect framesOf reason
            editSlot frames key (\sync → sync {syncFenceState = FenceUncertain reason})
          throwIO (FrameEffectUncertain framesOf reason)
        Just submission → do
          -- The recording's own evidence that each batch's work was
          -- submitted, which its readback needs; the model has already
          -- consumed every batch, so none can be refused here.
          for_ members $ \member → noteBatchSubmitted recording (memberBatch member) submission
          pure (Right (SubmittedAs submission))

    answered operation framesOf outcome = stateRootsModel roots $ \model → case outcomeModel (operation framesOf outcome model) of
      Admitted next → ((), next)
      _ → ((), model)
