# Runtime foundation: errors and application composition

Define how components fail, recover, initialize, and share services before
messaging, worker, and GLFW implementations depend on those conventions.
The error/origin/recovery phase is ready to process. Contexts, state ownership,
initialization, and worker lifecycle remain in this arc behind explicit design
gates; they are not prerequisites for processing the error phase.

Design state: `ready for issue processing`

Owner: `coghex/hetoimasia`; publication target: `master`.
Started 2026-09-12 against Hetoimasia
`7e92e73d5eed7e564e9752ee49cce0eb5ba150c2`.
Readiness covers EPIC and RT-1 through RT-3. RT-4 through RT-6 are deliberately
deferred under Q-3 and D-9. This document authorizes no tracker creation or
implementation by itself.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Establish reusable runtime failure and composition contracts
- [ ] RT-1. Preserve typed failures with structured origin and operation context
- [ ] RT-2. Add bounded recovery around complete owned operations
- [ ] RT-3. Report recovery and terminal outcomes through the existing logger
- [ ] RT-4. Compose component contexts and scoped initialization — [deferred]: settle Q-3's context and initial-state contract
- [ ] RT-5. Establish scoped worker startup, cancellation, and joining — [deferred]: settle Q-3's worker ownership and stuck-worker contract
- [ ] RT-6. Integrate application startup, availability, and shutdown — [deferred]: settle Q-3's application lifecycle contract and complete RT-4/RT-5

Process EPIC, then RT-1, RT-2, and RT-3 in dependency order, one artifact at a
time. Stop before drafting a deferred slice until its named decisions are
settled and its one-PR scope is refined. Completing the error phase does not
complete this epic.

## Epic contract

- **Goal:** components can initialize, perform work, and fail under explicit
  ownership and error contracts, with narrow dependencies and preserved evidence.
- **Done when:** the owner-approved contracts have implementation and Hspec
  evidence for ordinary results, typed failures, cleanup failures, cancellation,
  scoped recovery, and the eventual initialization/lifecycle composition. The
  latter contracts must be settled under Q-3 and implemented before this epic
  can close; the initial error phase alone is insufficient.
- **Users and operators:** engine developers and applications composing services.
- **Arc label:** none proposed.

## Current state and evidence

Hetoimasia already implements:

- `Hetoimasia.Foundation.Resource.Scoped`: a closed continuation representation
  with `Functor`, `Applicative`, `Monad`, and `MonadIO`; `withScoped` is its runner.
- `allocResource`, `allocComposite`, and `locally`: lifetime composition over
  the implemented scope and composite-construction contracts.
- Exception propagation that preserves the primary type, payload, and context;
  cleanup failures retained as separately inspectable evidence; cancellation
  unwinding under the accepted mask discipline. See [resources.md](resources.md).
- `Hetoimasia.Runtime.Resources.resourceSmoke`: a specific composition of
  resource scopes, injected work, and the existing reporting policy. It is an
  example consumer, not a generic runtime error boundary or message transport.

`Scoped` has no `MonadError`, `MonadCatch`, or environment/state instance. An
exception thrown by `liftIO` already unwinds its scopes; these absent instances
do not mean failure handling is absent. `runApplication` currently logs around
an `IO` action, without constructing an environment or supervising workers.

Read-only Synarchy inspection at
`91fec430ea5596f497d76eb720de9940aeeb6c39`:

