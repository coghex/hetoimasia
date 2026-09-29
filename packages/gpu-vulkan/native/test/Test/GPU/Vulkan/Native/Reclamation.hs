-- | Allocation recovery (VK-14, D-25) over the frames' rig, and a lost surface
-- as the frames report it.
--
-- An out-of-memory failure with a specified no-effect result — a submission, a
-- presentation — or a creation that raised and so created nothing gets one
-- bounded reclamation pass over subjects already eligible for disposal, and
-- the failed operation once more only if that pass actually disposed of
-- something. The rig's retired generation is what there is to reclaim: a
-- target rebuilt for an out-of-date result retires its old generation, whose
-- holds have all ended, and which the owner's next step would destroy.
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Reclamation (spec) where

import Control.Concurrent (forkIO, killThread, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), Exception, throwIO, toException, try)
import Control.Monad (when)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model
  ( PresentOutcome (..)
  , RetryVerdict (..)
  , SessionFailureCause (CleanupFailed)
  , SessionState (..)
  , TargetView (..)
  , Usage (..)
  , deviceLossObserved
  , disposalEligible
  , sessionState
  , usage
  )
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest)
import Hetoimasia.GPU.Model.Identity (GenerationId, HoldSubject (..), TargetClass (..), TargetId, generationTarget)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( AllocationNotRecovered (..)
  , GenerationView (..)
  , RecoveryEnd (..)
  , StepSummary (..)
  , SwapchainResult (..)
  , TargetCondition (..)
  , TargetGenerationsView (..)
  , noteSwapchainResult
  , stepGenerations
  , trackTarget
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..), TargetGeometry (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (Refusal (..), createReadback, recordFrame)
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( GraphicsDeviceLost (..)
  , NativeFailure (..)
  , TerminalReport (..)
  , admitRootTarget
  , readRootsTerminal
  )
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), RecordingStandIn, RecordingStep (..), onceAt, outOfMemoryAt, recordingCalls)
import qualified Test.GPU.Vulkan.Native.StandIn as Roots

