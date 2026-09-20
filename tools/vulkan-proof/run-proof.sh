#!/usr/bin/env bash
# Run the VK-2 native Vulkan compatibility proof against this platform's pinned
# loader, driver, and validation layers.
#
# This is the only thing that builds `tools/vulkan-proof`. It selects the
# repository's third project file, `cabal.project.vulkan`, which is the only one
# that names that package — so an ordinary `cabal build all`, with either of the
# other two project files, neither resolves nor links the Vulkan binding.
#
# The environment it establishes is project-local and reaches one child process:
# an absolute `VK_DRIVER_FILES` manifest path, a controlled `VK_LAYER_PATH`, and
# the private GLFW prefix on `PKG_CONFIG_PATH`. It edits no shell profile,
# installs nothing, and changes nothing another project uses. The harness itself
# clears conflicting discovery overrides it finds and records which, so the
# pinned selection cannot be quietly overridden from outside.
#
# The proof opens a visible window and presents to it, so it needs the same
# per-run consent `glfw-native-tests` needs. It supplies none: on macOS the
# human's `HETOIMASIA_NATIVE_SESSION=desktop` must already be on the invocation,
# and on Linux `tools/display/x11.sh` supplies its own for the isolated display
# it starts. See AGENTS.md and docs/glfw.md.
#
#   HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan-proof/run-proof.sh
#   bash tools/display/x11.sh -- bash tools/vulkan-proof/run-proof.sh   # Linux
#
# Every argument is forwarded to the harness as a test option. `--headless`
# selects the release decision's own examples and nothing else: they are pure,
# open no window, initialize no GLFW, and read no consent, so that run needs
# none and starts no session.
#
#   bash tools/vulkan-proof/run-proof.sh --headless
#
# Exit status: the proof's own; 2 for a configuration diagnostic. See
# docs/vulkan_compatibility_record.md.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

set -a
# shellcheck disable=SC1091
. "$root/tools/ci-image/toolchain.pin"
# shellcheck disable=SC1091
. "$root/tools/toolchain/binding.pin"
# shellcheck disable=SC1091
. "$root/tools/vulkan-proof/environment.pin"
set +a

refuse() {
  echo "run-proof: $1" >&2
  exit 2
}

# The toolchain identity. A proof run on some other compiler proves nothing
# about the one this repository pins, so it is refused rather than reported.
actual_ghc="$(ghc --numeric-version)"
actual_cabal="$(cabal --numeric-version)"
[ "$actual_ghc" = "$GHC_VERSION" ] || refuse "ghc on PATH is $actual_ghc, but this repository pins $GHC_VERSION"
[ "$actual_cabal" = "$CABAL_VERSION" ] || refuse "cabal on PATH is $actual_cabal, but this repository pins $CABAL_VERSION"

# The binding flags the project file constrains must be the ones the toolchain
# record qualified. Restating them in two files is only safe if one checks the
# other.
[ "$VULKAN_FLAG_SAFE_FOREIGN_CALLS" = "on" ] || refuse "binding.pin turns safe-foreign-calls off; the proof's Haskell debug callback requires it"
[ "$VULKAN_FLAG_DARWIN_LIB_DIRS" = "off" ] || refuse "binding.pin turns darwin-lib-dirs on; the proof names its own loader prefix"
grep -q '^    vulkan +safe-foreign-calls,$' "$root/cabal.project.vulkan" \
  || refuse "cabal.project.vulkan does not constrain vulkan +safe-foreign-calls"
grep -q '^    vulkan -darwin-lib-dirs$' "$root/cabal.project.vulkan" \
  || refuse "cabal.project.vulkan does not constrain vulkan -darwin-lib-dirs"

