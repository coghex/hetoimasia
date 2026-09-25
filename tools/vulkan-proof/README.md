# The retired VK-2 Vulkan compatibility proof

This directory held the VK-2 proof harness for
[issue #158](https://github.com/coghex/hetoimasia/issues/158): a single native
test suite that answered the backend design's evidence gate Q-2 — which
runtime profile the project can require, on which loader and driver, with which
completion and abandonment behaviour — and to which VK-5, VK-6 and VK-7 then
attached their own native cases. It was never a library or a production
component, and it is gone.

VK-8 ([issue #220](https://github.com/coghex/hetoimasia/issues/220)) moved every
one of those cases, with its assertions, into the window integration package's
native suite, which the validation group `test.vulkan-native` runs on every
change that affects it:

- the fixture and the cases are
  [`packages/gpu-vulkan/glfw/native-test/`](../../packages/gpu-vulkan/glfw/native-test/),
  and [the native suite](../../docs/gpu_backend.md#the-native-suite) is their
  contract;
- [`tools/vulkan/run.sh`](../vulkan/run.sh) replaced `run-proof.sh` and
  `run-shaders.sh`, and the shader evidence script moved beside it;
- the `vulkan-proof` route of `.github/workflows/ci-image.yml` is gone.

What the harness proved stays where it was retained, as the historical evidence
of the inputs each record names:

- [the compatibility record](../../docs/vulkan_compatibility_record.md), the
  summary later slices build on;
- the VK-2 pair, [`docs/vulkan/macos.md`](../../docs/vulkan/macos.md) and
  [`docs/vulkan/linux.md`](../../docs/vulkan/linux.md), and VK-4's provisioned
  pair beside them;
- VK-6's [`macos-vk6.md`](../../docs/vulkan/macos-vk6.md) and
  [`linux-vk6.md`](../../docs/vulkan/linux-vk6.md), VK-5's
  [`macos-vk5.md`](../../docs/vulkan/macos-vk5.md) and
  [`linux-vk5.md`](../../docs/vulkan/linux-vk5.md), VK-7's
  [`linux-vk7.md`](../../docs/vulkan/linux-vk7.md), and VK-9's shader records.

Those records name paths under this directory and the proof's own run
commands; they describe the harness as it was when each was taken, and are not
instructions for today.
