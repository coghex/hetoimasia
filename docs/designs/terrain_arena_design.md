# Terrain arena design

Begin recreating Ecce Homo on Hetoimasia with flat terrain and on-demand
chunk loading as the camera explores an expanding procedural arena. Synarchy's
testing arena is the concrete reference. The owner
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
  procedurally generated and loaded by camera/query demand as exploration
  extends the arena, using a complete terrain model that includes
  subsurface structure and gaps from the outset, with the engine/game boundary
  preserved. Flat describes the initial terrain source, not a surface-only model.
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

Follow-up inspection, 2026-11-06: H `origin/master` at
`45c54833a2c4ad361c252f92af02ad04f08b20ce`; S remains at the revision above.
The following are specific observed implementation choices, not a general
defect verdict on Synarchy:

- Air gaps already exist in `ColumnTiles`: interior air is stored in a
  contiguous vertical range, with separate material/slope/vegetation arrays
  (S `src/World/Chunk/Types.hs:72–94`).
- A loaded chunk also stores terrain-top and rendered-surface maps
  (S `src/World/Chunk/Types.hs:104–109`). The Lua `getTerrainAt(x,y)` query
  returns those two surface heights, not all solid/empty intervals
  (S `src/Engine/Scripting/Lua/API/WorldQuery/Terrain.hs:29–62`).
- `WeSetCell` writes an arbitrary in-range cell, or grows upward with air
  filling the gap, but returns the unchanged chunk below the stored column
  floor. It then recomputes top surfaces; structures use a separate overlay
  (S `src/World/Edit/Apply.hs:298–343`, `:412–438`). Do not copy those limits
  or overlay semantics without choosing their meaning for the new model.
- Synarchy's procedural column builder chooses its stored lower bound from
  the surface and neighboring elevations (`exposeFrom`), then allocates
  material/slope/vegetation arrays for that exposed range. Its current interior
  air entries still occupy positions in those arrays; this is distinct from
  compressing an entire air interval into a range record
  (S `src/World/Generate/Chunk/Columns.hs:100–115`, `:205–209`;
  `src/World/Chunk/Types.hs:72–80`).
- When newly loaded neighbors expose a deeper cliff face, Synarchy extends
  edge columns downward by repeating the lowest stored material. That is an
  explicit continuation rule, not reconstruction of arbitrary deeper geology
  (S `src/World/Slope/EdgePatch.hs:16–24`, `:95–109`).

Initial tracker overlap check, 2026-11-06: the open issue list contains #446
and #563; an all-state `terrain arena` title/body search returned no match.
No existing open terrain umbrella was found. Repeat at readiness; this is not
final per-slice deduplication. Synarchy's own terrain trackers are references,
not Hetoimasia delivery items.

## Desired experience and scope

**Accepted direction:** begin terrain for Ecce Homo using flat arena terrain
and demand-driven chunk loading. The full terrain model, including gaps,
belongs in the first version (D-4). Procedural elevation generation is deferred.
Compressed columns with demand-driven materialization are the chosen direction
(D-5). Rendering and game queries can both demand terrain; undemanded detail
stays unmaterialized (D-6). The rejected Beacon example is not the consumer.
The arena expands with exploration; camera loading initially materializes only
the top tile of each untouched column. Removal demands newly exposed terrain
without eagerly filling underground depth (D-7).

**P-1, navigation/loading direction accepted by D-7:** a visible terrain arena
that can be navigated, making camera demand and the resulting terrain
observable. Keep the first terrain source simple while designing proper
publication and lifetime. Exact camera controls, vertical extent, appearance,
editing controls and Lua APIs remain open. No implementation or delivery order
follows from this direction alone.

**Proposal P-2: one authoritative spatial terrain model.** Represent terrain
occupancy and its material/shape at positions in three dimensions, with gaps
and multiple separated solid regions at the same horizontal position. Surface
height, exposed faces and visibility are derived queries/caches with defined
consistency, not substitute terrain authorities. Distinguish known empty space
from unloaded/unknown terrain and outside-world positions. A flat arena fills
this same model procedurally; future elevation generation would populate it
differently.

