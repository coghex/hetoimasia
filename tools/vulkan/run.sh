#!/usr/bin/env bash
# Build, test, and run the Vulkan project's components against the loader,
# driver, and validation layer the private native prefix was provisioned with.
#
#   bash tools/vulkan/run.sh build COMPONENT...
#   bash tools/vulkan/run.sh test COMPONENT... [-- TEST-OPTION...]
#   bash tools/vulkan/run.sh native COMPONENT [-- ARGUMENT...]
#
# This is the one command that selects the repository's third project file,
# `cabal.project.vulkan` — the only one that names the native backend package,
# the window integration package, or turns the GLFW package's Vulkan interop
# component on — so an ordinary `cabal build all`, with either of the other two
# project files, neither resolves nor links the Vulkan binding. The validation
# groups `test.vulkan-headless` and `test.vulkan-native` run through it.
#
# `build` compiles the named components, and nothing else. `test.vulkan-native`
# runs it as its preparation stage, so the compilation is recorded apart from
# the native execution it prepares and never counted in it.
#
# `test` builds and runs the named test suites. `test.vulkan-headless` runs the
# native backend's `native-tests` and `shader-tests` and the window
# integration's `integration-tests` through it: none of them opens a window,
# acquires a display or a session, or creates a device, and none reads consent.
# Every argument after `--` reaches every suite as a test option.
#
# `native` runs one component already built — the native suite — as the
# timed execution. It builds nothing, and refuses a component that was not
# prepared. On Linux, a run given no consent of its own is started inside the
# isolated X11 display `tools/display/x11.sh` starts for it, which supplies the
# consent for that display alone and needs no approval; the display's startup
# and teardown are part of the run. A run that already carries consent — the
# isolated display it was started inside, or the desktop opt-in — uses it, and
# no second display is started. On macOS `HETOIMASIA_NATIVE_SESSION=desktop`
# must be on the run's own command, and this supplies none. Every argument
# after `--` reaches the executable.
#
# Every input comes from one place: `tools/native/native.py prepare`, which
# refuses the prefix unless it is exactly what this configuration provisions
# and then prints the discovery that prefix owns. Nothing here names a machine
# path or generates a project file; the loader is found through the prefix's
# own package description and, where a declaration cannot read one, through
# link and include directories passed to Cabal on the command line. The
# environment it establishes reaches its own children and nothing else.
#
# The loader is a runtime dependency, so a runtime library search override
# could load an ABI-compatible substitute after `prepare` verified the pinned
# file. Such a variable is refused before the first check rather than cleared,
# and the native suite then requires the image its entry point was resolved
# from to be `HETOIMASIA_VULKAN_QUALIFIED_LOADER`, the loader `prepare` names.
#
# The shader toolchain fingerprint (packages/gpu-vulkan/native/README.md) is
# generated before anything that builds the native package, because every
# shader splice registers it and nothing else would notice a replaced
# compiler. It is generated output rather than a source, and it sits inside a
# package every Vulkan group consumes, so one this command created is removed
# again when it exits: the validation runner holds a checkout to its candidate,
# and a generated file left inside a consumed directory would refuse the next
# group run from the same checkout. Recreating it with the same toolchain
# writes the same bytes, which is all a warm build compares.
#
# Exit status: the build's, the suites', or the executable's own; 2 for a
# configuration diagnostic.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

refuse() {
  echo "vulkan: $1" >&2
  exit 2
}

usage="usage: tools/vulkan/run.sh build COMPONENT... | test COMPONENT... [-- TEST-OPTION...] | native COMPONENT [-- ARGUMENT...]"
[ "$#" -ge 2 ] || refuse "$usage"
mode="$1"
shift
components=()
arguments=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--" ]; then
    shift
    arguments=("$@")
    break
  fi
  components+=("$1")
  shift
done
case "$mode" in
  build) [ "${#arguments[@]}" -eq 0 ] || refuse "build takes no options after --" ;;
  test) ;;
  native) [ "${#components[@]}" -eq 1 ] || refuse "native runs exactly one component" ;;
  *) refuse "$usage" ;;
esac
[ "${#components[@]}" -gt 0 ] || refuse "$usage"

set -a
# shellcheck disable=SC1091
. "$root/tools/ci-image/toolchain.pin"
# shellcheck disable=SC1091
. "$root/tools/toolchain/binding.pin"
set +a

# A runtime library search override lets the dynamic linker answer the
# loader's soname with some other file after `prepare` has verified the pinned
# one. Each is refused rather than cleared, so a run never reports on something
# other than what its caller's environment asked for without saying so. macOS
# strips the DYLD_ variables before a protected binary such as /bin/bash runs,
# so there they are refused wherever they survive.
for variable in LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT \
  DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES \
  DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_IMAGE_SUFFIX; do
  if value="$(printenv "$variable")"; then
    refuse "$variable is set ($value); a runtime library search override can load a Vulkan loader other than the one the prefix qualified, so unset it and run again"
  fi
