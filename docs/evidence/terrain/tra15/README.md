# TRA-15 evidence: validated data textures on a device (#657)

What this records: the native subgroup `validated data texture pixels (TRA-15)` of
`lua-engine-graphics-native-tests`, run on the owner's Mac (Apple M3 Max, MoltenVK, validation and
synchronization validation on) at the pull request's final code head, plus the unchanged M1 group
`Lua offscreen pixels` run beside it as the regression. Both opened no window (`windows: 0`, no surface)
and ended with a clean diagnostic verdict. It qualifies **format routing** (colour versus data through the
real content pipeline and the production texture adapter) and the retention boundary. It is not the later
terrain material or its all-shape picking proof (TRA-16/TRA-17).

Commands (macOS, under the owner's standing approval and a granted window slot; no window appears):

```sh
HETOIMASIA_NATIVE_SESSION=desktop HETOIMASIA_VALIDATION_EVIDENCE=<dir> bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --match 'validated data texture pixels (TRA-15)'
HETOIMASIA_NATIVE_SESSION=desktop HETOIMASIA_VALIDATION_EVIDENCE=<dir> bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --match 'Lua offscreen pixels'
```

Build identity of both runs: revision `9752b786dbcb…` (the merged pull request head, with the README correction of
this change still uncommitted, hence `dirty`), source digest
`051432ce3be08499d920ab3d7262d7f33fb02f0212059a951320974a588db120`. The run was repeated at this head after the first
review round's repairs and the merge of #655.

## Files

| File | What it is |
|---|---|
| `ramp-colour-route.png`, `.json` | the 4 × 2 ramp requested as colour (default), drawn one texel to a pixel into the sRGB target and read back |
| `ramp-data-route.png`, `.json` | the same file requested as `kind="data"`, same draw |
| `normals-facts.png`, `.json` | a 4 × 2 binary-alpha normal map loaded as `data` + `coverage` + `normal_encoding`, whose plane (`0xFB`) and checked profile were reached through `retainTexture` |
| `native-run-record.md`, `native-run-record-m1-regression.md` | the runner's records for the two commands |

Every `.json` carries the SHA-256 of the input PNG, the request, the target (`R8G8B8A8_SRGB`, 32 × 16,
surface-free), the build identity, `windows: 0`, the oracle's counts (512 determinate pixels, 0 failures) and
every comparison. The input files are explicitly labelled technical fixtures built byte by byte by the suite
(`Test.LuaEngine.Graphics.Png`), not production artwork.

## What the numbers say

The ramp's texels are opaque with intermediate channels. The target is sRGB, so a **colour** texel is decoded to
linear light on sampling and encoded again on the store and reads back as itself, while a **data** texel's number
`v ÷ 255` is taken as linear light and encoded, reading back as `round (255 × encode (v ÷ 255))`:

| input channel | 1 | 16 | 32 | 64 | 96 | 128 | 160 | 200 | 250 |
|---|---|---|---|---|---|---|---|---|---|
| colour route reads | 1 | 16 | 32 | 64 | 96 | 128 | 160 | 200 | 250 |
| data route reads | 13 | 71 | 99 | 137 | 165 | 188 | 208 | 229 | 253 |

Every one of the eight texels' three channels read back within the stated tolerance of 1 in both routes; the data
route read exactly the hand-stated values (the table of the `DataTextures` module header, worked from the IEC
61966-2-1 transfer function). Had the data route been reinterpreted as colour, the mid-grey 128 would read 128, not
188. The `normals-facts` record names the coverage bits (`fb`, texel (2,0) transparent) and the version identity the
retained facts belong to. A zero-vector normal map and a nonbinary alpha under `coverage="binary"` failed as
`invalid_image` and left the table's marks, the live-texture count and the shared CPU account unchanged (asserted in
the example, recorded in the run record's evidence lines).
