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

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), Exception, SomeException, fromException, throwIO, try)
import Control.Monad (unless, when)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Conc (ThreadStatus (..), BlockReason (..), threadStatus)
import Numeric.Natural (Natural)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant)
import Hetoimasia.GPU.Model
  ( FramePhase (..)
  , FrameView (..)
  , GpuModel
  , HoldView (..)
  , Outcome (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , TargetPhase (..)
  , TargetView (..)
  , beginAllocation
  , closeTarget
  , frameView
  , holdView
  , modelBudgets
  , sessionState
  , suspendTarget
  , targetView
  , usage
  , usageFrames
  , usageObjects
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind (..), BudgetRequest (..), defaultBudgetRequest, objectLimit, validateBudgets)
import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , FrameSlotId
  , GenerationId
  , HoldSubject (..)
  , IdentityKind (..)
  , Misuse (..)
  , SubmissionId
  , TargetClass (..)
  , TargetId
  , frameSlotNumber
  , imageGeneration
  , imageIndex
  )
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Generations
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (newRecordingStandIn, recordingStandInOps)
import Test.GPU.Vulkan.Native.StandIn (StandInRoots, newStandIn, newStandInRoots, standardRequest, surfaceNumbered)

spec ∷ Spec
spec = describe "Frames" $ do
  describe "acquisition" $ do
    it "reserves in the model before acquiring, makes the slot's synchronization first, and owns the exact generation and image" $ do
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
      map kind calls `shouldBe` ["semaphore", "semaphore", "fence", "fence", "acquire"]
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
    it "submits a sealed batch waiting on the acquisition and signalling the render-finished semaphore, resetting the fence just before" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      submission ← submitted rig (batch :| [])
      [SlotView _ _ sync] ← atomically (readSlots (rigFrames rig))
      calls ← drop 5 <$> frameCalls (rigStandIn rig)
      calls
        `shouldBe` [ ResetFence (syncFence sync)
                   , Submitted [([syncAcquire sync], WaitAtColorOutput, [commandsOf rig 0], [syncRendered sync])] (syncFence sync)
                   ]
      (syncFenceState sync, syncAcquireState sync, syncRenderedState sync) `shouldBe` (FencePending, SemaphoreWaitOwed, SemaphoreSignalOwed)
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
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _) → frames == [ownedFrame frame]

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
      -- The same step then asks the cleanup fence, which has not signalled.
      last . filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` Submitted [([syncRendered sync], WaitAtAllCommands, [], [])] (syncCleanup sync)
      imagesOwned (rigStandIn rig) `shouldReturn'` (`shouldSatisfy` (not . null))
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → progressSettled report `shouldBe` [ownedFrame frame]
      imagesOwned (rigStandIn rig) `shouldReturn` []
      phaseOf rig (ownedFrame frame) `shouldReturn` Nothing
      [SlotView _ _ settled] ← atomically (readSlots (rigFrames rig))
      (syncAcquireState settled, syncRenderedState settled) `shouldBe` (SemaphoreUnsignalled, SemaphoreUnsignalled)
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
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _) → length frames == 2
      settleAll rig
      atomically (readFrameStandings (rigFrames rig)) `shouldReturn` []
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      atomically (readSlots (rigFrames rig)) `shouldReturn` []
      length . filter isDestruction <$> frameCalls (rigStandIn rig) `shouldReturn` 8
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
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _) → frames == [ownedFrame frame]
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
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _) → frames == [ownedFrame frame]
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

-- ---------------------------------------------------------------------------
-- The rig

data Rig = Rig
  { rigStandIn ∷ !FramesStandIn
  , rigRoots ∷ !StandInRoots
  , rigGenerations ∷ !(Generations () Int Int Text Int)
  , rigRecording ∷ !(Recording () Int Int Text Int Word64)
  , rigFrames ∷ !(Frames () Int Int Text Int Word64)
  , rigTarget ∷ !TargetId
  , rigStorages ∷ ![FrameStorage]
  , rigCommands ∷ ![Word64]
  }

-- | Started roots over the stand-in, one target on surface 10 with a 640 by
-- 480 generation of three images, a recording, the frames, and a storage for
-- each of the target's two frame slots.
newRig ∷ IO Rig
newRig = newRigWith 2

