{-# LANGUAGE OverloadedRecordDot #-}

-- | Requirement 7's operation and result matrix.
--
-- Every row says what the operation's result actually did — which effects
-- happened, which did not, what the caller still owns, and whether a retry is
-- safe — and where that claim comes from. A run of this proof observes a
-- handful of these rows directly; the rest are rare or destructive paths, and
-- for those the row cites the specification text that establishes it and says
-- so, rather than implying the proof produced them.
--
-- No device loss is induced. The device-loss rows are specification rows, and
-- the matrix says which destruction they authorize precisely so a later slice
-- does not have to guess.
module Test.Vulkan.Proof.Matrix
  ( MatrixRow (..)
  , Evidence (..)
  , Observation (..)
  , Standing (..)
  , Achieved (..)
  , operationMatrix
  , standing
  , describeEvidence
  ) where

import Data.Text (Text)

-- | A result this proof claims to have produced itself.
--
-- A row cannot simply be labelled observed, because whether it was depends on
-- what the run did: a run that stopped before creating a device produced none
-- of these, and a run whose every acquisition returned @VK_SUBOPTIMAL_KHR@
-- produced no @VK_SUCCESS@ acquisition however well it otherwise went.
data Observation
  = AcquireSucceeded
  | SubmissionAccepted
  | PresentSucceeded
  | ImagesReleased
  deriving (Eq, Show)

-- | What the run has to say about one of those.
data Standing
  = Observed
    -- ^ The run produced this result and saw the effect.
  | NotObserved
    -- ^ The run reached the operation and this particular result did not occur.
  | NotReached
    -- ^ The run stopped before it could produce this result at all.
  deriving (Eq, Show)

-- | The results a finished run actually produced, reduced to what the matrix
-- needs. Small on purpose: the labelling rules below are then testable without
-- building a whole set of findings.
data Achieved = Achieved
  { achievedAcquireResults ∷ [Text]
  , achievedPresentResults ∷ [Text]
  , achievedReleaseResults ∷ [Text]
  , achievedSubmissions ∷ Int
  }
  deriving (Eq, Show)

-- | How a run stands on one observation. 'Nothing' is a run that stopped, and
-- a run that stopped observed nothing.
standing ∷ Maybe Achieved → Observation → Standing
standing Nothing _ = NotReached
standing (Just achieved) observation = case observation of
  AcquireSucceeded → fromResults achieved.achievedAcquireResults
  PresentSucceeded → fromResults achieved.achievedPresentResults
  ImagesReleased →
    if not (null achieved.achievedReleaseResults) && all (== "SUCCESS") achieved.achievedReleaseResults
      then Observed
      else NotObserved
  SubmissionAccepted → if achieved.achievedSubmissions > 0 then Observed else NotObserved
  where
    fromResults results = if "SUCCESS" `elem` results then Observed else NotObserved

-- | Where a row's claim comes from.
data Evidence
  = Observable Observation
    -- ^ A result this proof sets out to produce. Whether it did is the run's to
    -- say, not this table's.
  | Specified Text
    -- ^ The Vulkan specification establishes it; the text names the section.
    -- No attempt is made to produce the result on a real device.
  deriving (Eq, Show)

describeEvidence ∷ (Observation → Standing) → Evidence → Text
describeEvidence resolve = \case
  Specified citation → "specification: " <> citation
  Observable observation → case resolve observation of
    Observed → "observed in this run"
    NotObserved → "**not observed in this run**"
    NotReached → "**not reached: the run stopped first**"

data MatrixRow = MatrixRow
  { rowOperation ∷ Text
  , rowResult ∷ Text
  , rowEffects ∷ Text
    -- ^ What actually happened, including what did not happen.
  , rowDisposition ∷ Text
    -- ^ What the caller still owns and what it may safely do next.
  , rowEvidence ∷ Evidence
  }
  deriving (Eq, Show)

-- | The matrix. Ordered by operation so a reader can find one; the acquire,
-- submit, present, creation-with-@oldSwapchain@, and destruction groups are the
-- five requirement 7 names.
operationMatrix ∷ [MatrixRow]
operationMatrix =
  [ MatrixRow
      { rowOperation = "vkAcquireNextImageKHR"
      , rowResult = "VK_SUCCESS"
      , rowEffects = "An image index is returned and the semaphore or fence given to the call will be signalled. The application now owns that image."
      , rowDisposition = "Record, submit, present, or release it. The acquisition's signal operation exists whether or not the frame is ever rendered, so abandoning the frame must still consume it."
      , rowEvidence = Observable AcquireSucceeded
      }
  , MatrixRow
      { rowOperation = "vkAcquireNextImageKHR"
      , rowResult = "VK_SUBOPTIMAL_KHR"
      , rowEffects = "A successful acquisition with the same ownership and signal effects as VK_SUCCESS; the swapchain no longer matches the surface exactly."
      , rowDisposition = "Keep the image and its synchronization; never discard the index. Coalesce a replacement request and finish or safely abandon this frame first."
      , rowEvidence = Specified "vkAcquireNextImageKHR return codes; VK_SUBOPTIMAL_KHR is a success code"
      }
  , MatrixRow
      { rowOperation = "vkAcquireNextImageKHR"
      , rowResult = "VK_NOT_READY or VK_TIMEOUT"
      , rowEffects = "No image was acquired and no semaphore or fence was signalled. Ordinary backpressure, not a failure."
      , rowDisposition = "Release any slot reservation and defer. No completion obligation was created, so there is nothing to wait on and nothing to release."
      , rowEvidence = Specified "vkAcquireNextImageKHR: with a zero or expired timeout no image is acquired and the semaphore and fence are unaffected"
      }
  , MatrixRow
      { rowOperation = "vkAcquireNextImageKHR"
      , rowResult = "VK_ERROR_OUT_OF_DATE_KHR"
      , rowEffects = "No image was acquired and the semaphore and fence are unaffected. The swapchain can no longer be used for presentation."
      , rowDisposition = "No new acquisition obligation exists. Request a target-local replacement; every older obligation on the retiring swapchain remains the owner's."
      , rowEvidence = Specified "vkAcquireNextImageKHR: on VK_ERROR_OUT_OF_DATE_KHR the semaphore and fence are unaffected"
      }
  , MatrixRow
      { rowOperation = "vkQueueSubmit2"
      , rowResult = "VK_SUCCESS"
      , rowEffects = "The batch is pending; its waits, command buffers, signals, and fence are all in force until it completes."
      , rowDisposition = "The command buffers, semaphores, and every resource they reference stay owned until the fence signals. A returned handle is not completion."
      , rowEvidence = Observable SubmissionAccepted
      }
  , MatrixRow
      { rowOperation = "vkQueueSubmit2"
      , rowResult = "VK_ERROR_OUT_OF_HOST_MEMORY or VK_ERROR_OUT_OF_DEVICE_MEMORY"
      , rowEffects = "No submission became pending: the specified no-effect case. The fence is not signalled and no semaphore state changed."
      , rowDisposition = "Do not mark anything pending and do not wait on the fence. The prior acquisition and recording stay owned; reclaim eligible resources once and retry at most once, otherwise retire the frame safely."
      , rowEvidence = Specified "Vulkan: a command that returns a run time error has no side effects unless otherwise specified; vkQueueSubmit2 out-of-memory returns leave the submission unmade"
      }
  , MatrixRow
      { rowOperation = "vkQueuePresentKHR"
      , rowResult = "VK_SUCCESS"
      , rowEffects = "Presentation was enqueued for every swapchain in the call. The wait semaphores are consumed by that operation, and a present fence chained through VkSwapchainPresentFenceInfoKHR will signal when the presentation engine has finished with them."
      , rowDisposition = "Retire the presentation semaphore on the present fence and on nothing else. The rendering fence says only that rendering finished."
      , rowEvidence = Observable PresentSucceeded
      }
  , MatrixRow
      { rowOperation = "vkQueuePresentKHR"
      , rowResult = "VK_SUBOPTIMAL_KHR"
      , rowEffects = "Presentation was enqueued exactly as for VK_SUCCESS; the swapchain no longer matches the surface exactly."
      , rowDisposition = "Preserve the enqueued operations and the per-swapchain results. Request recovery without resetting this frame's synchronization early."
      , rowEvidence = Specified "vkQueuePresentKHR return codes; VK_SUBOPTIMAL_KHR is a success code and presentation still occurred"
      }
  , MatrixRow
      { rowOperation = "vkQueuePresentKHR"
      , rowResult = "VK_ERROR_OUT_OF_DATE_KHR or VK_ERROR_SURFACE_LOST_KHR"
      , rowEffects = "With several swapchains, some may have been presented and some not; pResults is the only per-swapchain truth. The semaphore waits that did happen still happened."
      , rowDisposition = "Classify per swapchain through pResults before deciding anything. Recover the affected target; do not treat one swapchain's failure as evidence about another's."
      , rowEvidence = Specified "vkQueuePresentKHR: pResults gives the per-swapchain result; the overall result is the worst of them"
      }
  , MatrixRow
      { rowOperation = "vkQueuePresentKHR"
      , rowResult = "VK_ERROR_OUT_OF_HOST_MEMORY or VK_ERROR_OUT_OF_DEVICE_MEMORY"
      , rowEffects = "No presentation was enqueued: the specified no-effect case. No present fence was enqueued either."
      , rowDisposition = "Do not wait on a present fence this call did not enqueue. The image and its synchronization are still owned, and the prior rendering is still pending or complete on its own fence."
      , rowEvidence = Specified "Vulkan: a command that returns a run time error has no side effects unless otherwise specified"
      }
  , MatrixRow
      { rowOperation = "vkReleaseSwapchainImagesEXT"
      , rowResult = "VK_SUCCESS"
      , rowEffects = "The named images return to the presentation engine without being presented, and become acquirable again. The call is read-only with respect to them: it does not present them, does not modify their contents, does not change their layout, and does not retire or rebuild the swapchain."
      , rowDisposition = "Legal only for images that were acquired and not presented, and only once every semaphore signalled by their acquisition has been waited on. Contents and layout survive the release: acquiring a released image again returns it as it was, which is the one place an acquired image\'s contents are not simply undefined, and is why abandoning a frame this way costs nothing to redo. This is the abandonment path; it is not a substitute for presentation."
      , rowEvidence = Observable ImagesReleased
      }
  , MatrixRow
      { rowOperation = "vkCreateSwapchainKHR with a non-null oldSwapchain"
      , rowResult = "VK_SUCCESS"
      , rowEffects = "A new swapchain exists and oldSwapchain is retired. Retired is not dead: it is not destroyed, its outstanding work is untouched, and images already acquired from it may still be presented. What it may no longer do is supply a new acquisition."
      , rowDisposition = "Finish the frames already in flight on the retired swapchain by presenting them; acquire nothing further from it. It also cannot be named as oldSwapchain again, because that parameter must be a non-retired swapchain. Every image, view, and synchronization object depending on it stays owned until its work completes; destroying it early is the error the retirement model exists to prevent."
      , rowEvidence = Specified "VUID-VkSwapchainCreateInfoKHR-oldSwapchain-01933 requires a non-retired oldSwapchain; VUID-vkAcquireNextImageKHR-swapchain-01285 forbids acquiring from a retired swapchain, and no such rule forbids presenting an image already acquired from one"
      }
  , MatrixRow
      { rowOperation = "vkCreateSwapchainKHR with a non-null oldSwapchain"
      , rowResult = "any error"
      , rowEffects = "No new swapchain was created, but oldSwapchain is retired regardless. This is the documented exception to the no-side-effects rule, and it is the failure case a naive retry loses."
      , rowDisposition = "A retry cannot pass the now-retired swapchain as oldSwapchain, because that parameter must name a non-retired one. Nor can it simply pass VK_NULL_HANDLE straight away: the retired swapchain still holds the native window, and creating against that surface while it lives can fail with VK_ERROR_NATIVE_WINDOW_IN_USE_KHR. The order is finish or abandon the images already acquired from it, destroy it once its work has completed, and only then create afresh with VK_NULL_HANDLE."
      , rowEvidence = Specified "vkCreateSwapchainKHR: oldSwapchain is retired even if creation of the new swapchain fails; VUID-VkSwapchainCreateInfoKHR-oldSwapchain-01933 then excludes it from a retry, and vkCreateSwapchainKHR may return VK_ERROR_NATIVE_WINDOW_IN_USE_KHR while the native window is still held"
      }
  , MatrixRow
      { rowOperation = "vkDestroySwapchainKHR"
      , rowResult = "n/a"
      , rowEffects = "Destroys the swapchain and its images. Images acquired from it must not be in use, and the surface's other swapchains are unaffected."
      , rowDisposition = "Every outstanding acquisition, submission, and presentation that names this swapchain or its images must have completed. A present fence is the completion evidence for the presentation side; the rendering fence is not."
      , rowEvidence = Specified "vkDestroySwapchainKHR valid usage: all uses of presentable images acquired from the swapchain must have completed"
      }
  , MatrixRow
      { rowOperation = "any queue or device command"
      , rowResult = "VK_ERROR_DEVICE_LOST"
      , rowEffects = "The device is permanently unusable. Pending work may never complete, and fences and semaphores may never be signalled."
      , rowDisposition = "Terminal for the whole graphics session. Waiting for completion is not an option, because the completion may never arrive."
      , rowEvidence = Specified "Vulkan, Lost Device: the device is lost and further commands on it fail"
      }
  , MatrixRow
      { rowOperation = "destruction after VK_ERROR_DEVICE_LOST"
      , rowResult = "n/a"
      , rowEffects = "The specification permits destroying objects of a lost device without waiting for their pending work: completion is not required, because it may never happen."
      , rowDisposition = "This is the only rule that authorizes destroying an object whose work has not completed. It authorizes destruction, not a claim that the work finished, and it must never be used to mark an unfinished fence as signalled."
      , rowEvidence = Specified "Vulkan, Lost Device: objects of a lost device may be destroyed, and vkDeviceWaitIdle and fence waits may return VK_ERROR_DEVICE_LOST"
      }
  ]
