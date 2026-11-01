# The graphics adapter on a real device

- revision: ba158d8a1299284c8731a4c71147970afdccaca1
- source digest: e8229f183a2de1a42abcf0820f814c776cc44e467cc787b894602f0fb8d34b7c
- command: lua-engine-graphics-native-tests --match Lua offscreen pixels (through tools/vulkan/run.sh native)
- platform: darwin/aarch64, ghc Version {versionBranch = [9,14], versionTags = []}
- device: Apple M3 Max
- driver manifest: /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
- loader: /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib
- consent: the desktop opt-in on this run's command, under the owner's standing approval
- windows: 0 (the session is started without a surface and no window is requested)
- validation: synchronization validation, pinned features synchronization
- diagnostic verdict: clean, 64 records delivered
- native calls: 427
- destruction: vkDestroyFence, vkDestroyFence, vkDestroyPipeline, vkDestroyCommandPool, vkDestroyCommandPool, vkDestroyDescriptorPool, vkDestroyDescriptorPool, vkDestroyDescriptorPool, vkDestroyDescriptorSetLayout, vkDestroyDescriptorSetLayout, vkDestroyDescriptorSetLayout, vkDestroySampler, vkDestroySampler, vkDestroySampler, vkDestroySampler, vkDestroyPipelineLayout, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
- configuration: staging 33554432 bytes, table capacity 33, versions 10, native bytes budgeted 306186832 bytes of 2147483648 bytes
- seconds: 10.502556
- result: every check passed

## What the examples measured

