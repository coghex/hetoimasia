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

## Approved amendment for #714 · View lifecycle

The owner approved this section at `741cb5e9cd` with “Y” on 2026-11-21 at 16:48:26 UTC.

At `7194e362`, minimizing a populated view clears its runtime demand. Restoring the same metrics satisfies the published-basis check, so the demand stays empty. The window adapter can also miss the minimize altogether. Both failures follow from using a record of a past draw to answer a question about the target now. This section amends delivery A. The approved destination-copy rule, amendment F and the boundary with #715 and #717 continue to apply. [Round 6](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7059053106) · [Round 7](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7059489440)

### What the view observes

| Input | Owner and observation |
| --- | --- |
| Authority and geometry | Read the session gate, original leases, target incarnation, usability and claim together. For a window, subscribe to the window client's observation in STM, including while no frames are recorded. **Zero** means an observed zero dimension in either logical or framebuffer extent, even if scale or the other extent is missing. **Extent** requires complete, valid positive metrics. All other incomplete observations mean **Unknown**. Offscreen registration supplies the same three values from its current metrics cell. Target retirement is an authority change. |
| Camera and intent | The view owns the last settled camera (initially absent), the initial camera settings, latest validated camera/lighting intent and the optional move with its settlement cell. An admitted control advances an intent identity. Settling or rejecting that move consumes its cell under the same identity. A follow-surface answer belongs to one arena, column and content revision. |
| Preparation basis and readiness | Read arena incarnation, content and knowledge revisions from the runtime. Capture them with view/target identity, geometry, intent and exact style/atlas interests. Using the approved prospective camera, derive F and, for an explicit-Z move, the additional destination key if needed. Only Zero proves F empty without a geometry walk. Unknown defers that walk. Surface replies, split-copy totals, readiness of the destination terrain part and finished plans/builds are evidence for that particular preparation. |
| Applied outputs and ownership | The session keeps the accepted terrain revision if any, its basis, bounded demand prefix, parts and pins. Separately keep the runtime view's last successfully installed prefix and receipt, initially empty, and the renderer's actual drawn receipt. The owner also observes the status of its own jobs, uploads, ledger pins and disposals. These records survive only as long as their consumers need them. |

`Window.Host.observedGeometry` must preserve observed zero. `windowViewTarget` must read live geometry even with a cached nonzero frame. Recorded metrics still describe that frame for drawing and picking. An unversioned cache cannot fill gaps in a newer observation. A fresh unknown window may use the existing initial-scene bootstrap when no scene is showing. An existing M1 scene stays until the first accepted terrain publication.

### Reconcile demand, publication and controls

Evaluate these rules on one current snapshot. The worker obtains missing evidence or applies a differing output. If everything is satisfied or waiting on an existing operation, it has no work. Recheck authority, basis, candidate identity and the captured move before committing an effect. Late results surrender only their own resources.

1. **Demand.** Give each accepted terrain revision its residency list. For a drawable target, the desired list is the accepted revision's list (empty before the first acceptance), replaced by the successor's list at acceptance. For Unknown, Zero or an ended view the desired list is empty. Compare it with the *installed* list on every reconciliation, including when the accepted revision already fits the restored metrics. Replace a differing list once under the live runtime authority and record the receipt. At publication, commit a required demand change and scene acceptance together. If either refuses, commit neither replacement and record the cause. A demand-only restore needs no new scene or tag. A truncated successful receipt is current for the submitted list. Completion of truncated residency remains #706's.
2. **Compute the list within its bounds.** Take distinct visible keys from all of F up to `limitCameraRegions`. F empty gives an empty list. Otherwise use remaining places for distinct region keys outside F from the configured horizontal margin and level band. Walk the clipped ring incrementally, charging the configured chunk, interval, per-chunk region and work allowances in their own units. A horizontal chunk can supply several vertical keys, each consuming one runtime place. Skip duplicates, meter the scan and stop at the first exhausted applicable bound, retaining the prefix already produced. Skip the ring entirely when no place or work remains. Produce this prefix on the planner from the shared read windows, without first constructing `cdPrefetch` for the whole ring. Neither the extra Z key nor cache status gives a key visible priority.
3. **Camera eligibility.** Unknown defers destination admission. At Zero, F is empty but a follow move can still need its scalar surface answer and an explicit-Z move still needs its destination terrain part. Admit F plus the extra key together under the approved caps. Never send an empty regional request. While evidence is outstanding the move stays pending. With coherent, fitting inputs and a ready destination, commit the settled camera and answer `MoveLanded` once, even at Zero. A current refusal before eligibility answers `MovePressure` and retains the settled camera. Later build or publication failure preserves a move's completed result. A newer admitted move or camera update supersedes a pending move. Lighting alone preserves it. Open settles at attachment. Configure validates the whole update and uses the settled camera's presence for its existing busy result.
4. **Publication.** Unknown and Zero keep the accepted revision or M1. At Extent, once destination eligibility is established, a proven empty F produces a complete clear terrain plan with the current camera, mapping, style and arena versions and no chunks, quads or pending coverage. Let the cell planner construct this plan from its own empty-footprint proof and current identity, so it needs neither a prior source nor a dummy snapshot. Readiness-only copies supply no draw content. Nonempty F follows the approved copy, plan and build admission. A current, valid accepted revision suffices. Otherwise accept the complete successor under the existing host, pin and upload checks. The drawn tag and its mapping advance only at the existing draw boundary.
5. **Refusal.** Record the limit and the attempt's basis, including the admitted intent identity, in the guarded settlement. While this record applies, keep the accepted scene, its drawn mapping and the demand prescribed by rule 1. Consume the pending move once and discard private work. Removing the pending jump is an outcome of that attempt and cannot itself re-arm it. Report entry into refusal once. A new intent, geometry, content or knowledge basis can prepare afresh using the camera then requested. If retry depends on a resource, compare only a relevant observed change that can make the request fit (for example, sufficient reusable slots on that target). Returning the failed attempt's own reservation to its starting value, a peer's unrelated disposal, a frame wake or unchanged residency cannot keep an attempt spinning. No capacity waiter or replay of a settled control. Residency churn alone preserves a valid publication.