newRigWith ∷ Integer → IO Rig
newRigWith slots = do
  rootsStandIn ← newStandIn
  roots ← newStandInRoots rootsStandIn (either (error . show) id (validateBudgets defaultBudgetRequest {requestedFrameSlots = slots}))
  _ ← startRoots roots standardRequest
  target ← admitRootTarget roots OptionalTarget (surfaceNumbered rootsStandIn 10) >>= either (fail . show) pure
  generations ← newGenerations roots
  atomically (trackTarget generations target OptionalTarget 10)
  _ ← stepGenerations generations (at 0) (Map.singleton target (TargetGeometry (Right ()) (Just (SurfaceExtent 640 480)) Nothing 1))
  recordingStandIn ← newRecordingStandIn
  recording ← newRecording (recordingStandInOps recordingStandIn) roots generations
  standIn ← newFramesStandIn
  frames ← newFrames (framesStandInOps standIn) recording
  storages ← mapM (\slot → createFrameStorage recording target slot >>= either (fail . show) pure) [0 .. fromIntegral slots - 1]
  views ← atomically (readManaged recording)
  let commands = [handle | ManagedView _ _ "frame storage" [handle] ← views]
  pure (Rig standIn roots generations recording frames target storages commands)

-- | The command buffer of a slot's storage: the stand-in allocates it right
-- after the pool, so it is the pool's number plus one.
commandsOf ∷ Rig → Natural → Word64
commandsOf rig slot = (rigCommands rig !! fromIntegral slot) + 1

acquired ∷ Rig → IO Acquisition
acquired rig = tryAcquireFrame (rigFrames rig) (rigTarget rig) >>= either (fail . ("the acquisition was refused: " <>) . show) pure

owned ∷ Rig → IO OwnedFrame
owned rig =
  acquired rig >>= \case
    AcquisitionOwned frame → pure frame
    other → fail ("no frame was acquired: " <> show other)

-- | An empty batch, sealed, for the frame.
sealed ∷ Rig → OwnedFrame → IO BatchId
sealed rig frame = fst <$> (recordFrame (rigRecording rig) (ownedFrame frame) (\_ → pure ()) >>= either (fail . ("the recording was refused: " <>) . show) pure)

submitted ∷ Rig → NonEmpty BatchId → IO SubmissionId
submitted rig batches =
  submitFrames (rigFrames rig) batches >>= \case
    Right (SubmittedAs submission) → pure submission
    other → fail ("the submission answered " <> show other)

progress ∷ Rig → IO Progress
progress rig = progressFrames (rigFrames rig) (at 1)

-- | Complete everything pending and step, until no frame is being abandoned
-- and nothing is pending.
settleAll ∷ Rig → IO ()
settleAll rig = go (8 ∷ Int)
  where
    go 0 = expectationFailure "the frames did not settle in eight steps"
    go remaining = do
      completeAll (rigStandIn rig)
      report ← progress rig
      abandoning ← filter (abandoningStage . standingStage) <$> atomically (readFrameStandings (rigFrames rig))
      pending ← pendingFences (rigStandIn rig)
      when (not (null abandoning) || not (null pending) || progressOutstanding report > 0) (go (remaining - 1))
    abandoningStage = \case
      StageSkipping → True
      StageClosing _ → True
      StageSettling → True
      _ → False

ok ∷ Show refusal ⇒ IO (Either refusal ()) → IO ()
ok action = action >>= either (fail . ("refused: " <>) . show) pure

-- | Require that no call broke a rule the stand-in holds the frames to.
clean ∷ Rig → Expectation
clean rig = violations (rigStandIn rig) `shouldReturn` []

