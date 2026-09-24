# The VK-9 shader rebuild record, macOS

> **Editorial context, added when this record was retained.** Everything above
> the "Captured transcript" marker is written by hand. Below it is the
> unedited output of `bash tools/vulkan-proof/shader-evidence.sh`, except that
> the session's scratch directory is written `<scratch>` and the provisioned
> native prefix `<prefix>`.

This is the local macOS evidence for issue #221 that no single build can give.
It was taken at repository revision `3f2d190bc6b77f757cae43758272de3c398adb95`,
with GHC 9.14.1 and Cabal 3.18.1.0, against a private native prefix that
`tools/native/native.py prepare` accepted. The pinned compiler is glslang
15.0.0 (`/usr/local/bin/glslang`, `7167bc1261b1…`). No window, device, session
or consent was involved.

The script copies the candidate to a scratch directory and edits only that
copy. Steps 1 to 13 compile through a *fixture* wrapper and fixture native
manifest. The wrapper answers `--hetoimasia-identity` for the pinned compiler
under a version label of its own (`15.0.0-fixture-a`, then `-b`) and logs each
compile it runs. That is how a compiler identity change is exercised without
changing a pin, and how each shader compilation is observed rather than
inferred. The `compiler:` lines are that log. Inline source is compiled from a
scratch file named `shader.<stage>`. Steps 16 and 17 use the provisioned
wrapper itself.

What it shows:

| Step | Change | Modules recompiled | Compiler runs |
| --- | --- | --- | --- |
| 1 | cold build | both | vert, frag |
| 2 | nothing | none (Cabal: up to date) | none |
| 3 | fragment source file | `Test.Shader.Fragment` | frag |
| 4 | transitive include of the fragment | `Test.Shader.Fragment` | frag |
| 5 | interpolated Haskell constant | `Test.Shader.Vertex` | vert |
| 6 | compiler flags | both | vert, frag |
| 7 | target environment | both | vert, frag |
| 8 | compiler identity | both | vert, frag |
| 9 | nothing | none (Cabal: up to date) | none |
| 10 | fingerprint hand-edited, no regeneration | both, then refused | none |
| 11 | fingerprint regenerated | none | none |
| 12 | wrapper removed | fragment, then refused | none |
| 13 | wrapper substituted | fragment, then refused | none |

- An unaffected shader is not compiled again. In steps 3 and 4 the vertex half
  is left alone, and in step 5 the fragment half is.
- The generator refuses a removed or substituted wrapper, and so does the
  splice when it runs anyway. Both name the wrapper and the native manifest
  identity it was held to. A competing `glslangValidator` first on `PATH` never
  ran (step 14).
- The source distribution was made before any edit. It carries the adapter,
  the fingerprint generator, the verification source, both includes and the
  tracked fixture fingerprint, and no generated one (step 15). Built from its
  tarballs alone, in two different extraction directories, it embeds the same
  bytes both times: vertex `47e12a96…`, fragment `0faa1f66…`. These are the
  same digests the checkout's own build prints (steps 16 and 17).

## Captured transcript

