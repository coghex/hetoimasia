# Terrain views with retained chunks

Design state: `approved`. **D-1 / Q-2 resolved.** The owner approved the design with “Y” on 2026-11-20 at 18:45:19 UTC and directed this shorter specification and two-issue delivery.

## Processing status

- [#636] EPIC. Terrain arena.
- [ ] TRA-9-V2-A. Publish retained terrain in the graphics session.
- [ ] TRA-9-V2-B. Pick the drawn frame and reject stale edits. Depends on A. Its PR completes #645.

## What is ordered and what is not

Ordering is free unless it affects gameplay. These are the only ordering and consistency guarantees.

1. Every drawn frame uses one complete, coherent revision. Loading is valid content in a complete revision. A half-built replacement never reaches the screen.
2. A GPU buffer stays alive until the last frame using it finishes.
3. A pick answers against the frame actually drawn.
4. An edit from a stale pick returns `stale_view` and changes no cell.
5. Fog conceals undiscovered terrain. Hidden cells cannot be picked.
6. Every operation settles exactly once. Session exit leaves no view work or resources behind.

Regions, chunks, copies and textures can become ready in any order. Concurrent requests can settle in either order. Intermediate loading states, frame and owner-step counts, and which relevant change prompts a fresh attempt after refusal are unspecified. Any retirement order respecting guarantee 2 is valid. Tests assert outcomes and these guarantees.

## The session-owned view

**D-3, D-8.** One trusted graphics session owns one view per target incarnation. At attach, check session admission, the original live window/texture/arena leases, complete atlas mapping, depth support and the exclusive claim shared with M1. The view retains its own exact-version atlas and coverage interests. The application uses the existing Hetoimasia owners. [Resource contract](../resources.md) · [Renderer and release lanes](../../packages/render-2d-vulkan/README.md)

The presentation instance supplies the latest intent. Each view owns one runtime demand and at most one regional snapshot request. The terrain runtime owns terrain and knowledge. The view copies immutable facts and returns the borrow even if cancellation loses to settlement. The graphics owner runs bounded pure planning and instance assembly between frames and owns chunk builds, publication, draw receipts and release. Close and cleanup can progress on a minimized target. [Terrain runtime](../../packages/terrain-runtime/README.md)

**D-2.** Plan the projected height band, including distant contributors, occluding neighbors and a mixed cell’s two parts. Visible demand has priority over prefetch. Publish the ready chunks and matching plan together after rechecking claim, arena/content/knowledge, intent, cut, facing, metrics, projection, lighting and atlas versions. Reuse a region when its kind, bounds, encoded instances and local material records match. A changed dense depth key can rebuild a nearer region. #696 can narrow that set later. [Retained chunks](../../packages/render-2d/README.md#retained-chunks)

**D-5, D-6.** Refuse an unaffordable replacement and keep the current drawing and mapping. Mark unresolved foreground as loading wherever it could hide a rear cell. Discard private builds and report the binding limit once on entering refusal. Capacity refusal installs no waiter.

At construction, use checked arithmetic to reserve the declared CPU allowances for controls, bounded planning scratch, pins and chunk descriptions once within the shared 128 MiB account. At admission enforce the profile’s limits on targets, regions, quads, pending spans, input runs and intervals (including split copies), planner work, and chunk slots and bytes. Check the unculled recorder window. Two pins per target cover the drawn revision and one successor. With `W` targets, `K` chunk slots per target and `C` encoded bytes per chunk, vertex payload is bounded by `W × K × C ≤ 128 MiB`. Candidate, drawn, retiring and failed chunks all occupy slots, including across close and reopen.

**D-4.** Use the renderer’s FIFO barrier/release lane. A slot holds any built prefix until physical disposal. An unpublished chunk needs only upload disposal. A failed release retains its identity and cause while independent cleanup proceeds. [Renderer lifetime](../../packages/render-2d-vulkan/README.md)

| Ending | Disposal and caller outcome |
| --- | --- |
| Close | Revoke the view and withdraw its demand. Atomically hand a published claim back with a real empty revision. Return an unpublished claim directly. Lease close reports `retiring`, `done` or `already_released`. |
| Lease/client or arena revoked | Invalidate authority, cancel pending moves and hand back any live claim. Report revocation. |
| Target retired | Drop that incarnation’s claim and demand. Report target gone. |
| Graphics owner ends | Stop admission and settle outstanding calls as stopped or failed. Drain with native dependencies live. |
| Session ends | Retire targets, drain copies, uploads and frames, then return the reservation. |
| Failure | Discard private builds. A failed handback protects the scene through session teardown. Preserve primary and cleanup failures, including device loss. |

## Controls, picking and editing

For #646, `openView` settles at attachment and `moveView` at the eligible camera transition, with recoverable pressure. A move without Z restores follow. Explicit Z selects manual depth. A newer admitted move or camera change cancels a pending jump. Lighting changes survive it. `configureView` accepts a validated partial camera/lighting/depth update atomically or returns busy. `closeView` revokes immediately through the lease.

**D-7.** `pickView` uses the plan tag and metrics from successful presentation enqueue, or successful submission on the registered offscreen target. Adoption alone leaves the drawn receipt unchanged. Allow one synchronous pick per target. Protect its pin through evaluation, then release it when the frame can no longer draw and the pick has returned. Only opaque handles, requests and forced compact results leave the view.

| Cursor and drawn coverage | Result |
| --- | --- |
| Outside, missing/zero drawable, empty pixel or covered fog | `no_hit` |
| Missing drawn plan, mismatched nonzero metrics or unresolved coverage potentially in front | `loading` |
| Known covered part at the physical pixel centre, looking through atlas holes | Cell, content revision and opaque token |

Residency churn alone preserves the drawing. Sample the current residency generation on each hit. In final removal settlement, check the issuing terrain service, lease, arena, cell, content, knowledge, generation and drawn view/target/tag/metrics. This also catches changes during storage preparation.

## Review hazards and tracker changes

| Hazard in PR #697 | Observable outcome |
| --- | --- |
| Capacity wakes, peer churn, leaked charges | Refusal preserves the drawing and the caps. |
| Orphan builds, early release, failed handback | Guarantees 2 and 6 hold across every ending. |
| Lost pins, lazy results, stale authority | Guarantees 3–5 hold through resize, revocation and edit settlement. |
| Scheduler-dependent tests | Compare drawn output, settlements and final ownership. |

Reuse `Camera`, `Facts`, `Cells`, `CellPick`, the atlas adapter and scene ledger. Adapt #697’s inputs, style, claims, region grouping, draw and edit checks. Drop its worker, keeper, byte accounting and wake tests.

Amend #636 §6 with the fixed view reservation and caps, and §7 with the six guarantees. Preserve §3. #647 composes the session and handles refusal without replaying failed moves or edits. #648 qualifies the drawn result and GPU lifetime. B absorbs #705. Keep #706 for truncated runtime demand and #710 for independent rendering and release witnesses. #709 and #711 are obsolete for this view. Preserve original flake receipts. Defer #713’s untrusted and multi-session cases.

## Delivery · draft issue bodies

Both issues use the qualified toolchain. Run each selected check once at the final head, including planner-selected groups and applicable native selections (`--match 'terrain views'` and `--terrain-views-full`). Record command, head and evidence. Note a flake with its example, seed and original result. Never fix or rerun it in these issues.

### TRA-9-V2-A. Publish retained terrain in the graphics session

Implement the session-owned view, its four control operations, retained publication, draw receipt and retirement.

1. On window and offscreen paths, a coherent scene reaches the recorder. Byte-identical regions keep their refs. Changed terrain, knowledge or style appears correctly, including mixed fog and distant contributors.
2. Exercise admission at and beyond the caps, including runtime and recorder refusals. Record profile counts, declared reservation, occupancy and measured peak heap.
3. Cover the six endings, including an in-flight build, a held GPU batch, a full release lane and M1 handback. Account for each resource or terminal failure.
4. In the native run, measure owner-thread planning time within the frame and record it against that run’s frame budget. If planning exceeds the budget, move pure planning off-thread in this issue. Hand only the latest immutable result back to the graphics owner and join the planner inside the session.

### TRA-9-V2-B. Pick the drawn frame and reject stale edits

Use A’s draw receipt for the fifth operation and the terrain runtime’s final removal check.

1. Compare captured pixels and picks with the independent oracle for known parts, holes, fog and loading. Cover resize and an accepted successor that never drew.
2. Show that residency churn preserves the drawn revision, invalidates an old token and permits a fresh pick on the same frame.
3. Through real edit settlement, a valid token edits its cell. A superseding drawn revision, revoked authority or a relevant change during storage preparation returns `stale_view` with terrain intact.

## Approved amendment for #714 · Copy admission from the destination camera

The owner approved this section at `8b8e7f32cf` with “Y” on 2026-11-21 at 02:39:46 UTC.

A preparation copies every storage region the cell planner can read for one camera. It admits that set as a whole. A cap refusal preserves the displayed terrain or M1 scene and its drawn mapping. Runtime camera demand gives those same regions priority for residency. This amends delivery A. The six guarantees, the “F” amendment, and the scope of delivery B still apply. [#714 amendment F](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7052799078) · [Readiness review](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7052832709)

### Settle the camera, then enumerate its reads

Capture the live view, target, arena, content and knowledge revisions, metrics and current intent. Use the destination of a pending move as the anchor. In follow mode ask the terrain runtime for the **surface of that one column** (`surfaceWith`). Its answer includes the arena and content revision and the highest remaining occupied level after removals. A matching answer can be reused for the same column. A present surface sets the reference to its top plane and the cut to its level plus headroom, capped at the world ceiling. An empty column clears the followed surface and retains the camera's existing reference and cut, as `Camera` does today. A failed read yields a runtime failure. A superseded answer is discarded. The surface request uses the runtime's bounded query and settles before any regional request. Its result is a scalar and contributes zero regional copies.

Manual depth uses the camera's specified cut and reference. An explicit-Z jump uses the destination Z and its top plane. Its existing destination-readiness test examines the terrain part for that tile in the destination copy. If that part is unavailable, settle the pending jump with recoverable pressure and keep the old camera. A pending jump becomes eligible once the coherent destination inputs fit and its readiness and authority checks succeed. Settle it once at the camera transition. Later builds and presentation keep their existing boundaries. A newer camera intent supersedes the jump, and lighting alone preserves it.

Let **F** be the set of region keys touched by the planner's geometric reads. The cell planner and footprint calculator must share the same geometry function in `terrain-render-2d`. Feed it the settled anchor, fractional position, reference, cut, facing, zoom, target mapping, margin and depth.

1. Use `startCells`' padded visible rectangle and projected envelope for the inclusive band `[cut − depth, cut]`. For each candidate of matching parity, use `evaluateColumn`'s per-row intersection to obtain the inclusive cell levels `[lo, hi]`. Skip an empty intersection. This includes distant contributors whose level projects into the viewport.
2. In the rotated view frame, include the candidate column over `[lo, min(cut, hi + 1)]` and its two nearer columns at offsets `(+1,0)` and `(0,+1)` over `[lo, hi]`. These are the three state reads used for drawing, fog, mixed parts and the occlusion proof. Rotate back to world axes, intersect each read with the representable world, and floor-divide X/Y by 16 and Z by 32. Union the keys, including every level-region crossed. Membership is independent of contents, cache history, the previous anchor, quad pickability and pending-span listings.
3. Missing usable metrics defer drawable preparation. A zero drawable has an empty geometric footprint. Handle an empty set directly without sending an invalid empty snapshot request. If an explicit-Z jump needs a destination-readiness key outside the drawable footprint, include that single key in its copy budget and check it separately from visible residency priority. A close or revocation can always progress.

### One admission decision

The graphics owner holds one candidate per view. Its pure work runs on the existing session planner. Enumerate under the column/work bounds, with checked wide arithmetic and bounded set insertion. A first excess key proves `LimitRegions` without allocating the rest of an oversized footprint. A geometry work bound reports a planner refusal. On a fitting set, request disjoint nonempty batches up to the smaller of the profile request size and the runtime hold bound, with one request outstanding. A runtime configuration that cannot serve even one required key refuses. Splitting is transport only.

For each returned key require exactly one held entry at the captured arena/content/knowledge version. Count each removed interval and the knowledge inputs the planner will actually receive. A uniform one-run region counts once. Otherwise count every run of every column, including repeated uses of a shared class. An explicitly unavailable part contributes zero runs for that part and keeps its unavailable state. A missing entry is a failed copy. A version change discards the candidate. Residency generations may differ across coherent copies.

Use one total over the fixed set. Count packed input before expanding it into planner structures. Keep the current batch under its runtime borrow until it can be transferred within the view's existing reservation or discarded. Checked, monotone subtotals can prove failure early. Success requires exact coverage, a fitting total and the current basis. A discarded, missing or over-budget batch can never become “asked” coverage. A run excess reports `LimitRuns`. Return every borrow, including a late settlement after cancellation. A stale failure can discard only its own preparation. A current refusal settles a still-pending move with pressure and installs no capacity waiter.

Plan once from the admitted inputs. A settled plan may contain loading where a held part was genuinely unavailable. Pending foreground continues to cover anything it could hide. Plan-wide, recorder and GPU limits keep their existing refusals. Pins need only the plan, camera, metrics and compact copy identities for the receipt. Release superseded input scratch, including outstanding pure work that can still read it, before another candidate uses its allowance.

### Residency demand

Form the runtime list from all of F, including copied, fog-only and unavailable regions. Append distinct prefetch keys outside F from the configured horizontal chunk margin around its column windows over their level band. Generate only as much optional ring as its work budget and remaining demand slots allow. Submit the visible-first prefix of length at most `limitCameraRegions`, once per demand replacement. A short camera allowance can leave some visible regions without residency priority while their copies still draw. Ties within a priority class have no gameplay ordering.

Check the client owns the live arena lease at attachment. Apply demand under a current view/intent check, with the runtime's authority check and the recording of its receipt in one transaction. A runtime `Left` prevents adoption of that candidate. Distinguish requested keys from the runtime's admitted, pending, excluded and truncated results. A successful truncated receipt leaves the copy decision intact. Completing a staging-truncated residency demand belongs to [#706](https://github.com/coghex/hetoimasia/issues/706).

### Measured copy cost and worst-case bounds

Cold open of the TRA-9 headless fixture at (0,0), facing south, 320 × 240 at unit scale, pristine loam over granite. The surface was level 1, the reference 2, the cut 26 and the depth 250. Each zoom ran once on the real terrain service. The PR columns count every returned batch up to its first publication. The proposed columns count disjoint batches of up to 64 keys from the shared read-window rule. Runs use `plannerRuns`. Packed bytes sum `regionSnapshotFootprint`, which includes batch headers and excludes the shared source. They measure copy backing, separately from planner allocation and process peak heap.

| Zoom | PR regions | Proposed regions | PR runs | Proposed runs | PR packed bytes | Proposed packed bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 (default) | 32 | 36 | 3,100 | 3,104 | 8,992 | 9,952 |
| 0.125 (widest) | 164 | 164 | 15,504 | 15,504 | 45,280 | 45,152 |

At 1× the four extra regions lie in the nearer-column reads at vertical region indices −6 and −3. Each is buried and has one uniform knowledge run. Their entries add 1,088 bytes, offset by one fewer 128-byte snapshot header. At 0.125× the region sets are identical and one fewer header accounts for all 128 bytes saved. Both PR preparations published. The proposed measurement exercised geometry and copying only. Scratch baseline `master@cee917e1` with the #716 source at `93485f78` and a local census in the TRA-9 rig. Command in that checkout: `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests -- --match 'copy admission census'`. Result recorded on `#het-tsolve` under request `user-het-tsolve-20261107-0421`.

Keep the default 512 regions and 131,072 expanded runs. A highly fractured region alone can supply 4,096 removed intervals and 8,192 knowledge runs. The global run limit still binds across regions. For **R** distinct required keys and **U** input runs/intervals, packed backing is bounded by **1,024R + 4U bytes**, even with one snapshot per region. Per key, a 128-byte snapshot header, a 200-byte entry, two array headers, rounding and the knowledge class map fit within 1,024 bytes. Terrain needs at most four payload bytes per interval including its column prefix. Knowledge needs at most three per expanded run including its class prefix. This gives a default packed ceiling of **1,048,576 bytes per candidate**, independent of batch size. Apply this derived bound to the whole copy. The region and run limits enforce it without another configurable limit.

The profile already reserves **9,437,184 bytes per target** for copied inputs and their planner entries (`2,048Rmax + 64Umax`) within the **101,744,640-byte** session reservation. These are declared costs. Independently, a 64-region request can require up to **2,403,456 bytes** in the runtime retained bank before settlement, plus its ordinary request record. That bank can refuse even a candidate that fits the view. Keep the existing recorder, slot, GPU and shared CPU ceilings. [Snapshot encoding and reservation](../../packages/terrain-runtime/backed/Hetoimasia/Terrain/Runtime/Backed/RegionCopy.hs)

### Acceptance examples for the amendment

Run each example once. Compare outcomes, using independently known destination keys or counts. Every refusal below preserves the previous revision and mapping, including an existing M1 scene before first terrain publication.

| Review edge | Single-run outcome and reason |
| --- | --- |
| Some required regions already copied | A destination needing four distinct regions under a cap of three returns `LimitRegions` even when two overlap the drawn view. F contains all four. |
| Previous camera's copies refuse a move | Two disjoint footprints each fit the region cap exactly. Moving publishes the destination with its ready coverage because only destination keys enter admission. |
| Ready copies disappear from residency demand | With four runtime places and at least four ready footprint regions competing with prefetch, all four submitted keys belong to F. The complete view can still draw. |
| Fog has no pick cell | Give the whole footprint exactly enough runtime places and offer prefetch. Its fog-only region gets a place and still conceals the cell. With the region cap one below the footprint, the replacement refuses. |
| Bounded visible listing hides pending regions | Set `clDemandChunks = 0` with a pending footprint larger than the region cap. The replacement returns `LimitRegions`. Geometry supplies every key before any demand listing exists. |
| A rejected seed batch counted as asked | With one-region requests, edit a multi-region view so each batch fits but their expanded input total exceeds the cap. The outcome is `LimitRuns` and the prior drawing. The only successful copy result covers every key. |
| Old anchor's runs charged to the destination | Give the move exactly the destination's expanded-run budget. The origin fits separately and their union exceeds it. The move lands and the destination publishes, including with both anchors inside one possible request's size. |

Also exercise a removed source summit whose actual top is in another vertical region, an empty followed column, and explicit-Z moves whose destination part is ready or unavailable. Compare an all-ready scene with the full-input oracle across a rotated region seam with a distant contributor and occluding neighbors. A content or knowledge change between split copies cannot produce a mixed drawn tag. Two clients of the same runtime cannot attach with one another's lease. A refusal racing a newer move leaves that move eligible. Proposal acceptance adds no required copy order or step count. [Round 2](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7052753333) · [Round 3](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7055000359) · [Round 4](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7055360102)

### Replacement in PR #716

In `TerrainView.Session`, replace the seeding in `startIfDue`, the over-budget fallback in `stepCopying`, the extra requests in `stepInputting`/`settleCamera`, the discovery of keys from outputs in `planOf`, the append/afresh branches in `stepPlanning`, and the unchecked `setDemand`. Remove `profileRounds`, `prepRounds`, `prepSeeding`, `prepRegions` as an asked-set, the cross-round `prepNeeded`, the old demand seed, `plannedNext`'s copy branch, and the round-exhaustion meaning of `cdIncomplete`. Preserve independent invalidation for failed uploads. Route the immediate `moveView` path through the same destination eligibility rule so cached origin facts cannot bypass it.

Replace the tests that derive their expected region cap from `regionsCopied`, allow a spare region of runs in the move budget, or treat an empty `cdVisible` as proof of coverage. Delete their obsolete measurement helpers where unused. Keep the split-copy expanded-run regression, pure camera/Cells planner tests, the stale-refusal guard, runtime bank refusals, capture and native zoom assertions, draw receipts, retirement, shutdown and final-head evidence. View-specific close reporting and the evicted-metrics M1 regression remain separate outstanding #716 fixes within A.