spec ∷ Spec
spec = describe "Allocation recovery" $ do
  describe "a construction that ran out of memory" $ do
    it "reclaims a retired generation once, and makes the construction once more, which succeeds" $ do
      (rig, recording) ← rigWithRecording 1
      old ← retiredEligible rig (rigTarget rig)
      oldSwapchain ← swapchainOf rig old
      outOfMemoryAt recording AtCreateReadback 1
      created ← createReadback (rigRecording rig) 1024
      either (\refusal → expectationFailure ("refused: " <> show refusal)) (const (pure ())) created
      readbacks recording `shouldReturn` 2
      -- The retired generation was destroyed, child before parent, between
      -- the two creations, and the model recorded its disposal.
      destroyedSwapchains rig `shouldReturn` [oldSwapchain]
      disposalEligible (GenerationSubject old) <$> modelOf rig `shouldReturn` False
      map viewGeneration . viewGenerations <$> generationsOf rig >>= (`shouldSatisfy` notElem old)
      clean rig

    it "does not retry without reclamation progress, and reports the original failure with the pass's evidence" $ do
      (rig, recording) ← rigWithRecording 1
      before ← usageObjects . usage <$> modelOf rig
      outOfMemoryAt recording AtCreateReadback 1
      failure ← notRecovered (createReadback (rigRecording rig) 1024)
      notRecoveredEnd failure `shouldBe` RetryRefused RetryWithoutReclamation
      notRecoveredDisposed failure `shouldBe` []
      notRecoveredExamined failure `shouldSatisfy` (> 0)
      notRecoveredFailure failure `shouldSatisfy` Text.isInfixOf "FailedOutOfMemory"
      readbacks recording `shouldReturn` 1
      -- The attempt's accounting was given back.
      usageObjects . usage <$> modelOf rig `shouldReturn` before

    it "ends the recovery at a second failure, with one retry made" $ do
      (rig, recording) ← rigWithRecording 1
      _ ← retiredEligible rig (rigTarget rig)
      outOfMemoryAt recording AtCreateReadback 2
      failure ← notRecovered (createReadback (rigRecording rig) 1024)
      notRecoveredEnd failure `shouldSatisfy` \case
        RetryFailedAgain _ → True
        _ → False
      length (notRecoveredDisposed failure) `shouldBe` 1
      readbacks recording `shouldReturn` 2

    it "gives the reservation back when the retry raises a failure the roots classify, which it re-raises" $ do
      (rig, recording) ← rigWithRecording 1
      _ ← retiredEligible rig (rigTarget rig)
      before ← usage <$> modelOf rig
      atRetry ← retryRaising rig recording (throwIO (Roots.StandInResult "retry" FailedSurfaceLost))
      raisedBy (createReadback (rigRecording rig) readbackBytes) `shouldReturn` Roots.StandInResult "retry" FailedSurfaceLost
      readbacks recording `shouldReturn` 2
      atRetry >>= givenBack rig before

    it "gives the reservation back when the retry loses the device, whose loss it re-raises and latches" $ do
      (rig, recording) ← rigWithRecording 1
      _ ← retiredEligible rig (rigTarget rig)
      before ← usage <$> modelOf rig
      atRetry ← retryRaising rig recording (throwIO (Roots.StandInLoss Roots.AtFrameCall))
      loss ← raisedBy (createReadback (rigRecording rig) readbackBytes)
      lostDuring loss `shouldBe` "vkCreateBuffer"
      reportDeviceLost <$> atomically (readRootsTerminal (rigRoots rig)) `shouldReturn` Just loss
      deviceLossObserved <$> modelOf rig `shouldReturn` True
      atRetry >>= givenBack rig before

    it "gives the reservation back when the retry is cancelled, which it re-raises" $ do
      (rig, recording) ← rigWithRecording 1
      _ ← retiredEligible rig (rigTarget rig)
      before ← usage <$> modelOf rig
      started ← newEmptyMVar
      never ← newEmptyMVar
      -- The construction runs on the owner's thread, this one; the
      -- cancellation comes from another once the retry is under way.
      owner ← myThreadId
      _ ← forkIO (takeMVar started >> killThread owner >> putMVar never ())
      atRetry ← retryRaising rig recording (putMVar started () >> takeMVar never)
      raisedBy (createReadback (rigRecording rig) readbackBytes) `shouldReturn` ThreadKilled
      atRetry >>= givenBack rig before

    it "gives the reservation back when the reclamation pass is cancelled, which it re-raises" $ do
      (rig, recording) ← rigWithRecording 1
      old ← retiredEligible rig (rigTarget rig)
      oldSwapchain ← swapchainOf rig old
      before ← usage <$> modelOf rig
      gate ← newTVarIO False
      Roots.script (rigRootsStandIn rig) Roots.AtDestroySwapchain (Roots.WaitsInterruptibly gate)
      outOfMemoryAt recording AtCreateReadback 1
      owner ← myThreadId
      _ ← forkIO (Roots.awaitCall (rigRootsStandIn rig) (Roots.DestroyedSwapchain oldSwapchain) >> killThread owner >> atomically (writeTVar gate True))
      raisedBy (createReadback (rigRecording rig) readbackBytes) `shouldReturn` ThreadKilled
      readbacks recording `shouldReturn` 1
      -- The pass released nothing: its one destruction never returned.
      after ← usage <$> modelOf rig
      usageAllocations after `shouldBe` usageAllocations before
      (usageBytes after, usageObjects after) `shouldBe` (usageBytes before, usageObjects before)

    it "escalates a disposal that failed and permits no retry, however much else the pass reclaimed" $ do
      (rig, recording) ← rigWithRecording 2
      [firstOld, secondOld] ← retiredEligibleAll rig (rigTargets rig)
      -- The first generation's destruction returns; the second's swapchain
      -- destruction raises.
      Roots.script (rigRootsStandIn rig) Roots.AtDestroySwapchain (Roots.SucceedsThenFails 1)
      outOfMemoryAt recording AtCreateReadback 1
      failure ← notRecovered (createReadback (rigRecording rig) 1024)
      notRecoveredDisposed failure `shouldBe` [GenerationSubject firstOld]
      notRecoveredFailed failure `shouldBe` [GenerationSubject secondOld]
      notRecoveredEnd failure `shouldSatisfy` \case
        RetryUnadmitted _ → True
        _ → False
      readbacks recording `shouldReturn` 1
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed

    it "examines a bounded window, and reaches an eligible generation beyond it at a later pass through the carried cursor" $ do
      (rig, recording) ← rigWithRecordingOver 2 defaultBudgetRequest {requestedReclaimExamination = 1}
      [_, second] ← pure (rigTargets rig)
      _ ← retiredEligible rig second
      -- The window holds one record: the first target's active generation,
      -- which is not eligible. Examining it is not progress.
      outOfMemoryAt recording AtCreateReadback 1
      failure ← notRecovered (createReadback (rigRecording rig) 1024)
      notRecoveredExamined failure `shouldBe` 1
      notRecoveredEnd failure `shouldBe` RetryRefused RetryWithoutReclamation
      -- The next failure's pass starts where that one stopped, and reaches
      -- the second target's retired generation.
      outOfMemoryAt recording AtCreateReadback 1
      again ← createReadback (rigRecording rig) 1024
      either (\refusal → expectationFailure ("refused: " <> show refusal)) (const (pure ())) again
      readbacks recording `shouldReturn` 3

    it "keeps configured-capacity exhaustion backpressure, starting no recovery and making no native call" $ do
      (rig, recording) ← rigWithRecording 1
      _ ← retiredEligible rig (rigTarget rig)
      exhaust rig
      createReadback (rigRecording rig) 1024 >>= \case
        Left (RefusedBackpressure _) → pure ()
        other → expectationFailure ("expected backpressure, got " <> show (fmap (const ()) other))
      readbacks recording `shouldReturn` 0
      destroyedSwapchains rig `shouldReturn` []

  describe "a swapchain creation that ran out of memory" $ do
    it "is made once more after reclamation when it handed nothing over" $ do
      (rig, _) ← rigWithRecording 1
      target ← admitRootTarget (rigRoots rig) OptionalTarget (Roots.surfaceNumbered (rigRootsStandIn rig) 12) >>= either (fail . show) pure
      atomically (trackTarget (rigGenerations rig) target OptionalTarget 12)
      -- In one step: the first target is rebuilt for an out-of-date result,
      -- retiring a generation nothing holds, and then the new target's first
      -- creation — handing nothing over — runs out of memory.
      old ← activeGeneration rig
      atomically (noteSwapchainResult (rigGenerations rig) old SwapchainOutOfDate) >>= (`shouldBe` True)
      Roots.script (rigRootsStandIn rig) Roots.AtCreateSwapchain (Roots.AnswersOnceAfter 1 FailedOutOfMemory)
      _ ← stepGenerations (rigGenerations rig) (at 20) (Map.fromList [(rigTarget rig, geometryAt 640 480), (target, geometryAt 640 480)])
      destroyedSwapchains rig >>= (`shouldSatisfy` (not . null))
      viewCondition <$> generationsOn rig target `shouldReturn` Presenting
      length . filter (onSurface 12) <$> Roots.calls (rigRootsStandIn rig) `shouldReturn` 2
      viewTargetRecoveryAttemptsOf rig target `shouldReturn` 0

    it "is never made again once it handed the active generation over as oldSwapchain, even after reclamation" $ do
      (rig, _) ← rigWithRecording 2
      [first, second] ← pure (rigTargets rig)
      _ ← retiredEligible rig second
      active ← activeGenerationOn rig first
      Roots.script (rigRootsStandIn rig) Roots.AtCreateSwapchain (Roots.AnswersOnce FailedOutOfMemory)
      atomically (noteSwapchainResult (rigGenerations rig) active SwapchainOutOfDate) >>= (`shouldBe` True)
      before ← length . filter (onSurface 10) <$> Roots.calls (rigRootsStandIn rig)
      _ ← stepGenerations (rigGenerations rig) (at 20) (Map.singleton first (geometryAt 640 480))
      after ← length . filter (onSurface 10) <$> Roots.calls (rigRootsStandIn rig)
      after - before `shouldBe` 1
      viewCondition <$> generationsOn rig first >>= (`shouldSatisfy` \case
        ConstructionFailed reason → "RetryAfterOldSwapchainRetirement" `Text.isInfixOf` reason
        _ → False)
      -- The pass ran all the same: the other target's retired generation is
      -- gone.
      destroyedSwapchains rig >>= (`shouldSatisfy` (not . null))

  describe "a frame slot's synchronization that ran out of memory" $ do
    it "is made once more after reclamation, and the acquisition proceeds" $ do
      (rig, _) ← rigWithRecording 2
      [first, second] ← pure (rigTargets rig)
      _ ← retiredEligible rig second
      outOfMemoryAtFrame (rigStandIn rig) AtCreateSemaphore 1
      _ ← ownedOn rig first
      destroyedSwapchains rig >>= (`shouldSatisfy` (not . null))
      clean rig

    it "gives the reservation back and reports the failure when nothing was reclaimed" $ do
      (rig, _) ← rigWithRecording 1
      outOfMemoryAtFrame (rigStandIn rig) AtCreateSemaphore 1
      failure ← notRecovered (tryAcquireFrame (rigFrames rig) (rigTarget rig))
      notRecoveredEnd failure `shouldBe` RetryRefused RetryWithoutReclamation
      -- The reservation went back whole: the next acquisition is served.
      _ ← owned rig
      clean rig

  describe "a submission with no effect" $ do
    it "is submitted once more after reclamation, its batch recorded once" $ do
      (rig, _) ← rigWithRecording 2
      [first, second] ← pure (rigTargets rig)
      runs ← newIORef (0 ∷ Int)
      frame ← ownedOn rig first
      (batch, _) ← recordFrame (rigRecording rig) (ownedFrame frame) (\_ → modifyIORef' runs (+ 1)) >>= either (fail . show) pure
      _ ← retiredEligible rig second
      failOnce rig AtSubmitNoEffect isSubmission
      submitFrames (rigFrames rig) (batch :| []) >>= \case
        Right (SubmittedAs _) → pure ()
        other → expectationFailure ("the submission answered " <> show other)
      length . filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` 2
      readIORef runs `shouldReturn` 1
      clean rig

    it "still reclaims and is submitted once more when the object budget is full, with no attempt to account" $ do
      (rig, _) ← rigWithRecording 2
      [first, second] ← pure (rigTargets rig)
      frame ← ownedOn rig first
      batch ← sealed rig frame
      _ ← retiredEligible rig second
      exhaust rig
      failOnce rig AtSubmitNoEffect isSubmission
      submitFrames (rigFrames rig) (batch :| []) >>= \case
        Right (SubmittedAs _) → pure ()
        other → expectationFailure ("the submission answered " <> show other)
      length . filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` 2
      destroyedSwapchains rig >>= (`shouldSatisfy` (not . null))
      clean rig

    it "answers nothing submitted, naming the pass, when nothing was reclaimed, and is submitted once" $ do
      (rig, _) ← rigWithRecording 1
      frame ← owned rig
      batch ← sealed rig frame
      failFrameStep (rigStandIn rig) AtSubmitNoEffect
      submitFrames (rigFrames rig) (batch :| []) >>= \case
        Right (SubmittedNothing reason) → reason `shouldSatisfy` Text.isInfixOf "not recovered"
        other → expectationFailure ("the submission answered " <> show other)
      length . filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` 1
      clean rig

  describe "a presentation with no effect" $
    it "is presented once more after reclamation" $ do
      (rig, _) ← rigWithRecording 2
      [first, second] ← pure (rigTargets rig)
      _ ← retiredEligible rig second
      frame ← ownedOn rig first
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaisingUnwritten (toException StandInOutOfMemory)]
      presentFrame (rigFrames rig) (ownedFrame frame) >>= \case
        Right (PresentedAs _ PresentationEnqueued) → pure ()
        other → expectationFailure ("the presentation answered " <> show other)
      length . filter isPresentation <$> frameCalls (rigStandIn rig) `shouldReturn` 2
      clean rig

  describe "a lost surface, as the frames report it" $ do
    it "gives an acquisition's reservation back, reports the loss, and acquires nothing more until the surface is replaced" $ do
      (rig, _) ← rigWithRecording 1
      scriptAcquire (rigStandIn rig) [AcquiringSurfaceLost]
      acquired rig `shouldReturn'` \case
        AcquisitionPending PendingSurfaceLost → pure ()
        other → expectationFailure ("the acquisition answered " <> show other)
      _ ← stepGenerations (rigGenerations rig) (at 20) (geometries (rigTargets rig) (SurfaceExtent 640 480))
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceLost
      before ← length . filter isAcquisition <$> frameCalls (rigStandIn rig)
      acquired rig `shouldReturn'` \case
        AcquisitionPending PendingSurfaceLost → pure ()
        other → expectationFailure ("the acquisition answered " <> show other)
      length . filter isAcquisition <$> frameCalls (rigStandIn rig) `shouldReturn` before
      -- Nothing of the lost acquisition is held: the target's frames retire.
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      clean rig

    it "keeps a presentation that answered the surface lost enqueued, and retires its generation only once its present fence has" $ do
      (rig, _) ← rigWithRecording 1
      frame ← owned rig
      generation ← activeGeneration rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaising PresentStatusSurfaceLost (toException (ErrorCall "VK_ERROR_SURFACE_LOST_KHR"))]
      presentFrame (rigFrames rig) (ownedFrame frame) >>= \case
        Right (PresentedAs _ PresentationEnqueuedSurfaceLost) → pure ()
        other → expectationFailure ("the presentation answered " <> show other)
      wanted ← stepGenerations (rigGenerations rig) (at 20) (geometries (rigTargets rig) (SurfaceExtent 640 480))
      summarySurfacesWanted wanted `shouldBe` []
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceLost
      -- Its presentation still holds the retired generation, so neither it
      -- nor the surface goes.
      _ ← stepGenerations (rigGenerations rig) (at 21) (geometries (rigTargets rig) (SurfaceExtent 640 480))
      map viewGeneration . viewGenerations <$> generationsOf rig `shouldReturn` [generation]
      settleAll rig
      _ ← stepGenerations (rigGenerations rig) (at 22) (geometries (rigTargets rig) (SurfaceExtent 640 480))
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceReplacing
      clean rig

