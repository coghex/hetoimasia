# Shared terrain arenas and regional reads in Lua

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[x]` linked to an issue.

## Processing status

- [x] EPIC. Share live terrain and coherent regional reads with Lua — [#743]
- [ ] LUA-TERR-1. Attach a Lua instance to a host-published arena
- [ ] LUA-TERR-2. Copy one regional terrain and discovery snapshot to Lua

## Epic contract and evidence

A native client must be able to demand terrain through its view while a Lua instance queries the same live edits through the stock API. A script must also be able to take a bounded copy of terrain and discovery at one pair of revisions. Both operations belong in the engine's CPU terrain integration.

The downstream `verifyLuaAuthority` probe passes the same service to the facade and the native view. Runtime `setViewDemandSTM` rejects the Lua client's lease with that view. Separately, the adapter's `nameKey` scopes Lua names to a session and content root. Native attach by plain name therefore misses. The downstream settlement control observed surface 0 at revision 0 and −3 at revision 1 in the same incarnation. It used a custom binding. The native regional API already supplies both revisions and independent terrain and knowledge availability.

## Decisions

**D-1. Publish one owner lease to one content root at session assembly.** The Haskell constructor is `terrainInjectionWithArena ∷ TerrainFacade → RootKey → ArenaLease → IO (Either Refused TerrainInjection)`. It validates and borrows the host's live creator lease on the facade's service. The injection holds a reference for the sessions where the host explicitly installs it. It acquires no lease and keeps no arena alive. The original injection remains available.

**D-2. Return one whole region per request as ordinary copied Lua values.** The call names exactly one native region, covering 16 × 16 × 32 cells. A result contains both native knowledge facts for each available cell. The fixed M1 profile must carry a worst-case region. A tighter profile that cannot carry it refuses the call before admission. This gives consumers a bounded, self-contained result without pagination or a snapshot handle.

## Open questions

Q-1 resolved by D-1. Q-2 resolved by D-2. The manager approved both on 2026-11-24.

## Delivery plan

### LUA-TERR-1. Attach a Lua instance to a host-published arena

Either role in the selected root calls `api.terrain.attach_host()` and takes an ordinary arena handle. Use the instance's registered client and the existing request/adoption path. Extend the runtime's attach operation to accept a live creator lease as the source, validating it at the point the destination lease is issued. The new lease belongs to the requesting client, conveys attachment rights (including ordinary removal), and cannot grow or retry storage. Native code retains its creator lease and uses it with its own view. Existing Lua names have their current meaning.

| Condition | Observable outcome |
| --- | --- |
| Foreign service, ended lease or non-creator supplied at assembly | Typed host refusal. |
| Unpublished root or session, or owner gone before a later attach | `not_found`. Reopening the native name cannot redirect the grant. |
| Request or lease places full | `nil, busy`. Both sides return their reservations. |
| Cancel, release, instance end | An unadopted offer is released. Releasing the attachment cancels its work and leaves the owner and other clients usable. |
| Final owner lease released with Lua attached | Arena closes. Outstanding arena work can settle `arena_closed`; the stale handle cannot reach a replacement. Release remains repeatable. |
| Service closes | Admission closes, outstanding work settles through ordinary cancellation or arena closure, and leases drain. |

Test through the stock session and a real native view. Demand succeeds with the native lease. Cell, column, surface and status through the Lua lease agree with native reads before and after a native edit. Cover hidden roots, stale publication after name reuse, creator-only operations and cleanup when cancellation wins adoption.

### LUA-TERR-2. Copy one regional terrain and discovery snapshot to Lua

Either role calls `api.terrain.region(arena, {x=rx, y=ry, z=rz})` with region indices and takes a `terrain_region` request. It works with any valid instance-owned arena handle, including an ordinary Lua open. Haskell already exposes `withRegionSnapshot` and the asynchronous equivalent `regionsWith` with take/retire/release. Use the latter in the existing request machinery so Lua never waits on the terrain owner. Make the complete bounded copy outside STM while the borrow is held. Release it after copying, before Lua takes the reply. Nothing in the reply may retain snapshot storage.

Return `{content_revision, knowledge_revision, terrain, knowledge}`. Each part has `state="ready"` and a dense `cells` array, or `state="unavailable"` with no cells. For local zero-based coordinates the Lua index is `1 + x + 16*y + 256*z`. A terrain cell uses the stock air/material/shape fields. A knowledge cell carries separate `solid` and `void` values, each `"none"`, `"known"` or `"unknown"`. The two part states are independent. Only the index mapping defines order. No revision is read from a later status request.

| Condition | Observable outcome |
| --- | --- |
| Invalid address, whole region beyond extent, foreign or released handle, worst-case reply over VM byte/depth/element ceilings | Ordinary pre-admission error, no request or borrow. Count the complete encoded reply, including keys and wrappers. An unrepresentable revision follows the existing host-defect rule. |
| Request places or runtime hold/retained bank full | `nil, busy`; no partial result or retained charge. |
| Missing terrain or knowledge data | The affected part reports `unavailable`. A ready unknown void remains distinguishable from unavailable knowledge and from air. |
| Cancel, release, instance end, arena/service close, copy failure | One terminal outcome. Retire an untaken result or release a taken borrow on every exit. An already copied success remains coherent through later edits or closure. |

Compare the Lua copy to a native regional snapshot at the same revisions, including a shaped solid with unknown void, and independently unavailable parts. Check the maximum region on the stock profile, tightened limits, and native hold/byte accounting after success without a Lua take, cancellation and close. Use causal gates only where needed to observe ownership.

Both slices are independent and can land in either order. Each changes the owning terrain facade contract and its focused CPU tests. The design adds no graphics, game rules, persistence format, scheduling guarantee or new worker pool. No arc label is proposed.
