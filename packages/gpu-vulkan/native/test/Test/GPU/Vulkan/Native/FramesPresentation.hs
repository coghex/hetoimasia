-- | Presentation and retirement over stand-in native layers (VK-13): a
-- submitted frame presented through its target's presentation pool; the render
-- fence unable to free presentation objects; an image reacquired while its
-- older presentation is still pending; a delayed presentation keeping its
-- obligations; each per-swapchain answer — suboptimal, out of date, surface
-- lost, out of memory and unreadable — classified by its actual effect;
-- skipped and never-presented frames settling separately; pool exhaustion as
-- bounded backpressure; a finite drain wait that times out; cancellation at the
-- presentation handoff; incremental generation retirement across targets; and
-- the first target's close leaving the shared roots valid for the second.
--
-- The frames' stand-in ("Test.GPU.Vulkan.Native.FramesStandIn") models what
-- Vulkan holds the application to, presentation included, and every example
-- ends by requiring that nothing broke it. A fence signals only when an example
-- completes it. Nothing here creates a Vulkan object, and nothing waits on a
-- clock.
module Test.GPU.Vulkan.Native.FramesPresentation (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM, atomically)
import Control.Exception (ErrorCall (ErrorCall), SomeException, toException, try)
import Control.Monad (forM, forM_, replicateM, void)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Word (Word32, Word64)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldNotBe, shouldReturn, shouldSatisfy)