### Transitions derived from those rules

Here **keep** includes an existing M1 scene or no terrain revision. A retained scene's demand is its stored visible-first prefix. Each row gives the observable outputs once its stated inputs settle.

| Event or new observation | Runtime demand | Publication | Control outcome |
| --- | --- | --- | --- |
| Attach with Unknown, or lose usable metrics | Empty | Keep | Open attached. A move awaits geometry. |
| Minimize, including after a recorded frame | Empty | Keep | Eligible moves can settle under rule 3. Close remains available. |
| Restore the same metrics, then minimize again | Retained prefix on restore, empty on minimize | Keep if the basis still matches | No replay |
| Resize or change cut, facing, zoom or lighting | Retained prefix until acceptance, then new prefix (empty if F is empty) | Accept the current complete plan, including a first clear plan | Valid configure settles atomically. Only camera changes supersede a move. |
| Content or knowledge edit | Accepted prefix until replaced | Recompute at current revisions. Keep on refusal. | A pending move needs matching inputs. |
| Move with fitting inputs, including ready explicit Z | New prefix at acceptance on Extent, empty on Zero | Accept on Extent, keep on Zero | Land once at eligibility |
| Destination unavailable, copy or build refused, or demand replacement refused | Last successful installation. Suppress a failed replacement at its refusal basis. | Keep and record refusal | Pressure only for a still-pending move |
| New relevant input after refusal, or stale work returns | Reconcile the live view's desired list | Only a current candidate may replace | A stale refusal cannot settle a newer move. |
| Close, revoke, retire target or end session | Withdraw by closing this runtime view | End claim and hand back a published live target under the existing endings table | Pending moves end once. Drain that view's ownership under amendment F. |

### A refused build still has an owner

Reserve the target slot and its vertex allowance before `handBuild`. The renderer knows whether it allocated a buffer. Extend the result of `buildRetainedChunkWith` so every refusal describes either **no allocation** or **an allocation in disposal**, with buffer identity, the release outcome and access to physical-disposal status. Propagate this through the builder and production owner adapter. Validation or buffer-creation refusal can return the reservation immediately. Upload backpressure, permanent upload refusal and reference exhaustion after allocation all transfer the reservation to disposal. The renderer initiates release once. The session tracks the allocation even though it never received a `ChunkRef`. Successful registration transfers ownership to the existing chunk path.

Make the handoff exception-safe from allocation onward. A raised error after allocation must leave a tracked allocation or an identified cleanup failure. A bare exception is insufficient evidence to unreserve. `releaseBuffer` requests release. The backend's `constructedDisposal` confirms destruction. Only `DisposalDone` frees the slot and bytes. Pending remains charged across close, reopen and competing builds. Failed release or destruction retains identity, charge and cause while independent cleanup continues. A refused, unpublished buffer needs no scene barrier. Accepted chunks retain their existing upload, frame and FIFO release protections.

Distinguish a refused *build call* from a refused *view replacement*. Transient upload backpressure can leave the candidate and its successful prefix in flight. Resume only with evidence of upload capacity and an available charged slot for the next build. A permanent build failure takes rule 5. In either case, close and disposal progress independently of a drawable frame.

### Changes to the current implementation

Replace `startIfDue`'s published/invalid/idle tests, `vsIdleAt`, `settleWith.withdraw`, the `vsSource` branch and the separate `vsReady` flag with the observations and output comparisons above. Replace the overloaded publication Boolean with actual part validity, and the global freed-counter refusal test with the current refusal and its relevant inputs. Keep one bounded candidate, serial and move guards, packed counting under borrow, latest pure planner, owner-only build/publication and the independent invalidation of failed uploads. Wake the reconciler on changes to its observed inputs or completion of its outstanding work. Ledger, receipt and owner-queue notifications may coalesce. A kick carries no instruction to rebuild or settle. Extend the existing disposal ledger to represent a refused allocation as well as a registered chunk.

### Approved #714 amendment and acceptance

**Amendment text.** Derive this view's runtime demand, terrain publication and control settlement from the current authority, observed geometry, camera intent and readiness under the rules above. Restore demand independently of drawing. Publish a drawable empty footprint as a coherent clear revision. Retain a refused allocation's charge until confirmed destruction. Apply the following acceptance examples alongside amendments F and S. Each runs once and checks outcomes. Ordering within a priority class, owner steps and elapsed time are free.

| Example | Observable outcome |
| --- | --- |
| Draw at 320 × 240, minimize, restore to 320 × 240, minimize again | Inspect the installed request and runtime disposition at every state. The visible prefix is present, empty, present again and empty again. The matching retained revision and drawn mapping survive. |
| Production window adapter with cached nonzero frame metrics | Supply an observed zero framebuffer without recording another frame. The view sees Zero and its runtime demand clears. Missing framebuffer information yields Unknown. A later complete positive observation restores Extent. |
| First drawable at a world corner with F empty, and a populated drawable changed to the same empty coverage | Both show a tagged clear terrain revision with an empty plan and demand, including over an M1 predecessor. Neither requires a regional copy. |
| Explicit Z on a minimized populated target with a ready destination | Its readiness-only copy fits and the move lands. Demand stays empty and the old publication, drawn tag and pinned metrics survive. Restoring prepares the landed camera. |
| View-level unavailable Z after a real draw | Supply an unavailable destination terrain part at the copy boundary. At owner quiescence the move has one `MovePressure`, the camera and drawn tag/pin are the originals, and the published revision has not advanced. Exercise the view's real settlement and receipt paths. |
| Current refusal, unrelated wake, then a changed intent | The unchanged refusal has one report and preserves the drawing at quiescence. A later affordable move lands and publishes. A delayed refusal for the superseded attempt cannot alter that result. |
| 36 known visible regions, 37 runtime places, `clDemandChunks = 1` | All 36 visible keys and one distinct eligible ring key appear in the submitted demand. With zero optional work only visible keys appear. |
| Over-budget split batch | At a deterministic gate **inside packed counting** for the offending held batch, observe its outstanding runtime charge. On release of the gate the view refuses with `LimitRuns`, returns that borrow once, and keeps the pre-edit drawn tag, camera and metrics. A final zero balance alone cannot establish ownership during counting. |
| Production retained build refused after vertex allocation | With destruction held pending, a competing build cannot spend the slot or bytes, including across close/reopen. Once the backend confirms destruction the capacity is reusable exactly once. A pre-allocation refusal leaves no outstanding charge. |

