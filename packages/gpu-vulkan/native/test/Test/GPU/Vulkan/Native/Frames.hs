-- | Acquisition, submission and safe abandonment over stand-in native layers:
-- one-slot and two-slot schedules through acquire, record, submit, skip and
-- close; not-ready, suboptimal and out-of-date acquisitions; refused batches;
-- a no-effect and an uncertain submission; the settlement of submitted but
-- never-presented frames; cancellation at each native handoff; and cleanup
-- that fails.
--
-- The frames' stand-in ("Test.GPU.Vulkan.Native.FramesStandIn") models the
-- rules Vulkan holds the application to — no wait on a fence no submission
-- made pending, no reuse of a semaphore while a wait on it is outstanding, no
-- release of an image whose acquisition was never waited on — and every
-- example ends by requiring that nothing broke one. A fence signals only when
-- an example completes its submission. Nothing here creates a Vulkan object,
-- and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Frames (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), throwIO, try)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model
  ( FramePhase (..)
  , FrameView (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , TargetPhase (..)
  , TargetView (..)
  , closeTarget
  , sessionState
  , suspendTarget
  , usage
  , usageFrames
  , usageObjects
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind (..))
import Hetoimasia.GPU.Model.Identity
  ( HoldSubject (..)
  , IdentityKind (..)
  , Misuse (..)
  , frameSlotNumber
  , imageGeneration
  , imageIndex
  )
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Generations
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn

spec ∷ Spec
spec = describe "Frames" $ do
  describe "acquisition" $ do
    it "reserves in the model before acquiring, makes the slot's synchronization and a pool record first, and owns the exact generation and image" $ do
      rig ← newRig
      seen ← newIORef Nothing
      duringFrameCall (rigStandIn rig) $ \case
        Acquired {} → do
          model ← modelOf rig
          modifyIORef' seen (const (Just (usageFrames (usage model))))
        _ → pure ()
      frame ← owned rig
      readIORef seen `shouldReturn` Just 1
      generation ← activeGeneration rig
      imageGeneration (ownedImage frame) `shouldBe` generation
      imageIndex (ownedImage frame) `shouldBe` 0
      ownedSuboptimal frame `shouldBe` False
      calls ← frameCalls (rigStandIn rig)
      -- The slot's acquisition semaphore and two fences, then the pool
      -- record's render-finished semaphore and present fence.
      map kind calls `shouldBe` ["semaphore", "fence", "fence", "semaphore", "fence", "acquire"]
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      poolHolder pool `shouldBe` PoolHeldByFrame (ownedFrame frame)
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameAcquired
      acquisitionState rig (ownedFrame frame) `shouldReturn` Just SemaphoreSignalOwed
      clean rig

    it "answers not ready and a timeout as pending, gives the reservation back whole, and owes no signal" $ do
      rig ← newRig
      before ← usageObjects . usage <$> modelOf rig
      scriptAcquire (rigStandIn rig) [AcquiringNotReady, AcquiringTimedOut]
      acquired rig `shouldReturn` AcquisitionPending PendingNoImage
      acquired rig `shouldReturn` AcquisitionPending PendingNoImage
      model ← modelOf rig
      usageFrames (usage model) `shouldBe` 0
      usageObjects (usage model) `shouldBe` before
      [slot] ← atomically (readSlots (rigFrames rig))
      syncAcquireState (viewSlotSync slot) `shouldBe` SemaphoreUnsignalled
      atomically (readFrameStandings (rigFrames rig)) `shouldReturn` []
      imagesOwned (rigStandIn rig) `shouldReturn` []
      clean rig

    it "keeps a suboptimal acquisition's index and requests a replacement beside it" $ do
      rig ← newRig
      scriptAcquire (rigStandIn rig) [AcquiredSuboptimalIndex 2]
      frame ← owned rig
      (imageIndex (ownedImage frame), ownedSuboptimal frame) `shouldBe` (2, True)
      viewTargetReplacementRequested <$> targetOf rig `shouldReturn` True
      viewPendingResult <$> generationsOf rig `shouldReturn` Just SwapchainSuboptimal
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameAcquired
      clean rig

    it "gives an out-of-date acquisition's reservation back and requests the target's replacement" $ do
      rig ← newRig
      scriptAcquire (rigStandIn rig) [AcquiringOutOfDate]
      acquired rig `shouldReturn` AcquisitionPending PendingReplacement
      usageFrames . usage <$> modelOf rig `shouldReturn` 0
      viewPendingResult <$> generationsOf rig `shouldReturn` Just SwapchainOutOfDate
      imagesOwned (rigStandIn rig) `shouldReturn` []
      clean rig

    it "refuses a foreign target as misuse, never pending, and another thread as not the owner, with no native call" $ do
      rig ← newRig
      other ← newRig
      tryAcquireFrame (rigFrames rig) (rigTarget other) `shouldReturn` Left (RefusedMisuse (ForeignIdentity TargetIdentity))
      done ← newEmptyMVar
      _ ← forkIO (tryAcquireFrame (rigFrames rig) (rigTarget rig) >>= putMVar done)
      takeMVar done `shouldReturn` Left RefusedNotOwner
      frameCalls (rigStandIn rig) `shouldReturn` []
      clean rig

    it "answers a suspended target, a closing one and a failed session without acquiring" $ do
      rig ← newRig
      inModel rig (suspendTarget (rigTarget rig))
      acquired rig `shouldReturn` AcquisitionSuspended
      closing ← newRig
      inModel closing (closeTarget (rigTarget closing))
      acquired closing `shouldReturn` AcquisitionClosing
      failed ← newRig
      atomically (failRootsSession (rigRoots failed) CleanupFailed)
      acquired failed `shouldReturn` AcquisitionUnavailable
      mapM_ (\each → frameCalls (rigStandIn each) `shouldReturn` []) [rig, closing, failed]

    it "answers an exhausted frame budget as pending backpressure, before any native call" $ do
      rig ← newRigWith 1
      _ ← owned rig
      before ← length <$> frameCalls (rigStandIn rig)
      acquired rig `shouldReturn` AcquisitionPending (PendingBackpressure FrameSlotBudget)
      length <$> frameCalls (rigStandIn rig) `shouldReturn` before
      clean rig

    it "gives the reservation back when the acquisition raised" $ do
      rig ← newRig
      failFrameStep (rigStandIn rig) AtAcquire
      outcome ← try @FrameStepFailed (tryAcquireFrame (rigFrames rig) (rigTarget rig))
      fmap (const ()) outcome `shouldBe` Left (FrameStepFailed AtAcquire)
      usageFrames . usage <$> modelOf rig `shouldReturn` 0
      clearFrameStep (rigStandIn rig) AtAcquire
      _ ← owned rig
      clean rig

  describe "submission" $ do
    it "submits a sealed batch waiting on the acquisition and signalling its pool record's render-finished semaphore, resetting the fence just before" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      submission ← submitted rig (batch :| [])
      [SlotView _ _ sync] ← atomically (readSlots (rigFrames rig))
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      calls ← drop 6 <$> frameCalls (rigStandIn rig)
      calls
        `shouldBe` [ ResetFence (syncFence sync)
                   , Submitted [([syncAcquire sync], WaitAtColorOutput, [commandsOf rig 0], [poolRendered pool])] (syncFence sync)
                   ]
      (syncFenceState sync, syncAcquireState sync, poolRenderedState pool) `shouldBe` (FencePending, SemaphoreWaitOwed, SemaphoreSignalOwed)
      fmap viewFrameSubmission <$> frameOf rig (ownedFrame frame) `shouldReturn` Just (Just submission)
      standingOf rig (ownedFrame frame) `shouldReturn` Just (StageSubmitted submission)
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just (BatchSubmitted submission)
      clean rig

    it "shares one completion obligation among a multi-frame request, retaining every member's dependencies until it completes" $ do
      rig ← newRig
      first ← owned rig
      second ← owned rig
      firstBatch ← sealed rig first
      secondBatch ← sealed rig second
      submission ← submitted rig (firstBatch :| [secondBatch])
      map (\case Submitted batches _ → length batches; _ → 0) . filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` [2]
      mapM (\frame → fmap viewFrameSubmission <$> frameOf rig (ownedFrame frame)) [first, second] `shouldReturn` replicate 2 (Just (Just submission))
      generation ← activeGeneration rig
      submittedOn rig (GenerationSubject generation) `shouldReturn` [submission]
      mapM (submittedOn rig . ResourceSubject . managedResource) (rigStorages rig) `shouldReturn` [[submission], [submission]]
      progress rig `shouldReturn'` \report → progressCompleted report `shouldBe` []
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → progressCompleted report `shouldBe` [submission]
      submittedOn rig (GenerationSubject generation) `shouldReturn` []
      mapM (submittedOn rig . ResourceSubject . managedResource) (rigStorages rig) `shouldReturn` [[], []]
      clean rig

    it "settles separate submissions independently" $ do
      rig ← newRig
      first ← owned rig
      second ← owned rig
      early ← sealed rig first >>= \batch → submitted rig (batch :| [])
      late ← sealed rig second >>= \batch → submitted rig (batch :| [])
      early `shouldSatisfy` (/= late)
      fences ← map (syncFence . viewSlotSync) <$> atomically (readSlots (rigFrames rig))
      pendingFences (rigStandIn rig) `shouldReturn` fences
      completeFence (rigStandIn rig) (fences !! 1)
      progress rig `shouldReturn'` \report → progressCompleted report `shouldBe` [late]
      atomically (readOutstandingSubmissions (rigFrames rig)) `shouldReturn` [early]
      generation ← activeGeneration rig
      submittedOn rig (GenerationSubject generation) `shouldReturn` [early]
      clean rig

    it "refuses a duplicate batch, a consumed one, a discarded one and a partial one before any native call" $ do
      rig ← newRig
      first ← owned rig
      batch ← sealed rig first
      calls ← length <$> frameCalls (rigStandIn rig)
      submitFrames (rigFrames rig) (batch :| [batch]) `shouldReturn` Left (RefusedMisuse (DuplicateSubject BatchIdentity))
      length <$> frameCalls (rigStandIn rig) `shouldReturn` calls
      _ ← submitted rig (batch :| [])
      submitFrames (rigFrames rig) (batch :| []) `shouldReturn` Left (RefusedMisuse (AlreadyConsumed BatchIdentity))
      second ← owned rig
      discarded ← sealed rig second
      ok (discardBatch (rigRecording rig) discarded)
      submitFrames (rigFrames rig) (discarded :| []) `shouldReturn` Left (RefusedMisuse (AlreadyConsumed BatchIdentity))
      raised ← try @ErrorCall (recordFrame (rigRecording rig) (ownedFrame second) (\_ → throwIO (ErrorCall "the consumer failed")))
      fmap (const ()) raised `shouldBe` Left (ErrorCall "the consumer failed")
      [partial] ← map viewBatch . filter (partialStanding . viewBatchStanding) <$> atomically (readBatches (rigRecording rig))
      submitFrames (rigFrames rig) (partial :| []) `shouldReturn` Left (RefusedMisuse (WrongPhase BatchIdentity))
      length . filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` 1
      clean rig

    it "leaves nothing pending after a no-effect failure: the reset fence is never asked, and the frame resubmits" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      failFrameStep (rigStandIn rig) AtSubmitNoEffect
      submitFrames (rigFrames rig) (batch :| []) `shouldReturn'` \case
        Right (SubmittedNothing _) → pure ()
        other → expectationFailure ("the submission answered " <> show other)
      view ← frameOf rig (ownedFrame frame)
      (viewFramePhase <$> view, viewFrameFenceReset <$> view, viewFrameSubmission =<< view) `shouldBe` (Just FrameAcquired, Just False, Nothing)
      [SlotView _ _ sync] ← atomically (readSlots (rigFrames rig))
      (syncFenceState sync, syncAcquireState sync) `shouldBe` (FenceIdle, SemaphoreSignalOwed)
      _ ← progress rig
      filter isQuery <$> frameCalls (rigStandIn rig) `shouldReturn` []
      pendingFences (rigStandIn rig) `shouldReturn` []
      clearFrameStep (rigStandIn rig) AtSubmitNoEffect
      _ ← submitted rig (batch :| [])
      clean rig

    it "retains an uncertain submission's frames for ever, stops admission and fails the session" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      failFrameStep (rigStandIn rig) AtSubmit
      outcome ← try @FrameEffectUncertain (submitFrames (rigFrames rig) (batch :| []))
      fmap (const ()) outcome `shouldSatisfy` either (const True) (const False)
      sessionState <$> modelOf rig `shouldReturn` SessionFailed UnknownSubmissionEffect
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameUncertainEffect
      standingOf rig (ownedFrame frame) `shouldReturn'` (`shouldSatisfy` maybe False uncertainStage)
      acquired rig `shouldReturn` AcquisitionUnavailable
      skipFrame (rigFrames rig) (ownedFrame frame) `shouldReturn` Left (RefusedMisuse (WrongPhase FrameIdentity))
      _ ← progress rig
      filter isQuery <$> frameCalls (rigStandIn rig) `shouldReturn` []
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _ _ _) → frames == [ownedFrame frame]

    it "retains a fence whose reset raised, stops admission and fails the session, submitting nothing" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      failFrameStep (rigStandIn rig) AtResetFence
      outcome ← try @FrameStepFailed (submitFrames (rigFrames rig) (batch :| []))
      fmap (const ()) outcome `shouldBe` Left (FrameStepFailed AtResetFence)
      filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` []
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameAcquired
      [SlotView _ _ sync] ← atomically (readSlots (rigFrames rig))
      syncFenceState sync `shouldSatisfy` \case
        FenceUncertain _ → True
        _ → False
      acquired rig `shouldReturn` AcquisitionUnavailable
      -- The frame, never submitted, is still abandoned safely, but the slot
      -- keeps its doubtful fence.
      clearFrameStep (rigStandIn rig) AtResetFence
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames slots _ _) → null frames && slots == [0]
      clean rig

  describe "abandonment" $ do
    it "skips an acquired frame through a cleanup submission and returns its image once that has completed, rebuilding nothing" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame
      constructions ← viewConstructions <$> generationsOf rig
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      [SlotView _ _ sync] ← atomically (readSlots (rigFrames rig))
      last <$> frameCalls (rigStandIn rig) `shouldReturn` Submitted [([syncAcquire sync], WaitAtAllCommands, [], [])] (syncCleanup sync)
      standingOf rig (ownedFrame frame) `shouldReturn` Just StageSkipping
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameRetiring
      -- Its recording was invalidated natively and then discharged.
      atomically (readBatches (rigRecording rig)) `shouldReturn` []
      _ ← progress rig
      imagesOwned (rigStandIn rig) `shouldReturn'` (`shouldSatisfy` (not . null))
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → progressSettled report `shouldBe` [ownedFrame frame]
      imagesOwned (rigStandIn rig) `shouldReturn` []
      phaseOf rig (ownedFrame frame) `shouldReturn` Nothing
      viewTargetFrames <$> targetOf rig `shouldReturn` 0
      viewTargetPoolRecords <$> targetOf rig `shouldReturn` 0
      viewConstructions <$> generationsOf rig `shouldReturn` constructions
      viewTargetPhase <$> targetOf rig `shouldReturn` TargetAdmitted
      clean rig

    it "refuses a skip after submission as the wrong phase" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      skipFrame (rigFrames rig) (ownedFrame frame) `shouldReturn` Left (RefusedMisuse (WrongPhase FrameIdentity))
      clean rig

    it "settles a submitted, never-presented frame only after its rendering completed, through a cleanup of its render-finished semaphore" $ do
      rig ← newRig
      frame ← owned rig
      submission ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      ok (closeUnpresentedFrame (rigFrames rig) (ownedFrame frame))
      standingOf rig (ownedFrame frame) `shouldReturn` Just (StageClosing submission)
      progress rig `shouldReturn'` \report → (progressCleanups report, progressSettled report) `shouldBe` ([], [])
      length . filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` 1
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → (progressCompleted report, progressCleanups report) `shouldBe` ([submission], [ownedFrame frame])
      [SlotView _ _ sync] ← atomically (readSlots (rigFrames rig))
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      -- The same step then asks the cleanup fence, which has not signalled.
      last . filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` Submitted [([poolRendered pool], WaitAtAllCommands, [], [])] (syncCleanup sync)
      imagesOwned (rigStandIn rig) `shouldReturn'` (`shouldSatisfy` (not . null))
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → progressSettled report `shouldBe` [ownedFrame frame]
      imagesOwned (rigStandIn rig) `shouldReturn` []
      phaseOf rig (ownedFrame frame) `shouldReturn` Nothing
      [SlotView _ _ settled] ← atomically (readSlots (rigFrames rig))
      [PoolView _ _ freed] ← atomically (readPool (rigFrames rig))
      (syncAcquireState settled, poolRenderedState freed, poolHolder freed) `shouldBe` (SemaphoreUnsignalled, SemaphoreUnsignalled, PoolFree)
      clean rig

    it "abandons a closing target's frames, settles them while it closes, and then retires its slots" $ do
      rig ← newRig
      first ← owned rig
      second ← owned rig
      _ ← sealed rig second >>= \batch → submitted rig (batch :| [])
      inModel rig (closeTarget (rigTarget rig))
      acquired rig `shouldReturn` AcquisitionClosing
      answers ← closeTargetFrames (rigFrames rig) (rigTarget rig)
      answers `shouldBe` [(ownedFrame first, Right ()), (ownedFrame second, Right ())]
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _ _ _) → length frames == 2
      settleAll rig
      atomically (readFrameStandings (rigFrames rig)) `shouldReturn` []
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      atomically (readSlots (rigFrames rig)) `shouldReturn` []
      -- Two slots of three objects, and two pool records of two.
      length . filter isDestruction <$> frameCalls (rigStandIn rig) `shouldReturn` 10
      atomically (readPool (rigFrames rig)) `shouldReturn` []
      clean rig

    it "abandons a frame once ordinary admission is exhausted, holding its slot and pool record until the evidence arrives" $ do
      rig ← newRig
      frame ← owned rig
      exhaust rig
      acquired rig `shouldReturn` AcquisitionPending (PendingBackpressure ObjectBudget)
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      _ ← progress rig
      (viewTargetFrames <$> targetOf rig) `shouldReturn` 1
      (viewTargetPoolRecords <$> targetOf rig) `shouldReturn` 1
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → progressSettled report `shouldBe` [ownedFrame frame]
      (viewTargetFrames <$> targetOf rig) `shouldReturn` 0
      (viewTargetPoolRecords <$> targetOf rig) `shouldReturn` 0
      clean rig

    it "retains a frame whose cleanup submission raised, fails the session, and never settles it" $ do
      rig ← newRig
      frame ← owned rig
      failFrameStep (rigStandIn rig) AtCleanupSubmit
      skipFrame (rigFrames rig) (ownedFrame frame) `raises` \(FrameCleanupFailed failed _) → failed == ownedFrame frame
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      standingOf rig (ownedFrame frame) `shouldReturn'` (`shouldSatisfy` maybe False failedStage)
      completeAll (rigStandIn rig)
      _ ← progress rig
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameRetiring
      imagesOwned (rigStandIn rig) `shouldReturn'` (`shouldSatisfy` (not . null))
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _ _ _) → frames == [ownedFrame frame]
      clean rig

    it "retains a frame whose release raised, never fabricating a reusable image, and keeps its slot" $ do
      rig ← newRig
      frame ← owned rig
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      failFrameStep (rigStandIn rig) AtRelease
      completeAll (rigStandIn rig)
      progress rig `raises` \(FrameCleanupFailed failed _) → failed == ownedFrame frame
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameRetiring
      imagesOwned (rigStandIn rig) `shouldReturn'` (`shouldSatisfy` (not . null))
      clearFrameStep (rigStandIn rig) AtRelease
      _ ← progress rig
      length . filter isRelease <$> frameCalls (rigStandIn rig) `shouldReturn` 1
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _ _ _) → frames == [ownedFrame frame]
      clean rig

    it "preserves a frame whose consumer raised, runs that consumer once, and skips it safely" $ do
      rig ← newRig
      frame ← owned rig
      runs ← newIORef (0 ∷ Int)
      raised ← try @ErrorCall $ recordFrame (rigRecording rig) (ownedFrame frame) $ \_ → do
        modifyIORef' runs (+ 1)
        throwIO (ErrorCall "the consumer failed")
      fmap (const ()) raised `shouldBe` Left (ErrorCall "the consumer failed")
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameAcquired
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      readIORef runs `shouldReturn` 1
      clean rig

  describe "schedules" $ do
    it "one slot: acquire, record, submit, close and settle, then acquire the slot again and skip it" $ do
      rig ← newRigWith 1
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      acquired rig `shouldReturn` AcquisitionPending (PendingBackpressure FrameSlotBudget)
      ok (closeUnpresentedFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      again ← owned rig
      frameSlotNumber (ownedFrame again) `shouldBe` frameSlotNumber (ownedFrame frame)
      ownedFrame again `shouldSatisfy` (/= ownedFrame frame)
      _ ← sealed rig again
      ok (skipFrame (rigFrames rig) (ownedFrame again))
      settleAll rig
      _ ← owned rig
      clean rig

    it "two slots: two frames in flight at once, one skipped while the other's rendering is pending" $ do
      rig ← newRig
      first ← owned rig
      second ← owned rig
      map frameSlotNumber [ownedFrame first, ownedFrame second] `shouldBe` [0, 1]
      acquired rig `shouldReturn` AcquisitionPending (PendingBackpressure FrameSlotBudget)
      submission ← sealed rig first >>= \batch → submitted rig (batch :| [])
      ok (skipFrame (rigFrames rig) (ownedFrame second))
      progress rig `shouldReturn'` \report → progressSettled report `shouldBe` []
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → (progressCompleted report, progressSettled report) `shouldBe` ([submission], [ownedFrame second])
      third ← owned rig
      frameSlotNumber (ownedFrame third) `shouldBe` 1
      ok (closeUnpresentedFrame (rigFrames rig) (ownedFrame first))
      settleAll rig
      ok (skipFrame (rigFrames rig) (ownedFrame third))
      settleAll rig
      clean rig

    it "rotates a one-action step's work, so a later submission completing first is observed, cleaned up and released" $ do
      rig ← newRigWithActions 2 1
      first ← owned rig
      second ← owned rig
      early ← sealed rig first >>= \batch → submitted rig (batch :| [])
      late ← sealed rig second >>= \batch → submitted rig (batch :| [])
      mapM_ (ok . closeUnpresentedFrame (rigFrames rig) . ownedFrame) [first, second]
      [earlyFence, lateFence] ← map (syncFence . viewSlotSync) <$> atomically (readSlots (rigFrames rig))
      -- Only the later submission ever completes.
      completeFence (rigStandIn rig) lateFence
      let step' = do
            report ← progress rig
            -- Complete every cleanup made so far, never the early submission.
            pending ← pendingFences (rigStandIn rig)
            mapM_ (completeFence (rigStandIn rig)) (filter (/= earlyFence) pending)
            pure report
      reports ← mapM (const step') [1 .. 8 ∷ Int]
      concatMap progressCompleted reports `shouldBe` [late]
      concatMap progressCleanups reports `shouldBe` [ownedFrame second]
      concatMap progressSettled reports `shouldBe` [ownedFrame second]
      standingOf rig (ownedFrame first) `shouldReturn` Just (StageClosing early)
      clean rig

  describe "cancellation at each native handoff" $ do
    it "records an acquisition a cancellation reached, then delivers it" $ do
      rig ← newRig
      cancelled rig isAcquisition (tryAcquireFrame (rigFrames rig) (rigTarget rig))
      [FrameStanding frame _ StageAcquired] ← atomically (readFrameStandings (rigFrames rig))
      phaseOf rig frame `shouldReturn` Just FrameAcquired
      ok (skipFrame (rigFrames rig) frame)
      settleAll rig
      clean rig

    it "records a submission a cancellation reached, then delivers it" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      cancelled rig isSubmission (submitFrames (rigFrames rig) (batch :| []))
      standingOf rig (ownedFrame frame) `shouldReturn'` (`shouldSatisfy` maybe False submittedStage)
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameSubmitted
      atomically (readOutstandingSubmissions (rigFrames rig)) `shouldReturn'` (`shouldSatisfy` ((== 1) . length))
      ok (closeUnpresentedFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      clean rig

    it "records a skip's cleanup submission a cancellation reached, then delivers it" $ do
      rig ← newRig
      frame ← owned rig
      cancelled rig isSubmission (skipFrame (rigFrames rig) (ownedFrame frame))
      standingOf rig (ownedFrame frame) `shouldReturn` Just StageSkipping
      settleAll rig
      clean rig

    it "records a closed frame's cleanup submission a cancellation reached, then delivers it" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      ok (closeUnpresentedFrame (rigFrames rig) (ownedFrame frame))
      completeAll (rigStandIn rig)
      cancelled rig isCleanup (progressFrames (rigFrames rig) (at 1))
      standingOf rig (ownedFrame frame) `shouldReturn` Just StageSettling
      settleAll rig
      clean rig

    it "records a release a cancellation reached, then delivers it" $ do
      rig ← newRig
      frame ← owned rig
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      completeAll (rigStandIn rig)
      cancelled rig isRelease (progressFrames (rigFrames rig) (at 1))
      standingOf rig (ownedFrame frame) `shouldReturn` Nothing
      phaseOf rig (ownedFrame frame) `shouldReturn` Nothing
      imagesOwned (rigStandIn rig) `shouldReturn` []
      clean rig