-- ---------------------------------------------------------------------------
-- Helpers

-- | A frames rig of this many targets, and its recording's stand-in.
rigWithRecording ∷ Int → IO (Rig, RecordingStandIn)
rigWithRecording count = rigWithRecordingOver count defaultBudgetRequest

rigWithRecordingOver ∷ Int → BudgetRequest → IO (Rig, RecordingStandIn)
rigWithRecordingOver count request = do
  rig ← newRigOver count request
  pure (rig, rigRecordingStandIn rig)

-- | 'retiredEligible' for several targets at once, in one step, so no step's
-- disposal runs between them.
retiredEligibleAll ∷ Rig → [TargetId] → IO [GenerationId]
retiredEligibleAll rig targets = do
  olds ← mapM (activeGenerationOn rig) targets
  mapM_ (\old → atomically (noteSwapchainResult (rigGenerations rig) old SwapchainOutOfDate) >>= (`shouldBe` True)) olds
  _ ← stepGenerations (rigGenerations rig) (at 10) (Map.fromList [(target, geometryAt 640 480) | target ← targets])
  model ← modelOf rig
  map (\old → disposalEligible (GenerationSubject old) model) olds `shouldBe` map (const True) olds
  pure olds

-- | Rebuild the target for an out-of-date result at unchanged geometry, and
-- answer the generation that retired: every hold on it has ended, and it waits
-- for the owner's next step to destroy it.
retiredEligible ∷ Rig → TargetId → IO GenerationId
retiredEligible rig target = do
  old ← activeGenerationOn rig target
  atomically (noteSwapchainResult (rigGenerations rig) old SwapchainOutOfDate) >>= (`shouldBe` True)
  _ ← stepGenerations (rigGenerations rig) (at 10) (Map.singleton target (geometryAt 640 480))
  model ← modelOf rig
  disposalEligible (GenerationSubject old) model `shouldBe` True
  pure old

