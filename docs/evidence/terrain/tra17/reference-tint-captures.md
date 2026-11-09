# TRA-17: lossless captures of the depth treatment against the reference's multiplicative blue tint

**Labelled reference comparison, not parity.** The scene is `depth-stack-FaceSouth` at zoom 0.25 (nine loam and
granite cells of shape 5 at levels 0 to 8, the cut at level 8, so the front cell of a pixel has depth `8 - z`
below the cut), a 64 x 64 target, rendered twice from the independent hand model
(`Hetoimasia.Terrain.Render2D.Evidence`) over the independently decoded atlas art:

- `reference-tint-terrain.png`: the terrain material's treatment, default light, depth range 8 (the nine levels span it: darkening 0.15,
  haze 0.60, haze colour sRGB (0.72, 0.85, 0.95)), by the specified equations in linear light.
- `reference-tint-reference.png`: the same lit colour with the depth effects off, multiplied per channel on the
  display bytes by the reference's tint for the cell's depth (`fadeT = depth / 8`, `brightness = 1 - 0.15 fadeT`,
  `hazeT = 0.6 fadeT^2`, `tint_c = brightness (1 - hazeT) + haze_c hazeT`, Synarchy `3777d437`
  `src/World/Render/TileQuads.hs` lines 66 to 87).
- `reference-tint-sheet.png`: the two side by side at 4x, terrain on the left, reference on the right.

Sources: colour atlas `terrain-atlas/colour.png` SHA-256 `96c53814636e77b5cc822b5ebe93acd945640c7502c0d2d02b4eb112601bc29f`, normal atlas `terrain-atlas/normal.png`
SHA-256 `d6efb6d43cfccc03bf2ed2de5831234fc41ad7605e1ae4f75b70a40d90404fc2`, layout identity `263cb64032502aa0`. Both renderings are deterministic (no seed) and
lossless PNGs. The numeric white-texel table is in `reference-tint-comparison.md`.

Covered pixels: 1093; of them at depth 0 (the cut) the two agree on 157 of 157, and below the cut they differ on 936 of 936.

| level | depth | pixels | terrain (R, G, B) at the first | reference (R, G, B) at the first |
| ---: | ---: | ---: | --- | --- |
| 0 | 8 | 117 | 146, 173, 193 | 12, 12, 7 |
| 1 | 7 | 117 | 160, 178, 194 | 115, 122, 130 |
| 2 | 6 | 117 | 113, 133, 149 | 13, 12, 7 |
| 3 | 5 | 117 | 150, 160, 170 | 124, 127, 132 |
| 4 | 4 | 117 | 78, 92, 103 | 14, 13, 7 |
| 5 | 3 | 117 | 145, 147, 153 | 133, 133, 136 |
| 6 | 2 | 117 | 42, 48, 53 | 15, 13, 8 |
| 7 | 1 | 117 | 144, 142, 145 | 141, 139, 141 |
| 8 | 0 | 157 | 16, 14, 8 | 16, 14, 8 |
