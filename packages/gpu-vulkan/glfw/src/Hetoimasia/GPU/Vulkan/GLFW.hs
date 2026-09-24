-- | The Vulkan backend's window integration: one graphics session whose
-- supervised graphics owner owns a Vulkan instance, its one shared device and
-- a target for every window surface handed to it.
--
-- 'withVulkanOwnerHost' is the composition, in the order the backend design's
-- P-5 fixes: the loader capability the caller already holds, the diagnostic
-- lifetime, the loader-aware session, and the protected window host with its
-- graphics owner. The owner creates and destroys every Vulkan object on its
-- own thread through the controller's operations; the main thread creates
-- each window's surface through GLFW inside that window's attachment and
-- hands it over with 'handOverVulkanTarget'. See @docs/gpu_backend.md@.
--
-- Nothing is recorded, submitted or presented yet: there is no swapchain, and
-- the owner's progress step reports no render demand. Those are later
-- slices'.
module Hetoimasia.GPU.Vulkan.GLFW
  ( -- * The composition
    withVulkanOwnerHost
  , VulkanHostConfig (..)
  , vulkanHostConfig
  , VulkanHost (..)
  , NativeObserver (..)
  , noObserver

    -- * Handing targets over
  , handOverVulkanTarget
  , announceVulkanTarget
  , VulkanHandover (..)

    -- * Observation
  , VulkanController
  , Readiness (..)
  , readReadiness
  , VulkanRejection (..)
  , readTargetRejection
  , rejectionsRetained
  , readVulkanTargets
  , readVulkanRoots
  , readVulkanModel

    -- * Failures
  , InstanceExtensionsMissing (..)
  , OrphanSurfacesUncertain (..)
  , UnannouncedSurfaceUncertain (..)
  , LeaseRetained (..)
  , RootsOutlivedHost (..)
  ) where

import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.GLFW.Vulkan (LoaderIntegration, allocLoaderSession, requiredInstanceExtensions)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW (EventAdmission, GraphicsService)
import Hetoimasia.GPU.Model.Identity (TargetClass)
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticVerdict)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Bridge (vulkanSurfaceBridge)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( InstanceExtensionsMissing (..)
  , LeaseRetained (..)
  , NativeObserver (..)
  , OrphanSurfacesUncertain (..)
  , Readiness (..)
  , RootsOutlivedHost (..)
  , UnannouncedSurfaceUncertain (..)
  , VulkanController
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRejection (..)
  , readReadiness
  , readTargetRejection
  , readVulkanModel
  , readVulkanRoots
  , readVulkanTargets
  , noObserver
  , rejectionsRetained
  , vulkanHostConfig
  , withVulkanOwnerHostOver
  )
import qualified Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller as Controller
import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (instancePointer, vulkanRootOps)

-- | Run a Vulkan graphics host over this loader capability, and answer the
-- body's result with the diagnostic capture's verdict.
--
-- It must run on the process main thread, which GLFW requires. The
-- capability must outlive it, as its own scope does.
withVulkanOwnerHost
  ∷ Logger → LoaderIntegration → VulkanHostConfig scene → (VulkanHost scene → IO r) → IO (r, DiagnosticVerdict)
withVulkanOwnerHost logger integration =
  withVulkanOwnerHostOver
    logger
    vulkanRootOps
    instancePointer
    (vulkanSurfaceBridge integration)
    (allocLoaderSession integration)
    requiredInstanceExtensions

-- | Create one window's surface on the main thread, under its attachment, and
-- hand it to this host's owner as a required or optional target.
handOverVulkanTarget ∷ VulkanHost scene → WindowId → TargetClass → IO VulkanHandover
handOverVulkanTarget host =
  Controller.handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host)

-- | Announce a handed-over window whose announcement the owner's full port
-- deferred, now that it may have room.
announceVulkanTarget ∷ VulkanHost scene → GraphicsService → IO EventAdmission
announceVulkanTarget host = Controller.announceVulkanTarget (vulkanController host) (vulkanGraphicsOwner host)
