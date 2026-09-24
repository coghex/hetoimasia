# Low-level runtime capability findings, 2026-09-22

Evidence-backed capability gaps from the review of Hetoimasia's foundation,
runtime, and relevant GLFW integration. This report supports one-at-a-time
disposition through `process-report`; it does not prescribe one architecture
or combine all findings into an epic.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Methodology

Reviewed repository: `coghex/hetoimasia`, code baseline
`da81087bb2c81e844588a0fc30197bd99201c6b9`. The primary checkout still held
that revision when this document was converted to a report. The docs worktree
is the authoring location, not the code baseline used for the review.

The owner asked whether low-level runtime capabilities expected in a mature
game engine were missing. The review read the foundation/runtime
implementation, relevant GLFW integration, architecture and current contracts,
and the open issue inventory. Primary-source engine documentation supplied
comparisons, not a mandatory industry checklist. This was an architectural
review using existing tests, not an exhaustive correctness audit or a
performance qualification.

Existing foundations include scoped ownership and rollback, preserved primary
and cleanup failures, structured logging and an optional asynchronous adapter,
worker supervision, bounded channels, coherent snapshots, monotonic time,
fixed-step catch-up limits, and protected window/graphics retirement. The
findings below concern capabilities or qualification still missing from that
foundation; they do not establish that these existing contracts are broken.

The earlier review ran the following with GHC 9.14.1 selected on `PATH`:

```sh
cabal test hetoimasia-foundation:foundation-tests \
  hetoimasia-runtime:runtime-tests \
  --project-file=cabal.project.cpu --test-show-details=failures
```

Result: **339 foundation examples and 207 runtime examples, all passing**.
No desktop session or performance experiment ran. Those results belong to
the review baseline; the report conversion did not rerun them. Headless
success proves neither native responsiveness nor a visible rendering result.

Evidence paths and line numbers below refer to the reviewed code revision.
Recheck each premise and effective tracker specification during processing;
historical issue references are leads, not final deduplication or approval.

### Owner direction and document conversion

The owner approved prioritizing **runtime tracing and stalled-shutdown
diagnostics** and rejected combining all six findings into one epic.
The other capabilities remain follow-ups to consider through their concrete
consumers. On 2026-09-22 the owner confirmed two **planned future capabilities**
outside this first small effort:

- **GPU timing:** collect GPU execution timing and correlate it with the runtime
  timeline. Backend instrumentation, supported timestamp capabilities and clock
  correlation require later refinement; reuse the shared tracing format where
  applicable.
- **Native crash collection:** retain native crash evidence with build/platform
  identity and recent diagnostics. Platform collection, retention and failure
  handling require later refinement; in-process shutdown observation does not
  supply this capability.

Both remain planned work, with implementation approach and scheduling open.
Neither is a prerequisite for the first CPU tracing/stalled-shutdown delivery.

This report supersedes the local draft
`docs/designs/runtime_capabilities_design.md`, which was converted at the
owner's request. Stable identifiers RTC-1 through RTC-6 are preserved.
Its former design ledger, epic contract, and readiness questions are replaced
by independent findings. All findings remain unprocessed: priority is not an
issue disposition, implementation specification, or tracker linkage.

The proposed offline trace capture and in-process observer defaults were
never approved. They remain possible approaches, not requirements. Backend,
budget, retention, and ownership choices belong to a focused design if a
finding needs one; they do not block recording or processing this report.

## Status

