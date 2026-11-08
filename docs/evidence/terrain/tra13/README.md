# TRA-13 evidence: the corrected canonical shapes and their exact openings

Issue [#655](https://github.com/coghex/hetoimasia/issues/655), epic #636. Pinned to the
implementation head `7b5779e54b41d58513f4ff3b4517f44334ebc67c` of PR #667 (merged to master as
`d661115676cc3853a25a148126e5bb554728b522`; base: master after PR #654). Re-pinned after review: round 1 found
that `openingContains` counted the solid's own boundary as air, fixed in `92c79ae4`, and the figures below are
for the final head unless a line says it was measured at the earlier head `33a66b97da50`. Everything here is a **CPU, exact-arithmetic** result. No
performance claim and no amended GPU, corrected-mask, lighting or alpha-picking proof is
made (TRA-14, TRA-16 and TRA-17 own those).

## Reproduction

```sh
export PATH="$HOME/.cache/hetoimasia/toolchain/ghc-9.14.1/bin:$PATH"   # ghc 9.14.1, cabal 3.18.1.0
git checkout 7b5779e54b41d58513f4ff3b4517f44334ebc67c   # or master at d661115676cc
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct
(cd packages/terrain && cabal check)
python3 tools/validation/plan.py --catalog-check
cabal test workflow-tests --test-show-details=direct
```

Results: `terrain-tests` 669 examples, 0 failures (final head); `terrain-render-2d-tests` 256
examples, 0 failures; `cabal check` clean; catalog valid (36 groups); `workflow-tests` 965 examples,
0 failures; `terrain-render-2d-vulkan-tests` passed (the last four measured at `33a66b97da50`; the later
changes are the one `Opening.hs`/`Polygon.hs` fix, its tests, a README bullet and docs-only master merges); the native `tra8-terrain` scenario (surface-free,
no window) 5 examples, 0 failures with the 16-shape matrix judged in all four facings. A clean rebuild
of both touched packages (build directories removed first) produced no warning.

To run one part: `--test-option=--match --test-option='/Terrain/Openings/'` (portals and
connections), `'/Terrain/Geometry/'` (solids and queries), `'/Terrain/The retained reference defect/'`
(the original defect), `'/Terrain/Terrain opacity across the package boundary/'` (the external clients).

## The corrected catalog (P-9, D-49)

Local frame: X east, Y south, Z up, `N=y`, `E=1-x`, `S=1-y`, `W=x`; the solid is `0 <= z <= h` with
`h=1` for ID 0 and otherwise the minimum of the named expressions. **ID 15 is
`min(N,E,S,W)`**: vertices are the four base corners and the apex `(1/2,1/2,1/2)`; faces are four
sloping triangles and the base; no wall has positive area. Examples (`Test.Terrain.Geometry`,
describe "identity 15, the central half-height peak"): `(1/2,1/2,1/2)` Boundary,
`(1/2,1/2,3/4)` Exterior, `(1/2,1/2,1)` Exterior; a downward ray from `(1/2,1/2,2)` first meets the
apex at parameter `3/2` (`Enters`, the North facet by canonical order); the same ray stopped at
`z=1` misses and stopped on the apex `Grazes`.

### Old alias against the new cases

The alias (`shapeIdValue shape == 15 || null sides` in `taggedPlanes`) was reintroduced locally,
uncommitted, with every test unchanged (measured at `33a66b97da50`, 668 examples): **40 of 668 examples fail**, including the apex, the
ID-15 membership points, the wall-coverage table, "gives the peak no covered side at all", the
five-face count, and the opening-interface external client. The same run fails the portal
examples that need the peak's open sides (ID 15's side and top areas are 1, not 0).

### Boundary convention (round 1 fix)

`openingContains` is true to the closed solid: a face point is in an opening exactly when `classifyPoint`
calls the corresponding cell point `Exterior`. The solid's section by the face (the ramp and ridge lines, the
base edge, the top edge, the corners, even a section with no area) is excluded; the cell face's own edges and the
seams between an opening's convex pieces are air wherever the solid is not. Tests: "agrees with the
closed-solid classification on every point of every face, boundaries and seams included" (a 1/8 grid over all
16 identities and 6 faces) and "keeps the solid's boundary out of the opening: ramp, ridge, top edge and base
edge". Negative control: restoring closed polygon membership fails exactly these two of 669 examples.

## All 16 identities in all 4 orientations

For every identity and every positive turn count 0 to 3, `shapeOpenings (rotateShape t s)` must have, on
each of the six faces, the area the hand table below gives for the turned identity (the `After 1, 2, 3
turns` column is the hand rotation table), and also the area of the original identity on the face that
turned into it; and each face is open at exactly the lattice points where the independent height-rule
oracle says `z > h` (256 points per face per case, none on any boundary). 64 examples,
`opens identity N turned T time(s) ...`. Opening areas (the top, North, East, South, West, bottom
faces), worked on paper as one less the wall area on a side, the whole footprint on top for every
identity but 0, and nothing on the bottom:

