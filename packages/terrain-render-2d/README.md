# hetoimasia-terrain-render-2d

The pure half of the terrain arena's 2D view (epic #636): the exact isometric
projection of the shared terrain solids, the follow and manual cutaway camera as
pure state, the **whole-cell quad planner** (TRA-16) over supplied discovery
knowledge and atlas-region coverage, bounded resumable preparation, viewport
demand and picking from the coverage the plan draws, the deterministic offline
**terrain atlases** and their checked region manifest (TRA-17), the presentation
settings and the **terrain material** that lights and depth-shades the quads
(TRA-17), and the offline cutout and normal-map generator (TRA-14). The per-face
planner, analytic picker and polygon-mask material that preceded the cell-quad
path were removed by TRA-17 after the device proof; nothing here describes them
as current behaviour (the retained `docs/evidence/terrain/tra8/` captures are
labelled history of that model).

It plans; it does not draw. The Vulkan half is
[`hetoimasia-terrain-render-2d-vulkan`](../terrain-render-2d-vulkan/README.md).
Retained uploads, adoption and live publication are TRA-9; the Lua pick and
removal connection is TRA-10. Nothing
here edits terrain, takes a lease, reads mutable state, launches a worker or
keeps a cache.

| Module | Purpose |
| --- | --- |
| `Hetoimasia.Terrain.Render2D.Projection` | The exact projection, facing turns, the render view built on render-2d's mapping |
| `Hetoimasia.Terrain.Render2D.Camera` | Follow and manual camera state, commands, zoom, rotation, jumps |
| `Hetoimasia.Terrain.Render2D.Facts` | Versions, availability, the three-way fact answer, surface lookup, demand |
| `Hetoimasia.Terrain.Render2D.Knowledge` | The supplied discovery knowledge a cell-quad plan reads (TRA-16) |
| `Hetoimasia.Terrain.Render2D.Assets` | The supplied colour and map coverage as checked regions of shared parent planes, with their versions and region-aware identity (TRA-16, TRA-17) |
| `Hetoimasia.Terrain.Render2D.AtlasAssets` | The style's asset snapshot built from the manifest and the two loaded parent atlases (TRA-17) |
| `Hetoimasia.Terrain.Render2D.Cells` | Cell-quad planning, bounded progress, demand and identity (TRA-16) |
| `Hetoimasia.Terrain.Render2D.CellPick` | Visual picking from the coverage a cell-quad plan draws (TRA-16) |

