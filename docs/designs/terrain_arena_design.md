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
| Synarchy projects a diamond grid and has four camera facings 90 degrees apart. Camera input includes keyboard panning and middle-button dragging. | S `src/World/Grid.hs:220–236`; `src/Engine/Graphics/Camera.hs:22–37`; `src/Engine/Loop/Camera.hs:116–181` |
| Synarchy routes Shift-scroll to Z-slice input; arena slice input disables automatic Z tracking and increments/decrements the slice. Its inspected `camera.gotoTile` accepts two coordinates, computes a surface-based slice and enables Z tracking; it does not read an optional third Z argument. | S `src/Engine/Input/Thread/Scroll.hs:128–138`; `scripts/test_arena.lua:265–275`; `src/Engine/Scripting/Lua/API/Camera.hs:223–318` |
| Synarchy's renderer follows the terrain beneath the camera while Z tracking is enabled. Arena manual slice input disables tracking, the reset action restores it, and a zoom-map transition can also restore tracking. Rotation preserves the current tracking flag. | S `src/World/Render.hs:282–322`; `scripts/test_arena.lua:265–293`; `src/Engine/Scripting/Lua/API/Camera.hs:325–361` |
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
Development verification uses a temporary mouse-targeted keyboard shortcut
for tile removal, with no UI system or on-screen UI controls (D-8/D-9). Remove
the shortcut by task completion; the Lua removal API remains.
Changes survive chunk offload/reload within the current arena session, but
the arena is not persistent across sessions (D-10).
Depth should also extend on demand, with no designed bottom to the arena
(D-11). Numeric limits and bounded residency still need explicit contracts.
Shift-scroll controls the cutaway level. A camera jump defaults to the
destination's top level unless its Lua command supplies a Z level (D-12).
Normal panning, zooming and rotation automatically follow terrain height
(D-13). Shift-scroll temporarily pins the slice during panning; a camera jump
without explicit Z restores terrain following (D-14).

**P-1, navigation/loading direction accepted by D-7:** a visible terrain arena
that can be navigated, making camera demand and the resulting terrain
observable. Keep the first terrain source simple while designing proper
publication and lifetime. Exact camera controls, coordinate limits, appearance,
temporary key binding and exact Lua APIs remain open. No implementation or delivery order
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

### D-8. Keyboard shortcut for tile removal; no UI yet

Owner, directly in this pane on 2026-11-06, accepting the proposed initial
select-and-remove tile tool:

> yes sure, by keyboard shortcut, we dont want to implement any ui yet

Include an arena shortcut that removes one targeted exposed tile and exercises
D-7's lazy exposure behavior. Do not add a UI system, menus, toolbar, buttons
or other on-screen UI controls for this arc. The exact key and how the target
is chosen remain to be specified; accepting keyboard activation does not
choose mouse hover, click selection or a keyboard-controlled tile cursor.
Other editing tools remain outside the accepted scope. D-9 subsequently
settles mouse targeting and limits this shortcut to development verification.

### D-9. Temporary development shortcut; retain the Lua API

Owner, directly in this pane on 2026-11-06, accepting mouse targeting and one
tile removal per shortcut press:

> that is fine, this would be a dev only shortcut that we would soon delete when the task is done, leaving only the lua api call

Use the mouse to target an exposed tile and a keyboard shortcut to remove one
tile per press during development. The shortcut is temporary verification
scaffolding, not a shipped arena editing control. Remove its binding and
shortcut-specific glue by task completion, leaving the Lua tile-removal API
as the durable removal interface. The temporary control must exercise that
same API rather than a separate mutation path. Retain appropriate API-level
regression coverage after the shortcut is deleted. Do not infer deletion of
general camera/input or terrain-query capabilities from this cleanup.

The exact API name, arguments, result/failure semantics and temporary key
remain to be designed. No UI implementation is introduced.

### D-10. Session-only changes retained across chunk offload/reload

Owner, directly in this pane on 2026-11-06:

> yes that fits, the testing arena is not supposed to be persistent, but the loaded chunks will have to track the changes, then save thos changes on chunk offload, then reapply them on reload

