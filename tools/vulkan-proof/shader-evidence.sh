#!/usr/bin/env bash
# Gather VK-9's shader rebuild, refusal and distribution evidence.
#
# This is local verification, not a routine check: it rebuilds a scratch copy
# of the repository a dozen times and takes several minutes. It exists because
# what it shows is what a build does across builds — which modules Cabal and
# GHC recompile, and which shader compilations actually run, when one input
# changes — and no single Hspec example can observe that from inside one build.
# `run-shaders.sh` is the routine route; this is what its claims rest on.
#
# Nothing in the checkout is touched. The tracked and untracked-but-not-ignored
# files are copied to a scratch directory and edited there, and the compiler is
# reached through a *fixture* wrapper with a fixture native manifest: a wrapper
# that answers for the pinned compiler under a version label of its own and
# logs every compile it runs, so a compiler identity change can be exercised
# without changing any pin, and every shader compilation is observed rather
# than inferred. The provisioned prefix is still what `native.py prepare`
# verifies and what the build links against.
#
#   bash tools/vulkan-proof/shader-evidence.sh > transcript.txt
#
# It prints a transcript; docs/vulkan/shader-rebuilds-macos.md retains one.
# It opens no window, starts no session and reads no consent.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
set -a
# shellcheck disable=SC1091
. "$root/tools/ci-image/toolchain.pin"
set +a
[ "$(ghc --numeric-version)" = "$GHC_VERSION" ] || { echo "shader-evidence: ghc on PATH is not $GHC_VERSION" >&2; exit 2; }
[ "$(cabal --numeric-version)" = "$CABAL_VERSION" ] || { echo "shader-evidence: cabal on PATH is not $CABAL_VERSION" >&2; exit 2; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hetoimasia-shader-evidence.XXXXXX")"
work="$scratch/tree"
fixture="$scratch/fixture"
invocations="$scratch/invocations.log"
competing_log="$scratch/competing.log"
mkdir -p "$work" "$fixture/vulkan/bin" "$scratch/competing"
echo "scratch: $scratch"

# The candidate as Git sees it: tracked files and untracked files it does not
# ignore, so a generated fingerprint or build directory is never copied.
git -C "$root" ls-files -z --cached --others --exclude-standard \
  | (cd "$root" && xargs -0 tar cf - 2>/dev/null) | (cd "$work" && tar xf -)
echo "revision: $(git -C "$root" rev-parse HEAD)$(git -C "$root" diff --quiet HEAD || echo ' (dirty)')"

# The distribution is made now, from the copy as the candidate has it and
# before any step below edits it. The copy never held a generated fingerprint,
# so the tarballs carry only sources.
(cd "$work" && cabal sdist -v0 --project-file=cabal.project.vulkan --output-directory="$scratch/sdist" \
  hetoimasia-gpu-vulkan-native hetoimasia-foundation hetoimasia-gpu-vulkan-diagnostics \
  hetoimasia-gpu-vulkan-model hetoimasia-test-support)

native_prefix="${HETOIMASIA_NATIVE_PREFIX:-${XDG_CACHE_HOME:-$HOME/.cache}/hetoimasia/native/glfw}"
eval "$(python3 "$work/tools/native/native.py" prepare --prefix "$native_prefix" --build-dir "$work/dist-evidence")"
provisioned_wrapper="$HETOIMASIA_GLSLANG"
manifest_file="$native_prefix/hetoimasia-native-manifest.json"
read -r compiler compiler_sha256 < <(python3 - "$manifest_file" <<'PY'
import json, sys
glslang = json.load(open(sys.argv[1]))["vulkan"]["glslang"]
print(glslang["compiler"], glslang["compiler_sha256"])
PY
)
echo "native prefix: $native_prefix, written <prefix> below"
echo "provisioned wrapper: $provisioned_wrapper"
echo "pinned compiler: $compiler ($compiler_sha256)"

# A competing compiler, earlier on PATH than anything else, that records any
# use of it. Nothing may ever run it.
cat > "$scratch/competing/glslangValidator" <<EOF
#!/bin/sh
echo "competing glslangValidator ran: \$*" >> '$competing_log'
exit 1
EOF
chmod +x "$scratch/competing/glslangValidator"
export PATH="$scratch/competing:$PATH"
: > "$competing_log"

fixture_wrapper="$fixture/vulkan/bin/glslangValidator"
fixture_manifest="$fixture/hetoimasia-native-manifest.json"

# Write the fixture wrapper for a version label, and the manifest recording it.
make_fixture() {
  local version="$1"
  cat > "$fixture_wrapper" <<EOF
#!/usr/bin/env bash
# VK-9 verification fixture: the pinned compiler under the label $version, with
# every compile it runs logged. Not a provisioned wrapper.
set -euo pipefail
if [ "\${1:-}" = "--hetoimasia-identity" ]; then
  printf 'glslang %s\n' '$version'
  printf 'compiler %s\n' '$compiler'
  printf 'sha256 %s\n' '$compiler_sha256'
  exit 0
fi
stage=unknown; previous=""
for argument in "\$@"; do
  [ "\$previous" = "-S" ] && stage="\$argument"
  previous="\$argument"
done
echo "compile \$stage \$(basename "\${@: -1}")" >> '$invocations'
exec '$compiler' "\$@"
EOF
  chmod 755 "$fixture_wrapper"
  python3 - "$fixture_wrapper" "$fixture_manifest" "$version" "$compiler" "$compiler_sha256" <<'PY'
import hashlib, json, sys
wrapper, manifest, version, compiler, digest = sys.argv[1:]
with open(wrapper, "rb") as handle:
    wrapper_sha256 = hashlib.sha256(handle.read()).hexdigest()
document = {"vulkan": {"glslang": {"wrapper": wrapper, "wrapper_sha256": wrapper_sha256, "wrapper_mode": 493,
                                   "version": version, "compiler": compiler, "compiler_sha256": digest}}}
with open(manifest, "w") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
PY
}

cabal_flags=(
  --project-file=cabal.project.vulkan
  --builddir=dist-evidence
  --extra-lib-dirs="$HETOIMASIA_VULKAN_LIBDIR"
  --extra-include-dirs="$HETOIMASIA_VULKAN_INCLUDEDIR"
)
fingerprint="$work/packages/gpu-vulkan/native/shaders/toolchain.fingerprint"
export HETOIMASIA_GLSLANG="$fixture_wrapper"

generate() {
  (cd "$work" && cabal run -v0 "${cabal_flags[@]}" hetoimasia-gpu-vulkan-native:exe:hetoimasia-shader-fingerprint -- \
    --output "$fingerprint" --glslang "$fixture_wrapper" --native-manifest "$fixture_manifest") 2>&1 \
    | sed "s|$scratch|<scratch>|g; s/^/  generator: /"
  return "${PIPESTATUS[0]}"
}

build() {
  local output status
  set +e
  output="$(cd "$work" && cabal build "${cabal_flags[@]}" hetoimasia-gpu-vulkan-native:shader-tests 2>&1)"
  status=$?
  set -e
  if printf '%s\n' "$output" | grep -qE 'Up to date|Compiling Test\.Shader\.(Vertex|Fragment) '; then
    printf '%s\n' "$output" | grep -E 'Up to date|Compiling Test\.Shader\.(Vertex|Fragment) ' \
      | sed -E 's/^\[ *[0-9]+ of [0-9]+\] Compiling ([A-Za-z.]+) .*\) ?(\[.*\])?$/  recompiled \1 \2/; s/^Up to date$/  cabal: up to date/'
  else
    echo "  cabal ran GHC; no shader module recompiled"
  fi
  if [ "$status" -ne 0 ]; then
    echo "  build failed (exit $status); its diagnostic:"
    printf '%s\n' "$output" | grep -E 'shader toolchain is refused|glslangValidator wrapper|native manifest:|No other glslangValidator|did not compile|ERROR:' \
      | sed "s|$scratch|<scratch>|g; s/^ */    /" | sort -u || true
  fi
  if [ -s "$invocations" ]; then
    sed 's/^/  compiler: /' "$invocations"
  else
    echo "  compiler: not invoked"
  fi
  : > "$invocations"
  return 0
}

step() {
  echo
  echo "## $1"
  : > "$invocations"
}

make_fixture "15.0.0-fixture-a"

step "1. Cold build"
generate
build

step "2. Warm rebuild, nothing changed"
generate
build

step "3. The fragment shader's source file changes"
echo "// evidence edit" >> "$work/packages/gpu-vulkan/native/test/shaders/verification.frag"
generate
build

step "4. The fragment shader's transitive include changes"
echo "// evidence edit" >> "$work/packages/gpu-vulkan/native/test/shaders/include/verification_layout.glsl"
generate
build

step "5. The interpolated Haskell constant changes"
sed -i.bak 's/verificationMarker = 0x5EED1234/verificationMarker = 0x5EED1235/' \
  "$work/packages/gpu-vulkan/native/test/Test/Shader/Constants.hs"
generate
build

step "6. The compiler flags change (-V to -V100)"
sed -i.bak 's/^compilerFlags = \["-V"\]$/compilerFlags = ["-V100"]/' \
  "$work/packages/gpu-vulkan/native/shader-toolchain/Hetoimasia/GPU/Vulkan/Native/Shader/Toolchain.hs"
generate
build

step "7. The target environment changes (vulkan1.3 to vulkan1.2)"
sed -i.bak 's/^vulkan13 = TargetEnvironment "vulkan1.3"$/vulkan13 = TargetEnvironment "vulkan1.2"/' \
  "$work/packages/gpu-vulkan/native/shader-toolchain/Hetoimasia/GPU/Vulkan/Native/Shader/Toolchain.hs"
generate
build

step "8. The compiler identity changes (fixture a to fixture b)"
make_fixture "15.0.0-fixture-b"
generate
build

step "9. Warm rebuild after the identity change, nothing changed"
generate
build

step "10. The fingerprint's recorded compiler identity is edited, and the build runs without regenerating it"
sed -i.bak 's/^glslang 15.0.0-fixture-b$/glslang 15.0.0-fixture-c/' "$fingerprint"
build

step "11. The generator restores the fingerprint; nothing is recompiled"
generate
build

step "12. The wrapper is removed, with a competing glslangValidator first on PATH"
mv "$fixture_wrapper" "$fixture_wrapper.removed"
generate || echo "  generator refused (exit $?)"
echo "// evidence edit" >> "$work/packages/gpu-vulkan/native/test/shaders/verification.frag"
build
mv "$fixture_wrapper.removed" "$fixture_wrapper"

step "13. The wrapper is substituted, with the manifest left as it was"
echo "# substituted" >> "$fixture_wrapper"
generate || echo "  generator refused (exit $?)"
build
make_fixture "15.0.0-fixture-b"

step "14. The competing compiler on PATH"
if [ -s "$competing_log" ]; then
  echo "  it ran:"
  sed 's/^/    /' "$competing_log"
  exit 1
fi
echo "  never ran"

step "15. The package's source distribution, made before the steps above edited anything"
tar tzf "$scratch/sdist/hetoimasia-gpu-vulkan-native-0.1.0.0.tar.gz" \
  | grep -E '\.(frag|vert|glsl|fingerprint)$|fingerprint/Main.hs|shader-toolchain/' | sed 's/^/  /'

# Two extractions in different directories, each built from the tarballs alone
# with the provisioned prefix and the toolchain configuration the project files
# document: the index, the binding's constraints and macOS stanza, and the
# warning policy. Each generates its own fingerprint from the provisioned
# wrapper, builds, and runs the shader suite, which prints the embedded pair's
# digests.
export HETOIMASIA_GLSLANG="$provisioned_wrapper"
number=16
for extraction in first second; do
  step "$number. Build and test from the distribution, extracted as '$extraction'"
  number=$((number + 1))
  directory="$scratch/extracted-$extraction/nested-$extraction"
  mkdir -p "$directory"
  for tarball in "$scratch"/sdist/*.tar.gz; do
    tar xzf "$tarball" -C "$directory"
  done
  cp "$work/cabal.project.common" "$directory/cabal.project.common"
  python3 - "$work/cabal.project.vulkan" "$directory/cabal.project" <<'PY'
import sys
source, target = sys.argv[1:]
lines = open(source).read().splitlines()
out, skipping = [], False
for line in lines:
    if line.startswith("packages:"):
        out.append("packages: */*.cabal")
        skipping = True
        continue
    if skipping:
        if line.startswith("  ") and line.strip():
            continue
        skipping = False
    out.append(line)
open(target, "w").write("\n".join(out) + "\n")
PY
  native="$(ls -d "$directory"/hetoimasia-gpu-vulkan-native-*)"
  eval "$(python3 "$work/tools/native/native.py" prepare --prefix "$native_prefix" --build-dir "$directory/dist-newstyle")"
  (cd "$directory" && cabal run -v0 --extra-lib-dirs="$HETOIMASIA_VULKAN_LIBDIR" --extra-include-dirs="$HETOIMASIA_VULKAN_INCLUDEDIR" \
    hetoimasia-gpu-vulkan-native:exe:hetoimasia-shader-fingerprint -- --output "$native/shaders/toolchain.fingerprint") \
    | sed "s|$scratch|<scratch>|g; s|$native_prefix|<prefix>|g; s/^/  generator: /"
  (cd "$directory" && cabal test -v1 --extra-lib-dirs="$HETOIMASIA_VULKAN_LIBDIR" --extra-include-dirs="$HETOIMASIA_VULKAN_INCLUDEDIR" \
    --test-show-details=direct hetoimasia-gpu-vulkan-native:shader-tests 2>&1) \
    | grep -E 'embedded .* SPIR-V|examples, |Test suite shader-tests: ' | sed 's/^/  /'
done

echo
echo "scratch retained at $scratch"