swapchainOf ∷ Rig → GenerationId → IO Word64
swapchainOf rig generation = do
  views ← generationsOn rig (generationTarget generation)
  maybe (fail "the generation has no swapchain") pure (lookup generation [(viewGeneration view, viewSwapchain view) | view ← viewGenerations views] >>= id)

-- | An eligible target observed at this framebuffer.
geometryAt ∷ Word32 → Word32 → TargetGeometry
geometryAt width height = TargetGeometry (Right ()) (Just (SurfaceExtent width height)) Nothing 1

-- | The readback every construction example makes, and the accounting its
-- construction reserves: its bytes, and its buffer and memory.
readbackBytes, readbackObjects ∷ Natural
readbackBytes = 1024
readbackObjects = 2

-- | Have the readback creation answer out of memory, and its one retry run
-- this — which raises — once it has read the model's usage: the attempt still
-- reserved, and whatever the reclamation pass released already gone. Answers
-- that usage, once the retry has run.
retryRaising ∷ Rig → RecordingStandIn → IO () → IO (IO Usage)
retryRaising rig recording raise = do
  seen ← newIORef Nothing
  outOfMemoryAt recording AtCreateReadback 1
  onceAt recording AtCreateReadback (modelOf rig >>= writeIORef seen . Just . usage >> raise)
  pure (readIORef seen >>= maybe (fail "the retry was never made") pure)