Loaded chunks track their changes. Before offloading a changed chunk, retain
those changes in a store owned by the current arena session. Reloading
regenerates terrain from the same source and reapplies the retained changes
before the chunk becomes usable. Further edits and repeated offload/reload
must preserve all earlier changes, including removals, without resurrecting
deleted tiles. Untouched underground detail remains lazy under D-7.

Here, saving on offload means retaining changes for the current session;
the accepted scope does not require disk saves or recovery across application
restarts. Destroying the arena ends the store's lifetime, and a new arena
starts fresh. The store retains changes independently of resident chunk data,
so chunk eviction cannot discard them. Exact encoding, compaction, threading
and transfer/publication mechanics remain design choices in Q-3/Q-6/Q-9.

### D-11. Effectively unlimited depth, generated on demand

Owner, directly in this pane on 2026-11-06, responding to a proposed
configurable bottom versus terrain extending downward with digging:

> ideally it would be infinite, unless you see a reason why it cant be

Select the direction of no designed bottom: terrain continues downward as
needed. Lazy generation is compatible with this direction; no need to
allocate or compute an infinite column. A terrain recipe can define what
exists at a requested depth without enumerating intervening underground cells.
The finite-bottom recommendation is not selected.

This means effectively unlimited exploration, not infinite machine resources.
Coordinate representation, arithmetic/conversion limits and out-of-range
behavior remain explicit implementation choices. Do not silently wrap or lose
tile identity at large depths. No specific coordinate type is approved here.

Residency must work vertically too: descending must not require retaining
every previously visited depth in the same horizontal chunk. Recommend sparse,
bounded vertical residency within the compressed-column model and queries
restricted to demanded ranges, rather than traversal from the surface to the
requested depth. Exact partitioning remains Q-3/Q-9. Exposed geometry also
needs bounded preparation; a deep shaft must not force an arbitrarily tall
wall mesh to stay resident. Session edit storage remains D-10 and can grow
with edits; compression does not promise constant memory for arbitrary
modifications. None of these constraints requires a gameplay depth floor.

### D-12. Shift-scroll cutaway and optional Z on camera jumps

Owner, directly in this pane on 2026-11-06, accepting cutaway viewing:

> yes that works, i was thinking shift-scroll would change the z level of the cutaway, that should be how synarchy works, with the camera automatically snapping to the top level when the camera first jumps to a location, unless the optional z level was included in the camera move api command.

Include manual cutaway viewing, controlled by Shift-scroll. Terrain above the
selected plane is hidden rather than removed. The view demands needed terrain
under D-6 without materializing the full depth between the surface and slice.
The selected slice and terrain picking must describe the same displayed view.

The Lua camera move/jump command accepts an optional Z level. With Z omitted,
the camera initially snaps to the destination's top terrain level; with Z
provided, that level overrides automatic surface selection. The command must
work for an unloaded destination through terrain demand and must not
subsequently overwrite an explicit Z with a late surface lookup. Exact API
name/signature, loading publication and failure behavior remain open.

Synarchy confirms the Shift-scroll reference. Its inspected jump API has no
optional Z argument, so optional Z is a selected Hetoimasia requirement rather
than a claim of existing Synarchy parity. D-13 subsequently selects normal
terrain-following navigation and rejects the recommendation to keep the view
at a fixed Z through ordinary navigation. The detailed meaning of top level at
an edited or empty destination and scroll step/direction remain to be
specified. D-14 settles the manual-panning override and jump reset.

### D-13. Follow terrain during ordinary camera navigation

Owner, directly in this pane on 2026-11-06, correcting the fixed-Z navigation
recommendation:

> no, like synarchy panning zooming and rotation simply follow the terrain, so that we can move around hills without having to manually set the z slice level

Normal panning, zooming and rotation automatically follow terrain height.
Moving around hills must not require manually adjusting the cutaway level.
The previous fixed-Z navigation recommendation is withdrawn. Flat initial
generation remains D-1; this camera behavior must also accommodate varied
terrain heights and edits without requiring procedural hills in this arc.