# The private GLFW prefix, exactly the one every other native build here uses.
prefix_default="${XDG_CACHE_HOME:-$HOME/.cache}/hetoimasia/native/glfw"
glfw_prefix="${HETOIMASIA_NATIVE_PREFIX:-$prefix_default}"
python3 "$root/tools/native/native.py" check --prefix "$glfw_prefix" >/dev/null \
  || refuse "the private GLFW prefix at $glfw_prefix is not what this configuration builds; rebuild it with: python3 tools/native/native.py build --prefix $glfw_prefix"
export PKG_CONFIG_PATH="$glfw_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# The platform's loader, driver, and layers.
case "$(uname -s)" in
  Darwin)
    loader_prefix="${HETOIMASIA_VULKAN_PREFIX:-$MACOS_VULKAN_PREFIX}"
    driver_manifest="${HETOIMASIA_VULKAN_DRIVER_MANIFEST:-$MACOS_VULKAN_DRIVER_MANIFEST}"
    layer_path="${HETOIMASIA_VULKAN_LAYER_PATH:-$MACOS_VULKAN_LAYER_PATH}"
    ;;
  Linux)
    # The binding finds the loader through `pkgconfig-depends: vulkan` here, so
    # no prefix is named; the container's loader development package is the
    # whole configuration.
    loader_prefix=""
    driver_manifest="${HETOIMASIA_VULKAN_DRIVER_MANIFEST:-$LINUX_VULKAN_DRIVER_MANIFEST}"
    layer_path="${HETOIMASIA_VULKAN_LAYER_PATH:-$LINUX_VULKAN_LAYER_PATH}"
    ;;
  *)
    refuse "$(uname -s) is not a platform this proof is qualified on"
    ;;
esac

