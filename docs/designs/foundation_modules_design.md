# Foundation module organization

Establish the owner's flexible, subsystem-local `Base`/`Types` convention in
foundation before planning equivalent work in its consumers. This is a
structural design over existing contracts, not a new service architecture.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

The six delivery slices are accepted for issue processing under D-4. Tracker
artifacts remain unprocessed and require their own approval before creation.

- [ ] EPIC. Establish foundation's module-local data and behavior boundaries
- [ ] FMO-1. Separate logging and failure data from their operations
- [ ] FMO-2. Separate resource representations and collection types
- [ ] FMO-3. Separate worker data, requests, startup, observation and group lifetime
- [ ] FMO-4. Separate recovery policy and outcome types
- [ ] FMO-5. Separate time data and pure arithmetic from clock operations
- [ ] FMO-6. Separate messaging types and give its component identity a common owner

## Epic contract

- **Goal:** Foundation has cohesive, acyclic module-local type layers, with
  existing public interfaces and lifecycle behavior preserved.
- **Done when:** The approved module layout is implemented; every foundation
  production Haskell file in `src/` and `internal/` is below 600 physical lines,
  including comments; module and Cabal-component dependency graphs are acyclic
  without boot files; every module has a concrete responsibility or dependency
  boundary rather than merely filling a naming pattern; external opacity,
  behavior and required validation pass; accompanying contracts and the package
  README's module map describe the implemented owners and source roots.
- **Users and operators:** Engine maintainers and existing foundation consumers.
- **Arc label:** None proposed.

## Current state and evidence

Inspected at `master@9e2f0333c120c613dd06bf26a62b6981b16c9799` on 2026-09-26.
There are twelve production Haskell files, ten exposed library modules, and
two exposed modules of the package-private `internal` sublibrary. No production
file is currently named `Base.hs` or `Types.hs`.

Current production tree, with physical line counts:

```text
packages/foundation/
├── hetoimasia-foundation.cabal
├── README.md
├── LICENSE
├── src/Hetoimasia/Foundation/
│   ├── Failure.hs                 421
│   ├── Log.hs                     744
│   ├── Recovery.hs                513
│   ├── Resource.hs                266
│   ├── Resource/Collection.hs     516
│   ├── Time.hs                    318
│   ├── Worker.hs                  123
│   └── Messaging/
│       ├── Channel.hs             386
│       ├── Payload.hs              91
│       └── Snapshot.hs            275
├── internal/Hetoimasia/Foundation/
│   ├── Resource/Internal.hs       558
│   └── Worker/Internal.hs         952
└── test/
    ├── Main.hs
    └── Test/Foundation/
        ├── Spec.hs
        ├── Failures/Spec.hs
        ├── Logging/               (9 modules)
        ├── Messaging/             (6 modules)
        ├── Recovery/Spec.hs
        ├── Resources/             (7 modules)
        ├── Time/                  (2 modules)
        └── Workers/               (2 modules)
```

The test folders are abbreviated; production files are listed completely.

Verified dependency opportunities:

- `Failure.hs` imports `Log` only for `Component`, `SourceLocation` and
  `componentText`. Lower logging contracts can serve this dependency without
  importing emission, configuration parsing or sink implementation.
- `Time.hs` combines primitive time values and pure arithmetic with clock IO,
  logging identity and failure attribution. Pure arithmetic can be separated.
- `Messaging/Snapshot.hs` imports `Messaging/Channel` for `messagingComponent`
  alone. That identity belongs to their common messaging owner.
- Resource's private seam is required by public resource, collection and
  recovery construction and by private worker implementation. The private
  library cannot import the main library back.
- Worker requests and completion observation both invoke `retireIfSettled`;
  start and group lifetime both need cancellation. These shared operations
  must remain below their callers, not create opposing module imports.
- `Messaging/Payload.hs` already owns one opaque type, its evaluation guarantee
  and its operations in 91 lines. It is a suitable dedicated type module.

Open tracker checked again at readiness on 2026-09-26: no foundation organization issue or epic
found. #266 concerns native Vulkan generations, a separate module family.
This is an arc overlap check, not final per-issue deduplication.

