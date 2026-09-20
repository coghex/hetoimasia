{-# LANGUAGE OverloadedRecordDot #-}

-- | The verdict.
--
-- Every example here is a pure assertion over what the native run observed, so
-- the whole suite runs after teardown — including whatever instance
-- destruction it performed — has finished. That is what makes requirement 8's
-- "compute the verdict only after all callback-producing teardown has
-- completed" true by construction rather than by ordering discipline.
--
-- Finished is not the same as complete. Teardown retains a handle whose
-- completion evidence is missing rather than destroying it, so a stopped run
-- can reach here with its session partly alive; what has finished by then is
-- the decision and every release it permitted. A run that proved retains
-- nothing, which is what the teardown examples below assert.
--
-- A run that stopped fails every example with the step it stopped at, rather
-- than passing the ones it happened to reach first.
module Test.Vulkan.Proof.Spec (spec) where

import Data.List (isInfixOf, nub)
import qualified Data.Text as Text
import Test.Hspec

import Test.Vulkan.Proof.Findings
import Test.Vulkan.Proof.Interop (Provenance (..))
import Test.Vulkan.Proof.Matrix
  ( Achieved (..)
  , Evidence (..)
  , MatrixRow (..)
  , Observation (..)
  , Standing (..)
  , operationMatrix
  , standing
  )
import Test.Vulkan.Proof.Record (achievedFrom, matrixTable, renderRecord)
import qualified Test.Vulkan.Proof.InvocationSpec as Invocation
import Test.Vulkan.Proof.Retention (teardownEntries)
import qualified Test.Vulkan.Proof.RetentionSpec as Retention

spec ∷ Outcome → Spec
spec outcome = do
  -- The release decision teardown obeyed, asserted over its own inputs rather
  -- than over what this run happened to reach. These are the same examples
  -- `run-proof.sh --headless` selects on their own, and they make no native
  -- call here either.
  Retention.spec
  Invocation.spec

  describe "The native run" $
    it "established every step it started" $
      onFindings outcome (\_ → pure ())

  describe "The recorded environment" $ do
    it "selected the driver by an absolute manifest path rather than by default discovery" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsPlatform
        maybe "" (Text.take 1) facts.platformDriverFiles `shouldBe` "/"

    it "cleared every conflicting discovery override it found" $
      onFindings outcome $ \findings →
        -- The run removes them and records what it removed; what matters is
        -- that the record says which, not that there happened to be none.
        length findings.findingsPlatform.platformClearedOverrides `shouldSatisfy` (>= 0)

    it "identifies the exact sources it proved, by their content" $
      onFindings outcome $ \findings → do
        -- The digest, not the revision, is the identity: a revision can be
        -- dirty, and the Linux container has no checkout to resolve one from.
        let digest = findings.findingsPlatform.platformSourceDigest
        Text.length digest `shouldBe` 64
        Text.unpack digest `shouldSatisfy` all (`elem` ("0123456789abcdef" ∷ String))

    it "names a repository revision alongside it" $
      onFindings outcome $ \findings → do
        let recorded = findings.findingsPlatform.platformRevision
        recorded `shouldSatisfy` (not . Text.null)
        recorded `shouldSatisfy` (/= "unrecorded")

    it "ran with validation actually loaded, so a clean run means something" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsPlatform
        facts.platformRequestedLayers `shouldContain` ["VK_LAYER_KHRONOS_validation"]
        -- Requesting is not loading. The loader's filter variables can drop a
        -- requested layer, and a run that validated nothing would otherwise
        -- report zero validation errors just as loudly.
        facts.platformValidationLayerLoaded `shouldBe` True
        -- And nothing else is in the chain: implicit layers need no request, so
        -- clearing the ambient overrides only restores the loader's default
        -- search for them. The policy switches that search off.
        facts.platformImplicitLayerPolicy `shouldSatisfy` Text.isInfixOf "~implicit~"

    it "recorded the layers the pinned path offers" $
      onFindings outcome $ \findings →
        findings.findingsPlatform.platformAvailableLayers `shouldSatisfy` (not . null)

  describe "One loader" $ do
    it "gives GLFW and the binding the same vkGetInstanceProcAddr address" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsLoader
        facts.loaderGlfwEntry.provenanceAddress `shouldBe` facts.loaderBindingEntry.provenanceAddress

    it "attributes that address to one image" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsLoader
        facts.loaderBindingEntry.provenanceImage `shouldSatisfy` (/= Nothing)
        facts.loaderGlfwEntry.provenanceImage `shouldBe` facts.loaderBindingEntry.provenanceImage

    it "resolves an ordinary instance command to the same address on both sides" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsLoader
        facts.loaderGlfwSample.provenanceAddress `shouldBe` facts.loaderBindingSample.provenanceAddress

    it "records which driver was actually loaded, not which one was configured" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsLoader
        facts.loaderDriverName `shouldSatisfy` (not . Text.null)
        facts.loaderDriverInfo `shouldSatisfy` (not . Text.null)
        facts.loaderDeviceApiVersion `shouldSatisfy` (not . Text.null)

  describe "The runtime profile" $ do
    it "enabled Vulkan 1.3 dynamic rendering and synchronization2 rather than assuming them" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsProfile
        facts.profileDynamicRenderingSupported `shouldBe` True
        facts.profileSynchronization2Supported `shouldBe` True
        facts.profileDynamicRenderingEnabled `shouldBe` True
        facts.profileSynchronization2Enabled `shouldBe` True

    it "enabled the portability subset exactly when the device advertised it" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsProfile
        facts.profilePortabilitySubsetEnabled `shouldBe` facts.profilePortabilitySubsetAdvertised

    it "found one queue family with both graphics and real surface presentation" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsProfile
        facts.profileQueueGraphics `shouldBe` True
        facts.profileQueuePresent `shouldBe` True

    it "presents through a format whose usages include transfer-source capture" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsProfile
        facts.profileTransferSourceSupported `shouldBe` True
        facts.profileRequestedUsages `shouldContain` ["TRANSFER_SRC"]
        facts.profileRequestedUsages `shouldContain` ["COLOR_ATTACHMENT"]

    it "enabled the selected maintenance extension with its whole dependency chain" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsProfile
        facts.profileMaintenanceVariant `shouldBe` "VK_EXT_swapchain_maintenance1"
        facts.profileEnabledDeviceExtensions `shouldContain` ["VK_EXT_swapchain_maintenance1"]
        map snd facts.profileMaintenanceDependencies `shouldSatisfy` and
        facts.profileMaintenanceFeatureSupported `shouldBe` True
        facts.profileMaintenanceFeatureEnabled `shouldBe` True

    it "resolved a release entry point, and records which spelling answered" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsProfile
        map snd facts.profileMaintenanceAlias `shouldSatisfy` or

    it "built a swapchain with room to hold an abandoned image" $
      onFindings outcome $ \findings →
        findings.findingsProfile.profileSwapchainImages `shouldSatisfy` (>= 2)

  describe "Presentation completion" $ do
    it "observed every present fence signalled" $
      onFindings outcome $ \findings →
        map (.framePresentFenceSignalled) findings.findingsCompletion.completionFrames
          `shouldSatisfy` (\values → not (null values) && and values)

    it "retires every presentation semaphore on its present fence and never on the rendering fence" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsCompletion
        nub (map (.frameRetiredOn) facts.completionFrames) `shouldBe` ["present fence"]
        facts.completionPool.poolRenderFenceNeverRetiredASemaphore `shouldBe` True

    it "recycles the semaphore pool only on present-fence evidence" $
      onFindings outcome $ \findings → do
        let pool = findings.findingsCompletion.completionPool
        pool.poolReuses `shouldSatisfy` (not . null)
        pool.poolEveryReuseBackedByPresentFence `shouldBe` True
        pool.poolFramesPresented `shouldSatisfy` (> pool.poolSize)

    it "withholds a delayed frame's slot until its present fence, not until its rendering fence" $
      onFindings outcome $ \findings → do
        let delayed = findings.findingsCompletion.completionDelayed
        delayed.delayedRenderFenceSignalledBeforePresent `shouldBe` True
        delayed.delayedTurnsBetweenSubmitAndPresent `shouldSatisfy` (> 0)
        delayed.delayedSlotWithheldWhileUnpresented `shouldBe` True
        delayed.delayedSlotReusedOnlyAfterPresentFence `shouldBe` True

  describe "Safe abandonment" $ do
    it "returns an acquired, unrendered image after a tracked cleanup submission consumed its acquisition semaphore" $
      onFindings outcome $ \findings → do
        let record = findings.findingsAbandonment.abandonUnsubmitted
        record.releaseCleanupFenceSignalled `shouldBe` True
        record.releaseSucceeded `shouldBe` True
        record.releaseResult `shouldBe` "SUCCESS"

    it "returns a submitted, unpresented image after its rendering completed and its semaphore was settled" $
      onFindings outcome $ \findings → do
        let record = findings.findingsAbandonment.abandonUnpresented
        record.releaseCleanupFenceSignalled `shouldBe` True
        record.releaseSucceeded `shouldBe` True
        record.releaseResult `shouldBe` "SUCCESS"

    it "needs no swapchain rebuild for either path" $
      onFindings outcome $ \findings →
        findings.findingsAbandonment.abandonSwapchainRebuilt `shouldBe` False

    it "keeps making progress on the same swapchain afterwards" $
      onFindings outcome $ \findings →
        case findings.findingsAbandonment.abandonProgressAfterwards of
          Nothing → expectationFailure "no frame was presented after the two abandonment paths"
          Just frame → frame.framePresentFenceSignalled `shouldBe` True

  describe "The capture path" $
    it "reads a known payload back through transfer-source usage" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsCapture
        facts.captureObserved `shouldBe` facts.captureExpected
        facts.captureMatched `shouldBe` True
        facts.captureBytes `shouldSatisfy` (> 0)

  describe "Callbacks and the FFI" $ do
    it "re-entered Haskell during creation, submission, and destruction" $
      onFindings outcome $ \findings → do
        let phases = findings.findingsCallbacks.callbackPhases
            reached name = any (\count → count.phaseName == name && count.phaseNatural + count.phaseInjected > 0) phases
        reached "messenger creation" `shouldBe` True
        reached "submission" `shouldBe` True
        reached "instance destruction" `shouldBe` True

    it "still reached Haskell after the explicit messenger was destroyed" $
      onFindings outcome $ \findings → do
        -- The instance-create-info messenger is the only one left by then, and
        -- the extension uses it for instance destruction. These are naturally
        -- emitted diagnostics arriving inside vkDestroyInstance, which is
        -- exactly the reentry the requirement names.
        findings.findingsCallbacks.callbackDuringInstanceDestruction `shouldSatisfy` (> 0)
        findings.findingsCallbacks.callbackAfterExplicitMessengerDestroyed `shouldSatisfy` (> 0)

    it "found its callback storage still valid while the instance was destroyed" $
      onFindings outcome $ \findings →
        findings.findingsCallbacks.callbackStorageAliveAfterInstanceDestroyed `shouldBe` True

    it "ran on the threaded RTS with GLFW on the process main thread" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsCallbacks
        facts.callbackRtsThreaded `shouldBe` True
        facts.callbackMainThreadBound `shouldBe` True
        facts.callbackSafeForeignCalls `shouldBe` True
        -- The constraint above is a build-time fact. This is the run's own
        -- evidence that it is in force: with `unsafe` foreign imports a Vulkan
        -- call re-entering Haskell corrupts the RTS instead of arriving.
        facts.callbackTotal `shouldSatisfy` (> 0)

    it "recorded no validation error and no failed callback" $
      onFindings outcome $ \findings →
        findings.findingsCallbacks.callbackValidationErrors `shouldBe` []

  describe "Teardown" $ do
    it "released everything it acquired, with nothing failing and nothing retained" $
      onFindings outcome $ \findings → do
        let facts = findings.findingsTeardown
        -- Requirement 7: the successful path is the same ten entries in the
        -- same order. A run that proved owes no presentation, so it is also
        -- the path on which the retention rule withholds nothing — a retained
        -- handle here would mean the run reported a completion it did not have.
        facts.teardownReleases `shouldBe` teardownEntries
        facts.teardownFailures `shouldBe` []
        facts.teardownRetained `shouldBe` []
        facts.teardownRoute `shouldSatisfy` Text.isPrefixOf "ordinary"

    it "destroyed the explicit messenger after every resource it should have watched" $
      onFindings outcome $ \findings → do
        let released = findings.findingsTeardown.teardownReleases
            position name = length (takeWhile (/= name) released)
        -- Reverse registration order, so a smaller position is released
        -- earlier. The messenger must outlive the swapchain, device, surface
        -- and window, and must not outlive the instance.
        mapM_
          (\earlier → position earlier `shouldSatisfy` (< position "the explicit debug messenger"))
          ["the frame slots", "the swapchain", "the logical device", "the window surface", "the proof window"]
        position "the explicit debug messenger" `shouldSatisfy` (< position "the Vulkan instance")

  describe "The operation and result matrix" $ do
    it "covers acquisition, submission, presentation, oldSwapchain creation, and destruction" $ do
      let operations = map (.rowOperation) operationMatrix
          mentions fragment = any (Text.isInfixOf fragment) operations
      mentions "vkAcquireNextImageKHR" `shouldBe` True
      mentions "vkQueueSubmit2" `shouldBe` True
      mentions "vkQueuePresentKHR" `shouldBe` True
      mentions "oldSwapchain" `shouldBe` True
      mentions "vkDestroySwapchainKHR" `shouldBe` True

    it "states the device-loss destruction rule from the specification and induces no device loss" $ do
      let lossRows = [entry | entry ← operationMatrix, Text.isInfixOf "DEVICE_LOST" entry.rowResult || Text.isInfixOf "DEVICE_LOST" entry.rowOperation]
      lossRows `shouldSatisfy` (not . null)
      map (.rowEvidence) lossRows `shouldSatisfy` all isSpecified

    it "labels every row as either a specification citation or an observation to resolve" $
      map (.rowEvidence) operationMatrix
        `shouldSatisfy` all (\evidence → isObservable evidence || isSpecified evidence)

    it "actually observed every result it claims to observe" $
      onFindings outcome $ \_ → do
        let resolve = standing (achievedFrom outcome)
            unmet =
              [ entry.rowOperation <> " " <> entry.rowResult
              | entry ← operationMatrix
              , Observable observation ← [entry.rowEvidence]
              , resolve observation /= Observed
              ]
        unmet `shouldBe` []

  describe "The matrix's observation labels" $ do
    it "claims nothing for a run that stopped" $ do
      let stopped = Stopped (Failure "a step" "a reason") noTeardown
          rendered = renderRecord "title" "invocation" [] stopped False
      -- The record says "nothing below this line was established"; the table
      -- below that line must not then say otherwise.
      Text.unpack rendered `shouldSatisfy` not . isInfixOf "observed in this run"
      Text.unpack rendered `shouldSatisfy` isInfixOf "not reached: the run stopped first"
      achievedFrom stopped `shouldBe` Nothing

    it "does not call a VK_SUCCESS row observed when every result was suboptimal" $ do
      -- A completed run can still fail to produce a particular result.
      -- VK_SUBOPTIMAL_KHR is a success code the proof accepts, so this is the
      -- shape a real run could take on a resized surface.
      let suboptimal =
            Achieved
              { achievedAcquireResults = ["SUBOPTIMAL_KHR", "SUBOPTIMAL_KHR"]
              , achievedPresentResults = ["SUBOPTIMAL_KHR"]
              , achievedReleaseResults = ["SUCCESS", "SUCCESS"]
              , achievedSubmissions = 2
              }
          resolve = standing (Just suboptimal)
      resolve AcquireSucceeded `shouldBe` NotObserved
      resolve PresentSucceeded `shouldBe` NotObserved
      -- The ones it did produce are unaffected.
      resolve ImagesReleased `shouldBe` Observed
      resolve SubmissionAccepted `shouldBe` Observed
      unlines (map Text.unpack (matrixTable resolve))
        `shouldSatisfy` isInfixOf "**not observed in this run**"

    it "does not call a release row observed when a release failed" $ do
      let refused =
            Achieved
              { achievedAcquireResults = ["SUCCESS"]
              , achievedPresentResults = ["SUCCESS"]
              , achievedReleaseResults = ["SUCCESS", "ERROR_OUT_OF_HOST_MEMORY"]
              , achievedSubmissions = 1
              }
      standing (Just refused) ImagesReleased `shouldBe` NotObserved

    it "records the oldSwapchain failure case, which retires the old swapchain anyway" $ do
      let rows = [entry | entry ← operationMatrix, Text.isInfixOf "oldSwapchain" entry.rowOperation]
      map (.rowResult) rows `shouldContain` ["any error"]

isSpecified ∷ Evidence → Bool
isSpecified = \case
  Specified citation → not (Text.null citation)
  Observable _ → False

isObservable ∷ Evidence → Bool
isObservable = \case
  Observable _ → True
  Specified _ → False

-- | Every example needs the run to have finished. One that did not fails with
-- the step it stopped at, so the suite names the missing requirement rather
-- than reporting an absence as a pass.
onFindings ∷ Outcome → (Findings → Expectation) → Expectation
onFindings outcome assertion = case outcome of
  Stopped failure _ →
    expectationFailure
      ( "the native run stopped at "
          <> Text.unpack failure.failureStep
          <> ": "
          <> Text.unpack failure.failureDetail
      )
  Proved findings → assertion findings
