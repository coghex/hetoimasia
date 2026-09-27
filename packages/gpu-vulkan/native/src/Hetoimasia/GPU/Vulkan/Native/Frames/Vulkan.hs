{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The production native layer under "Hetoimasia.GPU.Vulkan.Native.Frames".
--
-- Every call is the binding's own, which `cabal.project.vulkan` builds @safe@:
-- submission, acquisition, presentation, a fence's status, a finite fence wait
-- and an image's release are blocking or driver-bound calls, not recording, so
-- none belongs in the audited @unsafe@ subset (D-28). Every decision about what may be acquired,
-- submitted, waited on or released is the frames'; this module only turns
-- each request into its native call and each result into what the frames
-- decide by.
module Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan
  ( vulkanFrameOps
  ) where

import Control.Exception (SomeException, fromException, throwIO, try)
import Data.IORef (writeIORef)
import qualified Data.Vector as Vector
import Data.Word (Word64)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek, poke)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10
  ( CommandBuffer
  , Device
  , Fence (..)
  , FenceCreateInfo (..)
  , Result (..)
  , Semaphore (..)
  , SemaphoreCreateInfo (..)
  , commandBufferHandle
  , createFence
  , createSemaphore
  , destroyFence
  , destroySemaphore
  , getDeviceQueue
  , getFenceStatus
  , resetFences
  , waitForFences
  , data NULL_HANDLE
  )
import Vulkan.Core13
  ( CommandBufferSubmitInfo (..)
  , SemaphoreSubmitInfo (..)
  , SubmitInfo2 (..)
  , queueSubmit2
  )
import Vulkan.Core13.Enums.PipelineStageFlags2
  ( PipelineStageFlags2
  , data PIPELINE_STAGE_2_ALL_COMMANDS_BIT
  , data PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT
  )
import Vulkan.Exception (VulkanException (..))
import Vulkan.Extensions.VK_EXT_swapchain_maintenance1 (ReleaseSwapchainImagesInfoKHR (..), SwapchainPresentFenceInfoKHR (..), releaseSwapchainImagesKHR)
import Vulkan.Extensions.VK_KHR_swapchain (PresentInfoKHR (..), SwapchainKHR (..), acquireNextImageKHR, queuePresentKHR)
import Vulkan.Zero (zero)

import Hetoimasia.GPU.Vulkan.Native.Frames
  ( AcquireResult (..)
  , FrameOps (..)
  , PresentRequest (..)
  , PresentStatus (..)
  , SubmitBatch (..)
  , WaitStage (..)
  )

