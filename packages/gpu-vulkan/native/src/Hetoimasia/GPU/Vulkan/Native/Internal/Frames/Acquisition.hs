-- | Acquisition for the frames ("Hetoimasia.GPU.Vulkan.Native.Frames"):
-- 'tryAcquireFrame', which reserves a frame in the model, makes sure its slot's
-- synchronization exists, binds it a record of its target's presentation
-- pool, and acquires one image without waiting, recording what the call did
-- in the same masked step.
--
-- This module inserts frame records, creates slot synchronization and
-- presentation-pool records, and binds and frees pool records in the frames'
-- state ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State"), and marks a
-- slot's acquisition semaphore owed a signal. It owns no state of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Acquisition
  ( tryAcquireFrame
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception (SomeException, mask_, onException, rethrowIO, throwIO, tryWithContext)
import Control.Monad (void, when)
import Data.Foldable (for_)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model
  ( AcquireAnswer (..)
  , AcquireOutcome (..)
  , GpuModel
  , Outcome (..)
  , SessionFailureCause (CleanupFailed)
  , SessionState (SessionRunning)
  , TargetPhase (..)
  , TargetView (..)
  , acquireImage
  , modelBudgets
  , outcomeModel
  , reserveFrame
  , sessionState
  , targetView
  )
import Hetoimasia.GPU.Model.Budget (presentationPoolCapacity)
import Hetoimasia.GPU.Model.Identity
  ( FrameSlotId
  , IdentityKind (..)
  , Misuse (..)
  , TargetId
  , frameTarget
  , imageGeneration
  , targetSession
  )
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( GenerationView (..)
  , SwapchainResult (..)
  , TargetCondition (..)
  , TargetGenerationsView (..)
  , noteSwapchainResult
  , readTargetGenerations
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer (AcquireResult (..), FrameOps (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (recoveringCreation)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State (Refusal (..), checkpointed, modelAnswer, modelEdit, owned)
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (..), PoolObject (..), SlotObject (..), poolObjectName, slotObjectName)
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( failRootsSessionBecause
  , nameRootsObject
  , readRootsInstrumentation
  , rootsCall
  , rootsSessionIdentity
  , stateRootsModel
  )

-- | Try to acquire one frame of the target, without waiting.
--
-- Before any native call the target must be this session's, admitted, and
-- presenting from an active generation, and the model must reserve a frame —
-- its slot, the presentation-pool record it may need and the submission record
-- it may need. A target that is suspended, closing or unavailable answers so;
-- one with nothing to acquire from, or whose frame or pool budget is
-- exhausted, answers 'AcquisitionPending'; a foreign or stale target is a
-- misuse, never pending. The slot's synchronization is made the first time it
-- is reserved, and a free record of the target's presentation pool — its
-- render-finished semaphore and present fence — is bound to the frame, made
-- if the pool has none free, both before the acquisition: an acquired frame can
-- always be abandoned, and presenting it never makes, waits for or is refused a
-- record.
--
-- The acquisition's result and its bookkeeping are one masked step. A
-- successful one — suboptimal included, which keeps its index and requests a
-- replacement beside it — owns the image. Not ready and a timeout give the
-- reservation back whole; out of date gives it back and requests a replacement
-- of the target. A call that raised acquired nothing and gives it back too.
tryAcquireFrame ∷ Frames q inst msgr phys dev cmd → TargetId → IO (Either Refusal Acquisition)
tryAcquireFrame frames target =
  owned (framesRecording frames) . checkpointed (framesRecording frames) $
    atomically gate >>= \case
      Left refusal → pure (Left refusal)
      Right (Left answer) → pure (Right answer)
      Right (Right (generation, swapchain, device)) → acquire generation swapchain device
  where
    roots = framesRoots frames
    generations = framesGenerations frames
    ops = framesOps frames
    gate = do
      model ← readModel frames
      view ← readTargetGenerations generations target
      device ← deviceOf frames
      pure $ case targetView target model of
        Nothing → Left (RefusedMisuse (targetMisuse model))
        Just state
          | sessionState model /= SessionRunning → Right (Left AcquisitionUnavailable)
          | otherwise → case viewTargetPhase state of
              TargetSuspended → Right (Left AcquisitionSuspended)
              TargetRetiring → Right (Left AcquisitionClosing)
              TargetUnavailable → Right (Left AcquisitionUnavailable)
              TargetAdmitted → case viewCondition <$> view of
                Just Presenting → case view >>= active of
                  Nothing → Right (Left (AcquisitionPending PendingGeneration))
                  Just (generation, swapchain) → case device of
                    Nothing → Left RefusedDeviceAbsent
                    Just (handle, _) → Right (Right (generation, swapchain, handle))
                Just (Suspended _) → Right (Left AcquisitionSuspended)
                Just Closing → Right (Left AcquisitionClosing)
                Just RecoverySpent → Right (Left AcquisitionUnavailable)
                Just SurfaceLost → Right (Left (AcquisitionPending PendingSurfaceLost))
                Just SurfaceReplacing → Right (Left (AcquisitionPending PendingSurfaceLost))
                Just (PresentationUnsupported _) → Right (Left AcquisitionUnavailable)
                _ → Right (Left (AcquisitionPending PendingGeneration))
    active view = do
      generation ← viewActive view
      native ← find ((== generation) . viewGeneration) (viewGenerations view)
      swapchain ← viewSwapchain native
      pure (generation, swapchain)
    -- The model's own classification of a target it cannot resolve.
    targetMisuse model
      | targetSession target /= rootsSessionIdentity roots = ForeignIdentity TargetIdentity
      | otherwise = case reserveFrame target model of
          Rejected SessionAlreadyFailed → StaleIdentity TargetIdentity
          Rejected misuse → misuse
          _ → UnknownIdentity TargetIdentity

    acquire generation swapchain device = mask_ $
      atomically (modelAnswer roots (reserveFrame target)) >>= \case
        Left (RefusedBackpressure kind) → pure (Right (AcquisitionPending (PendingBackpressure kind)))
        Left refusal → pure (Left refusal)
        Right frame →
          tryWithContext @SomeException (prepare device frame) >>= \case
            Left failure → do
              atomically (giveBack frame)
              rethrowIO failure
            Right (Left refusal) → do
              atomically (giveBack frame)
              pure (Left refusal)
            Right (Right (sync, pool)) →
              tryWithContext @SomeException (rootsCall roots "vkAcquireNextImageKHR" (opsAcquireImage ops device swapchain (syncAcquire sync))) >>= \case
                Left failure → do
                  -- A call that raised acquired nothing: an error result has no
                  -- effect but the two the layer answers as values.
                  atomically (giveBack frame)
                  rethrowIO failure
                Right result → atomically (commit frame generation swapchain pool result) >>= either (throwIO . FrameEffectUncertain [frame]) (pure . Right)

    prepare device frame =
      prepareSlot frames device frame >>= \case
        Left refusal → pure (Left refusal)
        Right sync → fmap ((,) sync) <$> preparePool frames device frame

    -- The reservation goes back whole, and with it the pool record it held.
    giveBack frame = do
      modelEdit roots (outcomeModel . acquireImage frame AcquireNotReady)
      freePoolOf frames frame

    commit frame generation swapchain pool result = do
      answer ← stateRootsModel roots $ \model → case acquireImage frame (outcomeOf result) model of
        Admitted (next, value) → (Right value, next)
        refused → (Left (Text.pack (show (outcomeModel' refused))), model)
      case answer of
        Right (ImageOwned image suboptimal)
          | imageGeneration image /= generation → do
              -- The model owns an image of a generation other than the one the
              -- swapchain belongs to: which image is owned is unknown.
              modifyTVar' (framesLive frames) (Map.insert frame (FrameRecord image swapchain pool (StageUncertain mismatch)))
              editSlot frames (slotOf frame) (\sync → sync {syncAcquireState = SemaphoreUncertain mismatch})
              failRootsSessionBecause roots CleanupFailed (Text.pack (show frame) <> ": " <> mismatch)
              pure (Left mismatch)
          | otherwise → do
              modifyTVar' (framesLive frames) (Map.insert frame (FrameRecord image swapchain pool StageAcquired))
              editSlot frames (slotOf frame) (\sync → sync {syncAcquireState = SemaphoreSignalOwed})
              when suboptimal (void (noteSwapchainResult generations generation SwapchainSuboptimal))
              pure (Right (AcquisitionOwned (OwnedFrame frame image suboptimal)))
        -- Given back whole, its pool record freed untouched with it.
        Right ReservationReturned → do
          freePoolOf frames frame
          pure (Right (AcquisitionPending PendingNoImage))
        -- The model gave the reservation back, its pool record with it; the
        -- native record it was bound to is freed untouched too, as any given-
        -- back reservation's is, or it would stay bound to a frame that no
        -- longer exists and hold the target's retirement back for ever.
        Right ReplacementRequested → freePoolOf frames frame >> case result of
          AcquiringOutOfDate → do
            void (noteSwapchainResult generations generation SwapchainOutOfDate)
            pure (Right (AcquisitionPending PendingReplacement))
          _ → do
            -- The surface itself must be replaced (VK-14): the generations are
            -- told, and their next step retires this generation.
            void (noteSwapchainResult generations generation SwapchainSurfaceLost)
            pure (Right (AcquisitionPending PendingSurfaceLost))
        Left reason
          | acquiredSomething result → do
              -- The image is owned natively and the model refused to record it:
              -- its semaphore's signal is owed and nothing can settle it.
              let why = "the model refused an acquisition the swapchain made: " <> reason
              editSlot frames (slotOf frame) (\sync → sync {syncAcquireState = SemaphoreUncertain why})
              failRootsSessionBecause roots CleanupFailed (Text.pack (show frame) <> ": " <> why)
              pure (Left why)
          | otherwise → do
              giveBack frame
              pure (Right (AcquisitionPending PendingNoImage))
      where
        mismatch = "the model's acquisition named another generation than the swapchain's"
    outcomeModel' ∷ Outcome (GpuModel, AcquireAnswer) → Outcome ()
    outcomeModel' = fmap (const ())

outcomeOf ∷ AcquireResult → AcquireOutcome
outcomeOf = \case
  AcquiredIndex index → AcquiredImage (fromIntegral index)
  AcquiredSuboptimalIndex index → AcquiredSuboptimalImage (fromIntegral index)
  AcquiringNotReady → AcquireNotReady
  AcquiringTimedOut → AcquireNotReady
  AcquiringOutOfDate → AcquireOutOfDate
  AcquiringSurfaceLost → AcquireSurfaceLost

-- | Whether the swapchain gave an image, and so owes the semaphore a signal.
acquiredSomething ∷ AcquireResult → Bool
acquiredSomething = \case
  AcquiredIndex _ → True
  AcquiredSuboptimalIndex _ → True
  _ → False

-- | The slot's synchronization, made now if the slot has none: a binary
-- semaphore and two fences, each unsignalled, named when the device offers
-- naming. A creation or a naming that raised destroys what was made before it
-- raises, so the slot is either complete or absent; a creation that ran out of
-- memory created nothing, and is recovered as an allocation, once (VK-14). An
-- existing slot must be
-- idle: the model frees a slot only once its own obligations have ended, so
-- anything else is refused.
prepareSlot ∷ Frames q inst msgr phys dev cmd → dev → FrameSlotId → IO (Either Refusal SlotSync)
prepareSlot frames device frame =
  (Map.lookup key <$> readTVarIO (framesSlots frames)) >>= \case
    Just sync
      | reusable sync → pure (Right sync)
      | otherwise → pure (Left (RefusedIllegal ("the frame slot's synchronization is still in use: " <> Text.pack (show sync))))
    Nothing → do
      acquisition ← semaphore
      fence ← create "vkCreateFence" (opsCreateFence ops device) `onException` destroySemaphore acquisition
      cleanup ← create "vkCreateFence" (opsCreateFence ops device) `onException` (destroyFence fence >> destroySemaphore acquisition)
      name [(ObjectSemaphore, acquisition, AcquisitionSemaphore), (ObjectFence, fence, SubmissionFence), (ObjectFence, cleanup, CleanupFence)]
        `onException` (destroyFence cleanup >> destroyFence fence >> destroySemaphore acquisition)
      let sync = SlotSync acquisition SemaphoreUnsignalled fence FenceIdle cleanup FenceIdle Nothing
      atomically (modifyTVar' (framesSlots frames) (Map.insert key sync))
      pure (Right sync)
  where
    key@(target, slot) = slotOf frame
    ops = framesOps frames
    roots = framesRoots frames
    create ∷ Text → IO Word64 → IO Word64
    create called call = recoveringCreation roots called Nothing (rootsCall roots called call)
    semaphore = create "vkCreateSemaphore" (opsCreateSemaphore ops device)
    destroySemaphore handle = rootsCall roots "vkDestroySemaphore" (opsDestroySemaphore ops device handle)
    destroyFence handle = rootsCall roots "vkDestroyFence" (opsDestroyFence ops device handle)
    name objects =
      readRootsInstrumentation roots >>= \case
        Nothing → pure ()
        Just (_, instrumentation) →
          for_ objects $ \(kind, handle, object) → nameRootsObject roots instrumentation kind handle (slotObjectName target slot object)
    reusable sync =
      syncAcquireState sync == SemaphoreUnsignalled
        && syncFenceState sync `elem` [FenceIdle, FenceSignalled]
        && syncCleanupState sync `elem` [FenceIdle, FenceSignalled]

-- | Bind the frame a record of its target's presentation pool, answering the
-- record's number: the first free record whose objects are idle, or a new one
-- — a render-finished semaphore and a present fence, each unsignalled, named
-- when the device offers naming — while the target holds fewer than the
-- model's pool capacity. The model reserved the frame's pool record already,
-- and binds no more records than that capacity, so a target with no record to
-- bind is refused as illegal rather than grown. A creation or a naming that
-- raised destroys what was made before it raises, so a record is either
-- complete or absent; a creation that ran out of memory created nothing, and
-- is recovered as an allocation, once (VK-14).
preparePool ∷ Frames q inst msgr phys dev cmd → dev → FrameSlotId → IO (Either Refusal Natural)
preparePool frames device frame = do
  (held, capacity) ← atomically $ do
    pool ← readTVar (framesPool frames)
    model ← readModel frames
    pure ([(number, sync) | ((owner, number), sync) ← Map.toAscList pool, owner == target], presentationPoolCapacity (modelBudgets model))
  case [number | (number, sync) ← held, poolHolder sync == PoolFree, idle sync] of
    number : _ → Right number <$ atomically (bind number)
    []
      | fromIntegral (length held) >= capacity →
          pure (Left (RefusedIllegal ("every presentation-pool record of the target is held: " <> Text.pack (show (map snd held)))))
      | otherwise → do
          let number = unused 0
              unused candidate
                | candidate `elem` map fst held = unused (candidate + 1)
                | otherwise = candidate
          rendered ← create "vkCreateSemaphore" (opsCreateSemaphore ops device)
          fence ← create "vkCreateFence" (opsCreateFence ops device) `onException` destroySemaphore rendered
          name number [(ObjectSemaphore, rendered, RenderFinishedSemaphore), (ObjectFence, fence, PresentFence)]
            `onException` (destroyFence fence >> destroySemaphore rendered)
          atomically $
            modifyTVar' (framesPool frames) (Map.insert (target, number) (PoolSync rendered SemaphoreUnsignalled fence FenceIdle (PoolHeldByFrame frame) Nothing))
          pure (Right number)
  where
    target = frameTarget frame
    ops = framesOps frames
    roots = framesRoots frames
    bind number = editPool frames (target, number) (\sync → sync {poolHolder = PoolHeldByFrame frame})
    idle sync = poolRenderedState sync == SemaphoreUnsignalled && poolFenceState sync `elem` [FenceIdle, FenceSignalled]
    create ∷ Text → IO Word64 → IO Word64
    create called call = recoveringCreation roots called Nothing (rootsCall roots called call)
    destroySemaphore handle = rootsCall roots "vkDestroySemaphore" (opsDestroySemaphore ops device handle)
    destroyFence handle = rootsCall roots "vkDestroyFence" (opsDestroyFence ops device handle)
    name number objects =
      readRootsInstrumentation roots >>= \case
        Nothing → pure ()
        Just (_, instrumentation) →
          for_ objects $ \(kind, handle, object) → nameRootsObject roots instrumentation kind handle (poolObjectName target number object)
