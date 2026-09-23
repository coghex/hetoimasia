# Low-level runtime review findings, 2026-09-20

Bugs, risks, and design gaps found by a read-and-test review of the foundation,
runtime, GLFW, and Vulkan proof and model layers at `master@5c593e2`, retained
for later disposition. Documentation drift found by the same review landed
directly in `fddcac5` and is not repeated here.

Owner-approved follow-up on 2026-09-20 corrects the premises and records the
delivery direction below, checked against `af4436d` unless an entry names its
earlier baseline. The test results in Methodology belong to the original review;
these documentation amendments did not rerun them. The ledger below records
subsequent dispositions; historical findings do not describe every capability
now delivered. Verify current tracker coverage before changing a remaining
disposition, drafting an issue or proposing an amendment to an existing slice.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Methodology

The review built `cabal build all` warning-clean with the qualified GHC 9.14.1
and the private GLFW prefix, ran every headless suite (336 foundation, 184
runtime, 454 GLFW, 134 GPU model, 137 Lua host, 11 console examples, all
passing), the native dry run, and the console smoke, then read the resource,
time, logging, worker, application, update-policy, GLFW session, window,
capture, native shim, owner loop, render demand, retirement, GPU model, and
Vulkan proof modules against their contracts. No desktop session and no Vulkan
proof run was started. Findings are ordered from concrete mismatches to design
gaps; none is a failing test today.

## Status

