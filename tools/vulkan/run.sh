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
# groups `test.vulkan-headless`, `test.vulkan-native`, `test.vulkan-wayland`,
# `test.vulkan-lua-engine-native` and `test.vulkan-run-native` run through it.
#
# `build` compiles the named components, and nothing else, then records the
# build identity of each executable they resolve to: the source digest and the
# revision of the tree the build started from, in the form `native` prints, in
# `native-identity/` inside the build directory (`build_identity`, below).
# The record is bound to the executable by its content, path and variant, and is
# not among the digest's inputs. Building `run-native-tests` also records the
# full-product `hetoimasia` executable it launches, even when only the suite is
# named. A target that is not one executable (a library, a whole package) builds
# as before and records nothing. A build that fails, is interrupted, or sees the
# source change while it compiles records nothing; one that compiles but cannot
# record exits 1 naming the component. `test.vulkan-native` and
# `test.vulkan-wayland` run it as their preparation stage, so the compilation is
# recorded apart from the native execution it prepares and never counted in it.
#
# `test` builds and runs the named test suites. `test.vulkan-headless` runs the
# native backend's `native-tests` and `shader-tests`, the window integration's
# `integration-tests`, the samples' suites and the 2D renderer's recorder's
# `render-2d-vulkan-tests` and the Lua-first engine's graphics adapter's
# `lua-engine-graphics-tests` through it, and the root package's full-product `hetoimasia-tests` (the `run`
# command's grammar, composition and boot refusals, none of which starts a native session): none of them opens a window,
# acquires a display or a session, or creates a device, and none reads consent.
# Every argument after `--` reaches every suite as a test option.
#
# `native` runs one component already built — the native suite — as the
# timed execution. It builds nothing, and refuses a component that was not
# prepared. What it prints as the run's provenance (`repository revision`,
# `source digest`) and exports for the executable to record is the identity the
# executable's own build recorded, never the tree as it is now: it refuses, with
# status 2 and the command that prepares the component, an executable whose
# record is missing, malformed, made for another executable (or the same one in
# the other build directory), or built
# from a tree whose digest is not the current one, and a caller-set
# `HETOIMASIA_VULKAN_REVISION` that disagrees with the record. For
# `run-native-tests` the `hetoimasia` executable it launches must satisfy the same
# and carry the same revision and digest, so the header and the suite's record
# are one truthful pair. On Linux, a run given no consent of its own is started inside the
# isolated X11 display `tools/display/x11.sh` starts for it, which supplies the
# consent for that display alone and needs no approval; the display's startup
# and teardown are part of the run. A run that already carries consent — the
# isolated display or compositor it was started inside, or the desktop opt-in —
# uses it, and no second display is started: `test.vulkan-wayland` starts
# `tools/display/wayland.sh` around this command, so the same suite runs on the
# isolated headless compositor instead. On macOS `HETOIMASIA_NATIVE_SESSION=desktop`
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
# That removal ignores TERM, INT and HUP for its whole duration, before it does
# anything else. The validation runner signals every member of a stage's session
# at its expiry and, during the grace that follows, every member it first sees
# in that grace, which includes the `rm` and `rmdir` the removal starts; an
# ignored disposition is inherited by them, so a signal that arrives while it
# runs neither ends it early nor leaves a generated fingerprint in the checkout.
# The exit status is unchanged by it. A removal that hangs is still frozen and
# killed after the grace, by the runner.
#
# `HETOIMASIA_VMA_FOREIGN_CALLS` chooses the call safety of the Hackage
# `VulkanMemoryAllocator` binding's Haskell imports, which only the allocator
# probe calls (GRS-18, #361); the native backend links the VMA that package
# compiles but calls it through its own shim, so the choice changes nothing
# the engine runs: `unsafe`, the default and the binding's own default, or
# `safe`, its `safe-foreign-calls` flag. A project builds one configuration of
# a dependency, so the choice is a constraint on the command line, every other
# input identical, and the safe build keeps its own build directory so neither
# variant rebuilds the other. The choice is exported to what runs, which the
# probe checks against the binding's behaviour.
#
# Exit status: the build's, the suites', or the executable's own; 2 for a
# configuration diagnostic (including a refused build identity); 1 for a build
# identity that could not be recorded.
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
vma_calls="${HETOIMASIA_VMA_FOREIGN_CALLS:-unsafe}"
case "$vma_calls" in
  unsafe) vma_constraint="VulkanMemoryAllocator -safe-foreign-calls" ;;
  safe)
    vma_constraint="VulkanMemoryAllocator +safe-foreign-calls"
    build_directory="$root/dist-vulkan-vma-safe"
    ;;
  *) refuse "HETOIMASIA_VMA_FOREIGN_CALLS is '$vma_calls'; it is 'unsafe' (the default) or 'safe'" ;;
