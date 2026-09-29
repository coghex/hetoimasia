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

import Control.Concurrent (forkIO, killThread, myThreadId, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, throwSTM, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), Exception, SomeException, fromException, mask, throwIO, toException, try)
import Control.Monad (forM_, join, void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Maybe (fromMaybe, isJust)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldNotReturn, shouldReturn, shouldSatisfy, shouldThrow)
import Test.Support.Bounded (bounded)

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
import Hetoimasia.GPU.Vulkan.Native.Recording (Refusal (..), recordFrame, retireRecording)
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( Checkpoint (..)
  , DiagnosticAlarm (..)
  , GraphicsDeviceLost (..)
  , RootsRetained (..)
  , TargetGenerationsRemain (..)
  , TeardownEvidence (..)
  , TerminalCause (..)
  , TerminalReport (..)
  , checkpointRoots
  , checkpointRootsSettled
  , failRootsSessionBecause
  , readRootsTerminal
  , retireRootTarget
  , retireRoots
  , watchRootsDiagnostics
  , watchRootsDiagnosticsOrdered
  , DiagnosticWatch (..)
  , DiagnosticOrder (..)
  )
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), RecordingStep (AtDestroyStorage), duringReset, failAt, recordingCalls)
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

    it "with an unsubmitted recording whose pool reset reported the loss: the release lets it go without another reset" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame
      -- The skip's reset of the frame's storage is what reports the loss.
      duringReset (rigRecordingStandIn rig) (markDeviceLost (rigStandIn rig) >> throwIO (StandInLoss AtFrameCall))
      skipFrame (rigFrames rig) (ownedFrame frame) `raises` \(_ ∷ SomeException) → True
      duringReset (rigRecordingStandIn rig) (pure ())
      primaryIs rig lostLoss
      resets ← length . filter isReset <$> recordingCalls (rigRecordingStandIn rig)
      -- The batch the reset left uncertain holds nothing back: nothing is
      -- reset against the lost device again, and the frame, its generation and
      -- the roots are released and destroyed.
      tornDownUnderLoss rig
      length . filter isReset <$> recordingCalls (rigRecordingStandIn rig) `shouldReturn` resets

    it "during a presentation the swapchain answered out of date: what was enqueued is recorded, and the loss still raised" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaising PresentStatusOutOfDate (toException (StandInLoss AtFrameCall))]
      presentFrame (rigFrames rig) (ownedFrame frame) `raises` \loss → lostDuring loss == "vkQueuePresentKHR"
      -- The presentation was enqueued, so its obligations were kept before the
      -- loss went on to the caller.
      map standingPresentedFrame <$> atomically (readPresentations (rigFrames rig)) `shouldReturn` [ownedFrame frame]
      phaseOf rig (ownedFrame frame) `shouldReturn` Just FramePresentationEnqueued
      primaryIs rig lostLoss
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
    it "stays pending while a failure of the owner's own holds first place in a transaction still running, then keeps it as the primary ahead of a later validation error" $ do
      rig ← newRig
      _ ← pendingPresentation rig
      capture ← newFakeCapture
      atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (fakeWatch capture))
      -- The owner's progress step loses the device and claims first place for
      -- the loss. Before its transaction commits, an error reaches the
      -- capture and another thread checkpoints.
      seen ← newEmptyMVar
      holdNextClaim capture $ do
        reportValidationError capture
        answered ← newEmptyMVar
        _ ← forkIO $ do
          answer ← checkpointRoots (rigRoots rig)
          latched ← reportPrimary <$> atomically (readRootsTerminal (rigRoots rig))
          putMVar answered (answer, latched)
        takeMVar answered >>= putMVar seen
      loseFrameStep (rigStandIn rig) AtQueryFence
      progress rig `raises` \loss → lostDuring loss == "vkGetFenceStatus"
      -- That checkpoint latched nothing and refused.
      takeMVar seen `shouldReturn` (CheckpointPending, Nothing)
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `shouldReturn'` (`shouldSatisfy` sessionRefused lostLoss)
      primaryIs rig lostLoss
      evidenceOf rig `shouldReturn'` (`shouldSatisfy` elem (LaterFailure TerminalValidationError))
      tornDownUnderLoss rig

    it "holds nothing back for a claim whose transaction was abandoned: a settled checkpoint answers, and a validation error that follows is latched" $ do
      rig ← newRig
      capture ← newFakeCapture
      atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (fakeWatch capture))
      abandonClaim rig
      -- Nothing has failed: the settled checkpoint answers clear rather than
      -- waiting for a record no transaction will make, and work is admitted.
      bounded (checkpointRootsSettled (rigRoots rig)) `shouldReturn` CheckpointClear
      frame ← owned rig
      -- A diagnostic failure after it is not hidden behind the void claim.
      reportValidationError capture
      checkpointRoots (rigRoots rig) `shouldReturn` CheckpointFailed TerminalValidationError
      evidenceOf rig `shouldReturn` []
      recordFrame (rigRecording rig) (ownedFrame frame) (\_ → pure ()) `shouldReturn'` (`shouldSatisfy` sessionRefused (== TerminalValidationError))
      clean rig

    it "holds nothing back for a claim abandoned by a thread that is still running" $ do
      rig ← newRig
      capture ← newFakeCapture
      atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (fakeWatch capture))
      abandoned ← newEmptyMVar
      release ← newEmptyMVar
      -- The claimant rolls its transaction back and carries on, never reaching
      -- another checkpoint of its own.
      _ ← forkIO (abandonClaim rig >> putMVar abandoned () >> takeMVar release)
      bounded (takeMVar abandoned)
      checkpointRoots (rigRoots rig) `shouldReturn` CheckpointClear
      reportValidationError capture
      checkpointRoots (rigRoots rig) `shouldReturn` CheckpointFailed TerminalValidationError
      evidenceOf rig `shouldReturn` []
      putMVar release ()
      clean rig

    it "keeps a sink failure that arrived behind an abandoned claim pending until it publishes, and orders a later failure of the owner's own behind it" $ do
      rig ← newRig
      capture ← newFakeCapture
      atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (fakeWatch capture))
      abandonClaim rig
      -- The sink fails behind the void claim and its worker has not yet
      -- published why: something has failed, so nothing is clear.
      noteSinkFailure capture
      checkpointRoots (rigRoots rig) `shouldReturn` CheckpointPending
      -- The owner's next failure waits for the reason, which is published once
      -- it has looked and found it pending.
      afterNextAlarms capture (publishSinkFailure capture "the sink is gone")
      atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "a later cleanup failed")
      primaryIs rig (== TerminalSinkFailed "the sink is gone")
      evidenceOf rig `shouldReturn` [LaterFailure (TerminalCleanupFailed "a later cleanup failed")]
      clean rig

    it "orders a failure of the owner's own behind the validation error that followed an abandoned claim" $ do
      rig ← newRig
      capture ← newFakeCapture
      atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (fakeWatch capture))
      abandonClaim rig
      reportValidationError capture
      -- No checkpoint runs between: the next failure of the owner's own finds
      -- the void claim still holding the capture's first place.
      atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "a later cleanup failed")
      primaryIs rig (== TerminalValidationError)
      evidenceOf rig `shouldReturn` [LaterFailure (TerminalCleanupFailed "a later cleanup failed")]
      clean rig

    it "records an uncertain presentation whole when a cancellation aimed at the owner arrives while a sink failure that claimed first place is unpublished" $ do
      rig ← newRig
      frame ← owned rig
      _ ← sealed rig frame >>= \batch → submitted rig (batch :| [])
      scriptPresent (rigStandIn rig) [PresentRaisingUnwritten (toException (ErrorCall "the driver failed"))]
      -- The sink's worker has claimed first place and not yet published why.
      -- The presentation's record finds that out inside its transaction, and a
      -- cancellation is then aimed at the owner and held there, waiting.
      looks ← newIORef (0 ∷ Int)
      let published = do
            look ← atomicModifyIORef' looks (\count → (count + 1, count))
            if look == 0
              then do
                owner ← myThreadId
                killer ← forkIO (killThread owner)
                awaitThrowing killer
                pure Nothing
              else pure (Just "the sink is gone")
      atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (DiagnosticWatch (pure []) (pure (SinkFirst published))))
      -- The presentation runs on the owner's thread, which the cancellation is
      -- aimed at; one still pending when it returns is delivered, and caught,
      -- just after.
      (presented, after) ← mask $ \restore → do
        presented ← try @SomeException (restore (presentFrame (rigFrames rig) (ownedFrame frame)))
        after ← try @SomeException (restore (pure ()))
        pure (presented, after)
      [failure | Left failure ← [void presented, after]] `shouldSatisfy` \case
        [cancellation] → fromException cancellation == Just ThreadKilled
        [effect, cancellation] → isJust (fromException @FrameEffectUncertain effect) && fromException cancellation == Just ThreadKilled
        _ → False
      -- The record is whole: the frame and its synchronization are uncertain,
      -- admission is closed, the sink failure is the primary and the owner's
      -- uncertain effect is kept beside it.
      standingOf rig (ownedFrame frame) `shouldReturn'` (`shouldSatisfy` maybe False uncertainStage)
      [PoolView _ number pool] ← atomically (readPool (rigFrames rig))
      poolFenceState pool `shouldSatisfy` \case
        FenceUncertain _ → True
        _ → False
      poolRenderedState pool `shouldSatisfy` \case
        SemaphoreUncertain _ → True
        _ → False
      primaryIs rig (== TerminalSinkFailed "the sink is gone")
      evidenceOf rig `shouldReturn'` (`shouldSatisfy` any (\case LaterFailure (TerminalUncertainEffect _) → True; _ → False))
      refusedPrimary rig `shouldReturn` Just (TerminalSinkFailed "the sink is gone")
      settleAll rig
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames' _ _ pools) → frames' == [ownedFrame frame] && pools == [number]
      clean rig

    it "keeps a validation error reported during a call as the primary when that call then returns the device's loss" $ do
      rig ← newRig
      atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (DiagnosticWatch (pure []) (pure ValidationFirst)))
      loseFrameStep (rigStandIn rig) AtAcquire
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `raises` \(_ ∷ GraphicsDeviceLost) → True
      report ← atomically (readRootsTerminal (rigRoots rig))
      reportPrimary report `shouldBe` Just TerminalValidationError
      reportDeviceLost report `shouldSatisfy` isJust
      reportEvidence report `shouldSatisfy` any (\case LaterFailure (TerminalDeviceLost _) → True; _ → False)
      deviceLossObserved <$> modelOf rig `shouldReturn` True
      tornDownUnderLoss rig

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

    it "names each cleanup that failed in one disposal pass, beside the primary" $ do
      rig ← newRig
      loseFrameStep (rigStandIn rig) AtAcquire
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `raises` \(_ ∷ GraphicsDeviceLost) → True
      -- Both slots' storages go in one pass, and both destructions fail.
      failAt (rigRecordingStandIn rig) AtDestroyStorage
      retireRecording (rigRecording rig) (at 5) `raises` \(_ ∷ SomeException) → True
      primaryIs rig lostLoss
      cleanups ← (\evidence → [reason | LaterFailure (TerminalCleanupFailed reason) ← evidence]) <$> evidenceOf rig
      length cleanups `shouldBe` 2
      length (nub cleanups) `shouldBe` 2

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

    it "keeps a validation error reported inside a submission whose effect is then unknown as the primary" $ do
      rig ← newRig
      frame ← owned rig
      batch ← sealed rig frame
      -- The submission's own checkpoint reads nothing; the error is reported
      -- from inside the call, which then raises with an effect the frames
      -- cannot know.
      looks ← newIORef (0 ∷ Int)
      atomically $
        watchRootsDiagnosticsOrdered (rigRoots rig) $
          DiagnosticWatch
            ( do
                seen ← atomicModifyIORef' looks (\count → (count + 1, count))
                pure [AlarmValidationError | seen > 0]
            )
            (pure ValidationFirst)
      failFrameStep (rigStandIn rig) AtSubmit
      submitFrames (rigFrames rig) (batch :| []) `raises` \(FrameEffectUncertain {}) → True
      primaryIs rig (== TerminalValidationError)
      evidenceOf rig `shouldReturn'` (`shouldSatisfy` \case [LaterFailure (TerminalUncertainEffect _)] → True; _ → False)
      _ ← closeTargetFrames (rigFrames rig) (rigTarget rig)
      retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` \(FramesRetained _ frames _ _ _) → frames == [ownedFrame frame]

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

    it "refuses new work while a diagnostic failure is pending, latching nothing until a checkpoint can latch it in order" $ do
      rig ← newRig
      frame ← owned rig
      alarms ← newTVarIO [AlarmPending]
      atomically (watchRootsDiagnostics (rigRoots rig) (readTVarIO alarms))
      before ← length <$> frameCalls (rigStandIn rig)
      recordFrame (rigRecording rig) (ownedFrame frame) (\_ → pure ()) `shouldReturn'` (`shouldBe` Left RefusedDiagnosticPending)
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `shouldReturn` Left RefusedDiagnosticPending
      length <$> frameCalls (rigStandIn rig) `shouldReturn` before
      -- Nothing latched, and the model's session is still running.
      reportPrimary <$> atomically (readRootsTerminal (rigRoots rig)) `shouldReturn` Nothing
      sessionState <$> modelOf rig `shouldReturn` SessionRunning
      -- Once the capture can say, the failure that came first is the primary.
      atomically (writeTVar alarms [AlarmSinkFailed "the sink is gone", AlarmValidationError])
      tryAcquireFrame (rigFrames rig) (rigTarget rig) `shouldReturn` Left (RefusedSessionFailed (TerminalSinkFailed "the sink is gone"))
      evidenceOf rig `shouldReturn` [LaterFailure TerminalValidationError]
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

    it "keeps a validation error the capture held before the step that would exhaust a required target as the primary, and recovers no further" $ do
      rig ← newRigClassed [RequiredTarget, OptionalTarget] defaultBudgetRequest
      (required, healthy) ← twoTargets rig
      -- The error reaches the capture, and no checkpoint reads it, before the
      -- step that exhausts the required target.
      exhaustRecoveryAfter rig required $
        atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (DiagnosticWatch (pure [AlarmValidationError]) (pure ValidationFirst)))
      -- The error was latched before the attempt that would have spent the
      -- episode, so the session had failed and recovery went no further.
      primaryIs rig (== TerminalValidationError)
      evidenceOf rig `shouldReturn` []
      sessionState <$> modelOf rig `shouldReturn` SessionFailed ValidationError
      viewCondition <$> generationsOn rig required `shouldNotReturn` RecoverySpent
      tryAcquireFrame (rigFrames rig) healthy `shouldReturn` Left (RefusedSessionFailed TerminalValidationError)
      clean rig

    it "waits for a sink failure that claimed the order however long its reason takes to publish, before a required target's recovery can be exhausted" $ do
      rig ← newRigClassed [RequiredTarget, OptionalTarget] defaultBudgetRequest
      (required, _) ← twoTargets rig
      -- The sink claimed first place, and its worker is delayed before it
      -- publishes why; no checkpoint could have read it.
      published ← newTVarIO Nothing
      _ ← forkIO $ do
        threadDelay 50000
        atomically (writeTVar published (Just "the sink is gone"))
      exhaustRecoveryAfter rig required $
        atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (DiagnosticWatch (pure []) (pure (SinkFirst (readTVarIO published)))))
      primaryIs rig (== TerminalSinkFailed "the sink is gone")
      evidenceOf rig `shouldReturn` []
      viewCondition <$> generationsOn rig required `shouldNotReturn` RecoverySpent
      clean rig

    it "orders a validation error that claimed first place ahead of the exhaustion it preceded, though no checkpoint could read it yet" $ do
      rig ← newRigClassed [RequiredTarget, OptionalTarget] defaultBudgetRequest
      (required, _) ← twoTargets rig
      -- Only the capture's order knows of the error: the transition that
      -- would exhaust the target is taken on the session it failed.
      exhaustRecoveryAfter rig required $
        atomically (watchRootsDiagnosticsOrdered (rigRoots rig) (DiagnosticWatch (pure []) (pure ValidationFirst)))
      primaryIs rig (== TerminalValidationError)
      evidenceOf rig `shouldReturn` []
      sessionState <$> modelOf rig `shouldReturn` SessionFailed ValidationError
      viewCondition <$> generationsOn rig required `shouldNotReturn` RecoverySpent
      clean rig

    it "keeps a required target's exhausted recovery as the primary when a validation error follows it" $ do
      rig ← newRigClassed [RequiredTarget, OptionalTarget] defaultBudgetRequest
      (required, healthy) ← twoTargets rig
      alarms ← newTVarIO []
      atomically (watchRootsDiagnostics (rigRoots rig) (readTVarIO alarms))
      exhaustRecovery rig required
      atomically (writeTVar alarms [AlarmValidationError])
      tryAcquireFrame (rigFrames rig) healthy `shouldReturn` Left (RefusedSessionFailed (TerminalRequiredTarget (Just required)))
      evidenceOf rig `shouldReturn` [LaterFailure TerminalValidationError]
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
  exhaustRecoveryAfter rig target (pure ())
  viewCondition <$> generationsOn rig target `shouldReturn` RecoverySpent