## Decisions

### D-1. Flexible Base/Types and dedicated type modules

The owner accepted the boundaries in [module conventions](../module_conventions.md).
No package-wide universal type collection, forced empty modules or renaming of
already cohesive dedicated type modules is required.

### D-2. Module-local ownership and size

Owner clarification: module-specific types belong under the module's name,
such as `Camera/Base.hs`, `Camera/Types.hs` or dedicated `Camera/Vertex.hs`.
Subcomponents can own nested `Types` modules. Keep `Base`/`Types` below roughly
600 lines and consider a coherent component extraction when they exceed that.
The proposed refactor acceptance criterion uses fewer than 600 physical lines,
including comments, with substantial headroom rather than filling the limit.

### D-3. Delivery priority

Begin with foundation's data-layer refactor, then its consumers. Decompose the
GPU-model `State.hs` after the foundational refactor. Math-package implementation
is deferred and is not a prerequisite. The feature backlog follows the
structural work.

### D-4. Accept the revised layout and six delivery slices

On 2026-09-26, after reporting that the cross-brand reviewer approved the revised
document, the owner asked to mark it ready subject to this agent's readiness
check. That check passed: the revised layout, explicit worker call graph,
two-facade Cabal boundary, single cleanup-identity owner, six delivery slices,
compatibility constraints and completion criteria are accepted for issue
processing. Q-1 is resolved. This records design signoff, not canonical GitHub
issue approval, implementation completion or permission to publish or file.

## Accepted layout

This tree is the accepted implementation target, not a claim about implemented files.
The existing ten public import paths stay exposed. New `src` modules are hidden
`other-modules` of the main library. The private `internal` library retains
exactly its two exposed modules, `Resource.Internal` and `Worker.Internal`;
all new modules in that component are `other-modules`. Only the facades are
importable across the component boundary, including by foundation's tests.
Implementation modules inside `internal` can import one another directly.
Do not share source directories between Cabal components.

Each tree below is relative to `Hetoimasia/Foundation/` in its source root.
The ranges are rough **estimated final physical lines**, based on the current
declaration/function blocks, retaining their comments and allowing for new
headers, imports and exports. They are planning estimates, not measured output
or minimum sizes. Check actual counts during implementation; do not add text
or fragment a cohesive module to hit a range.

```text
src/                              estimated lines; responsibility
├── Log.hs                         200–280  public API and logger operations
├── Log/
│   ├── Base.hs                     50–90   levels, source locations, small options
│   ├── Component.hs                70–110  validated Component and its constructors
│   ├── Types.hs                   160–230  filters, entries, sinks, metadata, logger records
│   ├── Filter.hs                  210–290  configuration parsing and admission predicates
│   ├── Format.hs                  120–170  deterministic text formatting and escaping
│   └── Sink.hs                    100–150  callback/handle sinks and serialized writes
├── Failure.hs                     220–300  raising, attaching and inspecting evidence
├── Failure/
│   ├── Base.hs                     25–45   Operation and its naming operations
│   └── Types.hs                   170–230  origins, contexts, sites, annotation and rendering
├── Recovery.hs                    330–430  bounded recovery and scoped construction
├── Recovery/
│   └── Types.hs                   180–250  tags, strategies, policies, outcomes and history
├── Time.hs                        130–190  clock IO, sampling and existing public exports
├── Time/
│   ├── Types.hs                   100–160  instants, durations, errors, results, sources, baselines
│   └── Arithmetic.hs              140–210  conversions and non-wrapping time arithmetic
├── Messaging/
│   ├── Component.hs                15–30   common messaging component identity
│   ├── Payload.hs                  91      existing Prepared type and evaluation contract
│   ├── Channel.hs                 260–340  channel operations and public exports
│   ├── Channel/
│   │   └── Types.hs               150–220  phases, errors, endpoints, receipts and statistics
│   ├── Snapshot.hs                190–260  snapshot operations and public exports
│   └── Snapshot/
│       └── Types.hs               120–180  cursors, errors, state, endpoints, observations, updates
├── Resource.hs                    260–290  public scope operations and exports
├── Resource/
│   ├── Collection.hs              370–450  membership, borrowing and retirement operations
│   └── Collection/
│       └── Types.hs               170–230  member IDs, phases, errors, state and results
└── Worker.hs                      120–140  existing public facade

internal/
├── Resource/
│   ├── Internal.hs                 65–90   existing package-private facade
│   ├── Types.hs                   120–180  ReleaseRank, Part, Assembling, Assembly and Ledger
│   ├── Scoped.hs                   90–130  dedicated continuation type, instances and runner
│   ├── Cleanup.hs                 230–310  cleanup ID, counter, evidence, inspection/release
│   └── Assembly.hs                210–290  staged acquisition, rollback and lending
└── Worker/
    ├── Internal.hs                 80–110  existing package-private facade and probe entry point
    ├── Base.hs                     100–150 IDs, requests, phases and cancellation exception
    ├── Types.hs                    180–270 group/entry/handle/definition/probe/status records
    ├── Outcome.hs                  120–180 outcomes, exception capture and classification
    ├── Observation.hs              150–230 status, waits, observation and settled retirement
    ├── Requests.hs                 110–170 stop, cancellation helpers and single-worker drain
    ├── Startup.hs                  180–260 registration, fork, handoff and child execution
    ├── Group.hs                    220–310 group creation, closing snapshot and group drain
    └── Evidence.hs                  95–140 worker evidence type, annotation rendering/inspection
```