done

# The toolchain identity. A build on some other compiler says nothing about the
# one this repository pins, so it is refused rather than reported.
actual_ghc="$(ghc --numeric-version)"
actual_cabal="$(cabal --numeric-version)"
[ "$actual_ghc" = "$GHC_VERSION" ] || refuse "ghc on PATH is $actual_ghc, but this repository pins $GHC_VERSION"
[ "$actual_cabal" = "$CABAL_VERSION" ] || refuse "cabal on PATH is $actual_cabal, but this repository pins $CABAL_VERSION"

# The binding flags the project file constrains must be the ones the toolchain
# record qualified. Restating them in two files is only safe if one checks the
# other.
[ "$VULKAN_FLAG_SAFE_FOREIGN_CALLS" = "on" ] || refuse "binding.pin turns safe-foreign-calls off; the VK-2 case's Haskell debug callback requires it"
[ "$VULKAN_FLAG_DARWIN_LIB_DIRS" = "off" ] || refuse "binding.pin turns darwin-lib-dirs on; the build names its own loader prefix"
grep -q '^    vulkan +safe-foreign-calls,$' "$root/cabal.project.vulkan" \
  || refuse "cabal.project.vulkan does not constrain vulkan +safe-foreign-calls"
grep -q '^    vulkan -darwin-lib-dirs$' "$root/cabal.project.vulkan" \
  || refuse "cabal.project.vulkan does not constrain vulkan -darwin-lib-dirs"

# Nothing generates a project file, and a leftover one would quietly put a
# former configuration back into every build here. Cabal reads
# `<project-file>.local` silently, so its presence is diagnosed rather than
# tolerated, and retiring it is the reader's deliberate act: this command does
# not delete a file it did not write.
local_project="$root/cabal.project.vulkan.local"
if [ -e "$local_project" ]; then
  refuse "$local_project exists; the loader is provisioned into the native prefix and no project file is generated, so this one is obsolete configuration that would override the provisioned prefix. Delete it and run again."
fi

# The private native prefix: the GLFW archive and the Vulkan runtime beside it,
# exactly the ones every other native build here uses. `prepare` refuses a
# prefix that is not what this configuration provisions, stamps the build
# directory so nothing linked against another native configuration is reused,
# and prints the discovery the prefix owns.
prefix_default="${XDG_CACHE_HOME:-$HOME/.cache}/hetoimasia/native/glfw"
native_prefix="${HETOIMASIA_NATIVE_PREFIX:-$prefix_default}"
case "$(uname -s)" in
  Darwin|Linux) ;;
  *) refuse "$(uname -s) is not a platform the Vulkan project is qualified on" ;;
esac
build_directory="$root/dist-vulkan"
discovery="$(python3 "$root/tools/native/native.py" prepare --prefix "$native_prefix" --build-dir "$build_directory")" \
  || refuse "the private native prefix at $native_prefix is not what this configuration provisions; the diagnosis above says what differs, and a prefix that is simply out of date is rebuilt with: python3 tools/native/native.py build --prefix $native_prefix"
eval "$discovery"

[ -n "${VK_DRIVER_FILES:-}" ] || refuse "the native prefix named no driver manifest"
[ -n "${VK_LAYER_PATH:-}" ] || refuse "the native prefix named no layer directory"
[ -r "$VK_DRIVER_FILES" ] || refuse "the provisioned driver manifest $VK_DRIVER_FILES is not readable"
[ -d "$VK_LAYER_PATH" ] || refuse "the provisioned layer directory $VK_LAYER_PATH does not exist"
[ -n "${HETOIMASIA_GLSLANG:-}" ] || refuse "the native prefix named no glslangValidator wrapper"

cabal_flags=(
  --project-file=cabal.project.vulkan
  --builddir="$build_directory"
  --extra-lib-dirs="$HETOIMASIA_VULKAN_LIBDIR"
  --extra-include-dirs="$HETOIMASIA_VULKAN_INCLUDEDIR"
)

echo "vulkan: ghc $actual_ghc, cabal $actual_cabal"
echo "vulkan: native prefix $native_prefix"
echo "vulkan: VK_DRIVER_FILES=$VK_DRIVER_FILES"
echo "vulkan: VK_LAYER_PATH=$VK_LAYER_PATH"
echo "vulkan: validation features ${HETOIMASIA_VULKAN_VALIDATION_FEATURES:-none}"

cd "$root"

