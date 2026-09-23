#!/usr/bin/env bash
# Run the native Vulkan compatibility proof against the loader, driver, and
# validation layers the private native prefix was provisioned with.
#
# This is the only thing that builds `tools/vulkan-proof`. It selects the
# repository's third project file, `cabal.project.vulkan`, which is the only one
# that names that package — so an ordinary `cabal build all`, with either of the
# other two project files, neither resolves nor links the Vulkan binding.
#
# Every input comes from one place: `tools/native/native.py prepare`, which
# refuses the prefix unless it is exactly what this configuration provisions and
# then prints the discovery that prefix owns. Nothing here names a machine path,
# reads `tools/vulkan-proof/environment.pin` — which VK-4 retired — or generates
# a project file; the loader is found through the prefix's own package
# description and, where a declaration cannot read one, through link and include
# directories passed to Cabal on this one command line.
#
# The environment it establishes is project-local and reaches one child process:
# an absolute `VK_DRIVER_FILES` manifest path, a `VK_LAYER_PATH` holding exactly
# the qualified layer, and the prefix's two package descriptions on
# `PKG_CONFIG_PATH`. It edits no shell profile, installs nothing, and changes
# nothing another project uses. The harness itself clears conflicting discovery
# overrides it finds and records which, so the provisioned selection cannot be
# quietly overridden from outside.
#
# The loader itself is a runtime dependency (`libvulkan.so.1` on Linux), so a
# runtime library search override could load an ABI-compatible substitute after
# `prepare` verified the pinned file. This refuses any such variable before its
# first check rather than clearing it, and the harness then requires the image
# its entry point was resolved from to be `HETOIMASIA_VULKAN_QUALIFIED_LOADER`,
# the loader `prepare` names.
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
set +a

refuse() {
  echo "run-proof: $1" >&2
  exit 2
}

# A runtime library search override lets the dynamic linker answer the
# loader's soname with some other file after `prepare` has verified the pinned
# one, and an ABI-compatible substitute would then be proved in its place. Each
# is refused rather than cleared, so a run never proves something other than
# what its caller's environment asked for without saying so. The harness also
# holds the loader it actually loaded to the recorded file, which catches what
# this list cannot name. macOS strips the DYLD_ variables before a protected
# binary such as /bin/bash runs, so there they are refused wherever they survive.
for variable in LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT \
  DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES \
  DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_IMAGE_SUFFIX; do
  if value="$(printenv "$variable")"; then
    refuse "$variable is set ($value); a runtime library search override can load a Vulkan loader other than the one the prefix qualified, so unset it and run again"
  fi
done

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

# Nothing generates a project file any more, and a leftover one from before
# VK-4 would quietly put the former SDK paths back into every build here. Cabal
# reads `<project-file>.local` silently, so its presence is diagnosed rather
# than tolerated, and retiring it is the reader's deliberate act: this harness
# does not delete a file it did not write.
local_project="$root/cabal.project.vulkan.local"
if [ -e "$local_project" ]; then
  refuse "$local_project exists; VK-4 provisions the loader into the native prefix and generates no project file, so this one is obsolete configuration that would override the provisioned prefix. Delete it and run again."
fi

# The private native prefix: the GLFW archive and the Vulkan runtime beside it,
# exactly the ones every other native build here uses. `prepare` refuses a
# prefix that is not what this configuration provisions, stamps the build
# directory so nothing linked against another native configuration is reused,
# and prints the discovery the prefix owns — which is where every Vulkan path
# below comes from.
prefix_default="${XDG_CACHE_HOME:-$HOME/.cache}/hetoimasia/native/glfw"
native_prefix="${HETOIMASIA_NATIVE_PREFIX:-$prefix_default}"
case "$(uname -s)" in
  Darwin|Linux) ;;
  *) refuse "$(uname -s) is not a platform this proof is qualified on" ;;
