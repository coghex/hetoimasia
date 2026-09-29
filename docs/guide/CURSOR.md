# Guide cursor

Resume after: `59272883680df53425673059695cf93818414c0a` · [2026-09-29T150521Z-5927288](2026-09-29T150521Z-5927288.md) · 2026-09-29T15:05:21Z
Covered beyond the boundary: none

## Next

Finish #304 (PR #316, `reviewed:changes`). If another round finds more ordering gaps, settle the capture's order-claim protocol as a design decision rather than patching again.
Then close epics #155 and #268 and choose the next arc; the owner-sequenced GPU-model `State.hs` decomposition is recommended.

## Open findings

None.

## Pending handoff

- #304 / PR #316 is the one open repair from 2026-09-29T121551Z-50cecce; its third review found an ordering gap after an abandoned claim.
- Test races keep surfacing after merge (#280, #284, #306, #308, #313); an owner-requested flake-lab sweep of the foundation, headless Vulkan and diagnostics suites is suggested.
- Epics #155 and #268 are complete but still open, with stale checkboxes (tracker housekeeping).
- No settled next slice: the `State.hs` decomposition (recommended), a 2D renderer design, trusted-Lua slices (D-13/D-14), or Wayland WL-4 under #202.
- Qualification gates remain open: Lua confinement (both verdicts inconclusive) and Wayland rendering WL-4.

## Alignment

| Principle | Reading | Since | Note |
|---|---|---|---|
| V-1 | aligned | 2026-09-29T150521Z-5927288 | |
| V-2 | aligned | 2026-09-29T121551Z-50cecce | |
| V-3 | aligned | 2026-09-29T150521Z-5927288 | #311 restores exact reservation accounting |
| V-4 | aligned | 2026-09-29T121551Z-50cecce | |
| V-5 | aligned | 2026-09-29T150521Z-5927288 | |
| V-6 | aligned | 2026-09-29T150521Z-5927288 | #312 closes the replacement liveness gap |
| V-7 | aligned | 2026-09-29T121551Z-50cecce | |
| V-8 | aligned | 2026-09-29T121551Z-50cecce | |
| V-9 | aligned | 2026-09-29T121551Z-50cecce | |
| V-10 | aligned | 2026-09-29T150521Z-5927288 | Test races are repaired as they surface; see the handoff |
| V-11 | aligned | 2026-09-29T121551Z-50cecce | |