The directory is the logical owner even when the physical source root is
`internal`. For example `Resource/Types.hs` is still under `Resource` and need
not be called `Resource/Internal/Types.hs` to remain hidden from clients.
Each slice updates a module map in `packages/foundation/README.md` listing
logical module, physical source path, Cabal component, visibility and purpose.
That map must describe delivered modules only, not present the proposed whole
tree as implemented after the first slice.

### Responsibilities and dependency rules

- Extract `Base` when a concrete lower consumer needs elementary types without
  importing the composite records, or a demonstrated dependency cycle requires
  that layer. A small family otherwise gets one owner-local `Types` module.
  This calibration is accepted for this foundation refactor under D-4; it
  does not impose a new universal convention. Retaining `Snapshot/Types.hs` serves the owner's explicit
  navigation/ownership preference even though Snapshot is already below 600.
  `Payload.hs` remains a cohesive dedicated type module. Review any target
  approaching 600; there is no minimum file size. No global `Foundation/Base.hs`
  or `Foundation/Types.hs` is proposed.
- The three retained `Base` modules have concrete consumers: failure needs
  `Log.Base.SourceLocation` without logger records; recovery needs
  `Failure.Base.Operation` without failure annotations; `Worker.Outcome` needs
  worker IDs and request/run tags without group/handle representations.
  The small `Failure.Base` is justified by that dependency, not by its size.
- `Log.Component` keeps the validated name and its operations together.
  `Log.Types` imports `Log.Base` and `Log.Component`; filter, format and sink
  modules consume types. `Log` composes those operations. Failure imports the
  small logging contracts directly within the main component.
- `Failure.Types` also owns its private annotation representation and instance
  if needed to avoid a cycle. Type-specific rendering required by an instance
  stays with it. Operational attachment and raising stay in `Failure`.
- Recovery's data modules depend on the lower operation-name contract, not
  the recovery loop. Its two recovery paths and their existing shared helpers
  remain together; this refactor does not invent a general retry framework.
- `Time.Arithmetic` imports only time data layers and suitable external
  libraries. It has no clock IO, logging or failure-attribution dependency.
- Both messaging implementations import `Messaging.Component`; `Channel`
  continues to re-export `messagingComponent` for source compatibility.
- `Resource.Scoped` is an independent dedicated type module. `Resource.Types`
  owns release ranks, the assembly representation and its instances;
  `Resource.Assembly` implements its effects and uses `Resource.Cleanup`.
  `Resource.Cleanup` alone defines `CleanupFailureId`, `CleanupFailure`, the
  existing counter and identity allocation. Facades re-export the same identity
  type; no second definition, counter or representation exists elsewhere.