Recommend a discrete `(x,y,z)` cell model as the logical contract, independently
of physical storage. This can express cave floors, ceilings and overhangs.
Cell shapes/slopes, terrain versus constructed structures, vertical chunking,
exact data representation are separate decisions. D-5 selects compressed
columns; exact cell/shape granularity and query semantics remain in Q-8.

**Owner memory concern, 2026-11-06 — direction addressed by D-5:**

> i initially avoided the 3d cell because i was worried about having too much data, what would you say to that? by compressing airgaps and only holding the top terrain, we only hold in memory the basic structure, not every cell

The logical ability to answer about `(x,y,z)` does not require allocating a
record for each cell. P-2 must not be read as a recommendation for a dense
full-depth voxel allocation. This concern led to P-3 and the owner's subsequent
approval of its direction in D-5; physical layout and budgets remain open.

**Proposal P-3: compressed vertical spans with bounded materialization.** Keep
columns, but describe solid/material intervals and gaps compactly. An
illustrative column could be stone at z=0–99, air at z=100–119, stone at
z=120–124, then air to the selected world ceiling. This needs a handful of
span boundaries instead of a separate record for each depth; exact integer
boundary conventions and representation are not selected by this example.
Uniform solid interiors can be compact just as air can. Gaps, cave ceilings
and separated spans remain queryable parts of the same model.

D-5 accepts this direction. The illustrative layout and all detailed choices
below remain proposals rather than an approved implementation specification.

Distinguish three questions: what terrain exists, which terrain data is
materialized in memory, and which exposed faces are prepared for rendering.
An exposed-surface cache may be small, but material omitted beneath it needs
an explicit authoritative answer: a compact base definition, a deterministic
source fetched/generated on demand, or an explicit unavailable state. It must
not silently become air or lose a buried edit. D-7 selects a procedural source
for the arena; its deep-terrain recipe and the eviction/durable-edit boundary
are still Q-3/Q-6/Q-9 decisions.

Span compression favors coherent layers. Highly fragmented materials/shapes
or alternating solid/air can require many spans; queries and edits also need
search/split/merge work. No compression ratio or speed is claimed. Account for
actual resident representations and derived render data when selecting bounds;
a chunk count alone does not establish a memory bound. Compare representative
flat, layered, hollow and fragmented cases before choosing physical storage.

**P-4, direction accepted by D-6: demand follows consumers.** Untouched
underground detail may remain uncomputed and unallocated until needed. A small
terrain definition/source and any retained modifications provide its meaning;
there is no requirement to precompute every underground column's spans. Known
air intervals likewise need no per-cell enumeration. Materialize only the
requested region and whatever bounded neighboring data its query requires.

Rendering is one possible demand producer. A future digging, collision or
other game query can need terrain that is not visible. Such examples explain
the contract; they do not add those systems to this arc. Unloaded terrain must
not be interpreted as air, and revealing or reloading the same terrain must
remain consistent with its source and retained edits. Rendering faces and CPU
terrain detail can have different residency requirements. D-6 selects the
demand-producer rule; exact request APIs, budgets and scheduling remain open.

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

### D-4. Establish the full terrain model, including gaps, immediately

Owner, directly in this pane on 2026-11-06, answering Q-1:

> yes, we need to get the whole terrain model in place from the beginning. including the possibility of gaps, so synarchy does this in a patchwork way, we need to implement correct from the start.

A surface-only first model is rejected. Include subsurface structure and gaps
in the initial terrain model; do not rely on retrofitting those through special
cases after a flat arena is delivered. Flat terrain generation remains the
initial source under D-1, and loading remains on demand under D-2.

The owner's description of Synarchy motivates a coherent replacement; the
inspection above establishes the narrower facts actually checked. This answer
does not select a cell/shape representation, physical storage scheme, numeric
vertical bounds, structural-support simulation or exact editing tools. The
remaining meaning and boundaries of the full model are refined in Q-8 and the
other open questions, rather than silently narrowed to a fixed solid column.