esac
export HETOIMASIA_VMA_FOREIGN_CALLS="$vma_calls"
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
  "--constraint=$vma_constraint"
)

echo "vulkan: ghc $actual_ghc, cabal $actual_cabal"
echo "vulkan: native prefix $native_prefix"
echo "vulkan: VK_DRIVER_FILES=$VK_DRIVER_FILES"
echo "vulkan: VK_LAYER_PATH=$VK_LAYER_PATH"
echo "vulkan: validation features ${HETOIMASIA_VULKAN_VALIDATION_FEATURES:-none}"
echo "vulkan: VMA binding calls $vma_calls ($vma_constraint), build directory $build_directory"

cd "$root"

# Regenerate the shader toolchain fingerprint before Cabal decides anything is
# up to date, in every package whose shader splices read it — each splice
# reads `shaders/toolchain.fingerprint` relative to the package it compiles
# in — and remove each again at exit if this command created it.
fingerprints=(
  "packages/gpu-vulkan/native/shaders/toolchain.fingerprint"
  "samples/triangle/renderer/shaders/toolchain.fingerprint"
  "samples/sprites/renderer/shaders/toolchain.fingerprint"
  "samples/scene3d/renderer/shaders/toolchain.fingerprint"
  "packages/render-2d-vulkan/shaders/toolchain.fingerprint"
)
cleanup=""
generate_fingerprint() {
  for fingerprint in "${fingerprints[@]}"; do
    if [ ! -e "$fingerprint" ]; then
      # The directory too, when this created it: Git records no empty
      # directory, so one left behind is an addition the candidate lacks. The
      # cleanup must never decide the exit status — under `set -e` a failing
      # command in the trap would replace the suites' own — so each step
      # tolerates what it finds.
      cleanup="$cleanup rm -f \"\$root/$fingerprint\" || true;"
      if [ ! -d "$(dirname "$fingerprint")" ]; then
        cleanup="$cleanup rmdir \"\$root/$(dirname "$fingerprint")\" 2>/dev/null || true;"
      fi
    fi
  done
  if [ -n "$cleanup" ]; then
    # The removal protects itself and the commands it starts from the signals a
    # stage's expiry sends, first of all.
    # shellcheck disable=SC2064
    trap "trap '' TERM INT HUP; $cleanup" EXIT
  fi
  "$HETOIMASIA_GLSLANG" --hetoimasia-identity | sed 's/^/vulkan: glslang wrapper reports /'
  for fingerprint in "${fingerprints[@]}"; do
    mkdir -p "$root/$(dirname "$fingerprint")"
    cabal run -v1 "${cabal_flags[@]}" hetoimasia-gpu-vulkan-native:exe:hetoimasia-shader-fingerprint -- \
      --output "$root/$fingerprint" \
      | sed 's/^shader fingerprint:/vulkan: shader fingerprint:/'
  done
}

# The Linux receipt of the launcher's native suite captures and closes its windows through an external helper
# (tools/x11-window/x11_window.py, LFE-25). Its preparation is that it loads libX11 with every entry point it uses; it
# needs no display, so the build stage can prove it, and the timed execution proves it again. A helper that is not ready
# refuses the run: a requested native group is blocked, never skipped.
prepare_x11_helper() {
  [ "$(uname -s)" = "Linux" ] || return 0
  python3 -I "$root/tools/x11-window/x11_window.py" prepare >/dev/null \
    || refuse "the X11 evidence helper is not ready: python3 -I tools/x11-window/x11_window.py prepare failed"
  echo "vulkan: X11 evidence helper ready"
}

