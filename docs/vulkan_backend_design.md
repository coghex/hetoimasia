# First windowed Vulkan backend design

Carry Synarchy's proven windowing and Vulkan decisions into independently owned
Hetoimasia components, with a visible triangle as the first graphics milestone.

Design state: `ready for issue processing`

Owner: `coghex/hetoimasia`; publication target: `master`.
Started 2026-09-12; the owner marked it ready for issue processing on
2026-09-17 under D-27. It specifies tracker work, not an implementation. The owner accepted separate GLFW/Vulkan components
and a first main-thread window/render loop. Infrastructure comes first: establish
messaging, runtime initialization/lifecycle, threading, and independent GLFW
windowing before Vulkan work. The triangle is the eventual first graphics
result, not a reason to accelerate past these foundations. See D-6.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Establish the first windowed Vulkan backend — [#155]
- [x] VK-1. Qualify and pin the shared Haskell toolchain — [#157]
- [x] VK-2. Prove the native compatibility and completion profile — [#158]
- [x] VK-3. Model GPU retention and frame ownership — [#160]
- [ ] VK-4. Provision the pinned native Vulkan environment
- [ ] VK-5. Add the loader-aware GLFW surface bridge
- [ ] VK-6. Capture validation diagnostics with an independent worker
- [ ] VK-7. Own Vulkan instance, device and targets under protected retirement
- [ ] VK-8. Integrate package-native Vulkan fixtures and CI evidence
- [ ] VK-9. Make Template Haskell shaders reproducible
- [ ] VK-10. Manage swapchain generation construction and replacement
- [ ] VK-11. Record through retained managed resources
- [ ] VK-12. Track acquisition, submission and safe frame abandonment
- [ ] VK-13. Track presentation completion and retire generations
- [ ] VK-14. Apply bounded target and allocation recovery
- [ ] VK-15. Complete terminal graphics failure and device-loss teardown
- [ ] VK-16. Compose rendering demand and retirement with TIME and LIFE
- [ ] VK-17. Deliver the multi-window triangle consumer and final evidence

Slices are mirrored below in dependency order. The owner signed off the
reviewed contracts and split on 2026-09-17 under D-27. The native proof gate
is explicit; it is not permission to guess its result. Its #158 merge
precondition is now satisfied; unchecked entries above remain unprocessed.

## Epic contract

- **Goal:** an independent application renders triangles in multiple GLFW/Vulkan
  windows sharing one compatible device on both macOS and Linux, using
  Hetoimasia's logging and resource scopes.
- **Done when:** two rendered windows demonstrate independent resize and close,
  including continued rendering after the first-created window closes, on both
  platforms, with explicit completion and teardown behavior, safe frame skipping,
  bounded target recovery, and final validation evidence under D-21. Q-2/Q-3
  gate the platform proofs; a tutorial that only renders successfully is insufficient.
- **Users and operators:** the owner developing the backend and later 2D/3D
  consumers; agents implementing and testing its bounded parts.
- **Arc label:** propose `vulkan`, color `A41E22`, description “Vulkan backend, GPU resource lifetimes, presentation and platform verification”. No label is created by this design.

## Current handoff at `38388f8` — 2026-09-19

VK-1/#157, VK-2/#158 and VK-3/#160 merged through PRs #171, #174 and
#175. The [qualified toolchain](toolchain.md) and
[compatibility record](vulkan_compatibility_record.md) supply the previously
open preliminary evidence. TIME and LIFE's children, package-owned test
migration, and host repairs #166–#169 are also merged. Consume their current
contracts; do not redraft those prerequisites.

The [batch review ledger](project_review/ledger.md) records the review of
PRs #170–#180. The [Vulkan model review](project_review/175.md) identifies
image-reacquisition and budget-opacity repairs. The
[proof review](project_review/174.md) identifies unsafe unsuccessful-exit
cleanup and partial-construction rollback gaps. Repair those contracts before
dependent native integration relies on them. Successful retained platform runs
still support the selected compatibility profile; the production backend has
not been implemented or verified by that experiment.

VK-4 onward remain unprocessed. The original #158 merge gate is satisfied;
processing a later issue must account for its actual dependencies and these
review findings, rather than preserving an obsolete merge wait or treating
merged code as defect-free. Lua's independent platform verdicts are
inconclusive, so [its design](lua_runtime_design.md) returns to exploring under
D-11 without making Lua a prerequisite of Vulkan.

## Historical handoff at `e0c752e` — 2026-09-17

The following records the earlier design/processing baseline, not current
implementation or tracker status.

The CPU runtime, messaging, and independent GLFW implementation are now present.
Logging, resources, runtime, and messaging arcs are complete. GLFW issues
#87–#100 merged through PRs #101–#114, including the main-thread host, dynamic
windows, native input, and shared native fixture. The
[completion review](project_review_114-101.md) produced repairs #115–#118,
now merged through #119–#122. The [repair review](project_review_122-119.md)
found follow-up #123 (the recovery association after a move between live
monitors), now merged in PR #126. Native desktop-test consent #124 merged in
PR #128. Epic #86 is closed; none of these repairs remains an implementation
gate. This design is ready for issue processing.

The owner requested a pre-Vulkan backlog on 2026-09-16. Scheduling now has its
own [design](runtime_scheduling_design.md), with six reviewed slices; CPU-side
graphics lifetime integration has its own
[design](window_graphics_lifetime_design.md), with four reviewed slices.
Both prerequisite documents have now been fully processed: scheduling epic #131
owns #133/#134/#135/#136/#138/#139, and lifetime epic #140 owns #141–#144.
#133 merged through PR #152 and now provides the monotonic boundary in
`docs/time.md`; #135's native wake capability merged through PR #153, and #142's managed
dependency lifetime runner merged through PR #154. The other TIME and LIFE
children remain open at this review.
Those approved issues, including their canonical approval amendments, own the
prerequisite implementations. This Vulkan document owns actual surface
integration and GPU completion;
do not draft duplicate TIME or LIFE slices here.

The active work is Vulkan-specific completion, surface integration, managed
recording and the platform/toolchain proof. TIME and LIFE already own scheduling
and CPU attachment contracts; their interfaces must be consumed, not redesigned.
The present loop decides idleness from command/event dispatch counts; it does
not yet express continuous renderer demand. None of these GPU choices is
settled by the CPU scope or by completing the GLFW arc.

The GLFW arc supersedes the early windowing proposals below. Keep its accepted
multiple-window ownership and capability boundaries; do not reimplement the
runtime, messaging, window binding, or fixture from historical inventory text.
Linux remote CI and local Cocoa verification remain fixed owner decisions.

The owner plans to process the canonical [Lua design](lua_runtime_design.md)
in parallel with this design work. Its binding and confinement proof gates
remain intact. Neither backend imports the other: application-owned services
connect scripting to eventual rendering consumers. Coordinate shared clock,
runtime, Cabal and CI changes through their existing owners. In particular,
The owner selected VK-1 first. Lua #146 has been amended to require the exact
GHC/Cabal/index baseline that VK-1 qualifies and merges, rather than its former
GHC 9.12.2 requirement. Its body defines the prerequisite's observable completion
and prohibits starting the solve before that gate is satisfied. Canonical
[reapproval](https://github.com/coghex/hetoimasia/issues/146#issuecomment-5718532902)
passed on 2026-09-17 through GPT-6-Astra at high effort; approval does not waive
that dependency. Link VK-1's tracker number into #146 when created. This is a
shared-toolchain prerequisite, not a Lua dependency on graphics code.

Package-owned test migration #129 and #130 is merged on this baseline. Foundation,
runtime and GLFW have their own Hspec suites; root tests now cover console
composition. Do not make those completed moves new Vulkan prerequisites. The
open tracker at this review contains TIME, LIFE and Lua work but no Vulkan epic.

This review checked source/specification contracts; it did not initialize Vulkan,
run a native proof, change the toolchain or publish tracker artifacts. Q-2/Q-3
remain explicit evidence gates, not presumed successes.

### Integration review on 2026-09-16

Source and the open tracker were checked again at `5d381cf` (code unchanged
since `727f59a`). The three reported error paths map exactly to existing repairs;
the two integration boundaries have design coverage here but no open delivery
issue. Do not treat completing the repairs as completing these boundaries.

| Concern | Verified evidence | Disposition |
|---|---|---|
| GPU dependents can outlive a CPU borrow | `Runtime/GLFW/Internal.hs`: `beginClose` and `retireClosing` protect collection borrows, with no graphics-owner retirement acknowledgement. Final host scope exit also releases remaining windows. | Extend the integration lifetime under P-5/Q-2/Q-7 before creating a persistent surface or submitting GPU work; this is outside the delivered GLFW-only contract. |
| Rendering demand does not prevent an idle wait | The same module's `runOwnerLoop` computes the next idle flag from command/event counts only; `Continue` carries no deadline. `defaultHostConfig` sets `hostIdleWait = 0.1`. | P-6/Q-6 must precede a continuously updating/rendering consumer. Native events can end waits early; this is a potential 100 ms delay, not a fixed frame-rate guarantee. |
| Worker command admission does not wake the owner | Public command admission is `IO` around bounded STM admission. It makes no production native wake call. `noteProgressForCheck` calls `glfwPostEmptyEvent` only as a native-test helper. | Design a production wake protocol under P-6, including its session lifetime and admission/cancellation races. The test hook supplies no production guarantee. |
| Creation failure is lost when rollback fails | `createWindow` classifies the native failure as rejection without checking retained cleanup evidence; `testRollbackCleanupPoisons` expects the later cleanup primary. | Covered by [#115](https://github.com/coghex/hetoimasia/issues/115). |
| Observation erases disconnect recovery | `presentationFrom` replaces applied mode; `reconcileWindowMode` derives its pending recovery from that mode. | Covered by [#116](https://github.com/coghex/hetoimasia/issues/116). |
| Partial departure loses the latest windowed placement | `modeAttempt` records `leaving` only on successful completion of all steps. | Covered by [#117](https://github.com/coghex/hetoimasia/issues/117). |

Runtime-host source above is under
`packages/glfw/runtime-glfw-core/Hetoimasia`; window-model source is under
`packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs`. The independently
filed fixture cancellation repair [#118](https://github.com/coghex/hetoimasia/issues/118)
was also required for reliable native lifecycle evidence. All four repairs in
this historical review subsequently merged; the current handoff above records
their review and the subsequently merged follow-up #123. This table is a dated
historical assessment, not a list of current open defects.

## Completed foundations and prior evidence

The historical pre-GLFW inventory is superseded by implemented contracts:
[CPU resources](resources.md), [runtime/supervision](supervision.md),
[messaging](messaging.md), and [GLFW](glfw.md). The continuation facade,
application composition, component state, worker ownership and failure evidence
are delivered; do not rebuild Synarchy's combined Reader/State EngineEnv.

This arc refines FND-2/FND-3 of the older [foundation design](engine_foundation_design.md).
D-1 supersedes that document's early offscreen-first sequence. TEST-2/#93 and
its repair #118 delivered the GLFW-only shared fixture; actual GPU completion
and GPU fixtures belong here. Prior reviews and Git history retain the original
bootstrap inventories; they are not current prerequisite lists.

### Synarchy behavior to carry forward

Read-only inspection of `~/work/synarchy` at
`91fec430ea5596f497d76eb720de9940aeeb6c39`; no game was launched or code changed.
These are current implementation observations, not a comprehensive Synarchy
audit or a claim that every implementation detail should be copied.

| Synarchy source | Useful behavior and intended adaptation |
|---|---|
| `src/Engine/Graphics/Window/GLFW.hs` and `Window/Types.hs` | Explicit window configuration, `NoAPI`, visibility/focus policy, and live geometry sampled after creation. Preserve the distinction between requested configuration and what the platform actually created. Keep hidden automated windows non-activating where supported. |
| `src/Engine/Input/Callback.hs` | Short callbacks publish typed events. Window/framebuffer/focus state continues updating during startup; user-intent input has a separate lifecycle gate. Preserve this separation when input arrives, and keep teardown out of callbacks. |
| `app/App/Graphical.hs` and `src/Engine/Loop.hs` | Application composition connects window creation, callback installation, Vulkan initialization, and the windowed event/render loop. Keep this coherent owning-thread flow while narrowing each component's dependencies. |
| `src/Engine/Graphics/Vulkan/ResizeRequest.hs` | Pure resize decisions; compare the observed framebuffer state with the state a swapchain was built for. Preserve zero-area handling, minimize/restore history, and the distinction between requested size and clamped extent. A newer resize must survive an earlier rebuild. |
| `src/Engine/Graphics/Vulkan/Instance/Plan.hs` and `Instance.hs` | Separate capability decisions from queries and creation. Obtain required surface extensions through GLFW; distinguish required support from optional diagnostics and portability support. |
| `src/Engine/Graphics/Vulkan/Device.hs` | Select graphics/presentation queues with the real surface; avoid duplicate queue creation when families coincide. Enable advertised portability-subset support when required. Triangle requirements should be stated independently of Synarchy's bindless renderer. |
| `src/Engine/Loop/Frame.hs` and `Vulkan/Sync.hs` | Acquire before resetting the submission fence; consume an image acquired with `SUBOPTIMAL`; index presentation-wait semaphores by swapchain image. Preserve these reasons explicitly in implementation and tests. |
| `test/Spec.hs` and `test/Test/Engine/Graphics/Window/GLFW.hs` | Keep the resource continuation around all borrowers. Test project-owned creation through actual observations, including sentinel initial values that cannot accidentally satisfy postconditions. Distinguish environment preflight from engine assertions. |
| `src/Engine/Core/Queue.hs` and `test-headless/Test/Headless/Core/Queue.hs` | Typed STM FIFO transport, transactional dequeue/timeout choice, atomic depth/high-water telemetry, and careful payload laziness that keeps backlog traversal outside ordinary queue transactions. The queue is explicitly unbounded; telemetry does not supply admission or scheduling policy. |
| `src/Engine/Input/Thread/Dispatch.hs` | Ordered input processing publishes each processed state before later events are handled. Preserve causal ordering when another component observes that state and receives related messages. |
| `src/Engine/Core/Thread.hs` | A reusable worker skeleton already exists independently of EngineEnv: worker-specific actions are supplied through a spec. Preserve the distinction between requesting stop and confirming completion, and establish failure state before attempting diagnostic output. Re-evaluate its masking and shutdown policy against Hetoimasia's resource contract when introducing a worker. |

Additional read-only inspection at Synarchy
`064a255f06b59e2b1f8e881dcf4c747d52967a36` on 2026-09-16:
`src/Engine/Core/Clock.hs` provides an injected monotonic source,
`sanitiseElapsed`, and `sampleElapsed`. Its interruption policy caps an elapsed
step at 0.25 seconds and always replaces the previous raw sample, dropping excess
time instead of accumulating catch-up debt. Preserve the separation of elapsed
time from wall-clock timestamps and the testable clock boundary. The numerical
cap and drop policy are evidence for Q-6, not automatically adopted settings.

Implementation handoffs should identify the precise Synarchy functions being
adapted and retain their relevant regression cases. Do not substitute a generic
tutorial implementation without comparing it to this evidence. Keep any copied
code's provenance and applicable license notices. The integration should accept
narrow services and handles; Lua queues, game managers, and EngineEnv are not
dependencies of these new owners.

## Desired experience and scope

The first graphical consumer displays triangles in independently managed windows
sharing one compatible device on both selected platforms (D-7). The existing
console and headless foundation remain usable
without installing or initializing graphics dependencies. Windowed launches are
explicit. A build alone cannot demonstrate the displayed result.

This milestone starts the backend; the broader plan still includes independent
2D/3D consumers and Lua. Existing window controls feed the resize, suspension and close
contracts below. A triangle does not establish a scene,
camera, asset, or game-facing rendering abstraction.

## Decisions accepted by the owner

### D-1. Reach a window with a rendered triangle first

Explicit owner selection in the preceding design conversation. An offscreen
scene is not the first user-visible milestone. Capture can still provide test
evidence for the windowed milestone. D-6 clarifies that this is the first
graphics result after the infrastructure is established, not the immediate
development target.

### D-2. Verify macOS and Linux from the start

Explicit owner selection on 2026-09-12. Both platforms need evidence before
claiming this first graphics milestone complete.

### D-3. Keep remote CI Linux-only and macOS validation local

Explicit owner clarification on 2026-09-12. Do not add hosted macOS jobs.
Describe local macOS commands and retained results alongside the Linux checks.
D-10 selects Lavapipe with isolated X11. Q-3 gates the measured execution
profile; the current hosted checks do not yet verify Vulkan or presentation.

### D-4. Preserve Synarchy's successful GLFW integration decisions

The owner explicitly requested inspection and retention of the spirit of that
work, calling the GLFW integration solid. Start from the relevant existing
behavior and its rationale. Adapt it to the accepted modular ownership policy.

The existing architecture, logging, resource failure policy, Hspec preference,
and selective validation contracts remain applicable; this arc does not replace
them.

### D-5. Separate GLFW and Vulkan; drive the first loop on the main thread

The owner explicitly accepted the proposed ownership/threading direction:
separate GLFW and Vulkan components, with the triangle application processing
events and rendering on the process main thread, adhering to Synarchy's flow.
The first sample does not require a render worker. This settles Q-1's high-level
choice; concrete APIs and package placement still follow the agreed boundaries.
It does not approve every detail of Synarchy's existing worker implementation.

### D-6. Establish the infrastructure methodically before Vulkan

The owner explicitly accepted a queue foundation before graphics, then clarified
that logging, messaging, runtime initialization, GLFW windowing, and ideally
threading should be solid before touching Vulkan. The owner has built triangle
applications many times; reaching another triangle quickly is not the purpose
of this phase.

Keep the completed logging/resource work. Establish reusable messaging with
Hspec coverage, design application/service initialization and state ownership,
and include worker lifecycle and independent GLFW integration in the pre-Vulkan
plan. Worker behavior can be developed and verified through headless Hspec
consumers before it is needed by rendering. Do not postpone threading solely
because a triangle could run without it.

The runtime, worker, messaging, and GLFW slices subsequently landed, followed by
the four GLFW repairs and follow-up #123. The agreed main-thread
GLFW/render ownership still holds:
reusable worker support does not move GLFW operations to a worker. Remote
Linux/local macOS validation and deliberate reuse of Synarchy remain accepted.

### D-7. Render multiple windows using one compatible shared device

Owner accepted this scope on 2026-09-17. The first Vulkan arc supports multiple
independently managed rendered windows on one device where presentation support
allows. Each target owns its surface and swapchain generations; the shared
device outlives all of its targets. Demonstrate independent resize and closure,
including closing the first-created window while another continues rendering.

This extends the consumer scope without changing D-5's main-thread owner or
adding multi-device rendering. Check subsequent surfaces against the selected
device and available queues. The exact unsupported-target outcome remains part
of Q-2/Q-3's policy rather than an implicit device migration.

### D-8. Refresh the Haskell toolchain instead of inheriting Synarchy's pins

Owner requested current GHC, Cabal and compatible packages on 2026-09-17.
Synarchy remains behavioral evidence, not a reason to retain its older versions.
Select and prove the new baseline before final Lua/Vulkan compatibility proofs;
coordinate with the parallel Lua work. D-13 permits release candidates; exact
version pins follow the compatibility proof. This decision authorizes design work, not an
unreviewed change to shared installations, project pins or the CI image.

### D-9. Require verified presentation-fence completion

Owner accepted the explicit presentation-completion mechanism on 2026-09-17.
Submission fences do not satisfy this requirement. Q-2 still selects the exact
extension, feature enablement and destruction proof on both platforms, including
failure paths; neither a Vulkan version number nor a clean validation run alone
proves that contract.

### D-10. Use Mesa Lavapipe for Linux graphics verification

Owner accepted Lavapipe on 2026-09-17. Pin and select the implementation in the
Linux CI environment. Local macOS uses MoltenVK under D-2/D-3. Required-group
selection, exact versions and retained verification evidence remain Q-3/P-10;
software-driver success is not a claim about hardware performance or every GPU.

### D-11. Preserve Template Haskell shader compilation

Owner selected Synarchy's workflow on 2026-09-17: GLSL quasiquotes compiled during
the Haskell build, embedded SPIR-V, and shader errors reported through the build.
Retain interpolation of shared Haskell constants/layout declarations where
useful. No separate manual shader-build step is required.

The inspected `vulkan-utils` implementation invokes `glslangValidator` from
Template Haskell; the workflow still has a native build-tool dependency. Pin its
identity and target environment, include them in cache/CI identities, and make
tool/config changes invalidate the affected shader compilation. Track any
external include inputs too. GHC does not notice an arbitrary executable on
PATH changing merely because a splice once invoked it. Applications need the
embedded output at runtime, not the build-time shader compiler.

### D-12. Require Vulkan 1.3 and preserve the option of other backends

Owner accepted Vulkan 1.3+ on 2026-09-17. Deliver one Vulkan backend with a 1.3
minimum and explicit feature/limit checks, using dynamic rendering and
synchronization2. Newer capabilities may be used through an explicitly enabled
profile without silently raising the minimum for the baseline path. Keep modern
binding/SDK versions independent of that runtime support floor.

Preserve narrow renderer-facing boundaries so another backend can be implemented
later. A Vulkan 1.2 compatibility profile, OpenGL implementation and runtime
backend switching remain later work with their own evidence. Vulkan handles
stay within backend-specific adapters; the first arc does not freeze a universal
graphics API. This resolves Q-9's scope decision; P-1 develops its concrete
consumer boundary.

### D-13. Prefer the newest compatible toolchain, including release candidates

Owner explicitly accepts release candidates for the compiler, build tools and
other dependencies on 2026-09-17, prioritizing current software supported by the
target platforms. Consider published RCs alongside stable releases when choosing
versions; do not hold the project to stable-only or Synarchy's older pins.
The permission does not require tracking floating development branches.

Hardware support is necessary but does not establish compiler/library/FFI
compatibility. Verify the selected combination on Linux and local macOS, retain
the existing runtime failure/cancellation contracts, and pin versions, source
identities and the dependency index once proved. If a candidate fails, record
the blocker and choose a working version or a reviewed repair explicitly.
Recheck release availability when implementing the upgrade; the previously
observed GHC 9.14.2-rc2 is now eligible. This resolves Q-10's policy, without
claiming an upgrade or a successful compatibility proof has already happened.

### D-14. Use the standard Vulkan loader on both platforms

Owner accepted the recommended loader direction on 2026-09-17. Use one standard
Vulkan loader shared by the backend and GLFW, with MoltenVK on macOS and the
selected native/software driver on Linux. Preserve normal loader-managed
validation and tooling. D-13 governs version selection; P-7 still specifies
dispatch ownership, configuration before GLFW initialization and teardown.
Direct MoltenVK loading is not the selected first integration.

### D-15. Centralize lifetime enforcement and keep scheduling flexible

Owner accepted the revised recommendation on 2026-09-17. The backend owns native
resources, accounts for recorded and submitted uses, tracks completion and
controls safe retirement. Rendering consumers can choose supported arrangements
of acquisition, recording, submission and presentation through that owner.
They cannot bypass its submission/resource accounting with untracked native work.

Keep lifetime enforcement separate from scheduling policy. A convenient
render-one-window operation may compose the supported operations; it must not
become the only possible one-callback/one-submission/one-present schedule.
Preserve room for shared offscreen work, batching and independent window demand.
Multiple queues, asynchronous compute and a general render graph are future
capabilities, not additional implementation requirements of this decision.
All exposed paths retain the same cancellation, failure and completion contract.

### D-16. Make frame capacity configurable with a default of two per window

Owner accepted this policy on 2026-09-17. Each rendered window has a finite,
configurable frame-slot limit, defaulting to two, with one also supported.
The limit bounds reusable frame resources; it does not require two queued
frames, fix the swapchain image count or promise a particular latency.

Reuse requires the appropriate completion evidence. Pending work in one window
must leave other ready targets and runtime services able to progress. Account
for aggregate device resource budgets across admitted windows under P-8.
Validate the supported configuration limits and define capacity-exhausted
outcomes in the frame API. This resolves Q-11's default and configurability.

### D-17. Treat device loss as terminal for the affected graphics session

Owner accepted this policy on 2026-09-17. Stop new graphics admission on the lost
device and fail outstanding consumer work with its original diagnostics. Every
window sharing that device loses rendering. Do not automatically recreate the
device or replay work; a later restart design would reconstruct a new session.
Application shutdown still follows the existing required/optional service policy.

Perform protected teardown under Vulkan's device-loss rules. Device loss does
not implicitly destroy child objects: release eligible children before parents,
preserve the device-loss failure as primary and attach cleanup failures. Settle
in-use obligations using the actual operation's specified device-loss outcomes;
do not wait forever for a successful-render signal that will never arrive or
pretend the lost frame rendered successfully. Keep host-side borrowers and
presentation obligations accounted for before acknowledging window retirement.
Q-2 must still prove the concrete native teardown sequence; an unknown or hung
driver outcome retains dependencies under the existing protected-lifetime policy.

Device loss can result from timeouts, power/platform events, driver defects or
invalid application usage as well as hardware problems. The policy is a chosen
failure boundary, not a diagnosis of the user's computer. See
[Vulkan's device-loss rules](https://docs.vulkan.org/spec/latest/chapters/devsandqueues.html#devsandqueues-lost-device).

### D-18. Overlap resize generations within bounded resource budgets

Owner approved this recommendation on 2026-09-17. Rebuild the affected target
while retaining its older generations until their CPU, submission and
presentation obligations retire. Bound retained generations/resources under
P-8 and coalesce resize requests to the latest observed framebuffer state.
If the next replacement cannot fit its budget, pause that target's rendering
and continue servicing other ready windows and runtime work. Do not make
device-wide idle the normal resize mechanism.

Always draining a target before replacement was considered but not selected;
bounded overlap permits progress at the cost of temporary resource duplication.
This does not promise native creation calls never block or make replacement
transactional. Passing `oldSwapchain` retires it even when creation fails, so
replacement failure must have an explicit recovery/failure state. Never resume
acquisition from a retired generation. Concrete budgets and that failure path
remain part of P-8/Q-2's specification. This resolves Q-12's overlap policy.

### D-19. Deliver diagnostics through a backend-owned worker

Owner accepted the bounded queue and separate diagnostic worker on 2026-09-17.
Use the existing logger from a worker owned by the backend lifetime. Native
callbacks capture capped, owned data promptly; they never wait for queue space,
write to a sink or let an exception escape. A full queue records loss, while
latched error/overflow state remains observable independently of log delivery.
The worker must not retain borrowed native callback pointers.

Establish capture and its consumer before enabling native diagnostics; keep
them alive through the final possible teardown callback. Quiesce callbacks,
drain or account for captured messages, await worker completion and then release
logging/storage dependencies. Use the existing worker and failure contracts in
this backend-owned lifetime, not the application worker group that stops before
graphics retirement. Sink/consumer failure must stay observable and must not
replace a primary graphics failure or authorize unsafe native release.

Draining logs on the owner thread was considered but not selected because slow
sinks could delay window/runtime progress. This is a Vulkan adapter for the
existing logger. Q-8 still specifies detailed capacity/overflow behavior and
measurement details; D-20 settles the response to validation errors.

### D-20. Stop graphics work on validation errors at a safe owner boundary

Owner accepted strict handling on 2026-09-17. Whenever validation is enabled,
error-severity reports latch a session failure independently of logger filters
or successful delivery of detailed messages. Observe that failure at safe owner
checkpoints, stop ordinary graphics admission and perform protected teardown.
Finish required accounting for a native operation's outcome before propagating
the failure; do not lose ownership of an operation that already took effect.
The native callback records the error and returns normally: no throwing through
the foreign boundary, Vulkan calls or destruction inside it.

Warnings remain diagnostics rather than automatic session failure. Log-only
continuation after validation errors was considered but not selected. Stopping
does not undo invalid work already issued or establish that cleanup is safe;
the same ownership/completion rules still govern teardown. Validation errors
encountered during teardown remain in the final failure evidence, preserving any
earlier primary failure. Validation tests fail on captured errors or incomplete
diagnostic evidence, including capture overflow; a final verdict follows the
last callback and diagnostic finalization, not merely the last rendered frame.

### D-21. Keep required native checks small and verify each platform in its own environment

Owner accepted this testing policy on 2026-09-17. Selected required portable
Hspec tests run on both platforms. Selected required platform-specific tests
run only on their platform: local macOS/MoltenVK before the solver opens the
PR, and remote Linux/Lavapipe through GitHub CI. There is no remote macOS job
or requirement to reproduce Linux CI locally. Preserve the existing mandatory
floor plus affected non-optional groups plus PR requests; the Vulkan native
group is required when affected, outside the universal floor.

The small required Vulkan native check must complete in less than 30 seconds
per platform, with compilation and image/native dependency provisioning counted
separately. Count test-owned display startup, native fixture creation, examples,
GPU retirement, diagnostic finalization and teardown in that execution budget.
Measure the prebuilt invocation and leave headroom; record build/provisioning
costs separately rather than hiding them. An external test-process watchdog
fails a run that exceeds its budget; it does not relax production lifetime rules
or authorize forced release of resources still in use.

Broader integration, stress, performance and extra-hardware checks are opt-in.
Prefer Hspec; any Python probes are entirely optional, with a documented reason
the boundary cannot reasonably be exercised through Hspec. Optional groups do
not become mandatory merely because their inputs changed. Essential ownership,
failure and cancellation contracts remain required headless tests rather than
being moved into optional probes to meet the native budget. The verification
strategy below fixes local evidence, platform applicability and desktop consent.

### D-22. Let applications classify rendering targets as required or optional

Owner accepted target-level failure isolation on 2026-09-17. The application
explicitly designates each admitted rendering target as required or optional;
creation order does not determine importance or ownership of the shared device.
When bounded, proven-safe recovery is exhausted, an optional target becomes
unavailable and reports its failure while other targets continue. A required
target's failure stops the graphics session through the existing runtime
failure policy. Required/optional target policy is distinct from whether the
application treats the whole graphics service as required or optional.

This isolates recognized target failures, not unknown safety. Device loss and
validation errors still fail the shared session under D-17/D-20; an unclassified
exception or uncertainty affecting shared resources cannot be suppressed because
it originated while rendering an optional target. Graphics keeps the window's
attachment until safe retirement; unavailability does not itself close the
native window or authorize destruction. Cleanup failure preserves ownership and
failure evidence under the existing contract. Intentional close or suspension
is not failure, even for a required target; application exit policy stays with
the application.

Stopping graphics whenever any target cannot recover was considered but not
selected, because optional tool/preview windows should not end healthy
rendering elsewhere. P-14 and Q-2 retain the operation-specific recovery and
admission details still to be specified.

### D-23. Support explicit safe abandonment of unsubmitted frames

Owner accepted this API behavior on 2026-09-17. A renderer may explicitly skip
an acquired but unsubmitted frame as an ordinary outcome. The backend consumes
the frame capability, retains its exact acquisition/resource obligations, and
settles them before reusing the affected objects. Skipping does not by itself
make the target unavailable, warn as a failure, or rebuild its swapchain.
Outstanding abandonment still consumes its bounded resource capacity; it is not
a way to admit unlimited frames while cleanup is pending.

An ordinary skip is distinct from cancellation and an escaping exception.
Cancellation preserves the runtime's cancellation outcome while the backend
protects cleanup; unexpected exceptions follow the existing failure policy.
Neither path automatically replays consumer code. Once any rendering work for
the frame has been submitted, this unsubmitted-frame operation is no longer
legal: the backend must retain the actual submitted obligations. Any internal
cleanup submission must itself be accounted for and completed safely.

Always retiring/rebuilding the affected generation on abandonment was considered
but not selected as the normal path. The exact synchronization and unused-image
release mechanism remains a compatibility/implementation proof under Q-2. If
that proof fails, return to the design rather than silently weakening safety or
substituting a mandatory rebuild. A failed abandonment follows the established
target/session recovery policy and never fabricates reusable resources.

### D-24. Attempt bounded recovery of a lost surface on its live window

Owner accepted automatic surface recovery on 2026-09-17. Stop admission for the
affected target, safely retire its old graphics dependents, and attempt surface
and swapchain replacement on the same still-live GLFW window. Keep the window
attachment throughout and recheck support against the existing shared device
and queues. Healthy targets continue where shared-resource safety permits.

Recovery uses finite attempts and monotonic scheduling, not a busy retry loop.
Repeated loss notifications cannot replenish the budget without genuine
recovery progress. Exhaustion follows D-22's required/optional target policy.
Unknown cleanup safety retains resources and prevents replacement; an attempt
budget is not a deadline permitting unsafe disposal. Partial replacement must
also have proven rollback before another attempt.

Do not recreate the shared device, replace the GLFW window or resurrect a
closing target. A close request wins over pending recovery. Immediate target
failure requiring application-requested reattachment was considered but not
selected. Exact retry limits and platform completion/rollback evidence remain
part of Q-2's concrete recovery contract.

### D-25. Reclaim safely, then retry a native allocation failure at most once

Owner accepted this response on 2026-09-17. Make one bounded pass over
backend-owned resources already eligible for disposal. Retry the failed native
operation at most once, only after actual reclamation progress and only when
its no-effect result or completed construction rollback proves retry safe.
No progress or another failure ends automatic recovery and follows the
established target/session policy, preserving the original failure and recovery
evidence. Device loss, unknown effects and failed cleanup are not retryable
allocation pressure.

Do not replay consumer callbacks or submitted work, evict live generations,
steal another target's reservations, or silently change resolution, quality or
configured frame capacity. Configured capacity exhaustion remains ordinary
backpressure. This recovery is scheduled within owner progress rather than a
global idle wait. Its finite budget belongs to the failing operation and must
survive scheduler turns and nested recovery calls; wrapping it in another
recovery boundary cannot replenish it indefinitely.

Immediate failure requiring application-directed retries was considered but
not selected, because the backend knows which retired resources it can reclaim
safely. Exact accounting and operation-specific rollback/completion evidence
remain implementation gates under Q-2; this is not a general promise that every
allocation failure can recover.

### D-26. Record through managed handles with automatic resource retention

Owner accepted this renderer interface on 2026-09-17. Renderers use a small
Vulkan-specific recording API whose operations retain the exact resource
generations they reference, including the transitive dependencies of supported
bindings. Renderers still choose draw order, pipelines and supported
submission/presentation scheduling under D-15. The backend owns native handles,
recorded/submitted-use accounting, completion and eventual disposal.

Logical release stops new uses through the released handle; existing recorded
and submitted uses retain their generations until their obligations end.
Replacement publishes a new generation without redirecting previously recorded
work. Stale, foreign or already-consumed capabilities must fail before native
effects. Retention enforces lifetime; access ordering, image layouts and memory
synchronization remain explicit contracts of the supported operations.

Trusted raw Vulkan callbacks with manually declared dependency lists were
considered but not selected: the backend could not establish that such lists
were complete. A raw escape hatch would require a separate explicit contract.
Implement the commands needed by actual consumers, starting with the triangle
and its verification readback. Do not build a second complete Vulkan binding,
universal graphics DSL, render graph or renderer-owned destruction framework.
Q-13 is resolved; concrete signatures and accounting transitions remain design
work under P-1/P-8 before dependent implementation slices are ready.

### D-27. Final review and delivery boundaries

The final review on 2026-09-17 checked the contracts above against the current
source, the cached `vulkan-3.27` and `vulkan-utils-0.5.11.0` binding sources,
the pinned GLFW 3.4 header, the local loader/driver inventory, the TIME and
LIFE designs, and the open tracker. The verified corrections are incorporated:
explicit loader, driver and validation-layer selection (P-9), the
header-dependent interop pre-init capability (P-7), an explicit shader target
environment and pinned compiler wrapper (D-11, VK-9), a bounded
presentation-semaphore pool with caller-selected batching (P-2), idle
retirement-poll backoff (P-15), a separately owned diagnostics worker group
(D-19, VK-6), VK-2's temporary Linux proof infrastructure, and the amended Lua
#146 baseline. P-1 through P-15 are the reviewed contract for D-1 through D-26.

The owner signed off the seventeen slices for issue processing on 2026-09-17.
Q-2 and Q-3 remain deliberately open proof gates owned by VK-2, VK-8 and VK-17;
VK-4 through VK-17 stay deferred until VK-2's merged proof passes on both
platforms. A failed proof returns to this document rather than authorizing a
silent policy change.

## Design

### P-1. Separate owners; use one main-thread loop for multiple targets

High-level direction accepted by D-5; the following responsibility sketch
guides the concrete interface design.

Proposed component responsibilities, not final package or API declarations:

| Owner | Owns and mutates | Borrowers and lifetime |
|---|---|---|
| Application composition | Configuration, connected services, exit request | Assembles scopes and runs the first loop; no game state is required. |
| GLFW component | Process GLFW session, windows, callbacks, observed geometry/events | Windows borrow the session. Callback storage lives until callbacks are detached and window use has ended. Session/window/event operations remain on the process main thread. |
| Vulkan component | Instance/device resources, submission state, swapchain generations | Surface integration borrows the window and instance. A generation owns its dependent images/views and synchronization resources; completion constrains destruction. |
| Triangle consumer | Triangle-specific shaders/pipeline choices, draw commands and supported scheduling requests | Borrows the backend's scoped capabilities; never bypasses its lifetime/submission accounting. Later rendering modules can replace this consumer. |

Use one explicit interop boundary for GLFW surface creation; the core GLFW
owner should not need the renderer, and Vulkan device machinery should not
query a game or Lua service. Place that boundary once its smallest concrete
API is agreed. Keep Vulkan-specific types inside backend/integration consumers;
do not freeze a universal graphics interface for one triangle.

#### Package dependency boundary

Use a Vulkan backend package for managed GPU resources and retirement, with its
pure model in a binding-independent component. Its public implementation may
depend on foundation/runtime services and the Vulkan binding, but not GLFW,
Lua or a game. CPU-only project selection excludes this native package.

The GLFW package owns a small interop sublibrary over its private native seam.
It exposes checked integration capabilities without depending on the GPU package
or a concrete renderer. Its C shim includes Vulkan headers before GLFW headers
(P-7). Isolate those headers/link inputs to the selected interop component;
VK-5 must prove an ordinary GLFW-only build with that component disabled and
without a Vulkan SDK. Do not silently impose its dependency on window-only
consumers through package-wide Cabal settings.

A separate runtime/Vulkan/GLFW integration component depends on both interfaces.
It assembles loader-aware host construction, attachments and backend targets,
then TIME-driven progress. The application depends on that integration and its
renderer. The GPU backend never imports the integration back again.

VK-3 establishes the pure/backend package split; VK-5 adds the GLFW-owned
boundary; VK-7 introduces the integration owner, and VK-16 completes its loop
adapter. Component names may follow the existing Cabal conventions, but these
dependency directions and independent CPU/window-only build checks are part of
acceptance. Avoid another generic environment that hides both owners.

#### Renderer-facing boundary

D-26 selects a small Vulkan-specific recording interface with opaque managed
resources and automatic retention of the generations each operation uses.
Keep the renderer's control over pipelines, draw order and supported scheduling,
while backend code owns native handles and lifetime accounting. This is not a
universal 2D/3D graphics language or a replacement binding for all Vulkan calls.
Grow the recording operations only as actual consumers require them; the first
consumer needs triangle drawing and verification readback, not asset streaming.

Conceptual capabilities below describe responsibilities, not final Haskell names
or signatures:

| Capability | Renderer may do | Backend retains/control |
|---|---|---|
| Device information and target description | Inspect supported features and current target format/extent to choose compatible rendering data | Device/session identity, actual native device/queues, and target generation |
| Managed rendering resources | Request supported construction, use handles and request logical release | Native allocations and exact dependency generations; release does not destroy resources still referenced by recording or submitted work |
| Acquired frame capability | Inspect the acquired generation's immutable frame information; record or explicitly skip | Window/image ownership, frame budget and synchronization; a newer resize cannot mutate this frame's identity |
| Scoped recorder | Bind managed resources and issue supported commands | Command storage and automatic generation references; consumer code runs once and cannot submit or destroy native objects directly |
| Recorded batch | Schedule submission through the backend or discard while unsubmitted | Sealed command data and recorded-use references, even if the caller loses its handle |
| Submission/presentation capability | Request supported submission/presentation ordering and inspect progress | Actual effects, completion records and deferred disposal; returning a ticket does not mean GPU work completed |

Keep acquire, record, submit, present, abandon and progress composable under
D-15. A convenience single-frame helper may compose them but cannot be the only
API. Every operation validates owner, device/generation and legal state before
native effects. Reusing an alias after submit/skip or retaining a recorder past
its scope cannot bypass those checks. Do not claim Haskell lexical scope alone
prevents a caller from retaining a handle. Frame-local capabilities must not
become persistent game/Lua identifiers.

The first supported scheduling vocabulary is explicit. Names below are design
names; exported spelling can follow repository conventions without weakening
these transitions:

| Operation | Contract |
|---|---|
| `tryAcquireFrame target` | Return an owned frame or a typed Pending/Suspended/Closing/Unavailable outcome. Invalid/foreign handles are misuse failures, not Pending. |
| `recordFrame frame action` | Run the consumer once with a checked recorder; produce one sealed, single-use batch for that frame. No retained recorder can issue later commands. |
| `submitFrames nonEmptyBatches` | Submit ready batches on the single graphics queue in caller order, retaining every exact dependency. Validate/reserve the whole request before native effects; no automatic callback replay. |
| `presentFrame submittedFrame` | Present one target image per native request. Different targets may present independently; delaying presentation keeps that frame's obligations and consumes bounded capacity. |
| `skipFrame frame` / `discardBatch batch` | Mark unsubmitted work unusable, invalidate its command references safely and schedule acquisition cleanup under P-2. Return is acknowledgement of retirement admission, not GPU completion. |
| `progressBackend` / status queries | Advance bounded owner work; report completion, demand and latched failures without transferring destruction authority. |

An alias cannot consume a frame or batch twice. A request containing a duplicate
batch is rejected before any native call. A multi-batch submit records one
completion obligation with all its members; the implementation may expose
separate submissions too. Initially use one graphics queue and one selected
presentation queue, shared by all targets (the same queue where possible).
If their families differ, use a verified concurrent-sharing swapchain profile;
do not accidentally require an unimplemented ownership-transfer path. Check new
surfaces against the already-created queues. Extra transfer/compute queues,
reusable command lists and independent multithreaded recording are later work.

Managed construction returns opaque resources under the controller. Logical
release denies new recordings but cannot invalidate already sealed batches.
The minimal recorder supports dynamic rendering, compatible graphics pipelines,
viewport/scissor, triangle draws, barriers required by those operations and
bounded verification readback. Unsupported commands fail at the interface rather
than becoming an unchecked callback escape hatch.

Recording operations retain dependencies through managed handles, including
transitive resources of supported bindings. A batch must not look up whichever
resource generation happens to be current later at submission. Replacement or
CPU-side editing cannot silently change data expected by a retained batch; an
in-place update needs an explicit validated access/ordering contract.
Advanced descriptors, indirect references or device addresses need their own
complete reference/mutation contract before they are exposed; they are not
implicitly supported by the triangle API. Retention proves lifetime only:
supported commands still need explicit layout, access and synchronization rules.
This is not an implicit render graph or automatic hazard resolver.

D-26 rejects manually declared dependency lists as the normal recording
interface. Any later raw escape hatch needs a separate explicit contract;
ordinary renderer code cannot bypass retention or native-effect accounting.

Establish each operation's resource references before native recording can
capture them. Exceptional recording keeps partial command storage and its
references owned until reset/free or another proven invalidation path makes
future submission impossible. Discarding recorded commands does not itself
settle a frame's acquisition or presentation obligations. Successful submission
hands references into tracked completion without a gap in ownership; failed
submission follows P-2/P-14's actual-effect rules.

Logical release, batch discard and completion each end only their own holds.
They cannot release another batch's reference to a shared resource. Backend
ownership remains explicit even if a Haskell handle becomes unreachable; GC
finalizers are not the disposal or GPU-completion mechanism. Closing an owner
must account for outstanding records instead of depending on callers to return
every token. Define these transitions in the retirement model before wiring
the recorder to native commands.

Synarchy's `src/Engine/Graphics/Vulkan/Command/Record.hs` at `02b7b183a` is useful
context: it records viewport/scissor and ordered layer draws and integrates
capture into that command buffer. Preserve deliberate draw ordering and
coordinated capture; replace passing broad `GraphicsState` and native handles
with the narrow capabilities above. Validate the boundary with the triangle
consumer; scene/render graphs and common 2D/3D drawing contracts remain later
designs.

D-15 settles the ownership/scheduling split. Define supported composable
operations and their state transitions before choosing convenience wrappers.
Recording, batching or delaying presentation must retain the exact resource
generations involved; flexibility does not transfer destruction responsibility
to each renderer. Keep native effects on the accepted owning thread.

The first GLFW loop will process events and consume window-state changes on
the process main thread. Drawing joins that loop only after the infrastructure
phase. Reusable workers developed in that phase retain their own explicit
ownership and communication contracts.
GLFW's [thread contract](https://www.glfw.org/docs/latest/intro_guide.html#thread_safety)
requires initialization, termination, window creation/destruction, and event
processing on the thread that calls `main`. A Haskell bound worker is not proof
of that identity. The eventual graphics test runner must preserve it too.

## Design proposals

### P-2. Preserve lifecycle behavior before adding rendering breadth

Use the existing GLFW windows, including their already delivered controls and
mode changes. Define the backend's response to close, minimize/restore, mode
changes, and framebuffer resize, including high-DPI sizes. Fonts, texture
streaming, and scene rendering remain outside this first graphics milestone.
D-16 selects a configurable frame-slot budget, defaulting to two per window
with one supported; swapchain image ownership stays separate from frame slots.
D-15 permits flexible scheduling within that finite budget.

#### Proposed frame ownership table

This table develops D-15/D-16/D-18/D-22/D-23; concrete ABI/completion proofs remain
Q-2 gates. A frame slot, acquired image, swapchain generation and submission
are distinct identities. Track acquisition, CPU recording references, GPU uses
and presentation obligations separately: presentation may be queued before GPU
execution completes, so this is not one enum whose next state erases the last
obligation. Retire each object only when all obligations relevant to it end.

| Phase | Backend retains | Next operation and failure/cancellation exit |
|---|---|---|
| Reserved; no image acquired | Bounded slot reservation and any prepared CPU work | Attempt acquisition with a finite/nonblocking policy. Not-ready/timeout returns scheduling status, releases unused reservations and creates no image or fence-completion obligation. |
| Image acquired; unsubmitted | Exact target/generation/image, acquisition synchronization and recorded resource references | Record, submit or explicitly abandon. A successful acquisition includes `SUBOPTIMAL`; never discard its image index. Abandonment must settle acquisition synchronization and relinquish the image, not wait for a nonexistent rendering submission. |
| Rendering submitted | Actual submission completion record, command/pool storage, referenced generations and any still-unpresented image | Presentation may be queued without a CPU wait for render completion. Cancellation stops new ordinary work but retains submitted obligations; it cannot undo submission or turn a timeout into completion. |
| Presentation enqueued | Per-target presentation record and synchronization, plus any remaining rendering/CPU obligations | Observe the selected maintenance-fence retirement evidence separately from rendering completion. Error results must be classified by their actual enqueued effects. |
| Retiring or abandoning | Every obligation still outstanding and the native dependency chain | Advance bounded completion checks and safe disposal. A caller returning, cancellation or an optional-target failure cannot release the window attachment early. |
| Reusable or disposed | No outstanding use of the specific object being reclaimed | Reuse a slot only after its own obligations end; destroy a retired generation only after its CPU/GPU/presentation uses end. Terminal or foreign tokens cannot submit, present or release it again. |

Reserve bookkeeping capacity before native calls. Protect each native effect
and recording of its result against cancellation; a pending owner-level failure
is delivered only after that accounting. Keep consumer recording code outside
this small protected handoff. The handoff masks cancellation until the native
result and its ownership obligations are recorded; it does not wrap an arbitrary
consumer callback or GPU wait in an uninterruptible release. Preallocate the
completion record and retention capacity. If bookkeeping cannot be committed
after a possible native effect, enter an explicit uncertain-effect state that
retains parents and stops admission; never roll back as if the call did nothing. Reset a submission fence only when prepared to
attempt submission. A reset followed by a call that submits nothing leaves an
unsignaled, non-pending fence; no drain may wait for it as if work existed.

Synarchy at `02b7b183a`, `src/Engine/Loop/Frame.hs`, preserves an acquired image
on `SUBOPTIMAL` and acquires before resetting its rendering fence; retain those
lessons. Extend them here to recording/submission failure, finite waits and
explicit accounting. Track the suboptimal observation itself for coalesced
replacement rather than depending on a later present returning the same status.

For D-23, use a tracked cleanup submission that waits on the acquisition binary
semaphore, executes no consumer commands and carries its own completion fence.
Once that submission has completed, the semaphore has been consumed and the
unused image can be returned through the selected maintenance extension's
[image release](https://docs.vulkan.org/refpages/latest/refpages/source/vkReleaseSwapchainImagesKHR.html).
Release itself does not reset the acquisition semaphore. Reserve cleanup
bookkeeping/synchronization when admitting a frame so capacity pressure cannot
make every admitted frame impossible to abandon. VK-2 must prove this sequence
on both profiles; a failed cleanup submission/release retains ownership under
P-14. Ordinary successful skips need no swapchain rebuild or consumer replay.

There is a separate exit after successful rendering submission but before any
presentation is enqueued: close, cancellation, or presentation admission failure
can leave that image unpresented. Await its actual rendering completion, return
the now-unused image through maintenance, and settle the render-finished
semaphore whose signal may have no consumer. Either consume it through tracked
cleanup or replace it only after every pending use has ended; a signaled binary
semaphore cannot simply be signaled again. This path retires completed work; it
does not pretend that a submitted frame was an unsubmitted skip.

Synchronization records are keyed separately:

- A frame slot owns command storage and acquisition synchronization. Rendering
  completion refers to the submission record that used it.
- Use a finite per-target pool of render-finished binary semaphores and
  presentation-fence records. Reserve a pair before admitting acquisition; attach
  it to the exact generation/image for this use. It may be recycled only after
  that present's maintenance fence or the proven unpresented-frame cleanup.
  It is not permanently tied to an image index. Pool exhaustion is backpressure,
  never permission to grow unboundedly or recycle a busy semaphore.
- Each actual present retains its generation until its obligations end.
  Rendering completion alone cannot recycle its presentation synchronization.
  Image reacquisition need not wait on the host for the previous present fence
  solely to obtain a semaphore: a free pool record can service the new frame.
  Still obey the new acquisition semaphore before touching the image.

Synarchy's per-image scheme is valid, and the
[Khronos guide](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
describes safe reuse through reacquisition synchronization. The extra mandatory
host-side present-fence check in this document's earlier revision was stricter
than that scheme requires. With maintenance fences already required here, a
bounded pool keeps reuse/disposal explicit without adding that image-specific
host stall. This does not remove actual WSI/image backpressure.

The initial submission completion primitive remains a fence per native submit
call. Separate target submissions have separate records; an explicitly requested
multi-batch call deliberately shares one completion record. Never automatically
combine unrelated targets just to save a call. A caller that needs earlier
retirement chooses separate submits. Tests cover both schedules. Shared-device
independence concerns ownership, admission and owner-loop service; it cannot
promise independent GPU latency on a common queue.

Keep abstract completion keys in the pure model so queue timeline values can be
added later without changing managed resource ownership. They can improve batch
granularity, but are not a correction required to make fences safe. Multiple
values in one native call require separate `VkSubmitInfo2` batches; same-batch
semaphore signals are unordered. A timeline signal alone does not certify a
sibling binary signal has finished, nor does it establish presentation retirement.
Any later timeline path must prove signal scope, monotonic values, failed-submit
bookkeeping and destruction safety. See
[signal ordering](https://docs.vulkan.org/spec/latest/chapters/synchronization.html#synchronization-signal-operation-order).

D-23 accepts an explicit consumer outcome for intentionally skipping an
unsubmitted frame, separate from an exception. The backend performs abandonment
and can accept later frames within its remaining safe capacity. Do not catch
arbitrary recording exceptions and silently continue or replay the consumer.
The API behavior is settled; Q-2 retains the exact native abandonment proof.

D-18 selects bounded overlap of replacement generations on resize. Preserve Synarchy's
sampled-framebuffer and newer-request handling; choose retirement separately
from resize detection. Any design using Vulkan's `oldSwapchain` parameter must
model its irreversible retirement even when replacement creation fails.

### P-3. Establish a small message-passing foundation before its GLFW consumer

Completed by messaging epic #73; Q-4 is resolved. Use bounded channels,
prepared payloads, snapshots and supervised inboxes from [messaging.md](messaging.md).
The historical transport proposal is superseded by that implemented contract;
no additional queue abstraction or event-bus delivery belongs in this arc.

### P-4. Design scoped application composition and component-owned state

Completed by runtime epic #52 and its repairs; Q-5 is resolved. Use narrow
services and explicit application composition under the existing failure and
supervision contracts. LIFE-2/#142 adds the managed dependency lifetime needed
by graphics; it is not a reason to rebuild the runtime or add EngineEnv.

### P-5. Integrate graphics retirement with both window close and host exit

Use LIFE #141–#144 from
[window_graphics_lifetime_design.md](window_graphics_lifetime_design.md).
Its protected IO host lifetime and exclusive window attachment are prerequisites,
not another Vulkan-owned CPU resource redesign. Acquire the attachment before
creating a surface. A transient `withHostWindow` callback is insufficient.

The composition order is logger, shared loader, diagnostic lifetime, protected
GLFW host plus graphics-retirement controller, then application supervision.
GPU objects are created dynamically inside that controller: a session supplies
instance extensions, a window supplies the bootstrap surface, then a compatible
device is selected. The shared device belongs to the session/controller, never
to the first-created target. Ordinary nested `Scoped` allocations must not unwind
the device or instance before the controller's protected drain.

Every exit follows the same ordering constraints:

1. Quiescence closes admission and settles pending commands under LIFE's finite
   STM hook; it performs no native wait.
2. Application workers stop and drain while their borrowed dependencies remain
   live. They cannot depend on a stopped event loop to finish a new command.
3. The owner performs protected IO graphics retirement: invalidate unsubmitted
   work safely, settle actual GPU/presentation uses, and destroy dependents.
   The controller progresses directly; it does not enqueue work to its ended loop.
4. Dispose each target's swapchains before its surface and acknowledge its exact
   attachment only after all window-dependent objects are gone. Shared device
   resources precede the device; surfaces and device precede the instance.
   Other live targets continue when just one target closes.
5. Keep diagnostic capture live through the last possible Vulkan callback,
   including instance destruction. Native windows/session may release only
   after their attachments retire. Reset persistent borrowed loader configuration
   before ending loader ownership; join diagnostics before releasing their logger.

These are dependency constraints rather than a misleading linear `Scoped`
nesting. Initialization failure before the application quiescence hook is
installed uses the same controller protection. Repeated cancellation cannot
release ancestors early. Native Vulkan destruction, which may enter a driver,
belongs in protected IO retirement rather than foundation's uninterruptible
release callbacks. Disposition uses proven normal or device-loss rules;
failed cleanup preserves evidence and never manufactures an acknowledgement.

Later texture streaming can reuse this GPU ownership model, but assets becoming
unwanted, ended CPU references and completed GPU uses remain distinct events.
No asset manager or new concurrent foundation Collection is part of this arc.

### P-6. Consume TIME scheduling without adding another loop

Use TIME #133/#134/#135/#136/#138/#139 from
[runtime_scheduling_design.md](runtime_scheduling_design.md): its injected
monotonic source, deadlines, wake protocol and per-window render suspension.
Simulation policy remains application-owned; hidden, minimized or zero-area
targets suspend new rendering without abandoning existing retirement obligations.

Backend progress reports immediate work, its earliest absolute retry/poll
deadline, or no demand. Combine that with consumer render demand and TIME's
checkpoint/wait bound. A pending GPU obligation creates a finite next progress
deadline even when all windows are suspended; an unsignaled fence is not
immediate work that justifies spinning. Use round-robin bounded progress across
targets, and retain command/event fairness. Work duration counts against the
next deadline rather than being followed by an unconditional sleep.

All native queue and target effects stay on the accepted main-thread owner.
Worker publications use existing channels and the production wake capability;
notifications are hints and authoritative pending state survives a lost wake.
The bounded-poll fallback belongs to TIME. Do not copy its clocks, native-wake
lifetime or fixed-step driver into the backend.

### P-7. Establish one loader and a narrow surface bridge

VK-5 owns the Vulkan-specific bridge excluded from LIFE-4. Q-2 deliberately
leaves the native ABI proof to VK-2; no guessed pointer representation may pass
that gate.

Own the Vulkan loader outside both the GLFW session and Vulkan instances. Give
the backend and GLFW the same loader's `vkGetInstanceProcAddr`; do not mix a
direct MoltenVK instance with a different loader's dispatch. Resolve platform
loading and ABI details through the Q-2 compatibility proof first.

GLFW 3.4's public header guards `glfwInitVulkanLoader`,
`glfwGetInstanceProcAddress` and `glfwCreateWindowSurface` declarations with
`VK_VERSION_1_0`. The extension-name query is unguarded. This was verified in
the project's cached 3.4 header and the
[upstream header](https://github.com/glfw/glfw/blob/3.4/include/GLFW/glfw3.h).
The interop C shim includes Vulkan headers first; do not duplicate their ABI
declarations in the ordinary header-free native component.

The session gains an additive, opaque integration capability for pre-init loader
selection and post-termination/default reset, populated by the interop component.
The ordinary `SessionConfig` stays a pure window configuration; an additive
integration constructor can accept the capability separately rather than adding
arbitrary `IO ()` actions to an Eq/Show configuration record. The session model
invokes checked integration operations after taking session ownership and before
`nativeInitialize`, beside the existing `nativeSetInitHints` step. User callbacks
cannot inject arbitrary initialization work under a lock or bounded finalizer.
The capability retains the loader and records its session use; stale/foreign use
fails before native effects, and scripted tests cover ordering and failure.

Preserve the window-only constructor. The loader setting survives termination,
so the integration must reset it on normal termination and failed initialization
before ending borrowed loader ownership. If reset or termination is uncertain,
retain/poison the relevant ownership rather than leaving a dangling function
pointer for a later window-only session. See
[GLFW's loader contract](https://www.glfw.org/docs/3.4/group__init.html).
The header-free path need not itself call a Vulkan-typed reset; successful
interop teardown restores the default before it can become available again.

For the candidate binding, `Vulkan.Dynamic` imports `vkGetInstanceProcAddr`
from the linked loader. The shim can pass that same linked symbol to
`glfwInitVulkanLoader`. VK-2 verifies loader identity using the resolved function
addresses and image provenance (for example `dladdr`, accounting for symbol
stubs), rather than assuming two independently found libraries are the same.
No redundant GLFW instance-proc wrapper is required.

Copy extension names while the session is live. Create a surface only under the
protected window attachment, with its native pointer borrowed synchronously
inside the bridge. Preserve typed ownership across partial construction and
cancellation. Destroy the surface before its attachment acknowledgement and
instance release. VK-2 still proves handle representation/calling convention;
the need for headers is no longer an unresolved question. Extend only the small
GLFW seam operations this lifecycle actually needs.

Device selection may query a real surface without making a shared device's
lifetime a child of the first window. Record the final ownership graph and how
subsequent windows validate presentation support before multi-window rendering.
Closing the bootstrap window must not accidentally release another window's
device. This is distinct from the already accepted first main-thread owner.

### P-8. Retire GPU generations beneath the window attachment

Agree with the missing boundary, but start it inside `gpu-vulkan`. A private
pure retirement model with abstract completion facts is testable without a GPU;
that does not require a new foundation-wide resource framework or public
backend-independent API before a second backend exists.

The model distinguishes logical release, ended CPU uses capable of future
submission, recorded-but-unsubmitted references, and completion of every
submitted use. A queued or executable command buffer can retain a resource even
before a submission fence exists. Key obligations by device/queue and resource
generation; one scalar completed serial is valid only after proving a common
submission order. Presentation obligations remain separate from submission
fences. Resetting/re-recording a command buffer and abandoning an unsubmitted
batch must discharge the right references explicitly.

A successful submission publishes its completion obligation atomically with the
owner's bookkeeping under a protected handoff. Cancellation or failed submission
must not leave an unsignallable fence treated as pending work, nor release a
resource whose native submission outcome is uncertain. D-17 makes device loss
terminal to its session, with a distinct teardown path rather than a synthetic
completed fence. Q-2 must establish
which evidence authorizes which destruction on that path.

Use bounded frame arenas, reusable command pools and generation records owned
by the protected controller. Add descriptor pools only when a supported command
actually needs them. CPU-only roots can use `Scoped`; native GPU owners must use
P-5's protected IO lifetime. Reclaim a frame slot only after
its CPU and GPU obligations end. Bound retired bytes/objects and apply explicit
backpressure when the bound is reached; an indefinitely unsignalled device must
not produce an unbounded deletion queue. Stop admission, retain parent resources,
and preserve disposal failures without replay when safe release is unknown.

The existing Collection is a single-owner CPU primitive, not inherently limited
to windows: a render owner could own its own collection. Do not share one across
threads or turn it into a concurrent GPU registry. `Scoped` is useful beyond
startup whenever lexical ownership fits; it does not supply deferred completion.
Per-frame native allocations should not be the default strategy. There is no
claim that masks alone have been measured as this engine's bottleneck.

### P-9. Prove the toolchain before building the renderer

The first proposed Vulkan work is a compatibility proof after D-8's toolchain
refresh, not a triangle or a general renderer API. Synarchy's inspected local build plan uses GHC 9.12.2,
`vulkan-3.26.6` and `vulkan-utils-0.5.10.6`; both projects pin the Hackage index
at 2026-08-14. This is a useful candidate baseline, not evidence that Hetoimasia
already builds those components on Linux and macOS. D-8 now prefers a current
compatible binding over retaining these historical pins. Inspect the binding's actual
loader, callback and FFI modes; potentially blocking calls and Haskell callbacks
must remain compatible with the threaded RTS and the chosen failure boundary.

Record exact compiler/binding, loader, driver, validation-layer and shader-tool
versions. Query real capabilities: advertised Vulkan API version alone does not
establish the presentation-completion extensions Q-2 needs. Evaluate the standard
loader with MoltenVK on local macOS and pinned Mesa Lavapipe in the Linux image;
explicitly select the intended ICD so CI cannot silently run another driver.
Software Vulkan gives useful API and image correctness evidence, not hardware
performance coverage. Preserve portability enumeration/subset requirements from
Synarchy and verify them against the selected versions.

Provisioning is its own code-and-docs delivery: extend the existing image recipe,
publish and verify a new digest, update the native/toolchain evidence identity,
and reuse the existing cache path. Do not rebuild/install Vulkan dependencies in
every test job. CPU-only projects must still build without this SDK. Select one
pinned build-time SPIR-V compiler; track shader sources, target environment,
flags and tool identity, and make generated artifacts reproducible/packageable.
D-11 selects Template Haskell as the build integration, preserving embedded
shaders and interpolation; pinning the underlying compiler does not introduce
a separate manual workflow.
Runtime shader compilation and shader hot reload are outside this first arc.

No native Vulkan proof was run during this review. Q-2/Q-3 are deliberately
open evidence gates owned by VK-2/VK-8, with the stop conditions recorded below.

#### Shader splice adapter

The inspected `vulkan-utils-0.5.11.0` `vert`/`frag` quoters call
`compileShaderQ Nothing`; its backend invokes `glslangValidator` on PATH
and registers no dependent files. Preserving Synarchy's TH workflow does not
mean preserving those implicit build inputs. VK-9 supplies a project adapter
using the interpolating `glsl` string quoter with an explicit compile splice
target, initially `Just "vulkan1.3"`, and registers the shader/include inputs
and a generated compiler/flags/native-manifest fingerprint with TH.

Provision a private-prefix `glslangValidator` wrapper/alias that resolves to the
pinned compiler, and arrange the build child's PATH deterministically. No global
PATH mutation is needed. Upstream
[renamed the executable and retained a compatibility symlink](https://github.com/KhronosGroup/glslang/blob/main/CHANGES.md);
its future disappearance is a packaging risk, not a currently verified removal.
A small local adapter plus wrapper is preferred to forking the entire binding.
If compiler identity changes, regenerate the registered fingerprint before GHC
decides whether the splice is up to date. Test that behavior explicitly.

#### Binding and callback configuration

The reviewed `vulkan-3.27` source defaults `safe-foreign-calls` to false and
explicitly requires it for callbacks into Haskell. Enable that flag for this
backend before installing a Haskell validation callback. Audit the pinned
binding and the GLFW bridge together: using a safe wrapper for just a fence
wait is insufficient when create, submit or destroy can invoke validation.
Compile native executables with the threaded RTS. Safe FFI permits Haskell
callbacks and other Haskell threads to progress; it does not change GLFW's
main-thread rule or guarantee driver-call cancellation. See
[GHC's FFI contract](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/ffi.html).

The candidate also enables `darwin-lib-dirs` by default, injecting
`/usr/local/lib`. Disable that ambient-search flag and supply the project-managed
loader prefix explicitly, including executable runtime resolution. Linux
pkg-config discovery and macOS linking must select the same loader used by
P-7. Record binding flags in build inputs and evidence. A later native-only
capture shim could avoid Haskell reentry, but disabling safe calls is not an
unmeasured optimization allowed by this design.

These findings were checked in the locally cached `vulkan-3.27` source
(`vulkan.cabal`, `Vulkan.Dynamic`, generated device/queue/debug-utils imports).
VK-2 must recheck the actually pinned version, calling conventions, callback
reentry, and dispatch identity on both platforms.

#### Compatibility profile — proved on 2026-09-18

VK-2 (#158) ran the proof this table was waiting for, on both selected
platforms, and [docs/vulkan_compatibility_record.md](vulkan_compatibility_record.md)
is its record. The rows below now state what was proved rather than what was
proposed; where a row is still a direction rather than an observation, it says
so. Q-9/Q-10 remain resolved policy decisions. Keep build-tool versions distinct
from the runtime capabilities required from a device; installing a newer SDK
does not itself raise that minimum.

| Choice | Proved profile, or the accepted direction where none was proved | Next reasonable alternative |
|---|---|---|
| Haskell binding/toolchain | **Proven and pinned by VK-1 (#157) on 2026-09-18**: GHC 9.14.1, cabal-install 3.18.1.0, `index-state: 2026-09-18T00:00:00Z`, `vulkan-3.27` with `vulkan-utils-0.5.11.0` at `+safe-foreign-calls -darwin-lib-dirs`. GHC 9.14.2-rc2 was the newer D-13 candidate and was excluded by a documented compatibility blocker. See [docs/toolchain.md](toolchain.md). | The candidate row this replaced recorded GHC 9.14.2-rc2 as the recommended candidate on 2026-09-17, subject to proof before pinning; that proof is what excluded it. |
| Runtime baseline | **Proved by VK-2 (#158) on 2026-09-18**: Vulkan 1.3 with `dynamicRendering` and `synchronization2` supported, requested, and accepted on both platforms — MoltenVK 1.4.0 reports device API 1.3.323 on an Apple M3 Max, and pinned Mesa 25.2.8 Lavapipe reports 1.4.318 in the Linux proof container. D-12's 1.3 minimum stands as a requirement downstream slices may assume. | A 1.4-only minimum was considered and not selected. A later 1.2 profile needs its own supported features and tests, not another copied backend. |
| Presentation retirement | **Proved by VK-2 (#158)**: `VK_EXT_swapchain_maintenance1` with `VK_KHR_swapchain`, `VK_EXT_surface_maintenance1`, and `VK_KHR_get_surface_capabilities2`, and its `swapchainMaintenance1` feature enabled. Present fences signal, and both abandonment paths return an image through `vkReleaseSwapchainImagesEXT` with no swapchain rebuild. The KHR spelling remains an **unproved alias** on both platforms: neither MoltenVK 1.4.0 nor Mesa 25.2.8 Lavapipe resolves `vkReleaseSwapchainImagesKHR`, and `vulkan-3.27` hides the difference by exposing the KHR types as aliases and trying the EXT name first. | Requiring KHR alone could force a newer Mesa build without strengthening this arc's contract. Proving the KHR alias needs a driver that offers it and is its own piece of evidence. |
| Loader and drivers | **Proved by VK-2 (#158)**: the standard loader is shared by construction — GLFW is handed the Haskell binding's own `vkGetInstanceProcAddr` before `glfwInit`, and both sides then resolve identical addresses in one image. Locally that is LunarG 1.3.296 loading **Homebrew MoltenVK 1.4.0**, named by an absolute `VK_DRIVER_FILES` manifest, because the SDK's own default ICD declares API 1.2 and cannot meet D-12. Linux is D-10's pinned Lavapipe (Mesa 25.2.8, `lvp_icd.json`), selected the same way from among the eight ICD manifests that container installs. Device-level entry points resolve into the enabled validation layer's image, which is the layer chain working as asked. | Direct MoltenVK loading was considered and not selected because it bypasses the ordinary loader/layer path and needs different integration. |
| Shader build | D-11 selects Template Haskell GLSL-to-SPIR-V compilation using pinned glslang, with an explicit target environment. | A different compiler behind the same TH interface would require a reason to change the selected glslang workflow; a separate manual pipeline is not selected. |
| Provisioning | Accepted direction, not yet delivered. VK-2 proved the recipe in a throwaway container (`tools/vulkan-proof/Dockerfile.linux-proof`) and a project-local macOS selection (`tools/vulkan-proof/environment.pin`); the published CI image still carries no Vulkan input and the native manifest still describes GLFW alone. Promoting either is VK-4. | System packages for local exploration, but still pin the CI environment and reject incompatible capabilities explicitly. |

Read-only environment audit on 2026-09-17:

- `/usr/local/lib/libvulkan.dylib` and `libvulkan.1.dylib` resolve to the
  LunarG 1.3.296 loader. Its conventional `/usr/local/share/vulkan/icd.d/`
  manifest selects `/usr/local/lib/libMoltenVK.dylib`, declares API 1.2.0,
  and that binary contains the MoltenVK 1.2.11 version. The corresponding
  validation-layer manifest declares API 1.3.296.
- Homebrew's MoltenVK 1.4.0 is a separate installation under `/opt/homebrew`;
  its manifest is `/opt/homebrew/Cellar/molten-vk/1.4.0/etc/vulkan/icd.d/MoltenVK_icd.json`.
  This session has no `VK_DRIVER_FILES` or `VK_ICD_FILENAMES` override, and
  no Homebrew `libvulkan.1.dylib` was installed at its ordinary library path.
- GHC 9.14.1 is installed locally; the proposed RC is an available candidate,
  not an already installed toolchain. Synarchy's recorded build plan still uses
  GHC 9.12.2 / `vulkan-3.26.6`; its shader workflow is precedent, not evidence
  that Hetoimasia's 1.3 profile is already running.

Those were static configuration observations, not a Vulkan launch or driver
query, and VK-2 has now superseded them with one. It confirmed the shape of the
problem — the default SDK path does advertise a profile below D-12 — and
resolved it the way this paragraph proposed: an absolute `VK_DRIVER_FILES`
manifest naming Homebrew's MoltenVK 1.4.0, controlled layer discovery, and
conflicting discovery overrides cleared in the child environment, with the
actually loaded identities recorded. Nothing was installed, no shell profile was
edited, and Synarchy's installation is untouched. See
[the loader's explicit driver selection](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md#overriding-the-default-driver-discovery)
and [the compatibility record](vulkan_compatibility_record.md).

[MoltenVK 1.4.0's release](https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.0)
supports Vulkan 1.4; its tagged runtime guide lists dynamic rendering,
synchronization2 and EXT swapchain maintenance. That made the proposed 1.3
profile plausible; VK-2 verified it on this machine, and also found that the EXT
maintenance variant is the only one MoltenVK offers. The
[Vulkan version guide](https://docs.vulkan.org/guide/latest/versions.html)
explains the promoted 1.3 APIs and separate instance/device version checks.
The proof had to build the selected binding and query and enable the exact
capabilities on both selected platforms before any downstream issue assumed
them; it did.

Availability evidence checked on 2026-09-17: [GHC 9.14.1](https://www.haskell.org/ghc/download_ghc_9_14_1.html)
was the latest stable compiler listed by the official site/GHCup metadata;
9.14.2-rc2 is a prerelease in the official download directory. The
[Cabal latest directory](https://downloads.haskell.org/~cabal/cabal-install-latest/)
names 3.18.1.0. The [vulkan 3.27 changelog](https://hackage-content.haskell.org/package/vulkan-3.27/changelog)
adds Vulkan 1.4 bindings; cached `vulkan-utils-0.5.11.0` source depends on
`vulkan ==3.27.*` and retains the glslang TH interface. These are availability
and source checks, not a successful Hetoimasia build.

The current project constrains `base <4.22`; GHC 9.14.1 supplies base 4.22.
Add each new local package to `cabal.project.common`'s package-specific warning
policy in the PR that introduces it, preserving the existing `-Werror` policy
without imposing it on third-party dependencies. Keep native Vulkan/interop
packages out of `cabal.project.cpu`.
A toolchain refresh therefore needs deliberate bounds/API verification,
especially exception context, cancellation, STM and TH behavior, plus the CI
image/descriptor/workflow pins and coherent dependency index. Compiler-coupled
packages such as base and ghc-prim follow the compiler; do not upgrade them
independently. Prefer newest compatible dependencies including RCs under D-13, then pin the tested
resolution rather than allowing every build to float. Keep the old compiler
available for Synarchy and concurrent work.

### P-10. Test the decisions and the native boundary at different levels

Use pure planning/state tests for capabilities, queue selection, resize, frame
transitions and retirement. Add small injected operation interfaces where they
prove effects that pure tests cannot: partial acquisition, failed submission,
callback containment and disposal ordering. Do not build a second implementation
of hundreds of Vulkan calls for tests, or rely on real-device success to prove
rare failure/cancellation paths.

Real integration groups exercise the selected Vulkan implementation with
validation and image/lifecycle assertions. D-21 settles required-when-affected
native checks, their execution budget and the local macOS/remote Linux split;
the verification strategy specifies evidence and applicability. Lengthy stress,
performance and extra-hardware probes remain optional. Local disruptive macOS
evidence needs the human's explicit approval each session.
Use the package-owned suite layout already delivered by #129/#130. Backend
contracts belong beside the backend; root tests own application composition,
and tool tests own provisioning/selection. Do not move them into one root suite.

External-client compilation tests prove important public opacity boundaries;
they are not required for every helper. Contract docs should describe ownership,
failure states and usage once, with implementation detail beside its owner.
Neither a test/code line ratio nor component count alone establishes waste.

### P-11. Contain validation callbacks and measure before RTS tuning

The synchronous logger is behaving as designed. `newHandleSinkWith` can disable
per-entry flush, but writes can still block; buffering that handle alone does
not make the render path nonblocking. Avoid changing the foundation logger's
semantics to accommodate a future consumer.

Before enabling validation, provide component-owned bounded diagnostic capture
using P-9's callback-safe binding configuration.
The native callback copies capped data into owned storage, contains every
exception, and never formats to a user sink, waits for queue space or calls back
into Vulkan. Preserve a latched error/overflow indication independently of
successful logging. Saturation is visible through counts/truncation and cannot
be presented by an integration test as complete, clean validation evidence.
D-20 requires error-severity reports to stop ordinary graphics work at safe
owner boundaries; warnings remain diagnostics. Inspect the error latch during
initialization, frame operations and teardown independently of the log worker.
[The Vulkan callback contract](https://docs.vulkan.org/refpages/latest/refpages/source/PFN_vkDebugUtilsMessengerCallbackEXT.html)
forbids Vulkan calls from the callback.

Report outside the callback and graphics critical path through D-19's bounded
capture and backend-owned diagnostic worker. Own it in a separate foundation
`withWorkerGroup` inside logger/capture ownership, with protected backend
construction, use and teardown inside that group's body. It is not registered
with application supervision and performs no GPU retirement. Keep it alive
through the last possible callback, close/drain its inbox explicitly, inspect
its terminal report, then end the group. Do not rely on the default group drain
to flush accepted diagnostics after an exceptional exit.

Keep callback funptrs, user data and capture state alive for every registering
native lifetime. In particular, callbacks registered through instance-create
`pNext` can occur during instance destruction after the explicit debug messenger
has been destroyed. Ending that messenger alone is not callback quiescence.
Finish the last callback-producing destruction, drain or account for captured
diagnostics, join the consumer, then release callback storage and its logger. Sink failure cannot replace the primary Vulkan
failure or authorize unsafe GPU retirement. This is a Vulkan diagnostic adapter,
not approval of an engine-wide asynchronous logger rewrite.

Initial configurable capture limits are 1,024 queued records and 4 KiB total
copied text per record, with at most 16 object identifiers. Validate positive,
finite limits at construction. Native strings, arrays and labels are bounded
during copying; do not first decode an unbounded string and truncate afterward.
Callback pointers never escape into deferred log work. Classify severity and
latch errors before attempting detail admission. Track dropped, truncated and
capture-failed records independently with saturating counters; none can erase
an error or yield a clean validation verdict. Callback exceptions are contained
at the ABI boundary and latch capture failure; return the API's normal
non-aborting callback result.

A failing diagnostic sink is reported through an independent terminal status,
not by recursively logging to itself. Preserve any earlier graphics failure.
A permanently blocked sink can prevent protected worker shutdown; retain its
borrowed storage/logger and use the existing external-termination escape rather
than detaching it. A separate worker prevents ordinary sink delays from stalling
frames; it does not promise a bounded arbitrary user callback.

Record an optional reproducible baseline before optimizing: idle CPU use,
allocations and service latency at increasing window/port counts, deadline
lateness under command bursts, and later frame-time distributions/GC pauses.
Existing resource allocation-cost tests are useful but are not a frame baseline.
Record hardware, revision, native/toolchain identity and RTS flags. Choose
capabilities, nursery size and GC mode from measured representative workloads;
do not guess permanent `-N`, `-A` or nonmoving-GC defaults now. Performance probes
belong outside correctness CI and must not turn timing noise into Hspec failures.

### P-12. Make waits cooperative without promising driver preemption

Prefer finite fence/timeline/acquire timeouts, with explicit Pending/Timeout,
stop checks and owner progress between attempts. Normal owner-loop retirement
uses nonblocking progress opportunities so one closing window does not stall
another. Stop ends new admission; it does not end outstanding GPU use. Protected
shutdown may still retain dependencies while completion cannot be established.

Audit each actual API: queue/device idle have no timeout parameter and are not
the normal frame pacing or blanket retirement mechanism. Some driver calls can
block despite having no explicit wait in their name. Neither a Haskell timeout,
async exception nor safe FFI can promise to interrupt arbitrary foreign code.
Keep GPU waits out of foundation's uninterruptible release callbacks and specify
the behavior of native destroy calls under the chosen backend policy.

The review's claim that device loss necessarily leaves a Vulkan wait stuck is
too strong: [Vulkan requires those waits to return in finite time after device loss](https://docs.vulkan.org/spec/latest/chapters/devsandqueues.html#devsandqueues-lost-device).
A defective driver can violate that guarantee. A caller-selected finite timeout
is also not a hard wall-clock bound. Preserve the accepted retain-and-wait
policy, report a stalled condition without flooding logs, and document external
process termination as the operator escape. Hard in-process shutdown guarantees
or a separately killable renderer process would be a new design, not an implied
change to worker drain. Presentation still needs its own Q-2 completion proof;
queue/device idle alone does not supply it.

### P-13. Permit other backends without duplicating Vulkan by version

The owner asked about Vulkan 1.2/1.3/1.4 and eventual OpenGL on 2026-09-17;
D-12 now accepts a 1.3 minimum and future backend extensibility. Use one Vulkan
implementation with negotiated feature/limit profiles,
selected at construction and validated against the physical device. Keep shared
resource/retirement logic; resolve core-versus-extension entry points at setup.
Only advertise a profile after its code paths and shader target have evidence.
Running a lower API profile on a newer driver is useful but does not prove all
older hardware support. No automatic fallback may weaken D-9.

OpenGL is a separate backend with different context, shader, synchronization
and presentation ownership. Keep concrete Vulkan imports below backend-specific
renderer adapters; game/Lua services consume narrow rendering contracts. Expose
capabilities rather than promising identical features everywhere. Native handles
belong to one backend/device generation and cannot cross into another backend.
Use the first concrete renderer to shape a small interface; a complete universal
graphics API, OpenGL implementation and runtime backend switching are not added
to this first arc by this proposal.

Current GLFW windows use NoAPI. OpenGL would require a deliberate context-creation
and context-lifetime extension to that component, not just a different drawing
module on the same native window. Choose the backend before creating its native
targets. Apple's native OpenGL interface is deprecated; preserving a later
backend option is reasonable, but does not establish OpenGL as the preferred
macOS compatibility strategy. See the [GLFW window guide](https://www.glfw.org/docs/3.4/window_guide.html)
and [Apple's OpenGL profile documentation](https://developer.apple.com/documentation/appkit/nsopenglprofileversion4_1core).

### P-14. Isolate recognized target failures without hiding session failures

D-22 accepts application-designated required/optional targets and the failure
scope when safe recovery is exhausted; D-24 accepts bounded surface recovery.
P-14/P-15 develop those policies and new-target admission; Q-2 gates the
operation-specific native proof. Importance never weakens ownership/completion
requirements. Do not implicitly make the
first-created window required or the shared device its child.

| Situation | Proposed disposition |
|---|---|
| A new target cannot present through the shared device's enabled capabilities and existing queues | Reject that attachment with a structured reason and safely roll back partial construction. Keep existing targets; do not create or migrate to a second device. The application decides whether the rejected request prevents startup. |
| A frame is temporarily unavailable or its target is suspended | Report readiness/demand state and service other targets; no error log or busy retry for ordinary backpressure. |
| A recognized resize/presentation change needs recovery | Rebuild only the affected target within the agreed finite retry/resource limits, retaining all old-generation obligations. |
| Safe target recovery is exhausted | Mark an optional target unavailable, notify the application and retire its graphics safely while other targets continue. Failure of a required target fails the graphics session through the existing runtime policy. |
| Device loss, validation error, unknown shared-state safety, or an unclassified exception | Do not downgrade it to an optional-window warning. D-17/D-20 and the runtime failure contract govern the shared session. |

Target unavailability is distinct from native-window destruction. The
application may retain the window or request its close; graphics retains its
attachment until safe retirement is established. A cleanup failure is never
permission to acknowledge retirement or to proceed as though rollback succeeded.

Stopping the whole graphics session whenever any target cannot recover was not
selected (D-22). Isolation does not make arbitrary driver calls nonblocking or
promise progress when shared safety is unknown.

The concrete frame/failure tables must classify effects by operation as well as
return code. In particular, an out-of-date or lost-surface result from
`vkQueuePresentKHR` can still leave its queue operations enqueued; treating it
like an unsuccessful acquisition would lose synchronization obligations. See
the [presentation operation contract](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueuePresentKHR.html).
P-2/P-15 specify surface replacement, frame abandonment and allocation recovery;
VK-2 must prove their native completion/rollback prerequisites.

#### Proposed operation-specific outcome table

| Operation/outcome | Ownership and recovery response |
|---|---|
| Acquire returns not-ready/timeout | No image was acquired; defer through TIME scheduling without warning or busy retry. |
| Acquire returns suboptimal | Preserve the acquired image and synchronization; coalesce a replacement request. Finish or safely abandon this frame. |
| Acquire returns out-of-date | No new acquisition obligation; request target-local replacement under D-18. Older obligations remain. |
| Present returns suboptimal, out-of-date or surface-lost | Preserve the actual enqueued presentation/wait operations and per-target results. Request the appropriate target recovery without resetting its synchronization prematurely. |
| Submit returns a specified out-of-memory result without effects | Do not mark a submission pending. The prior acquisition/recording stays owned; retry only under D-25, otherwise retire it safely. A reset submission fence is not completion evidence. |
| Present returns a specified out-of-memory result without enqueueing | Preserve prior rendering and the still-owned image/synchronization. Do not wait on a presentation fence that this call did not enqueue. |
| Surface is lost | D-24's bounded automatic recovery: stop acquiring, establish safe retirement of old dependents, retain the native-window attachment and recheck the shared device's support before replacement. Exhaustion follows D-22. |
| Consumer explicitly skips an unsubmitted frame | D-23's safe abandonment under P-2; no automatic consumer replay. An escaping exception instead follows the runtime/session failure contract. |
| Device lost, validation error, unknown effect or failed cleanup | D-17/D-20 and retained ownership apply. Optional target classification never supplies missing safety evidence. |

The no-effect guarantees above are operation-specific, documented for
[submission](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueueSubmit2.html)
and [presentation](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueuePresentKHR.html);
do not generalize them to all allocation errors or partial construction.
D-25 settles the resource-pressure response; P-15 supplies finite recovery
accounting. Recovery budgets bound attempts, never the lifetime of resources
whose safe disposal is unknown.

D-24 selects bounded automatic surface/swapchain replacement on the same live
window. Its native proof must include loss during acquisition and presentation,
partial replacement, repeated loss, and close arriving during retirement or
replacement. Publish a replacement only if the target remains admitted; a close
observed after native construction requires owned retirement of that result,
not publication back into active rendering.

D-25 selects one bounded reclamation pass and at most one
retry after actual reclamation progress, with no automatic visual-quality
changes. Reclaim only backend-owned resources already eligible for disposal;
never evict live generations, steal another target's reservations, or treat an
incomplete GPU use as finished. Ordinary configured-capacity exhaustion remains
backpressure rather than an allocation error. Keep progress integrated with the
owner scheduler rather than blocking all targets for global idle.

Retry only the failed native operation where its specified outcome had no
effects, or a resource-construction attempt whose rollback is proven complete.
Do not rerun consumer callbacks, replay submitted work or retry failed cleanup.
No reclamation progress or another failure ends this automatic attempt. Report
the actual failing operation and resource scope: a proven isolated target
failure follows D-22, while shared-session failure or unknown safety follows the
session contract. Lowering resolution, frame capacity or render quality requires
a separate explicit application policy. The accepted policy still needs
per-operation evidence of safe retry and bounded reclamation in Q-2's proof.

The selected [presentation fence](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainPresentFenceInfoKHR.html)
establishes the extension's resource-retirement guarantees; it need not mean
that the image has finished appearing on screen. Keep visual timing claims
separate from safe object reuse/destruction.

### P-15. Bound admission, progress and recovery explicitly

These are proposed engineering defaults for the first implementation, not new
owner decisions about game behavior. Configuration is validated before native
effects; reject zero/negative/overflowing limits and checked-arithmetic failures.
Tests exercise small limits. An implementation may change a default with a
documented reason and the same contracts; it may not silently remove a bound.

| Budget | Initial policy |
|---|---|
| Active or retiring target records | Configurable, default 16; retiring targets still consume admission capacity. |
| Frame slots | D-16's default 2 per target, supporting 1; a session-wide configured cap bounds their aggregate. Do not equate this with swapchain image count. |
| Live swapchain generations | Default 2 per target, counting active, constructing and retired generations together. At capacity, retire first and coalesce the newest resize. |
| Presentation records | Default per-target capacity is the checked sum of its configured swapchain-image tracking limit and frame-slot count: at least the actual admitted image count plus frame slots. Also charge it to the session object budget. Count reserved, unpresented, pending and retired-generation records; reserve before acquire. |
| Backend allocation accounting | Finite configured byte and object limits, with explicit values in application/test configuration. Count recorded-but-unsubmitted and retired allocations too; reserve before construction. |
| Progress work | At most 32 completion/disposal actions per owner turn by default, round-robin across targets. Start with a 5 ms pending-work poll interval; with no render demand and no progress, back off up to the configured idle-progress bound (initially 100 ms). |
| Native waits | Nonblocking acquire/poll during ordinary turns; any explicit protected-drain wait uses a finite timeout, initially at most 10 ms, followed by stop/status/progress checks. Timeouts are scheduling outcomes, not completion or safe disposal. |
| Surface/repeated stable-target recovery | At most 3 construction attempts per episode, with retry delays initially 100 ms and 500 ms. No wait occurs inside a foundation release. |
| Allocation recovery | One bounded scan of already eligible disposals, followed by at most one native retry if that scan actually reclaimed resources, as in D-25. |

A complete configuration must state a finite aggregate frame cap, owned-byte
limit, object limit, swapchain-image tracking limit and maximum records examined
per reclaim pass; no unbounded sentinel is permitted. Proposed starter values
are 32 aggregate frame slots, 256 MiB of accounted backend allocations, 4,096
object records, 16 image records per swapchain and 64 examined records per
reclaim pass. With 16 as the image limit and 2 frame slots, the default target
presentation pool therefore has capacity 18. Derive that finite default from
configuration with overflow checking; do not freeze a smaller constant when
frame capacity changes. A new generation consumes the existing target pool,
including any still-pending records from retired generations; it does not
receive an additional unlimited pool. These are configuration values, not driver
limits; the small test fixture deliberately chooses smaller budgets. Byte accounting covers
known backend allocations, not an unverifiable promise to cap all memory a WSI
driver allocates internally. Surface capabilities determine image counts; reserve
and check returned counts before building dependent arrays. If the driver
exceeds the configured tracking limit, reject and safely retire that candidate.
Backpressure must not consume the cleanup records already reserved for admitted
work, and the total memory occupied by retired work never vanishes from metrics.

Polling backoff uses absolute monotonic deadlines: 5, 10, 20, 40, 80, then
100 ms under unchanged no-demand/no-progress conditions, with a configurable
finite cap. New render demand, a new native obligation, observed completion or
a close transition schedules an immediate progress opportunity and resets the
backoff; an unrelated event that changes none of those must not reset it.
Earlier application/TIME deadlines and checkpoint limits still bound the owner
wait, without forcing a native fence query on every such wake. Unsignaled
presentation obligations can persist during occlusion; the policy must remain
cheap without treating elapsed time as completion. Scripted clocks prove the
backoff and prompt wake behavior; there is no universal assumption that macOS
occlusion necessarily delays a particular maintenance fence.

Track each recovery episode on the target, surviving owner turns and nested
helpers. A new retry helper, changed framebuffer observation or allocation
sub-retry cannot replenish it. Successful recovery resets the failure budget
only after a completed normal presentation-retirement cycle and one second of
healthy monotonic progress without another recovery failure. Application-level
explicit reattachment can begin a new episode after safe retirement; do not
silently loop through detach/reattach internally.

Ordinary resize invalidation is not a failed construction: coalesce observations
and wait until the latest geometry has been quiet for 16 ms before rebuilding,
while continuing safe work on other targets. Repeated out-of-date results with
unchanged observed geometry do consume the recovery budget. Continually changing
geometry can remain pending without warning or growing retirement storage.
Zero-area suspension creates no failed attempt. Close takes precedence over
retry admission and over publishing a completed replacement.

An allocation attempt has its own stable identity and a spent-retry bit. Its
reclamation pass examines no more than the configured record budget, does not
wait for unfinished work, and counts progress only after successful disposal.
A failure after `oldSwapchain` retirement cannot reuse that retired handle as
a fresh non-retired `oldSwapchain`: continue from the actual native state and
prove a legal fresh-construction path. Do not claim D-25 permits replaying the
previous creation arguments after any partially effective call.

The first presentation profile is deliberately small: single-sample SDR,
color-attachment rendering, FIFO presentation, no depth/MSAA/HDR in the triangle
consumer, and an advertised compatible 8-bit RGBA/BGRA sRGB surface format.
Use physical framebuffer dimensions and the queried extent/image-count limits;
report unsupported formats rather than assuming a preferred format exists.
Other formats/modes can be later capabilities without changing ownership.
Native verification additionally requires a supported transfer-source capture
path in its selected test environments; normal target support must not silently
require that optional surface usage. Q-2 proves the chosen capture profile.

## Open questions

### Q-1. Accept P-1's component ownership and first thread model?

Resolved by D-5. Separate components and the first main-thread loop are accepted.
Frame work can delay event handling; a future render worker requires its own
handoff and lifetime contract. Exact package names follow the agreed boundaries.

### Q-2. What compatibility and completion contract should the backend require?

Policy resolved by D-8/D-9/D-11–D-18/D-22–D-26. P-1/P-2/P-7/P-8/P-12/P-14/P-15
specify the ownership, retry and admission contracts. **Deliberately open
technical proof gate: VK-2**, after VK-1 qualifies the compiler/dependency set.
It must record an exact profile for both selected platforms:

- Binding version/flags, ABI and callback reentry; one shared standard loader
  and its actual driver/layer discovery, without ambient MoltenVK/loader mixing.
- Vulkan 1.3 features (dynamic rendering and synchronization2), required instance
  surface/portability extensions, portability subset when advertised, queue
  support, formats/usages, and explicitly enabled extension feature chains.
- The selected EXT or KHR maintenance variant, its dependency extensions,
  resolved entry points and evidence for present fences and unused-image release.
  A version string or advertised extension alone is insufficient.
- P-2's acquisition cleanup submission, safe unpresented-image return, bounded
  semaphore-pool recycling and independent submission/presentation retirement. Normal
  completion proof must be distinguished from device-loss destruction rules.
- A cited operation/result matrix for actual effects, no-effect errors and
  safe retry/destruction, including the `oldSwapchain` failure case.
  Rare errors need model/seam evidence later, not intentional real device damage.
- A capture path supported by the selected native test environments and
  shader target compatibility. Record unsupported hardware assumptions explicitly.

VK-2 uses a narrow reproducible proof harness, not a provisional public backend.
It may establish legal exceptional paths through specification/source evidence
plus later injected checks; do not claim to have induced a real device loss.
Its PR retains the recipe, observations and conclusion, including explicit
unknowns. No native downstream slice becomes actionable on a failed or incomplete
proof. Report a concrete compatibility blocker to the owner; do not silently
weaken fences, change the runtime minimum, choose direct MoltenVK, or fall back
to device-idle teardown. VK-3's pure model may proceed independently.

Device loss remains terminal, and a UI sharing that device cannot be promised
to keep rendering. The proof must state which device-loss rules authorize
destruction; it cannot mark unfinished work as a successfully signaled fence.
Unresolved safety retains ownership under P-12 rather than releasing parents.

**Answered on 2026-09-18 by #158**, which passed on both platforms:
[docs/vulkan_compatibility_record.md](vulkan_compatibility_record.md) records
the profile, the loader identity evidence, the completion and abandonment
results, the cited operation matrix, and the unknowns it deliberately leaves —
the KHR maintenance alias, every rare result, and any real device loss. The
compatibility profile table above now states what was proved. This gate is
cleared for downstream slices only once that pull request merges; the deferred
entries in the processing status say so in their own words.

### Q-3. Accept P-2's window scope, and where will Linux graphics execute?

Scope/policy resolved by D-3/D-7/D-10/D-21/D-22 and P-14/P-15: multiple compatible
targets on one shared device; unsupported new-target attachment is rejected
without replacing the device. Remote Linux uses pinned Lavapipe and isolated
X11; macOS verification is local MoltenVK/Cocoa. The existing GLFW scope stays.

**Deliberately open execution-evidence gate: VK-8, completed by VK-17.** VK-4
supplies the pinned environment; VK-8 owns package-native fixtures, runner
selection and pre-PR local evidence. Required checks have nonempty platform
selection and measured total native execution under 30 seconds, including their
test-owned display/fixture and teardown. VK-17 must demonstrate the complete
two-window image/lifecycle profile within that limit, not merely reuse VK-8's
smaller startup measurement. Missing required capability/environment fails
clearly; no silent skip, green zero-example selection, or transfer of Linux
evidence to macOS. A failure to meet the budget or profile returns to the owner
for a scope/test split; it does not silently make required coverage optional.

### Q-4. Establish P-3's small queue foundation before GLFW/Vulkan integration?

Resolved and implemented by messaging epic #73, issues #74–#79 and PRs #80–#85.
Use the existing bounded channels, snapshots, and inbox contracts in
[messaging.md](messaging.md). No further queue prerequisite or generic event bus
is authorized by this historical proposal.

### Q-5. What is the runtime composition and initialization contract?

Resolved and implemented by the [runtime foundation design](runtime_foundation_design.md),
including D-13 through D-18 and P-10 through P-13. Epic #52 and children #53–#60,
plus repairs #69/#70, delivered errors, recovery, construction, worker ownership,
logging lifetime, supervision, and application integration. GLFW subsequently
added the pre-drain quiescence hook. Use those contracts; do not reopen them.
The remaining gates are the scheduling and dependent-lifetime implementations
and the GPU lifecycle/platform choices here. Follow-up #123 is satisfied.

### Q-6. What timing, suspension, and wake policy should the first consumer use?

Delegated to [runtime_scheduling_design.md](runtime_scheduling_design.md).
Owner accepted event/deadline/fixed-step support with configurable limits and
per-window render suspension independent of simulation. That document's D-5
records its completed final review and readiness; epic #131 owns delivery.
No fixed 0.25-second cap
or simulation rate has been silently inherited from Synarchy.

### Q-7. What scoped attachment API connects graphics owners to windows?

Delegated to [window_graphics_lifetime_design.md](window_graphics_lifetime_design.md).
The owner accepted one exclusive graphics owner per window. That document's
D-5 records review of its protected IO host lifetime and managed application
composition; epic #140 owns delivery. The attachment API itself is settled
there. Vulkan-specific surface interop remains open under P-7/Q-2, and no
attachment acknowledgement may substitute for real GPU-completion proof.

### Q-8. What diagnostic and measurement policy should the backend adopt?

Resolved by D-19/D-20, with concrete capture limits and callback/worker lifetimes
in P-9/P-11. VK-6 owns that implementation and VK-8 the final-after-teardown test
verdict. Error, dropped, truncated and capture-failed evidence cannot be erased
by a successful sink write or early test result.

Performance baselines remain optional P-11 work. Do not reopen the completed
logger or invent permanent RTS tuning before measurements. Q-2 still gates
the native callback/FFI proof; it is not an unresolved diagnostic policy choice.

### Q-9. Which Vulkan profiles are delivered first, and how far does backend abstraction go?

Resolved by D-12: one extensible Vulkan backend with a 1.3 minimum, newer
capabilities explicitly enabled, and other backends left possible for later
implementation. A 1.4-only floor was not selected. Future 1.2 support needs
tested feature, dispatch and shader paths. The concrete small consumer API
remains P-1's design task; scope agreement does not claim it is implemented.

### Q-10. Does newest toolchain mean stable releases or prereleases too?

Resolved by D-13: newest compatible versions, including release candidates,
pinned after verification on both platforms. Stable-only was not selected.
Recheck availability when implementing the upgrade. Do not change the parallel
Lua document or approved issues silently; coordinate their proof baseline.

### Q-11. How many frames may each window have in flight initially?

Resolved by D-16: configurable per-window capacity with two as the default and
one supported. A one-slot default was considered but not selected because two
permits preparation/execution overlap. This does not change the swapchain image
count or presentation-retirement rules. Exact supported configuration limits
and readiness outcomes remain part of the concrete frame API and its tests.

### Q-12. May replacement swapchain generations overlap while older work retires?

Resolved by D-18: bounded overlap for the affected target, coalesced resize
requests and per-target backpressure when the next replacement cannot fit its
resource budget. Always draining before replacement was not selected. Preserve
other owner work and account for aggregate device limits under P-8.

This is not transactional rollback to an old active swapchain. Vulkan retires
the `oldSwapchain` supplied to creation even if creation fails; no new images
may be acquired from that retired chain. Already acquired/submitted work still
needs its specified completion and disposal. Represent replacement failure
explicitly and choose bounded recovery or target failure under Q-2, rather than
resuming acquisitions on an unusable old generation. See the
[swapchain creation contract](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainCreateInfoKHR.html).

### Q-13. How should recording retain the renderer's resource dependencies?

Resolved by D-26: managed handles and a small Vulkan-specific recording
interface automatically retain the exact resource generations they use.
Trusted raw Vulkan recording with a caller-maintained dependency list was not
selected because completeness could not be enforced. P-1 develops the API
under D-15's central ownership and flexible scheduling; concrete signatures and
retention transitions remain engineering work, not an undecided ownership model.

## Verification strategy

Use Hspec for pure capability/queue/extent decisions, state transitions, and
effectful ownership tests. Preserve independently buildable CPU components and
headless suites. The Cabal/project layout and catalog must explicitly account
for graphics dependencies without making the console depend on them.

Use separate execution groups for graphics requirements. Describe the actual
runner, toolchain, consumed shaders and fixtures, and required environment. Initial group names
are `test.vulkan` (portable contracts) and `test.vulkan-native` (display/native),
both non-optional, affected/requested groups outside the unconditional floor.
VK-3 registers the portable group when its first contracts land; VK-8 adds the
native group and shared fixture, retaining the portable registration. Earlier
native evidence uses the explicit VK-2 proof route described in the delivery plan.
Build-input changes can still affect existing mandatory build groups. Route the
native group to the existing display runner class; do not run it on a CPU-only
worker or add a duplicate runner-class mechanism. Vulkan tests remain owned by
the backend package rather than extending the root console suite.
Keep evidence tied to the tested inputs and platform under the existing
[validation contract](validation.md); local macOS evidence cannot substitute
for Linux evidence, nor can Linux success establish macOS verification. Reuse
current selection and freshness rules.

Under D-21, apply this matrix to the groups selected for the change:

| Test scope | Local macOS, before PR | Remote Linux CI |
|---|---|---|
| Required portable Hspec contracts | Run | Run |
| Required native Vulkan integration | MoltenVK and Cocoa; under 30 seconds | Pinned Lavapipe and isolated X11; under 30 seconds |
| Required platform-specific examples | macOS examples only | Linux examples only |
| Optional Hspec checks and Python probes | Only when requested and applicable | Only when requested and applicable |

The native fixture/CI delivery slice must supply the following, rather than
assuming Linux's green check enforces a local requirement:

- A solver pre-PR command and retained macOS evidence identifying selected
  groups, outcomes, elapsed native time, tested inputs and actual toolchain/native
  environment. Review checks that evidence; changed consumed inputs require
  affected checks again before merge. Docs-only changes may reuse compatible
  evidence. Use existing receipts where applicable; local evidence must never
  claim the Linux image identity or satisfy a Linux receipt requirement.
- Explicit platform applicability and a visible non-empty example selection.
  The current catalog has runner classes and the plan has an OS identity, but
  the catalog has no platform selector. Use platform-aware suite composition
  with reported coverage. Do not add an unrecognized field or count zero matched examples,
  a missing loader/device/layer/display, or an unavailable required feature as
  a passing selected native check. Wrong-platform cases are identified as
  inapplicable, not credited as having passed on this platform.
- A measured, bounded required native profile exercising two rendered windows,
  image assertions, a resize, retirement/closure of the first-created window
  while the other still renders, and final cleanup/validation evidence. Keep
  extensive permutations and long runs optional; use required headless tests
  for deterministic failure paths. Fail on validation errors or incomplete
  diagnostic capture under D-20. This budget is not a performance benchmark.
- Preserve the human's explicit per-session approval before any local test
  disrupts their desktop, even when the test is required and the solver owns
  running it. No consent means local verification remains pending, not passed.
  Isolated Linux X11 needs no desktop approval. Do not infer consent from an
  issue approval or turn the native-session opt-in into a persistent setting.

FIFO presentation is a compatibility choice, not a frame-clock assertion.
Required tests do not infer refresh cadence, vblank, frame pacing, or immediate
completion from Xvfb/Lavapipe or MoltenVK fence timing. A given virtual display
may emulate timing; query and record behavior instead of assuming all frames
complete instantly. Use injected clocks for pacing and keep native assertions
about ownership, content, progress and the bounded suite verdict.

Build/provisioning time is outside D-21's native execution budget. VK-8 must
build the selected executable in an explicit preparation stage, then time the
test-owned display/setup, execution and complete teardown as one native check.
A bare `cabal test` timeout that includes compilation is not that measurement.
Preserve the catalog's transitive component/input identity when executing the
built binary; do not evade selection or receipts through a detached script.
A watchdog expiry fails and retains evidence; it does not certify safe shutdown.

Required image assertions use the verified transfer-source capture profile on
the selected drivers, with known clear/background and triangle-interior samples
and tolerances rather than exact whole-image hashes. Verify real acquire,
submit and present alongside those pixels; a purely offscreen image cannot
claim two windowed targets. Optional manual visual evidence can supplement
this, but must not replace native completion and final validation assertions.
Ordinary runtime target compatibility remains independent of test-only readback
usage. Capture swapchains use `clipped = False`: obscured pixels can otherwise
be undefined under the
[swapchain creation contract](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainCreateInfoKHR.html).
Use mapped, non-minimized test windows without requesting focus; do not bypass
the suspension contract merely to draw into hidden test targets. Record any
noncoherent mapped-memory invalidate/flush and image-layout requirements in the
managed capture implementation.

Identity includes compiler/package flags, loader, driver, validation-layer
version and source/build identity, shader compiler, native recipe/manifest and
Linux image digest through the existing toolchain map. VK-4 pins the validation
layers as native recipe inputs on both platforms, including their manifest and
binary identity; an ambient SDK layer with the same name is not interchangeable.
Both planner and worker use coherent declared identities, and the worker
verifies its actual environment. Local macOS evidence identifies its own native
manifest; package changes invalidate affected evidence under existing rules.

TEST-2/#93 delivered the GLFW fixture; #118 repairs its repeated-cancellation
drain. Build any Vulkan fixture on the existing ownership and main-thread
dispatch lessons, with GPU-specific completion proof in this arc's own slice.
Selected compatible examples share expensive roots; example state stays private;
destructive lifecycle tests use private roots. Discovery and dry runs must not
initialize graphics. Demonstrate thread ownership independently of Hspec hook
names; introduce no second generic fixture framework.

Before hardware tests, use scripted completion and clock sources to verify:

- Closing one attached window cannot destroy it before graphics retirement;
  another window continues. Repeated/foreign acknowledgements and attachment
  attempts after close cannot bypass the guard.
- Normal return, startup/body failure, submission failure, and repeated
  cancellation all protect native windows through the graphics drain. Failed
  disposal preserves primary and cleanup evidence; no GPU wait occurs in an
  uninterruptible foundation release. Scripted device-loss handling must match
  D-17 and the eventual explicit Q-2 native teardown contract, including terminal
  wait outcomes, child-before-parent disposal and rejection of further work.
- A replaced snapshot or logically released resource cannot invalidate a still
  retained CPU generation or pending GPU use. Alternative supported schedules
  use the same accounting: shared work remains alive until its last use ends,
  and abandoning recorded work releases only its own unsubmitted obligations.
- D-26's managed recorder pins the generation actually
  used, logical release cannot invalidate a sealed batch, and stale/foreign
  capabilities fail before native effects. Exceptional recording and discarded
  batches release only their own references. Later publication of a replacement
  resource cannot silently change earlier recorded commands.
  Releasing a handle denies new uses but preserves existing batches; partial
  recording failure cannot free dependencies still reachable by command storage.
  Discarding one batch cannot release another batch's shared resource holds.
- An explicit frame skip, recording exception, and cancellation at each native
  handoff preserve the actual acquisition/submission/presentation obligations.
  Cover suboptimal acquisition, submit failure after fence reset, duplicate
  batches, delayed presentation, submitted-but-never-presented close and rejected
  presentation with enqueued waits. Keep presentation-pool records distinct from
  reused frame slots; exercise reacquisition while an older present fence is
  pending, bounded pool exhaustion and independent versus explicitly batched
  target submissions. No phantom fence wait or premature reuse.
  Optional-target exhaustion preserves healthy targets, required-target failure
  stops the session, and intentional close is not misclassified as failure.
- Lost-surface recovery retains its attachment, rechecks compatibility, and
  cannot publish a replacement after close. Repeated loss and failed partial
  replacement obey their finite budgets; failed cleanup cannot start another
  attempt or release parents. Unaffected targets retain their own resources.
  Interleaved resizes and nested allocation recovery cannot replenish a failing
  episode; ordinary moving geometry coalesces without growing generation storage.
- Native allocation failure retries at most once after actual safe reclamation,
  including across owner turns and nested recovery. No-progress and failed
  reclamation paths cannot retry; live generations and target reservations stay
  intact. Consumer callbacks and successful submissions are never replayed.
- Continuous demand with quiet queues does not select the old idle wait;
  pending deadlines account for work duration, event floods remain fair, and
  no-demand/suspended windows back off completion polls without spinning or
  pausing other windows, and new demand interrupts that backoff.
- Long interruptions obey the selected debt policy. Admission/wake races,
  wake failure, repeated cancellation, and stale ports after termination leave
  neither stranded tickets nor native calls against a dead session.

Use coordinated Hspec seams rather than timing sleeps for correctness. Native
X11/local Cocoa evidence must separately demonstrate the production wake path;
scripted tests cannot prove that a platform event wait actually wakes.

Callback checks include reentry during creation/destruction, bounded string
copying, queue saturation, detail truncation, sink failure, and final callbacks
after the explicit messenger ends. Preserve the first graphics failure and
additional cleanup/diagnostic evidence; no exception crosses the native ABI.

Real graphics checks should retain triangle pixels, validation output, observed
framebuffer dimensions, and lifecycle results for both platforms. Proposed
window cases include resize, zero area, restore to the same dimensions, close,
and failure during partial setup or submitted work. Exact capture and failure
injection procedures follow the agreed backend contract; none were run here.
Required contracts and evidence belong in each implementation PR.

## Delivery plan

The owner-approved policies D-1–D-26 are preserved. This review supplies concrete
contracts and the following proposed one-PR delivery boundaries. The owner
signed off readiness on 2026-09-17 under D-27; the document itself creates no
tracker artifacts.

VK-1 and VK-2 qualify the shared toolchain and native profile; VK-3 can progress
beside VK-2. Downstream native slices are deliberately deferred until VK-2
records a passing proof. Their dependency edges encode that gate transitively.
Q-3's execution-budget gate belongs to VK-8 and its final milestone to VK-17.
Failure of a proof returns a concrete blocker to the owner rather than silently
changing an accepted policy.

Existing TIME/LIFE issues own their prerequisites, and #123/#129/#130/#133/#135/#142
are merged. The owner selected VK-1 before Lua #146; its amended and reapproved
specification consumes the qualified toolchain and forbids a competing upgrade.
Do not recreate those issues
or let the old foundation umbrella duplicate Vulkan work. Required contracts,
compatibility results and native verification evidence stay in each code PR.
The pure model and compiler-only tests do not initialize a desktop. Surface,
submission and presentation slices must remain independently reviewable;
split an unexpectedly oversized implementation before processing it, preserving
stable IDs for already recorded slices.

**Proof infrastructure before the production fixture.** VK-2 owns a temporary,
reproducible Linux x86_64 container recipe and a manually requested Linux proof
job that builds/runs it on the hosted runner with isolated X11. Pin its base
image and native inputs, cache expensive builds, and retain recipe/evidence in
that PR. This is permitted qualification work before VK-4; it does not replace
the production image descriptor or require publishing an unproved image.
An equivalent local Linux run is useful additional evidence, not a prerequisite
that assumes this macOS machine has Docker or an x86_64 Linux VM.

VK-4 promotes the proved recipe to the normal cached image/manifest. VK-5,
VK-6 and VK-7 add focused cases to VK-2's Hspec proof harness using their actual
production operations; its explicit local command and Linux proof job retain
fresh evidence for each PR. Their native acceptance is not a claim that VK-8's
catalog group already exists. VK-8 migrates those cases into the package-native
fixture and affected group, preserves their assertions, and removes temporary
duplicate routing. Platform-aware Hspec selection and the existing display
runner suffice; no new catalog platform field is assumed.

**Parallel runway.** Independent of unfinished TIME/LIFE, the available chain
is VK-1, then VK-2 beside VK-3, followed by VK-4, then VK-6 and VK-9. These still
obey their own proof/dependency gates. VK-5 and the later integrated backend
wait for #144, whose chain includes #143 → #136 and #138 plus their prerequisites.
#133 and #135 have landed; there is no basis for estimating this barrier as “weeks”.
Progress the independent work while those owners finish.

### VK-1. Qualify and pin the shared Haskell toolchain

- **Outcome:** One tested compiler/Cabal/index/constraint set, including a binding build, available to both Lua and Vulkan work.
- **Scope:** Recheck newest candidates, adjust bounds deliberately, pin component flags and synchronize existing CI image/descriptor/workflow/compiler identity. Preserve Synarchy's installation.
- **Phase:** Qualification.
- **Depends on:** none.
- **Ordering:** critical path; must merge its qualified baseline before the amended Lua #146 is solved.
- **Relevant decisions:** D-8, D-13.
- **Acceptance signals:** Required portable tests pass with exception-context/STM/cancellation behavior intact; exact resolution and any newer-version blocker are recorded in the same PR. Record the qualification commit and coherent pins/evidence for Lua #146 to consume; that issue remains gated until this qualification merges.
- **Out of scope:** Native Vulkan completion proof or renderer APIs.
- **Open questions:** Q-2 is deliberately open for VK-2; failure to qualify the preferred toolchain requires a documented blocker before selecting an older candidate.

### VK-2. Prove the native compatibility and completion profile

- **Outcome:** A reproducible Q-2 proof for local MoltenVK and Linux Lavapipe, identifying exact ABI, loader, feature and completion assumptions.
- **Scope:** Narrow Hspec/native harness with a pinned temporary Linux container recipe and requested Linux proof job; project-local macOS loader/driver/layer selection; audit effect/rollback rules, callback-safe FFI and capture capability. Retain the compatibility matrix, commands and results.
- **Phase:** Qualification.
- **Depends on:** `VK-1`.
- **Ordering:** critical path; hard gate for native delivery.
- **Relevant decisions:** D-2, D-9–D-14, D-17, D-23–D-25.
- **Acceptance signals:** Real present-fence retirement and successful unused-image cleanup on both profiles; callback/dispatch identity verified; exceptional paths distinguished as specification or injected evidence. Explicit human approval precedes disruptive local execution.
- **Out of scope:** Production managed backend or a claim that a prototype satisfies final CI/lifecycle coverage.
- **Open questions:** Q-2 deliberately open. Stop dependent native slices and consult the owner if proof fails or needs a policy change; do not waive the gate.

### VK-3. Model GPU retention and frame ownership

- **Outcome:** Backend-private pure state and accounting for exact generations, CPU/recorded/submitted/presentation holds and bounded admission.
- **Scope:** P-1/P-2/P-8/P-15 identities, legal transitions, alias/misuse checks, reservation and actual-effect outcomes; shared resources and retirement eligibility. Keep it binding-independent; register its package-owned suite as the affected CPU group `test.vulkan` now. Add the new package to the per-package warning policy in `cabal.project.common` in this PR; later slices do the same for any additional package they introduce.
- **Phase:** Pure contracts.
- **Depends on:** `VK-1`.
- **Ordering:** parallel with VK-2.
- **Relevant decisions:** D-15–D-18, D-22–D-26.
- **Acceptance signals:** Hspec sequences prove no premature disposal, no phantom completion, no budget replenishment through nested helpers, and finite storage under stuck completions.
- **Out of scope:** A new foundation resource framework, native calls, or hundreds of fake Vulkan entry points.
- **Open questions:** None; abstract completion facts must not assume a result of Q-2.

### VK-4. Provision the pinned native Vulkan environment

- **Outcome:** Cached, reproducible native inputs locally and in the public digest-pinned Linux image.
- **Scope:** Promote the proof's loader/driver/validation-layers/glslang recipe, pkg-config and explicit child-process driver/layer discovery; extend native manifest and existing cache seed/identity behavior, keeping CPU projects independent. Pin validation-layer identity even when the host SDK supplies older layers.
- **Phase:** Native foundations.
- **Depends on:** `VK-2`.
- **Ordering:** critical path.
- **Relevant decisions:** D-3, D-10, D-11, D-13, D-14, D-21.
- **Acceptance signals:** Cold provisioning and warm reuse identify the same inputs; planner/worker identities agree; ordinary runs do not rebuild native libraries. Validation-layer versions and manifest/binary identities participate in evidence compatibility on both platforms, and a changed layer invalidates affected evidence. Published-image digest and recipe evidence land in this code PR.
- **Out of scope:** Hosted macOS CI, changes to Synarchy, or a new parallel cache/receipt system.
- **Open questions:** None once VK-2 passes.

### VK-5. Add the loader-aware GLFW surface bridge

- **Outcome:** Narrow attachment-protected interop without exposing raw window pointers or requiring Vulkan in ordinary GLFW clients.
- **Scope:** P-7's Vulkan-header interop shim and opaque session-integration capability, loader selection before init, copied extension names, verified handle ABI and checked surface construction handoff; reset persistent configuration on all exits. Keep SDK inputs out of the ordinary GLFW native component.
- **Phase:** Native foundations.
- **Depends on:** `VK-4`. External prerequisite: LIFE #144 (and its #141–#143 chain).
- **Ordering:** critical path.
- **Relevant decisions:** D-5, D-7, D-14.
- **Acceptance signals:** Scripted admission/cancellation/failure tests and focused VK-2-harness native cases prove shared-loader use and preserved SDK-free window-only behavior. Surface ownership cannot escape its registered attachment; retained evidence covers both platforms before VK-8 takes over routing.
- **Out of scope:** Device selection, swapchains or another GLFW native API mirror.
- **Open questions:** None; use VK-2's proven ABI profile.

### VK-6. Capture validation diagnostics with an independent worker

- **Outcome:** Bounded callback capture and a backend-owned logging consumer with independently observable failure state.
- **Scope:** P-9/P-11 safe-call configuration, bounded copies, error/drop/truncation latches, a separately owned foundation worker group, callback storage lifetime and final drain/join.
- **Phase:** Native foundations.
- **Depends on:** `VK-3`, `VK-4`.
- **Ordering:** parallel with VK-5.
- **Relevant decisions:** D-19–D-21.
- **Acceptance signals:** Hspec saturation, callback exception and sink-failure paths preserve the primary; focused VK-2-harness cases prove native reentry; final callbacks cannot access freed storage or be excluded from the verdict.
- **Out of scope:** Foundation logger rewrite or permanent RTS performance tuning.
- **Open questions:** None; native callback proof is a VK-2 gate.

### VK-7. Own Vulkan instance, device and targets under protected retirement

- **Outcome:** A session controller with shared device roots and independently attached surfaces whose every exit respects P-5.
- **Scope:** Capability/queue plans, portability features, initial and later surface admission, controller construction/rollback and dependency graph. Device loss stops admission immediately; no work is yet submitted.
- **Phase:** Native foundations.
- **Depends on:** `VK-3`, `VK-5`, `VK-6`. External prerequisite: LIFE #142/#143/#144.
- **Ordering:** critical path.
- **Relevant decisions:** D-7, D-9, D-14, D-15, D-17, D-22.
- **Acceptance signals:** Partial startup, close and repeated cancellation preserve child-before-parent retirement; incompatible targets are rejected without replacing the device; the first target never owns shared roots. Native cases run through VK-2's proof infrastructure until VK-8 migrates them.
- **Out of scope:** Frame submissions or prematurely acknowledging an attachment.
- **Open questions:** None after VK-2; consume settled LIFE interfaces.

### VK-8. Integrate package-native Vulkan fixtures and CI evidence

- **Outcome:** The package-native fixture and affected `test.vulkan-native` group alongside VK-3's portable group, isolated Linux execution and enforceable local pre-PR evidence.
- **Scope:** P-10/Q-3 verification contract, main-thread shared roots, private destructive fixtures, platform-aware nonempty selection, prebuild versus timed native execution and final-after-teardown diagnostics. Migrate the VK-2/VK-5–VK-7 evidence cases and replace temporary proof routing without dropping assertions.
- **Phase:** Verification infrastructure.
- **Depends on:** `VK-7`.
- **Ordering:** critical path for production native operations.
- **Relevant decisions:** D-2, D-3, D-20, D-21.
- **Acceptance signals:** Tiny initial native profile runs on both platforms under 30 seconds; selected missing environments fail; records identify real inputs and local consent. Later slices add their cases to the same bounded profile.
- **Out of scope:** Claiming initial instance/device checks prove the final two-window milestone; full coverage is VK-17.
- **Open questions:** Q-3 deliberately open until both the initial and completed profile are measured. Report infeasible budget/environment choices rather than weakening required status.

### VK-9. Make Template Haskell shaders reproducible

- **Outcome:** The preserved Synarchy-style glslang TH workflow produces pinned, embedded SPIR-V with correct rebuild identity.
- **Scope:** Wrap the string quoter and explicit target-env compile splice; provide the pinned private-prefix compiler alias, registered input/fingerprint dependencies and build environment. Track shader source/includes/interpolation, executable/version/flags and Cabal distribution closure.
- **Phase:** Rendering inputs.
- **Depends on:** `VK-4`.
- **Ordering:** parallel with VK-5–VK-8.
- **Relevant decisions:** D-11, D-12, D-13.
- **Acceptance signals:** Shader and tool-identity changes rebuild affected artifacts; a clean source distribution has all inputs; diagnostics identify the offending shader; shader compilation requires no display/device.
- **Out of scope:** Runtime shader hot reload, a manual external build workflow or a general shader language.
- **Open questions:** None once VK-2/VK-4 choose compatible inputs.

### VK-10. Manage swapchain generation construction and replacement

- **Outcome:** Bounded generation ownership with capability-driven format/extent/image planning and safe partial construction.
- **Scope:** P-15 small presentation profile, zero-area suspension, coalesced resize, generation reservations, the irreversible oldSwapchain transition and exact target identity.
- **Phase:** Rendering lifecycle.
- **Depends on:** `VK-8`.
- **Ordering:** critical path.
- **Relevant decisions:** D-7, D-16, D-18, D-22.
- **Acceptance signals:** Injected failed replacement cannot reacquire/pass a retired old handle; oversized returned image counts safely reject; newer resize survives earlier work and no target steals another's reservations.
- **Out of scope:** Surface-loss retries or ordinary consumer rendering.
- **Open questions:** None; legal native construction follows VK-2.

### VK-11. Record through retained managed resources

- **Outcome:** Minimal managed graphics resources and scoped recording with exact transitive retention for triangle and capture operations.
- **Scope:** P-1 pipelines, command storage, draws, necessary barriers and readback resources; logical release, sealed single-use batches and safe discard/reset. Keep Vulkan-specific choices visible to consumers.
- **Phase:** Rendering lifecycle.
- **Depends on:** `VK-3`, `VK-7`, `VK-9`, `VK-10`.
- **Ordering:** critical path.
- **Relevant decisions:** D-15, D-26.
- **Acceptance signals:** Foreign/stale/duplicate use fails before effects; partial recording cannot free captured resources; replacement cannot redirect earlier commands; noncoherent capture memory is handled correctly.
- **Out of scope:** Raw escape callbacks, asset streaming, bindless/device-address features, reusable command lists or an implicit render graph.
- **Open questions:** None.

### VK-12. Track acquisition, submission and safe frame abandonment

- **Outcome:** Composable acquire/submit/skip operations with protected actual-effect bookkeeping and completion-driven resource holds.
- **Scope:** Single and batched graphics submissions, finite acquire, suboptimal acquisition, cleanup submission and unused-image return, including submitted-but-unpresented close.
- **Phase:** Rendering lifecycle.
- **Depends on:** `VK-11`.
- **Ordering:** critical path.
- **Relevant decisions:** D-15–D-17, D-23, D-26.
- **Acceptance signals:** One/two-slot schedules and injected failure/cancellation prove no unsignallable fence wait, repeated batch effect or semaphore reuse while busy. Native smoke acquires, submits and safely returns images without presentation.
- **Out of scope:** Public multi-queue scheduling or retrying consumer actions.
- **Open questions:** None; unknown native safety stops admission and retains ownership, never uses an unfinished completion as success.

### VK-13. Track presentation completion and retire generations

- **Outcome:** Independent per-target presentation and complete normal retirement of all submission and presentation obligations.
- **Scope:** Bounded per-target presentation semaphore/fence pools, delayed present, enqueued-error accounting and incremental generation/window retirement. A new acquisition may use a free pool record without a redundant host wait on its image's older presentation fence.
- **Phase:** Rendering lifecycle.
- **Depends on:** `VK-12`.
- **Ordering:** critical path.
- **Relevant decisions:** D-9, D-15, D-18, D-23.
- **Acceptance signals:** The prior render fence cannot free presentation objects; real resize/close uses verified fences; skipped or never-presented images settle separately; closing the first target leaves shared roots valid. The derived default pool covers image count plus frame slots, counts old-generation records against the same cap, and rejects arithmetic overflow; explicit pool exhaustion remains bounded backpressure.
- **Out of scope:** Claiming fences measure final on-screen display time, device recreation or global idle as a substitute.
- **Open questions:** None.

### VK-14. Apply bounded target and allocation recovery

- **Outcome:** Recognized failures recover within stable budgets while unrelated healthy targets retain their resources.
- **Scope:** P-14/P-15 surface replacement on the same live window, support recheck, required/optional disposition and safe reclaim-once/retry-once behavior. Preserve actual oldSwapchain effects.
- **Phase:** Failure behavior.
- **Depends on:** `VK-13`.
- **Ordering:** critical path.
- **Relevant decisions:** D-18, D-22, D-24, D-25.
- **Acceptance signals:** Close defeats late replacement; changed geometry/nested retries cannot reset a failure episode; failed rollback forbids retry; no-progress reclamation stops; successful work is never replayed.
- **Out of scope:** Automatic device recreation, quality reduction or eviction of live data.
- **Open questions:** None; rare paths use narrow injected effects, with native rules from VK-2.

### VK-15. Complete terminal graphics failure and device-loss teardown

- **Outcome:** All-exit terminal retirement preserves the original failure and disposes only under proven normal/device-loss rules.
- **Scope:** Device loss, strict validation error, callback/sink failure, uncertain native effects, cleanup failures and repeated cancellation; direct owner drain with no event-loop dependency.
- **Phase:** Failure behavior.
- **Depends on:** `VK-13`.
- **Ordering:** parallel with VK-14 where files permit.
- **Relevant decisions:** D-17, D-19, D-20, D-22.
- **Acceptance signals:** Injected device loss rejects further rendering without waiting on phantom work or simulating successful fences; cleanup evidence cannot replace the primary; unknown safety retains parents; final callbacks affect test verdicts.
- **Out of scope:** Recovery of a lost device, forced driver preemption or intentional hardware damage in CI.
- **Open questions:** None; any gap in VK-2's destruction proof blocks the affected path rather than authorizing release.

### VK-16. Compose rendering demand and retirement with TIME and LIFE

- **Outcome:** The existing owner loop drives rendering, finite GPU progress and all-exit retirement without a second engine loop.
- **Scope:** P-5/P-6 deadline combination, fair target progress, render suspension, idle retirement-poll backoff with prompt resumption, stop/quiescence order and status delivery to application services.
- **Phase:** Runtime integration.
- **Depends on:** `VK-14`, `VK-15`. External prerequisite: TIME #138/#139 (and dependencies); LIFE #144.
- **Ordering:** critical path.
- **Relevant decisions:** D-5, D-15, D-18, D-22.
- **Acceptance signals:** Quiet continuous scenes avoid idle waits; suspended targets retain needed progress without spinning; other targets/commands remain serviceable; workers cannot await commands from an ended loop.
- **Out of scope:** A new simulation driver, game EngineEnv or render-worker architecture.
- **Open questions:** None; consume delivered TIME/LIFE contracts.

### VK-17. Deliver the multi-window triangle consumer and final evidence

- **Outcome:** A small renderer client proves the managed API and complete two-window milestone on both platforms.
- **Scope:** Embedded triangle shaders, required image assertions and two-window resize/first-window close, one/two-frame configurations, final teardown verdict, usage docs and local/remote evidence.
- **Phase:** Milestone.
- **Depends on:** `VK-8`, `VK-16`.
- **Ordering:** last on critical path.
- **Relevant decisions:** D-1–D-4, D-7, D-16, D-20, D-21, D-26.
- **Acceptance signals:** Full required native profile including test-owned setup and teardown measures under 30 seconds on each platform; second window renders after first closes; no missing validation detail; component docs/evidence land before final review.
- **Out of scope:** Scene graphs, camera/assets, optional stress runs becoming mandatory, or performance tuning without measurements.
- **Open questions:** Q-3 final timing/coverage gate; stop for an explicit scope decision if it cannot fit rather than reducing coverage silently.
