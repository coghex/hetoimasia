-- | The production composition over the native layers and the loader
-- integration, with or without verification capture (VK-19).
--
-- The public module's 'Hetoimasia.GPU.Vulkan.GLFW.withVulkanOwnerHost' is
-- 'withVulkanOwnerHostAs' 'CaptureOff'. 'CaptureOn' is reachable only through
-- this private sublibrary, so only this package's own suites can build a host
-- whose swapchains are unclipped transfer sources and ask it for a frame's
-- pixels. It holds no state of its own.
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Production
  ( withVulkanOwnerHostAs
  ) where

import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.GLFW.Vulkan (LoaderIntegration, allocLoaderSession, requiredInstanceExtensions)
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticVerdict)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Bridge (vulkanSurfaceBridge)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( CaptureMode
  , RenderingOps (..)
  , VulkanHost
  , VulkanHostConfig
  , noControllerHooks
  , withVulkanOwnerHostHooked
  )
import Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan (vulkanFrameOps)
import Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan (vulkanRecordingOps)
import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (instancePointer, vulkanRootOps)

-- | Run a Vulkan graphics host over this loader capability, building its
-- generations for verification capture or not, and answer the body's result
-- with the diagnostic capture's verdict. It must run on the process main
-- thread, and the capability must outlive it.
withVulkanOwnerHostAs
  ∷ CaptureMode → Logger → LoaderIntegration → VulkanHostConfig scene → (VulkanHost scene → IO r) → IO (r, DiagnosticVerdict)
withVulkanOwnerHostAs capturing logger integration =
  withVulkanOwnerHostHooked
    noControllerHooks
    capturing
    logger
    vulkanRootOps
    (RenderingOps vulkanRecordingOps vulkanFrameOps)
    instancePointer
    (vulkanSurfaceBridge integration)
    (allocLoaderSession integration)
    requiredInstanceExtensions
