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
    set -a
    # shellcheck disable=SC1091
    . "$recipe/tools/ci-image/compositor.pin"
    # shellcheck disable=SC1091
    . "$recipe/tools/native/vulkan.pin"
    set +a
    apt-get update
    # C build prerequisites, the libraries GHC's binary distribution links, the
    # tools actions need inside a container (git for checkout, zstd for the
    # cache), the tools the workflow tests' shipped steps and process checks
    # call (jq, and procps for kill and ps), the X11 and Wayland development
    # libraries GLFW builds both of its Linux backends against — libwayland-dev
    # also supplies the wayland-scanner the Wayland backend's protocol files are
    # generated with — and the display packages only the native worker's
    # tools/display/ helpers start: the Xvfb server, the Openbox window manager,
    # the xdpyinfo and xprop readiness probes, the pinned Weston compositor, and
    # the wayland-info client the Wayland helper proves readiness by connecting
    # with. Nothing here starts a display or a compositor.
    #
    # Weston and every Vulkan input are installed at one exact revision each. An
    # `=` constraint apt cannot satisfy fails this layer rather than silently
    # taking a newer package, which is what keeps a driver or a layer upgrade an
    # explicit requalification rather than something a rebuild does on its own.
    #
    # The Vulkan set is the loader and its headers, Mesa — whose Lavapipe is the
    # software driver D-10 selects, and which `tools/native/vulkan.pin` names by
    # manifest rather than letting the recipe pick from the eight that package
    # installs — the Khronos validation layers, and the pinned glslang compiler.
    # Nothing here compiles a shader; the compiler is provisioned for D-11 and
    # VK-9 to inherit already qualified.
    apt-get install --yes --no-install-recommends \
      binutils build-essential ca-certificates cmake curl git jq pkg-config \
      procps python3 unzip xz-utils zstd \
      libffi-dev libgmp-dev libncurses-dev libnuma-dev zlib1g-dev \
      libx11-dev libxcursor-dev libxext-dev libxi-dev libxinerama-dev libxrandr-dev \
      libwayland-dev libxkbcommon-dev \
      openbox x11-utils xvfb \
      "weston=$WESTON_VERSION" wayland-utils \
      "$LINUX_LOADER_PACKAGE=$LINUX_LOADER_PACKAGE_VERSION" \
      "$LINUX_HEADERS_PACKAGE=$LINUX_HEADERS_PACKAGE_VERSION" \
      "$LINUX_DRIVER_PACKAGE=$LINUX_DRIVER_PACKAGE_VERSION" \
      "$LINUX_LAYER_PACKAGE=$LINUX_LAYER_PACKAGE_VERSION" \
      "$LINUX_GLSLANG_PACKAGE=$LINUX_GLSLANG_PACKAGE_VERSION"
    rm -rf /var/lib/apt/lists/*
    # Every installed revision is read back from dpkg rather than assumed from
    # the constraint, so what the image carries is what the pin names.
    installed="$(dpkg-query --show --showformat='${Version}' weston)"
    test "$installed" = "$WESTON_VERSION"
    for pinned in \
      "$LINUX_LOADER_PACKAGE=$LINUX_LOADER_PACKAGE_VERSION" \
      "$LINUX_HEADERS_PACKAGE=$LINUX_HEADERS_PACKAGE_VERSION" \
      "$LINUX_DRIVER_PACKAGE=$LINUX_DRIVER_PACKAGE_VERSION" \
      "$LINUX_LAYER_PACKAGE=$LINUX_LAYER_PACKAGE_VERSION" \
      "$LINUX_GLSLANG_PACKAGE=$LINUX_GLSLANG_PACKAGE_VERSION"; do
      name="${pinned%%=*}"
      want="${pinned#*=}"
      have="$(dpkg-query --show --showformat='${Version}' "$name")"
      if [ "$have" != "$want" ]; then
        echo "provision.sh: $name $have is installed, not the pinned $want" >&2
        exit 1
      fi
    done
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
package = lambda name: subprocess.run(
    ["dpkg-query", "--show", "--showformat=${Version}", name], capture_output=True, text=True, check=True
).stdout.strip()
# The Vulkan identities the prefix recorded, read through the recipe that wrote
# them so the image and a worker arrive at one spelling rather than two.
sys.dont_write_bytecode = True
sys.path.insert(0, "/opt/hetoimasia/recipe/tools/native")
import vulkan  # noqa: E402

document = {
    "schema_version": 1,
    "recipe_fingerprint": fingerprint,
    "native_manifest": native,
    **vulkan.toolchain_entries(vulkan.recorded_from(manifest)),
    "ghc": version("ghc"),
    "cabal": version("cabal"),
    # The compositor is identified by its installed package revision, which is
    # what a worker can verify; `weston --version` reports neither the Ubuntu
    # revision nor which package supplied the binary.
    "weston": package("weston"),
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
