# Component tests and shared fixture ownership

Own Hspec tests beside the packages whose contracts they exercise, keep root
application and tooling tests independently runnable, and retain expensive
graphics resources only for selected examples that can safely share them.
The original grouping and native-fixture phases are implemented; the next phase
moves the remaining central engine tests into package-owned Cabal suites.

Design state: `ready for issue processing`

Owner: `coghex/hetoimasia`; publication target: `master`.
Drafted and reviewed 2026-09-11 against Hetoimasia
`b4ef301566259d5c43b7cca46cc366db50f73f2a`. The owner accepted the hierarchy,
fixture contracts, and sequencing, then requested final edits and readiness if
the review passed. The epic and TEST-1 have since been processed as #49 and #50;
TEST-1 is implemented. On 2026-09-14 the owner assigned TEST-2 to GLFW-7 and
settled its thread model (D-7 below). The owner authorized final review and
readiness of this revision alongside the GLFW design on 2026-09-14; the review
passed. On 2026-09-16 the owner requested package-owned suites alongside root
and tools tests (D-8), then authorized final review and readiness signoff.
That review is complete for TEST-3 through TEST-6 under D-10; it does not reopen
completed TEST-1/TEST-2.
Historical source observations below describe their recorded revision, not
current master.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Establish component-owned tests and scoped shared fixtures — [#49]
- [x] TEST-1. Split the headless engine suite into component specs — [#50]
- [x] TEST-2. Add a shared fixture for the first concrete graphics suite — [#93]
- [x] TEST-3. Extract neutral support shared by independently built test suites — [#125]
- [x] TEST-4. Move foundation contracts into a foundation-owned suite — [#127]
- [x] TEST-5. Move runtime contracts into a runtime-owned suite — [#129]
- [x] TEST-6. Move GLFW headless coverage into a GLFW-owned suite — [#130]

The ledger records issue processing, not implementation completion. TEST-1/#50
merged through PR #51. TEST-2's single implementation, GLFW-7/#93, merged through
PR #107 with its shared native fixture and platform gates. Repair #118 merged
through PR #122; the subsequent review is recorded in
[project_review_122-119.md](project_review_122-119.md). On 2026-09-16 the owner
directly authorized the epic amendment: #49 now marks TEST-1/TEST-2 complete,
records the merged fixture repair, and includes TEST-3 through TEST-6 with the
reviewed ownership, dependency and validation contracts. The tracker edit was
verified; its title, `epic`/`tests` labels and open state are unchanged.
All children have since been filed and approved. TEST-3/#125 merged in PR #132
and TEST-4/#127 in PR #137. Epic #49's checklist was reconciled on 2026-09-17;
TEST-5/#129 and TEST-6/#130 remain open. Read each child's canonical approval
amendments as part of its implementation specification. No processing entry
remains in this document.

## Epic contract

- **Goal:** developers can find and run a component's tests independently, while
  compatible graphics examples reuse expensive infrastructure safely.
- **Done when:** foundation, runtime, and GLFW own separately runnable suites;
  root tests own application integration and tools retain their suite; every
  existing example is accounted for exactly once; package dependencies, focused
  selection, and CI coverage agree with that ownership. The first graphics
  suite retains shared acquisition, isolated example state, and correct teardown
  through production resource APIs.
- **Users and operators:** engine developers, CI, and future periodic testers.
- **Arc label:** existing `tests` label; reuse epic #49.
- **Scope:** test organization, fixture ownership, focused execution, and the
  associated Cabal/catalog/documentation wiring.
- **Out of scope:** implementing the graphics backend, replacing CI selection,
  integrating `test`/`autotest`, introducing a generic fixture framework, or
  reopening the completed logging implementation, changing production APIs,
  or reducing the mandatory validation floor as part of a structural move.

## Current implementation

Rechecked 2026-09-17 at `master@9300962`. These are source and tracker
observations, not a new test execution:

- Foundation now owns `foundation-tests`; runtime and GLFW headless suites
  still await TEST-5/TEST-6. Root `hetoimasia-tests` retains runtime, GLFW and
  console coverage plus the `glfw-window-examples` build tool. Hspec filtering
  chooses examples at execution time; it does not remove build dependencies.
- `Test.Engine.Runtime.Console` exercises the application. Conversely,
  `Test.Engine.Runtime.ResourceSmoke` exercises runtime's `resourceSmoke`, and
  `Test.Engine.Runtime.Messaging` now holds the six supervised channel/snapshot
  integration cases. TEST-5 moves these with their owning runtime contracts.
- Runtime, messaging, and GLFW opacity specs imported a compilation harness from
  `Test.Engine.Resources.Opacity`. Runtime also imported logging test helpers;
  console tests imported configuration values from a logging spec. TEST-3
  (#125) removed these coupling points: the harness and bounded wait now live in
  `hetoimasia-test-support` at `tools/test-support/`, runtime builds its own
  logger fixture, and the console spec states its own variable names.
- TEST-4 (#127) moved the foundation contracts into `foundation-tests` under
  `packages/foundation/test/`, registered as the floor group `test.foundation`
  on the existing `haskell-engine` worker, with the per-example mapping in
  [foundation_tests_mapping.md](foundation_tests_mapping.md). The console
  resource smoke and the six supervised Channel/Snapshot cases now sit under
  the root `Runtime` group for TEST-5. P-6's clean CPU-only check needed a
  `cabal.project.cpu` that imports the shared `cabal.project.common`; see
  [validation.md](validation.md#building-without-the-glfw-sdk).
- GLFW's `window-examples/` executable already owns the scripted window/host
  examples and can use private libraries. One root Hspec example launches it as
  a subprocess, obscuring its individual examples from root Hspec selection.
- `packages/glfw/native-tests/` already belongs to `glfw-native-tests`. It lazily
  acquires a main-thread session, dispatches from Hspec, and retains private
  lifecycle cases. Linux X11 runs remotely when affected; Cocoa runs locally.
  Keep this ownership and fixture contract; GPU fixtures remain future work.
- `workflow-tests` already owns `tools/test`. Catalog policy version 8 has
  `build.all`, `test.foundation`, `test.engine`, and `smoke.console` in its mandatory floor;
  `test.workflow` and `test.glfw-native` are non-optional affected groups. The
  workflow explicitly assigns group IDs to workers and publishes receipts.

Tracker recheck found open epic #49 and approved migration issues #129/#130.
Native-test consent #124 and monitor recovery #123 are merged; preserve their
behavior through the remaining test moves. See
[glfw.md](glfw.md#the-native-suite) for native-fixture instructions.

## Historical design evidence

Rechecked 2026-09-14 against `master@16cab02`: TEST-1 (#50) is closed, the
resource, runtime and messaging APIs exist, and no GLFW package exists yet.
The owner selected GLFW-7 in [the GLFW design](glfw_integration_design.md) as
TEST-2's implementation. Its adoption and existing-issue disposition subsequently
linked #93; TEST-1 was checked in the epic. D-7's thread model and Q-1 are
resolved. The historical no-GLFW observation is not the current state.

Inspected Hetoimasia at `b4ef301566259d5c43b7cca46cc366db50f73f2a` on
2026-09-11. These are source observations, not a new test execution:

- `test/Main.hs` combines the engine suite's 56 examples and its helpers. Its
  groups cover logging, configuration, runtime execution, and console startup.
- `hetoimasia.cabal` declares `hetoimasia-tests` with `main-is: Main.hs`, a
  `test` source root, and foundation/runtime dependencies. It needs no GPU or
  display. `workflow-tests` already has a separate `tools/test` source root.
- The implemented validation catalog has a stable `test.engine` group that
  invokes this suite. Component source inputs are derived from Cabal. CI work
  continues separately; this design must integrate with its landed contract.
- Resource ownership is specified in the
  [resource design](resource_ownership_design.md); its APIs are not implemented
  at this inspected revision. Graphics package directories are ownership notes.

Inspected Synarchy at `13bd01bdeb3043e0087b93adc90d67352a253bf0`; the following
files had no local changes. No Synarchy tests were run or files modified:

| Evidence | Lesson |
|---|---|
| [test/Spec.hs](https://github.com/coghex/synarchy/blob/13bd01bdeb3043e0087b93adc90d67352a253bf0/test/Spec.hs) | `withCreatedWindow` encloses the Hspec run, keeping GLFW and windows alive until their consumers finish. An example-local scope would terminate GLFW beneath later examples. |
| The same runner's headless-suite note | Window initialization happens before Hspec. Its graphics suite is compile-only in automated gates; GPU-free tests had to move to an independently runnable suite. |
| [Vulkan/Instance.hs](https://github.com/coghex/synarchy/blob/13bd01bdeb3043e0087b93adc90d67352a253bf0/test/Test/Engine/Graphics/Vulkan/Instance.hs), [Vulkan/Device.hs](https://github.com/coghex/synarchy/blob/13bd01bdeb3043e0087b93adc90d67352a253bf0/test/Test/Engine/Graphics/Vulkan/Device.hs) | Vulkan instances also have example-local scopes, including deliberate repeated create/destroy coverage. Shared GLFW lifetime does not mean every test shares one Vulkan instance. |

Retain the enclosing ownership scope and private lifecycle tests. Hetoimasia's
fixtures should pass narrow borrowed capabilities, following its existing
architecture rules, without importing Synarchy's EngineEnv/EngineState coupling.

The initial tracker check and readiness recheck on 2026-09-11 found the existing CI epic
[#8](https://github.com/coghex/hetoimasia/issues/8) and completed logging arc,
with no overlapping test-architecture issue or epic. The CI epic owns selection
and evidence handling; it does not own this component-spec refactor. Recheck
overlap before issue processing, especially against the
[foundation plan](engine_foundation_design.md).

## Decisions accepted by the owner

### D-1. Mirror component ownership in the test hierarchy

Use a small composition entry point and component-owned specs/helpers. The
conceptual Engine group contains Logging, Runtime/configuration/startup, and
Resources as they arrive. Future GLFW, Vulkan, rendering, and scripting specs
follow their owning components. This grouping does not create a new universal
Engine package or change production dependency direction.

### D-2. Share compatible infrastructure; isolate example state

Acquire expensive roots once for a selected compatible group in one process
invocation, lend them to its examples, and release them after all borrowers
finish. An instance, device, or window is shared only where the tests need it
and agree on its initialization requirements. Separate CI processes cannot
reuse these ordinary in-process handles.

Each example owns its temporary resources and mutable observations. Running a
single example must work without an earlier example initializing its state.
Creation/destruction tests, incompatible configurations, and tests that destroy
or invalidate shared roots use private fixtures. Sharing must not introduce
test-order dependencies or let one example's state contaminate another.

### D-3. Exercise production ownership and cleanup

Use the resource scope/composite-construction APIs delivered by the resource
arc. The fixture owner surrounds the entire borrower lifetime; each example
has shorter scopes for its own resources. Acquisition failure rolls back the
resources already owned. Teardown follows dependency order on normal return,
test failure, and cooperative cancellation, preserving primary and secondary
failure evidence under the existing resource policy.

Wait for relevant GPU work before reclaiming resources it still uses. CPU
scope exit alone proves no GPU completion. A graphics fixture must also join
its own outstanding work before its root scope exits. This is not a promise of
in-process cleanup after a hard process kill or driver failure.

The first GLFW-only fixture submits no GPU work and needs no GPU completion
operation. It must settle its assertion worker and dispatcher before releasing
native roots. Future Vulkan fixtures must prove actual GPU completion before
releasing resources used by submitted work; CPU fixture success is not that proof.

### D-4. Separate component grouping from execution requirements

Keep headless tests independently buildable and runnable without window/GPU
initialization or graphics dependencies. Pure backend decisions can also have
headless tests. Offscreen Vulkan tests may need a GPU without needing a window;
windowed tests have additional display and thread requirements.

Use separate Cabal suites/source roots where those requirements differ. A
single top-level Hspec tree must not force every engine test to acquire graphics
resources. Workflow tooling tests retain their separate suite.

For the package migration, the graphics-dependency exclusion applies to
foundation, runtime, and the current console-only root suite. A headless GLFW
suite may link GLFW and need its provisioned SDK without opening a display;
headless execution and native-library-free compilation are different promises.

Preserve GLFW's actual main-thread requirements for initialization, termination,
window creation/destruction, and event processing. Independent CPU specs may run
in parallel; shared mutable graphics operations need explicit synchronization
or serialization. Choose Hspec hooks and runner placement with thread ownership
in view, rather than assuming that a hook name establishes thread affinity.
See [GLFW's thread contract](https://www.glfw.org/docs/latest/intro_guide.html#thread_safety)
and [Hspec's execution model](https://hspec.github.io/parallel-spec-execution.html).

### D-5. Keep selection policy in the existing CI contract

The [CI design](ci_validation_design.md) decides which groups must run; fixture
ownership decides how selected examples execute. Preserve mandatory checks,
affected non-optional groups, and PR-requested groups. Optional tests remain
optional even when their fixture or shared dependency changes.

Sharing setup must not run unrequested optional examples. Batching compatible
selected groups may amortize setup, but must preserve each group's result and
declared inputs. Fixture helpers, configuration, and consumed assets are real
validation inputs. An unavailable requested environment, failed fixture, or
selection that unexpectedly matches no examples must not be reported as a pass.

Hspec remains the primary testing framework, including effectful integration
tests. Python probes require a boundary Hspec cannot reasonably exercise.
Periodic `test`/`autotest` integration remains deferred under the CI design.

### D-6. Document now; implement after CI and resource ownership

Historical sequencing for TEST-1; these prerequisites have since merged.

Finish the current CI work (CI-1 through CI-4) and CPU resource arc before
reorganizing this suite. Deferred CI-5 skill integration is not a prerequisite.
New resource tests may follow these grouping conventions immediately; they do
not depend on TEST-1 merging. TEST-1 then reorganizes the current suite, including
whatever resource coverage has landed. Concrete graphics fixtures wait for
their production interfaces and lifetime contracts.

### D-7. GLFW-7 fulfills TEST-2; Vulkan fixtures belong to the Vulkan arc

Accepted by the owner on 2026-09-14. Use GLFW-7 as the one implementation of the
first concrete shared native fixture, linked under both its GLFW epic and #49.
The executable's process main thread owns the production session and dispatches
native operations. Hspec assertions run in a controlled worker through a
test-only dispatcher. Verify native thread identity at setup, example operations
and teardown; failed or cancelled execution on either side settles the other.

Construct/select the spec tree before native acquisition. Compatible selected
examples share one session and, only where reset/isolation is established, an
ordinary window. Mutation, failure, incompatible configuration and lifecycle
examples use private windows; no example may terminate the shared session.
Use a separate GLFW supermodule/native suite; existing engine tests remain
independent. D-3 still governs rollback and borrower lifetimes.

GLFW-1/GLFW-2 must deliver the production APIs before implementation. They do
not gate recording this chosen thread model or drafting GLFW-7 with those
prerequisites. GLFW-7 owns Xvfb/window-manager setup, catalog/display-runner
support, native CI wiring, and its required tests and documentation. Its small
native Hspec group is non-optional and required when affected, outside the
mandatory floor; remote runs use Linux X11, local macOS runs use Cocoa.
Interactive/lengthy probes stay optional.

TEST-2 is fulfilled when GLFW-7 delivers the shared fixture and evidence; do not
leave an additional GPU requirement on #49. The later Vulkan arc owns its own
instance/device fixtures, sharing configuration and actual GPU-completion proof.

### D-8. Packages own their tests; root and tools retain their own suites

Accepted by the owner on 2026-09-16. Put a package's tests and local helpers in
that package directory, with a separately selectable Cabal test component.
Retain root tests for executable/application composition and integration owned
by the root package, alongside the existing tools suite. This extends D-1 from
logical grouping to physical ownership and supersedes P-1's central layout as
the long-term destination.

Ownership follows the contract under test, not the number of packages imported.
Runtime tests should exercise real foundation services; that does not make them
root tests. GLFW runtime-adapter tests belong with the adapter in the GLFW
package. Foundation tests must not acquire a dependency on runtime or GLFW.
Root tests must not re-register package specs merely to offer an aggregate run.

### D-9. Local native execution needs the human's explicit session approval

Retain the owner's accepted desktop policy: before opening native windows,
requesting focus, or manipulating fullscreen/display state locally, ask the
human user for explicit approval and wait for acceptance for that session.
Issue approval or a previous session's permission is not standing consent.
Isolated Linux X11 CI remains non-optional when affected. Issue #124 implements
the native opt-in guard; this migration preserves it and does not duplicate it.

### D-10. Approve the reviewed package migration and preserve required coverage

On 2026-09-16 the owner authorized final review and signoff of ready designs.
Review against `master@e2d30ea` and the open tracker found P-3 through P-6 ready:
four bounded migration slices, neutral test support, independent package suites,
root application ownership, unchanged native-fixture safety, and preservation
of effective mandatory coverage. These are the processing contracts. New suite
groups enter the existing floor as their examples leave the monolithic suite;
reducing that floor requires a separate policy decision.

Q-2 is resolved. This signs off the design for processing, not implementation.
The owner subsequently directly authorized amending existing epic #49, and
that amendment is complete. Each new child still receives separate approval.

## Design

### P-1. Keep the first refactor small

Historical TEST-1 proposal, now implemented with `Main.hs` retained as the entry
point. P-3 below specifies the new destination; this original proposal does not
require retaining a root aggregate suite or console tests under Runtime.

Original headless source layout; names below describe test modules:

```text
test/
  Spec.hs                         -- module Main: compose the suite
  Test/Engine/Spec.hs              -- compose the Engine group
  Test/Engine/Logging/Spec.hs
  Test/Engine/Runtime/Spec.hs
  Test/Engine/Resources/Spec.hs     -- once resource tests exist
```

Put helpers and further subdivisions beside their owning spec when useful.
Logging filter/parser/sink tests belong to Logging; application assembly and
console startup belong to Runtime. Avoid moving every helper into one shared
test environment. `Spec.hs` is an entry-point convention, not a lifetime feature.
Update Cabal's `main-is` and `other-modules` with the move.

Preserve `hetoimasia-tests` and the catalog's `test.engine` identity for this
refactor. Adding nested descriptions may change Hspec match paths: update and
verify the affected documented selectors in the same PR. Do not add a catalog
group for every file just to reflect the source tree.

Source moves, Cabal declarations, and fixture changes remain real validation
inputs even when assertions are unchanged. Follow the landed CI contract for
their required checks; do not classify this refactor as a prose-only update.

### P-2. Introduce graphics fixtures only with real consumers

The later graphics runner should compose the smallest existing production
scopes its selected specs need. Typed fixture values expose borrowed handles
or operations to the relevant component specs. D-7 selects the main-thread
owner/dispatcher with a controlled Hspec assertion worker for GLFW; use the
production resource scopes around that entire borrower lifetime.

Construct and select the spec tree without acquiring graphics resources.
Listing/discovery, dry runs, and runs selecting no graphics examples must not
initialize those fixtures. This preserves focused execution as well as avoiding
unnecessary setup; selecting no examples unexpectedly still follows D-5.

Document each fixture's owner, borrowers, initialization configuration, owning
thread, synchronization, reset behavior, and teardown prerequisites alongside
its implementation. Do not introduce a graphics-wide mutable TestEnv or a
fixture registry before concrete consumers justify an abstraction.

### P-3. Give each package an executable test boundary

Reviewed destination and suite identities under D-10:

| Owner and source root | Cabal suite | Contracts exercised |
|---|---|---|
| `packages/foundation/test/` | `foundation-tests` | Logging, failures, recovery, scoped resources/collections, workers, messaging primitives |
| `packages/runtime/test/` | `runtime-tests` | Application runner, reporting/logging lifetime, supervision, inbox services, runtime resource smoke and messaging composition |
| `packages/glfw/test/` | `glfw-tests` | Headless session/window/command/input/monitor models, runtime adapter, linking and public-interface opacity |
| `packages/glfw/native-tests/` | existing `glfw-native-tests` | Native thread/lifecycle/platform evidence through the existing fixture |
| root `test/` | existing `hetoimasia-tests` | Console entry point, configuration integration, exit behavior and application assembly |
| `tools/test/` | existing `workflow-tests` | Validation, receipts, image/display provisioning, review and workflow tooling |

Each suite has a small `Main.hs`, component spec composers, owner-local helpers,
and `fail-on-empty` behavior. Keep useful Hspec subgroup names and existing
selectors where ownership has not changed; document deliberate selector moves.
Do not create one Cabal suite or CI group per source file. No empty placeholder
suites for Vulkan or other future packages.

Foundation Channel/Snapshot examples using supervision move to runtime's
messaging integration specs; primitive transaction, payload, cursor and channel
contracts remain in foundation. Runtime's `resourceSmoke` coverage moves out of
the foundation resource group. Console tests remain at root even though they
use the runtime. Register each assertion once; importing lower-level services
does not require mocking them or repeating their own unit tests.

Move root GLFW Session/Linking/Opacity specs and the actual window-examples
specs into `glfw-tests`. Register those Hspec trees directly. Remove the root
subprocess wrapper and obsolete example executable/build-tool dependency after
checking their callers and updating their documented commands. Declare the
new suite's needed public/private component dependencies explicitly, including
components built for external-client compilation tests. Do not rely on the
removed executable incidentally registering a library in the package database.
Preserve public APIs, including the existing seam visibility, during this move.

Independent commands use fully qualified targets, for example
`cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct`
and `cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct`.
The same convention names `hetoimasia-glfw:glfw-tests`,
`hetoimasia:hetoimasia-tests`, and `hetoimasia:workflow-tests`.
Hspec `--match` still selects subgroups within the chosen suite.

Document explicit headless target lists for a whole-project CPU sweep. Do not
recommend an unrestricted `cabal test all` as a routine local command: it also
selects the native suite. Package ownership and execution environment are
separate axes; a package may own both CPU and native suites.

### P-4. Share utilities without sharing spec trees or private engine access

Extract the existing external-client compiler harness into a small repository
test-support library at `tools/test-support/` with package name
`hetoimasia-test-support`. Add only utilities already shared across suites,
such as a bounded test wait when useful. It contains no registered specs, engine
dependencies, native initialization, mutable global fixture, or production
service API. Production libraries and executables never depend on it. Its
sources belong to that component alone, not overlapping `hs-source-dirs`.

Keep domain-specific fixture construction beside its owning suite. For example,
foundation logging metadata fixtures stay local; runtime may construct its own
small logger fixture through the public logging API. A few simple fixture
values may be repeated rather than making one package depend on another
package's tests. Root console environment expectations must not import a
foundation configuration spec. Do not build a generic fixture framework to
eliminate trivial duplication.

Opacity examples still compile fresh external clients with an explicit allowed
package list and hidden defaults. Positive clients must compile/link/run, and
negative clients must fail for the intended constructor/module/field restriction,
not a missing package or source path. Moving an example inside a package grants
its test component access to private libraries; that component's own successful
compilation is not proof of the external-client boundary. Retain that distinction.

Tests must work under each owning package's working directory. Replace accidental
root-relative assumptions with explicit package/repository fixture locations;
include consumed files in Cabal source manifests and CI input declarations.
External-client package-database discovery must work for every new executable
and build directory, without picking a stale build from another worktree.

### P-5. Migrate CI coverage in the same PR as each suite

Preserve D-5 and the effective coverage of the current floor. Add `test.foundation`,
`test.runtime`, and `test.glfw` as their suites move; put each in the floor because
its coverage was previously mandatory inside `test.engine`. Keep `test.engine`
as the existing root-suite identity with an updated application-integration
description. Retain `build.all` and `smoke.console`. Narrowing this floor later
is a separate explicit policy decision, not an incidental consequence of moving
files. Independent local execution is available immediately; this design does
not promise lower CI execution counts while the same floor remains mandatory.

Keep `test.workflow` and `test.glfw-native` under their existing affected-group
policy. All new headless groups use the CPU runner; the native group keeps the
display runner. Existing optional probes remain optional. Suite independence
does not require one workflow job per suite: initially route new CPU groups to
the existing Haskell engine worker, keeping separate group results and receipts
without duplicating toolchain setup and cache restoration for every package.

Every migration PR must update Cabal membership, root registration, catalog
component targets/inputs, worker assignments, receipt publication/reuse, and
commands/authoring documentation together. No intermediate commit may remove
mandatory examples from the old suite without adding their destination to
required execution. The required aggregate status must account for every selected
group, including skipped workers with reusable evidence. Existing explicit
`test.engine` requests select root integration after migration; update callers
that intended the old whole-engine coverage to request the explicit group set.

Use the existing planner's component closure for source, helper, manifest, and
configuration inputs. New group identities and changed component/policy inputs
must invalidate incompatible receipts normally; never relabel an old monolithic
pass as several new suite passes. Extend existing workflow Hspec cases where
needed to prove new groups are assigned, executed or validly reused, and required
by the aggregate. Preserve documentation-only evidence reuse and image/cache
policy; the migration is not another CI framework rewrite.

### P-6. Preserve build independence and coordinate active work

A `--match` filter is insufficient evidence of dependency isolation. Verify
foundation and runtime targets from a clean CPU-only package selection with no
GLFW SDK or display. Once all migrations land, verify the root console suite
the same way. Cabal may configure other packages in a project even for a focused
target; if the ordinary project still requires GLFW discovery, provide a small
documented CPU project configuration that excludes the GLFW package and shares
the canonical compiler, bounds and index pins. Do not maintain divergent pins.
Each owning slice must demonstrate its promised boundary; TEST-6 completes the
final root check after removing the last root GLFW dependency.

GLFW's headless suite may still require the pinned native SDK for linking and
opacity checks. It must initialize no native session or display. Preserve all
required suite flags: in particular foundation's resource cost examples need
allocation statistics (`-T`), and concurrent suites need the threaded runtime.
Build and source-distribution manifests must include moved tests and fixtures.

The [timing design](runtime_scheduling_design.md) and
[graphics-lifetime design](window_graphics_lifetime_design.md) retain their proof
obligations. New tests follow their current package owner; whichever PR lands
later reconciles the paths and registrations against its actual base. This
migration is not a new prerequisite for either feature arc. TEST-4 and TEST-6
may be developed independently after TEST-3, but both edit root Cabal/catalog
wiring: stage their landings and reconcile that overlap before review. Keep
required documentation, example mapping, and validation evidence in each code
PR rather than landing them separately afterward.

## Open questions

### Q-1. What does the first concrete graphics fixture require?

Resolved by D-7 and GLFW design D-14. The first concrete fixture owns a GLFW
session and scoped NoAPI windows with the selected main-thread dispatcher.
It has no Vulkan instance/device or GPU work. GLFW-7 delivers this outcome
after GLFW-1/GLFW-2; the later Vulkan arc specifies its distinct GPU fixture.
Do not file another TEST-2 issue or invent GPU completion to unblock GLFW.

### Q-2. Is the package-migration plan ready for processing?

Resolved by D-10 after the owner's requested final review. P-3 through P-6
settle suite names, neutral test support, preservation of floor coverage, and
incremental delivery. No material question blocks TEST-3 through TEST-6.

## Verification strategy

For TEST-1, inventory the examples on the implementation base, preserve their
assertions and failure paths, build warning-clean, and run the reorganized suite.
The historical 56-example count is not a fixed target: include coverage added by
the resource work, and map moved examples to their new groups. A matching count
alone does not prove that no example was lost or registered twice.
Verify representative focused selections for each populated component return
real examples. Confirm the catalog still selects the engine suite for relevant
test/source changes and headless execution acquires no graphics resources.

For TEST-2, use Hspec and observable acquisition/release traces to verify the
harness adds exactly one shared acquisition and teardown around multiple
compatible examples, with no reliance on example order. Verify isolated reruns,
per-example disposal, private lifecycle fixtures, and failure/cancellation
unwinding at the harness boundary. Verify that discovery, dry runs, and selections
outside the graphics group acquire no graphics fixture. Use deterministic
coordination, not sleeps.
Existing resource primitive tests remain authoritative for their lower-level
contracts; native runs must separately demonstrate thread constraints and
teardown. The GLFW fixture proves worker/dispatcher completion; later Vulkan
fixtures must additionally prove actual GPU completion. Compile-only success
proves neither native lifecycle execution nor GPU execution.

For TEST-3 through TEST-6, inventory assertions from the implementation base
and map every moved example to its owning suite. Expand the old GLFW subprocess
wrapper into its underlying inventory: raw before/after root example counts
cannot establish equivalence. Keep failure and cancellation cases, positive and
negative client compilation, fixture isolation, RTS flags, and existing selector
semantics unless an ownership move requires a documented new path.

Run the changed headless suites, representative focused selections, deliberate
empty selections, and relevant workflow tests. Verify CPU package isolation,
warning-clean builds, Cabal/source manifests, package-relative fixture paths,
and external-client package discovery. Check catalog plans for foundation,
runtime, GLFW, tools, shared-helper and docs-only changes; confirm coverage and
receipt validity rather than testing only that a catalog entry exists. No
example is counted twice merely to preserve the old root grouping.

Relocation alone does not authorize local native execution. Preserve the native
fixture and its isolation/approval guards; use the existing affected Linux gate
when selected. Any needed local Cocoa run follows D-9 with explicit session
approval. #124 remains the guard implementation owner, including if its PR
lands before this migration. No Python probe is needed to prove a source move.

## Delivery plan

### TEST-1. Split the headless engine suite into component specs

- **Outcome:** a small entry point and independently selectable Engine subgroups
  preserve the suite's current behavior and coverage.
- **Scope:** test moves, local helper ownership, Cabal declarations, necessary
  selector/catalog wiring, and the required test-authoring instructions.
- **Phase:** after the current CI and CPU resource work.
- **Depends on:** none within this document.
- **External implementation gates:** CI-1 through CI-4 (#10 through #13) and
  RES-1 through RES-4 must have merged. Resolve the resource tracker references
  before approving this issue for implementation; reuse its existing arc.
- **Ordering:** first implementation in this document; not a prerequisite for
  writing resource tests or completing either existing arc.
- **Relevant decisions:** D-1, D-4, D-5, D-6.
- **Acceptance signals:** preserved example inventory, passing suite, meaningful
  focused selections, warning-clean build, and correct validation selection.
- **Out of scope:** logging behavior changes, resource API changes, graphics
  dependencies, or speculative empty spec modules.
- **Open questions:** none blocking; P-1 is the proposed file organization.

### TEST-2. Add a shared fixture for the first concrete graphics suite

> Linked to #93 (GLFW-7) on 2026-09-14 as an existing issue; no second
> implementation is filed.

- **Outcome:** compatible tests of the first available backend share expensive
  roots safely while retaining independent examples and private lifecycle tests.
- **Scope:** one bounded fixture integration, its owning suite, harness coverage,
  catalog declaration, and ownership/run instructions in the same PR.
- **Phase:** shared native verification, delivered through GLFW-7.
- **Depends on:** TEST-1.
- **External gates:** GLFW-1/GLFW-2 before implementation. Q-1 is settled by D-7;
  draft/link the single GLFW-7 issue through the GLFW design's processor.
- **Ordering:** owned by GLFW-7; this slice does not authorize building the backend.
- **Relevant decisions:** D-1 through D-7.
- **Acceptance signals:** the harness and real-backend evidence described above,
  accurate selected-group results, and independent headless execution.
- **Out of scope:** a general fixture framework, cross-process handle reuse,
  scheduler integration, Vulkan fixtures/GPU completion implementation, or
  implementing unrelated graphics features.
- **Open questions:** none.

### TEST-3. Extract neutral support shared by independently built test suites

> Linked to #125 on 2026-09-17 as a new issue.

- **Outcome:** existing root specs use a reusable test-only compiler harness
  without importing it from a resource spec.
- **Scope:** P-4's minimal support package, project registration, current client
  rewiring, removal of spec-to-spec helper imports that obstruct the split,
  and required manifests, input tracking and documentation.
- **Phase:** package ownership preparation.
- **Depends on:** TEST-1.
- **Ordering:** first new slice; foundation and GLFW migration can follow it.
- **Relevant decisions:** D-1, D-4, D-5, D-8, D-10.
- **Acceptance signals:** current suites preserve their assertions; external
  clients still prove positive use and intended negative failures; the support
  library depends on no engine package, and production depends on no test support.
- **Out of scope:** relocating whole suites, changing APIs, generic fixture
  machinery, or changing the mandatory floor.
- **Open questions:** None.

### TEST-4. Move foundation contracts into a foundation-owned suite

> Linked to #127 on 2026-09-17 as a new issue.

- **Outcome:** `foundation-tests` owns foundation contracts and runs without
  runtime or GLFW dependencies.
- **Scope:** foundation specs/local helpers, Cabal component and runtime flags;
  split supervised messaging cases and runtime resource smoke from primitive
  coverage, retaining them in the current root runtime group until TEST-5;
  add `test.foundation` and all P-5 wiring in this PR.
- **Phase:** package ownership migration.
- **Depends on:** TEST-3.
- **Ordering:** precedes runtime migration; may develop beside TEST-6 with
  coordinated root/catalog edits.
- **Relevant decisions:** D-1, D-4, D-5, D-8, D-10.
- **Acceptance signals:** mapped foundation examples run exactly once under the
  new suite; root retains every not-yet-moved example; focused and empty
  selection behave correctly; external clients, allocation statistics, clean
  CPU build independence and required-group routing are verified.
- **Out of scope:** runtime suite creation, production resource changes, and
  reducing CI coverage.
- **Open questions:** None.

### TEST-5. Move runtime contracts into a runtime-owned suite

> Linked to #129 on 2026-09-17 as a new issue.

- **Outcome:** `runtime-tests` owns runtime behavior and composition with real
  foundation services, while root retains console/application integration.
- **Scope:** runtime specs/helpers, resource smoke and supervised messaging
  cases; root Console grouping and its independent helpers; `test.runtime`,
  Cabal declarations, all P-5 wiring and revised ownership/run instructions.
- **Phase:** package ownership migration.
- **Depends on:** TEST-4.
- **Ordering:** follows the primitive/integration split; can develop beside
  TEST-6 with coordinated root/catalog edits.
- **Relevant decisions:** D-1, D-4, D-5, D-8, D-10.
- **Acceptance signals:** runtime suite builds/runs without GLFW or console
  executable dependencies; root executable integration still passes; complete
  assertion mapping, external clients, focused/empty selection and required
  routing are verified. If TEST-6 has not landed, its GLFW coverage remains
  registered at root until that move.
- **Out of scope:** runtime API/lifecycle changes, native fixtures, and copying
  runtime specs into root to preserve an aggregate test executable.
- **Open questions:** None.

### TEST-6. Move GLFW headless coverage into a GLFW-owned suite

> Linked to #130 on 2026-09-17 as a new issue.

- **Outcome:** `glfw-tests` directly selects all headless GLFW examples beside
  the existing native suite; the root suite no longer depends on GLFW.
- **Scope:** P-3's direct Hspec registration, moved Session/Linking/Opacity specs,
  explicit private/public component dependencies, package-relative fixtures,
  removal of the obsolete subprocess wrapper/build tool, `test.glfw` and all
  P-5 wiring. Complete the CPU-only root verification/profile from P-6 and
  update the suite matrix to reflect the slices landed at that point.
- **Phase:** package ownership migration.
- **Depends on:** TEST-3.
- **Ordering:** independent of TEST-4/TEST-5 after support extraction; coordinate
  shared root/catalog edits before landing. If it lands first, the root suite
  still temporarily contains their CPU-only examples.
- **Relevant decisions:** D-1 through D-5, D-7, D-8, D-9, D-10.
- **Acceptance signals:** model examples are individually discoverable and
  selectable without launching GLFW; external-client opacity and native link
  manifest checks still work from the package; no wrapper duplication or lost
  coverage; all target/receipt routing passes; final root suite builds/runs
  without GLFW. Existing native fixture/guard contracts remain intact.
- **Out of scope:** changing seam visibility, native fixture redesign, #123/#124
  implementation, Vulkan tests, timing/lifetime feature implementation or new
  local desktop authorization.
- **Open questions:** None.

## Processing handoff

The original phase is processed: #49, #50, and existing issue #93 are linked;
both implementation children and fixture repair #118 have merged. Preserve
those IDs and their completed contracts. Vulkan owns GPU fixtures and actual
GPU-completion evidence separately.

Readiness is signed off, and the owner-directed amendment of epic #49 is
complete and verified on 2026-09-16. Its checklist retains completed
TEST-1/TEST-2, accounts for PRs #51/#107/#122, and adds the package-ownership
phase and its done conditions. Do not repeat the epic amendment, create a
duplicate epic, or repurpose closed issues #50/#93.

The next invocation selects TEST-3. Process TEST-3 through TEST-6 one child at a
time, with separate child approval, rechecking tracker overlap and the current
source layout. Their four ledger entries remain unchecked until linked to
actual issues. Issue #124 remains the independent native opt-in guard; do not
draft another issue for it here.

Recommended document processing order: this package-test extension, then
`runtime_scheduling_design.md`, then `window_graphics_lifetime_design.md`.
Test ownership comes first to reduce test-file churn; it is not a new hard
dependency for TIME/LIFE. Scheduling must supply the tracker references for
LIFE-3/LIFE-4's external gates. The Vulkan design remains exploring until its
capability, completion and platform-verification choices are settled.