- `Worker.Outcome` depends on worker primitives and resource cleanup evidence,
  never worker state. `Worker.Types` can therefore import it without a cycle.
  `StartOutcome`, which carries a worker handle, belongs in `Worker.Types`.
- `Worker.Observation` depends on data and outcomes; it owns the one settled
  retirement operation used by observation and cancellation. `Requests` imports
  it; `Startup` and `Group` can both import requests, observation and evidence.
  Neither `Startup` nor `Group` imports the other. `settledSummary` lives in
  `Observation`; `drainWorker` lives in `Requests`, which already imports
  observation and can request cancellation. `Group` owns only group draining.
  Preserve every STM transaction and mask/restore boundary while moving functions.
- `Worker.Evidence` imports outcomes and resource evidence, not group lifecycle.
  The existing test coordination hook remains available only through the private
  component. Do not add a general hooks framework or expose it publicly.
- Exactly the existing two `internal` facades remain exposed by that private
  library; every newly extracted module is an `other-module`. Main-library
  Resource, Collection and Recovery continue to import `Resource.Internal`;
  public Worker and its probe tests import `Worker.Internal`. Worker
  implementation modules inside the private component import `Resource.Scoped`
  and `Resource.Cleanup` directly. The private component never imports the main
  library. External-client negative-test source strings are not actual internal
  imports and must continue to fail compilation.

### Worker function ownership and call graph

The callers below are current direct callers, grouped by their accepted owner.
These placements make the dependency direction explicit; no `Worker.Util` or
mutually importing startup/group pair is needed.

| Function | Owning module | Direct callers / owning modules |
| --- | --- | --- |
| `settledSummary` | `Worker.Observation` | `drainWorker` / Requests; `awaitReport` / Group |
| `retireIfSettled` | `Worker.Observation` | `observeCompletion` / Observation; `requestCancelEntry`, `deliverCancellation` / Requests |
| `requestCancelEntry` | `Worker.Requests` | `requestCancel`, `drainWorker` / Requests; `escalate` / Group |
| `drainWorker` | `Worker.Requests` | `startWorkerWith` / Startup |
| `drainGroup`, `escalate` | `Worker.Group` | group lifetime and the drain loop / Group |
| `trySome` | `Worker.Outcome` | `withWorkerGroupProbed`, `drainGroup`, `escalate` / Group; `startWorkerWith`, `runChild` / Startup; `drainWorker`, `requestCancelEntry`, `deliverCancellation` / Requests |
| `failureResult` | `Worker.Outcome` | `startWorkerWith`, `runChild` and its local run-exit classifier / Startup |
| `resultCleanup` | `Worker.Outcome` | `publish` / Startup |
| `succeeded` | `Worker.Outcome` | `beginClosing` / Group; `retireIfSettled` / Observation |
| `describeSummary` | `Worker.Evidence` | `EvidenceEntry`'s annotation renderer / Evidence only |
| `attachEvidence` | `Worker.Evidence` | `startWorkerWith` / Startup; `withWorkerGroupProbed` / Group |

`trySome` remains the existing `tryWithContext` wrapper, colocated with outcome
classification; Outcome is therefore not claimed to be a purely functional
module. It performs no worker/group mutation or lifecycle orchestration.
The other three shared outcome helpers preserve their current definitions.

Correction to the supplied review: `retireIfSettled` at lines 858–869 does
**not** call `describeSummary`. The call at line 888 is inside the
`ExceptionAnnotation EvidenceEntry` instance. Keeping that renderer in Evidence
does not make Observation depend on Evidence.

## Scope and compatibility

Accepted scope: foundation production modules, Cabal declarations, accompanying
ownership/module documentation and directly affected tests. Preserve current
public module paths, exported names, types, constructor access, nominal roles,
instances and observable behavior. Keep instances with their type; introduce
no orphan instances. Changes to defining modules can affect reflection and
Haddock provenance: do not promise stable `TypeRep` module names or binary ABI
solely because source imports are preserved; check for such consumers before
each extraction.

