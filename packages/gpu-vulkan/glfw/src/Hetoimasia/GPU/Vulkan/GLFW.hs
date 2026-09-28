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
-- The owner builds, replaces and destroys each target's swapchain generations
-- from the geometry it folded, and recovers a lost surface on the same live
-- window: the main thread creates the replacement with
-- 'replaceVulkanSurfaces' when the owner asks, and a target that cannot be
-- recovered is reported unavailable ('readVulkanUnavailability') or, when it
-- is required, fails the session ('VulkanRequiredTargetFailed'). Nothing is
-- recorded, submitted or presented through the controller yet, and the
-- owner's progress step reports no render demand: composing the frames in is
-- a later slice's.
--
-- A terminal failure — the device's loss, a validation error or a sink failure
-- the capture reports, an uncertain effect, a failed cleanup, a required
-- target's exhausted recovery — is latched as the session's primary failure
-- at the owner's next checkpoint, ends the owner's run, reaches the
-- application's checkpoints through the owner's supervision, and refuses every
-- later handover naming it ('VulkanSessionFailed'); 'readVulkanTerminal'
-- reads it with what teardown found beside it.
module Hetoimasia.GPU.Vulkan.GLFW
  ( -- * The composition
    withVulkanOwnerHost
  , VulkanHostConfig (..)
  , vulkanHostConfig
  , ValidationFeature (..)
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

    -- * Terminal failure
  , readVulkanTerminal
  , TerminalReport (..)
  , TerminalCause (..)
  , TeardownEvidence (..)
  , GraphicsSessionFailed (..)

    -- * Swapchain generations
  , readVulkanGenerations
  , useVulkanGeneration
  , endVulkanGenerationUse

    -- * Recovery (VK-14)
  , replaceVulkanSurfaces
  , VulkanUnavailability (..)
  , UnavailableBecause (..)
  , readVulkanUnavailability
  , unavailabilitiesRetained

    -- * Failures
  , InstanceExtensionsMissing (..)
  , OrphanSurfacesUncertain (..)
  , UnannouncedSurfaceUncertain (..)
  , LeaseRetained (..)
  , RootsOutlivedHost (..)
  , ReplacementSurfaceUncertain (..)
  , VulkanRequiredTargetFailed (..)
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
  , ReplacementSurfaceUncertain (..)
  , RootsOutlivedHost (..)
  , UnannouncedSurfaceUncertain (..)
  , UnavailableBecause (..)
  , VulkanController
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRejection (..)
  , VulkanRequiredTargetFailed (..)
  , VulkanUnavailability (..)
  , readReadiness
  , readVulkanUnavailability
  , unavailabilitiesRetained
  , readTargetRejection
  , endVulkanGenerationUse
  , readVulkanGenerations
  , readVulkanModel
  , readVulkanRoots
  , readVulkanTargets
  , readVulkanTerminal
  , noObserver
  , useVulkanGeneration
  , rejectionsRetained
  , vulkanHostConfig
  , withVulkanOwnerHostOver
  )
import qualified Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller as Controller
import Hetoimasia.GPU.Vulkan.Native.Profile (ValidationFeature (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsSessionFailed (..), TeardownEvidence (..), TerminalCause (..), TerminalReport (..))
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

-- | Create, on the main thread, every replacement surface this host's owner
-- asked for to recover a lost surface, each under its target's existing
-- attachment (VK-14). The owner wakes the main thread when it asks; until
-- VK-16's loop adapter runs this every turn, the application runs it, as it
-- publishes observations. Answers how many it created or tried to.
replaceVulkanSurfaces ∷ VulkanHost scene → IO Int
replaceVulkanSurfaces host = Controller.replaceVulkanSurfaces (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host)

-- | Announce a handed-over window whose announcement the owner's full port
-- deferred, now that it may have room.
announceVulkanTarget ∷ VulkanHost scene → GraphicsService → IO EventAdmission
announceVulkanTarget host = Controller.announceVulkanTarget (vulkanController host) (vulkanGraphicsOwner host)
