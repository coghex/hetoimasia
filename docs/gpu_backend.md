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

[#250](https://github.com/coghex/hetoimasia/issues/250) (VKR-2) adds **debug
names and recording labels**: every native object the backend creates is named
from identities it already holds — the debug messenger excepted — and every
batch and every dynamic-rendering pass is bracketed in balanced command-buffer
labels, which [the diagnostic capture](vulkan_diagnostics.md) now copies. See
[Names and labels](#names-and-labels).

Frames are acquired, submitted, presented and abandoned by the native
package's frames module, and its native cases drive them on private roots; the
controller wires neither the recording nor the frames in, and the owner's
progress step reports no render demand. Its deadlines are the brief
self-scheduled watch over an attachment whose announcement a full port
deferred, described below, and the generations' own: a settling resize, a
deferred recovery attempt, and the model's schedule for a retired generation
still held. Composing the frames into the owner's loop is VK-16's, and
completing device-loss teardown across submitted work and pending
presentations is VK-15's.

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
`Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan`, its production layer. The package's private modules, which no client can import,
are the audited `unsafe` subset, `Hetoimasia.GPU.Vulkan.Native.Internal.Commands`;
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
`State`, `Acquisition`, `Submission`, `Presentation`, `Abandonment` and
`Progress` (see [How the frames are built](#how-the-frames-are-built)); and
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
                               │    │          first target's surface)
                               │    └─ target surfaces, one record per target,
                               │         keyed by the model's TargetId
                               │           └─ swapchain generations, keyed by
                               │              GenerationId: each swapchain, its
                               │              images and their views
                               └─ GPU model (identities, the session's state)
```

- **The instance, its explicit messenger and the device belong to the roots**,
  for the session. No target owns the device or gates its lifetime —
  including the bootstrap target, whose surface the device was selected
  against — so closing the first-created window cannot release a device
  another target is using (D-7).
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
and a `NativeObserver`: something that wraps every native call the controller
makes, for evidence. It must run each call once and answer what it answered; it
decides nothing, and the default observes nothing.

## Threads

| Work | Thread |
| --- | --- |
| Loader-aware session, extension copy, window creation, each surface's creation through GLFW | The process main thread |
| Instance and messenger creation and destruction, device selection and creation, the later-target check, every surface's destruction, device destruction | The graphics owner |
| Every surface query, swapchain and image view creation and destruction | The graphics owner |
| Publishing a target's observation (`publishGraphicsObservation`) | The main thread; until VK-16's loop adapter does it every turn, the application does it |
| Holding and ending a generation's CPU use | Any thread, in `STM` |
| Reporting a swapchain call's out-of-date, suboptimal or surface-lost result | The graphics owner, whose acquisitions and presentations produce it |
| Destroying a lost surface, rechecking a replacement's support, a reclamation pass | The graphics owner |
| Creating a replacement surface under a target's existing attachment (`replaceVulkanSurfaces`) | The main thread; until VK-16's loop adapter does it every turn, the application does it |

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

- **A live surface** is offered to the roots. The first one is the bootstrap:
  every physical device is queried with each queue family's presentation
  support for that surface, `selectDevice` takes the first satisfying the
  profile — Vulkan 1.3, `dynamicRendering`, `synchronization2`,
  `VK_KHR_swapchain`, `VK_EXT_swapchain_maintenance1` and its
  `swapchainMaintenance1` feature, and one queue family answering both
  graphics and presentation — and the device is created with that family's one
  queue and `VK_KHR_portability_subset` exactly where the device advertises
  it. No satisfying device is `NoCompatibleDevice`, naming every candidate
  and everything each lacks: a structured startup failure, fatal to the owner,
  whose drain destroys the surface, the messenger and the instance.
- **A later surface** is checked against the session's queue family with
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
main thread. VK-16's loop adapter will publish one every turn; until then an
application publishes it itself, after a handover and after anything that
changes its window.

### The profile

P-15's first profile: single-sample SDR, color-attachment usage only, FIFO,
opaque composition where offered, and an advertised `B8G8R8A8_SRGB` or
`R8G8B8A8_SRGB` format in the sRGB nonlinear color space. The transfer usages
the retired proof harness asked for are neither required nor requested, and
nothing falls back to a UNORM or an arbitrary format. A surface that cannot
serve the profile leaves its target `PresentationUnsupported`, naming every gap
at once; it is a structured target failure, not an assumption.

### Replacement

A target is rebuilt when its geometry moves or when a swapchain call on its
active generation answered out of date or suboptimal (`noteSwapchainResult`, or
a replacement the model counted from an acquisition). Those calls run on the
owner's thread, and so does the report: it makes the owner's next deadline
immediate, so the owner that reported a result takes the round that
reconciles it rather than going idle. A report from another thread wakes
nothing, and the package's public module does not offer one.

- **Ordinary resize** is not a failed construction. The extent a replacement
  would be built at is watched, with the observed geometry it was planned
  from, and the generation is rebuilt only once both have been the same for
  16 ms on the owner's monotonic clock (`Settling`); a newer observation
  restarts the wait even while the surface still reports the old extent, so
  only the newest geometry is built. A move that settles at the extent the
  active generation already has is adopted without a rebuild, and a move that
  returns to the active generation's geometry is cancelled.
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
  hot. A recovery rebuild whose observed geometry
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
  unretired has been destroyed, so a failed candidate that was created goes
  first, and so does an old generation a cancelled replacement never handed
  over; a retry that must wait for one spends no recovery attempt.
- **A newer resize during a replacement** is not lost: the replacement publishes
  what it was begun for, and the newer geometry is built next, while the
  generation it replaced keeps its obligations until they end.

### Bounds

A target holds at most the model's generation limit, two by default, counting
active, constructing and retired together. At capacity, every retired generation
whose holds have ended is destroyed first; if the replacement still cannot fit,
the target is `Backpressured` — suspended in the model — until a hold ends, and
every other target and the owner carry on. With a limit of one, the active
generation is the only thing in the way: it is retired on its own, awaited, and
destroyed, and a fresh generation is built without it once its geometry has
settled — every construction after a target's first is a replacement, and
waits the same quiet period. No target reserves or
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
| `Layer` | The native layer's shape: `RecordingOps` and the command, layout and request vocabulary. No state, no call. | — |
| `State` | The `Recording` and the three maps it holds; handles, refusals, failures and views; the owner check, the live-generation check, the model helpers and a generation's one native destruction. | `Layer` |
| `Construction` | Creating, replacing, naming and releasing managed resources, each in one masked step. | `Layer`, `State` |
| `Batches` | Discard, reset, submission evidence, and freeing a slot of completed batches: invalidate natively, then discharge. | `Layer`, `State` |
| `Recorder` | `recordFrame`, the `Recorder` and its commands, retention before each native call, and label balancing. | `Layer`, `State`, `Batches` |
| `Readback` | Host reads gated on completion evidence, host fills, and the atom-aligned mapped range. | `Layer`, `State` |
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
| Managed rendering resources | `createPipelineLayout`; `createPipeline` over a layout, VK-9's embedded shaders and a color format; `replacePipeline`; `createFrameStorage` for a target's frame slot; `createReadback` of a byte size; `releaseManaged` | The native objects, their accounting reserved with `beginAllocation` before each creation, and the exact generation each handle names |
| Checked frame | `recordFrame` takes a `FrameSlotId` the model holds acquired, and resolves its image, view, extent and format through the generation that owns them | The frame's generation, retained by the batch |
| Scoped recorder | `transitionImage`, `beginRendering`, `bindPipeline`, `setViewport`, `setScissor`, `draw`, `endRendering`, `copyToReadback` | The slot's command storage and the batch's recorded references |
| Recorded batch | `discardBatch`; `resetFrameRecorder`; `noteBatchSubmitted`, which VK-12's `submitFrames` calls | Sealed commands and references, whether or not the caller keeps the `BatchId` |
| Readback | `readReadback`, `fillReadback` | The mapped memory and what last wrote it |
| Disposal | `disposeResources`, `retireRecording` | Destruction on the owner, only once the model reports every hold ended |

The supported vocabulary is exactly the triangle and its verification: dynamic
rendering into the frame's one color view, a graphics pipeline compatible with
the frame's format, dynamic viewport and scissor, whole-triangle draws, the four
image transitions below, and one bounded copy of the whole image into a readback
buffer. There is no raw command buffer, no callback escape hatch, no descriptor,
no vertex buffer and no render graph. A command outside that vocabulary — an
unsupported transition, a draw that is not whole triangles, a transition into or
out of the transfer-source layout or a copy of an image that is not a transfer
source — is `RefusedUnsupported`; one the recorder's state
does not admit — a draw outside rendering or before a pipeline, viewport and
scissor, a transition inside rendering or from a layout the image is not in,
rendering into an image that is not a color attachment, a viewport that is not
finite or has no area, a viewport or scissor that leaves the frame's image — is
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
allocated, a buffer whose memory could not be bound — destroys that part before
raising, so a creation that raised created nothing.

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
| A readback's buffer and memory | `resource <n>.<g> readback buffer`, `… readback memory` | The same |

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
contract, not an automatic hazard resolver.

### Readback memory

A readback buffer is a transfer-destination buffer in host-visible memory —
cached where the device offers it — bound, and mapped whole for its lifetime.

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
- **Non-coherent memory.** Before a read of non-coherent memory the mapped range
  is invalidated, and after `fillReadback` writes it the range is flushed. The
  range (`mappedRange`) is the bytes asked for with the start rounded down and
  the end rounded up to the device's non-coherent atom, the end clamped to the
  memory's size, which is what Vulkan requires of both calls. Coherent memory is
  read without either, and an empty read reads nothing and invalidates
  nothing. `fillReadback` marks the bytes unreadable before its write changes
  the first of them, and readable again only once the write and any flush have
  returned, so a write or flush that raised part-way exposes nothing.
- **Release.** Releasing a readback ends its CPU use: it is read no more.

### Capture usage

P-15's profile never requires transfer usage of a surface. A verification
capture needs its images to be transfer sources, so
`planGenerationWith CaptureWhenOffered` adds that usage wherever the surface
offers it, and otherwise plans exactly what `planGeneration` does — capture is
never a gap. `newGenerationsCapturing` builds generations that way; no normal
target does, and the controller does not. VK-2 verified the transfer-source
capture profile on both drivers.

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
evidence; every managed resource must be gone before the device.

### The FFI audit

D-28's production split, as built. The binding is compiled with
`+safe-foreign-calls`, so every import of its own is `safe`; the package's only
genuine `unsafe` Vulkan imports are the twelve `dynamic` imports in the private
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
| `vkCmdCopyImageToBuffer` | Records a copy; it does not perform one. |
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

`nativeFfiConfiguration` records the list (`ffiUnsafeImports`), the binding's
flags and the C-only callback; the native case's record prints it, so it is
part of the evidence identity beside the build's source digest. The headless
suite reads the package's own import declarations and requires exactly those
twelve `dynamic` imports and, besides them, only the capture callback's address
import.

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
| `retireTargetFrames target` | Destroys a target's slot synchronization and presentation pool once nothing of it is live, presented and unretired, or pending | Returns, or raises `FramesRetained` naming what remains |

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

The target must be this session's (`ForeignIdentity`, `StaleIdentity` or
`UnknownIdentity` otherwise — misuse, never pending), and admitted: a suspended
target answers `AcquisitionSuspended`, a retiring one `AcquisitionClosing`, and
an unavailable one or a failed session `AcquisitionUnavailable`. Its generations
must be presenting from an active generation: a target still constructing,
settling a resize, backpressured or waiting to recover answers
`AcquisitionPending PendingGeneration`; a spent recovery or an unsupported
surface answers `AcquisitionUnavailable`.

| The call answered | The model | The answer |
| --- | --- | --- |
| `VK_SUCCESS` | The frame owns the image | `AcquisitionOwned` |
| `VK_SUBOPTIMAL_KHR` | The frame owns the image, and the target counts a replacement request | `AcquisitionOwned`, suboptimal; the generations are told (`SwapchainSuboptimal`), so the owner's next step reconciles |
| `VK_NOT_READY`, `VK_TIMEOUT` | The reservation goes back whole, with no synchronization obligation | `AcquisitionPending PendingNoImage` |
| `VK_ERROR_OUT_OF_DATE_KHR` | The reservation goes back, its pool record freed untouched, and a replacement is requested | `AcquisitionPending PendingReplacement`; the generations are told (`SwapchainOutOfDate`) |
| `VK_ERROR_SURFACE_LOST_KHR` | The reservation goes back, its pool record freed untouched, and a replacement is requested | `AcquisitionPending PendingSurfaceLost`; the generations are told (`SwapchainSurfaceLost`), and the surface is [replaced](#replacing-a-lost-surface) |
| It raised | The reservation goes back: an error result has no effect | The failure is re-raised; device loss latches as always |

A successful acquisition whose result the model then refused to record — the
native image is owned and nothing can settle it — is an uncertain effect: the
slot is retained for ever, admission closes, the session fails with
`CleanupFailed`, and `FrameEffectUncertain` is raised.

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
VK-13's drains through `awaitFrames`; composing it into the owner's loop and
the model's schedule is VK-16's.

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
its own: it re-exports what seven private modules under
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
| `Progress` | `progressFrames`, `awaitFrames` and `retireTargetFrames`. | `Layer`, `State`, `Abandonment` |

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
session, which makes no new native effect — the frame's exit is its close; a
frame this owner did not acquire, or that is not submitted, already presented
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
The controller constructs no frames until VK-16 wires them in, so the
controller's own retirement meets no presentation obligation yet; the order and
the withheld evidence it will meet are the ones above, proved on private roots.

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
| An ordinary resize, however often the geometry moves | No: it settles for 16 ms and is built as a replacement ([Replacement](#replacement)) |
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
raises it. Then, on the owner's thread:

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
   main thread for each and wakes it. `replaceVulkanSurfaces`, on the main
   thread, creates the surface through the bridge's admitted replacement
   (`replaceWindowSurface`, [#216](https://github.com/coghex/hetoimasia/issues/216))
   under that same attachment, and deposits what it created. Until VK-16's loop
   adapter runs it every turn, the application runs it, as it publishes
   observations.
5. **Support is rechecked, then a fresh generation is built.** The owner's next
   step offers the surface to the generations (`offerReplacementSurface`). The
   roots ask `vkGetPhysicalDeviceSurfaceSupportKHR` of the session's one queue
   family and install it (`installRootSurface`), and the next step builds a
   fresh generation on it — handing nothing over — whose publication settles
   the attempt as a success, or whose failure spends the next.

| What the replacement came to | What happens |
| --- | --- |
| Installed | `ReplacementInstalled`; the surface is the roots', and a step is owed at once |
| The device's queue family cannot present to it | `ReplacementUnsupported`; the surface is destroyed on the owner's thread, the attempt fails, and the target is declared unrecoverable: [disposed of through its designation](#required-and-optional-dispositions). No second device or queue is made, and nothing migrates |
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
the device cannot present to, is disposed of through the designation the
application gave it (D-22):

- **Optional** — the model marks it unavailable and the session continues. Its
  generations retire as their holds end, and every other target keeps
  presenting on the same device. The controller reports it once, by
  attachment: `readVulkanUnavailability` answers the target and why —
  `UnavailableRecoverySpent` or `UnavailableSurfaceUnsupported` — and an
  application waits on it in `STM`; the most recent 64 are kept. The native
  window is not closed and its destruction is not authorized: the attachment
  stays until the application releases it and its retirement is safe. A target
  that holds nothing more once it is unavailable is forgotten by the model's
  next progress turn, which is why the report is read from the model's
  escalation and not from the target's phase.
- **Required** — the model fails the graphics session
  (`RequiredTargetUnrecoverable`), and the owner's step raises
  `VulkanRequiredTargetFailed` naming each such target, which ends the owner's
  run and reaches the application's checkpoints like any other owner failure
  ([VK-18](glfw.md#the-supervised-graphics-owner)). The ordinary all-exit
  retirement follows.

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
| A swapchain's creation that handed nothing over, or an image view's | A creation call that raised created nothing | That call |
| A frame slot's or a pool record's semaphore or fence | A creation call that raised created nothing; if its recovery does not succeed, the objects made before it are destroyed before the failure is raised | That call |
| A swapchain's creation that handed a generation over | Never: that call retired the generation whatever it answered | Nothing; the construction fails into the episode's fresh construction |

Configured-capacity exhaustion is backpressure, answered before any native
call, and starts no recovery. For each failure:

1. **The attempt.** The operation's model allocation attempt — the managed
   resource's own, or one accounted for the recovery's duration — records the
   failure, and notes a generation the construction already retired as
   `oldSwapchain`. One that cannot be accounted for is no recovery: the failure
   stands as it was.
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
   however much else the pass reclaimed.

No progress, a failed disposal, a refused retry or a second failure ends the
recovery and reports the original failure with the pass's evidence — what it
examined, disposed of and failed to dispose of, and how it ended: as
`AllocationNotRecovered` from a construction, and in `SubmittedNothing` or
`PresentedNothing` from a submission or a presentation. Device loss and a
cancellation during the retry are re-raised as themselves.

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

## Destruction order

| Exit | What is destroyed, in order, on the owner's thread |
| --- | --- |
| A window closed or a target released | That target's swapchain generations — each one's image views, newest first, then its swapchain — and then its surface. The owner writes its terminal record only after the destructions returned, and the main thread then certifies the attachment's facts and releases the window. The device, the instance, the owner and every other target stay live, and nothing is joined. A generation still held retains the surface, and with it everything above. |
| Whole-host exit (D-33) | Every remaining target's surface; then — whole-owner retirement — every surface the lease still owes that no target held (an attachment whose announcement never reached the owner), and the device; then — whole-owner destruction — any surface a creation still in its native call left, the explicit messenger, and the instance, the last call that can reach the capture's callback. Only after that evidence is the owner joined, and only then are windows, the session and the capability released. |

Each step is refused rather than reordered when something that must go first
has not verifiably gone. A destruction that raised is uncertain: it is recorded,
never attempted again, and it retains every parent above it. Running a
destruction and recording what it did are one masked step, so a destruction
that returned always removes its record and one that raised — synchronously or
with a cancellation of its own — always leaves it marked uncertain; a
cancellation is re-raised only after that record exists. The failures are
`SurfaceDestructionFailed`, `RootDestructionFailed` and `RootsRetained`, which
name what was retained. The owner then produces no evidence for what is retained, so the host
keeps the window, the session and every parent, as VK-18's contract requires;
only independent evidence ends that wait. The instance is destroyed only once
the surface bridge's lease is releasable. No timeout, cancellation or cleanup
failure is permission (D-33, LIFE D-4).

## Device loss

A native call the layer classifies as device loss — `VK_ERROR_DEVICE_LOST`,
and nothing else — latches the loss, closes the roots' admission and fails the
model's session with `DeviceLost`, all in one transaction, and raises
`GraphicsDeviceLost` in the call's place. Raised from the owner's construction
it is the owner's first latched failure, which closes the owner's admission at
once and reaches the application's checkpoints through `superviseGraphicsOwner`
while retirement is still running; a later progress step raises it too. The
retirement that follows is the ordinary child-before-parent one — the
controller submits nothing, and Vulkan permits destroying a lost device's
objects without waiting for work — and nothing is recreated or replayed. The
frames treat a loss raised by a submission or a presentation as an unknown
effect, which retains what it concerns; completing teardown across submitted
work and pending presentations is VK-15's. A cleanup failure
during it stays behind the loss. An outcome that is unknown rather than lost is
not loss: it is an ordinary failure, and a destruction whose outcome is unknown
retains its parents.

## State

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| Each root's slot (instance, messenger, device) | The roots | Written by startup, admission and retirement; any thread reads | The owner | The session | Only advances: absent, live, then destroyed or uncertain |
| Target records | The roots | Admission inserts, retirement removes; recovery releases a lost surface and installs its replacement in place | The owner | Admission until destroyed | Removed only by a destruction that returned; a surface released by recovery leaves the record with none until a replacement is installed |
| Disposers | The roots | The generations and the recording each register one when made; a reclamation pass reads them | The owner | The session | Never removed |
| The GPU model | The roots | Admission, retirement, loss | The owner | The session | Never reset |
| The loss latch | The roots | Set once; any thread reads | Any | The session | Never cleared |
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
| Deferred attachments | The controller | Written by a handover whose announcement the port refused; removed by `announceVulkanTarget` once admitted, or by the owner once it has destroyed the surface | Main, owner | Until announced or settled | Cleared by whole-owner retirement |
| Managed records | The recording | Construction inserts; release, replacement and disposal advance each one's standing | The owner | From construction until the model records the disposal | Removed once the model records it; kept, explicitly uncertain, when a destruction raised; never retried |
| Frame storages | The recording | Construction inserts one per target frame slot; disposal removes it | The owner | As its managed record | As its managed record |
| Batch records | The recording | `recordFrame` inserts; a discard or reset removes one after the invalidation returned | The owner | From admission until invalidated | Kept, explicitly uncertain, when an invalidation raised; never retried |
| A recorder | Its `recordFrame` | The consumer action | The owner | One consumer action | Closed when the action returns or raises |
| Slot synchronization | The frames | `Acquisition` creates a slot's three objects and marks its acquisition; `Submission`, `Abandonment` and `Progress` advance each object's state; `Progress` destroys them | The owner | From the slot's first reservation until the target's frames retire | Destroyed once idle; kept, explicitly uncertain, when a call on them raised |
| Presentation pool | The frames | `Acquisition` creates a record and binds it to a frame; `Submission`, `Presentation`, `Abandonment` and `Progress` advance its semaphore and fence; `Presentation` rebinds it to its presentation; `Progress` frees and destroys it | The owner | From the first reservation that needs it until the target's frames retire | Freed by the retirement or settlement the model recorded; destroyed once free and idle; kept, explicitly uncertain, when a call on it raised |
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
  attempt, coalesced resize waiting 16 ms for the newest geometry, a move the
  surface has not caught up with yet, a cancelled move not shortening a later
  one's quiet period, a newer observation restarting it at an unchanged
  surface extent, a newer resize waiting it out under the one-generation
  limit, capacity retiring and destroying first
  and pausing otherwise, the one-generation configuration, per-target
  reservation isolation, an oversized and a zero returned image count refused
  before any view, a failed replacement unable to reacquire from or hand over
  the retired handle, a newer resize surviving an in-flight replacement,
  repeated out-of-date and suboptimal results bounded by the recovery episode
  without a hot loop, a reported result asking for a step at once until it is
  reconciled, a moved observation and a resize after a failed construction
  each settling before the recovery rebuild, and a move cancelled while
  recovery waits leaving a later move its full quiet period, failures after the swapchain destroying exactly what they
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
  surface.

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
foreign target or an unissuable slot; the readback's aligned ranges, bounds,
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
after, and the session then retired with every fence observed.

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
episode. `Allocation recovery`, over the frames' rig, covers: a creation that
ran out of memory made once more after one pass reclaimed a retired
generation; no retry without progress, the original failure reported with the
pass's evidence and its accounting given back; a second failure ending the
recovery; a disposal that failed escalating the session and permitting no
retry despite what else the pass reclaimed; a bounded window that reaches an
eligible generation beyond it only at a later pass, through the carried cursor;
configured-capacity exhaustion as backpressure with no native call; a fresh
swapchain creation retried after reclamation and one that handed a generation
over never retried; a frame slot's synchronization recovered, and its
reservation given back when nothing was; a no-effect submission submitted once
more with its batch recorded once, and answered nothing, naming the pass, when
nothing was reclaimed; a no-effect presentation presented once more; and a
lost surface as the frames report it — an acquisition's reservation given back,
its pool record freed and the target's frames retirable, nothing acquired until
the surface is replaced, and a surface-lost presentation enqueued and holding
its generation until its present fence retires. `Frames`' out-of-date
acquisition now also frees its pool record. The model's suite adds
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
[`docs/vulkan/linux-vk14.md`](vulkan/linux-vk14.md). #250's are retained as
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
| Private roots | A case that must create, poison or destroy roots of its own runs in a child process of the same executable, started with `--private-roots <scenario>`, on the child's own main thread: `vk2-compatibility`, `vk6-capture`, `vk5-bridge`, `vk7-roots`, `vk11-recording`, `vk12-frames`, `vk13-presentation`, `vk14-recovery`, `synchronization-hazard`, and `debug-names`. The child asserts its migrated examples as the proof did — the whole spec, with Hspec's configuration reading left out, so an ambient `HSPEC_*` cannot narrow its verdict — and the parent's example passes only when every one ran and passed. The parent starts no child without consent; a child started directly without it refuses with exit status 3 before looking its scenario up, and an unknown scenario under consent exits 2. |
| Selection | Building, listing and filtering the tree, a `--dry-run`, and a selection that dispatches nothing acquire nothing and start no child. A selection matching no example fails. `--complete`, which the catalog group passes, runs the whole tree with Hspec's configuration reading left out and then fails unless the shared session was acquired once and every private scenario ran and passed, so no ambient setting can turn the group's receipt into a pass for a subset. The consent rules and the migrated proof's pure release, construction, publication and loader-selection examples need no session and run without consent. |
| Consent | Read once, at startup, from `HETOIMASIA_NATIVE_SESSION`, with the GLFW suite's rules for `desktop` and `isolated-x11:<display>`; this suite has no Wayland session. Without it every native example is refused before its body, the session is never acquired, and the run ends with the refusal on stderr and a non-zero exit. |
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

Run it as the group does:

```bash
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --dry-run
```

On Linux the native mode starts an isolated X11 display for the run and needs
no approval. On macOS the suite opens windows on the owner's desktop. The
owner's standing approval covers a run an issue or pull request needs (see
[the GLFW native suite](glfw.md#the-native-suite)), so the agent runs it
without asking, with the consent on that one command:

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
```

See [validation.md](validation.md#the-vulkan-groups-local-evidence) for the
receipt that run leaves and what it is evidence of.
