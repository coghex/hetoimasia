# Guide cursor

Resume after: `e1c842add120a2eb46531684fc4619cb3aee6a37` · [2026-09-30T040151Z-e1c842a](2026-09-30T040151Z-e1c842a.md) · 2026-09-30T04:01:51Z
Covered beyond the boundary: none

## Next

Both guide amendments are posted to #324 and #349; no findings remain to process.
Finish the remaining structural refactors before resuming shared GPU services; recheck #345's changed sampling specification.

## Open findings

None.

## Pending handoff

- #351 owns the quruntul shader-fingerprint trial failure; #352 implements the #323 Lua aggregate split. Open PR heads are context only.
- Remaining structural refactors: #323/#324/#325; feature sequencing remains owner-controlled.
- Follow-up: revised #345 retains per-draw sampling and has a canonical rereview approval; full newer-spec audit remains pending.
- #330 supplies a settled next service arc; owned-allocator parity (#331/#333) and native bindless support (#343) remain evidence gates.
- Lua confinement remains inconclusive; Wayland rendering qualification awaits #327.
- Unpublished design/vision edits do not change the heading reviewed at the pin.
- End recheck: #345 specification changed and #351 updated; newer states are unreviewed. Default branch/vision stayed at the pin.

## Alignment

| Principle | Reading | Since | Note |
|---|---|---|---|
| V-1 | aligned | 2026-09-29T150521Z-5927288 | Private boundaries preserved |
| V-2 | drifting | 2026-09-30T040151Z-e1c842a | GUIDE-2: amendment posted to #349; implementation pending |
| V-3 | aligned | 2026-09-29T150521Z-5927288 | #316 repairs publication; protected ownership preserved |
| V-4 | aligned | 2026-09-29T121551Z-50cecce | |
| V-5 | aligned | 2026-09-29T150521Z-5927288 | |
| V-6 | aligned | 2026-09-29T150521Z-5927288 | |
| V-7 | aligned | 2026-09-29T121551Z-50cecce | |
| V-8 | aligned | 2026-09-29T121551Z-50cecce | Qualification gates retained |
| V-9 | aligned | 2026-09-29T121551Z-50cecce | Lua model stays pure |
| V-10 | aligned | 2026-09-29T150521Z-5927288 | Package-owned examples preserved |
| V-11 | drifting | 2026-09-30T040151Z-e1c842a | GUIDE-1: amendment posted to #324; implementation pending |
