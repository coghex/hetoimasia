# Component tests and shared fixture ownership

Organize Hspec tests around the engine's modular components, and retain expensive
graphics resources for the selected tests that can safely share them. Establish
the conventions now; implement them after the current CI and CPU resource work.

Design state: `ready for issue processing`

Owner: `coghex/hetoimasia`; publication target: `master`.
Drafted and reviewed 2026-09-11 against Hetoimasia
`b4ef301566259d5c43b7cca46cc366db50f73f2a`. The owner accepted the hierarchy,
fixture contracts, and sequencing, then requested final edits and readiness if
the review passed. The epic and TEST-1 are ready for drafting; TEST-2 retains its
explicit design gate. This document remains local and unpublished.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Establish component-owned tests and scoped shared fixtures
- [ ] TEST-1. Split the headless engine suite into component specs
- [ ] TEST-2. Add a shared fixture for the first concrete graphics suite — [deferred]: production graphics interfaces exist and Q-1 is settled with the owner

The ledger records issue processing, not implementation completion. A linked
issue does not satisfy a requirement that its implementation has merged.

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

## Current state and evidence

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
or operations to the relevant component specs. This may use Hspec hooks or an
explicit scope around the graphics runner; the concrete choice remains Q-1.

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

Deliberately deferred; blocks TEST-2 only. Once the backend/window interfaces
exist, identify the first compatible examples, required instance/device/window
configuration, actual thread model, and GPU completion operations. Then choose
the narrow context, suite placement, and Hspec integration using those APIs.
Review those choices with the owner before processing TEST-2. Do not invent
backend capabilities or duplicate their implementation to unblock this design.

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
contracts; graphics runs must separately demonstrate actual backend completion,
thread constraints, and teardown. Compile-only success proves no GPU execution.

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

- **Outcome:** compatible tests of the first available backend share expensive
  roots safely while retaining independent examples and private lifecycle tests.
- **Scope:** one bounded fixture integration, its owning suite, harness coverage,
  catalog declaration, and ownership/run instructions in the same PR.
- **Phase:** deferred until concrete graphics interfaces exist and Q-1 is settled.
- **Depends on:** TEST-1.
- **External gates:** the relevant production backend/ownership APIs exist and
  Q-1 is settled with the owner before this child is drafted.
- **Ordering:** later; this slice does not authorize building the backend.
- **Relevant decisions:** D-1 through D-6.
- **Acceptance signals:** the harness and real-backend evidence described above,
  accurate selected-group results, and independent headless execution.
- **Out of scope:** a general fixture framework, cross-process handle reuse,
  scheduler integration, or implementing unrelated graphics features.
- **Open questions:** Q-1; settle before drafting this implementation issue.

## Processing handoff

The two delivery slices above are ready within their stated gates; no issues
have been filed for them. Process EPIC first, then exactly one eligible child per
invocation, with separate approval for each tracker artifact. TEST-1 can be
drafted while its external work continues, but cannot be solved before those
implementations merge. Deferred CI-5 does not block it.

Keep TEST-2 deferred until its production interfaces and owner-approved Q-1
choices exist; return to this design to record those choices and review that
slice before processing it. Do not silently choose a fixture/thread model or
draft a placeholder implementation issue. The epic's full completion still
requires the graphics outcome; TEST-1 alone does not complete it.

Recheck the foundation arc before processing TEST-2: if its first graphics PR
already owns this exact fixture outcome, link that work rather than create a
duplicate. Required code, tests, contracts, and evidence travel together in each
implementation PR.
