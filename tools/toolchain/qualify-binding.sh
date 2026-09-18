#!/usr/bin/env bash
# Prove that the pinned Vulkan binding builds on this repository's qualified
# toolchain, with the flags `tools/toolchain/binding.pin` requires.
#
# The qualification is deliberately not a package of this repository. There is
# no `packages/gpu-vulkan` yet, and adding `vulkan` to `cabal.project` would
# make every ordinary build and every CI worker pay for a binding nothing
# imports. Instead this builds a throwaway consumer in a temporary directory,
# against the same compiler, Cabal, and Hackage index the repository pins, and
# reports what the solver actually chose.
#
# It runs on local macOS against a named loader prefix, and on Linux inside the
# pinned throwaway container `tools/toolchain/Dockerfile.linux-binding` builds.
# It never runs on an ordinary validation worker, and the CI image gains no
# Vulkan input from it. See docs/toolchain.md.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

set -a
# shellcheck disable=SC1091
. "$root/tools/ci-image/toolchain.pin"
# shellcheck disable=SC1091
. "$root/tools/toolchain/binding.pin"
set +a

# The index the repository pins, read from the one file that declares it rather
# than repeated here, so this qualification can never resolve against a
# different view of Hackage than an ordinary build does.
index_state="$(sed -n 's/^index-state:[[:space:]]*//p' "$root/cabal.project.common")"
if [ -z "$index_state" ]; then
  echo "qualify-binding: cabal.project.common declares no index-state" >&2
  exit 2
fi

# The toolchain identity. A qualification run on some other compiler proves
# nothing about the one this repository pins, so it is refused rather than
# reported.
actual_ghc="$(ghc --numeric-version)"
actual_cabal="$(cabal --numeric-version)"
if [ "$actual_ghc" != "$GHC_VERSION" ]; then
  echo "qualify-binding: ghc on PATH is $actual_ghc, but this repository pins $GHC_VERSION" >&2
  exit 2
fi
if [ "$actual_cabal" != "$CABAL_VERSION" ]; then
  echo "qualify-binding: cabal on PATH is $actual_cabal, but this repository pins $CABAL_VERSION" >&2
  exit 2
fi

flag_argument() {
  case "$2" in
    on) printf -- '+%s' "$1" ;;
    off) printf -- '-%s' "$1" ;;
    *) echo "qualify-binding: $1 is $2, which is neither on nor off" >&2; exit 2 ;;
  esac
}

safe_foreign_calls="$(flag_argument safe-foreign-calls "$VULKAN_FLAG_SAFE_FOREIGN_CALLS")"
darwin_lib_dirs="$(flag_argument darwin-lib-dirs "$VULKAN_FLAG_DARWIN_LIB_DIRS")"

# How the loader is found. On Linux the binding declares `pkgconfig-depends:
# vulkan` and the container installs the loader's development package, so
# nothing has to be named here. On macOS the binding declares
# `extra-libraries: vulkan` and would have found the loader only through the
# `darwin-lib-dirs` default this repository turns off, so the prefix is named
# explicitly and checked before the solver is asked anything.
loader_stanza=""
case "$(uname -s)" in
  Darwin)
    prefix="${HETOIMASIA_VULKAN_PREFIX:-$MACOS_VULKAN_PREFIX}"
    if [ ! -d "$prefix/lib" ]; then
      echo "qualify-binding: no Vulkan loader prefix at $prefix (set HETOIMASIA_VULKAN_PREFIX)" >&2
      exit 2
    fi
    # `extra-lib-dirs` is a link-time search path only. `vulkan-utils` runs
    # Template Haskell against the compiled `vulkan` library, which makes GHC
    # dlopen it while compiling, and that dylib records the loader as
    # `@rpath/libvulkan.1.dylib`. Without an rpath entry naming this prefix the
    # load fails and the binding looks broken when only the search path was
    # missing. The `darwin-lib-dirs` default hid this behind a hard-coded
    # /usr/local/lib; naming the prefix is what makes the dependency explicit.
    #
    # It has to be a `package vulkan` stanza rather than a command-line option:
    # `--ghc-options` reaches local packages only, never a dependency the store
    # builds.
    loader_stanza="$(cat <<EOF

package vulkan
  extra-lib-dirs: $prefix/lib
  extra-include-dirs: $prefix/include
  ghc-options: -optl-Wl,-rpath,$prefix/lib
EOF
)"
    echo "loader-prefix=$prefix"
    ;;
  Linux)
    # The binding declares pkgconfig-depends on vulkan here, so the loader's
    # development package is the whole configuration and nothing is named.
    if ! pkg-config --exists vulkan; then
      echo "qualify-binding: pkg-config cannot see a vulkan loader" >&2
      exit 2
    fi
    echo "loader-prefix=$(pkg-config --variable=prefix vulkan)"
    ;;
  *)
    echo "qualify-binding: $(uname -s) is not a qualified platform" >&2
    exit 2
    ;;
esac