# The exact identity of the sources under test, computed from their content,
# which the VK-2 case's record carries. A revision is a convenience and can be
# inexact — a working tree can be dirty — so a record is pinned by this instead,
# and a reader can recompute it.
source_digest() {
  python3 - "$root" <<'DIGEST'
import hashlib, os, sys

root = sys.argv[1]
# Everything that decides what the native suite is and how it is built, by
# directory rather than by file, because naming files individually is how an
# input gets left out.
roots = ["tools/vulkan", "tools/native", "tools/display",
         "packages/gpu-vulkan/native", "packages/gpu-vulkan/glfw", "packages/glfw",
         "samples/triangle/renderer", "samples/triangle/app",
         "samples/sprites/renderer", "samples/sprites/app",
         "samples/image2d/renderer", "samples/image2d/app",
         "samples/scene3d/renderer", "samples/scene3d/app",
         "packages/gpu-vulkan/diagnostics", "packages/gpu-vulkan/model",
         "packages/runtime", "packages/foundation", "packages/math", "tools/test-support",
         "packages/render-2d-vulkan", "packages/render-2d", "packages/render-api",
         "packages/render-2d-oracle", "packages/asset", "packages/asset-image",
         "packages/lua-engine-graphics", "packages/lua-engine", "packages/scripting-lua",
         "packages/content",
         # The root package's own inputs, named one by one: the root directory itself is never a root here,
         # because it would hash dist-vulkan and every other generated output. These are the entry point, its
         # two build variants, the private console and run libraries, the root suites and the shipped content.
         "app", "app-cpu", "app-full", "console", "run", "test", "test-cpu", "test-full",
         "run-native-test", "samples/lua-quad", "tools/x11-window"]
files = ["cabal.project.vulkan", "cabal.project.common", "hetoimasia.cabal",
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
}

# The repository revision of the tree as it is now, with ` (dirty)` when tracked
# files differ from it. `build` records it; `native` never computes it.
source_revision() {
  local revision
  if revision="$(git -C "$root" rev-parse HEAD 2>/dev/null)"; then
    git -C "$root" diff --quiet HEAD -- . 2>/dev/null || revision="$revision (dirty)"
  else
    revision="unknown"
  fi
  printf '%s\n' "$revision"
}

# The build identity `tools/vulkan/run.sh build` stamps and `run.sh native` reads.
#
# An executable built earlier is run later, by a command that builds nothing. What
# that run reports as its provenance must describe the executable, not the source
# tree at run time, so the build records, beside the executable, the revision and
# source digest of the tree it built from, and the run reads them back.
#
# A stamp is bound to the executable it was made for by that executable's own
# content (SHA-256) and its path, which names the component and the build directory
# (each build variant has its own), so it is refused rather than trusted when it is
# missing, incomplete, malformed, copied from another build or another component,
# or left behind by an executable that has since been replaced.
#
#     build_identity record --directory DIR --executable PATH
#                              --revision TEXT --digest HEX
#     build_identity verify --directory DIR --executable PATH
#
# `record` writes the stamp atomically (a temporary file in DIR renamed over the
# stamp), and exits 1 with a one-line diagnostic when it cannot. `verify` prints
# the recorded revision and digest, one per line, and exits 0; otherwise it prints
# one line saying why the identity cannot be trusted and exits 1. Neither reads
# the source tree: the digest is computed by `run.sh`, which compares it.
#
# Ownership: a stamp is written by `run.sh build` in the build directory's
# `native-identity` directory, read by `run.sh native`, and removed with the build
# directory it lives in. Nothing else writes it, and no state outlives one call.
build_identity() {
  python3 -I - "$@" <<'IDENTITY'
import argparse
import hashlib
import os
import re
import sys
import tempfile

FORMAT = "hetoimasia-native-identity 1"
HEX = re.compile(r"[0-9a-f]{64}\Z")
# A commit id, optionally dirty, or the word the runner uses outside a checkout.
REVISION = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})(?: \(dirty\))?\Z|unknown\Z")
CHUNK = 1 << 20


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                return digest.hexdigest()
            digest.update(block)