### D-5. Compressed columns with lazy materialization

Owner, directly in this pane on 2026-11-06, answering whether the compressed
column direction matches their intent:

> yes that fits, the thing that i liked that synarchy did was leave all the empty space uncalculated when it was unrendered, then tiles get loaded into memory as they are needed, without any memory loaded in that is underground, is something wrong with that approach?

Accept compressed columns and materializing terrain detail only as needed.
Do not require dense per-cell storage or eager computation of the underground
to satisfy D-4's complete spatial model. The owner specifically values leaving
unneeded space uncalculated. Their question asks whether this is sound; it
does not yet approve a visibility-only demand policy or promise literally zero
memory for the source definition, metadata or retained underground edits.
P-4 recommends the demand rule; Q-8/Q-9 retain representation details.

### D-6. Rendering and game queries can both demand terrain

Owner, directly in this pane on 2026-11-06:

> yes that sounds correct

This answers the recommendation to let rendering and game queries both
request terrain while leaving everything else unmaterialized. Visibility is
not the sole condition for loading: a consumer may request invisible terrain.
Loading the requested region does not require materializing all underlying
depth. An unloaded region is not air, and reloading must preserve the meaning
of the terrain source and any retained modifications. Specific gameplay
systems, editing tools and save/load remain separate scope decisions.

### D-7. Expanding procedural arena with camera demand and lazy exposure

Owner, directly in this pane on 2026-11-06:

> keep extending as you explore, this is how the testing arena works in synarchy (or should work according to my memory). the arena should be procedurally generated, and loaded in with the camera, so that only the top tile is defined and the rest underground remain not in memory until a tile above is removed

Choose an arena that keeps extending horizontally with exploration, rather
than the proposed finite rectangle. Camera movement requests new chunks from
a procedural source. D-1's initial flat surface remains selected: procedural
here means terrain supplied by a generation rule on demand; variable elevation
generation remains deferred. Coordinate representation and practical limits
still need specification; expansion is not a promise of infinite residency.

For untouched columns loaded by the camera, materialize the top tile only.
Do not allocate underground tile records or enumerate all buried spans.
Removing a tile demands the newly exposed terrain from the same source;
deeper untouched terrain remains unmaterialized. The complete gap-capable
model remains D-4/D-5, and D-6 still allows explicit game queries to demand
invisible terrain. A compact source definition supplies the meaning of
unmaterialized terrain without allocating its individual tiles.

Removal/reveal behavior is part of the terrain contract. The exact removal
interaction, additional editing operations and disk persistence remain open.
For gaps and openings, exposure must include relevant neighboring side faces,
floors and ceilings rather than assume every removal merely lowers a single
height value. This follows from the agreed full model; it does not require
materializing the full surrounding underground volume.

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

Resolved by D-4: the initial terrain model includes subsurface structure and
gaps. A surface-only model is rejected. Exact logical representation continues
in Q-8; bounds, authorship and editing remain separate choices.

### Q-2. Finite arena or expandable terrain?

Resolved in direction by D-7: keep extending as the camera explores. The finite
arena recommendation was declined. Specify coordinate conventions and limits,
chunk dimensions, vertical limits and absent/unloaded behavior. Synarchy's
5 × 5 startup footprint is not an approved extent or budget.

### Q-3. How does demand become usable terrain and then retire?

Rendering and game queries are allowed demand producers under D-6. Define
their authority, request deduplication, bounded admission,
priorities, cancellation, complete publication, failures, residency accounting
and safe eviction. Decide how late results are prevented from reaching a
replaced world and how renderer holds interact with CPU data eviction. A flat
generator must not substitute for a lifetime contract.
Queries can concern invisible regions while undemanded detail remains
unmaterialized. The producer rule is settled; its operational contract remains
open.

