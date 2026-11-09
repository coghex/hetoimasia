# hetoimasia-terrain-render-2d-vulkan

The terrain arena's application material for the 2D renderer's Vulkan recorder
(epic #636, TRA-8). It is the Vulkan-dependent half of the terrain view: the pure
half, [`hetoimasia-terrain-render-2d`](../terrain-render-2d/README.md), plans the
faces and owns the record layout, the packing and the model of the material.

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

- **Record:** one full handle (the art sheet) and 23 words, the layout of
  `Hetoimasia.Terrain.Render2D.Material` (`recordLayout`): six floats of the art
  map (`u' = a·u + b·v + c`, `v' = d·u + e·v + f`), the mask's vertex count and
  up to eight mask vertices. Floats are the words' bit patterns.
- **Push block:** none. Tint, brightness and the cutout wrapping are the engine's.
- **Cutout-capable:** the output alpha is the sheet's wherever the mask covers the
  fragment and zero elsewhere, and the adapter's instances sample the sheet
  nearest, so the alpha is binary wherever the sheet's is. Whether an instance
  takes the cutout or the ordered path is decided by the registered mark of its
  texture (the art's decoded mark), never forced by the material.
- **The function** samples the sheet at the art coordinates unconditionally, then
  covers the fragment by the convex mask polygon (closed, either orientation):
  outside is transparent black.

Nothing is added to the renderer: no descriptor binding, no vertex or instance
format (the 64-byte instance and its parameter word are the engine's), no depth
output and no per-fragment depth. A face the mask does not cover writes neither
colour nor depth, so the renderer's ordinary depth key decides which face is
nearest.

## Immutable configuration, owner and lifetime

The declaration is the whole configuration and it is immutable, fixed at build
time. The owner is the build; a caller registers the compiled material with
`registerMaterial` on a renderer it owns, and the reference belongs to that
renderer (a material is never released). The package starts no thread or process,
holds no state, and creates no service, window publisher, global registry, Lua
shader source or live shader loader. The art, its handle and its marks are the
caller's data (`TerrainStyle`).

## Tests

`hetoimasia-terrain-render-2d-vulkan:test:terrain-render-2d-vulkan-tests`, part of
the group `test.vulkan-headless`, creates no device:

```sh
bash tools/vulkan/run.sh test hetoimasia-terrain-render-2d-vulkan:test:terrain-render-2d-vulkan-tests
```

It checks the declaration against the pure layout, that an adapted plan's records
and instances pass snapshot validation and are refused when a record has another
layout or a parameter word is past the table, the draw path the art's mark routes
the faces to, and the bytes the renderer writes for the records. The offscreen
proof on a real device is the `tra8-terrain` scenario of `vulkan-native-tests`.