- Lua offscreen pixels / shipped-quad / shipped quad: revision 1, (304,304), 89872 determinate pixels judged, 2544 indeterminate, 17 named probes, no fault, png sha256 23fbec21ef9aa897c0bcaa7e1623536f063170385daa862834766086192ebdb6
- Lua offscreen pixels / top-left-nearest / initial scene: revision 0, (64,48), 3072 determinate pixels judged, 0 indeterminate, 3 named probes, no fault, png sha256 877cc583927a33fd82334650cd957694f789432760faa9cf289408216b17237d
- Lua offscreen pixels / top-left-nearest / grid: revision 1, (64,48), 2824 determinate pixels judged, 248 indeterminate, 29 named probes, no fault, png sha256 438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28
- Lua offscreen pixels / ordered-transparency / red then blue: revision 1, (64,48), 3072 determinate pixels judged, 0 indeterminate, 13 named probes, no fault, png sha256 7d5eac401fd0b5a4eb778075c099a1e24fd33a9f0cb111403faa47d1c2e703ee
- Lua offscreen pixels / ordered-transparency / blue then red: revision 2, (64,48), 3072 determinate pixels judged, 0 indeterminate, 6 named probes, no fault, png sha256 e75f1ec4c99625d09eedbbd1bb0ca27b182bfd3cfdab21c4114325b26fee0d2f
- Lua offscreen pixels / srgb-byte-clear / clear 128: revision 1, (64,48), 3072 determinate pixels judged, 0 indeterminate, 3 named probes, no fault, png sha256 979f29b8da966e89e406718611d7733899cba54310b7f0e8c7f10aa6b53ad7ef
- Lua offscreen pixels / srgb-byte-clear / texel 128: revision 2, (64,48), 3072 determinate pixels judged, 0 indeterminate, 6 named probes, no fault, png sha256 f931f1c96f7763f6f4c50fcc7210db14a248b014b62e37b2fd9f6afac29d56a9
- Lua offscreen pixels / fractional-negative-clipping / placement: revision 1, (64,48), 3072 determinate pixels judged, 0 indeterminate, 38 named probes, no fault, png sha256 f8030fa0453ed76e1ea70751f2c1c39beafb0d275955876a9aa955d65cf66947
- Lua offscreen pixels / target-metrics / extent 64x48, scale 1: revision 1, (64,48), 2824 determinate pixels judged, 248 indeterminate, 29 named probes, no fault, png sha256 438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28
- Lua offscreen pixels / target-metrics / extent 128x96 for logical 64x48, scale 2: revision 1, (128,96), 11768 determinate pixels judged, 520 indeterminate, 29 named probes, no fault, png sha256 4cc3246590379cfcfc30e528638cfa6b8f1fea46f95e76b89ffe09963c9a57df
- Lua offscreen pixels / target-metrics / extent 80x60, scale 1: revision 1, (80,60), 4552 determinate pixels judged, 248 indeterminate, 29 named probes, no fault, png sha256 c746da3a69e60e35d0119ec862972b536ed6b24421fa20b11771adffda157641
- Lua offscreen pixels / target-metrics / extent 40x30, scale 1: revision 1, (40,30), 972 determinate pixels judged, 228 indeterminate, 24 named probes, no fault, png sha256 d9fea5f19d349cf0e4b3f8179d07246bd1856edeb6efcc584c0c6f8ab497c05f
- Lua offscreen pixels / empty-scene / before: the grid: revision 1, (64,48), 2824 determinate pixels judged, 248 indeterminate, 29 named probes, no fault, png sha256 438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28
- Lua offscreen pixels / empty-scene / after: empty: revision 2, (64,48), 3072 determinate pixels judged, 0 indeterminate, 5 named probes, no fault, png sha256 4e5920a9e1418c5e73f0d9073f44f06822076fdb5a873725683d0cf7f6d49875
- Lua offscreen pixels / copied-scene / as published, after the script changed its table: revision 1, (64,48), 3072 determinate pixels judged, 0 indeterminate, 4 named probes, no fault, png sha256 190ac18d45773b3fbd82af85c9a41b2010907c29b006c5f0530eb85a98723235
- Lua offscreen pixels / copied-scene / republished after the change: revision 2, (64,48), 3072 determinate pixels judged, 0 indeterminate, 4 named probes, no fault, png sha256 54d2678a18b54bd9f3c90cdff618b6db3f80b152d3d8d25a9f07b9291daeb8bc
- Lua offscreen pixels / refused-publication / last accepted, before the refusals: revision 1, (64,48), 2824 determinate pixels judged, 248 indeterminate, 16 named probes, no fault, png sha256 ab8d5bc40357f5c5074cae4f54616f6b219c1bf860de4a0db534dd0a5fd8a9f0
- Lua offscreen pixels / refused-publication / last accepted, after the refusals: revision 1, (64,48), 2824 determinate pixels judged, 248 indeterminate, 16 named probes, no fault, png sha256 ab8d5bc40357f5c5074cae4f54616f6b219c1bf860de4a0db534dd0a5fd8a9f0
- Lua offscreen pixels / release-after-publish / drawn after the release: revision 1, (64,48), 2824 determinate pixels judged, 248 indeterminate, 29 named probes, no fault, png sha256 438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28
- Lua offscreen pixels / release-after-publish / drawn again, no new publication: revision 1, (64,48), 2824 determinate pixels judged, 248 indeterminate, 29 named probes, no fault, png sha256 438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28
- Lua offscreen pixels / release-after-publish / drawn while the replacement is published: revision 1, (64,48), 2824 determinate pixels judged, 248 indeterminate, 29 named probes, no fault, png sha256 438376d98dd4fd34f1cb56fd8f51ee17cba3d31913339cdd031258aa1677ca28
- Lua offscreen pixels / release-after-publish / the empty replacement: revision 2, (64,48), 3072 determinate pixels judged, 0 indeterminate, 5 named probes, no fault, png sha256 4e5920a9e1418c5e73f0d9073f44f06822076fdb5a873725683d0cf7f6d49875
- Lua offscreen pixels: a texture released straight after acceptance and before adoption was drawn after the release (two batches), refused for a new publication, and retired only after the replacement and the old batches' tickets completed
