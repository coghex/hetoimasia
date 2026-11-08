# TRA-18 evidence: bounded symbolic source connectivity

Evidence for [#660](https://github.com/coghex/hetoimasia/issues/660) (TRA-18 of #636),
delivered by pull request [#670](https://github.com/coghex/hetoimasia/pull/670).

**Revision.** Implementation head `dee863db2f5c` (branch `issue-660-source-connectivity`, with
`origin/master` `1b15651df1d9` merged). Every figure below was produced at that revision with the
qualified toolchain (GHC 9.14.1, Cabal 3.18.1.0). The suite's own output is the primary record;
this document restates it with the commands that reproduce it. It qualifies the pure source
compiler only, not live discovery, cancellation, storage durability or arena admission.

## Commands

```sh
export PATH="$HOME/.cache/hetoimasia/toolchain/ghc-9.14.1/bin:$PATH" PYTHONDONTWRITEBYTECODE=1
ghc --numeric-version            # 9.14.1
cabal --numeric-version          # 3.18.1.0
cabal build --project-file cabal.project.cpu lib:hetoimasia-terrain lib:hetoimasia-terrain-render-2d
cabal test  --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
cabal test  --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct
(cd packages/terrain && cabal check)
python3 tools/validation/plan.py --catalog-check
PKG_CONFIG_PATH="$HOME/.cache/hetoimasia/native/glfw/lib/pkgconfig" cabal test workflow-tests --test-show-details=direct
# the connectivity examples alone, with the growth and allocation rows printed:
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct \
  --test-option=--match --test-option="Source connectivity"
```

Results at the revision: `terrain-tests` 825 examples, 0 failures (the connectivity
examples are the `Source connectivity` and `Source connectivity bounds` groups);
`terrain-render-2d-tests` 298 examples, 0 failures; `cabal check` clean; catalog valid (36
groups); `workflow-tests` 965 examples, 0 failures; `cabal build all` exit 0 with no warning.

## What was compared, and with what

The oracle (`Test.Terrain.ConnectivityOracle`) shares no code with the library. It reads the
`SourceSpec` through the naive scan of `Test.Terrain.Model`, takes each shape's top from the
issue's stated rule (shape 0 the full block; otherwise the minimum of the selected expressions
`N = y`, `E = 1 - x`, `S = 1 - y`, `W = x`, bits North 1, East 2, South 4, West 8), decides
whether two face-adjacent cells connect by testing the 32 x 32 exact rational sample centres of
the shared face for membership in both open regions (strict inequalities, so edge and point
contacts contain no sample), and floods a finite window face by face with the supported world
as the only wall. The exterior seeds are the cells of the topmost level whose top face opens.

Every comparison is between the compiled result and that model: void versus no-void; the
partition into components as a bijection with the component keys; the exterior flag of every
component; the cells of every component's ranges against the model's component, clipped to the
window; every portal relation expanded to cell pairs (each must be a pair the model connects,
and every model connection must be inside one box or in an expanded relation); and every
boundary face expanded to (cell, face) pairs against the model's pairs whose across cell is
outside the component, or no cell at all (a limit).

The sealed finite room gives an exact expectation with no outside to leak into: the interior's
four sides are a ring of single-column full-block patches, and its floor and ceiling are full
block layers. The covered open worlds drop the ring: the default content outside the core is
translation invariant, so clamping coordinates into the window is a graph homomorphism and the
window flood reproduces the unbounded plane for the cells compared (one cell inside the window's
edge, or six cells past the core for the wide variants that compare bulk family boxes).

## Generated fixtures and seeds (SplitMix64, `Test.Terrain.ConnectivityFixtures`)

| Family | Default kind | Cases (seeds) | Size and origin |
| --- | --- | --- | --- |
| sealed room | air, then identities 0-15 (index `i = 0..16`) | `100 * i + s`, `s = 1..6` | footprint `(4 + s mod 2) x 4`, 3 levels; origin `(13 s - 20, 7 s - 31, 11 s - 40)` |
| covered open world | the same 17 kinds | `7000 + 100 i + s`, `s = 1..3` | core `4 x 3 x 3`, compared one cell past the core |
| wide covered open world | the same 17 kinds | `9000 + 100 i + s`, `s = 1..2` | core `3 x 2 x 3`, compared six cells past the core |
| open-top world | slab shape `1 + seed mod 15` | `900 + s`, `s = 1..12` | core `4 x 3 x 2`, air above reaching `z = 2^62 - 1` |
| sealed room at an extreme | `3 s mod 16` | `50000 + s`, `s = 1..4` at each of three corners | `4 x 4 x 3` at `(-2^62, -2^62, -2^62 + 3)`, `(2^62 - 4, 2^62 - 4, 2^62 - 9)`, `(-2^62, 2^62 - 4, 2^62 - 9)` |
| all-sixteen cavity | hand built | n/a | the 16 identities on a 4 x 4 square at level 0 of an air layer, ring of full blocks |

Interior patches: each column holds a patch with probability 5/8, one or two disjoint vertical
runs of 1-3 levels inside `[z0 - 2, z0 + h + 2)`; content is air (4/20), a full block (3/20) or a
nonflat shape (13/20, identities 1-15). Every example names the seed that reproduces it.

## Hand-stated fixtures (`Test.Terrain.Connectivity`)

At spans `g` or `L` of `2^20` and `2^60`:

* the default flat source (`stone` below -3, `soil` on `[-3, 1)`, air above): one exterior
  component, 2 nodes, 1 relation, 1 class; stone and soil cells answer `NoVoid`;
* wholly air terrain: one exterior component;
* a covered air slab of `2 g` levels spanning the supported X/Y range: sealed, one component
  from the lowest corner to the highest; with a shaft `(3, -4, [0, 2^62))`: exterior and one
  component with the slab; with a shaft stopping inside the cover `[0, g + 5)`: still sealed;
  air touching only the horizontal and lower limits (cap above `0`): sealed;
* a topmost full block: no opening, no void; a topmost N ramp: each row's top portal reaches the
  outside; an omitted layer upper end read as `2^62`;
* a covered layer of `L` N ramps: separate row channels (parameters `Y`, `Z`), one component along
  a row, distinct for adjacent rows and levels; `E` ramps: columns (`X`, `Z`); `S` ramps along X and
  `W` ramps along Y; the layer under open air joins every row of the top level (and only that level)
  to the sky;
* a full-block patch splitting one ramp channel into two with neighbouring rows and levels
  unchanged; an air shaft through all `L` levels joins row `y0` (both sides) and row `y0 + 1` at
  every level (no parameters left) while `y0 - 1` and `y0 + 2` stay separate rows; a partial shaft
  joins exactly the levels it covers, plus the one ramp cell below its bottom, whose top portal it
  rests on; patches and portals across the negative chunk and vertical-region boundaries
  (`x = -1`, `z in [-33, -31)`); a patch that restates the layer changes nothing.

## Growth, yielding and refusal (`Test.Terrain.ConnectivityBounds`)

The recipe is `n` full-height air shafts and `n` four-level full-block splits through a layer of
ramps (`scaled n L`). Every row is identical at `L = 2^20` and `L = 2^60`.

| n | boxes | nodes | relations | steps | max steps per quantum | result bytes | peak bytes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 6 | 2 | 0 | 902 | 902 | 1,632 | 3,920 |
| 1 | 420 | 250 | 223 | 2,544 | 1,024 | 68,624 | 196,624 |
| 2 | 990 | 590 | 554 | 4,818 | 1,024 | 159,008 | 461,088 |
| 4 | 2,850 | 1,702 | 1,648 | 12,246 | 1,024 | 453,824 | 1,325,248 |
| 8 | 9,450 | 5,654 | 5,564 | 38,622 | 1,024 | 1,499,648 | 4,394,496 |

Accounted bytes are admission figures (the constants in `Connectivity.hs`), not RSS and not
measured allocation. Measured allocation (`GHC.Stats` allocated bytes across major collections,
the convention of `Test.Terrain.Growth`): `n = 4` at `2^20` 20,763,568 B and at `2^60`
20,763,568 B; `n = 1` at `2^60` 3,223,904 B; `n = 8` at `2^60` 69,495,608 B. The span does not
matter and the authored complexity does. A covered layer with no patch allocates the same at 1,000
levels and at `2^60`. The component of a `n = 3` source has the same number of boundary faces,
ranges and relations at both spans (at most six faces per range).

The structure grows with the number of distinct patch columns and boundaries because the lattice
is a product of per-axis cuts. About 30 scattered patches in void-bearing default content reach
the 65,536-node bound and are refused, as designed.

Deferred work. The worst allocation of any single one-step resume (`System.Mem`-style thread
allocation counter, read around each `resumePreparation 1`) is 35,112 B for `n = 2` and 27,120 B for
`n = 8` (bound 262,144 B, and no more than twice the small case plus 64 KiB). With the relation, mark
and canonical folds left lazy (a local mutation, never committed) the same measurement is 757,352 B and
8,145,200 B and the example fails: the work is done inside the step that is counted.

Temporaries without nodes. A solid world with 200 full-block patches at `(5 i, 0)` over `[0, 5)` has
0 nodes and over 20,000 lattice boxes; its peak exceeds its result by more than 100,000 accounted bytes
(the interval lists and walk state, `intervalTempBytes` 128 per interval and `latticeTempBytes` 512). It
completes with the peak limit equal to the measured peak and is refused one byte short with
`PeakBytes`.

Refusals (all typed, none exposes a result): the measured figures of a fixture with 4 patches
(nodes, relations, steps, result bytes, peak bytes) each succeed as the limit and are refused one
short naming that resource with `needed > limit`; 120 scattered air patches in a ramp layer are
refused at the 65,537th node `Refusal {StructuralNodes, 65537, 65536}`; 700 scattered patches in a
block world are refused up front on work (the lattice alone implies more than 8,388,608 steps);
a work limit of 1,200 refuses mid-compilation with the input unchanged and still compilable.
Resuming in quanta of 1, 17 and 1,024 gives equal results and totals; a request of 0, -5 or 1,025
is refused, never clamped; discarding a continuation changes nothing.

## Negative controls (applied locally to the implementation, never committed)

| Protected behavior broken | Failing examples |
| --- | --- |
| a side limit also counts as exterior | 37 of 120 connectivity examples |
| every parameter dropped from the keys (families merged) | 13 of 137 |
| vertically adjacent void cells connect (levels joined) | 79 of 137 |
| any two cells holding void connect (bounding-rule connectivity) | 64 of 120 |
| work check off by one | 2 of 137 |

In the suite, three deliberately wrong views of the real result (keys without parameters, keys
without the level parameter, exterior at a side limit) are rejected by the same comparison that
accepts the real views.

## Defect found by this evidence

The first oracle run found that extents such as `2^62 - (-2^62)` overflow `Int64`, which made a
world-spanning box look one cell wide. Extents are now compared as `hi > lo + 1` and
`hi == lo + 1`; the hand fixtures at `2^20`/`2^60` and the covered-open comparisons pin it.
