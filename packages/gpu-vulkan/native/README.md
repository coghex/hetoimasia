# Native Vulkan backend

Buildable package: `hetoimasia-gpu-vulkan-native`, in `packages/gpu-vulkan/native`.

The package that owns the Vulkan binding, the handles and the calls: VK-6's
diagnostic messengers, VK-9's shader adapter, and VK-7's roots. It depends on no
window system: a surface reaches it as a 64-bit handle and the action that
destroys it.

- `Hetoimasia.GPU.Vulkan.Native.Profile` is the runtime profile as pure
  decisions: what the instance asks for (`planInstance`), which physical device
  and queue family the session takes against a bootstrap surface
  (`selectDevice`), and why a later surface is refused (`TargetRejection`).
  It names no binding type, and its examples hold its extension names to the
  binding's.
- `Hetoimasia.GPU.Vulkan.Native.Roots` owns one session's instance, explicit
  messenger, shared device and per-target surface records, keyed by the GPU
  model's `TargetId`, over an open native layer (`RootOps`). It creates parent
  before child, destroys child before parent and refuses rather than reorders,
  never retries an uncertain destruction, and latches device loss. It makes no
  native call of its own.
- `Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan` is the production native layer:
  the binding's own calls, reporting into a diagnostic capture.

- `Hetoimasia.GPU.Vulkan.Native.Diagnostics` builds the two debug-utils
  messengers an instance can have — the one chained into `VkInstanceCreateInfo`
  and the explicit one — from one
  [diagnostic capture](../diagnostics/README.md). Both register
  `captureMessengerCallback`, a C function in `cbits/` with Vulkan's exact
  callback type that hands its arguments to the diagnostics package's C
  producer, with the capture's storage as user data. No Haskell is reachable
  from it, so a Vulkan call made through a genuine `unsafe` import can report
  through it.
- `destroyInstanceQuiesced` destroys an instance whose messengers deliver into a
  capture and returns the `Quiesced` evidence the diagnostic lifetime demands:
  `vkDestroyInstance` is the last call that can invoke the callback, so its
  return is what establishes that none can still run.
- `cbits/hetoimasia_vulkan_native.c` is the one translation unit that sees both
  the diagnostics package's header and the Vulkan headers, and it asserts at
  compile time that the diagnostics package's layout mirror is the headers'
  layout.
- `nativeFfiConfiguration` records this package's own use of the binding: the
  binding-wide flags `cabal.project.vulkan` constrains, the C-only capture
  callback, no Haskell callbacks, and no `unsafe` imports yet — the audited
  recording subset is VK-11's. The roots add no recording or submission.

It is listed only in `cabal.project.vulkan`, beside its local dependency closure
— the diagnostics package, `hetoimasia-gpu-vulkan-model`, the foundation, and
the test-only support library its shader suite uses — so neither ordinary
project resolves the binding, the Vulkan headers or a loader. The only things
that build it are `tools/vulkan-proof/run-shaders.sh` and
`tools/vulkan-proof/run-proof.sh`, which runs the former first; both point Cabal
at the provisioned loader and headers. Its headless suite, `native-tests`
(`test/RootsMain.hs`), runs the profile's and the roots' examples over a
stand-in native layer through `run-proof.sh --headless`, beside the shader
suite; its native cases run in the proof harness until VK-8 moves them into a
package-native fixture — see [the proof harness](../../../tools/vulkan-proof/README.md).

## Shaders

`Hetoimasia.GPU.Vulkan.Native.Shader` is VK-9's adapter: GLSL compiled while
the Haskell build runs, embedded as a strict `ByteString` of SPIR-V (D-11, P-9).
Source is written with `glsl`, `vulkan-utils`' interpolating quasiquoter —
`$name` or `${name}` is replaced by the `show` of a Haskell value defined in
another module, so shared constants and layout locations are written once — and
compiled by a splice:

```haskell
shadeRed ∷ ByteString
shadeRed = $(fragmentShader [glsl|
  #version 450
  layout(location = ${colourLocation}) out vec4 colour;
  void main() { colour = vec4(1, 0, 0, 1); }
|])

shadeBlue ∷ ByteString
shadeBlue = $(fragmentShaderFile "shaders/blue.frag") -- relative to the package root
```

`vertexShader`, `fragmentShader` and `computeShader` take source text;
`vertexShaderFile`, `fragmentShaderFile` and `computeShaderFile` take a file,
whose `#include`s are resolved relative to it. `compileShaderQ` and
`compileShaderFileQ` take the target environment, the stage and, for source
text, include directories explicitly. The target is `vulkan13` (SPIR-V 1.6),
the only one D-12 allows. Compiling needs no display, device, loader session or
consent.

Unlike the binding's own `vert` and `frag` quoters, which run whatever
`glslangValidator` is on `PATH` for no stated target and register nothing, a
splice here:

