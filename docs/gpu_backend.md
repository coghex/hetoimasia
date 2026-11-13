# The Vulkan roots and their window integration

The contract of the Vulkan backend: one graphics session's instance, debug
messenger, one shared device with its allocator, a target for every window
surface handed to it, each target's swapchain generations, the renderer-facing
recording boundary over managed resources, frames, presentation, recovery and
terminal failure, composed into the supervised graphics owner and the main
thread's scheduled loop. The pure accounting it relies on is
[the GPU model](gpu_model.md); the diagnostic capture is
[vulkan_diagnostics.md](vulkan_diagnostics.md); the owner it runs in is
[glfw.md](glfw.md#the-supervised-graphics-owner). Signatures are in the
modules' export lists.

## Packages

| Package | Location | Holds | Depends on |
| --- | --- | --- | --- |
| `hetoimasia-gpu-vulkan-native` | `packages/gpu-vulkan/native/` | The profile's decisions, the roots, generations, recording, frames and allocator over an open native layer, and the production native layers | The binding, the diagnostics package, the GPU model, the foundation; never GLFW |
| `hetoimasia-gpu-vulkan-glfw` | `packages/gpu-vulkan/glfw/` | The session controller, the main-thread handover, the composition (`Hetoimasia.GPU.Vulkan.GLFW`) | The native package, `hetoimasia-glfw:runtime-glfw`, `:vulkan-interop`, the diagnostics package, the model |

Both are listed only in `cabal.project.vulkan` and built only through
[`tools/vulkan/run.sh`](../tools/vulkan/run.sh); the ordinary projects resolve
no Vulkan header, binding or loader. Each public native module
(`Roots`, `Generations`, `Recording`, `Frames`, `Allocator`, `Presentation`,
`Profile`) has a `.Vulkan` production layer where it makes native calls, and
its implementation is under `Hetoimasia.GPU.Vulkan.Native.Internal`. The
audited `unsafe` subset is `Internal.Commands` and the VMA shim's imports are
`Internal.Vma`. [`packages/gpu-vulkan/README.md`](../packages/gpu-vulkan/README.md)
maps all four GPU packages.

## The ownership graph

```text
 application
   └─ loader capability (LoaderIntegration)          main thread; the caller's scope
       └─ diagnostic lifetime (DiagnosticCapture)     drains into the caller's logger
           └─ loader-aware GLFW session                main thread
               └─ protected window host                main thread; windows, attachments
                   ├─ window ── attachment ─┐          main thread owns the slot
                   │                        │ holds (surface obligation)
                   └─ graphics owner (worker, its own group)
                       └─ session controller
                           └─ roots
                               ├─ instance ◀─ lease (surface bridge)
                               │    ├─ explicit messenger
                               │    ├─ device (one, shared)
                               │    │    └─ allocator (VMA, one per device)
                               │    └─ target surfaces, keyed by the model's TargetId
                               │           └─ swapchain generations, keyed by GenerationId
                               └─ GPU model (identities, the session's state)
                           ├─ recording (managed resources, frame storages, readback)
                           └─ owner-thread actions (bounded queue)
```

- **The instance, messenger, device and allocator belong to the roots**, for
  the session. No target owns the device or gates its lifetime, including the
  bootstrap target, so closing the first window cannot release a device
  another target uses. A session with no target still holds the device until
  whole-owner retirement.
- **Each admitted target's surface belongs to the roots** from admission until
  its retirement destroys it.
- **Each target's swapchain generations belong to the generations module.**
  The roots refuse to destroy a surface while the model holds any generation
  of it (`TargetGenerationsRemain`), and every generation goes before the
  device.
- **The attachment and the window belong to the main thread.** A surface's
  obligation holds its attachment and the instance's lease from the instant
  the native call returns, so neither the window's release nor the instance's
  destruction can happen while the surface may exist.
- What an owner-thread action constructs belongs to the recording, whatever
  becomes of the action.

## Composition

`withVulkanOwnerHost` composes, in order: the loader capability the caller
holds; the diagnostic lifetime, which both messengers report into and which
the instance's destruction quiesces; the loader-aware session, entered on the
process main thread, which copies the required instance extensions into the
controller; the protected window host and its graphics owner, whose injected
operations are the controller's; then the body, given a `VulkanHost`. The
application registers `superviseGraphicsOwner` afterwards so a terminal owner
failure reaches its checkpoints. It answers the body's result and the
capture's verdict. An instance the host did not destroy keeps the capture's
storage retained.

`withVulkanOwnerHostOver` is the same composition over an injected native
layer and surface bridge, which the headless examples drive.

`VulkanHostConfig` carries the host and capture configurations, the instance
layers (each must be offered), the model's budgets, the initial scene, a
`NativeObserver` (wraps every native call for evidence; decides nothing), a
`VulkanRenderer` (`clearRenderer` by default), a `FrameObserver`,
`vulkanDeviceStart` (`DeviceAtFirstSurface` or `DeviceSurfaceFree`), the
action and release-request capacities (64 each), and
`vulkanInitialSceneHoldsNothing`. No configuration field turns verification
capture on; only the package's own suites can capture.

## Threads

| Work | Thread |
| --- | --- |
| The session, extension copy, window creation, each surface's creation through GLFW, replacement surfaces | The process main thread |
| Publishing observations and captured render demand | The main thread, every turn of `runVulkanOwnerLoop` |
| Publishing a scene; submitting an owner-thread action; release requests; holding and ending a generation's CPU use | Any thread |
| Every other Vulkan call: instance, messenger, device, surface queries and destruction, swapchains, recording, acquisition, submission, presentation, fences, reclamation, running actions | The graphics owner |

The controller makes no GLFW call. The owner is one serialized Haskell thread,
not a promise of OS-thread affinity.

## Startup

The owner's startup reads the extensions the session supplied
(`InstanceExtensionsMissing` otherwise), plans the instance against what the
loader offers, creates it with the capture's messenger chained in, creates the
explicit messenger, and leases the instance to the surface bridge.
`readReadiness` answers `RootsReady` from then on, and windows are handed over
only after it. With `DeviceSurfaceFree` the device is also created in startup.

`planInstance` asks for Vulkan 1.3, the window system's surface extensions,
`VK_EXT_debug_utils`, `VK_KHR_get_surface_capabilities2`,
`VK_EXT_surface_maintenance1`, `VK_KHR_portability_enumeration` where
advertised, and the caller's layers. Anything missing is an `InstanceRefusal`
naming the whole gap before anything is created. A startup that fails part-way
leaves what it created recorded, and the owner's drain destroys it.

That request is strict: a layer or validation feature named in the host
configuration that the loader lacks is a refusal, never a silent fall back.
`vulkanOptionalValidation` (`hetoimasia run --vulkan-validation`) is a
best-effort request beside it: `resolveValidation` adds the Khronos layer and
synchronization validation only where offered, drops the rest, and records the
resolution (`readValidationResolution`). It never loosens the strict request
([run_command.md](run_command.md#validation)).

## Admitting targets

`handOverVulkanTarget` runs on the main thread. Its construction step, masked
throughout, registers the attachment with the owner's custody ledger, creates
the surface through the surface bridge, and deposits it for the owner. It then
announces the attachment through the owner's bounded port:
`VulkanTargetHandedOver`, `VulkanAnnouncementDeferred` (port full),
`VulkanOwnerClosed`, or `VulkanRootsNotReady` (nothing attached). A
cancellation during the step is delivered only after the attachment is
published and announced, so the caller loses the answer, not the target.

A deferred attachment stays attached with its surface deposited; the caller
may announce it again with `announceVulkanTarget` or release it. While any
deferred attachment exists the owner takes rounds on its own deadline and
destroys, on its thread, the surface of any whose slot has begun retiring. An
uncertain destruction there is never retried and raises
`UnannouncedSurfaceUncertain`, which ends the owner's run.

The owner's construction takes the deposit:

- **The first live surface, with no device yet,** is the bootstrap.
  `selectDevice` takes the first physical device satisfying the profile:
  Vulkan 1.3, `dynamicRendering`, `synchronization2`, the texture table's six
  descriptor-indexing features, `VK_KHR_swapchain`,
  `VK_EXT_swapchain_maintenance1`, and one queue family answering both
  graphics and presentation. The device is created with that family's one
  queue. No satisfying device is `NoCompatibleDevice`, naming every candidate
  and what each lacks, and is fatal to the owner.
- **A later surface** is checked against the session's queue family. One it
  cannot present to is `TargetSurfaceUnsupported`: its surface is destroyed
  and the target settles as a verified rollback. No second device or queue is
  ever created.
- **An unusable surface** is destroyed and rolled back; a failed creation is
  rolled back; a deposit lost to a cancellation is found on the lease and
  destroyed.

`readTargetRejection` reads a rejected target's reason (the latest 64 are
kept), `readTargetStanding` its standing, and `readVulkanTargets` lists the
admitted targets.

## Swapchain generations

`Hetoimasia.GPU.Vulkan.Native.Generations` owns every admitted target's
swapchain generations, above the roots. Each generation is the model's
`GenerationId`. The model decides what a generation owes and when it may go;
this module makes the calls and records each result in the same masked step
that made it.

### Lifecycle

| Stage | What happens |
| --- | --- |
| Planned | The surface's capabilities, formats and modes are read, and `planGeneration` decides the format, FIFO, the extent, and an image count within the surface's limits and the tracking limit. |
| Constructing | `beginGeneration` reserves the candidate's image accounting and, for a replacement, retires the active generation there and then. The swapchain is created; its image count is checked against the tracking limit before any view is built. |
| Active | `publishGeneration` records the count the driver returned. The target is `Presenting`. |
| Retired | Handed over as `oldSwapchain`, retired on its own, refused, failed or superseded. Nothing is acquired from it again. |
| Destroyed | Once the model reports every hold ended: its views, newest first, then its swapchain. The owner's step destroys at most the model's progress-action limit of generations, rotating across targets. |

The per-target presentation pool is not a generation's: a retired
generation's pending presentations keep their pool records
([The presentation pool](#the-presentation-pool)).

### The extent

`chooseExtent` decides in this order:

1. the target's render eligibility (hidden, minimized, deferred with no
   framebuffer observed, or closing) withholds it before the surface is asked;
2. a concrete current extent the surface supplies is taken, unless it has no
   area;
3. otherwise the last published framebuffer observation, checked for area
   before it is clamped to the platform's and the surface's bounds.

Nothing is invented: with no observation the extent is withheld
(`SuspendedUnobserved`). A withheld extent leaves the target `Suspended`,
which is not a failure and spends no recovery attempt. The swapchain is always
the framebuffer's size in physical pixels. An application that drives its own
loop publishes observations itself (`publishGraphicsObservation`).

### The profile

Single-sample SDR, color-attachment usage only, FIFO, opaque composition where
offered, and `B8G8R8A8_SRGB` or `R8G8B8A8_SRGB` in the sRGB nonlinear color
space. Nothing falls back to a UNORM or arbitrary format. A surface that
cannot serve the profile leaves its target `PresentationUnsupported`, naming
every gap.

### Replacement

A target is rebuilt when its geometry moves, when a swapchain call answered
out of date or suboptimal (`noteSwapchainResult`), or when it resumes after
its active generation was withdrawn.

- **Ordinary resize** is not a failed construction. A move is coalesced for
  16 ms from when it was first seen (`Settling`) and then built from the
  newest geometry. A later change within the period joins the move, so a
  continuous resize is rebuilt once a period, not never. Meanwhile the active
  generation keeps presenting. A move that returns to the active geometry is
  cancelled.
- **Withdrawal** is not a failed construction. A target suspended while a
  generation stood, or whose generation the owner withdrew before a hide,
  presents on that generation no more: once eligible it is replaced at once,
  with no settling period and no recovery attempt.
- **Without a fresh observation**, an out-of-date or suboptimal result with a
  concrete surface extent is enough to rebuild, so a stalled main thread does
  not hold the target at stale geometry.
- **Unchanged geometry** makes the rebuild a recovery attempt, admitted by the
  model's episode: at most three, 100 ms then 500 ms apart
  (`RecoveryWaiting`), and exhaustion is `RecoverySpent`
  ([dispositions](#required-and-optional-dispositions)). Nothing retries hot.
  A delay the clock cannot express is `RecoveryUnscheduled` and is never
  admitted early.
- **The `oldSwapchain` transition is irreversible.** Replacement hands the
  active generation over; it is marked retired before the creation call. A
  creation that then fails leaves the target in `ConstructionFailed` with no
  active generation. The next construction is a fresh one, never passed the
  retired handle, and begins only once every swapchain of the target that
  Vulkan still counts as unretired, and every retired chain still standing,
  has been destroyed.
- A newer resize during a replacement is built next; it is not lost.

### Bounds and holds

A target holds at most the model's generation limit (two by default),
counting active, constructing and retired. At capacity every retired
generation whose holds have ended is destroyed first; if the replacement still
cannot fit the target is `Backpressured` until a hold ends, and it keeps
presenting from its active generation meanwhile. With a limit of one, the
active generation is retired, awaited and destroyed before a fresh one is
built. No target reserves or releases anything of another's.

`useVulkanGeneration` holds a CPU use on the active generation from any thread
and `endVulkanGenerationUse` ends it; while one is held the generation is
retired but not destroyed. A recorded batch holds the generation it records
into, a submission holds it until its fence signals, and a presentation until
its present fence signals.

### Failure and close

- A destruction that raised is uncertain. The generation is kept and never
  offered again; the session fails with `CleanupFailed`; the step raises
  `GenerationDestructionFailed`, which ends the owner's run. The surface, the
  device and the instance are retained.
- An effect whose bookkeeping could not be committed enters the same path
  (`GenerationEffectUncertain`). A creation that raised created nothing.
- Admission through a construction's settlement is one masked region. A
  cancellation can land only between effects, and whatever exists is recorded.
  A creation interrupted inside the call may have created something whose
  handle never came back: its candidate is kept uncertain, never destroyed,
  and the session fails.
- Close wins: a closed target begins no construction and admits no recovery
  attempt. A target's retirement destroys every generation whose holds have
  ended and raises `GenerationsRetained`, manufacturing no evidence, if any
  remains.

### How the generations are built

The public module re-exports eight private modules under
`Internal.Generations`: `State` (the one map of target and generation
records), `Uses`, `Disposal`, `Reconciliation`, `Step`, `Surface`,
`Retirement` and `Observation`. The graph is acyclic and only `State` creates
state. `Generations` and `GenerationUse` stay abstract.

## Device memory

Device memory is VMA beneath the model's accounting.
`Hetoimasia.GPU.Vulkan.Native.Allocator` is the allocator's shape (an open
record of calls, `AllocatorOps`) and the engine's memory-type policy;
`Allocator.Vulkan` is its production form through the engine's own shim. No
VMA type crosses the package's public API.

**Ownership.** One allocator per device, created by the roots right after the
device with `VMA_ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT` and an explicit
large-heap block size of 256 MiB. Every call to it is made on the graphics
owner's thread; nothing relies on VMA's internal locking. The roots destroy it
after every target's surface and before the device, and only once every
allocation has been freed (`AllocationsRemain` otherwise). A destruction that
raised is uncertain: the session fails with `CleanupFailed` and the device is
retained (`AllocatorRemains`).

### Usages and memory types

| Usage | Required | Preferred | For |
| --- | --- | --- | --- |
| `UsageTexture` | device-local | none | textures, depth and color targets |
| `UsageStaticGeometry` | device-local | none | static geometry, staged |
| `UsageStaging` | host-visible | host-coherent | staging written by the host |
| `UsageFrameRing` | host-visible | host-coherent | per-frame rings the device reads |
| `UsageReadback` | host-visible | host-cached | readback buffers |

The engine, not VMA, chooses the one memory type (`chooseMemoryType`): among
the allowed types with every required property, the one with the most
preferred properties, lowest index first. Only that type's bit is passed to
VMA, so VMA cannot fall back to another. No serving type is
`RefusedNoMemoryType`.

### Accounting and backpressure

The model's accounted bytes charge the device memory VMA holds (each block and
each dedicated allocation), never a resource's own size. An allocation attempt
proceeds in this order:

1. The memory requirements are asked of the device without creating the
   resource, and the memory type is chosen.
2. The resource is created in held memory only
   (`VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT`), which opens and charges
   nothing. A miss (`NotPlaced`) spends no recovery.
3. The attempt reserves the most the allocating call could open
   (`reserveDeviceMemory`): the larger of the type's preferred block size and
   the requirements' size. Over budget is `RefusedBackpressure`, answered
   before the call. **The bound holds only if the allocating call asks VMA to
   map nothing and `VMA_DEBUG_MARGIN` is zero in the linked VMA**; otherwise
   VMA can retain a failed block and open a dedicated allocation in one call.
4. The allocating call. VMA's device-memory callbacks record what it opened
   and freed, and the effect is settled right after (`settleDeviceMemory`),
   whether the call succeeded or not.
5. An effect that disagrees with the accounting is a defect
   (`AllocatorAccountingDefect`): the request fails and the session fails with
   `CleanupFailed`.
6. A buffer's host-visible allocation is mapped for its lifetime by a separate
   call after the allocating call is settled, never by the allocating call. An
   image's allocation is never mapped.

Every later call that can free memory is settled the same way. A block several
resources share is charged once, and VMA's retained empty block stays charged
until VMA frees it. Under the default 256 MiB budget and 256 MiB block, a
large heap admits an allocating call only while nothing else is charged; a
consumer that needs more than one block raises the budget.

**Recovery.** A no-effect out-of-memory result gets one reclamation pass and
at most one retry of the whole protocol
([Allocation recovery](#allocation-recovery)). A placement miss is never a
failure and backpressure never reaches recovery.

**Failure cleanup.** A creation, bind or map that failed leaves nothing
allocated and no reservation held, and rolls back only itself. A destruction
that raised there has an unknown effect: the allocation stays counted, the
session fails with `CleanupFailed`, and the request's own failure is raised.

**Lifetime.** An allocation is freed only when the model allows its resource's
disposal, after completion evidence has ended every submitted use. VMA tracks
no GPU use. Teardown unmaps, destroys the buffer (or the view, then the
image), then frees the allocation.

## Recording through managed resources

`Hetoimasia.GPU.Vulkan.Native.Recording` is the small Vulkan-specific
recording interface. A renderer never holds a native handle: it holds opaque
managed handles, each naming one generation of one managed resource by the
model's `ResourceId`, and records through a `Recorder` lent to one consumer
action. Every native call goes through an open native layer, `RecordingOps`.
A `Recording` is created by the graphics owner, and every operation is refused
with `RefusedNotOwner` on any other thread.

### How the recording is built

The public module re-exports seven private modules under
`Internal.Recording`: `Layer` (the native layer's shape and vocabulary),
`State` (the `Recording` and its three maps: managed records, frame storages,
batch records), `Construction`, `Batches`, `Recorder`, `Readback` and
`Disposal`. Only `State` creates state, and `Internal.Commands` is the only
home of the `unsafe` subset.

### The boundary

| Capability | Operations |
| --- | --- |
| Managed resources | `createPipelineLayout`, `createPipeline`, `replacePipeline`, `createFrameStorage`, `createReadback`, `createBuffer`, `createImage`, `releaseManaged` |
| Checked frame | `recordFrame` takes a `FrameSlotId` the model holds acquired and resolves its image, view, extent and format through the owning generation |
| Scoped recorder | image and resource transitions, `beginRendering`, `beginRenderingInto`, pipeline binds, viewport, scissor, draws, `endRendering`, copies to readback |
| Recorded batch | `discardBatch`, `resetFrameRecorder`, `noteBatchSubmitted` |
| Readback | `readReadback`, `fillReadback` |
| Disposal | `disposeResources`, `retireRecording`, on the owner, only once the model reports every hold ended |

There is no raw command buffer, no callback escape hatch and no render graph.
A command outside the supported vocabulary is `RefusedUnsupported`; one the
recorder's state does not admit (a draw outside rendering, a transition inside
rendering, a viewport or scissor that leaves the attachment) is
`RefusedIllegal`. Either way nothing native happens.

A creation reserves its accounting first, so an exhausted budget is
`RefusedBackpressure` before any native call. A creation that raised created
nothing and gives the reservation back; one that returned is recorded in the
same masked step. A frame slot has at most one storage (a command pool with
one primary command buffer) and one outstanding batch.

### Retention

Every recording operation, in order:

1. checks the calling thread, that the recorder's consumer is still running
   (`RefusedRecorderClosed`), each handle it names (this session's, still
   managed, not replaced, not released) and the recorder's state;
2. registers in the model the exact resource generations it references,
   including transitive dependencies such as a pipeline's layout, as recorded
   references of the batch (`extendBatch`);
3. makes the native call.

Steps 2 and 3 are one masked step. A batch never resolves a resource again:
`replacePipeline` publishes a new generation and releases the old, and every
batch that recorded the old one keeps naming it until its references end.
In-place mutation of data a batch depends on is refused (`RefusedInUse`).

### Batches

`recordFrame` runs its consumer exactly once and seals the batch only if the
consumer returned with rendering ended and no command's native call raised.
Otherwise the batch is **partial**: its commands and references stay owned,
the slot's storage stays occupied, and it can never be submitted. A recorder
kept past its scope refuses every command.

`discardBatch` and `resetFrameRecorder` end a batch. Each first resets the
storage's pool, the native invalidation that makes submission of its commands
impossible, and only then discharges that batch's references in the model.
Neither settles the frame's acquisition or presentation obligation. An
invalidation that raised is uncertain: the batch keeps every reference, is
never invalidated again, the session fails with `CleanupFailed`, and
`BatchInvalidationFailed` is raised.

A submitted batch keeps its record and its slot's storage until its submission
completes. The next `recordFrame` for that slot then resets the storage.

### Names and labels

When the instance enabled `VK_EXT_debug_utils` and the device resolved the
naming and label entry points, the roots offer an `Instrumentation` and the
backend names what it creates and labels what it records. Without it nothing
is named and nothing fails.

- Every name is built by `boundedName` from identities the backend already
  holds, capped at 64 bytes. No caller-supplied text reaches a name. The
  scheme is `Hetoimasia.GPU.Vulkan.Native.Naming`: for example
  `target <n>.<incarnation> generation <g> swapchain` and
  `resource <n>.<generation> pipeline`.
- A naming call that raised is a failure of the thing being named, by that
  thing's own rules: a surface is not admitted, a generation fails its
  construction, a managed resource is released and its handle never returned.
  Nothing is published as named that was not.
- **Two objects are never named.** The instance, because naming requires
  external synchronization and the main thread uses the instance through the
  surface bridge's lease. The debug messenger, because the pinned loader
  forwards the naming call untranslated and MoltenVK crashes on it.
- A labelled batch's command buffer has a region for the batch
  (`batch <b> target <t> generation <g>`) and one for each dynamic-rendering
  pass. Every region still open is closed, innermost first, before
  `recordFrame` returns or raises. A closing call that raised leaves the batch
  partial; a label failure supplies no retirement evidence.

### Image transitions

The recorder tracks the frame image's layout and records each transition as
one `vkCmdPipelineBarrier2`:

| From | To | Source stage, access | Destination stage, access |
| --- | --- | --- | --- |
| Undefined | Color attachment | Color-attachment output, none | Color-attachment output, color-attachment write |
| Color attachment | Transfer source | Color-attachment output, color-attachment write | Copy, transfer read |
| Color attachment | Present source | Color-attachment output, color-attachment write | All commands, none |
| Transfer source | Present source | Copy, none | All commands, none |

Leaving for presentation names every stage as its destination so the layout
transition is ordered before the render-finished semaphore's signal; with no
destination stage, synchronization validation reported every presentation as
`SYNC-HAZARD-PRESENT-AFTER-WRITE`. These rules are a swapchain image's alone;
managed resources are ordered by
[their own contract](#ordering-managed-resources). Retention proves lifetime
only, not hazard freedom.

### Readback memory

A readback buffer is a transfer-destination buffer in the allocator's readback
usage, mapped for its lifetime.

- **The copy.** `copyToReadback` needs the frame's image in the
  transfer-source layout, from a generation built for a verification capture.
  The buffer must hold the whole image at four bytes a pixel
  (`RefusedOutOfBounds`). A buffer has one writer at a time: a copy into one
  any batch or submission still holds is `RefusedInUse`.
- **Completion before exposure.** `readReadback` answers bytes only with
  positive completion evidence: the batch that recorded the copy was recorded
  as submitted (`noteBatchSubmitted`, which requires the model's
  `submissionCarries`), and the buffer owes no recorded reference and no
  submitted use. With nothing submitted a read is `RefusedNotWritten`. A fence
  is not a host-visibility barrier; the recorded buffer barrier is.
- **Non-coherent memory** is invalidated before a read and flushed after
  `fillReadback`, as allocation-relative ranges through the allocator, so a
  neighbouring allocation in the same block is never touched.

**Capture usage.** The profile never requires transfer usage of a surface.
`planGenerationWith CaptureWhenOffered` adds it where offered and plans the
swapchain unclipped, because the verification strategy reads every pixel. Only
a host composed with [verification capture](#verification-capture) builds
generations that way.

### Buffers and images

`createBuffer` and `createImage` make opaque managed handles on the owner's
thread; the window integration lends them through the host's `Construction`
(`constructBuffer`, `constructImage`, `releaseConstructed`). A creation names
an engine-defined kind, never raw usage flags:

| Buffer kind | Usage flags | Memory usage | For |
| --- | --- | --- | --- |
| `VertexBuffer` | vertex buffer, transfer destination | `UsageStaticGeometry` | static vertex data, staged |
| `IndexBuffer` | index buffer, transfer destination | `UsageStaticGeometry` | static index data, staged |
| `InstanceBuffer` | vertex, index and storage buffer | `UsageFrameRing` | per-frame instance data and the shared ring |
| `LookupBuffer` | storage buffer | `UsageFrameRing` | a per-frame lookup table |
| `StagingBuffer` | transfer source | `UsageStaging` | host-written bytes the device copies from |

| Image kind | Usage flags | Memory usage | Aspect | Formats |
| --- | --- | --- | --- | --- |
| `TextureImage` | sampled, transfer destination and source | `UsageTexture` | color | RGBA8 and BC7, each sRGB and linear |
| `DepthTarget` | depth-stencil attachment | `UsageTexture` | depth | `D32_SFLOAT`, `X8_D24_UNORM_PACK32`, `D16_UNORM` |
| `ColorTarget` | color attachment, transfer source | `UsageTexture` | color | RGBA8 and BGRA8, each sRGB and linear |

An image is two-dimensional, one layer, one sample, optimally tiled, created
in the undefined layout, and owns exactly one view of its whole resource.
Before anything native is created:

- a zero-size or oversized buffer, a zero extent or mip count, or more mips
  than the full chain is `RefusedOutOfBounds`;
- a format the kind does not take, a BC7 image on a device without
  `textureCompressionBC` (the feature is enabled exactly when offered), or a
  combination the device's format query does not support is
  `RefusedImageUnsupported`.

An attempt reserves its objects and no bytes: two for a buffer, three for an
image. A creation that raised before it was committed destroys what it made
and returns no handle. `releaseManaged` ends logical and CPU use together, and
`disposeResources` destroys a resource only once the model reports every hold
ended; a destruction that raised is uncertain, never retried, and fails the
session. `readManaged` reports each resource with its kind, standing and
native handles.

### Ordering managed resources

The recorder applies the model's pure ordering rules
([gpu_model.md](gpu_model.md#ordering-managed-resources)) to every access a
batch makes to a managed buffer or image, and maps them onto Vulkan. Swapchain
images keep [their own path](#image-transitions).

| Kind | Resting use | Resting layout | Resting stages | Resting accesses |
| --- | --- | --- | --- | --- |
| `TextureImage` | `ShaderSampled` | shader-read-only | fragment shader | shader sampled read |
| `DepthTarget` | `DepthAttachment` | depth attachment | early and late fragment tests | depth-stencil attachment read and write |
| `ColorTarget` | `ColorAttachment` | color attachment | color-attachment output | color-attachment read and write |
| `VertexBuffer`, `IndexBuffer` | `GeometryRead` | none | vertex input | vertex attribute or index read |
| `InstanceBuffer` | `InstanceRead` | none | vertex input, vertex and fragment shaders | vertex attribute, index and shader read |
| `LookupBuffer` | `StorageRead` | none | vertex and fragment shaders | shader storage read |
| `StagingBuffer` | `TransferRead` | none | transfer | transfer read |

Other legal uses: `TransferWrite` for a texture and for vertex and index
buffers, and `TransferRead` for a color target. Instance, lookup and staging
buffers are host-written; the submission after a host write makes it visible,
so no scope names the host.

- **Transitions.** `transitionResource` moves a buffer or image within a
  batch from the use the batch left it in (or from undefined, images only)
  into another legal use. An illegal use is `RefusedUnsupported`; a move from
  the wrong use or inside rendering is `RefusedIllegal`.
- **Boundary barriers.** A batch's first touch finds the resource at rest and
  is recorded as the entry barrier. When the consumer returns with every
  touched resource back at rest, the recorder records an exit barrier for
  each. Consumers never record either. On the one graphics queue each batch's
  entry barriers chain to earlier batches' exit barriers, ordering accesses
  between batches even when no layout changes.
- **Sealing.** A batch whose consumer leaves a resource away from rest is
  refused (`RefusedIllegal`) and left partial; exit barriers never stand in
  for the transition the consumer omitted.
- **Initialization.** A new image awaits initialization. The first batch that
  touches it must initialize it by a transition from undefined; any other
  first touch, and any touch by another batch before the initializing batch
  is submitted, is `RefusedUninitialized`. Only a submission the queue
  accepted publishes the initialization. A discard, reset, skipped frame or
  uncertain submission leaves the image uninitialized again.

### Offscreen color targets

A managed `ColorTarget` can be rendered into and read back, in a frame batch
and a [frame-less batch](#frame-less-batches) alike.

- **The pass.** `beginRenderingInto recorder image start clear` begins dynamic
  rendering with the target's owned view as the one color attachment, cleared
  across its whole extent. `ClearTarget` keeps the contents and requires an
  initialized target; `ClearFromUndefined` discards them and is the
  initialization a new target awaits.
- **Refusals before any native call:** a foreign handle
  (`RefusedMisuse ForeignIdentity`), a released or stale one
  (`RefusedMisuse WrongPhase`), a non-color-target (`RefusedWrongKind`), more
  than one mip level (`RefusedUnsupported`), an extent beyond the device's
  framebuffer limits (`RefusedOutOfBounds`), or a pass already open.
- **The attachment governs.** A pipeline, viewport and scissor are checked
  against the open pass's attachment, and a draw checks them again, so state
  bound for one attachment never reaches another's draw. A pipeline built for
  another format is `RefusedIncompatible`. Outside rendering a frame-less
  batch refuses them.
- **The copy.** `copyTargetToReadback` copies mip level 0 of the whole target
  into a readback buffer. The target must be in its `TransferRead` use (the
  consumer's explicit transition) and be returned to rest afterwards.
- **The bytes** are the target's rows, top row first, four bytes a pixel in
  the target's own component order, tightly packed, with no conversion: an
  sRGB target's bytes are its encoded values. They are exposed exactly as a
  frame image's are, only after the recording batch's submission completed.
  The window integration lends a readback through `constructReadback`,
  `readConstructedReadback` and `releaseConstructed`.

### Depth attachments

A managed `DepthTarget` can be the depth attachment of a pass into a managed
color target, in either batch kind.

**Conventions.** Coordinates follow Vulkan's: clip-space Y points down and
depth runs 0 at the near plane to 1 at the far plane. A depth attachment is
depth-only; no stencil format exists in the vocabulary. A pass clears depth to
1.0 unless given another value, and a pipeline compares less-or-equal unless
it declares another operation, so a renderer that reverses depth needs nothing
more. A matching projection is `hetoimasia-math`'s
`perspective ZeroToOne YDown`.

- **The depth format.** `selectDepthFormat` (`constructDepthFormat` through
  the host) answers the first of `D32_SFLOAT`, `X8_D24_UNORM_PACK32`,
  `D16_UNORM` the device supports as a depth attachment, asking the device.
  None is `RefusedImageUnsupported`. `imageFormatOf`
  (`constructImageFormat`) answers a live image's format.
- **Pipelines** declare depth with `createPipelineWithDepth` or
  `createDepthCheckedPipeline`, given a `PipelineDepth`: the attachment
  format, whether fragments are tested, whether they write (writing without
  testing is `RefusedIllegal`), and the compare operation. `depthTested format`
  is testing, writing, less-or-equal. Every other pipeline constructor, and
  `replacePipeline`, declares no depth.
- **Passes.** `beginRenderingWithDepth recorder color start clear depth` adds
  a `DepthPass` (`clearedDepth target start` clears to 1.0). The color and
  depth targets are entered and retained in one transaction. The depth target
  must be this session's, live, a `DepthTarget`, of one mip level and of the
  color target's extent (`RefusedIncompatible` otherwise), and the clear value
  finite and within 0 to 1.
- **Pipeline and pass agree.** A pipeline is drawn only in a pass whose depth
  attachment has exactly the format it declares, and one that declares none
  only in a pass that has none. This is checked when a pipeline is bound and
  again by every draw (`RefusedIncompatible`).
- **Clearing depth within a rectangle.** `clearDepthRect recorder rect value`
  clears the open pass's depth attachment within `rect` (render-area pixels,
  wholly inside the render area) and leaves the rest unchanged. It needs no
  bound pipeline, viewport or scissor, is not narrowed by the scissor, and is
  ordered with the pass's draws as a draw is. A world layer that clears its
  own depth within its viewport uses it.

Out of scope: reversed-Z as a default, stencil, multisampling, and more than
one color attachment. Depth cannot be read back.

### Windowed depth

Each swapchain generation of a window can own a managed depth image, so a
renderer can draw into the window with a depth test.

**The setting.** `VulkanHostConfig`'s `vulkanWindowDepth` is `False` by
default, and nothing then changes: no generation has a depth image, no
`FrameRequest` names one (`requestDepth` is `Nothing`) and the device is asked
nothing about depth. When it is `True`, the controller asks the generations
for a depth image with every generation (`requireWindowDepth`), and **no
generation is constructed** until the recording supplies what makes the images
(`supplyRecordingWindowDepth`). The owner's step makes the recording before
the generations' step, so no generation is ever published without the depth it
was configured for.

**One image per generation.** Each generation owns one depth image of its
extent, in the format `selectDepthFormat` answers, with one owned view, shared
by every frame in flight of that generation. It is made last in the
generation's construction, as a managed image of the recording's
(`createImage`): its memory is charged by the allocation protocol, it awaits
initialization until the first pass that clears it from undefined has been
submitted, and every batch that records a pass with it holds it until that
batch has completed. It is named from the generation's identity, and
`windowDepthOf recording generation` answers the handle of a live one.

**The frame's pass.** A windowed frame's request names its generation's depth
image (`requestDepth`), borrowed from the generation: the renderer cannot
release it (`releaseManaged` of it is `RefusedIllegal`).
`beginFrameRenderingWithDepth recorder clear depthPass` begins rendering into
the frame's image with the depth image as the depth attachment, in a frame
batch only (`RefusedUnsupported` in a frame-less batch), under the same rules
and refusals as `beginRenderingWithDepth`. Frames in flight of one generation
share the image and are ordered by the boundary barriers, whether a pass
clears from undefined each time or keeps the contents.

**Following the generation.** A resize or replacement builds a new generation
with a depth image of its own. The old generation's image is released when the
generation is destroyed, which happens only once every hold on the generation
has ended, and the model destroys the image only once every batch that
recorded it has completed. Two overlapping generations each have their own
image. A lost surface retires its generation and the image with it; the
recovered generation gets a new one. The recording's own retirement does not
release a generation's depth image: a recording retiring while the generation
stands retains it (`ResourcesRetained`). Under device loss the image is
released and destroyed under the device-loss rule.

**Failure.** A depth image that cannot be made fails its generation's
construction (`ConstructionFailed`, a recovery attempt), and anything charged
is given back. An out-of-memory result gets the one allocation recovery. A
byte or object budget that cannot hold it is `RefusedBackpressure`. A
cancellation inside the image's or view's creation leaves the candidate
uncertain and fails the session with `CleanupFailed`. Nothing leaves a
generation without the depth it was configured for, or an image owned by no
generation.

### Drawing from buffers

Batches draw from vertex, index and instance data with push constants, and
each session has one shared ring of host-visible memory that batches claim
regions of. A bind is a use of a buffer under the ordering contract above.

- **Push constants.** `createPipelineLayoutWith recording ranges` makes a
  layout with `PushConstantRange`s (stages, offset, size). Each range must
  name a stage, have an offset and size that are multiples of four, and end
  within `maxPushConstantsSize`; no stage may be named by two ranges.
  `pushConstants` requires a bound pipeline, and every range the pushed bytes
  overlap must be pushed for all its stages. Past a limit or range is
  `RefusedOutOfBounds`; anything else invalid is `RefusedIllegal`.
- **Vertex input.** `createPipelineWith ... input` takes a `VertexInput` of
  bindings (number, stride, `PerVertex` or `PerInstance`) and attributes
  (location, binding, format, offset), for triangle lists. It is checked
  against the device's limits and Vulkan's rules before any native call.
  Strides and offsets are multiples of four. The formats offered are ones
  every device must support. A batch checks every push, bind and draw against
  the pipeline bound now; a pipeline switch changes what is checked and leaves
  bound data bound.
- **The ring.** `createRing recording size` (`constructRing` through the
  host) makes the session's one ring; a second is
  `RefusedMisuse DuplicateSubject`. The size is validated, never clamped. The
  configured size is the claimable size `R`; a ring with a storage-table
  window is `R + W` bytes, and claims use only the first `R`.
- **Claims.** `claimRegion recorder size alignment` claims a region for the
  recording batch and `writeClaim` writes into it.
  - On non-coherent memory a region starts on and is padded to the device's
    `nonCoherentAtomSize`, so no two claims share an atom, and each write is
    flushed at once.
  - A claim that does not fit now is `RefusedBackpressure RingBudget`, after
    reclaiming completed batches' regions. One larger than the whole ring is
    `RefusedOutOfBounds`, permanently.
  - A region is the batch's until its submission completes or the batch is
    discarded or reset. An invalidation that raised, an unknown submission
    effect and a device loss reclaim nothing.
  - A claim number is never reissued. Writes are admitted only while the batch
    records (`RefusedRecorderClosed` afterwards).
  - The batch's first claim records the ring's entry barrier, so a first claim
    inside a pass is `RefusedIllegal`.
- **Binding and drawing.** `bindVertexBuffer` and `bindIndexBuffer` take a
  `BufferSource`: `FromBuffer` a managed buffer or `FromClaim` a claimed
  region. A wrong kind is `RefusedWrongKind`. A first touch inside a pass is
  `RefusedIllegal`: bind before the pass. `draw` and `drawIndexed` require
  every binding the bound pipeline declares to be bound with enough data, and
  check each buffer again at draw time (still recordable, still in the use it
  was bound in).
- **Indexed reads.** For index data in a ring region the batch wrote, the
  recording reads the indices when the draw is recorded, bounds every
  per-vertex binding's reads by the largest index, and from then on refuses
  any write of the batch into those bytes. A managed index buffer filled by a
  completed upload bounds reads the same way. Index data the recording cannot
  read cannot bound them, so an indexed draw through it that reads per-vertex
  data is `RefusedUnsupported`.

Every bind retains exactly what it references. The window integration lends
`constructPipelineLayoutWith` and `constructPipelineWith`.

### Blending

A `PipelineRequest` carries a `PipelineBlend`: `BlendNone` (the output
replaces the attachment's contents; every pipeline that declares nothing) or
`BlendPremultipliedAlpha` (source factor `ONE`, destination factor
`ONE_MINUS_SRC_ALPHA`, operation `ADD`, for colour and alpha:
`source + destination × (1 − source alpha)`). No other blend mode exists.
`createBlendedCheckedPipeline` (`constructBlendedCheckedPipeline`) builds a
pipeline from checked shaders with a declared blend.

### Checked shader interfaces

Every shader that reads anything from the host is checked against a Haskell
description of that interface while the package builds, with no native tool,
and pipelines are built from the descriptions.

- **Descriptions.** A `ShaderInterface`
  (`Hetoimasia.GPU.Vulkan.Native.Shader.Interface`) names its stage and what
  the host supplies: the push-constant block's members (offset and size), for
  a vertex shader its `VertexInput`, and its descriptor bindings (set,
  binding, kind, and `DescriptorCount n` or `RuntimeSized`). SPIR-V cannot say
  a binding's rate or stride or an attribute's binding, offset or storage
  format, so those are the description's; only each attribute's location and
  shader type are compared.
- **The reader** (`Shader.Reflect`, in the private `shader-toolchain` library)
  reads a module's entry point, push-constant block, non-built-in vertex
  inputs and descriptors from its SPIR-V words. Its input is SPIR-V from the
  pinned compiler. It checks every instruction it consumes against one
  explicit whitelist (operand counts, declared-before-use ids, decoration
  literals, storage classes, explicit block layouts obeying std140 for
  Uniform blocks and std430 for StorageBuffer and PushConstant blocks) and
  refuses a module or shape it does not support with a diagnostic, never
  reading it as empty or matching. Exhaustive semantic validation of arbitrary
  SPIR-V is out of scope (owner amendment, 2026-10-03). Enabling
  `scalarBlockLayout` or `uniformBufferStandardLayout` would be a new device
  requirement and is not one.
- **The checked splices** (`checkedVertexShader`, `checkedFragmentShader` and
  their file forms) compare the SPIR-V's interface with the description in
  both directions and fail the build naming every mismatch. A shader that
  passes is a `CheckedShader`.
- **Unchecked splices** (`vertexShader`, `fragmentShader`, their file forms)
  compile only interface-free shaders; one that declares a push-constant
  block, vertex input or descriptor binding fails the build. Compute shaders
  are out of scope.
- **Pipelines.** `checkedRanges` derives the push-constant ranges a pipeline
  over a `CheckedShaders` pair needs; stages whose blocks disagree are
  `RefusedIncompatible`. `createPipelineLayoutFor`, `createCheckedPipeline`
  and `replaceCheckedPipeline` keep the descriptions authoritative, refusing a
  supplied layout with other ranges. The host lends
  `constructPipelineLayoutFor`, `constructCheckedPipeline` and
  `replaceConstructedCheckedPipeline`.

### Uploads

Uploads move bytes into a fresh texture, vertex buffer or index buffer through
one bounded, host-visible staging buffer the graphics owner holds. The owner
records copies from it into frame-less batches in chunks under a per-turn byte
budget. Each upload has a ticket, which completes only when the batch carrying
its final copies completes. `Hetoimasia.GPU.Vulkan.Native.Uploads` is the
public surface.

**Configuration.** `validateUploadConfig staging budget queue` validates the
staging size, the bytes recorded per turn and the number of unsettled uploads,
and never clamps. The turn budget must hold one block row of the widest level
any image may have (four bytes per texel of `maxImageDimension2D`), or
`newUploads` is `RefusedOutOfBounds`. The window integration takes the
configuration as `vulkanUploads` (default `Nothing`: no uploads) and makes the
uploads in the first owner round in which the device exists.

**Admission.** `submitUpload uploads request` runs on any thread
(`submitVulkanUpload` through the host, gated on the owner's admission).
`UploadImage image levels` carries every mip level, base first;
`UploadBuffer buffer bytes` the whole buffer. One transaction decides, in this
order:

1. the session is running (`UploadSessionFailed`) and admission open
   (`UploadClosed`);
2. the target is this session's and live (`UploadMisuse`);
3. no other unsettled upload writes into it (`UploadAlreadyTargeted`);
4. it is a texture, vertex buffer or index buffer (`UploadWrongKind`), and not
   BC7 on a device without it (`UploadUnsupportedFormat`);
5. it is fresh (`UploadNotFresh`): a texture still uninitialized, or a buffer
   no upload was admitted into and no batch holds;
6. the bytes initialize it exactly (`UploadMalformed`);
7. the padded size fits the whole staging buffer (`UploadOversized`, a
   permanent refusal);
8. the queue and staging have room now (`UploadBackpressure`, as `QueueFull`
   or `StagingFull`).

The transaction reserves the target, the queue place and the staging region
and makes the ticket. The caller's thread then copies the bytes into the
region, so its bytes are free when admission returns. If the copy raises or is
cancelled, every reservation is given back.

**The exclusive target.** From admission until its upload settles, a target
belongs to the upload alone: every other batch's use of it is
`RefusedUninitialized`, disposal does not destroy it, and releasing it is
deferred until the upload settles. A released target whose upload had not
started is cancelled; one already started completes first.

**Progress.** `progressUploads` runs once per owner step, after the fence
poll. It settles uploads lost to a device loss, observes each batch in flight
(complete, discarded so re-recorded from the same staging bytes, or lost),
cancels unstarted uploads whose target was released, then records the next
copies of each upload with no batch in flight, in admission order, into one
frame-less batch, up to the turn's budget.

- A texture's copies are whole block rows of one level at a time; a buffer's
  are byte ranges.
- An upload has at most one batch in flight.
- On its first chunk the target enters transfer write from undefined; between
  chunks it rests in transfer write; after its final chunk it moves to its
  kind's resting use.
- A staging region is freed only when its upload settles.
- If the batch cannot be opened now, nothing is recorded that turn and a stall
  flag keeps the owner from spinning.

**Tickets** only advance: `UploadQueued`, `UploadUploading`, then one of the
terminal `UploadComplete`, `UploadCancelled`, `UploadLost`.
`awaitUploadTicket ticket duration` waits at most that long and cancels
nothing; it is `RefusedOwnerWait` on the owner's thread. `cancelUpload` works
only before the owner claims the upload (`CancelStarted` afterwards).

**Exit.** `closeUploads` closes admission before the drain and cancels
unstarted uploads. `retireUploads` waits for any caller still copying into
staging, then settles what remains as lost (after device loss) or cancelled.

**What an upload leaves behind.** A completed index-buffer upload keeps the
indices it wrote, which bound indexed draws through that buffer.
`copyLevelToReadback recorder image level readback` copies one mip level of a
texture into a readback, so a consumer can compare what it uploaded.
`readUploads` shows each unsettled upload.

### The texture table

The bindless texture table gives a registered texture a stable handle. Shaders
resolve the handle through a lookup version that each batch freezes when it
first binds the table, then sample one update-after-bind array of images with
one of four shared samplers. The pure rules (handles, versions, slot reuse)
are `Hetoimasia.GPU.Model.TextureTable`; the public native surface is
`Hetoimasia.GPU.Vulkan.Native.TextureTable`.

**The profile.** The table needs six Vulkan 1.2 descriptor-indexing features,
which device selection requires and the roots enable:
`runtimeDescriptorArray`, `descriptorBindingPartiallyBound`,
`descriptorBindingSampledImageUpdateAfterBind`,
`shaderSampledImageArrayNonUniformIndexing`,
`descriptorBindingVariableDescriptorCount` and
`descriptorBindingUpdateUnusedWhilePending`. A device missing any is refused
with `DeviceFeatureMissing`. Non-uniform indexing is enabled, dynamic indexing
is not.

**Configuration.** `validateTableConfig capacity initial versions` validates,
never clamping: the cap (slots the layout declares), the initial size (slots
the set allocates, slot 0 included, at least two), and the version ring's
length (`defaultVersionCount`, 8).

**Making it.** `createTextureTable recording uploads config` makes the
session's one table on the owner's thread, after checking the cap, samplers,
pools, sets and ring against the device's limits (`RefusedOutOfBounds`). It
makes, each as a managed generation:

1. four immutable samplers, in index order: nearest/clamp-to-edge,
   nearest/repeat, linear/clamp-to-edge, linear/repeat;
2. set 0's layout: binding 0 the four samplers, binding 1 the sampled-image
   array declared at the cap (update-after-bind, partially bound,
   variable-count);
3. set 1's layout: one dynamic storage buffer. An update-after-bind set may
   not hold a dynamic buffer, which is why there are two sets;
4. a pool and a set for each;
5. the version ring: one host-visible lookup buffer. One version is the cap's
   lookup entries of eight bytes each (little-endian slot, then generation).
   Set 1 and the ring are sized for the cap and never rebuilt; only set 0
   grows;
6. one managed version generation per ring entry, which a batch that binds the
   table at that entry retains;
7. slot 0's placeholder: a 1×1 transparent-black RGBA8 texture, uploaded
   through the session's uploads.

The table can be bound once the placeholder's upload has completed; until then
binding is `RefusedNotWritten`.

**Handles.** `registerTexture recording image` takes a live texture of this
session and answers a `TextureHandle`: a lookup index and a generation that is
never zero and never persisted.

- Until the image's upload has completed, the handle resolves to slot 0.
- From registration on the table holds the image: `releaseManaged` on it is
  refused, and `releaseTexture` ends the handle instead.
- Registration refuses a non-texture, an already registered image
  (`DuplicateSubject`), and a full table at its cap
  (`RefusedBackpressure TextureSlotBudget`).
- A released, older-generation or never-issued handle is `RefusedStaleHandle`.

**Versions.** A version is a whole-table copy of every lookup index's slot and
generation. A new one is published only when a mapping changed, into a ring
entry no batch holds. When a new version is owed and every other entry is
held, binding is `RefusedBackpressure LookupVersionBudget`.

**Slot reuse.** A slot is reused, and its descriptor rewritten, only once no
live version maps it. So a batch recorded before a texture is released or
replaced still samples the original image when it is submitted later, and the
image stays held until that batch completes.

**Growth.** When registration finds no free slot, set 0 doubles (never past
the cap): a new pool and set are made over the same layout, every written
descriptor is copied across, and the new set becomes current for later
batches. Pipelines and layouts built before the growth stay compatible.
Handles, slots and versions are unchanged. A failed growth destroys its pool
and leaves everything as it was. A native out-of-memory gets the one
allocation recovery; unrecovered it raises `AllocationNotRecovered`.

**Swaps.** `swapTexture recording handle image` lets a live handle show a
replacement texture (hot reload's GPU half) and answers a `SwapTicket`.

- The swap reserves a slot and changes no mapping until the replacement's
  upload completes; the handle keeps showing its current texture, never the
  placeholder.
- When it takes effect the ticket reads `SwapPublished`. Earlier batches keep
  their version and the old texture, which is released at once in the model
  and destroyed only when those batches have completed.
- A second swap on the handle supersedes the first (`SwapSuperseded`);
  releasing the handle abandons it (`SwapAbandoned`); a cancelled or lost
  upload, or a failed session, fails it (`SwapFailed`). A ticket is settled
  once, and a device loss is never reported as success.
- Only the upload the swap accepted may fill its replacement.

**Bringing it up to date.** `refreshTable` writes newly complete textures,
makes completed swaps take effect, ends failed ones, and reclaims retiring
slots no live version maps. It runs before every binding, after every
registration, and once per owner step. Once the session has failed it writes
nothing but still reclaims.

**Pipelines.** A table pipeline layout holds both set layouts and exactly the
checked shaders' push-constant ranges. Shaders may declare only the table's
own bindings; set 0 is visible to the fragment stage alone. There are two
kinds:

- *Pushed* (`createTablePipelineLayout recording shaders samplerOffset`): the
  recorder pushes the sampler index at the declared offset with
  `selectSampler`, so every draw samples with one sampler.
- *Shader-sampled* (`createShaderSampledTablePipelineLayout`,
  `constructShaderSampledTablePipelineLayout` through the host): the shaders
  choose their samplers per instance from vertex input, and no push-constant
  bytes are reserved. The 2D renderer uses this kind.

**Binding and drawing.** `bindTable recorder` binds both sets with the dynamic
offset of the batch's version. A batch's first binding pins the current set 0
and version and retains everything the version maps; later bindings in the
batch bind the same pair. A draw through the table needs the table bound under
a compatible layout, every mapped image in its sampled use, and, under a
pushed layout, a selected sampler (index 0 to 3). Binding a pipeline of the
other kind, or one without the table, disturbs the binding and the selection.

**The shader's obligations under a shader-sampled layout.** The backend cannot
see per-instance data, so the shader must:

- clamp the sampler index it reads to 3
  (`samplers[nonuniformEXT(min(index, 3u))]`); an unclamped index past the
  array is undefined behaviour the backend cannot refuse;
- index with `nonuniformEXT`: the sampler index, the slot index and the
  combined sampled image.

A handle resolves in the shader: an index past the version's entries, or an
entry whose generation differs from the handle's, resolves to slot 0 before
any descriptor is read. `tableShaders` and `tableInstanceShaders` (in
`Recording.Shaders`) are the reference pairs.

### Per-batch storage tables

A batch can bind a table it wrote to the shared ring as a storage buffer
(set 2), beside the texture table. `render-2d-vulkan` uses it for per-batch
clip tables and material records; the semantics of what is written are the
client's.

- **The window.** The application configures a storage-table window of `W`
  bytes (`validateStorageWindow`, never clamped). `createRingWith recording
  size (Just window)` (`constructRingWith`) refuses a window beyond
  `maxStorageBufferRange` or beyond the ring's claimable size, and a total
  `R + W` beyond `maxBufferSize`. The tail keeps a window that starts at any
  claimable offset inside the buffer.
- **Set 2.** `createStorageTable recording` (`constructStorageTable`) makes,
  once per session, a set layout with one dynamic storage buffer visible to
  the vertex and fragment stages, its pool and its set, covering the ring from
  offset 0 over `W` bytes. It needs a ring made with a window. The device's
  ordinary limits are checked first (`RefusedLimit`); the update-after-bind
  counterparts are not read, since they may legally be zero.
- **Layouts.** `createTablePipelineLayoutWith recording shaders options`
  (`constructTablePipelineLayoutWith`) names the sampler mode and whether the
  layout holds set 2, declared after the texture table's two sets. It needs
  both the texture table and the storage table. Shaders under such a layout
  may declare set 2's binding (`storageTableDescriptors`); under any other
  layout declaring it is refused.
- **Claiming and binding.** `claimTable recorder size` is `claimRegion` at
  the device's `minStorageBufferOffsetAlignment`. `bindStorageTable recorder
  claim offset` binds set 2 alone with a dynamic offset of the claim's start
  plus `offset`. It is refused for a stale or foreign claim, an offset past
  the claim's end, a table larger than the window, and a misaligned offset.
- **The shader's obligation.** The window is a descriptor window, not
  ownership of every byte it exposes. A shader's reads must stay within the
  bound claim, from the bound offset to the end of the bytes claimed; the
  backend cannot see them.
- **Drawing.** A draw with a pipeline whose layout holds set 2 is refused
  unless set 2 is bound under a compatible layout. A pipeline switch disturbs
  it under the same rules as the texture table's binding.

### Destruction

`disposeResources` destroys, on the owner, every released generation whose
holds the model reports ended, and records each disposal. A pipeline layout
waits until every pipeline built over it is destroyed. A destruction that
raised is uncertain, never retried, fails the session with `CleanupFailed`,
raises `ResourceDestructionFailed`, and retains everything that depends on it.
`retireRecording` releases every live handle, destroys what it can and raises
`ResourcesRetained` naming the rest, without manufacturing evidence. Every
managed resource must be gone before the device.

### The FFI audit

The binding is compiled with `+safe-foreign-calls`, so every import of its own
is `safe`. The package's only `unsafe` Vulkan imports are the twenty `dynamic`
imports in the private `Internal.Commands`, each a command-recording call
through the device dispatch table the binding resolved:

`vkBeginCommandBuffer`, `vkEndCommandBuffer`, `vkCmdPipelineBarrier2`,
`vkCmdBeginRendering`, `vkCmdEndRendering`, `vkCmdBindPipeline`,
`vkCmdSetViewport`, `vkCmdSetScissor`, `vkCmdDraw`, `vkCmdClearAttachments`,
`vkCmdPushConstants`, `vkCmdBindVertexBuffers`, `vkCmdBindIndexBuffer`,
`vkCmdDrawIndexed`, `vkCmdBindDescriptorSets`, `vkCmdCopyImageToBuffer`,
`vkCmdCopyBuffer`, `vkCmdCopyBufferToImage`, `vkCmdBeginDebugUtilsLabelEXT`,
`vkCmdEndDebugUtilsLabelEXT`.

Each may be `unsafe` for the same reasons: it records into a command buffer
the calling thread owns; it does not execute, wait on the device or block on
another thread; and it cannot call back into Haskell, because the package
installs no Haskell callback, allocation callback or trampoline. The only code
a validation layer can reach from inside one is the C-only capture messenger.
Everything else stays `safe`: waits, queue submission, presentation, pipeline
creation, every construction and destruction, pool resets and mapped-memory
maintenance. Every unsafe call sits inside the same masked step as the
retention before it and the count after it.

The second set of `unsafe` imports is the allocator's VMA shim
(`Internal.Vma`, over `cbits/hetoimasia_vma.cpp`). VMA's device-memory
callbacks are C functions, so none of those calls can enter Haskell, and they
are made on the owner's thread alone.

`nativeFfiConfiguration` records both lists, the binding's flags and the
C-only callback. The headless suite reads the package's own import
declarations and requires exactly those imports, so adding an `unsafe` import
means extending this audit and that list together.

## Frames: acquisition, submission and abandonment

`Hetoimasia.GPU.Vulkan.Native.Frames` sits above the recording, over an open
native layer `FrameOps`. Every operation belongs to the graphics owner
(`RefusedNotOwner` otherwise). The model decides what every frame owes
([gpu_model.md](gpu_model.md#frame-ownership)); this module makes the native
calls and supplies the facts it observed.

### The operations

| Operation | What it does |
| --- | --- |
| `tryAcquireFrame target` | Reserves the frame in the model (slot, presentation-pool record, submission record), makes the slot's synchronization if needed, and acquires one image with a zero timeout |
| `recordFrame` | Runs the consumer once and seals one batch for the frame |
| `submitFrames batches` | Validates the whole request, resets one fence, and submits every batch in order as one `vkQueueSubmit2` |
| `skipFrame frame` | Consumes an acquired, unsubmitted frame: invalidates its recording, skips it in the model, and makes a cleanup submission |
| `closeUnpresentedFrame frame` | Closes a submitted frame that will never be presented |
| `presentFrame frame` | Resets the pool record's present fence and presents the image |
| `closeTargetFrames target` | Skips every acquired frame of a target and closes every submitted one |
| `progressFrames now` | The owner's bounded step: observes pending fences, makes owed cleanup submissions, returns images |
| `awaitFrames now timeout` | A finite wait (at most `drainWaitLimit`, 10 ms) on one pending fence, then `progressFrames`. The wait is never evidence |
| `retireTargetFrames target` | Destroys a target's synchronization once nothing of it is live or pending, or raises `FramesRetained` |
| `releaseFramesToDeviceLoss` | After device loss: lets go of everything only the lost device could have discharged |

Frame capacity is the model's: two slots per target by default. An
acquisition refused for want of a slot, pool record or accounting answers
`AcquisitionPending (PendingBackpressure kind)` before any native call.

### Slot synchronization

Each frame slot owns an acquisition semaphore, a submission fence and a
cleanup fence, made together the first time the slot is reserved. So an
acquired frame always has the synchronization its abandonment needs. The
render-finished semaphore is not the slot's: it belongs to the frame's
presentation-pool record, because a presentation waits on it for longer than
the slot is held.

### Acquisition

A failed session refuses first (`RefusedSessionFailed`). A suspended target
answers `AcquisitionSuspended`, a retiring one `AcquisitionClosing`, an
unavailable one `AcquisitionUnavailable`. A target acquires from its active
generation while it is presenting and also while a replacement is settling or
backpressured, so a live resize keeps rendering.

| The call answered | The model | The answer |
| --- | --- | --- |
| `VK_SUCCESS` | The frame owns the image | `AcquisitionOwned` |
| `VK_SUBOPTIMAL_KHR` | The frame owns the image; a replacement is requested | `AcquisitionOwned`, suboptimal |
| `VK_NOT_READY`, `VK_TIMEOUT` | The reservation goes back whole | `AcquisitionPending PendingNoImage` |
| `VK_ERROR_OUT_OF_DATE_KHR` | The reservation goes back; a replacement is requested | `AcquisitionPending PendingReplacement` |
| `VK_ERROR_SURFACE_LOST_KHR` | The reservation goes back; the surface is [replaced](#replacing-a-lost-surface) | `AcquisitionPending PendingSurfaceLost` |
| It raised | The reservation goes back | The failure is re-raised |

A successful acquisition the model then refused to record is an uncertain
effect: the slot is retained for ever, the session fails with `CleanupFailed`,
and `FrameEffectUncertain` is raised.

A synchronization construction that fails part-way destroys every object it
made, newest first, with the construction's failure primary. If one of those
destructions raised, the slot or record is published held by no frame, marked
uncertain, never destroyed again, and the session fails with `CleanupFailed`.

### Submission

`submitFrames` refuses before any native call: a foreign, duplicated,
consumed, partial or still-recording batch; a batch whose frame this owner did
not acquire; two batches of one frame; and anything the model would refuse.
Then, in one masked step, the first frame's slot fence is reset and the
submission is made. Each batch waits on its frame's acquisition semaphore at
the color-attachment-output stage and signals its pool record's
render-finished semaphore.

- **It returned.** The model records one submission every frame of the
  request shares, and each batch is recorded as submitted. Separate calls are
  separate submissions; a shared request is never split.
- **A specified no-effect failure** (out of memory). Nothing is pending and
  every frame is still acquired with its batch sealed. It gets the one
  [allocation recovery](#allocation-recovery); otherwise `SubmittedNothing`.
- **The fence reset raised.** Nothing was submitted, but the fence is marked
  uncertain and the session fails with `CleanupFailed`. The frames can still
  be skipped.
- **Anything else raised.** Whether anything was submitted is unknown. Each
  frame enters the model's uncertain-effect state, the session fails, and
  `FrameEffectUncertain` (or the device loss) is raised. Nothing is rolled
  back.

### Abandonment

- **A skipped frame.** `skipFrame` is legal only for an acquired frame with
  nothing submitted. Its recording is invalidated natively, then discharged;
  a cleanup submission that runs no command waits on the acquisition
  semaphore; once its fence has signalled, `progressFrames` returns the image
  through `vkReleaseSwapchainImagesEXT` and supplies the frame's settlement.
  The swapchain is not rebuilt.
- **A submitted frame never presented.** `closeUnpresentedFrame` keeps its
  submission and image. `progressFrames` waits for its submission's fence,
  settles the render-finished semaphore through a tracked cleanup submission,
  and only then returns the image.
- A cleanup submission or release that raised retains the frame for ever,
  never retried, fails the session with `CleanupFailed` and raises
  `FrameCleanupFailed`. A failed cleanup is never recoverable pressure,
  whatever the target's designation.

### Completion and the owner's step

Only a fence a queue operation made pending is ever asked whether it has
signalled, and only without waiting (`vkGetFenceStatus`), inside
`progressFrames`. A signalled submission fence is the model's
`SubmissionCompleted` fact; a signalled present fence is `PresentationRetired`;
a signalled cleanup fence followed by a returned release is
`UnpresentedFrameSettled`. Nothing else (elapsed time, a returned call, a
cancellation, a reset fence) becomes any of them. Completions are also
appended to a log (`readCompletedSubmissions`, `takeCompletedSubmissions`).

A step makes at most the model's progress-action limit of native calls and
starts one place further along its work each time, so a fence that never
signals cannot hold back a later one. It raises only after recording
everything that returned: device loss first, then the first cleanup failure
or uncertain effect.

**The protected handoff.** Each native effect and the bookkeeping of its
result are one masked step. A cancellation is delivered only before the call
or after its result is recorded; it never undoes an effect or turns a pending
fence into completion. No consumer code runs inside a handoff.

### How the frames are built

Eight private modules under `Internal.Frames`: `Layer`, `State`,
`Acquisition`, `Submission`, `Presentation`, `Abandonment`, `Loss` and
`Progress`. Every call the production layer makes is the binding's own and
`safe`.

## Presentation and retirement

### Presentation

`presentFrame frame` presents one submitted frame's image to the swapchain it
was acquired from. It refuses before any native call on another thread, in a
failed session, for a frame not submitted or already presented, and for
anything the model would refuse. Presenting is never refused for capacity,
because the pool record was reserved with the frame. The frame's rendering
need not have completed: the presentation waits on the render-finished
semaphore on the device.

In one masked step the pool record's present fence is reset and
`vkQueuePresentKHR` presents the image with that fence chained through
`VkSwapchainPresentFenceInfoEXT`. The call may block in the driver; the
handoff promises a recorded outcome, never a prompt return. Targets present
independently.

### What was enqueued

The swapchain's own entry of `pResults` is the truth; the production layer
starts it as `VK_RESULT_MAX_ENUM`, so an entry the call never wrote is read as
unwritten, never as success.

| The call | The swapchain's entry | Meaning | Recorded |
| --- | --- | --- | --- |
| Returned | `VK_SUCCESS` | Enqueued | `PresentationEnqueued`; the fence pending |
| Returned | `VK_SUBOPTIMAL_KHR` | Enqueued | `PresentationEnqueuedSuboptimal`; a replacement requested |
| Raised | `VK_ERROR_OUT_OF_DATE_KHR` | Enqueued: a rejected presentation's queue operations still happen | `PresentationEnqueuedOutOfDate`; a replacement requested |
| Raised | `VK_ERROR_SURFACE_LOST_KHR` | Enqueued, likewise | `PresentationEnqueuedSurfaceLost`; the surface replaced once every hold on its generation has retired |
| Raised out of memory | Out of memory, or unwritten | Nothing enqueued | The frame is still submitted; one allocation recovery, otherwise `PresentedNothing` |
| Anything else | Unwritten, contradictory, device loss, or unclassified | Unknown | The frame enters the uncertain state; the session fails with `UnknownSubmissionEffect` |

### The presentation pool

Each target owns a pool of records, each a render-finished semaphore and a
present fence, bound to a frame at its reservation. A record serves one owner
at a time and is freed only when its present fence signalled or at the
explicit settlement of a frame never presented. It is never freed because the
frame's rendering completed, by a timeout, or because its image was acquired
again.

The capacity is the model's derived `presentationPoolCapacity` (the image
tracking limit plus the frame-slot count, 18 by default), shared by the
target's active and retired generations. A new acquisition of an image whose
older presentation is still pending takes a free record with no host wait on
the older fence.

### Retirement evidence

A presentation retires only when its own present fence is observed signalled,
by a non-blocking status query or after `awaitFrames`' finite wait. That
observation is the `PresentationRetired` fact: it discharges the generation's
presentation hold and frees the pool record. A present fence proves the
presentation's resource-retirement condition only; it says nothing about when
the image reached the screen. A wait that timed out changes nothing.

A status query that raised retains the presentation for ever, fails the
session with `CleanupFailed`, and raises `PresentationUncertain`.

### Incremental retirement

Retired generations are destroyed incrementally, from verified fences alone,
rotating across targets. Nothing waits for the device to go idle. A closing
window retires the same way: its frames are closed, its presentations stay
until their own fences are observed, `retireTargetFrames` raises
`FramesRetained` and `retireTargetGenerations` raises `GenerationsRetained`
until then, which withholds the attachment's terminal retirement fact. Closing
the first-created target retires only its own frames, generations and surface.

## Recovery

Recovery acts on a lost surface, a spent episode, and a native allocation that
ran out of memory. Allocation reclamation and swapchain replacement live in
the native package; surface replacement on the live window, which needs the
main thread, is orchestrated by the controller.

### The episode

Every recovery a target makes spends its one episode, which the model owns
([gpu_model.md](gpu_model.md#recovery)): at most three attempts, 100 ms then
500 ms apart, one in flight at a time. A deferred attempt is a deadline the
generations name, so the owner never polls hot.

| What happens | Is it an attempt? |
| --- | --- |
| An ordinary resize | No: coalesced and built as a replacement |
| An out-of-date or suboptimal result with unchanged geometry | Yes, each rebuild |
| A construction after one that failed (`VK_ERROR_NATIVE_WINDOW_IN_USE_KHR` included) | Yes: the next attempt of the same episode |
| A lost surface's replacement, from asking to publishing a generation on it | Yes, one attempt |
| Waiting for an unretired swapchain or a lost surface's generations to go | No |
| A zero-area or ineligible target | No: suspended |
| An allocation's own retry after reclamation | No |

### Replacing a lost surface

A surface is lost when a swapchain call, the capability query or a swapchain
creation answers `VK_ERROR_SURFACE_LOST_KHR`. Then, on the owner's thread:

1. **Admission stops.** The active generation is retired and nothing is built
   on the surface again. Acquisition answers
   `AcquisitionPending PendingSurfaceLost`. The target stays admitted; every
   other target, the device and the instance are untouched.
2. **Old dependents retire on their own evidence.** Nothing is waited on and
   nothing is replayed.
3. **The lost surface goes, then an attempt begins.** Once no generation of
   the target remains, the roots destroy the lost surface and keep the target
   and, above it, the window's attachment, which is never released or
   reattached. Only then does the episode admit an attempt
   (`SurfaceReplacing`).
4. **The main thread creates the replacement.** The controller asks the main
   thread, and `replaceVulkanSurfaces` creates the surface through the
   bridge's `replaceWindowSurface` under the same attachment.
   `runVulkanOwnerLoop` runs it every turn; an application that drives its own
   loop runs it itself.
5. **Support is rechecked, then a fresh generation is built** on it, handing
   nothing over. Its publication settles the attempt as a success; its failure
   spends the next.

| What the replacement came to | What happens |
| --- | --- |
| Installed | `ReplacementInstalled`; a step is owed at once |
| The queue family cannot present to it | `ReplacementUnsupported`; the surface is destroyed and the target is declared unrecoverable |
| It cannot serve the presentation profile | `PresentationUnsupported`; the target is declared unrecoverable |
| Created unusable, or not created | The attempt fails; the episode schedules the next |
| The bridge refused it | Close is coming: the attempt is left for the target's retirement, unless the target is still eligible, in which case it fails |
| Its support query or naming raised | The surface is destroyed and the attempt fails |

Close wins: a retiring target asks for and is offered nothing, and a
replacement that arrives after the close is destroyed
(`ReplacementNotWanted`). A lost surface or partial replacement whose
destruction did not complete is retained, never attempted again, and fails the
session with `CleanupFailed` (`SurfaceDestructionFailed`,
`GenerationDestructionFailed`).

### Required and optional dispositions

A target whose episode is spent, or whose replacement surface cannot be
presented to or cannot serve the profile, is disposed of through its
designation:

- **Optional.** The model marks it unavailable and the session continues;
  every other target keeps presenting. `readVulkanUnavailability` answers the
  target and why (`UnavailableRecoverySpent`, `UnavailableSurfaceUnsupported`,
  `UnavailablePresentationUnsupported`); the latest 64 are kept. The native
  window is not closed: the attachment stays until the application releases
  it.
- **Required.** The model fails the session (`RequiredTargetUnrecoverable`),
  the roots latch it, and the step raises `VulkanRequiredTargetFailed` (or an
  earlier diagnostic primary), which ends the owner's run.

Device loss, a validation error, an unknown effect and a failed cleanup are
never recoverable pressure, whatever the designation.

### Allocation recovery

One bounded reclamation pass and at most one retry, only where retrying is
proven safe:

| Operation that ran out of memory | What is retried |
| --- | --- |
| `vkQueueSubmit2` (specified no-effect result) | The same request, its batches as sealed |
| `vkQueuePresentKHR` (no-effect result read from the swapchain's entry) | The same frame's presentation |
| A managed resource's creation | The same creation |
| An allocating VMA call | The whole allocation protocol |
| A swapchain creation that handed nothing over, an image view's, a semaphore's or fence's | That call |
| A swapchain creation that handed a generation over | Nothing: that call retired the generation whatever it answered |

Configured-capacity exhaustion is backpressure and starts no recovery. The
pass (`reclaimPass`) offers the eligible subjects in its window to the layer
that owns each, which destroys them child before parent. Nothing waits for
unfinished work. `retryAllocation` permits the one retry only after a disposal
completed since the failure, never after the construction retired a generation
as `oldSwapchain`, and never in a failed session. Otherwise the original
failure is reported with the pass's evidence: `AllocationNotRecovered`,
`SubmittedNothing` or `PresentedNothing`.

### What recovery never does

It never replays a consumer callback or submitted work, evicts a live
generation, takes another target's reservations or budget, retries a failed
cleanup, recreates the device, migrates a target to another device, or changes
resolution, quality or frame capacity. It never closes or destroys a window,
and never releases or reattaches an attachment.

## The composed loop

There is one engine loop: the main thread runs the GLFW package's
`runScheduledOwnerLoop`, and the graphics owner is the supervised worker
([glfw.md](glfw.md#the-supervised-graphics-owner)).

### The loop adapter

`runVulkanOwnerLoop` is `runScheduledOwnerLoop` with one addition to every
turn. After the application's update, the main thread:

1. **publishes observations**: each attached window's latest
   `WindowObservation` and render eligibility, when newer than the last
   published;
2. **publishes render demand**: it captures every such window's demand slot,
   combines the requests and publishes them to the owner's demand snapshot.
   Demand published and not yet taken into an owner step is published again
   with anything newer, so a newer publication never replaces demand the owner
   has not seen;
3. **creates replacement surfaces** the owner asked for;
4. **folds the owner's deadline** into the schedule: it can shorten the main
   loop's wait and never lengthen it.

None of it waits, and the main thread performs no GPU work. An application
that runs this loop leaves observation publication and window demand capture
to it. A scene may be published from any thread with `publishVulkanScene`.

### What asks for a frame

Each step is handed the latest demand and scene with their publication
revisions, so two equal publications are two requests. A target is asked for
a frame (the model's `requestRender`) when:

- a demand publication the owner has not acted on is due (immediate, or its
  deadline has come);
- a scene publication the owner has not rendered arrives (in a per-window
  host, only that window's target);
- a target that has presented before can no longer be showing the latest
  scene: its active generation changed, or it became eligible again after a
  suspension.

Nothing else asks. A host whose application publishes neither demand nor a
scene presents nothing. A target that has never presented is asked for its
first frame only by a demand publication, a scene publication or a capture
request; eligibility alone asks nothing. If the owner takes a target's first
demand before it has folded the observation that makes the target eligible,
the frame is refused and the first frame waits for the retry, one backoff
interval (5 ms by default) later on the owner's clock.

### A scene for each window

An application can give each window a scene of its own. This is a generic
extension of the window host: what a snapshot references, and holding it, are
the rendering adapter's. The lifecycle, the barrier and the observation are
keyed by `SceneTargetKey`, a window or a registered
[offscreen target](#offscreen-scene-targets).

**The mode.** `vulkanSceneMode` chooses once; `vulkanScene` is the initial
scene either way.

- `SharedScene` (default): one latest-value snapshot serves every target, and
  `publishVulkanScene` publishes it.
- `PerWindowScenes`: one snapshot per window, keyed by `WindowId`, not by an
  attachment. `publishVulkanScene` is refused (`SceneRefusedPerWindow`). Each
  window starts with the initial scene at revision 0, and the renderer is
  handed its window's scene and revision (`requestSceneRevision`).

**Publishing.** `publishVulkanWindowScene host window scene` publishes from
any thread, never waits, and replaces the window's publication if the owner
has not taken it. Revisions count per window from 1. The publication survives
the window's surface being recreated or reattached. It answers
`WindowScenePublished`, `WindowSceneUnknown`, `WindowSceneClosed` or
`WindowScenesNotEnabled`. A window's unrendered publication asks that window's
target alone for a frame.

**Adoption.** A target adopts its window's scene in the owner's step, before
anything else the step does and whether or not a frame is rendered, when the
window's revision is newer than the one it holds or it holds none. Adopting
asks for no frame. A revision replaced before a step takes it is never
adopted, notified or released.

**The lifecycle.** `vulkanSceneLifecycle` supplies two hooks, run on the
owner's thread. Neither may raise or wait.

- `sceneAdopted window revision scene` runs when a target adopts a revision,
  with the exact scene the step took. An adapter holds what the scene
  references from here.
- `sceneReleased window revision` runs once the revision is superseded or its
  target has ended, **and** every frame recorded with it has a use that is
  over.

Every adopted revision is released exactly once, in adoption order per
window. A use ends only on evidence that the frame's commands can no longer
read what the scene references: its recording was discarded, or the submission
that carried it completed (read from the frames' completion log). A frame
abandoned after submission, a refused presentation, a timeout and a
retirement end nothing. A use whose discard or completion is not established
(a recording that raised, a submission a device loss let go of) stays, and so
do the revision it names and the revisions adopted after it for that window.
Adoption and its notification are one uninterruptible transition, so the hooks
must return finitely.

**Pressure.** A target holds at most `2 × (frameSlotLimit + 1)` unreleased
revisions. At the limit it adopts nothing newer and the step renders nothing
for it; when a release makes room the owner takes another round at once. The
publication never waits.

**Release requests.** `requestVulkanRelease host action` queues an owner-thread
action that runs only once the owner has adopted what was published when the
request was made, so an application can release an object a snapshot
references.

- It is admitted and settled as `submitVulkanAction` is, but against its own
  bound: `vulkanReleaseCapacity`, refused with `ReleaseQueueFull`. Release
  requests and ordinary actions never refuse each other.
- In the queuing transaction the request records a barrier: for every window
  the host holds, the latest revision published for it (revision 0 for a
  window with no publication). It runs when, for every named window, a live
  target of the window holds that revision or later, or the host no longer
  holds the window. A target that has ended holds nothing.
- Requests run in the order made. An action with no barrier is never held
  back by one that has.
- `vulkanInitialSceneHoldsNothing` (off by default; `render-2d`'s hosts turn
  it on) declares that the initial scene references nothing a release could
  free, so windows still at revision 0 are left out of the barrier.
- **The case that remains.** A window that has published and has no live
  target holds every later request until a target of it adopts that revision
  or the host drops the window. Resolving it is the application's: attach a
  target of the window, or close it.

`readVulkanSceneState` reads each window's published revision, adopted
watermark, revisions awaiting release, deferral count, and the queued release
requests with their barriers.

### Offscreen scene targets

A scene target with no window (LFE-27) gets the same barrier, ledger identity
and adopt/release lifecycle as a window.

- **One key.** Everything is keyed by `SceneTargetKey`: `KeyWindow WindowId`
  or `KeyOffscreen OffscreenTargetId`. An `OffscreenTargetId` is issued only
  by the host that registered the target, with an incarnation never reused,
  and is exported without constructors, so a stale, foreign or forged identity
  never equals a live one.
- **Registration.** `registerVulkanSceneTarget host` is one transaction that
  never waits and opens no window. It is refused, in order, as
  `TargetSessionFailed`, `TargetOwnerClosed`, `TargetDeviceNotReady` or
  `TargetCapacityReached` (`vulkanTargetCapacity`, 8 by default, counting
  unregistered targets with unreleased records).
  `unregisterVulkanSceneTarget` ends it.
- **Publication.** `publishVulkanTargetScene host target scene` never waits;
  it answers `TargetSceneUnknown` or `TargetSceneClosed` when it cannot
  publish.
- **Barrier, adoption and release** are a window's: a release request made
  after the target accepted revision R waits until the target adopts R or is
  unregistered; adoption happens in the owner's step before any action runs;
  the retention limit and deferral are the same.
- **The recording boundary.** `recordVulkanTargetBatch host target
  construction consumer`, inside an owner-thread action, records one
  frame-less batch that reads the scene the host adopted for the target. The
  batch's use of the revision is bound to the batch's own ticket before
  anything is recorded, and ends only on that ticket's evidence: complete or
  discarded. A ticket lost to a device loss or still pending ends nothing. It
  is refused as `TargetBatchUnknown` or `TargetBatchNotAdopted`.
- **Teardown.** Unregistering at any point leaves no hold stranded without a
  real completion. A lost device or an unobserved completion does not
  manufacture a release and does not require an empty ledger at shutdown.

### Rendering a frame

A target the model says wants a frame is offered one attempt per step, in an
order whose lead rotates. The attempt is `tryAcquireFrame` with a zero
timeout; `recordFrame` with the transition into the color-attachment layout,
the configuration's `VulkanRenderer` and the transition to presentation; one
`submitFrames`; and one `presentFrame`.

- An acquisition the swapchain cannot answer yet, or one refused as
  `AcquisitionSuspended`, is retried at the first interval of the model's
  backoff (5 ms by default), anchored at the step's own instant.
- A frame the renderer refused, whose recording was refused, or whose
  submission had no effect is skipped; one whose presentation enqueued nothing
  is closed unpresented. Neither is replayed. The target's render demand
  stands, so a renderer that refuses every frame costs one attempt an
  interval, never one every round.
- Enqueuing the presentation clears the model's render demand.

The renderer records through the managed boundary alone. Its `FrameRequest`
carries the attachment, target, frame, image, the image's extent and color
format, the scene revision, the generation's depth image (`requestDepth`, with
[windowed depth](#windowed-depth)), and the window's `requestLogicalExtent`
and `requestContentScale`. Those last two are `Maybe`: `Nothing` means the
platform has not reported the attribute, never a default, and a renderer that
needs a value it was not given declines the frame. The image's own extent is
the framebuffer extent.

### Consumer construction

With each frame the renderer is lent the session's `Construction`, through
which it builds (`constructPipelineLayout`, `constructPipeline` and the other
`construct*` operations), replaces (`replaceConstructedPipeline`) and releases
(`releaseConstructed`) managed resources. The consumer holds opaque handles
and never a native one. The public module re-exports the recording
vocabulary, so a consumer needs only the host's package and the shaders it
embeds. The triangle sample
([`samples/triangle`](../samples/triangle/README.md)) is the consumer example.

- **Thread.** Every construction and release belongs to the graphics owner's
  thread (`RefusedNotOwner` otherwise), and is refused once the session has
  failed or while a diagnostic failure is pending.
- **Failure.** A refused construction answers its refusal, and a renderer
  that passes it on has its frame skipped; the session continues. A
  construction that raised before committing any generation left nothing and
  is answered `RefusedConstructionFailed`, confined to that frame. One that
  raised after committing a generation (a replacement that could not be
  named), one that raised because the session failed, and every cancellation
  end the owner's run. No exception of the renderer's own is caught.
- **Lifetime.** A handle outlives its frame. A replaced or released
  generation is destroyed on the owner's thread in a later step once nothing
  holds it (`reclaimReleased`). Whatever the renderer never released is
  released and destroyed by the recording's retirement, before the device.

### Verification capture

The capture of a real, presented frame's pixels is reachable only by this
package's own suites. A host composed with capture on builds every generation
unclipped and, where offered, as a transfer source. Every other host refuses
every request (`CaptureDisabled`).

- `requestVulkanCapture` admits, from any thread, a request for the next
  frame of an attachment's target and answers a `CaptureTicket`. At most one
  request per attachment is outstanding and at most 64 in total
  (`CaptureBacklogFull`). Admission asks the target for a frame.
- The next frame the owner acquires for the target is the request's, whatever
  becomes of it: a failed capture is settled, never moved to a later frame. A
  generation that is not a transfer source settles it `WithheldUnsupported`;
  no readback buffer, `WithheldNoReadback`; an abandoned frame,
  `WithheldFrameAbandoned`.
- The frame's batch ends with the copy of the whole image into a readback
  buffer. Once the batch's completion evidence exposes the bytes, the request
  is settled with a `CapturedFrame`: the bytes (a copy of their own), extent,
  format, the frame's identities and scene revision. `takeVulkanCapture`
  answers a settled request once.
- A request outstanding when its target retires is settled
  `WithheldTargetRetired`; at the session's end, `WithheldSessionEnded`.
  Nothing is read once the session has failed or the device is lost.

### Polling completion

A fence is asked only when the model's schedule says a poll is due
(`progressDeadline`, [gpu_model.md](gpu_model.md#owner-progress)) or when a
frame is to be attempted this step. A round something unrelated woke asks no
fence and takes no model turn. The backoff moves on once per poll: 5, 10, 20,
40, 80 and then 100 ms. New demand, a new obligation, an observed completion
or a close transition restarts it.

### Pacing, suspension and fairness

The owner's `graphicsNextDeadline` is the earliest of the unannounced watch, a
replacement it is waiting on, the generations' deadline, and rendering's (a
frame wanted now, an acquisition's retry, or a demand deadline ahead).

- A hidden, iconified, zero-area or closing target is **suspended**: it is
  offered no frame and its render demand contributes no deadline. Its
  outstanding obligations keep a finite poll deadline. One suspended target
  never pauses another.
- A target resumed after its window was hidden or minimized is **replaced**,
  never resumed on the old generation, with no settling period and no
  recovery attempt. A compositor need not answer a presentation made for a
  surface it has since unmapped (on Wayland with Weston 13, Mesa's FIFO
  present then waits with no timeout). It costs one swapchain creation per
  resume.
- **Hiding a presenting window.** The host has the window's graphics owner
  withhold its presentation before the hide's native call
  ([glfw.md](glfw.md#hiding-an-attached-window)). The step view's withdrawal
  count rises with every hold, and the controller then withdraws the target's
  active generation (`withdrawGeneration`) before any frame of that step, so
  even a hide and show between two steps resume on a replacement.

### Retiring a target

A target's retirement is owed (`RetirementOwed`) until it can be performed.
The first time the owner asks (`graphicsPrepareRetirement`), the controller
closes the target in the model and closes its frames. It answers ready once no
frame and no presentation of the target remains, or once the device has been
lost. Only then is the target retired, once: its frame synchronization, its
frame storages, its generations, then its surface. An owed retirement
certifies nothing.

Whole-owner retirement refuses every owner-thread action still queued, then
retires the recording before the device is destroyed.

### Status, stop and stalls

- **Status** reaches the application through the runtime's checkpoints
  (`superviseGraphicsOwner`), `readVulkanUnavailability`, and the attachment's
  observation. The owner's wake asks for a round while the capture's sink has
  failed, and while a primary failure latched on another thread has not yet
  been taken by the owner's step.
- **Stop** follows the graphics owner's exit order
  ([glfw.md](glfw.md#the-exit-which-is-d-33s)). A target whose retirement is
  still owed when the drain begins is asked again on the model's poll
  schedule. No timeout ends that wait; a cancellation leaves what is still
  owed with the owner, unverified. Quiescence refuses every queued
  owner-thread action that has not started, before ordinary workers drain, so
  a worker awaiting one is answered.
- **During a main-thread stall** the adapter publishes nothing, but the owner
  keeps rendering the latest scene and last coherent observation on its own
  deadlines, and a live resize keeps presenting from the active generation. A
  presented frame and its signalled present fence do not prove the frame
  became visible; that is a native measurement.

The controller's modules are `Internal.Rendering` (frames above the
generations, what asks for a frame, completion polls, retirement readiness),
`Internal.Loop` (the adapter), `Internal.Controller` (the owner's step,
deadline, wake and retirements) and `Internal.Actions`.

## Surface-free sessions and owner-thread actions

Offscreen and upload work runs without a window inside the existing
GLFW-hosted graphics owner. On Linux the host still runs under a display,
because GLFW's session needs one.

`vulkanDeviceStart` says when the session's one device is created:

- **`DeviceAtFirstSurface`** (default): selected against the first window
  surface handed over.
- **`DeviceSurfaceFree`**: created in the owner's startup against no surface.
  `selectSurfaceFreeDevice` takes the first device satisfying the whole
  profile except presentation, keeping every extension and feature a later
  swapchain needs. No satisfying device is `NoCompatibleDevice`, fatal to the
  owner. Every window handed over later is a later target, checked against
  the chosen queue family.

Either way it is the session's only device.

**Zero-target progress.** A session with no targets keeps making owner
progress: completion is polled when the model's schedule says so, released
resources are destroyed, and actions run. When nothing is owed it names no
deadline and sleeps until woken. It retires through the same protected exit.

### Owner-thread actions

`submitVulkanAction` hands the graphics owner a `VulkanAction`: bounded work,
run once on the owner's thread and lent the session's `Construction`, whose
result the caller takes from its `ActionTicket` (`readVulkanAction`,
`awaitVulkanAction`). It works with or without targets.

- **Admission** is one transaction that never waits. It refuses with
  `ActionSessionFailed`, `ActionOwnerClosed`, `ActionDeviceNotReady` (under
  `DeviceAtFirstSurface`, until the first window is admitted) or
  `ActionQueueFull` (`vulkanActionCapacity`). Admission wakes an idle owner.
- **Running.** The owner's step runs the actions queued when the step began,
  one at a time, before anything else it does, so an action never runs beside
  a frame's rendering.
- **Start and exit.** Each action is started in a transaction that asks the
  same gate as admission; once the session has failed or the owner's
  admission has closed, a queued action is refused (`ActionRefused`) and never
  runs. A caller reading its ticket asks the gate too. Every admitted action
  receives a settled outcome or a refusal.
- **Failure.** An action that raises answers `ActionRaised` and the owner
  goes on; what it constructed stays a managed resource of the session. It is
  never run again. A cancellation of the owner, a failure setting the
  construction up, and a construction failure that escaped (a committed
  generation, or a latched session failure) end the owner's run after the
  ticket is settled.
- **Cooperation.** An action is a finite callback. It must not wait for work
  that needs the same owner: another action's outcome, a frame, a handover.

## Frame-less batches

Batches that belong to no frame (offscreen rendering and uploads) have their
own submission and completion. The model's rules are
[gpu_model.md's](gpu_model.md#frame-less-batches).

- **Recording.** Inside an owner-thread action, `constructFramelessBatch`
  lends a consumer a `Recorder` for one frame-less batch and answers its
  `BatchTicket`. Every check a frame's batch has applies, but there is no
  swapchain image: `transitionImage`, `beginRendering` and `copyToReadback`
  are `RefusedUnsupported`. It renders into a managed color target. A
  renderer's frame records no frame-less batch.
- **Submission order.** When the action returns, its sealed frame-less
  batches are submitted in the order sealed, each as its own
  `vkQueueSubmit2`, before anything else the owner submits after the action.
  One the queue accepted stays accepted. The first that is refused, or fails
  with no effect after its one recovery, is discarded with every batch sealed
  after it. An unknown effect fails the session
  (`FramelessEffectUncertain`). An action that raised or was cancelled
  submits nothing and discards every batch it opened.
- **Tickets.** `readTicket` reads from any thread: `TicketPending`, then
  `TicketComplete` (its fence observed signalled and recorded with the model),
  `TicketDiscarded`, or `TicketLost` (the device was lost while pending).
  `awaitTicket` waits at most the given duration and discards, releases and
  completes nothing; it is `RefusedOwnerWait` on the owner's thread.
- **Progress.** The owner observes frame-less fences in its bounded progress
  step on the same rotation as its other work. A fence whose query raised
  without losing the device is uncertain: the session fails and the
  submission is kept with its ticket pending.
- **Device loss and retirement.** After device loss every frame-less
  submission is let go of, completing none, with each pending ticket settled
  lost. At whole-owner retirement the owner waits, in finite drain steps (at
  most a hundred), for each outstanding frame-less fence. One still
  outstanding without device-loss evidence is retained (`FramelessRetained`),
  and so is the device.

## Destruction order

| Exit | What is destroyed, in order, on the owner's thread |
| --- | --- |
| A window closed or a target released | That target's swapchain generations (each one's image views, newest first, then its swapchain), then its surface. The owner writes its terminal record only after the destructions returned; the main thread then certifies the attachment's facts and releases the window. Everything else stays live. |
| Whole-host exit | Every remaining target's surface; then, in whole-owner retirement: every surface the lease still owes, every queued owner-thread action refused, outstanding frame-less submissions waited for and their fences destroyed, every managed resource (pipelines before their layouts), the allocator once no allocation remains, and the device; then, in whole-owner destruction: any late surface, the explicit messenger, and the instance. Only after that evidence is the owner joined, and only then are windows, the session and the capability released. |

Each step is refused rather than reordered when something that must go first
has not verifiably gone. A destruction that raised is uncertain: it is
recorded, never attempted again, and retains every parent above it
(`SurfaceDestructionFailed`, `RootDestructionFailed`, `RootsRetained`,
`AllocationsRemain`, `AllocatorRemains`). Running a destruction and recording
what it did are one masked step. The host then keeps the window, the session
and every parent until independent evidence arrives. No timeout, cancellation
or cleanup failure is permission.

## Terminal failure

### The latch

The roots keep one terminal latch. Its first failure is the session's
**primary**:

| Source | Latched | As |
| --- | --- | --- |
| A call answered `VK_ERROR_DEVICE_LOST` | By the call's own guard, before the failure propagates | `TerminalDeviceLost` |
| An error-severity validation report | At the next checkpoint, from the capture's error latch | `TerminalValidationError` |
| The diagnostic sink failed | At the next checkpoint | `TerminalSinkFailed` |
| A native effect whose outcome is unknown | By the step that observed it | `TerminalUncertainEffect` |
| A cleanup that raised | By the destruction or cleanup that raised | `TerminalCleanupFailed` |
| A required target's recovery exhausted | At the next checkpoint or read of the latch | `TerminalRequiredTarget` |

- Latching the primary is one transaction that closes the roots' admission
  and fails the model's session.
- A later failure never displaces the primary: it joins the latch's evidence
  as `LaterFailure`, oldest first, the first 64 kept and the rest counted.
  Each cleanup failure is latched with its subject.
- **Reporting a validation error wakes no one.** It is latched at the owner's
  next checkpoint, and the owner takes a round only when something asks for
  one. A sink failure and a primary latched on another thread have wakes of
  their own. A test that reports an error from its own thread must give the
  owner a round afterwards.
- **Which failure was first** is decided by the diagnostic capture's
  first-failure cell ([vulkan_diagnostics.md](vulkan_diagnostics.md#the-verdict)),
  which the capture's callback, its worker and the owner's own failures all
  claim. A checkpoint that sees a claim whose failure is not yet readable
  answers `CheckpointPending`: it latches nothing and refuses new work, so
  admission never reopens in between. A claim made by a transaction attempt
  that was abandoned is void.
- The device's loss is kept apart from the primary (`reportDeviceLost`): a
  session a validation error failed first whose teardown then meets the loss
  keeps the validation error as primary and switches teardown to the
  device-loss rules.
- `readVulkanTerminal` reads the whole latch from any thread.

### Checkpoints and refusals

- The controller's progress step raises the primary (`GraphicsDeviceLost` or
  `GraphicsSessionFailed`), which ends the owner's run;
  `superviseGraphicsOwner` raises it at the application's checkpoint while
  retirement is still running.
- `recordFrame`, `tryAcquireFrame`, `submitFrames` and `presentFrame` refuse
  with `RefusedSessionFailed`, or `RefusedDiagnosticPending` while a failure
  is pending.
- `handOverVulkanTarget` answers `VulkanSessionFailed` or
  `VulkanDiagnosticPending` and attaches nothing. The owner's construction of
  a handed-over target checks again and rejects with `RejectedSessionFailed`.

**Retirement never passes through a checkpoint.** Closing and skipping
frames, progress observations, the drain wait and every retirement keep
running, because they run precisely because the session has failed.

The native effect a failing call had is recorded in the same masked step as
the call, before anything propagates, even when the call's own device loss
failed the session in between.

### Teardown after device loss

Once the loss is recorded, the specification's rule applies to what the lost
device could have discharged: its objects may be destroyed without waiting
for work that may never complete.

- No fence is asked or waited on again.
- A skipped frame makes no cleanup submission, and no storage is reset.
- `releaseFramesToDeviceLoss` skips every acquired frame, then has the model
  release every submission, presentation and frame that had left acquisition.
  None is recorded as completed or retired, and no recovery cycle is
  credited.
- Frames, generations, the surface, the device, the messenger and the
  instance go child before parent. Nothing waits for the device to go idle,
  and nothing is recreated or replayed.
- An object whose destruction already raised is destroyed under no rule.

### Teardown under the ordinary rules

After any other terminal failure, obligations settle on their own evidence
within the drain's finite waits. What cannot be verified is retained: an
uncertain effect keeps its frame, and with it its generation, surface, device
and instance (`FramesRetained`, `GenerationsRetained`,
`TargetGenerationsRemain`, `RootsRetained`).

Validation errors delivered during teardown reach the final report through
the capture's verdict, not the latch. A sink failure never authorizes a
release. Every retirement that could not verify what it owns records what it
retained (`RetainedUnverified`). Process termination is the escape, and it is
never orderly cleanup.

## State

Each layer owns its state; all of it is written on the graphics owner's
thread unless noted, and the owning modules' Haddock has the per-cell detail.

| State | Owner | Notes |
| --- | --- | --- |
| Root slots (instance, messenger, device, allocator), target records, disposers, the GPU model | The roots | Slots only advance: absent, live, then destroyed or uncertain. Target records are removed only by a destruction that returned |
| The loss latch and the terminal latch | The roots | Set once; read from any thread; never cleared. Evidence bounded at 64 |
| The lease, deposits, deferred attachments, replacements, rejections and unavailability reports | The controller | Written by the main thread and the owner; reports keep the latest 64 |
| Generation records, swapchain results, lost surfaces, window-depth setting | The generations (`Internal.Generations.State`) | A CPU use is held and ended from any thread. A record is kept, uncertain, when a destruction raised |
| Managed records, frame storages, batch records, the ring and its regions, upload-held targets, texture table | The recording | Removed once the model records the disposal. Regions are never reissued |
| A recorder | Its `recordFrame` | One consumer action |
| Slot synchronization, the presentation pool, frame, submission and presentation records, frame-less fences | The frames | Removed on the model's completion, retirement or settlement fact, or by the device-loss release |
| Per-target rendering records, revisions acted on, the scene ledger and uses, the offscreen target registry | The controller's rendering | The ledger is read from any thread; a record is removed once, before its release hook runs |
| The owner-thread action queue and each action's standing | The controller's `Internal.Actions` | Admitted from any thread; standing only advances |
| The adapter's published revisions and untaken demand | `runVulkanOwnerLoop` | The main thread, every turn |

## Evidence

**Headless.** The group `test.vulkan-headless` builds and runs, through
`bash tools/vulkan/run.sh test`, the shader contract (`shader-tests`), the
native package's `native-tests` over stand-in native layers, and the window
integration's headless suite over the GLFW seam
(`withVulkanOwnerHostOver`). They need no device and no display. The
stand-ins journal every native call, so examples assert order and refusals
with no native call, never a time.

**Native.** The groups `test.vulkan-native` and `test.vulkan-wayland` run the
native suite below on a real device with the Khronos validation layer and
synchronization validation. The retained platform records that tests read are
under [`docs/vulkan/`](vulkan/) and
[vulkan_compatibility_record.md](vulkan_compatibility_record.md).

A headless example proves the engine's handling of what the native layer
reports; only a native case proves what a driver does. Rows of a result table
that are specification obligations and were not observed on a driver are
injected by headless examples and say so.

## The native suite

`hetoimasia-gpu-vulkan-glfw:vulkan-native-tests`, in
`packages/gpu-vulkan/glfw/native-test/`, follows
[the GLFW native suite's](glfw.md#the-native-suite) ownership rules and adds
the Vulkan owner's:

| Rule | How it holds |
| --- | --- |
| Main thread | Hspec runs on its own thread; the process main thread owns one shared production graphics session. An example that needs the main thread submits an operation (`onMain`), run between two turns of the host's owner loop. Windows are created through the host's command port. |
| Identities | Every dispatched operation is checked to be on the bound process main thread. Every native call is recorded where it runs by a `NativeObserver`, so examples show from the calls themselves which thread made each. |
| Sharing | The instance, messenger and one device are acquired lazily, at most once, and shared. Each example's windows and targets are its own. |
| Private roots | A case that must create, poison or destroy roots of its own runs in a child process of the same executable (`--private-roots <scenario>`), on the child's main thread. |
| Selection | A dry run, a listing, or a selection that dispatches nothing acquires nothing and starts no child. A selection matching nothing fails. `--complete`, which the catalog group passes, runs the whole tree and fails unless the shared session was acquired once and every private scenario the run's consent requires ran and passed, so no ambient setting can turn the receipt into a pass for a subset. |
| Consent | Read once from `HETOIMASIA_NATIVE_SESSION`, with the GLFW suite's rules. Under the Wayland consent every session requests Wayland by name. |
| Environment | Before any Vulkan call the suite clears every ambient discovery override and validation-layer setting it finds, records which, and disables implicit layers. |
| Validation | Every validation-enabled instance enables the Khronos layer and synchronization validation through its own create info. The `synchronization-hazard` case passes only when the capture carries `SYNC-HAZARD-WRITE-AFTER-WRITE`, which shows the validation is active: zero validation errors is a claim about coverage only when a hazard is shown to be caught. |
| After teardown | The shared session is released only once Hspec has finished. The run then checks the destruction order, the owner's thread for each destruction, and that the capture's final verdict is clean. |
| Report | The run prints the environment, the shared session's native calls, destruction order and verdict, and each child's exit and seconds. Each child's record is written to the validation runner's evidence directory. |

`test.vulkan-wayland` runs the same profile under packaged headless Weston on
Lavapipe. Its one extra case, `wayland-connection-loss`, ends the compositor
from the loop's update once a presentation has retired and requires the
application to end with `ConnectionFailed` and the protected exit to retire
everything.

Run the suite as the group does:

```bash
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --dry-run
```

The second command builds nothing and refuses an executable built from
another tree. After any change under the digest's roots, which include
`tools/vulkan` and `tools/native`, run the first command again
([the build identity](validation.md#a-native-runs-build-identity)).

On Linux the native mode starts an isolated X11 display and needs no approval;
the Wayland profile runs on the isolated headless compositor:

```bash
bash tools/display/wayland.sh -- bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
```

On macOS the suite opens windows on the desktop. The standing approval and its
limits are in [AGENTS.md](../AGENTS.md); the consent goes on that one command:

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
```

See [validation.md](validation.md#the-vulkan-groups-local-evidence) for the
receipt that run leaves.

**The graphics-owner interaction probe** is the suite's last example and the
only one no routine run executes. It extends
[the GLFW interaction probe](glfw.md#the-interaction-probe) with the graphics
owner and is gated the same way: it needs the run's consent and is pending
unless `HETOIMASIA_INTERACTION_PROBE_SECONDS` is set. It records, in one time
domain, the main thread's owner turns and native event calls and the owner's
acquisitions, present requests, returns and present-fence completions,
through an idle baseline, a window move, a live resize and a menu
interaction. It asserts only that every phase measured something and that
validation reported nothing; it never asserts that frames visibly advanced. On
macOS it measured the owner still presenting during a live resize and a menu
interaction. The standing approval does not reach it: a person must perform
the interactions, so it runs when the owner asks.

```bash
HETOIMASIA_NATIVE_SESSION=desktop HETOIMASIA_INTERACTION_PROBE_SECONDS=15 \
  HETOIMASIA_INTERACTION_PROBE_OUTPUT=/tmp/graphics-owner-probe.tsv \
  bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --interaction-probe
```
