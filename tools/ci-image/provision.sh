#!/usr/bin/env bash
# Provision one stage of the Linux CI image. The Dockerfile runs each stage as
# its own layer; nothing here runs on an ordinary validation worker.
set -euo pipefail

recipe="$(cd "$(dirname "$0")/../.." && pwd)"
root=/opt/hetoimasia

stage="${1:?usage: provision.sh packages|toolchain|cabal|glfw|stamp FINGERPRINT}"

fetch() {
  local url="$1" sha="$2" target="$3"
  curl --fail --silent --show-error --location --retry 3 --output "$target" "$url"
  echo "$sha  $target" | sha256sum --check --strict -
}

case "$stage" in
  packages)
    apt-get update
    # C build prerequisites, the libraries GHC's binary distribution links, the
    # tools actions need inside a container (git for checkout, zstd for the
    # cache), the tools the workflow tests' shipped steps and process checks
    # call (jq, and procps for kill and ps), the X11 development and runtime
    # libraries GLFW builds against, and the display packages only the native
    # worker's tools/display/x11.sh starts: the Xvfb server, the Openbox window
    # manager, and the xdpyinfo and xprop readiness probes. Nothing here starts
    # a display.
    apt-get install --yes --no-install-recommends \
      binutils build-essential ca-certificates cmake curl git jq pkg-config \
      procps python3 unzip xz-utils zstd \
      libffi-dev libgmp-dev libncurses-dev libnuma-dev zlib1g-dev \
      libx11-dev libxcursor-dev libxext-dev libxi-dev libxinerama-dev libxrandr-dev \
      openbox x11-utils xvfb
    rm -rf /var/lib/apt/lists/*
    # The resolved package manifest is retained: input hashes cannot promise a
    # byte-identical rebuild once the upstream archive moves.
    dpkg-query -W -f='${Package} ${Version}\n' | sort > "$root/packages.txt"
    ;;
  toolchain)
    set -a
    # shellcheck disable=SC1091
    . "$recipe/tools/ci-image/toolchain.pin"
    set +a
    scratch="$(mktemp -d)"
    fetch "$GHC_URL" "$GHC_SHA256" "$scratch/ghc.tar.xz"
    mkdir "$scratch/ghc"
    tar -xJf "$scratch/ghc.tar.xz" -C "$scratch/ghc"
    bindist="$(find "$scratch/ghc" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    (cd "$bindist" && ./configure --prefix="$root/ghc" && make install)
    fetch "$CABAL_URL" "$CABAL_SHA256" "$scratch/cabal.tar.xz"
    mkdir "$scratch/cabal"
    tar -xJf "$scratch/cabal.tar.xz" -C "$scratch/cabal"
    install -D -m 0755 "$(find "$scratch/cabal" -type f -name cabal | head -n 1)" "$root/cabal-install/bin/cabal"
    rm -rf "$scratch"
    test "$(ghc --numeric-version)" = "$GHC_VERSION"
    test "$(cabal --numeric-version)" = "$CABAL_VERSION"
    ;;
  cabal)
    mkdir -p "$CABAL_DIR/store"
    cabal user-config init
    cabal user-config update --augment "store-dir: $CABAL_DIR/store"
    test "$(cabal path --store-dir)" = "$CABAL_DIR/store"
    # The Hackage index snapshot; cabal.project's index-state selects from it.
    cabal update
    ;;
  glfw)
    python3 "$recipe/tools/native/native.py" build --prefix "$HETOIMASIA_NATIVE_PREFIX" --source-cache /tmp/glfw-sources
    python3 "$recipe/tools/native/native.py" link-check --prefix "$HETOIMASIA_NATIVE_PREFIX"
    rm -rf /tmp/glfw-sources
    ;;
  stamp)
    fingerprint="${2:?the recipe fingerprint is required}"
    case "$fingerprint" in
      *[!0-9a-f]*|'') echo "provision.sh: $fingerprint is not a recipe fingerprint" >&2; exit 2 ;;
    esac
    test "${#fingerprint}" -eq 64
    # The image records its own recipe fingerprint and native manifest hash, and
    # deliberately never its digest, which does not exist until it is pushed.
    python3 - "$fingerprint" <<'PY'
import hashlib, json, subprocess, sys
fingerprint = sys.argv[1]
manifest = "/opt/hetoimasia/native/glfw/hetoimasia-native-manifest.json"
with open(manifest, "rb") as handle:
    native = hashlib.sha256(handle.read()).hexdigest()
version = lambda tool: subprocess.run([tool, "--numeric-version"], capture_output=True, text=True, check=True).stdout.strip()
document = {
    "schema_version": 1,
    "recipe_fingerprint": fingerprint,
    "native_manifest": native,
    "ghc": version("ghc"),
    "cabal": version("cabal"),
}
with open("/opt/hetoimasia/image.json", "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
    ;;
  *)
    echo "provision.sh: unknown stage $stage" >&2
    exit 2
    ;;
esac