The package also owns the offline cutout and normal-map asset generator
(TRA-14; see [the canonical maps](#the-canonical-cutout-and-normal-map-assets-tra-14)):
the pure `hetoimasia-terrain-render-2d:terrain-mapbake` component, its file side
`terrain-mapgen-core` and the `terrain-mapgen` executable. None depends on Vulkan,
a window, Lua or the terrain service.

The package's further public components have no GPU, window, Lua or game
dependency either:

| Component | Modules | Purpose |
| --- | --- | --- |
| `hetoimasia-terrain-render-2d:terrain-atlas` | `Hetoimasia.Terrain.Atlas.{Manifest,Pack}` | The checked, bounded atlas region manifest and the deterministic offline packer (TRA-17) |
| `hetoimasia-terrain-render-2d:terrain-material` | `Hetoimasia.Terrain.Render2D.{Material,Presentation}` | The presentation settings and the 48-byte push block, the two-handle record, `adaptCells`, `adaptedInstance`, `terrainView` and `terrainModel`, the pure model of the fragment function (TRA-17) |
| `hetoimasia-terrain-render-2d:terrain-fixtures` | `Hetoimasia.Terrain.Render2D.{Evidence,Scenes,AtlasFixtures}` | The evidence scenes, the committed atlases' loader (through the bounded PNG decoder) and the independent hand model of the quad contract; shared by the CPU suite and the native scenario so neither imports the other's spec. No engine library depends on it. |

`Hetoimasia.Terrain.Render2D.Internal.*` are private; the package does not expose
them and the suite proves a client cannot import them.

## Dependencies, ownership and lifetime

Production dependencies are `base`, `containers` and the pure `hetoimasia-terrain`,
`hetoimasia-math`, `hetoimasia-asset-image` (the checked region views), `hetoimasia-render-2d` and `hetoimasia-render-api` packages
(the last supplies the texture handle in render-2d's `Instance`). No game, Lua,
GLFW, runtime terrain service or GPU backend package reaches it.

Every value is immutable and every function is pure, so there is no state to own:

- The *caller* owns the one current `CameraState` and replaces it with each
  transition's result, and owns the `Source`, `Changes` and `Availability` values
  a `TerrainFacts` names. The residency owner is the writer of availability.
- A `CellPlan` is a whole immutable value. Planning again returns a new one; a
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
a whole pixel exactly when the mapping's world scale is a whole multiple of 1/8.
The scale is taken from the render-2d world transform itself, so it includes the
scale a fixed-half-height zoom mode gives (viewport height times zoom over twice
the half-height), not the camera zoom alone. A view that snaps at any other
scale is refused (`PixelSnapUnsupported`, carrying the scale); `snapCompatible`
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
so a client cannot rewrite one). Every transition that takes a `CameraConfig`
(`newCamera`, `applyCommand`, `refollow`, `completeJump`) validates it first and
answers `Left InvalidConfig` without touching the camera: a negative headroom or
an unordered zoom range is never installed as a cut. The same transitions also
bound the camera's zoom by the configuration in force, so a camera built under a
wider range cannot keep a zoom the current range forbids. `PlanConfig` is
validated the same way: a negative or over-large depth, margin or chunk margin, a
negative `PlanLimits` bound, or a key bound beyond the 24-bit key space is
`InvalidPlanConfig`. `newCamera`, `applyCommand`, `refollow`,
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

## Terrain atlases and checked regions (TRA-17)

Every terrain texture is an **atlas**: a single image is the same contract with one
full-image region. `terrain-mapgen --atlas-output DIR` writes, deterministically and
without altering any 96 x 64 canvas, one **colour atlas** (`colour.png`: loam,
granite, blank; 288 x 64) and one **normal atlas** (`normal.png`: the 46 catalog
maps, eight to a row in catalog order; 768 x 384) and a versioned region manifest
(`manifest.json`) under `samples/ecce-homo/content/textures/terrain-atlas/`.
`--check-atlases` regenerates in temporary storage and compares without writing,
failing nonzero on a missing, changed or unexpected file. Unused grid cells are
zero (zero alpha). Runtime packs nothing; it loads the two parents through the
bounded decoder (colour as colour, the normal parent as data with
`unit-normal-rgb-v1` validated and binary coverage).

`Hetoimasia.Terrain.Atlas.Manifest` is the checked, bounded manifest
representation (at most 256 KiB, 8 atlases, 256 regions an atlas): it refuses a
wrong schema, a missing, duplicate or unexpected identity, a region in the wrong
parent, a wrong kind or profile, a zero, negative, overflowing or out-of-bounds
rectangle, a terrain region that is not 96 x 64, overlap, an oversized atlas and
a layout identity that is not the digest of the rectangles. A *layout identity*
digests every atlas name and extent and every identity with its rectangle.

`Hetoimasia.Asset.Image.Region` (asset-image) is the neutral primitive: a
`RegionView` is a checked rectangle of **one shared coverage plane per loaded
parent**, never copied per region, quad or cell. The local texel is chosen in the
region's own extent, `i = min (w - 1) (floor (clamp u 0 1 * w + 1/128))` (the owner's
2026-11-09 Q-13 amendments; `Hetoimasia.Terrain.Render2D.TexelRule` in this package's main
library is its one definition, evaluated exactly with the coordinate converted by
`toRational` before the product, and used by the shader's colour and normal samples (the
GLSL literal is made from it), CPU coverage and picking and the material's pure model; the
independent expected model of the evidence restates 1/128 by hand in `Rational` and imports
nothing from it; the neutral region primitive stays unbiased and a terrain consumer passes
its integer index to `regionViewCoverageAt`), and only then is the origin added, so an
interior boundary selects the higher texel, the outer edge the region's last, and a region
never reads a neighbour. `Assets` holds a region
for each colour and map; its identity folds in the parent version, the rectangle,
the layout identity, the parent extent and the normal profile, so a rectangle
change on the same parent invalidates a stale identity. `AtlasAssets` builds the
snapshot from the manifest and the two loaded parents and refuses a parent of the
wrong extent or profile, a texture and coverage of different versions and an
unknown material colour, producing nothing partial.

