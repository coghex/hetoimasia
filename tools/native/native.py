#!/usr/bin/env python3
"""Build, record, and check the private GLFW prefix every native build uses.

One recipe serves both places GLFW is compiled: a developer's local macOS
prefix and the copy baked into the Linux CI image. It fetches the upstream
archive ``glfw.pin`` names, refuses it unless its SHA-256 matches, and builds
only a static, position-independent archive into a private prefix whose library
directory is ``lib``.

A prefix is only as good as the configuration that produced it, so the build
writes a *native manifest* beside it: the GLFW version and source checksum, the
recipe fingerprint, the native identity (platform, architecture, C compiler,
SDK, deployment target, and effective build options), and the link requirements
``pkg-config --libs --static glfw3`` derives from the generated ``glfw3.pc``.
``check`` accepts a prefix only when all of that still holds for this machine,
and never falls back to a GLFW a package manager happens to supply.

It depends on Python 3, and on CMake and ``pkg-config`` for the commands that
need them. See ``docs/validation.md`` for the developer instructions.

Exit status: ``0`` on success, ``1`` when a check or link check fails, and ``2``
for a configuration or usage diagnostic.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

# A one-shot tool must not write into the checkout it runs from.
sys.dont_write_bytecode = True

RECIPE_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
PIN_FILE = os.path.join(RECIPE_DIRECTORY, "glfw.pin")

# The files whose bytes decide what the recipe builds. The fingerprint is taken
# over these exact names so a copy of the recipe inside the image fingerprints
# identically to the checkout it was copied from.
RECIPE_FILES = ("glfw.pin", "native.py")

MANIFEST_NAME = "hetoimasia-native-manifest.json"
MANIFEST_SCHEMA_VERSION = 1

# The stamp a build directory carries once products in it have been linked
# against one manifest. Products linked against another native configuration are
# not reused, so a stamp naming a different manifest is a refusal.
BUILD_STAMP_NAME = "hetoimasia-native.json"

PREREQUISITES = "install CMake and pkg-config first (on macOS: brew install cmake pkgconf)"

# Variables that would let a link or a run find a library somewhere other than
# where the link flags point. The link check scrubs them so a success proves the
# flags alone were enough.
LIBRARY_PATH_VARIABLES = (
    "LIBRARY_PATH",
    "LD_LIBRARY_PATH",
    "LD_RUN_PATH",
    "DYLD_LIBRARY_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH",
    "DYLD_INSERT_LIBRARIES",
)


class NativeError(Exception):
    """A diagnostic reported instead of a result."""

    def __init__(self, message: str, status: int = 2) -> None:
        super().__init__(message)
        self.status = status


# --------------------------------------------------------------------------
# Pins and fingerprints


def read_pin(path: str = PIN_FILE) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        raise NativeError(f"cannot read the native pin {path}: {error}") from error
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        name, separator, value = stripped.partition("=")
        if not separator or not name:
            raise NativeError(f"{path}:{number}: expected NAME=VALUE, not {stripped!r}")
        values[name] = value
    for required in ("GLFW_VERSION", "GLFW_URL", "GLFW_SHA256", "MACOS_DEPLOYMENT_TARGET"):
        if not values.get(required):
            raise NativeError(f"{path} does not pin {required}")
    return values


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def recipe_fingerprint() -> str:
    digest = hashlib.sha256()
    for name in RECIPE_FILES:
        with open(os.path.join(RECIPE_DIRECTORY, name), "rb") as handle:
            content = handle.read()
        digest.update(name.encode("utf-8") + b"\0" + hashlib.sha256(content).hexdigest().encode("ascii") + b"\n")
    return digest.hexdigest()


def canonical(document: dict) -> bytes:
    return json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8")


def manifest_hash(path: str) -> str:
    """The native-manifest identity: a SHA-256 over the manifest file's bytes."""
    return sha256_file(path)


# --------------------------------------------------------------------------
# Native identity