-- | The failed construction left no attempt behind and gave its reservation
-- back: usage is what it was before the construction, less what the
-- reclamation pass released, which disposed of something.
givenBack ∷ Rig → Usage → Usage → IO ()
givenBack rig before atRetry = do
  after ← usage <$> modelOf rig
  let releasedBytes = usageBytes before + readbackBytes - usageBytes atRetry
      releasedObjects = usageObjects before + readbackObjects - usageObjects atRetry
  releasedObjects `shouldSatisfy` (> 0)
  usageAllocations after `shouldBe` usageAllocations before
  (usageBytes after, usageObjects after) `shouldBe` (usageBytes before - releasedBytes, usageObjects before - releasedObjects)

-- | Run the action, which must raise this exception, and answer it.
raisedBy ∷ (Exception e, Show a) ⇒ IO a → IO e
raisedBy action =
  try action >>= \case
    Left failure → pure failure
    Right value → do
      expectationFailure ("nothing was raised: " <> show value)
      fail "unreachable"

-- | How many readbacks the recording asked the native layer for.
readbacks ∷ RecordingStandIn → IO Int
readbacks recording = length . filter (\case CreatedReadback {} → True; _ → False) <$> recordingCalls recording

-- | Every swapchain the roots' stand-in destroyed, oldest first.
destroyedSwapchains ∷ Rig → IO [Word64]
destroyedSwapchains rig = (\recorded → [swapchain | Roots.DestroyedSwapchain swapchain ← recorded]) <$> Roots.calls (rigRootsStandIn rig)

