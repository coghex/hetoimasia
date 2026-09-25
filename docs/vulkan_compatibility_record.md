# The VK-2 native Vulkan compatibility record

This is the answer to [Q-2](vulkan_backend_design.md#q-2-what-compatibility-and-completion-contract-should-the-backend-require),
the deliberately open evidence gate of the Vulkan backend design: which runtime
profile this project may require, on which loader and driver, with which
completion and abandonment behaviour, on both selected platforms. It is the
record [#158](https://github.com/coghex/hetoimasia/issues/158) asks for, and it
is what VK-4 through VK-17 may assume.

It is not a changelog. When the profile moves, this file is rewritten to
describe the new one, and the proof that established it is named by commit.

Each retained record identifies the sources it was produced from twice over: by
a SHA-256 over the content of every file the harness is built from, which is
exact and which a reader can recompute, and by the repository revision, which is
the convenient one. The revision is the commit that introduced the harness
rather than the one that retains the record — evidence is produced before it can
be committed — and inside the Linux container there is no checkout to resolve
one from at all. The digest is what pins the record either way.

It also does something the revision cannot: the two retained records carry the
*same* digest, `f50261a8…`, computed independently — on macOS from a Git
checkout, and inside the Linux container from the files the recipe copied into
it, with no checkout to consult. That is direct evidence the two platforms
proved one tree rather than two that were believed to match.

VK-4 later ran the same harness against the environment it provisions rather
than against the temporary one this record was produced on, and retained what
that produced beside these: [`docs/vulkan/macos-provisioned.md`](vulkan/macos-provisioned.md)
and [`docs/vulkan/linux-provisioned.md`](vulkan/linux-provisioned.md). Those are
a separate pair, not a revision of this one — they consumed different files by
a different discovery route, and each says which. This record and the two it
summarises are unchanged.

**Verdict: pass on both platforms.** The design's 1.3 minimum, its present-fence
retirement, and its `VK_EXT_swapchain_maintenance1` image release all hold. No
part of the contract was weakened to reach it.

## What produced it

`tools/vulkan-proof` was the harness. It is retired: VK-8 moved its cases,
unchanged, into the Vulkan native suite (see "Reproducing it" below), and
[its README](../tools/vulkan-proof/README.md) now only points here. The raw
records it wrote, with the commands that produced them at the time, are retained
beside this file:

| Platform | Record | Produced by |
| --- | --- | --- |
| macOS 26.6 on Apple M3 Max (arm64) | [`docs/vulkan/macos.md`](vulkan/macos.md) | `HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan-proof/run-proof.sh`, after the owner approved that session |
| Linux x86_64, Mesa 25.2.8 Lavapipe | [`docs/vulkan/linux.md`](vulkan/linux.md) | the `route: vulkan-proof` job of `.github/workflows/ci-image.yml`, dispatched against this branch, which names the commit it proved in its own job summary |

Each record carries its own operation and result matrix, its own transcript, and
the exact environment its process ran in. This file states what the two of them
together settle, and what they do not.

## The proved profile

| What | macOS | Linux |
| --- | --- | --- |
| Loader | LunarG 1.3.296, `/usr/local/lib/libvulkan.1.3.296.dylib` | 1.3.275, `/lib/x86_64-linux-gnu/libvulkan.so.1` |
| Driver | MoltenVK 1.4.0 on an Apple M3 Max, named by absolute `VK_DRIVER_FILES` | Mesa 25.2.8 Lavapipe (`llvmpipe`, LLVM 20.1.2), named by absolute `VK_DRIVER_FILES` |
| Device API version | 1.3.323 | 1.4.318 |
| Conformance version | 1.4.2.0 | 1.3.1.1 |
| Validation layer | `VK_LAYER_KHRONOS_validation` 1.3.296, verified present in the loaded chain, zero error records | `VK_LAYER_KHRONOS_validation` 1.3.275, verified the same way, zero error records |
| 1.3 core features | `dynamicRendering` and `synchronization2` supported, requested, accepted | the same |
| Portability | `VK_KHR_portability_enumeration` advertised and enabled on the instance; `VK_KHR_portability_subset` advertised and enabled on the device | `VK_KHR_portability_enumeration` advertised and enabled on the instance too; `VK_KHR_portability_subset` not advertised, so not enabled |
| Maintenance variant | `VK_EXT_swapchain_maintenance1`, `swapchainMaintenance1` accepted | the same |
| Its dependencies | `VK_KHR_swapchain`, `VK_EXT_surface_maintenance1`, `VK_KHR_get_surface_capabilities2`, all present and enabled | the same |
| Release entry point | `vkReleaseSwapchainImagesEXT` resolved; `…KHR` did not | the same |
| Surface extension | `VK_EXT_metal_surface` | `VK_KHR_xcb_surface` |
| Presentation | `PRESENT_MODE_FIFO_KHR`, `FORMAT_B8G8R8A8_UNORM`, three images at 640×480 | `PRESENT_MODE_FIFO_KHR`, `FORMAT_B8G8R8A8_UNORM`, four images at 320×240 |
| Capture | `TRANSFER_SRC` read back and matched | the same |
| Callbacks | 77 deliveries, 1 during teardown, 3 during instance destruction | 84 deliveries, none during teardown, 1 during instance destruction |
| Teardown | ten releases, none failed | the same ten, none failed |

The two halves of portability are separate and only one of them is about
MoltenVK. `VK_KHR_portability_enumeration` is an *instance* extension that lets
the loader enumerate portability drivers at all; the proof enables it wherever
the loader advertises it, which includes Linux, where it then finds no such
driver. `VK_KHR_portability_subset` is the *device* extension a portability
driver advertises to say which parts of Vulkan it does not fully implement, and
that one appears on MoltenVK and not on Lavapipe. A slice that conflates them
will enable the wrong one on the wrong platform.

Downstream slices may require Vulkan 1.3 with dynamic rendering and
synchronization2, the EXT maintenance variant with present fences and image
release, and a presentation format carrying `TRANSFER_SRC`. That is the whole of
what this proof settles; anything not listed here is not settled by it.

## Findings the raw records do not say in prose

### The macOS default driver cannot satisfy the contract, and is not the one used

The LunarG SDK's own ICD manifest at `/usr/local/share/vulkan/icd.d/` selects the
SDK's MoltenVK, whose manifest declares API 1.2.0 — below D-12's accepted
minimum. Homebrew's MoltenVK 1.4.0 sits under `/opt/homebrew` with a manifest the
default loader never reads.

So the proof names the driver rather than accepting discovery. At the time of
this record that selection lived in `tools/vulkan-proof/environment.pin`, which
pinned the Homebrew manifest by absolute path; VK-4 (#208) retired that file and
moved the same selection into `tools/native/vulkan.pin`, which the native recipe
qualifies by digest and provisions into `<native prefix>/vulkan`. Either way
the runner — `run-proof.sh` then, `tools/vulkan/run.sh` now — passes the
selected manifest as `VK_DRIVER_FILES`, which is the loader's own documented
override. The harness additionally cleared, as the native suite still clears, `VK_ICD_FILENAMES`,
`VK_ADD_DRIVER_FILES`, `VK_ADD_LAYER_PATH`, `VK_INSTANCE_LAYERS`, and the loader's
select/disable variables out of its own environment before initializing, and
records which it removed — a run whose driver selection could have been
overridden from outside would not be evidence about the pinned one.

The standard loader is still the one in use, and it is still shared: D-14 holds.
Only the driver the loader is told to load changed.

### "One loader" is an observation, not two searches that agreed

GLFW 3.4 finds a loader by itself unless told otherwise. Rather than find one and
compare version strings, the proof resolves `vkGetInstanceProcAddr` through the
Haskell binding's own linked loader and hands *that exact function pointer* to
`glfwInitVulkanLoader` before `glfwInit`. It then checks what each side resolves,
by address and by the image `dladdr` attributes the address to.

On macOS both sides return `vkGetInstanceProcAddr` and `vkCreateDevice` at
identical addresses in `/usr/local/lib/libvulkan.1.3.296.dylib`. Two independently
found libraries exporting the same names cannot produce that.

One consequence is worth stating because it looks alarming and is not: a
*device-level* entry point resolves into the validation layer's image, not the
loader's — `QueueSubmit2` attributes to `libVkLayer_khronos_validation.dylib`, and
so does the maintenance release entry point. That is the enabled layer chain
doing its job. One loader dispatching through the layers it was asked to enable is
exactly the arrangement D-14 selects.

### The maintenance extension is EXT here, and the binding tries both spellings

`vulkan-3.27` resolves image release with
`getFirstDeviceProcAddr ["vkReleaseSwapchainImagesEXT", "vkReleaseSwapchainImagesKHR"]`
and exposes the KHR types as the EXT ones' aliases. So the Haskell names do not
say which entry point a device actually answered for.

The proof asks the device directly for both spellings and records the answer.
Neither platform resolves the KHR name: only `vkReleaseSwapchainImagesEXT`
answers on MoltenVK 1.4.0, and only `vkReleaseSwapchainImagesEXT` answers on
Mesa 25.2.8 Lavapipe either. Two drivers as different as those agreeing on it is
worth more than one would be. The KHR variant is an unproved alias on both
selected platforms; do not write code that assumes it, and do not read the
binding's KHR-shaped Haskell names as evidence that it resolved.

### A `VkInstanceCreateInfo` messenger is not a general messenger

The proof installs two debug-utils messengers: one chained into
`VkInstanceCreateInfo`, one created explicitly. An early version of the proof
tried to deliver an injected message through the chained one after destroying the
explicit one, and nothing arrived.

That is correct behaviour, not a driver defect: the extension uses a create-info
messenger for `vkCreateInstance` and `vkDestroyInstance` and for nothing else.
The proof therefore observes destruction-time reentry where it actually happens —
inside `vkDestroyInstance`, with the explicit messenger already destroyed and the
Haskell callback storage still live. VK-6 should not expect a chained messenger
to carry ordinary diagnostics.

It follows that the explicit messenger has to outlive every child resource. The
proof destroys it immediately before the instance and therefore after the
swapchain, the device, the surface and the window; an earlier teardown would
leave the diagnostics those destructions emit — a device's leak reports among
them — with nowhere to go, while the record still reported zero validation
errors. That window is not hypothetical, and it is platform-specific: one
diagnostic arrives during teardown on macOS that a messenger destroyed any
earlier would have missed, and none does on Linux. A harness that only ever ran
on Lavapipe would have no reason to notice the gap.

### Callback reentry is real, and some of it had to be elicited

Creation and destruction produce plenty of naturally emitted diagnostics. On
macOS: 54 callbacks during `vkCreateInstance`, 16 during `vkCreateDevice`, 1
during teardown, 3 during `vkDestroyInstance`. On Linux: 55, 14, none, and 1,
plus 12 during messenger creation that macOS did not produce at all.

Those counts are not stable across runs or across driver versions, and nothing
asserts them; they are here to show the shape of the reentry, and the retained
records are what they are taken from. `tools/test/VulkanProof.hs` checks that
this summary still quotes the same totals the records carry, because a summary
that quietly drifts from its own evidence is worse than one that quotes none. All of them re-enter Haskell from inside a
Vulkan call on the binding's `+safe-foreign-calls` imports.

Submission produced none of its own. Rather than claim reentry that did not
happen, the proof elicits it with `vkSubmitDebugUtilsMessageEXT` at chosen points
and labels those deliveries as injected in a separate column. Every phase table
in the records distinguishes the two.

### "Zero validation errors" is a claim about coverage, not just about count

The sentence is worth nothing unless three things are true, and each of them can
fail quietly, so the proof checks each:

- **The layer was actually loaded.** Requesting `VK_LAYER_KHRONOS_validation`
  does not load it — the loader's own `VK_LOADER_LAYERS_DISABLE` can drop a
  requested layer, and `vkEnumerateInstanceLayerProperties` would still list it,
  because that reports what is *available*. The proof instead resolves a device
  entry point and checks the image it lands in, which is the layer's own on both
  platforms. It clears that filter and the implicit-layer paths out of its
  environment first, and records what it cleared.
- **Nothing else was in the chain.** Implicit layers need no request from the
  application at all, so clearing `VK_IMPLICIT_LAYER_PATH` is not enough: that
  restores the loader's *default* implicit search rather than disabling it, and
  `VK_LAYER_PATH` governs explicit layers only. After scrubbing, the proof sets
  `VK_LOADER_LAYERS_DISABLE=~implicit~` and records the policy, so the chain is
  the explicit layers it asked for and nothing a machine happened to have
  installed. The effect is visible in the Linux record: Mesa's implicit
  `VK_LAYER_MESA_device_select` is present on the machine and absent from the
  enumeration the run reports.
- **Something was listening for the whole session.** A messenger destroyed
  before the device would miss every diagnostic the device's own destruction
  emits. See the section above.
- **Teardown itself succeeded.** Every release runs in reverse registration
  order and a failure never stops the ones after it — but the failures are
  collected and fail the verdict, because a `vkDeviceWaitIdle` that returned
  device loss is not a clean session however few validation messages arrived.

### A fence is not a host-visibility barrier

The capture copies the presented image into a host-visible, host-coherent buffer
and reads it back after the submission fence signals. That is not sufficient on
its own: a fence's access scope covers device accesses, so it does not make the
transfer write available to the host domain, and host-coherent memory only
removes the need to invalidate a mapped range. The proof issues a buffer memory
barrier from `TRANSFER_WRITE` to `HOST_READ` before the fence, so the bytes it
compares are a guarantee rather than the implementation's habit. A capture path
that omits this usually appears to work, which is what makes it worth stating.

### The presented extent is the framebuffer's, not the window's

The proof asks for a 320×240 window on both platforms. The macOS surface reports
a 640×480 current extent on a Retina display; the Linux surface, on an Xvfb
display with no scaling, reports 320×240. Swapchains are built from the surface's
extent, never from the window size. VK-5 and VK-10 inherit that, and a consumer
that reasons from the requested window size will be wrong by the backing scale
factor on exactly the platform where nobody tests it first.

### Whether a present fence is already signalled is a race, not a property

The proof reads each present fence's status immediately after
`vkQueuePresentKHR` returns and before waiting on it. That reading is not
stable. Across the retained records:

| Platform | Pre-wait present-fence status |
| --- | --- |
| macOS | uniform — every frame reads `VK_NOT_READY` |
| Linux | mixed — both `signalled` and `not ready` occur within the one record |

Successive dispatches of the identical Linux container also disagree with each
other about which frames are which.

No frequency is claimed here, and none should be: the counts move between runs,
so a quoted rate would be describing a coin toss. The two words that do carry
weight — *uniform* and *mixed* — are read back out of the records' own frame
tables by `tools/test/VulkanProof.hs`, which fails if either stops being true.

That variability is exactly why D-9's rule has to be a rule rather than a
precaution. A design that retired a presentation semaphore on the rendering
fence would be wrong on every frame on MoltenVK, and on Lavapipe would be wrong
only sometimes — which is the worse failure, because it survives testing. The
proof therefore records the pre-wait status and asserts nothing about it; what
it asserts is that the fence was waited for and signalled, on every frame, on
both platforms.

## What is deliberately not proved

- **KHR maintenance.** `VK_KHR_swapchain_maintenance1` is not advertised by
  MoltenVK 1.4.0 and its entry point does not resolve there. Treating it as an
  alias of the EXT variant needs its own proof on a driver that offers it.
- **Device loss.** No device loss was induced. The matrix's device-loss rows are
  specification rows and say so. What they establish is which destruction the
  specification authorizes after a loss — not that this project has observed one.
- **Every rare result.** Out-of-memory returns, `VK_ERROR_OUT_OF_DATE_KHR`,
  surface loss, and the `oldSwapchain` failure case are specification rows. VK-12
  and VK-14 owe injected-seam evidence for the paths that matter to them; this
  proof establishes the rules they must satisfy, not the occurrences.
- **Performance.** Lavapipe is a software driver and MoltenVK is a translation
  layer. Both give API and image-correctness evidence and neither gives hardware
  performance coverage.
- **Hosted macOS CI.** macOS evidence is local and requires a human's per-run
  approval, exactly as D-3 and AGENTS.md require. Nothing here changes that.
- **The production environment.** At the time of this proof the CI image carried
  no Vulkan input and the native manifest described GLFW alone; promoting the
  recipe was left to VK-4 rather than taken as a side effect here. VK-4 (#208)
  has since done it, and the
  [provisioned records](vulkan/linux-provisioned.md) are that environment's own
  evidence. This record remains what it was: a proof of the profile, not of the
  environment that now carries it.
- **Multiple windows, resize, and a triangle.** One surface, one swapchain, no
  pipeline, no shader. VK-10 and VK-17 own those.

## Reproducing it

The proof's cases are now the Vulkan native suite's `vk2-compatibility` case,
run in a child process with roots of its own, and the validation group
`test.vulkan-native` runs it — on Linux on every change that affects it, on the
published image and an isolated X11 display, and on macOS as the solver's local
pre-PR evidence. The toolchain must be the one
[`docs/toolchain.md`](toolchain.md) pins; the runner refuses outright otherwise.
Every instance it creates now also enables synchronization validation, which the
retained records above predate.

macOS, only after a human has approved that session, because the suite opens a
window on the desktop it runs on and presents to it:

```bash
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
```

Linux, where the same native command starts an isolated display and supplies
the consent for that display alone, so it needs no approval. With the validation
runner's evidence directory set, each case writes its record there, in the shape
of the records above; see
[the native suite](gpu_backend.md#the-native-suite).

`cabal build all` and `cabal build all --project-file cabal.project.cpu` continue
to resolve and link no Vulkan binding at all.