# Regenerate the shader toolchain fingerprint before Cabal decides anything is
# up to date, and remove it again at exit if this command created it.
fingerprint="packages/gpu-vulkan/native/shaders/toolchain.fingerprint"
generate_fingerprint() {
  if [ ! -e "$fingerprint" ]; then
    # The directory too, when this created it: Git records no empty
    # directory, so one left behind is an addition the candidate lacks. The
    # cleanup must never decide the exit status — under `set -e` a failing
    # command in the trap would replace the suites' own — so each step
    # tolerates what it finds.
    if [ -d "$(dirname "$fingerprint")" ]; then
      trap 'rm -f "$root/$fingerprint" || true' EXIT
    else
      trap 'rm -f "$root/$fingerprint" || true; rmdir "$root/$(dirname "$fingerprint")" 2>/dev/null || true' EXIT
    fi
  fi
  "$HETOIMASIA_GLSLANG" --hetoimasia-identity | sed 's/^/vulkan: glslang wrapper reports /'
  cabal run -v1 "${cabal_flags[@]}" hetoimasia-gpu-vulkan-native:exe:hetoimasia-shader-fingerprint -- \
    --output "$root/$fingerprint" \
    | sed 's/^shader fingerprint:/vulkan: shader fingerprint:/'
}

case "$mode" in
  build)
    generate_fingerprint
    cabal build "${cabal_flags[@]}" "${components[@]}"
    ;;
  test)
    generate_fingerprint
    options=()
    for argument in ${arguments[@]+"${arguments[@]}"}; do
      options+=("--test-option=$argument")
    done
    cabal test "${cabal_flags[@]}" --test-show-details=direct "${components[@]}" ${options[@]+"${options[@]}"}
    ;;
  native)
    # The exact identity of the sources under test, computed from their
    # content, which the VK-2 case's record carries. A revision is a
    # convenience and can be inexact — a working tree can be dirty — so a
    # record is pinned by this instead, and a reader can recompute it.
    HETOIMASIA_VULKAN_SOURCE_DIGEST="$(
      python3 - "$root" <<'DIGEST'
import hashlib, os, sys

root = sys.argv[1]
# Everything that decides what the native suite is and how it is built, by
# directory rather than by file, because naming files individually is how an
# input gets left out.
roots = ["tools/vulkan", "tools/native", "tools/display",
         "packages/gpu-vulkan/native", "packages/gpu-vulkan/glfw", "packages/glfw",
         "packages/gpu-vulkan/diagnostics", "packages/gpu-vulkan/model",
         "packages/runtime", "packages/foundation", "tools/test-support"]
files = ["cabal.project.vulkan", "cabal.project.common",
         "tools/toolchain/binding.pin", "tools/ci-image/toolchain.pin"]

def carried(path):
    parts = path.split(os.sep)
    # The shader fingerprint is generated from the prefix, which the record
    # already identifies; it is not a source.
    return ("__pycache__" not in parts and not path.endswith(".pyc") and ".DS_Store" not in parts
            and not path.endswith(os.path.join("shaders", "toolchain.fingerprint")))

paths = set(files)
for directory in roots:
    for base, _, names in os.walk(os.path.join(root, directory)):
        for name in names:
            relative = os.path.relpath(os.path.join(base, name), root)
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
    export HETOIMASIA_VULKAN_SOURCE_DIGEST
    if [ -z "${HETOIMASIA_VULKAN_REVISION:-}" ]; then
      if revision="$(git -C "$root" rev-parse HEAD 2>/dev/null)"; then
        git -C "$root" diff --quiet HEAD -- . 2>/dev/null || revision="$revision (dirty)"
      else
        revision="unknown"
      fi
      export HETOIMASIA_VULKAN_REVISION="$revision"
    fi
    echo "vulkan: repository revision $HETOIMASIA_VULKAN_REVISION"
    echo "vulkan: source digest $HETOIMASIA_VULKAN_SOURCE_DIGEST"

    executable="$(cabal list-bin -v0 "${cabal_flags[@]}" "${components[0]}")" \
      || refuse "Cabal could not name the executable of ${components[0]}"
    [ -x "$executable" ] \
      || refuse "${components[0]} has not been built; prepare it with: bash tools/vulkan/run.sh build ${components[0]}"

    if [ -z "${HETOIMASIA_NATIVE_SESSION:-}" ] && [ "$(uname -s)" = "Linux" ]; then
      # No consent of its own on Linux: the isolated display is started for
      # this run, inside it, and its logs are kept with the run's evidence.
      display=(bash "$root/tools/display/x11.sh")
      if [ -n "${HETOIMASIA_VALIDATION_EVIDENCE:-}" ]; then
        display+=(--retain "$HETOIMASIA_VALIDATION_EVIDENCE")
      fi
      exec "${display[@]}" -- "$executable" ${arguments[@]+"${arguments[@]}"}
    fi
    exec "$executable" ${arguments[@]+"${arguments[@]}"}
    ;;
esac