-- | The frames' native layer.
vulkanFrameOps ∷ FrameOps Device CommandBuffer
vulkanFrameOps =
  FrameOps
    { opsCreateSemaphore = \device →
        (\(Semaphore handle) → handle) <$> createSemaphore device (SemaphoreCreateInfo {next = (), flags = zero}) Nothing
    , opsDestroySemaphore = \device handle → destroySemaphore device (Semaphore handle) Nothing
    , opsCreateFence = \device →
        (\(Fence handle) → handle) <$> createFence device (FenceCreateInfo {next = (), flags = zero}) Nothing
    , opsDestroyFence = \device handle → destroyFence device (Fence handle) Nothing
    , opsResetFence = \device handle → resetFences device (Vector.singleton (Fence handle))
    , opsFenceSignalled = \device handle →
        getFenceStatus device (Fence handle) >>= \case
          SUCCESS → pure True
          NOT_READY → pure False
          other → throwIO (VulkanException other)
    , opsAcquireImage = \device swapchain semaphore →
        try (acquireNextImageKHR device (SwapchainKHR swapchain) 0 (Semaphore semaphore) NULL_HANDLE) >>= \case
          Right (SUCCESS, index) → pure (AcquiredIndex index)
          Right (SUBOPTIMAL_KHR, index) → pure (AcquiredSuboptimalIndex index)
          Right (NOT_READY, _) → pure AcquiringNotReady
          Right (TIMEOUT, _) → pure AcquiringTimedOut
          Right (other, _) → throwIO (VulkanException other)
          Left (VulkanException ERROR_OUT_OF_DATE_KHR) → pure AcquiringOutOfDate
          Left (VulkanException ERROR_SURFACE_LOST_KHR) → pure AcquiringSurfaceLost
          Left failure → throwIO failure
    , opsSubmit = \device family batches fence → do
        queue ← getDeviceQueue device family 0
        queueSubmit2 queue (Vector.fromList (map submitInfo batches)) (Fence fence)
    , opsNoEffect = \failure → case fromException failure of
        Just (VulkanException result) → result `elem` [ERROR_OUT_OF_HOST_MEMORY, ERROR_OUT_OF_DEVICE_MEMORY]
        Nothing → False
    , opsReleaseImages = \device swapchain indices →
        releaseSwapchainImagesKHR
          device
          ReleaseSwapchainImagesInfoKHR {swapchain = SwapchainKHR swapchain, imageIndices = Vector.fromList indices}
    , opsPresent = \device family request status → do
        queue ← getDeviceQueue device family 0
        -- The swapchain's entry of pResults starts as a value no call writes,
        -- so an entry the call left alone is read as unwritten, never as
        -- success; it is read back before anything the call raised is
        -- re-raised.
        alloca $ \results → do
          poke results unwritten
          outcome ←
            try @SomeException $
              queuePresentKHR
                queue
                ( PresentInfoKHR
                    { next = (SwapchainPresentFenceInfoKHR {fences = Vector.singleton (Fence (presentFence request))}, ())
                    , waitSemaphores = Vector.singleton (Semaphore (presentWait request))
                    , swapchains = Vector.singleton (SwapchainKHR (presentSwapchain request))
                    , imageIndices = Vector.singleton (presentIndex request)
                    , results = results
                    }
                    ∷ PresentInfoKHR '[SwapchainPresentFenceInfoKHR]
                )
          peek results >>= writeIORef status . statusOf
          either throwIO (const (pure ())) outcome
    , opsWaitFence = \device handle timeout →
        waitForFences device (Vector.singleton (Fence handle)) True timeout >>= \case
          SUCCESS → pure True
          TIMEOUT → pure False
          other → throwIO (VulkanException other)
    }

-- | A result no call writes: @VK_RESULT_MAX_ENUM@.
unwritten ∷ Result
unwritten = Result maxBound

-- | The swapchain's entry of @pResults@, as the frames read it.
statusOf ∷ Result → PresentStatus
statusOf result
  | result == unwritten = PresentStatusUnwritten
  | otherwise = case result of
      SUCCESS → PresentStatusSuccess
      SUBOPTIMAL_KHR → PresentStatusSuboptimal
      ERROR_OUT_OF_DATE_KHR → PresentStatusOutOfDate
      ERROR_SURFACE_LOST_KHR → PresentStatusSurfaceLost
      ERROR_OUT_OF_HOST_MEMORY → PresentStatusOutOfMemory
      ERROR_OUT_OF_DEVICE_MEMORY → PresentStatusOutOfMemory
      Result code → PresentStatusOther code

-- | One batch as @VkSubmitInfo2@: every wait at the batch's stage, every
-- command buffer in order, and every signal once all its commands complete.
submitInfo ∷ SubmitBatch CommandBuffer → SomeStruct SubmitInfo2
submitInfo batch =
  SomeStruct
    ( SubmitInfo2
        { next = ()
        , flags = zero
        , waitSemaphoreInfos = Vector.fromList [semaphoreInfo (waitStage (submitWaitStage batch)) handle | handle ← submitWaits batch]
        , commandBufferInfos =
            Vector.fromList
              [ SomeStruct (CommandBufferSubmitInfo {next = (), commandBuffer = commandBufferHandle commands, deviceMask = 0} ∷ CommandBufferSubmitInfo '[])
              | commands ← submitCommands batch
              ]
        , signalSemaphoreInfos = Vector.fromList [semaphoreInfo PIPELINE_STAGE_2_ALL_COMMANDS_BIT handle | handle ← submitSignals batch]
        }
        ∷ SubmitInfo2 '[]
    )
  where
    semaphoreInfo ∷ PipelineStageFlags2 → Word64 → SemaphoreSubmitInfo
    semaphoreInfo stage handle = SemaphoreSubmitInfo {semaphore = Semaphore handle, value = 0, stageMask = stage, deviceIndex = 0}
    waitStage = \case
      WaitAtColorOutput → PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT
      WaitAtAllCommands → PIPELINE_STAGE_2_ALL_COMMANDS_BIT
