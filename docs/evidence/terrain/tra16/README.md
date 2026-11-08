# TRA-16 CPU evidence: cell-quad planning and coverage picking

**This is CPU evidence only.** It shows that the pure planner and picker agree with independent
references on fixed scenes. It does not show that a device rasterizer, depth test or sampler agrees;
TRA-17 owns that proof (Q-13), and a disagreement found there is a counterexample, not a reason to
change an order, threshold or rule here.

- Pinned to commit: `e581d3674046666a290da5a54fce8e939c7dd2e5`
- Reproduce: `HETOIMASIA_TRA16_EVIDENCE_DIR=<dir> HETOIMASIA_TRA16_COMMIT=<commit> cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct --test-options='--match "TRA-16 evidence record"'`
- Seeds: none. Every scene, facing and sample pixel is enumerated in `packages/terrain-render-2d/test/Test/TerrainRender2D/Cells.hs`;
  the run is deterministic (Hspec's seed affects only example order).
- View: a 320 x 240 target at zoom 1, camera at the anchor column, manual cut as listed; the oracle
  samples the centre of every sixth pixel from offset (5, 3), keeping a pixel only where its answer is
  stable under a 1/32 render-pixel jitter (a pixel on a facet or mask edge is skipped, not guessed).

## Source and asset identities

| Input | SHA-256 |
| --- | --- |
| `samples/ecce-homo/content/textures/blanktexture.png` | c747223e0f788c942d1e8699735ac4a26a011599b6442c707b91c29f42f2f90e (470 bytes) |
| `samples/ecce-homo/content/textures/loam.png` | f449a06bc3aa76fdf56607c4e4d23ac1cc8c1a67245b8ae5b295dbff621105e1 (2384 bytes) |
| `samples/ecce-homo/content/textures/granite.png` | 776a28d3ee45f656ee8f024444c0f2529b4d176da455902e4ac9bfb329d79d1c (1268 bytes) |
| `samples/ecce-homo/content/textures/facemap/manifest.json` | 59ff744971a1f14fde6c7c689a14c822539ad9321b89f3840e629dbefc61328c (23192 bytes) |

The asset snapshot used is version 5, built from the committed catalog (46 maps), the blank colour and
the loam (`stone`) and granite (`soil`) artwork above, each with texture version 5 and coverage version 5.
Its identity is the sorted list of those versions: `AssetIdentity 5 [(AssetColour ColourBlank,5,5),(AssetColour (ColourMaterial (MaterialId "soil")),5,5),(AssetColour (ColourMaterial (MaterialId "stone")),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 0}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 1}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 2}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 3}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 4}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 5}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 6}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 7}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 8}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 9}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 10}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 11}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 12}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 13}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 14}),5,5),(AssetMap (MapKey {mapRole = Ordinary, mapShape = ShapeId 15}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 1}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 2}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 3}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 4}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 5}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 6}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 7}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 8}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 9}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 10}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 11}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 12}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 13}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 14}),5,5),(AssetMap (MapKey {mapRole = KnownPart, mapShape = ShapeId 15}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 1}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 2}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 3}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 4}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 5}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 6}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 7}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 8}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 9}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 10}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 11}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 12}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 13}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 14}),5,5),(AssetMap (MapKey {mapRole = FogPart, mapShape = ShapeId 15}),5,5)]`.

## Expected against actual classifications

Per scene and facing: decidable sample pixels, then the oracle's answer against the reference traversal
(which sees fog) and the production pick (which does not distinguish fog from a miss). `none`, `fog`,
`known` count the oracle's frontmost classification. `reference mismatches` and `pick mismatches` are the
pixels where the traversal or the pick differs from it; the acceptance is that both are 0.

| Scene | Facing | Decidable | none | fog | known | reference mismatches | pick mismatches | Quads | Depth keys (min..max) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| a 4 x 4 grid of every identity, knowledge cycling | FaceSouth | 2120 | 1227 | 674 | 219 | 0 | 0 | 21 | 0..20 |
| a 4 x 4 grid of every identity, knowledge cycling | FaceWest | 2120 | 1454 | 415 | 251 | 0 | 0 | 18 | 0..17 |
| a 4 x 4 grid of every identity, knowledge cycling | FaceNorth | 2120 | 1135 | 709 | 276 | 0 | 0 | 21 | 0..20 |
| a 4 x 4 grid of every identity, knowledge cycling | FaceEast | 2120 | 1483 | 412 | 225 | 0 | 0 | 18 | 0..17 |
| a roof over a cavity with ramps at the rim | FaceSouth | 2120 | 1405 | 15 | 700 | 0 | 0 | 19 | 0..18 |
| a roof over a cavity with ramps at the rim | FaceWest | 2120 | 1432 | 12 | 676 | 0 | 0 | 19 | 0..18 |
| a roof over a cavity with ramps at the rim | FaceNorth | 2120 | 1141 | 116 | 863 | 0 | 0 | 20 | 0..19 |
| a roof over a cavity with ramps at the rim | FaceEast | 2120 | 1453 | 0 | 667 | 0 | 0 | 19 | 0..18 |
| stacked disconnected spans and a steep depth separation | FaceSouth | 2120 | 1841 | 85 | 194 | 0 | 0 | 8 | 0..7 |
| stacked disconnected spans and a steep depth separation | FaceWest | 2120 | 1734 | 203 | 183 | 0 | 0 | 6 | 0..5 |
| stacked disconnected spans and a steep depth separation | FaceNorth | 2120 | 1755 | 200 | 165 | 0 | 0 | 6 | 0..5 |
| stacked disconnected spans and a steep depth separation | FaceEast | 2120 | 1734 | 198 | 188 | 0 | 0 | 6 | 0..5 |
| cutaway through undiscovered air, cut above | FaceSouth | 2120 | 1871 | 188 | 61 | 0 | 0 | 4 | 0..3 |
| cutaway through undiscovered air, cut above | FaceWest | 2120 | 1867 | 188 | 65 | 0 | 0 | 4 | 0..3 |
| cutaway through undiscovered air, cut above | FaceNorth | 2120 | 1871 | 188 | 61 | 0 | 0 | 4 | 0..3 |
| cutaway through undiscovered air, cut above | FaceEast | 2120 | 1868 | 188 | 64 | 0 | 0 | 4 | 0..3 |
| cutaway through undiscovered air, cut at the known cells | FaceSouth | 2120 | 1952 | 0 | 168 | 0 | 0 | 2 | 0..1 |
| cutaway through undiscovered air, cut at the known cells | FaceWest | 2120 | 1963 | 0 | 157 | 0 | 0 | 2 | 0..1 |
| cutaway through undiscovered air, cut at the known cells | FaceNorth | 2120 | 1966 | 0 | 154 | 0 | 0 | 2 | 0..1 |
| cutaway through undiscovered air, cut at the known cells | FaceEast | 2120 | 1952 | 0 | 168 | 0 | 0 | 2 | 0..1 |
| a known ramp side beside an unrevealed void and fog behind it | FaceSouth | 2120 | 1833 | 138 | 149 | 0 | 0 | 6 | 0..5 |
| a known ramp side beside an unrevealed void and fog behind it | FaceWest | 2120 | 1807 | 188 | 125 | 0 | 0 | 6 | 0..5 |
| a known ramp side beside an unrevealed void and fog behind it | FaceNorth | 2120 | 1770 | 190 | 160 | 0 | 0 | 6 | 0..5 |
| a known ramp side beside an unrevealed void and fog behind it | FaceEast | 2120 | 1785 | 145 | 190 | 0 | 0 | 6 | 0..5 |
| a chunk seam in X and Y | FaceSouth | 2120 | 1143 | 97 | 880 | 0 | 0 | 19 | 0..18 |
| a chunk seam in X and Y | FaceWest | 2120 | 1188 | 108 | 824 | 0 | 0 | 19 | 0..18 |
| a chunk seam in X and Y | FaceNorth | 2120 | 1215 | 56 | 849 | 0 | 0 | 19 | 0..18 |
| a chunk seam in X and Y | FaceEast | 2120 | 1165 | 53 | 902 | 0 | 0 | 19 | 0..18 |
| a vertical region seam | FaceSouth | 2120 | 1571 | 409 | 140 | 0 | 0 | 20 | 0..19 |
| a vertical region seam | FaceWest | 2120 | 1551 | 387 | 182 | 0 | 0 | 22 | 0..21 |
| a vertical region seam | FaceNorth | 2120 | 1531 | 380 | 209 | 0 | 0 | 22 | 0..21 |
| a vertical region seam | FaceEast | 2120 | 1539 | 415 | 166 | 0 | 0 | 22 | 0..21 |
| the greatest legal coordinates | FaceSouth | 2120 | 1415 | 0 | 705 | 0 | 0 | 9 | 0..8 |
| the greatest legal coordinates | FaceWest | 2120 | 1539 | 0 | 581 | 0 | 0 | 9 | 0..8 |
| the greatest legal coordinates | FaceNorth | 2120 | 1425 | 0 | 695 | 0 | 0 | 9 | 0..8 |
| the greatest legal coordinates | FaceEast | 2120 | 1541 | 0 | 579 | 0 | 0 | 9 | 0..8 |
| the least legal coordinates | FaceSouth | 2120 | 1356 | 150 | 614 | 0 | 0 | 11 | 0..10 |
| the least legal coordinates | FaceWest | 2120 | 1459 | 135 | 526 | 0 | 0 | 11 | 0..10 |
| the least legal coordinates | FaceNorth | 2120 | 1344 | 109 | 667 | 0 | 0 | 11 | 0..10 |
| the least legal coordinates | FaceEast | 2120 | 1491 | 106 | 523 | 0 | 0 | 11 | 0..10 |

## Work and count readings

Limits are the defaults of `defaultCellLimits` unless stated (engineering defaults, not measured capacity).

| Scene (South) | Columns | Levels evaluated | Instances | Pending spans | Distinct assets | Progress |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| a 4 x 4 grid of every identity, knowledge cycling | 810 | 16 | 21 | 0 | 18 | Settled |
| a roof over a cavity with ramps at the rim | 810 | 18 | 19 | 0 | 6 | Settled |
| stacked disconnected spans and a steep depth separation | 810 | 7 | 8 | 0 | 6 | Settled |
| cutaway through undiscovered air, cut above | 810 | 4 | 4 | 0 | 4 | Settled |
| cutaway through undiscovered air, cut at the known cells | 810 | 2 | 2 | 0 | 3 | Settled |
| a known ramp side beside an unrevealed void and fog behind it | 810 | 4 | 6 | 0 | 8 | Settled |
| a chunk seam in X and Y | 810 | 18 | 19 | 0 | 6 | Settled |
| a vertical region seam | 810 | 15 | 20 | 0 | 9 | Settled |
| the greatest legal coordinates | 810 | 9 | 9 | 0 | 3 | Settled |
| the least legal coordinates | 810 | 10 | 11 | 0 | 5 | Settled |

## Capacity pressure

Scene: a mixed ramp, a full block, a mixed ramp (identity 12) and an undiscovered block (six quads).
`clInstances` is the instance limit. A column is admitted whole or left unresolved, so a mixed cell's fog and
known parts are never split; ranks are distinct and below the limit.

| clInstances | Quads | Progress | Known parts without their fog |
| ---: | ---: | --- | ---: |
| 0 | 0 | Halted HaltInstances | 0 |
| 1 | 1 | Halted HaltInstances | 0 |
| 2 | 1 | Halted HaltInstances | 0 |
| 3 | 3 | Halted HaltInstances | 0 |
| 4 | 4 | Halted HaltInstances | 0 |
| 5 | 4 | Halted HaltInstances | 0 |
| 6 | 6 | Settled | 0 |

