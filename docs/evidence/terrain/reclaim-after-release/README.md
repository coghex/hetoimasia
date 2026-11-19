# Retired pages left unreclaimed after the last reader pin was released (#703)

On an idle owner, terrain-runtime could leave retired pages pending forever once the last reader pin was released.
The cause was the idle mark of internal work, recorded at the store's state when the transaction ended rather than at the store
its plan was given. The repair is `slotBasis` in `Internal/Types.hs`, taken in `grantSlot`'s transaction and recorded by
`slotOver`'s `markIdle`. Every figure is a lab observation on an Apple M3 Max (16 logical cores, macOS 26.7.1) with GHC 9.14.1.

Heads: this branch `760b9bdb` (off master `ebd46690`); #692 `550d3b63` (local, unchanged); the combination `19037224` (local,
never pushed): #692's head with this branch merged. #692's head descends from `ebd46690`.

## The mechanism

Captured in the combination without the repair (scratch traces of grants, reader releases and the idle mark; run 6 of at most 20,
process at `+RTS -N2`):

- A reclamation was granted with the arena store at version 25 and its oldest pin `Just 7`. `maintenancePlanner` keeps that store
  (`Internal/Backed.hs:967`).
- While the plan's page read was in flight, the view's gather released reader serial 5, the version-7 pin. The store version was
  still 25 and the readers were now empty.
- The plan answered `ReaderBlocks 8 7` from the store it was given (`Backed/Txn.hs:257`).
- `markIdle` stamped the arena's state at that moment, `(25, Nothing)` (`Internal/Owner.hs:1447-1450`, `:1480`).
- The chooser's idle test (`Internal/Backed.hs:933-936`) compared the same `(25, Nothing)`, so it never offered reclamation again.
  For 3 s after the check, pending reclaim stayed at 110,592 bytes, with the owner quiescent, no storage job and `inspectBacked`
  empty.

Without a commit or a reader change after that, nothing moved the mark. A commit by unrelated work hid the stall, which is
why it showed only in some runs.

## Deterministic example and control

`terrain-runtime-tests`, `The backed terrain service` › "offers reclamation again once the last reader pin is released while a
reclamation's plan that saw the pin was in flight, with no further edit or request". It runs in the sequential phase and in the
multi-capability pass.

- The pin is a view load's page read held at the seam.
- An owner probe holds each internal grant after a second edit; the example takes the first one made with discovery idle and the
  pin held, and gates that reclamation's first page read.
- The view closes and the pin's read is let go (readers 0, pending unchanged). Then the plan's read is let go, and a bounded wait
  needs pending to fall with no further edit or request.

| | With the repair | Control (the repair reverted) |
| --- | --- | --- |
| Sequential phase | passes | fails: the bounded wait for pending to fall never returns |
| Multi-capability pass (2) | passes | fails the same way |

## Acceptance

| Check | Where | Result |
| --- | --- | --- |
| `terrain-runtime-tests`, the whole routine suite (both phases) | this branch | 1776 examples, 0 failures |
| #692's StorageFaults example alone in place, process at `+RTS -N2` | the combination | 20/20, 0.11 to 1.89 s each, load 12.3 to 12.9 |
| The lua-engine terrain set in place (`--match "/LuaEngine/Terrain/"`, `+RTS -N2`) | the combination | 162 examples, 0 failures |
| The lua-engine terrain set in the pass (`--match "/The multi-capability pass/Terrain/"`, effective 2) | the combination | 162 examples, 0 failures |

The StorageFaults example's own setting is one capability (#692's branch runs every example outside the pass on one); the
process started at `+RTS -N2`. Before the repair it failed in run 6 of this issue's capture, and in about 3 of 16 runs in #692's.