### Q-4. What can the owner see and control in the first version?

Camera exploration/loading is selected by D-7. Decide projection, terrain
assets/materials, camera movement/zoom/rotation controls,
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

D-7 requires removal to reveal newly materialized terrain. Decide its initial
interaction and any additional edits, what survives chunk eviction, whether
save/load or reset is included, and the relevant schema,
snapshot, tick/failure and determinism guarantees. Generated base data,
resident copies and durable edits need distinct meanings if all are included.
The earlier state agenda remains reference material; no save migration,
replay, mods or hot swap has been activated by D-1/D-2.
For the next owner choice, recommend a simple arena tool to select and remove
one exposed tile, making this loading contract directly observable. A
script-only removal command is an alternative with less interaction work.
Neither control choice is selected yet.

### Q-7. What proves this first terrain foundation complete?

Agree observable terrain and loading behavior, dependency boundaries, failure
and teardown cases, platform evidence and practical bounds. No performance
claim or whole-game parity follows from a flat terrain demonstration.

### Q-8. What is the logical model of solid terrain and gaps?

Recommend P-2's discrete 3D cell model: terrain at each `(x,y,z)` can be
independently present or empty, allowing multiple solid spans and multiple
surfaces in one vertical column. A cave/overhang is ordinary terrain geometry.
This needs richer queries than a height field, but does not require dense
per-cell storage: P-3 preserves a compressed column representation. A single
height per column cannot express the owner's requested gaps. Another option is geometry
defined by continuous surfaces/volumes; that would require different editing,
intersection and rendering contracts.

After the logical choice, settle partial-cell shapes/slopes, whether constructed
terrain shares that geometry authority, empty versus unavailable answers,
vertical bounds and physical storage. A cell contract does not itself require
a dense full-world allocation, cubic storage chunks or a particular array.

### Q-9. How is terrain represented compactly, including unmaterialized depth?

D-5 selects P-3's compressed-column direction, retaining complete spatial
meaning while materializing only demanded detail. D-7 selects a procedural
arena source and top-tile-only initial materialization. Settle its deep-terrain recipe,
uniform base/shared data, material and shape boundaries, edit overrides,
fragmentation limits and any alternative dense representation for complicated
regions. Do not equate a known air gap, an unstored solid interior, unavailable
terrain and an outside-world position. Exact memory/time tradeoffs remain
unmeasured, and the exact physical storage layout is not approved yet. P-4
allows a shared source definition to stand in for untouched underground spans;
choosing compressed columns does not require eagerly building every column.

## Verification strategy — proposal

Use focused Hspec/model tests for identity, demand deduplication, bounded
admission and refusal; causally controlled integration tests for late results,
world replacement, cancellation and retirement. Qualify exact flat-terrain
content independently of chunk request order where that contract is selected.
Include non-flat authored cases that exercise D-4 even though the initial arena
generator is flat: a cavity with a solid ceiling, separated solid spans,
completely empty columns and geometry crossing chunk boundaries. Require the
agreed terrain reads, rendering/picking and reload behavior to describe the same
geometry; no procedural cave generator is implied by these cases. Exact
consumers and evidence remain Q-4/Q-6/Q-7 decisions.
Exercise camera exploration beyond the startup footprint, top-only initial
materialization, repeated removal revealing deeper terrain, and exposure of
side faces and gaps. Inspect terrain allocations as well as rendered output
to verify that untouched depth stays unmaterialized. Check explicit invisible
queries separately under D-6 and returning to an edited, evicted region.
Use captured rendering evidence for the agreed visible result and native input
evidence for controls actually included. Select checks from Hetoimasia's
validation catalog once slices exist (H `AGENTS.md`, Language and build;
`docs/vision.md:244–263`). No build, test or window launch ran for this design.

## Delivery plan

Zero slices. Define one-PR outcomes with stable `TRA-N` IDs only after the
material choices are settled, and mirror their dependency order in Processing
status. Readiness and tracker processing require later explicit owner choices.
