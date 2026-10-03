# The Vulkan roots and their window integration

This is the delivered contract of VK-7 ([#219](https://github.com/coghex/hetoimasia/issues/219))
of [the Vulkan backend design](vulkan_backend_design.md): one graphics
session's Vulkan instance, its explicit debug messenger, its one shared device
and a target for every window surface handed to it, owned by the supervised
graphics owner and retired through its protected exit. It covers the design's
D-7, D-9, D-12, D-14, D-15, D-17, D-22, D-29, D-32 and D-33, and P-1, P-5, P-7,
P-8 and P-14 as far as this slice reaches.

VK-10 ([#222](https://github.com/coghex/hetoimasia/issues/222)) adds each
target's **swapchain generations**: their planning, construction, replacement
and destruction, keyed by the GPU model's identities — D-7, D-16, D-18, D-22
and D-30, P-2, P-8 and P-15, and Q-12. See
[Swapchain generations](#swapchain-generations).

VK-11 ([#223](https://github.com/coghex/hetoimasia/issues/223)) adds the
**renderer-facing boundary**: managed rendering resources, a scoped recorder
that retains the exact generations each command references, sealed single-use
batches that can be discarded, readback memory, and the audited `unsafe`
recording subset — D-15, D-26 and D-28, P-1's renderer-facing boundary and
P-8. See [Recording through managed resources](#recording-through-managed-resources).

GRS-11 ([#333](https://github.com/coghex/hetoimasia/issues/333)) backs **device
memory** with VMA: one externally synchronised allocator per device, owned by
the roots and used on the graphics owner's thread alone, through the engine's
own `unsafe` C shim; memory types chosen by the engine from each usage's
properties; the model's accounted bytes charging the blocks VMA holds, through
a bounded reservation before any call that could open one; VK-14's recovery
for a no-effect allocating failure; and readback buffers moved onto it as its
first consumer — D-15, D-16, D-38 and D-40 of the
[GPU resource services design](designs/gpu_resource_services_design.md). See
[Device memory](#device-memory).

GRS-2 ([#334](https://github.com/coghex/hetoimasia/issues/334)) adds **managed
buffers and images**: opaque handles over the model's `ResourceId`, created on
the graphics owner's thread — and lent to renderers and owner-thread actions
through the host's `Construction` — from engine-defined kinds that fix their
usage flags and memory usage; images checked against the device before
anything is created, each with one owned view of the whole image; their memory
placed through the allocator and charged as its blocks; and released and
disposed of like every other managed resource. Nothing records through them
yet. See [Buffers and images](#buffers-and-images).

VK-12 ([#225](https://github.com/coghex/hetoimasia/issues/225)) adds **frames**:
non-blocking acquisition, submission of sealed batches with one completion
obligation per native submission, and safe abandonment — a skipped
unsubmitted frame and a submitted frame never presented each returned through a
tracked cleanup submission and maintenance release — with every native effect
recorded in the same masked step as its bookkeeping. D-15–D-17, D-23 and D-26,
P-1's scheduling vocabulary and P-2. See
[Frames: acquisition, submission and abandonment](#frames-acquisition-submission-and-abandonment).

VK-13 ([#227](https://github.com/coghex/hetoimasia/issues/227)) adds
**presentation**: each target presents independently through a bounded
presentation pool of render-finished semaphores and present fences, reserved
with the frame; what was enqueued is read per swapchain from `pResults`; a
presentation retires, and its generation's presentation hold ends, only when
its own present fence is observed signalled; and retired generations and
closing windows retire incrementally from that evidence, with no device-wide
idle. D-9, D-15, D-18 and D-23, P-2, P-8, P-14 and P-15. See
[Presentation and retirement](#presentation-and-retirement).

VK-14 ([#229](https://github.com/coghex/hetoimasia/issues/229)) adds
**recovery**: a lost surface is replaced on the same live window, its
attachment kept throughout, within the target's bounded recovery episode; a
target that cannot be recovered is disposed of through its designation — an
optional one unavailable while every other continues, a required one failing
the session; and a native allocation failure with no effect gets one bounded
reclamation pass and at most one retry. D-18, D-22, D-24 and D-25, P-14 and
P-15. See [Recovery](#recovery).

VK-15 ([#231](https://github.com/coghex/hetoimasia/issues/231)) adds
**terminal failure**: one latch whose first failure — a device loss, a
validation error or sink failure the capture reports at a checkpoint, an
uncertain effect, a failed cleanup, or a required target's exhausted recovery
— is the session's primary, refuses every later rendering, acquisition,
submission, presentation and handover naming it, and is reported with what
teardown found beside it; and teardown after device loss under the
specification's device-loss rules, with no fence asked or waited on and none
recorded as signalled. D-17, D-19, D-20, D-22 and D-33, P-2, P-5, P-11 and P-14.
See [Terminal failure](#terminal-failure).

[#250](https://github.com/coghex/hetoimasia/issues/250) (VKR-2) adds **debug
names and recording labels**: every native object the backend creates is named
from identities it already holds — the debug messenger excepted — and every
batch and every dynamic-rendering pass is bracketed in balanced command-buffer
labels, which [the diagnostic capture](vulkan_diagnostics.md) now copies. See
[Names and labels](#names-and-labels).

VK-16 ([#232](https://github.com/coghex/hetoimasia/issues/232)) composes
**rendering** into the graphics owner and the owner into the main thread's
loop. The controller constructs the recording and the frames on the owner's
thread and renders the scene the owner holds when render demand, a newer scene,
a changed generation or a resumption asks a target for a frame; it paces its
own acquisition retries and completion polls on the owner's deadlines and the
model's idle backoff; and a retiring target's retirement is owed until every
frame and presentation of it has gone on its own evidence.
`runVulkanOwnerLoop` is the main thread's scheduled owner loop with the owner
composed in: each turn it publishes the windows' observations, their captured
render demand and the replacement surfaces the owner asked for, and bounds its
own wait by the owner's published deadline, with no second engine loop and no
GPU work on the main thread. D-5, D-15, D-18, D-22 and D-29–D-31, D-33, P-5,
P-6, P-12 and P-15. See [The composed loop](#the-composed-loop). A required
target's exhaustion fails the session through the terminal latch, and
device-loss teardown across submitted work and pending presentations is the
frames' own ([Terminal failure](#terminal-failure)).

GRS-15 ([#336](https://github.com/coghex/hetoimasia/issues/336)) of
[the GPU resource services design](designs/gpu_resource_services_design.md)
lets a session **start its device without a window**: an opt-in host setting,
`DeviceSurfaceFree`, has the owner's startup select and create the device
against no surface, and a window handed over later is admitted only if the
chosen queue family presents to it. A session with no target — one that never
had a window, or whose windows have all closed — keeps making owner progress
and retires through the same protected exit. And a consumer on any thread can
hand the owner a bounded **owner-thread action**, run on the owner's thread
with the session's `Construction`, with or without targets. D-6, D-12 and D-28
of that design. See
[Surface-free sessions and owner-thread actions](#surface-free-sessions-and-owner-thread-actions).

## Packages

| Package | Location | Holds | Depends on |
| --- | --- | --- | --- |
| `hetoimasia-gpu-vulkan-native` | `packages/gpu-vulkan/native/` | The profile's decisions, the roots over an open native layer, and the production native layer | The binding, the diagnostics package, the GPU model, the foundation — never GLFW |
| `hetoimasia-gpu-vulkan-glfw` | `packages/gpu-vulkan/glfw/` | The session controller, the main-thread handover, the composition | The native package, `hetoimasia-glfw:runtime-glfw`, `hetoimasia-glfw:vulkan-interop`, the diagnostics package, the model |

The GLFW package depends on neither, and the native package does not depend on
the integration package. Both are listed only in `cabal.project.vulkan`, and
`cabal.project.common` holds their `-Werror` entries; `cabal.project` and
`cabal.project.cpu` resolve no Vulkan header, binding or loader. Only
[`tools/vulkan/run.sh`](../tools/vulkan/run.sh) builds them, and the validation
groups `test.vulkan-headless` and `test.vulkan-native` run through it; see
[validation.md](validation.md#the-registered-groups). [`packages/gpu-vulkan/README.md`](../packages/gpu-vulkan/README.md) maps
all four GPU packages.

The integration package's public module is `Hetoimasia.GPU.Vulkan.GLFW`; its
controller lives in a private `controller` sublibrary. The native package
exposes `Hetoimasia.GPU.Vulkan.Native.Profile`,
`Hetoimasia.GPU.Vulkan.Native.Roots` and `Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan`
beside VK-6's `Hetoimasia.GPU.Vulkan.Native.Diagnostics`, and VK-10's
`Hetoimasia.GPU.Vulkan.Native.Presentation` — the presentation profile and the
extent policy, as pure decisions — and `Hetoimasia.GPU.Vulkan.Native.Generations`,
the generations above the roots; and VK-11's `Hetoimasia.GPU.Vulkan.Native.Recording`
— managed resources and the recorder over an open native layer —
`Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan`, its production layer, and
`Hetoimasia.GPU.Vulkan.Native.Recording.Shaders`, the verification pipeline's
embedded shaders; and VK-12's `Hetoimasia.GPU.Vulkan.Native.Frames` —
acquisition, submission and abandonment over an open native layer — and
`Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan`, its production layer; and GRS-11's
`Hetoimasia.GPU.Vulkan.Native.Allocator` — the device-memory allocator's shape
and the engine's memory-type policy — and
`Hetoimasia.GPU.Vulkan.Native.Allocator.Vulkan`, its production form over VMA
(see [Device memory](#device-memory)). The package's private modules, which no client can import,
are the audited `unsafe` subset, `Hetoimasia.GPU.Vulkan.Native.Internal.Commands`;
the VMA shim's imports, `Hetoimasia.GPU.Vulkan.Native.Internal.Vma`, and the
allocation protocol above them, `Hetoimasia.GPU.Vulkan.Native.Internal.Allocation`;
the generations' implementation under
`Hetoimasia.GPU.Vulkan.Native.Internal.Generations`: `State`, `Uses`,
`Disposal`, `Reconciliation`, `Step`, `Retirement` and `Observation`, which the
public generations module re-exports as it always exported them (see
[How the generations are built](#how-the-generations-are-built)); and the
recording's implementation under
`Hetoimasia.GPU.Vulkan.Native.Internal.Recording`: `Layer`, `State`,
`Construction`, `Recorder`, `Batches`, `Readback` and `Disposal`, which the
public recording module re-exports as it always exported them (see
[How the recording is built](#how-the-recording-is-built)); and the frames'
implementation under `Hetoimasia.GPU.Vulkan.Native.Internal.Frames`: `Layer`,
`State`, `Acquisition`, `Submission`, `Presentation`, `Abandonment`, `Loss`
and `Progress` (see [How the frames are built](#how-the-frames-are-built)); and
VK-14's allocation recovery, `Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation`,
and its surface recovery, the generations' `Surface` (see
[How recovery is built](#how-recovery-is-built)).

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
                               │    ├─ device (one, shared, selected against the
                               │    │          first target's surface — or, for a
                               │    │          surface-free start, against none)
                               │    │    └─ allocator (VMA, one per device; the
                               │    │         device memory every allocation
                               │    │         lies in, charged to the model)
                               │    └─ target surfaces, one record per target,
                               │         keyed by the model's TargetId
                               │           └─ swapchain generations, keyed by
                               │              GenerationId: each swapchain, its
                               │              images and their views
                               └─ GPU model (identities, the session's state)
                           ├─ recording (managed resources: the consumer's
                           │    pipelines and layouts, frame storages,
                           │    readback buffers and their allocations)
                           └─ owner-thread actions (bounded queue; each run
                                once on the owner's thread, lent the
                                recording's Construction)
```

- **The instance, its explicit messenger, the device and the device's
  allocator belong to the roots**, for the session. Every allocation made from
  the allocator belongs to the managed resource whose memory it is. No target owns the device or gates its lifetime —
  including the bootstrap target, whose surface the device was selected
  against — so closing the first-created window cannot release a device
  another target is using (D-7). A surface-free session's device has no
  bootstrap target at all, and a session with no target still holds it until
  whole-owner retirement.
- **An owner-thread action's standing belongs to the controller's queue**
  from admission until it is settled; what the action constructs belongs to
  the recording, as the renderer's constructions do, whatever becomes of the
  action.
- **Each admitted target's surface belongs to the roots** from admission until
  its retirement destroys it. Each target record carries the model's
  `TargetId`, the application's required or optional designation (D-22), the
  surface's handle and the one action that destroys it.
- **Each target's swapchain generations belong to the generations above the
  roots**, from the construction that begins one until its destruction. A
  generation is the surface's child and the device's: the roots refuse to
  destroy a target's surface while the model holds any generation of it
  (`TargetGenerationsRemain`), and every generation of every target goes before
  the device. Swapchain images are the swapchain's and go with it; the image
  views are the generation's own.
- **The attachment and the window belong to the main thread.** A surface's
  obligation holds its attachment and the instance's lease from the instant
  the native call returns, so neither the window's release nor the instance's
  destruction can happen while the surface may exist (P-7).

## Composition

`withVulkanOwnerHost` composes, in P-5's order:

1. the loader capability, which the caller already holds, from
   `Hetoimasia.GLFW.Vulkan.withLoaderIntegration`;
2. the diagnostic lifetime (`withDiagnosticCapture`), whose capture both of the
   instance's messengers report into, and which the instance's destruction
   quiesces;
3. the loader-aware session, entered on the calling thread — which must be the
   process main thread — and which copies the instance extensions the
   platform's surfaces require (`requiredInstanceExtensions`) into the
   controller before the owner starts;
4. the protected window host and its graphics owner
   (`withGraphicsOwnerHostIn`), whose injected operations are the controller's;
5. the body, given a `VulkanHost`: the window host, the graphics owner and the
   controller.

Application supervision comes after, as the runner's own: register
`superviseGraphicsOwner` so a terminal owner failure reaches the application's
checkpoints. `withVulkanOwnerHostOver` is the same composition over an injected
native layer and surface bridge, which is what the headless examples drive.

It answers the body's result and the capture's verdict. The verdict's
quiescence evidence is what the instance's destruction returned; roots whose
instance was never created prove it trivially. However the host ends, an
instance it did not destroy keeps the capture's storage retained rather than
freed under a messenger that may still name it.

`VulkanHostConfig` names the host configuration, the capture configuration,
the instance layers to enable (each must be offered by the loader), the model's
budgets, the owner's initial scene, an adjustment to the owner's configuration,
a `NativeObserver`: something that wraps every native call the controller
makes — the recording's and the frames' included — for evidence, a
`VulkanRenderer`, a `FrameObserver`, when the device is created
(`vulkanDeviceStart`: `DeviceAtFirstSurface`, the default, or
`DeviceSurfaceFree`), and how many owner-thread actions may be queued at once
(`vulkanActionCapacity`, `defaultActionCapacity` — 64 — by default). The observer must run each call once
and answer what it answered; it decides nothing, and the default observes
nothing. The renderer records one frame of the scene between the controller's
transitions into rendering and to presentation, with the session's managed
construction lent to it ([Consumer construction](#consumer-construction));
`clearRenderer`, the default, clears it to opaque black. The frame observer is
told each acquisition, submission, present request, present return and
observed completion, on the owner's thread, and the default is told nothing.
`withVulkanOwnerHostOver` also takes the recording's and the frames' native
layers (`RenderingOps`); `withVulkanOwnerHost` supplies the production ones.

No configuration field turns [verification capture](#verification-capture) on.
The package's private `controller` sublibrary composes the same production
host with it (`withVulkanOwnerHostAs CaptureOn`, in
`Hetoimasia.GPU.Vulkan.GLFW.Internal.Production`), and so does its headless
seam (`withVulkanOwnerHostHooked`); `withVulkanOwnerHost` is
`withVulkanOwnerHostAs CaptureOff`, and no host outside the package's own
suites can capture.

## Threads

| Work | Thread |
| --- | --- |
| Loader-aware session, extension copy, window creation, each surface's creation through GLFW | The process main thread |
| Instance and messenger creation and destruction, device selection and creation, the later-target check, every surface's destruction, device destruction | The graphics owner |
| Every surface query, swapchain and image view creation and destruction | The graphics owner |
| Publishing a target's observation (`publishGraphicsObservation`) and capturing its window's render demand | The main thread: `runVulkanOwnerLoop` does both every turn |
| Publishing the scene (`publishVulkanScene`) | Any application thread |
| Recording, acquiring, submitting, presenting, abandoning, asking a fence, and destroying frame synchronization and frame storages | The graphics owner |
| Holding and ending a generation's CPU use | Any thread, in `STM` |
| Reporting a swapchain call's out-of-date, suboptimal or surface-lost result | The graphics owner, whose acquisitions and presentations produce it |
| Destroying a lost surface, rechecking a replacement's support, a reclamation pass | The graphics owner |
| Creating a replacement surface under a target's existing attachment (`replaceVulkanSurfaces`) | The main thread: `runVulkanOwnerLoop` does it every turn |
| Submitting an owner-thread action (`submitVulkanAction`) and reading or awaiting its outcome | Any thread, in `STM` |
| Running an owner-thread action, and everything it constructs or releases | The graphics owner, in its step, never beside a frame's rendering |

The controller makes no GLFW call. A surface is destroyed through the loader
capability's `vkDestroySurfaceKHR`, a Vulkan call, by the thread that holds its
obligation — the owner. The owner is one serialized Haskell thread, not a
promise of OS-thread affinity (P-1), so the evidence below requires its calls
to share one Haskell thread and each to run off the main OS thread.

## Startup

The owner's injected startup reads the extensions the session supplied (it is
refused with `InstanceExtensionsMissing` otherwise), plans the instance
against what the loader offers, creates the instance with the capture's
messenger chained into its create info, creates the explicit messenger, and
leases the instance to the surface bridge. `readReadiness` answers
`RootsReady` from then on, and an application hands windows over only after it.
A host configured with `DeviceSurfaceFree` also creates the device in that
startup, between the messenger and the lease, so `RootsReady` then means a
device exists too ([Surface-free bootstrap](#surface-free-bootstrap)).

The instance plan (`planInstance`) asks for Vulkan 1.3, the window system's
surface extensions, `VK_EXT_debug_utils`, `VK_KHR_get_surface_capabilities2`
and `VK_EXT_surface_maintenance1`, `VK_KHR_portability_enumeration` exactly
where the loader advertises it (with the enumerate-portability flag), and the
caller's layers. A loader below 1.3, a missing extension or a missing layer is
`InstanceRefusal`, naming the whole gap, before anything is created. A startup
that fails part-way leaves what it created recorded, and the owner's drain
retires and destroys it.

## Admitting targets

`handOverVulkanTarget` runs on the main thread. It attaches the window with a
protocol whose construction step:

1. registers the attachment with the owner's custody ledger — exactly
   `graphicsTargetProtocol`'s construction;
2. creates the surface through the surface bridge against the instance's lease;
3. deposits what it created, under the attachment's identity, for the owner.

The step is masked throughout. A cancellation aimed at the main thread
meanwhile arrives as the mask ends, still inside the step, where the host would
take it for a failed construction and roll back an attachment whose surface
exists; the step catches it, and the handover delivers it once the attachment
is published and announced, so the caller loses the answer rather than the
target. A synchronous failure is the construction's own. The handover then
announces the attachment to the owner through its bounded port:
`VulkanTargetHandedOver` when the port took it, `VulkanAnnouncementDeferred`
when the port was full, and `VulkanOwnerClosed` once the owner's admission has
ended. `VulkanRootsNotReady` attaches nothing.

The handover registers the owner's watch over an attachment before it
attempts the announcement, and withdraws it once the announcement is admitted
or the port has closed. So an owner that takes a refused port's events and
then chooses its next deadline always sees the watch; registering it only
after the refusal would let the owner go idle in between and never learn of
it. A deferred attachment stays attached, with its surface deposited. The same
holds for an attachment whose answer a cancellation lost after it was
published: the handover's recovery re-announces it, and if the port is full it
is deferred and watched exactly the same way. The caller
may announce it again with `announceVulkanTarget`, after which the owner
constructs it as any other target, or release it. Until it is announced the
owner watches it: while any deferred attachment exists, the owner names its
own next deadline one host idle bound ahead, so it takes rounds without being
woken, and its progress step destroys — on its own thread — the surface of any
deferred attachment whose slot has begun retiring, because it was released or
its window closed. That destruction is what lets the attachment's retirement
finish while the session runs; nothing else would ever tell the owner about
it. An attachment that is still attached may yet be announced, and one whose
announcement was admitted is the owner's ordinary target, so neither is
touched. A destruction there that is uncertain is never attempted again: its
obligation keeps retaining the attachment and the instance, and the step raises
`UnannouncedSurfaceUncertain`, which ends the owner's run and reaches the
application's checkpoints like any other owner failure.

The owner's construction takes the deposit:

- **A live surface** is offered to the roots. Without a device, the first one
  is the bootstrap:
  every physical device is queried with each queue family's presentation
  support for that surface, `selectDevice` takes the first satisfying the
  profile — Vulkan 1.3, `dynamicRendering`, `synchronization2`, the texture
  table's six descriptor-indexing features (`runtimeDescriptorArray`, `descriptorBindingPartiallyBound`,
  `descriptorBindingSampledImageUpdateAfterBind`,
  `shaderSampledImageArrayNonUniformIndexing`,
  `descriptorBindingVariableDescriptorCount` and
  `descriptorBindingUpdateUnusedWhilePending`,
  [The texture table](#the-texture-table)), `VK_KHR_swapchain`,
  `VK_EXT_swapchain_maintenance1` and its
  `swapchainMaintenance1` feature, and one queue family answering both
  graphics and presentation — and the device is created with that family's one
  queue and `VK_KHR_portability_subset` exactly where the device advertises
  it. No satisfying device is `NoCompatibleDevice`, naming every candidate
  and everything each lacks: a structured startup failure, fatal to the owner,
  whose drain destroys the surface, the messenger and the instance.
- **A later surface** — every surface, once a surface-free start has created
  the device — is checked against the session's queue family with
  `vkGetPhysicalDeviceSurfaceSupportKHR`. One it cannot present to is rejected
  with `TargetSurfaceUnsupported`: its surface is destroyed there and then, on
  the owner's thread, the target settles as a verified rollback, and the
  device, the instance and every existing target are untouched. No second
  device and no second queue is ever created (D-7).
- **An unusable surface** — created but unpublished — is destroyed the same way
  and rolled back; **a creation that failed** is rolled back with nothing to
  destroy; **a deposit that never arrived**, because a cancellation lost the
  step's answer, is found on the lease instead and destroyed.

A rejected target's reason is readable with `readTargetRejection` (the most
recent 64 are kept), and its standing with `readTargetStanding` is
`TargetUnusable False`: nothing remains, and the main thread releases it. A
construction whose surface destruction was uncertain settles as partial
instead, and the owner retires it — which is where the uncertainty is kept.
An admitted target is `TargetUsable`; `readVulkanTargets` lists each by its
attachment, with its model identity, designation and surface.

## Swapchain generations

`Hetoimasia.GPU.Vulkan.Native.Generations` owns every admitted target's
swapchain generations, above the roots and over their native layer's
`GenerationOps`. The controller tracks a target as soon as the roots admit it,
hands every progress step the geometry the owner folded for each constructed
target, and retires a target's generations before its surface. Each generation
is the model's `GenerationId`, and each of its images that identity and an
index; the model decides what a generation owes and when it may go, and this
module makes the calls and records each result in the same masked step that
made it.

### Lifecycle

| Stage | What happens |
| --- | --- |
| Planned | The surface's capabilities, formats and modes are read on the owner's thread, and `planGeneration` decides: the profile's format and FIFO, D-30's extent, and an image count within the surface's limits and the tracking limit. |
| Constructing | `beginGeneration` reserves the candidate's image accounting at the tracking limit and, for a replacement, retires the active generation there and then. The swapchain is created; its images are enumerated, and their count is checked against the tracking limit **before** any view is built; a view is created for each image. |
| Active | `publishGeneration` records the count the driver actually returned. The target is `Presenting`. |
| Retired | Handed over as `oldSwapchain`, retired on its own, refused, failed or superseded. Nothing is acquired from it again, and no CPU use of it can begin. |
| Destroyed | Once the model reports every hold on it ended — presentation retirement included — its views, newest first, then its swapchain, whose images go with it. Then the model records the disposal. The owner's step destroys at most the model's progress-action limit of generations, one of each target's in turn, starting one target further along each step; a target's own retirement or capacity path destroys all of that target's it can. |

The per-target presentation pool is not a generation's: a retired generation's
pending presentations keep their pool records, counted against the same target
capacity a new generation draws on (see
[The presentation pool](#the-presentation-pool)).

### The extent

`chooseExtent` is D-30, in the order of `Hetoimasia.Runtime.GLFW`'s
`chooseTargetExtent` seam, over the controller's `targetGeometry` view of it:

1. the target's render eligibility — hidden, minimized, deferred with no
   framebuffer observed, or closing — withholds it before the surface is asked
   anything;
2. a concrete current extent the surface supplies is taken as it is, unless it
   has no area;
3. otherwise the application chooses: the last published framebuffer
   observation, checked for area **before** it is clamped, then clamped to the
   bounds the platform published, if any, and to the surface's reported bounds;
   a clamp that still leaves no area is withheld too.

Nothing is invented: with no observation to choose from the extent is withheld
(`SuspendedUnobserved`). A withheld extent leaves the target `Suspended`, which
is not a failure and spends no recovery attempt. The swapchain is always the
framebuffer's size in physical pixels, never the window's: on a Retina display
it is twice the window size.

The observation reaches the owner through `publishGraphicsObservation` on the
main thread, which `runVulkanOwnerLoop` does every turn whenever the window's
observation is newer than the one it last published. An application that
drives its own loop publishes it itself, after a handover and after anything
that changes its window.

### The profile

P-15's first profile: single-sample SDR, color-attachment usage only, FIFO,
opaque composition where offered, and an advertised `B8G8R8A8_SRGB` or
`R8G8B8A8_SRGB` format in the sRGB nonlinear color space. The transfer usages
the retired proof harness asked for are neither required nor requested, and
nothing falls back to a UNORM or an arbitrary format. A surface that cannot
serve the profile leaves its target `PresentationUnsupported`, naming every gap
at once; it is a structured target failure, not an assumption.

### Replacement

A target is rebuilt when its geometry moves, when a swapchain call on its
active generation answered out of date or suboptimal (`noteSwapchainResult`, or
a replacement the model counted from an acquisition), or when it resumes after
its active generation was withdrawn. Those calls run on the
owner's thread, and so does the report: it makes the owner's next deadline
immediate, so the owner that reported a result takes the round that
reconciles it rather than going idle. A report from another thread wakes
nothing, and the package's public module does not offer one.

- **Ordinary resize** is not a failed construction. A move is coalesced for
  16 ms on the owner's monotonic clock from when it was first seen
  (`Settling`), and then built from the newest extent and observed geometry. A
  later change within the period joins the move rather than restarting its
  wait, so a resize that never pauses — a Cocoa live resize changes the
  framebuffer about every 8.5 ms — is rebuilt once a period rather than never.
  Meanwhile the active generation keeps presenting
  ([Acquisition](#acquisition)): a swapchain that answered suboptimal still
  presents, scaled to the surface. A move that settles at the extent the
  active generation already has is adopted without a rebuild, and a move that
  returns to the active generation's geometry is cancelled. A surface that
  reports its new extent later than the period is reported by the active
  generation's next suboptimal or out-of-date answer, as any resize is.
- **Withdrawal** is not a failed construction either. A target suspended as
  ineligible while a generation stood — its window hidden or minimized — or
  whose generation the owner withdrew (`withdrawGeneration`, when its step
  view's withdrawal count rose before a hide) presents on that generation no
  more: once eligible it is replaced at once, at whatever extent, handing the
  old one over, with no settling period and no recovery attempt, and it stays
  suspended in the model until the replacement is published
  ([Pacing, suspension and fairness](#pacing-suspension-and-fairness), #357).
- **Reconciliation without a fresh observation.** With a concrete surface
  extent, an out-of-date or suboptimal result is enough to rebuild at the
  surface's new extent: a main thread stalled in a platform modal loop does not
  hold the target at stale geometry.
- **Unchanged geometry** is not a resize. An out-of-date or suboptimal result
  whose plan is the extent the active generation already has makes the rebuild
  a recovery attempt, admitted by the model's episode: at most three, 100 ms and
  then 500 ms apart after failures (`RecoveryWaiting`), and exhausting it is
  escalated through the target's designation — an optional target unavailable,
  a required one failing the session — and reported as `RecoverySpent`, which
  [Recovery](#required-and-optional-dispositions) acts on. Nothing retries
  hot. A next attempt whose delay the clock cannot express — one failing at the
  very end of its range — is never admitted early: the target is reported as
  `RecoveryUnscheduled`, builds nothing and asks for no step, whether its
  surface was lost or a construction failed. A recovery rebuild whose observed geometry
  has moved — since the active generation, or since the failed construction
  was planned — first waits for that move to settle, as any resize does; one
  whose geometry has come back cancels the move it had begun to settle, so a
  later move waits its own full period.
- **The irreversible `oldSwapchain` transition.** Replacement hands the active
  generation over. The model retires it when the replacement is admitted, and
  it is recorded as handed over to Vulkan immediately before the creation call
  that passes it — a replacement cancelled before that call never handed it
  over, and it stays a swapchain Vulkan counts as unretired. It is marked
  retired before the native call, and a creation
  that then fails leaves the target without an active generation, in
  `ConstructionFailed`. The next construction is a fresh one — never passed the
  retired handle, never replaying the failed call — and a recovery attempt. It
  begins only once every swapchain of the target that Vulkan still counts as
  unretired has been destroyed, and, since it hands nothing over, every
  retired chain still standing too — the one the failed replacement handed over
  included, however long its holds keep it (VK-14), so a failed candidate that was created goes
  first, and so does an old generation a cancelled replacement never handed
  over; a retry that must wait for one spends no recovery attempt.
- **A newer resize during a replacement** is not lost: the replacement publishes
  what it was begun for, and the newer geometry is built next, while the
  generation it replaced keeps its obligations until they end.

### Bounds

A target holds at most the model's generation limit, two by default, counting
active, constructing and retired together. At capacity, every retired generation
whose holds have ended is destroyed first; if the replacement still cannot fit,
the target is `Backpressured` until a hold ends, and every other target and the
owner carry on. When only the generation count is in the way and an active
generation remains, the target keeps presenting from it: those frames spend
nothing the replacement waits for, since the retired generation's holds end on
their own present fences. Any other budget suspends the target in the model
while it waits. With a limit of one, the active
generation is the only thing in the way: it is retired on its own, awaited, and
destroyed, and a fresh generation is built without it once its move's period
has passed — every construction after a target's first is a replacement, and
is coalesced the same way. No target reserves or
releases anything of another's.

### Holds

A generation's ended-CPU-use hold is certified when it retires, unless a CPU use
is still held: `useVulkanGeneration` holds one on the active generation, from
any thread, and `endVulkanGenerationUse` ends it. While one is held the
generation is retired but not destroyed; the model's schedule keeps the owner
polling it, and the owner destroys it at the first step after the use ends.
A recorded batch holds the generation it records into as a recorded reference
([Retention](#retention)); a submission holds it until its fence signals
(VK-12), and a presentation until its present fence signals (VK-13).

### Failure and close

- A destruction that raised is uncertain. The generation is kept, marked so,
  and never offered again; the session fails with `CleanupFailed` and the roots
  close admission; the step raises `GenerationDestructionFailed`, which ends the
  owner's run. The surface above it is retained (`TargetGenerationsRemain`), and
  with it the device and the instance.
- An effect whose bookkeeping could not be committed enters the same path
  (`GenerationEffectUncertain`). A creation that raised created nothing.
- Admission through a construction's settlement is one masked region, so a
  candidate the model admitted is always settled. Each native effect and its
  record are consecutive inside it, and a cancellation can land only between
  effects: whatever
  exists is recorded, the construction is settled as failed, and the
  cancellation is then delivered. A creation a cancellation reached after it
  returned leaves its swapchain owned, and destroyed before the next
  construction. One a cancellation interrupted *inside* the call — which blocks
  interruptibly — may have created something whose handle never came back: its
  candidate is kept uncertain and never destroyed, the session fails with
  `CleanupFailed`, admission closes, and the surface and everything above are
  retained.
- Device loss raised by any generation call is latched as the roots' is.
- Close wins: a closed target begins no construction and admits no recovery
  attempt, and a construction completed after the close is retired rather than
  published. A target's retirement retires its active generation, destroys every
  generation whose holds have ended, and raises `GenerationsRetained` —
  manufacturing no evidence — if any remains, which retains the surface, the
  window and every parent.

### How the generations are built

`Hetoimasia.GPU.Vulkan.Native.Generations` is the entry point and holds no code
of its own: it re-exports, with unchanged names, signatures and constructor
visibility, what eight private modules under
`Hetoimasia.GPU.Vulkan.Native.Internal.Generations` implement. The split (#266)
moved code and changed no behaviour, and VK-14 added `Surface`; each module's
Haddock states what it owns.

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `State` | The `Generations` and its one map of target records, each with its generation records; the conditions, standings and swapchain results; the constructors and `trackTarget`; the three failures; and the lookup, edit, ended-CPU-use and asynchrony helpers every other module shares. | — |
| `Uses` | `noteSwapchainResult`, and holding and ending a CPU use of the active generation, in `STM` on any thread. | `State` |
| `Disposal` | Making the generations and registering their disposer with the roots; destroying every retired generation whose holds ended, views newest first and then the swapchain, each in one masked step; and the model's progress turn that records the disposals. | `State` |
| `Reconciliation` | One target brought to its latest geometry: eligibility and suspension, planning, settling, recovery through the model's episode, capacity and the one-generation path, and the masked construction, naming and publication of a candidate with its `oldSwapchain` handover. | `State`, `Disposal` |
| `Step` | `stepGenerations` — disposal, then each named target's reconciliation, then the lost surfaces' release, then one progress turn — and `generationsDeadline`. | `State`, `Disposal`, `Reconciliation`, `Surface` |
| `Surface` | A lost surface released once its generations have gone, an attempt asked for, and its replacement taken or refused (VK-14). | `State` |
| `Retirement` | `retireTargetGenerations`: close, retire the active generation, dispose, and forget the target only once none remains. | `State`, `Disposal` |
| `Observation` | `readTargetGenerations` and its views. | `State` |

The graph is acyclic, and no module adds state: the target records and their
generation records are the one map `State` creates, and each module edits only
what its own operation concerns — the table in the public module's Haddock
names which. A `GenerationUse`'s ended flag belongs to its holder, and a
construction's note of the creation call in progress to that one construction.
`Generations` and `GenerationUse` stay abstract: their constructors are
exported only by `State` and `Uses`, which clients cannot import. The
recording's private modules still import the public module, and no new module
declares a foreign import.

## Device memory

GRS-11 (#333) backs device memory with VMA beneath the model's accounting, as
D-38 and D-40 of the [GPU resource services design](designs/gpu_resource_services_design.md)
decide. `Hetoimasia.GPU.Vulkan.Native.Allocator` is the allocator's shape — an
open record of calls, `AllocatorOps`, over 64-bit handles — and the engine's
memory-type policy; `Hetoimasia.GPU.Vulkan.Native.Allocator.Vulkan` is its
production form, VMA through the engine's own shim; the headless examples
supply a stand-in that keeps its blocks in Haskell. No VMA type crosses the
package's public API: the shim's imports are private, and an external-client
example proves neither they nor the Hackage binding the package links for its
compiled VMA are reachable.

### Ownership and thread

One allocator per device. The roots create it right after the device — at the
first admission or a surface-free start — with
`VMA_ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT`, the instance's
`vkGetInstanceProcAddr` and the device's `vkGetDeviceProcAddr` from the
binding's own dispatch tables, `vulkanApiVersion` 1.3, and an explicit
large-heap block size of 256 MiB (`largeHeapBlockSize`, VMA's own default, as
#361 measured it). Every user of the device shares it, and every call to it is
made on the graphics owner's thread; nothing relies on VMA's internal locking.
An allocator whose creation raised is absent: the device stays recorded for
retirement and the failure is raised, and nothing can be allocated
(`RefusedDeviceAbsent`).

The roots destroy it child before parent: after every target's surface and
before the device, and only once every allocation made from it has been freed —
`retireRoots` raises `AllocationsRemain`, retaining the allocator and the
device, while one remains. Its destruction frees the device memory VMA still
held, its retained empty blocks, and that is released from the model's
accounting in the same masked step, exactly once. A destruction that raised is
uncertain: the allocator is recorded so, the session fails with
`CleanupFailed`, and the device is retained (`AllocatorRemains`).

### Usages and memory types

An allocation names a `MemoryUsage`, which states the properties it requires
and prefers (D-16):

| Usage | Required | Preferred | For |
| --- | --- | --- | --- |
| `UsageTexture` | device-local | — | textures, always staged |
| `UsageStaticGeometry` | device-local | — | static geometry, staged |
| `UsageStaging` | host-visible | host-coherent | staging written by the host |
| `UsageFrameRing` | host-visible | host-coherent | per-frame rings the device reads directly |
| `UsageReadback` | host-visible | host-cached | readback buffers |

The engine, not VMA, chooses the one memory type an allocation uses
(`chooseMemoryType`): among the types the buffer's `memoryTypeBits` allow
with every required property, the one with the most preferred properties, and
of those the lowest index. It passes only that type's bit to VMA, so VMA can
neither choose nor fall back to another; VMA still honours the driver's
preferred or required dedicated allocation within that type. A usage no
allowed type serves is `RefusedNoMemoryType`, naming the usage, before any
allocation. Each [buffer or image kind](#buffers-and-images) fixes the usage
its allocation is made under; depth and color targets, which only the device
writes and reads, use the texture usage's device-local memory.

### Accounting and backpressure

The model's accounted bytes charge the device memory VMA holds — each block
and each dedicated allocation — never a resource's own size (D-15, D-40). The
private allocation protocol makes a buffer's or an image's memory for an
allocation attempt in this order; the two differ only in VMA's calls
(`vmaCreateBuffer` and `vmaCreateImage`, `vmaDestroyBuffer` and
`vmaDestroyImage`) and in that an image is never mapped:

1. The resource's memory requirements are asked of the device without
   creating it (`vkGetDeviceBufferMemoryRequirements`,
   `vkGetDeviceImageMemoryRequirements`), and the memory type chosen.
2. The resource is created in held memory only
   (`VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT`). That opens nothing and charges
   nothing new. A request nothing held fits (VMA's
   `VK_ERROR_OUT_OF_DEVICE_MEMORY`) and one the driver requires dedicated (VMA's
   `VK_ERROR_FEATURE_NOT_PRESENT`, since a dedicated allocation is never made
   in held memory) are both the expected miss, `NotPlaced`: they spend no
   recovery and lead to the next step.
3. The attempt reserves the most the allocating call could open
   (`reserveDeviceMemory`): the larger of the type's preferred block size —
   VMA's `CalcPreferredBlockSize`, an eighth of a heap of at most 1 GiB and
   otherwise the configured 256 MiB, aligned to 32 bytes (`preferredBlockSize`)
   — and the requirements' size. The bound holds only under
   [D-40](designs/gpu_resource_services_design.md#d-40-the-byte-budget-charges-vmas-blocks-reserved-before-one-can-open)'s
   preconditions: the allocating call asks VMA to map nothing — no
   `VMA_ALLOCATION_CREATE_MAPPED_BIT`, nor any other mapping inside the call;
   the shim passes `VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT` in step 2 and no
   flags at all here — and `VMA_DEBUG_MARGIN` is zero in the VMA the engine
   links. Without them VMA can retain a freshly opened block whose commit
   failed and open a dedicated allocation as well, in one call
   (#367). A reservation the byte budget cannot hold is
   `RefusedBackpressure`, answered before the call that could open memory, and
   never enters recovery. A reservation the model rejects — the session failed,
   or the attempt may no longer allocate — is refused with its misuse
   (`RefusedMisuse`), and the call that could open memory is never made.
4. The allocating call. VMA's device-memory callbacks, counting in C inside
   that call, record every block or dedicated allocation it opened and freed.
   Right after it — whether it succeeded or not — the effect is settled
   (`settleDeviceMemory`): the reservation is replaced by what it opened,
   nothing if it opened nothing, the rest returned at once, and what it freed
   released.
5. An effect that disagrees with the accounting is a defect
   (`AccountingFinding`): opening more than was reserved, which under step
   3's preconditions cannot happen and so shows one of them was broken;
   freeing more than was charged as held, after which the charge
   would no longer bound the memory; or an effect the model refused to settle
   under the attempt, which is then settled under no reservation so nothing
   held goes uncharged. The resource is destroyed before its allocation is
   freed, that effect settled too, and the request fails with
   `AllocatorAccountingDefect`. The memory still held stays charged. The
   session fails with `CleanupFailed`, and nothing else is freed for it,
   unless the defect is memory opened beyond a reservation that the budget
   still holds.
6. A buffer's host-visible allocation is mapped for its lifetime
   (`vmaMapMemory`), by this separate call after the allocating call has been
   settled — never by the allocating call itself, which is step 3's first
   precondition — so a failed mapping never enters that call's accounting.
   Persistent mapping for any later buffer or image kind, the host-visible
   staging ring among them, follows the same rule. An image's allocation is
   not mapped: it is optimally tiled, and the host never writes it directly
   (D-16).

Every later call that can free memory — a destruction, the allocator's own —
is settled the same way before anything else is admitted, and a defect there
fails the session the same way, though the destruction itself stands. A block several
resources share is charged once, and disposing of or abandoning a resource
releases none of it; VMA's retained empty block stays charged until VMA frees
it. Under the default 256 MiB byte budget and VMA's 256 MiB large-heap block,
the bound admits an allocating call on a large heap only while nothing else is
charged, so a consumer that needs more than one block on such a heap raises
the budget (D-11); placements in held memory are unaffected.

### Recovery

A no-effect out-of-memory result from the allocating call reaches the
construction's VK-14 recovery with its reservation already returned: one
reclamation pass and at most one retry, which runs the whole protocol again —
held memory first, then a fresh reservation against the reconciled
accounting. Disposing of a resource counts as progress, so a retry can succeed
by placing in memory the pass emptied, even when no block was freed; the
nested steps of one construction make one retry between them. A placement miss
is never a failure, and backpressure never reaches recovery. An effect that is
uncertain follows the [terminal-failure policy](#terminal-failure).

### Failure cleanup

A creation, bind or map that failed leaves nothing allocated and no
reservation held. VMA's own creation destroys what it made when its bind
fails, inside the same call, and the effect it reports is settled; a map that
failed destroys the buffer and frees its allocation, settling that; an owned
view whose creation failed destroys its image and frees the image's
allocation, settling that. Memory such
a failure left held — a block opened for it and kept, empty — stays charged
until VMA frees it, and the next request may place in it. Each allocation is
counted with the roots the moment the call that made it returns, and a
failed request counts what it made gone only once destroying it returned; a
destruction that raised there has an unknown effect, so the allocation stays
counted — the allocator, and the device, are never destroyed under it — the
session fails with `CleanupFailed`, and the request's own failure is the one
raised. A failed request
rolls back only itself: other allocations, their blocks and their mappings are
untouched.

### Lifetime and mapping

An allocation is freed only when the model allows its resource's disposal,
after completion evidence has ended every submitted use: VMA tracks no GPU use
and is never relied on to. Teardown unmaps, destroys the buffer, then frees its
allocation; for an image it destroys the owned view, then the image, then frees
its allocation. Each allocation is mapped once, for its lifetime; VMA maps the
block beneath as it needs, and unmapping one allocation leaves its siblings'
mappings alone. Flushes and invalidates are allocation-relative ranges given to
VMA ([Readback memory](#readback-memory)).

### State

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| The allocator | The roots | Created after the device by `createDevice`; read by the allocation protocol; destroyed by `retireRoots` | The owner | The device's | Destroyed once no allocation remains, before the device; uncertain if its destruction raised, retaining the device |
| Live allocations | The roots | The allocation protocol counts each made and freed; `retireRoots` reads | The owner | The session | Counts down as each is freed |
| The callbacks' counts | The shim's allocator state | VMA's device-memory callbacks write, inside each call; each shim entry clears them before the call and copies them out after | The owner, inside a VMA call | The allocator's | Freed with the allocator |
| Device-memory charges | The model (`gpuDeviceMemory`) | Settled after every allocator call; reserved per attempt before an allocating call | The owner | The session | Released only as VMA reports memory freed |

## Recording through managed resources

`Hetoimasia.GPU.Vulkan.Native.Recording` is D-26's small Vulkan-specific
recording interface as VK-11 delivers it. A renderer never holds a native
handle: it holds opaque managed handles, each naming one generation of one
managed resource by the model's `ResourceId`, and it records through a
`Recorder` lent to one consumer action. Every native call goes through an open
native layer, `RecordingOps`, whose production form is
`Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan`; the headless examples supply a
stand-in. A `Recording` is created over the session's roots and generations by
the graphics owner, and every operation is refused with `RefusedNotOwner` on any
other thread.

### How the recording is built

`Hetoimasia.GPU.Vulkan.Native.Recording` is the entry point and holds no code of
its own: it re-exports, with unchanged names, signatures and constructor
visibility, what seven private modules under
`Hetoimasia.GPU.Vulkan.Native.Internal.Recording` implement. The split (#265)
moved code and changed no behaviour; each module's Haddock states what it owns.

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `Layer` | The native layer's shape: `RecordingOps` and the command, layout and request vocabulary, the buffer and image kinds and what each fixes. No state, no call. | — |
| `State` | The `Recording` and the three maps it holds; handles, refusals, failures and views; the owner check, the live-generation check, the model helpers and a generation's one native destruction. | `Layer` |
| `Construction` | Creating, replacing, naming and releasing managed resources, each in one masked step. | `Layer`, `State` |
| `Batches` | Discard, reset, submission evidence, and freeing a slot of completed batches: invalidate natively, then discharge. | `Layer`, `State` |
| `Recorder` | `recordFrame`, the `Recorder` and its commands, retention before each native call, and label balancing. | `Layer`, `State`, `Batches` |
| `Readback` | Host reads gated on completion evidence, host fills, and their flushes and invalidations through the allocator. | `Layer`, `State` |
| `Disposal` | Destroying released generations child before parent, recording disposals, and retirement. | `State` |

The graph is acyclic, and no module adds state: the managed records, the frame
storages and the batch records are the `Recording`'s three maps, created by
`State`, and each module edits only the entries its own operation concerns, on
the graphics owner's thread — the table in the public module's Haddock names
which. A `Recorder`'s own references belong to the one `recordFrame` that made
it. `Recording.Vulkan` and `Recording.Shaders` still import the public module,
and no new module declares a foreign import, so `Internal.Commands` remains the
only home of the `unsafe` subset.

### The boundary as delivered

| Capability | Operation | What the backend keeps |
| --- | --- | --- |
| Managed rendering resources | `createPipelineLayout`; `createPipeline` over a layout, VK-9's embedded shaders and a color format; `replacePipeline`; `createFrameStorage` for a target's frame slot; `createReadback` of a byte size; `createBuffer` and `createImage` of an engine-defined kind ([Buffers and images](#buffers-and-images)); `releaseManaged` | The native objects, their accounting reserved with `beginAllocation` before each creation, and the exact generation each handle names |
| Checked frame | `recordFrame` takes a `FrameSlotId` the model holds acquired, and resolves its image, view, extent and format through the generation that owns them | The frame's generation, retained by the batch |
| Scoped recorder | `transitionImage`, `transitionResource` ([Ordering](#ordering-managed-resources)), `beginRendering`, `beginRenderingInto` ([Offscreen color targets](#offscreen-color-targets)), `bindPipeline`, `setViewport`, `setScissor`, `draw`, `endRendering`, `copyToReadback`, `copyTargetToReadback` | The slot's command storage, the batch's recorded references, and its managed resources' uses |
| Recorded batch | `discardBatch`; `resetFrameRecorder`; `noteBatchSubmitted`, which VK-12's `submitFrames` calls | Sealed commands and references, whether or not the caller keeps the `BatchId` |
| Readback | `readReadback`, `fillReadback` | The buffer's allocation, its mapping, and what last wrote it |
| Disposal | `disposeResources`, `retireRecording` | Destruction on the owner, only once the model reports every hold ended |

The supported vocabulary is exactly the triangle and its verification: dynamic
rendering into the frame's one color view or a managed color target's
([below](#offscreen-color-targets)), a graphics pipeline compatible with the
attachment's format, dynamic viewport and scissor, whole-triangle draws —
instanced, and indexed and instanced, from vertex, index and instance data bound
from managed buffers and the session's shared ring, with push constants
([Drawing from buffers](#drawing-from-buffers), GRS-4) — the four image
transitions below, one bounded copy of the whole frame image or color target
into a readback buffer, and GRS-3's checked transitions and boundary barriers of
managed buffers and images. There is no raw command buffer, no callback escape
hatch, no descriptor, no sampling of an image, and no render graph. A command outside that vocabulary — an
unsupported transition, a draw that is not whole triangles, a transition into or
out of the transfer-source layout or a copy of an image that is not a transfer
source — is `RefusedUnsupported`; one the recorder's state
does not admit — a draw outside rendering or before a pipeline, viewport and
scissor, a transition inside rendering or from a layout the image is not in,
rendering into an image that is not a color attachment, a viewport that is not
finite or has no area, a viewport or scissor that leaves the attachment — is
`RefusedIllegal`. Keeping both within the image keeps them within every
device's viewport limits, which Vulkan requires to cover any image a
framebuffer can hold, so no device limit is read.
Either way nothing native happens.

Construction is ordinary `IO` on the owner. A creation reserves its accounting
first, so an exhausted budget is `RefusedBackpressure` before any native call;
a creation that raised created nothing and gives the reservation back; one that
returned is recorded as a managed generation in the same masked step. A frame
slot has at most one storage — a command pool with one primary command buffer —
and one outstanding batch; `createFrameStorage` refuses, before any native
call, a target that is not this session's, not admitted or suspended, or a slot
the frame budget cannot issue. A construction whose native layer raised after
making part of its objects — a pool whose command buffer could not be
allocated, a buffer whose memory could not be mapped — destroys that part before
raising, so a creation that raised created nothing. A readback's creation may
also refuse, having made nothing: `RefusedBackpressure` for device memory the
budget cannot hold, `RefusedNoMemoryType` for a usage no memory type serves
([Device memory](#device-memory)).

### Retention

Every recording operation, in order:

1. checks the calling thread, that the recorder's consumer is still running
   (`RefusedRecorderClosed` otherwise), each handle it names — this session's
   (`ForeignIdentity`), still managed (`StaleIdentity`), not replaced
   (`StaleIdentity`), not released (`WrongPhase`) — and the recorder's state;
2. registers, in the model, the exact resource generations it references — its
   own, and the transitive dependencies of the binding: a pipeline's layout
   generation, fixed when the pipeline was built — as recorded references of the
   batch (`extendBatch`), before the native call that could capture them;
3. makes the native call.

Steps 2 and 3 are one masked step, so a cancellation lands only before the
reference is taken or after the command is recorded; a refusal at step 1 or 2
makes no native call. The union is taken per operation and the model keeps one
reference per subject per batch, so binding the same pipeline twice, or two
pipelines over one layout, retains each subject once and is not a duplicate. The
batch itself is admitted by `recordBatch` against the acquired frame, which
reserves its record — the only accounting a batch needs — and retains the frame's
swapchain generation and the slot's storage; a budget that cannot reserve it
refuses `recordFrame` before any command buffer is begun.

A batch never resolves a resource again. `replacePipeline` publishes a new
generation and releases the old one, whose handle then records nothing more;
every batch that recorded the old generation keeps naming it, and it and its
layout are destroyed only when those batches' references end. Releasing a handle
denies new recordings through it and ends its CPU use, and leaves every batch
that already recorded it untouched. In-place mutation of data a batch depends on
is refused: `fillReadback` answers `RefusedInUse` while any batch or submission
holds the buffer, and nothing else can write a managed resource.

### Batches

`recordFrame` runs its consumer exactly once. It seals the batch only if the
consumer returned with rendering ended and no command's native call raised. A
command whose call raised may or may not have reached the buffer: the batch is
marked partial at that boundary, the recorder records nothing more, and a
consumer that catches the exception and returns still gets `RefusedIllegal`
rather than a sealed batch. A consumer that raised, a cancellation,
or rendering left open leaves the batch **partial**: its commands and every
reference it took stay owned, the slot's storage stays occupied, it can never be
submitted, and the exception is re-raised (or `RefusedIllegal` answered for
unbalanced rendering). A recorder kept past its scope refuses every command; no
claim is made that Haskell's lexical scope prevents keeping one.

`discardBatch` and `resetFrameRecorder` end a batch. Each first resets the
storage's pool — the native invalidation that makes future submission of its
commands impossible — and only after that returns discharges, in the model,
exactly that batch's references (`resetFrameRecorder`: every unsubmitted batch of
the frame). Neither settles the frame's acquisition or presentation obligation.
A batch still being recorded is refused, and so is one the model no longer
holds, or a frame no longer acquired: a submitted batch's commands may be
executing, and resetting its pool then would be invalid. An invalidation that
raised is uncertain: the batch keeps every reference, is never invalidated
again — neither `discardBatch` nor `resetFrameRecorder` of its frame retries
it — the session fails with `CleanupFailed`, and `BatchInvalidationFailed` is
raised. A batch record goes only with the model's discharge, so one the model
refuses to discharge stays. Discarding one batch never releases another batch's reference to a
shared resource.

A submitted batch keeps its record, and its slot's storage, until the
submission that carried it completes, since its commands may be executing
until then. The next `recordFrame` for that slot then resets the storage —
invalidating the executed commands so the buffer can be begun again — and drops
the record, so a slot records frame after frame. The frame is checked first:
a stale or foreign frame is refused before anything is done for the slot, and
only a live storage is ever reset. A completed batch's record also goes when
its storage is destroyed, since a storage is disposable only once nothing holds
it.

`skipUnsubmittedFrame` in the model also discharges a frame's batches, so
VK-12's `skipFrame` resets the frame's recorder through this module first: the
native invalidation always precedes the discharge.

### Names and labels

`Hetoimasia.GPU.Vulkan.Native.Naming` is the naming scheme as pure decisions.
When the instance enabled `VK_EXT_debug_utils` — the profile always asks for it —
and the device's own dispatch table resolved `vkSetDebugUtilsObjectNameEXT`,
`vkCmdBeginDebugUtilsLabelEXT` and `vkCmdEndDebugUtilsLabelEXT`, the roots offer
an `Instrumentation` (`readRootsInstrumentation`), and the backend names what it
creates and labels what it records. Without it nothing is named or labelled,
nothing fails, and recording and sealing are otherwise unchanged.

Every name is built from identities the backend already holds, by one function,
`boundedName`, which caps it at 64 bytes (`maximumNameBytes`) and drops any NUL.
No caller-supplied text reaches a name.

| Object | Named | When |
| --- | --- | --- |
| The device | `hetoimasia device` | At the first admission, once the device exists |
| Its one queue | `hetoimasia queue family <f> index 0` | The same; `vkGetDeviceQueue` is asked for it only to name it |
| A target's surface | `target <n>.<incarnation> surface` | Before the target is admitted, under the `TargetId` the model is about to issue |
| A generation's swapchain | `target <n>.<i> generation <g> swapchain` | Right after it is created, before the generation is published |
| Each swapchain image | `… generation <g> image <index>` | Right after the images are enumerated |
| Each image view | `… generation <g> view <index>` | Right after each is created |
| A pipeline layout, a pipeline | `resource <n>.<generation> pipeline layout`, `… pipeline` | After the model issues the `ResourceId`, before the handle is returned |
| A pipeline's vertex and fragment shader modules | `resource <n>.<g> pipeline vertex shader`, `… fragment shader` | Each right after it is created and before the pipeline is built from it, under the `ResourceId` the model is about to issue the pipeline; the modules are destroyed once it is built |
| A frame storage's pool and command buffer | `resource <n>.<g> command pool target <t> slot <s>`, `… command buffer …` | The same |
| A frame-less slot's fence | `frame-less slot <s> submission fence` | Right after it is created at the slot's first submission, before it is recorded |
| A readback's buffer | `resource <n>.<g> readback buffer` | The same. Its allocation is named the same inside the allocator, through VMA, whether or not the device offers naming; the device memory it lies in, which other allocations share, is named nowhere |
| A managed buffer | `resource <n>.<g> buffer` | The same, its allocation named the same inside the allocator, as a readback's is |
| A managed image, and its owned view | `resource <n>.<g> image`, `… image view` | The same, the image's allocation named as the image inside the allocator |

Every naming call runs on the graphics owner's thread through the roots' device
loss classification, and one that raised is handled as a failure of what it was
naming, by that thing's own rules. A surface whose name could not be set is not
admitted, so its creator still owns it. A device or queue whose name could not
be set stays recorded and owned, and is named again at the next admission. A
generation whose swapchain, image or view could not be named fails its
construction: it is retired unpublished and destroyed once its holds end. A
pipeline whose shader module could not be named is not created: the native
layer destroys the modules it made, and the reservation is given back. A
managed resource whose objects could not be named is released — nothing can
record it, and the owner's disposal destroys it — and its handle is never
returned; a replacement whose new generation could not be named leaves neither
generation recordable. Nothing is published as named that was not.

Two objects are never named. **The instance**: naming requires external
synchronization of the object named, and the surface bridge's lease lets the
main thread use the instance while the owner runs. **The debug messenger**,
on both profiles: the pinned loader answers its own wrapper for a messenger and
forwards a naming call without translating it, and MoltenVK reads that wrapper
as one of its own objects and crashes. Vulkan permits naming a messenger; the
defect is the loader's and the driver's together, and the backend makes no
naming call for one. The messenger's diagnostics stay the capture's own. The
crash and its diagnosis are retained in
[`docs/vulkan/macos-debug-utils-naming.md`](vulkan/macos-debug-utils-naming.md),
which also shows that a surface is named safely on a device that enabled
`VK_KHR_swapchain`, as the profile's device always does.

A labelled batch's command buffer carries two kinds of region, each named from
the batch's `BatchId` and its frame's target and generation:

| Region | Label | Opens | Closes |
| --- | --- | --- | --- |
| The batch | `batch <b> target <t> generation <g>` | Right after `vkBeginCommandBuffer` | Right before `vkEndCommandBuffer` |
| A dynamic-rendering pass | `pass batch <b> target <t> generation <g>` | Right before `vkCmdBeginRendering`, in the same masked step | Right after `vkCmdEndRendering`, in the same masked step |
| A pass into a managed color target ([GRS-5](#offscreen-color-targets)), in a frame or frame-less batch | `pass batch <b> into resource <n>.<g>` | Right before `vkCmdBeginRendering`, after the target's entry barrier, in the same masked step | Right after `vkCmdEndRendering`, in the same masked step |

The recorder counts the regions open, each from the moment its opening call
returned. Whatever else happens — a consumer that raised, a cancellation,
rendering left open, a command whose call raised — every region still open is
closed, innermost first, before `recordFrame` returns or raises. A closing call
that raised leaves the batch partial with the reason that its labels could not
be balanced: it is never sealed, never submittable, and keeps its commands,
storage and references until a discard or reset invalidates it; a label failure
supplies no retirement evidence. The consumer's own failure, when there was one,
is still the one raised. Label commands go through the native layer's
`opsRecord`, like every other recorded command, and count as commands.

### The checked frame

`recordFrame` requires the frame to be acquired in the model, with its image's
generation still recordable. Public acquisition is VK-12's `tryAcquireFrame`
([below](#frames-acquisition-submission-and-abandonment)); the backend offers
no way to fake one. VK-11's native case, which predates it, supplies its frame privately — it reserves a
frame and records the acquisition of image 0 in the model alone, through the
roots' model, making no native acquisition — and after the discard skips the
frame and supplies its unpresented-frame settlement, which is everything that
frame owes. That construction lives in the suite
(`Test.GPU.Vulkan.Native.Recording`), not in the backend's interface.

### Image transitions

The recorder tracks the frame image's layout and records each transition as one
`vkCmdPipelineBarrier2`, with these scopes:

| From | To | Source stage, access | Destination stage, access |
| --- | --- | --- | --- |
| Undefined | Color attachment | Color-attachment output, none | Color-attachment output, color-attachment write |
| Color attachment | Transfer source | Color-attachment output, color-attachment write | Copy, transfer read |
| Color attachment | Present source | Color-attachment output, color-attachment write | All commands, none |
| Transfer source | Present source | Copy, none | All commands, none |

Entering rendering waits on the color-attachment stage, which is where an
acquisition's semaphore wait is made. Leaving for presentation names every
stage as its destination, with no access: the presentation engine's read needs
no visibility operation, but the layout transition must be ordered before the
render-finished semaphore's signal, which the frames make at every stage. With
no destination stage the transition chained into nothing that followed it, and
on Lavapipe synchronization validation reported every presentation as
`SYNC-HAZARD-PRESENT-AFTER-WRITE` (VK-13). Retention proves lifetime only: these
layout and synchronization rules are the supported operations' own explicit
contract, not an automatic hazard resolver. They are a swapchain image's
alone; managed buffers and images are ordered by
[GRS-3's contract](#ordering-managed-resources).

### Readback memory

A readback buffer is a transfer-destination buffer whose memory comes from the
device's [allocator](#device-memory) under the readback usage — host-visible,
cached where the device offers it — bound, and mapped for its lifetime. It is
the allocator's first consumer. Its attempt reserves two objects, the buffer
and its allocation, and no bytes of its own: the memory is charged as the
allocator holds it, never as the buffer's size.

- **The copy.** `copyToReadback` needs the frame's image in the transfer-source
  layout, and an image its generation made a transfer source: only generations
  built for a verification capture are
  (`newGenerationsCapturing`, [below](#capture-usage)). The buffer must hold the
  whole image, four bytes a pixel (`readbackBytesFor`), or the copy is
  `RefusedOutOfBounds`. A buffer has one writer at a time: a copy into one that
  any batch — an earlier copy in the same batch included — or any submission
  still holds is `RefusedInUse`, since the two writes would be unordered and the
  contents misattributed. After the copy the recorder records a buffer barrier from
  the copy's transfer write to host reads; the transitions around it are the
  renderer's explicit commands.
- **Completion before exposure.** `readReadback` answers bytes only with
  positive completion evidence: the batch that recorded the copy was recorded
  as submitted — `noteBatchSubmitted`, which VK-12's `submitFrames` calls once
  the model has accepted the submission and before it completes, and which
  requires the model's word that the outstanding submission consumed exactly
  that batch (`submissionCarries`), so a batch reset in the model whose frame
  was then submitted without it is refused — and the buffer owes no recorded
  reference and no submitted use,
  which the model discharges only on that submission's completion fact. The
  evidence is kept on the buffer, so it outlives the batch's record. A batch
  the model merely no longer holds proves nothing, since a skip or a reset in
  the model removes one without submitting it. A fence is not a host-visibility barrier; the
  recorded barrier is what makes the write visible, and the completion is what
  makes reading it legal. With nothing submitted, a read is `RefusedNotWritten`,
  so a recorded-and-discarded batch never claims a captured pixel.
- **Non-coherent memory.** Before a read of non-coherent memory the bytes
  asked for are invalidated, and after `fillReadback` writes the buffer it is
  flushed, each as a range of the buffer's own allocation — an offset from its
  start and a size — through the allocator, which translates it into the
  device memory the allocation lies in and aligns it to the non-coherent atom.
  Nothing rounds the range before VMA does, and no range reaches past the
  allocation, so a neighbouring allocation in the same block is never flushed
  or invalidated over by this one's maintenance. Bounds are checked first: a
  read past the buffer is `RefusedOutOfBounds`. Coherent memory is read without
  either, and an empty read reads nothing and invalidates nothing. `fillReadback` marks the bytes unreadable before its write changes
  the first of them, and readable again only once the write and any flush have
  returned, so a write or flush that raised part-way exposes nothing.
- **Release.** Releasing a readback ends its CPU use: it is read no more.

### Capture usage

P-15's profile never requires transfer usage of a surface. A verification
capture needs its images to be transfer sources, so
`planGenerationWith CaptureWhenOffered` adds that usage wherever the surface
offers it — capture is never a gap. It also plans the swapchain unclipped
(`planClipped = False`): the verification strategy reads every pixel, and a
clipped swapchain's obscured pixels are undefined. Otherwise it plans exactly
what `planGeneration` does, and every generation `planGeneration` plans is
clipped. `newGenerationsCapturing` builds generations that way; no normal
target does, and the controller does so only for a host composed with
[verification capture](#verification-capture) on. VK-2 verified the
transfer-source capture profile on both drivers.

### Buffers and images

GRS-2 (#334) adds two managed handles, `Buffer` and `Image`, opaque over the
model's `ResourceId` like the others: no constructor and no native handle
reaches a client. `createBuffer` and `createImage` make them on the graphics
owner's thread; the window integration lends both, with `releaseConstructed`,
through the host's `Construction` (`constructBuffer`, `constructImage`), to a
renderer and to an owner-thread action alike, behind the same owner check,
checkpoint and construction-failure handling as its pipelines. A batch orders
and transitions them through GRS-3's checked operations
([below](#ordering-managed-resources)), and binds vertex, index and instance
buffers ([Drawing from buffers](#drawing-from-buffers), GRS-4); bytes reach a
fresh texture, vertex buffer or index buffer through the session's uploads
([Uploads](#uploads), GRS-6).

**Kinds.** A creation names an engine-defined kind, never raw usage flags.
Each kind fixes the resource's Vulkan usage flags and the memory usage its
allocation is made under ([Usages and memory types](#usages-and-memory-types)):

| Buffer kind | Usage flags | Memory usage | For |
| --- | --- | --- | --- |
| `VertexBuffer` | vertex buffer, transfer destination | `UsageStaticGeometry` | static vertex data, staged |
| `IndexBuffer` | index buffer, transfer destination | `UsageStaticGeometry` | static index data, staged |
| `InstanceBuffer` | vertex buffer, index buffer | `UsageFrameRing` | per-frame instance data, or the shared ring (D-33), which the device reads directly |
| `LookupBuffer` | storage buffer | `UsageFrameRing` | a per-frame lookup table (D-23, D-35) |
| `StagingBuffer` | transfer source | `UsageStaging` | host-written bytes the device copies from |

| Image kind | Usage flags | Format features required | Memory usage | View aspect | Formats |
| --- | --- | --- | --- | --- | --- |
| `TextureImage` | sampled, transfer destination, transfer source | sampled image, transfer destination, transfer source | `UsageTexture` | color | RGBA8 and BC7, each sRGB and linear (D-21) |
| `DepthTarget` | depth-stencil attachment | depth-stencil attachment | `UsageTexture` | depth | `D32_SFLOAT`, `X8_D24_UNORM_PACK32`, `D16_UNORM`: depth-only (D-36) |
| `ColorTarget` | color attachment, transfer source | color attachment, transfer source | `UsageTexture` | color | RGBA8 and BGRA8, each sRGB and linear |

`bufferKindUse`, `imageKindUse` and `kindFormats` state these as pure
functions. A buffer's host-visible allocation is mapped for its lifetime; an
image's never is.

**Descriptions.** A buffer is described by its kind and its size in bytes
(`BufferDescription`); an image by its kind, format, extent and mip-level
count (`ImageDescription`) — two-dimensional, one array layer, one sample,
optimally tiled, exclusive to the session's queue family, created in the
undefined layout. Before anything native is created:

- a buffer of zero bytes, of more than a `VkDeviceSize` holds, or larger than
  the device's `maxBufferSize` is `RefusedOutOfBounds`;
- an image whose format its kind does not take is
  `RefusedImageUnsupported`, naming both; a zero width, height or mip count is
  `RefusedOutOfBounds`, and so is more mip levels than the extent's full chain
  (`fullMipChain`);
- a BC7 image on a device created without `textureCompressionBC` is
  `RefusedImageUnsupported`. The profile enables that feature exactly when the
  device offers it (`planTextureCompressionBC`); it is optional, so a device
  without it is still selected, and only BC7 is refused on it;
- the device is then asked, without creating anything, whether its optimal
  tiling offers the kind's format features for the format, and what
  `vkGetPhysicalDeviceImageFormatProperties` allows for the kind's usage: a
  combination it does not support is `RefusedImageUnsupported`, and a width,
  height or mip count beyond what it allows `RefusedOutOfBounds`. That query
  is the only native call before the creation's reservation;
- once the attempt is reserved, the image's memory requirements are asked of
  the device, still creating nothing, and requirements beyond the device's
  largest resource for that use (`maxResourceSize`) are `RefusedOutOfBounds`,
  naming both sizes, with the reservation given back.

**The owned view.** Each image owns exactly one view of its whole resource —
two-dimensional, every mip level of its one layer, in its own format, over
the aspect its kind fixes — created right after the image under the same
`ResourceId`, named with it, and destroyed with it. Separate or partial views
and samplers are GRS-7's.

**Memory and accounting.** Each is placed through the allocator under its
kind's memory usage ([Device memory](#device-memory)): its bytes are charged
only as the blocks VMA holds, never as its own size. Its attempt reserves its
objects and no bytes: two for a buffer (the buffer and its allocation), three
for an image (the image, its allocation and its view), so the object budget
refuses one with `RefusedBackpressure` before anything native is done.
Allocation backpressure and `RefusedNoMemoryType` reach the caller as the
allocator answers them, having opened nothing.

**Failure.** A creation that raised before it was committed — at the
requirements, the creation, the bind, a buffer's map, or an image's view —
destroys what it made and frees its allocation, settling that, gives back its
reservation, and returns no handle; VK-14's recovery applies to an
out-of-memory failure as to any construction. If destroying the image whose
view could not be created raises too, its effect is uncertain: the image and
its allocation are retained — the allocator can then not be destroyed, so
neither can the device — the session fails with `CleanupFailed`, and the view's
failure is the one raised. A naming call that raised after the generation was
committed follows the [naming contract](#names-and-labels): the generation is
released, its handle never returned, and the owner's disposal destroys it and
gives its objects back.

**Release and disposal.** `releaseManaged` ends a buffer's or an image's
logical and CPU use together, like any managed resource's. `disposeResources`
destroys one only once the model reports every hold ended: an image's view,
then the image, then its allocation (`vmaDestroyImage`); a buffer, unmapped
first when mapped, then its allocation (`vmaDestroyBuffer`). The destruction
and the record of what it did are one masked step, and the model records the
disposal before `disposeResources` returns; a destruction that raised is
uncertain, never retried, retains what it was made from and fails the session,
as for every managed resource. `readManaged` reports each with its kind —
`vertex buffer`, `index buffer`, `instance buffer`, `lookup buffer`,
`staging buffer`, `texture`, `depth target`, `color target` — its standing,
and its native handles: a buffer's and its allocation's, or an image's, its
view's and its allocation's.

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| A buffer's or an image's managed record | The recording's managed records (`State`) | `Construction` inserts it, and releases it — on release or on a naming failure; `Disposal` advances it to destroyed or uncertain and removes it; `readManaged` reads it | The graphics owner | From its creation's commit until the model records its disposal | Destroyed once every hold has ended — view, image or buffer, then allocation — and removed when the model records that; kept, never retried, if its destruction was uncertain |
| Its native objects and allocation | The same record | Made by the allocation protocol and the native layer inside the creation's masked step; freed only by its disposal, or by a creation's own rollback | The graphics owner | The record's | Freed with the record's disposal; retained with an uncertain one |

### Ordering managed resources

GRS-3 (#335; resource services design D-18 and D-26) orders every access a
batch makes to a managed buffer or image. The rules are the GPU model's pure
ones ([the model contract](gpu_model.md#ordering-managed-resources)); the
recorder applies them, maps their answers onto Vulkan, and records what they
owe. Swapchain images keep their own path: `transitionImage` and
`supportedTransition` are [unchanged](#image-transitions).

**Resting states.** Every kind rests in one use between batches. Each use maps
onto the stages and accesses it covers and, for an image, a layout
(`useScope`, `useLayout`, over `bufferResourceKind` and `imageResourceKind`):

| Kind | Resting use | Resting layout | Resting stages | Resting accesses |
| --- | --- | --- | --- | --- |
| `TextureImage` | `ShaderSampled` | shader-read-only | fragment shader | shader sampled read |
| `DepthTarget` | `DepthAttachment` | depth attachment | early and late fragment tests | depth-stencil attachment read and write |
| `ColorTarget` | `ColorAttachment` | color attachment | color-attachment output | color-attachment read and write |
| `VertexBuffer` | `GeometryRead` | — | vertex input | vertex attribute read |
| `IndexBuffer` | `GeometryRead` | — | vertex input | index read |
| `InstanceBuffer` | `InstanceRead` | — | vertex input, vertex and fragment shaders | vertex attribute, index and shader read |
| `LookupBuffer` | `StorageRead` | — | vertex and fragment shaders | shader storage read |
| `StagingBuffer` | `TransferRead` | — | transfer | transfer read |

The other legal uses are `TransferWrite` for a texture and for vertex and index
buffers — the transfer stage's transfer write, in the transfer-destination
layout for a texture — and `TransferRead` for a color target, in the
transfer-source layout. Instance, lookup and staging buffers are host-written:
the submission that follows a host write makes it visible to the device, so no
scope names the host. That waives none of the boundary barriers below, none of
a non-coherent allocation's flushing, and none of the protection a buffer
retained by a batch or a submission has against being written in place; the
mapped-memory safeguards of [readback memory](#readback-memory) stay as they
are, and nothing writes a managed buffer from the host yet.

**Transitions.** `transitionResource` moves a `Buffer` or an `Image` (the
`Ordered` handles) within a batch, from the use the batch left it in
(`FromUse`) or from undefined contents (`FromUndefined`, an image only), into
another legal use of its kind, or into the same use, which orders the batch's
earlier accesses in it before its later ones. Like every command it checks
the owner's thread, the handle — this session's, still managed, live, a buffer
or an image — the recorder, that rendering is not open, and the rules; it
retains the exact generation in the model before its barrier; and only then
records it. An illegal use is `RefusedUnsupported`; a move that does not start
from the use the batch left the resource in, or one inside rendering, is
`RefusedIllegal`; and each is refused with no native call and no retention.

**Boundary barriers.** A batch's first touch of a resource finds it at rest,
so its first transition must start from the resting use, or from undefined; it
is recorded as the **entry barrier**, one barrier from the resting scope
straight into its destination. When the consumer returns, with rendering
ended and every touched resource back at rest, the recorder records an **exit
barrier** for each — from the resting use back to it, a same-use barrier
still owed — inside the batch's label, before its labels are balanced and its
command buffer ends. Consumers never record either. On the one graphics queue
a barrier's first scope covers every earlier submission, so each batch's entry
barriers chain to earlier batches' exit barriers, ordering write-after-write,
read-after-write and write-after-read between batches even when no layout
changes. A barrier that discards leaves the undefined layout, and its first
scope is still the resting one.

**Sealing.** A batch whose consumer leaves a resource away from rest is
refused, `RefusedIllegal` naming the resource, its kind and its use, and left
partial, as one that leaves rendering open is: its exit barriers are never
recorded, so they never stand in for the transition the consumer omitted, and
only a discard or a reset ends it. A barrier that raised — an entry, a
transition or an exit — leaves the batch partial like any command that raised,
with every reference it took retained until a valid invalidation; an exit
barrier's failure is raised once the batch's labels are balanced.

**Initialization.** A new image awaits initialization: `createImage` marks it
in the model as it commits. The first batch that touches it must initialize it,
by a transition from undefined; any other first touch, and any touch by another
batch before the initializing batch has been submitted, is
`RefusedUninitialized`, with no native call. A color or depth target cleared
every pass may transition from undefined every time, and still takes the entry
barrier. Only a submission the queue accepted publishes the initialization —
`submitFrames` records it with the submission, before anything has completed.
Recording, sealing, a fence reset, a no-effect failure and an unknown effect
never publish it, and a discarded batch, a reset recorder, a skipped frame and
an uncertain submission leave what their batch was initializing uninitialized
again. Nothing changes a resting state, which is the kind's.

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| The batch's accesses, and each touched resource's native handle | The recorder (`Recorder`) | `transitionResource` advances them; `recordFrame`'s seal reads them for the exit barriers | The graphics owner | One consumer action | Dropped with the recorder |
| An image's initialization | The model (`Internal.Initialization`) | `createImage` marks it; a first touch claims it; an accepted submission publishes it; a dropped batch or an unknown effect withdraws it | The graphics owner, through the roots' model | The generation's record | Leaves with the record |

### Offscreen color targets

GRS-5 (#338) renders into a managed `ColorTarget` image
([Buffers and images](#buffers-and-images)) and reads it back, in a frame batch
and a [frame-less batch](#frame-less-batches) alike. It obeys GRS-3's contract
above: the target's uses are `ColorAttachment` at rest and `TransferRead` to
copy it, every entry and exit barrier is the recorder's, and the consumer's own
transitions are explicit.

**The pass.** `beginRenderingInto recorder image start clear` begins dynamic
rendering with the target's owned view as the one color attachment, cleared to
the color across the target's whole extent, which is the render area. It needs
no swapchain image, so a frame-less batch records it. How the pass begins is
the consumer's `PassStart`:

- `ClearTarget` is a use of the target in its color-attachment use, keeping its
  contents: the batch's first touch records the entry barrier, and a target
  another touch in this batch moved elsewhere is `RefusedIllegal`. Its
  contents must be initialized.
- `ClearFromUndefined` is a transition from undefined into that use: its
  barrier discards whatever the target held, and is the initialization a new
  target awaits ([Initialization](#ordering-managed-resources)).

Before any native call the handle must be this session's (otherwise
`RefusedMisuse ForeignIdentity`), live (a released or stale one is
`RefusedMisuse WrongPhase`), a `ColorTarget` (otherwise
`RefusedWrongKind`), and of one mip level: a dynamic-rendering attachment's
view must cover exactly one, and the target's owned view covers every level,
so a target of more than one is `RefusedUnsupported`. Its extent, the
render area, must lie within the device's `maxFramebufferWidth` and
`maxFramebufferHeight`, which the recording reads once from the physical
device: an image's own limits, which its creation checks, do not bound them,
so a wider or taller target is `RefusedOutOfBounds`, naming its size and the
limit. No pass may be open; and a `ClearTarget` pass into a
target that awaits initialization, or into one another batch is still
initializing, is `RefusedUninitialized`. The batch retains the target before
its barrier and the pass are recorded. `endRendering` ends either kind of pass,
and `beginRendering` keeps rendering into the frame's image exactly as before.

**The attachment governs.** The open pass's attachment — the target's extent
and format, or the frame image's — is what a pipeline, a viewport and a
scissor are checked against; outside rendering a frame batch checks them
against its frame's image, and a frame-less batch, which has no image to
check them against, refuses them, `RefusedIllegal`. A draw checks the bound
pipeline's format, the viewport and the scissor again against the pass it is
drawn in, so state bound for one attachment never reaches another's draw: a
pipeline built for another format is `RefusedIncompatible`, naming both
formats, and a viewport or scissor beyond the target is `RefusedIllegal`.
Either way nothing native happens.

**Formats.** A color target is RGBA8 or BGRA8, each sRGB or linear
(`R8G8B8A8_SRGB`, `R8G8B8A8_UNORM`, `B8G8R8A8_SRGB`, `B8G8R8A8_UNORM`); a
pipeline renders into it only when built for that same format
(`createPipeline … (formatCode format)`). An sRGB target encodes what the
fragment shader writes on store, as Vulkan specifies, and a linear one stores
it as it is.

**The copy.** `copyTargetToReadback recorder image readback` copies the whole
target, mip level 0 of its color aspect, into a readback buffer, then records
the same buffer barrier from the copy's transfer write to host reads that
`copyToReadback` does ([Readback memory](#readback-memory)). The target must be
in its `TransferRead` use within the batch — the consumer's explicit
`transitionResource image (FromUse ColorAttachment) TransferRead` — and the
consumer returns it to rest after the copy, or the seal refuses the batch and
leaves it partial. Before any native call the target is checked as for a pass
and so is the buffer: this session's and live; recorded outside rendering
(inside it is `RefusedIllegal`); large enough for four bytes a pixel of the whole target
(`readbackBytesFor`, otherwise `RefusedOutOfBounds`); and written by no other
copy any batch or submission still holds (`RefusedInUse`). A copy before the
transition is `RefusedIllegal`, naming the use the target is in. The batch
retains both before the copy is recorded.

**The bytes.** A readback's bytes are the target's rows, top row first, each
pixel four bytes in the target's own format's component order — R, G, B, A for
RGBA8 and B, G, R, A for BGRA8 — tightly packed, with no padding between rows
and no conversion: an sRGB target's bytes are its encoded values. They are
exposed exactly as a frame image's are: only once the batch that recorded the
copy was recorded as submitted and its submission has completed, and a copy
discarded with its batch, or the completion of any other batch, exposes
nothing. The window integration lends a readback buffer to an owner-thread
action or a renderer with `constructReadback`, reads it with
`readConstructedReadback`, and releases it with `releaseConstructed`.

**Release.** A target or buffer released after its copy was recorded is held
by its batch, and destroyed only once that batch's holds have ended.

**Proof.** The stand-in suite (`Test.GPU.Vulkan.Native.Offscreen`) renders into
a target and copies it in both batch kinds, checks pipeline, viewport and
scissor state left from the frame's pass against a target of another format
and extent, and covers every refusal above, a target of two mip levels and one its image
limits allow beyond a lowered framebuffer limit included, the seal's refusal of a target left
in its transfer-source use, a discarded copy and an unrelated completion
exposing nothing, and initialization published only by submission. The
surface-free native case `grs5-offscreen` clears an `R8G8B8A8_SRGB` target and
an `R8G8B8A8_UNORM` one to blue from undefined in frame-less batches, draws a
pipeline-only yellow triangle (`endpointShaders`, every channel 0 or 1, so
exact in either encoding), copies each into a readback buffer, waits on its
ticket, and reads exact bytes at probe points well inside and outside the
triangle, with validation, synchronization validation included, reporting
nothing. It writes each readback as a PNG to a temporary path its record
prints; no reference image is committed.

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| The open pass's attachment, and the bound pipeline's format, viewport and scissor | The recorder (`Recorder`) | `beginRendering` and `beginRenderingInto` set the attachment and `endRendering` clears it; `bindPipeline`, `setViewport` and `setScissor` set the rest; `draw` reads all of it | The graphics owner | One consumer action | Dropped with the recorder |

### Drawing from buffers

GRS-4 (#340) draws from vertex, index and instance data with push constants,
and gives each session one shared ring of host-visible memory that batches
claim regions of (D-33). It obeys GRS-3's contract: a bind is a use of a
buffer, its entry and exit barriers are the recorder's, and the consumer's own
transitions are explicit. That a shader declares what its pipeline does is
checked when it is compiled ([Checked shader interfaces](#checked-shader-interfaces),
GRS-16).

**Push constants.** `createPipelineLayoutWith recording ranges` makes a layout
with no descriptor sets and these `PushConstantRange`s, each naming the stages
it is visible to — `PushVertex`, `PushFragment`, the two every pipeline has —
and an offset and size in bytes; `createPipelineLayout` is the same with none.
Before any native call each range must name at least one stage and none twice,
have a size, have an offset and size that are multiples of four, and end within
the device's `maxPushConstantsSize`; and no stage may be named by two ranges.
A range past the limit is `RefusedOutOfBounds`, naming how far it reaches and
the limit; anything else invalid is `RefusedIllegal`. `pushConstants recorder
stages offset bytes` pushes into the bound pipeline's layout, inside a pass or
outside one: a pipeline must be bound, the push must name a stage and have
bytes, its offset and size must be multiples of four, every stage it names must
have a range holding every byte pushed, and every range those bytes overlap
must be pushed for all its stages, as Vulkan requires. A push beyond a named
stage's range is `RefusedOutOfBounds`; anything else is `RefusedIllegal`. The
batch retains the layout, which it already holds through the pipeline.

**Vertex input.** `createPipelineWith recording layout shaders format input`
makes a pipeline that reads a `VertexInput`: `VertexBinding`s, each a number, a
stride and an `InputRate` (`PerVertex` or `PerInstance`), and
`VertexAttribute`s, each a location, the binding it reads, a `VertexFormat`
and an offset, for triangle lists. `createPipeline` is the same with no vertex
input, and such a pipeline works exactly as before. Before any native call the
input is checked against the device's `maxVertexInputBindings`,
`maxVertexInputAttributes`, `maxVertexInputBindingStride` and
`maxVertexInputAttributeOffset` — a value past one is `RefusedOutOfBounds` —
and against Vulkan's rules: binding numbers and locations each unique, every
attribute reading a declared binding and fitting within its stride, strides
positive and, like offsets, multiples of four, which every device's vertex
fetch admits; any other violation is `RefusedIllegal`. The formats offered —
one to four 32-bit floats, a 32-bit unsigned integer, and four normalized
bytes — are ones Vulkan requires every device to support for vertex input, so
none is asked of the device. The device's limits are read once, with the
non-coherent atom, as `RecordingLimits`. A pipeline keeps what its layout and
input declare with its generation, and a batch checks every push, bind and
draw against the pipeline it has bound now: binding another pipeline changes
what is checked, and leaves bound data bound, as Vulkan does.

**The ring.** `validateRingSize` validates the application's configured ring
size once: zero, negative and sizes no `VkDeviceSize` can hold are refused,
never clamped. `createRing recording size` makes the session's one ring — a
second is `RefusedMisuse DuplicateSubject` — as a buffer placed through the
device's allocator under the instance buffer's usage, vertex and index reads in
the frame ring's host-visible memory, mapped for its lifetime and charged as
the allocator holds it (D-40). A size beyond the device's `maxBufferSize` is
`RefusedOutOfBounds` before anything is made, and a block the byte budget cannot
hold is `RefusedBackpressure`. The ring is a managed generation the recording
owns: no handle to it is returned, and it is released with every other live
generation when the recording retires. The window integration makes it with
`constructRing` in an owner-thread action.

**Claims.** While a batch records, frame or frame-less alike,
`claimRegion recorder size alignment` claims a region of the ring for it, and
`writeClaim recorder claim offset bytes` writes into it — the backend's first
CPU write path for drawing data:

- A claim's alignment must be a power of two. On coherent memory the region
  starts where asked; on non-coherent memory it also starts on the device's
  `nonCoherentAtomSize` and is padded to a multiple of it, so no two claims
  share an atom.
- A claim that does not fit now is `RefusedBackpressure RingBudget`, once the
  regions of batches whose submission has completed have been reclaimed to make
  room. One larger than the whole ring, padded, can never fit and is
  `RefusedOutOfBounds`, a distinct, permanent refusal. A claim of no bytes, an
  alignment that is not a power of two and a session with no ring are
  `RefusedIllegal`. The next region is tried where the last claim ended, then
  from the ring's start, so claims wrap round.
- A region is the batch's from its claim, bound or not, until the batch's
  submission completes — observed through the model's completion fact — or the
  batch is discarded or reset, its storage's invalidation having returned.
  Nothing else reclaims it: an invalidation that raised, an unknown submission
  effect and a device loss reclaim nothing, and a device loss reports no
  completion.
- A claim's number is never reissued: a claim whose region was reclaimed, and
  perhaps handed to another, is `RefusedMisuse StaleIdentity`; another batch's
  is `RefusedMisuse WrongParent`; another session's is
  `RefusedMisuse ForeignIdentity`.
- Writes are admitted only while the batch records: once its consumer returns
  — sealed, partial or raised — its recorder is closed and a write is
  `RefusedRecorderClosed`. A write past the bytes claimed is
  `RefusedOutOfBounds`. The batch's submission makes its writes visible to the
  device, as #335's resting use for host-written buffers records, so no barrier
  is recorded; on non-coherent memory each write is flushed at once, over a
  range aligned to the atom that never leaves its claim's padded region. A write
  or flush that raised leaves the batch partial.
- The batch's first claim is its first touch of the ring: it records the ring's
  entry barrier, and the batch retains the ring's generation, which the barrier
  names. A barrier cannot be recorded inside rendering, so a batch's first claim
  inside a pass is `RefusedIllegal`; later claims may be made there.

**Binding and drawing.** `bindVertexBuffer recorder binding source` binds vertex
or instance data to a binding the bound pipeline declares, and
`bindIndexBuffer recorder source indexType` binds 16-bit or 32-bit index data,
each from a `BufferSource`: `FromBuffer` a managed buffer, or `FromClaim` a
region the batch claimed, at an offset into it. Vertex input reads a
`VertexBuffer` or an `IndexBuffer` in its `GeometryRead` use and an
`InstanceBuffer` — the ring included — in its `InstanceRead` use; a vertex bind
takes a vertex or instance buffer, an index bind an index or instance buffer,
and any other kind is `RefusedWrongKind`. The bind touches the buffer in that
use: the batch's first touch records its entry barrier, so a first touch
inside a pass is `RefusedIllegal` — a consumer binds before the pass, or moves
the buffer to its use before it — and a buffer this batch moved to another use
is `RefusedIllegal`. `draw recorder vertices instances` draws instanced and
`drawIndexed recorder indices instances` indexed and instanced, from the first
vertex, index and instance, with `draw`'s existing checks; every binding the
bound pipeline declares must be bound, a per-vertex one with data for every
vertex `draw` reads and a per-instance one for every instance either reads, and
an indexed draw needs index data holding every index it reads. A binding's
offset must let every attribute reading it be read, each attribute's address a
multiple of its format's component size, as Vulkan requires: a bind checks it
against the pipeline bound then, and every draw again against the pipeline
bound now, since a binding outlives a pipeline switch. Every draw also checks
each buffer it reads again — the data bound to the bindings the pipeline bound
now declares, and for an indexed draw the index data, nothing else bound: a managed buffer still recordable — not released,
replaced or stale since its bind — and every buffer still in the use it was
bound in, so a transition between passes that moved it elsewhere refuses the
draw.

**Indexed reads.** The vertices an index names are the index data's to say.
For index data in a ring region the batch wrote, the recording reads the
indices from the ring's mapping when the draw is recorded, bounds every
per-vertex binding's reads by the largest index, and from then on refuses any
write of the batch into the bytes it read (`RefusedIllegal`), so the indices
the device reads are the ones checked. The indices are read only after the
draw's thread is found to be the owner's and its recorder open, so no read
reaches a region that may have been reclaimed or a mapping that may be
gone. A managed index buffer an upload filled ([Uploads](#uploads)) bounds
those reads the same way, by the indices its completed upload wrote, which the
recording keeps until the buffer is forgotten. Index data the recording cannot
read — a managed index buffer no upload has completed into — cannot bound
them, so an indexed draw through it that reads per-vertex data is
`RefusedUnsupported`; one whose bindings are all per-instance is not.

Before any native call a bind, push or draw is refused, recording nothing, when
it has no bound pipeline (`bindPipeline` itself needs none); when its buffer's
kind does not fit the use; when a managed buffer is released or not this
session's, or a claim was reclaimed or is another batch's — a managed buffer
is the session's, and several batches may bind it; when its offset falls
outside the buffer or the bytes claimed (`RefusedOutOfBounds`), or an index
offset is not a multiple of the index's size; when a vertex source's offset is
one its attributes cannot be read from; or when a draw needs a binding or index
data that is not bound, more of either than is bound (`RefusedOutOfBounds`), a
vertex an index names beyond what is bound (`RefusedOutOfBounds`), or a buffer
released or moved out of its use since its bind. Every bind retains exactly what it references through
the transitive retention above: the managed buffer's generation, or the ring's.
Binding a binding again releases nothing an earlier command captured, and a
resource or claim no command references gains no binding retention.

**The commands.** The native layer records `CommandPushConstants`,
`CommandBindVertexBuffer`, `CommandBindIndexBuffer` and `CommandDrawIndexed`
through the audited unsafe subset ([The FFI audit](#the-ffi-audit)), and
creates layouts with their ranges and pipelines with their vertex input. The
window integration lends the layout and pipeline constructions as
`constructPipelineLayoutWith` and `constructPipelineWith`.

**Proof.** The stand-in suite (`Test.GPU.Vulkan.Native.Drawing`) covers range
and vertex-input validation, each refused with no native call; pushes inside
and outside the ranges and their stage coverage; a pipeline switch changing
what is checked while bindings stay bound; the ring's size validation, its one
per session and a claim with none; claims reclaimed only on completion or
discard, wrapping round, backpressure, and an oversized claim refused; regions
kept through an invalidation that raised, a partial and a cancelled recording
until their discard, and a submission whose effect is unknown, and released for
batches a no-effect submission failure discarded; atom padding and flushes on
non-coherent memory; claims distinct across reuse, another batch's refused, a
write past a claim and one after recording refused; the first claim refused
inside rendering; indexed and instanced draws from ring regions with 16-bit
indices and from a managed vertex buffer with 32-bit indices, with how far each
read reaches; 16-bit and 32-bit indices naming a vertex beyond the region
bound, managed index data refused for per-vertex reads, and a write into
indices a draw read refused; a vertex source its attributes cannot be read
from, at its bind and after a pipeline switch; a draw through a buffer
released or moved out of its use since its bind; a draw that is not indexed
reading no index data, and a pipeline with no vertex input reading no binding;
indices read only on the owner's thread and by an open recorder; binds
retaining exactly their references; and every refusal above with no native call, no draw recorded. The surface-free native case `grs4-drawing` makes
the ring, writes a quad's four vertices, its six 16-bit indices and two
instance offsets into ring regions of a frame-less batch, pushes magenta as a
fragment push constant, draws indexed and instanced into an `R8G8B8A8_SRGB`
target cleared blue, copies it into a readback, waits on its ticket and reads
exact bytes at probe points inside each instance's quad and outside both, with
validation, synchronization validation included, reporting nothing. It writes
the readback as a PNG to a temporary path its record prints.

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| The shared ring: its generation, mapping, size, atom, next claim number and head | The recording (`Internal.Recording.State`) | `createRing` makes it; every claim reads it and advances the number and head | The graphics owner | From `createRing` until its buffer's disposal | Its generation released by `retireRecording` with every other live one; forgotten once the model records that disposal |
| The ring's regions | The recording | `claimRegion` adds one for its batch and reclaims completed batches' to make room; a discard, reset or completed slot's invalidation, and a storage's disposal, release a dropped batch's | The graphics owner | From the claim until its batch's submission completes or its invalidation returns | Kept through an invalidation that raised, an unknown effect and a device loss; never reissued |
| The bound pipeline's interface, and the vertex and index data bound | The recorder (`Recorder`) | `bindPipeline` sets the pipeline; `bindVertexBuffer` and `bindIndexBuffer` set the bindings; `pushConstants`, `draw` and `drawIndexed` read them | The graphics owner | One consumer action | Dropped with the recorder |

### Checked shader interfaces

GRS-16 (#341) checks every shader that reads anything from the host against a
Haskell description of that interface while the package builds, with no native
tool (D-19, D-34), and builds pipelines from the descriptions.

**Descriptions.** A `ShaderInterface`
(`Hetoimasia.GPU.Vulkan.Native.Shader.Interface`) names its stage
(`VertexInterface` or `FragmentInterface`) and what the host supplies:

- its push-constant block, as each member's offset and size in bytes
  (`PushMember`), in declaration order — empty for a shader with none;
- for a vertex shader, its vertex input as the pipeline binds it — the
  `VertexInput` of [Drawing from buffers](#drawing-from-buffers). SPIR-V cannot
  say whether a binding advances per vertex or per instance, its stride, or an
  attribute's binding, byte offset or storage format, so those are the
  description's, and only each attribute's location and the shader type its
  format is read as are compared: one to four 32-bit floats for the float
  formats and for four normalized bytes, a 32-bit unsigned integer for the
  unsigned one;
- its descriptor bindings (`DescriptorDeclaration`): set, binding, kind
  (`CombinedImageSampler`, `SampledImage`, `StorageImage`, `Sampler`,
  `UniformBuffer`, `StorageBuffer`) and count — `DescriptorCount n`, compared
  exactly, or `RuntimeSized`, a runtime-sized array whose capacity is the
  layout's and whose filled count the allocation's, neither of which a shader
  states.

A description is a value a splice runs, so it is defined in another module, or
written whole in the splice's argument.

**The reader.** `Hetoimasia.GPU.Vulkan.Native.Shader.Reflect`, in the private
`shader-toolchain` library, reads a module's interface from its words: its one
entry point and the global variables its interface lists — every global the
shader uses, from SPIR-V 1.4 — through their storage classes, types and
decorations. It reports the push-constant block's members, their sizes computed
from scalars, vectors, matrices under their stride and majority, and arrays
under their stride; a vertex shader's inputs that are not built-ins, by
location and scalar or vector type; and each descriptor's set, binding, kind and
count. A fragment shader's inputs and outputs and a vertex shader's outputs are
varyings, which the validation layer checks at pipeline creation, and built-ins
are the device's: it reports neither.

**What the reader guarantees (owner amendment, 2026-10-03).** The reader's
input is SPIR-V from the pinned compiler, which is what every splice hands it.
Over that input it retains every structural check below, every regression that
proves one, and the compile-time match of a shader's interface against its
description. Exhaustive semantic validation of arbitrary SPIR-V — everything a
validator such as spirv-val checks — is explicitly out of scope: that is a
disclosed narrowing of the earlier guarantee that any malformed interface is
refused. What the reader does check, it checks completely, and a module it
does not support is refused with a diagnostic, never read as empty or matching.

Before it reads anything, the reader checks every instruction it consumes
against one explicit whitelist, the subset it supports:

- the module's header bounds every id it declares, and its one entry point has
  a model, a function, a name terminated and zero-padded within the
  instruction, and no interface id listed twice;
- every decoration of a kind it reads — Block, BufferBlock, RowMajor,
  ColMajor, ArrayStride, MatrixStride, BuiltIn, Location, Component, Binding,
  DescriptorSet, Offset — decorates a declared type, constant or variable, or a
  member a declared struct has; carries exactly the literals its kind takes;
  is not given twice to one target or member; has a positive stride where it is
  one; is never RowMajor and ColMajor on one member; and is never BuiltIn
  together with Location or Component, which is refused before any built-in is
  left out of what the host declares. No missing literal stands for a default;
- each interface variable's `OpVariable` has three operands, or four with an
  initializer, which only Output and Private variables take, and which must be
  a constant of the variable's own type, declared before it and naming a type
  declared before itself: a boolean, a
  scalar of as many words as its width, a null, or a composite of as many
  constituents as its type has, each a constant of its constituent's type;
- each variable's storage class is one it knows — UniformConstant, Input,
  Uniform, Output, Workgroup, Private, PushConstant or StorageBuffer — and its
  type is an `OpTypePointer` of that same storage class;
- every id an instruction names resolves to a type or constant declared before
  that instruction, so forward references, self-references and cycles are
  refused, and no id is declared twice;
- every id names the kind its position requires: a pointer's pointee is a type
  other than void or a pointer; an array's or runtime array's element is a
  sized or opaque type; a struct's members are sized types, with a runtime
  array only as the last; a vector's component is a scalar; a matrix's column
  is a float vector; an image's sampled type is a 32-bit float or a 32- or
  64-bit integer; a sampled image's image is an image; and an array's length is
  an `OpConstant` of a 32-bit integer type with a positive value;
- every instruction has exactly the operands its opcode takes, with literals in
  range: integer widths of 8, 16, 32 or 64 and signedness 0 or 1, float widths
  of 16, 32 or 64, vectors of 2–4 components, matrices of 2–4 columns, image
  operands within their enumerations, and a known pointer storage class;
- nothing an Input, Output, Uniform, PushConstant or StorageBuffer variable
  reaches is a boolean or an opaque type, unless the variable or the struct
  member reaching it is a built-in — gl_FrontFacing and gl_HelperInvocation
  are booleans the device supplies;
- every Uniform, StorageBuffer and PushConstant block has the explicit layout
  it requires, from its struct down through a descriptor array of blocks:
  every struct member an Offset, every array and runtime-sized array an
  ArrayStride, and every matrix member, or array of them, a MatrixStride and
  RowMajor or ColMajor;
- and those layout values obey the block layout matched to the device profile
  the roots create, which enables Vulkan 1.1's relaxed block layout (always
  on) and neither `scalarBlockLayout` nor `uniformBufferStandardLayout`: a
  Uniform block is std140, and a StorageBuffer block, a Uniform `BufferBlock`
  and a PushConstant block are std430. A vector member is aligned to its
  scalar; every other member to its base alignment, or under std140 its
  extended alignment (an array's, struct's or matrix's, rounded up to 16). A
  vector of at most 16 bytes does not straddle a 16-byte boundary and a larger
  one starts on one; an ArrayStride is a multiple of its array's alignment and
  holds its element; a MatrixStride is a multiple of its matrix's alignment;
  no member overlaps another; and none starts between the end of a struct,
  array or matrix and the next multiple of that one's alignment. Enabling
  either layout feature would be a new device requirement, and is not one.

The first instruction that fails is an error naming it, the rule it breaks and
the variable that reaches it. A module the reader cannot read, or a supported
shape it does not read — a nested push-constant struct, a matrix or array
vertex input, a texel buffer, an input attachment, a vertex input starting past
its location's first component — is likewise an error naming it, never an
empty or a matching interface. So are an interface naming an id the module
defines no variable for, a descriptor variable lacking its `DescriptorSet` or
`Binding`, a buffer whose struct is not decorated as its storage class
requires, and a combined image sampler over an image that is not sampled or
not of a supported dimension. Push-constant extents are computed without
bound, so a member reaching beyond what 32 bits can hold is refused rather than
wrapped, and `checkedRanges` refuses such members in a description the same way
(`RefusedOutOfBounds`).

**The checked splices.** `checkedVertexShader` and `checkedFragmentShader` take
a description and source text, and `checkedVertexShaderFile` and
`checkedFragmentShaderFile` a description and a file, compiling exactly as the
other splices do. They read the SPIR-V's interface and compare it with the
description in both directions: something declared but absent from the shader,
something present but undeclared, and a stage, push-constant member offset or
size, vertex input location or format, or descriptor set, binding, kind or
count that disagrees each fail the build, naming the module, the splice's
position, the stage and every mismatch. A shader that passes is a
`CheckedShader`: its SPIR-V beside its description.

**Unchecked splices.** `vertexShader`, `fragmentShader`, their file forms, and
`compileShaderQ` and `compileShaderFileQ` for those stages compile only
interface-free shaders: one declaring a push-constant block, a vertex input or a
descriptor binding fails the build, naming each and the checked splice to use.
Built-ins and varyings are no interface of the host's, so the triangle's
shaders and the verification shaders compile unchanged. Compute shaders are out
of scope and compile as before.

**Pipelines.** `CheckedShaders` pairs a checked vertex and fragment shader.
`checkedRanges` derives the push-constant ranges a pipeline over them needs:
one for each stage that declares a block, one for both stages when both declare
the same block, none for a stage that declares none; stages whose blocks
disagree on any member's offset or size are `RefusedIncompatible`, a stage given
the other stage's shader is too, and a shader declaring a descriptor binding is
`RefusedUnsupported`, since no layout declares descriptor sets yet (GRS-7).
`createPipelineLayoutFor` makes the layout with exactly those ranges.
`createCheckedPipeline` and `replaceCheckedPipeline` build a pipeline whose
vertex input is the vertex description's, and refuse a supplied layout that
declares any other ranges, `RefusedIncompatible`, so the descriptions stay
authoritative on creation and replacement alike; every refusal is made before
any native call. The window integration lends them as
`constructPipelineLayoutFor`, `constructCheckedPipeline` and
`replaceConstructedCheckedPipeline`. The `quadShaders` of
`Hetoimasia.GPU.Vulkan.Native.Recording.Shaders`, which `grs4-drawing` draws
with, are checked shaders over the descriptions in
`Hetoimasia.GPU.Vulkan.Native.Recording.ShaderInterfaces`.

**Proof.** `shader-tests` reads committed SPIR-V fixtures
(`test/fixtures/spirv/`, each beside its GLSL): a vertex shader's push-constant
matrix, vector and array and its inputs, but not its built-in or varying; every
descriptor kind with a fixed and a runtime-sized array; refusals of a nested
push-constant struct, a matrix input, an input attachment, a push-constant
member beyond 32 bits, an interface naming an undefined id, a component-offset
vertex input, descriptors stripped of their set and binding, buffers stripped of
their `Block`, and malformed modules; and, in `Test.Shader.Malformed`, one
rejecting mutation of a valid fixture for every whitelist rule — types,
constants, decorations, layout, variable declarations, the entry point and the
id bound — with a too-many and a too-few operand count for every fixed-count
opcode, and an Output variable with a null initializer of its own type read
exactly as without one; a fixture holding std430 push constants beside a
std140 uniform block and a std430 storage buffer, read as the compiler laid
them out, and refused at each layout rule its mutations break — including a
float array of stride 4 and an array at offset 132, which std430 takes and
std140 does not; a fragment shader reading gl_FrontFacing and
gl_HelperInvocation read as interface-free from its compiled fixture and
through an unchecked splice; and no interface in
the interface-free verification pair. Matching checked shaders in the source
and file forms, with vertex and instance host layouts and fixed and
runtime-sized arrays, compile with the suite. External clients, each compiled
against the built package, fail their build naming a push-constant member's
offset and size, a vertex input's location and format, a descriptor's set,
binding number, type and count, a block declared but absent and one present but
undeclared, and an unchecked splice over a shader with an interface. In
`native-tests`, `Test.GPU.Vulkan.Native.Checked` derives layouts from checked
shaders, takes the vertex input from the description, and refuses each
disagreement above with no native call, through a replacement too.

### Uploads

GRS-6 (#342) moves bytes into a fresh texture, vertex buffer or index buffer.
Its design is D-9, D-11, D-20, D-21 and D-30 of the
[resource services design](designs/gpu_resource_services_design.md). Bytes go
through one bounded, host-visible staging buffer that the graphics owner holds.
The owner records copies from it into frame-less batches
([Batches](#batches), GRS-12), in chunks under a per-turn byte budget. Each
upload has a ticket, which completes only when the batch carrying the upload's
final copies completes. The private `Internal.Uploads` module owns the uploads'
state; `Hetoimasia.GPU.Vulkan.Native.Uploads` is its public surface.

**Configuration.** `validateUploadConfig staging budget queue` validates three
values once, in that order, and never clamps them:

- the staging buffer's size in bytes;
- the bytes the owner records into upload copies in one turn;
- how many uploads may be unsettled at once.

Zero, negative, larger than a `VkDeviceSize` holds, or (for the capacity) more
than an `Int` counts is refused, naming the value. `newUploads` then checks the
configuration against the device, on the owner's thread:

- The turn budget must hold one block row of the widest level any image may
  have: four bytes for each texel of `maxImageDimension2D` (read as
  `limitImageDimension` in `RecordingLimits`, D-30). A smaller budget is
  `RefusedOutOfBounds`, naming that row and the budget, and nothing is made.
- The staging buffer is then made as a `StagingBuffer`-kind managed buffer of
  the configured size (`createStaging`). It is placed through the allocator
  like every other buffer, so its own refusals reach the caller as they are.
  Following D-40, its memory is mapped by a separate `vmaMapMemory` after the
  allocation, never inside the allocating call.

`uploadsSupportBC7` reports whether the device takes BC7, as its
`textureCompressionBC` feature says (D-21). Nothing assumes it: on a device
without BC7, a BC7 texture is already refused when it is created
([Buffers and images](#buffers-and-images)).

The window integration takes the configuration as `vulkanUploads` in
`VulkanHostConfig`. The default is `Nothing`, which takes no uploads. The
owner's step makes the uploads the first round in which the device exists,
before it runs any owner-thread action, so an action's uploads find them.

**Admission.** `submitUpload uploads request` runs on any thread (D-20).
`UploadImage image levels` carries every mip level of a texture, base level
first, each tightly packed in its format's blocks. `UploadBuffer buffer bytes`
carries the whole contents of a vertex or index buffer. One STM transaction
decides the request, in this order:

1. The session must be running (`UploadSessionFailed` with its primary
   otherwise), and admission open (`UploadClosed` otherwise).
2. The target must be this session's, still managed and not released
   (`UploadMisuse`).
3. No other unsettled upload may write into it (`UploadAlreadyTargeted`).
4. It must be a `TextureImage`, a `VertexBuffer` or an `IndexBuffer`
   (`UploadWrongKind`). A BC7 texture on a device without BC7 is
   `UploadUnsupportedFormat`.
5. It must be fresh (`UploadNotFresh`):
   - a texture the model still records as uninitialized, so neither one
     already initialized nor one another batch is initializing;
   - a buffer that no upload has been admitted into — through any uploads
     over the recording, which keeps that set (`recordingFilled`) — and that
     no recorded or submitted batch still holds.
6. The bytes must initialize the target exactly (`UploadMalformed`, saying
   what differs). A texture needs every level it declares, each the size its
   format's blocks and that level's extent need (`levelBytes`). A buffer needs
   its whole size.
7. The upload's size, padded to the staging granule, must fit in the whole
   staging buffer. Otherwise it is `UploadOversized`, naming the padded size
   and the buffer's. This refusal is permanent: no amount of waiting admits it.
8. The queue must have room, and the staging buffer a free region for the
   padded size. Either missing is `UploadBackpressure`, as `QueueFull` or
   `StagingFull`, distinct from the permanent refusal above, and answered at
   once.

The staging granule is the larger of 16 bytes and the device's non-coherent
atom. So every region starts where any format's block and any flush can begin,
and staging is charged for that alignment and padding. A region is the first
free gap that holds it, searched from where the last region ended and then
from the start, so regions wrap round the buffer.

The same transaction reserves the target in the recording's upload-held set
(`recordingUploading`), the queue place and the region, and makes the ticket.
The caller's thread then copies the bytes into the region through the mapping,
so the caller's bytes are free when admission returns. The copy runs
interruptibly; if it raises or is cancelled, every reservation is given back
and the exception is re-raised. If the owner's exit began during the copy, the
reservations are given back too and the answer is `UploadClosed`. Otherwise the
upload is queued. `submitUploadGated` reads a caller's gate in both
transactions, the one that reserves and the one that queues: a refusal in
either gives every reservation back. The window integration's
`submitVulkanUpload` gates on the owner's own admission, so it refuses as an
owner-thread action is refused — once the session has failed, with its
primary, or once the owner's admission has closed — and no upload is queued
after quiescence closes the owner. Its wake asks whether an upload is waiting
(`uploadsWaiting`), so admission makes an idle owner runnable.

**The exclusive target.** From admission until its upload settles, a target
belongs to the upload alone. Every other batch's ordered use of it is
`RefusedUninitialized` (`orderedSequence`). Disposal does not destroy it
(`destroyableNow`). Releasing it is deferred: `releaseManaged` marks it
released at once, so nothing more can use it, but the model's release and the
end of its CPU use wait until the upload settles (`recordingReleaseDeferred`).
A released target whose upload had not started is cancelled on the owner's
next turn. One already started completes first; only then is the target
released and later destroyed like any other.

**Progress and chunking.** `progressUploads` runs on the owner's thread. The
window integration calls it once per owner step, after the step's fence poll,
so an upload whose final batch that poll observed complete settles in the same
step. Each call:

1. After the device's loss, settles every unsettled upload as lost, except
   one whose caller is still copying its bytes into staging: its region stays
   that caller's until it finishes, and the upload is lost on a later turn.
2. Observes each batch in flight:
   - one complete moves its upload on, or completes the upload if it carried
     the final copies;
   - one discarded, and so never submitted, returns its upload to where those
     copies began, to be recorded again from the same staging bytes;
   - one lost loses its upload.
3. Cancels each upload not yet started whose target was released.
4. Records the next copies of every queued or uploading upload that has
   copies left and no batch in flight. It takes them in admission order, into
   one frame-less batch, up to the turn's budget, while admission is open and
   the session is running. The transaction that plans the turn also claims
   each planned upload, so no cancellation, close or release can settle it,
   freeing its staging, while its copies are recorded and submitted. One
   transaction after the submission publishes each carried upload's flight,
   cursor and ticket as it releases that upload's claim, so a submitted copy's
   staging is never left unheld in between; an upload whose copies no
   submitted batch carries — the batch refused, discarded, or its recording
   refused — releases its claim without a flight. A recording that raised
   leaves its uploads claimed, their staging held until retirement:
   - a texture's copies are whole block rows of one level at a time
     (`CommandCopyBufferToImage`), so a BC7 level's last, partial block row
     reaches the level's edge;
   - a buffer's copies are byte ranges (`CommandCopyBuffer`);
   - one upload may carry several levels in a turn while the budget lasts;
   - the first upload whose next row or byte does not fit ends the turn's
     plan.

An upload has at most one batch in flight: its next chunk waits for the last
one's completion. On non-coherent memory, the bytes a turn's copies read are
flushed before recording, aligned to the atom and never past the upload's own
region. Each upload's copies are bracketed by the recorder's barriers:

- the staging buffer is read under transfer read;
- on its first chunk, the target enters transfer write from its resting use,
  from the undefined layout, discarding what it held;
- between chunks it rests in transfer write, in the transfer-destination
  layout;
- after its final chunk it moves to its kind's resting use and layout.

If the batch cannot be opened now (no frame-less slot, or its budget refused),
nothing is recorded that turn. A stall flag then keeps `uploadsWaiting` from
waking the owner, so it does not spin; the next step it runs for another
reason, such as a fence poll that completes a batch, tries again. A batch the queue did not accept moves nothing on.

**Staging lifetime.** A region is freed only when its upload settles: complete,
cancelled or lost. It is never freed while the upload's copies are recorded or
in flight, and a discarded batch frees nothing for its copies.

**Tickets.** `UploadTicket` reads without a native call (`readUploadTicket`,
STM). Its state only advances:

- `UploadQueued`: admitted, with none of its copies recorded;
- `UploadUploading`: its first copies are recorded;
- `UploadComplete`: its final batch was observed complete, so its target is
  initialized and at rest, and other batches may use it;
- `UploadCancelled`;
- `UploadLost`.

The last three are terminal. `awaitUploadTicket ticket duration` waits at most
that long and answers the state then, which may still be queued or uploading.
The wait belongs to the caller alone: its expiry or cancellation cancels
nothing and completes nothing. It is `RefusedOwnerWait` on the owner's thread,
whose own progress the upload needs.

**Cancellation.** `cancelUpload` runs on any thread, in STM, and works only
before the owner claims an upload to record its first copies. It frees the
staging region, answers `UploadCancelled`, and leaves the target as it was:
uninitialized and free for another upload. Once the upload is claimed, it
completes; cancelling then is `CancelStarted`. A settled upload is `CancelSettled`, and
a ticket these uploads did not issue is `CancelUnknown`.

**Exit.** At the owner's exit, `closeUploads` closes admission before the
drain and cancels every upload not yet started. Uploads already started go on
with the other frame-less work the drain waits for. After the drain,
`retireUploads` first waits for every caller still copying its bytes into
staging, each of which then finds admission closed and gives its reservations
back, so the staging buffer is never unmapped under a writer; that wait is for
copies into mapped memory already under way. It then observes the batches in
flight once more, and settles each still
unsettled upload as lost after a device loss, and otherwise as cancelled (left
unfinished by the exit), its target released with the rest of the recording.
The staging buffer is a managed buffer like any other, destroyed by
`retireRecording` before the device.

**What an upload leaves behind.**

- **Index data.** A completed index-buffer upload stores the indices it wrote
  in the recording (`recordingIndexData`). An indexed draw through that buffer
  is then bounded by those indices, as it is for a ring region
  ([Drawing from buffers](#drawing-from-buffers)). The data is forgotten with
  the buffer.
- **Level readback.** `copyLevelToReadback recorder image level readback`
  copies one mip level of a texture into a readback buffer
  (`CommandCopyImageLevelToBuffer`), tightly packed in its blocks. The texture
  must be in its transfer-read use after a checked transition. To support this
  copy, the texture kind's usage gains transfer source, required of the
  format's features like the rest. Another kind is `RefusedWrongKind`; a level
  the texture lacks is `RefusedOutOfBounds`, naming the level count; and a
  readback too small for the level is `RefusedOutOfBounds`, naming the bytes
  needed and the readback's size.
  It lets a consumer compare what it uploaded.
- **Observation.** `readUploads` shows each unsettled upload's number,
  target, phase, staging region, and whether it has started, has a batch in
  flight, has every copy recorded, or is claimed by the owner's recording. It also shows whether admission is
  open, and the staging buffer's identity and size.

**Proof.** The stand-in suite (`Test.GPU.Vulkan.Native.Uploads`) covers:

- configuration refusals, never clamped;
- a budget below one widest block row, and staging the device cannot make;
- staging made as a staging-kind buffer, with BC7 support reported;
- admission copying the caller's bytes before it returns;
- every admission refusal, each reserving and copying nothing;
- oversized refused distinctly from full-queue and full-staging backpressure;
- targets not fresh or already targeted;
- reservations given back when the caller's copy raised;
- one winner of two uploads racing for one target;
- a gate closed before admission, or closing while the bytes are copied,
  refusing the upload with every reservation given back;
- a buffer an upload filled refused as not fresh through a second uploads
  over the same recording;
- BC7 reported unsupported on a device without it;
- copies at block-row boundaries under the budget, with the target resting
  in transfer write between batches, completing on the final batch's fence;
- a BC7 level's partial last row, and a buffer's byte ranges;
- the target refused to every other batch until its upload completes;
- staging freed only at settlement;
- a discarded batch re-recorded from the same bytes;
- non-coherent flushes aligned to the atom and kept within the region;
- cancellation before and after the first copies, and a cancellation and a
  rival admission inside the recording of an upload's first copies and inside
  its batch's submission, refused and backpressured while its staging stays
  held; the flight published as the claim is released; and a discarded
  batch's claim released without a flight, the upload then cancellable;
- tickets completing only on the final fence, a wait refused on the owner,
  and a deadline that cancels nothing;
- every unsettled upload lost after device loss, except one whose caller is
  still copying, which keeps its region until it finishes and is lost then;
- exit cancelling uploads not yet started and settling started ones;
- retirement returning only after a caller still copying has finished;
- a released target destroyed only after its upload settles;
- an indexed draw bounded by uploaded indices;
- level readback, with its refusals.

The integration suite admits uploads from another thread into an idle owner
with no target. It keeps them uploading past a wait's deadline while their
batches are pending, and completes them on fence evidence.

The surface-free native case `grs6-uploads` makes:

- an RGBA8 texture of two levels, 256 by 256, whose 320 KiB need three turns
  of a 128 KiB budget;
- a BC7 texture of two levels where the device takes BC7 (reported
  unsupported where it does not);
- the quad's vertex, instance-offset and index buffers.

It admits each upload from the main thread, not the owner's, and waits for
each ticket with a deadline. Then, in one frame-less batch, it copies every
level back with `copyLevelToReadback` and draws the quad from the uploaded
buffers into a color target. It compares every level byte for byte and probes
the drawing's pixels. Validation, synchronization validation included, reports
nothing.

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| The upload queue: each unsettled upload's entry, its phase, cursor, batch in flight and whether the owner has claimed it, the next upload number, the staging head, whether admission is open, and the stall flag | The uploads (`Internal.Uploads`) | `submitUpload` adds an entry; `progressUploads` claims, advances and settles them; `cancelUpload`, `closeUploads` and `retireUploads` settle them, never a claimed one or, but at retirement after its caller finishes, an admitting one | Admission and cancellation on any thread, in STM; everything else on the graphics owner's | From `newUploads` until `retireUploads` | Each entry removed when its upload settles; the numbers are never reissued |
| The staging buffer and its regions | The uploads, over a managed buffer of the recording's | Admission reserves a region and its caller writes it; the owner flushes and copies from it | Writes on the admitting thread, into its own region only; copies on the owner's | Each region from admission until its upload settles; the buffer from `newUploads` until `retireRecording` | Regions freed at settlement only; the buffer destroyed with every other managed resource |
| Each ticket's state | The uploads | The owner and cancellation advance it; any thread reads it | Any | From admission; kept by the caller after settlement | Never reset; terminal once settled |
| The upload-held targets and their deferred releases | The recording (`recordingUploading`, `recordingReleaseDeferred`) | Admission adds a target; settlement removes it and performs a deferred release; `orderedSequence` and `destroyableNow` read it | Any, in STM | From admission until its upload settles | Emptied as uploads settle |
| Uploaded index data | The recording (`recordingIndexData`) | A completed index-buffer upload stores it; indexed draws read it | The graphics owner | From completion until the buffer is forgotten | Deleted by `forget` |
| The buffers uploads have filled | The recording (`recordingFilled`) | Admission adds a buffer and reads the set for freshness; a cancellation before any copy, and an admission given back, remove it | Any, in STM | From admission until the buffer is forgotten | Deleted by `forget` |

### The texture table

GRS-7 (#343) is the bindless texture table. Its design is D-1, D-11, D-22,
D-23, D-27, D-31 and D-35 of the
[resource services design](designs/gpu_resource_services_design.md). A
texture registered with the table gets a stable handle. Shaders resolve the
handle through a lookup version that each batch freezes when it first binds
the table, then sample one update-after-bind array of images with one of four
shared samplers. The pure rules — handles, versions and slot reuse — live in
`Hetoimasia.GPU.Model.TextureTable` and run without a device. The native
table lives in the private `Internal.Recording.Table` and
`Internal.Recording.Lookup` modules, and `Hetoimasia.GPU.Vulkan.Native.TextureTable`
is its public surface.

**The profile.** The table needs six Vulkan 1.2 descriptor-indexing
features:

- `runtimeDescriptorArray`;
- `descriptorBindingPartiallyBound`;
- `descriptorBindingSampledImageUpdateAfterBind`;
- `shaderSampledImageArrayNonUniformIndexing`;
- `descriptorBindingVariableDescriptorCount`;
- `descriptorBindingUpdateUnusedWhilePending`.

The roots read them from `VkPhysicalDeviceVulkan12Features` (`BindlessFeatures`
in `DeviceOffer`) and enable all six when they create the device. Device
selection refuses a device missing any of them with `DeviceFeatureMissing`,
naming each missing feature, so `NoCompatibleDevice` lists everything each
candidate lacks. MoltenVK 1.4.2 on an Apple M3 Max offers all six, and an
update-after-bind sampled-image limit of 1,000,000 per stage and per set.

**Configuration.** `validateTableConfig capacity initial versions` validates
three values once and never clamps them:

- the cap: how many texture slots the layout declares;
- the initial size: how many slots the set allocates, slot 0 included, so at
  least two, and no more than the cap;
- the length of the version ring, `defaultVersionCount` (8) unless the
  application chooses otherwise.

Zero, negative and unrepresentable values are refused, naming the value
(`TableConfigRefused`). The table is fixed-size: it allocates its initial
size, and growth up to the declared cap is GRS-14's.

**Making it.** `createTextureTable recording uploads config` makes the
session's one table, on the owner's thread. A second is `RefusedMisuse`
`DuplicateSubject`. Before anything is made, the table is checked against
the device; each check that fails is `RefusedOutOfBounds`, naming what was
asked for and the limit, and nothing is made:

- the cap against `maxDescriptorSetUpdateAfterBindSampledImages`;
- the four samplers against `maxDescriptorSetUpdateAfterBindSamplers`;
- a stage's every table binding (the cap, four samplers and the lookup
  buffer) against `maxPerStageUpdateAfterBindResources`;
- set 0's pool, the four samplers and the initial images, against
  `maxUpdateAfterBindDescriptorsInAllPools`;
- the two sets against `maxBoundDescriptorSets`;
- one version's bytes against `maxStorageBufferRange`;
- the last version's dynamic offset against what 32 bits hold;
- the whole ring against the largest buffer the device makes.

Like all new work, making the table is refused once the session has failed.

Then, in order, it makes the following. Each sampler, set layout and pool
is a managed generation of its own, made by one creation that never rolls
anything else back:

1. **Four immutable samplers**, in index order: nearest/clamp-to-edge,
   nearest/repeat, linear/clamp-to-edge and linear/repeat (`TableSampler`).
   Linear samplers filter mips linearly; none is anisotropic.
2. **Set 0's layout.** Binding 0 is the four samplers. Binding 1 is the
   sampled-image array, declared at the cap and flagged update-after-bind,
   partially bound, update-unused-while-pending and variable-count. It is the
   highest binding, as Vulkan requires of a variable-count binding. The
   layout is created with the update-after-bind pool flag.
3. **Set 1's layout**: one dynamic storage buffer at binding 0. An
   update-after-bind set may not hold a dynamic buffer
   (`VUID-VkDescriptorSetLayoutCreateInfo-flags-03000`), which is D-35's
   reason for a second set.
4. **A pool for each set, then the set.** Set 0's pool is update-after-bind,
   and its set is allocated with the initial size as its variable count.
   Each set is allocated after its pool exists and is freed with it.
5. **The version ring**: one host-visible lookup buffer, made and mapped as
   the uploads' staging buffer is (`createMapped`). One version is the
   initial size's lookup entries of eight bytes each, a little-endian slot
   then generation. Versions sit at a stride rounded up to both the device's
   `minStorageBufferOffsetAlignment` and its non-coherent atom. Set 1's
   descriptor is written once, over one version's range.
6. **One managed version generation for each ring entry.** It owns no
   native object; a batch that binds the table at that entry retains it.
7. **Slot 0's placeholder**: a one-by-one transparent-black RGBA8 texture,
   whose upload is admitted through the session's uploads.

If any step is refused or raises, every generation made so far is
released, and the ordinary disposal destroys it. The construction runs
masked from the first creation to the table's publication, so a
cancellation lands only inside a step, after which the unwinding sees every
generation made before, or once the table holds them all. A destruction that raises
is retained, never retried, and fails the session with `CleanupFailed`, as
for any managed resource. The table can be bound once the placeholder's upload has completed and its
descriptor has been written; until then binding is `RefusedNotWritten`.

**Handles.** `registerTexture recording image` takes a live `TextureImage`
of this session and answers a `TextureHandle`: a lookup index and a
generation, which is never zero and never persisted. It reserves a free
index and a free slot. Slot 0 is never issued and counts against the
table's size.

- Until the image's upload has completed, the handle resolves to slot 0. A
  texture counts as complete once the model holds it initialized and no
  upload holds it any longer.
- Its descriptor is written into its slot when the owner next brings the
  table up to date. Versions published after that map the handle to its
  slot.
- From registration on, the table holds the image. `releaseManaged` on it is
  refused; the handle is released instead.

`releaseTexture recording handle` ends a handle. Its index may be issued
again at once under the next generation, and its slot retires. Its image
stays held until no live version maps the slot, and is then released as any
managed image is (deferred while an upload still holds it).

`registerTexture` refuses:

- an image that is not a live texture of this session;
- an image already registered (`DuplicateSubject`);
- a full table (`RefusedBackpressure` `TextureSlotBudget`), until a slot is
  reclaimed.

A handle released, of an older generation, or never issued is
`RefusedStaleHandle` wherever it is used.

**Versions.** A version is a whole-table copy: every lookup index's slot and
generation. An index no live handle holds reads as slot 0 with generation 0.

- A new version is published only when a mapping has changed since the
  current one: a texture completed, or a handle released. It is written into
  a ring entry that no batch holds and that is not the current version, then
  flushed when its memory is not coherent. The submission that follows makes
  the write visible to the device (D-26).
- When nothing changed, every batch binds the current version, however many
  entries are held.
- When a new version is owed and every other entry is held, binding is
  `RefusedBackpressure` `LookupVersionBudget`.
- An entry is held while its version generation has a recorded reference or
  a submitted use in the model. Those holds end when the batch completes, or
  when it is discarded, as every managed resource's do.

**Slot reuse.** A slot is reused, and its descriptor rewritten, only once no
live version maps it. A version is live while a batch holds it, and the
current version also while no mapping has changed since it was published,
the only time a batch can still bind it. Descriptor writes therefore target
only a slot that no recorded or pending batch can sample:

- a slot just reserved for a registration, which was free;
- slot 0 before the table is first bound.

So a batch recorded before a texture is released or replaced still samples
the original image when it is submitted later. The image, its view and its
allocation stay held until that batch completes: its version keeps the slot
retiring, and the batch itself retains every image its version maps
([Binding and drawing](#the-texture-table)), so not even retirement destroys
them while it is outstanding. A texture released before its
upload completes was never written into a version, so its slot is reclaimed
at once. Its image is released after that upload settles.

**Bringing it up to date.** `refreshTable` writes the placeholder once its
upload completes and writes each newly complete texture into its slot. It
then reclaims every retiring slot no live version maps, releasing its image.
Once the session has failed, or while a diagnostic failure is pending, it
writes nothing, since that is new work. Reclamation still runs, since that
is cleanup. `registerTexture` and `createTablePipelineLayout` are refused
then too, while `releaseTexture` is not.
It runs:

- before every binding;
- after every registration;
- once in every owner step of the window integration, after the step's
  uploads (`refreshRenderingTable`), so a released texture's image goes even
  when nothing binds the table again;
- whenever the owner calls `refreshTextureTable`.

**Pipelines.** `createTablePipelineLayout recording shaders samplerOffset`
makes a pipeline layout holding both of the table's set layouts, from set 0
on, and exactly the checked shaders' push-constant ranges. Its shaders may
declare the table's own bindings (`textureTableDescriptors`): set 0's four
samplers at binding 0 and runtime-sized image array at binding 1, and set
1's storage buffer at binding 0. They may declare no other binding. Set 0
is visible to the fragment stage alone, so a vertex shader declaring set 0's
samplers or images is refused; set 1 is visible to both stages. A layout
from `createPipelineLayoutFor` declares no set, so a shader declaring any
descriptor binding is refused there. The sampler offset must be a multiple
of four and lie whole within a fragment-stage range. Refused before any
native call:

- a session with no table;
- an offset that is unaligned or outside every fragment range;
- whatever the checked-range and push-range validation refuse.

**Binding and drawing.** `bindTable recorder` binds both sets under the bound
pipeline's layout, with the dynamic offset of the batch's version, through
`vkCmdBindDescriptorSets`. A batch takes its version at its first binding
and keeps it: a later binding in the same batch, after any change, binds the
same version. The batch retains the version generation, the table's
samplers, set layouts, pools and lookup buffer, the placeholder and every
image its version maps. `selectSampler recorder n`
pushes `n` at the layout's declared sampler offset. Binding a pipeline whose
layout does not hold the table disturbs the binding and the sampler, so the
table's pipeline needs both again. Refused with no native call:

- binding with no pipeline bound, under a pipeline whose layout does not
  hold the table, or in a session with no table;
- a sampler index above 3 (`RefusedOutOfBounds`), or a sampler selected
  under a pipeline without the table;
- a push over the sampler index's four bytes;
- a draw with a table pipeline before the table is bound under a compatible
  layout, or before a sampler is selected;
- a draw through the table while the batch holds an image its version maps
  in a use other than sampling, for example after moving a texture to a
  transfer use, until the batch moves it back;
- any binding once the session has failed.

**The shaders.** `tableShaders` (in `Recording.Shaders`) are the reference
pair the native case draws with. The vertex shader covers the render area
with one triangle. The fragment shader resolves the pushed handle: an index
past the version's `entries.length()`, or an entry whose generation differs
from the handle's, resolves to slot 0 before any descriptor is read. It then
samples that slot (`nonuniformEXT`) with the pushed sampler, clamped to 3.
Their interface descriptions are `tableVertexInterface` and
`tableFragmentInterface`: the handle at push offset 0 and the sampler index
at `tableSamplerOffset` (8).

**The window integration.** An owner-thread action has:

- `constructTextureTable`, over the session's uploads; the host must
  configure `vulkanUploads`, or it is refused;
- `constructTablePipelineLayout`;
- `registerConstructedTexture` and `releaseConstructedTexture`;
- `readConstructedTable`.

A renderer or a frame-less batch records `bindTable` and `selectSampler` as
it records any command.

**Observation.** `readTable` shows:

- the mapping a version published now would hold;
- the current version and the live ones;
- the slots live versions map, the free slots and the retiring slots;
- whether the placeholder is written;
- the stride and each ring entry's version generation.

**Proof.** The pure examples (`Test.GPU.Model.TextureTable`, in
`gpu-model-tests`) cover:

- configuration refusals;
- the placeholder before completion and stale handles after release;
- index reuse under a new generation;
- versions published only on change, and the current one bindable while
  every entry is held;
- backpressure with no partial registration or version;
- slots reused only once no live version maps them;
- a released, never-bound texture's slot freed at once;
- `resolveHandle`'s bounds and generation checks.

The stand-in examples (`Test.GPU.Vulkan.Native.Table`, in `native-tests`)
cover:

- the table's native objects, and the sizes it asks for;
- every device-limit refusal before anything is made;
- the table's pipeline layouts and their refusals;
- binding both sets with the version's offset, and the sampler push;
- every recorder refusal with exactly one native call between them;
- a batch's version kept through a later change and a rebind;
- binding refused before the placeholder is written;
- descriptor writes only into slots no live version maps;
- versions held to completion, with backpressure;
- each new version written whole into an entry no batch holds before the
  batch that binds it records, and flushed to the atom on non-coherent
  memory;
- the current version bound while every entry is held;
- stale handles;
- a release before the upload completes;
- a discarded batch's version freed;
- the record-then-release case;
- every image a batch's version maps kept through retirement, with the
  batch recorded and with it submitted;
- a draw refused while a mapped texture is in a transfer use;
- a vertex shader declaring set 0 refused, and one declaring set 1
  admitted;
- the largest dynamic offset checked before anything is made;
- new table work refused, and nothing written, after the session fails,
  while a release still completes;
- a construction failing part-way leaving only whole generations, whose
  failed destruction is retained and fails the session;
- a cancellation aimed at the owner during the first sampler's creation
  leaving every generation released or held by the published table;
- the total update-after-bind pool limit checked before anything is made.

A mutation check that ignored version holds failed the three hold-dependent
examples, and one that left the version's images out of the batch's
references failed the retirement example, and one that ran the
construction unmasked failed the cancellation example. The device-profile examples refuse a device missing any of the six
features, by name. The shader suite checks that `tableShaders`' SPIR-V
declares exactly the table's three bindings and matches its descriptions.

The surface-free native case `grs7-texture-table` makes a table of sixteen
slots, eight at first, over the session's uploads. It then draws four
frame-less batches, each into a 64-by-64 RGBA8 target that is copied back
and probed:

1. a texture registered before its upload reads as transparent black, the
   placeholder;
2. after red, green and blue two-by-two textures upload, red and green are
   drawn side by side with different samplers;
3. a batch is recorded with red's handle. Before it is submitted (when its
   action returns), the handle is released and blue is registered. The batch
   still draws red; blue took a different slot, and red's slot is the only
   one retiring;
4. blue is drawn beside red's released handle, which the shader resolves to
   the placeholder.

Once every batch has completed, the owner's step reclaims red's slot. A
second release of red's handle is `RefusedStaleHandle`. Validation, with
synchronization validation, reports nothing.

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| The table's book: handles, generations, the slot map, the current version, the free and retiring slots | The recording (`recordingTable`, `tableBook`) | Registration, release, completion, binding and reclamation, all through the pure rules | The graphics owner; observers read it in STM | From `createTextureTable` until the recording retires | Never reset; the recording's retirement releases what it holds |
| The samplers, set layouts, pools and sets | The recording, as managed generations the table names | Made once; bound by batches, which retain them | The graphics owner | Until `retireRecording` | Destroyed with every other managed resource, pools before set layouts before samplers |
| The version ring's buffer and mapping | The recording, as a managed lookup buffer | The owner writes a version into an entry no batch holds; the device reads the entry a batch bound | The graphics owner | Until `retireRecording` | Destroyed with every other managed resource |
| Each ring entry's version generation | The recording | Batches retain it through the model's holds; `versionHeld` reads them | The graphics owner | Until `retireRecording` | Destroyed with every other managed resource |
| The images the table holds | The recording (`tableTextures`) | Registration adds; reclamation removes and releases | The graphics owner | From registration until no live version maps the image's slot | Released then; destroyed once nothing holds it |

### Destruction

`disposeResources` destroys, on the owner, every released generation the model
reports every hold of ended, and records each disposal with progress turns
that answer for managed resources only. A turn does bounded work, so turns
continue until every destruction that returned is recorded, and passes continue
until one destroys nothing. A pipeline layout waits until every
pipeline built over it is destroyed; a pass destroys pipelines first. A
destruction that raised is uncertain, never retried, fails the session with
`CleanupFailed` and raises `ResourceDestructionFailed`, and retains everything
that depends on it. `retireRecording` releases every live handle, destroys what
it can and raises `ResourcesRetained`, naming the rest, without manufacturing
evidence; every managed resource must be gone before the device. A readback's
destruction unmaps its allocation, destroys its buffer and then frees the
allocation (VMA's `vmaDestroyBuffer`), and settles whatever device memory that
freed; a sibling allocation's mapping and memory are untouched. A managed
buffer's is the same; a managed image's destroys its owned view, then the
image, then frees its allocation (`vmaDestroyImage`), settling that too.

### The FFI audit

D-28's production split, as built. The binding is compiled with
`+safe-foreign-calls`, so every import of its own is `safe`; the package's only
genuine `unsafe` Vulkan imports are the nineteen `dynamic` imports in the private
`Hetoimasia.GPU.Vulkan.Native.Internal.Commands`, each calling the function
pointer the binding's own device dispatch table (`DeviceCmds`) resolved for the
command buffer's device, with structures marshalled by the binding's
`withCStruct`. A Haskell wrapper around a `safe` import would not have changed
its calling convention.

| Entry point | Why it may be `unsafe` |
| --- | --- |
| `vkBeginCommandBuffer` | Puts a command buffer the owner alone holds into the recording state. No wait, no other thread's lock; its result is checked and raised as the binding raises it. |
| `vkEndCommandBuffer` | Ends that recording state. The same. |
| `vkCmdPipelineBarrier2` | Records a barrier; it does not execute one. |
| `vkCmdBeginRendering` | Records the start of dynamic rendering. |
| `vkCmdEndRendering` | Records its end. |
| `vkCmdBindPipeline` | Records a binding of an already-created pipeline. |
| `vkCmdSetViewport` | Records dynamic state. |
| `vkCmdSetScissor` | Records dynamic state. |
| `vkCmdDraw` | Records a draw. |
| `vkCmdPushConstants` | Records push-constant bytes, which the recording has checked fit the bound layout's ranges; they are copied into the command buffer during the call and not kept (GRS-4). |
| `vkCmdBindVertexBuffers` | Records one buffer, already created, bound to one vertex input binding at an offset (GRS-4). |
| `vkCmdBindIndexBuffer` | Records an already-created buffer bound as index data at an offset (GRS-4). |
| `vkCmdDrawIndexed` | Records an indexed draw (GRS-4). |
| `vkCmdBindDescriptorSets` | Records a binding of the texture table's two already-written sets under an already-created layout, with one dynamic offset; the set and offset arrays are marshalled for the call and not kept (GRS-7). |
| `vkCmdCopyImageToBuffer` | Records a copy; it does not perform one. |
| `vkCmdCopyBuffer` | Records one region's copy from the staging buffer into a buffer; it does not perform one (GRS-6). |
| `vkCmdCopyBufferToImage` | Records one band of whole block rows' copy from the staging buffer into a mip level; it does not perform one (GRS-6). |
| `vkCmdBeginDebugUtilsLabelEXT` | Records the opening of a label region; the label's name is marshalled for the call and not kept. |
| `vkCmdEndDebugUtilsLabelEXT` | Records its closing. |

Each records into a command buffer the calling thread owns; none waits on the
device, blocks on another thread, or can run long enough to matter. None can
call back into Haskell: the package installs no Haskell callback, no allocation
callback and no trampoline, so the only code a validation layer can reach from
inside one is #217's C-only capture messenger
(`hetoimasia_vulkan_capture_messenger`), which copies capped data into bounded
storage and returns. Everything else stays `safe`, through the binding: waits,
queue submission and presentation (VK-12 and VK-13), pipeline creation, every
construction and destruction, the pool reset and mapped-memory maintenance.
Masking, native-effect accounting and retention hold across the mix, because
every unsafe call sits inside the same masked step as the retention before it
and the count after it, and an unsafe call cannot be interrupted.

GRS-11 adds the second set of `unsafe` imports: the allocator's VMA shim, in
the private `Hetoimasia.GPU.Vulkan.Native.Internal.Vma`. Each is one C entry
of the engine's own shim (`cbits/hetoimasia_vma.cpp`) taking scalars and one
result record the allocator reuses, the shape #361 qualified
([the VMA qualification record](gpu_vma_qualification_record.md)). VMA's
device-memory callbacks are C functions counting into the allocator's own
state, so none of these calls can enter Haskell, and VMA's own Vulkan calls
reach the capture's C messenger at most. They are made on the owner's thread
alone, under the same masked steps as the accounting around them.

`nativeFfiConfiguration` records the lists (`ffiUnsafeImports` and
`ffiAllocatorImports`), the binding's flags, the allocator, and the C-only
callback; the native case's record prints it, so it is part of the evidence
identity beside the build's source digest. The headless suite reads the
package's own import declarations and requires exactly those nineteen `dynamic`
imports and, besides them, only the capture callback's address import and the
allocator shim's entries.

## Frames: acquisition, submission and abandonment

`Hetoimasia.GPU.Vulkan.Native.Frames` is VK-12
([#225](https://github.com/coghex/hetoimasia/issues/225)): P-1's scheduling
vocabulary — try to acquire, submit, skip, advance — over P-2's frame ownership
table, with D-23's safe abandonment of unsubmitted frames and D-15–D-17's
composable, finite, terminal-on-unknown contract. It sits above the recording: a
`Frames` is made over a `Recording`, and so over its generations and roots, and
every native call goes through an open native layer, `FrameOps`, whose
production form is `Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan`; the headless
examples supply a stand-in. Every operation belongs to the graphics owner — the
thread that owns the recording — and any other is refused with
`RefusedNotOwner`. Refusals are the recording's `Refusal`.

The model decides what every frame owes; this module makes the native calls
and supplies the model the facts it observed, and nothing else. The GPU model's
public surface is unchanged: every transition used here — `reserveFrame`,
`acquireImage`, `resetSubmissionFence`, `submitFrames`, `skipUnsubmittedFrame`,
`closeSubmittedFrame` and `recordCompletion` — was already
[its contract](gpu_model.md#frame-ownership).

### The operations

| Operation | What it does | What it answers |
| --- | --- | --- |
| `tryAcquireFrame target` | Reserves the frame in the model — its slot, the presentation-pool record and the submission record it may need — makes the slot's synchronization if it has none, and acquires one image with a zero timeout, recording the result in the same masked step | `AcquisitionOwned` an `OwnedFrame`, carrying its `FrameSlotId` and the exact `ImageId` and whether it was suboptimal; `AcquisitionPending` a reason; `AcquisitionSuspended`; `AcquisitionClosing`; `AcquisitionUnavailable`; or a misuse refusal |
| `recordFrame` (the recording's) | Runs the consumer once and seals one batch for the frame | A `BatchId` |
| `submitFrames batches` | Validates the whole non-empty request, then resets one fence, submits every batch in the caller's order as one `vkQueueSubmit2` on the session's one graphics queue, and records the result in the same masked step | `SubmittedAs` the one `SubmissionId` every frame of the request shares; `SubmittedNothing` for the specified no-effect failure; or a refusal before any native call |
| `skipFrame frame` | Consumes an acquired, unsubmitted frame: invalidates its recording, skips it in the model, and makes a cleanup submission waiting on its acquisition semaphore | Acknowledgement of its admission to retirement, not its completion |
| `closeUnpresentedFrame frame` | Closes a submitted frame that will never be presented, in the model alone | Acknowledgement; its settlement follows its actual rendering completion |
| `presentFrame frame` | Validates a submitted frame, then resets its pool record's present fence and presents its image waiting on the record's render-finished semaphore, recording what the swapchain answered in the same masked step ([Presentation and retirement](#presentation-and-retirement)) | `PresentedAs` the `PresentationId` and what was enqueued; `PresentedNothing` for out of memory; or a refusal before any native call |
| `closeTargetFrames target` | Skips every acquired frame of a target and closes every submitted one | What each frame answered |
| `progressFrames now` | The owner's bounded step: observes pending fences — submission, present and cleanup — makes the cleanup submissions closed frames owe, and returns images | A `Progress`: completed submissions, retired presentations, settled frames, cleanups made, fences still pending |
| `awaitFrames now timeout` | A finite protected-drain wait — at most `drainWaitLimit`, 10 ms — on one pending fence, then `progressFrames` | The step's `Progress`; the wait itself is never evidence |
| `retireTargetFrames target` | Destroys a target's slot synchronization and presentation pool once nothing of it is live, presented and unretired, or pending — after the device's loss, once the loss has released them, whatever they were owed | Returns, or raises `FramesRetained` naming what remains |
| `releaseFramesToDeviceLoss` | After the device's loss: skips every acquired frame without a cleanup submission, and lets go of every submission, presentation and frame the lost device alone could have discharged ([Teardown after device loss](#teardown-after-device-loss)) | The model's `DeviceLossRelease`; `RefusedIllegal` before any loss |

Frame capacity is the model's: two slots per target by default, one supported
(D-16). An acquisition refused for want of a slot, a presentation-pool record
or accounting answers `AcquisitionPending (PendingBackpressure kind)` before any
native call.

### Slot synchronization

Each frame slot owns three synchronization objects: an **acquisition
semaphore**, the **submission fence** of a native submission it leads, and a
**cleanup fence**. They are made together, named from the target and slot when the device offers
naming (`slotObjectName`), the first time the slot is reserved and before its
first acquisition; a creation or naming that raised destroys what was made
before it and gives the reservation back. So an acquired frame always has the
synchronization its abandonment needs, whatever the budgets say by then: the
cleanup submission charges nothing, and the model reserved its bookkeeping with
the frame. A slot is reused only once the model has freed it, and the
acquisition checks its objects are idle — no semaphore owed a signal or waited
on, no fence pending — and refuses otherwise.

The **render-finished semaphore** a frame's rendering signals is not the
slot's: a presentation waits on it for longer than the slot is held, so it
belongs to the record of the target's presentation pool bound to the frame at
its reservation ([The presentation pool](#the-presentation-pool)). The frame's
submission signals it; its presentation, or the cleanup of a frame never
presented, waits on it.

### Acquisition

A failed session refuses the acquisition before anything else, naming its
primary failure (`RefusedSessionFailed`; [Checkpoints and
refusals](#checkpoints-and-refusals)). The target must be this session's
(`ForeignIdentity`, `StaleIdentity` or `UnknownIdentity` otherwise — misuse,
never pending), and admitted: a suspended target answers
`AcquisitionSuspended`, a retiring one `AcquisitionClosing`, and an unavailable
one `AcquisitionUnavailable`. It acquires from the
active generation while its generations are presenting, and also while a
replacement is settling or backpressured, so a live resize keeps rendering
(on MoltenVK the image is scaled to the layer until the replacement is built).
A target with no active generation — still constructing, or after a failed
construction — or waiting to recover answers
`AcquisitionPending PendingGeneration`; a spent recovery or an unsupported
surface answers `AcquisitionUnavailable`.

| The call answered | The model | The answer |
| --- | --- | --- |
| `VK_SUCCESS` | The frame owns the image | `AcquisitionOwned` |
| `VK_SUBOPTIMAL_KHR` | The frame owns the image, and the target counts a replacement request | `AcquisitionOwned`, suboptimal; the generations are told (`SwapchainSuboptimal`), so the owner's next step reconciles |
| `VK_NOT_READY`, `VK_TIMEOUT` | The reservation goes back whole, its pool record freed untouched, with no synchronization obligation | `AcquisitionPending PendingNoImage` |
| `VK_ERROR_OUT_OF_DATE_KHR` | The reservation goes back, its pool record freed untouched, and a replacement is requested | `AcquisitionPending PendingReplacement`; the generations are told (`SwapchainOutOfDate`) |
| `VK_ERROR_SURFACE_LOST_KHR` | The reservation goes back, its pool record freed untouched, and a replacement is requested | `AcquisitionPending PendingSurfaceLost`; the generations are told (`SwapchainSurfaceLost`), and the surface is [replaced](#replacing-a-lost-surface) |
| It raised | The reservation goes back: an error result has no effect | The failure is re-raised; device loss latches as always |

A successful acquisition whose result the model then refused to record — the
native image is owned and nothing can settle it — is an uncertain effect: the
slot is retained for ever, admission closes, the session fails with
`CleanupFailed`, and `FrameEffectUncertain` is raised.

The slot's synchronization and a presentation-pool record are each built
before they are published: a slot's acquisition semaphore, submission fence and
cleanup fence, and a record's render-finished semaphore and present fence, each
created and then named. A creation that ran out of memory created nothing and
is recovered as an allocation, once ([Allocation recovery](#allocation-recovery)).
Any other creation or naming that raises after something was made is rolled
back:

- every object made is destroyed exactly once, newest first — the dependency
  order — and a destruction that raised does not stop the ones after it;
- the construction's failure stays primary, and every destruction that raised
  is retained beside it, in the order attempted, under the
  `vulkan frame synchronization rollback` label, as
  [the failure table](resources.md#the-failure-table) requires;
- when every destruction returned, nothing is retained and nothing else
  changes: the reservation goes back as for any acquisition that raised, the
  session is not failed, and synchronization published before — the complete
  slot a failed pool record was being built for — stays;
- when one raised, the object it named may still exist. The slot or record is
  published anyway, held by no frame, with each object standing as its
  rollback left it: uncertain (`FenceUncertain`, `SemaphoreUncertain`) if its
  destruction raised, `FenceDestroyed` or `SemaphoreDestroyed` if it returned,
  and `FenceNeverCreated` or `SemaphoreNeverCreated` — its handle naming
  nothing — if the construction never made it. Its `syncDestruction` or
  `poolDestruction` records why. Admission closes and the session fails with
  `CleanupFailed`, without replacing an earlier terminal primary, before the
  failure is raised. Like a published record whose destruction raised, it is
  never destroyed again under any rule, the device-loss rule included, so the
  target's frame retirement keeps it and raises `FramesRetained` rather than
  certifying anything.

### Submission

`submitFrames` refuses before any native call: a batch of another session; a
batch named twice (`DuplicateSubject BatchIdentity`); one already submitted,
discarded or reset (`AlreadyConsumed BatchIdentity`); one still recording,
partial or uncertain (`WrongPhase BatchIdentity`); a batch whose frame this
owner did not acquire, or that is no longer acquired; two batches of one frame;
synchronization that is not ready; and anything the model would refuse, which is
asked of a copy it then discards. So the whole request is validated and its one
submission record reserved — the frame reserved it — before any native effect.

Then, in one masked step, the model notes each frame's fence reset, and the
first frame's slot fence is reset, only now, immediately before the one
submission it is passed to. Each batch waits on its frame's acquisition
semaphore at the color-attachment-output stage — where the recorder's
transition into rendering first touches the image — executes its command
buffer, and signals the render-finished semaphore of its frame's pool record. What the call did is
recorded before the step ends:

- **It returned.** The model records one submission every frame of the request
  shares, which retains every subject each batch recorded and every frame's
  swapchain generation until it completes; each batch is recorded as submitted
  with the recording (`noteBatchSubmitted`), which is the evidence its
  readback needs; and the fence is pending. Separate calls are separate
  submissions and settle independently; an explicitly shared request is never
  split, and unrelated targets are never combined behind the caller's back.
- **A specified no-effect failure** — out of host or device memory, which the
  native layer identifies (`opsNoEffect`). Nothing is pending; the model clears
  its fence-reset bookkeeping, and the native fence, reset and unsubmitted, is
  never waited on. Every frame is still acquired with its batch sealed. That is
  an allocation failure with no effect, [recovered once](#allocation-recovery):
  a reclamation pass, and the same request — its batches sealed as they were,
  no consumer run again — validated and submitted once more only if the pass
  disposed of something. Otherwise, or when that fails again,
  `SubmittedNothing` is answered, naming the original failure and the pass's
  evidence, and every frame can still be submitted again or skipped.
- **The fence reset raised.** Nothing was submitted and every frame is still
  acquired, with its batch sealed; but the fence is now in doubt, so it is
  marked uncertain and retained for ever with its slot, and since native
  synchronization safety is unknown, admission closes and the session fails
  with `CleanupFailed` before the failure is re-raised. The frames can still be
  skipped: a skip uses the slot's cleanup fence.
- **Anything else raised.** Whether anything was submitted is unknown. Each frame
  enters the model's uncertain-effect state, which retains every parent for
  ever and stops admission; the fence and both semaphores of each frame are
  marked uncertain, the session fails, and `FrameEffectUncertain` is raised — or
  the device loss itself, when that is what it was, so the loss is what the
  caller sees first. Nothing is rolled back.

### Abandonment

**A skipped frame.** `skipFrame` is legal only for an acquired frame nothing of
which has been submitted — a skip after any submission is `WrongPhase` — and is
an ordinary outcome, not a failure. Its unsubmitted recording is invalidated
natively through the recording's `resetFrameRecorder` and only then discharged;
the model skips the frame, which consumes its capability; and a cleanup
submission that runs no command and waits on the acquisition semaphore is made
with the slot's cleanup fence. Once that fence has signalled, `progressFrames`
returns the image through `vkReleaseSwapchainImagesEXT` and supplies the model
the frame's settlement, which frees its slot and its pool record — the native
record included, since nothing signalled its semaphore. The swapchain
is not rebuilt, the target stays available, and later frames are admitted within
the capacity that remains. Outstanding abandonment still holds its slot and its
pool record until the evidence arrives.

**A submitted frame never presented.** Close, cancellation or a refused
presentation can leave a submitted frame unpresented; `closeUnpresentedFrame`
marks it so in the model, keeping its submission and its image. It is never
treated as an unsubmitted skip. `progressFrames` first waits for its actual
rendering completion — its submission's fence — then settles the render-finished
semaphore of its pool record, whose signal has no other consumer, through a
tracked cleanup submission that waits on it, and only once that cleanup's fence
has signalled returns the image and supplies the settlement. The semaphore is
then unsignalled with no wait outstanding, the pool record is free, and the
slot may be reused. A presentation that enqueued nothing leaves its frame
submitted, and this is its exit too.

A cleanup submission or a release that raised retains the frame, its image and
its synchronization for ever — never retried, never fabricated as reusable —
fails the session with `CleanupFailed`, and raises `FrameCleanupFailed`. This
follows the precedent every other cleanup failure in the backend sets; isolating
an optional target from it is not recovery's to do: a failed cleanup is never
recoverable pressure, whatever the target's designation (P-14, VK-14). Both paths were proved on
both drivers by VK-2 ([macOS](vulkan/macos.md#safe-abandonment),
[Linux](vulkan/linux.md#safe-abandonment)); the KHR spelling of the release
entry point resolves on neither, and the binding's call dispatches the EXT one.

### Completion and the owner's step

Only a fence a queue operation made pending is ever asked whether it has
signalled, and only without waiting (`vkGetFenceStatus`), inside
`progressFrames`. A signalled submission fence is the model's
`SubmissionCompleted` fact: it discharges every hold the submission carried,
unsignals the acquisition semaphores it waited on, and frees each slot that
owes nothing else — but no presentation-pool record. A signalled present fence
is the `PresentationRetired` fact ([Retirement
evidence](#retirement-evidence)). A signalled cleanup fence, followed by a
release that returned, is the `UnpresentedFrameSettled` fact. Nothing else —
elapsed time, a returned call, a cancellation, a reset fence — ever becomes any
of them. A step makes
at most the model's progress-action limit of native calls. Its work — each
outstanding submission's fence, each cleanup owed, each cleanup fence — is one
list that each step starts one place further along, so a budget smaller than
the work still reaches every piece in turn and a fence that never signals
cannot hold a later submission's completion, cleanup or release back; work the
step itself creates is taken by a further pass while the budget lasts. A step
runs whatever the target's phase — closing included — and raises only once it has recorded
everything that returned: device loss first, then the first cleanup failure or
uncertain effect. VK-12's native case polls it a millisecond apart and
VK-13's drains through `awaitFrames`; the controller asks it only when the
model's schedule says a poll is due or a frame is to be attempted
([Polling completion](#polling-completion)).

### The protected handoff

Each native effect and the bookkeeping of its result are one masked step:
acquisition, the fence reset and the submission, the present fence's reset and
the presentation, each cleanup submission, each fence observation, and each
release. A cancellation is delivered only before the
call or after its result is recorded, in the model and here, and it is then
re-raised unchanged; it never undoes an effect or turns a pending fence into
completion. No consumer code runs inside a handoff, and none is run again:
recording is `recordFrame`'s, which runs its consumer exactly once, and a
consumer that raised leaves its frame acquired and its batch partial, to be
skipped. A step whose bookkeeping cannot commit enters the uncertain state and
is never rolled back.

### How the frames are built

`Hetoimasia.GPU.Vulkan.Native.Frames` is the entry point and holds no code of
its own: it re-exports what eight private modules under
`Hetoimasia.GPU.Vulkan.Native.Internal.Frames` implement, as the recording's
entry point does.

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `Layer` | The native layer's shape: `FrameOps`, what an acquisition and a presentation answer, a submission's batches and a presentation's request. No state, no call. | — |
| `State` | The `Frames` and the five maps it holds; the answers, failures and views; and the uncertain-state step. | `Layer`, the recording's `State` |
| `Acquisition` | `tryAcquireFrame`, the slot's synchronization, and binding the frame its presentation-pool record. | `Layer`, `State` |
| `Submission` | `submitFrames`. | `Layer`, `State`, the recording's `Batches` |
| `Presentation` | `presentFrame` and `classifyPresent`. | `Layer`, `State` |
| `Abandonment` | `skipFrame`, `closeUnpresentedFrame`, `closeTargetFrames`, and the cleanup submission `Progress` also makes. | `Layer`, `State`, the recording's `Batches` |
| `Loss` | `releaseFramesToDeviceLoss`. | `State`, `Abandonment` |
| `Progress` | `progressFrames`, `awaitFrames` and `retireTargetFrames`. | `Layer`, `State`, `Abandonment`, `Loss` |

`Frames.Vulkan` imports the public module. Every call it makes is the binding's
own and `safe`: submission, acquisition, presentation, a fence's status, a
finite fence wait and an image's release are driver-bound calls, not recording,
so the audited `unsafe` subset is unchanged. The controller constructs no recording, and so no frames either:
this module, like the recording, is driven on private roots by its native case,
and the loop adapter that composes both into the controller's owner step is
VK-16's.

## Presentation and retirement

VK-13 ([#227](https://github.com/coghex/hetoimasia/issues/227)) is
presentation over the frames, and the retirement that follows from it: D-9's
verified presentation-fence completion, D-15's bounded central lifetime
enforcement, D-18's overlapping generations and D-23's separately settled
abandonment, over P-2's frame ownership table, P-8's retirement beneath the
attachment, P-14's classification by actual effect and P-15's budgets. The GPU
model's public surface is unchanged: `enqueuePresentation`, its
`PresentOutcome`s, the `PresentationRetired` fact and the derived pool capacity
were already [its contract](gpu_model.md#frame-ownership), and this backend
supplies the native evidence.

### Presentation

`presentFrame frame` presents one submitted frame's image, one target image per
native request, to the swapchain it was acquired from, on the session's one
graphics queue. It refuses before any native call: another thread; a failed
session, naming its primary failure (`RefusedSessionFailed`), which makes no
new native effect — the frame's exit is its close; a frame this owner did not
acquire, or that is not submitted, already presented
or being abandoned (`WrongPhase FrameIdentity`); anything the model's
`enqueuePresentation` would refuse, asked of a copy it then discards; and a pool
record not bound to the frame, whose render-finished semaphore is not owed the
submission's signal or whose present fence is pending. Nothing is made,
reserved or waited for here: the pool record was reserved and bound with the
frame, so presenting is never refused for capacity. The frame's rendering need
not have completed — the presentation waits on the render-finished semaphore on
the device, never on the host.

Then, in one masked step, the pool record's present fence is reset — only now,
immediately before the one presentation it is passed to — and
`vkQueuePresentKHR` presents the image waiting on the record's render-finished
semaphore, with that fence chained through `VkSwapchainPresentFenceInfoEXT`
(`VK_EXT_swapchain_maintenance1`), and what the call did is read and recorded
before the step ends. A cancellation aimed at the owner is delivered only after
that record exists. The call may block in the driver: the handoff promises a
recorded outcome, never a prompt return, and it never interrupts the call
(GUIDE-2, #211). Targets present independently: nothing about one target's
presentation waits for, orders or refuses another's, and a presentation that is
delayed — or never made — keeps its frame's obligations and pool record, and
nothing else.

### What was enqueued

The swapchain's own entry of `pResults` is the truth for the swapchain; the
production layer starts it as `VK_RESULT_MAX_ENUM`, which no call writes, and
reads it back — before re-raising anything the call raised — so an entry the
call never wrote is read as unwritten, never as success. `classifyPresent`
reads it with whether the call raised, and they must agree: a call that
returned answers success or suboptimal for its one swapchain, and one that
raised answers the error it raised with.

| The call | The swapchain's entry | What it means | What is recorded |
| --- | --- | --- | --- |
| Returned | `VK_SUCCESS` | Enqueued | The model's presentation, `PresentationEnqueued`; the fence pending; the semaphore the presentation engine's |
| Returned | `VK_SUBOPTIMAL_KHR` | Enqueued | The same, `PresentationEnqueuedSuboptimal`; a replacement coalesced in the model and reported to the generations (`SwapchainSuboptimal`), with none of the frame's synchronization reset |
| Raised | `VK_ERROR_OUT_OF_DATE_KHR` | Enqueued: the specification keeps a rejected presentation's queue operations, and its semaphore waits happen | The same, `PresentationEnqueuedOutOfDate`; a replacement requested, reported as `SwapchainOutOfDate`, and rebuilt as [Replacement](#replacement) describes |
| Raised | `VK_ERROR_SURFACE_LOST_KHR` | Enqueued, likewise | The same, `PresentationEnqueuedSurfaceLost`; a replacement requested in the model, reported as `SwapchainSurfaceLost`, and the surface [replaced](#replacing-a-lost-surface) once this presentation, and every other hold on its generation, has retired |
| Raised out of memory | Out of memory, or unwritten | The specified no-effect case: nothing enqueued, and no present fence | Nothing but the fence, reset and never pending, and never waited on. The frame is still submitted, owning its image, semaphore and record. [Recovered once](#allocation-recovery): a reclamation pass, and the same frame presented once more only if the pass disposed of something; otherwise `PresentedNothing`, naming the original failure and the pass's evidence, and the frame can be presented again or closed |
| Anything else | Unwritten, contradictory, device loss, or a result the profile does not classify | Unknown | The frame enters the uncertain state — retained for ever with its image, record and parents — admission stops, the session fails with `UnknownSubmissionEffect`, and `FrameEffectUncertain` is raised, or the device loss itself |

A present fence whose reset raised presents nothing, but the fence is in doubt:
it is retained for ever with its record, admission stops, the session fails with
`CleanupFailed`, and the failure is re-raised; the frame can still be closed.
The rows other than success and suboptimal are specification obligations, not
behaviour VK-2 observed on both profiles — its record names them as
specification rows — and the headless examples inject each one.

### The presentation pool

Each target owns a presentation pool (P-2): records of a **render-finished
semaphore** and a **present fence**, made together the first time the pool
needs another record, named from the target and record (`poolObjectName`) when
the device offers naming, and bound to a frame at its reservation — before its
acquisition — so its rendering has a semaphore to signal and its presentation a
fence to chain whatever the budgets say later. A record serves one owner at a
time (`PoolHolder`): free, the frame reserved with it, and then the presentation
enqueued with it. It is bound only while its semaphore is unsignalled with no
wait outstanding and its fence is not pending, and it is freed only when the
model lets go of the pool record it served: when its present fence signalled,
or at the explicit settlement of a frame that was never presented — a skipped
one, a closed one, or one whose presentation enqueued nothing — never because
the frame's rendering completed, never by a timeout, and never because its image
was acquired again. A reservation given back — not ready, a timeout, out of date
— frees it untouched.

The pool's capacity is the model's derived `presentationPoolCapacity`, the
overflow-checked sum of the image tracking limit and the frame-slot count — 18
by default — validated with P-15's other budgets before a model exists. A
target's retired generations' pending records count against the same capacity
as its active generation's; no generation receives a pool of its own. An
acquisition the pool cannot serve answers
`AcquisitionPending (PendingBackpressure PresentationPoolBudget)` before any
native call, and a retirement makes room without the pool growing. Cleanup
never needs a record: a frame's abandonment uses the record it already holds.

A new acquisition of an image whose older presentation is still pending takes a
free record, with no host wait on the older present fence; the older record is
neither retired, recycled nor discharged by it, and still names its own image.
The new acquisition's own semaphore still orders the image's use on the device.

### Retirement evidence

A presentation retires only when its own present fence is observed signalled:
by a non-blocking `vkGetFenceStatus` in `progressFrames`, or after
`awaitFrames`' finite drain wait, whose wait is not itself the evidence. That
observation — and nothing else — is the model's `PresentationRetired` fact: it
discharges the generation's presentation hold, frees the pool record, whose
semaphore the presentation engine has finished with, and completes the
presentation half of the target's retirement cycle, matched to it by identity.
A status query that answers not ready is simply pending: what a fence answered
before is never read into it, and no status is assumed, before or after a wait.
A signalled render fence completes the submission and frees the frame's slot,
and frees no presentation object. A present fence only proves the
presentation's resource-retirement condition; it says nothing about when the
image reached the screen.

A status query that raised retains the presentation for ever — its record, its
pool record and its generation's hold — fails the session with `CleanupFailed`,
and raises `PresentationUncertain` once the step has recorded everything else;
the presentation is never asked again.

`awaitFrames now timeout` waits at most the timeout, and never longer than
`drainWaitLimit` — P-15's 10 ms — for the first pending fence of the step's work
(`vkWaitForFences` on that one fence), then runs `progressFrames`. It waits on
nothing when nothing is pending, and a wait on a fence has no effect on it. A
wait that timed out leaves every obligation, pool record and retirement exactly
as it was: a timeout is a scheduling outcome. The owner may call it where a
protected drain would otherwise spin.

### Incremental retirement

Retired generations retire incrementally, from verified fences alone. Once the
model reports every hold on a retired generation ended — its presentations'
among them — the owner's next generations step destroys its views and
swapchain, bounded to the model's progress-action limit of generations a step
and taken one of each target's in turn, starting one target further along each
step, so no target's backlog delays another's. Nothing waits for the device to
go idle.

A closing window retires the same way. Its frames are closed
(`closeTargetFrames`) — acquired ones skipped, submitted ones closed unpresented
— and its presentations stay until their own present fences are observed.
`retireTargetFrames` then destroys its slots' and its pool's synchronization,
and raises `FramesRetained`, naming the frames, presentations and records that
remain, until then; `retireTargetGenerations` raises `GenerationsRetained` while
any generation's hold remains, which keeps the surface, and so the attachment's
terminal retirement fact, withheld from the protected host through #219's
controller path. Closing the first-created target retires only its own frames,
presentations, generations and surface: the shared device, the instance and
every other target stay live, and another target keeps presenting throughout.
The controller meets exactly this order: its retirement of a target is owed
until the evidence has arrived ([Retiring a target](#retiring-a-target)), so
it withholds nothing by raising and retries nothing.

## Recovery

VK-14 ([#229](https://github.com/coghex/hetoimasia/issues/229)) acts on what the
earlier slices only reported: a lost surface, an episode spent, and a native
allocation that ran out of memory. It is D-18, D-22, D-24 and D-25 over P-14's
operation table and P-15's budgets. Allocation reclamation and swapchain
replacement live in the native package; surface replacement on the live
window, which needs the main thread, is orchestrated by the controller. The GPU
model's public surface gains one transition, `declareTargetUnrecoverable`
([its contract](gpu_model.md#recovery)); everything else was already the
model's.

### The episode as delivered

Every recovery a target makes spends its one episode, which the model owns
([Recovery](gpu_model.md#recovery)): at most three construction attempts, the
second 100 ms after the first failure and the third 500 ms after the second, on
the owner's monotonic clock, with one attempt in flight at a time and
exhaustion decided at the last failure. A deferred attempt is a deadline the
generations name (`RecoveryWaiting`), so the owner takes the round it falls
due in and never polls or loops hot.

| What happens | Is it an attempt? |
| --- | --- |
| An ordinary resize, however often the geometry moves | No: it is coalesced for 16 ms and built as a replacement ([Replacement](#replacement)) |
| An out-of-date or suboptimal result with unchanged geometry | Yes, each rebuild |
| A construction after one that failed, a window still in use (`VK_ERROR_NATIVE_WINDOW_IN_USE_KHR`) included | Yes: the next attempt of the same episode, never a new one |
| A lost surface's replacement, from asking for the surface to publishing a generation on it | Yes, one attempt; a construction on the new surface that fails spends the next |
| Waiting for an unretired swapchain or a lost surface's generations to go | No: nothing is admitted until they have gone |
| A zero-area or ineligible target | No: suspended |
| An allocation's own retry after reclamation | No: it is inside the attempt that made the allocation, and reaches no episode accounting |

Nothing replenishes the budget but what the model counts: a completed
presentation-retirement cycle after a successful recovery, and a healthy second
after that. A changed framebuffer observation, a nested retry, repeated loss,
and an allocation's retry all count on from where the episode stands.

### Replacing a lost surface

A surface is lost when a swapchain call on the target's active generation
answers `VK_ERROR_SURFACE_LOST_KHR` — an acquisition, which gives its
reservation back, pool record included, or a presentation, which was enqueued
all the same — reported as `SwapchainSurfaceLost`, which outranks every other
result; or when the surface's capability query or a swapchain's creation
raises it. The loss is the surface's, so it is taken from any generation the
target still tracks — a late presentation on a generation already retired
included — and, once the surface is being recovered, a late report about it
changes nothing and never reaches the replacement. Then, on the owner's thread:

1. **Admission stops.** The reconciliation retires the active generation there
   and then, and builds nothing on the surface again. Acquisition answers
   `AcquisitionPending PendingSurfaceLost` without a native call; the target
   stays admitted, and every other target, the device and the instance are
   untouched.
2. **Old dependents retire on their own evidence.** Acquired and submitted
   frames settle and presentations retire through the frames, and the retired
   generation is destroyed once its holds end, as any retired generation is.
   Nothing is waited on and nothing is replayed.
3. **The lost surface goes, then an attempt begins.** Once no generation of the
   target remains, the roots destroy the lost surface and keep the target
   (`releaseRootSurface`) — its identity, its designation and, above it, the
   window's attachment, which is never released or reattached. Only then does
   the episode admit an attempt (`SurfaceReplacing`); a deferred one waits for
   its deadline, and a spent one is disposed of through the designation.
4. **The main thread creates the replacement.** The step answers the targets
   that now want a surface (`summarySurfacesWanted`); the controller asks the
   main thread for each and wakes it. That holds for every step that can admit
   an attempt: the owner's own, and the one another target's retirement runs
   when its poll is due, which can release this target's lost surface too. An
   attempt already outstanding asks nothing more. `replaceVulkanSurfaces`, on
   the main thread, creates the surface through the bridge's admitted replacement
   (`replaceWindowSurface`, [#216](https://github.com/coghex/hetoimasia/issues/216))
   under that same attachment, and deposits what it created.
   `runVulkanOwnerLoop` runs it every turn; an application that drives its own
   loop runs it, as it publishes observations.
5. **Support is rechecked, then a fresh generation is built.** The owner's next
   step offers the surface to the generations (`offerReplacementSurface`). The
   roots ask `vkGetPhysicalDeviceSurfaceSupportKHR` of the session's one queue
   family and install it (`installRootSurface`), and the next step builds a
   fresh generation on it — handing nothing over — whose publication settles
   the attempt as a success, or whose failure spends the next. A loss the
   replacement's own query reports before then fails that attempt with it, so
   the episode admits the next, or is spent.

| What the replacement came to | What happens |
| --- | --- |
| Installed | `ReplacementInstalled`; the surface is the roots', and a step is owed at once |
| The device's queue family cannot present to it | `ReplacementUnsupported`; the surface is destroyed on the owner's thread, the attempt fails, and the target is declared unrecoverable: [disposed of through its designation](#required-and-optional-dispositions). No second device or queue is made, and nothing migrates |
| Installed, but it cannot serve the presentation profile | `PresentationUnsupported`, naming every gap; the attempt fails and the target is declared unrecoverable, disposed of through its designation, as one the device cannot present to is |
| Created unusable, or not created | The attempt fails, the unusable surface is destroyed, and the episode schedules the next |
| The bridge refused it | The window is closing, the attachment retiring or the lease releasing: close is coming, and the attempt is left for the target's retirement to settle. If the owner's view shows the target still eligible, the attempt fails instead, rather than waiting for a close that is not coming |
| Its support query or naming raised | The surface is destroyed and the attempt fails; device loss and a cancellation stay the owner's |

**Close wins.** A target that has begun retiring asks for nothing and is offered
nothing: a replacement that arrives after the close stays its creator's and is
destroyed (`ReplacementNotWanted`), and the target's retirement settles an
attempt still outstanding, whose failure then decides nothing. A replacement the
main thread is creating at the moment the attachment retires is waited for —
its native call is finite and owes the owner nothing — so its surface is on the
lease before the retirement sweeps it. A construction completed after the close
is retired rather than published, as [before](#failure-and-close).

**Unproven rollback forbids the next attempt.** A lost surface whose
destruction did not complete is retained, never attempted again, fails the
session with `CleanupFailed`, and raises `SurfaceDestructionFailed`; so does a
partial replacement whose candidate could not be destroyed
(`GenerationDestructionFailed`). Either retains the target's parents, and no
attempt is admitted in a failed session.

### The retired chain

A replacement that handed the active generation over as `oldSwapchain` retired
it whatever the creation answered — `VK_ERROR_NATIVE_WINDOW_IN_USE_KHR` and out
of memory included — and it is never named again. The next construction is a
fresh one, with a null `oldSwapchain`, and it begins only once every swapchain
of the target Vulkan still counts as unretired has been destroyed: the retired
chain's images are finished or abandoned, it is destroyed, and only then is the
fresh creation made. A window still in use at that fresh creation is an
ordinary failed attempt of the same episode, never a reason to create before
the destruction. The native rules are the proof record's
([macOS](vulkan/macos.md), [Linux](vulkan/linux.md)); the headless examples
inject them.

### Required and optional dispositions

A target whose episode is spent (`RecoverySpent`), or whose replacement surface
the device cannot present to or that cannot serve the profile, is disposed of through the designation the
application gave it (D-22):

- **Optional** — the model marks it unavailable and the session continues. Its
  generations retire as their holds end, and every other target keeps
  presenting on the same device. The controller reports it once, by
  attachment: `readVulkanUnavailability` answers the target and why —
  `UnavailableRecoverySpent`, `UnavailableSurfaceUnsupported` or
  `UnavailablePresentationUnsupported` — and an
  application waits on it in `STM`; the most recent 64 are kept. The native
  window is not closed and its destruction is not authorized: the attachment
  stays until the application releases it and its retirement is safe. A target
  that holds nothing more once it is unavailable is forgotten by the model's
  next progress turn, which is why the report is read from the model's
  escalation and not from the target's phase.
- **Required** — the model fails the graphics session
  (`RequiredTargetUnrecoverable`), and the owner's step checkpoints the roots,
  which latch it in the terminal report ([Terminal failure](#terminal-failure)).
  When it is the primary, the step raises `VulkanRequiredTargetFailed` naming
  each such target; when a diagnostic failure came first, that primary is
  raised instead and the exhaustion joins the evidence behind it. Either ends
  the owner's run and reaches the application's checkpoints like any other
  owner failure ([VK-18](glfw.md#the-supervised-graphics-owner)). The ordinary
  all-exit retirement follows.

Device loss, a validation error, an unknown effect and a failed cleanup are
never recoverable pressure: they escalate to the session whatever the target's
designation, as they always have.

### Allocation recovery

D-25's one bounded reclamation pass and at most one retry, only where retrying
is proven safe — the operation-specific no-effect results, and constructions
whose rollback is complete — and nowhere else:

| Operation that ran out of memory | Why a retry is safe | What is retried |
| --- | --- | --- |
| `vkQueueSubmit2` | The specified no-effect result | The same request, its batches as sealed |
| `vkQueuePresentKHR` | The specified no-effect result, read from the swapchain's entry | The same frame's presentation |
| A managed resource's creation | A creation that raised created nothing; a composite one destroyed what it made before raising | The same creation, for the same allocation attempt |
| A readback's allocating VMA call | VMA destroyed what the call made, and the call's effect was settled, its reservation returned | The whole allocation protocol once more: held memory first, then a fresh reservation ([Device memory](#recovery)) |
| A swapchain's creation that handed nothing over, or an image view's | A creation call that raised created nothing | That call |
| A frame slot's or a pool record's semaphore or fence | A creation call that raised created nothing; if its recovery does not succeed, the objects made before it are destroyed before the failure is raised | That call |
| A swapchain's creation that handed a generation over | Never: that call retired the generation whatever it answered | Nothing; the construction fails into the episode's fresh construction |

Configured-capacity exhaustion is backpressure, answered before any native
call, and starts no recovery. For each failure:

1. **The attempt.** The operation's model allocation attempt — the managed
   resource's own, or one accounted for the recovery's duration — records the
   failure, and notes a generation the construction already retired as
   `oldSwapchain`. When the object budget is full — exactly when reclaiming
   matters — the recovery runs with no attempt to account, and its one retry
   is judged by the same rules the model's attempt applies; a session that has
   failed admits no recovery at all.
2. **One pass.** The model's `reclaimPass` decides the window: at most the
   configured number of generation and managed-resource records, ineligible
   ones included, from a cursor it carries from pass to pass. The subjects
   eligible in that window are offered to the layer that owns each — the
   generations and the recording each register a disposer with the roots when
   they are made — which destroys it natively, child before parent, each
   destruction recorded in its own masked step, or declines when something
   above it still stands. Then the pass records what each destruction did.
   Nothing waits for unfinished work, and nothing but a destruction that
   returned is progress.
3. **At most one retry.** `retryAllocation` permits the attempt's one retry
   only after a disposal completed since the failure, never after the
   construction retired a generation as `oldSwapchain`, and never in a failed
   session — so a disposal that failed, which escalates the session, forbids it
   however much else the pass reclaimed. Each failed disposal is latched once,
   as a cleanup failure naming its subject.

No progress, a failed disposal, a refused retry or a second failure ends the
recovery and reports the original failure with the pass's evidence — what it
examined, disposed of and failed to dispose of, and how it ended: as
`AllocationNotRecovered` from a construction, and in `SubmittedNothing` or
`PresentedNothing` from a submission or a presentation. Every attempt, the
retry included, runs through the roots' guard, so device loss latches wherever
it is raised; and what the retry raised that means more than a failed retry —
device loss, a cancellation, a lost surface, a window still in use — is
re-raised as itself, so the construction acts on it as it would on a first
failure.

### What recovery never does

It never replays a consumer callback or submitted work, evicts a live
generation, takes another target's reservations or budget, retries a failed
cleanup, recreates the device, migrates a target to another device, or changes
resolution, quality or frame capacity. It never closes or destroys a window,
and never releases or reattaches an attachment to reach the bridge.

### How recovery is built

| Module | Responsibility |
| --- | --- |
| `Internal.Generations.Reconciliation` | Reads a surface-lost result, and the surface loss the capability query or a creation raises, retiring the active generation; recovers a swapchain's and a view's creation that ran out of memory |
| `Internal.Generations.Surface` | `releaseLostSurfaces`, run by `stepGenerations` after reconciliation; `offerReplacementSurface` and `replacementSurfaceFailed` |
| `Internal.Generations.Disposal`, `Internal.Recording.Disposal` | Make the generations and the recording, registering each one's disposer with the roots |
| `Internal.Reclamation` | `reclaimOnce`, `recoverAllocation` and `recoveringCreation`, over the roots' disposers and the model's allocation attempt |
| `Roots` | `releaseRootSurface`, `installRootSurface`, the `NativeFailure` classifier and the disposer registry |
| The controller | Asking for and settling replacements, `replaceVulkanSurfaces` on the main thread, the unavailability report and `VulkanRequiredTargetFailed` |

## The composed loop

VK-16 ([#232](https://github.com/coghex/hetoimasia/issues/232)) composes the
graphics owner's rendering with the main thread's scheduled owner loop, TIME's
deadlines and LIFE's retirement. There is still one engine loop: the main
thread runs the GLFW package's `runScheduledOwnerLoop`, and the graphics owner
is the supervised worker [VK-18](glfw.md#the-supervised-graphics-owner) already
runs. What VK-16 adds is what crosses between them every turn, and what the
owner's step does with it.

### The loop adapter

`runVulkanOwnerLoop` is `runScheduledOwnerLoop` over the host's window host
with the application's own `ScheduledHooks`, and one addition to every turn.
Once the application's update opportunity has returned, the main thread:

1. **publishes observations** — for every window with an attachment, the
   window's latest `WindowObservation` and the render eligibility the main
   thread classified it as (`windowRenderEligibility`), whenever it is newer
   than the one last published for that attachment;
2. **publishes render demand** — it captures every such window's demand slot,
   which is the acknowledgement the slot's publisher is owed, combines the
   requests, and publishes them to the owner's demand snapshot. The snapshot
   keeps only its latest value, so what was published and not yet taken into
   an owner step (`readOwnerDemandTaken`) is kept and published again with
   anything newer: a newer publication never replaces demand the owner has not
   seen. Once taken, it is forgotten. A closed snapshot — the owner's admission
   has ended — settles it, since nothing will render it;
3. **creates replacement surfaces** the owner asked for
   (`replaceVulkanSurfaces`, [Recovery](#recovery));
4. **folds the owner's deadline** into the schedule the application's update
   answered: the earliest absolute instant the owner last published, when it
   is still ahead, bounds the turn's wait. It can shorten the main loop's wait
   and never lengthen it: `NoUpdateDemand` becomes `UpdateBy` it, an earlier
   `UpdateBy` stays, and `UpdateImmediately` stays. A deadline that has already
   passed is left out: the owner schedules its own rounds, wakes the host after
   each, and needs none of this to be read.

None of it waits: every handoff is a latest-value snapshot or a non-blocking
capture, and the main thread performs no GPU work. An application that runs
this loop leaves observation publication and window demand capture to it — an
observation published by hand at a higher revision would make the adapter's
stale, and a slot the application captured itself would never reach the
owner. A scene may be published from any application thread with
`publishVulkanScene`.

### What asks for a frame

The owner's step is handed the latest demand and scene with the revisions of
their publications (`stepDemandRevision`, `stepSceneRevision`), so two equal
publications are two requests. Each constructed target records the latest
revisions a step has considered for it, so a publication made before a target
could take it — a first redraw arriving with its handover, taken by a round
that had no target constructed yet — is still its request once it is
constructed. A target is asked for a frame — the model's `requestRender`, which
is also what restarts the idle backoff, and which supersedes any retry pending
for it — when

- a demand publication the owner has not acted on is due: immediate, or with a
  deadline that has come; one still ahead is kept and asked for when it comes,
  and the owner's deadline includes it. One publication can carry both parts —
  two windows captured in one turn, one asking now and one by a later
  deadline — and both are kept: the request now is served at once, and the
  deadline when it comes. A held deadline that comes while no target is
  constructed stays held until one is;
- a scene publication the owner has not rendered arrives: the renderer renders
  the latest scene, whichever application thread published it (D-31); or
- a target that has presented before can no longer be showing the latest
  scene: its active generation is not the one its last presentation went to,
  or it has become eligible again after a suspension. A generation it moved to
  is asked for once, however many rounds pass before a frame of it is
  presented, so a frame refused meanwhile keeps its retry's pacing. And since
  the step plans its frames before the generations' step, a replacement that
  step publishes — a quiet target's, whose one allowed generation was disposed
  of in that same step with nothing left owed — is asked for then and offered a
  frame in the same step. A target already due in that step is offered its
  frame on the replacement, and the replacement is recorded as asked for it
  too.

Nothing else asks. A target nobody asked a frame of is never rendered to,
however its generations change, so a host whose application publishes neither
demand nor a scene presents nothing, exactly as before VK-16.

### Rendering a frame

A target the model says wants a frame — render demand, admitted, and not
suspended or closing — is offered **one** attempt per step, and the targets
are served in an order whose lead rotates each step, so none waits behind a
neighbour. The attempt is `tryAcquireFrame` with a zero timeout; the recording
of the frame, inside `recordFrame`, as the transition into the
color-attachment layout, the configuration's `VulkanRenderer`, and the
transition to presentation; one `submitFrames`; and one `presentFrame`. The
recording and the frames are made on the owner's thread the first time a frame
is attempted once the device exists, and each target's frame storages — one per
frame slot of the model's budget — the first time that target is.

- An acquisition the swapchain cannot answer yet — not ready, out of date, no
  generation, backpressure — is retried at the first interval of the model's
  backoff schedule (5 ms by default), anchored at the step's own instant, so
  work the step did counts against it and nothing sleeps after it.
- A frame the renderer refused, whose recording was refused, or whose
  submission had no effect is skipped (`skipFrame`); one whose presentation
  enqueued nothing is closed unpresented (`closeUnpresentedFrame`). Each is
  abandoned safely under VK-12's rules, never replayed. The target's render
  demand stands, so its next frame is tried at the same first interval, as an
  acquisition that could not be answered is: a renderer that refuses every
  frame costs one attempt an interval, never one every owner round. A fresh
  request for the target is an opportunity now, and supersedes that retry.
- Enqueuing the presentation clears the model's render demand.

The renderer is `∀`-typed over the native handles, so it records through the
managed boundary alone; `clearRenderer` clears the frame to the colour it
computes from the scene and the `FrameRequest` — the attachment, target,
frame, image, the image's extent and color format, and the scene revision. The
request is the frame's description, handed to the renderer before it records
anything; the controller's own transitions around it are the only commands
recorded first.

### Consumer construction

VK-19 ([#299](https://github.com/coghex/hetoimasia/issues/299)) gives the
renderer the construction D-26 and P-1 assign the consumer. With each frame it
is lent the session's `Construction`, and through it it builds
(`constructPipelineLayout`, `constructPipeline`), replaces
(`replaceConstructedPipeline`) and releases (`releaseConstructed`) pipeline
layouts and graphics pipelines over #221's embedded shaders. They are the
recording's [managed resources](#recording-through-managed-resources), beside
the controller's own frame storages, so the consumer holds opaque handles and
never a native one. A pipeline is built for one color format; the frame's
`requestFormat` is the one its image has, and a pipeline built for another is
refused at `bindPipeline` by the recorder's own check (`RefusedIncompatible`),
before anything is recorded. Inside the frame, the renderer begins dynamic
rendering, binds, sets the viewport and scissor, draws, and ends rendering;
the controller owns the image-layout transitions on either side of it. The
public module re-exports that recording vocabulary, so a consumer needs only
the host's package and the shaders it embeds.

- **Thread.** Every construction and release belongs to the graphics owner's
  thread, where the renderer runs; one made from any other thread is refused
  (`RefusedNotOwner`) before anything native is done. So is one after the
  session has failed or while a diagnostic failure is pending. The controller
  still makes no GLFW call.
- **Failure.** A construction that is refused answers its refusal, and the
  renderer that answers it in turn skips its frame under the ordinary skip
  rules — the renderer is not called again for that frame, the target's next
  frame is tried at the backoff's first interval, and the session continues. A
  construction that *raised* before committing any generation, with the
  session still running, left nothing — its creation made nothing and gave its
  reservation back — and is answered `RefusedConstructionFailed`, confined to
  that frame the same way. Its allocation recovery
  ([Recovery](#allocation-recovery)) retries a creation that ran out of memory
  inside the construction, never by calling the renderer again. One that raised
  after committing a generation is not confined: a replacement whose new
  pipeline could not be named has released that generation and already
  replaced the old one, so the renderer's handle is stale, and the failure is
  raised as it was and ends the owner's run. So does a construction that raised
  because the session failed — the device's loss, an uncertain effect, a failed
  cleanup, which the call latched on its way out — with that primary through
  the [terminal latch](#terminal-failure), and so does every cancellation. No
  exception of the renderer's own is caught.
- **Lifetime.** A handle outlives its frame; the consumer keeps it across
  frames. A replacement publishes a new generation and releases the old one: a
  batch that recorded the old pipeline keeps it, and its layout, until that
  batch's references end, and only then is it destroyed. Whatever the renderer
  released, and a replaced generation, is destroyed on the owner's thread in a
  later step once nothing holds it (`reclaimReleased`, which takes a model turn
  only when some released generation is eligible). Whatever it never released
  is released and destroyed by the recording's retirement, before the device,
  on the host's normal and terminal exits alike
  ([Destruction order](#destruction-order)); what cannot be verifiably
  destroyed — a destruction that raised, or holds that never ended — is
  retained with its parents, and the terminal report says so.

The triangle sample ([`samples/triangle`](../samples/triangle/README.md),
VK-17) is the consumer example. Its drawing, `drawTriangle`, is written against
the native recording vocabulary alone and takes the two constructions it needs
as values; the sample's executable, and the native suite's required profile,
hand it to the host in one line:

```haskell
triangleRenderer ∷ Triangle → VulkanRenderer scene
triangleRenderer triangle = VulkanRenderer $ \_ request construction recorder →
  drawTriangle triangle
    (Builders (constructPipelineLayout construction) (constructPipeline construction))
    (requestFormat request) (requestExtent request) recorder
```

It builds a layout and a pipeline the first time it meets a format, keeps them
across frames, and leaves both to the session's teardown. A format's layout is
built once: when the pipeline over it is refused, the frame is skipped and the
layout is kept for the next frame's attempt, so a refusal that recurs never
spends the session's object budget on another layout.

### Verification capture

The verification strategy's capture — the pixels of a real, presented frame —
is reachable through the host, and only by this package's own suites. A host
composed with capture on builds every generation unclipped and, where its
surface offers the usage, as a transfer source ([Capture usage](#capture-usage)).
A host with it off — every other host — builds exactly what it did before
VK-19: clipped swapchains with no transfer-source usage, and a target's
compatibility never depends on capture. It refuses every request
(`CaptureDisabled`).

- **Request.** `requestVulkanCapture` admits, from any thread, a request for
  the next frame of an attachment's target and answers a `CaptureTicket`. It
  is refused — `CaptureRefusal` — when the host does not capture, when the
  owner holds no target for the attachment, when that target has begun
  retiring (`CaptureTargetRetiring`: its retirement closes admission before it
  settles the requests it has, so none is admitted after that settlement),
  when the attachment already has a request outstanding, when 64 requests are
  outstanding or settled and not yet taken (`CaptureBacklogFull`, which is
  backpressure), and once the session has failed. Admission wakes the
  owner, and its next step asks that target for a frame as render demand
  would, so a verifier need publish nothing else. At most one request per
  attachment is outstanding, and each capture's readback buffer is admitted
  under the model's existing budgets like any managed resource.
- **Association.** The next frame the owner acquires for the target is the
  request's, whatever becomes of it: a failed capture is settled, never moved
  to a later frame. The owner claims the request a frame will be for before it
  asks for that frame, and associates only the one it claimed, so a request
  admitted while an acquisition is under way is a later frame's; and a frame
  is associated before its acquisition is reported to the frame observer, so a
  request made from that report is a later frame's too. A frame whose generation is not a transfer source — its
  surface offers no transfer-source usage, which never refuses the target
  itself — settles the request `WithheldUnsupported`, and one for which no
  readback buffer could be made settles it `WithheldNoReadback`; either frame
  is then recorded, submitted and presented as any other.
- **Recording.** Otherwise the frame is recorded, submitted and presented as
  usual, and its batch ends, after the renderer's commands, with the image's
  transition from the color attachment to the transfer source, the copy of the
  whole image into the readback buffer made for it, the barrier from that
  transfer write to host reads, and the transition to presentation. A frame
  skipped, abandoned or closed unpresented settles the request
  `WithheldFrameAbandoned`, naming why, and delivers no bytes.
- **Delivery.** Once the batch's completion evidence exposes the bytes —
  `readReadback`'s own rule: the batch recorded as submitted, and the buffer
  owing no reference and no submitted use, which the model discharges only on
  the submission's completion fact — the owner copies them out in the step
  whose poll observed the completion and settles the request with a
  `CapturedFrame`: the bytes, as a copy of their own that later reuse of the
  readback memory cannot change; the extent and format; and the frame's
  identities — target and attachment, generation, frame slot, image,
  presentation — and scene revision, kept apart from any later reuse of the
  slot or the generation. `takeVulkanCapture` answers a settled request once,
  and keeps it until it is taken: since admission is what is bounded, no
  admitted request's outcome is ever dropped. The readback buffer is
  released at settlement and destroyed on the owner's thread once its batch no
  longer holds it.
- **Ending.** A request still outstanding when its target retires is settled
  `WithheldTargetRetired` — after one last delivery attempt, since the
  retirement's preparation waited for every frame of the target to end on its
  own evidence — and one the session's end finds is settled
  `WithheldSessionEnded`, with the primary failure if the session failed.
  Nothing is read once the session has failed or the device has been lost: a
  hold the loss let go of is not completion. The host's exit settles any
  request its owner never reached the same way, so nothing waits on one for
  ever. Readback buffers are released and destroyed under the same teardown
  rules as the consumer's resources.

### Polling completion

A fence is asked only when the model's own schedule says a poll is due, or
when a frame is to be attempted this step and the slots it needs may be
waiting on one. The schedule is the model's `progressDeadline`
([GPU model](gpu_model.md#owner-progress)): the idle backoff over pending
obligations and every recovery deadline, with render demand left out, because
render demand says a frame is wanted, not that one can be acquired now. The
generations are stepped — which is where the model's progress turn, and so the
backoff's anchor, happens — when a target's observation moved, when their own
deadline has come (a result to reconcile, a settling resize, a recovery
attempt, the poll), or when a frame is to be attempted. A round something
unrelated woke asks no fence and takes no model turn: it neither polls early
nor moves the schedule on.

Each generation step takes one model turn, and a second only when its
reconciliation rescheduled an opportunity now: the backoff moves on once per
poll, 5, 10, 20, 40, 80 and then 100 ms under unchanged conditions. New
demand, a new obligation — a presentation enqueued — an observed completion or
a close transition restarts it at once; an unrelated event changes none of
those and restarts nothing.

### Pacing, suspension and fairness

The owner's `graphicsNextDeadline` is the earliest of the unannounced watch, a
replacement it is waiting on, the generations' own deadline, and rendering's:
a frame wanted now, an acquisition's retry, or a demand deadline still ahead.
So a quiet scene rendered continuously — demand, or a new scene, each time the
last frame was presented — keeps the owner on the first pending-work interval
and never lets its schedule fall into the idle backoff; and a target with no
demand and no progress backs off on absolute deadlines.

A hidden, iconified, zero-area or closing target is **suspended**: its
generations' reconciliation suspends it in the model from the main thread's
classification of its window, it is offered no frame, and its render demand
contributes no deadline. Its outstanding obligations — a presentation whose
present fence has not been observed — keep a finite poll deadline on the
backoff, so the owner neither forgets them nor spins on them. One suspended
target, or one whose acquisitions cannot be answered, never pauses another:
each is offered its own attempt, and a pending acquisition only reschedules
that target's retry.

A target resumed from an ineligibility suspension while a generation stood —
its window hidden or minimized — is **replaced**, never resumed on that
generation: the reconciliation that finds it eligible again builds a
replacement at once, handing the old one over as `oldSwapchain`, with no
settling period and no recovery attempt spent, and the target stays suspended
in the model until the replacement is published. A compositor need not answer
a presentation made for a surface it has since unmapped: on Wayland, Weston 13
offers no `wp_fifo_v1`, so Mesa's FIFO present waits, with no timeout, for the
frame callback its swapchain's previous presentation requested, and the old
generation's next present would never return
([#357](https://github.com/coghex/hetoimasia/issues/357)). It costs one
swapchain creation per resume on every platform. The old generation is
retired as any replaced one is: held until its presentations have retired on
their own present fences, then destroyed.

**Hiding a presenting window.** A hide's native call is itself the
hazard, because the owner learns a window was hidden only from the observation
published after it. So the host has the window's graphics owner withhold its
presentation first ([glfw.md](glfw.md#hiding-an-attached-window)), whether the
hide came through the host's command ports or was made directly on a window
`withHostWindow` lends
([#368](https://github.com/coghex/hetoimasia/issues/368)): the main
thread waits while the owner's step in flight may present to the target, and
every later step views the target as suspended until the hidden window's
observation is folded. The step view's withdrawal count (`viewWithdrawals`)
rises with every hold a step applies, and the controller then withdraws the
target's active generation (`withdrawGeneration`) before any frame of that
step, so even a hide and a show that both came between two steps resume the
target on a replacement.

### Retiring a target

A target's retirement is owed (`RetirementOwed`) until it can be performed.
The first time the owner asks (`graphicsPrepareRetirement`), the controller
closes the target in the model — which drops its render demand and restarts
the schedule — and closes its frames (`closeTargetFrames`): acquired ones
skipped, submitted ones closed unpresented. Each time it asks it polls when a
poll is due, anchoring the schedule with one generation step, and answers
ready once no frame and no presentation of the target remains, or once the
device has been lost. Only then does the owner retire the target, once:
`retireTargetFrames` destroys its slots' and pool's synchronization, its frame
storages are released and destroyed, then its generations, then its surface.
An owed retirement certifies nothing; the attachment's terminal record is
written only by the retirement's own return, exactly as before.

Whole-owner retirement refuses every owner-thread action still queued, then
retires the recording — releasing and destroying every managed resource still
live — before the device is destroyed.

### Status

Status reaches application services through the runtime's checkpoints and the
attachment's observation, as it did: a latched terminal failure (VK-15) ends
the owner's run at its next step and is raised by the application's next
checkpoint through `superviseGraphicsOwner`; target unavailability (VK-14) is
read with `readVulkanUnavailability`; retirement facts reach the attachment's
observation through the host's completion publisher, with terminal records
retaining what a full inbox could not carry. The owner's wake
(`graphicsWake`) asks for a round while the capture's sink has failed and
nothing is latched, **and** while a primary failure latched on another thread —
a handover's checkpoint on the main thread — has not yet been taken by the
owner's own step; without the second an idle owner kept running on a session
the main thread already knew had failed.

### Stop and quiescence

Stop follows D-33 through VK-18's machinery, unchanged: quiescence closes
admission and the owner's publications; ordinary workers drain; the owner
retires each target, then itself, then destroys itself; the main thread
services bounded housekeeping and joins the owner before any window is
released. A target whose retirement is still owed when the owner begins its
exit drain is asked again between waits for the owner's own next deadline —
the model's poll schedule — until it is retired or its retirement fails. A
demand deadline counts toward that schedule only while an admitted target that
is not closing could serve it: the drain takes no step, so no frame can, and a
deadline left standing once it passed would be asked about again at once, for
ever. For the same reason a target the model is retiring owes its generations'
reconciliation nothing — a settling replacement, an unseen swapchain result or
a deferred recovery attempt — since no step reconciles it again; its
obligations keep the model's poll schedule. No
timeout ends that wait, because a timeout is not evidence, and a cancellation
ends it by leaving what is still owed with the owner, unverified, and naming it
to whole-owner retirement. Nothing waits for a command from the ended loop: a
window command submitted once the loop has ended is answered by the host's
quiescence, never left waiting. Nor does anything wait for an owner-thread
action the exit will never run: quiescence's closing of the owner's
publications is also what refuses every queued action that has not started,
before ordinary workers drain, so a worker awaiting one is answered and can
drain ([Owner-thread actions](#owner-thread-actions)). That closing is part of
the host's own quiescence transaction, which the application's pre-drain
quiescence commits ([The exit, which is D-33's](glfw.md#the-exit-which-is-d-33s)),
so the action gate, which follows the owner's lifetime port, closes there and
not at the protected exit after the ordinary drain.

### During a main-thread stall

A platform modal loop inside the native event call stalls every step of the
adapter: no observation, no demand and no replacement surface is published
until the call returns, and window commands wait for the pump as they always
did. The owner is not stalled by it. It keeps rendering what it holds — the
latest scene any other thread published, the last coherent observation, and
the extent the surface's capabilities supply (D-30), with acquisition
suspended for unusable dimensions and replacement bounded by VK-10's budget —
on its own deadlines. A live resize, which changes the surface faster than a
replacement's period, keeps presenting from the active generation and is
rebuilt from the newest extent once a period
([Replacement](#replacement)); a headless example holds the native call while
the stand-in surface changes every 8 ms and requires both.

**What that does not mean.** A frame the owner presents during a stall proves
that the request was admitted; its present fence, observed signalled, proves
that the presentation engine finished with the image. Neither proves the frame
became visible. Whether frames visibly advance during a Cocoa live resize or
menu interaction is a native measurement: the graphics-owner interaction probe
([The native suite](#the-native-suite)) records it, and
[the graphics-owner interaction verdict](graphics_owner_interaction_verdict.md)
states what was measured and what was not.

### How it is built

| Module | Responsibility |
| --- | --- |
| `Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering` | The recording and the frames above the generations, what asks a target for a frame, one frame's attempt, completion polls, the rendering deadline, and a target's retirement readiness and rendering retirement |
| `Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop` | The adapter: one turn's handoffs, the deadline fold, and `runVulkanOwnerLoop` |
| `Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller` | Wires both into the owner's step, its deadline, its wake and its retirements |
| `Hetoimasia.GPU.Vulkan.GLFW.Internal.Actions` | The owner-thread actions' bounded queue, their tickets and standing, admission and start against the gate, and refusal of what is left |

## Surface-free sessions and owner-thread actions

GRS-15 ([#336](https://github.com/coghex/hetoimasia/issues/336)) delivers
[D-28](designs/gpu_resource_services_design.md#d-28-the-device-can-start-without-a-window-inside-the-existing-owner):
offscreen and upload work runs without a window inside the existing
GLFW-hosted graphics owner, not a second, headless one. On Linux the host
still runs under a display — the native suite's isolated X11 display — because
GLFW's session needs one; running without a display server is out of scope.

### The setting

`vulkanDeviceStart` in `VulkanHostConfig` says when the session's one device
is created:

- **`DeviceAtFirstSurface`**, the default, is every windowed application's
  selection, unchanged: the device is selected against the first window
  surface handed over and created at its admission
  ([Admitting targets](#admitting-targets)). The triangle sample keeps it.
- **`DeviceSurfaceFree`** creates the device in the owner's startup, before any
  window and against no surface.

Either way it is the session's only device. No setting creates a second one,
and adapter preference among several compatible devices is not decided here
(the first compatible device in enumeration order is taken, as before).

### Surface-free bootstrap

The owner's startup creates the instance and its explicit messenger as
always, then — before it leases the instance to the surface bridge — the roots'
`startRootsDevice`:

1. every physical device is enumerated **with no surface-support query**
   (`opsDeviceOffers` is given no bootstrap surface, and answers every queue
   family as not presenting);
2. `selectSurfaceFreeDevice` takes the first device satisfying the whole
   profile except the presentation requirement: Vulkan 1.3,
   `dynamicRendering`, `synchronization2`, the texture table's six
   descriptor-indexing features, `VK_KHR_swapchain`,
   `VK_EXT_swapchain_maintenance1` and its `swapchainMaintenance1` feature,
   `VK_KHR_portability_subset` where advertised, and one queue family that
   answers graphics. Dropping only presentation keeps every extension and
   feature a later swapchain needs, so the device can still present once a
   surface arrives;
3. the device is created with that family's one queue, recorded in the same
   masked step, and it and its queue are named, exactly as at a first
   admission ([Names and labels](#names-and-labels)).

No satisfying device is `NoCompatibleDevice`, naming every candidate and what
each lacks — `DeviceNoGraphicsFamily` when no family answers graphics — a
structured startup failure, fatal to the owner, having created no device; the
owner's drain destroys the messenger and the instance. `readReadiness` then
answers `RootsFailed`. A session whose failure was latched before the device
could be created raises that primary instead of creating anything.

### Later admission

Once a surface-free start has created the device, every window handed over is
a later target: its surface is checked against the chosen queue family with
`vkGetPhysicalDeviceSurfaceSupportKHR`, admitted if that family presents to
it, and otherwise rolled back with `TargetSurfaceUnsupported`, destroyed on
the owner's thread, exactly as any later target is today. No second device
and no second queue is ever created (D-7).

### Zero-target progress

A session with zero targets — one that never had a window, or whose windows
have all closed — keeps making owner progress until the application ends it.
The owner offers its step every round, whatever its targets, and a round comes
when something wakes it or its own deadline does: the model's completion-poll
schedule, a released resource's disposal, an admitted owner-thread action. In
that step completion is polled when the model's schedule says a poll is due,
and every released managed resource nothing still holds is destroyed
(`reclaimReleased`). It records no frame and needs no render demand: nothing
asks a frame of a session with no target. When nothing is owed it names no
deadline and sleeps until woken; it never polls without cause.

It retires through the same protected exit as a windowed session
([Destruction order](#destruction-order)): with no target to retire,
whole-owner retirement refuses what is still queued, disposes of every managed
resource, and destroys the device, and whole-owner destruction then destroys
the messenger and the instance, keeping the primary failure, if there was
one, and the teardown evidence beside it.

### Owner-thread actions

`submitVulkanAction` hands the graphics owner a `VulkanAction`: bounded work,
run once on the owner's thread and lent the session's `Construction` — the
same one each frame's renderer is lent
([Consumer construction](#consumer-construction)) — whose result the caller
takes back from the `ActionTicket` it is given, with `readVulkanAction` or
`awaitVulkanAction`. It works with or without targets. GRS-12 extends it with
frame-less batch recording ([Frame-less batches](#frame-less-batches)).

- **Admission** is one `STM` transaction that never waits. It refuses at
  once, with the reason, when the session has failed (`ActionSessionFailed`,
  with its primary), when the owner's admission has closed — its exit has
  begun, or its run has ended (`ActionOwnerClosed`) — when no device exists
  yet (`ActionDeviceNotReady`: under `DeviceAtFirstSurface`, until the first
  window is admitted; nothing is created for it and it is never held until a
  device exists), and when the queue already holds `vulkanActionCapacity`
  actions (`ActionQueueFull`). Waiting for the outcome is the caller's
  explicit choice. Admission wakes an idle owner without any window event or
  render demand: the queue is part of the owner's wake, except while a
  diagnostic failure is pending, when the owner looks again within its poll.
- **Running.** The owner's step, after its checkpoint, runs the actions queued
  when the step began before anything else it does, one at a time; the rest of
  the step — completion polls, reclamation, frames — follows in the same round.
  So an action never runs concurrently with a frame's rendering, and what it
  releases is reclaimed by that same step when nothing holds it. An action
  admitted meanwhile waits for the next round, which its admission asks for.
- **Start and exit.** Each action is started in one transaction that asks the
  same gate admission asks: once the session has failed or the owner's
  admission has closed, a queued action is refused (`ActionRefused`) and never
  runs. A caller reading its ticket asks that gate too, and settles a queued
  action the gate refuses there and then, so quiescence — which closes the
  owner's admission before ordinary workers drain
  ([Stop and quiescence](#stop-and-quiescence)) — answers every waiting worker
  at once, without waiting for the owner. Exactly one of the two decides:
  every admitted action receives a settled outcome or a refusal. An action
  already running finishes, keeping what it borrowed until it returns.
  Whole-owner retirement refuses whatever is still queued.
- **Failure.** An action that raises answers `ActionRaised` with what it
  raised, and the owner goes on; whatever it constructed before it raised is a
  managed resource of the session, released and destroyed as the renderer's
  are. It is never run again. What the owner's run must end with is raised on
  after the ticket is settled: a cancellation of the owner; a failure setting
  the construction up — making the recording, the first time one is needed —
  which ends the run as it would a frame's; a construction whose failure
  escaped it — one that committed a generation, or that raised because the
  session latched a failure, such as the device's loss — which the
  construction records as it raises, so it ends the run however the action
  handled it, even caught and returned from, and the ticket then answers
  `ActionRaised` with it unless the action raised its own; and a failure the
  session latched meanwhile, raised as its primary as the step's own
  checkpoint raises it. None clears the terminal latch. The ticket is marked
  running, and settled, with asynchronous exceptions masked everywhere but
  inside the construction's setup and the action itself, so nothing can end
  the owner with a ticket left running.
- **Cooperation.** An action is a cooperative, finite callback. The owner does
  nothing else while it runs, so it must not wait for work that needs the same
  owner — another action's outcome, a frame, a handover — which could only
  come after it returns. `Construction` calls from any other thread are
  refused (`RefusedNotOwner`), as they are for the renderer.

The headless examples cover each case over the scripted seam — surface-free
startup and teardown order with no window, later admission and refusal, an
action on the owner's thread returning its result, the default setting's
device-not-ready refusal, the full queue's immediate refusal, a raising
action's failure and its retained resources, a construction's device loss
ending the owner — raised, or caught and returned from — a failure setting the
construction up settling its ticket before it ends the owner, refusal after terminal failure and after exit begins
(including one queued behind a running action), serialization with frames,
zero-target disposal with no target and after the last target closes, and an
idle session with no target naming no deadline until an action wakes it;
the native suite's `grs15-surface-free` and `grs15-surface-free-window` run
them against the device ([The native suite](#the-native-suite)).

## Frame-less batches

GRS-12 (#337; resource services design D-12) records batches that belong to
no frame — offscreen rendering and uploads, which later issues build on —
with their own submission and completion. The model's rules are
[gpu_model.md's](gpu_model.md#frame-less-batches).

**Recording.** Inside an owner-thread action, `constructFramelessBatch` lends
a consumer a `Recorder` for one frame-less batch and answers its
`BatchTicket`. The recorder is the frame's, with every check a frame's batch
has — the owner's thread, the handles, retention before each native call,
#335's transitions, boundary barriers and sealing rules — but no swapchain
image: every command that needs one (`transitionImage`, `beginRendering`,
`copyToReadback`) is `RefusedUnsupported` before anything native. It renders
into a managed color target instead ([Offscreen color
targets](#offscreen-color-targets)): `bindPipeline`, `setViewport` and
`setScissor` are checked against the open pass's target, and outside a pass,
with no image to check them against, are `RefusedIllegal`. The batch is recorded into the
command storage of the lowest free frame-less slot: made the first time the
slot is used — named, released and destroyed like a frame storage — and reused
by later batches of the slot only after its batch was discarded or its
submission's completion observed, its pool reset first. A renderer's frame
records no frame-less batch: the construction it is lent refuses one.

**Submission order.** When the action returns, its sealed frame-less batches
are submitted in the order they were sealed, each as a `vkQueueSubmit2` of its
own on the one graphics queue, with no wait and no signal but its slot's
fence — before anything else the owner submits after the action, so before
any later frame's submission. One the queue accepted stays accepted whatever
follows. The first that is refused, or fails with no effect after its one
reclamation and retry (VK-14), is discarded with every batch sealed after it;
one whose effect is unknown fails the session with
`FramelessEffectUncertain`, retaining what it held, and the rest are
discarded. A batch left partial is never submitted and is discarded, as only a
discard ends one. An action that raised, or was cancelled, submits nothing and
discards every batch it opened; a discard whose storage reset raised keeps the
batch, its references and its slot, uncertain, fails the session, and the
action's own failure is still the one raised. The device's loss is asked again
before each discard: once lost, every batch left is let go of under the
device-loss rule instead, its ticket lost, with no native call.

**Tickets.** A `BatchTicket` names one batch, whatever slot or storage later
serves another. `readTicket` reads it from any thread without a native call:
`TicketPending` until its submission's fence has been observed signalled and
recorded with the model, then `TicketComplete`; `TicketDiscarded` once its
batch was discarded; `TicketLost` if the device was lost while it was pending.
Once terminal it never changes, after the slot's reuse and the session's end
alike. `awaitTicket` waits for a terminal state at most the given duration and
answers the state then; its expiry, or its cancellation, discards nothing,
releases nothing and completes nothing. It is refused on the graphics owner's
thread (`RefusedOwnerWait`), whose own return and progress the batch needs.

**Progress.** The owner observes frame-less fences in its bounded progress
step, among its other work and on the same rotation, so one that has not
signalled never holds back another — in windowed and zero-target sessions
alike, since a pending submission is owed work the model's poll schedule
counts. A signalled fence is recorded as the submission's completion, which
discharges its holds and frees its slot, and completes its ticket. A fence
whose query raised without losing the device is uncertain: the session fails,
the fence is never asked again, and the submission is kept with its ticket
pending — retaining it and the device, and letting a later loss report it
lost. A slot's fence is made at its first submission; one whose creation ran
out of memory is recovered once, as a frame slot's are (VK-14), and one that
is not recovered discards the batch without recording it again. Once made,
the fence is named `frame-less slot <s> submission fence` when the device
offers naming, before it is recorded and never again, and a naming that raised
destroys it once: when that returns nothing is recorded and the rollback fails
nothing itself — a loss the naming reported stays latched — the naming failure
is raised, and the slot's next submission makes and names a new fence while
the session runs; when that destruction raised too, the fence is kept,
uncertain, and never passed to another native call, under the device-loss rule
too, the session fails with `CleanupFailed`, and the destruction is retained
beside the naming failure under the `vulkan frame synchronization rollback`
label.

**Device loss and retirement.** After the device's loss no fence is asked or
waited on: the device-loss release lets go of every frame-less submission,
completing none and settling each pending ticket as lost, and forgets every
unsubmitted frame-less batch with no native call, discarding it in the model.
At whole-owner retirement the owner waits, in the frames' finite drain steps
and for at most a hundred of them, for each outstanding frame-less
submission's fence, then destroys the frame-less fences. One still outstanding
without device-loss evidence is retained (`FramelessRetained`), and so is the
device: nothing is certified complete to finish the teardown.

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| A frame-less slot's command storage | The recording's managed records and storages (`State`) | `Recorder`'s frame-less recording makes it through `Construction`, resets it before reuse through `Batches`; `Disposal` destroys it | The graphics owner | Its slot's first batch until the owner retires the recording | Destroyed once released and no batch holds it; kept, uncertain, if its reset or destruction raised |
| A frame-less slot's fence | The frames (`Frames.State`) | `Frameless` makes it at its slot's first submission, resets it before each later one and destroys it at retirement; `Progress` and `Loss` advance it | The graphics owner | Its slot's first submission until the owner retires | Destroyed by `retireFrameless` once idle, or under the device-loss rule; kept, uncertain, otherwise |
| A frame-less submission's record | The frames (`Frames.State`) | `Frameless` inserts it; `Progress` removes it on its fence's signal, `Loss` on the device's loss | The graphics owner | The submission until its completion is observed or the device is lost | Removed with its ticket settled |
| A ticket's state | The ticket (a `TVar` in `Recording.State`) | The recording settles it on a discard, the frames on a completion or the device's loss; any thread reads it | Any, in STM | From the batch's opening for as long as the caller keeps the ticket | Only ever leaves pending, once |
| An action's frame-less scope | `Frameless`'s `withFramelessScope` | The action's recording notes each batch it opens and seals; the scope submits and discards them when the action ends | The graphics owner | One owner-thread action | Ends with the action |

The headless examples cover each case over the stand-in native layers — seal
order before a later frame, swapchain commands refused, a partial batch
discarded, an action raising after sealing, an accepted prefix kept when a
later submission fails with no effect or an unknown effect, slot reuse only
after completion or discard, a discard whose reset raised, tickets completed
only on fence evidence, lost on device loss and waited for with a deadline,
a ready submission observed behind one that has not signalled,
initialization, and retirement — and the integration examples record
frame-less batches inside owner-thread actions of a zero-target session; the
native suite's `grs12-frameless` runs them against the device
([The native suite](#the-native-suite)).

## Destruction order

| Exit | What is destroyed, in order, on the owner's thread |
| --- | --- |
| A window closed or a target released | That target's swapchain generations — each one's image views, newest first, then its swapchain — and then its surface. The owner writes its terminal record only after the destructions returned, and the main thread then certifies the attachment's facts and releases the window. The device, the instance, the owner and every other target stay live, and nothing is joined. A generation still held retains the surface, and with it everything above. |
| Whole-host exit (D-33), with or without targets | Every remaining target's surface, if any remains; then — whole-owner retirement — every surface the lease still owes that no target held (an attachment whose announcement never reached the owner), every owner-thread action still queued is refused, every frame-less submission still outstanding is waited for in the frames' finite drain steps and then every frame-less slot's fence destroyed (GRS-12), every managed resource the recording still holds — the consumer's pipelines before their layouts, whether its renderer or an owner-thread action built them, and any capture's readback buffer, each once no batch holds it (VK-19) — then the device's allocator, once no allocation made from it remains, and the device; then — whole-owner destruction — any surface a creation still in its native call left, the explicit messenger, and the instance, the last call that can reach the capture's callback. Only after that evidence is the owner joined, and only then are windows, the session and the capability released. |

Each step is refused rather than reordered when something that must go first
has not verifiably gone. A destruction that raised is uncertain: it is recorded,
never attempted again, and it retains every parent above it. Running a
destruction and recording what it did are one masked step, so a destruction
that returned always removes its record and one that raised — synchronously or
with a cancellation of its own — always leaves it marked uncertain; a
cancellation is re-raised only after that record exists. The failures are
`SurfaceDestructionFailed`, `RootDestructionFailed` and `RootsRetained`, which
name what was retained — `AllocationsRemain` and `AllocatorRemains` among them,
for an allocator that still holds an allocation or whose destruction was
uncertain, either of which retains the device. The owner then produces no evidence for what is retained, so the host
keeps the window, the session and every parent, as VK-18's contract requires;
only independent evidence ends that wait. The instance is destroyed only once
the surface bridge's lease is releasable. No timeout, cancellation or cleanup
failure is permission (D-33, LIFE D-4).

## Terminal failure

VK-15 ([#231](https://github.com/coghex/hetoimasia/issues/231)) is the
session's terminal failure and the teardown that follows it: D-17's device
loss, D-19's and P-11's sink failure, D-20's validation error, D-22's required
target, and D-33's all-exit drain, over P-2's ownership table and P-5's
dependency order, with P-14's rule that a target's designation never supplies
missing safety evidence.

### The latch

The roots keep one terminal latch. Its first failure, from any of these
sources, is the session's **primary**:

| Source | Latched | As |
| --- | --- | --- |
| A queue or device call answered `VK_ERROR_DEVICE_LOST` | By the call's own guard, before the failure propagates | `TerminalDeviceLost`, naming the call |
| An error-severity validation report | At the next checkpoint, which asks the capture's error latch — set before the report's detail is admitted, whatever the queue, the logger's filter or the sink did | `TerminalValidationError` |
| The diagnostic sink failed | At the next checkpoint, which asks `captureAlarms` | `TerminalSinkFailed`, a terminal status of its own |
| A native effect whose outcome is unknown | By the step that observed it: a submission, a presentation, a bookkeeping refusal | `TerminalUncertainEffect` |
| A cleanup that raised | By the destruction or cleanup that raised: a surface — one created while the lease closed included — a root, a generation, a frame's cleanup submission or release, a slot's or pool record's objects, a managed resource | `TerminalCleanupFailed` |
| A required target's recovery exhausted | The model escalates it; the next checkpoint, or any read of the latch, takes it | `TerminalRequiredTarget` |

Latching the primary is one transaction: it closes the roots' admission and
fails the model's session with the matching cause (`DiagnosticSinkFailed` for
a sink). Every cleanup failure is latched with its subject and what raised —
the surface, root, generation, frame, slot, pool record, batch or resource —
so several failures of one pass are each accounted for rather than collapsed
into one. The controller's surface discharges — an unannounced or rejected
attachment's, a retired target's remaining ones, the orphans the owner's
retirement finds and the late ones its destruction finds — latch each
destruction that raised by its surface's handle and attachment. A later pass
that finds the same obligation still owed is refused by the bridge as
`DischargeStillUncertain`, which is not latched again; what is recognised is
the obligation's own identity, never the handle, which a later surface may
reuse. A failure after it never displaces it: it joins the latch's evidence
as `LaterFailure`, oldest first, the first 64 kept and the rest counted. A
failure the model recorded by itself before anything was latched is the primary
it stands for, and one that describes the same failure as the model's cause —
an uncertain submission the model recorded and the step that says what it was —
is one failure, with the step's detail.

The first failure is first by one ordering point shared by every source: the
diagnostic capture's first-failure cell. An error report claims it with a
compare-and-swap before it sets the error latch, and the capture's worker
claims it for its sink before it publishes the failure; a failure of the
owner's own claims it too (`claimCaptureOrder`), inside the transaction that
records it, wherever it comes from — a native call that answered the device's
loss, a cleanup that failed, an effect whose outcome is unknown, and any
transition the model makes that fails a running session by itself, such as a
required target's exhausted recovery (`stateRootsModel` checks every transition
for that before committing it, and only the owner changes the model). When a
validation error or sink failure claimed the cell first, it is latched in that
same transaction ahead of the owner's failure, which joins the evidence; a
transition that would have failed the session is taken on the failed session
instead, so a required target's recovery goes no further. A sink failure whose
reason its worker has not yet published is waited for inside the transaction,
which never blocks: a `retry` there would make the transaction interruptible
even under `mask_`. The worker publishes right after its claim, in one masked
step that calls nothing native, delivers nothing to the sink and waits on
nothing, so the wait depends on that thread's CPU bookkeeping alone — never on
a driver, the sink or the owner — and it promises no wall-clock bound. Nothing
in it is interruptible and it masks nothing of its own: a masked record cannot
be cancelled there, and an unmasked one can, as anywhere else in its
transaction. The claim answers the same however often a transaction runs it.

A claim holds first place only for the transaction attempt that made it, and
it is a compare-and-swap in C that an abandoned attempt does not undo. Each
claiming attempt therefore enters a token in the roots, held there only
weakly, and writes it into its own transaction log: the attempt keeps it alive
while it may still commit, and once GHC discards an abandoned attempt — rolled
back by an exception, or run again — a collection finds the token gone,
whatever the claiming thread goes on to do. Between the owner's claim and the
commit of the transaction that records its failure, a checkpoint on another
thread — a handover's, say — sees the claim (`CaptureOwnerClaimed`,
`AlarmOwnerClaimed`) with nothing latched and its attempt's token alive, and
answers `CheckpointPending`, latching nothing, so a later diagnostic failure
cannot take the owner's place. A claim no live attempt holds is void: the
checkpoint latches the alarms beside it as usual, so an abandoned transaction
leaves no checkpoint pending and no settled checkpoint waiting. It runs a major
collection to tell, and only while nothing is latched, a claim is visible and
some token still answers.

A diagnostic failure that arrives behind a claim loses its own claim, so the
capture also records each one's arrival before it tries to claim, and which
arrived first (`hetoimasia_capture_arrived_failures`). It answers those behind
an owner's claim in the order they arrived, and one whose alarm is not yet
readable as `CaptureAlarmPending` beside the claim. A checkpoint therefore
answers pending, never clear, while a sink failure behind a void claim is
unpublished. A later failure of the owner's own, whose claim the void one still
answers first, takes the capture's arrivals, read right after its claim
(`captureArrivals`, carried in `OwnerFirst`), as its order point: each
diagnostic failure that had arrived by then is latched ahead of it once
readable, in the order they arrived — a wait bounded as the sink's publication
is — and one that arrives
after comes after it, as it would behind a claim of its own.

Every record of a failure of the owner's own made inside a masked step — an
uncertain or failed presentation, an uncertain submission, a progress step's
fence answer, a device loss — is therefore made whole or not started, whatever
cancellation is aimed at the owner: its transaction never blocks, so the
cancellation arrives after it. A device loss is latched with exceptions masked
from the moment its call returns (`rootsCall`), and a progress step asks each
fence and records its answer in one masked step.

Roots given only a list
of alarms (`watchRootsDiagnostics`, as headless examples use) latch them at
checkpoints and order nothing; the controller installs the capture's order
(`watchRootsDiagnosticsOrdered`). The
device's loss is also kept apart
from the primary (`reportDeviceLost`), whenever it is observed: a session that
a validation error failed first and whose teardown then meets the loss keeps
the validation error as its primary and switches that teardown to the
device-loss rules. The model records the loss the same way, with `noteDeviceLoss`,
beside its first cause. `readVulkanTerminal` reads the whole latch from any
thread.

### Checkpoints and refusals

A checkpoint asks the capture for its alarms — the controller installs
`captureAlarms`, the capture's error latch and sink failure, as the roots'
diagnostic watch — latches them in the order they happened, and answers the
primary. The capture's C callback and its worker claim one first-failure cell
with a compare-and-swap before either sets its own latch, so a sink failure
followed by a validation error before the next checkpoint stays the primary
with the error beside it, and the other way round, whichever thread got there
first. A checkpoint that looks after the first failure claimed the cell but
before it set its own alarm is told only that a failure is pending
(`CaptureAlarmPending`, `AlarmPending`): it answers `CheckpointPending`,
latches nothing — neither the capture's alarms nor a failure the model recorded
by itself, which might otherwise be taken ahead of the diagnostic failure that
came first — and refuses new work, so the next checkpoint latches them in order
and admission never reopens in between. It raises nothing, calls nothing native
and waits for nothing. The owner's ordinary operations pass through one:

- the controller's progress step raises the primary — the loss as
  `GraphicsDeviceLost`, anything else as `GraphicsSessionFailed` — which ends
  the owner's run: the owner machinery latches it, closes its admission, and
  `superviseGraphicsOwner` raises it at the application's checkpoint while
  retirement is still running; while a failure is pending it does nothing new
  that round and asks for another within the controller's poll;
- `recordFrame`, `tryAcquireFrame`, `submitFrames` and `presentFrame` refuse
  with `RefusedSessionFailed` naming the primary before anything native, or
  with `RefusedDiagnosticPending` while a failure is pending;
- `handOverVulkanTarget` answers `VulkanSessionFailed` naming the primary, or
  `VulkanDiagnosticPending` while a failure is pending, and attaches nothing;
- the owner's construction of a handed-over target, which a round runs before
  its step, checks again (`checkpointRootsSettled`: it latches what the
  capture holds, waiting out a pending alarm) before anything native, and
  rejects with `RejectedSessionFailed` a target whose session failed after its
  handover; it checks once more when admission's native calls return, and a
  target a layer reported against during them is answered as a partial
  construction, which the owner owns and retires, never as a usable one.

Retirement never passes through one. Closing and skipping frames, the
progress step's observations, the finite drain wait, and every target's,
generation's, root's and the owner's retirement keep running, because they run
precisely because the session has failed. A validation error a layer reports
from inside one of the owner's own calls is seen at that round's step. A sink
failure arrives on the diagnostic worker's thread, so the controller asks the
owner to wake for it (`graphicsWake`) while it is published and not yet
latched: an owner with no round due takes one at once, and its step latches
the failure.

### The call that observed the failure

The native effect a failing call had is recorded in the same masked step as
the call, before anything propagates, even when the call's own device loss
failed the session in between: an acquisition that raised gives its reservation
back, a submission that raised is recorded as an uncertain effect — the model
records a failed call's outcome whenever it happened, and refuses only new
work — a presentation that raised keeps what the swapchain's `pResults` entry
says it enqueued, and a presentation or submission that returned keeps its
obligations. The loss is what the caller sees first: a presentation whose call
raised the loss while its entry answered out of date or surface lost is
recorded as enqueued, and then the loss is raised.

### Teardown after device loss

Once the loss is recorded, the specification's device-loss rule governs what
the lost device could have discharged — its objects may be destroyed without
waiting for work that may never complete — and nothing else:

- no fence is asked or waited on again: `progressFrames` makes no call, and a
  step whose own query lost the device asks nothing further; `awaitFrames`
  waits for nothing;
- a skipped frame makes no cleanup submission (`StageLost`), and no storage is
  reset against the lost device: the unsubmitted recording's commands can
  never execute, so its batch records go with the model's skip — one an
  earlier reset left uncertain included — and the storage's destruction frees
  them;
- `releaseFramesToDeviceLoss` skips every frame still acquired, then has the
  model release every submission, certain or uncertain, every enqueued
  presentation, and every frame that had left acquisition
  (`releaseToDeviceLoss`): their holds end, their pool records are free, each
  pending fence becomes `FenceLost` and each owed semaphore `SemaphoreLost`.
  None of it is recorded as completed or retired, no fence is marked signalled,
  and no recovery cycle is credited;
- `retireTargetFrames` releases first, then destroys every slot's and pool
  record's objects whatever they were owed — except one whose destruction
  already raised, which may already be gone and is destroyed under no rule;
- the target's generations, whose holds the release ended, then its surface,
  the device (`"… after its loss"`), the messenger and the instance go child
  before parent. Nothing waits for the device to go idle, and nothing is
  recreated or replayed.

A fence wait, a status query or a device wait that answers the loss during
teardown latches it — as the primary, or beside an earlier one — and settles
nothing. Before any loss the release is refused: the frames answer
`RefusedIllegal` and the model `WrongPhase` of the device.

### Teardown under the ordinary rules

After a validation error, a sink failure, a required target's exhaustion, an
uncertain effect or a failed cleanup, obligations settle on their own evidence,
as VK-12 and VK-13 settle them, within the drain's finite waits. What cannot be
verified is retained: an uncertain effect keeps its frame, and with it its
generation, surface, device and instance (`FramesRetained`,
`GenerationsRetained`, `TargetGenerationsRemain`, `RootsRetained`); a
destruction that raised is never attempted again. A gap in the proof's
destruction evidence for a path blocks that path's release rather than
authorizing it.

### Evidence and retention

The primary is never displaced. Cleanup failures and later failures join the
latch's evidence beside it. Validation errors delivered during teardown —
inside `vkDestroyInstance` too — join the capture's verdict, which follows the
last callback: retirement asks the latch nothing, so they reach the final
report through the verdict rather than the latch. A sink failure never
authorizes a release.

Every retirement the controller runs that could not verify what it owns records
what it retained in the latch (`RetainedUnverified`) before its failure goes to
the owner, which keeps its evidence and manufactures no acknowledgement. The
host then keeps the window, the session and every parent, and waits for
independent evidence; process termination is the escape, and it is never
orderly cleanup. Cancellation during the drain, once or repeatedly, follows
VK-18's D-33 order and releases nothing early.

## State

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| Each root's slot (instance, messenger, device, allocator) | The roots | Written by startup, admission and retirement; any thread reads | The owner | The session | Only advances: absent, live, then destroyed or uncertain |
| Live allocations | The roots | The allocation protocol counts each allocation made and freed; retirement reads | The owner | The session | Counts down as each is freed; the allocator is destroyed only at zero ([Device memory](#state)) |
| Target records | The roots | Admission inserts, retirement removes; recovery releases a lost surface and installs its replacement in place | The owner | Admission until destroyed | Removed only by a destruction that returned; a surface released by recovery leaves the record with none until a replacement is installed |
| Disposers | The roots | The generations and the recording each register one when made; a reclamation pass reads them | The owner | The session | Never removed |
| The GPU model | The roots | Admission, retirement, loss | The owner | The session | Never reset |
| The loss latch | The roots | Set once; any thread reads | Any | The session | Never cleared |
| The terminal latch | The roots | `latchTerminal` sets the primary once and appends evidence; any thread reads through `readRootsTerminal` | Any, in `STM` | The session | Never cleared; evidence bounded at 64 with the rest counted |
| The diagnostic watch | The roots | Installed once by the controller; read by every checkpoint | The owner | The session | — |
| The requested extensions | The controller | Written once by the session's entry | Main | The host | — |
| The lease | The controller | Written by startup; read by handovers | Owner, main | Startup until destruction | Released before the instance is destroyed |
| Deposits | The controller | Written by a construction step; taken by the owner's construction or retirement | Main, owner | Attachment until its construction or retirement | Cleared by whole-owner retirement |
| Attachment to target | The controller | The owner alone | The owner | Admission until the target's surface is destroyed | Kept on an uncertain destruction |
| Rejections | The controller | Written by the owner; any thread reads | Owner | The most recent 64 | Oldest dropped |
| Replacements | The controller | The owner's step asks; `replaceVulkanSurfaces` on the main thread claims, creates and deposits; the owner's step, or the attachment's retirement, takes each | Owner, main | From an admitted attempt's request until its deposit is settled | Taken by the attachment's retirement, which waits for one being created |
| Unavailability reports | The controller | Written by the owner's step; any thread reads | Owner | The most recent 64 | Oldest dropped |
| Generation records | The generations' `Internal.Generations.State`, which defines them | `Reconciliation` builds and replaces, `Retirement` retires the active one, and `Disposal` destroys and removes, on the owner's step; any thread holds and ends a CPU use through `Uses`, in `STM` | The owner (uses: any) | From the construction that begins one until its destruction returned | Kept, explicitly uncertain, when a destruction raised; never retried |
| Swapchain results | The generations' `Internal.Generations.State`, which defines them | The owner reports through `Uses`; `Reconciliation` consumes on its step | The owner | Until the active generation is replaced | Cleared by the publication that replaces it, or by the surface's loss |
| A target's lost surface and outstanding attempt | The generations' `Internal.Generations.State`, which defines them | `Reconciliation` marks the loss; `Surface` releases, asks and installs; `Retirement` settles an attempt still outstanding | The owner | From the loss until a replacement is installed, or the target retires | Cleared by the installation, or by retirement |
| Rendering: the recording and the frames | The controller's rendering | Made by the first frame attempted, or the first owner-thread action run, once the device exists; read by every step and retirement | The owner | From then until whole-owner retirement | Retired before the device is destroyed |
| Rendering: the construction's escape record | The controller's rendering | The first failure a construction raised that must end the owner's run, set as it raises; read by the owner-thread action's runner on both its return and raise paths | The owner | The owner's run | Cleared each time the construction is lent to an action |
| Owner-thread action queue | The controller's `Internal.Actions` | Any thread admits in `STM`; the owner's step takes and removes | Any, in `STM` | The session | Each entry removed when the owner takes it; emptied by whole-owner retirement, which refuses what is left |
| An owner-thread action's standing | The controller's `Internal.Actions` | The owner starts and settles it; a reader of its ticket settles one the gate now refuses | Any, in `STM` | From admission until its reader drops the ticket | Only advances: queued, running, settled |
| The owner's open admission, as actions read it | The controller | Installed once by the composition with the owner's own port state; read by every action's admission and start | Any, in `STM` | The host | Closes with the owner's publications, never reopened |
| The device start | The controller | Configured; read by the owner's startup | The owner | The host | — |
| Rendering: per-target records (frame storages, acquisition retry, last generation shown, eligibility, closing) | The controller's rendering | The owner's step, retirement readiness and retirement | The owner | From a target's first render request until its retirement | Removed by the target's retirement |
| Rendering: the demand and scene revisions acted on, and a demand deadline ahead | The controller's rendering | The owner's step | The owner | The owner's run | Only rise |
| Observations reconciled | The controller | The owner's step: each target's observation revision and eligibility the generations were last stepped with | The owner | The owner's run | Replaced every step that reconciles |
| The adapter's published revisions and untaken demand | `runVulkanOwnerLoop` | The main thread, every turn | Main | The loop's run | Bounded by the windows the host holds; untaken demand forgotten once the owner took it |
| Deferred attachments | The controller | Written by a handover whose announcement the port refused; removed by `announceVulkanTarget` once admitted, or by the owner once it has destroyed the surface | Main, owner | Until announced or settled | Cleared by whole-owner retirement |
| Managed records | The recording | Construction inserts; release, replacement and disposal advance each one's standing | The owner | From construction until the model records the disposal | Removed once the model records it; kept, explicitly uncertain, when a destruction raised; never retried |
| Frame storages | The recording | Construction inserts one per target frame slot; disposal removes it | The owner | As its managed record | As its managed record |
| Batch records | The recording | `recordFrame` inserts; a discard or reset removes one after the invalidation returned | The owner | From admission until invalidated | Kept, explicitly uncertain, when an invalidation raised; never retried |
| The shared ring and its regions | The recording | `createRing` makes it; a recorder's claims add regions and reclaim completed batches'; a dropped batch's go with its record | The owner | From `createRing` until its buffer's disposal; each region until its batch completes or is invalidated | Released at retirement with every live generation; regions never reissued, kept through an invalidation that raised |
| A recorder | Its `recordFrame` | The consumer action | The owner | One consumer action | Closed when the action returns or raises |
| Slot synchronization | The frames | `Acquisition` creates a slot's three objects and marks its acquisition; `Submission`, `Abandonment` and `Progress` advance each object's state; `Loss` marks what was owed lost; `Progress` destroys them | The owner | From the slot's first reservation until the target's frames retire | Destroyed once idle, or after the device's loss whatever they were owed; kept, explicitly uncertain, when a call on them raised, and never destroyed again once a destruction raised |
| Presentation pool | The frames | `Acquisition` creates a record and binds it to a frame; `Submission`, `Presentation`, `Abandonment` and `Progress` advance its semaphore and fence; `Presentation` rebinds it to its presentation; `Loss` frees what the loss released; `Progress` frees and destroys it | The owner | From the first reservation that needs it until the target's frames retire | Freed by the retirement or settlement the model recorded, or by the device-loss release; destroyed once free and idle; kept, explicitly uncertain, when a call on it raised |
| Frame records | The frames | `Acquisition` inserts; `Submission`, `Abandonment` and `Progress` advance; `Presentation` removes on presentation and `Progress` on settlement | The owner | From acquisition until presented or until the model records the settlement | Kept, failed or uncertain, when a cleanup, a presentation or its bookkeeping did not complete |
| Submission records | The frames | `Submission` inserts; `Progress` removes once the fence signalled | The owner | From the native submission until its fence signalled | Removed with the model's completion fact |
| Presentation records | The frames | `Presentation` inserts; `Progress` removes once the present fence signalled | The owner | From the enqueued presentation until its present fence signalled | Removed with the model's retirement fact; kept, uncertain, when asking the fence raised |

## Evidence

**Headless.** The group `test.vulkan-headless` builds and runs, through
`bash tools/vulkan/run.sh test`, the native backend's shader contract
(`shader-tests`) and:

- `hetoimasia-gpu-vulkan-native:native-tests` — the profile's decisions, and the
  roots over a stand-in native layer: rollback of exactly what exists at every
  failing creation step, the structured no-device failure, a cancellation at a
  creation's handoff, targets keyed by model identity with their designations,
  the incompatible-target rejection with no second device, the bootstrap
  target owning nothing, the full destruction order, every refused step behind
  an uncertain destruction without a retry — including a destruction that
  raised outright and one a cancellation ended part-way — device loss closing
  admission with the model failed while an unknown outcome is neither loss nor
  success, and synchronization validation planned only through an enabled
  layer that offers it; the presentation profile and D-30's extent as pure
  decisions — concrete against application-chosen extents, zero area checked
  before clamping, eligibility first, no invented geometry, every gap of an
  unsupported surface named, no transfer usage required and no UNORM fallback,
  image counts within the surface's limits and the tracking limit; and the
  swapchain generations over the stand-in: construction from the surface's
  extent and format, a stale observation, zero area suspending without an
  attempt, a resize coalesced for 16 ms from its first move and built from the
  newest geometry, a resize that never pauses rebuilt once a period, a move the
  surface has not caught up with yet, a cancelled move not shortening a later
  one's period, a newer observation joining the move at an unchanged surface
  extent, a newer resize built from the newest extent under the one-generation
  limit once there is room, capacity retiring and destroying first
  and keeping the active generation presenting otherwise, the one-generation configuration, per-target
  reservation isolation, an oversized and a zero returned image count refused
  before any view, a failed replacement unable to reacquire from or hand over
  the retired handle, a newer resize surviving an in-flight replacement,
  repeated out-of-date and suboptimal results bounded by the recovery episode
  without a hot loop, a reported result asking for a step at once until it is
  reconciled, a closing target's settling replacement and unseen result owing
  no step, its deadline left to the model's own schedule, a moved observation and a resize after a failed construction
  each settling before the recovery rebuild, and a move cancelled while
  recovery waits leaving a later move its full period, failures after the swapchain destroying exactly what they
  left child before parent, a failed cleanup retained without a retry and
  retaining the surface, a replacement cancelled before its creation never
  handing the old swapchain over, a cancellation right after a candidate's
  admission
  and one at a creation's handoff, one
  interrupting a swapchain's or a view's creation inside the call, and one
  ending a destruction part-way, device loss, and close winning over retry and
  publication;
- `hetoimasia-gpu-vulkan-glfw:integration-tests` — whole graphics hosts over the
  GLFW package's scripted seam, driven through the real owner machinery and
  controller with a stand-in native layer and surface bridge, journalling every
  native call with its thread: thread placement, the shared device, readiness,
  incompatible, unusable and failed surfaces, a full owner port — a deferred
  attachment released and its surface destroyed by the owner while the host
  runs, one announced again and admitted, one whose destruction failed
  reported at a checkpoint without a retry, and one whose answer a cancellation
  lost after publication, recovered into the same watch, and one refused while
  the owner drains its port and goes idle before the handover answers — rollback at every startup and
  bootstrap step, a cancellation during the handoff's surface creation,
  repeated cancellation during the exit, a first window's close, an individual
  release, the exit order with the owner joined before any window goes, a
  destruction still pending certifying nothing, and device loss reaching a
  checkpoint while retirement is pending, staying primary over a failed
  cleanup that is retained without a retry; and swapchain generations built on
  the owner's thread from the geometry the owner folded, replaced after a resize
  with the old one handed over and destroyed only once its hold ended, none for a
  hidden target, and a closing window's views and swapchain destroyed before its
  surface;
- `hetoimasia-sample-triangle:triangle-tests` — the triangle sample's pipeline
  cache over stand-in builders: a format's layout built once and handed to
  every attempt while its pipeline is refused, each refusal answered as it
  was, the built pipeline reused for every later frame of its format, nothing
  held after a refused layout, and one layout and one pipeline per color format.

Every `integration-tests` example runs under a fixture-aware bound
(`Test.GPU.Vulkan.GLFW.Bound`): a minute, or thirty seconds for those under
`Vulkan controller`, for the whole example rather than for each rig run. A
plain timeout cannot end a rig example: `runRig` runs its body on a bound thread
through `runInBoundThread`, so an exception for the example's own thread waits
for the whole run, and the owner's protected exit absorbs cancellation until it
has destruction evidence that a scripted rig withholds. On expiry the bound
starts a cleanup watchdog first, then rescues every rig the example made — from
then on every fence answers signalled, every scripted hold already entered or
entered later passes, no call is slowed, no frame refused and no event pump
held, and every wait the owner arms on a scripted clock comes due at once and
moves the clock to its deadline; an irreversible scripted failure stays, and
nothing publishes destruction evidence the stand-ins did not produce — and only
then cancels each rig run's bound thread and the example's own, and waits for
the example to settle: its own thread, every rig run it started, and every
cancellation's delivery. The owner's protected exit completes on the stand-ins' real destruction evidence, and the
example fails as not having finished within its bound, even if it caught the
cancellation. A synchronous failure, or that cancellation, escaping a rig's
body rescues the rig before the protected teardown begins, so an example that
fails before it releases its gates reports its own failure. The last resort: if
the example has not settled ten seconds after rescue began, the suite
prints the example's name on standard error and ends the test process with a
failure status, unwinding nothing — operator termination is the protected
exit's documented escape. The production teardown is unchanged; all of this is
the fixture's. `the fixture-aware example bound` covers a blocked example, one
that fails before releasing its gates, a hold the owner had already entered,
the last resort — also while a rig run on a thread of the example's own outlives
the example's thread — and a timer hook replaced while an earlier one runs,
with bounds and a grace that expire only when the example says, and finds no
thread of the example still running afterwards.

VK-19's examples are in `integration-tests`, under `Vulkan consumer rendering
and capture`, over the same stand-ins, extended to journal every command the
recording layer is asked to record and every pipeline, layout and readback
buffer it makes and destroys, to report each swapchain's image usage and
whether it was created clipped, to offer a surface usage the example chooses,
to raise once from a chosen creation, to offer naming that raises for a chosen
kind of object, and to read every readback buffer back as
one known byte. They cover: each frame's format and extent reaching the
consumer, and its own layout and pipeline — built on the owner's thread for
that format — bound and drawn between the controller's transitions inside the
rendering it began; construction and release from the main thread refused
`RefusedNotOwner` with nothing native done; a pipeline built for another format
refused at its binding, with no bind recorded and nothing presented; a refused
construction and one that raised having created nothing each skipping one frame,
the renderer called once per acquired frame, the third frame presenting and the
session running; a construction that lost the device failing the session with
the loss primary and never reaching the renderer as a refusal; a replacement
whose new pipeline could not be named, on a device offering naming, after the
new generation was committed ending the owner's run with that failure — the
renderer never answered, both pipelines still destroyed before the device; a replaced
pipeline kept while the batch that bound it is in flight and destroyed only on
its completion, the new one and the layout still standing; the consumer's
pipeline destroyed before its layout, and both before the device, on the normal
exit with a clean verdict and on a validation-error exit with that error
primary; a host without capture building clipped swapchains with no
transfer-source usage when the surface offers it, and refusing a request
`CaptureDisabled`; a capturing host building them unclipped as transfer
sources; a capture, asked for with nothing else published, whose frame's batch
ends with the transfer-source transition, the copy, the host-read barrier and
the transition to presentation, withheld while its fence answers not yet over
further polls, delivered once after completion with its frame's identities and
the whole image's bytes, and never again, its readback buffer destroyed before
the device; a captured frame the renderer refused settled
`WithheldFrameAbandoned` with no copy recorded and its buffer destroyed; a
surface offering no transfer-source usage admitted, its frame presented and its
capture settled `WithheldUnsupported` with no buffer made; a capture whose frame
could never be acquired settled `WithheldTargetRetired` when its window closed;
a request refused `CaptureTargetRetiring` once its target's retirement had
begun, while that retirement was still owed and its surface stood, with the
request it already had settled `WithheldTargetRetired` and a later one refused
`CaptureNoTarget`; sixty-four requests admitted and settled without being
taken, the sixty-fifth refused `CaptureBacklogFull`, every one of the
sixty-four still there to take, and a request admitted again once they were;
a request made from inside the frame observer's report of an acquisition
captured from a later acquisition, never the one reported; a request admitted
while an acquisition was held inside the native call captured from a later
acquisition, never the one under way;
and a presented capture whose batch completed only after a validation error
ended the owner's run settled `WithheldSessionEnded` with that primary, and
taken once.

VK-16's examples are in `integration-tests`, under `Vulkan loop adapter`, over
stand-in frame and recording layers — every swapchain three images, a
submission's fence and a present fence pending until asked and then signalled
if the example allows it, a present fence's image given back when it signals —
and, where a schedule is asserted, a scripted clock the host and the owner
share, whose owner timer expires once the clock reaches the deadline the owner
gave it. They cover: the adapter publishing each window's observation and
captured demand with nothing published by hand, and the owner presenting a
frame of its own; the owner's deadline folded into the main loop's schedule —
`NoUpdateDemand` and a later `UpdateBy` become it, an earlier one and
`UpdateImmediately` stay, one already passed is left out — and the composed
loop then waiting for it rather than for a five-second fallback; demand
captured before the owner took it kept across a newer publication while the
owner's step was held inside an acquisition, and a window closed meanwhile
still retiring; two windows' demand captured in one turn — one now, one by a
later deadline — served as two frames now, none while a still clock stays short
of the deadline, and two more once it comes; a redraw the owner took while no
target was constructed rendered once the window handed over afterwards is,
with nothing published since; a quiet scene rendered continuously never arming the owner's
timer beyond the first pending-work interval; the backoff through 5, 10, 20,
40, 80, 100 and 100 ms from a presentation, an unrelated publication a
millisecond before a poll moving neither the fence queries nor the deadline,
and new demand, an observed completion and a close each restarting it at 5 ms;
no fence asked on an unrelated early wake, and a poll whose work consumed the
next interval followed by the next poll with no timer armed between them; the
clock reaching the owner's published deadline inside its timer's arming, after
the owner read the clock, and the owner still waking at that deadline to poll,
and the same window in the exit drain's wait, the drain still waking and
arming again — examples that fail with a timer that measures its interval from
a reading of its own (#386); a
suspended target keeping a finite deadline with its presentation pending, not
spinning while the clock stands still, and polling when it comes; one target
presenting five more frames while another's acquisitions all answer not ready;
a window hidden while the owner's presentation to it holds, as Mesa's legacy
FIFO present does, whose hide makes its native call only once that
presentation returns, the other target presenting three frames and the hidden
one none, its old swapchain kept while its presentations are unretired, and
the shown window presenting on a replacement handed that swapchain and never on
the old one — an example that fails with the hold or the replacement removed
(#357); a window whose target is already suspended hidden again while the other
target's presentation holds, whose hide makes its native call without waiting
for that step; the same presentation hold with the hide and the show made
directly, from the main thread's update opportunity, on the window
`withHostWindow` lends, and a direct hide and show of a presenting window made
in one update opportunity while no owner round completes, followed by a frame
on a replacement handed the old swapchain and none on the old one — examples
that fail without the lent window's hide guard (#368);
a renderer refusing every frame, with the owner's deadline one backoff interval
ahead of a still clock and no second attempt until the clock reaches it; a
fresh request, made while such a retry is pending, rendered at once with the
clock still; a frame of a new generation refused after a resize, with an
unrelated wake making no second attempt before the retry's interval; with
one live generation, a quiet target's resize whose replacement is rendered with
nothing published; and a demand deadline coming at the instant a resize's
replacement is due, whose frame on the replacement is refused once, with no
second attempt before the retry's interval, an unrelated wake included;
the owner presenting a scene published from another thread while the main
thread is held inside its native event call, and a window command submitted
then served only once the call returns; a live resize under the same held call,
the stand-in surface changing every 8 ms and every swapchain built at another
extent answering suboptimal, with the owner presenting throughout and building
at least three replacements — the same example presents once and builds none
under a rule that waits for quiet geometry; a presentation's device loss reaching
the composed loop's checkpoint; and the exit drain waiting for owed
presentations before retiring the target, the device, the messenger and the
instance, with a window command submitted after the loop ended answered rather
than left waiting; and that drain, with a presentation still owed and a demand
deadline the owner took but never served, arming its timer again each time the
clock moves past that deadline rather than asking at once, for ever, and the
same once a resize has left the closing target's replacement settling past
its instant. In
`native-tests`' `Frames`, a closing pass cancelled from inside its first frame's
cleanup submission leaves the second frame acquired; closing the target's frames
again finishes the pass, a third finds nothing, and the target's slots retire. The `terminal failure` group's sink example now waits for
the owner's own failure before its checkpoint, which the owner's wake for a
failure latched on the main thread makes certain.

VK-11's examples are in `native-tests` too, over a stand-in recording layer
that journals every call and fails at a chosen step: a sealed batch retaining
the frame's generation, its storage, the pipeline and — transitively — its
layout, observed from inside the native bind; repeated and overlapping use
retained once; a replacement not redirecting an earlier batch; foreign, stale,
released, duplicate and consumed capabilities and a stranger's thread refused
with no native call; a recorder kept past its scope and a consumer run exactly
once; unsupported and illegal commands refused at the interface; a batch the
object budget cannot reserve refused before any command buffer begins; a
consumer that raised, one that was cancelled, one that left rendering open, and
one that caught a failed command and returned, each leaving a partial batch
owned and unsealed; invalidation observed to precede discharge,
and a failed invalidation retaining everything; a discard and a reset each
discharging only its own references; a submitted batch neither discarded nor
reset; release preserving a sealed batch, a layout outliving its pipelines, and
a failed destruction retained without a retry, every destruction recorded
beyond one progress turn's action limit, and frame storage refused for a
foreign target or an unissuable slot; the readback's allocation-relative ranges, bounds,
transfer-source requirement, non-coherent invalidation and flush, completion
before exposure, and no exposure after a skip or a reset in the model, after a
reset followed by the frame's submission, or after a fill whose flush raised; a
second writer refused; a slot reused for a second submitted frame once the
first's submission completed, the first's stale frame and a released
storage refused without a reset, and a destroyed storage taking its completed
batch's record with it; invalid viewports and scissors refused; and the FFI audit held to the package's import
declarations. The model's own suite adds `extendBatch`'s examples. The
presentation examples add the capture usage, taken only where offered.

VK-12's examples are in `native-tests` too, over a stand-in frames layer that
models what Vulkan holds the application to — each fence unsignalled, pending
or signalled, each binary semaphore idle, owed a signal or waited on, and each
owned image — and records a violation whenever a call breaks a rule: asking a
fence no submission made pending, resetting or destroying a pending fence,
acquiring into or signalling a busy semaphore, waiting on one nothing will
signal, or releasing an image whose acquisition was never waited on to
completion. Every example requires there were none. They cover: reservation
before the acquisition, the slot's synchronization made first, and the exact
generation and image owned; not ready and a timeout giving the reservation back
whole with no signal owed; a suboptimal acquisition keeping its index beside a
replacement request; an out-of-date one giving the reservation back and asking
for the target's replacement; a foreign target as misuse, a stranger's thread,
a suspended, a closing and a failed target; an exhausted frame budget answered
before any native call; an acquisition that raised giving the reservation back;
the submitted batch waiting on the acquisition and signalling the
render-finished semaphore with its fence reset just before; a two-frame request
sharing one submission and retaining both frames' generation and storages until
it completes, and two separate submissions settling independently; a duplicate,
consumed, discarded and partial batch refused before any native call; a
no-effect failure leaving no pending fence, never asked, and the frame
resubmitted; a fence reset that raised retaining the fence, stopping admission
and failing the session while the frame is still skipped safely; an uncertain submission retained for ever with admission stopped;
a skip returning its image only after its cleanup completed, with nothing
rebuilt; a skip after submission refused; a closed, never-presented frame
settled only after its rendering and then its render-finished semaphore's
cleanup completed; a closing target's frames abandoned, settled while it closes
and its slots retired; abandonment after ordinary admission was exhausted,
holding the slot and pool record until the evidence; a cleanup submission and a
release that raised each retaining the frame and its image, failing the session
and never settling; a consumer that raised run once and its frame skipped; the
one-slot schedule through acquire, record, submit, close, settle and the slot's
reuse, and the two-slot schedule with two frames in flight; a one-action step
observing, cleaning up and releasing a later submission that completed first
while an earlier one never does; and a cancellation
at each native handoff — the acquisition, the submission, a skip's cleanup, a
closed frame's cleanup and the release — each recorded before it is delivered.
`Frames visibility across the package boundary` compiles external clients as
the recording's does: every public frames name must compile, each
`Internal.Frames` module must be refused as hidden, and the `Frames`
constructor must be refused.

VK-13's examples, `Frames presentation`, are in `native-tests` over the same
stand-in, extended to model presentation: a presentation's semaphore wait, its
present fence pending until the example completes it, and its image returned to
the presentation engine, with a violation recorded for presenting an image the
application does not own, waiting on a semaphore nothing will signal, or asking
or waiting on a fence no queue operation made pending. They cover: the image
presented to its swapchain, waiting on its pool record's semaphore, with the
record's present fence reset immediately before; a presentation made before the
rendering completed, whose signalled render fence frees the slot and no
presentation object, retiring only on its own present fence; a present fence
that has not signalled answering pending however often it is asked; an image
reacquired while its older presentation is pending, through a second record,
with no fence waited on or asked; a delayed presentation keeping its frame, its
image, its slot and its record until it is presented; refusals before any native
call; each per-swapchain answer by its effect — suboptimal and out of date
reported to the generations with no synchronization reset, out of date and
surface lost enqueued although the call raised, out of memory (written or not)
enqueuing nothing and never asked, and an unwritten answer retained for ever
with the session failed — and the classification's whole table, contradictions
included; a cancellation at the presentation handoff, including an out-of-date
error return with enqueued obligations, recorded before it is delivered; a
present fence whose reset raised, and one whose status query raised; the finite
drain wait capped at 10 ms, whose timeout keeps the record, the hold and the
target's retirement — frames, generations and surface — withheld until the
evidence arrives; skipped and never-presented frames settling through their own
cleanup and freeing their records only then; the derived default pool of 18;
pool exhaustion as backpressure before any native call, and a retirement making
room without growth; a retired generation's pending records counted against the
new generation's capacity; a resized target's old generation destroyed only
after its presentation's retirement was observed; generations retired one a
step, round-robin across two targets; and the first of two targets closed from
verified fences — withheld while its presentation was pending — its surface
destroyed and the device kept, while the second keeps presenting before and
after, and the session then retired with every fence observed. VK-16 adds, under
`while a replacement waits`, a frame acquired from and presented to the active
generation while its replacement settles — the replacement then built and the
old generation held by that presentation — and one acquired from it while the
replacement waits for the generation count to have room.

VK-14's examples are in `native-tests` and `integration-tests`, over the same
stand-ins, extended to answer a native result recovery acts on
(`NativeFailure`) at a chosen step, once or after a number of successes, and to
run out of memory at a recording or frames step. `Generations`' group
`surface recovery (VK-14)` covers: a lost surface's generation retired and held
while a CPU use is, the surface destroyed only once every generation of it has
gone, and a replacement installed on the same target — its support queried, a
fresh generation handed nothing — as one attempt that is not given back; a loss
raised by the capability query and by a swapchain's creation; nothing more
asked, and no step owed, while an attempt waits for its surface; repeated loss
spending one episode, three replacements and then the target spent; one
episode carried across a failed replacement, a changed geometry and the
construction's own retries; a partial replacement retried freshly only after
its rollback was proven, and one whose rollback is unproven — its candidate or
the lost surface itself not destroyed — forbidding every further attempt and
failing the session; the retired chain destroyed before any fresh creation,
with a window still in use charged to the same episode; close defeating a late
replacement and settling its attempt; a failed replacement scheduling the next
through the episode; exhaustion and an unsupported replacement each making an
optional target unavailable while another keeps building, and failing the
session for a required one, with no second device; and an ordinary resize
spending nothing while a repeated failure at unchanged geometry spends the
episode; a lost surface whose next attempt's delay the clock cannot express,
at the very end of its range, released once and then left
`RecoveryUnscheduled`, owing no step, and a failed construction at that same
instant left the same way; a lost surface taken from a generation already retired, and a late
report about it never reaching the replacement; and a creation's retry that
raised device loss, latched and raised, or a lost surface, replaced, rather
than either being read as a failed retry; an attempt in flight failed when the
replacement surface's own query reports it lost, the next admitted after its
delay; and a fresh construction kept waiting, charging nothing, while the chain
a failed replacement handed over is still held, then created only after that
chain's destruction; and a replacement that cannot serve the profile failing its
attempt and making an optional target unavailable, or failing the session for a
required one. `Allocation recovery`, over the
frames' rig, covers: a creation that
ran out of memory made once more after one pass reclaimed a retired
generation; no retry without progress, the original failure reported with the
pass's evidence and its accounting given back; a second failure ending the
recovery; a disposal that failed escalating the session and permitting no
retry despite what else the pass reclaimed; a bounded window that reaches an
eligible generation beyond it only at a later pass, through the carried cursor;
configured-capacity exhaustion as backpressure with no native call; a no-effect
submission still reclaimed and submitted once more with the object budget full; a fresh
swapchain creation retried after reclamation and one that handed a generation
over never retried; a frame slot's synchronization recovered, and its
reservation given back when nothing was; a no-effect submission submitted once
more with its batch recorded once, and answered nothing, naming the pass, when
nothing was reclaimed; a no-effect presentation presented once more; and a
lost surface as the frames report it — an acquisition's reservation given back,
its pool record freed and the target's frames retirable, nothing acquired until
the surface is replaced, and a surface-lost presentation enqueued and holding
its generation until its present fence retires. `Frames`' out-of-date
acquisition, and a not-ready or timed-out one, now also free their pool
record, and the target's frames retire after them. The model's suite adds
`declareTargetUnrecoverable`'s examples. `Vulkan controller`'s group
`recovering a lost surface (VK-14)` runs whole hosts: a lost surface replaced on
the main thread under the same attachment, after its generation and then the
lost surface went on the owner's thread, with the other target left alone; a
close defeating a replacement still asked for; an optional target's spent
episode reported unavailable while the other keeps its generation, and a
required one's failing the session at a checkpoint; an unsupported replacement
destroyed on the owner's thread with no second device, making an optional target
unavailable and failing the session for a required one; and an ordinary resize
spending no attempt while each out-of-date result at unchanged geometry spends
one.

VK-15's examples, `Terminal failure`, are in `native-tests` over the same
stand-ins. The frames' stand-in can lose the device at any of its steps, and
from then on holds the frames to the device-loss rules: destroying a fence or a
semaphore whatever it was owed is no violation, and asking or waiting on a
fence, resetting one, acquiring, submitting, presenting or releasing is. They
cover device loss injected during acquisition — the reservation given back —
during submission — the effect recorded uncertain — during presentation and
during idle progress, each refusing further rendering naming the loss and each
torn down with every pending fence released as lost rather than signalled,
never asked or waited on again, and destroyed with every slot and pool object,
the generation, the surface and the device after it; a validation error
latched as the primary and a teardown wait that then reports the loss, keeping
the validation error and switching that teardown to the device-loss rules; the
loss surviving a cleanup failure during teardown, which joins the evidence and
is never retried; each of two storage destructions that failed in one
disposal pass named beside the loss; an unsubmitted recording whose pool reset
reported the loss released without another reset; a presentation whose call
raised the loss while its entry answered out of date, recorded as enqueued and
the loss still raised; an uncertain effect with no loss retaining its
frame, its generation, the surface and the roots through the whole teardown; a
validation error from the capture's watch refusing the next rendering and
acquisition with no native call, then settling what was owned under the
ordinary rules; a pending diagnostic failure refusing rendering and
acquisition with `RefusedDiagnosticPending`, latching nothing and leaving the
model running, until the capture's alarms name the sink failure as the primary
with the error beside it; a sink failure latched as a status of its own,
authorizing no release, and a sink failure and a validation error after a loss joining the
evidence behind it; a required target's exhausted recovery failing the
session and refusing the other target, while an optional target's leaves the
other rendering; a validation error in the capture before the step that would
exhaust a required target kept as the primary, with recovery going no further,
and one that follows the exhaustion kept behind it; a validation error only
the capture's order knows of, and a sink failure whose reason its worker
publishes late, each kept as the primary ahead of the exhaustion it preceded;
a validation error reported during a call that then returns the device's loss
kept as the primary with the loss beside it; a checkpoint that finds the
owner's claim unrecorded refusing as pending with nothing latched, and the
owner's loss then kept as the primary ahead of the later error; and a validation error
reported inside a submission that then raised with an unknown effect kept as
the primary, with the uncertain effect beside it. The model's own suite adds `Device loss`: the loss kept beside
an earlier cause, the release refused before the loss, a submission and a
presentation released without being completed or retired and their cycle
dropped uncredited, an uncertain effect retained until the loss, an acquired
frame left to be skipped first, a second release releasing nothing, and the
outcome of the call that failed the session recorded while new work is
refused. `integration-tests` adds `terminal failure`: a validation error a
stand-in call reports into the session's real capture, through the production C
callback, latched at the owner's next checkpoint and reaching the application's
as `GraphicsSessionFailed`, the target it was reported against left unusable
for the owner to retire, a later handover refused naming it, the
teardown in order and the verdict carrying the error; the same error latched
although a full capture dropped its record, since the latch is set before the
record is admitted; a sink failure latched as
its own status, with the verdict's consumer unsuccessful and no error latched;
a sink failure latched although the owner was idle and nothing else was
published, since its publication wakes the owner; a sink failure that came
before a validation error, both arriving while the owner was inside a native
call, kept as the primary with the error beside it; a handover while the
capture's sink had claimed the order but not published its failure, with an
error latched after it, refused as `VulkanDiagnosticPending` with nothing
latched or attached, and the next handover, once the failure is published,
refused naming the sink failure with the error beside it; a target whose
surface was still being created when an error arrived, after its handover's
checkpoint, rejected naming the error when its construction began, with no
native call made for it;
an exit whose surface destruction failed, reporting the cleanup failure as its
primary and what it retained beside it; a surface still in its native call when
the drain closed the lease, whose destruction then failed, latched as a cleanup
failure beside the earlier primary with the instance retained; two deferred
surfaces whose destruction both failed in the owner's orphan pass, each latched
once by its handle with what its own destruction raised; two distinct
surfaces that share a handle, both failing, each latched with its own
attachment; and cancellation
delivered three times
while the drain that follows a loss holds, leaving the destruction order and the
loss as they were. The diagnostics suite adds the sink failure observable while
the lifetime still captures, `captureAlarms` answering a sink failure and an
error in the order they happened, either way round, and answering only
`CaptureAlarmPending` while a sink that claimed the order has not yet published
its failure and an error has latched after it.

#266's examples, `Generations visibility across the package boundary`, compile
external clients the same way: one that imports every name the public
generations module exports, with the constructors it exports, must compile;
one per `Internal.Generations` module must be refused as a hidden module of
this package (`GHC-87110`), never as a missing one; and one naming the
constructor of each abstract type — `Generations`, `GenerationUse` — must be
refused because the public module does not export it (`GHC-10237`).

#265's examples, `Recording visibility across the package boundary`, compile
external clients through the shared harness (`Test.Support.ExternalClient`)
against the built package and the dependency store, typechecking only: one that
imports every name the public recording module exports, with the constructors
it exports, and the entry points of `Recording.Shaders` and `Recording.Vulkan`
must compile; one per `Internal.Recording` module must be refused as a hidden
module of this package (`GHC-87110`), never as a missing one; and one per
abstract handle — `Recording`, `PipelineLayout`, `Pipeline`, `FrameStorage`,
`Readback`, `Recorder` — naming its constructor must be refused because the
public module does not export it (`GHC-10237`).

#250's examples are there too, over the same stand-ins with naming turned on or
left off: the naming scheme's object types held to the binding's and its bound;
the device, its queue and every surface named from their identities once the
device exists, and no naming call ever dispatched for the messenger; nothing
named, and no queue asked for, when the device offers no naming; a surface
whose naming raised left unadmitted and its creator's, and a device whose naming
raised kept and named at the next admission; a generation's swapchain, images
and views named as each is made, and a construction whose naming raised retired
unpublished and destroyed child before parent; every managed resource's objects
named before its handle is returned, and one whose naming raised released and
destroyed by disposal; a batch and its pass bracketed in balanced labels naming
the batch, target and generation, and no label without naming; every open label
closed after a consumer that raised inside rendering, a cancellation, and a
failed command; and a batch whose labels could not be balanced left partial and
unsealed, keeping its storage and holds until a discard and keeping the
consumer's own failure.

**Native.** The group `test.vulkan-native` runs the native suite below. The
retained per-slice records from the retired proof harness —
[`docs/vulkan/linux-vk7.md`](vulkan/linux-vk7.md) for VK-7, and the VK-2, VK-5
and VK-6 records beside it — stay as the historical evidence of the inputs
they name. VK-10's native cases are retained as
[`docs/vulkan/macos-vk10.md`](vulkan/macos-vk10.md), from the local Cocoa run,
and [`docs/vulkan/linux-vk10.md`](vulkan/linux-vk10.md), from the Linux display
worker. VK-11's are retained as [`docs/vulkan/macos-vk11.md`](vulkan/macos-vk11.md)
and [`docs/vulkan/linux-vk11.md`](vulkan/linux-vk11.md). VK-12's are retained as
[`docs/vulkan/macos-vk12.md`](vulkan/macos-vk12.md) and
[`docs/vulkan/linux-vk12.md`](vulkan/linux-vk12.md). VK-13's are retained as
[`docs/vulkan/macos-vk13.md`](vulkan/macos-vk13.md) and
[`docs/vulkan/linux-vk13.md`](vulkan/linux-vk13.md). VK-14's are retained as
[`docs/vulkan/macos-vk14.md`](vulkan/macos-vk14.md) and
[`docs/vulkan/linux-vk14.md`](vulkan/linux-vk14.md). VK-15's are retained as
[`docs/vulkan/macos-vk15.md`](vulkan/macos-vk15.md) and
[`docs/vulkan/linux-vk15.md`](vulkan/linux-vk15.md). VK-17's are retained as
[`docs/vulkan/macos-vk17.md`](vulkan/macos-vk17.md) and
[`docs/vulkan/linux-vk17.md`](vulkan/linux-vk17.md), and the milestone they
complete is [the Vulkan milestone verdict](vulkan_milestone_verdict.md).
VK-19's are retained as
[`docs/vulkan/macos-vk19.md`](vulkan/macos-vk19.md) and
[`docs/vulkan/linux-vk19.md`](vulkan/linux-vk19.md). #250's are retained as
[`docs/vulkan/macos-vkr2.md`](vulkan/macos-vkr2.md) and
[`docs/vulkan/linux-vkr2.md`](vulkan/linux-vkr2.md). #265's, taken again over
the recording's split into private modules, are retained as
[`docs/vulkan/macos-recording-split.md`](vulkan/macos-recording-split.md) and
[`docs/vulkan/linux-recording-split.md`](vulkan/linux-recording-split.md).
#266's, taken again over the generations' split into private modules, are
retained as [`docs/vulkan/macos-generations-split.md`](vulkan/macos-generations-split.md)
and [`docs/vulkan/linux-generations-split.md`](vulkan/linux-generations-split.md).
The macOS evidence for the owner's standing desktop approval, taken again over
the suites' consent wording, is retained as
[`docs/vulkan/macos-standing-approval.md`](vulkan/macos-standing-approval.md);
its Linux execution is CI's.
#269's, taken again over the logging and failure modules' split into public
facades over hidden modules, are retained as
[`docs/vulkan/macos-log-failure-split.md`](vulkan/macos-log-failure-split.md);
their Linux execution is CI's.
#271's, taken again over the resource family's split into owning modules
behind its package-private facade, are retained as
[`docs/vulkan/macos-resource-split.md`](vulkan/macos-resource-split.md),
with that run's `test.glfw-native` receipt beside them; their Linux execution
is CI's.
#280's, taken again over the native wake examples' Wayland settling barrier,
are retained as
[`docs/vulkan/macos-wayland-settle.md`](vulkan/macos-wayland-settle.md), with
that run's `test.glfw-native` receipt beside them; their Linux execution is
CI's.
#272's, taken again over the worker group's split into owning modules behind
its package-private facade, are retained as
[`docs/vulkan/macos-worker-split.md`](vulkan/macos-worker-split.md), with that
run's `test.glfw-native` receipt beside them; their Linux execution is CI's.
#284's, taken again over the launcher regression's descendant check and its
test-only unreaped-exit helper, are retained as
[`docs/vulkan/macos-zombie-descendant.md`](vulkan/macos-zombie-descendant.md),
with that run's `test.glfw-native` receipt beside them; their Linux execution
is CI's.
#273's, taken again over recovery's split into its public module and the
hidden `Recovery.Types`, are retained as
[`docs/vulkan/macos-recovery-split.md`](vulkan/macos-recovery-split.md), with
that run's `test.glfw-native` receipt beside them; their Linux execution is
CI's.
#274's, taken again over time's split into its public module and the hidden
`Time.Types` and `Time.Arithmetic`, are retained as
[`docs/vulkan/macos-time-split.md`](vulkan/macos-time-split.md), with that
run's `test.glfw-native` receipt beside them; their Linux execution is CI's.
#275's, taken again over messaging's split into its public channel and
snapshot modules and the hidden `Messaging.Channel.Types`,
`Messaging.Snapshot.Types` and `Messaging.Component`, are retained as
[`docs/vulkan/macos-messaging-split.md`](vulkan/macos-messaging-split.md), with
that run's `test.glfw-native` receipt beside them; their Linux execution is
CI's.

## The native suite

`hetoimasia-gpu-vulkan-glfw:vulkan-native-tests`, in `packages/gpu-vulkan/glfw/native-test/`,
is the package-native Vulkan fixture and the native cases of VK-2 and VK-5
through VK-7 that it took over from the retired proof harness. It follows
[the GLFW native suite's](glfw.md#the-native-suite) ownership rules — which it
companions — and adds the Vulkan owner's:

| Rule | How it holds |
| --- | --- |
| Main thread | Hspec runs on a thread of its own; the process main thread owns one shared production graphics session: `withLoaderIntegration`, then `runGraphicsOwnerApplication` over `withVulkanOwnerHost`, with the production native layer and surface bridge. An example that needs the main thread — to hand a window's surface over, which GLFW creates there, or to close a window — submits an operation (`onMain`); the main thread runs it between two turns of the host's owner loop and returns its result or rethrows its failure. Windows are created through the host's command port from the example's own thread, which the owner loop executes, as an application's worker would. |
| Identities | Every dispatched operation is checked, before it runs, to be on the bound process main thread that entered the session — the Haskell thread, the bound flag, and the OS thread read through `pthread_self` — and a failed check fails the operation and the run. Every native call the session makes is recorded where it runs by a `NativeObserver`, so an example shows from the calls themselves that the instance, its messenger, the device and every surface's destruction ran on the graphics owner's thread and every surface's creation on the main thread — never from the name of an Hspec hook. |
| Sharing | The roots — the instance, its explicit messenger, and the one device — are acquired lazily, by the first dispatched operation, at most once, and shared by every later example. Each example's windows and targets are its own and are closed inside it. |
| Private roots | A case that must create, poison or destroy roots of its own runs in a child process of the same executable, started with `--private-roots <scenario>`, on the child's own main thread: `vk2-compatibility`, `vk6-capture`, `vk5-bridge`, `vk7-roots`, `vk11-recording`, `vk12-frames`, `vk13-presentation`, `vk14-recovery`, `vk15-validation-stop`, `vk15-retention`, `vk16-composed`, `vk17-one-slot`, `vk17-two-slots`, `vk19-capture`, `grs15-surface-free`, `grs15-surface-free-window`, `grs12-frameless`, `grs3-ordering`, `grs7-texture-table`, `synchronization-hazard`, `debug-names`, and, under the isolated compositor's consent only, `wayland-connection-loss`. The child asserts its migrated examples as the proof did — the whole spec, with Hspec's configuration reading left out, so an ambient `HSPEC_*` cannot narrow its verdict — and the parent's example passes only when every one ran and passed. The parent starts no child without consent; a child started directly without it refuses with exit status 3 before looking its scenario up, and an unknown scenario under consent exits 2. Each child runs in a process group of its own under an external 20-second deadline covering its exit and the end of its output; one still running at it is terminated with its group and fails its example as expired. |
| Selection | Building, listing and filtering the tree, a `--dry-run`, and a selection that dispatches nothing acquire nothing and start no child. A selection matching no example fails. `--complete`, which the catalog group passes, runs the whole tree with Hspec's configuration reading left out and then fails unless the shared session was acquired once and every private scenario the run's consent requires ran and passed — every one, except that `wayland-connection-loss` is required under the isolated compositor's consent and pending under any other — so no ambient setting can turn the group's receipt into a pass for a subset. The consent rules and the migrated proof's pure release, construction, publication and loader-selection examples need no session and run without consent. |
| Consent | Read once, at startup, from `HETOIMASIA_NATIVE_SESSION`, with the GLFW suite's rules for `desktop`, `isolated-x11:<display>` and `isolated-wayland:<socket>`: the last only on Linux, only when `WAYLAND_DISPLAY` names that socket, and never beside a `DISPLAY`. Under the Wayland consent every session requests Wayland by name — the shared host, each child's host, the VK-5 bridge's loader-aware session, and the proof shim's raw initialization, which sets `GLFW_PLATFORM` and fails one that selected another platform — so no X11 or XWayland session stands in; under the others every session requests nothing, as before. The first shared example asserts the platform GLFW selected before any example renders. Without consent every native example is refused before its body, the session is never acquired, and the run ends with the refusal on stderr and a non-zero exit. |
| Environment | Before any Vulkan call, the suite clears every ambient discovery override and every validation-layer setting it finds and records which, disables implicit layers, and points the layer's settings file at an empty one; a child inherits and re-establishes the same environment. |
| Validation | Every validation-enabled instance, shared or private, enables the Khronos layer and its **synchronization validation** through the instance's own create info. The fixture refuses to run with a set other than the one the provisioned layer is pinned to (`HETOIMASIA_VULKAN_VALIDATION_FEATURES`), which is the one the receipt names. `synchronization-hazard` records two `vkCmdFillBuffer` writes to one buffer with no barrier between them, on an instance the production native layer planned from the same request, and passes only when the capture carries `SYNC-HAZARD-WRITE-AFTER-WRITE` from inside the second write, completely, and its post-teardown verdict fails for that latched error and nothing else — reported apart from the clean profile's verdict and never filtered out of it. |
| After teardown | The shared session is released only once Hspec has finished: the loop finishes, the host retires every remaining target, and the owner destroys every surface, then the device, then the messenger, then the instance, which is the last native call. Only then does the run check that order, the owner's thread for each of them, and the capture's final verdict, which must be clean: any validation error or incomplete capture fails the run, and the run prints the error records. |
| Report | The run prints the environment it established, the shared session's acquisitions, native calls, destruction order and verdict, each child's exit and seconds, and how long the process ran. Each child's output and record are written to the validation runner's evidence directory. |

The initial required profile, over the shared roots: dispatched operations run
on the bound main thread; the instance and its explicit messenger are created on
the owner's thread; two windows are handed over as required targets on one
shared device, each surface created on the main thread, and when the
first-created closes, its surface is destroyed on the owner's thread while the
device, the instance and the second target stay live; and a later example's
target lands on the same device. VK-10's cases, over the same roots: a shown
window's target builds a generation on the owner's thread from the surface's
extent and the profile's format — the framebuffer's pixels, which the case
prints beside the window's size and content scale, and which on macOS it
requires to be the window's size times a scale above one — with a view of every
image, and its close destroys the views and then the swapchain before the
surface; and a window resized through the host's command port, which the main
thread executes, is replaced at its new framebuffer extent with the old
generation handed over, retired and still owned while a CPU use of it is held,
and destroyed on the owner's thread once that use ends. After teardown the run
also requires every image view and swapchain to have gone before the device,
and every swapchain created to have been destroyed. The private cases carry the migrated
assertions unchanged — VK-2's profile, completion, abandonment and capture,
with the synchronization-validation finding added; VK-6's C-only capture;
VK-5's bridge; VK-7's roots through the destruction order at the host's exit —
and the synchronization control.

The same profile runs on native Wayland as `test.vulkan-wayland` (WL-4, #327):
`tools/display/wayland.sh` starts packaged Weston headless around the run and
gives it the consent `isolated-wayland:<socket>`, and every session then
requests Wayland by name, so the shared roots, every private case but one and
VK-17's required profile are created, presented to and retired on Wayland
surfaces through the VK-5 bridge on Lavapipe, under the same completion rules
as on X11, VK-16's `vk16-composed` included. Weston 13 offers no
`wp_fifo_v1`, so Mesa's Wayland WSI throttles FIFO with frame callbacks — each
present waits, with no timeout, for the previous one's callback — and Weston
fires none for an unmapped surface: hiding a window whose target is presenting
would block the graphics owner in its next present to it, and showing it again
would block its old swapchain's. The presentation hold and the replacement on
resume ([Pacing, suspension and fairness](#pacing-suspension-and-fairness),
[#357](https://github.com/coghex/hetoimasia/issues/357)) are what the case
proves there; it was pending until they existed.
Its one extra case, `wayland-connection-loss`, starts a Weston of its own and
renders continuously to one window through the production host; once a
presentation has been observed retiring on its own present fence it ends that
compositor from the loop's update, never after an elapsed time. The next event
processing raises `ConnectionFailed` ([glfw.md](glfw.md#wayland-connection-loss)),
which ends the loop, and the host's protected exit retires the target, the
device, the messenger and the instance. The case requires that the application
end with that loss, a transport closure or protocol failure; that no surface be
created after it; that every present-fence retirement and every submission
completion recorded belong to a presentation or submission the owner made, so
the loss is never recorded as a signalled fence, a completion or a device loss,
while completion the driver genuinely reports is kept; and that every
swapchain be destroyed, the roots in dependency order with the instance last,
with a clean verdict. An expiry of its deadline fails it. Under X11 or desktop
consent it is pending and asserts nothing.

VK-11's case, `vk11-recording`, runs on private roots because it records
against a generation of its own and destroys everything it made: the production
native layer's roots, planned from the same request as every other case, admit
one window's surface; a generation built for a verification capture gives it a
real swapchain image; and the production recording layer constructs a pipeline
layout, a pipeline over VK-9's embedded verification shaders in the generation's
format, the frame slot's storage and a readback buffer for the generation's
extent. Against the [fixture-private frame](#the-checked-frame) it records one
batch of eleven commands — into rendering, the pipeline, viewport and scissor, a
triangle, out of rendering, into the copy, the copy with its host-read barrier,
and out to presentation — through the audited `unsafe` subset, inside the
batch's label and, around the rendering, the pass's, which make fifteen; requires the
model to hold all four resources for that batch, and the readback to refuse its
bytes since nothing was submitted; discards the batch, after which none is held;
settles the frame in the model; and releases and destroys every resource, then
the generation, the surface, the device, the messenger and the instance. It
passes only if no step received a validation error and the capture's verdict
after the last teardown callback is clean. Its record prints the package's FFI
configuration. No safe-versus-unsafe timing is measured, and none is asserted.

VK-12's case, `vk12-frames`, runs on private roots for the same reason, over
VK-11's roots, capture generation and resources, with the production frames
layer. It acquires a frame through `tryAcquireFrame`; records the triangle and
the copy of its image into a readback buffer the host filled with a sentinel;
submits that batch through `submitFrames`; and steps `progressFrames` until the
submission's fence has signalled — the readback refusing its bytes before that,
and exposing bytes that are no longer the sentinel after. It then closes that
never-presented frame and steps until its render-finished semaphore's cleanup
submission has completed and its image has gone back through
`vkReleaseSwapchainImagesEXT`; acquires and skips a second frame, stepping until
its acquisition semaphore's cleanup has completed and its image has gone back;
and acquires again, skipping each, until an image returned earlier is acquired
once more, with the swapchain never rebuilt. Nothing is presented. It passes
only if every frame settled, the rendered image went back only after its
rendering and its cleanup completed, no step received a validation error — with
synchronization validation on — and the capture's verdict after the last
teardown callback is clean. Its record lists every native call the frames made,
fence status queries aside. It asserts no pixel value: the triangle consumer's
pixels are VK-17's.

VK-13's case, `vk13-presentation`, runs on private roots too, over two windows'
surfaces, each with a generation of its own, VK-11's resources and the
production frames layer. It presents three triangle frames to each window back
to back — each acquired, recorded, submitted and presented with its pool
record's present fence — and drains through `awaitFrames` until every
presentation's retirement has been observed through its own present fence. It
then presents a frame to the first window and resizes that window through GLFW
before any progress step has asked that fence, and steps the generations until
the replacement is active: the old generation is retired and held by that one
presentation, and three further generation steps leave it in place. Only once
the present fence's retirement is observed does the next generation step
destroy it, and the first window then presents twice on its new generation.
Next it presents to the first window, leaves a second frame of it acquired, and
closes that target's frames: its retirement is attempted while the second window
presents, and withheld — naming the pending presentation, the skipped frame and
the records — until the evidence arrives; its frames, generations and surface
are then destroyed, and the second window presents three more frames on the same
device. It drains until nothing is outstanding before the second target, the
recording and the roots retire. It passes only if every presentation reset its
fence immediately before, every retirement was observed, the old generation was
held until its presentation's and destroyed at once after, the first window's
retirement was withheld while the second presented, nothing was left
unsettled, no step received a validation error — with synchronization
validation on — and the capture's verdict after the last teardown callback is
clean. Its record lists every native call the frames made, fence status queries
and drain waits aside. It asserts no pixel value.

VK-14's case, `vk14-recovery`, runs on private roots too, over two windows'
surfaces and generations, VK-11's resources and the production frames layer,
with two narrow injections and nothing else: the first window's next
acquisition answers `VK_ERROR_SURFACE_LOST_KHR` without the call being made,
and one readback buffer's creation raises `VK_ERROR_OUT_OF_DEVICE_MEMORY`
without it. It presents three triangle frames to each window and drains every
present fence; then injects the loss, whose acquisition gives its reservation
back, and while the second window presents a frame on every step, the
generations retire and destroy the first window's generation, then its lost
surface, and the episode admits an attempt. A replacement surface is created on
that same window, offered, checked against the one device and installed, and a
fresh generation — handed nothing — is built on it, after which the first
window presents three frames. It then resizes the second window and waits for
the old generation's presentations to retire without a generation step, so the
generation is eligible and nothing else destroys it; the readback's creation
runs out of memory, one reclamation pass destroys that generation, and the
creation is made once more and succeeds. It passes only if the loss was
answered pending, the replacement was installed on the same target as one
attempt, the lost surface's generation and then the lost surface went before
the replacement's support query and a fresh creation on it, nothing was built
on the lost surface again, the second window presented throughout, the
allocation was recovered with exactly one retry and one generation destroyed,
nothing was left unsettled, no step received a validation error — with
synchronization validation on — and the capture's verdict after the last
teardown callback is clean. The shared roots add the same replacement through
the controller and the production bridge: two shown windows handed over, the
first's loss reported as an acquisition on the owner's thread would, the
replacement created by `replaceVulkanSurfaces` through `replaceWindowSurface`
on the main thread under the same attachment and target, the lost surface
destroyed on the owner's thread before it and the new surface's support
checked and a swapchain built after it, there, while the second window's target
and generation are untouched.

VK-15's two cases run on private roots too. No device loss is induced
natively: its teardown is the headless examples', and the specification's rows
in the proof records.

`vk15-validation-stop` is VK-13's arrangement over one window, with the roots
watching the capture as the controller has them do. It presents two triangle
frames and observes both present fences; acquires, records and submits a third;
and then delivers one error-severity validation message through
`vkSubmitDebugUtilsMessageEXT`, carrying the message identifier
`VUID-hetoimasia-vk15-injected-validation-error`. The next checkpoint — the
third frame's presentation — is refused naming `TerminalValidationError`, and
so is a further acquisition, neither making a native call. The frame is closed
unpresented and everything is torn down under the ordinary rules: the drain
settles every obligation on its own evidence, and the frames, the generation,
the surface, the resources, the device, the messenger and the instance retire
without a failure. It passes only if the error is the session's primary with no
device loss recorded; exactly one error reached the capture — the injected one,
during its own step — and no other anywhere, with synchronization validation
on; and the verdict after the last teardown callback fails for that latched
error and nothing else, with nothing dropped, cut or undelivered and every
report offered through `vkDestroyInstance` counted in it.

`vk15-retention` runs the production composition, `withVulkanOwnerHost`, over
one visible window whose target's generation it builds, holds a CPU use of
that generation and never ends it, and lets the host exit. The owner's drain
cannot verify the generation, so it retains it and every parent above it and
records each retention in the latch; its run ends without destruction evidence
and without the target's terminal record, so the host keeps the window and
waits. The case passes only if the latch reports the retention with no primary
failure and no loss, if no swapchain, surface, device, messenger or instance
was destroyed, and if the host still holds the window. A watcher then writes the
record and terminates the process — #220's destructive boundary, the escape the
lifetime design leaves for what cannot be verified — and the record says so:
the operating system, not the session, reclaims what was retained, and no
diagnostic verdict follows, because the last callback was never reached.

VK-16's case, `vk16-composed`, runs the production composition over two
visible windows, driven by `runVulkanOwnerLoop` with nothing published by hand:
the adapter publishes each window's observation and captured demand, and the
application asks each window for a frame as soon as its last one was
presented. Once each target has presented three frames, the first window is
hidden through its command port. Once that command has settled as attempted,
the window has been observed hidden and its target is suspended in the model,
the second presents three more while the first presents none — none since the
hide settled. The first is then shown again; once that command has settled as
attempted and the window has been observed visible, the first presents again,
on a replacement swapchain; and the loop finishes, so the host exits through
D-33. On Wayland it is what shows that a hide never blocks the owner and that
a shown window never presents on its old swapchain (#357). The case hides and
shows through the command port; a hide made directly on a window
`withHostWindow` lends takes the same hold (#368), and is covered by the
headless `integration-tests` examples rather than by this case. It passes only if every Vulkan call ran on one thread, the graphics
owner's, and every surface was created on the main thread; if every
presentation's retirement was observed through its own present fence, no
presentation was made after the device's destruction began, and both surfaces,
the device, the messenger and the instance were destroyed in that order; and
if the verdict after the last teardown callback has no issue and no error was
reported.

VK-17's required profile, `vk17-one-slot` and `vk17-two-slots`, runs the
triangle sample's own drawing (`hetoimasia-sample-triangle`, which the suite
depends on, so the sample is among the group's inputs) through the production
host with verification capture on, over two mapped windows that request no
focus, driven by `runVulkanOwnerLoop` — once with a frame budget of one slot
and once with two, each in a child of its own. Each window's frame is
captured; the first window is resized through its command port and, once its
target's active generation is the one built at the new extent, captured again;
the first-created window is closed and, once its target has retired, the
second is captured again. It passes only if the model ran with the budget it
was given; if every captured frame has the sample's clear, sRGB-encoded, at a
point near its top-left corner and the sample's triangle at the triangle's
centroid, each channel within 6 — never a whole-image hash; if the resized
window's capture has its new generation's extent and not the old one; if the
first window's target retired before the second's last capture was asked
for; if each captured frame is one the case saw acquired, submitted,
presented and retired on its own present fence; if every generation was an
unclipped transfer source; if every Vulkan call ran on the graphics owner's
thread and every surface was created on the main thread; and if the verdict
after the last teardown callback has no issue and no error was reported. Both
children run inside the group's one thirty-second watchdog, with the rest of
the suite. The milestone they complete is recorded in
[the Vulkan milestone verdict](vulkan_milestone_verdict.md).

VK-19's case, `vk19-capture`, runs the production composition with
verification capture on — `withVulkanOwnerHostAs CaptureOn`, the private
sublibrary's — over two mapped windows that request no focus, driven by
`runVulkanOwnerLoop`, with a consumer renderer that builds a layout and a
pipeline over the embedded verification shaders for each frame's format, clears
to blue and draws one orange triangle. Each target is asked for a capture once
it has an active generation, and nothing else asks for a frame. The loop turns
until both captures have settled and every presentation made has retired on
its own present fence, and the host then exits through D-33. It passes only if
both captures were delivered, each with the whole image's bytes; if each has
the clear's sRGB encoding at a point near its top-left corner and the
triangle's at the triangle's centroid, each channel within 6 — two points,
never a whole-image hash; if each captured frame is one the case saw acquired,
submitted, presented and retired on its own present fence; if every generation
of both targets was an unclipped transfer source; if every Vulkan call ran on
the graphics owner's thread and every surface was created on the main thread;
and if the verdict after the last teardown callback has no issue and no error
was reported. It infers no cadence, vertical blank or pacing from any timing.

GRS-15's two cases run the production composition with `DeviceSurfaceFree`,
the validation layer and synchronization validation.
`grs15-surface-free` opens no window at all: once the owner's startup has
answered `RootsReady`, one owner-thread action builds a pipeline layout and a
pipeline over the embedded verification shaders, and a second releases both;
the case waits until the owner's own progress — with no target and no frame —
has destroyed them, and the host then exits through D-33. It passes only if no
window and no surface was created; if the calls after the instance and its
messenger were `vkEnumeratePhysicalDevices` and `vkCreateDevice`, with no
`vkGetPhysicalDeviceSurfaceSupportKHR` anywhere; if both actions returned
and ran on the thread that created the device, which is not the main thread;
if the pipeline and its layout were destroyed before the body returned and no
frame event was reported; if the destructions ran pipeline layout, device,
messenger, instance, in that order, with every Vulkan call on the owner's
thread; and if the verdict after the last teardown callback has no issue and no
error was reported. `grs15-surface-free-window` starts the same way over one
mapped window that requests no focus, hands it over once the device exists,
publishes a scene, and turns `runVulkanOwnerLoop` until that frame is presented
and its presentation retires on its own present fence. It passes only if the
device was created with no surface before the window's surface existed, and
the surface was then checked with `vkGetPhysicalDeviceSurfaceSupportKHR`; if
the target was admitted, with one device created in all; if a presentation
retired; if the destructions ran surface, device, messenger, instance, with
every Vulkan call on the owner's thread; and if the verdict is clean.

GRS-3's case, `grs3-ordering`, runs VK-12's roots, generation, recording and
frames with synchronization validation over one managed `D32_SFLOAT` depth
target and one vertex buffer. A first frame batch initializes the depth target
by a transition from undefined and moves the buffer into the copy's use and
back, writing both; it is submitted and awaited, and its frame closed and
settled. Then two frames are acquired, and each batch touches the same depth
target and buffer with no layout change, writing both, the second submitted
while the first is still outstanding. The writes are the issue's narrowly
scoped test-only accesses, recorded straight into the batch's command buffer:
a depth-only dynamic rendering pass that clears and stores the depth target,
and a `vkCmdFillBuffer` of the buffer; no production attachment, binding or
upload API is added for them. Between the two later batches' writes stand only
the first's exit barriers and the second's entry barriers. It passes only if
the depth target's initialization was published by its batch's submission; if
each batch recorded exactly the expected entry, transition and exit barriers;
if the third batch was submitted while the second's submission was
outstanding; if nothing was left unsettled; and if no step reported a
validation error and the verdict after the last teardown callback is clean. On
the pinned layer, measured once by hand with every barrier of the two later
batches dropped, submit-time synchronization validation reports the buffer's
write-after-write at the third submission, but nothing for the depth target's
load-op clear across submissions: for the depth target the case shows the
barriers recorded and their layouts accepted, not a hazard the layer could
have seen.

GRS-12's case, `grs12-frameless`, runs the same surface-free composition with
no window, under a 2 GiB byte budget, as VK-11's case does. One owner-thread
action builds a color target and a vertex buffer and records a frame-less
batch that initializes the target and moves the buffer into a copy's use and
back; a second records one that moves the target into a copy's source and back
and the buffer again, with no wait for the first's completion. Each is
submitted when its action returns. It passes only if no window, surface or
image acquisition was made and the device came first; if both actions ran on
the owner's thread, each beginning and ending one command buffer; if two
submissions were made, two completions observed, and both tickets, waited for
with a deadline from the main thread, answered complete; if the frame-less
fences were destroyed before the device, then the messenger and the instance,
with every Vulkan call on the owner's thread; and if the verdict after the
last teardown callback has no issue and no error was reported. Recorded
commands are not observed one by one there, so its barriers are the headless
examples', and their synchronization the verdict's.

#250's case, `debug-names`, is VK-11's on private roots of its own, with one
destructive seam only the fixture holds: it wraps the production recording
layer so the batch's copy into the readback buffer is recorded, through the
binding's own call, four bytes into the buffer, where the whole image no longer
fits. Core validation reports that while the command is recorded, as
`VUID-vkCmdCopyImageToBuffer-pRegions-00183`; nothing is submitted, and no
handle leaves the backend's interface, since the wrapper sees only what the
backend hands its own native layer. The case passes only when that report, and
no other error, reached the capture from the recording step; when the report's
objects carry the readback buffer's handle with the name the backend gave it;
when the report's command-buffer labels include the batch's, if the pinned
layer reports command-buffer labels at all — which label arrays each layer
populates, in what order, is recorded in the case's record, not assumed; and
when the
verdict after the last teardown callback fails for the latched error and
nothing else, with nothing dropped, cut, refused or undelivered. The shared
session also requires every naming call it made to have run on the owner's
thread and returned.

The **graphics-owner interaction probe** is the suite's last example, and
the only one no routine run executes. It extends
[RR-4's probe](glfw.md#the-interaction-probe) with the graphics owner and is
gated exactly as that one is: it needs the run's native consent, and it is
pending — opening no window — unless `HETOIMASIA_INTERACTION_PROBE_SECONDS`
names the seconds each phase lasts. No validation group names it, so
`test.vulkan-native` reports it pending on both platforms. Activated, it runs
in a child of the suite with the parent's terminal, so the person sees each
phase's instruction as it begins: the production composition over one
640×480 window, with the validation layer, driven by `runVulkanOwnerLoop`,
while a thread other than the main one publishes a new scene every 16 ms and
the owner clears each frame to a colour that moves with the scene. The
session's trace records the main thread's owner turns, the native event call's
entry and exit and every callback delivered inside it; the frame observer
records every acquisition, present request, present return and present fence
observed signalled into the same trace from the owner's thread, in the same
monotonic time domain. Through RR-4's four phases — an idle baseline, a window
move, a live resize and a menu-bar interaction — it reports, per phase, the
owner turns, the pumps, and the present requests, returns and completions
overall and inside each pump that blocked for a quarter of a second or more;
with `HETOIMASIA_INTERACTION_PROBE_OUTPUT` it writes every record with the
platform, compiler, device, loader, driver and layer identities. It asserts
that every phase measured something, lost nothing and faulted nothing, and
that validation reported nothing — never whether a stall happened, and never
that frames visibly advanced, which a present return and a present fence do not
prove. [The graphics-owner interaction verdict](graphics_owner_interaction_verdict.md)
records its measurement.

```bash
HETOIMASIA_NATIVE_SESSION=desktop HETOIMASIA_INTERACTION_PROBE_SECONDS=15 \
  HETOIMASIA_INTERACTION_PROBE_OUTPUT=/tmp/graphics-owner-probe.tsv \
  bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --interaction-probe
```

The owner's standing approval for native runs does not reach it: it is
interactive, no planner selects it, and a person must perform the interactions,
so it runs when the owner asks for it, as RR-4's did.

Run the suite as the group does:

```bash
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --dry-run
```

On Linux the native mode starts an isolated X11 display for the run and needs
no approval. `test.vulkan-wayland` runs the same profile on the isolated
headless compositor instead, which needs no approval either:

```bash
bash tools/display/wayland.sh -- bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
```

On macOS the suite opens windows on the owner's desktop. The
owner's standing approval covers a run an issue or pull request needs (see
[the GLFW native suite](glfw.md#the-native-suite)), so the agent runs it
without asking, with the consent on that one command:

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
```

See [validation.md](validation.md#the-vulkan-groups-local-evidence) for the
receipt that run leaves and what it is evidence of.