| Source | Relevant behavior |
|---|---|
| `src/Engine/Core/Monad.hs` | `EngineM` carries `Either EngineException a` through a continuation. `throwError` skips subsequent binds; `catchError` handles that explicit error value. `liftIO` does not translate native exceptions into it. |
| `src/Engine/Core/Error/Exception.hs` | Structured domain constructors, a human-readable message, and call-stack context. Its central sum imports an asset identifier; that dependency pattern should be evaluated when separating error owners here. |
| `app/App/Exception.hs` | `guardNativeExceptions` supplies another boundary for native exceptions, translating them into an engine error. This demonstrates the integration work needed when two failure channels coexist. |
| `src/Engine/Core/Log.hs`, `test-headless/Test/Headless/Core/LogMonad.hs` | Public logging wrappers preserve caller attribution rather than exposing a helper's location. Keep that discipline for failure origins; avoid relying on `logAndThrow` successfully logging before it throws. |
| `src/Engine/Audio/Thread.hs` | Optional audio records disabled/unavailable state before best-effort diagnostics. Synchronous diagnostic failures do not prevent that transition; cancellation is excluded from ordinary recovery. |
| `src/Engine/Graphics/Window/GLFW.hs` | Missing monitor/mode information can fall back to a plain window. The resulting mode and live geometry describe what was actually created. |
| `src/Engine/Core/Thread.hs` | A required worker failure requests engine cleanup before attempting diagnostics. Preserve shutdown intent independently of logger success; design worker joining separately under Q-3. |
| `src/Engine/Core/Init.hs` | `initializeEngineWith` assembles queues, references, and subsystems into EngineEnv. Preserve useful construction flow while defining each new component's own state and dependencies. |

