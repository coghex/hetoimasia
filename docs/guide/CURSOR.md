# Guide cursor

Resume after: `3fe47c7e5fea1b0d4572f44366e55638280cd68d` · [2026-10-14T015849Z-3fe47c7](2026-10-14T015849Z-3fe47c7.md) · 2026-10-14T01:58:49Z
Covered beyond the boundary: none

## Next

Walk GUIDE-1 (2D frames refused forever), then GUIDE-2 (an owner decision on the release barrier). Then renew the Lua design's readiness for the trusted path, the recommended next arc; text is the alternative.

## Open findings

- 2026-10-14T015849Z-3fe47c7/GUIDE-1 — 2D window frames that can never record are accepted and refused every frame — unprocessed
- 2026-10-14T015849Z-3fe47c7/GUIDE-2 — a held window with no target blocks every release request — unprocessed (owner decision)
- 2026-10-14T015849Z-3fe47c7/GUIDE-3 — per-frame scan of every retained chunk instance — unprocessed
- 2026-10-14T015849Z-3fe47c7/GUIDE-4 — stage expiry kills display-helper cleanup and evidence retention — unprocessed
- 2026-10-14T015849Z-3fe47c7/GUIDE-5 — unbounded released-texture set — unprocessed
- 2026-10-14T015849Z-3fe47c7/GUIDE-6 — eleven comment and Haddock drifts — unprocessed

## Pending handoff

- Bookkeeping: #398's done-when appears met; check #202's done-when (all its children have been closed since 2026-09-30); #371 is approved and ready.
- Design horizon: Lua trusted path (readiness renewal owed; the 2026-09-29 VM-owner decision is not yet in `lua_runtime_design.md`), text (D-6), render-3d (FND-3, no consumer yet).
- The #360/#362 apparatus audit remains incomplete (historical).
- 2026-10-03T021430Z-bfcd1bc findings are all dispositioned: #386, #387, and no issue (`f81c449c`).

## Alignment

| Principle | Reading | Since | Note |
|---|---|---|---|
| V-1 | aligned | 2026-10-14T015849Z-3fe47c7 | Pure render and asset packages; samples use public interfaces. |
| V-2 | aligned | 2026-10-14T015849Z-3fe47c7 | Each arc delivered for a named consumer. |
| V-3 | aligned | 2026-10-14T015849Z-3fe47c7 | Completion-gated lifetimes verified; GUIDE-5 is a minor exception. |
| V-4 | drifting | 2026-10-14T015849Z-3fe47c7 | GUIDE-1: frames refused every frame, with nothing told to the publisher. |
| V-5 | drifting | 2026-10-14T015849Z-3fe47c7 | GUIDE-2: blocked releases fill the shared action queue. |
| V-6 | aligned | 2026-10-14T015849Z-3fe47c7 | One table per session; batch-frozen versions; checked refusals. |
| V-7 | aligned | 2026-10-14T015849Z-3fe47c7 | VMA preconditions documented; no FFI boundary changes. |
| V-8 | aligned | 2026-10-14T015849Z-3fe47c7 | Prior receipt drift corrected (`f81c449c`). |
| V-9 | aligned | 2026-10-14T015849Z-3fe47c7 | Lua harness only; no confinement claims. |
| V-10 | drifting | 2026-10-14T015849Z-3fe47c7 | GUIDE-4: expiry can kill evidence-retaining cleanup. |
| V-11 | aligned | 2026-10-14T015849Z-3fe47c7 | Suite identity binds execution policy; receipt drift corrected. |
