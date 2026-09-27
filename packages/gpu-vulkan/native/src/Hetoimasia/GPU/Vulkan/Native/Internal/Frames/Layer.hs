-- | The native layer of frame acquisition, submission, presentation and
-- abandonment ("Hetoimasia.GPU.Vulkan.Native.Frames"): every native call it
-- makes, as the open record 'FrameOps', and what those calls answer.
--
-- This module holds no state and makes no call: it is the shape of the layer,
-- which "Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan" implements over the real
-- device and the headless examples implement over a stand-in. It is private
-- to the package; clients reach every name here through the public frames
-- module, which re-exports them unchanged.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer
  ( FrameOps (..)
  , AcquireResult (..)
  , WaitStage (..)
  , SubmitBatch (..)
  , PresentRequest (..)
  , PresentStatus (..)
  ) where

import Control.Exception (SomeException)
import Data.Int (Int32)
import Data.IORef (IORef)
import Data.Word (Word32, Word64)

-- | What one non-blocking acquisition answered.
data AcquireResult
  = AcquiredIndex !Word32
    -- ^ @VK_SUCCESS@: the image is owned and the semaphore's signal is pending.
  | AcquiredSuboptimalIndex !Word32
    -- ^ @VK_SUBOPTIMAL_KHR@: a successful acquisition, exactly as above.
  | AcquiringNotReady
    -- ^ @VK_NOT_READY@: nothing was acquired and nothing will be signalled.
  | AcquiringTimedOut
    -- ^ @VK_TIMEOUT@: the same.
  | AcquiringOutOfDate
    -- ^ @VK_ERROR_OUT_OF_DATE_KHR@: nothing was acquired, and the swapchain
    -- can supply nothing more.
  | AcquiringSurfaceLost
    -- ^ @VK_ERROR_SURFACE_LOST_KHR@: nothing was acquired.
  deriving (Eq, Show)

-- | The pipeline stage a submission's semaphore waits block.
data WaitStage
  = WaitAtColorOutput
    -- ^ Color-attachment output: where a frame's rendering first touches its
    -- image, and so where its acquisition must have finished.
  | WaitAtAllCommands
    -- ^ Every stage: a cleanup submission, which runs no command at all.
  deriving (Eq, Show)

-- | One batch of a queue submission: binary semaphores waited at one stage,
-- command buffers executed in order, and binary semaphores signalled once
-- they have all completed.
data SubmitBatch cmd = SubmitBatch
  { submitWaits ∷ ![Word64]
  , submitWaitStage ∷ !WaitStage
  , submitCommands ∷ ![cmd]
  , submitSignals ∷ ![Word64]
  }

-- | One presentation: one image of one swapchain, waiting on one binary
-- semaphore, with one present fence chained through
-- @VkSwapchainPresentFenceInfoEXT@.
data PresentRequest = PresentRequest
  { presentSwapchain ∷ !Word64
  , presentIndex ∷ !Word32
  , presentWait ∷ !Word64
    -- ^ The render-finished semaphore the presentation waits on.
  , presentFence ∷ !Word64
    -- ^ The present fence, unsignalled, which signals once the presentation
    -- engine has finished with the semaphore and the image's presentation
    -- resources.
  }
  deriving (Eq, Show)

-- | The swapchain's own entry of @pResults@: the only per-swapchain truth a
-- presentation answers.
data PresentStatus
  = PresentStatusSuccess
  | PresentStatusSuboptimal
  | PresentStatusOutOfDate
  | PresentStatusSurfaceLost
  | PresentStatusOutOfMemory
    -- ^ @VK_ERROR_OUT_OF_HOST_MEMORY@ or @VK_ERROR_OUT_OF_DEVICE_MEMORY@.
  | PresentStatusOther !Int32
    -- ^ Any other result, device loss included, as its numeric value.
  | PresentStatusUnwritten
    -- ^ The call never wrote the entry: nothing about the swapchain can be
    -- read from it.
  deriving (Eq, Show)

-- | Every native call the frames make, over an open device type @dev@ and an
-- open command-buffer type @cmd@. Semaphores and fences are 64-bit handles, as
-- every non-dispatchable handle is.
data FrameOps dev cmd = FrameOps
  { opsCreateSemaphore ∷ dev → IO Word64
    -- ^ A binary semaphore, unsignalled.
  , opsDestroySemaphore ∷ dev → Word64 → IO ()
  , opsCreateFence ∷ dev → IO Word64
    -- ^ A fence, unsignalled.
  , opsDestroyFence ∷ dev → Word64 → IO ()
  , opsResetFence ∷ dev → Word64 → IO ()
    -- ^ @vkResetFences@ of one fence no submission holds pending.
  , opsFenceSignalled ∷ dev → Word64 → IO Bool
    -- ^ @vkGetFenceStatus@: whether it has signalled, without waiting. Asked
    -- only of a fence a submission made pending.
  , opsAcquireImage ∷ dev → Word64 → Word64 → IO AcquireResult
    -- ^ @vkAcquireNextImageKHR@ from the swapchain with a zero timeout,
    -- signalling the semaphore. Any other result raises.
  , opsSubmit ∷ dev → Word32 → [SubmitBatch cmd] → Word64 → IO ()
    -- ^ @vkQueueSubmit2@ of the batches, in order, on the first queue of the
    -- queue family, signalling the fence once every batch has completed.
  , opsNoEffect ∷ SomeException → Bool
    -- ^ Whether a failure the submission raised is one the specification
    -- defines as having had no effect: out of host or device memory. Anything
    -- else a submission raised has an unknown effect.
  , opsReleaseImages ∷ dev → Word64 → [Word32] → IO ()
    -- ^ @vkReleaseSwapchainImagesEXT@: return acquired, unpresented images of
    -- the swapchain whose acquisition signals have all been waited on.
  , opsPresent ∷ dev → Word32 → PresentRequest → IORef PresentStatus → IO ()
    -- ^ @vkQueuePresentKHR@ of the one image on the first queue of the queue
    -- family. The swapchain's entry of @pResults@ is written to the reference
    -- whatever the call answered — before it returns, and before it raises —
    -- and the reference is left as it was, 'PresentStatusUnwritten', when the
    -- call never wrote that entry. An error result raises, as every call of
    -- the layer does; the reference is still written first.
  , opsWaitFence ∷ dev → Word64 → Word64 → IO Bool
    -- ^ @vkWaitForFences@ on one fence a queue operation made pending, for at
    -- most this many nanoseconds: whether it signalled, or 'False' when the
    -- wait timed out. A wait has no effect on the fence.
  }