The distinction is also documented by
[mtl's error-channel warning](https://hackage.haskell.org/package/mtl-2.3.2/docs/Control-Monad-Except.html#warning):
an `ExceptT` error is a different mechanism from a thrown `IO` exception.

Readiness tracker check on 2026-09-12 found no overlapping open runtime/error
arc. The open CI, resource, and test-architecture epics (#8, #22, #49) remain
separate. Recheck exact child overlap when processing; do not reopen completed
logging/resource work to implement these additions.

### Small semantic check against the current public API

Two scratch Hspec examples passed against the built foundation at `7e92e73`:

1. A `withScoped` callback returning `Left StartFailure`, followed by a failing
   release, propagates the release exception. The returned value is discarded
   under the existing successful-body/failing-release rule.
2. The same callback throwing typed `StartFailure`, followed by the same failing
   release, propagates `StartFailure` and retains one cleanup failure.

These are observations of the existing contract, not defects or newly added
production tests. They show why a plain `ExceptT e Scoped` result needs a
deliberate policy if its `Left` is intended to be the primary operation failure.
An ordinary `Either` result remains useful when it is intentionally data.

## Decisions already accepted

### D-1. Establish infrastructure before Vulkan

The owner selected methodical work on logging, messaging, runtime composition,
threading, and GLFW before Vulkan. The first eventual graphics milestone remains
a windowed triangle. The [foundation design](engine_foundation_design.md)
provides the broader component boundaries.

### D-2. Preserve the existing resource failure and reporting contracts

The owner previously approved retaining the original action/cancellation
failure, preserving cleanup evidence independently of logging, and attempting
the remaining eligible releases. Typed catch behavior and context survive
propagation. Logging failures must not skip cleanup or replace an existing
ordinary primary failure during a reporting attempt. Cancellation retains the
separate behavior already documented by the resource/reporting contracts.

This design must compose with those guarantees. Changing them requires an
explicit design revision, not a convenience instance on a new monad.

### D-3. Keep ownership modular and test primarily with Hspec

Previously accepted: application composition connects independently owned
services; consumers receive narrow interfaces. No universal EngineEnv or global
service registry. Hspec is the first choice, including effectful failure and
concurrency contracts. Preserve Synarchy's useful flow and decisions deliberately.

### D-4. Use typed exceptions for aborted operations and values for expected outcomes

The owner accepted P-1: resource-owning operations fail through typed IO
exceptions and the existing scope machinery. Expected outcomes remain explicit
component-owned return values. Do not introduce a second CPS/ExceptT failure
channel for the same operations. Native failures, component failures, and
cancellation must compose with D-2. Q-1 is resolved.

### D-5. Make failure origin clear and attempt supported recovery

The owner explicitly requires errors to identify where they came from, and
recovery to be attempted wherever it is possible. Preserve typed causes,
operation/component identity, and available source/context information through
propagation, recovery, and reporting. Recovery must establish a valid outcome;
warning alone does not make failed work successful.

### D-6. Distinguish optional and required services

The owner accepted bounded retry/fallback with warnings. If recovery is
exhausted, an optional feature can be explicitly disabled or its operation
rejected; an unrecoverable required service stops cleanly. Record the resulting
availability/outcome before relying on diagnostic output. Required versus
optional is determined by the caller's operation requirements, not by a global
severity attached to every instance of an exception type.

### D-7. Require a proven safe path after cleanup failure

The owner accepted that failed cleanup stops automatic retry/fallback unless
the component explicitly establishes that recovery is still safe. Attempted
release is not proof of disposal. Generic helpers must default to propagation
and must not infer safety from the exception's name, a timeout, or a warning.

### D-8. Keep the full runtime foundation in this design

The owner chose to keep application context/initialization and worker lifecycle
in the same design as errors, origins, and recovery. Preserve those later
questions and scope here; do not silently narrow the epic to error helpers alone.

### D-9. Process errors first and gate later phases

The owner explicitly permits processing the error/origin/recovery phase while
context, initialization, and worker slices remain blocked on later design
decisions. RT-1 through RT-3 may proceed; RT-4 through RT-6 require Q-3's
corresponding decisions. Q-4 is resolved. A processor must stop at those gates
instead of asking a solver to invent the remaining runtime architecture.

## Desired experience and scope

A developer can identify a failure's owning component, operation, original
cause, and available source location even when logging is disabled. A caller
can perform a supported recovery within a finite policy, observe the actual
resulting availability, and retain evidence of unsuccessful attempts. Required
unrecoverable work propagates its failure for orderly shutdown; an optional
failure can produce an explicit unavailable/rejected result with a warning.

The first phase adds origin/context support, complete-operation recovery, and
reporting integration over the existing foundation and runtime components.
The remaining arc owns narrow application composition, initial state, and
worker lifecycle once Q-3 is settled. No application-wide monad or universal
environment is selected by this document's readiness marker.

Messaging queues, GLFW integration, Vulkan, graphics recovery such as device
loss, and game-level save/transaction policy require their own component
contracts. They are not implementations in RT-1 through RT-3. No graphics SDK,
new demonstration application, global exception registry, or retry scheduler
is needed to verify the error phase.

## Error-phase design contract

The following behavior develops D-2 through D-7 into verification boundaries.
Exact helper names, signatures, and internal module layout remain implementation
proposals; issue processing may refine them without changing the accepted
failure channel, recovery policy, or ownership boundaries. A change to those
decisions requires returning to the owner.

### P-1. Use typed IO exceptions for failed operations; return expected outcomes

Accepted by D-4; the table describes the selected failure model:

| Situation | Representation and handling |
|---|---|
| Expected operation outcome | Component-owned result type: for example, a deliberately non-blocking send can report capacity/refusal. Pure validation can return `Either ValidationError Config`. The caller handles this as ordinary control flow. |
| An operation aborts | A structured component-owned exception travels through `IO` and the existing `Scoped` machinery. Skip subsequent work and preserve native exceptions under the same resource policy. |
| Cancellation | Propagate through scope cleanup. Ordinary recovery does not turn it into an expected rejection or retry. A future supervisor can observe a child's termination while respecting its own cancellation. |
| Cleanup fails | Use the current retained evidence and primary-failure rules. Do not convert a cleanup failure into a successful expected result. |

Do not make the foundation import every component's error type. Component error
types provide structured codes/payloads and useful display text as real cases
arrive. Generic infrastructure can retain an exception and its context without
knowing every constructor. Preserve foreign/library causes if a boundary later
adds component context; formatting a cause into text is not equivalent to
retaining its typed value.

This keeps Synarchy's structured failures and monadic short-circuiting while
using the failure path that the current resource contract already understands.
An ergonomic throw helper can build on `liftIO . throwIO`; its name and exact
signature are not selected here. Throwing a failure should not depend on first
successfully writing a log entry.

Tradeoff: `IO` does not advertise every possible exception in its return type.
Document failure cases and use typed recovery at named boundaries. The separate
application-error channel was considered and rejected in D-4 because it would
need additional integration with the established scope failure table.

### P-2. Recover around a complete owned operation

A recovery boundary names the operation and resources it covers. For example,
an optional component can be initialized and used within an inner scope; if
that operation fails, its eligible cleanup runs before the caller chooses a
fallback. Enclosing application services can remain live.

Place the actual work inside that boundary's resource continuation. A successful
result leaving a closed scope must be an ordinary value, never a borrowed handle
or a closure/lazy result whose validity needs that handle. A fallback requiring
a replacement live component needs a scoped consumer, not a function returning
a released component.

Do not naively implement a general catch by wrapping the entire CPS invocation
in `catch`. That invocation includes the caller's continuation; the wrapper can
therefore catch a later caller failure as if allocation itself had failed and
can run the continuation again through a fallback. Define and test the intended
recovery extent before exposing an instance or combinator. Handling one ordinary
`IO` operation while holding valid resources is a different extent from aborting
and rebuilding the whole component.

An IO boundary can already retain full evidence with `tryWithContext` and
propagate it with `rethrowIO`, following the
[base API](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html#v:tryWithContext).
Recovery should match only failures it knows how to handle. Unknown exceptions
propagate; a broad ordinary-recovery helper must identify cancellation before
invoking a handler. Classification by the existing async exception hierarchy
is the project's convention, not a claim that an exception's type reveals
every possible delivery mechanism.

Under D-7, failed cleanup prevents automatic fallback or retry by default. The
resource library guarantees that releases were attempted; it cannot prove their
postconditions after a release throws. Component-specific safe recovery despite
cleanup failure needs an explicit contract. The first generic recovery helper
propagates such failures; an exception to that default requires a separate
component contract proving safe postconditions, with verification. This phase
must not provide a generic unchecked override that treats cleanup as complete.

### P-3. Assign error, state, and reporting ownership independently

| Owner | Responsibility |
|---|---|
| Foundation resource code | Lifetimes, masking, and retained exception evidence; no application error taxonomy or logger dependency. |
| Component | Own failure types, expected results, private state invariants, and recovery it can actually perform. |
| Runtime/application boundary | Startup/shutdown policy, supervision, and an appropriate final result/report to its caller or operator. |
| Application composition | Supplies configuration and narrow service contexts; selects which component failure permits fallback. |

Exception recovery does not undo arbitrary IORef writes, consumed messages, or
external side effects. The owning operation must define what remains valid
after failure; a Reader/State facade cannot provide that rollback automatically.
Do not equate resource cleanup with a successful state transaction.

Keep exception context and logger context distinct. They can both carry operation
information, but logger breadcrumbs alone do not retain failure evidence when
logging is disabled or a sink fails. Apply the existing reporting policy at a
chosen boundary; returning or propagating through a helper does not justify
another automatic log entry.

### P-4. Retain origin as exception evidence, independently of logging

Each engine-originated aborted operation supplies stable component and operation
identity, a typed cause, and available caller source information. Capture origin
at the public failure/operation boundary, preserving the caller's module,
file/line, and call stack where available. Propagation may add outer operation
context but must not overwrite that origin with the catch or report location.
Caller-supplied resource/request identifiers are immutable context values, not
references to mutable engine state or borrowed resources.

For a native/library exception, keep the native exception type and payload.
Attach the known engine operation and observation boundary; if the native throw
site is unavailable, say so rather than inventing it. Component context must
not convert every `IOException`, for example, into one textual engine exception.
Inspectors must work when logging is filtered out or a sink is broken.

Use the existing exception-context mechanism rather than a new wrapper that
changes ordinary typed catch behavior. The
[base exception API](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html)
provides `tryWithContext` and `rethrowIO` for preserving evidence; `annotateIO`
adds context to synchronous exceptions only. Do not claim it automatically
annotates cancellation. Preserve cancellation's existing context and the
resource library's separately retained cleanup evidence.

Proposed implementation: small typed origin/operation annotations and inspectors
in foundation, with explicit `HasCallStack` at public helpers and a consistent
caller-attribution policy. Test attribution through an extra helper layer; do
not maintain a list of helper names to ignore. Keep origin distinct from the
logger's reporting-site `src` field. Low-level throwing/annotation functions
must not require a logger or log before raising the failure.

This is runtime diagnostic evidence, not a serialized save schema. Avoid
storing handles or lazy computations needing a closed resource in annotations.
An evaluation failure belongs inside the owned operation when producing its
result requires those resources; no generic helper promises to make arbitrary
lazy return values safe after scope exit.

### P-5. Make recovery finite, classified, and truthful

A recovery policy is supplied for a named operation, not installed globally for
every exception of a type. Its contract identifies the failures it can handle,
the restored/remaining state required for each attempt, and which work may be
replayed. Cleanup does not undo external effects or make an operation idempotent.
An operation with no established safe replay or fallback must propagate its
failure instead of trying it speculatively.

The boundary follows this order:

1. Run one complete owned operation with its caller's normal cancellation
   behavior. An attempt includes any inner scope's release obligations.
2. On failure, finish those cleanup attempts and retain the original exception
   with context. Exclude cancellation and failed cleanup from ordinary recovery
   before invoking the component's recovery classifier.
3. If the failure is recognized, state is safe, and the shared attempt budget
   permits, select a retry or fallback. Any wait is cancellable and occurs
   outside release callbacks. The next attempt cannot start before the failed
   attempt has finished cleanup.
4. On success, return the actual result, including degraded/fallback status when
   applicable. On exhaustion, required work propagates failure; optional work
   returns an explicit unavailable/rejected outcome only where its caller's
   contract permits continuing. Attach the reason and attempted recoveries to
   that outcome. Unknown failures are propagated, not silently downgraded.

One finite budget counts the initial attempt and every retry/fallback. Switching
strategy cannot reset the budget. Validate policy configuration before starting
the owned operation; no default unlimited retry or automatic retry of all IO
exceptions. The operation may need its own deadline or native timeout, but a
finite attempt count does not guarantee a wall-clock bound for a stuck foreign
call. Worker shutdown and stuck-worker policy remain gated under Q-3.

Retain unsuccessful attempts as typed, ordered context, bounded by the attempt
budget. If a later attempt fails, that latest active failure is primary and
earlier attempt failures remain inspectable, including their own origin and
cleanup evidence. Do not replace the terminal cause with a generic
`RetriesExhausted` string. Successful recovery and optional rejection retain a
structured account of earlier failures for their caller/reporting owner.

A failure in the classifier or recovery-policy machinery stops recovery; it
must not be fed recursively into the same policy. Preserve the failure being
handled as context of this new failure, following the existing handling/context
conventions. Cancellation during work, classification, waiting, fallback, or
reporting propagates with its own evidence; it is never converted to a retry,
an optional rejection, or the preceding synchronous failure.

The first API operates on complete `IO` operations returning ordinary values
and explicit outcomes. It adds no general `MonadCatch Scoped` instance. Choosing
a replacement live component for the rest of application startup is RT-4's
scoped-initialization design, not an excuse to return a released handle here.

### P-6. Report at the boundary that chooses the disposition

Recovery data does not require logging. A runtime adapter uses the existing
injected logger to explain recovery/degradation and terminal failure, preserving
the level meanings in [logging.md](logging.md) and reporting semantics in
[resources.md](resources.md). Foundation/resource code must not acquire a
logger dependency to support this adapter.

Keep diagnostic effects outside release callbacks and outside any gap between
acquisition and installation of its cleanup protection. A lifecycle diagnostic
failure already marked by the runtime must remain distinguishable from an
operation failure, so the adapter does not try the same broken sink again.

The caller records the selected availability/disposition before relying on a
diagnostic. For example, an exhausted optional initialization produces an
unavailable result; the application records that result before warning. This
preserves Synarchy's audio ordering and its GLFW distinction between requested
mode and achieved mode. A warning never substitutes for changing state or
returning a failure result.

Use Warning for a supported recovery/degradation or optional rejection that
allows the enclosing application to continue, and Error for terminal required
work/unhandled operation failure. Emit one terminal report at the boundary
handling it, not another Error at every propagation hop. Recovery reporting
must be bounded by actual attempts/transitions; a final report may summarize
the chain without duplicating each attempt as another terminal error. Identify
failure origin separately from the reporting location and include the resulting
availability. Do not classify an exception's severity globally.

Synchronous failure while formatting or emitting a failure/recovery diagnostic
must not replace the primary failure, reverse a chosen disposition, skip
cleanup, or cause another operation attempt. Do not recursively report a broken
logger through itself. Cancellation during reporting still propagates under
the existing reporting contract. Ordinary direct logger calls retain their
existing behavior; best-effort handling belongs to this diagnostic boundary.

RT-3 supplies and tests this reusable adapter and a minimal existing runtime
consumer. The first phase does not claim that application availability state,
worker supervision, or orderly engine shutdown has been implemented. Their
actual composition is RT-4 through RT-6.

## Open questions

### Q-1. Which failure channel should resource-owning engine operations use?

Resolved by D-4: typed IO exceptions for aborted operations, explicit results
for expected outcomes, and recovery at defined boundaries. The alternative
CPS/ExceptT application-error channel was rejected. The existing resource
primitives remain authoritative.

### Q-2. What recovery boundary and cleanup-failure policy should we expose?

Resolved for the error phase by D-4 through D-7 and the complete-operation
contract in P-1 through P-6: typed evidence, bounded classified attempts,
optional/required disposition, and propagation after cleanup failure. Exact
helper signatures can be refined during processing within that contract; no
arbitrary catch instance is approved by choosing an exception-based channel.
Recovery that yields a replacement live service remains part of Q-3/RT-4.

### Q-3. How should contexts, initialization, and worker lifecycle compose?

Deliberately open under D-8/D-9; this blocks RT-4 through RT-6, not RT-1 through
RT-3. The processor must stop before drafting each affected slice and return
the relevant choices to the owner:

- **RT-4:** explicit arguments versus a narrow Reader facade; component-owned
  configuration and initial state; scoped construction/partial startup; how a
  fallback service remains live for its consumer without replaying that
  consumer. Specify each state's owner, access, thread, lifetime, and reset.
- **RT-5:** who starts/owns a worker; startup acknowledgement, cancellation,
  completion and joining; how failures reach its supervisor; what to do when a
  worker cannot stop. A join is not automatically valid inside the existing
  uninterruptible release callback. Decide the explicit stop-before-release
  protocol and its failure obligations before implementing a worker helper.
- **RT-6:** application boot/shutdown ordering, required/optional service
  composition, coherent availability publication, and the runtime's final
  result. Decide these against RT-4/RT-5, including partial startup failure and
  cancellation. Specify which existing entry points migrate and their
  compatibility behavior before changing them.

Refine/split the corresponding reserved slice if the settled contract exceeds
one reviewable PR, updating both ledger and plan without reusing existing IDs.
Messaging transport and GLFW still need their own focused component designs.

### Q-4. May the error phase process while later runtime phases remain gated?

Resolved by D-9: process errors/origins/recovery first; keep the full runtime
foundation here and stop before Q-3's gated slices. Readiness does not authorize
a processor or solver to choose the remaining context or worker architecture.

## Verification strategy

Use Hspec with typed synthetic failures, real CPU scopes, injected sinks, and
observable acquisition/release/state traces. Add tests for the new boundaries,
reusing existing resource guarantees rather than duplicating their internals:

| Boundary | Required behavioral evidence |
|---|---|
| Origin/context | Engine failure and native `IOException` remain catchable by their original types through nested scopes, added operation context, and recovery. Original attribution survives an extra helper and a later report site; unknown native origin is distinguished from the known observation boundary. Inspect evidence with logging disabled. |
| Resource composition | Aborted work skips subsequent work. Primary and cleanup evidence survive annotation/rethrow. Failed-attempt releases finish before fallback; enclosing services remain usable. A caller failure after the complete-operation boundary is not caught/retried, and its continuation runs once. |
| Recovery | Supported retry and fallback succeed; exhausted required work fails; exhausted optional work is explicitly unavailable/rejected. Unknown failures and unsafe replay propagate. Invalid budgets are rejected before effects; strategy changes cannot reset the finite budget. |
| Recovery failures | Failed cleanup prevents another attempt. A classifier/handler failure stops the policy and retains the handled failure. Every failed attempt's typed cause/context remains inspectable in order. Result production that needs a borrowed resource is exercised inside its owned scope. |
| Cancellation | Coordinated cancellation during work, classification, waiting, fallback, and reporting escapes recovery with its own context/cleanup evidence. No retry or unavailable result absorbs it. |
| Reporting | Actual disposition is recorded before a warning can fail. Correct levels and distinct origin/report locations reach an injected sink without duplicate terminal reports. Synchronous formatting/sink failure cannot change the result, replace a primary failure, or skip cleanup; reporting cancellation follows the existing contract. |

Use deterministic coordination, injected waits where applicable, and watchdogs
only to fail a hung example. No sleeps as concurrency assertions and no new
window/GPU fixtures. Add examples under the owning engine component in the
existing Hspec hierarchy; keep its empty-selector protection. Use the existing
validation catalog/planner, updating input coverage in the implementing PR if a
new path requires it. No optional probe is needed to prove these CPU contracts.

Keep the existing resource API and successful `runApplication` behavior unless
an implementing issue explicitly specifies a compatible extension. Migrate only
the minimal existing runtime diagnostic consumer required for RT-3. Put public
API contracts and any module-authoring guidance beside the implementation in
the same PR; this design is not a substitute for current-behavior documentation.
No persistence format or asset migration is part of the error phase. Remote CI
remains Linux-only; validate the CPU behavior locally on macOS as well.

## Delivery plan

### RT-1. Preserve typed failures with structured origin and operation context

- **Outcome:** a developer can inspect where a typed operation failure arose
  without depending on its log output.
- **Scope:** small foundation origin/operation annotations and inspection/throw
  boundaries; preservation through existing exception/resource APIs; public
  usage and caller-attribution documentation. Component-specific error types
  remain with their owners; no central engine-error sum.
- **Phase:** errors.
- **Depends on:** none within this arc; use the merged resource/logger baseline.
- **Ordering:** critical path.
- **Relevant decisions:** D-2, D-3, D-4, D-5, D-9.
- **Acceptance signals:** Hspec proves original typed catch behavior, caller
  attribution through helpers, outer context without origin replacement,
  native-cause retention, cleanup evidence, and inspection without logging.
- **Out of scope:** recovery policy, new component taxonomies, context/worker APIs.
- **Open questions:** none blocking; exact names/signatures are refined in the
  issue within P-1/P-4 and the existing exception-context contract.

### RT-2. Add bounded recovery around complete owned operations

- **Outcome:** a caller performs safe classified recovery with a finite budget
  and obtains a truthful result or preserved terminal failure.
- **Scope:** logger-independent complete-operation boundary, explicit policy and
  outcome/history data, required/optional disposition, retry/fallback ordering,
  and documentation of replay prerequisites and failure behavior under P-2/P-5.
- **Phase:** errors.
- **Depends on:** RT-1.
- **Ordering:** critical path.
- **Relevant decisions:** D-2, D-3, D-4, D-5, D-6, D-7, D-9.
- **Acceptance signals:** Hspec observes release-before-fallback, parent scope
  validity, finite attempts across strategy changes, recovery success and
  exhaustion, typed attempt history, unknown/unsafe/cleanup-failed propagation,
  policy failure, cancellation, and no retry of the caller's later continuation.
- **Out of scope:** logger integration, recovering a live service for an external
  consumer, general catch instances on `Scoped`, worker/time-limit machinery.
- **Open questions:** none blocking; scoped service replacement is deferred RT-4.

### RT-3. Report recovery and terminal outcomes through the existing logger

- **Outcome:** recovery and failure diagnostics explain the origin and actual
  disposition without changing that disposition or weakening resource safety.
- **Scope:** runtime reporting adapter for RT-1/RT-2 evidence, a minimal existing
  runtime consumer, and module-authoring guidance for boundary ownership and
  state-before-diagnostics ordering. Reuse the logger and resource reporter's
  accepted behavior; preserve its diagnostic-failure distinction.
- **Phase:** errors.
- **Depends on:** RT-2.
- **Ordering:** critical path.
- **Relevant decisions:** D-2, D-3, D-5, D-6, D-7, D-9.
- **Acceptance signals:** injected-sink Hspec cases prove Warning/Error meaning,
  preserved origin and typed evidence, truthful optional status before a failed
  warning, bounded reporting without duplicate terminal errors, synchronous
  diagnostic failure isolation, and cancellation propagation. Existing runtime
  success and resource-reporting contracts continue to pass.
- **Out of scope:** new logger backend/configuration, whole-application lifecycle,
  production optional service, message transport, GLFW, or Vulkan.
- **Open questions:** none blocking; full application integration is deferred RT-6.

### RT-4. Compose component contexts and scoped initialization

- **Outcome:** an application constructs and borrows a small component through
  narrow dependencies, including component-owned initial state and partial
  startup cleanup.
- **Scope:** reserved for Q-3's selected context/state/construction contract;
  refine to one representative CPU component and one PR before processing.
- **Phase:** composition — deferred.
- **Depends on:** RT-3 and owner resolution of Q-3's RT-4 decisions.
- **Ordering:** critical path; may proceed independently of RT-5 once unblocked.
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-6, D-7, D-8, D-9.
- **Acceptance signals:** to be finalized with Q-3: narrow dependency use,
  owned initial state, lifetime-safe construction/fallback, and partial-startup
  failure/cancellation evidence.
- **Out of scope:** universal EngineEnv, concrete game state, GPU resources.
- **Open questions:** Q-3 blocks drafting this slice; stop for owner design.

### RT-5. Establish scoped worker startup, cancellation, and joining

- **Outcome:** one CPU worker has an explicit owner and observable startup,
  termination, and failure behavior.
- **Scope:** reserved for Q-3's worker contract; refine one worker lifecycle
  primitive and its controlled shutdown obligations into one PR before processing.
- **Phase:** workers — deferred.
- **Depends on:** RT-3 and owner resolution of Q-3's RT-5 decisions. Add RT-4
  only if the settled worker API actually needs its context interface.
- **Ordering:** critical path; otherwise independent of RT-4 once unblocked.
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-6, D-7, D-8, D-9.
- **Acceptance signals:** to be finalized with Q-3: acknowledged startup,
  observable failure/completion, cancellation/join coordination, and explicit
  behavior when a worker cannot stop. Hspec coordination must not rely on sleeps.
- **Out of scope:** general task scheduler, transport queues, moving GLFW calls
  off their required thread, presumed bounded joins inside release callbacks.
- **Open questions:** Q-3 blocks drafting this slice; stop for owner design.

### RT-6. Integrate application startup, availability, and shutdown

- **Outcome:** the runtime entry point composes the selected context and worker
  contracts into a coherent application lifecycle with truthful final results.
- **Scope:** reserved for Q-3's application contract; refine a minimal CPU
  composition and existing-entry-point migration into one PR before processing.
- **Phase:** application integration — deferred.
- **Depends on:** RT-4, RT-5, and owner resolution of Q-3's RT-6 decisions.
- **Ordering:** critical path after both composition and worker contracts.
- **Relevant decisions:** D-1 through D-9.
- **Acceptance signals:** to be finalized with Q-3: startup ordering, optional
  degradation, required-service failure, coherent availability, partial-startup
  cleanup, worker shutdown, and final reporting preserve the chosen contracts.
- **Out of scope:** gameplay startup, rendering, implicit global services.
- **Open questions:** Q-3 blocks drafting this slice; stop for owner design.

## Processing handoff

The processor may create the umbrella and draft RT-1 through RT-3 in order,
performing its normal deduplication and obtaining separate approval for each
tracker artifact. Treat Q-3 and the deferred ledger entries as hard stops, not
optional implementation notes. Do not file broad context/worker placeholders as
solvable issues before their contracts are settled. The epic remains open for
the full runtime arc; completion of RT-3 only finishes its error phase.