## The terrain material (TRA-17)

The pure half of the material lives in `terrain-material`.

- **Presentation settings** (`Presentation`): sun azimuth `[0,360)` (225), elevation
  `[-90,90]` (45), ambient `[0,1]` (0.35), sun strength `[0,1]` (1), integral
  depth range `1..250` (250), darkening `[0,1]` (0.15), haze `[0,1]` (0.60) and an
  sRGB haze colour (0.72, 0.85, 0.95). `mkLightSettings` validates the whole value
  and reports every nonfinite or out-of-range setting. Settings are immutable per
  presentation snapshot, not a world clock.
- **Push block**: three `vec4`s, 48 bytes: the view sun (the world direction toward
  the sun turned once by the camera's quarter turns) with ambient; the effective
  sun strength (zero at or below the horizon), darkening, haze and the reciprocal
  range; the haze colour in linear light. A cell's depth word is `cut - z` on wide
  integers bounded to `0..250`.
- **Record**: two full generation-checked handles (colour atlas, normal atlas) and
  thirteen words (each region's origin, extent and parent extent, and the depth).
  `adaptCells` makes the records, shares equal ones (at most 4096), derives the
  push block from the plan's own facing and refuses the whole plan if an asset is
  absent, not a canvas or not the plan's own; a mixed cell's parts are adapted
  together or not at all. `terrainView` refuses an adaptation of another plan.
- **Equations**: `p = clamp (dot n sunView) 0 1`, `B = ambient + (1 - ambient) *
  S * p`, `D = 1 - q * t`, `H = h * t^2`, `rgb = (1 - H) * T.rgb * m * B * D + H *
  F * alpha`, with `t = clamp (d / R) 0 1`, in linear light, `n` decoded from the
  sampled byte as `normalize (c - 128)`, and a transparent map sample contributing
  zero. `terrainModel` is the oracle's model of the same function.

Unshadowed preview lighting only: no cast shadows or occlusion, and no claim of
Synarchy lighting parity (Synarchy's face-weight lighting and its multiplicative
blue depth tint are reference behaviour; see the evidence).

### Evidence

The device proof is the `tra17-terrain` scenario of `vulkan-native-tests` (the
complete Q-13 matrix, run directly) and its bounded required selection
`tra17-terrain-ci`; the retained records, captures and the measured verdict are
under `docs/evidence/terrain/tra17/`. Live view ownership, streaming and final
visual acceptance remain #645 to #648.

## The canonical cutout and normal-map assets (TRA-14)

`terrain-mapgen` bakes, offline and deterministically, the shared catalog of
cutout and unit-normal maps the later amended renderer samples. It consumes the
canonical solids of `hetoimasia-terrain` (`shapeSolid`, `castRay`): there is no
second shape definition. It delivers assets and proof only; the bounded loader
(TRA-15), the cell-quad planner and alpha picker (TRA-16) and the material,
lighting and GPU qualification (TRA-17) are separate slices.

| Component | Source dir | Role |
| --- | --- | --- |
| `terrain-mapbake` (public) | `mapbake/` | Pure: the frontmost-facet evaluation at a canvas position, the 96 x 64 RGBA8 maps, the `unit-normal-rgb-v1` codec and validator (`canvasProblems`), the catalog of 46 maps and the rotated lookup. Reads no file. |
| `terrain-mapgen-core` (public) | `mapgen/` | The pinned inputs (SHA-256 checked), PNG and manifest bytes, writing and read-only checking of the committed catalog, the CPU evidence sheets and the command line as a function (`runCli`). |
| `terrain-mapgen` (executable) | `tool/` | A thin shell over `runCli`. |

```sh
cabal run --project-file cabal.project.cpu exe:terrain-mapgen -- --check              # regenerate in temporary storage, compare, write nothing
cabal run --project-file cabal.project.cpu exe:terrain-mapgen -- --output DIR          # generate the catalog and manifest into DIR
cabal run --project-file cabal.project.cpu exe:terrain-mapgen -- --evidence DIR        # the CPU comparison sheets and index
```

`--sample DIR` names the `samples/ecce-homo` directory and `--catalog DIR` the
committed catalog `--check` compares (defaults: the sample found at or above the
working directory, and `content/textures/facemap` under it), so the command does
not depend on where it is started. `--check` reports every missing, changed and
unexpected file by path, and the first differing manifest line by identity; it
never writes to the committed directory. Exactly one mode is accepted.

**The maps.** Each is a full 96 x 64 RGBA8 PNG, top row first, under
`samples/ecce-homo/content/textures/facemap/` (`manifest.json` describes them):
the 16 ordinary shape maps (`shape_NN_name.png`) and, for each of the 15 nonflat
shapes, a known-solid and a cover part (`mixed_NN_name_known.png`, `_fog.png`).
That is at most 46 authored maps, never one per cell; generic full-cell fog is
identity 0's ordinary map, and every authored identity is kept even where two maps
share bytes (the cover of shapes 6, 7, 14 and 15, which have no visible known
part). The canvas projects a unit-cell point `(x, y, z)` (X east, Y south, Z up)
to `u = 48 + 48 (x - y)`, `v = 16 + 24 (x + y) - 16 z`, the planner's
`isoProject` for a cell at `(48, 16)`; the frontmost surface along `(1, 1, 3)`
(larger multiples are nearer) is baked at each texel centre. Outside the
silhouette alpha is 0 and RGB is written as 0; inside it alpha is 255 and RGB is
the unit outward normal of the facet shown, `round (128 + 127 n)` per component
(flat-up `(128,128,255)`, the W ramp `(38,128,218)` = `(-1,0,1)/sqrt 2`), raw
linear data with no gamma, no premultiplication and no averaging across creases.
Consumers load them as `kind="data"`, `coverage="binary"`,
`normal_encoding="unit-normal-rgb-v1"` (TRA-15). The legacy face-weight masks of
Synarchy are never this encoding: they are retained only under
`samples/ecce-homo/reference/` as reference-only fixtures (a face-weight `(0,255,0)`
is refused as a normal because its R is 0).

**The tie rule.** The solid is closed, so a ray that only touches it is covered. A
point shared by several facets belongs to the first, of those facing the camera
(outward normal with positive dot against `(1, 1, 3)`), in `castRay`'s canonical
order: the top facets in the order of the shape's set bits N, E, S, W, then the
walls North, East, South, West. A ray that touches without entering takes the
first facet containing the contact in the same order. No tolerance is involved.
By construction no baked texel centre lies on any projected facet, ridge, wall or
silhouette edge: every vertex of every solid projects to a whole canvas point and
every projected edge is vertical or has slope 1/2, 1/6 or 5/6 in magnitude through
one, so `(k + 1/2) * slope` never has fractional part 1/2. The rule therefore
decides no baked texel; the suite evaluates it at exact rational boundary points.

**Mixed knowledge.** A cell whose solid is known but whose empty component above it
is not yet discovered is the solid plus opaque cover filling that void to the cell's
top, i.e. the unit cube. The known map holds the texels whose frontmost cube point
lies in the closed solid, the fog map the rest, each with the cube facet's normal
(the cover's own, never the hidden ramp's). They are disjoint and their union is
identity 0's map. Along `(1, 1, 3)` the quantity `z - h(x, y)` grows by
`3 - (h_x + h_y)`, which is 2, 3 or 4 for every catalog facet, so a ray cannot pass
from void into nearer solid inside the cell. Removing the cover selects the ordinary
sloped map; no cap is generated.

**Rotation.** World shape identities never change when the view turns. The view at a
facing selects the catalog entry of the shape turned by South 0, West 3, North 2,
East 1 positive quarter turns (`viewShape`; North to East to South to West;
`(x, y, z) -> (1 - y, x, z)`). `manifest.json` carries the checked lookup of all 16
world identities under all four facings (ordinary, known, cover and full-fog
entries); nothing is baked per camera.

**Inputs and provenance.** `loam.png` and `granite.png` are unchanged; the generic
`blanktexture.png` (the fog cover colour, opaque `(66,63,64)`) is a byte copy of
Synarchy `3777d437ea00e1302bf55162ad5693fee4879187`. The generator verifies each
input's SHA-256 and refuses a missing or altered one. PNG bytes come only from
JuicyPixels over the project's bundled zlib (`cabal.project.common` forces
`zlib +bundled-c-zlib -pkg-config`), so the committed hashes are the same on Linux
and macOS. `samples/ecce-homo/content/textures/provenance.json` records the colour
art, the sixteen reference-only masks with their Synarchy paths, git blobs and
SHA-256 and how Synarchy selects each, and the generated maps.

The colour art's silhouette is a superset of the exact cutout by 96 texels along the
top diamond's two upper edges (art alpha 255 where the centre-sampled cutout is 0);
every map lies inside the art, so the product of colour and map alpha equals the
cutout. Nothing resizes, repaints or thresholds the art.

The CPU suite's TRA-14 group (`Test.TerrainRender2D.MapAssets`) proves all of the
above independently, and this is CPU and generated-image proof only: GPU sampling,
raster-edge agreement, alpha picking, lighting, depth composition and offscreen
readback are TRA-15 through TRA-17, and no performance claim is made.

## The cell-quad planner and visual picker (TRA-16)

The visual path draws **one or two whole-cell quads per potentially visible
cell**, each a full 96 x 64 canvas with UV `[0,1]` through an atlas colour region
and normal region, ordered by an exact integer key and picked from the coverage
they draw. It is the only terrain visual contract: TRA-17 switched every
repository consumer to it and removed the per-face baseline.

The path is pure: no GPU, window, Lua, runtime-terrain, storage or concrete-game
dependency, no I/O, no lease, no thread and no state. It reads one coherent
immutable snapshot and returns values.

### The inputs

| Input | Module | What it is |
| --- | --- | --- |
| Terrain facts | `Facts` | The source, retained removals and availability (unchanged). |
| Knowledge | `Knowledge` | Per cell: `CellUndiscovered`, `CellDiscovered`, `CellSolidKnown` or `CellPending`, as a default, uniform 32-level region summaries and exact column runs (most specific wins), with a caller revision. |
| Assets | `Assets` | The colour artwork and map **coverage planes** (TRA-15 `CoveragePlane`, 96 x 64) of one adopted style, each with its texture and coverage version. |
| Camera, setup, configuration | `Camera`, `Projection`, `Cells` | The existing camera and view setup; a `CellConfig` with the 250-level band, slack, prefetch margin and `CellLimits`. |

`Knowledge` is the narrow contract revised #645 adapts live discovery into. It
lists no cell: a long buried or aerial span is one run. The combination P-14 does
not define, a discovered empty component whose solid boundary is not known, has no
state and is unrepresentable (a discovery publication records the void and its
exposed solid together); a `CellSolidKnown` cell that the terrain holds as air is
refused (`CellInconsistentKnowledge`), never drawn by guess. **Knowledge is not
residency:** `CellPending` (retained knowledge not arrived) and unavailable terrain
are pending, never fog and never air; a confirmed undiscovered cell is fog and its
terrain is **not read** for display.

`mkAssetSnapshot` refuses a plane that is not 96 x 64, a texture version that
differs from its coverage version, a map without the checked
`unit-normal-rgb-v1` profile, a catalog that lacks any of the 46 authored maps and
a duplicate; a plan additionally refuses a material with no colour
(`CellMissingMaterialColour`). Nothing is thresholded, resized or substituted.
`assetIdentity` is the snapshot's version with every texture and coverage version, as
a fixed-size digest taken once when the snapshot is built, so comparing identities
costs the same however many materials exist. A snapshot holds at most
`maxAssetMaterials` (4,096) materials and `maxAssetMaps` (4,096) maps, refused
before anything is walked: it is validated once, at construction, with that stated
bound, and no step of a plan walks it again.
How textures are bound, counted or packed for the device is not decided here:
`cellPlanAssets` names the distinct colour and map assets a plan references, which
is the unit a caller's own account counts.

### What a cell draws

| Supplied knowledge and detail | Representation |
| --- | --- |
| Confirmed undiscovered, whatever its hidden contents | one generic fog quad: blank colour, identity 0's map; no hidden lookup |
| Discovered whole air | no quad |
| Known solid, void discovered or absent (identity 0) | one quad: the view-turned shape's ordinary map, the material colour |
| Known shaped solid, void undiscovered | two quads: fog (the shape's cover map, blank colour) then known (its known map, material colour) |
| Terrain or retained knowledge unavailable | pending: no quad, no fabricated air, no newly forgotten fog |

The map is the catalog's rotated lookup (`lookupFor`): South 0, West 3, North 2,
East 1 positive quarter turns, world identities never change. At cut level `k`
every cell above `k` is omitted and the remaining known shapes keep their forms and
materials: no flat cap is added. Cells deeper than the configured depth (at most
250) below the cut are outside the band; zoom 0.125 to 8, the 25-level automatic
headroom, manual depth and jumps are the camera's and unchanged. The quad of a cell
at view offset `(rx, ry)` and level `z` (reference elevation `ref`) has its canvas
top-left at `(48 (rx - ry) - 48, 24 (rx + ry - 1) - 16 (z - ref) - 16)`, i.e.
`u = 48 + 48 (x - y)`, `v = 16 + 24 (x + y) - 16 z` for a point of the cell. All
differences are exact integers before conversion to a 32-bit transform, across the
legal axes and negative chunk seams.

### Order and the 24-bit keys

Cells are ordered far to near by the exact key `(viewX + viewY, z, viewX, viewY)` of
the rotated view frame, then fog before known material within a cell. Two distinct
cells on one view ray occur with nondecreasing X, Y and Z toward the camera, so
`X + Y` orders them and `Z` orders cells that agree in X and Y. The admitted quads
are ranked by that total order into `[0, 2^24)`, larger nearer, so ranks are
distinct, never wrap or reuse a key and do not depend on enumeration. No floating
key exists anywhere. This is a mathematical argument plus CPU proof against an
independent ray oracle, **not** a claim about a device: the backend's rank
translation and raster ties are TRA-17's Q-13 gate.

### Hidden cells

A quad is omitted only with a coverage proof: its east, south and upper neighbours
are each drawn with coverage **proved**, from the adopted planes themselves, to be
the whole hexagon (fog, or a full block whose colour and map both cover it). An
unavailable neighbour is neither air nor a proof, a mixed neighbour is not a proof
and a colour with a hole proves nothing. The supplied full-block map is itself
checked from the planes: it must cover itself translated to the three cells that
can hide one (east, south, above) and contain every catalog map, otherwise no asset
is a covering proof and nothing is omitted as hidden. The proof is made in the
canvas, so it also needs the covering cells to be *drawn* exactly one canvas step
from the hidden one: every quad's rectangle is rounded through 32-bit floats on its
own, so at a fractional zoom or pan neighbouring rectangles can miss an exact
translation by a unit in the last place and a pixel centre can then fall on the wrong
side of a shared edge. The planner therefore checks the rectangles as drawn, on
demand: once per column that has something hidden for x, and per hidden level for y
(the view's transform has no rotation, so the axes are independent), and a cell is
omitted only where both hold; elsewhere it is drawn. The y verdicts are cached
(`clProofs` entries at most, 4,096 by default, zero keeps none), so `startCells` does
no per-view work and the retained scratch is bounded whatever the viewport or margin;
the cache changes the work, never the plan.

**The work meter.** Everything a step examines of the caller's inputs is charged to
one meter, and a step never charges more than `clStepWork` (8,388,608 by default;
at least `columnWorkBound`, 8,192, the most one column can charge, so every step
progresses). The loop checks before beginning a column that its worst case still
fits, so a step cannot overshoot. The charges: one for each candidate column; for
each of the column's three state reads (knowledge runs, readiness intervals and
terrain steps, each of which covers at least one level) the window's levels plus one;
one per hidden level examined for omission plus three per drawn-rectangle verdict
computed; and one per admitted cell or pending span plus two asset lookups per quad.
`cellStatStepWork` reports the last step, `cellStatWork` all of them and
`cellStatDemandWork` the prefetch demand (the ring keys examined and one window read
per chunk listed, at most `clDemandChunks`). Nothing the planner or the picker reads
of the caller's inputs is read outside the meter; the plan's own quads and pending
spans are its output, bounded by `clInstances` and `clPending`, not input. Runs, not levels, are walked,
so cost follows run boundaries and exposed cells, not depth, and a column's
knowledge runs and a chunk's readiness intervals (`Facts.pieces`, shared with the
baseline planner and the camera, which return exactly what they did) are searched by
interval, so a window never visits intervals outside it. Terrain reads go through
`columnRuns` under the explicit `ccQueryLimits` of the terrain query API, whose own
cost is that package's contract and is not changed here.

### Bounded, resumable preparation

`startCells` reads nothing. `stepCells` examines at most `clStepCandidates`
candidate columns and admits at most `clStepLevels` levels (a level is one drawn
cell, with all its parts, or one pending span), **nearest row first**; both step
bounds must be at least one (a zero bound is a refused configuration). The level
bound may fall inside a column: the column then stays at the cursor with its
admitted units counted and the next step resumes it, so one step never admits
more than its bound however tall the column. `cellPlanOf` returns the plan reached
so far, publishable at any point. `planCells` runs to settled or to a bound. A
cell is admitted whole or not at all, so a mixed cell's fog and known parts are
never split. Plan-wide bounds (`clColumns`, `clLevels`, `clInstances` at most 2^24,
`clPending`) **halt** with the remainder explicitly unresolved (`Halted`), the
halting column included from its first unadmitted unit; nothing is truncated and
called complete. The unprocessed candidate columns are `cellPlanUnresolved`; a valid
camera larger than one plan's capacity is therefore never an invalid camera. With
sufficient capacity and unchanged inputs repeated steps reach `Settled` with the
plan one unbounded pass gives. A continuation, or a plan, made under a different
camera, knowledge revision, asset version, target or configuration is refused
(`CellStaleContinuation`): obsolete work never becomes current.

| Default | Value | Default | Value |
| --- | ---: | --- | ---: |
| `clStepCandidates` | 4,096 | `clInstances` | 1,048,576 (at most 16,777,216) |
| `clStepLevels` | 65,536 | `clPending` | 65,536 |
| `clStepWork` | 8,388,608 | | |
| `clColumns` | 1,048,576 | demand chunks / intervals / regions per chunk | 1,024 / 8,192 / 16 |
| `clLevels` | 16,777,216 | band, slack, prefetch margin | 250, 2, 1 |
| `clProofs` | 4,096 | | |

These are engineering defaults, not measured capacity.

### Demand

The candidate envelope is every column and level whose **full canvas** can touch
the padded viewport, so a lower or distant background outside any camera radius is
requested (`candidates` of the baseline already used the same bound). `cdVisible`
names, in 16 x 16 chunks and 32-level regions, the pending spans of the processed
part; `cdPrefetch` is the existing horizontal chunk margin, empty until the visible
work is settled and bounded by what the visible demand left of each limit, so
prefetch never takes capacity visible work needs. `cdTruncated` says a demand bound
cut a listing short. Admission, queueing and priority belong to the runtime.

### Picking

`pickCells plan (CellPickQuery identity point)` maps the logical point through the
plan's mapping to a framebuffer position and tests that **physical pixel's
centre**, from the nearest quad to the farthest. A quad **contains** the centre
under the left-and-top half-open rule (left and top edges inside, right and bottom
outside); the two triangles' shared diagonal is inside the rectangle, so a centre on
it is covered, and a centre on an outer edge shared by two quads belongs to exactly
one. The texel is `min (n - 1) (floor (u * n + 1/128))` with `u` the exact rational
position across the drawn rectangle (an interior boundary selects the higher index, as
does a position within 1/128 texel below it). The quad
covers the centre when the texel is covered in **both** its colour plane and its
map plane (colour alpha times map alpha at 0.5 for binary alpha); lighting, haze and
darkening play no part; nothing is sampled outside the rectangle because UVs clamp.

* The first covered quad decides. A known part is `CellPickHit` with its exact
  `TileCoord`, part and plan identity. **Fog is `CellPickNoHit`, the same answer as
  a miss:** it ends the search and leaks no hidden coordinate, material, shape,
  selection or edit authority (a fog quad itself holds none).
* Pending information that could lie ahead (a pending span whose footprint contains
  the centre with a nearer possible key, or an unprocessed candidate column in a row
  no farther) makes the answer `CellPickLoading` with no candidate. With no covering
  quad, any such information is loading. Information proved **behind** the covering
  quad does not change a hit.
* A stale identity is `CellPickStale`; a non-finite point `CellPickInvalidPoint`;
  outside the intersection of the viewport and the framebuffer, or in a zero
  extent, no hit: the renderer clamps drawing to the attachment, so a viewport that
  reaches past it shows nothing there, and the pixel is refused before coverage or
  pending information is resolved. The result issues no Lua token and
  edits nothing; the logical point and ray queries of `hetoimasia-terrain` remain
  the separate terrain-truth API, and fog or cutouts never replace occupancy or
  discover anything.

### Identity and state

`CellIdentity` is built only by the planner and compares exactly the arena
incarnation, content revision, residency generation, knowledge revision, camera
revision, anchor, fraction, reference, zoom, facing, cut, target mapping and
metrics, every asset and coverage version and the configuration. A plan, identity,
quad, preparation, knowledge value and asset snapshot cannot be built or edited by
constructor or record update from a client (checked by external clients).

| State | Owner | Writers | Readers | Lifetime |
| --- | --- | --- | --- | --- |
| Facts, knowledge, asset snapshot | the caller | the caller | the planner and picker (reads only) | the caller's |
| A `CellPrep` or `CellPlan` | the caller | nobody (each step returns a new value) | the caller, `pickCells` | the value's |

No thread, process, lease, cache, global or I/O.

### What remains

The device's raster edges, depth keys, region sampling, lighting and depth effects
were qualified by TRA-17 (`docs/evidence/terrain/tra17/`); the retained resources
and their interests under a live view, live discovery, adoption and the Lua pick
result are #645 and #646; a counterexample found there is a Q-13 stop, not
a reason to change an order, threshold or rule here. The reproducible CPU evidence
is under `docs/evidence/terrain/tra16/`.

## Tests

`hetoimasia-terrain-render-2d:terrain-render-2d-tests` is the non-optional CPU
group `test.terrain-render-2d`:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct
```

Its TRA-16 groups (`Test.TerrainRender2D.Cells`, `CellsCoverage`, `CellsProgress`,
`CellsWork`, `CellsClient`, `CellsEvidence`) check the cell-quad path against an independent
exact view-ray oracle (`CellFixtures`) that shares no code with the planner or the
picker, over the committed catalog for all 16 identities at all four facings in
ordinary, fogged and mixed states, with synthetic technical-fixture planes for the
texel and edge conventions. Their negative controls were broken once locally and
caught; none is committed.

Its TRA-17 groups are `Test.TerrainRender2D.Atlas` (deterministic generation and
exact per-region recovery of the three colour sources and all 46 maps against their
independently decoded sources, the manifest's refusals, the generator's atlas
modes), `AtlasAssets` (shared region views, packed and single-image assets planning
and picking alike, adaptation refusals), `Material` (the settings' ranges, the push
block, the model's region sampling, lighting and depth numbers worked out by hand,
the adaptation) and `Expectation` (the independent hand model of the quad contract,
which reads the decoded source images and shares no code with the planner, the
picker, the atlas adaptation or the material, agreeing with the picker over the
16-shape by 4-facing matrix, mixed and fog cells, roofs, spans, ramps and cutaways).

It is deterministic, starts no thread and sleeps nowhere; its generator groups read the committed assets from the repository and write only to temporary directories. Projection, camera and
planning expectations are hand-stated from the equations above and small explicit
terrain. Negative controls were broken once locally and caught (a region origin
ignored, the sun not turned for a facing, the haze not blended, and the cell-quad
path's earlier controls); none is committed. `Test.Support.ExternalClient`
compiles a client outside the package: one must link and run, and every attempt to
name a private constructor, rewrite a camera with record syntax or import a private
module must be refused for the specific diagnostic.