- [x] RR-1. Correct the proof shim header comments that describe behaviour the shim does not have — [#199]
- [x] RR-2. Preserve reproducible macOS Vulkan inputs through VK-4 — [#155]
- [x] RR-3. Correct the proposed ban on presentation-fence polling — [no-issue]
- [x] RR-4. Investigate owner-loop progress during native window interactions — [#200]
- [x] RR-5. Apply the approved mixed FFI policy to production Vulkan calls — [#155]
- [x] RR-6. Add an optional bounded asynchronous logging adapter — [#201]
- [x] RR-7. Qualify native Wayland support; defer Windows execution — [#202]
- [ ] RR-8. Defer bound workers until a concrete consumer requires OS-thread affinity — [deferred]: no named consumer with an affinity requirement
- [ ] RR-9. Design the next input arc after Vulkan boilerplate — [deferred]: input design document's EPIC entry unfiled
- [x] RR-10. Carry the pre-initialization hook requirement through existing VK-5 — [#155]

---

## Proof harness and environment

### [#199] RR-1. Correct the proof shim header comments that describe behaviour the shim does not have

Two declarations in the proof's C header document parameters and return values
the implementation never had. VK-5 is expected to copy from this shim, so a
reader will carry the wrong contract into the production bridge.

**Evidence:**

- `tools/vulkan-proof/cbits/hetoimasia_vulkan_proof.h:24-25` — says `init_vulkan_loader` "Returns 0 when GLFW was already initialized, which would make the call a no-op".
- `tools/vulkan-proof/cbits/hetoimasia_vulkan_proof.c:52-59` — the function calls `glfwInitVulkanLoader` and unconditionally returns 1; nothing checks initialization state.
- `tools/vulkan-proof/cbits/hetoimasia_vulkan_proof.h:28-29` — says `glfw_init` takes a hidden-window hint "when `visible` is zero".
- `tools/vulkan-proof/cbits/hetoimasia_vulkan_proof.c:61-66` — the function takes no parameter, and the window is created visible in `hetoimasia_proof_create_window`.

**Handoff context:**

- **Current behavior:** the comments promise a check and a parameter that do not exist.
- **Expected direction:** correct the header to describe exactly what the C does. Do not add behavior merely to satisfy the stale comments; a new initialization guard would require a separately verified need.
- **Scope and constraints:** keep the header repair and any accompanying contract updates together in the normal code PR lane, most naturally a scoped proof repair or VK-5. Choose the lane for the whole task, not by file extension.
- **Remaining uncertainty:** None at draft time.

### [#155] RR-2. Preserve reproducible macOS Vulkan inputs through VK-4

**Verification: Partially verified** — the proof defaults to a versioned
Homebrew manifest and an SDK layer directory. Removing that installation can
break discovery; this review did not run an upgrade to reproduce it. The harness
refuses missing inputs and accepts explicit path overrides, so the previous
claim that recovery requires editing the pin was incorrect. Stable paths alone
would not establish reproducibility.

**Evidence:**

- `tools/vulkan-proof/environment.pin:16` — `MACOS_VULKAN_DRIVER_MANIFEST=/opt/homebrew/Cellar/molten-vk/1.4.0/etc/vulkan/icd.d/MoltenVK_icd.json`.
- `tools/vulkan-proof/environment.pin:17` — `MACOS_VULKAN_LAYER_PATH=/usr/local/share/vulkan/explicit_layer.d`.
- `tools/vulkan-proof/run-proof.sh:80-82` — accepts `HETOIMASIA_VULKAN_PREFIX`, `HETOIMASIA_VULKAN_DRIVER_MANIFEST` and `HETOIMASIA_VULKAN_LAYER_PATH` overrides; later checks refuse unavailable inputs.
- `docs/vulkan_backend_design.md`, VK-4 — already owns cached native provisioning, explicit discovery and manifest/binary identities in validation evidence.

**Handoff context:**

- **Current behavior:** the historical proof identifies its selected inputs; production provisioning remains VK-4 work.
- **Expected direction:** retain a project-managed installation/cache with verified loader, driver and layer identities and explicit discovery. Missing or changed inputs must be diagnosed; an upgrade is an explicit requalification that invalidates affected evidence. Do not replace the exact input with a moving Homebrew `opt` symlink unless its resolved identity is still checked against the pin.
- **Delivery fit:** strengthen VK-4's acceptance criteria rather than create a parallel provisioning system. Check its current issue/design coverage when processing.
- **Acceptance:** cold provisioning and warm reuse select the same identities; missing inputs fail clearly; a substituted driver or layer cannot reuse old evidence. Explicit path overrides locate inputs, not waive qualification. Preserve the original proof records as historical evidence.
- **Remaining specification work:** VK-4 selects the retained-prefix layout and acquisition recipe. The owner approved reproducibility and requalification as the policy; current-path convenience must not weaken it.

### [no-issue] RR-3. Correct the proposed ban on presentation-fence polling

> **Disposition:** No issue — the polling-ban premise is withdrawn above and no
> design text inherits it: D-9 requires verified presentation-fence completion
> without naming wait over query, the scheduling contract already speaks of
> observed completion and of avoiding forced fence queries, `docs/gpu_model.md`
> ends the presentation hold on boundary-supplied retirement evidence with
> disposal gated on every hold, and the compatibility record scopes "waited for
> and signalled" to what the proof asserts. VK-13 inherits the corrected
> direction from this entry.

**Verification: Contradicted** — the original finding confused absence of a
signal-timing guarantee with absence of completion evidence. A successful status
query is valid signal evidence for a correctly associated presentation fence;
production retirement need not perform a redundant wait. The owner approved
correcting this premise, not implementing a polling prohibition.

**Evidence:**

- `tools/vulkan-proof/proof/Test/Vulkan/Proof/Run.hs:1409` — `before ← getFenceStatus device slot.slotPresentFence` immediately after `vkQueuePresentKHR` returns.
- `docs/vulkan_compatibility_record.md` — records that the pre-wait status is observed only and that the fence is always waited for.
- [The fence-status specification](https://docs.vulkan.org/refpages/latest/refpages/source/vkGetFenceStatus.html) defines `VK_SUCCESS` as signaled and `VK_NOT_READY` as unsignaled, with separate error/device-loss behavior.
- [Presentation fences](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainPresentFenceInfoKHR.html) associate signal evidence with the relevant presentation's resource obligations. Their guarantees differ from a rendering-submission fence and do not prove the time an image appeared on screen.

**Handoff context:**

- **Current behavior:** the proof always waits as part of its experiment. That is not a requirement to wait again after production has observed a valid signal.
- **Expected direction:** VK-13 may inject completion from a successful query or wait, tied to the exact enqueued presentation and fence generation. `VK_NOT_READY` establishes no completion; errors follow the existing failure policy. A signaled fence from initialization, an earlier use, or a different obligation is insufficient. Reset/reuse and resource disposal still require their full ownership conditions.
- **Scope and constraints:** check every outstanding submission/presentation/CPU hold before disposal. Keep device loss separate from normal retirement; status success does not by itself prove device health. Never infer completion from elapsed time, expected platform timing or a render fence alone.
- **Delivery fit:** verify VK-13's coverage and correct any inherited misleading documentation. The original polling-ban premise warrants no implementation issue. The processor may close that premise without an issue or propose a narrowly evidenced clarification if current coverage needs it; no disposition has been applied here.
- **Acceptance if clarification is needed:** distinguish matching signaled, not-ready, stale-generation and failed queries; no mandatory extra wait after valid signal evidence, and no disposal while another hold remains.
- **Remaining uncertainty:** none about allowing valid signal queries; exact native accounting remains VK-13's implementation work.

## Owner loop and rendering

### [#200] RR-4. Investigate owner-loop progress during native window interactions

**Verification: Partially verified** — GLFW documents that move, resize and
menu operations can block event processing on some platforms. The code runs
owner work after that native step, so such blocking would delay updates and
future owner-driven rendering. No local experiment in this review establishes
the exact current macOS behavior, callback set or stall duration. There is no
production renderer here from which to claim an observed rendering defect.

**Evidence:**

- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:2274` — the owner turn's native step is one `glfwWaitEventsTimeout` or `glfwPollEvents` call.
- `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs:334` — the refresh wrapper only forwards to `onWindowRefresh`, which the window model documents as record-only.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:1398-1410` — reconciliation, dispatch, and the update opportunity all follow the native step in the same turn, so nothing runs while the native step is blocked.
- `docs/glfw.md` — no occurrence of "live resize", "modal", or drawing from the refresh callback.
- [GLFW event processing](https://www.glfw.org/docs/3.4/group__window.html) documents platform-dependent blocking and refresh callbacks during window interactions. A wait timeout is not a bound on subsequent event dispatch.

**Handoff context:**

- **Expected first task:** a bounded local qualification experiment on the current macOS/GLFW profile. Record native-pump entry/exit, owner update progress and actual callbacks during move, resize and menu interactions. Use owned bounded capture so measurement itself does not add synchronous logging stalls; retain the command, platform identity and observations. Inspect Synarchy's corresponding flow as context, not as proof.
- **Acceptance:** distinguish an observed stall from an inferred risk, report which interactions reproduce it, and retain a verdict including any unperformed cases. Linux evidence cannot substitute for the requested Cocoa experiment. Desktop disruption requires the human user's explicit approval for that session; this report is not permission to launch it. Prefer Hspec where practical and document any manual interaction or probe boundary.
- **Decision after evidence:** before VK-16, choose and document temporary acceptance of a stall, a narrowly controlled redraw path, or a separate rendering owner. State what happens to other windows, simulation and queued commands during the interaction; continuous simulation is not automatically required by a redraw policy.
- **Scope and constraints:** this finding authorizes investigation first. Keep current record-only callbacks and main-thread ownership until a reviewed design explicitly changes them. It does not authorize callback reentrancy, rendering inside a callback or a render-worker redesign. Do not make this experiment a routine disruptive CI test or a prerequisite for every earlier Vulkan slice.
- **Remaining uncertainty:** actual platform behavior and the resulting rendering policy; settle them before integrated rendering relies on continuous owner turns.

### [#155] RR-5. Apply the approved mixed FFI policy to production Vulkan calls

> **Captured owner approval, 2026-09-20:** ok good argument, i agree, this is the right policy, can this go in a processable report? something i can make actionable issues out of?

**Verification: Verified** — the proof selects binding-wide safe imports and
installs a Haskell validation callback. That is a correct proof configuration,
not a measured production performance result. There is no production Vulkan
recording implementation yet. The owner approved the mixed production policy
below after discussing callback re-entry, driver blocking, and runtime progress.
This replaces the earlier RR-5 proposal to leave that policy undecided until a
benchmark; the size of any performance benefit remains unmeasured.

**Evidence, checked at `30e5f6a`:**

- `cabal.project.vulkan:19-26` selects `vulkan +safe-foreign-calls` for the
  separate proof project; its opening comment explains the ordinary projects
  do not include that harness.
- `tools/toolchain/binding.pin:13-23` records why Haskell callbacks require safe
  imports. The pinned `vulkan-3.27` source uses the package-wide
  `SAFE_FOREIGN_CALLS` selection on generated dynamic imports, including
  `Vulkan.Core10.CommandBufferBuilding.mkVkCmdDraw`.
- `tools/vulkan-proof/proof/Test/Vulkan/Proof/Run.hs:191-223` wraps and implements
  `debugCallback` in Haskell; `:531-557` registers it before instance creation.
  `tools/vulkan-proof/proof/Test/Vulkan/Proof/Spec.hs:229-261` checks callbacks,
  teardown lifetime, the threaded RTS and that safe-call configuration.
- [Vulkan design P-9](vulkan_backend_design.md#binding-and-callback-configuration)
  currently defers native-only capture. P-11 and D-19 already require bounded
  capture, independent failure latches and a separately owned diagnostic worker;
  VK-6 and VK-11 are the delivery points this decision affects.
- [GHC's FFI contract](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/ffi.html)
  allows Haskell re-entry through safe calls; unsafe calls hold a capability and
  prevent GC while they execute. With the threaded RTS, safe calls let other
  Haskell work and GC progress while the caller waits. Safe is not automatic
  offloading or a guarantee that a driver call can be cancelled.
- Vulkan permits [presentation to block](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueuePresentKHR.html)
  and executes a [debug callback on the originating call's thread](https://docs.vulkan.org/refpages/latest/refpages/source/VkDebugUtilsMessengerCreateInfoEXT.html).
  Moving only the eventual sink write to a worker does not remove Haskell
  re-entry from that native call.

**Approved production boundary:**

| Call category | Policy |
|---|---|
| Audited short draw/state/command-recording operations, with no Haskell re-entry | Use actual `unsafe` foreign imports. Audit the supported subset; do not assume every `vkCmd*` has the same host cost. |
| GPU waits, acquisition that may wait, and potentially lengthy operations such as pipeline compilation | Use `safe` imports. Preserve finite-wait and stop/checkpoint contracts. |
| Queue submission and presentation | Start with `safe` imports; their frequency does not rule out substantial driver work or blocking. |
| Any operation that can call back into Haskell | Use `safe` imports. It cannot join the unsafe subset while that re-entry remains possible. |

Validation capture for the unsafe path must be C-only, copying capped data into
owned bounded storage; the Haskell diagnostic worker drains it afterward. No
Haskell trampoline, exception, logger, or allocation callback may be reachable
from that unsafe path. Keep validation enabled on the same recording path used
in production. Preserve P-11's limits, concurrency handling, prompt capture,
no waiting for space, no sink I/O or Vulkan calls in the callback, and the normal
non-aborting callback result. Latch error severity before detail admission so
overflow cannot hide a fatal validation event.

Use the pinned binding's types and dispatch machinery where possible, with a
narrow private set of genuine unsafe imports or an equivalent audited generation
mechanism. A Haskell wrapper around an existing safe import does not change its
calling convention. Do not disable the flag on the current proof while its
Haskell callback is installed. Record the production FFI configuration in build
and evidence identity; retain the proof's historical results as historical.

**Handoff context:**

- **Current behavior:** the proof intentionally uses safe imports everywhere;
  the production design does not yet specify the approved fast recording path.
- **Expected behavior:** short recording operations avoid safe-call transition
  overhead while blocking operations permit runtime progress, and validation
  cannot re-enter Haskell from unsafe imports.
- **Delivery fit:** process this finding against VK-6 (capture/worker) and VK-11
  (managed recording), checking their current tracker state before proposing an
  amendment or bounded prerequisite issue. Reconcile P-9/P-11 and those slices
  with this owner decision before solving the affected work; do not create a
  second diagnostics service or duplicate those slices. This report captures
  the decision, not a claim that the design or tracker has already been amended.
- **Required acceptance:** retain an operation-by-operation FFI/callback audit
  and inspect the actual compiled import selection. Hspec cases must exercise
  concurrent capture, bounded copying, saturation, error latching, sink failure,
  and teardown ordering. Native cases must demonstrate the production C-only
  callback receiving diagnostics inside the unsafe path and surviving the final
  callback-producing destruction; synthetic seam coverage alone is insufficient.
  Preserve masking, native-effect accounting, resource retention and completion
  evidence across the mixed calls. Close capture only after callbacks quiesce,
  drain/join its worker, then release its storage and logger.
- **Measurement:** collect optional, reproducible safe/unsafe comparisons for
  representative recording on Linux and macOS, including runtime progress under
  driver waits. Record toolchain, layers and driver identity. Do not assert an
  unmeasured speedup or add noisy timing thresholds to required CI. Existing
  Linux-only remote CI, local macOS verification and explicit human approval for
  desktop disruption still apply.
- **Scope and constraints:** code, required contract updates and evidence belong
  together in each implementation PR. This finding does not authorize changing
  Lua's FFI settings, rewriting the foundation logger, broad RTS tuning, a new
  render-thread architecture, or expanding platform support.
- **Remaining uncertainty:** the exact first recording subset, private import
  mechanism and measured costs need implementation evidence. The mixed-call and
  C-only capture policy is approved, not an open product decision.

### [#201] RR-6. Add an optional bounded asynchronous logging adapter

> **Captured owner approval, 2026-09-20:** recommendations approved, make it so in the doc please

**Verification: Verified** — a handle sink can write and flush on the GLFW
owner thread. Frequency does not bound the duration of one blocked write.
The owner approved an optional runtime adapter with a bounded queue and a
writer, preserving the foundation logger and its synchronous sinks. This is
approved implementation direction; the adapter has not been implemented.

**Evidence, checked at `af4436d`:**

- `packages/foundation/src/Hetoimasia/Foundation/Log.hs:521-574` defines the
  synchronous sink contract, serialized handle writes and per-entry flush.
  `:649-675` filters before evaluating message fields or obtaining metadata,
  then emits a structured entry through a unit-returning sink operation.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:1435-1451`
  emits input-recovery and wake-degradation diagnostics during owner turns.
- `packages/runtime/src/Hetoimasia/Runtime/Logging.hs:19-59` requires producers,
  component cleanup and terminal reporting to finish before final flush; it
  defines failure precedence and cancellation paths that skip flush.
- Vulkan D-19/P-11 and RR-5 separately own native diagnostic capture. An async
  Haskell sink cannot be called from an unsafe Vulkan import's C-only callback.

**Approved behavior:**

- Bound queue length and retained record size, with immediate admission and no
  wait for space. On saturation discard the incoming record and count losses
  by severity; never fall back to a synchronous sink write on the owner thread.
  Specify oversize-record handling and account for any rejection or truncation.
  Bounded memory and nonblocking admission deliberately do not promise lossless
  delivery when the consumer cannot keep up.
- Preserve the emitting thread, timestamp, source, component and structured
  context. Filter first, then prepare owned payloads before publication; perform
  output formatting and sink I/O on the writer. Do not retain lazy producer
  computations or oversized backing storage through apparently small slices.
  This removes downstream I/O from producers, not the cost of arbitrary message
  construction, payload preparation or caller-supplied metadata providers.
- Distinguish admission, completed writes and losses in observable adapter
  status. Existing logging calls return `IO ()`: a normal return from a
  drop-on-full adapter is not proof of either admission or delivery. Logging is
  never the sole record of application failure or a substitute for failure state.
- Latch writer failure independently of logging; never report it recursively
  through that writer. Flush/finalization must observe it without replacing an
  earlier application failure. A failed write may have produced partial output;
  do not replay it automatically. A flush waiter must also observe writer
  termination rather than wait forever for a dead writer's acknowledgement.
- Give flush a precise barrier: records admitted before the barrier are written
  before the underlying sink flush is attempted; later admissions cannot extend
  that obligation indefinitely. A successful barrier does not erase loss
  counters or claim dropped records were delivered. Barrier/control admission
  must not be silently dropped by the ordinary record-overflow policy.
  Bound adapter-owned control requests and retained waiter registrations too;
  record capacity alone is not a bound on total retained state. Define how
  excess concurrent flush requests wait, coalesce or fail, without holding a
  lock or ownership token needed by the writer. Explicit flush may wait;
  ordinary record admission still must not wait for queue space.
- Own the writer in an explicit runtime IO lifetime that outlives all producers,
  including graphics teardown and terminal reporting. Stop admission only after
  those producers finish, and join before releasing the borrowed sink. Preserve
  the existing primary/secondary failure and cancellation rules: cancellation
  need not flush, and an already failed diagnostic path is not retried. Account
  for abandoned backlog separately from successful drain. Never put arbitrary
  sink I/O in an uninterruptible resource release or detach a writer still using
  its sink; a permanently blocked sink cannot promise bounded shutdown.

**Handoff context:**

- **Delivery fit:** runtime owns the optional adapter and worker lifecycle;
  applications opt in through composition and existing narrow logger injection.
  Reuse foundation messaging/worker contracts where they fit. Coordinate with
  VK-6 without replacing its native capture or prematurely stopping its producer.
- **Acceptance:** coordinated Hspec tests for concurrent admission, producer
  attribution, filtering, prepared payloads and retained-size bounds; saturation
  without sink access on the producer; observable losses; flush ordering while
  new records arrive; bounded concurrent control requests and cancellation
  releasing their registrations; writer failure waking waiters; final
  teardown records; and preservation of primary failure and borrowed ownership.
  Use latches and barriers rather than timing sleeps. These tests need no GPU
  or desktop; performance comparisons remain optional.
- **Scope and constraints:** update adapter and logging-lifetime documentation
  with its code PR. Existing synchronous users retain their behavior. No global
  logging registry, automatic asynchronous-exception delivery to producers, or
  general logging rewrite. This work can proceed alongside Vulkan and should
  be available before frame-critical integration.
- **Remaining specification work:** the issue must name validated capacity and
  record-size defaults, oversize behavior, status/API shape and exact lifetime
  composition. The admission/drop, attribution, failure and ownership policies
  above are approved; emission frequency is not a gate on doing this work.

## Platform and runtime scope

### [#202] RR-7. Qualify native Wayland support; defer Windows execution

> **Captured owner approval, 2026-09-20:** recommendations approved, make it so in the doc please

**Verification: Verified** — the Linux recipe disables Wayland and session
selection rejects it. The owner approved a bounded Wayland qualification
proposal alongside Vulkan, and explicitly deferred Windows execution until a
machine is available. Neither is a claim of current support or native evidence.

**Evidence, checked at `af4436d`:**

- `tools/native/native.py:205-208` builds X11 with `GLFW_BUILD_WAYLAND=OFF`
  and rejects targets other than Darwin and Linux.
- `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs:268-272` selects
  Cocoa or X11 by OS; `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:857-862`
  rejects Wayland even though the backend type names it.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:639-653` already
  describes unavailable Wayland operations and observations. The native C shim
  currently includes X11-specific helpers on Linux.
- [GLFW's window guide](https://www.glfw.org/docs/3.4/window_guide.html) documents
  Wayland's global-position restrictions and framebuffer/content-scale behavior.
  [Weston supports a headless backend](https://wayland.pages.freedesktop.org/weston/toc/running-weston.html)
  for isolated tests; that environment alone does not qualify every compositor.

**Approved scope and qualification direction:**

- **Windows:** execution and platform qualification wait for an available
  machine. Remote CI stays Linux-only. Windows is not a current supported build;
  remove the earlier assumption that it reliably reaches `UnsupportedBackend`
  at session entry. Compilation and provisioning have not been qualified there.
- **Wayland provisioning and selection:** plan native support, not only a CI
  checkbox. Enable and pin the required build inputs, preserve X11, audit the
  X11-specific shim helpers and choose an explicit session-selection contract.
  Keep native handles private and all GLFW ownership/main-thread rules intact.
- **Capability semantics:** unsupported positioning, focus/control requests and
  unavailable observations must be explicit; do not fabricate X11-equivalent
  state. Audit resize, framebuffer size/content scale, suspension and render
  eligibility against compositor-controlled behavior. Reuse the existing
  capability model, verifying its assumptions rather than treating the dormant
  Wayland row as already tested.
- **Initial evidence:** use an isolated headless compositor in Linux, asserting
  that GLFW selected native Wayland rather than XWayland. Verify independent
  window creation/closure, lifecycle and failure cleanup, resize/framebuffer
  observations, supported controls, unsupported-operation outcomes, native wake
  and shutdown. Report unavailable experiments honestly; X11 green results do
  not count as Wayland evidence.
- **Graphics evidence:** add real Wayland surface creation, presentation and
  retirement cases on the qualified software Vulkan stack when those backend
  slices are available. Window-only qualification does not establish rendering
  support. Keep graphics capability requirements and completion evidence intact.
- **CI and scope:** reuse the pinned Linux image, cache and validation catalog;
  define the qualification groups and their promotion to small
  required-when-affected checks when support is established. Extensive desktop
  and compositor-specific probes remain optional. Preserve local macOS testing
  and explicit human consent for desktop disruption. Do not block the existing
  macOS/X11 milestone on Windows or full desktop-platform parity.

**Handoff context:**

- **Delivery fit:** process a bounded Wayland qualification proposal, separating
  provisioning/session-capability work from native and later Vulkan evidence as
  needed. Coordinate image changes with VK-4 and surface evidence with VK-5/VK-8;
  check current issues before creating duplicate infrastructure. Record Windows
  as a future precondition, not a reason to defer the whole RR-7 finding.
- **Acceptance:** retained evidence identifies the pinned compositor, selected
  GLFW backend and, for rendering, loader/driver/layers. Headless capability
  tests and native examples agree on unavailable state; failure and shutdown
  preserve ownership. Document the precise supported profile and remaining
  compositor/hardware gaps without claiming a percentage of supported PCs.
- **Remaining specification work:** the qualification plan must choose the
  pinned compositor/version, backend-selection/fallback behavior, exact evidence
  matrix and CI promotion criteria. The current Cocoa/X11 behavior remains the
  implemented baseline until that work establishes the new profile.

### [deferred] RR-8. Defer bound workers until a concrete consumer requires OS-thread affinity

> **Deferred:** no consumer needs OS-thread affinity today, and the worker
> contract's unbound promise is explicit — clears when a named native service
> has a documented or reproduced OS-thread-affinity requirement that existing
> composition cannot satisfy, with its API and thread contract cited.

**Verification: Verified** — workers make no OS-thread-affinity promise, and no
current consumer requiring it was identified. That is an explicit contract, not a defect
without a service that needs a stronger one. The owner approved deferring an
additional worker mode until such a consumer is demonstrated.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Worker.hs:576` — `forkIOWithUnmask (runChild worker startup)`.
- `packages/foundation/src/Hetoimasia/Foundation/Worker.hs:40` — "It makes no OS-thread-affinity guarantee".

**Handoff context:**

- **Current behavior:** unbound workers only; the GLFW owner is the process main thread and is not a worker.
- **Expected disposition:** defer implementation, with the checkable precondition that a selected native service has a documented or reproduced OS-thread-affinity requirement that existing composition cannot satisfy. Name that service, its API/thread contract and the evidence before reopening the design. The deferred marker is already applied; retain it until that precondition is met.
- **Scope and constraints:** do not prebuild a generic `forkOS` option or assume an audio callback automatically requires one. If the precondition is met, design the specific construction/use/teardown affinity and prove startup, cancellation, supervision and drain behavior. A bound worker is still not GLFW's required process main thread.
- **Remaining uncertainty:** the identity and requirements of a concrete consumer. Current Vulkan work is not gated on adding this worker mode.

## Input surface

### [deferred] RR-9. Design the next input arc after Vulkan boilerplate

> **Deferred:** the approved work is a design task, which this repository
> captures in a `*_design.md` through the design-epic workflow rather than in
> an issue — clears when the input arc's design document exists and its EPIC
> entry carries `[#N]`, which this entry then adopts.

The bound GLFW surface covers window control, monitors, and keyboard, mouse
button, cursor position, cursor enter, scroll, and focus callbacks. It binds no
cursor mode or raw mouse motion, no joystick or gamepad, no clipboard, no file
drop, and no window icon. These are missing capabilities, not demonstrated bugs
in the implemented surface. The owner approved a scoped design task for the
next input arc, with implementation following the Vulkan boilerplate rather
than one issue adding every remaining GLFW input function.

**Evidence:**

- `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs` — no import of `glfwSetInputMode`, `glfwRawMouseMotionSupported`, `glfwGetGamepadState`, `glfwSetJoystickCallback`, `glfwGetClipboardString`, `glfwSetDropCallback`, or `glfwSetWindowIcon`.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:392-411` — `WindowCallbacks` enumerates the fifteen bound callbacks.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Input.hs` — the feed carries key, character, button, scroll, and focus payloads only; cursor position coalesces into the observation.

**Handoff context:**

- **Current behavior:** every listed feature is absent rather than wrong.
- **Expected first task:** design cursor capture/disabled mode and raw motion with focus-loss cleanup first, gamepad polling and hotplug next, then clipboard/text interaction. Keep file drops and window icons as separate later additions. Inspect Synarchy's useful device/input behavior and preserve lessons without copying its central game environment.
- **Required decisions:** define relative-motion accumulation and consumption, overflow/reset behavior and capture release/reacquisition on focus changes; a latest absolute cursor position is not the relative-motion contract. Define gamepad identity, disconnect/reset handling and polling ownership. Keep physical input and device capabilities in the engine; game-specific action bindings and gameplay state belong above it.
- **Acceptance of the design task:** specify narrow interfaces, state/thread/lifetime ownership, bounded messaging semantics, backend capability differences, a headless/native test split and independently solvable delivery slices. State how new feeds preserve existing keyboard/character behavior. Do not assume clipboard operations provide a complete text-editing or IME implementation.
- **Scope and constraints:** preserve native-handle privacy, callback containment, owner-thread rules and explicit input resets. Give any disruptive tests their existing consent/optional treatment. A Vulkan-boilerplate dependency should identify concrete delivered capabilities when the issue is drafted, not become an accidental requirement to finish every Vulkan slice before designing input.
- **Remaining specification work:** the design defines API shapes and delivery prerequisites within this approved priority order. This report is not an implementation specification for the whole input inventory.

## Vulkan bridge prerequisites

### [#155] RR-10. Carry the pre-initialization hook requirement through existing VK-5

P-7 requires the session to run a checked integration step, loader selection,
after taking ownership and before `glfwInit`, and to reset it after termination
or failed initialization. The session assembly currently has no such seam:
hints and initialization are one stage with nothing between them, and the
`Native` table has no operation for a loader.

**Verification: Verified** — already planned: P-7 and VK-5 explicitly own
this missing integration capability. The owner approved checking and carrying
that coverage forward rather than filing an independent duplicate prerequisite.

**Evidence:**

- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:895-901` — `initialize` calls `nativeSetInitHints` then `nativeInitialize` with no injectable step between them.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:418-502` — `Native` declares no loader, surface, or Vulkan-support operation.
- `docs/vulkan_backend_design.md`, P-7 — specifies the additive capability, its ordering, and the reset on every exit.
- `docs/vulkan_backend_design.md`, VK-5 — names the opaque session-integration capability, pre-init loader selection and reset on all exits in its delivery scope.

**Handoff context:**

- **Current behavior:** the window-only session is complete; the Vulkan-aware session cannot yet be composed.
- **Expected direction:** exactly what P-7 describes, as an additive constructor beside `sessionAssembly`, with the seam examples covering ordering, failure before native effects, and the reset on both exits.
- **Delivery fit:** check VK-5's current tracker state and effective specification. Preserve the requirement there, linking existing coverage or proposing an amendment only if needed. If VK-5 has not been filed, carry it through normal processing of the Vulkan design; do not create a second hook issue. No tracker linkage or terminal report disposition is claimed by this amendment.
- **Scope and constraints:** the header-free native library must keep `GLFW_INCLUDE_NONE`; the Vulkan-typed calls live in the interop component.
- **Remaining uncertainty:** none about ownership of the work; implementation and its evidence belong to VK-5.
