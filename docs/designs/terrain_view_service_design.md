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