D-12's manual Shift-scroll and explicit jump Z still apply. D-14 subsequently
settles the manual-panning exception and reset on a camera jump. Synarchy's
inspected implementation uses a tracking flag: Shift-scroll disables it, a
reset action restores it, and a zoom-map transition can also restore it.
That zoom-map transition is reference behavior, not an independently selected
Hetoimasia feature.

### D-14. Manual cutaway overrides panning until a camera jump

Owner, directly in this pane on 2026-11-06:

> in synarchy, if the z slice is set by custom shift scroll, then panning is temporarily overridden to allow for no changes, that is right, that works well, this then resets when we move the camera to a new spot

Shift-scroll selects a manual cutaway level and temporarily disables automatic
height following while panning. Panning still changes horizontal position;
it does not change the selected slice. Moving the camera to a new spot here
means the move/jump command discussed in D-12, distinct from ordinary panning.
A jump without Z clears the manual override, selects the destination's top
level and resumes terrain following. D-12's explicit Z argument takes
precedence when supplied, so such a jump uses the requested depth rather than
snapping to the surface.

| Action | Selected behavior |
| --- | --- |
| Normal pan, zoom or rotation while following | Follow terrain height (D-13). |
| Shift-scroll | Change cutaway Z and enter manual override. |
| Pan with manual override | Preserve the chosen cutaway Z. |
| Move/jump without Z | Clear override, select destination surface and follow terrain. |
| Move/jump with Z | Honor requested depth rather than automatic surface selection. |

No UI toggle or additional reset shortcut is selected by this decision.
Detailed zoom/rotation behavior during manual override remains part of the
camera contract to specify; do not import Synarchy's zoom-map reset implicitly.

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
arena recommendation was declined. D-11 also selects no designed bottom.
Specify coordinate conventions and machine limits, chunk dimensions and
absent/unloaded behavior. Synarchy's
5 × 5 startup footprint is not an approved extent or budget.

### Q-3. How does demand become usable terrain and then retire?

Rendering and game queries are allowed demand producers under D-6. Define
their authority, request deduplication, bounded admission,
priorities, cancellation, complete publication, failures, residency accounting
and safe eviction. Decide how late results are prevented from reaching a
replaced world and how renderer holds interact with CPU data eviction. A flat
generator must not substitute for a lifetime contract.
D-10 requires offload to preserve changes before discarding resident data and
reload to apply them before publication. Define that handoff and failure
behavior. Account separately for resident terrain, derived render data and
session-retained changes; a resident-chunk limit does not bound accumulated
edits across the explored arena.
Under D-11, define vertical residency and retirement as well as horizontal
chunk offload. A long-lived horizontal chunk must not retain all depth ever
visited merely because the camera is still over that column.
Queries can concern invisible regions while undemanded detail remains
unmaterialized. The producer rule is settled; its operational contract remains
open.

### Q-4. What can the owner see and control in the first version?

Camera exploration/loading is selected by D-7. Decide projection, terrain
assets/materials, camera movement/zoom/rotation controls,
and detailed picking behavior. D-12 selects Shift-scroll cutaway levels and
optional Z on camera jumps. D-8/D-9 select temporary shortcut-based removal
and exclude UI implementation for this arc. Determine the narrow Lua rendering/input
services required. Input ordering, focus/reset and routing need explicit
contracts. Loading behavior must respect the no-UI scope.

Targeting is settled by D-9: point at an exposed tile with the mouse and press
the temporary shortcut, removing one tile per press. The exact key remains
open. Delete this development binding by completion; the final removal
interface is the Lua API, not a persistent keyboard control.

Camera proposal, 2026-11-06, following the owner's request to explain what is
unclear: use Synarchy's isometric-style diamond view and four 90-degree
facings as the initial presentation. Recommend keyboard pan, mouse drag and
wheel zoom, with exact bindings adjustable during implementation. These are
proposals; prior approval of camera-driven loading did not select projection,
rotation or navigation behavior.

