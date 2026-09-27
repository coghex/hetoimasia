-- | Terminal graphics failure over stand-in native layers (VK-15): the latch
-- that records the first failure as the primary and refuses every later
-- rendering, acquisition, submission and presentation naming it; device loss
-- injected during acquisition, submission, presentation and idle progress,
-- each torn down under the device-loss rules with no phantom wait and no
-- simulated fence; a later loss switching an earlier failure's teardown to
-- those rules without displacing it; cleanup failures and later failures
-- joining the evidence beside the primary; an uncertain effect retaining its
-- parents through teardown; a validation error and a sink failure learned at
-- a checkpoint; and a required target's exhausted recovery failing the session
-- while an optional target's leaves another healthy target rendering.
--
-- The frames' stand-in ("Test.GPU.Vulkan.Native.FramesStandIn") holds the
-- frames to Vulkan's rules, and to the device-loss rules once a step has lost
-- the device: from then on asking or waiting on a fence, or making any queue
-- operation, is a violation, and destroying what a pending operation still
-- uses is not. Every example ends by requiring that nothing broke them. No
-- device is lost natively and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Terminal (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (toException)
import Control.Monad (forM_, void)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model
  ( DeviceLossRelease (..)
  , Escalation (..)
  , FramePhase (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , TargetPhase (..)
  , TargetView (..)
  , deviceLossObserved
  , escalations
  , sessionState
  )
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest)
import Hetoimasia.GPU.Model.Identity (PresentationId, TargetClass (..), TargetId)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( GenerationsRetained (..)
  , SwapchainResult (..)
  , TargetCondition (..)
  , TargetGenerationsView (..)
  , noteSwapchainResult
  , retireTargetGenerations
  , stepGenerations
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (Refusal (..), recordFrame)
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( DiagnosticAlarm (..)
  , GraphicsDeviceLost (..)
  , RootsRetained (..)
  , TargetGenerationsRemain (..)
  , TeardownEvidence (..)
  , TerminalCause (..)
  , TerminalReport (..)
  , readRootsTerminal
  , retireRootTarget
  , retireRoots
  , watchRootsDiagnostics
  )
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.StandIn (StandInLoss (..), Step (AtFrameCall))

spec ∷ Spec
spec = describe "Terminal failure" $ do
  describe "device loss" $ do
    it "during acquisition: the reservation goes back, rendering is refused naming the loss, and teardown waits for nothing" $ do
      rig ← newRig
      _ ← pendingPresentation rig
      frames ← viewTargetFrames <$> targetOf rig
      loseFrameStep (rigStandIn rig) AtAcquire
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `raises` \loss → lostDuring loss == "vkAcquireNextImageKHR"
      viewTargetFrames <$> targetOf rig `shouldReturn` frames
      primaryIs rig lostLoss
      refusedPrimary rig `shouldReturn'` (`shouldSatisfy` maybe False lostLoss)
      tornDownUnderLoss rig

    it "during submission: the effect is recorded uncertain, rendering is refused naming the loss, and teardown waits for nothing" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      loseFrameStep (rigStandIn rig) AtSubmit
      submitFrames (rigFrames rig) (batch :| []) `raises` \loss → lostDuring loss == "vkQueueSubmit2"
      -- The call that lost the device still owes its accounting: the model
      -- holds the frame in the uncertain-effect state, not as never submitted.
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FrameUncertainEffect
      primaryIs rig lostLoss
      evidenceOf rig `shouldReturn'` (`shouldSatisfy` any (\case LaterFailure (TerminalUncertainEffect _) → True; _ → False))
      recordFrame (rigRecording rig) (ownedFrame frame) (\_ → pure ()) `shouldReturn'` (`shouldSatisfy` sessionRefused lostLoss)
      tornDownUnderLoss rig

    it "during presentation: its unknown effect is retained until the loss releases it, and teardown waits for nothing" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaisingUnwritten (toException (StandInLoss AtFrameCall))]
      presentFrame (rigFrames rig) (ownedFrame frame) `raises` \loss → lostDuring loss == "vkQueuePresentKHR"
      primaryIs rig lostLoss
      presentFrame (rigFrames rig) (ownedFrame frame) `shouldReturn'` (`shouldSatisfy` sessionRefused lostLoss)
      tornDownUnderLoss rig

    it "during idle progress: no fence is asked or waited on again, and none is recorded as signalled" $ do
      rig ← newRig
      _ ← pendingPresentation rig
      loseFrameStep (rigStandIn rig) AtQueryFence
      progress rig `raises` \loss → lostDuring loss == "vkGetFenceStatus"
      -- A further step and a drain wait make no call at all: the stand-in
      -- would count either as a violation.
      before ← length <$> frameCalls (rigStandIn rig)
      progress rig `shouldReturn'` \report → (progressCompleted report, progressRetired report) `shouldBe` ([], [])
      void (awaitFrames (rigFrames rig) (at 2) drainWaitLimit)
      length <$> frameCalls (rigStandIn rig) `shouldReturn` before
      tornDownUnderLoss rig

  describe "the primary failure" $ do
    it "keeps an earlier validation error when a teardown wait reports the loss, and switches that teardown to the device-loss rules" $ do
      rig ← newRig
      _ ← pendingPresentation rig
      alarms ← newTVarIO []
      atomically (watchRootsDiagnostics (rigRoots rig) (readTVarIO alarms))
      atomically (writeTVar alarms [AlarmValidationError])
      refusedPrimary rig `shouldReturn` Just TerminalValidationError
      -- The ordinary rules first: the pending work retains the target.
      _ ← closeTargetFrames (rigFrames rig) (rigTarget rig)
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained {}) → True
      loseFrameStep (rigStandIn rig) AtWait
      awaitFrames (rigFrames rig) (at 2) drainWaitLimit `raises` \loss → lostDuring loss == "vkWaitForFences"
      report ← atomically (readRootsTerminal (rigRoots rig))
      reportPrimary report `shouldBe` Just TerminalValidationError
      reportDeviceLost report `shouldSatisfy` maybe False ((== "vkWaitForFences") . lostDuring)
      reportEvidence report `shouldSatisfy` any (\case LaterFailure (TerminalDeviceLost _) → True; _ → False)
      model ← modelOf rig
      sessionState model `shouldBe` SessionFailed ValidationError
      deviceLossObserved model `shouldBe` True
      tornDownUnderLoss rig

    it "survives a cleanup failure during teardown, which joins the evidence and is never retried" $ do
      rig ← newRig
      _ ← pendingPresentation rig
      loseFrameStep (rigStandIn rig) AtAcquire
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `raises` \(_ ∷ GraphicsDeviceLost) → True
      failFrameStep (rigStandIn rig) AtDestroy
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` (== FrameStepFailed AtDestroy)
      destroyed ← length . filter isDestruction <$> frameCalls (rigStandIn rig)
      primaryIs rig lostLoss
      evidenceOf rig `shouldReturn'` (`shouldSatisfy` any (\case LaterFailure (TerminalCleanupFailed _) → True; _ → False))
      -- Whatever raised is retained, and asking again destroys nothing more
      -- of it.
      clearFrameStep (rigStandIn rig) AtDestroy
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained {}) → True
      survivors ← length . filter isDestruction <$> frameCalls (rigStandIn rig)
      survivors - destroyed `shouldSatisfy` (<= 5)
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained {}) → True
      length . filter isDestruction <$> frameCalls (rigStandIn rig) `shouldReturn` survivors
      primaryIs rig lostLoss
      clean rig

    it "retains an uncertain effect's parents through the whole teardown when the device was not lost" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      failFrameStep (rigStandIn rig) AtSubmit
      submitFrames (rigFrames rig) (batch :| []) `raises` \(FrameEffectUncertain {}) → True
      primaryIs rig (\case TerminalUncertainEffect _ → True; _ → False)
      _ ← closeTargetFrames (rigFrames rig) (rigTarget rig)
      releaseFramesToDeviceLoss (rigFrames rig) `shouldReturn'` (`shouldSatisfy` either (const True) (const False))
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _ _ _) → frames == [ownedFrame frame]
      retireTargetGenerations (rigGenerations rig) (at 3) (rigTarget rig) `raises` \(GenerationsRetained _ retained) → not (null retained)
      retireRootTarget (rigRoots rig) (rigTarget rig) `raises` \(TargetGenerationsRemain {}) → True
      retireRoots (rigRoots rig) `raises` \case
        TargetsRemain targets → targets == [rigTarget rig]
        _ → False
      clean rig

  describe "diagnostic alarms at a checkpoint" $ do
    it "latches a validation error the capture reported, refusing the next rendering with no native call" $ do
      rig ← newRig
      frame ← owned rig
      alarms ← newTVarIO []
      atomically (watchRootsDiagnostics (rigRoots rig) (readTVarIO alarms))
      atomically (writeTVar alarms [AlarmValidationError])
      before ← length <$> frameCalls (rigStandIn rig)
      recordFrame (rigRecording rig) (ownedFrame frame) (\_ → pure ()) `shouldReturn'` (`shouldSatisfy` sessionRefused (== TerminalValidationError))
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `shouldReturn` Left (RefusedSessionFailed TerminalValidationError)
      length <$> frameCalls (rigStandIn rig) `shouldReturn` before
      sessionState <$> modelOf rig `shouldReturn` SessionFailed ValidationError
      -- The ordinary rules still settle what was already owned.
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      clean rig

    it "latches a sink failure as a terminal status of its own, which authorizes no release" $ do
      rig ← newRig
      _ ← pendingPresentation rig
      atomically (watchRootsDiagnostics (rigRoots rig) (pure [AlarmSinkFailed "the sink is gone"]))
      refusedPrimary rig `shouldReturn` Just (TerminalSinkFailed "the sink is gone")
      sessionState <$> modelOf rig `shouldReturn` SessionFailed DiagnosticSinkFailed
      -- It is not a loss: nothing is released, and the pending work retains
      -- the target under the ordinary rules.
      releaseFramesToDeviceLoss (rigFrames rig) `shouldReturn'` (`shouldSatisfy` either (const True) (const False))
      _ ← closeTargetFrames (rigFrames rig) (rigTarget rig)
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained {}) → True
      settleAll rig
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      clean rig

    it "keeps a loss as the primary when the sink fails after it" $ do
      rig ← newRig
      loseFrameStep (rigStandIn rig) AtAcquire
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `raises` \(_ ∷ GraphicsDeviceLost) → True
      atomically (watchRootsDiagnostics (rigRoots rig) (pure [AlarmSinkFailed "the sink is gone", AlarmValidationError]))
      refusedPrimary rig `shouldReturn'` (`shouldSatisfy` maybe False lostLoss)
      evidenceOf rig `shouldReturn` [LaterFailure (TerminalSinkFailed "the sink is gone"), LaterFailure TerminalValidationError]
      tornDownUnderLoss rig

  describe "target designation" $ do
    it "fails the session when a required target's recovery is exhausted, refusing every target" $ do
      rig ← newRigClassed [RequiredTarget, OptionalTarget] defaultBudgetRequest
      (required, healthy) ← twoTargets rig
      exhaustRecovery rig required
      -- A required target's exhaustion is the session's failure, not the
      -- target's: it is retiring with everything else.
      viewTargetPhase <$> targetViewOf rig required `shouldReturn` TargetRetiring
      primaryIs rig (== TerminalRequiredTarget (Just required))
      sessionState <$> modelOf rig `shouldReturn` SessionFailed RequiredTargetUnrecoverable
      tryAcquireFrame (rigFrames rig) healthy `shouldReturn` Left (RefusedSessionFailed (TerminalRequiredTarget (Just required)))
      clean rig

    it "leaves another healthy target rendering when an optional target's recovery is exhausted" $ do
      rig ← newRigClassed [OptionalTarget, OptionalTarget] defaultBudgetRequest
      (optional, healthy) ← twoTargets rig
      exhaustRecovery rig optional
      viewTargetPhase <$> targetViewOf rig optional `shouldReturn` TargetUnavailable
      escalations <$> modelOf rig `shouldReturn` [OptionalTargetUnavailable optional]
      sessionState <$> modelOf rig `shouldReturn` SessionRunning
      reportPrimary <$> atomically (readRootsTerminal (rigRoots rig)) `shouldReturn` Nothing
      acquiredOn rig optional `shouldReturn` AcquisitionUnavailable
      frame ← ownedOn rig healthy
      ok (skipFrame (rigFrames rig) (ownedFrame frame))
      settleAll rig
      clean rig

