# The VK-2 Vulkan compatibility proof

A narrow, reproducible qualification harness for
[issue #158](https://github.com/coghex/hetoimasia/issues/158), and nothing else.
It answers the open evidence gate Q-2 of
[the Vulkan backend design](../../docs/vulkan_backend_design.md): which runtime
profile this project can actually require, on which loader and driver, with
which completion and abandonment behaviour, on both selected platforms.

The result it produced is
[docs/vulkan_compatibility_record.md](../../docs/vulkan_compatibility_record.md).
Read that for what was proved. This file says how the harness is built and run.

## What it is not

It is not a backend, not a library, and not a public API. Its GLFW/Vulkan
interop shim in `cbits/` is deliberately throwaway, and nothing production uses
it: the production surface bridge is the GLFW package's own Vulkan interop
component, which VK-5's cases here exercise directly. VK-5 through VK-7 attach
their own focused native cases to this harness until VK-8 migrates them into the
package-native fixture and retires it.

It also adds no production component. `hetoimasia-vulkan-proof` exports no
library; its only component is a test suite, and the only project file that
names the package is the repository's `cabal.project.vulkan`. That project also
names the native backend package `packages/gpu-vulkan/native`, whose production
capture VK-6's cases exercise; the GLFW package `packages/glfw`, with its manual
`vulkan-interop` flag on, whose production loader capability and surface bridge
VK-5's cases exercise; and their local dependency closure — the diagnostics
package, the GPU model, the runtime and the foundation. Neither `cabal.project`
nor `cabal.project.cpu` lists the proof or the native package or sets that flag,
so neither `cabal build all` nor `cabal build all --project-file
cabal.project.cpu` resolves or links the Vulkan binding. That used to be proved for free, because
the floor ran on a CI image with no loader at all; VK-4 provisioned one, so
`tools/test/VulkanProof.hs` now asserts it directly — reading every package
those two project files name and requiring that none depends on the binding —
and holds the rest of that boundary honest besides, including that the Vulkan
project names exactly those seven packages and that only it turns the GLFW
interop component on. That check reads a flag-guarded block as Cabal configures
it — the interop component's dependencies count only where its flag is on —
and every other line of the GLFW package in full.

## How it is arranged

| Part | What it does |
| --- | --- |
| `proof/Main.hs` | Reads consent, runs the native procedure, then lets Hspec decide, then writes the record. That order is the contract. |
| `proof/Test/Vulkan/Proof/Consent.hs` | The per-run authorization guard, with the same rules as the GLFW native suite's. |
| `proof/Test/Vulkan/Proof/Invocation.hs` | Which mode an argument list asks for, and why the native one accepts no test options. |
| `proof/Test/Vulkan/Proof/Run.hs` | The whole native run, on the process main thread: environment, loader identity, instance, device, swapchain, completion, abandonment, capture, callbacks, and teardown. |
| `proof/Test/Vulkan/Proof/Findings.hs` | What the run observed, as data. |
| `proof/Test/Vulkan/Proof/Ownership.hs` | Who owns a handle between the call that created it and the teardown that releases it: the cleanup stack, the ledger, and the teardown executor. |
| `proof/Test/Vulkan/Proof/Construction.hs` | The two composites built from several fallible calls — a frame slot, and the capture buffer with its memory — written once against an open native layer. |
| `proof/Test/Vulkan/Proof/ConstructionSpec.hs` | Their ownership examples, which `--headless` selects: every step of both constructions failed in turn, with a stand-in native layer. |
| `proof/Test/Vulkan/Proof/Retention.hs` | The release decision: which of teardown's handles the run's own evidence permits destroying, as a pure function. |
| `proof/Test/Vulkan/Proof/RetentionSpec.hs` | That decision's own examples, which `--headless` selects. |
| `proof/Test/Vulkan/Proof/Publication.hs` | How the run stops, and the one masked step between a native call and the ledger entry recording what it did. |
| `proof/Test/Vulkan/Proof/PublicationSpec.hs` | The present handoff's cancellation examples, which `--headless` selects: a cancellation delivered across the enqueue, on a fresh slot and on a recycled one, with the native call replaced. |
| `proof/Test/Vulkan/Proof/InvocationSpec.hs` | The invocation policy's examples, selected alongside them. |
| `proof/Test/Vulkan/Proof/Spec.hs` | The verdict: pure Hspec assertions over those findings. |
| `proof/Test/Vulkan/Proof/Matrix.hs` | The cited operation and result matrix, with each row labelled observed or specified. |
| `proof/Test/Vulkan/Proof/Diagnostics.hs` | VK-6's native cases: a second session, on its own instance, whose only callback is the production C capture. |
| `proof/Test/Vulkan/Proof/DiagnosticsSpec.hs` | Their verdict, asserted over what that session observed once its capture lifetime has ended. |
| `proof/Test/Vulkan/Proof/Bridge.hs` | VK-5's native cases: a third session through the GLFW package's production Vulkan interop component — its loader capability, a loader-aware session behind a protected host, and a surface created and destroyed under an attachment. |
| `proof/Test/Vulkan/Proof/BridgeSpec.hs` | Their verdict, asserted over what that session observed once it and its instance have ended. |
| `proof/Test/Vulkan/Proof/Record.hs` | The Markdown record, with VK-6's and then VK-5's sections after the VK-2 findings. |
| `cbits/` | The throwaway GLFW/Vulkan interop shim and the `dladdr` image provenance. |
| `run-proof.sh` | The only thing that builds this package, the native backend package, and the GLFW package's Vulkan interop component, and what establishes the project-local environment from the provisioned native prefix. |

The native run and the assertions are separate on purpose. The run tears its
session down — including the instance, when it may — before Hspec starts, so the
verdict is computed after every callback-producing teardown has finished, and so
no Hspec worker thread can ever reach a GLFW call.

## Every handle is owned before the next fallible step

Teardown can only decide over handles it was given, so nothing this harness
creates is allowed to exist without a cleanup owner — not even for the one
native call that follows it.

A handle whose whole construction is a single call is registered inside the
same masked step that creates it, so neither a synchronous failure nor a
cancellation delivered at the handoff can leave it orphaned.

Two of the harness's resources are not single calls. A frame slot is two
semaphores, two fences, a command pool and a command buffer; the capture is a
buffer, an allocation bound to it, a submission, a readback and a present. For
those, `Construction.hs` registers every release *before* the first native call
of the construction runs, against places that are empty until each child
exists. So:

- a failure at any step of either slot — the second semaphore of the first, or
  any step of the second while the first is already whole — releases exactly
  the children that exist, in dependency order, before the device registered
  above them is destroyed. Without that, `vkDestroyDevice` ran over live device
  children, which `VUID-vkDestroyDevice-device-05137` forbids;
- a failure anywhere in the capture path — creating the buffer, allocating or
  binding its memory, acquiring, submitting, waiting, mapping or presenting —
  leaves both the buffer and its allocation to a teardown that frees them after
  the boundary has established that the copy completed, or retains them and
  says why if it has not. An unretired present does not hold them: a present is
  work the presentation engine does on a swapchain image, and neither is an
  object it touches;
- a command buffer is owned through the command pool that allocated it, which
  is what `vkDestroyCommandPool` says, rather than freed a second time on its
  own;
- an object is taken out of its place before it is destroyed, so nothing is
  released twice and a handle that was never created is never destroyed. A
  place records three states, not two: empty, holding, and *not released* — the
  destroy was attempted and did not complete. A failed destroy is never
  retried, and the place keeps the reason instead of the object, so a release
  the capture path performs itself at the end of its own path is as visible to
  teardown as one teardown performed;
- teardown reports what it actually did. A cleanup entry whose construction
  never reached it holds no native object, so it is neither counted as a
  destruction nor retained — retaining nothing would hold every parent above it
  for a handle that does not exist — and a release names the objects it
  emptied, so a partial construction's record lists the children that went
  rather than the entry that owns them;
- a release that fails is recorded beside the primary failure that stopped the
  run rather than replacing it. An entry that owns several children reports all
  of their failures and all of their destructions, so one child's failure
  neither hides a second nor denies the siblings that did go. Its object may
  still be alive, so every parent that must outlive it is withheld exactly as a
  retained child's parents are: destroying a device over a command pool whose
  destruction failed is the same invalid teardown as destroying it over one
  that was never registered. The releases that do not depend on it still run.

The successful path is unchanged by all of this: the same ten cleanup entries
in the same order. The capture is the one construction that frees its own two
handles at the end of the path, exactly once, as it always did — so it then
recalls their two registrations and teardown arrives where it always arrived.

`ConstructionSpec.hs` asserts that headlessly, by replacing the native layer
and choosing the step to fail at, because a native run cannot be asked to fail
its fifth `vkCreateSemaphore` or its memory allocation on demand.

## What a call did is owned as a handle is

`vkQueuePresentKHR` has enqueued its semaphore waits and chained its present
fence the moment it returns, and the ledger entry saying so is the only
evidence teardown has that the presentation is owed. A cancellation taken
between the two leaves an obligation that exists on the device and nowhere in
the run's own record, and teardown then destroys the present fence, the
presentation semaphore and the swapchain behind it — a use-after-free rather
than a failed assertion.

So the call and that entry are one masked step, exactly as a create and its
registration are. `Publication.hs` is that step. The mask covers the native
presentation call and the `IORef` write that records its effect. The driver may
block inside the call; the binding's `safe` import does not make it interruptible
or bound cancellation latency. Explicit fence and acquire waits stay outside
the mask with their existing cancellation behaviour, which may also defer
cancellation until native return. No native call becomes preemptible, and no
destroy is wrapped in a timeout. A cancellation deferred across the handoff is
taken once the entry is in and stops the run at the presentation step, carrying
its own failure, rather than escaping as an unexpected exception at no step at
all. The result recorded is the one the call reported; a cancellation that
arrived afterwards happened to the run, not to the present.

`PublicationSpec.hs` asserts that headlessly, with `vkQueuePresentKHR` replaced
by a stand-in and a real `throwTo` delivered at the first point the code under
test permits one — on a fresh slot and on a recycled slot whose earlier present
was retired. A native run cannot be asked to be cancelled at a chosen instant,
and the cancellation is deterministic rather than timed: it is armed by waiting
for the killing thread to block on the masked target, so there is no sleep and
no retry.

```bash
bash tools/vulkan-proof/run-proof.sh --headless --match cancellation
```

## Teardown is decided, not promised

A run that finishes owes nothing and releases all ten of its cleanup entries, in
order. A run that stops may owe something, and teardown does not destroy through
it.

`VK_EXT_swapchain_maintenance1` permits destroying a presentation semaphore only
after its present fence signals, and a swapchain only after the fences of all
past presents signal. Device idle is not that evidence: a present is work for
the presentation engine rather than for a queue, so `vkDeviceWaitIdle` can
return `VK_SUCCESS` with a present still outstanding. Destroying regardless is
the device-idle teardown fallback
[the backend design](../../docs/vulkan_backend_design.md) forbids at P-12 and
Q-2, and it is a use-after-free rather than a failed assertion, so no verdict
computed afterwards can catch it.

So teardown asks `Retention.hs`, and obeys it:

- a present-fence wait that returns `VK_TIMEOUT`, or any other non-success
  result that is not device loss, stops the run as it always did, and teardown
  then retains that slot's present fence and presentation semaphore, the
  swapchain, and every parent above them — the device, the surface, the
  instance, the window, the explicit messenger, the callback trampoline, and
  `glfwTerminate`, which would destroy the retained window. The slot's command
  pool, rendering fence and acquisition semaphore still go: they are queue
  objects, and the boundary does establish their completion;
- a teardown-boundary failure that is not device loss prohibits every release
  whose safety that boundary was to establish, and teardown reports the failure
  and the retained handles rather than continuing through them;
- a present rejected with `VK_ERROR_OUT_OF_DATE_KHR` or
  `VK_ERROR_SURFACE_LOST_KHR` still enqueued its semaphore waits, so its fence
  and semaphore stay pending; the error result alone releases nothing;
- the only route from retained to destroyed, apart from device loss, is the
  present fence itself signalling — a bounded wait teardown takes at the
  boundary. It discharges the presentation obligation and nothing else: an
  unresolved boundary failure still holds;
- device loss is its own disposition. The specification permits destroying a
  lost device's objects without waiting for work that may never complete, and
  the record says that path was taken. A timeout is never promoted to it. The
  waiver is about completion and about nothing else: a lost device's children
  are still objects that must be destroyed before it, so a child that was not
  released still withholds every parent that has to outlive it, on this route
  as on the ordinary one.

Anything still retained is released by process exit and by nothing else. No
native call here is made preemptible and no native destroy is wrapped in a
Haskell timeout — a destroy abandoned mid-call is worse than one not made — and
the callback trampoline and its storage outlive whatever destruction does run.
The record names every retained handle and the condition that was unmet, on a
run that stopped as well as on one that proved.

The decision is a pure function of the effects and results the run recorded, and
the native cleanup executor calls the same one the examples do. `--headless`
runs those examples, the construction ones, and the present handoff's
cancellation ones alone: they open no window, initialize no GLFW, make no
native call, and need no consent, which is what lets a fence timeout, a failed
boundary, a lost device, a construction that stops at a chosen step, and a
present cancelled between its enqueue and its record be exercised at all.

```bash
bash tools/vulkan-proof/run-proof.sh --headless
```

Every other argument is forwarded to the harness as a test option, so an Hspec
selector such as `--match` reaches the headless examples unchanged.

The native run accepts no test options, and refuses rather than ignoring one.
Its record carries `Verdict: pass` or `Verdict: fail` as a claim about the whole
contract, and a selector that ran a subset of the examples would still have its
result written as that claim — a run that stopped could be recorded as a pass
because the examples that assert over the native outcome were never selected.
For the same reason the native verdict is computed through Hspec's own
primitives with the configuration-reading step left out, so neither `./.hspec`,
`~/.hspec`, nor an ambient `HSPEC_*` can narrow what the record speaks for.
Selecting among the pure examples is free of that, because they write no record.

## VK-6: validation capture

After the VK-2 session has torn down, the native run starts a second session for
[VK-6](../../docs/vulkan_diagnostics.md): its own instance, with no window and no
surface, owned by a `withDiagnosticCapture` lifetime from the diagnostics
package. Both of its messengers — the one chained into `VkInstanceCreateInfo`
and the explicit one — are the native backend package's, and both register the
production C callback with the capture's storage as user data. No Haskell
callback is installed on that instance, so none of its Vulkan calls can re-enter
Haskell, and two of them go through genuine `unsafe` foreign imports of the
instance's and the device's own dispatch pointers:

- `vkSubmitDebugUtilsMessageEXT`, delivering one chosen message to the explicit
  messenger from inside the call; and
- `vkCmdSetViewport` with a viewport count of zero, a short recording command
  the validation layer rejects with
  `VUID-vkCmdSetViewport-viewportCount-arraylength`, so a validation error
  reaches the C callback from inside an unsafe recording call.

This is a focused proof operation, not the audited recording subset, which is
VK-11's. Around every native call the session reads the capture storage's own
counters, so each report is attributed to the call it arrived in by the
callback's synchronous effect, and the delivered records are attributed back to
those calls in admission order. `vkDestroyInstance` is the last thing the
lifetime's body does, after the explicit messenger has gone, through the native
package's `destroyInstanceQuiesced`, whose return is the quiescence evidence the
lifetime demands; the verdict is read only after the lifetime has ended.

`DiagnosticsSpec.hs` then requires that the callback lies in the proof
executable's own image — a Haskell callback would be an adjustor the runtime
allocated, in no image at all — and that no Haskell callback was installed; that
instance creation reported through the create-info chain; that the submitted
message arrived, exactly once, inside its unsafe call; that the zero viewport's
validation error arrived inside its unsafe call and latched the error state;
that `vkDestroyInstance` reported after the explicit messenger was destroyed and
every one of those reports was delivered; that the verdict delivered every
report offered, left nothing undelivered and had a worker that completed; that
the provoked error is the only issue and the only error; and that the native
package's recorded FFI configuration matches `tools/toolchain/binding.pin`. The
record's VK-6 section prints each step's reports, every delivered record, the
verdict, and that configuration.

The session runs the design's capture defaults except for the text budget,
which it raises from 4 KiB to 16 KiB and prints in its record. The first macOS
run at the default budget cut exactly one record — MoltenVK's routine info
report listing its 145 supported extensions, during `vkCreateInstance` — and the
truncation rightly made that verdict not clean; Lavapipe's reports all fit. The
default stays as P-11 set it. What it should be, or whether routine driver
commentary should count against a clean verdict, is left to VK-7 and VK-8, which
run production sessions under it; this session only needs every report to
arrive whole.

The record's source digest covers the production packages this session builds
against as well as the harness: `run-proof.sh` hashes the native backend
package, the diagnostics package, the GPU model and the foundation beside its
own directories, so a change to the production capture moves the digest.

The Linux record from the `vulkan-proof` route is retained as
[`docs/vulkan/linux-vk6.md`](../../docs/vulkan/linux-vk6.md), and the record of a
local macOS run under the human's explicit approval for that session as
[`docs/vulkan/macos-vk6.md`](../../docs/vulkan/macos-vk6.md); both carry one
source digest. VK-8 migrates these cases into the package-native fixture and
retires this route for them.

## VK-5: the loader-aware surface bridge

After VK-6's session, the native run starts a third for
[VK-5](../../docs/glfw.md#vulkan-interop), through the GLFW package's own
`vulkan-interop` component and nothing of this harness's shim but its `dladdr`
provenance. The VK-2 run handed GLFW the binding's entry point through the
throwaway shim and never took it back, so this session first restores GLFW's
default through that shim and says so; every loader setting it then observes is
one the production shim made. It runs these cases against the production
capability and bridge:

- **One loader.** `allocLoaderIntegration` builds the capability from the
  binding's own `vkGetInstanceProcAddr`. The session records that entry point's
  address and image beside the binding's own, and — while a loader-aware session
  is live — the setting the production shim handed GLFW, what GLFW itself
  resolves `vkGetInstanceProcAddr` to through `glfwGetInstanceProcAddress`, and
  the image each side resolves `vkCreateDevice` into for the instance it creates.
- **Extensions.** `requiredInstanceExtensions` copies the platform's names, and
  the instance is created with exactly those.
- **A surface for an attached window.** A protected host over the loader-aware
  session holds one hidden window. `attachWindowGraphicsWithSurfaces` attaches
  a scripted owner whose construction step calls `createWindowSurface` against a
  lease of that instance; the binding is then asked about the handle, and while
  it is owed, the attachment's `DependentsDisposed` fact and the instance's
  release are both recorded as refused. Another OS thread, not the owner,
  discharges the obligation through Vulkan, after which both are recorded as
  granted, and the instance is destroyed only once the host has exited.
- **The reset after termination.** Once the session has ended, the setting the
  shim holds, and the capability's own use.
- **The reset after a failed initialization.** On Linux, a second capability's
  session requests Wayland with `WAYLAND_DISPLAY` naming a display no compositor
  serves, so `glfwInit` fails after the capability was installed, and the same
  two readings are taken. GLFW 3.4's Cocoa initialization has no failure an
  application can provoke, and Cocoa is the only backend macOS admits, so on
  macOS this case records itself as not reachable and its example is pending;
  the seam example `restores the default after a failed initialization` holds
  that path headlessly on every platform.

GLFW offers no way to read back the loader hint it was given, so "the setting"
is the value the production shim last handed `glfwInitVulkanLoader`, which it
records with each call; that shim is the hint's only production writer.
`BridgeSpec.hs` requires that the capability's entry point is the binding's, by
address and image; that GLFW holds and resolves exactly that address while the
session is live, and resolves an instance entry point into the binding's image;
that the copied names include `VK_KHR_surface` and the platform's surface
extension; that the surface was created and accepted; that retirement and
release were refused while it was owed and granted once another thread
destroyed it; and that the shim holds null and the capability is restored after
termination and, where reachable, after the failed initialization. The record's
VK-5 section prints each of these.

The record's source digest covers the GLFW package and the runtime as well, so a
change to the bridge moves it. The Linux record from the `vulkan-proof` route is
retained as [`docs/vulkan/linux-vk5.md`](../../docs/vulkan/linux-vk5.md); a
macOS record is retained beside it only for a local run under the human's
explicit approval for that session.

## Running it

The proof opens a visible window and presents to it. It therefore needs the same
per-run consent `glfw-native-tests` needs, and supplies none itself. See
[AGENTS.md](../../AGENTS.md) and [docs/glfw.md](../../docs/glfw.md).

On macOS, with the qualified toolchain on `PATH`, and only after a human has
approved that session:

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan-proof/run-proof.sh
```

On Linux, inside the published CI image the committed
`tools/ci-image/descriptor.json` names, where `tools/display/x11.sh` supplies
its own consent for the isolated display it starts and no approval is needed:

```bash
docker run --rm --volume "$PWD:/candidate" --workdir /candidate \
  "$(python3 -c 'import json; d = json.load(open("tools/ci-image/descriptor.json")); print(d["reference"] + "@" + d["digest"])')" \
  bash tools/display/x11.sh -- bash tools/vulkan-proof/run-proof.sh
```

VK-4 provisioned the loader, driver, and layers into that image, so the proof
now runs against exactly the inputs ordinary Linux validation runs against and
the throwaway container this used to need is gone. The `route: vulkan-proof`
job of `.github/workflows/ci-image.yml` runs the command above and uploads the
record; dispatch it against a candidate branch with `--ref`.

`HETOIMASIA_VULKAN_PROOF_RECORD=<path>` writes the record to a file instead of
standard output. Every Vulkan path comes from the native prefix rather than
from a pin of this package's own; relocating one input for a run is
`tools/native/vulkan.py`'s business, through the `HETOIMASIA_VULKAN_*`
variables [docs/validation.md](../../docs/validation.md) describes, and an
override locates an input without waiving its qualification.

A runtime library search override is refused outright: `run-proof.sh` exits 2
naming `LD_LIBRARY_PATH`, `LD_PRELOAD`, `LD_AUDIT`, or a `DYLD_*` search or
insertion variable before it checks anything, because the loader is resolved
when the proof starts and such a variable could substitute another one. The
harness then stops unless the binding's loader image is
`HETOIMASIA_VULKAN_QUALIFIED_LOADER`, the recorded loader `prepare` exports.

A run refused for lack of consent exits non-zero with one line saying what is
missing and how a human authorizes it. It initializes nothing first. The mode is
decided before consent is read, so `--headless` is refused for nothing and
starts no session; it never falls through to the native procedure and never runs
an empty selection. A native invocation carrying a test option is refused there
too, in the same way and just as early.