-- | Exhaust a target's recovery, running an action just before the step that
-- spends its episode: the step after the fourth result, whose attempt is the
-- episode's last.
exhaustRecoveryAfter ∷ Rig → TargetId → IO () → IO ()
exhaustRecoveryAfter rig target beforeSpending = do
  forM_ (zip3 [0 ∷ Int ..] [20 ..] [SwapchainOutOfDate, SwapchainSuboptimal, SwapchainOutOfDate, SwapchainOutOfDate, SwapchainSuboptimal]) $ \(index, instant, result) → do
    active ← activeGenerationOn rig target
    _ ← atomically (noteSwapchainResult (rigGenerations rig) active result)
    when (index == 3) $ do
      sessionState <$> modelOf rig `shouldReturn` SessionRunning
      beforeSpending
    step instant
    step instant
  -- Past every recovery delay.
  step 5000
  where
    step instant = void (stepGenerations (rigGenerations rig) (at instant) (geometries (rigTargets rig) (SurfaceExtent 640 480)))

twoTargets ∷ Rig → IO (TargetId, TargetId)
twoTargets rig = case rigTargets rig of
  [first, second] → pure (first, second)
  other → fail ("the rig should have two targets, not " <> show other)

-- | A diagnostic capture's order and alarms kept as the real capture keeps
-- them: one first place that whichever failure claims it first holds for good
-- — an error-severity report, the sink, or the owner — beside the error latch,
-- the sink's published reason, and which diagnostic failures have arrived,
-- each recorded before it tries to claim; answered as 'captureAlarms' answers
-- them. The owner's next claim, and the next reading of the alarms, can each
-- run an action once.
data FakeCapture = FakeCapture
  { fakeFirst ∷ IORef (Maybe FakeFirst)
  , fakeErrorArrived ∷ IORef Bool
  , fakeErrorLatched ∷ IORef Bool
  , fakeSinkArrived ∷ IORef Bool
  , fakeSinkReason ∷ IORef (Maybe Text)
  , fakeAfterClaim ∷ IORef (IO ())
  , fakeAfterAlarms ∷ IORef (IO ())
  }

