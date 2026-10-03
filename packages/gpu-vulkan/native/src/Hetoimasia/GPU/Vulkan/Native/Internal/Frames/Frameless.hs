-- | Frame-less batches for the frames ("Hetoimasia.GPU.Vulkan.Native.Frames")
-- (GRS-12): a scope in which a consumer records batches that belong to no
-- frame, each submitted by itself on the one graphics queue when the scope
-- ends normally, in the order they were sealed, and discarded when it does
-- not; the submission itself; and retiring the frame-less slots' fences.
--
-- A frame-less batch is recorded by the recording
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder"'s
-- 'recordFrameless'); its completion is observed by the owner's progress step
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Progress"), and released on
-- device loss by "Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Loss".
--
-- This module creates and destroys frame-less fences and inserts frame-less
-- submission records, in the frames' state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State"), and records each
-- batch as submitted with the recording. A scope's own record of the batches
-- opened and sealed in it lives as long as the scope, on the owner's thread.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Frameless
  ( -- * Scopes
    FramelessScope
  , withFramelessScope
  , recordFramelessIn

    -- * Submission
  , submitFrameless

    -- * Retirement
  , retireFrameless
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , displayException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (unless, when)
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as Text

import Hetoimasia.GPU.Model
  ( FramelessView (..)
  , Outcome (..)
  , SessionFailureCause (CleanupFailed, UnknownSubmissionEffect)
  , SubmitAnswer (..)
  , SubmitOutcome (..)
  , framelessSlots
  , outcomeModel
  , submitFramelessBatch
  )
import Hetoimasia.GPU.Model.Identity (BatchId, IdentityKind (..), Misuse (..), batchSession)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer (FrameOps (..), SubmitBatch (..), WaitStage (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Loss (releaseFramesToDeviceLoss)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (recoverAllocation, recoveringCreation, withAllocationAttempt)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches (discardBatch, noteBatchSubmitted)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder (Recorder, recordFrameless)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchRecord (..)
  , BatchStanding (..)
  , BatchTicket (..)
  , ManagedRecord (..)
  , NativeResource (..)
  , Recording (..)
  , Refusal (..)
  , batchHeld
  , checkpointed
  , owned
  , owner
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost, failRootsSessionBecause, rootsCall, rootsSessionIdentity, stateRootsModel)

-- ---------------------------------------------------------------------------
-- Scopes

-- | One consumer action's frame-less batches: the batches opened in it, and
-- those sealed, in the order they were sealed.
data FramelessScope q inst msgr phys dev cmd = FramelessScope
  { scopeFrames ∷ !(Frames q inst msgr phys dev cmd)
  , scopeOpened ∷ !(IORef [BatchId])
    -- ^ Newest first.
  , scopeSealed ∷ !(IORef [BatchId])
    -- ^ Newest first.
  , scopeOpen ∷ !(IORef Bool)
  }

-- | Run one consumer action with a scope to record frame-less batches in, and
-- settle every batch opened in it when the action ends.
--
-- * When the action returns, its sealed batches are submitted, each as a
--   native submission of its own on the one graphics queue, in the order they
--   were sealed — before anything else the owner submits after the action.
--   A submission the queue accepted stays accepted whatever follows it. The
--   first that is refused, or that failed with no effect after its one
--   recovery, is discarded with every batch sealed after it. Then every batch
--   that was left partial is discarded, as only a discard ends one.
-- * When the action raises or is cancelled, nothing is submitted: every batch
--   opened in it is discarded, and the action's own failure is re-raised.
-- * A submission whose effect is unknown, or the device's loss, raises: the
--   batches it did not reach are discarded first, or after the loss let go of
--   under the device-loss rule, and the raise goes on. A discard that raised
--   keeps its storage and batch, uncertain, and the failure the scope was
--   already raising is the one raised.
--
-- Every discard settles the batch's ticket as discarded; a submission leaves
-- its ticket pending until the owner's progress observes its fence.
withFramelessScope ∷ Frames q inst msgr phys dev cmd → (FramelessScope q inst msgr phys dev cmd → IO a) → IO a
withFramelessScope frames body = mask $ \restore → do
  scope ← FramelessScope frames <$> newIORef [] <*> newIORef [] <*> newIORef True
  outcome ← tryWithContext @SomeException (restore (body scope))
  writeIORef (scopeOpen scope) False
  opened ← reverse <$> readIORef (scopeOpened scope)
  sealed ← reverse <$> readIORef (scopeSealed scope)
  case outcome of
    Left failure → do
      settle frames opened
      rethrowIO failure
    Right value → do
      submitted ← submitInOrder sealed
      case submitted of
        Left (accepted, failure) → do
          settle frames (filter (`notElem` accepted) opened)
          rethrowIO failure
        Right accepted → do
          settle frames (filter (`notElem` accepted) opened)
          pure value
  where
    -- The sealed batches, in order, until one is not accepted: answers the
    -- accepted ones, and the failure one raised.
    submitInOrder = go []
      where
        go accepted = \case
          [] → pure (Right (reverse accepted))
          batch : rest →
            tryWithContext @SomeException (submitFrameless frames batch) >>= \case
              Right (Right (SubmittedAs _)) → go (batch : accepted) rest
              Right _ → pure (Right (reverse accepted))
              Left failure → pure (Left (reverse accepted, failure))

-- | Discard every batch named that the recording still holds unsubmitted.
-- Before each discard the device's loss is asked again: once it is lost —
-- before the first, or by an earlier discard's reset — every unsubmitted
-- frame-less batch left is let go of under the device-loss rule, with no
-- native call, its ticket lost. A discard that raised is kept as the
-- recording keeps it, and the rest are still settled.
settle ∷ Frames q inst msgr phys dev cmd → [BatchId] → IO ()
settle frames = \case
  [] → pure ()
  batch : rest →
    atomically (lossObserved frames) >>= \case
      True → () <$ releaseFramesToDeviceLoss frames
      False → do
        held ← Map.lookup batch <$> readTVarIO (recordingBatches (framesRecording frames))
        case batchStanding <$> held of
          Just (BatchSubmitted _) → pure ()
          Just (BatchUncertain _) → pure ()
          Just _ → () <$ tryWithContext @SomeException (discardBatch (framesRecording frames) batch)
          Nothing → pure ()
        settle frames rest

-- | Record one frame-less batch in the scope: see
-- 'Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder.recordFrameless'.
-- A scope whose action has ended records nothing.
recordFramelessIn
  ∷ FramelessScope q inst msgr phys dev cmd
  → (Recorder q inst msgr phys dev cmd → IO a)
  → IO (Either Refusal (BatchTicket, a))
recordFramelessIn scope consumer =
  readIORef (scopeOpen scope) >>= \case
    False → pure (Left RefusedRecorderClosed)
    True → do
      recorded ← recordFrameless (framesRecording (scopeFrames scope)) (\ticket → modifyIORef' (scopeOpened scope) (ticketBatch ticket :)) consumer
      for_ recorded $ \(ticket, _) → modifyIORef' (scopeSealed scope) (ticketBatch ticket :)
      pure recorded

-- ---------------------------------------------------------------------------
-- Submission

-- | Submit one sealed frame-less batch as a native submission of its own, on
-- the session's one graphics queue: no wait, no signal but its slot's fence.
--
-- Everything is validated before any native call: the calling thread, the
-- batch — this session's, frame-less, sealed, held by the model and never
-- submitted — its slot's live storage, and the model's acceptance, asked of a
-- copy it then discards. Then, in one masked step, the slot's fence is made
-- if it has none yet, or reset if a submission signalled it, the batch is
-- submitted, and what the call did is recorded, as a frame submission's is:
--
-- * it returned: the model's submission record, the batch recorded as
--   submitted, and the fence pending;
-- * the fence's reset raised: nothing was submitted, the fence is retained
--   as uncertain, and the session fails;
-- * a specified no-effect failure: nothing is pending and the batch is still
--   sealed and held. One reclamation pass runs, and only if it disposed of
--   something is the same batch submitted once more; otherwise
--   'SubmittedNothing';
-- * anything else: the effect is unknown. The model records the submission
--   uncertain, which retains everything and stops admission, the session
--   fails, and 'FramelessEffectUncertain' is raised — or the device's loss.
submitFrameless ∷ Frames q inst msgr phys dev cmd → BatchId → IO (Either Refusal Submitted)
submitFrameless frames batch =
  owned recording . checkpointed recording $
    attempt >>= \case
      Right (SubmittedNothing reason) → recoverNoEffect reason
      other → pure other
  where
    recording = framesRecording frames
    roots = framesRoots frames
    ops = framesOps frames
    attempt =
      atomically validate >>= \case
        Left refusal → pure (Left refusal)
        Right (commands, ticket, slot, device, family) → submit commands ticket slot device family
    recoverNoEffect reason =
      withAllocationAttempt roots (\allocation → recoverAllocation roots "vkQueueSubmit2" allocation Nothing reason again) >>= \case
        Right (Right submitted) → pure (Right submitted)
        Right (Left notRecovered) → pure (Right (SubmittedNothing (Text.pack (displayException notRecovered))))
        Left _ → pure (Right (SubmittedNothing reason))
    again =
      attempt >>= \case
        Right (SubmittedAs submission) → pure (Right (SubmittedAs submission))
        Right (SubmittedNothing reason) → pure (Left reason)
        Left refusal → pure (Left ("refused on the retry: " <> Text.pack (show refusal)))

    validate
      | batchSession batch /= rootsSessionIdentity roots = pure (Left (RefusedMisuse (ForeignIdentity BatchIdentity)))
      | otherwise = do
          records ← readTVar (recordingBatches recording)
          managed ← readTVar (recordingManaged recording)
          held ← batchHeld roots batch
          model ← readModel frames
          device ← deviceOf frames
          pure $ do
            record ← maybe (Left (RefusedMisuse (AlreadyConsumed BatchIdentity))) Right (Map.lookup batch records)
            when (isJust (batchFrame record)) (Left (RefusedMisuse (WrongParent BatchIdentity)))
            case batchStanding record of
              BatchSealed → unless held (Left (RefusedMisuse (AlreadyConsumed BatchIdentity)))
              BatchSubmitted _ → Left (RefusedMisuse (AlreadyConsumed BatchIdentity))
              _ → Left (RefusedMisuse (WrongPhase BatchIdentity))
            commands ← case managedNative <$> Map.lookup (batchStorage record) managed of
              Just (NativeStorage _ _ buffer) → Right buffer
              _ → Left RefusedNoStorage
            slot ←
              maybe (Left (RefusedMisuse (WrongPhase BatchIdentity))) Right $
                lookup (FramelessRecording batch) [(view, number) | (number, view) ← framelessSlots model]
            case submitFramelessBatch batch SubmissionAccepted model of
              Rejected misuse → Left (RefusedMisuse misuse)
              Backpressure kind → Left (RefusedBackpressure kind)
              Admitted _ → Right ()
            (handle, family) ← maybe (Left RefusedDeviceAbsent) Right device
            pure (commands, batchTicket record, slot, handle, family)

    submit commands ticket slot device family = mask_ $ do
      existing ← Map.lookup slot <$> readTVarIO (framesFrameless frames)
      sync ← case existing of
        Just held → pure held
        Nothing → do
          -- An out-of-memory creation made nothing, and is recovered once
          -- (VK-14), as a frame slot's fences are.
          fence ← recoveringCreation roots "vkCreateFence" Nothing (rootsCall roots "vkCreateFence" (opsCreateFence ops device))
          let made = FramelessSync fence FenceIdle Nothing
          atomically (modifyTVar' (framesFrameless frames) (Map.insert slot made))
          pure made
      let fence = framelessFence sync
          edit change = modifyTVar' (framesFrameless frames) (Map.adjust change slot)
      reset ←
        if framelessFenceState sync == FenceSignalled
          then tryWithContext @SomeException (rootsCall roots "vkResetFences" (opsResetFence ops device fence))
          else pure (Right ())
      case reset of
        Left failure@(ExceptionWithContext _ exception) → do
          let reason = "resetting the fence of frame-less slot " <> Text.pack (show slot) <> " raised: " <> Text.pack (displayException exception)
          atomically $ do
            edit (\entry → entry {framelessFenceState = FenceUncertain reason})
            failRootsSessionBecause roots CleanupFailed reason
          rethrowIO failure
        Right () → do
          atomically (edit (\entry → entry {framelessFenceState = FenceIdle}))
          let native = SubmitBatch {submitWaits = [], submitWaitStage = WaitAtAllCommands, submitCommands = [commands], submitSignals = []}
          tryWithContext @SomeException (rootsCall roots "vkQueueSubmit2" (opsSubmit ops device family [native] fence)) >>= \case
            Right () → accepted ticket slot
            Left (ExceptionWithContext _ exception)
              | opsNoEffect ops exception → do
                  atomically (answered SubmissionFailedWithoutEffect)
                  pure (Right (SubmittedNothing (Text.pack (displayException exception))))
            Left failure@(ExceptionWithContext _ exception) → do
              let reason = "vkQueueSubmit2 raised, so whether it submitted is unknown: " <> Text.pack (displayException exception)
              atomically $ do
                answered SubmissionEffectUncertain
                edit (\entry → entry {framelessFenceState = FenceUncertain reason})
                failRootsSessionBecause roots UnknownSubmissionEffect (Text.pack (show batch) <> ": " <> reason)
              case fromException exception ∷ Maybe GraphicsDeviceLost of
                Just _ → rethrowIO failure
                Nothing → throwIO (FramelessEffectUncertain batch reason)

    -- Commit a submission the queue accepted. The model accepted this exact
    -- request a moment ago on this thread, so a refusal now is an effect whose
    -- bookkeeping cannot commit.
    accepted ticket slot = do
      committed ← atomically $ do
        answer ← stateRootsModel roots $ \model → case submitFramelessBatch batch SubmissionAccepted model of
          Admitted (next, SubmissionRecorded submission) → (Just submission, next)
          _ → (Nothing, model)
        for_ answer $ \submission → do
          modifyTVar' (framesFramelessSubmissions frames) (Map.insert submission (FramelessRecord slot batch ticket))
          modifyTVar' (framesFrameless frames) (Map.adjust (\entry → entry {framelessFenceState = FencePending}) slot)
        pure answer
      case committed of
        Nothing → do
          let reason = "the model refused to record a frame-less submission the queue accepted"
          atomically $ do
            answered SubmissionEffectUncertain
            modifyTVar' (framesFrameless frames) (Map.adjust (\entry → entry {framelessFenceState = FenceUncertain reason}) slot)
            failRootsSessionBecause roots UnknownSubmissionEffect (Text.pack (show batch) <> ": " <> reason)
          throwIO (FramelessEffectUncertain batch reason)
        Just submission → do
          -- The model has consumed the batch, so this cannot be refused.
          _ ← noteBatchSubmitted recording batch submission
          pure (Right (SubmittedAs submission))

    answered outcome = stateRootsModel roots $ \model → case outcomeModel (submitFramelessBatch batch outcome model) of
      Admitted next → ((), next)
      _ → ((), model)

-- ---------------------------------------------------------------------------
-- Retirement

-- | Destroy every frame-less slot's fence, once no frame-less submission is
-- outstanding and none of them is pending or uncertain, and forget them.
-- After the device's loss, what only it could have discharged is let go of
-- first, and the fences are destroyed without waiting for any of it.
-- Anything that remains is retained and 'FramelessRetained' raised naming it:
-- the device must outlive it. A destruction that raised is retained too,
-- never attempted again, and fails the session.
retireFrameless ∷ Frames q inst msgr phys dev cmd → IO ()
retireFrameless frames = owner (framesRecording frames) $ do
  lost ← atomically (lossObserved frames)
  when lost (() <$ releaseFramesToDeviceLoss frames)
  outstanding ← Map.keys <$> readTVarIO (framesFramelessSubmissions frames)
  syncs ← Map.toAscList <$> readTVarIO (framesFrameless frames)
  device ← atomically (deviceOf frames)
  failures ← fmap concat . mapM (destroy lost (null outstanding) device) $ syncs
  for_ failures rethrowIO
  remaining ← Map.keys <$> readTVarIO (framesFrameless frames)
  unless (null outstanding && null remaining) $
    throwIO (FramelessRetained outstanding remaining)
  where
    roots = framesRoots frames
    ops = framesOps frames
    destroy lost quiet device (slot, sync) = case device of
      Just (handle, _) | quiet, idle lost sync → mask_ $
        tryWithContext @SomeException (rootsCall roots "vkDestroyFence" (opsDestroyFence ops handle (framelessFence sync))) >>= \case
          Right () → [] <$ atomically (modifyTVar' (framesFrameless frames) (Map.delete slot))
          Left failure@(ExceptionWithContext _ exception) → do
            let reason = "destroying the fence of frame-less slot " <> Text.pack (show slot) <> " raised: " <> Text.pack (displayException exception)
            atomically $ do
              modifyTVar' (framesFrameless frames) (Map.adjust (\entry → entry {framelessFenceState = FenceUncertain reason, framelessDestruction = Just reason}) slot)
              failRootsSessionBecause roots CleanupFailed reason
            pure [failure]
      _ → pure []
    idle lost sync
      | isJust (framelessDestruction sync) = False
      | lost = True
      | otherwise = framelessFenceState sync `elem` [FenceIdle, FenceSignalled]