- **compiles only with the provisioned compiler.** It reads the package's
  toolchain fingerprint, `shaders/toolchain.fingerprint`, and checks it against
  the world as it is now: the wrapper it names must exist, be executable, hash
  to what the native manifest records and answer `--hetoimasia-identity` for the
  recorded compiler, whose own digest must match; the native manifest must hash
  to the identity the fingerprint recorded; and `HETOIMASIA_GLSLANG`, when set,
  must name that wrapper. Anything else is refused, naming the wrapper and the
  manifest identity it was held to, and no other `glslangValidator` is looked
  for. The wrapper runs with `PATH` set to its own directory ahead of
  `/usr/bin:/bin` and `LC_ALL=C`, not the environment the build inherited.
- **registers its rebuild inputs.** `addDependentFile` gets the fingerprint, the
  source file when there is one, and every include the compiler's depfile
  names, transitively. An include resolved outside the package root is refused,
  because a source distribution would not carry it. The package lists every one
  of those files as a source file — `test/shaders/*.frag`,
  `test/shaders/**/*.glsl` and `**/*.fingerprint` — because Cabal decides
  whether to run GHC at all from the files a package lists and never from the
  ones a splice registers. A package that splices shaders of its own needs the
  same globs and its own fingerprint.
- **reports failure through the build.** A shader that does not compile fails
  the module, naming the stage, the Haskell file and splice position, the
  module, the source, the target and the compiler's own `ERROR:` lines. A
  compiler warning is a build warning, so `-Werror` makes it an error.

The same compile is callable at run time, which is how its diagnostics are
tested: `Hetoimasia.GPU.Vulkan.Native.Shader.Toolchain`, in the package's
private `shader-toolchain` library, holds `loadToolchain`, `compileShader` and
the fingerprint. That library depends on neither the binding nor Template
Haskell.

### The fingerprint

GHC does not notice an executable changing because a splice once ran it, so the
compiler's identity is written into a file before every build.
`hetoimasia-shader-fingerprint`, this package's executable, does it:

```bash
hetoimasia-shader-fingerprint --output packages/gpu-vulkan/native/shaders/toolchain.fingerprint
```

It takes the wrapper from `HETOIMASIA_GLSLANG` and the native manifest from
beside `HETOIMASIA_VULKAN_PREFIX` — both exported by
`python3 tools/native/native.py prepare` — or from `--glslang` and
`--native-manifest`. It refuses unless the manifest records that wrapper, the
wrapper's bytes and the compiler's are the recorded ones, and the wrapper
answers for the recorded compiler. It then writes one `key value` line per
field: the format, the target environment and the flags from the adapter's own
declarations, the wrapper and its SHA-256, the compiler's version, path and
SHA-256, and the native manifest's path and identity (its SHA-256, as
`native.py` computes it). The file is rewritten only when a field changed, so an
unchanged toolchain leaves every module up to date, and a changed one
recompiles exactly the modules that splice shaders.

The fingerprint names this machine's prefix, so Git ignores it. A glob that
matches nothing makes `cabal sdist` fail, so the tracked fixture
`test/fixtures/foreign.fingerprint` — a fingerprint for a prefix that does not
exist, which the suite requires to be refused — keeps `**/*.fingerprint`
non-empty. A distribution made from a tree that has generated a fingerprint
carries it; it is never trusted there, because the generator rewrites it and
every splice checks it.

### Building and testing

```bash
bash tools/vulkan-proof/run-shaders.sh
```

runs `native.py prepare`, the fingerprint generator and
`cabal test hetoimasia-gpu-vulkan-native:shader-tests`, with the proof's build
directory and Cabal flags. Arguments are forwarded to the suite. It needs no
display, device or consent, and `run-proof.sh` runs it before the proof, which
is the route that executes the suite until VK-8's `test.vulkan-headless`
exists. The suite first prints the embedded pair's sizes and SHA-256 digests,
then checks that the embedded SPIR-V is version 1.6, that the interpolated
constant and location reached the compiled vertex module, that the fragment
file's transitive include was resolved, that the runtime entry compiles that
file to the embedded bytes and reports all three inputs, which fingerprints are
refused, and — by compiling a client module outside the package with the
package's fingerprint — that a broken splice fails the build with its module,
position, stage and compiler message.

`tools/vulkan-proof/shader-evidence.sh` is the local verification of what one
build cannot show: which modules recompile, and which shader compilations run,
when a source, an include, an interpolated constant, the flags, the target or
the compiler's identity changes; that an edited fingerprint is refused and a
regenerated one recompiles nothing; that a removed or substituted wrapper is
refused while a competing `glslangValidator` first on `PATH` never runs; and
that the source distribution builds, from two extraction directories, to the
same embedded bytes. Its retained transcript is
[docs/vulkan/shader-rebuilds-macos.md](../../../docs/vulkan/shader-rebuilds-macos.md).
The Linux proof route's run of the suite, with the compiler identity it named,
is retained as [docs/vulkan/linux-vk9.md](../../../docs/vulkan/linux-vk9.md).

[`docs/vulkan_diagnostics.md`](../../../docs/vulkan_diagnostics.md) is the
messengers' contract in prose, and [`docs/gpu_backend.md`](../../../docs/gpu_backend.md)
the roots'.