[Issue #714](https://github.com/coghex/hetoimasia/issues/714) · [Amendment F](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7052799078) · [Amendment S](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7056078928) · [PR principle audit](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7059259004) · [PR conformance table](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7059259209)

## Approved amendment for #714 · Chunk-build admission before allocation

The owner approved this section at `3277c13c93` with “Y” on 2026-11-21 at 20:42:22 UTC.

**Proposed #714 amendment.** A retained chunk build must secure capacity before creating its vertex buffer. A refused reservation owns nothing. Temporary pressure keeps the current candidate and its built parts. An impossible replacement is refused once, keeps the drawing and retires its private parts. A failure after admission retains its resource identity and cleanup outcome. This replaces amendment D’s “A refused build still has an owner”, its corresponding ledger change and its final acceptance example. It applies to delivery A under the existing six guarantees and amendment F’s teardown scope.

### Who can promise capacity

At `3daefcc0`, `buildRetainedChunkWith` creates the vertex buffer before `submitUploadGated` tries to place its bytes. The native upload service already owns the queue, staging geometry and placement function used by textures and buffers. Extend that service with a reservation for the exact byte length of a future vertex buffer. Expose it through the live gate in `gpu-vulkan-glfw` and the renderer’s `Builders` interface. The view only needs the renderer’s prepared part, its admission result and its chunk standing. [Backend admission contract](../gpu_backend.md#uploads) · [Round 10 rule audit](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7067720819)

1. **Prepare.** The renderer validates the chunk and derives the exact cutout byte length using its encoder’s layout. At grant, it also reserves a generational chunk reference, private until registration. An invalid chunk or exhausted reference space can therefore refuse before construction. A part with zero encoded bytes needs a reference and a logical slot only.
2. **Observe or reserve in STM.** Both operations use the same backend decision. Read owner admission, terminal and upload-service state. A configured service awaiting startup can become ready. An absent configuration, failed startup or ended service supplies its cause. For a positive byte length, round up to the backend staging granule. A padded request larger than staging is permanently oversized. Otherwise require one queue place and one aligned contiguous gap for the padded length under the backend’s existing placement rule. A missing place or gap is temporary pressure. Observation is read-only. A grant occupies both immediately in the ledger shared by **all** upload callers.
3. **Spend once.** The upload service owns an opaque session-bound reservation for that size and range. Only its reserved state can bind the fresh buffer or be abandoned. Binding verifies session, live gate, fresh vertex target and exact bytes, takes the usual exclusive target hold and transfers the existing place and range to the copying upload. Queueing rechecks the gate. Neither transition competes for capacity again. A spent, cancelled or foreign handle cannot change a live entry. The owner performs allocation and binding within a scoped build. An unused grant is returned on failure, supersession, cancellation or scope exit. Close invalidates unused grants. An active copy retains its range until its writer exits, and a queued upload retains it until ticket settlement under the existing drain rules.

### What the view waits for

Keep the candidate’s total number of fresh parts after reuse, and its **live** set of still-unbuilt parts. For each bounded owner step, reconcile the current candidate, its authority and its own chunk standings. Before testing current upload room, compare the remaining part count with the target’s free slots plus slots already retiring independently of this candidate. Each slot counts once. Exclude the displayed revision, reused parts, the candidate’s own prefix, and permanent losses. Apply the target’s byte allowances and check each remaining part’s padded size against the staging ceiling. Successive parts may reuse staging after settlement.

If completion is possible, the owner takes the next part’s target slot and byte allowance, renderer reference and upload reservation in **one STM transaction** guarded by the live basis and candidate identity. A failed grant commits none of those claims. The granted build counts as this view’s work through close or reopen. The owner then allocates, fills and registers the part. A current candidate takes the resulting reference and removes exactly that part from the remaining set. A superseded build hands its result to private retirement.

If the next part is temporarily blocked, keep the prefix. The session watcher reads the same next-part decision in STM and requests owner work when it becomes actionable. It also reads the candidate identity, live part standings, recoverable slots, authority and publication gates. A failed or missing part, an impossible candidate, or all parts ready with publication room are independently actionable. Read the level condition when arming the wait and recheck it on the owner. A coalesced notification, including completion before the first watcher read, is sufficient. A blocked owner step returns so uploads and disposal can progress. Only a complete current candidate can publish.

If the remaining parts exceed recoverable capacity, record the binding limit against the live basis and retire the private prefix once. Keep reused and displayed parts, the drawn mapping and last installed demand. For a slot refusal, record the **whole** fresh-part requirement for a new attempt after discarding the prefix. Its own retirement cannot satisfy a shortage that made completion impossible. A changed basis or enough genuinely reusable capacity can admit a new attempt under lifecycle rule 5. Oversize remains binding at the same size and configuration. A settled move keeps its result.

### Failure after a grant

The renderer owns the build until it hands a registered chunk to the view. Mask the handoffs so the build records the buffer identity as soon as it exists and every exit accounts for it. A failed build returns its unpublished reference and any unspent upload grant. Before buffer creation it also returns the target charge. After creation, one cleanup owner requests release once, or adopts the release that native construction already started if naming raised. Record the primary cause, buffer identity and release result before returning or propagating cancellation. Transfer the charged slot and bytes to that disposal record. Only `DisposalDone` returns physical capacity. A refused or raised release, or a later failed destruction, keeps its charge and identified cause while independent cleanup proceeds. A successfully registered chunk takes the charge and follows existing upload protection and FIFO frame retirement.

Remove `AllocationReleased` and `BuildRaised` accounting from **admission refusals**, the `BuildsWait` ticket comparison, `cdUploadWait`, `awaitUploads`, `ownerUploads` and the view’s dependency on `unsettledVulkanUploads`. An identified construction or disposal failure after a grant still has an owner.

- Control admission reads the live graphics-owner gate in the same transaction that accepts a move or configure and settles any superseded move.
- The public `buildRetainedChunk` result preserves a post-admission cleanup failure’s buffer identity and cause, including a raised release.

### Single-run acceptance for #714

Use deterministic gates or supplied backend states. Each example runs once and asserts observable outcomes. Chunk order, frame count and elapsed time are free. [Round 8](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7066648913) · [Round 9](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7067150987) · [Round 10](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7068012004)

| Given | Observable outcome |
| --- | --- |
| A texture or another view occupies the last queue place, or fragments staging so total free bytes suffice but no aligned gap fits | Unrelated wakes and ticket turnover at unchanged pressure produce zero new vertex allocations, releases or target charges. When a fitting gap and queue place coexist, the candidate completes, including when room returned before the watcher sampled and a peer ticket is still held. |
| Four fresh parts, four slots, one independent buffer awaiting destruction, upload room restored first | Three available slots can hold usable parts. Their references survive the wait for the fourth slot. Once destruction completes all four publish together within the cap. |
| A candidate has a private prefix and an unrelated upload stays held. A charged buffer’s release fails immediately or its pending destruction changes to failed | Once the remaining parts exceed recoverable slots, the view records one refusal even while upload admission is blocked. Its prefix retires once. The lost buffer stays identified and charged across reopen. Prefix retirement adds no refusal or retry. The prior drawing survives. |
| One part’s padded size exceeds the whole staging buffer | The replacement reports the oversized request once, keeps the scene and mapping, and leaves no private prefix or outstanding admission. Ordinary queue pressure on a fitting part preserves its prefix. |
| The last queue place and fitting range have been reserved while a competing upload arrives. The build spends its grant or exits unused | Only one caller owns the capacity. A consumed grant cannot bind twice or free the live upload’s range. An abandoned grant admits a fitting successor once. Clean scope exit accounts for the in-flight view slot and every grant. |
| Native naming raises after allocation, or the build fails after binding and release refuses or raises | One release site accounts for the buffer. Pending destruction holds the charge through close/reopen and confirmed destruction frees it once. A cleanup failure retains the buffer and both causes, including through the public wrapper. |
| A quiet offscreen candidate’s final upload settles between watcher samples | With no frame or caller kick, completion permits first publication. A failed upload instead retires the private candidate and preserves the previous scene. |
| Clean owner exit closes action admission while an earlier move is pending and the watcher has yet to record closure | A second move and camera or lighting configure return `ControlEnded`. The first move settles once as `MoveEnded EndStopped`. |
| A drawn view has one recorded zoom refusal. Minimize with the lease live and deterministically refuse the demand withdrawal, with no intervening move | The refusal count goes from one to two. The last installed list and receipt survive, as does the drawing. Unchanged wakes leave the count at two. |

## Approved amendment for #714 · One settlement per chunk-build spend

The owner approved this section at `3e2c2755e8` with “Y” on 2026-11-21 at approximately 23:59 UTC.

**Proposed #714 amendment.** Replace the mechanism in “Failure after a grant”. Each admitted build has one record of what it owns. On every exit the graphics owner settles that record before returning a value or propagating an exception. The admission decision, six guarantees and amendment F’s teardown scope still apply. [Approved admission](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7068947065) · [Round 12, findings 1–4](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7070130411)

**Record and handoffs.** The renderer creates the record on the issuing grant in the admission transaction. It holds the private reference and optional upload grant. For a view build, the same transaction associates it with the originating view, target incarnation, candidate part and charge, and increments that view’s build count. Install the owner-thread finalizer under the admission mask. Only the issuing registry may abandon a reserved grant or claim it for spending. Once claimed, only its spend may settle it.

| Handoff | Fact made durable under the mask |
| --- | --- |
| Start | `Reserved → Spending` in STM. The spend initially owns no buffer. An unused reservation can go directly to settlement. |
| Construct | Record the returned buffer before another interruptible operation. Construction must account for every managed buffer it creates. If native naming raises, its `ReleasedResource` context identifies the buffer whose release it already committed. Adopt that release for either exception class. A construction refusal or exception with no managed allocation leaves the buffer field empty. |
| Bind | The record refers to the issuing upload grant’s standing. The backend marks it spent in the same STM transaction that transfers the queue place and staging range to the copying upload. This fact is available even if copying exits before a ticket returns. Zero-byte parts skip construction and binding. |
| Register | Insert the reference and mark it registered in one STM transaction, with the buffer and ticket when present. The registry now owns the chunk. |

**Settlement.** The scoped spend runs one masked finalizer on the graphics owner thread. On failure it retains the primary refusal or original exception with its context. For an owned, unregistered buffer it requests release once, capturing success, refusal or **any** exception from cleanup, including cancellation. An adopted release already has its outcome. There is no interruptible gap from acquiring either outcome to recording it. The finalizer commits the following disposition and immutable receipt in one STM transaction that never waits for GPU work. The renderer supplies its grant and registry operations. The proposed settlement hand-off below revises when the session transfers its view-ledger charge. Public builds use the renderer disposition alone.

| Record at settlement | Disposition |
| --- | --- |
| Unused or unregistered, no buffer | Return the private reference, any still-reserved upload room and the view charge. Record the build cause on failure. |
| Unregistered buffer, release requested successfully or adopted | Return the private reference and any still-reserved upload room. Transfer the target charge, buffer identity, primary cause and disposal reading to the disposal ledger. `DisposalDone` frees the charge once. Failed destruction retains the charge, identity and both causes. |
| Unregistered buffer, release refused or raised | Return the same unused grant capacity. Retain the charge in the failure ledger with buffer identity, primary cause and release failure. Independent cleanup can proceed. |
| Registered | Transfer the charge and reference to the current candidate, or to private retirement if superseded. A public build hands the reference to its caller. Existing upload and FIFO frame protections govern disposal. |

Every row consumes the originating view’s build count once and seals the grant as returned or registered. A sealed grant and a foreign or losing claimant have no accounting action. The upload service alone recycles room already bound to a writer or ticket. Only a still-current candidate may acquire a part or record a replacement refusal.

**Public contract.** Both `buildRetainedChunk` and `buildRetainedChunkWith` project the same sealed receipt. Success returns the reference. An ordinary refusal returns `BuildRefused` with allocation and release evidence, including a synchronous cleanup failure. On a raised exit, attach the receipt as a typed, publicly readable annotation to the original exception, preserving its type and context. Propagate the build exception if it was cancellation, otherwise a cancellation raised during cleanup, otherwise the build exception. Thus cancellation during cleanup of a refused upload carries the refusal too. The receipt names any buffer, the release outcome and both causes when both operations failed.

Remove the `interrupted` callback, the spend adapter’s `guarded` conversion, and the session’s `handed`, `onException` accounting and unknown-allocation `raisedBuild`. Returned values and exception handlers can report the sealed outcome without applying it again. Keep live admission, candidate revalidation, disposal observation and existing release-lane handling.

**Single-run acceptance.** Use controlled backend outcomes. Each row checks ownership and the caller-visible result.

| Given | Observable outcome |
| --- | --- |
| Production view adapter, constructor raises before allocation | The actual cause survives. Build count and target occupancy return to baseline with no lost allocation. Grant capacity is reusable. Close reports retiring while a later real build is held. |
| Native naming is cancelled after allocation, with destruction held pending | Cancellation identifies the already-released buffer. Its slot and bytes remain unavailable across close/reopen. Confirmed destruction makes that capacity reusable once. |
| Upload refuses before binding and release raises `ThreadKilled` | Cancellation carries the upload refusal, buffer identity and release failure. The failed buffer remains charged. A competing build with its own target room can acquire the returned reference capacity, queue place and staging range. |
| Public `buildRetainedChunk` is cancelled after allocation and release refuses or raises synchronously | The caller catches the original cancellation and reads the exact buffer and cleanup outcome from its settlement annotation. |

## Approved amendment for #714 · Settlement hand-off and post-bind upload exits

The owner approved this section at `ec219909f7` with “Y” on 2026-11-22 at 02:16:47 UTC.

**Proposed #714 amendment.** The renderer seals the spend and retains its receipt. The view collects it in a second transaction. Each owner commits its own transitions using strict data and operations on its own or explicitly shared records. Caller-supplied actions run outside those commits. From admission until transfer, one scoped cleanup owns every exit. This replaces the same-transaction view transfer in the [approved spend amendment](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7071245012). Its four dispositions describe the outcome across seal and collection. Build-count consumption belongs to collection or sweep reconciliation.

**Receipt and charge.** At admission, create an opaque, registry-bound receipt cell unique to this grant, including when a refused reference is later reissued. Index it in the registry and put its handle in the session’s pending-build ledger alongside the originating view ID, target incarnation, candidate serial, part key and slot/byte charge. This is the existing admission transaction. A pending entry counts as one build of that view. Both indexes survive the spending stack and view close.

| Boundary or exit | Committed outcome |
| --- | --- |
| Renderer returns a chunk, refuses, abandons an unused grant, raises synchronously or is cancelled | The masked spend finalizer registers the chunk or returns the private reference and still-reserved upload room. In that same commit it writes the immutable outcome to the receipt cell as **available**, owned by the registry. Abandonment seals only an unused reservation. Foreign and duplicate claimants change nothing. |
| Construction, upload or release waits, raises or is cancelled | While work is outstanding the recorded owner retains the resource. An interrupted wait takes the same finalizer. Adopt a release already made or request it once, recording buffer identity, disposal or failure, and both causes. The seal contains no callback, user thunk, explicit STM wait or GPU wait. Internal STM conflict retries expose no partial transition. For public builds the existing masked hand-off delivers the reference to the caller, returns the refusal, or propagates the selected original exception with its context and receipt. |
| View collects an available receipt | A single view-owned commit claims the cell, removes its pending entry (one build count) and moves its charge. A current candidate takes the exact part. A superseded registration goes to private retirement. A refusal with no buffer frees the charge. A released buffer goes to observed disposal. A failed release goes to the failure ledger with identity and both causes. Only the matching current attempt can record a replacement refusal. |
| View revalidation or collection raises, retries, or is cancelled on either side of commit | A committed collection stands. Otherwise the receipt and pending entry survive together. Revalidation runs separately and produces strict evidence. At collection compare live authority, geometry and basis versions plus candidate identity using owner-maintained data cells. Each source changes its version in the transaction that changes its value. Stale evidence selects private retirement. On retry, relinquish collection to sweep and yield the owner step. On a raised exit request the same sweep under the mask before propagating the original exception. |
| View closes, a collector disappears, or collection races a sweep | Close marks that view’s pending handles for sweep, including grants still spending. The session reconciler observes the cells independently of the originating step. A finished or cancelled owner-step ticket with a pending entry requests the same sweep, even if its collector never ran. Registry teardown sweeps remaining available receipts before releasing native dependencies. Claiming for sweep and claiming for collection compete on the same cell. Duplicate and losing claims change nothing. |

Sweep claims an available receipt for registry retirement. For a registered chunk the registry retires the private reference under its upload protection and records physical disposal or identified failure. For refusal it uses the release evidence already in the receipt. The session can reconcile a sweep claim without geometry, a live view or a callback. It removes the originating pending entry once and retains any outstanding charge against the same target through reopening. Only no allocation or confirmed destruction frees that charge. Closing reports retiring while the old view has outstanding work. A new view may use the released capacity but can never collect the old part. Drop the registry index only after collection or durable transfer to registry retirement. Existing handles retain the outcome. The session drops its pending handle when it reconciles the charge.

**Native upload.** Check the caller’s gate before bind and again after the mapped write, before queueing, in separate interruptible checks. A gate may admit, refuse, raise or retry. To preserve atomic closure, an admitting answer carries a read-only permit for the gate’s current generation. The gate owner invalidates it in the same transaction that closes or changes admission. Bind and queue each verify the permit and the upload service’s own live state in their native commit. A bare earlier Boolean cannot authorize either transition. A retry yields a recoverable gate refusal without holding the graphics owner on an STM wait.

| Upload exit | Owner of queue place, aligned staging range and exclusive target hold |
| --- | --- |
| Before bind, including gate refusal, exception, retry or cancellation | The upload takes nothing. A live reservation remains spendable or abandonable. |
| Bind commits | The upload entry owns all three and a supplied grant is spent. Install its finalizer under the admission mask before restoring interruption for the copy and gate checks. Close keeps staging mapped while the writer can still touch it. |
| Write, second gate or queue attempt refuses, raises, retries or is cancelled before queue commits | One masked, nonwaiting cleanup keyed by the upload ID forgets only an admitting entry, removes its target bookkeeping and returns all three. Return the refusal or propagate the original exception after cleanup. The old grant stays spent. |
| Queue commits, including cancellation before the caller receives its ticket | The queued entry owns all three through ordinary ticket settlement or close. The same finalizer observes the transfer and leaves the entry to the queue. Retirement can finish once active writes exit and queued work drains. |

In #716 remove the settlement callback from `spendChunkGrant`, `viewGrant` and `grantSpend`, its `catchSTM`, `settlementRaised` and the matching exception branch in `stepBuilding`. Move `handOn` and `refusedBuild` accounting to receipt collection. In `submitWith`, replace the write-only exception handler and separate gate-refusal cleanup with the scoped admitting-entry finalizer. [Round 13, finding 1](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7071852031) · [Round 14, findings 1–3](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7072655992)

**Single-run acceptance.** Use controlled outcomes at the production seams. Each case runs once.

| Given | Observable outcome |
| --- | --- |
| A build refuses before allocation. View collection raises, retries, or is cancelled during revalidation. | A competing build can take the returned reference and upload room. The originating build count and target occupancy return to baseline once. The refusal and any raised cause remain identifiable. |
| Registration succeeds and the view’s geometry read raises. Close and reopen with destruction held pending. | The prior scene survives. The old chunk has one retirement owner, its originating build count settles, and its charge limits the reopened view. Destruction releases the charge once. A late collection can neither publish the old part nor free a second slot. |
| A granted upload binds the last place and only fitting range. The write raises, or the write succeeds and the second gate raises, retries or is cancelled. | The submitter observes the original failure, refusal or cancellation. The spent grant is stale. A fresh native submission can use the same place, range and still-live target, and retirement completes. Through the view adapter, one buffer stays charged while destruction is pending and confirmation frees one slot. |
| Gate closure races queue commit after copying. | Closure first yields a refusal and reusable capacity. Queue first yields an upload owned through ticket settlement, even if the submitter is cancelled. Both outcomes preserve the target hold until its owner is finished. |

## Approved amendment for #714 · Ownership transactions in #714

The owner approved the revision at `304853d8db` with “Y”. The manager recorded the approval on 2026-11-22 at 14:58:34 UTC. [Amendment D5](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7080954190) · [Foundation prerequisite #721](https://github.com/coghex/hetoimasia/issues/721)

**Approved revision to #714 amendment D4.** The owner selected narrower issuer access on 2026-11-22. This revises the boundary approved at `aa1f784758`. Across delivery-A package boundaries, ownership changes are concrete `OwnerTx` operations or IO wrappers over prepared data and opaque handles. Coupled writes compose in one commit. The approved hand-offs, spend dispositions and cleanup owners apply. [Amendment D4](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7080687421) · [Round 16](https://github.com/coghex/hetoimasia/pull/716#issuecomment-7075380166)

**Public and issuer interfaces.** Foundation's public `OwnerTx a` stays abstract, with sequencing and `commit ∷ OwnerTx a → IO a`. The public domain operations accept neither caller STM nor a callback, reader or caller-built transaction to execute in the commit. Issuers keep their private STM and existing state. They may embed a concrete operation through `fromIssuerSTM ∷ STM a → OwnerTx a` in `Hetoimasia.Foundation.OwnerTx.Issuer`. Each embedded path must use issuer-controlled inputs, validate before writing, return refusals as data, and finish without waiting or raising. GHC checks the public types. Review and outcome tests must check those properties inside each issuer, including its callees.

Put the bridge in a named Foundation sublibrary, `owner-tx-issuer`, with `visibility: public` for cross-package issuer dependencies. The ordinary Foundation library exports the abstract type and safe API. The proposed guard revision below allows named Cabal components to depend on the bridge. It assigns each such component's Haskell imports, exports and instances to issuer review. An external component that deliberately depends on the issuer sublibrary is outside that guard.

| Issuer | Operations composed by #714 |
| --- | --- |
| Foundation admission, GLFW handoff and Vulkan controller | Issue, verify and permanently close the parent's admission token. Enqueue view steps and FIFO barriers by opaque handle, observe and settle tickets. The action body runs in IO. |
| Terrain runtime and Settlement | Export attach/detach, install/restore/clear prepared demand, and take/retire a view request as concrete `…Tx` operations over the existing `St`. Check the parent's token in the commit. These paths use direct bookkeeping and model updates and must never dispatch an arbitrary host endpoint. |
| Native recording/uploads and renderer `Chunks` | Reserve, bind, queue, forget, settle and close over the native owner's existing cells. Verify permit generation and terminal state in bind/queue. Reserve the reference and room together, then record construction, seal, inspect, claim or sweep. Gates run before bind/queue and observers around the issuer's spend. |
| Scene claims, ledger/receipts, texture `RenderAccount` and terrain view `Session`/`Owner`/`Surface` | Compose the claim, reservation, demand and scene changes for attach, publication and close. Collect or sweep the receipt, transfer charges, reconcile and retire. Expose the coupled operations through opaque handles and keep waiting readers outside the commit. |

**TRA-5 and observed facts.** Existing TRA-5 hosts retain their endpoint API and atomic ready, eligibility and settlement semantics. For view surface and region requests the issuer constructs a sealed request handle and endpoint internally. Ready is a no-op, eligibility is true, and settlement uses a nonwaiting `tryPutTMVar` on the view-owned result box in the arbitrating transaction. The issuer supplies that concrete operation. The view API accepts no endpoint or user action. Its watcher observes the box and schedules reconciliation after settlement, replacing the inline `kick`. The view's take/retire operations accept only its request handle. Lease liveness, window showing and roots terminal status can be read-only publications. Their source installs the forced value and its revision together with the source change, including teardown.

**Delivery split.** Land the foundation issue first. Carry forward `25ebedcb`'s abstract transaction and commit, optional cells/read capabilities, revisioned publications, and `Exit` with context-preserving classification. Keep generic mutation helpers issuer-side wherever they accept functions. The foundation issue delivers the issuer bridge and Cabal split, the guard and its fixtures, positive composition over existing STM, negative public-client examples and publication/exit outcome tests. Its acceptance covers Foundation without a graphics dependency. Under the proposed revision, #716 consumes the merged API, lists the components that need the bridge and submits their adapters for review alongside the domain operations, shared decisions and integration acceptance below.

**Strict inputs.** Reuse Foundation's nominal `Prepared` and `prepare` at the IO boundary with issuer-defined, concrete payload types and complete `NFData` instances. For example, the surface writer accepts `Prepared (Maybe TargetMetrics)` and installs value and revision together. Force the command envelope, nested payloads, keys and diagnostic text before `commit`. Opaque capabilities are already-issued identities. Revalidation captures candidate, target, authorities and intent, geometry, arena/content/knowledge and lifecycle revisions in one read-only snapshot and forces it in IO. Collection compares identities and writer-maintained revisions, replacing `liveWitness`/`currentBasis` in the commit. Failed preparation leaves the prior value and revision intact. Once capacity is held, force results inside the protected operation whose cleanup owns it.

**Exits.** Foundation supplies one `classifyExit` for the spend, upload and view adapters. Given the operation's result and issuer terminal status, it distinguishes refusal, recoverable raised operation, cancellation and terminal failure (including escaped fatal construction). The host puts the original exception with context on its action ticket. `ownerGone` and drain consume the classified disposition instead of treating every `StepRaised` as terminal. Format text in protected IO. Carry formatter cancellation through settlement with the approved priority.

| Exit | Durable result and delivery |
| --- | --- |
| Refusal, stale evidence or read that would wait | Apply the existing refusal, private retirement or relinquish-to-sweep disposition. Yield when waiting for a named change. |
| Synchronous revalidation/collection failure with a live owner | Under the mask relinquish any still-pending receipt, then rethrow the original exception. The action ticket reports that exception with its context. The owner remains available for retirement and reopen. |
| Cancellation, terminal backend failure or permanent owner exit | The current cleanup first seals, relinquishes or observes the completed transfer. Deliver the selected exception or terminal refusal. End the service on the host's terminal disposition. A transient admission refusal leaves it eligible to run again. |

**One decision per fact.** Round-16 findings 1, 2 and 3 correspond to parent admission, exception delivery and strict writer inputs respectively.

| Finding | Decision shared by producers and consumers |
| --- | --- |
| 4 | `nextCandidateWork` returns runnable work, a wait on a specific writer revision, or an ended candidate. Collection and sweep apply it to the surviving candidate after accounting, and the scheduler consumes that same decision. A stale no-allocation claim can free its charge and schedule reconciliation in one commit, even when the geometry value compares equal. |
| 5 | `receiptOutcome` projects the write-once result. Inspect, collect and sweep use it. Claim changes a separate one-shot ownership flag and drops the index on transfer. The original handle still projects the full outcome. |
| 6 | `nextRetirement` selects work from current upload standing, holds, barriers, disposals and receipts. Readiness asks whether that selection can advance. Retirement recomputes the same selection when taking work, including an orphan entering the owner's hand. |
| 7 | Native recording's `releasedHandleOf` decodes one kind-tagged release record made from the actual managed handle. Generic identity and buffer lookup project from that result. A released pipeline or image retains its own kind. |
| 8 | The existing queue-transfer rule covers this case. The missing proof is cancellation after queue commit and before ticket delivery. |

**Single-run acceptance.** Compile an issuer composition and a client using its public operations. The public client must fail to lift caller STM/`retry`, install a session-admission reader, or pass raw metrics to a view commit. The proposed guard acceptance below exercises an unlisted Cabal dependency and prohibited Cabal re-exports and mixin renamings. Exercise the view endpoint through TRA-5 arbitration: one settlement is visible, the view resumes, and taking or retiring the request transfers or releases its borrow once. Run each outcome below once.

- Close parent admission during demand replacement. The old scene and demand survive a closure-first refusal, and a publication that wins commits both. Attachment and restore verify the same token.
- Supply failing deferred metrics between revalidation and collection. The writer observes the error and the build settles against the last accepted version. Separately, advance the version with equal geometry after a pre-allocation refusal on an idle target. The candidate progresses and its charge settles once.
- Observe the original recoverable exception and context on the action ticket, then retire and reopen. Observe the same full receipt before and after either collection or sweep, with one successful claim.
- Hold an orphan's upload pending during drain. Its retirement decision becomes runnable when the upload settles, and drain releases it once. A pipeline or image naming failure yields its own release identity and an empty buffer projection. A buffer failure yields its exact buffer.
- At a private IO rendezvous inside the protected hand-off after queue commit and before ticket delivery, cancel the submitter. The last place, range and target remain held by the queued upload through settlement, become reusable once, and retirement completes.

### Proposal for owner approval · revision · Cabal issuer dependency guard

The owner chose C after round 3 of #722. On approval, the following wording replaces the guard clauses in D5 and #721, including the module-level additions in its readiness review. [D5](https://github.com/coghex/hetoimasia/issues/714#issuecomment-7080954190) · [#721](https://github.com/coghex/hetoimasia/issues/721) · [Readiness additions](https://github.com/coghex/hetoimasia/issues/721#issuecomment-7081097300)

**Replacement #721 goal.** Keep an exact allowlist of repository components (package, component kind and name) in `tools/validation/owner_tx_issuers.json`. It must equal the components whose effective `build-depends` selects `hetoimasia-foundation:owner-tx-issuer` in at least one supported buildable configuration. Initially this includes `hetoimasia-foundation:test:foundation-tests` for issuer composition. Reject a missing or stale entry. Reject any component's Cabal `reexported-modules` or `mixins` renaming that exposes or renames `Hetoimasia.Foundation.OwnerTx.Issuer` or `Hetoimasia.Foundation.OwnerTx.Representation`, including through an alias and in a listed component.

Use Cabal's parsed declarations for `cabal.project`, `cabal.project.vulkan` and their local imports. Keep literal local package directories, Simple manifests, all supported component kinds (including tests, benchmarks and foreign libraries), expanded common stanzas and structured package/library selectors with version bounds. Check both branches of manual flags and the Linux/Darwin × x86_64/aarch64 target matrix. Reject unsupported selection or visibility forms, including optional packages, out-of-set condition atoms and Backpack signatures, before dropping any branch. An unresolved library selector, protected-module origin or manifest option that could change package visibility fails with the manifest and component/configuration. Ordinary Cabal builds supply compiler options, package macros and source selection.

**Review contract.** Cabal/GHC package visibility keeps the bridge unavailable to ordinary clients built against the main library. Within an admitted component, any module can import it. Review its modules and Foundation's private representation consumers for where issuer code runs and what reaches clients. Outside the defining modules, prohibit exports that convert caller STM to or from `OwnerTx`, directly or via a wrapper, class method or re-export. Prohibit adapter instances on STM or the protected Foundation types and any bridge-equivalent representation export. Keep Foundation's `Cells`/`Operations` split, opaque handles, nominal publication roles, prepared writes and context-preserving `Exit`. Safe observation and publication through STM remain public.

**Replacement #721 guard acceptance.** Use buildable minimal packages with ordinary Cabal visibility. Accept the listed dependency and reject an unlisted dependency, a stale entry, a protected Cabal re-export or mixin renaming, and unsupported manifest scope. Include an inactive branch and a Vulkan-project-only package. Assert the policy diagnostic. Preserve the exact-main-unit public-client compile and compile-fail examples, composition and Foundation outcome tests. Keep `test.owner-tx-guard` mandatory on `haskell-workflow` with the 300-second budget and existing selection on sources, manifests, project imports, tool and allowlist changes. Remove the guard's header/CPP and typed-interface passes, per-module export contracts, source fixtures for those passes, and its GHC library dependency if unused. The manifest check needs no store lookup. A compiler test that needs one retains the project-independent lookup and diagnostic.

**Disposition of review findings.** Numbers follow each PR comment, including the two Foundation findings at the start of round 1.

| Round | Cabal fixtures and retained tests | Issuer review and retired guard machinery |
| --- | --- | --- |
| [1](https://github.com/coghex/hetoimasia/pull/722#issuecomment-7083224073) | 1–2 keep nominal-role and failed-publication tests. 3 keep a dependency selected only in the second branch. 7–8 keep compact version selectors, nested common imports and foreign-library dependencies. | 3–6 branch-specific module imports, aliased Haskell exports, constructor exposure, wrapper conversions and braced/CPP imports move to review. |
| [2](https://github.com/coghex/hetoimasia/pull/722#issuecomment-7084607111) | 6–8 keep optional-package, unsupported-target and manifest-signature rejection. 10 keep read-only checkout coverage and store diagnostics where compilation needs a store. | 1–5 and 8–9 import/export behavior under target macros, dependency variants, nested or same-named types, instances, boot files and entry points goes to review against the actual Cabal build. Retire the guard's target preprocessing, type traversal, source loading and store discovery. |
| [3](https://github.com/coghex/hetoimasia/pull/722#issuecomment-7085674580) | 5 retain a project-import/conditional dependency fixture for Cabal scope. 12 the passing external consumer depends only on public libraries. Build it through Cabal and compile any client cited as evidence. | 1–7 and 11 retire synthetic home units, interface reuse, macro/option replay, preprocessor execution and entry-point identity checks. Review the actual component and its source variants. 8–10 review type identities, instance methods and the origin of defining exports. 12 retire the guard's instance-client fixture. |
