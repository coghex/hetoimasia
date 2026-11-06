# Terrain arena design

Begin recreating Ecce Homo on Hetoimasia with flat terrain and on-demand
chunk loading. Synarchy's testing arena is the concrete reference. The owner
chooses behavior in this design conversation; existing Synarchy implementation
choices are evidence, not automatically requirements for the new engine.

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Establish Ecce Homo's flat terrain with on-demand chunk loading

No delivery slices yet; material choices below remain open. This is design
only. No tracker items or implementation are authorized by this document.

## Epic contract

- **Goal:** a real first terrain foundation for Ecce Homo: flat terrain,
  loaded by chunk demand, with the engine/game boundary preserved.
- **Done when:** open; agree the terrain model, loading/lifetime contract,
  visible result, controls and acceptance evidence before defining slices.
- **Users and operators:** the owner developing Ecce Homo, game authors using
  engine services, and later players of the recreated game.
- **Arc label:** None proposed.

## Current state and evidence

Inspected 2026-11-06. Hetoimasia evidence is `origin/master` at
`edd82f8e0aa8fd71edddd183b105dbac413fdeff` in `coghex/hetoimasia`;
Synarchy evidence is its clean current checkout at
`3777d437ea00e1302bf55162ad5693fee4879187`, `~/work/synarchy`.
Prefixes H and S below distinguish those repositories. File:line references
are pinned to these revisions. Synarchy has not been modified or launched.

| Verified current fact | Evidence |
| --- | --- |
| Synarchy contains both its engine and Ecce Homo, a colony/survival game. | S `README.md:3` |
| Terrain chunks contain 16 × 16 vertical columns with material, slope and vegetation data. | S `src/World/Chunk/Types.hs:72–94` |
| One arena generator supplies initial chunks, demand loading and reconstruction. Each base column has twelve granite cells below four loam cells, a flat top and seeded surface vegetation variants; fluids, flora instances and structures begin empty. | S `src/World/Generate/Arena.hs:2–33`, `:126–149`, `:212–232` |
| The default arena starts with 5 × 5 chunks and expands on demand; that startup footprint is not a world boundary. | S `scripts/test_arena.lua:188–207`; `src/World/Generate/Arena.hs:70–104` |
| Arena topology does not wrap. A caller may request finite dimensions; larger finite arenas also load their remaining chunks on demand, with absent cells outside their rectangle. | S `docs/engine_contracts.md:8200–8246` |
| Arena controls include zoom, rotation and vertical slice selection; these are existing reference behaviors, not yet this arc's scope. | S `scripts/test_arena.lua:255–293` |
| Geological hydrology, settled-terrain processing, chunk composition and runtime fluid simulation are separate stages. Flat generation can avoid the geological work. | S `docs/hydrology_pipeline.md:24–43` |
| Hetoimasia's reusable renderer has world/UI views, cameras, depth, retained chunks and application materials. M1's Lua scene exposes only simple rectangles with a fixed camera, default material and one UI layer. | H `packages/render-2d/README.md:3–17`, `:59–69`; `packages/lua-engine/README.md:941–968`, `:1002–1011` |
| GLFW already supplies ordered input with explicit reset/acknowledgement, but the M1 Lua facade has no input binding. | H `packages/glfw/src/Hetoimasia/GLFW/Input.hs:1–26`; `packages/lua-engine/README.md:1042–1057`, `:1086–1101` |
| Scene acceptance, adoption and GPU completion are separate ownership facts. Terrain residency must not bypass those obligations. | H `packages/lua-engine-graphics/README.md:416–447` |
| Text/fonts are a separately selected future arc; beginning terrain does not automatically activate the full UI system. | H `docs/designs/render_2d_design.md:301–319` |
| M1 supplies no working gameplay-state store. The earlier example leaves schema, initial publication, tick failure, snapshots, ownership, determinism and compatibility open. | H `packages/lua-engine/README.md:1611–1634`; `docs/designs/gameplay_state_design.md:155–212` |

Initial tracker overlap check, 2026-11-06: the open issue list contains #446
and #563; an all-state `terrain arena` title/body search returned no match.
No existing open terrain umbrella was found. Repeat at readiness; this is not
final per-slice deduplication. Synarchy's own terrain trackers are references,
not Hetoimasia delivery items.

## Desired experience and scope

**Accepted direction:** begin terrain for Ecce Homo using flat arena terrain
and demand-driven chunk loading. Procedural elevation generation is deferred.
The rejected Beacon example is not the consumer.

**Proposal P-1:** a visible terrain arena that can be navigated, making chunk
demand and the resulting terrain observable. Keep the first terrain source
simple while designing proper publication and lifetime. Camera controls,
terrain depth, world extent, appearance, editing and exact Lua APIs remain
unapproved. No implementation or delivery order follows from this proposal.

## Decisions

### D-1. Start with flat terrain for Ecce Homo

Owner, directly in this pane on 2026-11-06:

> ok yes lets begin terrain, take a look at synarchy's terrain generation, it uses chunks that load, procedural elevations, we can skip that though, lets just start with flat terrain, if you look at synarchy it has a testing arena mode, we should implement this, tell me what you think

