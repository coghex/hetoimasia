# Hetoimasia vision and design guardrails

Owner direction consolidated on 2026-09-20 from the design conversation and
accepted decisions linked below. This is context for `$guide` and fresh
development sessions, not a claim that every feature is implemented. Detailed
contracts remain in their owning documents; current work and coverage belong
in the tracker and [guide reports](guide/).

New explicit owner decisions can revise this guide. Record the decision and
reconcile affected contracts; do not silently change intent to fit new code
or an agent recommendation. Preserve these principle IDs.

## Product and boundaries

### V-1. A reusable engine, with the game outside it

Build a modular Haskell engine using Lua for game authoring and Vulkan for the
first graphics backend, with independent 2D and 3D renderers. Applications
assemble services and own game rules, assets and authoritative state. Engine
packages never import concrete games. Use narrow services and opaque handles,
not a universal `EngineEnv`, service locator or mutable global registry. An
application-wide monad must not conceal dependency ownership.

Preserve Synarchy's useful reasoning about GLFW, logging, monotonic time,
shaders and rendering deliberately. Reuse is selective; its coupled environment
and game managers are not the new architecture. A future 2D module should make
migrating game behavior practical without promising source compatibility.
See [foundation direction](engine_foundation_design.md) and [AGENTS](../AGENTS.md).

Owner decision 2026-09-26: use flexible subsystem-local `Base`/`Types`
conventions, allowing dedicated type modules and explicit low-level local
contracts. Shared mathematics and mathematical structures belong in a separate
`packages/math` Cabal package, independent of every other local package and of
graphics packages. Rendering policy and API adapters stay with graphics.
The package is planned; numerical APIs remain to be designed. See
[module conventions](module_conventions.md) for the accepted boundaries.

### V-2. Build infrastructure methodically

Logging, failures, resources, messaging, supervision, timing and window ownership
come before the production renderer. A multi-window triangle is an eventual
integration milestone, not a reason to skip these boundaries. Lua can progress
independently where its prerequisites are satisfied. Add abstractions and
concurrency for a concrete consumer; defer bound-worker variants until a named
consumer needs OS-thread affinity. See [runtime direction](runtime_foundation_design.md)
and [runtime review dispositions](runtime_review_findings.md).

## Lifetime, failure and concurrency

### V-3. Ownership and completion are correctness boundaries

Construction, publication, use and release have named owners. Preserve the
primary failure and cleanup evidence on partial construction and shutdown.
Short CPU releases must not hide arbitrary driver, worker or logging waits
under uninterruptible masking. Workers drain before borrowed dependencies
disappear; sending cancellation is not proof of termination. If safe release
cannot be established, retain resources and wait under the protected lifetime.
That wait is in-process. Owner decision 2026-09-22: the application may bound
quit with its own watchdog. After an application-chosen deadline, it names the
owner or worker still running, makes a bounded best-effort log flush, and ends
the process without unwinding, leaving reclamation to the OS. It never releases
a resource that a live worker may still borrow. Engine packages gain no
deadline, detach or forced-release path.

Dynamic windows have independent lifetimes. One exclusive graphics attachment
holds each window alive until retirement is acknowledged. Closing the first
window must not invalidate another. GPU submission completion, presentation
retirement, CPU scope exit and logical asset release are distinct facts.
See [resources](resources.md), [workers](workers.md), runtime D-13 and
[window/graphics lifetime](window_graphics_lifetime_design.md).

### V-4. Explicit failures and bounded safe recovery

Failures identify component, operation and relevant instance. Retry or fallback
requires proven safety and finite budgets; never replay arbitrary consumer
effects. Distinguish optional-service rejection from required-service failure.
Supervision uses checkpoints and supervised waits, without promising interruption
of every blocking operation. Logging failures must not replace an earlier
primary failure. See [runtime foundation](runtime_foundation_design.md).

### V-5. Bounded communication and responsive ownership

Use bounded FIFO commands/events and coherent latest-value snapshots. Prepare
payloads deeply on the producer. Ordinary send reports full immediately;
waiting is explicit. Close permits backlog drain, abort discards it, and
in-flight effects are not automatically retried. Generic broadcast and
request/reply are deferred. See [messaging](messaging_design.md).

The GLFW owner stays on the process main thread. Owned ports, snapshots and
persistent command tickets connect services. Scheduling uses monotonic time,
explicit deadlines and optional fixed steps with bounded catch-up. Render demand
is per window; simulation pause policy belongs to the application. Expected
native-wake failure preserves admitted commands and degrades to bounded polling
with a diagnostic. See [scheduling](runtime_scheduling_design.md) and [GLFW](glfw.md).

The approved production rendering design uses a separate supervised graphics
owner, with bounded handoffs and explicit ownership of Vulkan roots. GLFW calls
and record-only callbacks remain on the main thread. The graphics owner's
component-owned worker group outlives ordinary application workers and remains
available through protected retirement, with the main thread servicing required
handoffs before the final join. Rendering consumes published scene snapshots;
the application chooses which thread produces them, and a simulation driver is
deferred. This does not promise window-command progress during a Cocoa modal
loop, or qualify rendering progress without the retained VK-16 native evidence.
See [Vulkan decisions D-29–D-33](vulkan_backend_design.md) and LIFE D-6.

## Graphics and platforms

### V-6. Central lifetime enforcement with flexible renderer scheduling

The first production profile requires Vulkan 1.3 or newer and verified features.
Preserve future backend alternatives without implementing Vulkan 1.2 or OpenGL
now. Support multiple rendered windows sharing a compatible device where
presentation permits, configurable frame capacity defaulting to two per target,
managed recording with automatic retention, bounded overlapping generations,
and verified completion. Draw order and supported scheduling stay explicit.

