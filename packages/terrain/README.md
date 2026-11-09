# hetoimasia-terrain

Checked terrain tile identity, the canonical geometry of every terrain shape,
and the pure source, storage and query kernel of the terrain arena arc (epic
#636). TRA-1 supplied pure coordinates, region keys, a 16-shape catalog with
exact rotation, and the one geometric authority that face generation, cutaway
coverage and picking will share; TRA-13 corrected identity 15 to the approved
central peak and added the exact empty-space openings and their connections
between neighboring cells. TRA-2 adds the immutable layered source, the
packed sparse resident-detail representation and the retained-removal overlay
with the queries over them, TRA-3 the pure residency and admission model
over them, TRA-18 the bounded symbolic compiler of the source's empty-space
connectivity, and TRA-19 the pure model of compressed player knowledge and resumable
discovery after removal. It is a data, query and decision kernel, not a world store:
transactional ownership, revisions and live offload (TRA-4), Lua copying
(TRA-5), input, camera, rendering and arena assembly belong to later slices.

| Module | Purpose |
| --- | --- |
| `Hetoimasia.Terrain.Coordinate` | Checked tile identity, region/local decomposition, cutaway |
| `Hetoimasia.Terrain.Shape` | The 16-shape catalog, sides, quarter turns, view facings |
| `Hetoimasia.Terrain.Geometry` | The canonical unit-cell solid, face coverage, membership, ray and segment queries |
| `Hetoimasia.Terrain.Opening` | The exact empty components of a cell, their portals on the six faces, and the connections between neighbors |
| `Hetoimasia.Terrain.Connectivity` | The exact, bounded, resumable compilation of a source's empty-space connectivity: component families, canonical keys, ranges, portal relations, compressed boundaries, initial upper-Z exterior |
| `Hetoimasia.Terrain.Discovery` | The pure discovery model: retained removed runs, a connectivity forest with known/unknown classes, paired removal-plus-obligation candidates, bounded resumable discovery batches, knowledge queries, replay from records, validated limits and allowances |
| `Hetoimasia.Terrain.Cell` | Authored materials, the air-or-solid cell value, half-open Z intervals, columns |
| `Hetoimasia.Terrain.Source` | The declarative layered source: definition, validation, limits and byte accounting |
| `Hetoimasia.Terrain.Changes` | Retained removals: canonical intervals, whole-cell removal, merge and restore |
| `Hetoimasia.Terrain.Query` | Cell, complete column-range and highest-occupied queries over source plus changes |
| `Hetoimasia.Terrain.Palette` | The 12-bit material palette and the 16-bit packed cell |
| `Hetoimasia.Terrain.Segment` | One known segment of at most 32 levels in uniform, runs or dense encoding |
| `Hetoimasia.Terrain.Resident` | Sparse resident detail: explicit coverage, materialization, discard, accounting |
| `Hetoimasia.Terrain.Residency` | The pure residency and admission model: validated limits, banks, admission, eviction, edit reservations, scheduling |

`Hetoimasia.Terrain.Internal.*` are private implementation modules; the package
does not expose them, and the suite proves a client cannot import them.

## Dependencies and ownership

The library depends on `base`, `containers` and `array` (a GHC boot library, for
the unboxed segment payloads) alone. It imports no other local
package, so no Lua host, window, GLFW, renderer, GPU, runtime or concrete game
reaches it, and it reads no file and no asset. The independent math package is
not used: its Float vectors and right-handed rotation do not fit exact integer
identity or the compass-defined turns below (see
[Quarter turns](#quarter-turns)). A later consumer converts to its own
camera-relative floating point from the exact values this package returns.

Terrain state does not live here. Every value is immutable and every function
is pure, so there is no owner, writer, thread, lifetime, reset or disposal to
document: constructing, translating or decomposing a coordinate allocates no
terrain volume, scans no column and holds no resource. The same holds for the
source, the changes, the palette, the segments and the resident detail below:
each is a value a later service owns, and every operation returns a new value
and leaves the old one valid, so a refusal always preserves the previous one.
No module starts a thread or a process.

## Coordinates

A tile coordinate is three signed 64-bit axis values. The supported range on
each axis is `[-2^62, 2^62 - 1]` (`-4611686018427387904` to
`4611686018427387903`).

- `AxisCoord`'s constructor is private. `axisFromInteger`, `tileCoord`,
  `offsetAxis` and `translateTile` compute in `Integer` and return
  `Left (AxisOutOfRange n)` carrying the exact refused value. Nothing wraps,
  truncates or saturates, and no floating-point value is a tile identity.
- `tileCoord x y z` reports the first axis out of range in the order X, Y, Z.
- `tileDelta from to` is the exact difference. With both operands in the
  supported range it lies in `[-(2^63 - 1), 2^63 - 1]`, so it always fits an
  `Int64` and needs no wider type; `translateTile` of that delta from `from`
  gives back `to`. Differences are therefore available exactly before any
  camera-relative float conversion, which belongs to TRA-7.
- `cellWorldPoint` places a cell-local point in tile space as exact rationals.

### Regions

A region key covers 16 columns on X, 16 on Y and 32 levels on Z. These are index
calculations only; a region is an accounting key and is never an allocated
16 x 16 x 32 array.

`decomposeTile` uses floor division with nonnegative local remainders, so:

| Axis | Coordinate | Region | Local |
| --- | --- | --- | --- |
| X or Y | `-1` | `-1` | `15` |
| X or Y | `-16` | `-1` | `0` |
| X or Y | `-17` | `-2` | `15` |
| Z | `-1` | `-1` | `31` |
| Z | `-32` | `-1` | `0` |
| Z | `-33` | `-2` | `31` |

`composeTile` is the inverse and computes in `Integer`, refusing a result outside
the supported range. `RegionCoord` holds bare `Int64` keys, so a hand-built key
can name a region that holds no supported tile; `composeTile` refuses it.
`LocalCoord` has a private constructor and `mkLocalCoord` refuses an offset
outside `0..15`, `0..15`, `0..31`.

### Cutaway

A cell `(x, y, z)` occupies the unit footprint and begins at elevation `z`.
Whole-cell cutaway level `k` includes the cells with `z <= k` (`cutawayIncludes`)
and its clipping plane is at elevation `k + 1` (`cutawayPlaneElevation`, an exact
`Integer`, so it may be `2^62`).

## Shapes

A world shape identity is `0..15` and is the four-bit mask of the reference
slope set: North 1, East 2, South 4, West 8, with North toward negative Y and
East toward positive X.

| ID | Name | ID | Name | ID | Name | ID | Name |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | Flat | 4 | S | 8 | W | 12 | SW |
| 1 | N | 5 | NS | 9 | NW | 13 | NSW |
| 2 | E | 6 | ES | 10 | EW | 14 | ESW |
| 3 | NE | 7 | NES | 11 | NEW | 15 | NESW |

- `mkShapeId` refuses every identity outside `0..15`. An unsupported identity
  is never normalized to flat, and the rejected thirteen-shape catalog is not
  substituted.
- Identities 0 and 15 are distinct authored identities with distinct solids:
  0 is the full block and 15 the central half-height peak. NS and EW are distinct
  opposite-direction forms.
- Arbitrary fractional slabs and new identities need a later, explicit
  extension.

### Quarter turns

Rotation permutes the four mask bits. **One positive quarter turn takes North to
East to South to West to North.** This is a compass mapping, never inferred from
an angle sign: with North toward -Y, East toward +X and Z as elevation the axes
are left-handed compared with the math package's "a quarter turn about +Z takes
+X to +Y", so reusing that package's `rotation` sign would reverse the facing
order. Four turns restore the starting shape; 0 and 15 are fixed (each is
symmetric about the cell's vertical axis) and NS and EW exchange under a single
turn. `turns` normalizes any count, including a negative
one, to `0..3`.

A local point turns with its shape: `rotatePoint (turns 1)` takes `(x, y, z)` to
`(1 - y, x, z)`, and the solid of `s` rotated by `t` is the solid of
`rotateShape t s`.

### View facings and stable world identities

The world identity never changes when a view changes facing. Only the mask a view
selects does (`viewShape`; `worldShape` undoes it). `ViewFacing` carries the
reference's names in the reference's order, and `facingTurns` gives the positive
quarter turns each applies:

| Facing | Turns | An East mask becomes |
| --- | --- | --- |
| `FaceSouth` | 0 | East |
| `FaceWest` | 3 | North |
| `FaceNorth` | 2 | West |
| `FaceEast` | 1 | South |

This is checked against the reference's own view mapping (below) for all 16
identities in all four facings.

## Geometry

`Hetoimasia.Terrain.Geometry` is the shared geometric authority. A later
consumer must read a shape's faces, coverage and intersections from this module
rather than approximate them, so rendering, cutaway coverage and picking cannot
disagree.

### Frame and solid

A cell's local frame has X east, Y south (North is toward -Y) and Z up. The cell
occupies `[0, 1]^3` and its base is its tile's elevation. A shape's solid is the
closed convex region

`0 <= x <= 1`, `0 <= y <= 1`, `z >= 0`, under the top surface,

where the top is a flat `z <= 1` for identity 0 and otherwise one full-width
45-degree ramp per set bit, each 0 high on its own side and 1 high on the
opposite side:

| Set bit | Ramp |
| --- | --- |
| North | `z <= y` |
| East | `z <= 1 - x` |
| South | `z <= 1 - y` |
| West | `z <= x` |

A set bit lowers its own side to the base, where the neighbor one level lower
meets it, and the solid is the intersection of every ramp. It is therefore always
a convex polytope with piecewise-planar faces: a corner form (NE, ES, NW, SW) is
a square pyramid with its apex over the opposite corner, an opposite pair (NS,
EW) is a tent with a half-height ridge along the other axis, and a three-side
form peaks at half height on the edge of its open side. A lowered side leaves a
zero-thickness edge, which is no face. Written as a height field, with `N = y`,
`E = 1 - x`, `S = 1 - y` and `W = x`, the solid is `0 <= z <= h(x, y)` where `h = 1`
for identity 0 and otherwise the minimum of the expressions its bits name.
**Identity 15 takes all four**: `h = min(N, E, S, W)`, a central four-sided peak
whose apex is `(1/2, 1/2, 1/2)`. It has four sloping top facets and a full base,
no wall of positive area (every side meets the base along an edge), and its four
base corners stay in the solid. It is not a full block and not a lowered flat
slab (owner decision D-49, which replaced the earlier flat-top alias; the old
identity-15-is-identity-0 expectations were reversed on purpose, not preserved
as a second authority). IDs 0 to 14 keep their lower-envelope solids, and no
identity is reshaped when a neighboring tile is removed.

`solidVertices`, `solidFaces` and `solidPlanes` give the exact vertices, faces
and bounding half-spaces. A `Face` has a kind (`TopFace`, `WallFace side`,
`BottomFace`), its plane with the normal pointing out of the solid, and its
corners counter-clockwise seen from outside. Faces are listed in canonical order:
top surfaces (in the order of the shape's ramps), then the walls North, East,
South, West, then the bottom.

### Face coverage

`sideCoverageArea shape side` is the exact area of a cell side's wall, and
`sideCoverage` classifies it as none, partial or full. This is what a later face
generator needs to decide which neighbor-facing walls can be hidden: a side is
fully covered only opposite a lowered side, or on the flat identity 0. The peak
covers no side at all. The top faces
together always cover the whole footprint (`faceFootprintArea` sums to 1), and
the bottom is one full face.

### Membership

`classifyPoint` distinguishes `Interior` (every half-space holds strictly),
`Boundary` (on a face, an edge or a vertex) and `Exterior`. The solid is closed:
its boundary belongs to it, so two cells that share a face, edge or vertex touch,
and a lowered side's zero-thickness edge is on the boundary while the air above it
is exterior.

### Rays and segments

`castRay` takes a ray (an origin and a nonzero direction, `t >= 0`) and
`castSegment` a segment (`t` in `[0, 1]`). Each returns the first contact: the
parameter, the point, the face and how it met the solid.

| Contact | Meaning |
| --- | --- |
| `StartsInside` | The origin is strictly interior; no face is entered |
| `Enters` | The query passes from the exterior into the interior at the point |
| `Grazes` | The query touches the closed solid without entering its interior within the queried extent |

Tie-breaking is by fixed rules, not tolerance:

- An origin strictly inside hits at `t = 0` with `StartsInside`.
- An origin on the boundary that moves inward `Enters` at `t = 0`; one that moves
  outward or along the boundary `Grazes`.
- A query that enters through an edge or a vertex reports, among the faces that
  contain the entry point and that it moves into, the first in canonical face
  order. A top surface therefore wins over a wall, and a wall over the bottom.
- A query that lies in a face's plane never enters through that face; if it never
  enters the interior it `Grazes`, reporting the first face, in canonical order,
  that contains the first contact point. This covers a ray along an edge, along a
  ridge, along a face, and one that touches only a vertex.
- A segment that ends exactly on the boundary `Grazes` there; one that stops short
  misses.

### Exactness and invalid input

All geometry is exact `Rational` arithmetic. There is no floating-point
rounding, so **there is no numerical tolerance**: two contacts coincide exactly
when their rational parameters are equal, and boundary and edge-contact decisions
are decided exactly. Floating-point input is accepted only through
`v3FromDoubles` and `mkRayFromDoubles`, which refuse a NaN or infinite component
with `NonFiniteComponent` (before reporting a zero direction) and convert finite
values exactly. A ray with no direction, and a segment of no length, are refused
with `ZeroLengthDirection`. Integer tile identity stays exact at the extreme
coordinates because `cellWorldPoint` adds the exact integer coordinates to the
local point as rationals.

## Openings and connections

`Hetoimasia.Terrain.Opening` is where empty space can pass. It derives everything
from the same `Solid` as the geometry above, so a portal, a point query and a ray
query cannot disagree; it owns no state and does not traverse a world, inspect
residency or turn missing data into air.

- *The empty region.* An occupied shape's empty region is the unit-cell space
  strictly above `h`. Identity 0 has none. Every other catalog identity has
  exactly one connected component (the region lies above a graph, so every point
  is joined straight up to the top face, whose open part is the footprint less at
  most an edge or a point). Membership is nonetheless explicit
  (`cellComponents`, `componentPortals`, `portalComponent`) so no consumer assumes
  a cell has at most one component, and the connection inside a cell is exactly
  "two portals of one component".
- *Portals.* A `Portal` is the part of a cell face through which a component is
  open: an exact `Opening` region (`openingPieces` as convex pieces without a
  common interior, `openingArea`, `openingContains`) on one of the six faces
  (`TopFace`, `WallFace side`, `BottomFace`). Face coordinates are `(y, z)` on
  East and West, `(x, z)` on North and South and `(x, y)` on top and bottom, each
  in `[0, 1]`, so a shared face has the same coordinates from either cell. A
  horizontal face's opening is its portion with `z > h`; the top opening is where
  `h < 1`; no occupied shape has a bottom opening of positive area. A selected
  side is open above its base and an unselected one may be partly open or sealed
  according to the same height function. N, for example, is fully open to the
  north, sealed to the south, triangular (area 1/2) to the east and west, and open
  over the whole top; identity 15 is open over all four sides and the top, and not
  at all below. Full air (`airOpenings`) is one component open over all six faces;
  it is not a seventeenth shape.
- *How an opening is computed.* The opening of a face is the unit square less the
  solid's section by that face's plane, which is the convex hull of the solid's
  vertices on the plane, subtracted as convex pieces. The pieces are one
  representation of a region, not a canonical form: compare regions by area and
  containment.
- *Connections.* `placePortals` puts a cell's portals on a tile, `connectPortals`
  joins two placed portals and `connectCells` all the portals two neighboring
  tiles share. Two components connect exactly when their portals are on opposite
  faces of one world plane and overlap over **positive area**, computed exactly
  after placement in world coordinates; the result names both components, the face
  and the common region (`connectionArea`, `connectionRegion`). Scalar areas are
  never compared: an N ramp beside another N ramp across X shares an opening of
  area 1/2, but an N beside an S shares 1/4 although each opens 1/2, and an
  adjoining full block seals it. Edge-only and point-only contact has area zero
  and never connects, there is no tolerance, and only the six face directions
  connect, so diagonal neighbors, which touch along an edge or at a corner, are
  never linked. A cell carrying a solid material is not automatically a sealed
  cube: whether it seals a face is the portal's business alone. A path can
  therefore turn through the empty region above a ramp into a diagonally situated
  cavity, and be stopped by a sealed neighbor or by a ramp whose open side faces
  away.
- *Rotation.* `rotateOpenings` follows `rotateShape`; four turns restore the
  original and full air is unchanged. A camera facing selects the turned openings
  and never rewrites the authored shape identity or a connection. World placement
  adds the tile's exact integer coordinates to the local points, so it is exact at
  the supported extremes and across negative region seams.
- *Boundary convention.* The closed-solid convention is unchanged: a boundary point
  belongs to the solid and is not air. `openingContains` is true to it: a face point
  is in an opening exactly when `classifyPoint` calls the corresponding cell point
  `Exterior`, so the solid's section by the face (the ramp line, the ridge, the base
  edge, the top edge and the corners, even where the section has no area) is
  excluded, while the cell face's own edges, and the artificial seams between an
  opening's convex pieces, are air wherever the solid is not. The pieces
  (`openingPieces`) are closed polygons that serve `openingArea`, and a zero-width
  contact never connects.

## Layered source

A `SourceSpec` is plain data: a list of unique authored material identifiers, a
sorted list of non-overlapping half-open `[z_min, z_max)` layers shared by every
column, and a list of `(x, y, z_min, z_max, value)` patches that override the
base with air or a material and shape. A level no layer or patch covers is air.
An omitted layer lower end is the lowest supported level and an omitted upper end
is one past the highest, so the last supported cell is covered. There is no
callback, Lua value, random stream or game-specific generator, and soil over
stone is an ordinary pair of layers a caller supplies (the suite's fixture is
stone `[-inf, -3)` under soil `[-3, 1)`, with thickness and identifiers as
parameters of the same mechanism).

`mkSource` validates the whole definition and returns a `Source` or the first
refusal; no partial source exists. It refuses an overlapping layer
(`OverlappingLayers`) and a layer that begins before its predecessor
(`LayersOutOfOrder`: the format requires sorted layers), overlapping patches in
one column, an invalid interval, a coordinate outside the supported range, a
duplicate or unknown material, an invalid material identifier, a shape outside
`0..15` and an oversized definition. Creating a source instantiates no column
and no buried cell; it stores the authored records only.

### Half-open limits

The supported range is `[-2^62, 2^62 - 1]`. A `ZRange` is `[lo, hi)` with `lo` a
supported level and `hi` at most one past the highest, `2^62`, so the last
supported cell is reachable by a layer, a patch or a range request. A lower end
outside the range (`LowerOutOfRange`), an exclusive end above `2^62`
(`UpperOutOfRange`) and an empty or inverted interval (`EmptyInterval`, `lo >=
hi`) are each refused, never clamped. The checks run in that order, so
`[2^62, 2^62 + 1)` reports its lower end.

### Material identifiers

A `MaterialId` is nonempty text of at most **64 UTF-8 bytes** with no control
character (Unicode category Cc) and no surrogate code point. Counting is in bytes:
32 two-byte characters fit, 33 do not. `mkMaterialId` is the only way to make
one.

### Limits and conservative accounting

`defaultSourceLimits` is the approved initial bound: **256 KiB** (262,144 bytes)
and **8,192 authored runs** per definition. An *authored run* is every layer and
every patch; materials are not runs. A source also holds at most **4,095
materials**, the non-air indices of the 12-bit palette. The accounting is
fixed and conservative; it is an admission figure, not heap or process memory:

| Item | Charge |
| --- | --- |
| Definition | 64 bytes once |
| Each material | 16 bytes plus its UTF-8 identifier length |
| Each layer | 24 bytes |
| Each patch | 40 bytes |

Counts are taken by traversals that stop one past a bound, and the total is an
`Integer`, so a limit is decided before any record is validated or stored and an
oversized or endless definition costs work bounded by the limit. Each bound is
tested accepting exactly at the limit and refusing one past it.

## Queries

`Hetoimasia.Terrain.Query` answers from a `Source` and a `Changes` only
(`emptyChanges` for the source alone), so a query consults retained changes
whether or not any cell is resident and does not depend on request order.

- `cellAt` answers `Air` or `Solid material shape`.
- `columnRuns` answers a complete finite half-open range of one column as
  coalesced runs: the runs cover the whole interval, air included, with no gap
  and no two adjacent equal runs. A range longer than `limitRangeLevels` (8,192
  initially) or an answer with more than `limitReturnedRuns` (1,024 initially)
  is refused with `RangeTooLarge` or `TooManyRuns`; it is never truncated, and
  the run count is decided by pulling at most one run past the limit.
- `highestOccupied` answers the highest solid cell, or `Nothing` for an empty
  column.

Every query steps from one interval boundary to the next across the source's
layers, the column's patches and its removed intervals, so a long stretch of air,
solid or removed cells is one step however many levels it spans: cost follows the
intervals met, never the levels between them, and no cell is allocated for them.

## Retained removals

`Changes` holds, per column, a sorted, disjoint, coalesced set of removed-cell
intervals. It is not an operation log. `removeCell` removes the whole cell,
whatever shape it had (a ramp included), and reshapes no neighbour. Removing air
or a cell already removed returns `removeChanged = False` and the very value that
was passed in; any other removal grows or joins an interval, so adjacent removals
coalesce whatever their order. A caller-supplied `ChangeLimits` bounds the
retained intervals, and an excess is a typed refusal (`TooManyRemovedIntervals`)
that leaves the previous value untouched. `emptyChanges` is a fresh session;
`mergeChanges` is the symmetric, associative union an offload needs, and
`changesFromIntervals` restores canonical changes from unordered, overlapping
intervals. `changesBytes` accounts 16 bytes per interval and 48 per column index
entry. The revision counter, admission reservation and cancellation arbitration
around a commit belong to TRA-4.

## Source connectivity

`Hetoimasia.Terrain.Connectivity` compiles a validated `Source` into the exact
connectivity of its empty space: which air spaces connect, which are initially
exterior, and a canonical identity for every connected component. It is pure and
CPU-only, instantiates no column, air cell or buried solid cell, and does not
open an arena, discover sealed space, hold knowledge or apply edits (TRA-19 to
TRA-22 do). Preparing connectivity needs only the source: the immutable result
is what a later service keeps beside it.

### What is exact

Two empty spaces connect exactly when a chain of cells joins them in which every
consecutive pair shares a face and their portals on it overlap over positive
area, as [Openings and connections](#openings-and-connections) defines (shape 0
the full block, identity 15 the central half-height peak, no nonflat shape with a
bottom opening of positive area). Edge and point contact never connects, there is
no tolerance and no blanket 26-neighbour rule, so a real diagonal path through
shaped voids exists exactly where a face-by-face chain does. The compiler never
asks about bounding boxes, shape bits or rendered alpha. It derives every fact
from `Opening`: which pairs of the 17 content kinds (air and the 16 identities)
connect along each axis, whether a kind has any void and whether its top face
opens, by asking about a representative pair of tiles.

### Representation: boxes, parameters and classes

The compiler cuts each axis where the source can change: every layer and patch
boundary and the cell below it, every patch column with its face neighbours on X
and Y, and the supported extremes (the upper endpoint `2^62` kept separately, and
the topmost level isolated). The cuts make a lattice whose boxes each hold one
kind of content, so a box is described by its kind and extents, never by its
cells. A box with void is a *node*; a full block is no node.

A node has no parameter on an axis along which its cells connect. An axis along
which they do not keeps the cell's coordinate as a *parameter* of the component.
A covered uniform N-ramp layer is therefore one node whose components are
indexed by row and by level (the south face is sealed and the north face open, so
rows never join, and no nonflat shape opens at the bottom, so levels never join);
the same layer of E ramps is indexed by column and level; a plane family of
connected shapes by level alone. A parameter spanning many members never claims
those members are mutually connected.

Two nodes that share a whole face and connect across it form one *class* and are
a *portal relation*. The join identifies the nodes' parameters, and removes a
parameter when one side has none: an air shaft that joins a vast range of repeated
layers removes their level parameter, so the shaft costs a few nodes and
relations, not one per level. A full-block patch splits a channel into fragments
the cuts already separate. A component is a class plus the values of its
remaining parameters. The lattice is refined at each patch column so that every
relation joins whole faces; a relation that would join part of a box would be a
defect, and the compiler refuses it as `Inconsistent` instead of guessing.

The lattice is a product of the per-axis cuts, so its size grows with the number
of distinct patch columns and boundaries, polynomially, never with an interval's
span or the number of identical members. That is the cost this design accepts: a
source with many scattered patches in default void-bearing content exceeds the
node, relation or work limit and is refused with the typed `source_complexity`
refusal below, and no dense fallback exists. The required fixtures (the flat
source, world-spanning and shafted air, all-16 cavities, and the huge ramp,
channel and layer families with their patches) fit the approved defaults.

### Identity, lookup and queries

`ComponentKey` is the origin of the class's first box in (z, y, x) order and the
parameter values the class keeps. It depends on the validated source and the
member's parameters alone, never on chunk-load order, query order or how the
preparation was divided into quanta, and the module promises no public encoding
and no equivalence between differently authored but semantically equal recipes.
`lookupVoid` addresses a void of a cell, so it stays correct for a future shape
with more than one; a full block answers `NoVoid` explicitly, never air and
never unknown, and an index the cell lacks answers `NoSuchVoid`. The compiler
addresses one void per cell and refuses (`Unsupported`) a catalog with more.
`componentRanges`, `componentRelations` and `componentBoundary` describe a
component by the boxes of its class, with its parameters applied: a boundary is a
set of rectangles of cells with the face and what lies across (a limit, solid
tiles or tiles of another component), at most six per box, so later discovery can
look up a component's or range's boundary without enumerating exposed tiles.

### Initial exterior

A component is initially exterior exactly when it connects through positive-area
openings to the upper Z boundary, unobstructed sky included. The X and Y limits
and the lower Z limit open nothing: a covered air slab that spans the horizontal
limits stays sealed, a full block at the highest cell supplies no opening, and a
shape's actual top portal reaches the outside. The classification is symbolic (a
topmost node is exterior when its kind's top face opens) and floods no sky and
allocates no boundary cell. Sealed components stay sealed whatever is queried or
resident; the result is initial metadata, not a discovered-tile set.

### Bounded, resumable preparation

`startPreparation` returns a suspended `Preparation`; `resumePreparation q` runs
at most `q` counted steps and returns `Pending`, `Complete` or `Refused`. A
refusal exposes no partial index, dropping a `Preparation` discards it with no
effect on any other value, and there are no threads, I/O or clocks. A request for
zero, a negative count or more than the configured quantum is refused, never
clamped. Fair scheduling, cancellation acknowledgment and the release of shared
admission reservations belong to the later service.

| Resource | Initial approved bound |
| --- | --- |
| Complete compiled connectivity per arena | 16 MiB |
| Peak compilation, including its result | 48 MiB |
| Structural nodes | 65,536 |
| Portal relations | 262,144 |
| Total compilation work | 8,388,608 counted steps |
| One preparation quantum | at most 1,024 steps |

A MiB is `2^20` bytes. The limits go through `mkConnectivityLimits`, whose
constructor and fields are private (as for the residency limits): each field has a
documented range (bytes in `[1, 2^40]`, nodes and relations in `[1, 2^32]`, work in
`[1, 2^48]`, the quantum in `[1, 1024]`, the peak at least the result), and a
figure outside it is refused by field with a `LimitError`, never clamped and never
reported as `source_complexity`.

A *step* is one of: forcing one entry of the 867-entry connection table (one exact
portal comparison), adding one authored layer, patch column or patch interval to
the cuts, classifying one lattice box, testing one node against one neighbour (and
recording the relation, at most three union-find operations of at most `log2 nodes`
hops), folding one mark or node into the canonical result, or assembling it. Each is
a constant number of operations on containers the limits bound, so no step scans a
coordinate extent, an unbounded container or an arbitrary recipe. Coordinates are
`Int64` inside `[-2^62, 2^62]` or `Integer`; extents are compared without
subtraction (`2^62 - (-2^62)` overflows `Int64`), and every sum that could leave a
limit is formed in `Integer` and compared first. The lattice is refused up front,
with the work it implies, when it alone exceeds the remaining work.

Bytes are conservative admission figures, not heap or RSS, charged before the
allocation or work they pay for: the constants `headerResultBytes` (512),
`cutResultBytes` (48), `nodeResultBytes` (160), `memberResultBytes` (40),
`classResultBytes` (96) and `relationResultBytes` (64) for the retained result, and
`nodeTempBytes` (512) for the union-find state and marks that exist until
canonicalization ends. The peak is the result plus those temporaries at any
moment. The connection table is a constant shared by the process and is charged as
work, not as bytes. A valid source whose connectivity needs more than a limit is
refused with a typed `Refusal` naming the `Resource` (result bytes, peak bytes,
structural nodes, portal relations or work steps) and the needed and limit
figures; the later integration maps any such refusal to the Lua domain code
`source_complexity`.

### What is charged to whom

The source definition (at most 256 KiB and 8,192 authored runs, enforced by
`mkSource`) is shared immutable input. Its bytes stay governed by
`sourceDefinitionBytes` and the existing independent source limit; they are
excluded from this compiler's result and peak figures (declaring a thousand more
materials changes none of them, and a test pins that), and this slice invents no
resident-bank charge for them: any charge for the retained source itself is the
arena-admission integration's choice. Only newly derived metadata is accounted:
the compiled result is charged once per arena to the 256 MiB resident terrain bank
by the later service, and the temporaries of the one compilation active per
session are charged to the same bank while they exist. This module creates no
bank, service, semaphore or session owner.

### State, owner and lifetime

None. A `Connectivity` is built whole and never mutated; a `Preparation` is a
suspended pure computation; nothing here has an owner, thread, queue, reset or
disposal.

## Discovery and knowledge

`Hetoimasia.Terrain.Discovery` (TRA-19) models what the player has discovered of
the empty space, over the immutable source plus retained removals. It is a pure
model of records, bounded candidate deltas and queries. It performs no I/O,
starts no thread, keeps no mutable registry and has no Lua, graphics or game
dependency. The page codec and copy-on-write store (TRA-20, in
[`hetoimasia-terrain-runtime`](../terrain-runtime/README.md#the-temporary-store-tra-20))
consume this model's records through its public types: it encodes
`RecordKey`/`Record` into pages and plans a `Candidate`'s writes as one bounded
transaction; this package gained only `mkComponentKey`, the inverse of a component
key's origin and parameters, so a decoded record names its component. The file and
asynchronous I/O (TRA-21) and the live owner that holds the committed value and
publishes candidates (TRA-22) are later slices; nothing here is a terrain
service, a file backend or a persistent-save promise.

### Three separate meanings

* **Terrain** is what a cell holds: the source plus the removals this model
  retains. A removal only enlarges empty space, so a source component stays a
  connected subset of the larger space after any removal. Placement, reshaping
  and any change that could split a space need a split-capable contract and are
  outside this one. The existing `Changes`, `Query`, `Resident` and `Residency`
  functions are unchanged; `retainedRemovals` converts the retained runs back
  for the consumers that read `Changes`, and a removal's `Changes` built through
  `removeCell` or `changesFromIntervals` is not this model's authority.
* **Residency** is which detail is materialized. Loading, eviction, camera
  motion and cutaway changes grant no knowledge, and knowledge never pins detail.
  Generic fog is presentation only: it never changes occupancy, a logical query
  or connectivity.
* **Knowledge** belongs to a connected class of empty space and is retained by
  compressed identity. Known **solid** and known **void** are separate facts: the
  solid face of a ramp is known when it is exposed to known empty space, the
  empty space above the ramp only when its own class is known. `queryCell`
  returns the two facts and `presentation` maps them to ordinary, fully unknown
  and known-solid/unknown-void.

### Initial knowledge

The initial known set is exactly the compiled source's exterior classification
(`Connectivity.isExterior`: connection through positive-area openings to the
upper Z boundary). It is derived from the compiled source without flooding sky,
preloading an exterior cave or using a fixed Z threshold; the lookup reads the
class's representative only, never the members of a class, so its cost does not grow
with the source's structure. Every other component
starts unknown and a sealed space stays unknown whatever is queried, resident or
raw-edited.

### Records, the forest and removed runs

All retained state is four plain-data records under an ordered key and a small
resident header (`Header`: the authority, the oldest unfinished and next
obligation sequence, and the accounted bytes). There is no closure, pointer
identity or auxiliary heap index.

| Key | Record | Meaning |
| --- | --- | --- |
| `KeyRun column lo` | `RecRun hi` | a canonical coalesced removed run `[lo, hi)` of one column |
| `KeyLink node` | `RecRoot (Root size known)` | a union-find root: members and whether the class is known |
| `KeyLink node` | `RecChild parent` | a member pointing toward its root |
| `KeyTodo sequence` | `RecTodo (Todo tile done)` | one removal's unfinished connections |

A `Node` is a source component (`SrcNode`, a canonical `ComponentKey` with its
row, column and level parameters) or a removed run (`RunNode`, named by the lowest
level it had when the node was made). A node with no `KeyLink` record is an
implicit singleton root: a source component is known exactly when the compiled
source calls it exterior, a run is unknown. **Absent is confirmed unknown**, which
is a different fact from a record the provider has not supplied (below).

Joining two classes writes a child pointer and rewrites the larger class's root;
the new root is known when either was. Joining a known class to an unknown one
therefore makes every member of the unknown class known in one record: a source
range, a family of parameters joined by an earlier removal, many removed runs. A
range of repeated components is never enumerated and uninvolved members of a
family are never merged because their bounds overlap; only the components a
removal's faces reach are joined. Union by size bounds a chain by `maxLinkChain`
(64). A run whose lower end moves, or two runs a removal bridges, are joined to
the run that takes their place in the same candidate, so no alias names a
vanished run and unfinished work survives intervening removals.

### A removal and its obligation

`stageRemoval` produces one complete candidate delta: the canonical removal, the
joins that follow from the cell itself (the new full-air cell contains its old
void, so a cell that was known stays known), and a retained obligation naming the
cell. Neither half applies alone: the candidate is one value. The obligation holds
the six face connections, where the full-air cell meets a neighbour's portals over
positive area (the geometry of `Opening`; edge and point contact never connects)
and the upper boundary of the world (a removal at the top level reaches the
exterior). Removing air or an already removed cell is `NoChange`: no history, no
obligation and no revision.

A raw removal inside a sealed unknown space records its connections and joins its
own classes but joins no known class, so it reveals nothing. A later opening from
known space joins the whole modified class and discovers it. A removal of a known
solid beside an unknown void discovers it only through actual new connectivity.

### Discovery batches

`stepDiscovery` inspects the connections of the oldest unfinished obligation, one
**structural update** per connection: one neighbour found by exact geometry, at
most one pair of classes joined and the obligation's progress. A batch performs at
most the validated `limitBatchUpdates` (1 to 64) updates. Each connection is
inspected exactly once and against the state at inspection time, so a connection
beside an already known or expanded region is joined, a class reached by two
fronts is joined once, and reaching sky ends only the outward branch. An
obligation is **unseen** before its first face, **pending** while partly inspected
and **expanded** (its record deleted) when finished (`queryObligation`); none is
the same fact as the knowledge of the class it touches, and an unfinished
obligation inside a known class is still inspected. Completion means no unfinished
obligation: the connected space and its exposed boundary are then known by
identity with no cell, boundary tile or resident detail enumerated or required.

A batch stops with a `Halt`: the batch limit, a drained queue, a record the provider
has not supplied, or a resource the allowance cannot fund. A first update that
cannot fit is refused with the resource and the work stays queued; pending capacity
never reads as completion.

### Exposed boundary and presentation

Exposed boundary knowledge is derived, not copied per chunk. `queryCell` resolves a
solid from exact contact geometry: a known void whose portal lies over the cell's
solid face section by positive area, the cell's own known void, or the sky above the
top level. `queryKnownBoundary` returns a known source component's compressed
boundary faces one bounded **page** at a time (at most six per box of its class, never an
enumeration of tiles): a page scans at most `limitBoundaryFaces` boxes of the class and returns
at most as many faces, possibly none when the boxes it scans lie inside the class, with the
box identity where the next page resumes; the cursor is that identity, resumed by a seek in an ordered
member index built once with the environment (charged once, 32 bytes a node, in `envSharedBytes`), so
a late page never walks the boxes before it and `pageVisited` stays within the limit on every page.
The page's bytes are charged before it is built, validation requires the scratch to cover the class
lookup as well as the page (no accepted configuration refuses every query), and the pages together are
the whole description (in box-identity order). A removal's effect on a boundary is read cell by cell. A chunk reloaded later resolves
the same answers from the retained records alone.

### Missing data and replay

An operation reads through a `Provider`, a bounded window, never the whole history:
an exact record lookup and a floor lookup of the removed run at or below a level. A
record the provider answers `Unavailable` suspends the operation with its obligation
intact (`EditSuspended`, `Stalled`, `HaltSuspended`, `MissingRecord`). It is never
read as absent, as air, as newly forgotten fog or as proof that no connection exists,
and pristine source state is never regenerated in place of a record the model was not
given. `retainedFromRecords` rebuilds a `Retained` value from a header and its records
after checking that they are a legitimate state (kinds match their keys, a run lies
inside the supported range `[-2^62, 2^62]` and runs of a column are disjoint and not
adjacent, so discovery and the existing `Changes` consumers cannot disagree about a
restored run); resuming from those records alone
gives the same knowledge and the same remaining work.

### Authority and candidates

**The revision rule**, stated once (`nextAuthority`; every candidate takes its next
authority from it): *content* advances exactly when a candidate changes terrain (an
applied removal); *knowledge* advances exactly when a candidate makes known space that was
not known (a class becomes known, or a cell joins a known class: an extended or bridged
run, a known old void) and never decreases; *store* advances on every candidate
(obligation progress and unions that change no knowledge). A reader that keyed a derived
result (a fog plan, a picked cell) by the knowledge revision it read is stale as soon as the
retained revision differs, and one keyed by content when terrain changed; a stale reader
keeps the old immutable value, correct for the authority it names, and never sees a
candidate that is not applied. A stale holder of a candidate is refused. A `Candidate` names the `Authority` it read: the arena incarnation (an
`ArenaId`) and the content, knowledge and store `Revision`s. `applyCandidate`
accepts it only against exactly that authority, so a candidate from a closed
incarnation, or one made stale by an applied candidate (a frontier-only one included),
is refused and applied nowhere, and a rejected or discarded candidate leaks neither
terrain nor knowledge. A candidate says whether it changes terrain (content revision),
knowledge (knowledge revision) or neither (frontier or union maintenance, store
revision only). Revision and sequence arithmetic is checked and refuses on overflow.
Staging is not publication: the atomic write, cancellation and settlement protocol
belong to TRA-20 to TRA-22. Retention is session semantics, not a save or crash
recovery.

### Limits and accounting

`DiscoveryLimits` are validated by `mkDiscoveryLimits`: a figure outside its range, or
too small for one minimal progress step (one removal with its continuation, or one
structural update with its worst-case inspected input), is refused by field and never
clamped, so a limit that can never fit gives a typed refusal and not an indefinite
pending state. An `Allowance` can only tighten them per call.

| Field | Range | Default |
| --- | --- | --- |
| batch updates | 1 to 64 | 64 |
| inspected records | `worstEditReads` (197) to 2^24 | 64 × `worstEdgeReads` |
| delta records | `worstEditWrites` (7) to 2^24 | 64 × `worstEdgeWrites` |
| delta bytes | `minimumDeltaBytes` to 2^40 | 1 MiB |
| scratch bytes | `minimumScratchBytes` to 2^40 | 4 MiB |
| unfinished obligations | 1 to 2^32 | 65,536 |
| retained bytes | `minimumRetainedBytes` to 2^40 | 48 MiB |
| boundary page | 6 to 2^16 boxes and faces (the scratch must cover the lookup of the class, `findReadsBound` records, and a page: `boundaryQueryScratch`) | 1,024 |

Bytes and counts are conservative accounted figures (keys, aliases, obligations,
container overhead and scratch; a deletion is charged as the largest record of its
kind), not heap or process RSS, and not final encoded pages. Every bound is checked
**before** the work it pays for, through **one function** (`charge`): a provider read is
charged one read and the largest record (`maxRecordBytes`) of scratch before the provider is
asked, a staged write is charged its entry before it is staged, and the output and
traversal state of a boundary page is charged before the page is built, so a request that
would overflow the read count, the scratch, the candidate records or bytes, or the retained
bytes never reaches the provider, the overlay or the page. The peak scratch a report shows is
read from the same state the charges update, so a rejected or suspended attempt reports what
it had been charged. An inspection rejected part way is discarded whole, and the
reads it had already made are reported as `reportAttemptedReads` (never above the read
limit), so the report cannot understate the provider's work. The shared compiled
source is charged once to the arena (`envSharedBytes`), never to a candidate. The
integration envelope is P-15's 64 MiB edit bank (48 MiB record caches, 8 MiB staging,
8 MiB control), at most 4 MiB of RAM and 1 MiB of encoded pages per later store
transaction and at most 64 structural updates per batch; the model can stop below 64
when its allowance is tighter. The exact page charges are TRA-20's
(`hetoimasia-terrain-runtime`: a plan writes at most 256 pages and reserves at most
4 MiB, and stops a batch earlier when that is tighter than 64 updates) and the bank
enforcement is TRA-22's; a structural update stays this model's unit (one connection
inspected), never a page or an index copy.

### State, owner and lifetime

None. Every value is immutable and every function pure. The later owner holds the
`Retained` value (or the store that replaces it), supplies the arena and revision
authority, applies candidates on its single owner thread and decides when to schedule
a batch. This module starts no thread, allocates no identity and owns no resource.

## Packed storage

### Cell value and palette

A packed cell is 16 bits: a 12-bit palette index over a 4-bit shape. Index 0 is
air, canonically the all-zero value, so a solid of shape 0 is distinct from air;
indices `1..4095` map to stable authored identifiers, and shapes 0 and 15 stay
distinct. Packing refuses rather than truncates: a full palette
(`PaletteFull`), a material not in the palette, an unassigned index and an air
index carrying a nonzero shape (`NonCanonicalAir`). Assigned indices are never
reassigned. This packing is internal: it is not a Lua numeric identifier or a
save-format promise.

### Segments and encodings

A `Segment` covers `[start, start + length)` with `1 <= length <= 32`, entirely
inside one 32-aligned vertical region. For `N` cells and `R` runs of equal
adjacent values the encoding is chosen once, by:

| Condition | Encoding | Payload bytes |
| --- | --- | --- |
| `R = 1` | Uniform: one 16-bit value | 2 |
| otherwise `4R < 2N` | Runs: one 32-bit word per run, exclusive end offset in the high half and value in the low half, ascending and coalesced | `4R` |
| otherwise | Dense: exactly `N` 16-bit values (a tie goes to direct indexing) | `2N` |

Uniform and dense lookups index directly; runs use binary search, with at most 15
runs in a nonuniform 32-cell segment. The suite pins one requested surface cell
at 2 bytes, 32 identical cells at 2, two runs at 8, three runs at 12, 15 runs at
60, and 16 runs or 32 alternating cells at 64. Payload bytes count the values
only: the segment's start, length and tag are metadata (`segmentMetadataBytes`,
32 accounted bytes), and the Haskell heap costs are neither, so they are
measured, not read from these figures. `updateSegment` decodes at most 32 values
into scratch, applies the changes and builds a fresh segment, choosing the new
encoding once; it never expands unknown depth, and the previous segment is
unchanged.

### Sparse resident detail

`Resident` maps a column to its known segments. Coverage is explicit: a level
inside a segment is known (and may be air), a level in no segment is
**unmaterialized, not air**, and a segment never crosses a region boundary. Two
segments of one region are separate unless they are adjacent. `materialize`
makes exactly the requested levels known: a top-only request creates one
one-cell segment, widely separated requests leave their gap unmaterialized, and
nothing fills buried source cells. Values come from the same immutable source
plus all retained removals, so a cell removed while it was not resident is
absent when materialized later, and `discardRange`, `discardRegion` and
`discardColumn` drop resident detail only and never touch changes.
Re-materializing over known levels recomputes the merged interval (at most 32
values) from the authority, so a stale value cannot survive. A request is
bounded by the caller's level limit. `residentStats` reports segments, known
cells, payload bytes and metadata bytes separately.

A region key is an index key, never an allocated 16 × 16 × 32 array. Residency
admission, eviction eligibility and retained-edit reservations are decided by
[the residency model](#residency-and-admission); the single writer, revisions
and the live offload protocol (TRA-4) are not here.

### Growth

Absolute depth and gap width do not cause proportional allocation or traversal.
The routine suite proves it with structural counts (known segments and cells)
and by measuring allocation at two widely separated depths and gap widths with
`GHC.Stats`, which separates a change in growth rate from a constant factor; no
wall-clock threshold is asserted.

### Measurement

`terrain-measure` is a benchmark component, outside every required group:

```sh
cabal bench --project-file cabal.project.cpu hetoimasia-terrain:terrain-measure
```

For flat, layered, hollow and fragmented fixtures over a 16 × 16 block of columns,
with a top-only and a 128-level demand, it prints segments, known cells, the
encoding mix, payload bytes, accounted metadata, accounted source bytes, the
heap the detail actually retains (the change in live bytes across major
collections) and the bytes allocated building it, then lookup (coherent and
scattered), bulk-scan, edit and encoding-transition costs in nanoseconds per
operation. These are one run on one machine; they make no speedup, universal
ratio or threshold claim, and the retained-heap figure is larger than the payload
because it includes object headers and the indexing maps.

## Residency and admission

`Hetoimasia.Terrain.Residency` (TRA-3) decides which regions may be admitted, shared,
evicted and protected under bounded horizontal and vertical residency. It
performs nothing: `step :: Model -> Event -> (Model, Either Refusal Report)` takes an
immutable `Model` and one `Event` and returns the next model with either a typed
refusal or a report. A refusal returns the model it was given, byte for byte. There
is no worker, mutable registry, STM or IO, and no Lua or graphics dependency. The
model is not a second authority for terrain contents: it tracks which cells of
which region are known, what they cost and who needs them, while the values live in
`Resident`, `Changes` and `Source`.

### State, owner and lifetime

| Item | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| `Model` | The later terrain service (TRA-4) | Its single owner thread feeds events and reads decisions | That owner thread | The service's | A fresh `newModel`; `RetireArena` releases an incarnation |
| Identities (arena incarnation, content revision, request, view, hold) | The service | Supplied with events, never reused | Owner | Never wrap | Not allocated here |
| Job numbers | The model | Allocated by admission, checked | Owner | Until the job completes or is dropped | A refusal when exhausted |

The owner carries out every decision and reports the corresponding event: it
discards the detail of each victim a decision names and then sends
`VictimReleased`, runs the job a `Dispatched` decision names and sends
`JobCompleted` with the cost it actually stored, and so on. The ledgers are derived
from the model's records, so a credit cannot be freed twice or underflow. Time is
logical: an event counter orders least-recently-used choices and aging, and no
deadline or clock is read.

### Validated limits

`LimitsSpec` is plain data; `mkLimits` is the only way to a `Limits`, whose
constructor and fields are private, so a validated figure cannot be rewritten by
record update. A limit that is zero or negative (`LimitNotPositive`) or above its
ceiling, 2^40 (or the region's 16, 16 and 32 for the extent), is refused by field
and never clamped.

**Capacity is guaranteed by configuration, not decided per request, for explicit
requests.** The limits carry the explicit request caps, and `mkLimits` refuses a
configuration whose banks cannot hold the worst-case footprint of the largest
admissible explicit request of every kind (`BankBelowMinimum`, naming the bank, the
bytes needed and the bytes configured). An explicit request (a query or a removal)
within its caps is therefore never refused as invalid for lack of capacity, in any
state; a shortage is only ever busy, and ends when the holders the progress
assumptions name release. A query is capped at 257 regions, which admits the approved
8,192-level column at any alignment; the cap does not depend on the number of
load-job slots, because a slot is taken when a job is dispatched, not when it is
admitted (an admitted job waits queued holding only its reservation). A surface
(highest-occupied or next-solid) query needs no resident detail beyond the same
8,192-level range, so the same cap bounds it.

**Camera demand is best effort.** It has no region cap, so the approved zoom range
and depth band (about 11,200 regions at zoom 0.125 on a 3840 x 2160 display with the
250-level band) are not limited by the model, and it is never refused for its size.
The model admits as much of it as the banks allow, strictly in the order the
producer lists it (nearest and visible first), and leaves the rest pending; unloaded
terrain stays absent until it fits. A description is normalized, never rejected: an
empty one withdraws the view's demand, repeated keys coalesce into the first
occurrence (keeping its priority), keys outside the supported coordinate range and
cells outside the configured extent are excluded and reported (`cameraExcluded`),
and a description longer than its structural maximum (`specCameraRegions`, 16,384:
more than the approved envelope needs) or than the staging the camera may use is cut
at the end, lowest priority first, and the remainder reported (`cameraTruncated`). The
staging the camera may use must hold the description, and nothing else decides how much of
it is stored: a description is cut only by its own bytes (the ledger's `descriptionBytes`)
against the camera share, net of the one camera region's interest and scratch the share must
always keep for the first region to start (`limitCameraRegionStagingBytes`, the same figure
the staging minimum keeps), and against the room the bank has now beside the headroom for
explicit requests (`cameraStagingRoom`). Nothing predicts what will or will not load, and a
stored demand is dropped only by withdrawal or replacement. Setting a demand is withdrawing
the old one (the existing withdrawal), storing the new description and admitting its
regions in priority order through the ordinary `planAdmission` while they fit now; the rest
stay pending, and every `Service` admits the next pending regions in the same order
whenever they fit (nothing is protected from eviction but the regions an admission names).
Cancelled work keeps its charges until its owner acknowledges it. Properties check that the
kept prefix is what the ordinary path leaves (right after the set `Service` has nothing
more for the view; the kept prefix is stable; growing the description one region at a time
keeps `min i k`), that replacing is the same as withdrawing and setting, and that a stored
demand that fits an empty camera share is eventually admitted whole by `Service` and
acknowledgements alone.

What camera work can occupy, and why it cannot starve explicit work. The mechanism is
a reserve of room, not a race: camera admission and hold acquisition are refused
(busy) unless the resident bytes the camera side keeps out of explicit reach stay
within the bank less the explicit resident minimum (`limitExplicitResidentBytes`).
Those bytes are every held region charged at its stored maximum (a pinned region can
grow and cannot be evicted) plus, for each region with a job only views need, the
detail it holds and the job's reservation (finite work, but not reclaimable while it
is queued or running).

| Camera holding | Reclaimable by an explicit request? | Worst case kept out of explicit reach |
| --- | --- | --- |
| Resident detail held only by camera interests | Yes: the view's interest is dropped and its demand is pending again | none |
| Queued and running camera jobs (reservation, scratch) | They finish under the progress assumptions; foreground jobs are dispatched first and aged ones are not starved | within the resident bank less the explicit minimum, checked at admission, so re-admitting camera jobs cannot restore a reservation that blocks explicit work |
| Pins and borrowers over resident regions | No while held | each held region at its stored maximum, within the same bound; the bound is also an invariant of the model |
| Descriptions, interests, hold records, scratch | No while held | draw only on the staging beyond the explicit staging minimum (`limitExplicitStagingBytes`) |
| Load-job slots | Dispatch is foreground first | no reservation needed |

Camera work never takes a region anyone holds an interest in.

The explicit caps are validated from the request alone, independent of the model's
state:

* a query names at most `specQueryRegions` regions (`DemandTooLarge`); a hold names at
  most `specHoldRegions` (`DemandTooLarge`; zero disables holds);
* every cell of an explicit request lies inside the extent `specExtentX` x
  `specExtentY` x `specExtentZ` of its region, at most the region's 16 x 16 x 32
  (`OutsideExtent`). The extent is the storage format's maximum per-region cost:
  whatever sequence of requests and edits made a region, it occupies at most
  `256 + 48 c + 34 n` bytes, with `c` columns and `n` cells (every cell its own
  segment of 32 bytes of metadata and two payload bytes, which removals can make of
  it), and a job over the extent reserves at most `48 c + 96 s` beyond it, `s` being
  its separate intervals. The model charges a region for its own column entries once
  each (the columns its coverage gains, whatever the data layer reports) and refuses
  a completion that would take a region past that maximum (`RegionExceedsMaximum`),
  so a region's accumulated charge never exceeds the bound the check assumed;
* a handoff duplicate is at most one region at its stored maximum
  (`HandoffTooLarge`).

Every bank is partitioned into an explicit reserve (the explicit worst case) and a
camera share (the rest). Camera work and holds draw only on the share and never touch
the reserve; explicit work uses the reserve and whatever of the share is free. The
configuration check requires the reserve to meet the explicit worst case and the share
to hold the largest single camera unit, or the camera could never make progress
(`BankBelowMinimum`; a camera or holds disabled with a zero cap need no unit). The
minimum budgets (`explicitMinimumBytes` for the reserve, `minimumBytes` with the unit,
exact integer arithmetic):

| Bank | Worst-case footprint it must hold |
| --- | --- |
| Resident | the most of: a query's regions, a removal; each region may already hold its stored maximum and then load the largest job beyond it (a removal: the stored maximum, one cell's 144 and its 62 of growth). Camera work and holds leave this much out of their reach. Beside it, the largest camera unit: the largest hold (its regions at the stored maximum) or one region's camera job (the stored maximum plus the largest job), whichever is larger |
| Staging | the most of: a query (command 128 + 32 per region, an interest and the scratch of the whole extent for each region), a removal (command, its 512 and one cell's scratch) and a handoff duplicate of a region at its stored maximum; this is the headroom camera work and holds leave free. Beside it the larger of the largest hold's records (64 per region) and one camera region (a one-region description, its interest and its scratch) |
| Edit | one removal's retained growth, 64 |
| Load jobs | one: a slot is taken at dispatch |

`defaultLimits` is the approved initial CPU profile, sized for a normal laptop
(hundreds of megabytes), and satisfies them:

| Limit | Initial |
| --- | --- |
| Resident terrain bank | 256 MiB |
| Retained session edit bank | 64 MiB |
| CPU render and staging bank | 128 MiB |
| Internal load jobs (running at once) | 128 |
| Queued (accepted, unsettled) terrain commands | 256 |
| Pinned CPU view revisions per view | 2 |
| Regions in a query | 257 |
| Regions in a hold | 256 |
| Regions in a stored camera description (structural maximum) | 16,384 |
| Region extent (columns, rows, levels) | 16 x 16 x 32 |
| Aging threshold (dispatches an eligible job may be passed over) | 8 |

Their worst cases (computed in the tests): a region stores at most 291,072 bytes at
that extent and its largest job reserves 405,504 more, so a 257-region query needs
179,020,032 of the 268,435,456 resident bytes and 4,301,280 of the 134,217,728
staging bytes (command 128 + 32 x 257, an interest each, and 16,640 of scratch per
region), which camera work and holds leave free, plus 16,896 for one camera region or
16,384 for the records of the largest hold (256 regions), and 74,514,432 resident bytes
for the held regions at their stored maximum (larger than one region's camera job,
696,576): 253,534,464 of the 268,435,456 in all; a removal needs 64 edit bytes of 67,108,864; a query needs one
load-job slot of 128. These are engineering defaults for the initial profile, not
measured capacity.

The byte banks are service-wide, never multiplied per arena. The 128 MiB GPU
data, the arena, view and lease caps and the source, column and input limits
belong to their owning slices. These budgets are conservative accounting, not a
process-RSS or measured performance guarantee.

### Who is charged for what

Each cost category is assigned to exactly one bank or slot:

| Category | Bank or slot | Charge |
| --- | --- | --- |
| Region metadata, for every resident region however little of it is known | Resident | 256 bytes |
| Sparse column index entries, charged to each region for its own columns | Resident | 48 bytes each |
| Segment metadata | Resident | 32 bytes each |
| Packed detail payload | Resident | the encoded bytes stored; reserved at the dense bound, 64 per interval |
| A removal's rebuilt segment (its payload is between 2 and 64 bytes) | Resident | 62 reserved; the growth actually stored is charged at the commit |
| Retained removals | Edit | 16 per interval and 48 per column entry (worst case for one removal: 64) |
| Load scratch | Staging | 256 + 2 per cell |
| Interest records | Staging | 64 each |
| Hold records (borrowers and publication pins) | Staging | 64 per region held |
| Accepted command records | Staging | 128 + 32 per region |
| The pending latest-value camera description of a view | Staging | 128 + 64 per region named |
| Removal staging (overlay and affected snapshot) | Staging | 512 |
| Temporary duplicate during a handoff | Staging | supplied by the owner |
| Internal load jobs (taken at dispatch, held until completion or acknowledgement); accepted commands; pins of one view | Slots | one each |

A region count or payload-only estimate is never enough: because region
metadata is charged, vertical regions holding almost no cells still consume the
resident bank, and descending cannot grow residency without bound while the
horizontal column count stays fixed. A one-cell job therefore reserves 256 + 48 +
32 + 64 = 400 resident bytes and, when its cell needs two payload bytes, stores 338.

The reservation bounds the growth whatever else is or becomes known in the region
and in whatever order other work completes or is canceled: merging cells into an
existing segment can raise that segment's payload (a uniform 31-cell segment is two
bytes, the merged dense segment 64), so a figure proportional to the new cells alone
would not bound it, and a job never depends on another job to fund its column. The
data layer keeps one index entry per column across all vertical regions; the model
charges each region for its own columns and keeps that charge until the region is
released, so it over-charges the shared index and evicting one region never leaves
another under-charged. When a job completes the owner reports what it stored as a
`Cost` whose columns are the region's own columns of the cells it added (not the
shared index's growth) and whose segments and payload are what it stored there; a
larger figure than reserved, or arithmetic that does not fit 64 bits, is a contract
failure, never silent growth or a retroactive busy. A removal's commit reports the
growth of the rebuilt segment the same way (`RemovalCommitted`'s last argument,
at most the 62 reserved); the removal's growth is funded like a job's and the commit
is refused (`EditNotFunded`) while it still waits for a victim's release.

### Admission

Admission is the only point where work answers busy (a hold or handoff duplicate
admits a small staging record and may answer busy for the same reasons). The atomic
admission unit is one explicit request covering all of its regions, or one region
job of a camera demand. A unit reserves every credit together or none, and is fully
funded at admission from free capacity plus an eviction set chosen and committed in
the same step; it is never refused afterwards. A job funded by committed victims
waits only for those victims' `VictimReleased` events, then is queued. A victim
cannot regain an interest or a hold, and a victim's bytes are never promised twice.
Checks run in a fixed order and the first failure is reported:

1. **Invalid** (permanent), from the request alone and so from every state: a
   malformed demand (empty, a query over its region cap, duplicated, a region key that
   names a tile outside the supported coordinate range, `UnsupportedRegion`,
   checked at the lowest and highest cell of the region, or a cell outside the
   configured extent), a duplicate identity, or a handoff duplicate larger than a
   region can be. No bank or slot is ever the reason: the minimum budgets above
   guarantee that an explicit request within its caps fits an otherwise empty model,
   and camera demand is best effort, so every shortfall below is pressure, and the
   model weighs no state to decide permanence.
2. **RetainedEditsExhausted** (edits only): the committed bytes plus this edit exceed
   the bank even with every reservation returned. It names the bank and persists until
   an arena's teardown frees retained bytes; the public Lua mapping stays `busy`
   until then (TRA-5 owns it). Reads, navigation and camera demand continue within
   their own banks. This bound and its persistent refusal are the current, interim
   rule: the design's D-40 (temporary disk backing for retained terrain changes) is
   specified, and its storage-aware admission decisions exist as a pure model in
   [`hetoimasia-terrain-runtime`](../terrain-runtime/README.md#the-temporary-store-tra-20)
   (TRA-20: a 48 MiB cache, 8 MiB staging and 8 MiB control division of this same
   64 MiB edit bank, backed-only eviction and a per-arena disk allowance). Until the
   terrain owner adopts them (TRA-22) this baseline keeps its RAM-only behavior
   exactly: its 64 MiB retained capacity, its lifetime charge (an offload or an
   eviction never credits it, because the baseline holds the only copy) and this
   refusal are unchanged and pinned by `Test.Terrain.StorageCompat`. The bound is
   still not the arena's final total-history contract.
3. **Busy**: the command slot, the staging bank, the edit bank (other
   reservations outstanding) and last the resident bank, whose refusal names the
   shortfall, the bytes of eligible victims and how many regions each condition
   keeps out of eviction.

Work is shared by arena incarnation, content revision and region. A caller whose
cells are already resident or already being loaded only gains an interest; any
cells that are not get a job of exactly those cells. Disjoint demands in one region
are never joined by filling the cells between them, and unloaded detail is never
air. Canceling an interest cancels a job only when no other interest intersects it;
a running job nobody needs is marked cancelling and keeps its scratch and resident
reservation until its completion or acknowledgement is reported, and its result is
dropped.

### Content revisions

A request names the arena's current revision or is stale. Revisions change only at
`RemovalCommitted`, and a removal changes exactly one region. Work for other regions
carries over; queued work for the changed region is dropped, running work is
superseded: it becomes cancelling, so its result is discarded and the owner's
completion or acknowledgement releases its slot, scratch and reservation. The owners
whose demand lost work are reported with the queued jobs that were dropped and the
running jobs now cancelling. Every event that leaves a job without an interest (a withdrawal, a camera
replacement, a failure that drops the interests it served, a commit) reports the
jobs it dropped at once and the running ones awaiting acknowledgement.

### Camera demand

Camera demand is latest-value state per view: best effort and uncapped (its
description is charged to staging, beside the headroom explicit work keeps), replaced
as a whole, never a queue of pan events. Replacing it is exactly withdrawing the view's
current demand (its description and all its interests, through the ordinary withdrawal)
and admitting the new demand as a fresh one; there is no replacement-specific path. Work
only this view needed that is still queued is dropped, and running work is cancelled and
freed only when its owner acknowledges it; work another caller needs is untouched, and
the jobs the withdrawal made obsolete are reported (dropped at once if queued, awaiting
their acknowledgement if running). Each region is admitted as its own unit, strictly in
the order of the demand: the first region that cannot be admitted holds back the regions
after it, so a later region never takes room an earlier one needs. The demand's staging
(its description and the interest and scratch of the first region) is drawn from the
staging beyond the headroom kept for explicit work; a description that does not fit is
cut at its lowest-priority end and the remainder reported, so an accepted demand can
always be staged. What is not admitted stays as coalesced pending demand, holds nothing,
and is retried in the same order by the owner's `Service` quantum.

### One charge function

Every bank total is derived from the model's records (`bankLedger`); nothing stores or
adjusts one. The rules a total must obey are defined once, in `chargeCheck`, and every
transition is held to them:

* no bank or slot over its limit;
* no resident region over the most its extent allows (`RegionOverMaximum`);
* what the camera side keeps out of explicit reach within the camera share of the
  resident bank (`CameraResidentOverShare`): every held region at its stored maximum
  plus the reservations of the jobs created for camera views, held regions' jobs
  included, and, for an admission, the detail of the regions those jobs enter;
* what the camera side uses of the staging bank within the camera share
  (`CameraStagingOverShare`): view descriptions, view interests, hold records and
  camera job scratch.

An admission (`planAdmission`) and a hold (`AcquireHold`) are tested against the state
they would produce (`admissionCheck`) and are busy if it would break a rule; an owner's
report (`JobCompleted`, `RemovalCommitted`) is a contract failure if it would
(`guardCharge`), changing nothing; and `step` refuses, as a `ChargeBreached` contract
failure, any transition whose result breaks a rule, so a path that forgot a check cannot
return a bad state. `modelInvariants` is the same function plus the structural checks
(victims, awaiting credits, interests), and the randomized interleaving property checks
it after every step.

### Eviction, holds and handoffs

A hold (a borrower or a publication pin) names at most `specHoldRegions` regions (a
typed refusal beyond that, from any state; the default is 256, so a view pins at most
the regions it is rendering from, and the rest of a large view is unpinned camera
detail, which stays evictable). Its records draw only on the staging the camera may
use, and a held region is charged at its stored maximum against the resident bank
less `limitExplicitResidentBytes`, together with the camera's jobs in flight; a hold
beyond either is busy, so a view that keeps releasing and re-acquiring pins can never
take the room an explicit request needs, and a pinned region that grows cannot either.

A resident region may be chosen as a victim only when it has no interest, no hold
(borrower or publication pin), no job, no unsettled changes and no handoff in
flight, and its arena is live. The one exception is for explicit requests: a region
only a camera view has an interest in may be taken (the interest is dropped and the
view's demand for it is pending again), because camera work is best effort. Candidates are taken in least-recently-used order of
the logical clock, ties by arena and region. Retained edits are never evicted. After
a removal commits, its region stays protected (dirty) until a handoff transfers its
changes: the transfer reserves its duplicate in staging, a confirmed transfer needs
no new edit allocation because the retained bytes were funded at the removal, and a
failed transfer keeps the changes, the protection and the retained bytes and is not
retried by the model. A handoff records the region's change generation, so confirming
an older handoff never clears a removal committed after it began: the region stays
changed and protected until a handoff that covers the newer change is confirmed.

### Scheduling

`Dispatch` chooses one queued job: foreground work (any explicit interest) and any
job already passed over for the aging threshold first, then the job whose callers
arrived or were served longest ago (callers take turns, however many regions each
asked for), then the lowest job number. Progress assumptions: required victims are
released, required holds are released, and dispatched finite work reports completion.
Superseded camera work need not finish solely for an obsolete view. A late failure
or completion of work a commit superseded is dropped and never touches current
demand.

### Arena retirement

`RetireArena` takes an incarnation the owner supplies. It withdraws that
incarnation's requests, interests and camera demand; its resident, staging and
retained-edit charges become releasable only after its in-flight jobs, borrowers,
pins and handoffs acknowledge, and after the owner has reported the release of every
region of it that was committed as another admission's victim (that credit funds the
other admission only at the release), in the same step as the last acknowledgement. Later
results for the incarnation are stale. The owner still performs the real close.

### What later owners must supply

TRA-4 supplies identities, sequencing, the real cells of each job, the measured cost
of each completed job, the real edit and its commit revision, and the discard of each
victim. TRA-22 replaces the lifetime retained-edit charge with the storage-aware
decisions of TRA-20 only when it adopts the store, and only for edits that have a
real backing copy. TRA-5 maps refusals to the Lua `busy`. Native memory, GPU ownership and
retirement, and every GPU limit belong to their render and graphics slices.

Retained trace evidence (separate resident, edit and staging ledgers around
reservation, cancellation, completion and handoff, vertical turnover, a failed
handoff, aging, and the negative controls) is in
[the TRA-3 evidence](../../docs/evidence/terrain/tra3/residency_evidence.md).

## Reference mapping

The reference is Synarchy at `3777d437ea00e1302bf55162ad5693fee4879187`. It
fixes some details of this contract and leaves others open; the library selects
the open ones. The design records Synarchy's face map as reference artwork
machinery, not a selected geometry specification for Hetoimasia
(`docs/designs/terrain_arena_design.md:146-148`). Nothing
in the library or the suite reads a Synarchy checkout, a PNG or any other asset;
the reference's relevant arithmetic is restated in the fixtures with provenance.

**What the reference fixes**

- *The bit semantics and neighbor axes.* `src/World/Slope/Compute.hs:116-119`
  take the N, E, S, W neighbors at `ly - 1`, `lx + 1`, `ly + 1`, `lx - 1`, and
  `:135-143` assemble `rawSlope` with N = 1, E = 2, S = 4, W = 8.
- *Which side a set bit lowers.* `slopeBit` (`:188-217`) sets a bit when the
  neighbor on that side is exactly one level lower (`diff == 1`, for dry land),
  so a tile slopes down toward the side whose bit is set. This is the source of
  "a set bit lowers its own side".
- *The identity set and its names.* `src/World/Render/Textures.hs:39-56` selects
  one face map for each of 16 slope IDs 0 to 15, `0` flat and `15` NESW, with the
  names this package uses.
- *The view mapping.* `Textures.hs:27-37` (`viewSlopeId`) rotates the four bits
  by `0`, `1`, `2`, `3` places for the South, West, North and East facings, which
  is the table above.
- *Slope 15 in generation.* `Compute.hs:158` and `:164` turn a raw slope of 15 into
  0: the reference never generates a distinct sloped form for 15 and its mask is a
  flat treatment. Hetoimasia **departs from this on purpose**: owner decision D-49
  makes identity 15 the central half-height peak. The earlier flat-block alias of
  this package (identity 15 as identity 0) is gone; the reference's treatment is
  evidence of what its sprites do, not the shape definition.

**What this package selects, because the reference leaves it open**

- The *solid* behind each mask: a full-width 45-degree ramp per set bit, the
  intersection of the ramps, flat top for 0 alone (15 is the four-ramp peak).
- The *interior profile of NS and EW*: a tent with a half-height ridge.
- The *interior form of the three-side identities* (7, 11, 13, 14): the lower
  envelope of three ramps, peaking at half height on the open side's edge.
- The *corner forms* (3, 6, 9, 12) as pyramids whose crease follows the diagonal.
- *Silhouette and visible faces.* The reference's sprites were inspected only to
  confirm orientation; no silhouette-for-silhouette match is claimed. Matching the
  full 16-identity visual matrix in all four facings belongs to TRA-7/TRA-8 under
  the Q-13 renderer gate. If a reference silhouette cannot be matched by any
  consistent solid, that is the escalation case for the owner; it is not resolved
  by changing the catalog here.

| ID | Name | Reference evidence (`Textures.hs`; bits per `Compute.hs`) | The solid this package selects |
| --- | --- | --- | --- |
| 0 | Flat | `:41` selects the flat map; no bits (`Compute.hs:158`, `:164`) | the unit cube |
| 1 | N | `:42`; bit 1, North neighbor lower (`:135`) | wedge, `z <= y` |
| 2 | E | `:43`; bit 2 | wedge, `z <= 1 - x` |
| 3 | NE | `:44`; bits 1 and 2 | pyramid, apex `(0, 1, 1)`, `z <= y` and `z <= 1 - x` |
| 4 | S | `:45`; bit 4 | wedge, `z <= 1 - y` |
| 5 | NS | `:46`; bits 1 and 4, opposite sides | tent, ridge `y = 1/2` at height 1/2 |
| 6 | ES | `:47`; bits 2 and 4 | pyramid, apex `(0, 0, 1)` |
| 7 | NES | `:48`; bits 1, 2 and 4 | lower envelope of the three ramps, open to the West |
| 8 | W | `:49`; bit 8 | wedge, `z <= x` |
| 9 | NW | `:50`; bits 1 and 8 | pyramid, apex `(1, 1, 1)` |
| 10 | EW | `:51`; bits 2 and 8, opposite sides | tent, ridge `x = 1/2` at height 1/2 |
| 11 | NEW | `:52`; bits 1, 2 and 8 | lower envelope, open to the South |
| 12 | SW | `:53`; bits 4 and 8 | pyramid, apex `(1, 0, 1)` |
| 13 | NSW | `:54`; bits 1, 4 and 8 | lower envelope, open to the East |
| 14 | ESW | `:55`; bits 2, 4 and 8 | lower envelope, open to the North |
| 15 | NESW | `:56`; bits 1, 2, 4 and 8; the reference treats a raw slope 15 as flat (`Compute.hs:158`, `:164`) | the central peak, apex `(1/2, 1/2, 1/2)` (D-49; not the cube) |

### The retained reference defect

The reference's own masks are not consistent with any one solid under a quarter
turn, and that is why its masks are evidence and not the shape definition. With the
reference's full-block projection `u = 48 + 48 (x - y)`, `v = 16 + 24 (x + y) - 16 z`,
the E mask's texel `(48, 2)` is opaque `(0, 255, 0, 255)`. The cell points that
project anywhere into that texel's whole area satisfy `0 <= x + y <= 1/8`,
`0 <= x - y <= 1/48` and `13/16 <= z <= 1`. Under the inverse quarter turn
`(x, y, z) -> (y, 1 - x, z)` they project into the N mask's window
`[0, 6] x [23.5, 27]`, every enclosing texel of which is transparent (the first
opaque N rows of columns 0 to 7 are `39, 39, 38, 38, 37, 37, 36, 36`). So an opaque
part E requires would lie inside a transparent part of N after the turn, by a wide
margin. `Test.Terrain.Reference` keeps the samples (the two pinned blobs
`effc21564c7a653605dcbafca23ce7bc560e262d` for N and
`5ed533b4d9467fa3b371a4cb489a87844fa64611` for E at the reference revision above),
`test/reference/extract_facemap_samples.py` reproduces them from a sibling checkout,
and the suite derives the implication itself in exact arithmetic. No PNG, checkout
or network is read at test time, and this is not corrected-mask, alpha-picking,
lighting or GPU evidence (TRA-14, TRA-16 and TRA-17).

## Tests

`hetoimasia-terrain:terrain-tests` is the non-optional CPU group `test.terrain`:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
```

It is deterministic, starts no thread of its own and sleeps nowhere. Expected geometry is an
independently authored matrix of vertices and faces for all 16 identities, with
exact rotation checked in four facings against the tests' own turn. The opening
examples check the portals of every identity in all four orientations against a hand
table of areas and a height-rule oracle sampled on a lattice that avoids every
boundary, integrate the area two neighbors share across each side independently,
exercise all six directions, edge-only and point-only contact, and diagonal paths and
their sealed controls through every orientation at placements across chunk,
vertical-region and negative seams and at both ends of the range (a missing tile is
unavailable, never air), and tie portals back to point and ray results. The source,
storage and query examples compare the library with an independent naive model
(`Test.Terrain.Model`) that scans every record for every level and shares no code
with the library, and with literals; the encoding examples assert the approved
payload table. The suite is built with `-with-rtsopts=-T` for the growth
examples, and an example that finds the statistics disabled fails. No example's
expected value is produced by the code it checks. `Test.Support.ExternalClient`
compiles a client outside the package: three must link and run, and every attempt
to name a private constructor, forge a value from one, rewrite a validated limit or
the model's state with record update, or import a private module must be refused for
the specific diagnostic that names the cause. The residency examples drive the model
with controlled events (no thread, sleep or deadline), recompute every ledger from
the model's records after each step, run the model beside the real source, changes
and resident detail across repeated edit, handoff, evict and reconstruct cycles, and
check the structural invariants over randomized event sequences. The connectivity
examples (TRA-18) compare the compiler with an independent flood model
(`Test.Terrain.ConnectivityOracle`) that shares no code with it: it re-derives each
shape's top from the stated height rule, decides whether two cells connect by exact
rational sampling of the shared face, and floods a finite window cell by cell. The
generated comparisons (`Test.Terrain.ConnectivityFixtures`, SplitMix64 seeds named in
each example) cover sealed rooms of every default kind (air and all 16 identities,
hence all four rotations of each orientable shape) with random air, block and shape
patches, covered open worlds whose window reproduces the unbounded plane around
them, open-top worlds whose air reaches the real upper limit, and rooms at the
coordinate extremes; each compares void against no-void, the partition into
components as a bijection with the keys, exterior, range membership, portal relations
(sound, and with each box's interior connections complete) and every boundary face.
Hand-stated fixtures check the flat source, wholly air terrain, covered and shafted
slabs, uniform ramp families in two rotations, patch splits and joins and negative
seams at spans of `2^20` and `2^60`. Negative controls (a family merged into one
component, a level dropped from a family, a side limit called exterior) must be
rejected by the same comparison. `Test.Terrain.ConnectivityBounds` tests every
configured bound at its exact boundary and one below it, quanta of 1, 17 and 1,024,
refusals, scale-independence of the structure counts and accounted bytes, and the
runtime's own allocation read with `GHC.Stats` (measured allocation, not admission
bytes and not RSS).

The discovery examples (TRA-19, `Test.Terrain.Discovery` with the driver and explicit
oracle `Test.Terrain.DiscoveryHarness`) run ordered traces of removals, discovery
batches, drains and record replays over small authored worlds and, after every event,
check the retained state for legitimacy after every event and after every batch of a
drain as well (it rebuilds from its own records, its removed
runs are exactly the removals applied, each connection was inspected exactly once, every
report is within its limit) and compare production knowledge with an independent
explicit model that shares no code with the overlay. The model reads the source as plain
data, decides which neighbours connect by exact rational sampling of the shared face
(reusing `Test.Terrain.ConnectivityOracle`), floods the window cell by cell and derives
known voids and known solids from first principles. Production knowledge must lie
between the oracle after the removals whose obligations are finished and the oracle
after every removal, and equal the latter when the obligations are drained. The cases
cover both opening orders and every interleaving of two openings with batches of 1, 2,
3 and 64 updates, raw buried and long coalesced removals, known solid against unknown
void, edge-only and point-only controls, 48 generated traces (all 16 identities, four
origins across negative region seams), huge ramp families at `2^20` and `2^60`, a
bounded working window while retained history grows, a record withheld and restored,
exact and insufficient allowances, stale and foreign candidates, overflow, and
negative controls that the oracle must reject. A lockstep example rebuilds one run from its
records alone after every edit and every batch of a drain and compares it with an
uninterrupted run record for record. A counting provider, independent of the model's
accounting, shows no request is made beyond an allowance on any exit, and an allocation
example shows a class lookup costs the same for a source with 0 and with 200 patches. Generated
properties cover the rest: a **revision property** over random edit, batch, forget, replay and
drain sequences (content advances with an applied removal only, knowledge never decreases and
advances whenever known space appeared, known voids never shrink, a known solid is lost only by
removing it, and a candidate staged before an action is refused after it); and a **windowed
replay property** that runs the same sequences through a provider exposing only the 16, 24 or 40
most recently loaded records, suspends and resumes on every missing record, evicts and reloads,
rebuilds the retained value from its records after every applied candidate and compares the
logical result (runs, removals, remaining work, knowledge) with the uninterrupted run. A
client compiled outside the package shows the discovery state unforgeable.

## Consumers

TRA-4 builds the transactional service on the sparse representation, the removal
overlay and the residency model. TRA-5 copies values across the Lua
boundary. TRA-7 builds camera projection, picking and visible-face planning on `Solid`,
`sideCoverage`, `castRay` and `castSegment`; TRA-8 compares the visual matrix.
