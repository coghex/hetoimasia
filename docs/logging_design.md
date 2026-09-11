# Logging conventions and service design

Set the logging contract before adding more engine subsystems. Resource ownership
is covered by [its own design](resource_ownership_design.md).

Design state: `ready for issue processing`

Owner: `coghex/hetoimasia`; publication target: `master`.
Readiness approved by the owner on 2026-09-10, after discussion of the recommended
contracts. Reviewed against `2062f8a`; implementation has not started.
The owner requested publication to `master` on 2026-09-10.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Establish reusable logging and module conventions — [#1]
- [x] LOG-1. Establish structured logging, filtering, and scoped context — [#2]
- [x] LOG-2. Implement deterministic output and safe sink ownership — [#3]
- [x] LOG-3. Integrate startup configuration and the module authoring guide — [#4]

## Epic contract

- **Goal:** engine and game modules emit consistent diagnostics through an
  explicit service, with defined context, concurrency, and failure semantics.
- **Done when:** all slices pass Hspec, console/runtime use the final interface,
  and an authoring guide plus AGENTS.md pointer establish future conventions.
- **Users:** engine/game developers and implementation agents.
- **Arc label:** `logging` (proposed).
- **Scope:** synchronous structured logging, filtering, context, metadata,
  handle/callback sinks, startup configuration, and conventions.
- **Deferred:** queues, rotation, telemetry, JSON output, live reload, a logging
  monad, and resource management. No continuation-monad decision is required.

## Verified evidence

At Hetoimasia `4c4ed18`, the [logger](../packages/foundation/src/Hetoimasia/Foundation/Log.hs)
is scratch code: synchronous level filtering, an opaque injected sink, strict
text entries, and a borrowed handle formatter. Sink exceptions propagate.
[Four Hspec examples](../test/Main.hs) cover filtering, sink failure, runtime
ordering/results, and action failure. Metadata, concurrent use, and handle
ownership are not yet tested.

Synarchy sources inspected at `36090b94a39a773f65a7e9dc236efd971b38269d`, with
no local differences in these files; paths below are under `~/work/synarchy`:

| Source | Useful decision |
|---|---|
| `src/Engine/Core/Log.hs` | Gate before collecting metadata; independent Debug switches; external source attribution |
| `src/Engine/Core/Log/Types.hs` | Structured fields, breadcrumbs, component controls |
| `src/Engine/Core/Log/Env.hs` | Consistent category spelling and startup overrides |
| `src/Engine/Core/Log/Format.hs` | Separate entry data from handle/callback output; explicit flushing |
| `test-headless/Test/Headless/Core/LogMonad.hs` | Source-attribution regression tests through wrappers |

Adapt the shared mutable context, game-specific category enum, and EngineEnv
wrappers to independent services. No source was copied; preserve applicable
notices if implementations reuse source later.

Readiness recheck on 2026-09-10: the target has no issues or open PRs. Recheck
before filing. This arc does not duplicate FND-1 in the foundation design.
Process logging first. Resource issues may be planned alongside it; their
implementation gate is recorded in the resource design.

## Decisions

### D-1. Establish conventions before broad implementation

The owner requested this short design for other agents to process and solve,
while the lead agent continues resource-management design.

### D-2. Prefer Hspec

The owner's policy covers pure, effectful, and integration tests. Python probes
are a fallback only where Hspec cannot reasonably exercise the boundary.

### D-3. Preserve boundaries and delivery conventions

Previously accepted: explicit services, private subsystem state, no universal
EngineEnv, and each implementation's required docs/evidence in that same PR.

### D-4. Adopt the component, context, filtering, and configuration contract

The owner's request to finalize both discussed designs adopts P-1/P-2/P-4:
explicit loggers, immutable derived context, extensible components, independent
Debug selection, and validated startup configuration. A single threshold that
also enables Debug is not selected. Q-1 is resolved.

### D-5. Adopt synchronous sinks and observable sink failures

The same readiness approval adopts P-3: serialized handle output, caller-owned
handles, per-entry flushing by default, and propagated sink errors. Cleanup
remains independent of logger success. Best-effort error suppression is not
selected. Q-2 is resolved.

## Approved contract

The P-N clause identifiers are retained for continuity; D-4/D-5 adopt them.

### P-1. Public interface and context

Keep `Hetoimasia.Foundation.Log` as the public facade. Pass an opaque Logger
explicitly; pure algorithms remain pure. Logging need not appear in every file.

Use extensible lowercase dotted component names, such as `gpu.vulkan` or
`game.world`, with exact matching across configuration/output. Each nonempty
segment matches `[a-z][a-z0-9_-]*`; reject invalid names rather than silently
normalizing them. Reserve standalone `all`/`none` for Debug selectors. No central
game-category enum, global registration, or hierarchical matching.

Derived loggers carry immutable fields/breadcrumbs and share their root sink.
Inner fields override outer fields; event fields override context fields.
Workers receive explicit derived loggers, preventing shared-context leakage.

Entries contain level, component, message, `Map Text Text` fields, breadcrumbs,
UTC timestamp, thread identity, and optional source location. Level helpers use
one emission path and preserve the external call site through wrappers. Inject
metadata providers for tests.

### P-2. Filtering

Use Synarchy's semantics: the master switch gates everything; Debug uses
an explicit component set or `all`; other levels use a component threshold or
the global fallback. A Debug threshold alone does not enable Debug.
Defaults: enabled, global Info, no overrides, Debug disabled, source enabled.

Gate before forcing message/field payloads or collecting metadata. Verify this
with unused-provider counters and deliberately failing lazy payloads; make no
unmeasured zero-allocation or performance claims.

### P-3. Sinks, ownership, and failures

Keep synchronous emission. Handle sinks serialize whole records and flushes
across derived loggers, preserving each producer's order. Cross-thread ordering
is unspecified. Separate roots sharing a handle must share the sink explicitly.
Callback sinks may receive concurrent calls; callbacks supply their own
synchronization and must not recursively emit to the same sink. Callback flush
is a supplied action, defaulting to a no-op when the callback has no flushable
state. Callback exceptions use the same propagation policy.

Use a stable text layout with UTC time, level, component, thread, optional source,
breadcrumbs, message, and sorted fields. Quote/escape text to preserve one record
per line. Use format options rather than a separate thread-logging API.

Borrow handles without closing them or changing buffering. Provide explicit flush
and configurable per-entry flushing; enable per-entry flush by default.
File ownership remains with the caller.

The application's logging scope outlives every subsystem/worker borrowing its
sink: stop and join producers, finish subsystem cleanup, then flush and close
any application-owned handle. Derived loggers extend no handle lifetime by
themselves. These are caller obligations, not a new file-owning logging service.

Retain propagation of sink errors. Error-level logging does not throw an engine
exception. Error-reporting/cleanup boundaries must preserve their primary failure
and complete cleanup when diagnostics fail. Do not swallow cancellation or
report a sink failure recursively through that sink.

Generic resource-scope primitives must be usable without a logger and must not
import the logging module. Subsystems may emit diagnostics around their use.
Cleanup outcomes must remain observable independently of a working sink; the
resource-management work owns that outcome/error policy and its failure tests.

### P-4. Startup configuration and module conventions

The application reads environment once and supplies validated configuration;
foundation provides pure parsers. Use these console controls:

- `HETOIMASIA_LOG_LEVEL=info`: global threshold.
- `HETOIMASIA_LOG_LEVELS=gpu.vulkan=warn,lua=info`: exact overrides.
- `HETOIMASIA_DEBUG=none|all|gpu.vulkan,lua`: Debug selection.

Absent values retain defaults. Malformed/empty values and duplicate override
keys fail configuration before application startup. Trim surrounding whitespace
in list entries/values; internal whitespace in names remains invalid. Levels
accept `debug`, `info`, `warn`/`warning`, and `error` case-insensitively; Debug
selection uses lowercase `none`, `all`, or a comma-separated component set.
Repeated Debug components collapse to one; `all`/`none` cannot mix with names.
Components use canonical names without a registry lookup. Other applications
may choose another prefix. The master/source switches remain programmatic
configuration in this arc; no additional environment controls are implied.

The module authoring guide establishes explicit injection, stable components,
context at subsystem boundaries, and structured identifiers/values. Debug is
optional detail; Info is meaningful lifecycle activity; Warning is degraded or
recoverable behavior; Error is failed work. Avoid routine per-frame Info output.
Report propagated failures once at the responsible handling boundary. Engine
libraries use the logger for diagnostics; CLI help/results remain application
output. Logging imposes no shared game/engine error type.

## Resolved questions and readiness

### Q-1. Approve the interface, filtering, and configuration contract

Resolved by D-4.

### Q-2. Approve sink behavior

Resolved by D-5.

No blocking design questions remain. Exact exported helper names and private
module layout can be selected during issue specification within this contract.
Choose and document the exact text layout in LOG-2, including fixed-metadata
examples and Hspec expectations; it must implement P-3's record/escaping rules.
This is a presentation detail, not permission to alter ownership or failures.

## Verification and delivery plan

Use Hspec, injected providers, temporary handles, and explicitly coordinated
concurrency tests without timing sleeps. No GPU, Lua, or Python probes are needed.
Each slice includes its contract updates and evidence in its code PR.

### LOG-1. Establish structured logging, filtering, and scoped context

- **Outcome/scope:** P-1/P-2 plus the initial public contract and usage guide.
  Update existing callers atomically with public API changes.
- **Phase:** core; **Depends on:** none; **Ordering:** critical path.
- **Relevant decisions:** D-1/D-2/D-3/D-4; **Open questions:** none.
- **Acceptance:** Hspec filtering matrix, payload/metadata gating, field
  precedence, concurrent context isolation, and source attribution through wrappers.
  Libraries compile against their declared dependencies.
- **Out of scope:** new sinks, environment IO, custom monads.

### LOG-2. Implement deterministic output and safe sink ownership

- **Outcome/scope:** P-3 formatting, serialization, flushing, ownership/failure docs.
- **Phase:** output; **Depends on:** LOG-1; **Ordering:** critical path.
- **Relevant decisions:** D-2/D-3/D-5; **Open questions:** none.
- **Acceptance:** Hspec fixed-metadata formatting, escaping, concurrent intact
  records, per-producer order, flushing, borrowed-handle survival, propagated
  failures, and usable serialization state after interruption. Failed writes
  may leave a partial record; do not promise transactional filesystem writes.
  The ownership contract documents producer shutdown before final sink disposal.
- **Out of scope:** resource scopes, owned file services, queues, rotation.

### LOG-3. Integrate startup configuration and the module authoring guide

- **Outcome/scope:** P-4, configured console/runtime, final examples, AGENTS.md
  pointer, and updated smoke expectations.
- **Phase:** adoption; **Depends on:** LOG-2; **Ordering:** critical path.
- **Relevant decisions:** D-1/D-2/D-3/D-4/D-5; **Open questions:** none.
- **Acceptance:** Hspec parser/default/error and startup cases using injected
  lookups or child-process environments; build and smoke pass. Existing failure
  tests retain their intent. Document API/output changes and migrate all current
  callers; there is no external compatibility promise at this bootstrap stage.
- **Out of scope:** live reload, Synarchy migration, resource implementation.

## Agent handoff

Resolve this repository's `docs-wip` worktree by branch. `kanban:process-design-doc`
processes the epic first, then exactly one child per invocation, with separate
artifact approvals. Readiness is approved; do not reopen Q-1/Q-2 without new
contradictory evidence. Recheck code/tracker state and update the ledger.

Follow the appropriate publication and issue/solve/review workflows; this design
grants no tracker or merge approvals. Resource
design can proceed alongside logging, while resource implementation should use
the settled logging facade.