Keep the existing test organization. Extend external-client opacity checks to
cover the new hidden paths where useful. No tests merely asserting filenames.
No resource protocol, cancellation policy, queue/snapshot semantics, numerical
policy, logging layout, allocation strategy or new dependency is proposed.
Math, GPU-model State, native generations, other packages, and a general
exception/evidence framework are outside this foundation arc.

## Verification strategy

- Check module and component import graphs for cycles without `.hs-boot`
  workarounds, verify the two-facade private seam in Cabal, and count physical
  lines across all production modules. Review each new module's stated purpose.
- Run affected foundation groups and existing external-client opacity/role tests.
  Especially preserve resource evidence ordering and inspection cost, worker
  helper/drain coordination, logging laziness/call sites, prepared payload and
  snapshot/channel ownership, and time overflow behavior.
- Use the validation planner to select required downstream builds/tests per
  implementation slice, including the mandatory floor. Source-compatible
  facades are not substitutes for consumer compilation.
- Keep tests deterministic and headless. No new desktop evidence is implied.
- All implementation docs, validation and required evidence travel in the
  implementation PR. No tests were run for this design-only proposal.

## Open questions

### Q-1. Accept or adjust the concrete layout and delivery slices

Resolved by D-4. The revised tree and six delivery slices are accepted.
No material design questions remain open. Exact issue acceptance commands and
fresh per-child deduplication belong to issue processing; they do not change
the accepted scope. No tracker artifact is created by this document.

## Cross-brand review disposition

Checked the supplied review against the same `9e2f033` source baseline. These
were revisions to the proposal at review time and are now accepted under D-4.

| Observation | Disposition |
| --- | --- |
| Unplaced worker helpers could force opposing imports | Accepted: explicit ownership/caller table added; single-worker draining is below Startup and Group. The claimed Observation call to `describeSummary` is inaccurate; its sole consumer remains Evidence. |
| Small families do not all need Base plus Types | Accepted in part: removed separate Base modules from Recovery, Time, Channel, Snapshot and Collection; retained their owner-local Types for the owner's organization preference. Removed Resource.Base as well. Added estimated final sizes for the entire tree and concrete consumers for each retained Base. No arbitrary minimum-size rule. |
| Cabal should enforce the private seam | Accepted: only the two existing private facades remain exposed; all extracted private implementation modules use other-modules. The review's three-test-import wording includes negative external-client source strings; those are not successful imports. |
| Resource identity has two apparent owners | Accepted: Cleanup owns the cleanup identity type, evidence and counter together; release ranks go in Resource.Types. |
| Epic completion needs stronger architectural criteria | Accepted: all foundation production files below 600, acyclic module/component graphs without boot files, concrete module purposes, preserved contracts and visibility, plus an accurate README module map. |
| Messaging helper name should be specific | Accepted: renamed the proposed module to Messaging.Component. |
| Split source roots need discoverability | Accepted: every implementation slice updates the foundation README's module-to-path/component/visibility map. |
| Explain FMO-3's dependency on FMO-2 | Accepted: worker implementations need the new Scoped/Cleanup owning modules before replacing the old Resource.Internal imports within the private component. |
| FMO-4 combines unrelated families | Accepted: FMO-4 now covers recovery; new FMO-5 and FMO-6 cover time and messaging. D-4 accepts these independently reviewable boundaries. |

## Delivery plan

### FMO-1. Separate logging and failure data from their operations

- **Outcome:** Logging is split below 600 lines per affected production file,
  and failure attribution consumes its small data contracts directly.
- **Scope:** Log and Failure families, visibility, README module map, contracts
  and relevant tests.
- **Phase:** Foundation data boundaries.
- **Depends on:** none.
- **Ordering:** can land first.
- **Relevant decisions:** D-1, D-2, D-3, D-4.
- **Acceptance signals:** Same logging/failure behavior and public API; hidden
  constructors/modules stay inaccessible; selected validation passes.
- **Out of scope:** Async runtime logging and new logging features.
- **Open questions:** None; Q-1 resolved by D-4.

### FMO-2. Separate resource representations and collection types

- **Outcome:** The private resource seam has explicit type and effect owners;
  collection-specific types sit under `Resource/Collection`.