data FakeFirst = FakeOwner | FakeError | FakeSink
  deriving (Eq, Show)

newFakeCapture ∷ IO FakeCapture
newFakeCapture =
  FakeCapture
    <$> newIORef Nothing
    <*> newIORef False
    <*> newIORef False
    <*> newIORef False
    <*> newIORef Nothing
    <*> newIORef (pure ())
    <*> newIORef (pure ())

-- | The watch the controller would install over the capture. Neither half runs
-- a transaction, since the roots read both inside theirs.
fakeWatch ∷ FakeCapture → DiagnosticWatch
fakeWatch capture = DiagnosticWatch alarms order
  where
    alarms = do
      latched ← readIORef (fakeErrorLatched capture)
      sink ← readIORef (fakeSinkReason capture)
      first ← readIORef (fakeFirst capture)
      errorArrived ← readIORef (fakeErrorArrived capture)
      sinkArrived ← readIORef (fakeSinkArrived capture)
      let errors = [AlarmValidationError | latched]
          sinks = [AlarmSinkFailed reason | Just reason ← [sink]]
          unpublished = (errorArrived && null errors) || (sinkArrived && null sinks)
          answer = case first of
            Just FakeSink
              | null sinks → [AlarmPending]
              | otherwise → sinks <> errors
            Just FakeError
              | null errors → [AlarmPending]
            Just FakeOwner → AlarmOwnerClaimed : [AlarmPending | unpublished] <> errors <> sinks
            _ → errors <> sinks
      once (fakeAfterAlarms capture)
      pure answer
    order = do
      first ← atomicModifyIORef' (fakeFirst capture) (\held → let first = fromMaybe FakeOwner held in (Just first, first))
      once (fakeAfterClaim capture)
      pure $ case first of
        FakeError → ValidationFirst
        FakeSink → SinkFirst (readIORef (fakeSinkReason capture))
        FakeOwner → OwnerFirst
    once hook = join (atomicModifyIORef' hook (\after → (pure (), after)))

-- | Run this once, inside the transaction of the owner's next claim, right
-- after it claims.
holdNextClaim ∷ FakeCapture → IO () → IO ()
holdNextClaim capture = writeIORef (fakeAfterClaim capture)

-- | Run this once, right after the next reading of the alarms has been answered.
afterNextAlarms ∷ FakeCapture → IO () → IO ()
afterNextAlarms capture = writeIORef (fakeAfterAlarms capture)

-- | An error-severity report: its arrival is recorded, then it claims first
-- place if nothing holds it, then sets the error latch.
reportValidationError ∷ FakeCapture → IO ()
reportValidationError capture = do
  writeIORef (fakeErrorArrived capture) True
  atomicModifyIORef' (fakeFirst capture) (\held → (Just (fromMaybe FakeError held), ()))
  writeIORef (fakeErrorLatched capture) True

-- | The sink's worker meeting its failure: its arrival is recorded and it
-- claims first place if nothing holds it; publishing why comes after.
noteSinkFailure ∷ FakeCapture → IO ()
noteSinkFailure capture = do
  writeIORef (fakeSinkArrived capture) True
  atomicModifyIORef' (fakeFirst capture) (\held → (Just (fromMaybe FakeSink held), ()))

publishSinkFailure ∷ FakeCapture → Text → IO ()
publishSinkFailure capture = writeIORef (fakeSinkReason capture) . Just

data Abandoned = Abandoned
  deriving (Eq, Show)

instance Exception Abandoned

-- | A transaction of the owner's that claims the capture's first place for a
-- failure of its own and is then abandoned: nothing it did is recorded, and
-- the claim outlives it.
abandonClaim ∷ Rig → IO ()
abandonClaim rig = do
  atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "never recorded" >> throwSTM Abandoned) `shouldThrow` (== Abandoned)
  reportPrimary <$> atomically (readRootsTerminal (rigRoots rig)) `shouldReturn` Nothing
  sessionState <$> modelOf rig `shouldReturn` SessionRunning

primaryIs ∷ Rig → (TerminalCause → Bool) → Expectation
primaryIs rig expected = atomically (readRootsTerminal (rigRoots rig)) `shouldReturn'` \report → reportPrimary report `shouldSatisfy` maybe False expected

evidenceOf ∷ Rig → IO [TeardownEvidence]
evidenceOf rig = reportEvidence <$> atomically (readRootsTerminal (rigRoots rig))

isReset ∷ RecordingCall → Bool
isReset = \case
  ResetStorage _ → True
  _ → False

lostLoss ∷ TerminalCause → Bool
lostLoss = \case
  TerminalDeviceLost _ → True
  _ → False

sessionRefused ∷ (TerminalCause → Bool) → Either Refusal a → Bool
sessionRefused expected = \case
  Left (RefusedSessionFailed primary) → expected primary
  _ → False