def probe(command: list[str]) -> str:
    """The first line a probe prints, or a diagnostic naming the missing tool."""
    try:
        process = subprocess.run(command, capture_output=True, check=False)
    except OSError as error:
        raise NativeError(f"cannot run {command[0]} to identify the native toolchain: {error}") from error
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise NativeError(f"{' '.join(command)} exited {process.returncode}: {detail or 'no output'}")
    lines = process.stdout.decode("utf-8", errors="replace").strip().splitlines()
    return lines[0].strip() if lines else ""


def compiler() -> str:
    return os.environ.get("CC") or "cc"


def build_type() -> str:
    return os.environ.get("HETOIMASIA_GLFW_BUILD_TYPE") or "Release"


def build_options(target: str, architecture: str, deployment_target: str) -> list[str]:
    """The effective CMake options the recipe configures GLFW with."""
    options = [
        "BUILD_SHARED_LIBS=OFF",
        "CMAKE_BUILD_TYPE=" + build_type(),
        "CMAKE_INSTALL_LIBDIR=lib",
        "CMAKE_POSITION_INDEPENDENT_CODE=ON",
        "GLFW_BUILD_DOCS=OFF",
        "GLFW_BUILD_EXAMPLES=OFF",
        "GLFW_BUILD_TESTS=OFF",
        "GLFW_INSTALL=ON",
    ]
    if target == "Darwin":
        options += [
            "CMAKE_OSX_ARCHITECTURES=" + architecture,
            "CMAKE_OSX_DEPLOYMENT_TARGET=" + deployment_target,
            "GLFW_BUILD_COCOA=ON",
        ]
    elif target == "Linux":
        options += ["GLFW_BUILD_WAYLAND=OFF", "GLFW_BUILD_X11=ON"]
    else:
        raise NativeError(f"the native recipe supports Darwin and Linux, not {target!r}")
    return sorted(options)


