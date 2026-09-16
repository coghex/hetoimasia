# Component tests and shared fixture ownership

Organize Hspec tests around the engine's modular components, and retain expensive
graphics resources for the selected tests that can safely share them. Establish
the conventions now; implement them after the current CI and CPU resource work.

Design state: `ready for issue processing`

Owner: `coghex/hetoimasia`; publication target: `master`.
Drafted and reviewed 2026-09-11 against Hetoimasia
`b4ef301566259d5c43b7cca46cc366db50f73f2a`. The owner accepted the hierarchy,
fixture contracts, and sequencing, then requested final edits and readiness if
the review passed. The epic and TEST-1 have since been processed as #49 and #50;
TEST-1 is implemented. On 2026-09-14 the owner assigned TEST-2 to GLFW-7 and
settled its thread model (D-7 below). The owner authorized final review and
readiness of this revision alongside the GLFW design on 2026-09-14; the review
passed. Historical source observations below describe their recorded revision,
not current master.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Establish component-owned tests and scoped shared fixtures — [#49]
- [x] TEST-1. Split the headless engine suite into component specs — [#50]
- [x] TEST-2. Add a shared fixture for the first concrete graphics suite — [#93]

The ledger records issue processing, not implementation completion. TEST-1/#50
merged through PR #51. TEST-2's single implementation, GLFW-7/#93, merged through
PR #107 with its shared native fixture and platform gates. Review at `727f59a`
found a repeated-cancellation teardown defect now tracked as #118. Epic #49
remains open; its TEST-2 checkbox still needs reconciliation with the merge,
and completion must account for the outstanding repair.

## Epic contract

- **Goal:** developers can find and run a component's tests independently, while
  compatible graphics examples reuse expensive infrastructure safely.
- **Done when:** the headless suite has component-owned specs with its coverage
  preserved, and the first graphics suite demonstrates shared acquisition,
  isolated example state, and correct teardown through production resource APIs.
- **Users and operators:** engine developers, CI, and future periodic testers.
- **Arc label:** none proposed.
- **Scope:** test organization, fixture ownership, focused execution, and the
  associated Cabal/catalog/documentation wiring.
- **Out of scope:** implementing the graphics backend, replacing CI selection,
  integrating `test`/`autotest`, introducing a generic fixture framework, or
  reopening the completed logging implementation.

## Current implementation

At `master@727f59a`, component-owned engine tests and the separate native GLFW
suite are implemented. The fixture acquires one session lazily on the process
main thread and dispatches operations from the Hspec borrower. Linux X11 runs
remotely when affected; Cocoa runs locally. GPU fixtures remain future Vulkan
work. See [glfw.md](glfw.md#the-native-suite) for current instructions and
[the review](project_review_114-101.md) for #118's reproduced lifetime defect.

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

## Implementation proposals

### P-1. Keep the first refactor small

Proposed headless source layout; names below describe test modules:

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

## Open questions

### Q-1. What does the first concrete graphics fixture require?

Resolved by D-7 and GLFW design D-14. The first concrete fixture owns a GLFW
session and scoped NoAPI windows with the selected main-thread dispatcher.
It has no Vulkan instance/device or GPU work. GLFW-7 delivers this outcome
after GLFW-1/GLFW-2; the later Vulkan arc specifies its distinct GPU fixture.
Do not file another TEST-2 issue or invent GPU completion to unblock GLFW.

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

## Processing handoff

Processing is complete: #49, #50, and existing issue #93 are linked. Both
implementation children have merged. Do not recreate TEST-2 or reopen its
thread-model decision.

The remaining fixture work is repair #118, with code, regressions, contracts,
and evidence in its own PR. Reconcile the epic's implementation checkbox with
PR #107 and retain the repair as outstanding until verified. Vulkan owns future
GPU fixtures and GPU-completion evidence separately.
