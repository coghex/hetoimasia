# The Vulkan roots and their window integration

This is the delivered contract of VK-7 ([#219](https://github.com/coghex/hetoimasia/issues/219))
of [the Vulkan backend design](vulkan_backend_design.md): one graphics
session's Vulkan instance, its explicit debug messenger, its one shared device
and a target for every window surface handed to it, owned by the supervised
graphics owner and retired through its protected exit. It covers the design's
D-7, D-9, D-12, D-14, D-15, D-17, D-22, D-29, D-32 and D-33, and P-1, P-5, P-7,
P-8 and P-14 as far as this slice reaches.

Nothing is recorded, submitted or presented yet: there is no swapchain, no
command buffer and no queue submission, and the owner's progress step reports
no rendering work and no render demand — its only deadline is the brief
self-scheduled watch over an attachment whose announcement a full port
deferred, described below. Those are VK-10 through VK-13's. Acting on a target
policy's exhaustion is VK-14's, and completing device-loss teardown across
submitted work is VK-15's.

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
beside VK-6's `Hetoimasia.GPU.Vulkan.Native.Diagnostics`.

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

## Destruction order

| Exit | What is destroyed, in order, on the owner's thread |
| --- | --- |
| A window closed or a target released | That target's surface. The owner writes its terminal record only after the destruction returned, and the main thread then certifies the attachment's facts and releases the window. The device, the instance, the owner and every other target stay live, and nothing is joined. |
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
retirement that follows is the ordinary child-before-parent one — nothing has
been submitted, and Vulkan permits destroying a lost device's objects without
waiting for work — and nothing is recreated or replayed. A cleanup failure
during it stays behind the loss. An outcome that is unknown rather than lost is
not loss: it is an ordinary failure, and a destruction whose outcome is unknown
retains its parents.

## State

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| Each root's slot (instance, messenger, device) | The roots | Written by startup, admission and retirement; any thread reads | The owner | The session | Only advances: absent, live, then destroyed or uncertain |
| Target records | The roots | Admission inserts, retirement removes | The owner | Admission until destroyed | Removed only by a destruction that returned |
| The GPU model | The roots | Admission, retirement, loss | The owner | The session | Never reset |
| The loss latch | The roots | Set once; any thread reads | Any | The session | Never cleared |
| The requested extensions | The controller | Written once by the session's entry | Main | The host | — |
| The lease | The controller | Written by startup; read by handovers | Owner, main | Startup until destruction | Released before the instance is destroyed |
| Deposits | The controller | Written by a construction step; taken by the owner's construction or retirement | Main, owner | Attachment until its construction or retirement | Cleared by whole-owner retirement |
| Attachment to target | The controller | The owner alone | The owner | Admission until the target's surface is destroyed | Kept on an uncertain destruction |
| Rejections | The controller | Written by the owner; any thread reads | Owner | The most recent 64 | Oldest dropped |
| Deferred attachments | The controller | Written by a handover whose announcement the port refused; removed by `announceVulkanTarget` once admitted, or by the owner once it has destroyed the surface | Main, owner | Until announced or settled | Cleared by whole-owner retirement |

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
  layer that offers it;
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
  cleanup that is retained without a retry.

**Native.** The group `test.vulkan-native` runs the native suite below. The
retained per-slice records from the retired proof harness —
[`docs/vulkan/linux-vk7.md`](vulkan/linux-vk7.md) for VK-7, and the VK-2, VK-5
and VK-6 records beside it — stay as the historical evidence of the inputs
they name.

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
| Private roots | A case that must create, poison or destroy roots of its own runs in a child process of the same executable, started with `--private-roots <scenario>`, on the child's own main thread: `vk2-compatibility`, `vk6-capture`, `vk5-bridge`, `vk7-roots`, and `synchronization-hazard`. The child asserts its migrated examples as the proof did — the whole spec, with Hspec's configuration reading left out, so an ambient `HSPEC_*` cannot narrow its verdict — and the parent's example passes only when every one ran and passed. The parent starts no child without consent; a child started directly without it refuses with exit status 3 before looking its scenario up, and an unknown scenario under consent exits 2. |
| Selection | Building, listing and filtering the tree, a `--dry-run`, and a selection that dispatches nothing acquire nothing and start no child. A selection matching no example fails. The consent rules and the migrated proof's pure release, construction, publication and loader-selection examples need no session and run without consent. |
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
target lands on the same device. The private cases carry the migrated
assertions unchanged — VK-2's profile, completion, abandonment and capture,
with the synchronization-validation finding added; VK-6's C-only capture;
VK-5's bridge; VK-7's roots through the destruction order at the host's exit —
and the synchronization control.

Run it as the group does:

```bash
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --dry-run
```

On Linux the native mode starts an isolated X11 display for the run and needs
no approval. On macOS the suite opens windows on the person's desktop, so an
agent first describes that disruption, asks the human user for explicit
approval for that session, and waits for acceptance; then, and only on that
one command:

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
```

See [validation.md](validation.md#the-vulkan-groups-local-evidence) for the
receipt that run leaves and what it is evidence of.
