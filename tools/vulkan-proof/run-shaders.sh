#!/usr/bin/env bash
# Build the native backend package's shaders against the provisioned compiler
# and run VK-9's shader contract suite.
#
# Shaders are GLSL compiled by Template Haskell while the package builds (see
# packages/gpu-vulkan/native/README.md). A splice can only notice that the
# compiler changed if something makes it run, and neither Cabal nor GHC runs a
# splice again because an executable it once invoked was replaced. So before
# Cabal decides anything is up to date, this:
#
#   1. asks `tools/native/native.py prepare` for the private native prefix,
#      which refuses a prefix whose wrapper, compiler, loader, driver or layer
#      is not the one recorded, and exports what the prefix provides —
#      HETOIMASIA_GLSLANG among it;
#   2. runs the package's own `hetoimasia-shader-fingerprint`, which checks the
#      wrapper against the native manifest and rewrites
#      `packages/gpu-vulkan/native/shaders/toolchain.fingerprint` only when the
#      toolchain changed; every splice registers that file, so a changed
#      toolchain recompiles exactly the modules that splice shaders;
#   3. builds and runs `hetoimasia-gpu-vulkan-native:shader-tests`.
#
# Nothing here opens a window, creates a device, starts a session or reads
# consent, so it needs no approval on any desktop. It edits no profile and
# changes no PATH but the one the compiler child is given, which the adapter
# itself decides. `tools/vulkan-proof/run-proof.sh` runs this first, so the
# proof route always executes the suite; it shares the proof's build directory
# and Cabal flags, so neither rebuilds what the other built.
#
#   bash tools/vulkan-proof/run-shaders.sh
#   bash tools/vulkan-proof/run-shaders.sh --match 'embedded verification pair'
#
# Every argument is forwarded to the suite as a test option.
#
# Exit status: the suite's own; 2 for a configuration diagnostic; 1 when the
# fingerprint generator refuses the toolchain.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

set -a
# shellcheck disable=SC1091
. "$root/tools/ci-image/toolchain.pin"
set +a

refuse() {
  echo "run-shaders: $1" >&2
  exit 2
}

actual_ghc="$(ghc --numeric-version)"
actual_cabal="$(cabal --numeric-version)"
[ "$actual_ghc" = "$GHC_VERSION" ] || refuse "ghc on PATH is $actual_ghc, but this repository pins $GHC_VERSION"
[ "$actual_cabal" = "$CABAL_VERSION" ] || refuse "cabal on PATH is $actual_cabal, but this repository pins $CABAL_VERSION"

local_project="$root/cabal.project.vulkan.local"
if [ -e "$local_project" ]; then
  refuse "$local_project exists; it would override the provisioned prefix for this build. Delete it and run again."
fi

prefix_default="${XDG_CACHE_HOME:-$HOME/.cache}/hetoimasia/native/glfw"
native_prefix="${HETOIMASIA_NATIVE_PREFIX:-$prefix_default}"
if ! discovery="$(python3 "$root/tools/native/native.py" prepare --prefix "$native_prefix" --build-dir "$root/dist-vulkan-proof")"; then
  # Name the manifest identity the wrapper is held to, so a refusal says what
  # was expected as well as what was found. No other compiler is looked for.
  manifest="$native_prefix/hetoimasia-native-manifest.json"
  identity="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$manifest" 2>/dev/null || echo unreadable)"
  refuse "the private native prefix at $native_prefix is not what this configuration provisions; the diagnosis above says what differs. Its native manifest $manifest has identity $identity; no other glslangValidator is used. A prefix that is simply out of date is rebuilt with: python3 tools/native/native.py build --prefix $native_prefix"
fi
eval "$discovery"
[ -n "${HETOIMASIA_GLSLANG:-}" ] || refuse "the native prefix named no glslangValidator wrapper"

# The same project, build directory and configure flags as the proof, so the
# two routes share one build of every package.
cabal_flags=(
  --project-file=cabal.project.vulkan
  --builddir=dist-vulkan-proof
  --extra-lib-dirs="$HETOIMASIA_VULKAN_LIBDIR"
  --extra-include-dirs="$HETOIMASIA_VULKAN_INCLUDEDIR"
)

echo "run-shaders: native prefix $native_prefix"
"$HETOIMASIA_GLSLANG" --hetoimasia-identity | sed 's/^/run-shaders: glslang wrapper reports /'

cd "$root"
cabal run -v1 "${cabal_flags[@]}" hetoimasia-gpu-vulkan-native:exe:hetoimasia-shader-fingerprint -- \
  --output "$root/packages/gpu-vulkan/native/shaders/toolchain.fingerprint" \
  | sed 's/^shader fingerprint:/run-shaders: shader fingerprint:/'

options=()
for argument in "$@"; do
  options+=("--test-option=$argument")
done

cabal test "${cabal_flags[@]}" \
  --test-show-details=direct \
  hetoimasia-gpu-vulkan-native:shader-tests \
  ${options[@]+"${options[@]}"}