-- | Whether a call created a swapchain for this surface.
onSurface ∷ Word64 → Roots.Call → Bool
onSurface surface = \case
  Roots.CreatedSwapchain _ on _ _ → on == surface
  _ → False

viewTargetRecoveryAttemptsOf ∷ Rig → TargetId → IO Natural
viewTargetRecoveryAttemptsOf rig target = viewTargetRecoveryAttempts <$> targetViewOf rig target

-- | Run the action, which must raise 'AllocationNotRecovered'.
notRecovered ∷ Show a ⇒ IO a → IO AllocationNotRecovered
notRecovered action =
  try action >>= \case
    Left failure → pure failure
    Right value → do
      expectationFailure ("the allocation was not refused: " <> show value)
      fail "unreachable"

-- | Fail the step at the first call the predicate selects, and let the second
-- such call succeed: the hook runs before the stand-in checks its failures.
failOnce ∷ Rig → FrameStep → (FrameCall → Bool) → IO ()
failOnce rig failing selected = do
  seenCalls ← newIORef (0 ∷ Int)
  failFrameStep (rigStandIn rig) failing
  duringFrameCall (rigStandIn rig) $ \call →
    when (selected call) $ do
      count ← atomicModifyIORef' seenCalls (\held → (held + 1, held + 1))
      when (count == 2) (clearFrameStep (rigStandIn rig) failing)
