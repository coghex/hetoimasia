-- | Managed rendering resources and the scoped recorder above the roots and
-- the generations (VK-11): the renderer-facing boundary of D-26, P-1 and
-- D-28.
--
-- A renderer never holds a native handle. It holds opaque managed handles —
-- a 'PipelineLayout', a 'Pipeline', a frame slot's 'FrameStorage', a
-- 'Readback' buffer — each naming one generation of one managed resource by
-- the GPU model's 'ResourceId', and it records through a 'Recorder' that
-- 'recordFrame' lends it for one consumer action. Every native call goes
-- through an open native layer, 'RecordingOps', whose production form is
-- "Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan"; the headless examples
-- supply a stand-in.
--
-- = Retention
--
-- Every recording operation first validates the calling thread, the handles
-- it names, the frame's generation and the recorder's state, and then
-- registers the exact resource generations it references — its own and the
-- transitive dependencies of the binding, such as a pipeline's layout — as
-- recorded references of the batch in the model ('extendBatch'), before the
-- native call that could capture them. A refusal at any of those steps makes
-- no native call. The union is taken per operation, so a subject used by
-- several commands, or reached through several bindings, is retained once. A
-- batch never looks a resource up again: a replacement published after
-- recording leaves the batch naming the generation it recorded, and a
-- released handle, or one whose generation was replaced, records nothing more.
--
-- = Batches
--
-- 'recordFrame' reserves one batch in the model against an acquired frame,
-- retaining the frame's swapchain generation and its frame slot's storage,
-- begins that storage's command buffer, runs the consumer exactly once, and
-- seals the batch. Each frame slot has one storage and one live batch at a
-- time. A consumer that raises, a cancellation, or rendering left open leaves
-- the batch partial: its commands and every reference it took stay owned, it
-- can never be submitted, and only 'discardBatch' or 'resetFrameRecorder'
-- ends it. Both invalidate the native commands first — the storage's pool is
-- reset — and only then discharge the batch's own references in the model; an
-- invalidation that raised retains everything, the session fails with
-- 'CleanupFailed', and 'BatchInvalidationFailed' is raised. Neither settles
-- any acquisition or presentation obligation of the frame.
--
-- A frame-less batch (GRS-12) is recorded the same way, through the frames'
-- scope ('Hetoimasia.GPU.Vulkan.Native.Frames.recordFramelessIn'), into the
-- storage of a frame-less slot of the session, with no swapchain image: every
-- command that needs one is refused, and it renders into a managed color
-- target instead. Its 'BatchTicket' reports it pending,
-- complete, discarded or lost; 'readTicket' reads it from any thread, and
-- 'awaitTicket' waits for it with a deadline anywhere but the graphics
-- owner's thread. A discard settles it as discarded.
--
-- = Offscreen color targets
--
-- GRS-5 renders into a managed 'ColorTarget' image, in a frame batch or a
-- frame-less one: 'beginRenderingInto' begins a pass with the target's owned
-- view as its one color attachment, cleared across its whole extent, either
-- keeping its color-attachment use ('ClearTarget') or transitioning it from
-- undefined ('ClearFromUndefined'), which initializes a new target. The open
-- pass's attachment governs the pipeline, viewport and scissor checks, and a
-- draw checks them again against it. 'copyTargetToReadback' copies a target
-- the consumer moved to its 'TransferRead' use whole into a readback buffer,
-- four bytes a pixel in the target's own byte order, tightly packed and
-- unconverted, readable once the copying batch's submission has completed.
--
-- = Names and labels
--
-- When the roots offer naming ('readRootsInstrumentation'), every managed
-- resource's native objects are named from its 'ResourceId'
-- ("Hetoimasia.GPU.Vulkan.Native.Naming") — a frame storage's pool and command
-- buffer with the target and slot they serve too — once the model has issued
-- that identity and before the handle is returned, so no batch can reference
-- an unnamed object. A pipeline's two shader modules exist only while it is
-- built, before that identity is issued, so they are named, as each is created,
-- under the identity the model is about to issue — every model operation that
-- issues one is this owner's, so it is the one issued — and a module whose
-- name could not be set fails the pipeline's construction: the native layer
-- destroys what it made, and the reservation is given back. A naming call that raised releases the generation it was
-- naming, which the owner's disposal then destroys like any other released
-- generation, and re-raises: the handle is never returned, and a replacement
-- whose new generation could not be named leaves neither generation
-- recordable.
--
-- Recording on such a device brackets each batch, and each dynamic-rendering
-- pass inside it, in a command-buffer label naming the batch and the target and
-- generation of its frame: the batch's label opens right after its command
-- buffer begins and closes right before it ends, and a pass's label opens
-- right before rendering begins and closes right after it ends. Whatever else
-- happens, every label a batch opened is closed before 'recordFrame' returns or
-- raises — a consumer that raised, was cancelled, left rendering open or had a
-- command fail included — and a batch whose labels could not all be closed is
-- partial, never sealed, with the consumer's own failure, where there was one,
-- still the one raised. Without naming nothing is labelled, and recording and
-- sealing are otherwise unchanged. Label commands are recorded through the
-- native layer's 'opsRecord' like any other, and count as commands.
--
-- = Release and destruction
--
-- 'releaseManaged' ends a handle's logical use and its CPU use in the model
-- together: nothing can record through it, or read it, again. Batches that
-- already recorded it are untouched. 'disposeResources' destroys, on the
-- owner's thread, every released generation the model reports every hold of
-- ended — never a pipeline layout while a pipeline built over it remains — and
-- records each disposal with the model; a destruction that raised is
-- uncertain, never retried, and fails the session.
--
-- = Readback
--
-- A readback buffer is host-visible memory, mapped once. 'copyToReadback'
-- records the copy of the frame's image — which its generation must have made
-- a transfer source, as only generations built for a verification capture do
-- ("Hetoimasia.GPU.Vulkan.Native.Generations.newGenerationsCapturing"), and
-- which must already be in the transfer-source layout — and after it a buffer
-- barrier from the transfer write to the host read. Bytes are exposed only
-- with completion evidence: the batch that wrote them was recorded as
-- submitted ('noteBatchSubmitted'), and the buffer owes no recorded reference
-- and no submitted use. Its memory is the device allocator's
-- ("Hetoimasia.GPU.Vulkan.Native.Allocator"), under the readback usage, and
-- is charged as the allocator holds it: the buffer's own size is never
-- charged. Non-coherent memory is invalidated over the bytes read before they
-- are read, and flushed over the buffer after 'fillReadback' writes it, each
-- as a range of the buffer's own allocation that the allocator aligns. A
-- write while any batch or submission holds the buffer is refused.
--
-- = Buffers and images
--
-- 'createBuffer' and 'createImage' (GRS-2) make a 'Buffer' or an 'Image' of an
-- engine-defined kind, which fixes its usage flags and the memory usage its
-- allocation is made under ('bufferKindUse', 'imageKindUse'); a consumer never
-- passes raw flags. An image is described by its kind, format, extent and mip
-- levels, and is refused before anything is created — 'RefusedImageUnsupported'
-- naming both, or 'RefusedOutOfBounds' — if its kind does not take the format,
-- its description is empty or beyond its full mip chain, its format needs a
-- device feature the device was not created with, or the device does not
-- support it for the kind's use or at that size. Each image owns one view of
-- its whole resource, created, named and destroyed with it. Their memory is the
-- device allocator's, charged as its blocks; each reserves its objects — two
-- for a buffer, three for an image — and no bytes. Nothing writes them yet,
-- and the only thing a batch records over them is a barrier (see Ordering).
-- Disposal destroys an image's view, then the image, then its allocation.
--
-- = Ordering
--
-- 'transitionResource' (GRS-3) moves a managed buffer or image between the
-- uses of its kind within a batch, under the GPU model's pure ordering rules
-- ("Hetoimasia.GPU.Model.Access"); 'useScope' and 'useLayout' map each use
-- onto Vulkan's stages, accesses and layouts. Every resource rests, between
-- batches, in its kind's resting use. A batch's first touch of a resource
-- records an entry barrier out of that resting use, and its seal an exit
-- barrier back into it for every resource it touched — mechanical barriers no
-- consumer records, which on the one graphics queue chain each batch's
-- accesses to the batches submitted before it. Between them the consumer moves
-- a resource only by an explicit transition, from the use the batch left it
-- in: anything else is refused with no native call. A batch that leaves a
-- resource away from rest is refused its seal and left partial, as one that
-- leaves rendering open is; its exit barriers never stand in for a
-- transition the consumer omitted. A barrier that raised, at entry, in a
-- transition or at the seal, leaves the batch partial with every reference it
-- took, until a discard or reset invalidates it.
--
-- A new image awaits initialization. The first batch that touches it must
-- initialize it, by a transition from undefined contents; any other first
-- touch, or one by another batch before the initializing batch has been
-- submitted, is 'RefusedUninitialized'. Only a submission the queue accepted
-- publishes the initialization: recording, sealing, a fence reset, a no-effect
-- failure, an unknown effect, a discard and a reset never do, and a dropped
-- initializing batch leaves its image awaiting initialization again. Swapchain
-- images keep 'transitionImage' and 'supportedTransition' unchanged.
--
-- = State
--
-- The recording's state is three maps the 'Recording' holds, and each
-- recorder's own references. Module names below are relative to
-- @Hetoimasia.GPU.Vulkan.Native.Internal.Recording@, the package's private
-- implementation of this module, which clients cannot import.
--
-- +-------------------+--------------+------------------------------------+--------+-----------------------------+-----------------------------+
-- | State             | Owner        | Readers and writers                | Thread | Lifetime                    | Reset or disposal           |
-- +===================+==============+====================================+========+=============================+=============================+
-- | Managed records   | @State@,     | @Construction@ inserts, releases   | Owner  | Construction until the      | Removed once the model      |
-- |                   | which        | and replaces; @Recorder@,          |        | model records the disposal  | records it; kept uncertain  |
-- |                   | creates them | @Batches@ and @Readback@ advance a |        |                             |                             |
-- |                   |              | readback's contents; @Disposal@    |        |                             |                             |
-- |                   |              | advances and removes               |        |                             |                             |
-- +-------------------+--------------+------------------------------------+--------+-----------------------------+-----------------------------+
-- | Frame storages    | @State@,     | @Construction@ inserts;            | Owner  | As its managed record       | As its managed record       |
-- |                   | which        | @Disposal@ removes                 |        |                             |                             |
-- |                   | creates them |                                    |        |                             |                             |
-- +-------------------+--------------+------------------------------------+--------+-----------------------------+-----------------------------+
-- | Batch records     | @State@,     | @Recorder@'s 'recordFrame' inserts | Owner  | Recording until invalidated | Removed after the native    |
-- |                   | which        | and advances; @Batches@ advances,  |        |                             | invalidation returned       |
-- |                   | creates them | and removes on discard and reset;  |        |                             |                             |
-- |                   |              | @Disposal@ removes with a storage  |        |                             |                             |
-- +-------------------+--------------+------------------------------------+--------+-----------------------------+-----------------------------+
-- | A recorder        | @Recorder@'s | The consumer, inside 'recordFrame' | Owner  | One consumer action         | Closed when the action ends |
-- |                   | 'recordFrame'|                                    |        |                             |                             |
-- +-------------------+--------------+------------------------------------+--------+-----------------------------+-----------------------------+
--
-- @Layer@ is the native layer's shape and holds no state. No other state
-- exists: no module keeps a registry, a worker or a ledger of its own.
--
-- Every operation belongs to the thread that created the 'Recording' — the
-- graphics owner — and any other thread is refused with 'RefusedNotOwner'.
module Hetoimasia.GPU.Vulkan.Native.Recording
  ( -- * The native layer
    RecordingOps (..)
  , PipelineRequest (..)
  , PipelineShaders (..)
  , ReadbackAllocation (..)
  , NativeCommand (..)
  , ImageLayout (..)
  , ClearColor (..)
  , Viewport (..)
  , Rect (..)
  , ImageQuery (..)
  , ImageLimits (..)
  , ViewRequest (..)
  , AccessScope (..)
  , BarrierObject (..)

    -- * The recording
  , Recording
  , newRecording
  , Refusal (..)

    -- * Managed resources
  , PipelineLayout
  , Pipeline
  , FrameStorage
  , Readback
  , Managed (managedResource)
  , createPipelineLayout
  , createPipeline
  , replacePipeline
  , createFrameStorage
  , createReadback
  , releaseManaged

    -- * Buffers and images (GRS-2)
  , Buffer
  , BufferKind (..)
  , bufferKindUse
  , BufferDescription (..)
  , createBuffer
  , Image
  , ImageKind (..)
  , ImageUse (..)
  , imageKindUse
  , ImageFormat (..)
  , formatCode
  , formatNeedsCompressionBC
  , kindFormats
  , ImageDescription (..)
  , fullMipChain
  , createImage

    -- * Ordering (GRS-3)
  , Ordered
  , ResourceUse (..)
  , TransitionSource (..)
  , bufferResourceKind
  , imageResourceKind
  , useScope
  , useLayout
  , transitionResource

    -- * Recording
  , Recorder
  , recorderBatch
  , recordFrame
  , transitionImage
  , supportedTransition
  , beginRendering
  , PassStart (..)
  , beginRenderingInto
  , endRendering
  , bindPipeline
  , setViewport
  , setScissor
  , draw
  , copyToReadback
  , copyTargetToReadback
  , readbackBytesFor

    -- * Tickets (GRS-12)
  , BatchTicket
  , ticketBatch
  , TicketState (..)
  , readTicket
  , awaitTicket

    -- * Batches
  , discardBatch
  , resetFrameRecorder
  , noteBatchSubmitted

    -- * Readback
  , readReadback
  , fillReadback

    -- * Disposal
  , disposeResources
  , retireRecording

    -- * Observation
  , ManagedStanding (..)
  , ManagedView (..)
  , readManaged
  , BatchStanding (..)
  , BatchView (..)
  , readBatch
  , readBatches

    -- * Failures
  , BatchInvalidationFailed (..)
  , ResourceDestructionFailed (..)
  , ResourcesRetained (..)

    -- * Allocation recovery (VK-14)
  , AllocationNotRecovered (..)
  , RecoveryEnd (..)
  ) where