-- | A frame of the first target submitted and presented, with neither its
-- submission's fence nor its present fence signalled.
pendingPresentation ∷ Rig → IO PresentationId
pendingPresentation rig = do
  frame ← owned rig
  _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
  presentFrame (rigFrames rig) (ownedFrame frame) >>= \case
    Right (PresentedAs presentation _) → pure presentation
    other → fail ("the presentation answered " <> show other)

-- | Tear the first target down after the device's loss, requiring the
-- device-loss rules: every pending fence released as lost — never signalled —
-- then every slot and pool object, the generations, the surface and the device
-- destroyed, with no fence asked or waited on and no queue operation made, and
-- the loss still recorded.
tornDownUnderLoss ∷ Rig → Expectation
tornDownUnderLoss rig = do
  pendingBefore ← pendingFences (rigStandIn rig)
  _ ← closeTargetFrames (rigFrames rig) (rigTarget rig)
  released ← releaseFramesToDeviceLoss (rigFrames rig)
  released `shouldSatisfy` either (const False) (null . releaseRemaining)
  slots ← atomically (readSlots (rigFrames rig))
  pool ← atomically (readPool (rigFrames rig))
  let fences = [(syncFence sync, syncFenceState sync) | SlotView _ _ sync ← slots] <> [(poolFence sync, poolFenceState sync) | PoolView _ _ sync ← pool]
  -- What was pending on the device is lost, not signalled.
  [state | (fence, state) ← fences, fence `elem` pendingBefore] `shouldSatisfy` all (/= FenceSignalled)
  atomically (readFrameStandings (rigFrames rig)) `shouldReturn` []
  atomically (readPresentations (rigFrames rig)) `shouldReturn` []
  atomically (readOutstandingSubmissions (rigFrames rig)) `shouldReturn` []
  retireTargetFrames (rigFrames rig) (rigTarget rig)
  atomically (readSlots (rigFrames rig)) `shouldReturn` []
  atomically (readPool (rigFrames rig)) `shouldReturn` []
  -- The fences it destroyed were never completed by anyone: the stand-in,
  -- which is the device here, still holds every one of them pending.
  pendingFences (rigStandIn rig) `shouldReturn'` \now → pendingBefore `shouldSatisfy` all (`elem` now)
  forM_ pendingBefore $ \fence → frameCalls (rigStandIn rig) `shouldReturn'` (`shouldSatisfy` elem (DestroyedFence fence))
  retireTargetGenerations (rigGenerations rig) (at 10) (rigTarget rig)
  retireRootTarget (rigRoots rig) (rigTarget rig)
  forM_ (drop 1 (rigTargets rig)) $ \target → do
    retireTargetFrames (rigFrames rig) target
    retireTargetGenerations (rigGenerations rig) (at 10) target
    retireRootTarget (rigRoots rig) target
  retireRoots (rigRoots rig) `shouldReturn'` (`shouldSatisfy` (== "destroyed the device stand-in device after its loss"))
  report ← atomically (readRootsTerminal (rigRoots rig))
  reportDeviceLost report `shouldSatisfy` maybe False (const True)
  clean rig

