# Corner-defined terrain solids

An author chooses which corners of a cell reach the next level. A consumer can identify the stored shape, clip against its solid and discover ground exposed beneath it using the same exact geometry.

Design state: `ready for issue processing`

## Processing status

- [x] EPIC. Support corner-defined terrain solids — [#752]
- [ ] COR-1. Resolve corner masks to exact solid pieces and boundary facets
- [ ] COR-2. Derive portals from the union of solid pieces
- [ ] COR-3. Carry the shape family through packed terrain segments
- [ ] COR-4. Admit corner cells through source, discovery and snapshot reads
- [ ] COR-5. Author corner masks through Lua terrain definitions

An unchecked entry awaits processing. A checked entry links its tracker issue.

## Epic contract

Done when all 16 corner inputs agree with the approved height and rotation oracle, stored cells select the correct geometry, discovery reaches exposed ground, and historic side inputs replay with their original results. The engine supplies immutable geometry, authoring and terrain queries. Applications own rendering, shading, ray-hit selection, movement costs, pathfinding and playtest fixtures. Use the existing epic label.

## Current state

At `beb215df`, `Terrain.Shape` assigns the four bits to **sides**. `Geometry.shapeSolid` intersects ramp half-spaces. Side 0 is a full block and side 15 is a four-sided apex at height ½. Correct the flat-top claim in the public Shape Haddock (GUIDE-2). `Opening` takes one convex hull per face and connectivity indexes 17 kinds including air. The render-2d mapgen/mapbake catalog enumerates side IDs. Its assets and lookups are keyed to those IDs.

## Decisions

**D-1. Fold the authored heights.** X increases east, Y south, Z up. On the unit square, assign NW=1, NE=2, SE=4, SW=8. Interpolate the binary heights on each of two triangles. For a lone high or low corner join its two neighbors. For opposite highs join the two lows. Either diagonal gives the same surface on coplanar tiles. One clockwise turn maps NW to NE and `(x,y)` to `(1−y,x)`.

**D-2. Identify a shape by family and value.** Preserve side-only `ShapeId` and its checked numeric constructor. Use a checked `CornerMask` (0…15) for authoring. Corner 0 resolves to air. Each nonzero corner mask has its own occupied key. Side 0 and corner 15 are distinct full-block keys. Side 15 retains its apex. Proposed public names and lookup path:

```haskell
mkCornerMask  ∷ Int → Either ShapeError CornerMask
resolveCorner ∷ CornerMask → Maybe ShapeKey
allShapeKeys  ∷ [ShapeKey]
cellShapeKey  ∷ Cell → Maybe ShapeKey
rotateKey     ∷ Turns → ShapeKey → ShapeKey
convexPieces  ∷ ShapeKey → [ConvexPiece]
piecePlanes   ∷ ConvexPiece → [Plane]
boundaryFaces ∷ ShapeKey → [Face]
surfaceHeight ∷ Maybe ShapeKey → Rational → Rational → Either GeometryError (Maybe Rational)
```

Build a renderer table by associating each of the 31 occupied keys in `allShapeKeys` with its pieces and faces. Look up the key returned by `cellShapeKey`. Air has no entry. A renderer may assign dense indices locally. Enumeration order carries no identity. Keep the existing side-only convex API available to its clients.

**D-3. Clip each convex piece, then take the union.** A triangle spans from the base to its interpolated height. Keep the closed pieces with positive volume. Each supplies rational planes with outward normal **n**, inside **n·p ≤ d**, and each external facet supplies its plane and vertices counterclockwise from outside. A side solid contributes its existing convex piece. The external boundary excludes internal partitions. For a ray, union the per-piece parameter intervals before identifying entry or exit. The game owns its hit policy. Height still reports 0 on a nonempty mask's flat half or crease. Discarding a zero-volume piece removes its coincident top and base faces, so clipping cannot hit a phantom floor.

**D-4. Derive exposure from that same union.** Subtract the union of the closed piece sections from each cell face. Count a connection or exposed solid surface only on positive shared area. A single NW-high bank above a full lower block has height `max(0,1−x−y)`. Its known upper void reaches the base over `x+y>1`, area ½. At (¾,¾) the lower block's top is exposed and discovery marks its solid known. The full block has no void to connect to. Replace it with air and the shared triangle connects the two voids. In valleys 5 and 10 the height reaches zero along a line, so neither exposes positive area below. The sloping facets meet at that line.

**D-5. Tag resident cells and preserve replay inputs.** The low 16 bits retain the existing twelve-bit palette index and four-bit value. Place the corner-family flag at bit 16 of the extended packed cell. A legacy word zero-extends exactly. Zero is canonical air. All 4,095 material slots remain available. The tag travels through segment construction, edits and residency. Account for actual encoded payload and worst-case staging at admission. Raw legacy-word access must never narrow a corner cell silently.

Historic source/replay numeric `shape` fields select sides. Add explicit corner authoring for Haskell layers and patches and Lua `corner_mask`; return the corresponding discriminator on cell, column, surface and region reads. A zero corner resolves to ordinary air. The v1 runtime page store holds removal/discovery records against a supplied source. Regional terrain copies hold removed intervals. Neither serializes packed shape words, so this extension needs no page-version, checksum-algorithm or historic replay-digest change. Test digests distinguish new corner values. Cross-run save formats belong to applications. The side-only map catalog keeps its existing entries. Its consumer reports an unsupported corner key if asked for a map.

| Input or condition | Observable result |
| --- | --- |
| Invalid mask, unknown family, malformed packed word or Lua definition selecting both families | Checked refusal before publishing a cell or definition |
| Air index with any other bits, or packed corner zero | Refuse noncanonical encoding |
| Height query outside the unit square | Coordinate error. Inside the square air yields no height |
| Side/corner partial contact, including a line or point | A portal connects only if the open overlap has positive area |
| Missing resident data or exhausted budget | Existing unavailable or bounded refusal result |

## Verification

Use a self-contained Hspec translation of the approved `surface_height` oracle in Widdershins’ `tracker/032-corner-defined-terrain.md`. For each mask and every `(i/16,j/16)`, i,j=0…16, compare exact engine height and its clockwise rotation with the reference, including empty. These 4,624 cases include the two valley creases, both interiors and shared edges. Compare facet coverage, membership and lookup by key. Compare discovery and replay by observed knowledge and cells. Piece order, portal enumeration and elapsed time carry no acceptance condition. Use focused headless suites once per candidate.

## Delivery plan

### COR-1. Resolve corner masks to exact solid pieces and boundary facets

Can land first. Deliver D-1–D-3, the side-15 Haddock correction and the 4,624-case oracle. Test plane signs, external facets, empty, and a ray crossing an internal partition. The cell accessor lands with COR-4.

### COR-2. Derive portals from the union of solid pieces

Depends on COR-1. Deliver D-4 for pure openings and inter-cell matching, including mixed families, the half-area bottom opening, both valleys and a three-high plateau. Check membership and area under rotation.

### COR-3. Carry the shape family through packed terrain segments

Depends on COR-1. Independent of COR-2. Deliver D-5's tagged packing, segment round-trips and runtime byte charges. Check old words, side/corner 15, edits, the maximum palette index and refusal without partial state. Keep ordinary sources usable while implementing storage support.

### COR-4. Admit corner cells through source, discovery and snapshot reads

Depends on COR-2 and COR-3. Connect Haskell layers/patches, cell keys and highest-occupied queries to connectivity, discovery and runtime snapshots. Adapt exhaustive readers including Lua replies and the side-only map boundary as part of admitting the new cells. Verify the worked lower-block case, sealed valley, mixed-source remove/replay and historic side-only reads under their supported limits.

### COR-5. Author corner masks through Lua terrain definitions

Depends on COR-4. Deliver the explicit input form in D-5 through the public facade and service. Check layer and patch validation, air normalization, matching tagged reads and reply-size admission. No further design questions are open.
