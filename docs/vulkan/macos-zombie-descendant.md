# #284's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the environment section of the
> `vk2-compatibility` record, and the three receipts the validation runner
> wrote, verbatim. The per-scenario records the native receipt lists are
> retained unchanged beside this file, at the receipt's own relative paths under
> [`macos-zombie-descendant/`](macos-zombie-descendant/evidence/test.vulkan-native/);
> the logs it lists are reproduced verbatim at the end of this file, because
> the validation catalog classifies no `.log` path under `docs/` and an
> unclassified file would select every group and change the inputs these
> receipts identify.

This is the local macOS evidence for issue #284, which makes the launcher
regression's check that an orphaned descendant has ended read the process's
state with `ps` instead of signal 0, adds `Test.GLFW.Native.Presence` and a
test-only C helper that holds a child unreaped, and corrects what the launcher's
documentation says about reaping. It was retaken after review round 1's fix, which
reads `ps`'s state only as each platform documents it, as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: a Darwin plan, then `run.py` for `test.vulkan-headless` and — under
the owner's standing approval for desktop runs an issue needs, carried on each
command as `HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under
MoltenVK and Cocoa, with the catalog's `--complete` command, and
`test.glfw-native` under Cocoa. All three passed at commit `02b09e7fa84bf2a3e5716650789356339834ce3e`,
input identity `4fc126050096aabdde3205a103f8c0e2deb8687ee720aa2ab447c0547fb28760`.

The change is confined to `glfw-native-tests`: its Haskell sources, a
test-only C source, and its Cabal stanza. No library changes, so every Vulkan
package is built from the same code as before; the planner selects the Vulkan
groups because they consume the GLFW package. The native Vulkan group's
preparation built the suite in 1.302 s, and its watched native execution took
2.684 s against the 30-second watchdog.
The receipts record `Darwin` and the local prefix's own toolchain map — the
MoltenVK driver, the 1.3.296 layer with `+synchronization` — and no `ci-image`
entry, so none can satisfy a Linux plan. The prefix is a private one built for
this run with `tools/native/native.py build`, because the shared prefix
predates this machine's current Command Line Tools and SDK; its `vulkan` and
`native-manifest` identities are therefore its own. Every scenario passed and
the shared session's verdict was clean.

The plan's local worker declaration is the one
[docs/validation.md](../validation.md#a-local-run-and-its-receipt) shows with
`test.glfw-wayland` added, as #280's was: that group is required when affected,
and a plan whose selected groups are not all routed is refused. Routing it is
not running it. It was not run here — it needs an isolated Wayland session —
and its execution, like every Linux execution, is CI's.

`test.glfw-native` reported `117 examples, 0 failures, 25 pending`. Its pending examples are the Wayland
tree, which needs the isolated Wayland consent this Cocoa run does not carry,
and the two human-in-the-loop probes (owner-turn interaction and monitor
hot-plug), which no routine run performs. The repaired regression and the two
new examples that prove the descendant check — against this process, a real
unreaped child, and the same child once reaped, and against each answer of
`ps` it accepts or refuses — are among its passes. Its receipt lists no
evidence files, and neither does the headless receipt.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
110 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 82
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 67 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.217962s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 4.8819e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.203675s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.315547s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.141001s
vulkan-native-tests: private vk6-capture: ExitSuccess in 5.8009e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.17339s
vulkan-native-tests: the process ran for 1.90377s, fixtures, examples and teardown included
```

### The per-scenario records

Each private scenario's record and log, as the receipt's `evidence` list names
them. The records are files relative to `macos-zombie-descendant/`; the logs are
the sections below.