- [ ] RTC-1. Runtime performance evidence lacks a correlated engine timeline
- [x] RTC-2. Protected shutdown can outlast the available terminal diagnostics — [#251]
- [ ] RTC-3. Finite worker jobs lack a bounded workload-execution service
- [ ] RTC-4. Content loading lacks asynchronous request ownership and memory budgets
- [ ] RTC-5. Timing primitives lack a worked simulation/input/render composition
- [ ] RTC-6. The input surface still lacks capabilities already identified by RR-9

---

## Execution visibility and shutdown diagnostics

### RTC-1. Runtime performance evidence lacks a correlated engine timeline

The owner requested a documentation-only contract discussion on 2026-09-23.
The [proposed tracing contract](runtime_tracing_design.md) records an opt-in
GHC-eventlog direction, observation semantics, bounds and qualification questions.
It is exploring, not an approved design or implementation; RTC-1 remains
unprocessed. No issue drafting or filing is authorized by that discussion.

**Verification: Verified capability gap in the inspected production code;
performance impact unmeasured.**

The runtime exposes useful subsystem counters and structured logs, but the
review found no shared engine timeline connecting update work, queue
residence, worker activity, native waits, and RTS allocation/GC events.
That limits the evidence available to explain an observed execution spike.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Messaging/Channel.hs:363` —
  `ChannelStatistics` reports capacity, depth, high-water, and conservation
  counters; it does not attribute queue residence time to a specific unit
  of work.
- `packages/runtime/src/Hetoimasia/Runtime/AsyncLog.hs:309` —
  `AsyncLogStatus` reports admission, delivery, truncation, and loss; it is
  not a correlated execution trace.
- `packages/runtime/src/Hetoimasia/Runtime/UpdatePolicy.hs:228` —
  `FixedStepTurn` reports simulation-step and discarded-time accounting,
  not actual execution durations.
- The production foundation/runtime sources and relevant application/GLFW
  surfaces were inspected for tracing and RTS integration. No shared
  engine tracing facility or engine use of `traceEventIO`,
  `traceMarkerIO`, or `GHC.Stats` was found in the reviewed surfaces.

**Handoff context:**

- **Current behavior:** individual logs and counters expose local facts, while
  a caller must construct cross-subsystem performance correlation separately.
- **Expected direction:** enable a representative consumer to correlate
  observed runtime work and waits with timing and RTS evidence, and retain
  reproducible measurements of the diagnostic path's own costs.
- **Priority:** one of the two owner-selected first areas.
- **Scope and constraints:** preserve injected services and existing counter
  semantics. Vulkan's independent validation capture/worker, tracked in #217
  at review time, is a different diagnostic boundary. Do not replace it or
  create a global service locator. Measure performance claims; a proposed
  trace API is not proof of low overhead.
- **Planned future capability:** GPU timing and CPU/GPU correlation remain
  subsequent work coordinated with the backend; the first CPU tracing slice
  does not deliver or cancel that capability.
- **Remaining uncertainty:** capture/export backend, clock correlation,
  initial events and consumer, boundedness/loss policy, retention, and
  disabled/enabled overhead budgets. Offline capture using existing tools is
  an unapproved candidate. RTS tuning follows workload evidence, not a
  preset optimization claim.

### [#251] RTC-2. Protected shutdown can outlast the available terminal diagnostics

**Verification: Verified ordering and diagnostic gap; no production hang was
reproduced by this review.**

The worker group preserves borrowed dependencies until workers actually
finish. The application's managed terminal report follows scope unwinding.
Consequently, a permanently incomplete drain can prevent that terminal
report from being reached. The ownership policy is deliberate; what is
missing is useful observation while the protected wait continues.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Worker.hs:488` —
  `drainGroup` waits for the terminal group report while preserving the
  protected lifetime.
- `packages/runtime/src/Hetoimasia/Runtime/Application.hs:262` —
  `runManagedApplication` encloses dependency and supervision lifetimes
  inside `reportOnce`.
- `packages/runtime/src/Hetoimasia/Runtime/Application.hs:283` —
  `reportOnce` catches the settled outcome of that enclosed work before
  attempting the managed terminal report.
- `packages/runtime/src/Hetoimasia/Runtime/Inbox.hs` — the documented
  stuck-handler policy retains resources, with no deadline or detachment.
- `console/Hetoimasia/Console/Exit.hs` — the executable maps propagated
  outcomes to exit status and a best-effort stderr line; it is not a
  native crash collection service.

**Handoff context:**

- **Current behavior:** safe completion remains a prerequisite for release;
  terminal diagnostics cannot describe a drain that has never returned.
- **Expected direction:** expose which workers remain, their last declared
  operation or known phase, stop/cancellation state, and elapsed drain time
  while the owner is waiting. Distinguish observed status from an inferred
  cause of the stall.
- **Priority:** the other owner-selected first area.
- **Scope and constraints:** diagnostic observation must preserve shutdown,
  exception, and cleanup-evidence semantics. Neither timeout nor cancellation
  proves safe resource release. Exercise a coordinated blocked worker and
  show that observation remains available until the worker is released;
  observer failure must not replace the primary failure or authorize cleanup.
  Avoid duplicating GPU retirement policy in the Vulkan/GLFW integration.
- **Remaining uncertainty:** observer lifetime, output path, bounds,
  observation cadence, and failure boundary. An opt-in in-process observer
  is an unapproved candidate and cannot promise evidence during every
  native/RTS/process-wide stall.
- **Planned future capability:** native crash collection, including retained
  build/platform identity and recent diagnostics, is owner-confirmed future
  work requiring separate refinement outside the first small effort. In-process
  shutdown observation does not establish crash capture or crash survival.

## Background work and content ownership

### RTC-3. Finite worker jobs lack a bounded workload-execution service

**Verification: Verified capability gap; no workload-driven performance need
or scheduler bottleneck has yet been established.**

The runtime can supervise finite jobs, but each started worker is an
individually owned Haskell thread. The reviewed code does not provide a
service controlling admission and execution concurrency for bursts of
expensive short work such as decoding or procedural generation.

**Evidence:**

- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs` —
  `Role.Job` distinguishes normal finite completion from an unexpected
  service exit; it does not supply a queued-job executor.
- `packages/foundation/src/Hetoimasia/Foundation/Worker.hs:569` —
  `startWorkerWith` starts an owned worker with `forkIOWithUnmask`.
- `packages/runtime/src/Hetoimasia/Runtime/Inbox.hs` —
  inbox dispatch handles one prepared message at a time on a supervised
  service; it is not a general concurrent short-job scheduling contract.
- The reviewed production package inventory contains no shared bounded
  job-admission/execution service.

**Handoff context:**

- **Current behavior:** applications can compose workers and messaging, but
  must define burst admission, concurrency, and per-job ownership themselves.
- **Expected direction:** when a named consumer needs it, establish bounded
  submission/concurrency, explicit saturation, completion, and cancellation
  behavior for that consumer's expensive background work.
- **Scope and constraints:** GHC already schedules lightweight threads. The
  finding does not justify a custom work-stealing scheduler or a native thread
  pool. Queued and in-flight cancellation differ; borrowed resources must
  survive actual completion. Preserve Lua's separate execution protocol and
  do not promise interruption of arbitrary native/Lua execution.
- **Remaining uncertainty:** first consumer, work granularity, required
  parallelism, resource limits, and whether a reusable service is warranted.
  The consumer requirement is a proposed processing precondition, not an
  already-applied deferred disposition. This is outside the first effort.

### RTC-4. Content loading lacks asynchronous request ownership and memory budgets

**Verification: Verified capability gap in the reviewed package inventory;
no production loading hitch or memory exhaustion was reproduced.**

Resource scopes establish construction and teardown, but they do not yet
provide content lookup, asynchronous loading, caching, or ownership of load
requests. Message capacity alone also does not bound the bytes or preparation
work retained by a future loading pipeline.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs` and
  `packages/foundation/src/Hetoimasia/Foundation/Resource/Collection.hs` —
  scoped and dynamic lifetime primitives, rather than content lookup or
  loading services.
- `packages/foundation/src/Hetoimasia/Foundation/Messaging/Channel.hs` —
  capacity admission counts entries; arbitrary payloads carry no byte charge.
- `packages/foundation/src/Hetoimasia/Foundation/Messaging/Payload.hs:84` —
  `prepare` evaluates through `NFData` without imposing a size or
  evaluation-time limit.
- `packages/gpu-vulkan/README.md` and
  `packages/render-api/README.md` — backend/resource boundaries do not
  provide a production application content-loading API at the reviewed
  revision.

**Handoff context:**

- **Current behavior:** applications must assemble loading protocols from
  lower-level effects and ownership primitives.
- **Expected direction:** use the first content consumer to establish
  request/status/result, duplicate-request ownership, cancellation, and
  transfer into GPU-owned resources. Account for queued, decoding, and
  upload-staging memory rather than only the number of requests.
- **Scope and constraints:** preserve game-owned save schemas and authored
  content identities. CPU release, logical content release, and GPU retirement
  remain distinct. Do not assume an arbitrary payload can be sized accurately
  or charge the same shared allocation twice.
- **Remaining uncertainty:** first content type, storage roots, cache/eviction
  policy, identity and persistence choices, numeric budgets, and whether RTC-3
  is a prerequisite. No virtual filesystem or generic asset manager design
  was approved. This is outside the first effort.

## Application composition and input

### RTC-5. Timing primitives lack a worked simulation/input/render composition

**Verification: Verified composition gap within the inspected baseline;
simulation ownership is deliberately application-level.**

The runtime already computes bounded fixed steps, interpolation, and
pause/resume timing. What the review did not find was a complete worked
application establishing which input each catch-up step consumes and when
the simulation publishes its render snapshot.

**Evidence:**

- `packages/runtime/src/Hetoimasia/Runtime/UpdatePolicy.hs:246` —
  `advanceFixedStep` produces step counts, retained remainder, discarded
  time, and the next deadline; it does not execute simulation or assign input.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Input.hs:405` —
  `InputEvent` contains window, epoch, and payload, not simulation-step
  assignment.
- `packages/glfw/src/Hetoimasia/GLFW/Input.hs` —
  one logical consumer reads ordered events and acknowledges resets after
  clearing its derived input state.
- `docs/vision.md`, V-5 — simulation and scene production remain
  application-owned; the graphics owner does not establish gameplay progress
  during Cocoa modal interactions.

**Handoff context:**

- **Current behavior:** the mechanisms compose, but application authors must
  define and demonstrate the input-to-step and publication policy themselves.
- **Expected direction:** a worked consumer should make that policy explicit
  across zero, one, and multiple catch-up steps, reset/focus events, and
  pause/resume, with coherent scene publication.
- **Scope and constraints:** retain application authority over game rules and
  pause policy. Fixed steps alone do not prove determinism or replay.
  Recheck Vulkan demand/retirement integration #232 and triangle consumer #233
  before proposing another consumer; those were open at review time.
- **Remaining uncertainty:** the first consumer, precise input assignment,
  existing consumer coverage when processed, and whether this merits a
  separate issue or focused design. This is outside the first effort.

### RTC-6. The input surface still lacks capabilities already identified by RR-9

**Verification: Verified current capability gap, with an existing report
follow-up rather than a newly discovered requirement.**

The input feed supports ordered keyboard, character, button, scroll, and focus
events with explicit resets. Cursor capture/raw relative motion, gamepad
polling/hotplug, and fuller text interaction remain outside the bound surface.

**Evidence:**

- `packages/glfw/src/Hetoimasia/GLFW/Input.hs:42` — the public input exports
  expose the existing event/reset/admission/statistics contract.
- `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs` — the reviewed
  binding lacks the cursor-mode/raw-motion, gamepad, and clipboard operations
  identified by the earlier review.
- `docs/runtime_review_findings.md:444` — RR-9 already records the next input
  design, with cursor capture/raw motion first, gamepad polling/hotplug next,
  then clipboard/text interaction.

**Handoff context:**

- **Current behavior:** the existing input protocol is useful and explicit
  about lost/reset state, but does not cover those device/interaction needs.
- **Expected direction:** continue the existing RR-9 design follow-up rather
  than create a parallel input arc.
- **Scope and constraints:** preserve native-handle privacy, record-only
  callbacks, owner-thread rules, epoch/reset acknowledgement, and game-owned
  action bindings. Specify focus-loss cleanup and relative-motion
  accumulation/consumption. Clipboard support is not a complete IME design.
- **Remaining uncertainty:** the input design's current existence/tracker
  coverage and concrete prerequisites when processed. RR-9's earlier
  deferred disposition is historical context; no disposition is applied to
  RTC-6 here. This is outside the first effort.

## References and processing handoff

Primary-source comparisons consulted during the original review:

- [Unreal Insights](https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-insights-in-unreal-engine)
  illustrates timing, counters, memory, and loading visibility.
- [GHC 9.14.1 RTS options](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/runtime_control.html)
  document parallelism, allocation, and GC configuration tradeoffs.
- [Unreal crash reporting](https://dev.epicgames.com/documentation/en-us/unreal-engine/crash-reporting-in-unreal-engine)
  illustrates retained error, build/system, log, and application context.
- [Godot WorkerThreadPool](https://docs.godotengine.org/en/stable/classes/class_workerthreadpool.html)
  illustrates task submission/completion, not a requirement to copy its singleton.
- [Godot background loading](https://docs.godotengine.org/en/stable/tutorials/io/background_loading.html)
  describes request/status/result and blocking on unfinished work.

Process RTC-1 first, then one finding per invocation in report order unless
the owner selects another. Processing re-verifies the premise and current
tracker coverage before proposing an issue, a focused design, an existing
link, no issue, or deferral. An independent finding is not necessarily a
single implementation issue.

Architectural questions retained above are handoff context, not report-readiness
gates. A focused design can settle them when the finding's approved disposition
calls for one. Keep all six findings independent; owner priority does not
authorize filing, implementing, or merging any of them.

When splitting or disposing of RTC-1/RTC-2 after the first diagnostics phase,
preserve their planned GPU-timing and native-crash follow-ups in an explicit
report/design handoff; completion of the first phase does not complete them.

Any eventual implementation keeps its code, required contracts, tests, and
retained evidence in one PR under the repository's normal workflow. Use
package-owned Hspec tests, explicit concurrency coordination, and the validation
planner. Performance claims require measurements. Native desktop disruption
requires separate human consent. This report grants none and publishes no
tracker mutation.
