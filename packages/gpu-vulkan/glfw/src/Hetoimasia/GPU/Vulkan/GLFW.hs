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
-- window: the main thread creates the replacement when the owner asks, and a
-- target that cannot be recovered is reported unavailable
-- ('readVulkanUnavailability') or, when it is required, fails the session
-- ('VulkanRequiredTargetFailed').
--
-- 'runVulkanOwnerLoop' is the main thread's scheduled owner loop with the
-- graphics owner composed in (VK-16): every turn it publishes each attached
-- window's observation and eligibility and the windows' captured render
-- demand to the owner, creates the replacement surfaces the owner asked for,
-- and bounds its own wait by the owner's published deadline. The owner renders
-- the scene it holds — the latest any application thread published through
-- 'publishVulkanScene' — with the configuration's renderer, when demand or a
-- newer scene asks for a frame, paces its own acquisitions and completion
-- polls, and retires a target only once its frames and presentations have gone
-- on their own evidence. A main-thread stall delays what the main thread
-- publishes and nothing the owner already holds.
--
-- The renderer is the consumer's (VK-19). Each frame's 'FrameRequest' names
-- its target, slot and image and the image's extent and color format before
-- the renderer records anything, and the renderer is lent the session's
-- managed 'Construction': it builds pipeline layouts and graphics pipelines
-- over embedded shaders on the owner's thread, binds a pipeline built for the
-- frame's format, sets the viewport and scissor and draws inside the dynamic
-- rendering it begins and ends, and releases or replaces what it built. It
-- also creates and releases buffers and images of the engine's kinds (GRS-2),
-- which it cannot yet record through. It never holds a native handle. What it did not release is destroyed with the
-- session's other managed resources, before the device.
--
-- A host configured with 'DeviceSurfaceFree' creates the device in the
-- owner's startup, before and without any window, and admits a window handed
-- over later only if the chosen queue family presents to it. With or without
-- windows, a consumer on any thread can hand the owner a bounded action
-- ('submitVulkanAction') that runs on the owner's thread with the same
-- 'Construction', never beside a frame, and reads its outcome from the ticket
-- it was given: admission refuses at once rather than waiting, and an action
-- still queued when the owner's exit or the session's failure begins is
-- refused, never run.
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
  , VulkanDeviceStart (..)
  , vulkanHostConfig
  , defaultActionCapacity
  , ValidationFeature (..)
  , VulkanHost (..)
  , NativeObserver (..)
  , noObserver

    -- * The loop (VK-16)
  , runVulkanOwnerLoop
  , publishVulkanScene

    -- * Rendering
  , VulkanRenderer (..)
  , FrameRequest (..)
  , clearRenderer
  , ClearColor (..)

    -- * Consumer construction (VK-19)
  , Construction
  , Constructed
  , constructPipelineLayout
  , constructPipeline
  , replaceConstructedPipeline
  , releaseConstructed
  , PipelineLayout
  , Pipeline
  , PipelineShaders (..)

    -- * Buffers and images (GRS-2)
  , constructBuffer
  , constructImage
  , Buffer
  , BufferKind (..)
  , BufferDescription (..)
  , Image
  , ImageKind (..)
  , ImageFormat (..)
  , formatCode
  , ImageDescription (..)

    -- * Offscreen color targets (GRS-5)
  , PassStart (..)
  , beginRenderingInto
  , copyTargetToReadback
  , copyLevelToReadback
  , constructReadback
  , readConstructedReadback
  , Readback

    -- * Uploads (GRS-6)
  , UploadConfig
  , validateUploadConfig
  , UploadConfigRefused (..)
  , UploadRequest (..)
  , submitVulkanUpload
  , VulkanUploadRefusal (..)
  , UploadsUnavailable (..)
  , UploadRefusal (..)
  , UploadPressure (..)
  , UploadTicket
  , ticketUpload
  , UploadState (..)
  , readUploadTicket
  , awaitUploadTicket
  , cancelVulkanUpload
  , CancelRefusal (..)

    -- * Drawing from buffers with push constants (GRS-4)
  , constructPipelineLayoutWith
  , constructPipelineWith
  , PushStage (..)
  , PushConstantRange (..)
  , InputRate (..)
  , VertexFormat (..)
  , VertexBinding (..)
  , VertexAttribute (..)
  , VertexInput (..)
  , noVertexInput
  , pushConstants
  , IndexType (..)
  , BufferSource (..)
  , bindVertexBuffer
  , bindIndexBuffer
  , drawIndexed

    -- * Pipelines from checked shaders (GRS-16)
  , CheckedShader (..)
  , CheckedShaders (..)
  , constructPipelineLayoutFor
  , constructCheckedPipeline
  , replaceConstructedCheckedPipeline

    -- * The shared ring (GRS-4)
  , RingSize
  , validateRingSize
  , RingSizeRefused (..)
  , constructRing
  , RingClaim
  , claimSize
  , claimRegion
  , writeClaim

    -- * Frame-less batches (GRS-12)
  , constructFramelessBatch
  , BatchTicket
  , ticketBatch
  , TicketState (..)
  , readTicket
  , awaitTicket
  , transitionResource
  , ResourceUse (..)
  , TransitionSource (..)

    -- * Owner-thread actions (GRS-15)
  , VulkanAction (..)
  , submitVulkanAction
  , ActionRefusal (..)
  , ActionTicket
  , readVulkanAction
  , awaitVulkanAction
  , ActionOutcome (..)

    -- * Recording a frame
  , Recorder
  , Refusal (..)
  , beginRendering
  , endRendering
  , bindPipeline
  , setViewport
  , Viewport (..)
  , setScissor
  , Rect (..)
  , draw
  , FrameEvent (..)
  , FrameObserver
  , noFrameObserver

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
  , FrameStorageRefused (..)
  ) where

