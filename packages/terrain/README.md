# hetoimasia-terrain

Checked terrain tile identity and the canonical geometry of every terrain
shape. This is the first slice of the terrain arena arc (TRA-1, epic #636): pure
coordinates, region keys, a 16-shape catalog with exact rotation, and the one
geometric authority that face generation, cutaway coverage and picking will
share. It is not a world store: nothing here holds terrain, generates it, or
answers what is at a position.

| Module | Purpose |
| --- | --- |
| `Hetoimasia.Terrain.Coordinate` | Checked tile identity, region/local decomposition, cutaway |
| `Hetoimasia.Terrain.Shape` | The 16-shape catalog, sides, quarter turns, view facings |
| `Hetoimasia.Terrain.Geometry` | The canonical unit-cell solid, face coverage, membership, ray and segment queries |

`Hetoimasia.Terrain.Internal.*` are private implementation modules; the package
does not expose them, and the suite proves a client cannot import them.

## Dependencies and ownership

The library depends on `base` and `containers` alone. It imports no other local
package, so no Lua host, window, GLFW, renderer, GPU, runtime or concrete game
reaches it, and it reads no file and no asset. The independent math package is
not used: its Float vectors and right-handed rotation do not fit exact integer
identity or the compass-defined turns below (see
[Quarter turns](#quarter-turns)). A later consumer converts to its own
camera-relative floating point from the exact values this package returns.

Terrain state does not live here. Every value is immutable and every function
is pure, so there is no owner, writer, thread, lifetime, reset or disposal to
document: constructing, translating or decomposing a coordinate allocates no
terrain volume, scans no column and holds no resource.

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
exact rotation checked in four facings against the tests' own turn. No example's
expected value is produced by the code it checks. `Test.Support.ExternalClient`
compiles a client outside the package: one must link and run, and every attempt
to name a private constructor, forge a value from one, or import a private module
must be refused for the specific diagnostic that names the cause.

## Consumers

TRA-2 builds storage and source queries on this identity and shape contract.
TRA-7 builds camera projection, picking and visible-face planning on `Solid`,
`sideCoverage`, `castRay` and `castSegment`; TRA-8 compares the visual matrix.
