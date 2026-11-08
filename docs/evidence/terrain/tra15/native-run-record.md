# The graphics adapter on a real device

- revision: 92330829cf57fc930af61ec1e8c17f256903057c (dirty)
- source digest: bbad521cf43f5f65d291fa7f6ba06128f0a7e216617667209949d99122da7821
- command: lua-engine-graphics-native-tests --match validated data texture pixels (TRA-15) (through tools/vulkan/run.sh native)
- platform: darwin/aarch64, ghc Version {versionBranch = [9,14], versionTags = []}
- device: Apple M3 Max
- driver manifest: /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
- loader: /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib
- consent: the desktop opt-in on this run's command, under the owner's standing approval
- windows: 0 (the session is started without a surface and no window is requested)
- validation: synchronization validation, pinned features synchronization
- diagnostic verdict: clean, 64 records delivered
- native calls: 146
- destruction: vkDestroyFence, vkDestroyPipeline, vkDestroyCommandPool, vkDestroyDescriptorPool, vkDestroyDescriptorPool, vkDestroyDescriptorPool, vkDestroyDescriptorSetLayout, vkDestroyDescriptorSetLayout, vkDestroyDescriptorSetLayout, vkDestroySampler, vkDestroySampler, vkDestroySampler, vkDestroySampler, vkDestroyPipelineLayout, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
- configuration: staging 33554432 bytes, table capacity 33, versions 10, native bytes budgeted 306186832 bytes of 2147483648 bytes
- seconds: 0.220204
- result: every check passed

## What the examples measured

- validated data texture pixels (TRA-15) / ramp-colour-route: png sha256 7ed740e7097c74872dffc25fd35f64514a4caff6f327ae6937f096d521a62c03
- validated data texture pixels (TRA-15) / ramp-data-route: png sha256 7e9acd7322f52d42f02bc912a00a9c72e0accd597fc33affc83ab1a6408d04d8
- ramp: the same file read back as colour (128 → 128) and as data (128 → 188) through the production adapter into an sRGB target; windows 0
- validated data texture pixels (TRA-15) / normals-facts: png sha256 e50f53d0d7ed2b550c38afda9854afbfbcc0d572b00ad0b1c3fde34b246d09c6
- normals: coverage plane 0xFB and the unit-normal-rgb-v1 fact reached through retainTexture only; a plain data request has neither
- refused: a zero-vector normal map and a nonbinary alpha under coverage=binary failed as invalid_image and registered nothing
