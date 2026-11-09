# TRA-17: the terrain depth treatment against the reference's multiplicative blue tint

**Labelled reference comparison, not parity.** The reference is Synarchy at `3777d437`,
`src/World/Render/TileQuads.hs` lines 66 to 87 (dry-tile branch), whose vertex tint is multiplied
into the sampled texel: `fadeT = clamp01 (depth / max 1 range)`, `brightness = clamp01 (1 - 0.15 fadeT)`,
`hazeT = 0.6 fadeT^2`, `tint_c = brightness (1 - hazeT) + haze_c hazeT`, haze `(0.72, 0.85, 0.95)`.
The terrain material's treatment is the specified one: depth below the cut `t`, `D = 1 - 0.15 t`,
`H = 0.6 t^2`, output `(1 - H) T B D + H F` in premultiplied linear light with the haze colour converted once.
The values below are the display bytes each leaves a WHITE texel under full light (the terrain's lighting
term is one: ambient 1, flat top), the terrain's from the independent hand model (`handShade`), the
reference's as `round (255 tint_c)`. The reference multiplies in the space its pipeline holds, which this
comparison does not claim to reproduce for coloured texels. Reproduce:
`HETOIMASIA_TRA17_REFERENCE_DIR=<dir> cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-options='--match "reference depth-tint"'`

| range | depth | terrain (R, G, B) | reference (R, G, B) | terrain minus reference |
| ---: | ---: | --- | --- | --- |
| 4.0 | 0 | 255, 255, 255 | 255, 255, 255 | 0, 0, 0 |
| 4.0 | 1 | 249, 250, 250 | 243, 244, 245 | 6, 6, 5 |
| 4.0 | 2 | 238, 242, 246 | 228, 233, 237 | 10, 9, 9 |
| 4.0 | 3 | 224, 234, 242 | 212, 223, 232 | 12, 11, 10 |
| 4.0 | 4 | 207, 225, 240 | 197, 217, 232 | 10, 8, 8 |
| 250.0 | 0 | 255, 255, 255 | 255, 255, 255 | 0, 0, 0 |
| 250.0 | 62 | 249, 250, 250 | 243, 244, 245 | 6, 6, 5 |
| 250.0 | 125 | 238, 242, 246 | 228, 233, 237 | 10, 9, 9 |
| 250.0 | 187 | 225, 234, 242 | 212, 223, 232 | 13, 11, 10 |
| 250.0 | 250 | 207, 225, 240 | 197, 217, 232 | 10, 8, 8 |

Both treatments leave a texel unchanged at the cut and both pull it toward the pale blue as depth grows.
They differ where the specification differs from the reference: haze is converted to linear light and
composed after darkening (`(1 - H) D + H F`), not folded into one per-channel sRGB tint. At full depth
the terrain material gives (207, 225, 240) and the reference (197, 217, 232) for the same white texel.
