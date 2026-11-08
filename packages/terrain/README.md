# hetoimasia-terrain

Checked terrain tile identity, the canonical geometry of every terrain shape,
and the pure source, storage and query kernel of the terrain arena arc (epic
#636). TRA-1 supplied pure coordinates, region keys, a 16-shape catalog with
exact rotation, and the one geometric authority that face generation, cutaway
coverage and picking will share. TRA-2 adds the immutable layered source, the
packed sparse resident-detail representation and the retained-removal overlay
with the queries over them, and TRA-3 the pure residency and admission model
over them. It is a data, query and decision kernel, not a world store:
transactional ownership, revisions and live offload (TRA-4), Lua copying
(TRA-5), input, camera, rendering and arena assembly belong to later slices.

| Module | Purpose |
| --- | --- |
| `Hetoimasia.Terrain.Coordinate` | Checked tile identity, region/local decomposition, cutaway |
| `Hetoimasia.Terrain.Shape` | The 16-shape catalog, sides, quarter turns, view facings |
| `Hetoimasia.Terrain.Geometry` | The canonical unit-cell solid, face coverage, membership, ray and segment queries |
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
- Identities 0 and 15 are distinct authored identities, kept distinct even
  though both have a flat top; NS and EW are distinct opposite-direction forms.
- Arbitrary fractional slabs and new identities need a later, explicit
  extension.

### Quarter turns

Rotation permutes the four mask bits. **One positive quarter turn takes North to
East to South to West to North.** This is a compass mapping, never inferred from
an angle sign: with North toward -Y, East toward +X and Z as elevation the axes
are left-handed compared with the math package's "a quarter turn about +Z takes
+X to +Y", so reusing that package's `rotation` sign would reverse the facing
order. Four turns restore the starting shape; 0 and 15 are fixed and NS and EW
exchange under a single turn. `turns` normalizes any count, including a negative
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

where the top is a flat `z <= 1` for identities 0 and 15, and otherwise one
full-width 45-degree ramp per set bit, each 0 high on its own side and 1 high on
the opposite side:

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
zero-thickness edge, which is no face. Identity 15 is the authored all-sides
identity with a flat top, and its solid is exactly that of identity 0.

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
fully covered only opposite a lowered side, or on a flat identity. The top faces
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
staging the camera may use must hold the description; how much of a description is kept
is decided by the ordinary admission, never by a separate estimate. The model walks the
regions in priority order on the state the withdrawal left, growing the view's description
by one region at a time and asking `planAdmission` (the code `Service` runs later) for each.
A region that fits is admitted. The first that does not fit now is kept, pending, with the
regions behind it, when it would be admitted once the pressure that is the owner's to
release has been released (jobs finished or acknowledged, pins and explicit requests
withdrawn, regions evicted for them gone); its turn comes on a later `Service`, and cancelled
work keeps its charges until its owner acknowledges it. The walk stops, and the rest is cut
and reported, at the first region whose description no longer fits the staging the camera
may use, or that would not be admitted even after the release, so a kept description can
always be started. Replacing a view's demand is withdrawing the old one and admitting the
new one through this same path (a property checks that the two produce the same model at
every state random sequences reach, and another that the kept prefix is what the ordinary
path leaves).

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
   rule: the design's D-40 (temporary disk backing for retained terrain changes,
   pending Q-19 and Q-20) is outside this slice, and the bound is not the arena's
   final total-history contract.
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
victim. TRA-5 maps refusals to the Lua `busy`. Native memory, GPU ownership and
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
- *The flat top of 15.* `Compute.hs:158` and `:164` turn a raw slope of 15 into 0:
  generation never produces a distinct sloped form for 15, which therefore has a
  flat-top treatment. 0 and 15 stay distinct identities; the solid of both is the
  cube.

**What this package selects, because the reference leaves it open**

- The *solid* behind each mask: a full-width 45-degree ramp per set bit, the
  intersection of the ramps, flat top for 0 and 15.
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
| 15 | NESW | `:56`; bits 1, 2, 4 and 8; flat-top treatment (`Compute.hs:158`, `:164`) | the unit cube, as 0 |

## Tests

`hetoimasia-terrain:terrain-tests` is the non-optional CPU group `test.terrain`:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
```

It is deterministic, starts no thread of its own and sleeps nowhere. Expected geometry is an
independently authored matrix of vertices and faces for all 16 identities, with
exact rotation checked in four facings against the tests' own turn. The source,
storage and query examples compare the library with an independent naive model
(`Test.Terrain.Model`) that scans every record for every level and shares no code
with the library, and with literals; the encoding examples assert the approved
payload table. The suite is built with `-with-rtsopts=-T` for the growth
examples, and an example that finds the statistics disabled fails. No example's
expected value is produced by the code it checks. `Test.Support.ExternalClient`
compiles a client outside the package: two must link and run, and every attempt
to name a private constructor, forge a value from one, rewrite a validated limit or
the model's state with record update, or import a private module must be refused for
the specific diagnostic that names the cause. The residency examples drive the model
with controlled events (no thread, sleep or deadline), recompute every ledger from
the model's records after each step, run the model beside the real source, changes
and resident detail across repeated edit, handoff, evict and reconstruct cycles, and
check the structural invariants over randomized event sequences.

## Consumers

TRA-4 builds the transactional service on the sparse representation, the removal
overlay and the residency model. TRA-5 copies values across the Lua
boundary. TRA-7 builds camera projection, picking and visible-face planning on `Solid`,
`sideCoverage`, `castRay` and `castSegment`; TRA-8 compares the visual matrix.