import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), durationFromNanoseconds, durationNanoseconds)
import Hetoimasia.GPU.Model
  ( FramePhase (..)
  , HoldView (..)
  , PresentOutcome (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , TargetView (..)
  , holdView
  , presentationImage
  , sessionState
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind (..), BudgetRequest (..), defaultBudgetRequest, presentationPoolCapacity, validateBudgets)
import Hetoimasia.GPU.Model.Identity (HoldSubject (..), IdentityKind (..), ImageId, Misuse (..), PresentationId, frameSlotNumber, generationTarget, imageGeneration, imageIndex)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Generations
import Hetoimasia.GPU.Vulkan.Native.Recording (Refusal (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceCapabilities (..), SurfaceExtent (..), SurfaceOffer (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (TerminalCause (..), failRootsSession, retireRootTarget, retireRoots)
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import qualified Test.GPU.Vulkan.Native.StandIn as Roots

spec ∷ Spec
spec = describe "Frames presentation" $ do
  describe "presentation" $ do
    it "presents a submitted frame's image to its swapchain, waiting on its pool record's semaphore, with the record's present fence reset just before" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      [PoolView _ number pool] ← atomically (readPool (rigFrames rig))
      presentation ← presentedAs rig frame PresentationEnqueued
      calls ← frameCalls (rigStandIn rig)
      let presents = [request | Presented request _ ← calls]
      map presentWait presents `shouldBe` [poolRendered pool]
      map presentFence presents `shouldBe` [poolFence pool]
      map presentIndex presents `shouldBe` [fromIntegral (imageIndex (ownedImage frame))]
      -- The fence was reset immediately before the presentation it was passed to.
      take 2 (dropWhile (/= ResetFence (poolFence pool)) calls) `shouldSatisfy` \case
        [ResetFence _, Presented _ PresentStatusSuccess] → True
        _ → False
      [PoolView _ number' held] ← atomically (readPool (rigFrames rig))
      (number', poolHolder held, poolRenderedState held, poolFenceState held)
        `shouldBe` (number, PoolHeldByPresentation presentation, SemaphoreWaitOwed, FencePending)
      -- The frame's record gives way to the presentation's.
      atomically (readFrameStandings (rigFrames rig)) `shouldReturn` []
      map standingPresentedFrame <$> atomically (readPresentations (rigFrames rig)) `shouldReturn` [ownedFrame frame]
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FramePresentationEnqueued
      presentationsOn rig (ownedImage frame) `shouldReturn` [presentation]
      imagesOwned (rigStandIn rig) `shouldReturn` []
      clean rig

    it "presents before the rendering completed, and a signalled render fence frees no presentation object" $ do
      rig ← newRig
      frame ← owned rig
      submission ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      presentation ← presentedAs rig frame PresentationEnqueued
      [SlotView _ _ slot] ← atomically (readSlots (rigFrames rig))
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      -- Only the rendering completes.
      completeFence (rigStandIn rig) (syncFence slot)
      progress rig `shouldReturn'` \report → (progressCompleted report, progressRetired report) `shouldBe` ([submission], [])
      -- The slot is free again; the presentation keeps its record, its
      -- semaphore and its generation's hold.
      viewTargetFrames <$> targetOf rig `shouldReturn` 0
      viewTargetPoolRecords <$> targetOf rig `shouldReturn` 1
      [PoolView _ _ held] ← atomically (readPool (rigFrames rig))
      (poolHolder held, poolRenderedState held, poolFenceState held) `shouldBe` (PoolHeldByPresentation presentation, SemaphoreWaitOwed, FencePending)
      presentationsOn rig (ownedImage frame) `shouldReturn` [presentation]
      -- Only the present fence retires it.
      completeFence (rigStandIn rig) (poolFence pool)
      progress rig `shouldReturn'` \report → progressRetired report `shouldBe` [presentation]
      [PoolView _ _ freed] ← atomically (readPool (rigFrames rig))
      (poolHolder freed, poolRenderedState freed, poolFenceState freed) `shouldBe` (PoolFree, SemaphoreUnsignalled, FenceSignalled)
      presentationsOn rig (ownedImage frame) `shouldReturn` []
      viewTargetPoolRecords <$> targetOf rig `shouldReturn` 0
      atomically (readPresentations (rigFrames rig)) `shouldReturn` []
      clean rig

    it "treats a present fence that has not signalled as pending, whatever it answered before, and retires on the answer that it has" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      presentation ← presentedAs rig frame PresentationEnqueued
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      forM_ [1 .. 3 ∷ Int] $ \_ →
        progress rig `shouldReturn'` \report → progressRetired report `shouldBe` []
      length . filter (== QueriedFence (poolFence pool)) <$> frameCalls (rigStandIn rig) `shouldReturn` 3
      viewTargetPoolRecords <$> targetOf rig `shouldReturn` 1
      completeFence (rigStandIn rig) (poolFence pool)
      progress rig `shouldReturn'` \report → progressRetired report `shouldBe` [presentation]
      settleAll rig
      clean rig

    it "reacquires the image of a pending presentation through a free pool record, waiting on no fence and retiring nothing" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      presentation ← presentedAs rig frame PresentationEnqueued
      [PoolView _ older _] ← atomically (readPool (rigFrames rig))
      before ← length <$> frameCalls (rigStandIn rig)
      scriptAcquire (rigStandIn rig) [AcquiredIndex (fromIntegral (imageIndex (ownedImage frame)))]
      again ← owned rig
      ownedImage again `shouldBe` ownedImage frame
      since ← drop before <$> frameCalls (rigStandIn rig)
      filter (\call → isQuery call || isWait call) since `shouldBe` []
      -- A second record, made for the new frame; the older one still serves
      -- the pending presentation, which still names the image.
      pools ← atomically (readPool (rigFrames rig))
      [(viewPoolNumber view, poolHolder (viewPoolSync view)) | view ← pools]
        `shouldBe` [(older, PoolHeldByPresentation presentation), (older + 1, PoolHeldByFrame (ownedFrame again))]
      presentationImageOf rig presentation `shouldReturn` Just (ownedImage frame)
      map standingPresentation <$> atomically (readPresentations (rigFrames rig)) `shouldReturn` [presentation]
      -- The new frame renders and presents on its own record.
      _ ← sealed rig again >>= \batch → submitted rig (batch :| [])
      later ← presentedAs rig again PresentationEnqueued
      later `shouldNotBe` presentation
      settleAll rig
      atomically (readPresentations (rigFrames rig)) `shouldReturn` []
      clean rig

    it "keeps a delayed presentation's obligations and its pool record, then presents it after its rendering completed" $ do
      rig ← newRig
      frame ← owned rig
      submission ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → progressCompleted report `shouldBe` [submission]
      -- Rendered and not yet presented: the frame, its image, its slot and its
      -- record all stay.
      standingOf rig (ownedFrame frame) `shouldReturn` Just (StageSubmitted submission)
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameSubmitted
      viewTargetFrames <$> targetOf rig `shouldReturn` 1
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      (poolHolder pool, poolRenderedState pool) `shouldBe` (PoolHeldByFrame (ownedFrame frame), SemaphoreSignalOwed)
      imagesOwned (rigStandIn rig) `shouldReturn'` (`shouldSatisfy` (not . null))
      presentation ← presentedAs rig frame PresentationEnqueued
      -- Its submission had completed, so presenting it frees its slot at once.
      viewTargetFrames <$> targetOf rig `shouldReturn` 0
      presentationsOn rig (ownedImage frame) `shouldReturn` [presentation]
      settleAll rig
      presentationsOn rig (ownedImage frame) `shouldReturn` []
      clean rig

    it "refuses a frame not submitted, one already presented, another thread, and a failed session, before any native call" $ do
      rig ← newRig
      frame ← owned rig
      presentFrame (rigFrames rig) (ownedFrame frame) `shouldReturn` Left (RefusedMisuse (WrongPhase FrameIdentity))
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      _ ← presentedAs rig frame PresentationEnqueued
      calls ← length <$> frameCalls (rigStandIn rig)
      -- Presented, the frame is the presentation's: in the wrong phase for a
      -- second presentation, a skip or a close.
      presentFrame (rigFrames rig) (ownedFrame frame) `shouldReturn` Left (RefusedMisuse (WrongPhase FrameIdentity))
      skipFrame (rigFrames rig) (ownedFrame frame) `shouldReturn` Left (RefusedMisuse (WrongPhase FrameIdentity))
      closeUnpresentedFrame (rigFrames rig) (ownedFrame frame) `shouldReturn` Left (RefusedMisuse (WrongPhase FrameIdentity))
      second ← owned rig
      _ ← sealed rig second >>= \batch → submitted rig (batch :| [])
      answer ← onOtherThread (presentFrame (rigFrames rig) (ownedFrame second))
      answer `shouldBe` Left RefusedNotOwner
      atomically (failRootsSessionOf rig)
      presentFrame (rigFrames rig) (ownedFrame second) `shouldReturn` Left (RefusedSessionFailed (TerminalCleanupFailed "CleanupFailed"))
      length . filter isPresentation . drop calls <$> frameCalls (rigStandIn rig) `shouldReturn` 0
      clean rig

  describe "answers classified by their actual effect" $ do
    it "records a suboptimal presentation as enqueued, requests a replacement and resets none of the frame's synchronization" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentReturning PresentStatusSuboptimal]
      [SlotView _ _ slot] ← atomically (readSlots (rigFrames rig))
      before ← length <$> frameCalls (rigStandIn rig)
      _ ← presentedAs rig frame PresentationEnqueuedSuboptimal
      viewTargetReplacementRequested <$> targetOf rig `shouldReturn` True
      viewPendingResult <$> generationsOf rig `shouldReturn` Just SwapchainSuboptimal
      -- The presentation reset only its own present fence, and none of the
      -- slot's synchronization.
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      (drop before <$> frameCalls (rigStandIn rig)) `shouldReturn'` \case
        [ResetFence fence, Presented _ PresentStatusSuboptimal] → fence `shouldBe` poolFence pool
        other → expectationFailure ("the presentation made " <> show other)
      [SlotView _ _ unchanged] ← atomically (readSlots (rigFrames rig))
      unchanged `shouldBe` slot
      settleAll rig
      clean rig

    it "keeps an out-of-date presentation's enqueued operations when the call raised, and requests a replacement" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaising PresentStatusOutOfDate (toException (ErrorCall "VK_ERROR_OUT_OF_DATE_KHR"))]
      presentation ← presentedAs rig frame PresentationEnqueuedOutOfDate
      viewPendingResult <$> generationsOf rig `shouldReturn` Just SwapchainOutOfDate
      viewTargetReplacementRequested <$> targetOf rig `shouldReturn` True
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      (poolHolder pool, poolFenceState pool) `shouldBe` (PoolHeldByPresentation presentation, FencePending)
      -- The semaphore wait happened, and only the present fence ends it.
      completeFence (rigStandIn rig) (poolFence pool)
      progress rig `shouldReturn'` \report → progressRetired report `shouldBe` [presentation]
      settleAll rig
      clean rig

    it "keeps a surface-lost presentation's enqueued operations and requests the target's recovery" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaising PresentStatusSurfaceLost (toException (ErrorCall "VK_ERROR_SURFACE_LOST_KHR"))]
      presentation ← presentedAs rig frame PresentationEnqueuedSurfaceLost
      viewTargetReplacementRequested <$> targetOf rig `shouldReturn` True
      map standingPresentedOutcome <$> atomically (readPresentations (rigFrames rig)) `shouldReturn` [PresentationEnqueuedSurfaceLost]
      presentationsOn rig (ownedImage frame) `shouldReturn` [presentation]
      settleAll rig
      presentationsOn rig (ownedImage frame) `shouldReturn` []
      clean rig

    it "leaves an out-of-memory presentation's frame owned, never waits on its fence, and presents it again" $ do
      rig ← newRig
      frame ← owned rig
      submission ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent
        (rigStandIn rig)
        [ PresentRaising PresentStatusOutOfMemory (toException StandInOutOfMemory)
        , PresentRaisingUnwritten (toException StandInOutOfMemory)
        ]
      forM_ [1, 2 ∷ Int] $ \_ →
        presentFrame (rigFrames rig) (ownedFrame frame) `shouldReturn'` \case
          Right (PresentedNothing _) → pure ()
          other → expectationFailure ("the presentation answered " <> show other)
      standingOf rig (ownedFrame frame) `shouldReturn` Just (StageSubmitted submission)
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameSubmitted
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      (poolHolder pool, poolRenderedState pool, poolFenceState pool) `shouldBe` (PoolHeldByFrame (ownedFrame frame), SemaphoreSignalOwed, FenceIdle)
      imagesOwned (rigStandIn rig) `shouldReturn'` (`shouldSatisfy` (not . null))
      completeAll (rigStandIn rig)
      _ ← progress rig
      filter (== QueriedFence (poolFence pool)) <$> frameCalls (rigStandIn rig) `shouldReturn` []
      _ ← presentedAs rig frame PresentationEnqueued
      settleAll rig
      clean rig

    it "retains a presentation whose answer cannot be read for ever, stops admission and fails the session" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaisingUnwritten (toException (ErrorCall "the driver failed"))]
      presentFrame (rigFrames rig) (ownedFrame frame) `raises` \(FrameEffectUncertain frames' _) → frames' == [ownedFrame frame]
      sessionState <$> modelOf rig `shouldReturn` SessionFailed UnknownSubmissionEffect
      standingOf rig (ownedFrame frame) `shouldReturn'` (`shouldSatisfy` maybe False uncertainStage)
      [PoolView _ number pool] ← atomically (readPool (rigFrames rig))
      poolFenceState pool `shouldSatisfy` \case
        FenceUncertain _ → True
        _ → False
      refusedPrimary rig `shouldReturn'` (`shouldSatisfy` \case
        Just (TerminalUncertainEffect _) → True
        _ → False)
      settleAll rig
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames' _ _ pools) → frames' == [ownedFrame frame] && pools == [number]
      clean rig

    it "reads every per-swapchain answer by its actual effect, never an unwritten entry as success" $ do
      let noEffect failure = show failure == show StandInOutOfMemory
          oom = Just (toException StandInOutOfMemory)
          other = Just (toException (ErrorCall "raised"))
          read' raised status = case classifyPresent noEffect raised status of
            ReadEnqueued outcome → Just (Right outcome)
            ReadNotEnqueued _ → Just (Left ())
            ReadUnknown _ → Nothing
      read' Nothing PresentStatusSuccess `shouldBe` Just (Right PresentationEnqueued)
      read' Nothing PresentStatusSuboptimal `shouldBe` Just (Right PresentationEnqueuedSuboptimal)
      read' other PresentStatusOutOfDate `shouldBe` Just (Right PresentationEnqueuedOutOfDate)
      read' other PresentStatusSurfaceLost `shouldBe` Just (Right PresentationEnqueuedSurfaceLost)
      read' oom PresentStatusOutOfMemory `shouldBe` Just (Left ())
      read' oom PresentStatusUnwritten `shouldBe` Just (Left ())
      -- Unreadable: unwritten, contradictory, or outside the profile.
      read' Nothing PresentStatusUnwritten `shouldBe` Nothing
      read' other PresentStatusUnwritten `shouldBe` Nothing
      read' Nothing PresentStatusOutOfDate `shouldBe` Nothing
      read' other PresentStatusSuccess `shouldBe` Nothing
      read' oom PresentStatusSuccess `shouldBe` Nothing
      read' other (PresentStatusOther (-4)) `shouldBe` Nothing
      read' Nothing PresentStatusOutOfMemory `shouldBe` Nothing

  describe "the presentation handoff" $ do
    it "records a presentation a cancellation reached, then delivers it" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      cancelled rig isPresentation (presentFrame (rigFrames rig) (ownedFrame frame))
      map standingPresentedFrame <$> atomically (readPresentations (rigFrames rig)) `shouldReturn` [ownedFrame frame]
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FramePresentationEnqueued
      settleAll rig
      clean rig

    it "records an out-of-date presentation a cancellation reached — an error return with enqueued obligations — then delivers it" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaising PresentStatusOutOfDate (toException (ErrorCall "VK_ERROR_OUT_OF_DATE_KHR"))]
      cancelled rig isPresentation (presentFrame (rigFrames rig) (ownedFrame frame))
      map standingPresentedOutcome <$> atomically (readPresentations (rigFrames rig)) `shouldReturn` [PresentationEnqueuedOutOfDate]
      viewPendingResult <$> generationsOf rig `shouldReturn` Just SwapchainOutOfDate
      settleAll rig
      clean rig

    it "retains a fence whose reset raised, presenting nothing, and the frame is still closed safely" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      [PoolView _ number _] ← atomically (readPool (rigFrames rig))
      failFrameStep (rigStandIn rig) AtResetFence
      outcome ← try @FrameStepFailed (presentFrame (rigFrames rig) (ownedFrame frame))
      fmap (const ()) outcome `shouldBe` Left (FrameStepFailed AtResetFence)
      clearFrameStep (rigStandIn rig) AtResetFence
      filter isPresentation <$> frameCalls (rigStandIn rig) `shouldReturn` []
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      ok (closeUnpresentedFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      atomically (readFrameStandings (rigFrames rig)) `shouldReturn` []
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames' _ _ pools) → null frames' && pools == [number]
      clean rig

    it "retains a presentation whose present fence could not be asked, and fails the session" $ do
      rig ← newRig
      frame ← owned rig
      submission ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      [SlotView _ _ slot] ← atomically (readSlots (rigFrames rig))
      completeFence (rigStandIn rig) (syncFence slot)
      progress rig `shouldReturn'` \report → progressCompleted report `shouldBe` [submission]
      presentation ← presentedAs rig frame PresentationEnqueued
      failFrameStep (rigStandIn rig) AtQueryFence
      progress rig `raises` \(PresentationUncertain uncertainOne _) → uncertainOne == presentation
      clearFrameStep (rigStandIn rig) AtQueryFence
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      (map standingPresent <$> atomically (readPresentations (rigFrames rig))) `shouldReturn'` \case
        [PresentUncertain _] → pure ()
        other → expectationFailure ("the presentation stands " <> show other)
      -- Never asked again, and never retired.
      completeAll (rigStandIn rig)
      progress rig `shouldReturn'` \report → progressRetired report `shouldBe` []
      presentationsOn rig (ownedImage frame) `shouldReturn` [presentation]
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ _ _ presentations _) → presentations == [presentation]

  describe "the finite drain wait" $ do
    it "waits at most 10 ms on a pending present fence, and a timeout keeps ownership, capacity and the target's retirement withheld" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      presentation ← presentedAs rig frame PresentationEnqueued
      [SlotView _ _ slot] ← atomically (readSlots (rigFrames rig))
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      completeFence (rigStandIn rig) (syncFence slot)
      _ ← progress rig
      second ← either (fail . show) pure (durationFromNanoseconds AllowZero 1000000000)
      awaitFrames (rigFrames rig) (at 2) second `shouldReturn'` \report → progressRetired report `shouldBe` []
      filter isWait <$> frameCalls (rigStandIn rig)
        `shouldReturn` [WaitedFence (poolFence pool) (fromIntegral (durationNanoseconds drainWaitLimit)) False]
      durationNanoseconds drainWaitLimit `shouldBe` 10000000
      -- Nothing moved: the record, the hold, and the target's retirement.
      viewTargetPoolRecords <$> targetOf rig `shouldReturn` 1
      presentationsOn rig (ownedImage frame) `shouldReturn` [presentation]
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ _ _ presentations _) → presentations == [presentation]
      retireTargetGenerations (rigGenerations rig) (at 3) (rigTarget rig) `raises` \(GenerationsRetained _ retained) → not (null retained)
      retireRootTarget (rigRoots rig) (rigTarget rig) `raises` \(_ ∷ SomeException) → True
      -- Evidence that does arrive lets retirement go on.
      completeFence (rigStandIn rig) (poolFence pool)
      awaitFrames (rigFrames rig) (at 4) second `shouldReturn'` \report → progressRetired report `shouldBe` [presentation]
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      retireTargetGenerations (rigGenerations rig) (at 5) (rigTarget rig)
      clean rig

    it "waits for nothing when no fence is pending" $ do
      rig ← newRig
      awaitFrames (rigFrames rig) (at 1) drainWaitLimit `shouldReturn'` \report → progressOutstanding report `shouldBe` 0
      filter isWait <$> frameCalls (rigStandIn rig) `shouldReturn` []
      clean rig

  describe "settling what was never presented" $ do
    it "settles skipped and never-presented frames through their own cleanup, never a presentation record, and only then frees their records" $ do
      rig ← newRig
      skipped ← owned rig
      closed ← owned rig
      _ ← sealed rig closed >>= \batch → submitted rig (batch :| [])
      ok (skipFrame (rigFrames rig) (ownedFrame skipped))
      ok (closeUnpresentedFrame (rigFrames rig) (ownedFrame closed))
      holders ← map (poolHolder . viewPoolSync) <$> atomically (readPool (rigFrames rig))
      holders `shouldBe` [PoolHeldByFrame (ownedFrame skipped), PoolHeldByFrame (ownedFrame closed)]
      _ ← progress rig
      map (poolHolder . viewPoolSync) <$> atomically (readPool (rigFrames rig)) `shouldReturn` holders
      settleAll rig
      map (poolHolder . viewPoolSync) <$> atomically (readPool (rigFrames rig)) `shouldReturn` [PoolFree, PoolFree]
      filter isPresentation <$> frameCalls (rigStandIn rig) `shouldReturn` []
      atomically (readPresentations (rigFrames rig)) `shouldReturn` []
      viewTargetPoolRecords <$> targetOf rig `shouldReturn` 0
      clean rig

  describe "the presentation pool" $ do
    it "derives the default pool as the image tracking limit plus the frame slots" $ do
      budgets ← either (fail . show) pure (validateBudgets defaultBudgetRequest)
      presentationPoolCapacity budgets `shouldBe` 18

    it "answers an exhausted pool as bounded backpressure before any native call, and a retirement makes room without growing it" $ do
      -- Three images and two slots: five records.
      rig ← newRigOver 1 defaultBudgetRequest {requestedImageTracking = 3, requestedFrameSlots = 2}
      presentations ← replicateM 5 (presentOne rig)
      viewTargetPoolRecords <$> targetOf rig `shouldReturn` 5
      before ← length <$> frameCalls (rigStandIn rig)
      acquired rig `shouldReturn` AcquisitionPending (PendingBackpressure PresentationPoolBudget)
      length <$> frameCalls (rigStandIn rig) `shouldReturn` before
      -- One retirement frees one record, which the next frame reuses.
      [PoolView _ first pool] ← take 1 <$> atomically (readPool (rigFrames rig))
      completeFence (rigStandIn rig) (poolFence pool)
      progress rig `shouldReturn'` \report → progressRetired report `shouldBe` take 1 presentations
      creations ← length . filter ((== "semaphore") . kind) <$> frameCalls (rigStandIn rig)
      frame ← owned rig
      length . filter ((== "semaphore") . kind) <$> frameCalls (rigStandIn rig) `shouldReturn` creations
      holders ← atomically (readPool (rigFrames rig))
      [viewPoolNumber view | view ← holders, poolHolder (viewPoolSync view) == PoolHeldByFrame (ownedFrame frame)] `shouldBe` [first]
      length holders `shouldBe` 5
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      clean rig

    it "counts a retired generation's pending records against the same capacity as the new generation's" $ do
      rig ← newRigOver 1 defaultBudgetRequest {requestedImageTracking = 3, requestedFrameSlots = 2}
      old ← activeGeneration rig
      _ ← replicateM 4 (presentOne rig)
      resize rig 100 800 600
      new ← activeGeneration rig
      new `shouldNotBe` old
      -- The old generation's four pending records leave room for one.
      frame ← owned rig
      acquired rig `shouldReturn` AcquisitionPending (PendingBackpressure PresentationPoolBudget)
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      clean rig

  describe "retirement" $ do
    it "destroys a resized target's old generation only once its presentation's present fence was observed" $ do
      rig ← newRig
      old ← activeGeneration rig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      presentation ← presentedAs rig frame PresentationEnqueued
      [SlotView _ _ slot] ← atomically (readSlots (rigFrames rig))
      [PoolView _ _ pool] ← atomically (readPool (rigFrames rig))
      completeFence (rigStandIn rig) (syncFence slot)
      _ ← progress rig
      resize rig 100 800 600
      activeGeneration rig `shouldReturn'` (`shouldNotBe` old)
      fmap viewPresentations <$> holdOf rig (GenerationSubject old) `shouldReturn` Just [presentation]
      forM_ [140, 160 ∷ Integer] $ \instant → stepAll rig instant (SurfaceExtent 800 600)
      destroyedSwapchains rig `shouldReturn` []
      completeFence (rigStandIn rig) (poolFence pool)
      progress rig `shouldReturn'` \report → progressRetired report `shouldBe` [presentation]
      stepAll rig 180 (SurfaceExtent 800 600)
      length <$> destroyedSwapchains rig `shouldReturn` 1
      holdOf rig (GenerationSubject old) `shouldReturn` Nothing
      clean rig

    it "retires generations incrementally, a bounded number a step, round-robin across targets" $ do
      rig ← newRigOver 2 defaultBudgetRequest {requestedProgressActions = 1}
      let targets = rigTargets rig
      olds ← mapM (activeGenerationOn rig) targets
      presentations ← forM targets $ \target → do
        frame ← ownedOn rig target
        _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
        presentedAs rig frame PresentationEnqueued
      resizeSurfaces rig 800 600
      _ ← stepGenerationsAll rig 100 (SurfaceExtent 800 600)
      _ ← stepGenerationsAll rig 116 (SurfaceExtent 800 600)
      mapM (activeGenerationOn rig) targets `shouldReturn'` \news → news `shouldNotBe` olds
      completeAll (rigStandIn rig)
      -- One action a step: the presentations retire one at a time, in turn.
      retired ← concat <$> forM [1 .. 6 ∷ Int] (\_ → progressRetired <$> progress rig)
      sort retired `shouldBe` sort presentations
      -- And the generations are destroyed one a step, one of each target's.
      first ← stepGenerationsAll rig 200 (SurfaceExtent 800 600)
      second ← stepGenerationsAll rig 201 (SurfaceExtent 800 600)
      map length [summaryDestroyed first, summaryDestroyed second] `shouldBe` [1, 1]
      sort (map generationTarget (summaryDestroyed first <> summaryDestroyed second)) `shouldBe` sort targets
      clean rig

    it "closes the first target from verified fences, leaving the shared roots valid for the second, which keeps presenting" $ do
      rig ← newRigOver 2 defaultBudgetRequest
      let (first, second) = case rigTargets rig of
            [one, two] → (one, two)
            _ → error "two targets"
      closing ← ownedOn rig first
      _ ← sealed rig closing >>= \batch → submitted rig (batch :| [])
      presentation ← presentedAs rig closing PresentationEnqueued
      unpresented ← ownedOn rig first
      _ ← closeTargetFrames (rigFrames rig) first
      standingOf rig (ownedFrame unpresented) `shouldReturn` Just StageSkipping
      -- Its retirement is withheld while its evidence is outstanding.
      retireTargetFrames (rigFrames rig) first `raises` \(FramesRetained _ _ _ presentations _) → presentations == [presentation]
      retireTargetGenerations (rigGenerations rig) (at 10) first `raises` \(GenerationsRetained _ _) → True
      -- The second target keeps rendering and presenting meanwhile.
      other ← ownedOn rig second
      _ ← sealed rig other >>= \batch → submitted rig (batch :| [])
      _ ← presentedAs rig other PresentationEnqueued
      settleAll rig
      retireTargetFrames (rigFrames rig) first
      retireTargetGenerations (rigGenerations rig) (at 11) first
      retireRootTarget (rigRoots rig) first
      roots ← Roots.calls (rigRootsStandIn rig)
      [surface | Roots.DestroyedSurface surface ← roots] `shouldBe` [10]
      [() | Roots.DestroyedDevice ← roots] `shouldBe` []
      -- The shared device serves the second target as before.
      again ← ownedOn rig second
      _ ← sealed rig again >>= \batch → submitted rig (batch :| [])
      _ ← presentedAs rig again PresentationEnqueued
      -- The session retires with every fence observed.
      settleAll rig
      pendingFences (rigStandIn rig) `shouldReturn` []
      atomically (readPresentations (rigFrames rig)) `shouldReturn` []
      retireTargetFrames (rigFrames rig) second
      retireTargetGenerations (rigGenerations rig) (at 12) second
      retireRootTarget (rigRoots rig) second
      _ ← retireRoots (rigRoots rig)
      length . filter (== Roots.DestroyedDevice) <$> Roots.calls (rigRootsStandIn rig) `shouldReturn` 1
      clean rig

-- ---------------------------------------------------------------------------
-- Helpers

-- | Present the frame, requiring the presentation engine to have answered
-- this.
presentedAs ∷ Rig → OwnedFrame → PresentOutcome → IO PresentationId
presentedAs rig frame expected =
  presentFrame (rigFrames rig) (ownedFrame frame) >>= \case
    Right (PresentedAs presentation outcome) | outcome == expected → pure presentation
    other → fail ("the presentation answered " <> show other)

-- | Acquire, submit and present one frame of the first target, completing its
-- rendering but not its presentation.
presentOne ∷ Rig → IO PresentationId
presentOne rig = do
  frame ← owned rig
  submission ← sealed rig frame >>= \batch → submitted rig (batch :| [])
  slots ← atomically (readSlots (rigFrames rig))
  forM_ [sync | SlotView target number sync ← slots, target == rigTarget rig, number == frameSlotNumber (ownedFrame frame)] $ \sync →
    completeFence (rigStandIn rig) (syncFence sync)
  progress rig `shouldReturn'` \report → progressCompleted report `shouldBe` [submission]
  presentedAs rig frame PresentationEnqueued

holdOf ∷ Rig → HoldSubject → IO (Maybe HoldView)
holdOf rig subject = holdView subject <$> modelOf rig

-- | The presentations still holding this image's generation.
presentationsOn ∷ Rig → ImageId → IO [PresentationId]
presentationsOn rig image = maybe [] viewPresentations <$> holdOf rig (GenerationSubject (imageGeneration image))

presentationImageOf ∷ Rig → PresentationId → IO (Maybe ImageId)
presentationImageOf rig presentation = presentationImage presentation <$> modelOf rig

failRootsSessionOf ∷ Rig → STM ()
failRootsSessionOf rig = failRootsSession (rigRoots rig) CleanupFailed

onOtherThread ∷ IO a → IO a
onOtherThread action = do
  done ← newEmptyMVar
  _ ← forkIO (action >>= putMVar done)
  takeMVar done

-- | Every surface reports this extent now; every target publishes it at this
-- instant and again once it has settled, 16 ms later.
resize ∷ Rig → Integer → Word32 → Word32 → IO ()
resize rig instant width height = do
  resizeSurfaces rig width height
  stepAll rig instant (SurfaceExtent width height)
  stepAll rig (instant + 16) (SurfaceExtent width height)

resizeSurfaces ∷ Rig → Word32 → Word32 → IO ()
resizeSurfaces rig width height =
  Roots.offerSurface (rigRootsStandIn rig) $ \offer →
    offer {offerCapabilities = (offerCapabilities offer) {capabilityCurrentExtent = Just (SurfaceExtent width height)}}

stepAll ∷ Rig → Integer → SurfaceExtent → IO ()
stepAll rig instant extent = void (stepGenerationsAll rig instant extent)

stepGenerationsAll ∷ Rig → Integer → SurfaceExtent → IO StepSummary
stepGenerationsAll rig instant extent = stepGenerations (rigGenerations rig) (at instant) (geometries (rigTargets rig) extent)

destroyedSwapchains ∷ Rig → IO [Word64]
destroyedSwapchains rig = (\calls' → [swapchain | Roots.DestroyedSwapchain swapchain ← calls']) <$> Roots.calls (rigRootsStandIn rig)
