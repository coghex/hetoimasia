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
interop shim in `cbits/` is deliberately throwaway: VK-5 designs the production
surface bridge, and nothing here anticipates it. VK-5 through VK-7 attach their
own focused native cases to this harness until VK-8 migrates them into the
package-native fixture and retires it.

It also adds no production component. `hetoimasia-vulkan-proof` exports no
library; its only component is a test suite, and the only project file that
names the package is the repository's `cabal.project.vulkan`. Neither
`cabal.project` nor `cabal.project.cpu` lists it, so neither
`cabal build all` nor `cabal build all --project-file cabal.project.cpu`
resolves or links the Vulkan binding, and the mandatory validation floor keeps
running on a CI image with no loader. `tools/test/VulkanProof.hs` holds the
examples that keep the rest of that boundary honest.

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
| `proof/Test/Vulkan/Proof/InvocationSpec.hs` | The invocation policy's examples, selected alongside them. |
| `proof/Test/Vulkan/Proof/Spec.hs` | The verdict: pure Hspec assertions over those findings. |
| `proof/Test/Vulkan/Proof/Matrix.hs` | The cited operation and result matrix, with each row labelled observed or specified. |
| `proof/Test/Vulkan/Proof/Record.hs` | The Markdown record. |
| `cbits/` | The throwaway GLFW/Vulkan interop shim and the `dladdr` image provenance. |
| `environment.pin` | Each platform's pinned driver manifest and layer directory. |
| `run-proof.sh` | The only thing that builds this package, and what establishes the project-local environment. |
| `Dockerfile.linux-proof` | The pinned temporary Linux container carrying Mesa Lavapipe, the loader, and the layers. |

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
  released twice, a handle that was never created is never destroyed, and no
  failed destroy is retried;
- teardown reports what it actually did. A cleanup entry whose construction
  never reached it holds no native object, so it is neither counted as a
  destruction nor retained — retaining nothing would hold every parent above it
  for a handle that does not exist — and a release names the objects it
  emptied, so a partial construction's record lists the children that went
  rather than the entry that owns them;
- a release that fails is recorded beside the primary failure that stopped the
  run rather than replacing it. Its object may still be alive, so every parent
  that must outlive it is withheld exactly as a retained child's parents are:
  destroying a device over a command pool whose destruction failed is the same
  invalid teardown as destroying it over one that was never registered. The
  releases that do not depend on it still run.

The successful path is unchanged by all of this: the same ten cleanup entries
in the same order. The capture is the one construction that frees its own two
handles at the end of the path, exactly once, as it always did — so it then
recalls their two registrations and teardown arrives where it always arrived.

`ConstructionSpec.hs` asserts that headlessly, by replacing the native layer
and choosing the step to fail at, because a native run cannot be asked to fail
its fifth `vkCreateSemaphore` or its memory allocation on demand.

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
  the record says that path was taken. A timeout is never promoted to it.

Anything still retained is released by process exit and by nothing else. No
native call here is made preemptible and no native destroy is wrapped in a
Haskell timeout — a destroy abandoned mid-call is worse than one not made — and
the callback trampoline and its storage outlive whatever destruction does run.
The record names every retained handle and the condition that was unmet, on a
run that stopped as well as on one that proved.

The decision is a pure function of the effects and results the run recorded, and
the native cleanup executor calls the same one the examples do. `--headless`
runs those examples and the construction ones alone: they open no window,
initialize no GLFW, make no native call, and need no consent, which is what
lets a fence timeout, a failed boundary, a lost device, and a construction that
stops at a chosen step be exercised at all.

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

## Running it

The proof opens a visible window and presents to it. It therefore needs the same
per-run consent `glfw-native-tests` needs, and supplies none itself. See
[AGENTS.md](../../AGENTS.md) and [docs/glfw.md](../../docs/glfw.md).

On macOS, with the qualified toolchain on `PATH`, and only after a human has
approved that session:

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan-proof/run-proof.sh
```

On Linux, inside the pinned container, where `tools/display/x11.sh` supplies its
own consent for the isolated display it starts and no approval is needed:

```bash
docker build -f tools/vulkan-proof/Dockerfile.linux-proof \
  --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  -t hetoimasia-vulkan-proof .
docker run --rm hetoimasia-vulkan-proof
```

The `route: vulkan-proof` job of `.github/workflows/ci-image.yml` runs exactly
that and uploads the record; dispatch it against a candidate branch with
`--ref`.

`HETOIMASIA_VULKAN_PROOF_RECORD=<path>` writes the record to a file instead of
standard output. `HETOIMASIA_VULKAN_DRIVER_MANIFEST` and
`HETOIMASIA_VULKAN_LAYER_PATH` override `environment.pin` for one run;
`HETOIMASIA_VULKAN_PREFIX` overrides the macOS loader prefix
`tools/toolchain/binding.pin` names.

A run refused for lack of consent exits non-zero with one line saying what is
missing and how a human authorizes it. It initializes nothing first. The mode is
decided before consent is read, so `--headless` is refused for nothing and
starts no session; it never falls through to the native procedure and never runs
an empty selection. A native invocation carrying a test option is refused there
too, in the same way and just as early.