case "$driver_manifest" in
  /*) ;;
  *) refuse "the pinned driver manifest $driver_manifest is not an absolute path" ;;
esac
# A refusal here has to say what the platform does offer. The pin names one
# manifest deliberately, and the useful question when it is absent is which
# other driver this machine installed — not whether to fall back to one.
if [ ! -r "$driver_manifest" ]; then
  available="$(ls -1 "$(dirname "$driver_manifest")" 2>/dev/null | tr '\n' ' ')"
  refuse "the pinned driver manifest $driver_manifest is not readable; $(dirname "$driver_manifest") holds: ${available:-nothing}"
fi
if [ ! -d "$layer_path" ]; then
  refuse "the pinned layer directory $layer_path does not exist"
fi

# On macOS the binding is given no search path at all once `darwin-lib-dirs` is
# off, and `vulkan-utils` makes GHC dlopen the compiled binding while compiling,
# so the prefix has to supply both a link path and an rpath. This is generated
# rather than committed because the prefix is a property of the machine, not of
# the repository; `<project-file>.local` is where Cabal reads exactly that.
local_project="$root/cabal.project.vulkan.local"
if [ -n "$loader_prefix" ]; then
  [ -d "$loader_prefix/lib" ] || refuse "no Vulkan loader prefix at $loader_prefix (set HETOIMASIA_VULKAN_PREFIX)"
  cat > "$local_project" <<EOF
-- Generated by tools/vulkan-proof/run-proof.sh; not committed. It names this
-- machine's Vulkan loader prefix, which the repository cannot know.
package vulkan
  extra-lib-dirs: $loader_prefix/lib
  extra-include-dirs: $loader_prefix/include
  ghc-options: -optl-Wl,-rpath,$loader_prefix/lib

package hetoimasia-vulkan-proof
  extra-lib-dirs: $loader_prefix/lib
  extra-include-dirs: $loader_prefix/include
  ghc-options: -optl-Wl,-rpath,$loader_prefix/lib
EOF
else
  rm -f "$local_project"
fi

# The exact identity of the sources under proof, computed from their content.
# A revision is a convenience and can be inexact — a working tree can be dirty,
# and the Linux container has no checkout at all — so the record is pinned by
# this instead, and a reader can recompute it with the same command.
HETOIMASIA_PROOF_SOURCE_DIGEST="$(
  python3 - "$root" <<'DIGEST'
import hashlib, os, sys

root = sys.argv[1]
# Everything that decides what the proof is and how it is built, by directory
# rather than by file, because naming files individually is how an input gets
# left out: `tools/native` holds both the GLFW pin and the recipe that builds
# from it, and two different recipes must not be able to produce one digest.
#
# This set is exactly what the Linux container copies into /work, so the digest
# computed there and the one computed from a checkout describe the same inputs
# and can be compared. Generated Python and macOS metadata are excluded because
# they are not inputs and do not exist identically in both places.
roots = ["tools/vulkan-proof", "tools/native", "tools/display"]
files = ["cabal.project.vulkan", "cabal.project.common",
         "tools/toolchain/binding.pin", "tools/ci-image/toolchain.pin"]

def carried(path):
    parts = path.split(os.sep)
    return "__pycache__" not in parts and not path.endswith(".pyc") and ".DS_Store" not in parts

paths = set(files)
for directory in roots:
    for base, _, names in os.walk(os.path.join(root, directory)):
        for name in names:
            full = os.path.join(base, name)
            relative = os.path.relpath(full, root)
            if carried(relative):
                paths.add(relative)

overall = hashlib.sha256()
for path in sorted(paths):
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        continue
    with open(full, "rb") as handle:
        content = hashlib.sha256(handle.read()).hexdigest()
    overall.update(path.encode("utf-8") + b"\0" + content.encode("ascii") + b"\n")
print(overall.hexdigest())
DIGEST
)"
export HETOIMASIA_PROOF_SOURCE_DIGEST
[ -n "$HETOIMASIA_PROOF_SOURCE_DIGEST" ] || refuse "the source digest could not be computed, so a record could not identify the sources it came from"

# What this run can be attributed to. A retained record that does not name the
# revision it was produced from cannot be told apart later from one taken
# against different code, so it is derived here rather than left to prose. The
# Linux container bakes the value in instead, because there is no checkout
# inside it to ask.
if [ -z "${HETOIMASIA_PROOF_REVISION:-}" ]; then
  if source_revision="$(git -C "$root" rev-parse HEAD 2>/dev/null)"; then
    if ! git -C "$root" diff --quiet HEAD -- \
      "$root/tools/vulkan-proof" "$root/cabal.project.vulkan" \
      "$root/cabal.project.common" "$root/tools/toolchain/binding.pin" 2>/dev/null; then
      source_revision="$source_revision (dirty)"
    fi
  else
    source_revision="unknown"
  fi
  export HETOIMASIA_PROOF_REVISION="$source_revision"
fi

export VK_DRIVER_FILES="$driver_manifest"
export VK_LAYER_PATH="$layer_path"

record="${HETOIMASIA_VULKAN_PROOF_RECORD:-}"
if [ -n "$record" ]; then
  export HETOIMASIA_VULKAN_PROOF_RECORD="$record"
fi

echo "run-proof: ghc $actual_ghc, cabal $actual_cabal"
echo "run-proof: repository revision $HETOIMASIA_PROOF_REVISION"
echo "run-proof: source digest $HETOIMASIA_PROOF_SOURCE_DIGEST"
echo "run-proof: VK_DRIVER_FILES=$VK_DRIVER_FILES"
echo "run-proof: VK_LAYER_PATH=$VK_LAYER_PATH"
echo "run-proof: GLFW prefix $glfw_prefix"
[ -n "$loader_prefix" ] && echo "run-proof: loader prefix $loader_prefix"

# What the caller asked the harness itself to do. The harness owns `--headless`
# and takes it out of the arguments before Hspec's runner sees them, so an
# Hspec selector such as `--match` passes through here unchanged.
options=()
for argument in "$@"; do
  options+=("--test-option=$argument")
done

cd "$root"
exec cabal test \
  --project-file=cabal.project.vulkan \
  --builddir=dist-vulkan-proof \
  --test-show-details=direct \
  hetoimasia-vulkan-proof:vulkan-proof \
  ${options[@]+"${options[@]}"}