def stamp_path(directory, executable):
    """One stamp per executable path, named so two components never share one."""
    key = hashlib.sha256(executable.encode("utf-8")).hexdigest()[:16]
    return os.path.join(directory, os.path.basename(executable) + "-" + key + ".stamp")


def render(executable, executable_sha256, revision, digest):
    return "\n".join([
        FORMAT,
        "executable " + executable,
        "sha256 " + executable_sha256,
        "revision " + revision,
        "digest " + digest,
        "end",
    ]) + "\n"


def parse(text):
    """The stamp's fields, or the reason it is not a complete, well-formed one."""
    if not text.endswith("\n"):
        return None, "it is truncated"
    lines = text[:-1].split("\n")
    expected = ["", "executable ", "sha256 ", "revision ", "digest ", "end"]
    if lines[:1] != [FORMAT]:
        return None, "it is not a build identity of this format"
    if len(lines) != len(expected):
        return None, "it is incomplete or has extra lines"
    values = {}
    for line, prefix in zip(lines[1:], expected[1:]):
        if prefix == "end":
            if line != "end":
                return None, "it has no end marker"
            continue
        if not line.startswith(prefix) or len(line) == len(prefix):
            return None, "its '%s' field is absent or empty" % prefix.strip()
        values[prefix.strip()] = line[len(prefix):]
    if not HEX.match(values["sha256"]):
        return None, "its executable hash is malformed"
    if not REVISION.match(values["revision"]):
        return None, "its revision is malformed"
    if not HEX.match(values["digest"]):
        return None, "its source digest is malformed"
    return values, None


def record(arguments):
    executable = os.path.abspath(arguments.executable)
    if not os.path.isfile(executable):
        return fail("%s is not a file" % executable)
    if "\n" in executable:
        return fail("the executable's path contains a newline")
    if not REVISION.match(arguments.revision):
        return fail("revision %r is malformed" % arguments.revision)
    if not HEX.match(arguments.digest):
        return fail("source digest %r is malformed" % arguments.digest)
    text = render(executable, sha256_of(executable), arguments.revision, arguments.digest)
    target = stamp_path(arguments.directory, executable)
    descriptor, temporary = tempfile.mkstemp(dir=arguments.directory, prefix=".stamp-")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temporary, target)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return 0


def verify(arguments):
    executable = os.path.abspath(arguments.executable)
    target = stamp_path(arguments.directory, executable)
    try:
        with open(target, "r", encoding="utf-8", errors="strict", newline="") as handle:
            text = handle.read()
    except FileNotFoundError:
        return fail("it has no recorded build identity")
    except (OSError, UnicodeDecodeError) as error:
        return fail("its recorded build identity cannot be read (%s)" % error)
    values, reason = parse(text)
    if values is None:
        return fail("its recorded build identity is unusable: %s" % reason)
    if values["executable"] != executable:
        return fail("its recorded build identity was made for %s" % values["executable"])
    try:
        actual = sha256_of(executable)
    except OSError as error:
        return fail("the executable cannot be read (%s)" % error)
    if values["sha256"] != actual:
        return fail("the executable is not the one its recorded build identity was made for (it was replaced after that build)")
    sys.stdout.write(values["revision"] + "\n" + values["digest"] + "\n")
    return 0


def fail(message):
    sys.stdout.write(message + "\n")
    return 1


def main(argv):
    parser = argparse.ArgumentParser(prog="run.sh build identity")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("record", "verify"):
        command = commands.add_parser(name)
        command.add_argument("--directory", required=True)
        command.add_argument("--executable", required=True)
        if name == "record":
            command.add_argument("--revision", required=True)
            command.add_argument("--digest", required=True)
    arguments = parser.parse_args(argv)
    if arguments.command == "record":
        try:
            os.makedirs(arguments.directory, exist_ok=True)
            return record(arguments)
        except OSError as error:
            return fail(str(error))
    return verify(arguments)


sys.exit(main(sys.argv[1:]))
IDENTITY
}