- **Scope:** Resource and collection families, Cabal seam, README module map,
  contracts and tests.
- **Phase:** Foundational lifetime representations.
- **Depends on:** none.
- **Ordering:** independent of FMO-1 in code; shared Cabal/doc edits favor serial delivery.
- **Relevant decisions:** D-1, D-2, D-3, D-4.
- **Acceptance signals:** Unchanged cleanup evidence, opacity, release order,
  failure table and collection ownership; affected production files below 600 lines.
- **Out of scope:** New resource abstractions or altered masks and lifetimes.
- **Open questions:** None; Q-1 resolved by D-4.

### FMO-3. Separate worker data, requests, startup, observation and group lifetime

- **Outcome:** Worker internals have cohesive private modules and no oversized
  data or lifecycle implementation file.
- **Scope:** Worker private/public seam, README module map, contracts and
  worker/opacity tests.
- **Phase:** Concurrency ownership.
- **Depends on:** FMO-2.
- **Ordering:** after FMO-2 creates Resource.Scoped and Resource.Cleanup. Worker
  implementations then import those owning modules directly inside the private
  component instead of importing Resource.Internal. Main-component consumers
  keep using the facade across the Cabal boundary.
- **Relevant decisions:** D-1, D-2, D-3, D-4.
- **Acceptance signals:** Startup/cancellation/drain/retirement behavior and
  probe privacy preserved; affected production files below 600 lines.
- **Out of scope:** Runtime supervision policy and forced worker shutdown.
- **Open questions:** None; Q-1 resolved by D-4.

### FMO-4. Separate recovery policy and outcome types

- **Outcome:** Recovery owns its policy, outcome and history types under
  Recovery/Types while its existing recovery paths stay together.
- **Scope:** Recovery family, Cabal, README module map, contracts and recovery tests.
- **Phase:** Remaining foundation data boundaries.
- **Depends on:** FMO-1, FMO-2.
- **Ordering:** independent of FMO-3; ordered after it for serial delivery.
- **Relevant decisions:** D-1, D-2, D-3, D-4.
- **Acceptance signals:** Policy evaluation, rollback, cancellation and history
  behavior preserved; affected production modules below 600; consumers pass.
- **Out of scope:** A general retry framework, Time and Messaging.
- **Open questions:** None; Q-1 resolved by D-4.

### FMO-5. Separate time data and pure arithmetic from clock operations

- **Outcome:** Time.Types owns the compact data vocabulary and Time.Arithmetic
  has no clock effects or logging/failure-attribution dependency.
- **Scope:** Time family, Cabal, README module map, contracts and time/opacity tests.
- **Phase:** Remaining foundation data boundaries.
- **Depends on:** FMO-1.
- **Ordering:** independent of FMO-2 through FMO-4; serial delivery limits Cabal conflicts.
- **Relevant decisions:** D-1, D-2, D-3, D-4.
- **Acceptance signals:** Validation, rounding, overflow, clock failure context,
  sampling and opacity unchanged; affected modules below 600; consumers pass.
- **Out of scope:** New numerical policies, math package and runtime scheduling.
- **Open questions:** None; Q-1 resolved by D-4.

### FMO-6. Separate messaging types and give its component identity a common owner

- **Outcome:** Channel and Snapshot have local Types modules and both depend on
  Messaging.Component for the existing identity; Payload remains cohesive.
- **Scope:** Messaging family, Cabal, README module map, contracts and messaging tests.
- **Phase:** Complete foundation adoption.
- **Depends on:** FMO-1.
- **Ordering:** independent of FMO-2 through FMO-5; serial delivery limits Cabal conflicts.
- **Relevant decisions:** D-1, D-2, D-3, D-4.
- **Acceptance signals:** Endpoint/cursor opacity and nominal roles, evaluation,
  STM boundaries, queue counters and snapshot semantics preserved; public
  messagingComponent re-export unchanged; affected modules below 600; consumers pass.
- **Out of scope:** New transport abstractions, other packages and GPU-model decomposition.
- **Open questions:** None; Q-1 resolved by D-4.
