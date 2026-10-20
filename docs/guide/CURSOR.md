# Guide cursor

Resume after: `edefc398ba6af202897476864b61086973c627bc` · [2026-10-20T150446Z-4e70eff](2026-10-20T150446Z-4e70eff.md) · 2026-10-20T15:18:54+00:00
Covered beyond the boundary: #489, #490, #491, #501 (2026-10-20T150446Z-4e70eff)

## Next

Finish #503 / PR #504 → resume amended #499 / PR #502 → qualify #500. LUA-5/6/7 and the runner/sample core are delivered; the old readiness advice is obsolete. Continue the uncovered lifetime-heavy guide inventory separately.

## Open findings

- 2026-10-20T150446Z-4e70eff/GUIDE-1 — release lifecycle test callback gates on assertion failure before protected teardown — unprocessed.

## Pending handoff

- Partial review: PRs #465, #469, #470, #471, #477, #478, #479, #480, #481, #484, #485, #495, #496, #497 and specs #464, #466–#468, #472–#476, #482/#483, #492–#494 remain uncovered. Boundary intentionally unchanged.
- #503/#499 are open work, not delivered. #500 is approved but blocked; deterministic qualification remains prospective. Follow existing owner review budgets.
- Q-5 remains inconclusive on both platforms; LUA-9–13/16/17 stay gated. After the trusted milestone, owner chooses a named consumer or renewed confinement feasibility discussion.
- #446 remains deferred until a render-to-texture consumer and Q-10; text is an alternative for a named consumer. #145's merged runner/sample checkboxes need routine reconciliation.
- Historical #360/#362 apparatus coverage remains incomplete.
- End recheck at 2026-10-20T15:16:06Z: master remained at the pin; no issue fingerprints or published vision changed. PR #504 updated after the snapshot. Its later revision is pending, and no conclusion here extends to it.
- Owner docs-push rule supersedes V-11's older one-PR docs sentence; no vision or owner draft was edited. Review only: no follow-up walk or tracker changes.

## Alignment

| Principle | Reading | Since | Note |
|---|---|---|---|
| V-1 | aligned | 2026-10-20T150446Z-4e70eff | Application-owned authoritative state and public engine services in #501. |
| V-2 | aligned | 2026-10-20T150446Z-4e70eff | Accepted core/failure/qualification split remains coherent; #503 makes the missing prerequisite explicit. |
| V-3 | aligned | 2026-10-20T150446Z-4e70eff | Core ownership and raw retirement preserve dependency lifetime; open #503/#499 completion obligations remain pending. |
| V-4 | aligned | 2026-10-20T150446Z-4e70eff | Core refusals are explicit; terminal failure handling belongs to amended #499. |
| V-5 | aligned | 2026-10-20T150446Z-4e70eff | Sample reservations remain held through atomic commit; open work must account for all instance and task capacity. |
| V-6 | aligned | 2026-10-16T165532Z-edefc39 | Publication holds and conservative GPU retirement remain; renderer repair does not turn CPU release into GPU completion. |
| V-7 | aligned | 2026-10-16T165532Z-edefc39 | Lua allocating operations protected in C and called safely; material-check optimization uses retained sets with measured historical evidence. |
| V-8 | aligned | 2026-10-16T165532Z-edefc39 | Evidence distinguishes Linux exact-tree reuse, fresh local macOS tests and absent native/confinement qualification. |
| V-9 | aligned | 2026-10-20T150446Z-4e70eff | Trusted independent domains delivered; D-23 qualification remains #500, untrusted deployment remains gated. |
| V-10 | drifting | 2026-10-20T150446Z-4e70eff | GUIDE-1: a merged gated assertion cannot fail within the promised example bound because teardown needs the unreleased gate. |
| V-11 | aligned | 2026-10-20T150446Z-4e70eff | Qualified GHC/Cabal and focused checks; owner docs-push rule supersedes the old one-PR docs sentence. |