# The build identity of each executable `build` produces, recorded where
# `native` reads it back (`build_identity`). It lives in the build
# directory — `dist-vulkan/` is a declared generated path and is ignored by Git,
# so the validation runner and `git status` see nothing new — and it is not
# among the source digest's inputs.
identity_directory="$build_directory/native-identity"

# The command that prepares a component, for a refusal to name: with the
# variant's choice when it is not the default.
prepare_prefix=""
[ "$vma_calls" = "unsafe" ] || prepare_prefix="HETOIMASIA_VMA_FOREIGN_CALLS=$vma_calls "

# Whether Cabal resolves a target to exactly one executable that exists, and which.
# A library, or a package naming several components, names no single executable:
# such a target builds as it always did and is not stamped.
built_executable() {
  local path
  path="$(cabal list-bin -v0 "${cabal_flags[@]}" "$1" 2>/dev/null)" || return 1
  [ -f "$path" ] && [ -x "$path" ] || return 1
  printf '%s\n' "$path"
}

# Record, for each executable the named targets built, the identity of the tree
# the build started from. Called only after the build and its checks succeeded,
# so a failed or interrupted build records nothing. If the source changed while
# it compiled, the executable may not match either tree, and nothing is
# recorded; a stamp that cannot be recorded fails the build, naming the target.
stamp_build() {
  local started_revision="$1" started_digest="$2"
  shift 2
  local labels=() paths=() target path label index seen suite_path status=0 recorded
  suite_path="$(built_executable hetoimasia:test:run-native-tests || true)"
  for target in "$@"; do
    path="$(built_executable "$target" || true)"
    [ -n "$path" ] || continue
    labels+=("$target")
    paths+=("$path")
    # The suite launches the full-product command as a child, and the two are
    # one pair: building the suite, however it was spelled, stamps both.
    if [ -n "$suite_path" ] && [ "$path" = "$suite_path" ]; then
      path="$(built_executable hetoimasia:exe:hetoimasia || true)"
      if [ -z "$path" ]; then
        echo "vulkan: cannot record the build identity of hetoimasia:exe:hetoimasia, which $target launches: it was not built" >&2
        status=1
      else
        labels+=("hetoimasia:exe:hetoimasia")
        paths+=("$path")
      fi
    fi
  done
  [ "${#paths[@]}" -gt 0 ] || return "$status"
  if [ "$(source_digest)" != "$started_digest" ]; then
    for label in "${labels[@]}"; do
      echo "vulkan: cannot record the build identity of $label: the source tree changed while it was being built" >&2
    done
    return 1
  fi
  seen=" "
  index=0
  for path in "${paths[@]}"; do
    label="${labels[$index]}"
    index=$((index + 1))
    case "$seen" in *" $path "*) continue ;; esac
    seen="$seen$path "
    if ! recorded="$(build_identity record --directory "$identity_directory" --executable "$path" \
      --revision "$started_revision" --digest "$started_digest")"; then
      echo "vulkan: cannot record the build identity of $label: $recorded" >&2
      status=1
    fi
  done
  return "$status"
}

# The identity recorded for an executable, or the refusal. Sets
# `recorded_revision` and `recorded_digest` to what the executable's build
# stamped, once it is the executable that stamp was made for and was built from
# the tree as it is now.
read_identity() {
  local label="$1" path="$2" prepare="$3" verified status=0
  verified="$(build_identity verify --directory "$identity_directory" --executable "$path")" || status=$?
  [ "$status" -eq 0 ] \
    || refuse "$label cannot be run: ${verified:-its recorded build identity could not be read}; prepare it with: $prepare"
  recorded_revision="${verified%%$'\n'*}"
  recorded_digest="${verified#*$'\n'}"
  [ "$recorded_digest" = "$current_digest" ] \
    || refuse "$label was built from source digest $recorded_digest (revision $recorded_revision), but the tree's is $current_digest; prepare it with: $prepare"
}

