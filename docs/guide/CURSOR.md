# Guide cursor

Resume after: `edefc398ba6af202897476864b61086973c627bc` · [2026-10-16T165532Z-edefc39](2026-10-16T165532Z-edefc39.md) · 2026-10-16T17:06:59Z
Covered beyond the boundary: none

## Next

Renew narrow readiness for LUA-5 against the merged general-owner and module APIs (#460/#462) and pure protocol #149. Then LUA-6/LUA-7 → LUA-8, each behind explicit readiness renewal. See the report’s owner next-steps table.

## Open findings

None. All six findings from 2026-10-14T015849Z-3fe47c7 were filed as #447–#452 and their repairs are merged and checked by this run. No new actionable finding.

## Pending handoff

- Trusted Lua runtime integration is unfinished: only LUA-2/LUA-3 had renewed readiness; LUA-5–8 remain deferred. Async/lifecycle binding calls intentionally return NotYetSupported today.
- Q-5 remains inconclusive on both platforms; process/confinement slices LUA-9–13/16/17 stay gated.
- #145’s LUA-3 checkbox lagged closed #462 at the snapshot; routine future manager reconciliation only. #202, #398 and #371 are complete.
- #446 remains deferred until a render-to-texture consumer and Q-10 decision; text is an alternative product arc for a named consumer.
- The #360/#362 apparatus audit remains incomplete (historical); this run does not extend that coverage.
- End recheck found no post-pin commits, changed issue specs, other updated issues, updated PRs or changed published vision. No open PRs at pin.
- Owner docs-push direction supersedes V-11’s old one-PR docs sentence; no vision or owner draft was edited.

## Alignment

| Principle | Reading | Since | Note |
|---|---|---|---|
| V-1 | aligned | 2026-10-16T165532Z-edefc39 | Host remains independent of runtime, graphics and games; application-owned registration and opaque public types. |
| V-2 | aligned | 2026-10-16T165532Z-edefc39 | Owner and module prerequisites delivered separately; runtime/scheduler scope and readiness remain explicit. |
| V-3 | aligned | 2026-10-16T165532Z-edefc39 | Protected close and cleanup composition, independent owners, child reader/pipe reclamation and bounded texture ledger. |
| V-4 | aligned | 2026-10-16T165532Z-edefc39 | Was drifting: prior GUIDE-1 repaired by #447/PR454; observable permanent refusals and frame overflow. Lua faults retain effect/context. |
| V-5 | aligned | 2026-10-16T165532Z-edefc39 | Was drifting: prior GUIDE-2 repaired by #448/PR456; isolated bounded release capacity and accepted revision-zero exemption. |
| V-6 | aligned | 2026-10-16T165532Z-edefc39 | Publication holds and conservative GPU retirement remain; renderer repair does not turn CPU release into GPU completion. |
| V-7 | aligned | 2026-10-16T165532Z-edefc39 | Lua allocating operations protected in C and called safely; material-check optimization uses retained sets with measured historical evidence. |
| V-8 | aligned | 2026-10-16T165532Z-edefc39 | Evidence distinguishes Linux exact-tree reuse, fresh local macOS tests and absent native/confinement qualification. |
| V-9 | aligned | 2026-10-16T165532Z-edefc39 | General trusted owners and explicit grants delivered; async/lifecycle callable support, scheduling and confined deployment remain gated. |
| V-10 | aligned | 2026-10-16T165532Z-edefc39 | Was drifting: prior GUIDE-4 repaired by #450/PR457. Cleanup evidence retention and package-owned failure-path tests; focused fresh checks. |
| V-11 | aligned | 2026-10-16T165532Z-edefc39 | Qualified pinned toolchain and compatible exact-tree receipts; explicit owner docs-push direction supersedes old one-PR documentation wording. |