import Control.Concurrent.STM (STM)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.GLFW.Vulkan (LoaderIntegration)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW (EventAdmission, GraphicsService)
import Hetoimasia.GPU.Model.Identity (TargetClass)
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticVerdict)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( ActionOutcome (..)
  , VulkanUploadRefusal (..)
  , ActionRefusal (..)
  , ActionTicket
  , CaptureMode (CaptureOff)
  , Construction
  , VulkanAction (..)
  , VulkanDeviceStart (..)
  , awaitVulkanAction
  , defaultActionCapacity
  , readVulkanAction
  , Constructed
  , constructBuffer
  , constructFramelessBatch
  , constructImage
  , constructReadback
  , readConstructedReadback
  , constructPipeline
  , constructPipelineLayout
  , constructPipelineLayoutWith
  , constructPipelineWith
  , constructRing
  , constructPipelineLayoutFor
  , constructCheckedPipeline
  , replaceConstructedCheckedPipeline
  , replaceConstructedPipeline
  , releaseConstructed
  , InstanceExtensionsMissing (..)
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
  , VulkanRenderer (..)
  , FrameRequest (..)
  , clearRenderer
  , FrameEvent (..)
  , FrameObserver
  , noFrameObserver
  , FrameStorageRefused (..)
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
  )
import qualified Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller as Controller
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop (publishVulkanScene, runVulkanOwnerLoop)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Production (withVulkanOwnerHostAs)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BatchTicket
  , Buffer
  , BufferDescription (..)
  , BufferKind (..)
  , BufferSource (..)
  , CheckedShader (..)
  , CheckedShaders (..)
  , ClearColor (..)
  , IndexType (..)
  , InputRate (..)
  , PushConstantRange (..)
  , PushStage (..)
  , RingClaim
  , RingSize
  , RingSizeRefused (..)
  , VertexAttribute (..)
  , VertexBinding (..)
  , VertexFormat (..)
  , VertexInput (..)
  , bindIndexBuffer
  , bindVertexBuffer
  , claimRegion
  , claimSize
  , drawIndexed
  , noVertexInput
  , pushConstants
  , validateRingSize
  , writeClaim
  , Image
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , formatCode
  , Pipeline
  , PipelineLayout
  , PipelineShaders (..)
  , Readback
  , Recorder
  , Rect (..)
  , Refusal (..)
  , ResourceUse (..)
  , TicketState (..)
  , TransitionSource (..)
  , Viewport (..)
  , PassStart (..)
  , awaitTicket
  , beginRendering
  , beginRenderingInto
  , copyTargetToReadback
  , copyLevelToReadback
  , bindPipeline
  , draw
  , endRendering
  , readTicket
  , setScissor
  , setViewport
  , ticketBatch
  , transitionResource
  )