case "$mode" in
  build)
    generate_fingerprint
    # The identity of the tree the build starts from, taken before anything
    # compiles.
    started_digest="$(source_digest)"
    started_revision="$(source_revision)"
    cabal build "${cabal_flags[@]}" "${components[@]}"
    for component in "${components[@]}"; do
      case "$component" in
        *run-native-tests) prepare_x11_helper ;;
      esac
    done
    stamp_build "$started_revision" "$started_digest" "${components[@]}"
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
    current_digest="$(source_digest)"

    executable="$(cabal list-bin -v0 "${cabal_flags[@]}" "${components[0]}")" \
      || refuse "Cabal could not name the executable of ${components[0]}"
    [ -x "$executable" ] \
      || refuse "${components[0]} has not been built; prepare it with: bash tools/vulkan/run.sh build ${components[0]}"

    # The launcher's native suite starts the built full-product command as a child. That executable is named here,
    # from this same project and build directory, so a `hetoimasia` of another profile that happens to be on PATH can
    # never be the one launched, and nothing is built during the timed execution: a command that was not built
    # is refused. The suite is recognized by the executable Cabal resolves for the component asked for, not by how
    # the component was spelled (`hetoimasia:test:run-native-tests`, `hetoimasia:run-native-tests`, `run-native-tests`
    # and so on all resolve to it), and any value inherited from the caller is dropped first, so no other component
    # and no stale environment can reach it.
    unset HETOIMASIA_RUN_EXECUTABLE
    run_native_suite="$(cabal list-bin -v0 "${cabal_flags[@]}" hetoimasia:test:run-native-tests 2>/dev/null || true)"
    suite_launches=""
    if [ -n "$run_native_suite" ] && [ "$executable" = "$run_native_suite" ]; then
      suite_launches="yes"
    fi

    # What the run reports as provenance is what each executable's own build
    # recorded, never the tree as it is now: the executable was built earlier and
    # this command builds nothing. An executable with no valid record, or built
    # from a different tree than the one here, is refused before anything starts.
    if [ -n "$suite_launches" ]; then
      prepare_command="${prepare_prefix}bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests"
    else
      prepare_command="${prepare_prefix}bash tools/vulkan/run.sh build ${components[0]}"
    fi
    read_identity "${components[0]}" "$executable" "$prepare_command"
    identity_revision="$recorded_revision"
    identity_digest="$recorded_digest"

    if [ -n "$suite_launches" ]; then
      run_executable="$(cabal list-bin -v0 "${cabal_flags[@]}" hetoimasia:exe:hetoimasia)" \
        || refuse "Cabal could not name the full-product hetoimasia executable"
      [ -x "$run_executable" ] \
        || refuse "the full-product hetoimasia executable has not been built; prepare it with: bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests"
      read_identity "hetoimasia:exe:hetoimasia" "$run_executable" "$prepare_command"
      # One truthful pair for the header and the suite's record: the suite and the
      # command it launches must have been built from the same revision and tree.
      if [ "$recorded_revision" != "$identity_revision" ] || [ "$recorded_digest" != "$identity_digest" ]; then
        refuse "${components[0]} and the hetoimasia executable it launches were built at different identities (${components[0]}: revision $identity_revision, source digest $identity_digest; hetoimasia:exe:hetoimasia: revision $recorded_revision, source digest $recorded_digest); build both together with: $prepare_command"
      fi
    fi

    # A caller-set revision may agree with the recorded one and may not stand in for it.
    if [ -n "${HETOIMASIA_VULKAN_REVISION:-}" ] && [ "$HETOIMASIA_VULKAN_REVISION" != "$identity_revision" ]; then
      refuse "HETOIMASIA_VULKAN_REVISION is set to '$HETOIMASIA_VULKAN_REVISION', but ${components[0]} was built at revision $identity_revision; unset it, or prepare the component with: $prepare_command"
    fi
    export HETOIMASIA_VULKAN_SOURCE_DIGEST="$identity_digest"
    export HETOIMASIA_VULKAN_REVISION="$identity_revision"
    echo "vulkan: repository revision $HETOIMASIA_VULKAN_REVISION"
    echo "vulkan: source digest $HETOIMASIA_VULKAN_SOURCE_DIGEST"

    if [ -n "$suite_launches" ]; then
      export HETOIMASIA_RUN_EXECUTABLE="$run_executable"
      echo "vulkan: launched executable $HETOIMASIA_RUN_EXECUTABLE"
      prepare_x11_helper
    fi

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