D-12 settles cutaway viewing: Shift-scroll changes the displayed Z level while
terrain above is hidden, and jumps choose the destination's top level unless
given explicit Z. Distinguish slice visibility from actual exposure caused by
removal. Cut-face appearance, visible depth range, exact top-level semantics
remain open. D-13 selects terrain following for normal pan/zoom/rotation;
the previous fixed-Z recommendation for normal navigation is withdrawn.
D-14 selects pinned Z during manual panning and restores following on a jump
without Z; an explicit jump Z takes precedence. Remaining manual-mode zoom
and rotation details must be specified without importing the reference's
zoom-map feature. No UI widgets are implied. The isometric/four-facing presentation and
remaining navigation proposal above are not independently settled by the
cutaway decision.

### Q-5. What belongs to the reusable engine and what belongs to Ecce Homo?

Separate generic storage/loading/rendering mechanisms from the game's flat
terrain recipe, material meanings and presentation policy. Decide Lua authoring
and Haskell boundaries under V-1, including how any application material is
provided. Do not inherit Synarchy's concrete `WorldState` or assume an ECS
component store is the right representation for every terrain cell.

### Q-6. Mutation, persistence and state publication?

D-7 requires removal to reveal newly materialized terrain; D-9 selects a
durable Lua removal API with a temporary development shortcut. D-10 settles
retention: track changes while loaded, retain them on offload, and reapply
them on reload within the same arena session. No cross-session persistence.
Define change representation, repeated-edit composition, handoff failures,
publication and determinism guarantees. Generated base terrain, resident
copies and session-retained changes have distinct lifetimes. Additional edit
operations and an explicit in-session reset command remain open.
The earlier state agenda remains reference material; save migration, gameplay
replay, mods and hot swap remain outside this scope. Reapplying terrain changes
on reload under D-10 does not introduce a general replay system.
The development removal tool is accepted; its lifecycle is D-9 and remaining
input choices are in Q-4.

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
coordinate limits and physical storage. D-11 selects no designed depth floor.
A cell contract does not itself require
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

D-11 settles the vertical direction: extend downward on demand, without a
designed bottom. Settle a recipe that answers for the requested depth without
generating every intervening tile, along with vertical residency, coordinate
limits and bounded range queries. The initial material/layer recipe remains
open.

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
Under D-10, verify remove/offload/reload, additional removal followed by another
cycle, and reconstruction independent of chunk demand order. Verify a fresh
arena inherits no changes from the previous session. No disk persistence test
is implied by this session-only contract.
For D-11, query widely separated depths without constructing the intervening
volume; verify vertical eviction/reload and bounded resident/render data as
the demanded depth moves. Include coordinate-limit and conversion checks once
the representation is chosen. Report retained edit storage separately from
resident terrain; no test can establish literal infinite resource capacity.
For D-12, verify Shift-scroll changes visibility without editing terrain;
camera jumps choose the surface when Z is omitted and honor explicit Z for
both resident and unloaded targets. Exercise successive jumps so a late result
cannot reset a newer view. Verify picking against the displayed cutaway and
that viewing a deep slice does not materialize the intervening volume.
For D-13, navigate varied-height authored terrain using pan/zoom/rotation and
verify that normal terrain following keeps the relevant surface visible.
For D-14, Shift-scroll then pan over different heights and verify the slice
stays fixed; jump without Z and verify surface following resumes; jump with Z
and verify that requested depth wins. Include unloaded jump destinations and
late surface results. These fixtures do not add a procedural hill generator
to the arc.
During development, exercise the D-8/D-9 shortcut through the agreed
targeting/input path, including no valid target and focus/reset behavior.
Capture its removal/reveal evidence before deleting the shortcut. Final
acceptance verifies the Lua API and retained regression coverage, and that
the temporary binding and its dedicated glue are gone. No UI framework is
needed to demonstrate this control.
Use captured rendering evidence for the agreed visible result and native input
evidence for controls actually included. Select checks from Hetoimasia's
validation catalog once slices exist (H `AGENTS.md`, Language and build;
`docs/vision.md:244–263`). No build, test or window launch ran for this design.

## Delivery plan

Zero slices. Define one-PR outcomes with stable `TRA-N` IDs only after the
material choices are settled, and mirror their dependency order in Processing
status. Readiness and tracker processing require later explicit owner choices.