echo "ghc=$actual_ghc"
echo "cabal=$actual_cabal"
echo "index-state=$index_state"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The throwaway consumer. It imports `Vulkan.Core10` and
# `Vulkan.Utils.Initialization` so the qualification links what it resolves
# rather than only planning it: a binding that resolves but cannot find the
# loader fails here instead of in the first slice that tries to use it.
cat > "$scratch/binding-qualification.cabal" <<EOF
cabal-version: 3.16
name: binding-qualification
version: 0
build-type: Simple

library
    exposed-modules: Qualification
    hs-source-dirs: src
    default-language: GHC2024
    default-extensions: UnicodeSyntax
    build-depends:
        base,
        vulkan ==$VULKAN_VERSION,
        vulkan-utils ==$VULKAN_UTILS_VERSION
EOF

mkdir "$scratch/src"
cat > "$scratch/src/Qualification.hs" <<'EOF'
-- | Enough of the binding to prove it resolved, compiled, and linked against a
-- real loader. It initializes nothing and calls no driver.
module Qualification (qualifiedStructure) where

import Vulkan.Core10 (ApplicationInfo)

-- Importing the utility module for its instances alone still makes its
-- Template Haskell run, and that is what loads the compiled binding — and
-- through it the loader — at compile time. A binding that resolves but cannot
-- find the loader fails here rather than in the first slice that uses it.
import Vulkan.Utils.Initialization ()

-- | Names a generated structure, so this module cannot compile unless the
-- binding's generated interface is really present.
qualifiedStructure ∷ Maybe ApplicationInfo
qualifiedStructure = Nothing
EOF

cat > "$scratch/cabal.project" <<EOF
packages: .

index-state: $index_state

constraints:
    vulkan $safe_foreign_calls,
    vulkan $darwin_lib_dirs
$loader_stanza
EOF

echo "flags=vulkan $safe_foreign_calls $darwin_lib_dirs"

# The generated project is the replayable resolution input: it carries the
# index, the flags, and the platform's loader configuration in one file. Keep it
# when asked, so a qualification recorded in docs/toolchain.md can be replayed
# rather than only read.
if [ -n "${HETOIMASIA_QUALIFICATION_OUT:-}" ]; then
  mkdir -p "$HETOIMASIA_QUALIFICATION_OUT"
  cp "$scratch/cabal.project" "$HETOIMASIA_QUALIFICATION_OUT/cabal.project"
  cp "$scratch/binding-qualification.cabal" "$HETOIMASIA_QUALIFICATION_OUT/binding-qualification.cabal"
fi

cd "$scratch"
# The build log is kept out of the qualification's own output, which is a short
# record, but printed in full when the build fails: a qualification that only
# says "it did not build" cannot be acted on.
if ! cabal build all > "$scratch/build.log" 2>&1; then
  cat "$scratch/build.log" >&2
  echo "qualify-binding: the pinned binding did not build on the pinned toolchain" >&2
  exit 1
fi

# What the solver actually chose, read back from the plan rather than from the
# pin, so a resolution that quietly drifted from the pinned pair is reported as
# the failure it is.
python3 - "$scratch" "$VULKAN_VERSION" "$VULKAN_UTILS_VERSION" \
  "$VULKAN_FLAG_SAFE_FOREIGN_CALLS" "$VULKAN_FLAG_DARWIN_LIB_DIRS" <<'PY'
import json, sys, pathlib

scratch, expected_vulkan, expected_utils = sys.argv[1], sys.argv[2], sys.argv[3]
# The pin is the single source of truth for the flags too, so flipping one there
# moves both what is asked for and what is checked.
expected_flags = {
    "safe-foreign-calls": sys.argv[4] == "on",
    "darwin-lib-dirs": sys.argv[5] == "on",
}
plan = json.loads(pathlib.Path(scratch, "dist-newstyle", "cache", "plan.json").read_text())

chosen = {}
flags = {}
for unit in plan["install-plan"]:
    name = unit.get("pkg-name")
    if name in ("vulkan", "vulkan-utils"):
        chosen[name] = unit.get("pkg-version")
        if unit.get("flags"):
            flags[name] = unit["flags"]

problems = []
for name, expected in (("vulkan", expected_vulkan), ("vulkan-utils", expected_utils)):
    if name not in chosen:
        problems.append(f"{name} is not in the resolved plan")
    elif chosen[name] != expected:
        problems.append(f"{name} resolved to {chosen[name]}, but the pin names {expected}")

effective = flags.get("vulkan", {})
for flag, wanted in sorted(expected_flags.items()):
    if effective.get(flag) != wanted:
        problems.append(f"vulkan flag {flag} resolved to {effective.get(flag)}, not {wanted}")

for name in sorted(chosen):
    print(f"resolved {name}-{chosen[name]}")
print("effective-flags " + " ".join(
    f"{'+' if value else '-'}{flag}" for flag, value in sorted(effective.items())
))

if problems:
    for problem in problems:
        print("qualify-binding: " + problem, file=sys.stderr)
    raise SystemExit(1)
PY

echo "qualify-binding: the pinned binding builds on the pinned toolchain"
