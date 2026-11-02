# Gameplay-state example design

Design one small visible game consumer of engine-held, Lua-defined state.
The owner refines this design directly with the designer; this document does
not authorize implementation or tracker creation.

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Deliver one visible Lua-defined gameplay-state example

No delivery slices yet. Consumer selection and the remaining state contracts
precede decomposition. No epic or issues have been drafted or created.

## Epic contract

- **Goal (owner direction):** one small interactive game example where Lua
  defines its state, the engine owns storage, commit timing and lifetime, and
  the result is visible on screen. Input in the first version is undecided.
- **Done when:** open pending Q-1/Q-2 and the state/verification choices below;
  a running window alone cannot establish the state contract.
- **Users and operators:** the game author using narrow engine services, and
  the person running the example through the generic application.
- **Arc label:** None proposed.

## Current state and evidence

Evidence baseline: `coghex/hetoimasia`, `origin/master` at
`868b78e55765bb1d2d91ad8c29f23c7c364dde52`, inspected 2026-11-02 UTC.
All file:line references below describe that revision, not an implementation
branch. Historical decisions are distinguished from delivered capabilities.
The previous design may move to `docs/archive/`; its immutable baseline is
[lua_first_engine_design.md at 868b78e5](https://github.com/coghex/hetoimasia/blob/868b78e55765bb1d2d91ad8c29f23c7c364dde52/docs/designs/lua_first_engine_design.md).

| Verified fact | Evidence at the baseline |
| --- | --- |
| V-1 specifies a reusable engine, Lua-authored games and engine-held, Lua-defined future gameplay state. M1 deliberately omitted that store. | `docs/vision.md:14–30` |
| The guide recommends this next discussion, with consumer and input choices before slices. Its M1 verdict is bounded; it does not approve this arc. | `docs/guide/2026-11-01T234207Z-ef1b9ad.md:44`, `:104–110` |
| The generic full-product launcher assembles services from a content folder. Selected role VMs evaluate content independently; the normal composition has one root per selected role. | `docs/run_command.md:3–21`, `:55–84` |
| The shipped quad's gameplay update is empty; presentation opens the window, loads the image and publishes a scene. | `samples/lua-quad/content/lua/main.lua:6–16`, `:35–69` |
| M1's state call latches terminal failure, prints unavailability and raises. No create/query/schema/store API exists. | `packages/lua-engine/README.md:1611–1634`; binding implementation `packages/lua-engine/facade/Hetoimasia/LuaEngine/Facade/Session.hs:71–108` |
| The session already coordinates startup, fixed logical grants and tick accounting, but supplies no world. Accounting is not yet a state commit protocol. | `packages/lua-engine/README.md:1303–1329`, `:1351–1360` |
| Scene publication has its own atomic acceptance, adoption and completion-safe texture lifetime. Those facts are distinct from gameplay state publication. | `packages/lua-engine-graphics/README.md:395–445` |
| VM owners are general, independent, runtime-created primitives; the game's two roles are one composition. An owned VM is accessed only by its execution owner. | `docs/lua_runtime_design.md:606–622`; `packages/scripting-lua/README.md:535–554` |
| Trusted in-process Lua, protected lifetime and the application-level quit-watchdog permission remain established direction. The watchdog permission does not imply a timer is already implemented by the launcher. | `MEMORY.md:38–51`; `docs/vision.md:61–74`, `:179–210`; existing signal behavior `docs/run_command.md:99–106` |
| The foundation design is architectural context with an explicitly dated 2026-09-28 inventory. Its old absence-of-rendering claims are not the current product inventory. | `docs/engine_foundation_design.md:17–38`, `:61–94`; current launcher and graphics contracts above |

Tracker overlap check on 2026-11-02 UTC: all five open issues were inspected
by title (#446, #563, #584, #585, #586), with an all-state search for
`gameplay state`. No open umbrella for this arc was found. Closed #514 is M1;
closed #498/#499/#500 concern the older headless two-domain sample. This is an
initial overlap check, not final child-issue deduplication. Repeat at readiness.
Parallel reliability work remains with its assigned owners.

## Desired experience — proposal P-1, not approved

**Beacon:** one token reaches a visible target on a small board. Lua defines
the token position, target position and round counter and the rules for
advancing them. Presentation derives the visible token, target and progress
from committed engine-held state. Simple textured shapes could avoid adding
fonts, widgets or physics solely for this example. Exact rules, assets and
board dimensions are still proposals.

Recommend selecting this consumer before designing the API. It gives a small
observable state transition involving multiple values and a concrete reason
for coherent presentation. A bouncing token would need fewer rules but prove
less game authoring; a larger game would bring unrelated systems into scope.

Q-2 separately decides whether a person moves the token in v1 or an authored
sequence exercises the same rules. The latter is a staged demonstration,
not a claim of delivered player interaction. No input choice follows merely
from approval of the consumer.

## Scope

### In scope by owner direction

One named consumer; Lua-defined state; engine-owned storage, commit timing
and lifetime; visible consumption. Resolve identity, schema, mutation/read
visibility, failed ticks, snapshots, ownership and v1 input with the owner.

### Out of scope under this request

Mods, hostile-code confinement, hot swap, replay, #446 and broad performance
work, unless the owner explicitly expands the arc. No game-specific Haskell
in engine libraries. Save/load and schema migration are unresolved in Q-9;
the recommendation is to exclude them, not silently decide their scope.

## Design constraints and inherited decisions

### D-1. Design this narrow arc with the owner

Owner instruction relayed in request `user-het-epicclose-20261101-2340`,
explicitly invoked in this pane: design only, one question at a time, input
in v1 left for design. This is the only new scope decision recorded here.
The request's source is the manager's request prompt, read at startup; the
owner's direct answers in this pane govern subsequent design decisions.

### D-2. Preserve the prior state decisions without inventing delivery scope

The earlier design's D-41 deferred D-30–D-40 in full and explicitly preserved
them as owner decisions for a later arc (`docs/designs/lua_first_engine_design.md:1331–1371`).
They are neither implemented M1 capabilities nor new approvals in this session.
The following inherited constraints remain the design starting point; Q-3
settles what this first consumer must deliver. Do not reopen them without new
evidence or an owner request. Consult the original sections and their accepted
proposals before specifying exact contracts.

| Prior decision | Preserved choice | Original evidence |
| --- | --- | --- |
| D-30 | Stable engine-owned entities with Lua-defined, schema-checked named components; no physical layout selected. | `docs/designs/lua_first_engine_design.md:1019–1055` |
| D-31 | Bounded copied nested records, dense typed lists and text-key maps; no live Lua objects, code, cycles or native handles in state. | same file `:1057–1083` |
| D-32 | Namespaced schema registration during gameplay init, frozen before first published state; invalid/duplicate registration fails boot. | same file `:1085–1107` |
| D-33 | Successful staged writes are immediately visible to later gameplay reads; reads are copies; UI sees committed snapshots. Failed ticks publish no changes; Lua tables/resource effects are not rolled back. | same file `:1109–1131` |
| D-34 | Fixed FIFO gameplay with stable admission and assigned logical positions; a yield does not imply whole-hook completion. | same file `:1133–1158` |
| D-35 | Explicit future-tick/result checkpoints can finish a contribution; ordinary yields cannot. Commit needs positive completion/no-work and failure accounting; earlier committed ticks survive later failure. | same file `:1160–1189` |
| D-36 | Rejected authoritative mutations latch tick failure even if caught. Discard that tick; stop gameplay with last good snapshot and a healthy error UI; no automatic retry. | same file `:1191–1216` |
| D-37 | Non-owning, session-scoped entity references can outlive targets; absence is inspectable; references never retarget silently. | same file `:1218–1244` |
| D-38 | Trusted gameplay instances share value authority; schema namespaces are not write permissions. UI is snapshot-only. Mod activation remains outside this arc. | same file `:1246–1274` |
| D-39 | Whole-component copied replacement, atomically validated, with no implicit merge/version test. Stale copies remain the author's responsibility. | same file `:1276–1301` |
| D-40 | Queries return complete copied lists with fixed membership in stable entity-ID order. Over-budget queries refuse without truncation or automatically failing the tick. | same file `:1303–1329` |

Other standing constraints: narrow services and acyclic component boundaries;
explicit state owner/readers/writers/thread/lifetime/reset/disposal; actual
worker and GPU completion before release. Engine mechanisms support the
application's simulation/commit policy; they do not embed this game's rules.
Sources: `AGENTS.md`, `docs/engine_foundation_design.md:61–94`,
`docs/vision.md:15–32`, `:61–74`, and `:212–222`.

## Open questions

### Q-1. Which named consumer?

P-1 recommends Beacon. Approve or revise its player-visible purpose first.
This blocks dependent API design, concrete acceptance and slice decomposition.

### Q-2. Does v1 include minimal player input?

Open by explicit owner direction. Recommend a narrow keyboard movement path
if the owner wants v1 to be playable: it demonstrates input → logical state →
committed presentation. Its cost is an actual Lua-facing input bridge, bounded
delivery, focus/lost-input behavior and deterministic tick assignment, not
just polling a key. A scripted first version isolates the state contract and
reduces scope, but leaves player interaction for a later increment. M1 has no
input service (`docs/guide/2026-11-01T234207Z-ef1b9ad.md:44`); existing GLFW
input alone does not supply that Lua/commit contract.

### Q-3. Which preserved state facilities ship in this first version?

D-30–D-40 define the intended semantics; decide the first consumer's required
subset and any deliberately deferred facilities explicitly. Set concrete
entity/schema/container/query/working-state/snapshot bounds, identity encoding,
type vocabulary, exact operations and phase rules. Do not infer that the
small consumer either cancels prior choices or activates all deferred work.

### Q-4. How is the initial state built and first published?

The old Q-5l was withdrawn without choosing an initial-world policy
(`docs/designs/lua_first_engine_design.md:8581–8585`). Decide init writes,
schema freeze, startup failure and what presentation can read before the first
successful publication. Existing concurrent init/start gates must be reconciled.

### Q-5. What exactly completes or rejects a tick?

Retain D-33–D-36. Define the actual completion/accounting boundary, checkpoint
API, due-result/input ordering, late work, pause/stop dispositions, diagnostics
and failure visibility. No scheduler-empty shortcut and no automatic rollback
of arbitrary Lua locals or service effects. Decide the visible error behavior.

### Q-6. How does presentation acquire a coherent snapshot?

Decide version/identity, acquisition granularity, consistency across separate
reads, retention/bounds, skipped presentation revisions, stale references and
copy/handle lifetime. A UI segment and a whole suspended hook are different
possible scopes; do not silently choose one. Keep gameplay publication distinct
from scene acceptance, adoption and GPU completion.

### Q-7. Who owns each piece of state through reset and disposal?

Before a design is ready, name owner, readers, writers, thread, lifetime,
reset and disposal for schema catalog, identities, working state, committed
state, snapshot views, failure latch and any input staging. Determine which
scope survives logical-role failure and releases only after every borrower
has finished. Preserve general VM ownership; no hard-coded engine-wide pair,
universal environment or synchronous cross-VM entry.

### Q-8. What determinism and evidence does this consumer qualify?

The standing requirement is identical gameplay results for identical initial
state/content/seed/tick-assigned inputs/configuration on the same build and
supported platform (`docs/vision.md:212–222`). Decide the exact state comparison,
input fixture and scheduling perturbations, and whether randomness is needed
at all. A qualification must not silently add replay or claim cross-platform
identity. Exact acceptance remains open.

### Q-9. Compatibility, persistence and migration boundaries?

Recommend an in-memory session-only consumer with no save/load, schema
migration or reset-in-place in v1. Decide this explicitly. Also decide how the
new service relates to M1's callable unavailable-state guard, existing manifest
and shipped quad, public bindings and existing tests; do not silently replace
an existing contract. Saved-game schemas remain game-owned.

## Verification strategy — proposal, not acceptance criteria yet

Use focused Hspec tests for schema/identity limits, copied-value isolation,
read-after-write, all-or-nothing tick publication and failure latching even
when Lua catches an error. Use causally gated real-VM integration tests for
snapshot coherence, late work and ownership through failure/stop. Add only
the input cases the owner includes. No sleeps as concurrency proof.

Capture independently checked offscreen output and actual windowed consumer
evidence for the visible state transitions; a headless pass proves no image.
Keep Linux/macOS evidence and limitations separate. Select validation groups
from `tools/validation/catalog.json` through its planner once slices exist.
These are proposals applying `AGENTS.md` and `docs/vision.md:244–263`, not a
request to run tests or open windows during design.

Before implementation review, map each new handoff from admission through
tracking, issuance and publication to actual terminal evidence, naming its
owner and borrowed dependencies. Include early/repeated cancellation,
combined primary/cleanup failure and completion/publication races where
applicable; include test helpers. This follows the guide's concrete lesson
(`docs/guide/2026-11-01T234207Z-ef1b9ad.md:80`).

## Delivery plan

Zero slices. Blocked on owner design choices, beginning with Q-1. Once the
behavior and boundaries are settled, add one-PR outcomes with stable `GST-N`
IDs and mirror them in Processing status in dependency order. Do not draft
issue bodies or mark this design ready while these choices remain unresolved.