import Hetoimasia.GPU.Model.Access (ResourceUse (..), TransitionSource (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches (discardBatch, noteBatchSubmitted, resetFrameRecorder)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction
  ( createBuffer
  , createFrameStorage
  , createImage
  , createPipeline
  , createPipelineLayout
  , createReadback
  , releaseManaged
  , replacePipeline
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (AllocationNotRecovered (..), RecoveryEnd (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Disposal (disposeResources, newRecording, retireRecording)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( AccessScope (..)
  , BarrierObject (..)
  , BufferDescription (..)
  , BufferKind (..)
  , ClearColor (..)
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , ImageLayout (..)
  , ImageLimits (..)
  , ImageQuery (..)
  , ImageUse (..)
  , ViewRequest (..)
  , bufferKindUse
  , formatCode
  , formatNeedsCompressionBC
  , fullMipChain
  , imageKindUse
  , kindFormats
  , NativeCommand (..)
  , PipelineRequest (..)
  , PipelineShaders (..)
  , ReadbackAllocation (..)
  , RecordingOps (..)
  , Rect (..)
  , Viewport (..)
  , bufferResourceKind
  , imageResourceKind
  , supportedTransition
  , useLayout
  , useScope
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Readback (fillReadback, readReadback)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder
  ( Recorder
  , PassStart (..)
  , beginRendering
  , beginRenderingInto
  , bindPipeline
  , copyTargetToReadback
  , copyToReadback
  , draw
  , endRendering
  , readbackBytesFor
  , recordFrame
  , recorderBatch
  , setScissor
  , setViewport
  , transitionImage
  , transitionResource
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchInvalidationFailed (..)
  , BatchStanding (..)
  , BatchTicket (ticketBatch)
  , BatchView (..)
  , Buffer
  , FrameStorage
  , Image
  , Managed (managedResource)
  , ManagedStanding (..)
  , ManagedView (..)
  , Ordered
  , Pipeline
  , PipelineLayout
  , Readback
  , Recording
  , Refusal (..)
  , ResourceDestructionFailed (..)
  , ResourcesRetained (..)
  , TicketState (..)
  , awaitTicket
  , readTicket
  , readBatch
  , readBatches
  , readManaged
  )