Required/optional target policy governs exhausted local recovery. Surface
replacement, allocation reclamation and explicit frame abandonment preserve
ownership and finite recovery budgets. Device loss and validation errors stop
the affected shared graphics session. Elapsed time and render fences do not
prove presentation retirement. Platform timing assumptions are not correctness
evidence. See [Vulkan decisions D-12–D-33](vulkan_backend_design.md).

### V-7. Optimize actual foreign-call and diagnostic boundaries

Use audited unsafe imports for suitably short recording hot paths. Potentially
blocking calls, waits, submission/presentation and Haskell re-entry retain the
required safe boundary. Production Vulkan capture is bounded and C-only, with
delivery through a separately owned diagnostic worker. Historical proof callbacks
are not the production contract. Measure performance rather than assuming a
binding-wide flag is an optimization. See Vulkan D-28.

Synchronous logging remains available. An optional bounded asynchronous runtime
adapter protects latency-sensitive producers, with explicit saturation,
truncation, flush, writer-failure and drain behavior. Its borrowed sink outlives
the writer. See [runtime review RR-5/RR-6](runtime_review_findings.md).

### V-8. Qualify platforms honestly and preserve native privacy

Remote CI is Linux-only; macOS native verification is local. Windows execution
is deferred until a machine is available. Linux defaults to X11; Wayland is
explicit, without silent fallback. Unavailable capabilities and observations
are reported, never fabricated. A headless compositor establishes a specific
profile, not every desktop compositor.

Private shims may implement approved native integrations without exposing
ownership to applications. The Wayland connection-status exception is a
read-only owner-thread probe, not permission to consume protocol messages or
take over GLFW's connection. Keep the exception and required disconnect
experiment in the [Wayland design](wayland_qualification_design.md).
Compositor loss cannot manufacture GPU completion.

## Scripting, tests and delivery

### V-9. Responsive Lua domains with untrusted-process isolation

Own independent UI and gameplay execution domains with bounded scheduling and
communication. Untrusted mods require confined processes per mod and domain,
explicit capability grants and enforced memory/execution limits. They receive
no ambient filesystem, network, process-launching or native-module authority.
Unsafe authoritative-state failure stops the affected gameplay session while
UI remains available to report it.

The game's own first-party scripts are trusted and run in-process in those
domains, calling bindings directly without IPC (owner decision 2026-09-22,
Lua D-12). Mods keep the confined pipeline. Both share one module and
capability registration layer, and the trusted path is never a mod fallback.

Owner decisions on 2026-09-24 (Lua D-13/D-14) permit trusted delivery
independently of confinement qualification, after renewed design readiness.
Binding registration defaults to no mod exposure: a confined binding needs an
explicit grant and supported bounded transport semantics. Direct bindings need
no IPC equivalent and cannot synchronously enter another VM owner. Trusted
scripts may hang or exhaust application memory; cooperative budgets are not
hard limits, and their dependencies remain held until actual completion.
Confined integration and adversarial acceptance remain required for the full
Lua arc, behind successful qualification on both platforms.

Cooperative scheduling is not hostile-code containment. A merged probe with an
inconclusive verdict does not qualify deployment or release its dependent gates.
Callback threads are runtime machinery, not cancellation endpoints; limits and
cancellation follow the VM-owner or process protocol. See [Lua design](lua_runtime_design.md)
and its platform confinement verdicts.

### V-10. Strong evidence with selective cost

Prefer Hspec and package-owned tests with focused groups. Root tests cover
composition; the tools suite covers workflow. Shared native fixtures preserve
main-thread and teardown rules. Python probes serve boundaries Hspec cannot
reasonably exercise. Required CI combines the mandatory floor, affected
non-optional groups and PR requests. Optional probes stay optional and may be
run by periodic testing.

Required Vulkan native checks should stay under 30 seconds; broader probes
are opt-in. Each platform supplies its own evidence. Ask for the **human user's
explicit approval before every desktop-disrupting test session**; issue approval
is not desktop consent. Isolated scripted displays are a separate approved path.
Pure/model tests do not establish visual results, performance or confinement.
See [validation](validation.md) and [test architecture](test_architecture_design.md).

### V-11. Reproducible inputs and efficient solo delivery

Prefer the newest compatible toolchain, including qualified release candidates,
then pin compiler, dependencies and native inputs. Reuse the public digest-pinned
Linux image and cached native builds. Preserve explicit loader, driver, layer
and shader-compiler identities. Keep Template Haskell shader compilation with
an explicit target environment and reproducible compiler discovery.

CI and review freshness are independent. An exact proven clean merge can retain
review while changed test inputs rerun selected checks. Documentation changes
may reuse compatible code evidence; SHA difference alone is not code change.
Code and required docs/evidence ship in one PR; standalone docs use their own
lane. `$guide` does not replace approval gates. Favor effectiveness first and
efficiency second, without adding team-scale process for hypothetical needs.
See [CI design](ci_validation_design.md), [workflow](workflow.md) and [toolchain](toolchain.md).

## Continuing after a context reset

Run `$guide` after a meaningful batch or when checking a new arc. It compares
changed issues and merged code, including comments and docs, with these decisions.
Each [report](guide/) names the exact snapshots checked while other agents keep
working, the coverage limits and next steps. Expected unfinished work is separate
from defects and drift. Update this document only for accepted changes in intent.

`$guide` then walks through follow-ups one at a time; `$guide continue` resumes
that discussion from the report. Completed legacy reviews are inherited from
the recorded owner-accepted baseline, not automatically reviewed again. This
vision remains applicable when a design arc finishes: if no settled next slice
exists, discuss the next unmet goal or unresolved decision before designing more
work. Finishing a design does not consume or erase its constraints.