| scenario | record | log | verdict | examples |
| --- | --- | --- | --- | --- |
| `debug-names` | [`debug-names.md`](macos-zombie-descendant/evidence/test.vulkan-native/debug-names.md) | [`debug-names.log`](#debug-nameslog) | pass | 6, 0 failures |
| `synchronization-hazard` | [`synchronization-hazard.md`](macos-zombie-descendant/evidence/test.vulkan-native/synchronization-hazard.md) | [`synchronization-hazard.log`](#synchronization-hazardlog) | pass | 5, 0 failures |
| `vk11-recording` | [`vk11-recording.md`](macos-zombie-descendant/evidence/test.vulkan-native/vk11-recording.md) | [`vk11-recording.log`](#vk11-recordinglog) | pass | 7, 0 failures |
| `vk2-compatibility` | [`vk2-compatibility.md`](macos-zombie-descendant/evidence/test.vulkan-native/vk2-compatibility.md) | [`vk2-compatibility.log`](#vk2-compatibilitylog) | pass | 74, 0 failures |
| `vk5-bridge` | [`vk5-bridge.md`](macos-zombie-descendant/evidence/test.vulkan-native/vk5-bridge.md) | [`vk5-bridge.log`](#vk5-bridgelog) | pass | 10, 0 failures, 1 pending |
| `vk6-capture` | [`vk6-capture.md`](macos-zombie-descendant/evidence/test.vulkan-native/vk6-capture.md) | [`vk6-capture.log`](#vk6-capturelog) | pass | 9, 0 failures |
| `vk7-roots` | [`vk7-roots.md`](macos-zombie-descendant/evidence/test.vulkan-native/vk7-roots.md) | [`vk7-roots.log`](#vk7-rootslog) | pass | 10, 0 failures |

Three scenarios provoke a validation error on purpose and record it as a
latched verdict issue while their own verdict passes, as the earlier records
did: `debug-names` its one expected `VUID-vkCmdCopyImageToBuffer-pRegions-00183`
on the named command buffer and readback buffer, `synchronization-hazard` its
two unbarriered writes to one buffer, and `vk6-capture` the
`VUID-vkCmdSetViewport-viewportCount-arraylength` it sends through an unsafe
import.

### The `vk2-compatibility` record's environment

- source digest: 1af3273dc65f7d1928045ff2b274d87f02947ef831957b3dea3a2b288d21d353
- repository revision: 02b09e7fa84bf2a3e5716650789356339834ce3e
- platform: darwin/aarch64
- session authorization: the desktop opt-in on this run's command, under the owner's standing approval
- VK_DRIVER_FILES: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/bd4d49db-49a3-4e95-a7b4-6e565a64b388/scratchpad/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
- VK_LAYER_PATH: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/bd4d49db-49a3-4e95-a7b4-6e565a64b388/scratchpad/native/glfw/vulkan/share/vulkan/explicit_layer.d
- cleared discovery overrides: VK_LOADER_LAYERS_DISABLE=~implicit~
- loader instance version: 1.3.296
- layers the pinned path offers: VK_LAYER_KHRONOS_validation 1.3.296
- implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
- layers requested: VK_LAYER_KHRONOS_validation
- the validation layer is in the loaded chain: yes
- validation features enabled by the create info: SynchronizationValidation
- surface extensions GLFW requires: VK_KHR_surface, VK_EXT_metal_surface

### `test.vulkan-native` receipt

```json
{
  "command": [
    "bash",
    "tools/vulkan/run.sh",
    "native",
    "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests",
    "--",
    "--complete"
  ],
  "duration_seconds": 2.684,
  "ended_at": "2026-09-27T12:44:34.612Z",
  "evidence": [
    "evidence/test.vulkan-native/debug-names.log",
    "evidence/test.vulkan-native/debug-names.md",
    "evidence/test.vulkan-native/synchronization-hazard.log",
    "evidence/test.vulkan-native/synchronization-hazard.md",
    "evidence/test.vulkan-native/vk11-recording.log",
    "evidence/test.vulkan-native/vk11-recording.md",
    "evidence/test.vulkan-native/vk2-compatibility.log",
    "evidence/test.vulkan-native/vk2-compatibility.md",
    "evidence/test.vulkan-native/vk5-bridge.log",
    "evidence/test.vulkan-native/vk5-bridge.md",
    "evidence/test.vulkan-native/vk6-capture.log",
    "evidence/test.vulkan-native/vk6-capture.md",
    "evidence/test.vulkan-native/vk7-roots.log",
    "evidence/test.vulkan-native/vk7-roots.md"
  ],
  "executed": true,
  "executed_commit": "02b09e7fa84bf2a3e5716650789356339834ce3e",
  "executed_tree": "c9c7f7521c3c68624e934a663f853ba77b802e01",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "02b09e7fa84bf2a3e5716650789356339834ce3e",
  "input_identity": "4fc126050096aabdde3205a103f8c0e2deb8687ee720aa2ab447c0547fb28760",
  "outcome": "passed",
  "plan_identity": "086288e177ce176b1731d306819915dc8a536b9ec53ffa9771830af3642606f7",
  "policy_version": "da8c964c97561260298f682a1dd2c955ca5d69448e5ae37abe7bd49ef20128e5",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 1.302,
    "ended_at": "2026-09-27T12:44:31.928Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-27T12:44:30.625Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-27T12:44:31.928Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "96a873a62e765ef5d47ace9f00f799f49ca29b54c15e9247f037e41dd91ab2d2",
    "vulkan": "8da752674d304ae79c45f90fe66208262c646aeef27aa32c86c8a1609495e5ae",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 d9bda0777168"
  },
  "worker": "local"
}
```

### `test.vulkan-headless` receipt

```json
{
  "command": [
    "bash",
    "tools/vulkan/run.sh",
    "test",
    "hetoimasia-gpu-vulkan-native:test:native-tests",
    "hetoimasia-gpu-vulkan-native:test:shader-tests",
    "hetoimasia-gpu-vulkan-glfw:test:integration-tests"
  ],
  "duration_seconds": 6.662,
  "ended_at": "2026-09-27T12:44:30.268Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "02b09e7fa84bf2a3e5716650789356339834ce3e",
  "executed_tree": "c9c7f7521c3c68624e934a663f853ba77b802e01",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "02b09e7fa84bf2a3e5716650789356339834ce3e",
  "input_identity": "4fc126050096aabdde3205a103f8c0e2deb8687ee720aa2ab447c0547fb28760",
  "outcome": "passed",
  "plan_identity": "086288e177ce176b1731d306819915dc8a536b9ec53ffa9771830af3642606f7",
  "policy_version": "da8c964c97561260298f682a1dd2c955ca5d69448e5ae37abe7bd49ef20128e5",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-27T12:44:23.606Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "96a873a62e765ef5d47ace9f00f799f49ca29b54c15e9247f037e41dd91ab2d2",
    "vulkan": "8da752674d304ae79c45f90fe66208262c646aeef27aa32c86c8a1609495e5ae",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 d9bda0777168"
  },
  "worker": "local"
}
```

### `test.glfw-native` receipt

```json
{
  "command": [
    "cabal",
    "test",
    "glfw-native-tests",
    "--test-show-details=direct"
  ],
  "duration_seconds": 11.825,
  "ended_at": "2026-09-27T12:44:46.808Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "02b09e7fa84bf2a3e5716650789356339834ce3e",
  "executed_tree": "c9c7f7521c3c68624e934a663f853ba77b802e01",
  "exit_status": 0,
  "expiry": null,
  "group": "test.glfw-native",
  "head_commit": "02b09e7fa84bf2a3e5716650789356339834ce3e",
  "input_identity": "4fc126050096aabdde3205a103f8c0e2deb8687ee720aa2ab447c0547fb28760",
  "outcome": "passed",
  "plan_identity": "086288e177ce176b1731d306819915dc8a536b9ec53ffa9771830af3642606f7",
  "policy_version": "da8c964c97561260298f682a1dd2c955ca5d69448e5ae37abe7bd49ef20128e5",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-27T12:44:34.983Z",
  "timeout_seconds": 1800,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "96a873a62e765ef5d47ace9f00f799f49ca29b54c15e9247f037e41dd91ab2d2",
    "vulkan": "8da752674d304ae79c45f90fe66208262c646aeef27aa32c86c8a1609495e5ae",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 d9bda0777168"
  },
  "worker": "local"
}
```

### The per-scenario logs

#### `debug-names.log`

```

#250 names and labels
  established every step of its private roots, its generation and its managed resources, on a device that offers naming [✔]
  recorded the batch inside its labels, and the report left it sealed and discardable [✔]
  received the provoked report while the overrunning copy was recorded, and no error from any other step [✔]
  carried the readback buffer, with the name the backend gave it, among the report's objects [✔]
  carried the enclosing batch's label among the report's command-buffer labels, wherever the layer reports any [✔]
  lost nothing, and failed its verdict after the last teardown callback for the latched error alone [✔]

Finished in 0.0005 seconds
6 examples, 0 failures
vulkan-native-tests debug-names: every check passed
```

#### `synchronization-hazard.log`

```

Synchronization validation's negative control
  established every step of its private roots [✔]
  reported the deliberate write-after-write hazard from inside the second write [✔]
  reported no error but the hazard it provoked, from no other step [✔]
  completed its capture: every report admitted and delivered, and its worker finished [✔]
  failed its verdict, after its last teardown callback, for the latched error and nothing else [✔]

Finished in 0.0005 seconds
5 examples, 0 failures
vulkan-native-tests synchronization-hazard: every check passed
```

#### `vk11-recording.log`

```

VK-11 managed recording
  established every step of its private roots, its generation and its managed resources [✔]
  recorded one sealed batch of eleven commands against the generation's image, inside the batch's and the pass's labels [✔]
  held every managed resource the batch referenced, and no longer once the discard invalidated it [✔]
  exposed no readback bytes, since nothing was submitted [✔]
  constructed, released and destroyed every managed resource [✔]
  received no validation error during any step [✔]
  completed its capture, and its verdict after the last teardown callback is clean [✔]

Finished in 0.0005 seconds
7 examples, 0 failures
vulkan-native-tests vk11-recording: every check passed
```

#### `vk2-compatibility.log`

```

A whole run
  releases the same ten entries, in the same order [✔]
  retains nothing and destroys every handle in plan order [✔]
  counts the boundary as an entry that ran and not as a handle destroyed [✔]
  reports the ordinary destruction rules, not device loss [✔]
A present fence that times out
  retains that slot's present fence and presentation semaphore, the swapchain, and every parent above them [✔]
  destroys only what does not depend on the unretired present [✔]
  names the reason on each retained handle [✔]
  is not device loss, however long the wait went unsatisfied [✔]
A teardown boundary that fails without device loss
  prohibits every release whose safety the boundary was to establish [✔]
  reports the boundary failure as the reason rather than a presentation [✔]
  is not discharged by a later valid present fence [✔]
Later valid present-fence evidence
  permits ordered release once the fence signals during teardown [✔]
Device loss
  permits destruction under the specification's own rule [✔]
  is never reached by promoting a timeout to it [✔]
  is established by the boundary alone as readily as by a fence [✔]
A present rejected out-of-date or surface-lost
  counts its enqueued operations and holds the slot [✔]
  releases the slot only on the fence, never on the error result [✔]
  creates no obligation for the specified no-effect results [✔]
An exception in place of a result
  classifies a thrown Vulkan result as that result [✔]
  treats an exception carrying no result as evidence of nothing [✔]
  treats a boundary that threw as a boundary that failed [✔]
A run that stopped before the boundary was registered
  releases what it registered [✔]
  still withholds when a registered boundary reached no result at all [✔]
A recycled slot
  is not discharged by the completion of the present before it [✔]
The record a stopped run renders
  keeps the failing step and the failed verdict [✔]
  renders the retained handles, their reasons, and the disposition [✔]
  still claims nothing the run did not establish [✔]
The loaded Vulkan loader
  accepts the recorded loader [✔]
  refuses an alternate loader found ahead of it on the search path, naming both [✔]
  refuses a run whose runner named no recorded loader [✔]
  refuses an entry point attributed to no image [✔]
The native run
  established every step it started [✔]
The recorded environment
  selected the driver by an absolute manifest path rather than by default discovery [✔]
  cleared every conflicting discovery override it found [✔]
  identifies the exact sources it proved, by their content [✔]
  names a repository revision alongside it [✔]
  ran with validation actually loaded, so a clean run means something [✔]
  enabled synchronization validation through the instance's own create info [✔]
  recorded the layers the pinned path offers [✔]
One loader
  gives GLFW and the binding the same vkGetInstanceProcAddr address [✔]
  attributes that address to one image [✔]
  resolves an ordinary instance command to the same address on both sides [✔]
  records which driver was actually loaded, not which one was configured [✔]
The runtime profile
  enabled Vulkan 1.3 dynamic rendering and synchronization2 rather than assuming them [✔]
  enabled the portability subset exactly when the device advertised it [✔]
  found one queue family with both graphics and real surface presentation [✔]
  presents through a format whose usages include transfer-source capture [✔]
  enabled the selected maintenance extension with its whole dependency chain [✔]
  resolved a release entry point, and records which spelling answered [✔]
  built a swapchain with room to hold an abandoned image [✔]
Presentation completion
  observed every present fence signalled [✔]
  retires every presentation semaphore on its present fence and never on the rendering fence [✔]
  recycles the semaphore pool only on present-fence evidence [✔]
  withholds a delayed frame's slot until its present fence, not until its rendering fence [✔]
Safe abandonment
  returns an acquired, unrendered image after a tracked cleanup submission consumed its acquisition semaphore [✔]
  returns a submitted, unpresented image after its rendering completed and its semaphore was settled [✔]
  needs no swapchain rebuild for either path [✔]
  keeps making progress on the same swapchain afterwards [✔]
The capture path
  reads a known payload back through transfer-source usage [✔]
Callbacks and the FFI
  re-entered Haskell during creation, submission, and destruction [✔]
  still reached Haskell after the explicit messenger was destroyed [✔]
  found its callback storage still valid while the instance was destroyed [✔]
  ran on the threaded RTS with GLFW on the process main thread [✔]
  recorded no validation error and no failed callback [✔]
Teardown
  released everything it acquired, with nothing failing and nothing retained [✔]
  destroyed the explicit messenger after every resource it should have watched [✔]
The operation and result matrix
  covers acquisition, submission, presentation, oldSwapchain creation, and destruction [✔]
  states the device-loss destruction rule from the specification and induces no device loss [✔]
  labels every row as either a specification citation or an observation to resolve [✔]
  actually observed every result it claims to observe [✔]
The matrix's observation labels
  claims nothing for a run that stopped [✔]
  does not call a VK_SUCCESS row observed when every result was suboptimal [✔]
  does not call a release row observed when a release failed [✔]
  records the oldSwapchain failure case, which retires the old swapchain anyway [✔]

Finished in 0.0050 seconds
74 examples, 0 failures
vulkan-native-tests vk2-compatibility: every check passed
```

#### `vk5-bridge.log`

```

VK-5 loader-aware surface bridge
  established every step of its session [✔]
  made the capability from the binding's own vkGetInstanceProcAddr [✔]
  had GLFW resolve through that exact entry point while the session was live [✔]
  had GLFW and the binding resolve an instance entry point into one image [✔]
  copied the platform's required instance extensions [✔]
  created a surface for the attached window, which the binding accepted [✔]
  refused the attachment's disposal fact and the instance's release while the surface was owed [✔]
  destroyed the surface through Vulkan on another thread, and then granted both [✔]
  restored GLFW's default loader after termination [✔]
  restored GLFW's default loader after a failed initialization, where the platform can fail one [‐]
    # PENDING: GLFW 3.4's Cocoa initialization has no failure an application can provoke, and Cocoa is the only backend this platform admits

Finished in 0.0007 seconds
10 examples, 0 failures, 1 pending
vulkan-native-tests vk5-bridge: every check passed
```

#### `vk6-capture.log`

```

VK-6 validation capture
  established every step of its session [✔]
  installed a C callback from the executable's own image, and no Haskell callback [✔]
  heard instance creation through the create-info chain [✔]
  delivered a message from inside a genuine unsafe import [✔]
  latched the validation error an unsafe recording call provoked, from inside that call [✔]
  heard vkDestroyInstance after the explicit messenger was destroyed, and delivered it [✔]
  counted every delivery in its final verdict [✔]
  found no error but the one it provoked [✔]
  records the FFI configuration the toolchain pin qualified [✔]

Finished in 0.0009 seconds
9 examples, 0 failures
vulkan-native-tests vk6-capture: every check passed
```

#### `vk7-roots.log`

```

VK-7 Vulkan roots
  established every step of its session [✔]
  made no native call that raised [✔]
  created each window's surface through GLFW on the process main thread [✔]
  made every root's creation and destruction, and every surface's destruction, on the graphics owner's thread [✔]
  created the instance, then the explicit messenger, then one device against the first window's surface [✔]
  admitted both windows' targets, each required, on that one shared device [✔]
  retired the first-created window's target alone, leaving the device, the instance and the second target live [✔]
  destroyed every surface, then the device, then the explicit messenger, then the instance [✔]
  delivered every report, both messengers' teardown reports included, with the instance's destruction as the quiescence evidence [✔]
  reported no validation error [✔]

Finished in 0.0006 seconds
10 examples, 0 failures
vulkan-native-tests vk7-roots: every check passed
```
