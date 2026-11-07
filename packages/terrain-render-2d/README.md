# hetoimasia-terrain-render-2d

The pure planning half of the terrain arena's 2D view (epic #636, TRA-7): the
exact isometric projection of the shared terrain solids, the follow and manual
cutaway camera as pure state, the bounded visible faces and the facts that decide
their exposure, missing-data demand, deterministic back-to-front ordering
candidates inside the 2D renderer's 24-bit depth keys, and CPU picking against
the exact plan it was given.

It plans; it does not draw. The material and shader work, artwork selection and
offscreen qualification are TRA-8 (#644); retained uploads, adoption and live
publication are TRA-9; the Lua pick and removal connection is TRA-10. Nothing
here edits terrain, takes a lease, reads mutable state, launches a worker or
keeps a cache.

| Module | Purpose |
| --- | --- |
| `Hetoimasia.Terrain.Render2D.Projection` | The exact projection, facing turns, the render view built on render-2d's mapping |
| `Hetoimasia.Terrain.Render2D.Camera` | Follow and manual camera state, commands, zoom, rotation, jumps |
| `Hetoimasia.Terrain.Render2D.Facts` | Versions, availability, the three-way fact answer, surface lookup, demand |
| `Hetoimasia.Terrain.Render2D.Plan` | Visible faces, exposure, bounds, demand, ordering and depth keys |
| `Hetoimasia.Terrain.Render2D.Pick` | CPU picking against one plan |

`Hetoimasia.Terrain.Render2D.Internal.*` are private; the package does not expose
them and the suite proves a client cannot import them.

## Dependencies, ownership and lifetime

Production dependencies are `base`, `containers` and the pure `hetoimasia-terrain`,
`hetoimasia-math`, `hetoimasia-render-2d` and `hetoimasia-render-api` packages
(the last supplies the texture handle in render-2d's `Instance`). No game, Lua,
GLFW, runtime terrain service or GPU backend package reaches it.

Every value is immutable and every function is pure, so there is no state to own:

- The *caller* owns the one current `CameraState` and replaces it with each
  transition's result, and owns the `Source`, `Changes` and `Availability` values
  a `TerrainFacts` names. The residency owner is the writer of availability.
- A `Plan` is a whole immutable value. Planning again returns a new one; a
  retained older plan is never changed. The renderer-side adoption and lifetime
  of a plan belong to TRA-9.
- The package owns no thread, process, queue, cache or other resource, and has
  nothing to reset or dispose.

## Frames and equations

Tiles are exact: `TileCoord`, three checked signed 64-bit axes `[-2^62, 2^62 - 1]`.
The world is X east, Y south, Z up; a cell `(x, y, z)` occupies the unit footprint
and begins at elevation `z`.

1. The camera's *anchor* is an exact tile column plus a fractional offset in
   `[0, 1)` on each axis (`camFrac`, a `Rational`), and an exact integer
   *vertical reference* `camRef`: the elevation of the horizontal plane at the
   viewport centre. Absolute addresses are never converted to a float.
2. The world is *turned* by the facing's quarter turns about the centre of the
   anchor tile (the view frame). One positive turn takes `(dx, dy)` to
   `(-dy, dx)` between tile centres, a compass turn taking East to South, as
   `rotateShape` does for masks. The facing `FaceSouth` is 0 turns, `FaceWest` 3,
   `FaceNorth` 2, `FaceEast` 1. A cell keeps its authored world tile and shape
   identity; only its offset and the mask it presents (`viewShape`) turn.
3. *Relative frame*: view-frame coordinates from the anchor tile's centre
   horizontally and from `camRef` vertically, computed in `Integer` from exact
   tile values, so differences, rotated offsets, cut planes and projected bounds
   cannot overflow and only small bounded offsets reach a floating-point number.
4. *Render world* is native-scale isometric pixels in the relative frame. For a
   relative point `(x, y, z)` in tile units (Y down on screen):

   ```
   sx = 48 · (x − y)
   sy = 24 · (x + y) − 16 · z
   ```

   so a top diamond is 96 pixels wide and 48 tall and a level is 16 pixels, the
   selected 96/48/16 baseline. Points with equal `(sx, sy)` differ by a multiple
   of `(1, 1, 3)`; the camera lies in that direction, and a larger multiple is
   nearer.
5. The render-2d `ViewMapping` composes this with zoom, viewport and the
   logical-window/framebuffer conversion. The camera position given to render-2d
   is the projection of the turned fractional offset (a few dozen pixels at
   most); zoom is the camera's zoom. Drawing and picking use the same mapping,
   including pixel snapping. The visible render-world rectangle is the viewport's
   four corners through the inverse, widened by a two-pixel margin that absorbs
   the mapping's 32-bit rounding and snap.

*Pixel snapping.* The recorder rounds each instance's origin to the device pixel
grid separately, so adjacent faces with different fractional origins would be
drawn apart by up to half a pixel and open cracks. Face origins lie on a lattice
of 48 pixels horizontally and 8 vertically at native scale, so every origin is on
a whole pixel exactly when the zoom is a whole multiple of 1/8. A view that
snaps at any other zoom is refused (`PixelSnapUnsupported`); `snapCompatible`
answers it. A view that does not snap has no such restriction.

Refusals are explicit: an invalid or non-finite view or zoom is
`InvalidView ViewRefused`; a camera not representable as a `Float` is
`UnrepresentableCamera`; a face the view's own mapping cannot place in the
target (the composed transform overflows) is `Unrepresentable`, never an empty
or partial polygon. A viewport with a zero extent, or a target whose logical or
framebuffer extent has a zero side, plans no faces and no demand and has no hits;
a point outside the viewport cannot hit. Nothing wraps and the world extent is
never clamped: a cell beyond the supported range does not exist and counts as
known air (so a face at the last supported coordinate is exposed to the void).

## Camera

`CameraState` is abstract (its accessors are plain functions, not record fields,
so a client cannot rewrite one). `newCamera`, `applyCommand`, `refollow`,
`completeJump` and `cancelJump` are the transitions; each returns a new state or
a typed refusal and changes nothing on refusal. There are no key bindings or
gesture accumulators.

- **Mode.** `Following` or `Manual level`. `camClip` is the effective clip level
  the plan cuts at: cells with `z <= clip` are included and the cut plane is at
  `clip + 1`. Following, it is the followed surface plus the configured
  automatic headroom (`ccHeadroom`, initially 25), capped at the highest
  supported level, which includes the same cells. Manual, it is the selected level
  exactly with no headroom.
- **Follow.** The surface is the highest remaining solid cell of the anchor column
  from the source *and* retained removals. Adopting it sets `camClip` and moves
  `camRef` to the surface's top plane, `surface + 1`. A *known empty* column
  preserves the current slice and reference and reports `FollowColumnEmpty`. A
  column whose facts are *unavailable* is not empty: the slice and reference are
  preserved, `FollowUnavailable` carries the missing facts as a `Demand`, and the
  surface is adopted only when `refollow` is later given facts that supply it.
- **Reference movement.** `camRef` changes only when a surface is adopted or a
  jump with a Z lands (to that depth's top plane). Pan, zoom, rotation, a manual
  slice change and `SliceBy` never move it.
- **Pan, zoom, rotation.** Pan carries whole tiles into the anchor with checked
  arithmetic and refuses a result outside the supported range
  (`PanOutOfRange`) or a non-finite input; the fraction stays an exact
  `Rational`. Zoom clamps to the validated finite range (initially 0.125 to 8,
  default 1 at native artwork scale); a non-finite or non-positive zoom is
  refused. `SetFacing`/`RotateBy` change only the facing, so the world anchor is
  the same.
- **Slices.** `SelectSlice level` enters manual mode at that exact level;
  `SliceBy delta` adds whole levels to the current effective clip level and makes
  the result the manual slice. Manual depth survives pan, zoom and rotation.
- **Jumps.** A jump without Z restores following at the destination (centre of the
  destination tile); a jump with Z enters manual mode at that depth. Zoom and
  facing are preserved. If the destination facts are not ready the jump is
  *pending*: the last coherent view is kept, `JumpPending id demand` names the
  missing facts, and a later `completeJump` for that identity lands it when the
  facts allow. Each jump has a `JumpId`; a newer jump supersedes a pending one and
  `cancelJump` clears it, and a completion for any identity but the current
  pending one is `JumpStale` and changes nothing, so a cancelled or superseded
  late result can never move a newer view. This is the pure transition model, not
  the asynchronous Lua API or its execution.
- `camRevision` increases with every transition that changes the state.

## Facts, availability and the three-way answer

`TerrainFacts` names a `Source`, the retained `Changes` and an `Availability`,
with the `Versions` (arena incarnation, content revision, residency generation)
the caller stamps on them. Cell values come from the source plus removals (the
TRA-2 authority); whether a cell may be *shown* is the residency owner's
`Availability`: per horizontal chunk (16 × 16 columns), the half-open level
intervals that are ready, or `AllKnown`. A level in no ready interval is
**unavailable**, which is neither air nor solid. Every query keeps the three
answers apart (`FAir`, `FSolid`, `FUnknown`); a missing neighbour or region is
never evidence of air. A chunk absent from the map is wholly unavailable,
including its column summaries; a chunk present has its summaries published, so
its empty column is known empty. Two adjacent ready intervals coalesce, so a
seam between them is invisible.

`columnFacts` reads a window of one column as runs over the source's and the
availability's intervals; a long gap of air, solid or removed cells is one run.

## Visible faces

Cell `z` is included when `z <= clip`; the visibility band is the clip level and
`pcDepth` (initially 250, and at most 250: a larger configured depth is
`InvalidPlanConfig`) levels below it, `[clip - 250, clip]`. This is a
visibility cap, not a terrain floor, and not a promise to load that volume; it is
independent of the 32-level storage region.

The view looks along `(1, 1, 3)`, so only a face whose outward normal has a
positive component along it can be seen: every top and sloped surface, the
**East** wall and the **South** wall of the view frame. A bottom face and the
North and West walls are never emitted. A *ceiling* is therefore never drawn: a
cavity ceiling is hidden by the cell that forms it, and when the cut removes that
cell the floor, walls and caps are what is revealed. The face set of a cell is
read from the shared `Hetoimasia.Terrain.Geometry` solid of the *view-frame* shape
(`viewShape facing shape`), so projection, caps, coverage and picking use one
geometry and there is no parallel slope catalog.

Exposure, per visible face, from the facts:

| Face | Emitted when |
| --- | --- |
| Sloped top | always: it borders the air inside its own cell |
| Flat top (plane `z = 1`) | the cell above is known air; or at the clip level, where the cut exposes it |
| East / South wall | the neighbouring cell on that side is known air or beyond the supported range; or solid and its opposite wall does not cover this wall |

*Cap.* A flat top at the clip level is a `RoleCap` unless the cell above is known
air (`RoleSurface`): the cut removed whatever lay above it. A top under a known
solid below the cut is not emitted. *Partial contacts.* A wall is compared with
the neighbour's actual opposite wall polygon from the shared solid, both in the
plane's coordinates: it is hidden only when every vertex lies in the neighbour's
wall, so a ramp, tent or pyramid neighbour exposes exactly what it leaves open.
This is never a full-block occupancy shortcut. A face that depends on an
unavailable fact is not emitted.

The planner does not edit terrain or reshape a neighbour, and the 0 and 15 flat
identities and opposite-direction masks stay distinct in every facing
(`faceShape` is the authored world shape).

## Bounded work and outputs

Candidate columns are enumerated from the visible rectangle, and for each column
only the levels that can project into the rectangle inside the band. Only the
levels at a run boundary of the column or its East and South neighbours, and the
levels where a solid cell meets a neighbour that is not an identical flat solid,
are evaluated, so cost follows the intervals and exposed faces and not the depth;
a deep slice or a long air gap enumerates nothing in between.

`PlanLimits` bound columns, levels examined, faces, overlap candidate pairs,
depth keys, chunks and intervals in a demand, and vertical regions per chunk
(independently of the number of columns). Each is checked before the work or
output it limits and exceeding one is `PlanInsufficient limit`: nothing is
truncated, no arbitrary suffix is dropped and nothing is retried inside the
planner. `defaultPlanLimits` are engineering defaults, not measured capacity.
`PlanStats` reports columns, levels examined and faces. The bounds on levels and
faces are checked as the work proceeds, the overlap-pair bound stops the
enumeration at the first pair past it, and the demand ring is generated
incrementally and refused at the first chunk past its bound.

## Demand

A plan is `Complete` or `Incomplete`. `planDemand` names the unavailable facts the
plan needed as `ChunkDemand`s: the horizontal chunk key, explicit half-open level
intervals (ascending, coalesced) and the vertical region keys (32 levels) they
touch, so later integration can coalesce and admit them without re-deriving them
from screen geometry. `planUnknown` bounds, in render-world pixels, the cells
nothing is known about. `cameraDemand` describes the bounded visible region plus a
margin of `pcChunkMargin` horizontal chunks (initially one) that is not yet ready,
as latest-value state; later integration coalesces and executes it.

## Ordering and depth keys

An `Instance` is a transformed unit square with one depth key in `[0, 2^24)`, a
larger key nearer. Each planned face is therefore a **quad plus a coverage
mask**: `faceQuad` is the instance transform of the unit square (a parallelogram:
a top face is the image of its footprint `(x, y)`, a wall of `(position along the
side, 1 − z)`), `faceMask` is the face's polygon in the unit square (the same
vertices as `facePolygon`, in the same order), and `facePolygon` is the exact
render-world polygon. The same face and mask serve the later material adapter and
this package's picking. `faceInstance` builds a render-2d `Instance` from a caller
texture handle.

Two faces constrain each other only where their projections overlap with positive
area. At every point of that overlap the one with the larger parameter along
`(1, 1, 3)` is nearer; planes of terrain faces cannot cross inside the overlap, so
the sign of the difference at the vertices of the exact overlap polygon decides
the pair. The constraints form a graph whose topological order — taking the
smallest canonical key (view-frame offsets, level, face index) among the ready
faces — is the total order, and each face's depth key is its position. Keys are
therefore distinct, independent of material grouping, chunk enumeration, source
traversal and input order, and no equal-key tie is ever left to the renderer.
Keys are valid within one plan; a plan neither merges with another plan's keys nor
assumes the cutout/ordered split, and the renderer's own run partitioning and
retained/dynamic merge (which resolve equal keys by submission order) never see
an equal key from one plan.

Anything the keys cannot express is refused, never approximated:
`PlanInsufficient LimitDepthKeys` when the faces outnumber the key space or the
configured key limit; `PlanUnorderable (OrderingCycle faces)` when the faces form
a cycle; `OrderingCrossing`/`OrderingCoincident` when two planes cross or coincide
inside an overlap. The refusal carries the faces as a counterexample. This is the
Q-13 stop path: no new vertex format, per-fragment depth or approximate visual
substitute is introduced here. The CPU fixture matrix (scenes, facings, cuts and
2,500 generated scenes, with no refusal and no disagreement) is recorded in
`docs/evidence/terrain/tra7/q13_cpu_evidence.md`.

## Picking

`pickPlan plan (PickQuery identity windowPoint)` answers from the exact plan:

- The presented `PlanIdentity` must equal the plan's, or the pick is
  `Left PickStale` (a mixed or superseded input).
- The window point goes through the plan's own mapping. Each face is tested as
  drawn: its mask vertices through its instance quad and the world-to-target
  transform in 32-bit floating point, plus, when the view snaps, the rounding of
  its instance origin (`snapPoint`), as the recorder does it.
- The frontmost containing face by depth key wins. A point on an edge shared by two
  faces belongs to the one whose left or top edge it is (the viewport's own
  half-open rule), so exactly one contains it.
- The integer cell identity is carried by the face, never derived from the float
  position, and is exact at any coordinate.
- A face that the plan's mapping cannot place in the target makes the pick
  `Left PickUnrepresentable`; nothing is answered from a partial polygon (a plan
  already refuses such faces).
- A point in a region the plan marks unknown is `PickIncomplete`, carrying the best
  known candidate if any, never `PickHit` and never `PickNoHit`. Picking removes
  nothing and issues no token; token authenticity and the Lua connection are later
  slices.

## Versions and identity

A request carries `Versions` that must equal the facts' (`MixedVersions`), plus a
material version (caller data, carried, never interpreted). The camera revision
comes from the camera. A `PlanIdentity` records the versions, the camera
revision, the material version, the facing, the cut level and the vertical
reference; a pick presents it. Planning never adopts a GPU frame or issues a live
pick token.

## What remains for TRA-8

This package proves, on the CPU, that the shared face and coverage geometry
projects, orders and picks consistently. It does not prove what the GPU draws.
TRA-8 must qualify, offscreen: the actual materials and transparent coverage of
the masks, depth behaviour of ordered and cutout paths with these keys, and the
visual matrix of all 16 identities in all four facings. If a required geometry
cannot be ordered through the existing instance ABI, the refusals above name it.

## Tests

`hetoimasia-terrain-render-2d:terrain-render-2d-tests` is the non-optional CPU
group `test.terrain-render-2d`:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct
```

It is deterministic, starts no thread and sleeps nowhere. Projection, camera and
planning expectations are hand-stated from the equations above and small explicit
terrain. Visibility, ordering and picking are checked against an independent
oracle that casts exact rays through the same cells with the terrain package's
`castRay`, sharing no code with the planner. Negative controls were broken once
locally and caught (reversed order, dropped caps, backmost picking, unavailable
treated as air, full-block contacts, cells above the cut, accepted mixed
versions, ignored band depth, shown covered tops, accepted snapped zooms, the
symmetric chunk range, unbounded pair collection, ignored framebuffer extents,
no depth cap, no representability check); none is
committed. `Test.Support.ExternalClient` compiles a client outside the package:
one must link and run, and every attempt to name a private constructor, rewrite a
camera with record syntax or import a private module must be refused for the
specific diagnostic.
