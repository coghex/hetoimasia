# LFE-24 pixel evidence: Lua-authored output through offscreen pixels

The retained evidence for [#539](https://github.com/coghex/hetoimasia/issues/539) (epic #514, LFE-24). It shows the
pixels the shipped `samples/lua-quad` content and small purpose-built Lua programs author, read from a real managed
RGBA8 sRGB colour target after the work that drew them completed, on a real device. It captures no screen, opens no
native window (the run's record reports `windows: 0`; the native window is LFE-25's) and makes no performance or new
platform-support claim. The contract is in the
[adapter's README](../../../packages/lua-engine-graphics/README.md#lua-offscreen-pixels-lfe-24); the technical fixtures,
their provenance and texel tables are in
[`test-common/fixtures/pixels/`](../../../packages/lua-engine-graphics/test-common/fixtures/pixels/README.md). **These are
technical test assets, not production art.**

## Identities

| | macOS |
| --- | --- |
| Producer | `lua-engine-graphics-native-tests`, the group `Lua offscreen pixels`, run locally with `HETOIMASIA_VALIDATION_EVIDENCE` set (the files below are what it wrote) |
| Command | `HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --match 'Lua offscreen pixels'`, after `bash tools/vulkan/run.sh build hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests` |
| Revision run | `4760bb503a4cf81a7f89fc3e2729a494fbd435d3`, a clean tree (the pull request's head after repairing review round 1) |
| Native source digest | `ffebe38127a14967a2e0b638c2dd971a3bad13786c991e218449f522f26e108c` (`tools/vulkan/run.sh` roots, which include `packages/lua-engine-graphics`, `packages/lua-engine`, `packages/scripting-lua`, `packages/content` and `samples/lua-quad`, so every Lua, content, adapter, fixture and renderer input) |
| Platform | macOS, Apple M3 Max, arm64; GHC 9.14.1, Cabal 3.18.1.0 |
| Device and driver | Apple M3 Max through MoltenVK (`VK_DRIVER_FILES` the provisioned prefix's `MoltenVK_icd.json`), the provisioned loader `libvulkan.1.dylib` (held to the recorded one) |
| Validation | `VK_LAYER_KHRONOS_validation` with synchronization validation; the diagnostic verdict, computed after the last teardown callback, is clean (64 records delivered) |
| Result | 11 examples, 0 failures (ten cases and the regression for a Lua failure before any window); `every check passed` ([the run's record](lua-engine-graphics-native.md)) |
| Consent | the desktop opt-in on that one command, under the owner's standing approval (AGENTS.md); the group opened no window |

The Linux receipts (the isolated X11 display, software Vulkan) are the pull request's CI receipts for
`test.vulkan-lua-engine-native`; they are linked from the pull request. A CI artifact may supplement these files; it does
not replace them.

## How an image was made and judged

For each image the display adapter recorded, in one frame-less batch on the graphics owner through
`recordVulkanTargetBatch`, the production `frameCandidate` output for the scene the host adopted, retargeted in its pass
target alone (equality in every other value is asserted), into a managed RGBA8 sRGB target of the stated extent, then
copied to a managed readback buffer; the bytes were read only after the batch's own ticket reported completion. Each image
is judged by:

* the render-2d oracle over the published window-pass scene, with the managed target's own `TargetSpec`, **every pixel**:
  the table's *determinate* column counts pixels it determined and the readback matched within the oracle's per-channel
  tolerance (0 or 1 by its exactness rule); *indeterminate* pixels are those the oracle declines to determine, by reason
  (all here are `NearTexelBoundary`: a nearest-sampled pixel within 1/16 texel of an interior boundary between texels that
  differ) and they count for no success; no image has an unevaluable or failed pixel;
* named positions and the colours the fixture's specification puts there, worked out by hand (tolerance 1 for an
  opaque texel or clear, 2 for a blend), and required to agree with the oracle's own expectation;
* the oracle over a snapshot written from the specification, whose textures are the texel tables premultiplied here, not
  by the decoder, and a comparison of the published scene with it.

The PNGs are lossless readbacks (8-bit RGBA, the target's pixels top row first). Each `.json` record names the case, the
scene revision, the target's format, extent and metrics, the texture identities of the scene's sprites, the completion
evidence, the counts, the tolerances and the SHA-256 of the readback bytes and of the PNG.

| PNG | Case / image | Revision | Target | Determinate | Indeterminate | Named probes | SHA-256 of the PNG |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [`shipped-quad--shipped-quad.png`](shipped-quad--shipped-quad.png) | shipped-quad / shipped quad | 1 | 304x304, scale 1 | 89872 | 2544 (NearTexelBoundary 2544) | 17 | `23fbec21ef9aa897c0bcaa7e1623536f063170385daa862834766086192ebdb6` |
| [`top-left-nearest--grid.png`](top-left-nearest--grid.png) | top-left-nearest / grid | 1 | 64x48, scale 1 | 2824 | 248 (NearTexelBoundary 248) | 29 | `438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28` |
| [`top-left-nearest--initial-scene.png`](top-left-nearest--initial-scene.png) | top-left-nearest / initial scene | 0 | 64x48, scale 1 | 3072 | 0 (none) | 3 | `877cc583927a33fd82334650cd957694f789432760faa9cf289408216b17237d` |
| [`ordered-transparency--blue-then-red.png`](ordered-transparency--blue-then-red.png) | ordered-transparency / blue then red | 2 | 64x48, scale 1 | 3072 | 0 (none) | 6 | `e75f1ec4c99625d09eedbbd1bb0ca27b182bfd3cfdab21c4114325b26fee0d2f` |
| [`ordered-transparency--red-then-blue.png`](ordered-transparency--red-then-blue.png) | ordered-transparency / red then blue | 1 | 64x48, scale 1 | 3072 | 0 (none) | 13 | `7d5eac401fd0b5a4eb778075c099a1e24fd33a9f0cb111403faa47d1c2e703ee` |
| [`srgb-byte-clear--clear-128.png`](srgb-byte-clear--clear-128.png) | srgb-byte-clear / clear 128 | 1 | 64x48, scale 1 | 3072 | 0 (none) | 3 | `979f29b8da966e89e406718611d7733899cba54310b7f0e8c7f10aa6b53ad7ef` |
| [`srgb-byte-clear--texel-128.png`](srgb-byte-clear--texel-128.png) | srgb-byte-clear / texel 128 | 2 | 64x48, scale 1 | 3072 | 0 (none) | 6 | `f931f1c96f7763f6f4c50fcc7210db14a248b014b62e37b2fd9f6afac29d56a9` |
| [`fractional-negative-clipping--placement.png`](fractional-negative-clipping--placement.png) | fractional-negative-clipping / placement | 1 | 64x48, scale 1 | 3072 | 0 (none) | 40 | `9f26ce1abe7ed64bc162a9de8493d36a7dd40d71dba1b126d5d8be4c7560f1d9` |
| [`target-metrics--extent-128x96-for-logical-64x48--scale-2.png`](target-metrics--extent-128x96-for-logical-64x48--scale-2.png) | target-metrics / extent 128x96 for logical 64x48, scale 2 | 1 | 128x96, scale 2 | 11768 | 520 (NearTexelBoundary 520) | 29 | `4cc3246590379cfcfc30e528638cfa6b8f1fea46f95e76b89ffe09963c9a57df` |
| [`target-metrics--extent-40x30--scale-1.png`](target-metrics--extent-40x30--scale-1.png) | target-metrics / extent 40x30, scale 1 | 1 | 40x30, scale 1 | 972 | 228 (NearTexelBoundary 228) | 24 | `d9fea5f19d349cf0e4b3f8179d07246bd1856edeb6efcc584c0c6f8ab497c05f` |
| [`target-metrics--extent-64x48--scale-1.png`](target-metrics--extent-64x48--scale-1.png) | target-metrics / extent 64x48, scale 1 | 1 | 64x48, scale 1 | 2824 | 248 (NearTexelBoundary 248) | 29 | `438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28` |
| [`target-metrics--extent-80x60--scale-1.png`](target-metrics--extent-80x60--scale-1.png) | target-metrics / extent 80x60, scale 1 | 1 | 80x60, scale 1 | 4552 | 248 (NearTexelBoundary 248) | 29 | `c746da3a69e60e35d0119ec862972b536ed6b24421fa20b11771adffda157641` |
| [`empty-scene--after--empty.png`](empty-scene--after--empty.png) | empty-scene / after: empty | 2 | 64x48, scale 1 | 3072 | 0 (none) | 5 | `4e5920a9e1418c5e73f0d9073f44f06822076fdb5a873725683d0cf7f6d49875` |
| [`empty-scene--before--the-grid.png`](empty-scene--before--the-grid.png) | empty-scene / before: the grid | 1 | 64x48, scale 1 | 2824 | 248 (NearTexelBoundary 248) | 29 | `438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28` |
| [`copied-scene--as-published--after-the-script-changed-its-table.png`](copied-scene--as-published--after-the-script-changed-its-table.png) | copied-scene / as published, after the script changed its table | 1 | 64x48, scale 1 | 3072 | 0 (none) | 4 | `190ac18d45773b3fbd82af85c9a41b2010907c29b006c5f0530eb85a98723235` |
| [`copied-scene--republished-after-the-change.png`](copied-scene--republished-after-the-change.png) | copied-scene / republished after the change | 2 | 64x48, scale 1 | 3072 | 0 (none) | 4 | `54d2678a18b54bd9f3c90cdff618b6db3f80b152d3d8d25a9f07b9291daeb8bc` |
| [`refused-publication--last-accepted--after-the-refusals.png`](refused-publication--last-accepted--after-the-refusals.png) | refused-publication / last accepted, after the refusals | 1 | 64x48, scale 1 | 2824 | 248 (NearTexelBoundary 248) | 16 | `ab8d5bc40357f5c5074cae4f54616f6b219c1bf860de4a0db534dd0a5fd8a9f0` |
| [`refused-publication--last-accepted--before-the-refusals.png`](refused-publication--last-accepted--before-the-refusals.png) | refused-publication / last accepted, before the refusals | 1 | 64x48, scale 1 | 2824 | 248 (NearTexelBoundary 248) | 16 | `ab8d5bc40357f5c5074cae4f54616f6b219c1bf860de4a0db534dd0a5fd8a9f0` |
| [`release-after-publish--drawn-after-the-release.png`](release-after-publish--drawn-after-the-release.png) | release-after-publish / drawn after the release | 1 | 64x48, scale 1 | 2824 | 248 (NearTexelBoundary 248) | 29 | `438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28` |
| [`release-after-publish--drawn-again--no-new-publication.png`](release-after-publish--drawn-again--no-new-publication.png) | release-after-publish / drawn again, no new publication | 1 | 64x48, scale 1 | 2824 | 248 (NearTexelBoundary 248) | 29 | `438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28` |
| [`release-after-publish--drawn-while-the-replacement-is-published.png`](release-after-publish--drawn-while-the-replacement-is-published.png) | release-after-publish / drawn while the replacement is published | 1 | 64x48, scale 1 | 2824 | 248 (NearTexelBoundary 248) | 29 | `438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28` |
| [`release-after-publish--the-empty-replacement.png`](release-after-publish--the-empty-replacement.png) | release-after-publish / the empty replacement | 2 | 64x48, scale 1 | 3072 | 0 (none) | 5 | `4e5920a9e1418c5e73f0d9073f44f06822076fdb5a873725683d0cf7f6d49875` |

## Reading the cases

* **Shipped Lua quad**: the unchanged `samples/lua-quad/content` (clear 24, 24, 24; `quad.png` at (32, 32) 256 × 256) on a
  304 × 304 target. The white texel is at the top left and the black one at the bottom right; red, green, blue and yellow
  are the quadrants.
* **Top-left / nearest**: `initial scene` is the host's initial scene before any publication, opaque black; `grid` is the
  twelve-colour table enlarged eight to a texel at logical (10, 8).
* **Ordered transparency**: `red then blue` and `blue then red` are two publications of the same two partly transparent
  sprites (alpha 192) over opaque black. The overlap reads (119, 0, 225) when the blue is listed last and (225, 0, 119)
  when the red is.
* **sRGB byte clear**: `clear 128` reads 128 everywhere (a byte 128 taken as linear light would read 188); `texel 128` is
  an opaque 128 texel over black.
* **Fractional, negative, clipping**: A and B have fractional origins and sizes (10.4, 6.4, 8.35 x 6.35 and 24.7, 6.7, 8.6 x 6.6), chosen so that rounding an origin to the nearest integer would change a covered pixel; C, D and E cross the left and
  top, right and bottom, and left edges; the grid is cropped by the top edge (its first row is above the target).
* **Target metrics**: four images of the same accepted revision (1), with no new publication, at 64 × 48, 128 × 96 for a
  logical 64 × 48 at content scale 2, 80 × 60 and 40 × 30.
* **Empty scene**: the earlier `grid` image, then the empty scene's opaque clear.
* **Copied scene**: the scene as published, read after the script changed its own table, and the table published again.
* **Refused publication**: the last accepted scene before and after a malformed publication and a publication naming a
  released texture were refused; both images are of revision 1.
* **Release after publish**: with the owner held on a gate until the host's own state showed revision 1 accepted and not
  adopted and the release request queued behind the target's barrier, the texture was released straight after acceptance.
  `drawn after the release` and `drawn again, no new publication` are revision 1; `drawn while the replacement is
  published` is a third batch recorded with revision 1 whose completion was awaited only after the empty replacement
  (revision 2) had been accepted; `the empty replacement` is revision 2. The texture was freed only after those batches'
  own tickets completed (the live-texture count and the ledger's holds fell to zero on the table's and the host's evidence).

## Negative controls

Each new negative control was broken once locally and failed as it must; the mutation was not committed. The fifteen are
recorded in the pull request.
