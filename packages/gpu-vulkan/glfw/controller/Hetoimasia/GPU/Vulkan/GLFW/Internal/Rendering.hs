{-# LANGUAGE RankNTypes #-}

-- | Rendering in the graphics owner's step (VK-16): the recording and the
-- frames composed into the controller, render demand turned into frames, and
-- the owner's own pacing of completion polls and acquisition retries.
--
-- The controller ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller") calls
-- every function here on the graphics owner's thread, from its progress step
-- and its target retirement, and nothing here makes a GLFW call.
--
-- = What makes a frame wanted
--
-- The graphics owner hands each step the latest render demand the main thread
-- published and the latest scene any application thread published, each with
-- the revision of its publication. A target is asked for a frame — the GPU
-- model's 'requestRender', which is also what restarts the idle backoff — when
--
-- * a demand publication it has not acted on is due: immediate, or with a
--   deadline that has come (one still ahead is kept, and asked for when it
--   comes);
-- * a scene publication it has not rendered arrives; or
-- * a target that has shown a frame before can no longer be showing the
--   latest one: its active swapchain generation is not the one its last
--   presentation went to, or it has become eligible again after a suspension.
--
-- Nothing else asks for a frame. In particular a target nobody asked a frame
-- of is never rendered to, however its generations change, so a host whose
-- application publishes neither demand nor a scene presents nothing.
--
-- = Rendering one frame
--
-- A target the model says wants a frame — render demand, admitted and not
-- suspended — is offered one attempt per step, round-robin with the lead
-- rotating each step: an acquisition with a zero timeout, then the renderer
-- recording the frame between the transition into rendering and the one to
-- presentation, then one submission and one presentation. An acquisition the
-- swapchain cannot answer yet is retried at the first interval of the model's
-- backoff schedule, anchored at the step's own instant, so work the step did
-- counts against it; a frame the renderer or the recording refused, or whose
-- submission had no effect, is skipped, and one whose presentation enqueued
-- nothing is closed unpresented. Every native effect's bookkeeping is the
-- frames module's own.
--
-- = Polling completion
--
-- A fence is asked only when the model's own schedule says a poll is due —
-- 'progressDeadline', which leaves render demand out — or when a frame is to
-- be attempted this step and the slots it needs may be waiting on one. An
-- owner round that something unrelated woke asks no fence, and takes no model
-- turn that would move the schedule on.
--
-- = Retirement
--
-- A target that begins retiring is closed in the model at once — which drops
-- its render demand and restarts the schedule — and its frames are closed:
-- acquired ones skipped, submitted ones closed unpresented. Its retirement is
-- owed ('RetirementOwed') until every frame and presentation of it has gone on
-- its own evidence; only then are its synchronization, its frame storages,
-- its generations and its surface destroyed. After the device's loss nothing
-- is waited for: the frames let go of what only the lost device could have
-- discharged.
--
-- = State
--
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
-- | State               | Owner     | Readers and writers                | Thread | Lifetime                     | Reset or disposal            |
-- +=====================+===========+====================================+========+==============================+==============================+
-- | The recording and   | This      | Made by the first frame attempted, | Owner  | The first attempt or action  | 'retireRendering', before    |
-- | the frames          | module    | or the first owner-thread action,  |        | after the device exists      | the device is destroyed      |
-- |                     |           | once the device exists; read by    |        | until whole-owner retirement |                              |
-- |                     |           | every function here                |        |                              |                              |
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
-- | Per-target records  | This      | Written by the step, retirement    | Owner  | A target's first render      | Removed by                   |
-- |                     | module    | preparation and retirement; read   |        | request until its retirement | 'retireTargetRendering'      |
-- |                     |           | by the deadline                    |        |                              |                              |
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
-- | The revisions acted | This      | The step alone                     | Owner  | The owner's run              | Never reset: revisions only  |
-- | on, and a demand    | module    |                                    |        |                              | rise                         |
-- | deadline ahead      |           |                                    |        |                              |                              |
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
-- | The construction's  | This      | 'confined' keeps the first escaped | Owner  | The owner's run              | Cleared each time the        |
-- | escape record       | module    | failure; an owner-thread action's  |        |                              | construction is lent         |
-- |                     |           | runner reads it                    |        |                              |                              |
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering
  ( -- * The native layers
    RenderingOps (..)

    -- * The renderer
  , VulkanRenderer (..)
  , FrameRequest (..)
  , clearRenderer

    -- * Consumer construction (VK-19)
  , Construction
  , Constructed
  , constructPipelineLayout
  , constructPipelineLayoutWith
  , constructPipeline
  , constructPipelineWith
  , replaceConstructedPipeline
  , constructRing
  , constructPipelineLayoutFor
  , constructCheckedPipeline
  , constructBlendedCheckedPipeline
  , replaceConstructedCheckedPipeline
  , constructBuffer
  , constructImage
  , releaseConstructed
  , constructFramelessBatch
  , constructReadback
  , readConstructedReadback
  , constructTextureTable
  , constructTablePipelineLayout
  , registerConstructedTexture
  , swapConstructedTexture
  , releaseConstructedTexture
  , readConstructedTable
  , lendConstruction
  , framelessScoped
  , constructionEscaped

    -- * Observing frames
  , FrameEvent (..)
  , FrameObserver
  , noFrameObserver

    -- * The rendering
  , Rendering
  , newRendering
  , StepInputs (..)
  , StepPlan (..)
  , planStep
  , requestPublished
  , renderDue
  , settleCaptures
  , reclaimReleased
  , renderingDeadline
  , pollDue

    -- * Uploads (GRS-6)
  , UploadsUnavailable (..)
  , makeRenderingUploads
  , progressRenderingUploads
  , refreshRenderingTable
  , renderingUploadsWaiting
  , submitRenderingUpload
  , cancelRenderingUpload

    -- * Retirement
  , prepareTargetRetirement
  , retireTargetRendering
  , endCaptures
  , failRenderingSwaps
  , retireRendering

    -- * Failures
  , FrameStorageRefused (..)
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, stateTVar, writeTVar)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , onException
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (forM, forM_, unless, void, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import Data.Foldable (for_)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Time (Instant, addDuration, deadlineReached)
import Hetoimasia.GPU.Model
  ( GpuModel
  , NextTurn (..)
  , Outcome (..)
  , PresentOutcome
  , TargetPhase (..)
  , TargetView (..)
  , closeTarget
  , deviceLossObserved
  , disposalEligible
  , modelBudgets
  , progressDeadline
  , requestRender
  , targetView
  )
import Hetoimasia.GPU.Model.Budget (backoffSchedule, frameSlotLimit)
import Hetoimasia.GPU.Model.Identity (FrameSlotId, GenerationId, HoldSubject (..), ImageId, PresentationId, SubmissionId, TargetId, imageGeneration, presentationTarget, frameTarget)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Capture
  ( CaptureOutcome (..)
  , CapturedFrame (..)
  , Captures
  , Presented (..)
  , Stage (..)
  , Withheld (..)
  , associateCapture
  , claimableFor
  , outstanding
  , outstandingFor
  , presentCapture
  , settleCapture
  , withholdAll
  )
import Hetoimasia.GPU.Vulkan.Native.Frames
  ( Acquisition (..)
  , FrameOps
  , FrameStanding (..)
  , Frames
  , OwnedFrame (..)
  , PendingReason
  , PresentationStanding (..)
  , Presented (..)
  , Progress (..)
  , Submitted (..)
  , FramelessScope
  , awaitFrames
  , closeTargetFrames
  , closeUnpresentedFrame
  , drainWaitLimit
  , newFrames
  , readFramelessSubmissions
  , recordFramelessIn
  , retireFrameless
  , withFramelessScope
  , presentFrame
  , progressFrames
  , readFrameStandings
  , readPresentations
  , retireTargetFrames
  , skipFrame
  , submitFrames
  , tryAcquireFrame
  )
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( GenerationView (..)
  , Generations
  , StepSummary (..)
  , TargetGenerationsView (..)
  , readTargetGenerations
  , stepGenerations
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent, SurfaceFormat (..), imageUsageTransferSource)
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( Buffer
  , BufferDescription
  , ClearColor
  , FrameStorage
  , Image
  , ImageDescription
  , ImageLayout (..)
  , ManagedStanding (..)
  , ManagedView (..)
  , Pipeline
  , PipelineLayout
  , PipelineShaders
  , PushConstantRange
  , RingSize
  , VertexInput
  , BatchTicket
  , Readback
  , Recorder
  , Recording
  , RecordingOps
  , Refusal (..)
  , beginRendering
  , copyToReadback
  , createBuffer
  , createFrameStorage
  , createImage
  , createPipeline
  , createPipelineLayout
  , createPipelineLayoutWith
  , createPipelineWith
  , createReadback
  , createRing
  , CheckedShaders
  , createCheckedPipeline
  , createPipelineLayoutFor
  , replaceCheckedPipeline
  , disposeResources
  , endRendering
  , newRecording
  , readManaged
  , readReadback
  , readbackBytesFor
  , recordFrame
  , releaseManaged
  , replacePipeline
  , retireRecording
  , transitionImage
  , createBlendedCheckedPipeline
  , PipelineBlend
  )
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( Checkpoint (..)
  , Roots
  , TerminalReport (..)
  , checkpointRoots
  , readRootsDevice
  , readRootsModel
  , readRootsTerminal
  , stateRootsModel
  )
import Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( TableConfig
  , TableView
  , TextureHandle
  , createTablePipelineLayout
  , createTextureTable
  , readTable
  , refreshTextureTable
  , registerTexture
  , releaseTexture
  , SwapTicket
  , failPendingSwaps
  , swapTexture
  )
import Hetoimasia.GPU.Vulkan.Native.Uploads
  ( CancelRefusal (CancelUnknown)
  , UploadConfig
  , UploadProgress (..)
  , UploadRefusal
  , UploadRequest
  , UploadTicket
  , Uploads
  , cancelUpload
  , closeUploads
  , newUploads
  , progressUploads
  , retireUploads
  , submitUploadGated
  , uploadsWaiting
  )
import Hetoimasia.Runtime.GLFW (AttachmentId, OwnerDemand (..))

-- ---------------------------------------------------------------------------
-- The native layers

-- | The native layers rendering adds to the roots': the recording's, made
-- from the session's physical device once it has been selected, and the
-- frames'. Production supplies "Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan"
-- and "Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan"; the headless examples
-- supply stand-ins.
data RenderingOps phys dev cmd = RenderingOps
  { renderingRecordingOps ∷ phys → IO (RecordingOps dev cmd)
  , renderingFrameOps ∷ FrameOps dev cmd
  }

-- ---------------------------------------------------------------------------
-- The renderer

-- | What one frame is being recorded for.
data FrameRequest = FrameRequest
  { requestAttachment ∷ !AttachmentId
  , requestTarget ∷ !TargetId
  , requestFrame ∷ !FrameSlotId
  , requestImage ∷ !ImageId
  , requestExtent ∷ !SurfaceExtent
    -- ^ The extent of the generation the image belongs to.
  , requestFormat ∷ !Word32
    -- ^ The image's Vulkan color format: what a pipeline bound in the frame
    -- must have been built for.
  , requestSceneRevision ∷ !Natural
    -- ^ The revision of the scene being rendered, zero for the owner's
    -- initial one.
  }
  deriving (Eq, Show)

-- | How a frame of the scene is recorded, on the graphics owner's thread.
--
-- The request describes the frame — its target, its slot, its image, and the
-- image's extent and color format — before anything of the renderer's is
-- recorded. The image is already in the color-attachment layout when it is
-- called, and is transitioned for presentation (or, for a capture, for the
-- copy) after it returns: the renderer begins dynamic rendering, records into
-- it and ends it. It may construct, replace and release managed pipelines and
-- layouts through the 'Construction' it is lent, and bind them in the frame.
-- An answer of 'Left', or a command it left refused, skips the frame; nothing
-- it recorded is submitted. It runs exactly once per frame and must return
-- finitely.
newtype VulkanRenderer scene = VulkanRenderer
  { renderScene
      ∷ ∀ q inst msgr phys dev cmd
       . scene
      → FrameRequest
      → Construction q inst msgr phys dev cmd
      → Recorder q inst msgr phys dev cmd
      → IO (Either Refusal ())
  }

-- | A renderer that clears each frame to the color it computes and draws
-- nothing else.
clearRenderer ∷ (scene → FrameRequest → ClearColor) → VulkanRenderer scene
clearRenderer color = VulkanRenderer $ \scene request _ recorder →
  beginRendering recorder (color scene request) `andThen` endRendering recorder

andThen ∷ IO (Either Refusal ()) → IO (Either Refusal ()) → IO (Either Refusal ())
andThen first second = first >>= either (pure . Left) (const second)

-- ---------------------------------------------------------------------------
-- Consumer construction

-- | The session's managed construction, lent to the renderer with each frame
-- (VK-19): the pipeline layouts and graphics pipelines it builds over
-- embedded shaders, and releases or replaces, and the buffers and images of
-- the engine's kinds it creates and releases (GRS-2), live in the session's
-- recording beside the host's own resources and are never native handles.
--
-- Every call is the graphics owner's: one from any other thread is refused
-- ('RefusedNotOwner') before anything native is done, as is one after the
-- session has failed. A construction that raised before it committed any
-- generation, with the session still running, left nothing: its creation made
-- nothing and gave its reservation back. It is answered
-- 'RefusedConstructionFailed', so it skips only the frame whose renderer
-- answers it; the allocation recovery a construction runs retries it without
-- calling the renderer again. One that raised after committing a generation —
-- a replacement whose new pipeline could not be named has released that
-- generation and already replaced the old one — has an effect the renderer
-- cannot see, so it is raised as it was and ends the owner's run, as do a
-- cancellation and a failure the session latched — the device's loss, an
-- uncertain effect, a failed cleanup — with the session's primary.
--
-- A handle outlives the frame it was made in. Whatever the renderer has not
-- released is released and destroyed on the owner's thread before the device,
-- on the host's normal and terminal exits alike; a batch still in flight keeps
-- what it recorded until its own references end.
--
-- The same construction is lent to an owner-thread action
-- ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Actions") with no frame at all, and
-- what it builds lives, and is released, exactly as the renderer's does.
data Construction q inst msgr phys dev cmd = Construction
  { constructionRecording ∷ !(Recording q inst msgr phys dev cmd)
  , constructionRoots ∷ !(Roots q inst msgr phys dev)
  , constructionEscape ∷ !(TVar (Maybe (ExceptionWithContext SomeException)))
    -- ^ The first failure a call raised that the owner's run must end with —
    -- one that committed a generation, or that the session latched — rather
    -- than answering it. An owner-thread action's runner raises it on however
    -- the action handled it.
  , constructionFrameless ∷ !(Maybe (FramelessScope q inst msgr phys dev cmd))
    -- ^ The owner-thread action's frame-less scope (GRS-12): 'Nothing' for a
    -- renderer's frame, which records no frame-less batch.
  , constructionUploads ∷ !(TVar (UploadsStanding q inst msgr phys dev cmd))
    -- ^ The session's uploads, which the texture table's placeholder is
    -- uploaded through (GRS-7).
  }

-- | What the renderer can release: the handles it can construct.
class Constructed handle where
  release ∷ Recording q inst msgr phys dev cmd → handle → IO (Either Refusal ())

instance Constructed PipelineLayout where
  release = releaseManaged

instance Constructed Pipeline where
  release = releaseManaged

instance Constructed Buffer where
  release = releaseManaged

instance Constructed Image where
  release = releaseManaged

instance Constructed Readback where
  release = releaseManaged

-- | A pipeline layout with no descriptor sets and no push constants.
constructPipelineLayout ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal PipelineLayout)
constructPipelineLayout construction = confined construction (createPipelineLayout (constructionRecording construction))

-- | A pipeline layout with no descriptor sets and these push-constant ranges
-- (GRS-4), validated against the device and Vulkan's rules before anything is
-- created.
constructPipelineLayoutWith ∷ Construction q inst msgr phys dev cmd → [PushConstantRange] → IO (Either Refusal PipelineLayout)
constructPipelineLayoutWith construction ranges = confined construction (createPipelineLayoutWith (constructionRecording construction) ranges)

-- | A graphics pipeline over the layout, as 'constructPipeline' makes one, with
-- this vertex input (GRS-4), validated against the device and Vulkan's rules
-- before anything is created.
constructPipelineWith
  ∷ Construction q inst msgr phys dev cmd → PipelineLayout → PipelineShaders → Word32 → VertexInput → IO (Either Refusal Pipeline)
constructPipelineWith construction layout shaders format input =
  confined construction (createPipelineWith (constructionRecording construction) layout shaders format input)

-- | Make the session's one shared ring (GRS-4, D-33), of the size the
-- application configured and validated once: a host-visible buffer batches
-- claim regions of while they record, write, and bind as vertex, index or
-- instance data. A second is refused. The ring lives until the host's exit
-- releases it with everything else; no handle to it is lent.
constructRing ∷ Construction q inst msgr phys dev cmd → RingSize → IO (Either Refusal ())
constructRing construction size = confined construction (createRing (constructionRecording construction) size)

-- | A pipeline layout with exactly the push-constant ranges these checked
-- shaders' descriptions need (GRS-16).
constructPipelineLayoutFor ∷ Construction q inst msgr phys dev cmd → CheckedShaders → IO (Either Refusal PipelineLayout)
constructPipelineLayoutFor construction shaders = confined construction (createPipelineLayoutFor (constructionRecording construction) shaders)

-- | A graphics pipeline from checked shaders (GRS-16): its vertex input is the
-- vertex shader's description's, and a layout declaring other ranges than
-- the descriptions need, or stages whose descriptions disagree, is refused
-- before anything is created.
constructCheckedPipeline
  ∷ Construction q inst msgr phys dev cmd → PipelineLayout → CheckedShaders → Word32 → IO (Either Refusal Pipeline)
constructCheckedPipeline construction layout shaders format =
  confined construction (createCheckedPipeline (constructionRecording construction) layout shaders format)

-- | A graphics pipeline from checked shaders with a declared blend (GRS-8),
-- checked as 'constructCheckedPipeline' checks them.
constructBlendedCheckedPipeline
  ∷ Construction q inst msgr phys dev cmd → PipelineLayout → CheckedShaders → Word32 → PipelineBlend → IO (Either Refusal Pipeline)
constructBlendedCheckedPipeline construction layout shaders format blend =
  confined construction (createBlendedCheckedPipeline (constructionRecording construction) layout shaders format blend)

-- | A new generation of a pipeline from checked shaders, checked as
-- 'constructCheckedPipeline' checks them; the old one is released.
replaceConstructedCheckedPipeline
  ∷ Construction q inst msgr phys dev cmd → Pipeline → PipelineLayout → CheckedShaders → Word32 → IO (Either Refusal Pipeline)
replaceConstructedCheckedPipeline construction old layout shaders format =
  confined construction (replaceCheckedPipeline (constructionRecording construction) old layout shaders format)

-- | A graphics pipeline over the layout for dynamic rendering into this color
-- format — a frame's 'requestFormat' — drawing triangle lists with no vertex
-- input, and a dynamic viewport and scissor.
constructPipeline
  ∷ Construction q inst msgr phys dev cmd → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
constructPipeline construction layout shaders format =
  confined construction (createPipeline (constructionRecording construction) layout shaders format)

-- | A new generation of a pipeline, over the given layout. The old one is
-- released: nothing records it again, and a batch that recorded it keeps it,
-- and its layout, until that batch's references end.
replaceConstructedPipeline
  ∷ Construction q inst msgr phys dev cmd → Pipeline → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
replaceConstructedPipeline construction old layout shaders format =
  confined construction (replacePipeline (constructionRecording construction) old layout shaders format)

-- | A buffer of one of the engine's kinds and a size in bytes. The kind fixes
-- its usage and the memory it lives in; nothing writes it yet.
constructBuffer ∷ Construction q inst msgr phys dev cmd → BufferDescription → IO (Either Refusal Buffer)
constructBuffer construction description = confined construction (createBuffer (constructionRecording construction) description)

-- | An image of one of the engine's kinds — a texture, a depth target or a
-- color target — with its format, extent and mip levels, and its one owned
-- view. A format the kind does not take or the device does not support for
-- it is refused before anything is created; nothing writes it yet.
constructImage ∷ Construction q inst msgr phys dev cmd → ImageDescription → IO (Either Refusal Image)
constructImage construction description = confined construction (createImage (constructionRecording construction) description)

-- | A host-visible readback buffer of this many bytes, which a batch can copy
-- a color target into (GRS-5) and the owner reads once that batch's
-- submission has completed ('readConstructedReadback').
constructReadback ∷ Construction q inst msgr phys dev cmd → Natural → IO (Either Refusal Readback)
constructReadback construction bytes = confined construction (createReadback (constructionRecording construction) bytes)

-- | Read bytes out of a readback buffer, from an offset: exposed only with
-- completion evidence — the batch that copied into it was submitted, and that
-- submission has completed — and never while a batch or a submission still
-- holds it.
readConstructedReadback ∷ Construction q inst msgr phys dev cmd → Readback → Natural → Natural → IO (Either Refusal ByteString.ByteString)
readConstructedReadback construction readback offset size = confined construction (readReadback (constructionRecording construction) readback offset size)

-- | Make the session's texture table (GRS-7) from a validated
-- configuration: its samplers, its two descriptor sets, its version ring and
-- slot 0's placeholder, whose upload goes through the session's uploads — so
-- the host must configure them ('vulkanUploads'), and the table binds once
-- that upload completes. A second is refused.
constructTextureTable ∷ Construction q inst msgr phys dev cmd → TableConfig → IO (Either Refusal ())
constructTextureTable construction config =
  readTVarIO (constructionUploads construction) >>= \case
    UploadsMade uploads → confined construction (createTextureTable (constructionRecording construction) uploads config)
    _ → pure (Left (RefusedIllegal "a texture table in a session whose uploads are not made: the host configures them with vulkanUploads"))

-- | A pipeline layout holding the texture table: both of its sets, the
-- checked shaders' push-constant ranges, and the offset of the sampler index
-- 'selectSampler' pushes.
constructTablePipelineLayout ∷ Construction q inst msgr phys dev cmd → CheckedShaders → Word32 → IO (Either Refusal PipelineLayout)
constructTablePipelineLayout construction shaders offset = confined construction (createTablePipelineLayout (constructionRecording construction) shaders offset)

-- | Register an uploaded texture with the table and answer its stable
-- handle: slot 0's placeholder until its upload completes, its own slot in
-- versions published after that. The table holds the image from now on.
registerConstructedTexture ∷ Construction q inst msgr phys dev cmd → Image → IO (Either Refusal TextureHandle)
registerConstructedTexture construction image = confined construction (registerTexture (constructionRecording construction) image)

-- | Ask a live handle to show a replacement texture, filled by an admitted
-- or completed upload (GRS-9): the handle keeps resolving to what it shows
-- until that upload completes, and to the replacement in versions published
-- after; the replaced texture is released then. The table holds the
-- replacement from now on, and the ticket reports where the swap stands.
swapConstructedTexture ∷ Construction q inst msgr phys dev cmd → TextureHandle → Image → IO (Either Refusal SwapTicket)
swapConstructedTexture construction handle image = confined construction (swapTexture (constructionRecording construction) handle image)

-- | Release a texture's handle: versions published from now on no longer
-- map it, and its image is released once no batch's version does.
releaseConstructedTexture ∷ Construction q inst msgr phys dev cmd → TextureHandle → IO (Either Refusal ())
releaseConstructedTexture construction handle = confined construction (releaseTexture (constructionRecording construction) handle)

-- | The texture table as it stands, if the session made one.
readConstructedTable ∷ Construction q inst msgr phys dev cmd → IO (Maybe TableView)
readConstructedTable construction = atomically (readTable (constructionRecording construction))

-- | Release a handle the renderer constructed: nothing records it again, and a
-- batch that recorded it keeps it until that batch's references end. The
-- owner destroys it once nothing holds it.
releaseConstructed ∷ Constructed handle ⇒ Construction q inst msgr phys dev cmd → handle → IO (Either Refusal ())
releaseConstructed construction handle = confined construction (release (constructionRecording construction) handle)

-- | Record one frame-less batch (GRS-12) inside an owner-thread action: a
-- batch that belongs to no frame, recorded with the same recorder and checks
-- as a frame's — transitions and boundary barriers included — but with no
-- swapchain image, and answered with its 'BatchTicket'. It is submitted, with
-- the action's other sealed frame-less batches in the order they were sealed,
-- when the action returns, and discarded if the action raises; one left
-- partial is discarded. The ticket reports its completion. A renderer's
-- frame records none: it is refused there as unsupported. Like every
-- construction it is refused once the session has failed; what the consumer
-- raises is the action's to handle.
constructFramelessBatch
  ∷ Construction q inst msgr phys dev cmd
  → (Recorder q inst msgr phys dev cmd → IO a)
  → IO (Either Refusal (BatchTicket, a))
constructFramelessBatch construction consumer = case constructionFrameless construction of
  Nothing → pure (Left (RefusedUnsupported "a frame-less batch outside an owner-thread action"))
  Just scope →
    checkpointRoots (constructionRoots construction) >>= \case
      CheckpointFailed primary → pure (Left (RefusedSessionFailed primary))
      CheckpointPending → pure (Left RefusedDiagnosticPending)
      CheckpointClear → recordFramelessIn scope consumer

-- | Run one construction behind the session's checkpoint, answering a
-- synchronous failure that left nothing as the refusal it is. Only a failure
-- that committed no new generation, and that the checkpoint finds nothing
-- behind, is answered: one that committed a generation first — whatever
-- became of it — whatever the session latched on its way out, and every
-- cancellation, is raised as it was, and the first two are recorded as having
-- escaped the construction ('constructionEscaped').
confined ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal a) → IO (Either Refusal a)
confined construction action =
  checkpointRoots roots >>= \case
    CheckpointFailed primary → pure (Left (RefusedSessionFailed primary))
    CheckpointPending → pure (Left RefusedDiagnosticPending)
    CheckpointClear → do
      before ← generations
      tryWithContext action >>= \case
        Right answer → pure answer
        Left failure@(ExceptionWithContext _ exception)
          | isAsynchronous exception → rethrowIO (failure ∷ ExceptionWithContext SomeException)
          | otherwise → do
              after ← generations
              checkpointRoots roots >>= \case
                CheckpointClear
                  | all (`elem` before) after → pure (Left (RefusedConstructionFailed (Text.pack (displayException exception))))
                _ → do
                  atomically (modifyTVar' (constructionEscape construction) (maybe (Just failure) Just))
                  rethrowIO failure
  where
    roots = constructionRoots construction
    generations = atomically (map viewResource <$> readManaged (constructionRecording construction))

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

-- | The first failure a call on this construction raised, since it was lent,
-- that the owner's run must end with.
constructionEscaped ∷ Construction q inst msgr phys dev cmd → STM (Maybe (ExceptionWithContext SomeException))
constructionEscaped = readTVar . constructionEscape

-- | The session's construction, lent on the owner's thread outside any frame
-- — to an owner-thread action — with nothing yet escaped from it. The
-- recording is made here if no frame has made it yet; there is none while the
-- session has no device.
lendConstruction ∷ Rendering q inst msgr phys dev cmd → IO (Maybe (Construction q inst msgr phys dev cmd))
lendConstruction rendering =
  live rendering >>= \case
    Nothing → pure Nothing
    Just made → do
      atomically (writeTVar (renderingEscape rendering) Nothing)
      pure (Just (construct rendering made))

-- | The construction over the session's recording.
construct ∷ Rendering q inst msgr phys dev cmd → Live q inst msgr phys dev cmd → Construction q inst msgr phys dev cmd
construct rendering made = Construction (liveRecording made) (renderingRoots rendering) (renderingEscape rendering) Nothing (renderingUploads rendering)

-- | Run an owner-thread action's body with the construction it was lent and a
-- frame-less scope over the session's frames (GRS-12): the frame-less batches
-- it records are submitted when it returns, and discarded if it raises.
framelessScoped
  ∷ Rendering q inst msgr phys dev cmd
  → Construction q inst msgr phys dev cmd
  → (Construction q inst msgr phys dev cmd → IO r)
  → IO r
framelessScoped rendering construction body =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → body construction
    Just made → withFramelessScope (liveFrames made) (\scope → body construction {constructionFrameless = Just scope})

-- ---------------------------------------------------------------------------
-- Observing frames

-- | Something the owner did with a frame, or observed about one, in the order
-- it happened. Each is reported on the graphics owner's thread as it happens:
-- a presentation's request before its call and its return after it, and a
-- present fence's completion when a poll observed it — independently of any
-- call's return.
data FrameEvent
  = FrameAcquired !AttachmentId !FrameSlotId !ImageId
  | FramePending !AttachmentId !PendingReason
  | FrameSubmitted !AttachmentId !FrameSlotId !SubmissionId
  | FramePresentRequested !AttachmentId !FrameSlotId !ImageId !Natural
    -- ^ About to present, with the scene revision the frame rendered.
  | FramePresented !AttachmentId !FrameSlotId !PresentationId !PresentOutcome
    -- ^ The present call returned with a presentation enqueued. It proves the
    -- request was admitted, nothing more.
  | FrameAbandoned !AttachmentId !FrameSlotId !Text
  | SubmissionCompleted !SubmissionId
  | PresentationRetired !PresentationId
    -- ^ The presentation's present fence was observed signalled.
  deriving (Eq, Show)

-- | Where frame events go. It must not raise and should not block: it runs on
-- the graphics owner's thread, between native calls.
type FrameObserver = FrameEvent → IO ()

noFrameObserver ∷ FrameObserver
noFrameObserver _ = pure ()

-- ---------------------------------------------------------------------------
-- The rendering

data Live q inst msgr phys dev cmd = Live
  { liveRecording ∷ !(Recording q inst msgr phys dev cmd)
  , liveFrames ∷ !(Frames q inst msgr phys dev cmd)
  }

-- | One target as rendering holds it.
data TargetRendering = TargetRendering
  { targetStorages ∷ ![FrameStorage]
  , targetRetryAt ∷ !(Maybe Instant)
    -- ^ When a frame that could not be made is tried again, unless a fresh
    -- request comes first.
  , targetShown ∷ !(Maybe GenerationId)
    -- ^ The generation the target's last presentation went to, once it has
    -- presented one.
  , targetEligible ∷ !Bool
    -- ^ Whether it was eligible at the last step.
  , targetClosing ∷ !Bool
  , targetDemandSeen ∷ !Natural
    -- ^ The latest demand publication a step has considered for it.
  , targetSceneSeen ∷ !Natural
    -- ^ The latest scene publication a step has considered for it.
  , targetAsked ∷ !(Maybe GenerationId)
    -- ^ The active generation when it was last asked for a frame: a
    -- generation it moved to is one request, however many rounds pass before
    -- a frame of it is presented.
  }

freshTarget ∷ TargetRendering
freshTarget = TargetRendering [] Nothing Nothing False False 0 0 Nothing

-- | Whether a target that has presented before now has an active generation
-- it neither presented to nor was asked a frame of since.
movedTo ∷ TargetRendering → Maybe TargetGenerationsView → Bool
movedTo record view = case view >>= viewActive of
  Nothing → False
  active → active /= targetShown record && active /= targetAsked record

-- | The rendering of one graphics session.
data Rendering q inst msgr phys dev cmd = Rendering
  { renderingRoots ∷ !(Roots q inst msgr phys dev)
  , renderingGenerations ∷ !(Generations q inst msgr phys dev)
  , renderingOps ∷ !(RenderingOps phys dev cmd)
  , renderingLive ∷ !(TVar (Maybe (Live q inst msgr phys dev cmd)))
  , renderingTargets ∷ !(TVar (Map TargetId TargetRendering))
  , renderingDemandSeen ∷ !(TVar Natural)
    -- ^ The latest demand publication whose deadline has been held.
  , renderingDemandAt ∷ !(TVar (Maybe Instant))
  , renderingCursor ∷ !(TVar Natural)
  , renderingObserver ∷ !FrameObserver
  , renderingCaptures ∷ !Captures
    -- ^ The verification captures requested of the session's targets
    -- ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Capture"), whose readback buffers
    -- this module makes, releases and destroys.
  , renderingEscape ∷ !(TVar (Maybe (ExceptionWithContext SomeException)))
    -- ^ The lent construction's record of a failure that escaped it.
  , renderingUploads ∷ !(TVar (UploadsStanding q inst msgr phys dev cmd))
    -- ^ The session's uploads (GRS-6): made by the owner's progress once the
    -- recording and the frames exist; any thread admits into them.
  }

-- | Where the session's uploads stand.
data UploadsStanding q inst msgr phys dev cmd
  = UploadsUnconfigured
    -- ^ The host configured none.
  | UploadsPending !UploadConfig
    -- ^ Configured, and not yet made: the device does not exist yet.
  | UploadsMade !(Uploads q inst msgr phys dev cmd)
  | UploadsRefused !Refusal
    -- ^ The device refused them: the turn budget holds no block row of its
    -- widest level, or the staging buffer could not be made.

newRendering
  ∷ Roots q inst msgr phys dev
  → Generations q inst msgr phys dev
  → RenderingOps phys dev cmd
  → FrameObserver
  → Captures
  → Maybe UploadConfig
  → IO (Rendering q inst msgr phys dev cmd)
newRendering roots generations ops observer captures uploads =
  Rendering roots generations ops
    <$> newTVarIO Nothing
    <*> newTVarIO Map.empty
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO 0
    <*> pure observer
    <*> pure captures
    <*> newTVarIO Nothing
    <*> newTVarIO (maybe UploadsUnconfigured UploadsPending uploads)

-- | The recording and the frames, made the first time they are needed once
-- the device exists, on the owner's thread, which is what makes it their
-- owner.
live ∷ Rendering q inst msgr phys dev cmd → IO (Maybe (Live q inst msgr phys dev cmd))
live rendering =
  readTVarIO (renderingLive rendering) >>= \case
    Just made → pure (Just made)
    Nothing →
      atomically (readRootsDevice (renderingRoots rendering)) >>= \case
        Nothing → pure Nothing
        Just (plan, _) → do
          ops ← renderingRecordingOps (renderingOps rendering) (planDevice plan)
          recording ← newRecording ops (renderingRoots rendering) (renderingGenerations rendering)
          frames ← newFrames (renderingFrameOps (renderingOps rendering)) recording
          let made = Live recording frames
          atomically (writeTVar (renderingLive rendering) (Just made))
          pure (Just made)

-- | A frame storage could not be made for a target's slot. It is raised, and
-- ends the owner's run like any other owner failure: a target whose slots
-- cannot be recorded into renders nothing.
data FrameStorageRefused = FrameStorageRefused !TargetId !Natural !Refusal
  deriving (Show)

instance Exception FrameStorageRefused

-- ---------------------------------------------------------------------------
-- The step

-- | What one owner step hands the rendering.
data StepInputs = StepInputs
  { inputsNow ∷ !Instant
  , inputsSceneRevision ∷ !Natural
  , inputsDemand ∷ !OwnerDemand
  , inputsDemandRevision ∷ !Natural
  , inputsTargets ∷ ![(TargetId, AttachmentId, Bool)]
    -- ^ Every target the owner constructed, with whether it is eligible to
    -- render now.
  , inputsCaptures ∷ ![AttachmentId]
    -- ^ The attachments a verification capture has just been requested of,
    -- each of which asks its target for a frame.
  }

-- | What the step owes before it renders.
data StepPlan = StepPlan
  { planPolled ∷ !Bool
    -- ^ Whether this step asked the fences, which a model turn must then
    -- anchor.
  , planDue ∷ ![(TargetId, AttachmentId)]
    -- ^ The targets to offer one frame each this step, in this step's order.
  }

-- | Fold the step's demand and scene into render requests, poll completion
-- if a poll is due or a frame is to be attempted, and say which targets are
-- offered a frame.
planStep ∷ Rendering q inst msgr phys dev cmd → StepInputs → IO StepPlan
planStep rendering inputs = do
  views ← atomically (mapM (\(target, _, _) → (,) target <$> readTargetGenerations (renderingGenerations rendering) target) (inputsTargets inputs))
  atomically $ do
    came ← foldPublications
    held ← readTVar (renderingTargets rendering)
    -- Each constructed target is asked for a frame by the publications it has
    -- not yet considered, so one published before the target could take it —
    -- a first redraw arriving with its handover — is still its request once
    -- it is constructed, and a stored deadline that comes is kept until a
    -- target exists to receive it.
    let demandDue = ownerDemandImmediate demand || maybe False (deadlineReached now) (ownerDemandDeadline demand)
        wanted =
          [ target
          | (target, attachment, eligible) ← inputsTargets inputs
          , let record = Map.findWithDefault freshTarget target held
          , not (targetClosing record)
          , came
              || attachment `elem` inputsCaptures inputs
              || (inputsDemandRevision inputs > targetDemandSeen record && demandDue)
              || inputsSceneRevision inputs > targetSceneSeen record
              || ( isJust (targetShown record)
                     && eligible
                     && (not (targetEligible record) || movedTo record (lookup target views >>= id))
                 )
          ]
    for_ wanted $ \target →
      stateRootsModel (renderingRoots rendering) $ \model → case requestRender target model of
        Admitted next → ((), next)
        _ → ((), model)
    -- A fresh request is an opportunity now: it supersedes a retry pending
    -- from a frame that could not be made.
    writeTVar (renderingTargets rendering) $
      foldl
        ( \records (target, _, eligible) →
            Map.alter
              ( Just
                  . ( \record →
                        record
                          { targetEligible = eligible
                          , targetDemandSeen = inputsDemandRevision inputs
                          , targetSceneSeen = inputsSceneRevision inputs
                          , targetRetryAt = if target `elem` wanted then Nothing else targetRetryAt record
                          , targetAsked = if target `elem` wanted then (lookup target views >>= id) >>= viewActive else targetAsked record
                          }
                    )
                  . maybe freshTarget id
              )
              target
              records
        )
        held
        (inputsTargets inputs)
  model ← atomically (readRootsModel (renderingRoots rendering))
  held ← readTVarIO (renderingTargets rendering)
  cursor ← atomically (stateTVar (renderingCursor rendering) (\at → (at, at + 1)))
  let due =
        rotated
          cursor
          [ (target, attachment)
          | (target, attachment, _) ← inputsTargets inputs
          , Just view ← [targetView target model]
          , viewTargetRenderDemand view
          , let record = Map.findWithDefault freshTarget target held
          , not (targetClosing record)
          , maybe True (deadlineReached now) (targetRetryAt record)
          ]
      polling = pollDue now model || not (null due)
  when polling (poll rendering now)
  pure (StepPlan polling due)
  where
    now = inputsNow inputs
    demand = inputsDemand inputs
    -- Holds a demand deadline still ahead, once per publication, and answers
    -- whether a held one has come. One publication can carry both parts — two
    -- windows, one asking now and one by a later deadline — and each is kept:
    -- the request now is due at once, and the deadline when it comes. A held
    -- deadline that comes while no target is constructed stays held.
    foldPublications = do
      seenDemand ← readTVar (renderingDemandSeen rendering)
      when (inputsDemandRevision inputs > seenDemand) $ do
        writeTVar (renderingDemandSeen rendering) (inputsDemandRevision inputs)
        for_ (ownerDemandDeadline demand) $ \at →
          unless (deadlineReached now at) $
            modifyTVar' (renderingDemandAt rendering) (Just . maybe at (min at))
      ahead ← readTVar (renderingDemandAt rendering)
      case ahead of
        Just at | deadlineReached now at, not (null (inputsTargets inputs)) → True <$ writeTVar (renderingDemandAt rendering) Nothing
        _ → pure False

-- | After the generations' step: ask a frame of every target that has
-- presented before and whose active generation that step published, beyond
-- those already due, and answer them to be offered one this same step. A
-- quiet target's replacement — the old generation disposed of and the new one
-- published in one step, with nothing left owed — would otherwise wait for an
-- unrelated publication, since the plan was made before the step. A target
-- already due is asked nothing more, but the generation it will now be
-- offered a frame of is recorded as asked, so a later round does not take it
-- for a fresh request and cut short the retry of a frame refused on it.
requestPublished
  ∷ Rendering q inst msgr phys dev cmd
  → [(TargetId, AttachmentId, Bool)]
  → [(TargetId, AttachmentId)]
  → IO [(TargetId, AttachmentId)]
requestPublished rendering targets due = do
  views ← atomically (mapM (\(target, _, _) → (,) target <$> readTargetGenerations (renderingGenerations rendering) target) targets)
  atomically $ do
    held ← readTVar (renderingTargets rendering)
    let active target = (lookup target views >>= id) >>= viewActive
        moved =
          [ (target, attachment)
          | (target, attachment, eligible) ← targets
          , target `notElem` map fst due
          , let record = Map.findWithDefault freshTarget target held
          , not (targetClosing record)
          , isJust (targetShown record)
          , eligible
          , movedTo record (lookup target views >>= id)
          ]
    for_ moved $ \(target, _) → do
      stateRootsModel (renderingRoots rendering) $ \model → case requestRender target model of
        Admitted next → ((), next)
        _ → ((), model)
      editTarget rendering target $ \record →
        record {targetRetryAt = Nothing, targetAsked = active target}
    for_ due $ \(target, _) →
      for_ (active target) $ \generation →
        editTarget rendering target (\record → record {targetAsked = Just generation})
    pure moved

-- | Whether the model's own schedule says a completion poll is due now.
pollDue ∷ Instant → GpuModel → Bool
pollDue now model = case progressDeadline model of
  TurnNow → True
  TurnAt at → deadlineReached now at
  TurnUnschedulable → True
  NoTurnNeeded → False

-- | Ask the fences, once, and report what was observed.
poll ∷ Rendering q inst msgr phys dev cmd → Instant → IO ()
poll rendering now =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure ()
    Just made → do
      progress ← progressFrames (liveFrames made) now
      for_ (progressCompleted progress) (renderingObserver rendering . SubmissionCompleted)
      for_ (progressRetired progress) (renderingObserver rendering . PresentationRetired)

-- | Offer each due target one frame of the scene. Answers whether any frame
-- was presented.
--
-- A frame acquired for a target whose attachment has a verification capture
-- outstanding is that capture's frame, whatever becomes of it. Its commands
-- end, after the renderer's, with the image's transition to the transfer
-- source, the copy into a readback buffer made for it with the write made
-- visible to the host, and the transition to presentation — or, where its
-- generation is not a transfer source or no buffer can be made, the capture
-- is settled without bytes and the frame recorded as any other. A frame given
-- up after its acquisition settles its capture without bytes.
renderDue
  ∷ Rendering q inst msgr phys dev cmd
  → VulkanRenderer scene
  → Instant
  → scene
  → Natural
  → [(TargetId, AttachmentId)]
  → IO Bool
renderDue rendering renderer now scene revision due =
  if null due
    then pure False
    else
      live rendering >>= \case
        Nothing → False <$ for_ due (\(target, _) → retryAfterPending target)
        Just made → or <$> forM due (renderOne made)
  where
    observe = renderingObserver rendering
    captures = renderingCaptures rendering
    renderOne made (target, attachment) = do
      ready ← storagesFor made target
      if not ready
        then False <$ retryAfterPending target
        else do
          -- The request this frame will be for is the one outstanding before
          -- it is asked for: one admitted while the acquisition is under way
          -- is the next frame's.
          claimed ← atomically (claimableFor captures attachment)
          tryAcquireFrame (liveFrames made) target >>= \case
            Right (AcquisitionOwned owned) → do
              atomically (editTarget rendering target (\record → record {targetRetryAt = Nothing}))
              -- The first frame acquired once a capture is outstanding is its
              -- frame, whatever becomes of it. It is associated before the
              -- acquisition is reported, so a request made from the report is
              -- a later frame's.
              asked ← case claimed of
                Nothing → pure False
                Just ticket → atomically (associateCapture captures attachment ticket (ownedFrame owned))
              observe (FrameAcquired attachment (ownedFrame owned) (ownedImage owned))
              described ← describeImage target (ownedImage owned)
              case described of
                Nothing → False <$ abandon made attachment owned (Captured asked Nothing) "its generation is no longer tracked"
                Just image → do
                  capture ← if asked then prepareCapture made attachment owned image else pure (Captured False Nothing)
                  recordOne made target attachment owned image capture
            Right (AcquisitionPending reason) → do
              observe (FramePending attachment reason)
              False <$ retryAfterPending target
            Right _ → False <$ retryAfterPending target
            Left _ → False <$ retryAfterPending target
    retryAfterPending target = do
      model ← atomically (readRootsModel (renderingRoots rendering))
      let first = case backoffSchedule (modelBudgets model) of
            interval : _ → Just interval
            [] → Nothing
          at = first >>= either (const Nothing) Just . addDuration now
      atomically (editTarget rendering target (\record → record {targetRetryAt = at}))
    storagesFor made target = do
      held ← Map.findWithDefault freshTarget target <$> readTVarIO (renderingTargets rendering)
      if not (null (targetStorages held))
        then pure True
        else do
          model ← atomically (readRootsModel (renderingRoots rendering))
          let slots = frameSlotLimit (modelBudgets model)
          made' ← forM [0 .. slots - 1] $ \slot →
            createFrameStorage (liveRecording made) target slot >>= \case
              Right storage → pure storage
              Left refusal → throwIO (FrameStorageRefused target slot refusal)
          atomically (editTarget rendering target (\record → record {targetStorages = made'}))
          pure True
    describeImage target image = do
      view ← atomically (readTargetGenerations (renderingGenerations rendering) target)
      pure $ do
        generations ← viewGenerations <$> view
        generation ← find ((== imageGeneration image) . viewGeneration) generations
        let plan = viewPlan generation
        pure (FrameImage (planExtent plan) (surfaceFormat (planFormat plan)) (planUsage plan .&. imageUsageTransferSource /= 0))
    -- A readback buffer for the capture, or the capture settled without bytes
    -- and the frame recorded as any other — no longer a capture's, so nothing
    -- that later becomes of it can settle a newer request.
    prepareCapture made attachment owned image
      | not (imageCapturable image) = Captured False Nothing <$ withhold attachment (WithheldUnsupported (imageGeneration (ownedImage owned)))
      | otherwise = do
          let bytes = readbackBytesFor (imageExtent image)
          confined (construct rendering made) (createReadback (liveRecording made) bytes) >>= \case
            Left refusal → Captured False Nothing <$ withhold attachment (WithheldNoReadback refusal)
            Right readback → pure (Captured True (Just (readback, bytes)))
    withhold attachment reason = atomically (settleCapture captures attachment (CaptureWithheld attachment reason))
    recordOne made target attachment owned image capture = do
      let request = FrameRequest attachment target (ownedFrame owned) (ownedImage owned) (imageExtent image) (imageFormat image) revision
          construction = construct rendering made
          finish recorder = case capturedWork capture of
            Nothing → transitionImage recorder LayoutColorAttachment LayoutPresentSource
            Just (readback, _) →
              transitionImage recorder LayoutColorAttachment LayoutTransferSource
                `andThen` copyToReadback recorder readback
                `andThen` transitionImage recorder LayoutTransferSource LayoutPresentSource
      recorded ←
        recordFrame (liveRecording made) (ownedFrame owned) (\recorder →
          transitionImage recorder LayoutUndefined LayoutColorAttachment
            `andThen` renderScene renderer scene request construction recorder
            `andThen` finish recorder)
          `onException` giveUp made attachment owned capture "its recording raised"
      case recorded of
        Right (batch, Right ()) →
          submitFrames (liveFrames made) (batch :| []) >>= \case
            Right (SubmittedAs submission) → do
              observe (FrameSubmitted attachment (ownedFrame owned) submission)
              present made target attachment owned image capture
            Right (SubmittedNothing reason) → False <$ abandon made attachment owned capture ("its submission had no effect: " <> reason)
            Left refusal → False <$ abandon made attachment owned capture ("its submission was refused: " <> tshow refusal)
        Right (_, Left refusal) → False <$ abandon made attachment owned capture ("the renderer refused: " <> tshow refusal)
        Left refusal → False <$ abandon made attachment owned capture ("its recording was refused: " <> tshow refusal)
    present made target attachment owned image capture = do
      observe (FramePresentRequested attachment (ownedFrame owned) (ownedImage owned) revision)
      presentFrame (liveFrames made) (ownedFrame owned) >>= \case
        Right (PresentedAs presentation outcome) → do
          observe (FramePresented attachment (ownedFrame owned) presentation outcome)
          atomically $ do
            editTarget rendering target (\record → record {targetShown = Just (imageGeneration (ownedImage owned))})
            for_ (capturedWork capture) $ \(readback, bytes) →
              presentCapture captures attachment . Presented readback bytes $ \copied →
                CapturedFrame
                  { capturedAttachment = attachment
                  , capturedTarget = target
                  , capturedGeneration = imageGeneration (ownedImage owned)
                  , capturedFrame = ownedFrame owned
                  , capturedImage = ownedImage owned
                  , capturedPresentation = presentation
                  , capturedExtent = imageExtent image
                  , capturedFormat = imageFormat image
                  , capturedSceneRevision = revision
                  , capturedBytes = copied
                  }
          pure True
        Right (PresentedNothing reason) → do
          _ ← closeUnpresentedFrame (liveFrames made) (ownedFrame owned)
          let why = "its presentation enqueued nothing: " <> reason
          observe (FrameAbandoned attachment (ownedFrame owned) why)
          giveUp made attachment owned capture why
          False <$ retryAfterPending target
        Left refusal → do
          _ ← closeUnpresentedFrame (liveFrames made) (ownedFrame owned)
          let why = "its presentation was refused: " <> tshow refusal
          observe (FrameAbandoned attachment (ownedFrame owned) why)
          giveUp made attachment owned capture why
          False <$ retryAfterPending target
    -- A frame given up after its acquisition leaves the target's render
    -- demand standing: the frame is tried again at the backoff's first
    -- interval, as a pending acquisition is, never on every round.
    abandon made attachment owned capture reason = do
      _ ← skipFrame (liveFrames made) (ownedFrame owned)
      observe (FrameAbandoned attachment (ownedFrame owned) reason)
      giveUp made attachment owned capture reason
      retryAfterPending (frameTarget (ownedFrame owned))
    -- The capture of a frame given up is settled without bytes, and its
    -- readback buffer released: a batch that recorded the copy keeps it until
    -- its own references end.
    giveUp made attachment owned capture reason = when (capturedAsked capture) $ do
      for_ (capturedWork capture) (\(readback, _) → void (releaseManaged (liveRecording made) readback))
      withhold attachment (WithheldFrameAbandoned (ownedFrame owned) reason)

-- | What rendering knows of a frame's image from its generation's plan.
data FrameImage = FrameImage
  { imageExtent ∷ !SurfaceExtent
  , imageFormat ∷ !Word32
  , imageCapturable ∷ !Bool
    -- ^ Whether its generation made it a transfer source.
  }

-- | Whether a frame is still an outstanding capture's, and the readback
-- buffer the copy goes into and its size, once one was made.
data Captured = Captured
  { capturedAsked ∷ !Bool
  , capturedWork ∷ !(Maybe (Readback, Natural))
  }

-- | Settle every capture whose frame was presented and whose bytes the
-- batch's completion evidence now exposes, delivering a copy of them, and
-- release its readback buffer. Nothing is read once the session has failed or
-- the device has been lost: a hold the loss let go of is not completion.
-- Answers whether it settled any.
settleCaptures ∷ Rendering q inst msgr phys dev cmd → IO Bool
settleCaptures rendering =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure False
    Just made → do
      (waiting, running) ← atomically $ do
        held ← outstanding captures
        terminal ← readRootsTerminal (renderingRoots rendering)
        model ← readRootsModel (renderingRoots rendering)
        pure ([(attachment, presented) | (attachment, StagePresented presented) ← held], isNothing (reportPrimary terminal) && not (deviceLossObserved model))
      if not running
        then pure False
        else fmap or . forM waiting $ \(attachment, presented) →
          readReadback (liveRecording made) (presentedReadback presented) 0 (presentedBytes presented) >>= \case
            Left (RefusedNotWritten _) → pure False
            answer → do
              _ ← releaseManaged (liveRecording made) (presentedReadback presented)
              atomically . settleCapture captures attachment $ case answer of
                Right bytes → CaptureDelivered (presentedFrame presented (ByteString.copy bytes))
                Left refusal → CaptureWithheld attachment (WithheldReadRefused refusal)
              pure True
  where
    captures = renderingCaptures rendering

-- | Destroy, on the owner's thread, every released generation — a replaced or
-- released pipeline of the renderer's, a capture's readback buffer — that
-- nothing holds any more. It takes a model turn only when there is one.
reclaimReleased ∷ Rendering q inst msgr phys dev cmd → Instant → IO ()
reclaimReleased rendering now =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure ()
    Just made → do
      due ← atomically $ do
        views ← readManaged (liveRecording made)
        model ← readRootsModel (renderingRoots rendering)
        pure
          ( or
              [ disposalEligible (ResourceSubject (viewResource view)) model
              | view ← views
              , released (viewManagedStanding view)
              ]
          )
      when due (void (disposeResources (liveRecording made) now))
  where
    released = \case
      ManagedReleased → True
      ManagedReplaced _ → True
      _ → False

editTarget ∷ Rendering q inst msgr phys dev cmd → TargetId → (TargetRendering → TargetRendering) → STM ()
editTarget rendering target edit = modifyTVar' (renderingTargets rendering) (Map.alter (Just . edit . maybe freshTarget id) target)

-- | The earliest instant rendering owes the owner a round, given the owner's
-- targets: a demand deadline, while one of them could still render it, and,
-- for every target the model says wants a frame, the retry of a frame that
-- could not be made, or now.
--
-- A demand deadline is cleared only by the step that serves it. Once every
-- target is closing — the exit drain, which takes no step — no frame can
-- serve it, so it is no longer owed; left in, it would be a passed deadline
-- the drain asks again at once, for ever.
renderingDeadline ∷ Rendering q inst msgr phys dev cmd → Instant → [TargetId] → IO (Maybe Instant)
renderingDeadline rendering now targets = atomically $ do
  ahead ← readTVar (renderingDemandAt rendering)
  held ← readTVar (renderingTargets rendering)
  model ← readRootsModel (renderingRoots rendering)
  let renderable =
        or
          [ True
          | target ← targets
          , not (maybe False targetClosing (Map.lookup target held))
          , Just view ← [targetView target model]
          , viewTargetPhase view == TargetAdmitted
          ]
      owed = if renderable then maybe [] pure ahead else []
      wanting =
        [ maybe now id (targetRetryAt record)
        | (target, record) ← Map.toList held
        , not (targetClosing record)
        , Just view ← [targetView target model]
        , viewTargetRenderDemand view
        ]
  pure $ case owed <> wanting of
    [] → Nothing
    candidates → Just (minimum candidates)

-- ---------------------------------------------------------------------------
-- Retirement

-- | Begin retiring one target, and say whether its retirement can be
-- performed now.
--
-- The first call closes the target in the model. Every call closes whatever
-- frame of the target is still acquired or submitted — a pass a cancellation
-- interrupted is finished by the next call, and a finished one finds nothing
-- — then asks the fences when a poll is due — the close itself makes one due —
-- and anchors the model's schedule with one generation step, and answers
-- 'Nothing' — ready — once no frame and no presentation of the target
-- remains, or once the device has been lost; otherwise the reason it is still
-- owed.
--
-- It answers too the targets whose recovery attempt that step admitted: a
-- step run for one target's retirement can release another target's lost
-- surface, and that attempt is outstanding until the main thread is asked for
-- its replacement, which the caller does.
prepareTargetRetirement ∷ Rendering q inst msgr phys dev cmd → Instant → TargetId → IO (Maybe Text, [TargetId])
prepareTargetRetirement rendering now target =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure (Nothing, [])
    Just made → do
      atomically $ do
        record ← Map.findWithDefault freshTarget target <$> readTVar (renderingTargets rendering)
        unless (targetClosing record) $ do
          editTarget rendering target (\held → held {targetClosing = True})
          stateRootsModel (renderingRoots rendering) $ \model → case closeTarget target model of
            Admitted next → ((), next)
            _ → ((), model)
      void (closeTargetFrames (liveFrames made) target)
      model ← atomically (readRootsModel (renderingRoots rendering))
      if deviceLossObserved model
        then pure (Nothing, [])
        else do
          wanted ←
            if pollDue now model
              then do
                poll rendering now
                summarySurfacesWanted <$> stepGenerations (renderingGenerations rendering) now Map.empty
              else pure []
          frames ← atomically (filter ((== target) . frameTarget . standingFrame) <$> readFrameStandings (liveFrames made))
          presentations ← atomically (filter ((== target) . presentationTarget . standingPresentation) <$> readPresentations (liveFrames made))
          pure
            ( if null frames && null presentations
                then Nothing
                else
                  Just
                    ( tshow (length frames)
                        <> " frames and "
                        <> tshow (length presentations)
                        <> " presentations of "
                        <> tshow target
                        <> " await their own evidence"
                    )
            , wanted
            )

-- | Destroy what rendering holds for one target: its slots' synchronization
-- and its presentation pool, which raises, retaining them, if anything of the
-- target is still owed; and its frame storages, released and destroyed once
-- the model reports them unheld.
--
-- A capture of the target's attachment still outstanding is settled first:
-- with its bytes when its batch's completion evidence exposes them — the
-- retirement's preparation waited for every frame and presentation of the
-- target to end on its own evidence — and otherwise without: the session's
-- primary failure when it has failed, and the target's retirement otherwise.
-- Its readback buffer is released and destroyed with the rest.
retireTargetRendering ∷ Rendering q inst msgr phys dev cmd → Instant → TargetId → AttachmentId → IO ()
retireTargetRendering rendering now target attachment =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → do
      withheld
      atomically (modifyTVar' (renderingTargets rendering) (Map.delete target))
    Just made → do
      _ ← settleCaptures rendering
      stage ← atomically (outstandingFor (renderingCaptures rendering) attachment)
      case stage of
        Just (StagePresented presented) → void (releaseManaged (liveRecording made) (presentedReadback presented))
        _ → pure ()
      withheld
      retireTargetFrames (liveFrames made) target
      storages ← maybe [] targetStorages . Map.lookup target <$> readTVarIO (renderingTargets rendering)
      forM_ storages (void . releaseManaged (liveRecording made))
      _ ← disposeResources (liveRecording made) now
      atomically (modifyTVar' (renderingTargets rendering) (Map.delete target))
  where
    withheld = atomically $ do
      primary ← reportPrimary <$> readRootsTerminal (renderingRoots rendering)
      let reason = maybe WithheldTargetRetired (WithheldSessionEnded . Just) primary
      settleCapture (renderingCaptures rendering) attachment (CaptureWithheld attachment reason)

-- | Settle every capture still outstanding without bytes, the session
-- ending — with its primary failure, if it failed — and release their readback
-- buffers, which the recording's retirement then destroys with everything
-- else. The owner's retirement runs it before the recording's.
endCaptures ∷ Rendering q inst msgr phys dev cmd → IO ()
endCaptures rendering = do
  (held, primary) ← atomically ((,) <$> outstanding captures <*> (reportPrimary <$> readRootsTerminal (renderingRoots rendering)))
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure ()
    Just made →
      for_ [presented | (_, StagePresented presented) ← held] $ \presented →
        void (releaseManaged (liveRecording made) (presentedReadback presented))
  atomically (withholdAll captures (WithheldSessionEnded primary))
  where
    captures = renderingCaptures rendering

-- ---------------------------------------------------------------------------
-- Uploads (GRS-6)

-- | Why the session takes no upload now.
data UploadsUnavailable
  = UploadsNotConfigured
    -- ^ The host configured no uploads.
  | UploadsNotReady
    -- ^ Configured, and not yet made: the device does not exist yet.
  | UploadsRefusedBy !Refusal
    -- ^ The device refused them when they were made.
  deriving (Eq, Show)

-- | Make the session's uploads, on the owner's thread, the first time the
-- recording and the frames exist, if configured: an owner step does this
-- before it runs any owner-thread action, so an action's uploads find them.
-- Answers whether it made, or was refused, them now.
makeRenderingUploads ∷ Rendering q inst msgr phys dev cmd → IO Bool
makeRenderingUploads rendering =
  readTVarIO (renderingUploads rendering) >>= \case
    UploadsPending config →
      live rendering >>= \case
        Nothing → pure False
        Just made → do
          made' ← newUploads (liveFrames made) config
          True <$ atomically (writeTVar (renderingUploads rendering) (either UploadsRefused UploadsMade made'))
    _ → pure False

-- | One owner step's uploads, on the owner's thread, after the step has
-- polled the fences, so a completion it observed settles its upload in the
-- same step: closed — every upload not yet started cancelled — once the
-- owner's admission has, and otherwise progressed ('progressUploads').
-- Answers whether anything was recorded or settled.
progressRenderingUploads ∷ Rendering q inst msgr phys dev cmd → Bool → IO Bool
progressRenderingUploads rendering open =
  readTVarIO (renderingUploads rendering) >>= \case
    UploadsMade uploads → progressMade uploads
    _ → pure False
  where
    progressMade uploads = do
      unless open (atomically (closeUploads uploads))
      progressUploads uploads >>= \case
        Right step → pure (progressAdvanced step)
        Left _ → pure False

-- | Bring the texture table up to date after the step's uploads (GRS-7):
-- write the descriptors of textures whose uploads completed, and release the
-- images of released textures no batch's version maps any longer. A session
-- with no table, or no recording, has nothing to do; a refusal leaves the
-- table as it was, for the next step.
refreshRenderingTable ∷ Rendering q inst msgr phys dev cmd → IO ()
refreshRenderingTable rendering =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure ()
    Just made → void (refreshTextureTable (liveRecording made))

-- | Whether an upload waits for the owner: any thread may ask, and the
-- owner's wake does.
renderingUploadsWaiting ∷ Rendering q inst msgr phys dev cmd → STM Bool
renderingUploadsWaiting rendering =
  readTVar (renderingUploads rendering) >>= \case
    UploadsMade uploads → uploadsWaiting uploads
    _ → pure False

-- | Admit an upload from any thread ('submitUploadGated'), once the
-- session's uploads exist, under the caller's gate, read in the transactions
-- that reserve and queue it.
submitRenderingUpload
  ∷ Rendering q inst msgr phys dev cmd
  → STM (Maybe UploadRefusal)
  → UploadRequest
  → IO (Either (Either UploadsUnavailable UploadRefusal) UploadTicket)
submitRenderingUpload rendering gate request =
  readTVarIO (renderingUploads rendering) >>= \case
    UploadsMade uploads → either (Left . Right) Right <$> submitUploadGated gate uploads request
    UploadsUnconfigured → pure (Left (Left UploadsNotConfigured))
    UploadsPending _ → pure (Left (Left UploadsNotReady))
    UploadsRefused refusal → pure (Left (Left (UploadsRefusedBy refusal)))

-- | Cancel an upload from any thread ('cancelUpload').
cancelRenderingUpload ∷ Rendering q inst msgr phys dev cmd → UploadTicket → STM (Either CancelRefusal ())
cancelRenderingUpload rendering ticket =
  readTVar (renderingUploads rendering) >>= \case
    UploadsMade uploads → cancelUpload uploads ticket
    _ → pure (Left CancelUnknown)

-- | Retire the recording, releasing and destroying every managed resource
-- left, before the device is destroyed. Raises, retaining them, if any
-- remains.
--
-- Frame-less submissions (GRS-12) are settled first: the owner waits, in the
-- frames' finite drain steps and for at most 'framelessDrainSteps' of them,
-- for each outstanding one's fence, observing each completion it proves, and
-- then destroys the frame-less slots' fences. Once the device is lost they
-- are let go of under the device-loss rule without waiting. One still
-- outstanding at the end is retained, and so is the device: nothing is
-- certified complete to finish the teardown.
-- | Fail every texture swap still pending in the rendering's recording
-- (GRS-9), touching no native object. The owner's teardown hooks run it
-- before and after everything else ("settlingSwaps").
failRenderingSwaps ∷ Rendering q inst msgr phys dev cmd → STM ()
failRenderingSwaps rendering = readTVar (renderingLive rendering) >>= maybe (pure ()) (failPendingSwaps . liveRecording)

retireRendering ∷ Rendering q inst msgr phys dev cmd → Instant → IO ()
retireRendering rendering now =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure ()
    Just made → do
      uploads ← readTVarIO (renderingUploads rendering)
      -- Uploads not yet started are cancelled before the drain, and those
      -- started are settled with the frame-less work it drains (GRS-6).
      case uploads of
        UploadsMade held → atomically (closeUploads held)
        _ → pure ()
      drain (liveFrames made) (0 ∷ Natural)
      case uploads of
        UploadsMade held → void (retireUploads held)
        _ → pure ()
      retireFrameless (liveFrames made)
      retireRecording (liveRecording made) now
  where
    drain frames steps = do
      pending ← atomically (readFramelessSubmissions frames)
      lost ← deviceLossObserved <$> atomically (readRootsModel (renderingRoots rendering))
      unless (null pending || lost || steps >= framelessDrainSteps) $
        -- A step that raised has latched its failure with the session; the
        -- retirement below decides what it retains.
        tryWithContext (awaitFrames frames now drainWaitLimit) >>= \case
          Left failure@(ExceptionWithContext _ exception)
            | isAsynchronous exception → rethrowIO (failure ∷ ExceptionWithContext SomeException)
            | otherwise → pure ()
          Right _ → drain frames (steps + 1)

-- | How many finite drain steps the owner's retirement waits for frame-less
-- submissions to complete: a hundred of the frames' 10 ms waits.
framelessDrainSteps ∷ Natural
framelessDrainSteps = 100

-- ---------------------------------------------------------------------------
-- Helpers

rotated ∷ Natural → [a] → [a]
rotated _ [] = []
rotated cursor items = drop offset items <> take offset items
  where
    offset = fromIntegral (cursor `mod` fromIntegral (length items))

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
