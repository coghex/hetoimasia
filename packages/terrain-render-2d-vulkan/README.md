# hetoimasia-terrain-render-2d-vulkan

The terrain arena's application material for the 2D renderer's Vulkan recorder
(epic #636, TRA-17). It is the Vulkan-dependent half of the terrain view: the pure
half, [`hetoimasia-terrain-render-2d`](../terrain-render-2d/README.md), plans the
whole-cell quads and owns the presentation settings, the record layout, the
packing and the model of the material.

It is listed only in `cabal.project.vulkan`, with the pure terrain packages it
needs, so `cabal.project` and `cabal.project.cpu` neither resolve the Vulkan
binding nor link a loader. `tools/vulkan/run.sh` builds and tests it; its
shader splice needs the shader toolchain fingerprint that command generates.

| Module | Purpose |
| --- | --- |
| `Hetoimasia.Terrain.Render2D.Vulkan.Material` | `terrainMaterial`, and `terrainMaterialEquivalent`, a second material of identical behaviour with its own SPIR-V |

`Hetoimasia.Terrain.Render2D.Vulkan.Source` is private: the GLSL, in a module of
its own because a Template Haskell splice may use only what another module defines.

## The material

Declared through the renderer's checked `defineMaterial` (R2D-11):

- **Record:** two full generation-checked handles (the colour atlas, which is also
  the instance's primary texture, and the normal atlas) and 13 words, the layout of
  `Hetoimasia.Terrain.Render2D.Material` (`recordLayout`): each region's origin
  and extent and its parent atlas's extent, and the cell's depth below the cut.
  The record is 17 words, 68 bytes.
- **Push block:** three `vec4`s, 48 bytes, the whole of what the engine leaves:
  `lightSun` (the view sun direction and ambient), `lightDepth` (effective sun
  strength, darkening, haze and reciprocal depth range) and `lightHaze` (the haze
  colour in linear light), packed by `Hetoimasia.Terrain.Render2D.Presentation`.
  The engine's tint, brightness and cutout wrapping apply once.
- **Cutout-capable:** the output alpha is the colour's alpha times the map's,
  binary wherever both are (each is a binary coverage, and both are sampled
  nearest at a texel centre). Whether an instance takes the cutout or the ordered
  path is decided by the registered mark of its colour atlas, never forced by the
  material.
- **The function** takes, for each region separately, the texel the UV selects in
  the region's own 96 x 64 extent, `floor (clamp u 0 1 * w + 1/128)` (the bias is the
  owner's 2026-11-09 Q-13 amendments; the GLSL literal is made from `texelBias`, the
  rule's one definition in `Hetoimasia.Terrain.Render2D.TexelRule` of the terrain main
  library), adds the origin afterwards, and samples that
  texel's centre, `(origin + (i + 1/2, j + 1/2)) / atlasExtent`, nearest at level
  zero; both samples are unconditional (the sampler's derivatives need uniform
  control flow). It decodes the normal as `normalize (round (255 c) - 128)` (a
  guard keeps a transparent sample from becoming a NaN), lights the colour, applies
  the darkening and haze in linear light and returns premultiplied linear colour.
  `terrainMaterialEquivalent` is the same function with every commutative
  operation written the other way round and its own SPIR-V.
- **Negative controls, never terrain materials**: `terrainMaterialInsetControl` (half-texel-inset
  interpolation), `terrainMaterialUnbiasedControl` (the texel rule with no bias: it reads the
  lower texel at exact boundaries, 92 to 106 pixels of about 4,400 in the exact-boundary fixtures
  on the recorded device) and `terrainMaterialStaleBiasControl` (the first amendment's 1/10000: it
  still reads the lower texel at 12 and 15 pixels of the snapped 9/8 and 5/4 fixtures). The device
  evidence shows its judge rejecting each.

Nothing is added to the renderer: no descriptor binding, no vertex or instance
format (the 64-byte instance and its parameter word are the engine's), no depth
output and no per-fragment depth. A texel the colour or the map leaves
transparent writes neither colour nor depth, so the renderer's ordinary depth key
decides which quad is nearest.

## Immutable configuration, owner and lifetime

The declaration is the whole configuration and it is immutable, fixed at build
time. The owner is the build; a caller registers the compiled material with
`registerMaterial` on a renderer it owns, and the reference belongs to that
renderer (a material is never released). The package starts no thread or process,
holds no state, and creates no service, window publisher, global registry, Lua
shader source or live shader loader. The atlases, their handles and their marks are the caller's data (`AtlasTextures`).

## Tests

`hetoimasia-terrain-render-2d-vulkan:test:terrain-render-2d-vulkan-tests`, part of
the group `test.vulkan-headless`, creates no device:

```sh
bash tools/vulkan/run.sh test hetoimasia-terrain-render-2d-vulkan:test:terrain-render-2d-vulkan-tests
```

It checks the declaration against the pure layout and push block (48 bytes at
offsets 0, 16 and 32), that an adapted plan's records and instances pass snapshot
validation and are refused when a record has another layout, a parameter word is
past the table or the push block is not the declared size, the draw path the
colour atlas's mark routes the quads to, and the bytes the renderer writes for the
records. The offscreen proof on a real device is the `tra17-terrain` scenario of
`vulkan-native-tests` (the complete Q-13 matrix, run directly) and its bounded
required selection `tra17-terrain-ci`; see `docs/evidence/terrain/tra17/`.