```text
revision: 3f2d190bc6b77f757cae43758272de3c398adb95
native prefix: <prefix>
provisioned wrapper: <prefix>/vulkan/bin/glslangValidator
pinned compiler: /usr/local/bin/glslang (7167bc1261b1a54268ccdb1e57cee3128b198a453fc4c6243925c7bd2484baba)

## 1. Cold build
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint written (glslang 15.0.0-fixture-a 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.3, flags -V, native manifest 89e2ff0b97ed)
  recompiled Test.Shader.Fragment 
  recompiled Test.Shader.Vertex 
  compiler: compile frag verification.frag
  compiler: compile vert shader.vert

## 2. Warm rebuild, nothing changed
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint unchanged (glslang 15.0.0-fixture-a 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.3, flags -V, native manifest 89e2ff0b97ed)
  cabal: up to date
  compiler: not invoked

## 3. The fragment shader's source file changes
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint unchanged (glslang 15.0.0-fixture-a 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.3, flags -V, native manifest 89e2ff0b97ed)
  recompiled Test.Shader.Fragment [test/shaders/verification.frag changed]
  compiler: compile frag verification.frag

## 4. The fragment shader's transitive include changes
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint unchanged (glslang 15.0.0-fixture-a 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.3, flags -V, native manifest 89e2ff0b97ed)
  recompiled Test.Shader.Fragment [test/shaders/include/verification_layout.glsl changed]
  compiler: compile frag verification.frag

## 5. The interpolated Haskell constant changes
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint unchanged (glslang 15.0.0-fixture-a 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.3, flags -V, native manifest 89e2ff0b97ed)
  recompiled Test.Shader.Vertex [Test.Shader.Constants changed]
  compiler: compile vert shader.vert

## 6. The compiler flags change (-V to -V100)
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint written (glslang 15.0.0-fixture-a 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.3, flags -V100, native manifest 89e2ff0b97ed)
  recompiled Test.Shader.Fragment [shaders/toolchain.fingerprint changed]
  recompiled Test.Shader.Vertex [shaders/toolchain.fingerprint changed]
  compiler: compile frag verification.frag
  compiler: compile vert shader.vert

## 7. The target environment changes (vulkan1.3 to vulkan1.2)
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint written (glslang 15.0.0-fixture-a 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.2, flags -V100, native manifest 89e2ff0b97ed)
  recompiled Test.Shader.Fragment [Hetoimasia.GPU.Vulkan.Native.Shader changed]
  recompiled Test.Shader.Vertex [Hetoimasia.GPU.Vulkan.Native.Shader changed]
  compiler: compile frag verification.frag
  compiler: compile vert shader.vert

## 8. The compiler identity changes (fixture a to fixture b)
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint written (glslang 15.0.0-fixture-b 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.2, flags -V100, native manifest 7f44f12245d7)
  recompiled Test.Shader.Fragment [shaders/toolchain.fingerprint changed]
  recompiled Test.Shader.Vertex [shaders/toolchain.fingerprint changed]
  compiler: compile frag verification.frag
  compiler: compile vert shader.vert

## 9. Warm rebuild after the identity change, nothing changed
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint unchanged (glslang 15.0.0-fixture-b 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.2, flags -V100, native manifest 7f44f12245d7)
  cabal: up to date
  compiler: not invoked

## 10. The fingerprint's recorded compiler identity is edited, and the build runs without regenerating it
  recompiled Test.Shader.Fragment [shaders/toolchain.fingerprint changed]
  recompiled Test.Shader.Vertex [shaders/toolchain.fingerprint changed]
  build failed (exit 1); its diagnostic:
    • the shader toolchain is refused: the fingerprint at shaders/toolchain.fingerprint no longer describes the toolchain: glslang is now 15.0.0-fixture-b, not the recorded 15.0.0-fixture-c
    glslangValidator wrapper: <scratch>/fixture/vulkan/bin/glslangValidator
    native manifest: <scratch>/fixture/hetoimasia-native-manifest.json (expected identity 7f44f12245d728578aa32843b5fb47c7ca7ddffda303b56248fa3527d13a31b6)
    No other glslangValidator is used. Regenerate the fingerprint from the provisioned prefix with
  compiler: not invoked

## 11. The generator restores the fingerprint; nothing is recompiled
  generator: shader fingerprint: <scratch>/tree/packages/gpu-vulkan/native/shaders/toolchain.fingerprint written (glslang 15.0.0-fixture-b 7167bc1261b1 behind <scratch>/fixture/vulkan/bin/glslangValidator, target vulkan1.2, flags -V100, native manifest 7f44f12245d7)
  cabal ran GHC; no shader module recompiled
  compiler: not invoked

## 12. The wrapper is removed, with a competing glslangValidator first on PATH
  generator: hetoimasia-shader-fingerprint: the shader toolchain is refused: no glslangValidator wrapper at <scratch>/fixture/vulkan/bin/glslangValidator
  generator:   glslangValidator wrapper: <scratch>/fixture/vulkan/bin/glslangValidator
  generator:   native manifest: <scratch>/fixture/hetoimasia-native-manifest.json (expected identity 7f44f12245d728578aa32843b5fb47c7ca7ddffda303b56248fa3527d13a31b6)
  generator:   No other glslangValidator is used. Regenerate the fingerprint from the provisioned prefix with
  generator:   `bash tools/vulkan-proof/run-shaders.sh`, or see packages/gpu-vulkan/native/README.md.
  generator refused (exit 1)
  recompiled Test.Shader.Fragment [test/shaders/verification.frag changed]
  build failed (exit 1); its diagnostic:
    • the shader toolchain is refused: no glslangValidator wrapper at <scratch>/fixture/vulkan/bin/glslangValidator
    glslangValidator wrapper: <scratch>/fixture/vulkan/bin/glslangValidator
    native manifest: <scratch>/fixture/hetoimasia-native-manifest.json (expected identity 7f44f12245d728578aa32843b5fb47c7ca7ddffda303b56248fa3527d13a31b6)
    No other glslangValidator is used. Regenerate the fingerprint from the provisioned prefix with
  compiler: not invoked

## 13. The wrapper is substituted, with the manifest left as it was
  generator: hetoimasia-shader-fingerprint: the shader toolchain is refused: the glslangValidator wrapper at <scratch>/fixture/vulkan/bin/glslangValidator hashes to 7ac2568b7c275f1d2be3ad78a133e4b374fe121a73b92a9895ee4ea07253636b, not the recorded 51c099a72967c4473ec4ef30b2f4e7db72fbf941efe81e07eac1043e4c08d5ec
  generator:   glslangValidator wrapper: <scratch>/fixture/vulkan/bin/glslangValidator
  generator:   native manifest: <scratch>/fixture/hetoimasia-native-manifest.json (expected identity 7f44f12245d728578aa32843b5fb47c7ca7ddffda303b56248fa3527d13a31b6)
  generator:   No other glslangValidator is used. Regenerate the fingerprint from the provisioned prefix with
  generator:   `bash tools/vulkan-proof/run-shaders.sh`, or see packages/gpu-vulkan/native/README.md.
  generator refused (exit 1)
  recompiled Test.Shader.Fragment [test/shaders/verification.frag changed]
  build failed (exit 1); its diagnostic:
    • the shader toolchain is refused: the glslangValidator wrapper at <scratch>/fixture/vulkan/bin/glslangValidator hashes to 7ac2568b7c275f1d2be3ad78a133e4b374fe121a73b92a9895ee4ea07253636b, not the recorded 51c099a72967c4473ec4ef30b2f4e7db72fbf941efe81e07eac1043e4c08d5ec
    glslangValidator wrapper: <scratch>/fixture/vulkan/bin/glslangValidator
    native manifest: <scratch>/fixture/hetoimasia-native-manifest.json (expected identity 7f44f12245d728578aa32843b5fb47c7ca7ddffda303b56248fa3527d13a31b6)
    No other glslangValidator is used. Regenerate the fingerprint from the provisioned prefix with
  compiler: not invoked

## 14. The competing compiler on PATH
  never ran

## 15. The package's source distribution, made before the steps above edited anything
  hetoimasia-gpu-vulkan-native-0.1.0.0/fingerprint/Main.hs
  hetoimasia-gpu-vulkan-native-0.1.0.0/shader-toolchain/Hetoimasia/GPU/Vulkan/Native/Shader/
  hetoimasia-gpu-vulkan-native-0.1.0.0/shader-toolchain/Hetoimasia/GPU/Vulkan/Native/Shader/Json.hs
  hetoimasia-gpu-vulkan-native-0.1.0.0/shader-toolchain/Hetoimasia/GPU/Vulkan/Native/Shader/Toolchain.hs
  hetoimasia-gpu-vulkan-native-0.1.0.0/test/fixtures/foreign.fingerprint
  hetoimasia-gpu-vulkan-native-0.1.0.0/test/shaders/include/verification_interface.glsl
  hetoimasia-gpu-vulkan-native-0.1.0.0/test/shaders/include/verification_layout.glsl
  hetoimasia-gpu-vulkan-native-0.1.0.0/test/shaders/verification.frag

## 16. Build and test from the distribution, extracted as 'first'
  generator: shader fingerprint: <scratch>/extracted-first/nested-first/hetoimasia-gpu-vulkan-native-0.1.0.0/shaders/toolchain.fingerprint written (glslang 15.0.0 7167bc1261b1 behind <prefix>/vulkan/bin/glslangValidator, target vulkan1.3, flags -V, native manifest 0b4f970368ba)
  Test suite shader-tests: RUNNING...
  embedded vertex SPIR-V: 824 bytes, sha256 47e12a96b5a5b173aaa6fdb7e5575e63db351a85f9d43164d3658fbf3d910a10
  embedded fragment SPIR-V: 828 bytes, sha256 0faa1f66b4b5e02865c4a292a6aa297c1b468aed36339caeefb8afd3a63a67ca
  14 examples, 0 failures
  Test suite shader-tests: PASS

## 17. Build and test from the distribution, extracted as 'second'
  generator: shader fingerprint: <scratch>/extracted-second/nested-second/hetoimasia-gpu-vulkan-native-0.1.0.0/shaders/toolchain.fingerprint written (glslang 15.0.0 7167bc1261b1 behind <prefix>/vulkan/bin/glslangValidator, target vulkan1.3, flags -V, native manifest 0b4f970368ba)
  Test suite shader-tests: RUNNING...
  embedded vertex SPIR-V: 824 bytes, sha256 47e12a96b5a5b173aaa6fdb7e5575e63db351a85f9d43164d3658fbf3d910a10
  embedded fragment SPIR-V: 828 bytes, sha256 0faa1f66b4b5e02865c4a292a6aa297c1b468aed36339caeefb8afd3a63a67ca
  14 examples, 0 failures
  Test suite shader-tests: PASS
```