-- | Exhaust one target's recovery: out-of-date results with unchanged
-- geometry, each a recovery attempt, until the episode is spent.
exhaustRecovery ∷ Rig → TargetId → IO ()
exhaustRecovery rig target = do
  forM_ (zip [20 ..] [SwapchainOutOfDate, SwapchainSuboptimal, SwapchainOutOfDate, SwapchainOutOfDate, SwapchainSuboptimal]) $ \(instant, result) → do
    active ← activeGenerationOn rig target
    _ ← atomically (noteSwapchainResult (rigGenerations rig) active result)
    step instant
    step instant
  -- Past every recovery delay.
  step 5000
  viewCondition <$> generationsOn rig target `shouldReturn` RecoverySpent
  where
    step instant = void (stepGenerations (rigGenerations rig) (at instant) (geometries (rigTargets rig) (SurfaceExtent 640 480)))

twoTargets ∷ Rig → IO (TargetId, TargetId)
twoTargets rig = case rigTargets rig of
  [first, second] → pure (first, second)
  other → fail ("the rig should have two targets, not " <> show other)

primaryIs ∷ Rig → (TerminalCause → Bool) → Expectation
primaryIs rig expected = atomically (readRootsTerminal (rigRoots rig)) `shouldReturn'` \report → reportPrimary report `shouldSatisfy` maybe False expected

evidenceOf ∷ Rig → IO [TeardownEvidence]
evidenceOf rig = reportEvidence <$> atomically (readRootsTerminal (rigRoots rig))

lostLoss ∷ TerminalCause → Bool
lostLoss = \case
  TerminalDeviceLost _ → True
  _ → False

sessionRefused ∷ (TerminalCause → Bool) → Either Refusal a → Bool
sessionRefused expected = \case
  Left (RefusedSessionFailed primary) → expected primary
  _ → False
