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
| `proof/Test/Vulkan/Proof/Run.hs` | The whole native run, on the process main thread: environment, loader identity, instance, device, swapchain, completion, abandonment, capture, callbacks, and teardown. |
| `proof/Test/Vulkan/Proof/Findings.hs` | What the run observed, as data. |
| `proof/Test/Vulkan/Proof/Retention.hs` | The release decision: which of teardown's handles the run's own evidence permits destroying, as a pure function. |
| `proof/Test/Vulkan/Proof/RetentionSpec.hs` | That decision's own examples, which `--headless` selects. |
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
runs those examples alone: they open no window, initialize no GLFW, make no
native call, and need no consent, which is what lets a fence timeout, a failed
boundary, and a lost device be exercised at all.

```bash
bash tools/vulkan-proof/run-proof.sh --headless
```

Every other argument is forwarded to the harness as a test option, so an Hspec
selector such as `--match` passes through unchanged.

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
missing and how a human authorizes it. It initializes nothing first. `--headless`
is decided before consent is read, so that mode is refused for nothing and
starts no session; it never falls through to the native procedure and never runs
an empty selection.
