# GRS-8 2D evidence: the sprites sample

The retained evidence for #345, the sprites sample (`samples/sprites/`). It
covers premultiplied-alpha blending and indexed, instanced textured quads drawn
through stable texture handles. The sample's
[README](../../../samples/sprites/README.md) is the manifest: fixtures, UV
regions, scene, sampler assignments and probe oracle.

## Identities

| | macOS | Linux (CI) |
| --- | --- | --- |
| Capture | [`sprites-macos.png`](sprites-macos.png) | [`sprites-linux.png`](sprites-linux.png) |
| PNG SHA-256 | `b0fc8bbe9c49b504d1f51968878e9e5ad137e1c0c17ed0948808c25d80fec119` | `b0fc8bbe9c49b504d1f51968878e9e5ad137e1c0c17ed0948808c25d80fec119` |
| Producer | `test.vulkan-native` (`--complete`, `grs8-sprites` case), run locally with `HETOIMASIA_VALIDATION_EVIDENCE` set | `test.vulkan-native` in workflow run [37165815897](https://github.com/coghex/hetoimasia/actions/runs/37165815897) (attempt 1), artifact `validation-receipts-vulkan` (id 11288474608), file `evidence/test.vulkan-native/sprites/sprites.png` |
| Revision run | `e0d98da955d97f796b9ffa37aaf0f53f3a4468f2`, the pull request's final head | `7d205d39785b69b2bc7a73654e45890120b017d5`, CI's merge of the pull request's final head `e0d98da955d97f796b9ffa37aaf0f53f3a4468f2` (tree `125d956528e5ddf6ffc8c625436aa446eb9cbe75`) |
| Native source digest | `ca7784d8805b3fb7b5bd0c7feff604d5456501e5227ddbda1d03ac24ba89b4db` | `ca7784d8805b3fb7b5bd0c7feff604d5456501e5227ddbda1d03ac24ba89b4db` |
| Platform | macOS 26.7.1 (25G313), Apple M3 Max, arm64 | GitHub Actions Linux X64, the CI image's isolated X11 display |
| Device and driver | Apple M3 Max; MoltenVK 1.4.2, device API 1.3.357 | `llvmpipe (LLVM 20.1.2, 256 bits)`; pinned Mesa 25.2.8 Lavapipe (`lvp_icd.json`) |
| Loader and layers | The provisioned prefix's loader and `VK_LAYER_KHRONOS_validation`; implicit layers disabled (`VK_LOADER_LAYERS_DISABLE=~implicit~`), no layer settings file | The same configuration from the CI image's prefix |
| Validation | Synchronization validation enabled; clean verdict after the last teardown | Synchronization validation enabled; clean verdict after the last teardown |
| Suite | 134 examples, 0 failures, 2 pending (by design); process ran 5.3 s | 134 examples, 0 failures, 2 pending; `grs8-sprites` exited successfully |
| BC7 | supported and exercised | supported and exercised |
| Readback | 262,144 bytes, complete | 262,144 bytes, complete |

The native source digest covers the native backend, the window integration,
both samples' packages and the runner (`tools/vulkan/run.sh`). Adding this
record changes the Git revision but not that digest, since `docs/` lies outside
it: both captures describe the delivered implementation sources. The pull
request head and the commit CI merged differ only by master's documentation
landings.

This record was regenerated at the pull request's final head `e0d98da9`, after
round 1 of its review changed `samples/sprites/renderer` (the probe record's
JSON escaping). That moved the native source digest from
`f7d30fad98a5a4c18c2defaf15c39f87e384cb8107411d58e0378f03d92f9dad` (head
`cac6f18d`) to the one above. Both platforms' captures are byte-identical to
those of the earlier head, since the drawing did not change.

CI's `test.vulkan-wayland` group ran the same case under the isolated headless
Wayland compositor. Its capture, `evidence/test.vulkan-wayland/sprites/sprites.png`
in the same artifact, has SHA-256 `b0fc8bbe9c49b504d1f51968878e9e5ad137e1c0c17ed0948808c25d80fec119`, and its 25 probes all passed.

## Fixtures

| Fixture | Format | Extent | Mip levels | Bytes | SHA-256 of the bytes |
| --- | --- | --- | --- | --- | --- |
| Atlas | Rgba8Linear | 8×8 | 1 (level 0) | 256 | `2496743087dc3b2ddf5e528fbe8c91c07b0dcfac38164aeb5cf6990f0bababf5` |
| Translucent | Rgba8Linear | 2×2 | 1 (level 0) | 16 | `f66f56c40d57546b15bd8092f1027ac3604ee6e0d0b5928259ab22b1bb796747` |
| Bc7Block | Bc7Linear | 4×4 | 1 (level 0) | 16 | `808b350834a573efdd88f3357d5d913f825eea9197867c9cec3111eaea156f19` |

## Draws and samplers

| Draw | Sampler | Sampler index | Instances |
| --- | --- | --- | --- |
| GridDraw | NearestClamp | 0 | 1032 |
| LinearDraw | LinearClamp | 2 | 2 |
| Bc7Draw | NearestClamp | 0 | 1 |

The target is 256×256 `R8G8B8A8_UNORM`, linear, cleared to (0,0,0,0),
single-sample, level 0, with no colour conversion.

## Checks

Expected values come from the sample's oracle, computed from the fixtures,
coordinates and blend equation, never from either image. A tolerance is exact
for opaque nearest samples and the clear, and ±1 per channel where linear
filtering or a translucent-over-non-clear blend contributes. The linear probe's
coordinate is chosen to hold its ±1 at any conformant sub-texel precision (see
the README).

| Check | Pixel | Purpose | Expected | Tolerance | macOS observed | Linux observed | Linux Wayland observed |
| --- | --- | --- | --- | --- | --- | --- | --- |
| grid red region (0,0) | (1,1) | LargeDraw | (255,0,0,255) | exact | (255,0,0,255) pass | (255,0,0,255) pass | (255,0,0,255) pass |
| grid green region (1,0) | (5,1) | LargeDraw | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| grid blue region (2,0) | (9,1) | LargeDraw | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| grid yellow region (3,0) | (13,1) | LargeDraw | (255,255,0,255) | exact | (255,255,0,255) pass | (255,255,0,255) pass | (255,255,0,255) pass |
| grid translucent red (7,3) | (29,13) | LargeDraw | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| grid blue region (14,16) | (57,65) | LargeDraw | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| grid green region (30,31) | (121,125) | LargeDraw | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| atlas red region | (147,19) | AtlasSelection | (255,0,0,255) | exact | (255,0,0,255) pass | (255,0,0,255) pass | (255,0,0,255) pass |
| atlas green region | (187,19) | AtlasSelection | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| atlas blue region | (147,59) | AtlasSelection | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| atlas yellow region | (187,59) | AtlasSelection | (255,255,0,255) | exact | (255,255,0,255) pass | (255,255,0,255) pass | (255,255,0,255) pass |
| red/green boundary, nearest | (232,24) | FilterDistinction | (255,0,0,255) | exact | (255,0,0,255) pass | (255,0,0,255) pass | (255,0,0,255) pass |
| red/green boundary, linear | (232,64) | FilterDistinction | (191,64,0,255) | ±1 | (191,64,0,255) pass | (191,64,0,255) pass | (191,64,0,255) pass |
| translucent red alone | (144,112) | Translucency | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| red then blue, one draw | (172,112) | PainterOrder | (64,0,128,192) | ±1 | (64,0,128,192) pass | (64,0,128,192) pass | (64,0,128,192) pass |
| translucent blue alone | (196,112) | Translucency | (0,0,128,128) | exact | (0,0,128,128) pass | (0,0,128,128) pass | (0,0,128,128) pass |
| translucent red alone, before the boundary | (144,176) | Translucency | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| red then blue, across the draw boundary | (172,176) | PainterOrder | (64,0,128,192) | ±1 | (64,0,128,192) pass | (64,0,128,192) pass | (64,0,128,192) pass |
| translucent blue alone, after the boundary | (196,176) | Translucency | (0,0,128,128) | ±1 | (0,0,128,128) pass | (0,0,128,128) pass | (0,0,128,128) pass |
| clear, between the grid and the atlas | (130,130) | Clear | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, lower right | (250,250) | Clear | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, lower left | (100,200) | Clear | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, right edge | (250,140) | Clear | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| BC7 left endpoint | (21,224) | Bc7Texels | (255,1,1,255) | exact | (255,1,1,255) pass | (255,1,1,255) pass | (255,1,1,255) pass |
| BC7 right endpoint | (43,224) | Bc7Texels | (1,1,255,255) | exact | (1,1,255,255) pass | (1,1,255,255) pass | (1,1,255,255) pass |

Every check passed on every platform: macOS 25/25, Linux 25/25, Linux Wayland 25/25.

## Inspection (D-6)

Both PNGs were opened and inspected. They agree with the intended scene and
with the probe results:

- the 32×32 grid of atlas regions in the upper-left quarter, cycling red,
  green, blue and yellow along each diagonal, with every eighth column the
  translucent red texture;
- the four atlas regions, each in its own colour, at the upper right;
- beside them, the nearest sample of the red/green boundary in red and the
  linear sample of the same coordinate in a red-green mix;
- two rows of translucent red, overlap and blue — once within one draw and
  once across the draw boundary — whose overlaps are the purple premultiplied
  composition of blue over red, not red over blue;
- the BC7 block's red and blue halves at the lower left;
- the transparent clear everywhere else.

An image viewer composites the translucent regions over its own background, so
they appear lighter there than their stored bytes. The two captures are
byte-identical, as is the Wayland capture. Whole-image equality across
platforms is not required, and is recorded here only as observed.

# GRS-9 2D evidence: a texture swap under a stable handle

The retained evidence for #346: the sprites sample's swap case
(`Hetoimasia.Sample.Sprites.Swap`), which the native suite runs as
`grs9-swap` and the sample's executable as `--evidence --swap`. The atlas's
handle is redirected to a replacement between a frame's recording and its
submission. The sample's [README](../../../samples/sprites/README.md#the-swap-case)
describes the case.

## Identities

| | macOS | Linux (CI) |
| --- | --- | --- |
| Captures | [`swap-before-macos.png`](swap-before-macos.png), [`swap-delayed-macos.png`](swap-delayed-macos.png), [`swap-after-macos.png`](swap-after-macos.png) | [`swap-before-linux.png`](swap-before-linux.png), [`swap-delayed-linux.png`](swap-delayed-linux.png), [`swap-after-linux.png`](swap-after-linux.png) |
| Before and delayed PNG SHA-256 | `b0fc8bbe9c49b504d1f51968878e9e5ad137e1c0c17ed0948808c25d80fec119` | `b0fc8bbe9c49b504d1f51968878e9e5ad137e1c0c17ed0948808c25d80fec119` |
| After PNG SHA-256 | `afea3c4720c1b056e12edec754464793f8efa94a583f1f3706c5ab12f8581db2` | `afea3c4720c1b056e12edec754464793f8efa94a583f1f3706c5ab12f8581db2` |
| Producer | `test.vulkan-native` (`--complete`, `grs9-swap` case), run locally with `HETOIMASIA_VALIDATION_EVIDENCE` set | `test.vulkan-native` in workflow run [37226749524](https://github.com/coghex/hetoimasia/actions/runs/37226749524) (attempt 1), artifact `validation-receipts-vulkan` (id 11311374962), files `evidence/test.vulkan-native/swap/` |
| Revision run | `8aef998510ffd3dbfe15fb06dc24a825f3d5d2f6`, the pull request's head after review round 1 | `4062de710e828756a4e65b78773b23d698d8a5ed`, CI's merge of the head `8aef998510ffd3dbfe15fb06dc24a825f3d5d2f6` (tree `bf8ceb1f84c5c0a0c87c6a2baeb69d32dc30e122`) |
| Native source digest | `a0e21578a103177c5050b881151661731a80d7c47b3944a4c1974de8539f6d72` | `a0e21578a103177c5050b881151661731a80d7c47b3944a4c1974de8539f6d72` |
| Platform | macOS 26.7.1 (25G313), Apple M3 Max, arm64 | GitHub Actions Linux X64, the CI image's isolated X11 display |
| Device and driver | Apple M3 Max; MoltenVK, device API 1.3.357 | `llvmpipe (LLVM 20.1.2, 256 bits)`; pinned Mesa Lavapipe (`lvp_icd.json`) |
| Validation | Synchronization validation enabled; clean verdict after the last teardown | Synchronization validation enabled; clean verdict after the last teardown |
| Suite | 136 examples, 0 failures, 2 pending (by design); `grs9-swap` exited successfully | 136 examples, 0 failures, 2 pending; `grs9-swap` exited successfully |
| BC7 | supported and exercised | supported and exercised |
| Readbacks | three of 262,144 bytes, complete | three of 262,144 bytes, complete |

This record was regenerated at head `8aef9985` after review round 1 changed
the native backend (pending swaps failed at retirement; a swap's replacement
refusing further uploads). That moved the native source digest from
`abeed0830233c28a4d3aef995b8b8e4bd3d1fe12da9a56a6af8e416abfcd5ee5` (head
`ac75a7cf`, workflow run 37215778595) to the one above. Every capture on both
platforms is byte-identical to the earlier head's, since the drawing did not
change.

CI's `test.vulkan-wayland` group ran the same case under the isolated headless
Wayland compositor (`evidence/test.vulkan-wayland/swap/` in the same
artifact). Its captures have the same SHA-256s, and all its checks passed.

The before and delayed captures are byte-identical to GRS-8's
[`sprites-macos.png`](sprites-macos.png) and
[`sprites-linux.png`](sprites-linux.png): they draw the same scene with the
original atlas.

## The replacement

`swappedAtlasFixture`: Rgba8Linear, 8×8, one mip level, 256 bytes. It keeps
the atlas's layout, so every UV rectangle and the linear probe's sub-texel
margin hold unchanged, and rotates each region's colour: green upper-left,
blue upper-right, yellow lower-left, red lower-right. Its upload completed
before the swap was requested. A changed format, extent and mip count are
covered by the native suite's stand-in examples rather than here.

## Facts and ordering

The same on both platforms (and under Wayland):

| Fact | Observed |
| --- | --- |
| The atlas's slot before the swap | 1 |
| The replacement's slot | 4 |
| The swap's ticket once the delayed frame completed | `SwapPublished` |
| Retiring slots while the delayed frame, recorded and not yet submitted, held the old version | `[1]` |
| The slot a texture registered then took | 5 |
| The slot a texture registered once the delayed frame completed took | 1, the atlas's old slot |
| The instance data before and after the swap | the same 41,400 bytes |

The order, as the record states it:

1. the frame before the swap completed;
2. the delayed frame was recorded, binding the table; then the atlas's handle
   was swapped and a texture registered; then the frame was submitted;
3. the delayed frame completed;
4. the frame after the swap completed;
5. a texture was registered once the delayed frame had completed.

## Checks

The before and delayed captures are checked against GRS-8's oracle over the
original fixtures: all 25 probes passed on every platform, with the values in
[GRS-8's checks](#checks) above. The after capture is checked against the same
oracle with the replacement drawn for the atlas (`evaluateProbesWith
swappedTextures`). Probe names keep the original atlas regions' names; the
expected colour is the replacement's.

| Check | Pixel | Expected | Tolerance | macOS observed | Linux observed | Linux Wayland observed |
| --- | --- | --- | --- | --- | --- | --- |
| grid red region (0,0) | (1,1) | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| grid green region (1,0) | (5,1) | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| grid blue region (2,0) | (9,1) | (255,255,0,255) | exact | (255,255,0,255) pass | (255,255,0,255) pass | (255,255,0,255) pass |
| grid yellow region (3,0) | (13,1) | (255,0,0,255) | exact | (255,0,0,255) pass | (255,0,0,255) pass | (255,0,0,255) pass |
| grid translucent red (7,3) | (29,13) | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| grid blue region (14,16) | (57,65) | (255,255,0,255) | exact | (255,255,0,255) pass | (255,255,0,255) pass | (255,255,0,255) pass |
| grid green region (30,31) | (121,125) | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| atlas red region | (147,19) | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| atlas green region | (187,19) | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| atlas blue region | (147,59) | (255,255,0,255) | exact | (255,255,0,255) pass | (255,255,0,255) pass | (255,255,0,255) pass |
| atlas yellow region | (187,59) | (255,0,0,255) | exact | (255,0,0,255) pass | (255,0,0,255) pass | (255,0,0,255) pass |
| red/green boundary, nearest | (232,24) | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| red/green boundary, linear | (232,64) | (0,191,64,255) | ±1 | (0,191,64,255) pass | (0,191,64,255) pass | (0,191,64,255) pass |
| translucent red alone | (144,112) | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| red then blue, one draw | (172,112) | (64,0,128,192) | ±1 | (64,0,128,192) pass | (64,0,128,192) pass | (64,0,128,192) pass |
| translucent blue alone | (196,112) | (0,0,128,128) | exact | (0,0,128,128) pass | (0,0,128,128) pass | (0,0,128,128) pass |
| translucent red alone, before the boundary | (144,176) | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| red then blue, across the draw boundary | (172,176) | (64,0,128,192) | ±1 | (64,0,128,192) pass | (64,0,128,192) pass | (64,0,128,192) pass |
| translucent blue alone, after the boundary | (196,176) | (0,0,128,128) | ±1 | (0,0,128,128) pass | (0,0,128,128) pass | (0,0,128,128) pass |
| clear, between the grid and the atlas | (130,130) | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, lower right | (250,250) | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, lower left | (100,200) | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, right edge | (250,140) | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| BC7 left endpoint | (21,224) | (255,1,1,255) | exact | (255,1,1,255) pass | (255,1,1,255) pass | (255,1,1,255) pass |
| BC7 right endpoint | (43,224) | (1,1,255,255) | exact | (1,1,255,255) pass | (1,1,255,255) pass | (1,1,255,255) pass |

Every check passed on every platform: before 25/25, delayed 25/25 and after
25/25 on macOS, Linux and Linux Wayland.

## Inspection (D-6)

The before and after PNGs were opened and inspected; the delayed PNG and the
other platform's are byte-identical to them:

- before and delayed: GRS-8's scene, unchanged;
- after: the same scene, with every atlas region in its rotated colour — the
  grid's cells cycling green, blue, yellow and red; the four atlas regions
  green, blue, yellow and red; the nearest boundary sample green and the
  linear one a green-blue mix — while the translucent rows, their overlaps,
  the BC7 block and the clear are as before.

The captures are byte-identical across platforms, as observed; whole-image
equality is not required.