esac
discovery="$(python3 "$root/tools/native/native.py" prepare --prefix "$native_prefix" --build-dir "$root/dist-vulkan-proof")" \
  || refuse "the private native prefix at $native_prefix is not what this configuration provisions; the diagnosis above says what differs, and a prefix that is simply out of date is rebuilt with: python3 tools/native/native.py build --prefix $native_prefix"
eval "$discovery"

[ -n "${VK_DRIVER_FILES:-}" ] || refuse "the native prefix named no driver manifest"
[ -n "${VK_LAYER_PATH:-}" ] || refuse "the native prefix named no layer directory"
[ -r "$VK_DRIVER_FILES" ] || refuse "the provisioned driver manifest $VK_DRIVER_FILES is not readable"
[ -d "$VK_LAYER_PATH" ] || refuse "the provisioned layer directory $VK_LAYER_PATH does not exist"

# The exact identity of the sources under proof, computed from their content.
# A revision is a convenience and can be inexact — a working tree can be dirty,
# and a checkout mounted into a container is not one `git` will speak for — so
# the record is pinned by this instead, and a reader can recompute it with the
# same command.
HETOIMASIA_PROOF_SOURCE_DIGEST="$(
  python3 - "$root" <<'DIGEST'
import hashlib, os, sys

root = sys.argv[1]
# Everything that decides what the proof is and how it is built, by directory
# rather than by file, because naming files individually is how an input gets
# left out: `tools/native` holds both the GLFW pin and the recipe that builds
# from it, and two different recipes must not be able to produce one digest.
#
# Both platforms compute it from a checkout — Linux inside the published CI
# image with the candidate mounted, macOS from the worktree — so a digest taken
# on one can be compared with a digest taken on the other. Generated Python and
# macOS metadata are excluded because they are not inputs and do not exist
# identically in both places.
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

record="${HETOIMASIA_VULKAN_PROOF_RECORD:-}"
if [ -n "$record" ]; then
  export HETOIMASIA_VULKAN_PROOF_RECORD="$record"
fi

echo "run-proof: ghc $actual_ghc, cabal $actual_cabal"
echo "run-proof: repository revision $HETOIMASIA_PROOF_REVISION"
echo "run-proof: source digest $HETOIMASIA_PROOF_SOURCE_DIGEST"
echo "run-proof: VK_DRIVER_FILES=$VK_DRIVER_FILES"
echo "run-proof: VK_LAYER_PATH=$VK_LAYER_PATH"
echo "run-proof: native prefix $native_prefix"
echo "run-proof: Vulkan prefix $HETOIMASIA_VULKAN_PREFIX"
python3 "$root/tools/native/native.py" check --prefix "$native_prefix" | sed 's/^native:/run-proof:/'
"$HETOIMASIA_GLSLANG" --hetoimasia-identity | sed 's/^/run-proof: glslang wrapper reports /'


# What the caller asked the harness itself to do. The harness owns `--headless`
# and takes it out of the arguments before Hspec's runner sees them, so an
# Hspec selector such as `--match` passes through here unchanged.
options=()
for argument in "$@"; do
  options+=("--test-option=$argument")
done

# The loader's link and include directories are handed to Cabal here rather
# than written into a project file. The binding declares `extra-libraries:
# vulkan` on macOS with no directory to find it in, and the loader the prefix
# installed there carries an absolute install name, so this is the whole
# configuration a link needs: no rpath, no machine path, and nothing left on
# disk afterwards to go stale.
cd "$root"
exec cabal test \
  --project-file=cabal.project.vulkan \
  --builddir=dist-vulkan-proof \
  --extra-lib-dirs="$HETOIMASIA_VULKAN_LIBDIR" \
  --extra-include-dirs="$HETOIMASIA_VULKAN_INCLUDEDIR" \
  --test-show-details=direct \
  hetoimasia-vulkan-proof:vulkan-proof \
  ${options[@]+"${options[@]}"}