-- | Run the action on this, the owner's, thread, with a cancellation aimed at
-- it from inside the first call the predicate selects: it can be delivered
-- only once the handoff that call is part of has recorded its result.
cancelled ∷ Show a ⇒ Rig → (FrameCall → Bool) → IO a → IO ()
cancelled rig selected action = do
  owner ← myThreadId
  armed ← newIORef True
  duringFrameCall (rigStandIn rig) $ \call → when (selected call) $ do
    first ← atomicModifyIORef' armed (\armed' → (False, armed'))
    when first $ do
      killer ← forkIO (killThread owner)
      awaitThrowing killer
  outcome ← try @SomeException action
  duringFrameCall (rigStandIn rig) (\_ → pure ())
  case outcome of
    Left failure → fromException failure `shouldBe` Just ThreadKilled
    Right value → expectationFailure ("the cancellation was not delivered: " <> show value)

awaitThrowing ∷ ThreadId → IO ()
awaitThrowing thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → pure ()
    _ → yield >> awaitThrowing thread

inModel ∷ Rig → (GpuModel → Outcome GpuModel) → IO ()
inModel rig operation = atomically $ stateRootsModel (rigRoots rig) $ \model → case operation model of
  Admitted next → ((), next)
  _ → error "the model refused the operation"

-- | Fill the object budget, so nothing more can be admitted.
exhaust ∷ Rig → IO ()
exhaust rig = atomically $ stateRootsModel (rigRoots rig) $ \model →
  let remaining = objectLimit (modelBudgets model) - usageObjects (usage model)
   in case beginAllocation 0 remaining model of
        Admitted (next, _) → ((), next)
        _ → error "the budget could not be filled"

modelOf ∷ Rig → IO GpuModel
modelOf rig = atomically (readRootsModel (rigRoots rig))

frameOf ∷ Rig → FrameSlotId → IO (Maybe FrameView)
frameOf rig frame = frameView frame <$> modelOf rig

phaseOf ∷ Rig → FrameSlotId → IO (Maybe FramePhase)
phaseOf rig frame = fmap viewFramePhase <$> frameOf rig frame

targetOf ∷ Rig → IO TargetView
targetOf rig = modelOf rig >>= maybe (fail "the target is not the model's") pure . targetView (rigTarget rig)

generationsOf ∷ Rig → IO TargetGenerationsView
generationsOf rig = atomically (readTargetGenerations (rigGenerations rig) (rigTarget rig)) >>= maybe (fail "the target is not tracked") pure

activeGeneration ∷ Rig → IO GenerationId
activeGeneration rig = generationsOf rig >>= maybe (fail "the target has no active generation") pure . viewActive

submittedOn ∷ Rig → HoldSubject → IO [SubmissionId]
submittedOn rig subject = maybe [] viewSubmitted . holdView subject <$> modelOf rig

standingOf ∷ Rig → FrameSlotId → IO (Maybe FrameStage)
standingOf rig frame = lookup frame . map (\standing → (standingFrame standing, standingStage standing)) <$> atomically (readFrameStandings (rigFrames rig))

acquisitionState ∷ Rig → FrameSlotId → IO (Maybe SemaphoreState)
acquisitionState rig frame =
  lookup (frameSlotNumber frame) . map (\view → (viewSlotNumber view, syncAcquireState (viewSlotSync view))) <$> atomically (readSlots (rigFrames rig))

raises ∷ ∀ e a. (Exception e, Show a) ⇒ IO a → (e → Bool) → Expectation
raises action expected =
  try @e action >>= \case
    Left failure → unless (expected failure) (expectationFailure ("an unexpected failure: " <> show failure))
    Right value → expectationFailure ("nothing was raised: " <> show value)

shouldReturn' ∷ IO a → (a → IO ()) → IO ()
shouldReturn' action assertion = action >>= assertion

partialStanding ∷ BatchStanding → Bool
partialStanding = \case
  BatchPartial _ → True
  _ → False

uncertainStage, failedStage, submittedStage ∷ FrameStage → Bool
uncertainStage = \case
  StageUncertain _ → True
  _ → False
failedStage = \case
  StageFailed _ → True
  _ → False
submittedStage = \case
  StageSubmitted _ → True
  _ → False

kind ∷ FrameCall → Text
kind = \case
  CreatedSemaphore _ → "semaphore"
  CreatedFence _ → "fence"
  Acquired {} → "acquire"
  _ → "other"

isSubmission, isQuery, isRelease, isAcquisition, isCleanup, isDestruction ∷ FrameCall → Bool
isSubmission = \case
  Submitted {} → True
  _ → False
isQuery = \case
  QueriedFence _ → True
  _ → False
isRelease = \case
  Released {} → True
  _ → False
isAcquisition = \case
  Acquired {} → True
  _ → False
isCleanup = \case
  Submitted batches _ → all (\(_, _, commands, _) → null commands) batches
  _ → False
isDestruction = \case
  DestroyedSemaphore _ → True
  DestroyedFence _ → True
  _ → False

-- | The instant this many milliseconds after the scripted clock's origin.
at ∷ Integer → Instant
at milliseconds = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero (milliseconds * 1000000)))