def native_identity(target: str, pin: dict[str, str]) -> dict:
    """Every input besides the source pin that decides what a prefix contains.

    GLFW's version alone does not establish compatibility: the same source built
    by another compiler, against another SDK, for another architecture or
    deployment target, or with other options is a different archive, and Haskell
    products linked against one are not products of the other.
    """
    cc = compiler()
    architecture = probe(["uname", "-m"])
    if target == "Darwin":
        sdk = "macosx {} ({})".format(
            probe(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
            probe(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
        )
        deployment_target = os.environ.get("MACOSX_DEPLOYMENT_TARGET") or pin["MACOS_DEPLOYMENT_TARGET"]
    else:
        sdk = probe(["getconf", "GNU_LIBC_VERSION"])
        deployment_target = "none"
    return {
        "platform": target,
        "architecture": architecture,
        "c_compiler": f"{probe([cc, '--version'])} [{probe([cc, '-dumpmachine'])}]",
        "sdk": sdk,
        "deployment_target": deployment_target,
        "build_options": build_options(target, architecture, deployment_target),
    }


def host_platform() -> str:
    return platform.system()


# --------------------------------------------------------------------------
# pkg-config


def require_tool(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise NativeError(f"{name} was not found on PATH; {PREREQUISITES}")
    return found


def pkg_config_environment(prefix: str) -> dict[str, str]:
    environment = dict(os.environ)
    inherited = environment.get("PKG_CONFIG_PATH")
    own = os.path.join(prefix, "lib", "pkgconfig")
    environment["PKG_CONFIG_PATH"] = own + (os.pathsep + inherited if inherited else "")
    return environment


def pkg_config(prefix: str | None, *arguments: str) -> str:
    executable = require_tool("pkg-config")
    environment = pkg_config_environment(prefix) if prefix else dict(os.environ)
    process = subprocess.run(
        (executable,) + arguments, capture_output=True, check=False, env=environment
    )
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise NativeError(
            f"pkg-config {' '.join(arguments)} failed: {detail or 'no output'}", status=1
        )
    return process.stdout.decode("utf-8", errors="replace").strip()


def resolved_metadata(prefix: str) -> dict:
    """What pkg-config resolves for glfw3 with this prefix first on its path."""
    return {
        "prefix": pkg_config(prefix, "--variable=prefix", "glfw3"),
        "modversion": pkg_config(prefix, "--modversion", "glfw3"),
        "cflags": shlex.split(pkg_config(prefix, "--cflags", "glfw3")),
        "libs_static": shlex.split(pkg_config(prefix, "--libs", "--static", "glfw3")),
    }


# --------------------------------------------------------------------------
# Prefix locations


def default_prefix() -> str:
    configured = os.environ.get("HETOIMASIA_NATIVE_PREFIX")
    if configured:
        return configured
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(cache, "hetoimasia", "native", "glfw")


def archive_path(prefix: str) -> str:
    return os.path.join(prefix, "lib", "libglfw3.a")


def manifest_path(prefix: str) -> str:
    return os.path.join(prefix, MANIFEST_NAME)


def normalized(path: str) -> str:
    return os.path.realpath(os.path.abspath(path))


# --------------------------------------------------------------------------
# Recording and checking


def record(prefix: str, target: str) -> str:
    """Write the manifest describing the prefix as it stands, for this identity."""
    pin = read_pin()
    prefix = normalized(prefix)
    archive = archive_path(prefix)
    if not os.path.isfile(archive):
        raise NativeError(f"{prefix} holds no static archive at lib/libglfw3.a to record")
    metadata = resolved_metadata(prefix)
    manifest = {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "library": "glfw3",
        "glfw_version": pin["GLFW_VERSION"],
        "source_url": pin["GLFW_URL"],
        "source_sha256": pin["GLFW_SHA256"],
        "recipe_fingerprint": recipe_fingerprint(),
        "identity": native_identity(target, pin),
        "prefix": prefix,
        "archive_sha256": sha256_file(archive),
        "pkg_config": metadata,
    }
    target_path = manifest_path(prefix)
    with open(target_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return target_path


def shared_libraries(prefix: str) -> list[str]:
    directory = os.path.join(prefix, "lib")
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    return sorted(
        name for name in names if name.startswith("libglfw") and (".so" in name or name.endswith(".dylib"))
    )


def check(prefix: str, target: str, build_directory: str | None) -> dict:
    """Refuse the prefix unless it is exactly what this configuration would build.

    Every refusal names what differs and how to repair it. Nothing here selects
    another GLFW: an absent or incompatible prefix is a configuration failure.
    """
    require_tool("pkg-config")
    pin = read_pin()
    prefix = normalized(prefix)
    rebuild = f"rebuild it with: python3 tools/native/native.py build --prefix {prefix}"
    manifest_file = manifest_path(prefix)
    if not os.path.isfile(manifest_file):
        system = system_glfw()
        note = f"; a system GLFW {system} is visible to pkg-config and is deliberately not used" if system else ""
        raise NativeError(f"no private GLFW prefix is recorded at {prefix}{note}; {rebuild}", status=1)
    try:
        with open(manifest_file, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise NativeError(f"the native manifest {manifest_file} is unreadable ({error}); {rebuild}", status=1) from error
    if not isinstance(manifest, dict) or manifest.get("schema_version") != MANIFEST_SCHEMA_VERSION:
        raise NativeError(f"the native manifest {manifest_file} is not a schema {MANIFEST_SCHEMA_VERSION} manifest; {rebuild}", status=1)

    problems: list[str] = []
    for field, expected in (
        ("glfw_version", pin["GLFW_VERSION"]),
        ("source_url", pin["GLFW_URL"]),
        ("source_sha256", pin["GLFW_SHA256"]),
        ("recipe_fingerprint", recipe_fingerprint()),
        ("prefix", prefix),
    ):
        if manifest.get(field) != expected:
            problems.append(f"{field} is {manifest.get(field)!r}, expected {expected!r}")
    identity = native_identity(target, pin)
    recorded_identity = manifest.get("identity")
    if not isinstance(recorded_identity, dict):
        problems.append("the manifest records no native identity")
    else:
        for field in sorted(set(identity) | set(recorded_identity)):
            if recorded_identity.get(field) != identity.get(field):
                problems.append(
                    f"native {field} is {recorded_identity.get(field)!r}, "
                    f"but this configuration is {identity.get(field)!r}"
                )
    if problems:
        raise NativeError(
            f"the prefix at {prefix} was built for a different configuration: "
            + "; ".join(problems) + f"; {rebuild}",
            status=1,
        )

    archive = archive_path(prefix)
    if not os.path.isfile(archive) or sha256_file(archive) != manifest.get("archive_sha256"):
        raise NativeError(f"the static archive in {prefix} is missing or is not the recorded one; {rebuild}", status=1)
    shared = shared_libraries(prefix)
    if shared:
        raise NativeError(f"{prefix} carries shared GLFW libraries ({', '.join(shared)}); the recipe installs only the static archive; {rebuild}", status=1)

    resolved = resolved_metadata(prefix)
    if normalized(resolved["prefix"]) != prefix:
        raise NativeError(
            f"pkg-config resolves glfw3 from {resolved['prefix']!r} rather than the private prefix {prefix}; "
            f"a substituted or system GLFW is never used; {rebuild}",
            status=1,
        )
    version = resolved["modversion"]
    if version != pin["GLFW_VERSION"] and not version.startswith(pin["GLFW_VERSION"] + "."):
        raise NativeError(f"pkg-config reports glfw3 {version}, not the pinned {pin['GLFW_VERSION']}; {rebuild}", status=1)
    recorded = manifest.get("pkg_config")
    if not isinstance(recorded, dict):
        raise NativeError(f"the manifest records no pkg-config metadata; {rebuild}", status=1)
    drift = [
        f"{field}: recorded {recorded.get(field)!r}, generated {resolved[field]!r}"
        for field in ("modversion", "cflags", "libs_static")
        if recorded.get(field) != resolved[field]
    ]
    if drift:
        raise NativeError(
            "native manifest drift: the generated glfw3.pc no longer matches the recorded "
            "requirements (" + "; ".join(drift) + f"); {rebuild}",
            status=1,
        )

    identity_hash = manifest_hash(manifest_file)
    if build_directory:
        stamp = os.path.join(build_directory, BUILD_STAMP_NAME)
        if os.path.isfile(stamp):
            try:
                with open(stamp, encoding="utf-8") as handle:
                    linked = json.load(handle).get("native_manifest")
            except (OSError, json.JSONDecodeError, AttributeError):
                linked = None
            if linked != identity_hash:
                raise NativeError(
                    f"build products in {build_directory} were linked against native manifest "
                    f"{str(linked)[:12]}, not the current {identity_hash[:12]}; remove {build_directory} "
                    "so nothing linked against the old native configuration is reused",
                    status=1,
                )
    return {"manifest": manifest, "native_manifest": identity_hash, "prefix": prefix}


def system_glfw() -> str | None:
    try:
        return pkg_config(None, "--modversion", "glfw3")
    except NativeError:
        return None


def stamp_build_directory(build_directory: str, identity_hash: str) -> None:
    os.makedirs(build_directory, exist_ok=True)
    with open(os.path.join(build_directory, BUILD_STAMP_NAME), "w", encoding="utf-8") as handle:
        json.dump({"native_manifest": identity_hash}, handle)
        handle.write("\n")


# --------------------------------------------------------------------------
# Building


def run_step(command: list[str], cwd: str | None = None) -> None:
    print("native: " + " ".join(shlex.quote(part) for part in command), flush=True)
    process = subprocess.run(command, cwd=cwd, check=False)
    if process.returncode != 0:
        raise NativeError(f"{command[0]} exited {process.returncode}", status=1)


def fetch_source(pin: dict[str, str], cache: str) -> str:
    os.makedirs(cache, exist_ok=True)
    target = os.path.join(cache, f"glfw-{pin['GLFW_VERSION']}-{pin['GLFW_SHA256'][:12]}.zip")
    if not os.path.isfile(target) or sha256_file(target) != pin["GLFW_SHA256"]:
        partial = target + ".partial"
        print(f"native: fetching {pin['GLFW_URL']}", flush=True)
        try:
            with urllib.request.urlopen(pin["GLFW_URL"], timeout=120) as response, open(partial, "wb") as handle:
                shutil.copyfileobj(response, handle)
        except OSError as error:
            raise NativeError(f"cannot fetch {pin['GLFW_URL']}: {error}", status=1) from error
        actual = sha256_file(partial)
        if actual != pin["GLFW_SHA256"]:
            os.remove(partial)
            raise NativeError(
                f"{pin['GLFW_URL']} has SHA-256 {actual}, not the pinned {pin['GLFW_SHA256']}", status=1
            )
        os.replace(partial, target)
    return target


def build(prefix: str, target: str, source_cache: str) -> str:
    if target != host_platform():
        raise NativeError(f"the recipe builds for the host platform {host_platform()}, not {target}")
    require_tool("cmake")
    require_tool("pkg-config")
    pin = read_pin()
    prefix = normalized(prefix)
    identity = native_identity(target, pin)
    archive = fetch_source(pin, source_cache)
    with tempfile.TemporaryDirectory(prefix="hetoimasia-glfw-") as scratch:
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(scratch)
        source = os.path.join(scratch, f"glfw-{pin['GLFW_VERSION']}")
        if not os.path.isdir(source):
            raise NativeError(f"{archive} does not unpack to glfw-{pin['GLFW_VERSION']}/", status=1)
        # A fresh prefix every time: a rebuild must not inherit anything an
        # earlier configuration installed there.
        if os.path.lexists(prefix):
            shutil.rmtree(prefix)
        binary = os.path.join(scratch, "build")
        configure = ["cmake", "-S", source, "-B", binary, "-DCMAKE_INSTALL_PREFIX=" + prefix]
        configure += ["-D" + option for option in identity["build_options"]]
        if os.environ.get("CC"):
            configure.append("-DCMAKE_C_COMPILER=" + os.environ["CC"])
        environment_target = identity["deployment_target"]
        if target == "Darwin":
            os.environ["MACOSX_DEPLOYMENT_TARGET"] = environment_target
        run_step(configure)
        run_step(["cmake", "--build", binary, "--parallel"])
        run_step(["cmake", "--install", binary])
    return record(prefix, target)


# --------------------------------------------------------------------------
# Link check

# GLFW_INCLUDE_NONE keeps the header from pulling in an OpenGL header: the
# consumer uses no client API, and the image deliberately carries none.
CONSUMER = r"""
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#include <stdio.h>

int main(void)
{
    int major, minor, revision;
    glfwGetVersion(&major, &minor, &revision);
    printf("%d.%d.%d %s\n", major, minor, revision, glfwGetVersionString());
    return 0;
}
"""


def defined_symbols(path: str) -> str:
    return subprocess.run(["nm", path], capture_output=True, check=False).stdout.decode("utf-8", errors="replace")


def dynamic_dependencies(path: str, target: str) -> str:
    command = ["otool", "-L", path] if target == "Darwin" else ["readelf", "-d", path]
    process = subprocess.run(command, capture_output=True, check=False)
    if process.returncode != 0:
        raise NativeError(f"{' '.join(command)} exited {process.returncode}", status=1)
    return process.stdout.decode("utf-8", errors="replace")


def link_check(prefix: str, target: str) -> str:
    """Prove a real consumer links against the private archive and runs.

    The consumer calls ``glfwGetVersion`` and ``glfwGetVersionString``, which
    need no initialization, window, or display. The link uses only the flags
    the manifest records, with every library search variable scrubbed, and the
    result must define the symbol itself and name no GLFW shared library among
    its dynamic dependencies — which is what shows the static archive supplied
    it rather than some other GLFW the linker could find.
    """
    checked = check(prefix, target, None)
    manifest = checked["manifest"]
    flags = manifest["pkg_config"]
    symbol = "_glfwGetVersionString" if target == "Darwin" else "glfwGetVersionString"
    if f"T {symbol}" not in defined_symbols(archive_path(checked["prefix"])):
        raise NativeError(f"the private archive does not define {symbol}", status=1)
    environment = {name: value for name, value in os.environ.items() if name not in LIBRARY_PATH_VARIABLES}
    with tempfile.TemporaryDirectory(prefix="hetoimasia-glfw-link-") as scratch:
        source = os.path.join(scratch, "consumer.c")
        executable = os.path.join(scratch, "consumer")
        with open(source, "w", encoding="utf-8") as handle:
            handle.write(CONSUMER)
        command = [compiler(), source, *flags["cflags"], "-o", executable, *flags["libs_static"]]
        print("native: " + " ".join(shlex.quote(part) for part in command), flush=True)
        linked = subprocess.run(command, capture_output=True, check=False, env=environment)
        if linked.returncode != 0:
            raise NativeError(
                "the native consumer did not link against the recorded flags:\n"
                + linked.stderr.decode("utf-8", errors="replace"),
                status=1,
            )
        if f"T {symbol}" not in defined_symbols(executable):
            raise NativeError(f"the linked consumer does not define {symbol} itself", status=1)
        dependencies = dynamic_dependencies(executable, target)
        # `otool -L` names the executable itself on its first line, and that
        # path is wherever the scratch directory landed; only the lines after
        # it are dependencies. `readelf -d` lists them as NEEDED entries.
        listed = dependencies.splitlines()[1:] if target == "Darwin" else dependencies.splitlines()
        if any("libglfw" in line.lower() for line in listed):
            raise NativeError("the linked consumer depends on a shared GLFW library:\n" + dependencies, status=1)
        ran = subprocess.run([executable], capture_output=True, check=False, env=environment)
        output = ran.stdout.decode("utf-8", errors="replace").strip()
        expected = manifest["glfw_version"]
        reported = output.split(" ", 1)[0]
        if ran.returncode != 0 or not (reported == expected or reported.startswith(expected + ".")):
            raise NativeError(
                f"the native consumer exited {ran.returncode} reporting {output!r}, not GLFW {expected}",
                status=1,
            )
    return output


# --------------------------------------------------------------------------
# Entry point


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="native.py", description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--platform",
        default=None,
        help="the target platform the identity describes (default: this host)",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    def with_prefix(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--prefix", default=None, help="the private prefix (default: $HETOIMASIA_NATIVE_PREFIX or ~/.cache/hetoimasia/native/glfw)")

    built = commands.add_parser("build", help="fetch, verify, build, and record the private prefix")
    with_prefix(built)
    built.add_argument("--source-cache", default=None, help="where the verified source archive is kept")
    recorded = commands.add_parser("record", help="write the native manifest for an existing prefix")
    with_prefix(recorded)
    checked = commands.add_parser("check", help="refuse the prefix unless it matches this configuration")
    with_prefix(checked)
    checked.add_argument("--build-dir", default=None, help="a build directory whose linked products must match")
    prepared = commands.add_parser("prepare", help="check, stamp the build directory, and print the environment")
    with_prefix(prepared)
    prepared.add_argument("--build-dir", default="dist-newstyle", help="the build directory to stamp")
    commands.add_parser("identity", help="print this configuration's native identity")
    linked = commands.add_parser("link-check", help="link and run a real consumer against the archive")
    with_prefix(linked)
    toolchain = commands.add_parser("toolchain", help="print the native-manifest toolchain entry")
    with_prefix(toolchain)
    commands.add_parser("fingerprint", help="print the native recipe fingerprint")

    arguments = parser.parse_args(argv)
    target = arguments.platform or host_platform()
    prefix = getattr(arguments, "prefix", None) or default_prefix()

    if arguments.command == "build":
        cache = arguments.source_cache or os.path.join(os.path.dirname(normalized(prefix)), "sources")
        print(f"native: recorded {build(prefix, target, cache)}")
    elif arguments.command == "record":
        print(f"native: recorded {record(prefix, target)}")
    elif arguments.command == "check":
        result = check(prefix, target, arguments.build_dir)
        print(f"native: {result['prefix']} matches this configuration (manifest {result['native_manifest'][:12]})")
    elif arguments.command == "prepare":
        result = check(prefix, target, arguments.build_dir)
        stamp_build_directory(arguments.build_dir, result["native_manifest"])
        print("export PKG_CONFIG_PATH=" + shlex.quote(pkg_config_environment(result["prefix"])["PKG_CONFIG_PATH"]))
    elif arguments.command == "identity":
        print(json.dumps(native_identity(target, read_pin()), indent=2, sort_keys=True))
    elif arguments.command == "link-check":
        print(f"native: link check passed: {link_check(prefix, target)}")
    elif arguments.command == "toolchain":
        print("native-manifest=" + check(prefix, target, None)["native_manifest"])
    elif arguments.command == "fingerprint":
        print(recipe_fingerprint())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except NativeError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(failure.status)