| ID | Name | Top | N | E | S | W | Bottom | IDs after 1, 2, 3 turns |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | Flat | [0 | 0 | 0 | 0 | 0 | 0 | 0, 0, 0 |
| 1 | N | 1 | 1 | 1 / 2 | 0 | 1 / 2 | 0 | 2, 4, 8 |
| 2 | E | 1 | 1 / 2 | 1 | 1 / 2 | 0 | 0 | 4, 8, 1 |
| 3 | NE | 1 | 1 | 1 | 1 / 2 | 1 / 2 | 0 | 6, 12, 9 |
| 4 | S | 1 | 0 | 1 / 2 | 1 | 1 / 2 | 0 | 8, 1, 2 |
| 5 | NS | 1 | 1 | 3 / 4 | 1 | 3 / 4 | 0 | 10, 5, 10 |
| 6 | ES | 1 | 1 / 2 | 1 | 1 | 1 / 2 | 0 | 12, 9, 3 |
| 7 | NES | 1 | 1 | 1 | 1 | 3 / 4 | 0 | 14, 13, 11 |
| 8 | W | 1 | 1 / 2 | 0 | 1 / 2 | 1 | 0 | 1, 2, 4 |
| 9 | NW | 1 | 1 | 1 / 2 | 1 / 2 | 1 | 0 | 3, 6, 12 |
| 10 | EW | 1 | 3 / 4 | 1 | 3 / 4 | 1 | 0 | 5, 10, 5 |
| 11 | NEW | 1 | 1 | 1 | 3 / 4 | 1 | 0 | 7, 14, 13 |
| 12 | SW | 1 | 1 / 2 | 1 / 2 | 1 | 1 | 0 | 9, 3, 6 |
| 13 | NSW | 1 | 1 | 3 / 4 | 1 | 1 | 0 | 11, 7, 14 |
| 14 | ESW | 1 | 3 / 4 | 1 | 1 | 1 | 0 | 13, 11, 7 |
| 15 | NESW | 1 | 1 | 1 | 1 | 1 | 0 | 15, 15, 15 |

Each shape's solid (vertices and faces) for all 16 identities in all four facings is the matrix of
`Test.Terrain.Geometry` ("the sixteen canonical solids", "quarter turns of the geometry"). The empty
space is one component for every identity but 0, which has none; an independent flood fill on an
eighth-cell grid counts one region for each of 1 to 15.

## Rational boundary and intersection examples

| Case (`Test.Terrain.Openings`, worked examples) | Exact result |
| --- | --- |
| N beside N across X | shared area `1/2`, the triangle `(1,0,0)`, `(1,1,1)`, `(1,0,1)` |
| N beside S across X | each opening `1/2`, shared area `1/4`, the triangle `(1,0,1)`, `(1,1/2,1/2)`, `(1,1,1)` |
| N or air beside a full block (ID 0) | no connection (sealed) |
| air beside a W ramp's west side | area `1`; a ramp whose side faces away (E) is sealed |
| ID 15 beside air on any of its four sides or its top | area `1`; none through its bottom |
| two portals one tile apart on one plane, sharing an edge or a point | no connection |
| ramp (W) south portal against air one level up | no connection (top edge only); against air at the same level, area `1/2` |

For every pair of the 16 identities and each of the four horizontal directions (1,024 cases) the
library's connection area equals the area integrated independently in the test from the two height
functions along the shared edge (`1 - max(h_A, h_B)`, exact by the trapezoid rule on each half), and
there is a connection exactly when it is positive. Across the top and bottom, two occupied cells never
connect; air above an occupied cell connects over its whole top (area 1); air below never does.

## Diagonal paths and controls

Layout: air A at the origin, a ramp B east of it (W, open to the west and partly to the south), air C
south of B. A and C are diagonal neighbors with no direct link; the path turns through the empty region
above the ramp. Each layout and its endpoints are rotated together through all four orientations and
placed at seven bases: the origin, `(15,15,31)` (a chunk seam and the vertical-region seam),
`(-1,-1,-1)`, `(15,-1,31)`, `(-17,31,-33)`, and one tile inside each end of the supported range.

* path present through the W ramp, in every orientation and placement;
* controls with no path: B a full block; B an E ramp (sealed to A); and for **all 16** identities of B the
  path exists exactly when B is open to both A and C;
* a missing tile is unavailable, not air: with B absent there is no path, with B known air there is;
* A and C touching only along an edge, or two cavities only at a corner, with the face neighbors
  sealed: no path;
* vertical: down through the open top of an ID 15 peak and out of its east side (across a vertical-region
  seam), no path from below the peak (no bottom opening), none through a full block.

## Original N/E defect fixture

Provenance and arithmetic are in `Test.Terrain.Reference` and
`packages/terrain/test/reference/extract_facemap_samples.py`. Reference: Synarchy
`3777d437ea00e1302bf55162ad5693fee4879187`; blobs `effc21564c7a653605dcbafca23ce7bc560e262d` (N) and
`5ed533b4d9467fa3b371a4cb489a87844fa64611` (E). The script reads them read-only through git, refuses any
other object id and prints the committed literals (E texel `(48,2)` = `(0,255,0,255)`; N columns 0 to 7
first opaque at rows `39,39,38,38,37,37,36,36`). The suite enumerates the vertices of the polytope of
cell points that project into the whole E texel (no library code) and derives
`x+y in [0,1/8]`, `x-y in [0,1/48]`, `z in [13/16,1]`, then, under the inverse turn
`(x,y,z) -> (y,1-x,z)` (checked equal to the library's `rotatePoint (turns 3)`), the N window
`[0,6] x [47/2,27]`; the enclosing texels are columns 0 to 6 and rows 23 to 27, all transparent, at least
eight rows clear of the first opaque row.

## Superseded and unchanged

The retained TRA-8 evidence under `docs/evidence/terrain/tra8/` is baseline work and is not rewritten;
its fidelity table describes ID 15 as the old flat solid, which this change supersedes. The coordinate,
shape-ID, source-encoding, whole-cell-removal and planner regression suites are unchanged and green. The
planner's isolated-cell face count for view mask 15 is now 4 (four sloping tops, no East or South wall)
rather than 3, and a flat cell's East and South wall beside an ID 15 neighbor is no longer covered.
