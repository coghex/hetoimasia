# Deferred work

Verified gaps and follow-ups that are waiting on a stated precondition. Each
was reviewed and deliberately not filed. Nothing here authorizes
implementation or a tracker change; when an item's precondition clears, draft
its issue or design through the usual workflow and remove the entry.

The findings reports these came from are in git history
([removed_records.md](removed_records.md)), with their evidence and full
handoff notes.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Status

- [ ] GLFW-UP-1. Upgrade GLFW and retire the temporary no-seat backport
- [ ] FND-3. Render and capture a minimal 3D scene through a public contract
- [ ] RTC-1. Runtime performance evidence lacks a correlated engine timeline — [deferred]: tracing design Q-1 to Q-3 undecided
- [ ] RTC-3. Finite worker jobs lack a bounded workload-execution service — [deferred]: no named consumer yet
- [ ] RTC-4. Content loading lacks asynchronous request ownership and memory budgets — [deferred]: no first content type or consumer chosen
- [ ] RTC-5. Timing primitives lack a worked simulation/input/render composition — [deferred]: no interactive consumer planned
- [ ] RR-8. Bound workers for OS-thread affinity — [deferred]: no named consumer with an affinity requirement
- [ ] RR-9. Design the next input arc — [deferred]: input design document and its epic do not exist
- [ ] VKR-7. Manage pipeline reuse and persistent cache compatibility — [deferred]: needs a renderer with real pipeline variants
- [ ] VKR-8. Define deployment and hardware qualification beyond proof profiles — [deferred]: owner release target and hardware matrix unrecorded
- [ ] CI-5. Integrate `test` and `autotest` with the shared testing contract — [deferred]: remaining receipt and scheduler scope needs owner direction

---

### GLFW-UP-1. Upgrade GLFW and retire the temporary no-seat backport

The project pins GLFW 3.4 with one upstream patch
(`tools/native/patches/0001-wayland-fix-segfault-when-there-is-no-seat.patch`)
that fixes initialization when a Wayland compositor advertises no seat. A
later upstream release includes that fix; 3.5.1 was current when this was
recorded and adds a Cocoa QuartzCore link dependency. Recheck upstream when
solving, qualify the release on every supported platform, pin its version and
checksum, drop the patch and its handling only if nothing else needs it, and
update the `pkgconfig-depends` bound and the declared macOS frameworks. Keep
the native Wayland selection examples.

### FND-3. Render and capture a minimal 3D scene through a public contract

`packages/render-3d` is a reserved stub. The sequencing precondition (depth
attachments, #349 and #350) has landed, so this is ready to design, not
blocked. Establish the smallest public scene and presentation contract with
an independent consumer, showing occlusion and camera changes with retained
image evidence and clean validation. Do not select an ECS, render graph,
model importer or universal scene API to implement the sample. PBR,
animation, shadows and general asset import are out of scope.

### [deferred] RTC-1. Runtime performance evidence lacks a correlated engine timeline

Subsystem counters and structured logs exist, but no shared timeline connects
update work, queue residence, worker activity, native waits and RTS
allocation and GC events. The proposal is
[runtime_tracing_design.md](runtime_tracing_design.md) (an opt-in GHC
eventlog direction), still exploring. Clears when that design records owner
decisions on its Q-1 to Q-3.

### [deferred] RTC-3. Finite worker jobs lack a bounded workload-execution service

Supervision runs finite jobs, but each is its own Haskell thread; nothing
controls admission and concurrency for bursts of short expensive work such as
decoding or generation. Clears when a filed issue or accepted design names
the first consumer with its job granularity and concurrency need.

### [deferred] RTC-4. Content loading lacks asynchronous request ownership and memory budgets

Resource scopes give construction and teardown, not lookup, asynchronous
loading, caching or ownership of load requests, and channel capacity counts
entries, not bytes. Clears when a filed issue or accepted design names the
first content type to load and its consumer.

### [deferred] RTC-5. Timing primitives lack a worked simulation/input/render composition

The runtime computes bounded fixed steps, interpolation and pause/resume
timing, but no worked application establishes which input each catch-up step
consumes and when the simulation publishes its render snapshot. Clears when
the first interactive consumer is named.

### [deferred] RR-8. Bound workers for OS-thread affinity

Workers make no OS-thread-affinity promise, by contract. Do not prebuild a
generic `forkOS` option or assume an audio callback needs one. Clears when a
named native service has a documented or reproduced affinity requirement that
existing composition cannot satisfy.

### [deferred] RR-9. Design the next input arc

The GLFW binding has no cursor mode or raw mouse motion, no joystick or
gamepad, no clipboard, no file drop and no window icon. The owner approved a
scoped design task, in this order: cursor capture and raw relative motion,
then gamepad polling and hotplug, then clipboard and text interaction. Not
one issue adding every remaining GLFW input function. Clears when the input
arc's design document exists and its epic is filed.

### [deferred] VKR-7. Manage pipeline reuse and persistent cache compatibility

Pipelines are created per use with reproducible SPIR-V; nothing defines
pipeline keys, reuse ownership, warmup or persistent driver-cache handling.
Through a representative renderer, define those with bounded storage and safe
handling of invalid cache data, and retain measurements before claiming
reduced stutter. Clears when a renderer has the pipeline variants needed to
define keys and measure creation cost.

### [deferred] VKR-8. Define deployment and hardware qualification beyond proof profiles

The retained proof covers particular Apple/MoltenVK and Lavapipe
environments, not general Linux hardware or a packaged end-user runtime.
Before distribution: select the supported hardware and driver matrix and the
runtime dependency and discovery contract, and verify clean-machine startup
without a developer SDK or validation layers. Clears when the owner records a
first release target.

### [deferred] CI-5. Integrate `test` and `autotest` with the shared testing contract

The local lab integration through `.quruntul/adapter.py` is delivered. The
broader receipt and scheduler scope was left open and needs owner direction
before any design.
