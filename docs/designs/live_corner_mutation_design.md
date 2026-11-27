# Live corner terrain mutation

Design state: `ready for issue processing`

## Processing status

An unchecked entry awaits filing. A checked entry links its tracker number.

- [x] EPIC. Narrow observed terrain solids in a live arena — [#767]
- [ ] NARROW-1. Represent and query tagged terrain replacements
- [ ] NARROW-2. Discover openings through edited corner cells
- [ ] NARROW-3. Store and replay bounded tagged replacements
- [ ] NARROW-4. Publish a conditional corner edit through the live arena
- [ ] NARROW-5. Expose the conditional edit to Lua

## Epic contract

A client can clear selected high corners of the cell it observed. Native and Lua clients sharing an arena see the same surviving material, exact shape, and discovery facts at the same revisions, including after eviction. The caller chooses the tile and mask. Graphics, targeting, and application rules stay with the consumer. The arc needs no new label.

On `2acfc04f`, [terrain](../../packages/terrain/README.md) already describes both full identities, folded corner geometry and exact openings. [Terrain runtime](../../packages/terrain-runtime/README.md) publishes only whole-cell removal. Its store, discovery, resident patch and regional copy all interpret an edited interval as air. The [Lua binding](../../packages/lua-engine/README.md) also rebuilds regional terrain from removed intervals.

## Decisions

### D-1. Narrow the observed solid

`narrowAt service lease tile expected target precondition` follows `removeAt`'s pending-request/result convention. `narrowWith` adds the host settlement endpoint as in `removeWith`. The expected `Cell` is matched by material, family and value. Side 0 supplies high bits 15. A `CornerSolid` supplies its nonzero mask. The target is a `CornerMask` whose bits form a strict subset of those high bits. Resolve it with `cornerCell` and the observed material. This admits clearing several bits in one edit. Clearing one each time takes either full identity through 14, 12, 8 and 0 to air. Side 0 and corner 15 remain different observations.

| Condition | Observable result |
| --- | --- |
| Air, side 1–15, malformed observed solid or mask, equal target or added bit | Invalid input before admission |
| Well-formed pair, current cell differs from expected, or supplied arena/revision precondition is stale | `StaleView` (`stale_view`), including a repeated successful request |
| Current staged edit wins settlement | Success with incarnation, committed content revision and `changed = true` |
| Cancellation wins before publication | Existing cancelled outcome, prior roots and revisions intact |
| Authority, closure, capacity, storage or host failure | Existing refusal/settlement for that condition. No partial edit |

An unrelated committed edit requires restaging against current contents. With no revision precondition the edit can still succeed if the observed cell matches. The owner publishes the checked root, resident patch, request settlement and initial knowledge work in the existing STM decision. Once success wins, cancellation cannot undo it. Whole-cell `removeAt`/`removeWith` still accept every occupied shape and return unchanged success on air.

### D-2. Store the resulting replacement

The immutable source plus one overlay owns content. Each column has disjoint half-open runs, keyed by lower level, carrying air or a nonzero corner mask. Resolve a mask against the source material at the level being queried. Changing the middle of a run can split it. Adjacent identical payloads coalesce, including air from either public operation. Source material boundaries still split effective cell answers.

The two corner surfaces are linear on the common subdivision made by both diagonals. At its vertices (the four corners and centre), clearing bits never raises the surface. Thus occupied cells and solid volume can only shrink. A floor lookup plus forward scan still finds overlapping runs, and a surface query may skip source-air gaps. Alternating masks can occupy one run per level. Replace the old half-window and 320-byte column estimates with bounds for tagged entries, predecessor, split/coalesce work, regional halo, staging and pins. Admission must cover the supported window or refuse it before work begins.

Version the private session pages from 1 to 2, validate tags, extents and canonical adjacency, and replay terrain, links and pending obligations from the same committed roots. Missing pages suspend and corrupt pages fail explicitly. The file lives for one arena session. Cross-run save migration is outside this contract.

### D-3. Publish coherent discovery and reads

Stage the replacement, joins to any old void it contains, and the obligation to inspect its faces together. Use the resulting key's openings (air openings at zero) and actual neighbour portals. Positive-area overlap connects. At the upper world boundary only an open top reaches the exterior. Equal vertically adjacent masks may share a storage run while their voids remain disconnected. Keep connectivity identities valid through run splits and coalescing. Later edits must preserve earlier joins and cover newly opened faces even when discovery work is already pending.

Sealed unknown space remains unknown. Content advances on the edit. Knowledge advances when new space becomes known, immediately or through ordinary bounded discovery. A regional copy pins terrain and knowledge to one committed version and retains its availability states. A held snapshot keeps its old value. Fresh resident view demand, direct cell/column/surface reads, regional reads and eviction/reload all resolve the same replacement at the same content revision.

**Native migration.** `regionTerrain` changes from removed intervals to tagged replacement runs. Native consumers inspecting runs must handle both payloads or use `regionCell`. Update the Lua regional adapter with this change so its copied cell schema stays compatible. Runtime view coverage is CPU data. The existing 2D renderer's corner-key refusal is outside this arc.

### D-4. Bind Lua in the same arc

`api.terrain.narrow(arena, pos, expected, target_mask [, pick])` takes the observed solid's material and exactly one shape discriminator (`shape` or `corner_mask`). The optional pick has the existing displayed-view precondition semantics. Success returns `{changed = true, revision = INT}` through the ordinary request lifecycle. Attached leases use the same authority as removal.

## Delivery plan

### NARROW-1. Represent and query tagged terrain replacements

Can land first. Implement D-1's pure transition and D-2's overlay in terrain. Cell, column, surface and materialization agree on edited levels and untouched neighbours. Verify strict subsets, same-material intermediate masks, zero, split/coalesce, and legacy removal.

### NARROW-2. Discover openings through edited corner cells

Depends on NARROW-1. Extend the pure discovery model, replay records and compressed regional knowledge under D-3. Verify sealed and connected space, a single-high bottom opening versus an opposite-high closed bottom, intervening edits with pending obligations, and restored knowledge.

### NARROW-3. Store and replay bounded tagged replacements

Depends on the tagged changes and the logical discovery records in NARROW-1/2. Codec and accounting work can be developed alongside discovery once the record contract is fixed. Land bounded planning, pinned reads, codec validation and same-session replay under D-2. Include alternating tags and a split inside a long run.

### NARROW-4. Publish a conditional corner edit through the live arena

Depends on NARROW-1/2/3. Deliver D-1 through D-3 across admission, settlement, regional migration, the Lua regional reader, resident views and reload. Verify the full-to-air sequence, duplicate and stale pick, an unrelated edit, both cancellation outcomes, and agreement between fresh reads while an earlier snapshot retains its value.

### NARROW-5. Expose the conditional edit to Lua

Depends on NARROW-4. Deliver D-4 through the stock binding. Exercise both full identities, invalid input, stale observations, cancellation and same-revision native/Lua readback through a shared arena.

## Verification

Use headless outcomes. Exercise both sides of settlement with causal gates. Compare exact material, tagged shapes, knowledge and revisions. No test depends on scheduling, elapsed time, incidental counts or a particular face-processing order. Run each selected check once; investigate a test problem for at most two iterations before reporting it.
