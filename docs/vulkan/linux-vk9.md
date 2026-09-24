# The VK-9 shader record, Linux

> **Editorial context, added when this record was retained.** Everything above
> the "Captured log" marker is written by hand. Below it is the shader part of
> the job log, with timestamps and Cabal's per-module build progress removed
> and nothing else changed.

This is the Linux evidence for issue #221. The shader suite ran through the
`vulkan-proof` route of `.github/workflows/ci-image.yml`
([run 36026685194](https://github.com/coghex/hetoimasia/actions/runs/36026685194)).
That route builds and runs the suite because `run-proof.sh` runs
`run-shaders.sh` before the proof harness. It ran inside the published image the
committed `tools/ci-image/descriptor.json` names,
`ghcr.io/coghex/hetoimasia-ci@sha256:c7c63349d38218d4c9174b64a7deb27f797f213f8eb719952823390914630187`,
at repository revision `3f2d190bc6b77f757cae43758272de3c398adb95` (source
digest `54e6f31b399c…`). The shader suite needed no display, device or consent.
The proof that followed it in the same job passed too (96 examples, 0 failures).

What it shows on this platform:

- The compiler is the pinned `glslang-tools` 15.1.0: `/usr/bin/glslang`,
  `96ea85d4228d…`, behind the image's private-prefix wrapper. `native.py
  prepare` and the wrapper itself both name it. The fingerprint generator
  validated the wrapper against native manifest `cd0d48bba8e7…` and wrote the
  fingerprint before the build.
- The verification pair compiled during the build, and all 14 examples of
  `hetoimasia-gpu-vulkan-native:shader-tests` pass.
- The embedded SPIR-V is byte-identical to the macOS build's (glslang 15.0.0):
  vertex `47e12a96…` (824 bytes), fragment `0faa1f66…` (828 bytes). See
  [the macOS rebuild record](shader-rebuilds-macos.md). That is an observation
  about these two shaders under these two compiler builds, not a promise that
  different glslang versions agree in general. The fingerprint still records
  each platform's compiler separately.

## Captured log

```text
run-proof: ghc 9.14.1, cabal 3.18.1.0
run-proof: repository revision 3f2d190bc6b77f757cae43758272de3c398adb95
run-proof: source digest 54e6f31b399c51f150ab553d63e6ae1a2c95589124d5e98bbacfe29e771591e8
run-proof: VK_DRIVER_FILES=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json
run-proof: VK_LAYER_PATH=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d
run-proof: native prefix /opt/hetoimasia/native/glfw
run-proof: Vulkan prefix /opt/hetoimasia/native/glfw/vulkan
run-proof: /opt/hetoimasia/native/glfw matches this configuration (manifest cd0d48bba8e7)
run-proof: loader 1.3.275 (e833b010f814) at /usr/lib/x86_64-linux-gnu/libvulkan.so.1.3.275, opened as libvulkan.so
run-proof: driver lvp 1.4.318 (9d69cae2004b) via /opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json
run-proof: layer VK_LAYER_KHRONOS_validation 1.3.275 (1d486283e4ce) via /opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d/VK_LAYER_KHRONOS_validation.json
run-proof: headers c2fe3093ec24 at /usr/include
run-proof: glslang 15.1.0 (96ea85d4228d) behind /opt/hetoimasia/native/glfw/vulkan/bin/glslangValidator
run-proof: package libvulkan1 1.3.275.0-1build1
run-proof: package libvulkan-dev 1.3.275.0-1build1
run-proof: package mesa-vulkan-drivers 25.2.8-0ubuntu0.24.04.2
run-proof: package vulkan-validationlayers 1.3.275.0-1
run-proof: package glslang-tools 15.1.0-2~ubuntu0.24.04.2
run-proof: glslang wrapper reports glslang 15.1.0
run-proof: glslang wrapper reports compiler /usr/bin/glslang
run-proof: glslang wrapper reports sha256 96ea85d4228d7065507cd58454628e0d3c9ec8bbd29a0cd20ee0f3cefaf6d026
run-shaders: native prefix /opt/hetoimasia/native/glfw
run-shaders: glslang wrapper reports glslang 15.1.0
run-shaders: glslang wrapper reports compiler /usr/bin/glslang
run-shaders: glslang wrapper reports sha256 96ea85d4228d7065507cd58454628e0d3c9ec8bbd29a0cd20ee0f3cefaf6d026
Resolving dependencies...
Build profile: -w ghc-9.14.1 -O2
In order, the following will be built (use -v for more details):
run-shaders: shader fingerprint: /candidate/packages/gpu-vulkan/native/shaders/toolchain.fingerprint written (glslang 15.1.0 96ea85d4228d behind /opt/hetoimasia/native/glfw/vulkan/bin/glslangValidator, target vulkan1.3, flags -V, native manifest cd0d48bba8e7)
Build profile: -w ghc-9.14.1 -O2
In order, the following will be built (use -v for more details):
Running 1 test suites...
Test suite shader-tests: RUNNING...
embedded vertex SPIR-V: 824 bytes, sha256 47e12a96b5a5b173aaa6fdb7e5575e63db351a85f9d43164d3658fbf3d910a10
embedded fragment SPIR-V: 828 bytes, sha256 0faa1f66b4b5e02865c4a292a6aa297c1b468aed36339caeefb8afd3a63a67ca

Shaders
  The embedded verification pair
    is SPIR-V 1.6, the version the vulkan1.3 target environment produces [✔]
    carries the interpolated Haskell constant into the compiled vertex module [✔]
    carries the interpolated layout location into the vertex module's interface [✔]
    resolves the fragment shader's location through its transitive include [✔]
  The runtime compile entry
    compiles the fragment file to the bytes the splice embedded, reporting the source and both includes [✔]
    names the module, the site, the stage and the compiler's message for a broken shader [✔]
    refuses a shader whose include resolves outside the package root [✔]
  The toolchain fingerprint
    describes the provisioned wrapper, compiler and manifest as they are now [✔]
    round-trips through its file, and a reader refuses a field it does not know [✔]
    refuses one generated against another prefix, naming the wrapper and manifest identity it expected [✔]
    refuses one whose recorded compiler identity was edited, rather than trusting it [✔]
    refuses a missing fingerprint, naming where it looked [✔]
    is generated only from a wrapper the native manifest records, naming the manifest's identity [✔]
  A shader spliced outside this package
    fails that build, naming the module, the splice, the stage and the compiler's message [✔]

Finished in 0.8013 seconds
14 examples, 0 failures
Test suite shader-tests: PASS
```