This selects terrain and the arena reference, deferring procedural elevations.
It does not select every feature of Synarchy's testing tools, its world format,
exact material stack, save compatibility or engine architecture.

The initiating owner request `user-het-terrain-20261106-1838` rejected Beacon
and named Ecce Homo as the game being recreated, with systems open to redesign
or reimplementation. The manager supplied no further design decisions.

### D-2. Demand-driven loading is foundational

Asked whether the first arena should load/unload chunks with camera movement
or keep its entire terrain loaded, the owner answered directly on 2026-11-06:

> loading on demand, that is the foundation

Do not replace this with an all-resident first version. Flat generation is the
initial source of terrain; chunk demand and lifetime belong to the foundation.
The demand source, admission/budgets, loading execution, publication, failure
policy and safe eviction contract still need design. No numeric cache limit,
thread model or unlimited-memory behavior has been approved.

### D-3. Use this document and supersede the earlier example

Owner, directly on 2026-11-06, answered “that is fine” to the explicit proposal
to create `docs/designs/terrain_arena_design.md` and mark the earlier gameplay
example superseded while preserving its unresolved state questions.
[gameplay_state_design.md](gameplay_state_design.md) retains that history.
Its Q-3–Q-9 and inherited decisions are not automatically implementation scope
for terrain; revisit the relevant boundaries as this consumer requires them.

## Design boundaries

Hetoimasia V-1 keeps game rules, authored data and orchestration outside engine
libraries, using narrow services. Synarchy's world managers and coupled
environment are not the new architecture (H `docs/vision.md:15–36`).

**Direction reconciliation remains open:** H `MEMORY.md:64–65` still records
“Not committed: ... a full Synarchy port”. The owner's new recreation direction
was flagged in this conversation. It chooses the real game and this first
step, but does not yet specify complete feature/asset/save fidelity or revise
V-1. Do not silently update memory or equate recreation with source portability.

Before selecting state or concurrency, document its owner, readers/writers,
thread, lifetime, reset and disposal. CPU completion and GPU retirement remain
distinct (H `AGENTS.md:14–35`). No terrain-specific ownership table or storage
layout has been approved yet.

## Open questions

### Q-1. What does flat terrain contain vertically?

Recommend real terrain columns beneath the flat surface, as in Synarchy's
arena, so this foundation has somewhere to represent later excavation and
construction. A surface-only plane is less work initially but would leave the
vertical model for later. Exact depth, material stack and whether it is
authored/configurable remain separate choices; neither digging nor building
tools follow automatically from choosing columns.

### Q-2. Finite arena or expandable terrain?

Both can load on demand. Decide boundaries, nonwrapping versus other topology,
coordinate conventions, chunk dimensions and behavior at absent/unloaded
terrain. Synarchy's 5 × 5 startup footprint is not an approved extent or budget.

### Q-3. How does demand become usable terrain and then retire?

Name demand producers and authority, request deduplication, bounded admission,
priorities, cancellation, complete publication, failures, residency accounting
and safe eviction. Decide how late results are prevented from reaching a
replaced world and how renderer holds interact with CPU data eviction. A flat
generator must not substitute for a lifetime contract.

### Q-4. What can the owner see and control in the first version?

Decide projection, terrain assets/materials, camera movement/zoom/rotation,
vertical slices, picking and any loading indication. Determine the narrow Lua
rendering/input services required. Full UI, fonts, editors and Synarchy's debug
tools are not implicitly approved. Input ordering, focus/reset and routing need
explicit contracts if included.

### Q-5. What belongs to the reusable engine and what belongs to Ecce Homo?

Separate generic storage/loading/rendering mechanisms from the game's flat
terrain recipe, material meanings and presentation policy. Decide Lua authoring
and Haskell boundaries under V-1, including how any application material is
provided. Do not inherit Synarchy's concrete `WorldState` or assume an ECS
component store is the right representation for every terrain cell.

### Q-6. Mutation, persistence and state publication?

Decide whether the first arena is read-only or editable, what survives chunk
eviction, whether save/load or reset is included, and the relevant schema,
snapshot, tick/failure and determinism guarantees. Generated base data,
resident copies and durable edits need distinct meanings if all are included.
The earlier state agenda remains reference material; no save migration,
replay, mods or hot swap has been activated by D-1/D-2.

### Q-7. What proves this first terrain foundation complete?

Agree observable terrain and loading behavior, dependency boundaries, failure
and teardown cases, platform evidence and practical bounds. No performance
claim or whole-game parity follows from a flat terrain demonstration.

## Verification strategy — proposal

Use focused Hspec/model tests for identity, demand deduplication, bounded
admission and refusal; causally controlled integration tests for late results,
world replacement, cancellation and retirement. Qualify exact flat-terrain
content independently of chunk request order where that contract is selected.
Use captured rendering evidence for the agreed visible result and native input
evidence for controls actually included. Select checks from Hetoimasia's
validation catalog once slices exist (H `AGENTS.md`, Language and build;
`docs/vision.md:244–263`). No build, test or window launch ran for this design.

## Delivery plan

Zero slices. Define one-PR outcomes with stable `TRA-N` IDs only after the
material choices are settled, and mirror their dependency order in Processing
status. Readiness and tracker processing require later explicit owner choices.