import Hetoimasia.GPU.Vulkan.Native.Profile (ValidationFeature (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering (UploadsUnavailable (..))
import Hetoimasia.GPU.Vulkan.Native.Uploads
  ( CancelRefusal (..)
  , UploadConfig
  , UploadConfigRefused (..)
  , UploadPressure (..)
  , UploadRefusal (..)
  , UploadRequest (..)
  , UploadState (..)
  , UploadTicket
  , awaitUploadTicket
  , readUploadTicket
  , ticketUpload
  , validateUploadConfig
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsSessionFailed (..), TeardownEvidence (..), TerminalCause (..), TerminalReport (..))

-- | Run a Vulkan graphics host over this loader capability, and answer the
-- body's result with the diagnostic capture's verdict.
--
-- It must run on the process main thread, which GLFW requires. The
-- capability must outlive it, as its own scope does.
withVulkanOwnerHost
  ∷ Logger → LoaderIntegration → VulkanHostConfig scene → (VulkanHost scene → IO r) → IO (r, DiagnosticVerdict)
withVulkanOwnerHost = withVulkanOwnerHostAs CaptureOff

-- | Hand this host's owner a bounded action to run on its own thread with the
-- session's 'Construction', from any thread, or have it refused at once.
submitVulkanAction ∷ VulkanHost scene → VulkanAction r → STM (Either ActionRefusal (ActionTicket r))
submitVulkanAction host = Controller.submitVulkanAction (vulkanController host)

-- | Admit an upload into this host's session from any thread (GRS-6):
-- answered at once, its bytes copied into the session's staging buffer before
-- this returns, and its ticket read or waited on with a deadline.
submitVulkanUpload ∷ VulkanHost scene → UploadRequest → IO (Either VulkanUploadRefusal UploadTicket)
submitVulkanUpload host = Controller.submitVulkanUpload (vulkanController host)

-- | Cancel an upload, from any thread, before its first copies are recorded.
cancelVulkanUpload ∷ VulkanHost scene → UploadTicket → STM (Either CancelRefusal ())
cancelVulkanUpload host = Controller.cancelVulkanUpload (vulkanController host)

-- | Create one window's surface on the main thread, under its attachment, and
-- hand it to this host's owner as a required or optional target.
handOverVulkanTarget ∷ VulkanHost scene → WindowId → TargetClass → IO VulkanHandover
handOverVulkanTarget host =
  Controller.handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host)

-- | Create, on the main thread, every replacement surface this host's owner
-- asked for to recover a lost surface, each under its target's existing
-- attachment (VK-14). The owner wakes the main thread when it asks, and
-- 'runVulkanOwnerLoop' runs this every turn; an application that drives its
-- own loop runs it itself. Answers how many it created or tried to.
replaceVulkanSurfaces ∷ VulkanHost scene → IO Int
replaceVulkanSurfaces host = Controller.replaceVulkanSurfaces (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host)

-- | Announce a handed-over window whose announcement the owner's full port
-- deferred, now that it may have room.
announceVulkanTarget ∷ VulkanHost scene → GraphicsService → IO EventAdmission
announceVulkanTarget host = Controller.announceVulkanTarget (vulkanController host) (vulkanGraphicsOwner host)

