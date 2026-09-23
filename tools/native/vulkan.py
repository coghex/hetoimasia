#!/usr/bin/env python3
"""Provision, record, and check the Vulkan inputs the private native prefix owns.

One recipe serves both places a Vulkan runtime is established: a developer's
local macOS prefix and the copy baked into the Linux CI image. ``vulkan.pin``
names every input on each platform — the loader, the driver, the Khronos
validation layer, and the glslang compiler — and this module locates exactly
those, qualifies each one's identity, and installs a *project-managed Vulkan
prefix* at ``<prefix>/vulkan`` that the rest of the repository points at:

- ``lib/pkgconfig/vulkan.pc`` describes the qualified loader, so the binding's
  own loader discovery resolves this prefix rather than whatever a machine or
  a distribution happens to offer;
- ``share/vulkan/icd.d/`` holds exactly one driver manifest and
  ``share/vulkan/explicit_layer.d/`` exactly one layer manifest, both written
  here from the qualified originals. ``VK_DRIVER_FILES`` names that one
  driver manifest. ``VK_LAYER_PATH`` names a directory the loader searches,
  so :func:`verify` holds it to exactly the recorded manifests and refuses
  any other entry beside them;
- ``bin/glslangValidator`` is a wrapper that runs the qualified compiler by
  absolute path and can report its identity without compiling anything.

On macOS the loader is *copied* into the prefix and given an absolute install
name, so a consumer links it without an rpath and without naming a machine
path; everything else is *referenced* by absolute path. On Linux every input is
referenced where its pinned package installed it. Either way the manifest
records what was actually resolved, and :func:`verify` re-reads and re-hashes
each file rather than trusting what was recorded.

Nothing here searches, and nothing falls back: a missing, unreadable, or
substituted input is refused with a diagnosis naming what the machine holds.
``HETOIMASIA_VULKAN_*`` overrides relocate an input without waiving its
qualification — an override locates, the pin decides.

See ``docs/validation.md`` for the developer instructions and ``docs/toolchain.md``
for loader discovery on each platform.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess

# A one-shot tool must not write into the checkout it runs from.
RECIPE_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
PIN_NAME = "vulkan.pin"
PIN_FILE = os.path.join(RECIPE_DIRECTORY, PIN_NAME)

# Where the provisioned Vulkan prefix sits inside the native prefix. It is a
# subdirectory rather than a sibling so one ``--prefix`` names everything a
# native build needs, and so one manifest describes all of it.
VULKAN_DIRECTORY = "vulkan"

# What `-lvulkan` actually opens. The linker looks for the unversioned name
# first, so this link — not the versioned file it points at — is the loader's
# discovery route, and it is recorded and verified as its own input. On macOS
# the prefix writes it beside its copy of the loader; on Linux it is the
# development package's link beside the referenced loader, and it is qualified
# as resolving to that loader before anything is provisioned.
LOADER_LINK = "libvulkan.dylib"
LINUX_LOADER_LINK = "libvulkan.so"
LOADER_FILE = "libvulkan.1.dylib"

# The wrapper's own flag. It is deliberately not a glslang flag: the wrapper
# answers it itself and never reaches the compiler, so the identity can be read
# from a machine where the compiler would refuse to run at all.
IDENTITY_FLAG = "--hetoimasia-identity"

# The four inputs, in the order a diagnosis lists them.
INPUTS = ("loader", "driver", "layer", "glslang")

# Environment variables that relocate one input. Each locates a file; none of
# them waives the identity the pin names for it.
OVERRIDES = {
    "loader": "HETOIMASIA_VULKAN_LOADER",
    "loader package description": "HETOIMASIA_VULKAN_LOADER_PC",
    "driver": "HETOIMASIA_VULKAN_DRIVER_MANIFEST",
    "layer": "HETOIMASIA_VULKAN_LAYER_MANIFEST",
    "glslang": "HETOIMASIA_VULKAN_GLSLANG",
}


class VulkanError(Exception):
    """A diagnostic reported instead of a provisioned or accepted prefix."""

    def __init__(self, message: str, status: int = 2) -> None:
        super().__init__(message)
        self.status = status


# --------------------------------------------------------------------------
# Pins


def read_pin(path: str = PIN_FILE) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        raise VulkanError(f"cannot read the Vulkan pin {path}: {error}") from error
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        name, separator, value = stripped.partition("=")
        if not separator or not name:
            raise VulkanError(f"{path}:{number}: expected NAME=VALUE, not {stripped!r}")
        values[name] = value
    return values


def required(pin: dict[str, str], name: str) -> str:
    value = pin.get(name)
    if not value:
        raise VulkanError(f"{PIN_FILE} does not pin {name}")
    return value


def platform_prefix(target: str) -> str:
    if target == "Darwin":
        return "MACOS"
    if target == "Linux":
        return "LINUX"
    raise VulkanError(f"the Vulkan recipe supports Darwin and Linux, not {target!r}")


def pinned_packages(target: str, pin: dict[str, str]) -> list[dict[str, str]]:
    """The distribution packages this platform's inputs come from, if any.

    Linux pins package revisions because that is what ``apt`` can be held to and
    what ``dpkg`` can be asked about afterwards. macOS pins file digests instead,
    because its inputs come from an SDK installer and a Homebrew cellar rather
    than from one package manager the recipe drives.
    """
    if target != "Linux":
        return []
    return [
        {"name": required(pin, f"LINUX_{role}_PACKAGE"), "version": required(pin, f"LINUX_{role}_PACKAGE_VERSION")}
        for role in ("LOADER", "HEADERS", "DRIVER", "LAYER", "GLSLANG")
    ]


def pinned_inputs(target: str, pin: dict[str, str]) -> dict:
    """What this platform names, where it looks, and which identity qualifies it.

    This is configuration rather than a result: it can be read on a machine that
    holds none of these files, which is what lets the native identity describe
    the Vulkan configuration before anything is provisioned.
    """
    platform = platform_prefix(target)

    def pinned(name: str) -> str:
        return required(pin, f"{platform}_{name}")

    def optional(name: str) -> str | None:
        return pin.get(f"{platform}_{name}") or None

    return {
        "loader": {
            "path": pinned("LOADER"),
            "version": pinned("LOADER_VERSION"),
            "sha256": optional("LOADER_SHA256"),
            "pkg_config": pinned("LOADER_PC"),
            "pkg_config_sha256": optional("LOADER_PC_SHA256"),
            "include": pinned("INCLUDE"),
            "headers_sha256": pinned("HEADERS_SHA256"),
        },
        "driver": {
            "path": pinned("DRIVER_MANIFEST"),
            "name": pinned("DRIVER_NAME"),
            "sha256": optional("DRIVER_MANIFEST_SHA256"),
            "library": optional("DRIVER_LIBRARY"),
            "library_sha256": optional("DRIVER_LIBRARY_SHA256"),
        },
        "layer": {
            "path": pinned("LAYER_MANIFEST"),
            "name": pinned("LAYER_NAME"),
            "version": pinned("LAYER_VERSION"),
            "sha256": optional("LAYER_MANIFEST_SHA256"),
            "library": optional("LAYER_LIBRARY"),
            "library_sha256": optional("LAYER_LIBRARY_SHA256"),
        },
        "glslang": {
            "path": pinned("GLSLANG"),
            "version": pinned("GLSLANG_VERSION"),
            "sha256": optional("GLSLANG_SHA256"),
        },
        "packages": pinned_packages(target, pin),
    }


def configuration(target: str, pin: dict[str, str] | None = None) -> dict:
    """The Vulkan half of the native identity: what the pin says, and the overrides in force.

    An override is part of the identity because a prefix provisioned from a
    relocated input is a prefix of *that* input. It never replaces the pinned
    identity; it only says where the file qualified against it was found.
    """
    resolved = pinned_inputs(target, pin if pin is not None else read_pin())
    return {
        "pin": resolved,
        "overrides": {role: os.environ.get(variable) for role, variable in sorted(OVERRIDES.items())},
    }


# --------------------------------------------------------------------------
# Locating and qualifying one input


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def holdings(path: str) -> str:
    """What the machine holds where an input was expected, for a diagnosis.

    A refusal is only useful if it says what is actually there. Nothing here
    selects an alternative: this names the directory's contents so a reader can
    see whether the input moved, was never installed, or is a different build.
    """
    directory = os.path.dirname(path) or "."
    try:
        names = sorted(os.listdir(directory))
    except OSError as error:
        return f"{directory} cannot be listed ({error})"
    if not names:
        return f"{directory} is empty"
    listed = ", ".join(names[:24])
    return f"{directory} holds: {listed}" + (", …" if len(names) > 24 else "")


def locate(role: str, pinned_path: str) -> tuple[str, str | None]:
    """Where this input actually is, and the override that relocated it.

    The override locates and nothing more. Whatever it names is qualified
    against the pin exactly as the pinned path would have been, so relocating
    an input cannot turn an unqualified file into an accepted one.
    """
    override = os.environ.get(OVERRIDES[role])
    path = override or pinned_path
    if not os.path.isabs(path):
        source = f"{OVERRIDES[role]}" if override else f"{PIN_NAME}"
        raise VulkanError(f"the {role} path {path!r} from {source} is not absolute")
    return path, override


def qualify(role: str, pinned_path: str, expected_sha256: str | None) -> dict:
    """Read one input, resolve it, and hold it to the identity the pin names."""
    path, override = locate(role, pinned_path)
    if not os.path.exists(path):
        raise VulkanError(
            f"the pinned {role} {path} does not exist; {holdings(path)}; nothing else is used instead",
            status=1,
        )
    # A symlink is resolved before it is hashed, so a moving link — Homebrew's
    # `opt` is the usual one — qualifies the file it currently points at rather
    # than being taken on trust because its own name did not change.
    resolved = os.path.realpath(path)
    if not os.path.isfile(resolved):
        raise VulkanError(
            f"the pinned {role} {path} resolves to {resolved}, which is not a file; {holdings(resolved)}",
            status=1,
        )
    try:
        digest = sha256_file(resolved)
    except OSError as error:
        raise VulkanError(f"the pinned {role} {resolved} is not readable ({error}); {holdings(resolved)}", status=1) from error
    if expected_sha256 and digest != expected_sha256:
        raise VulkanError(
            f"the {role} at {resolved} has SHA-256 {digest}, not the pinned {expected_sha256}; "
            f"a substituted {role} is never adopted, and an upgrade is an explicit requalification "
            f"that moves {PIN_NAME}",
            status=1,
        )
    return {"path": path, "resolved": resolved, "sha256": digest, "override": override}


def manifest_library(role: str, manifest_path: str, document: dict, key: str, pinned: str | None) -> str:
    """The binary one ICD or layer manifest names, as an absolute path.

    The loader reads ``library_path`` three ways, and so does this. An absolute
    path is itself. One with a separator in it is relative to the manifest's own
    directory, which is how the SDK and Homebrew manifests name their libraries.
    A bare filename is neither: the loader hands it to the dynamic linker and
    takes whatever the search path turns up, which is exactly what a pin exists
    to stop. Both Linux manifests are written that way, so the pin names the
    binary each one stands for and the manifest is held to it — the search never
    happens, and a manifest that began naming some other library is refused
    rather than followed.
    """
    section = document.get(key)
    if not isinstance(section, dict):
        raise VulkanError(f"the {role} manifest {manifest_path} has no {key!r} object", status=1)
    library = section.get("library_path")
    if not isinstance(library, str) or not library:
        raise VulkanError(f"the {role} manifest {manifest_path} names no library_path", status=1)
    if os.path.isabs(library):
        return library
    if os.sep in library or "/" in library:
        return os.path.normpath(os.path.join(os.path.dirname(manifest_path), library))
    if not pinned:
        raise VulkanError(
            f"the {role} manifest {manifest_path} names its library as the bare filename {library!r}, "
            f"which the loader would resolve through the dynamic linker's search path; {PIN_NAME} must "
            f"name that binary for this platform so the search is never made",
            status=1,
        )
    if os.path.basename(pinned) != library:
        raise VulkanError(
            f"the {role} manifest {manifest_path} names the library {library!r}, but {PIN_NAME} pins "
            f"{pinned}; the manifest describes a different library than the one this recipe qualified",
            status=1,
        )
    return pinned


def read_manifest(role: str, path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise VulkanError(f"the {role} manifest {path} is unreadable ({error}); {holdings(path)}", status=1) from error
    if not isinstance(document, dict):
        raise VulkanError(f"the {role} manifest {path} is not a JSON object", status=1)
    return document


def qualify_library(role: str, manifest: dict, expected_sha256: str | None) -> dict:
    """The binary behind a manifest, qualified exactly as the manifest itself is.

    A manifest and the binary it names are two inputs, not one: replacing the
    binary while keeping the manifest is precisely the substitution a recorded
    manifest hash alone would not notice.
    """
    resolved = os.path.realpath(manifest["library"])
    if not os.path.isfile(resolved):
        raise VulkanError(
            f"the {role} manifest {manifest['resolved']} names the library {manifest['library']}, "
            f"which is not a file; {holdings(resolved)}",
            status=1,
        )
    try:
        digest = sha256_file(resolved)
    except OSError as error:
        raise VulkanError(f"the {role} library {resolved} is not readable ({error})", status=1) from error
    if expected_sha256 and digest != expected_sha256:
        raise VulkanError(
            f"the {role} library at {resolved} has SHA-256 {digest}, not the pinned {expected_sha256}; "
            f"a substituted {role} binary invalidates the evidence gathered under the pinned one",
            status=1,
        )
    return {"path": manifest["library"], "resolved": resolved, "sha256": digest}


def qualify_loader_link(loader: dict) -> dict:
    """The name ``-lvulkan`` opens beside a referenced loader, held to that loader.

    A referenced loader's package description points the linker at the
    loader's own directory, and there ``-lvulkan`` opens the unversioned name,
    never the versioned file the pin qualified. A digest of that file alone
    would accept the name deleted, pointed elsewhere, or replaced by another
    library, and each of those either fails a clean build or links a loader
    this recipe never qualified.
    """
    link = os.path.join(os.path.dirname(loader["resolved"]), LINUX_LOADER_LINK)
    if not os.path.islink(link):
        state = (
            f"at {link} is a file of its own rather than a link"
            if os.path.lexists(link)
            else f"is missing from {link}"
        )
        raise VulkanError(
            f"the loader's linker-facing link {state}; `-lvulkan` opens that name, so it has to be a "
            f"link to the qualified loader {loader['resolved']}; {holdings(link)}",
            status=1,
        )
    resolved = os.path.realpath(link)
    if resolved != loader["resolved"]:
        raise VulkanError(
            f"the loader's linker-facing link at {link} resolves to {resolved}, not the qualified loader "
            f"{loader['resolved']}; `-lvulkan` would link a loader this recipe did not qualify",
            status=1,
        )
    return {"path": link, "target": os.readlink(link)}


# The header trees a consumer compiles against. Only these two, rather than the
# whole include directory the pin names: on Linux that directory is the
# distribution's own `/usr/include`, and hashing all of it would describe the
# machine rather than the Vulkan inputs.
HEADER_TREES = ("vulkan", "vk_video")


def headers_digest(include: str) -> str:
    """One digest over the Vulkan headers a prefix compiles against.

    Headers decide what compiles as surely as the loader decides what links, so
    they are an input with an identity rather than a directory that came along
    with one. Each file contributes its path relative to the include directory
    and its own digest, so an added, removed, renamed, or edited header moves
    this.
    """
    # A header that cannot be read, or a directory that cannot be listed, is
    # refused rather than skipped: `os.walk` would otherwise pass over an
    # unlistable directory silently and digest whatever remained.
    def unlistable(error: OSError) -> None:
        raise VulkanError(
            f"the Vulkan header directory {error.filename} cannot be listed ({error.strerror or error}); "
            f"{holdings(error.filename)}",
            status=1,
        )

    digest = hashlib.sha256()
    found = False
    for tree in HEADER_TREES:
        root = os.path.join(include, tree)
        if not os.path.isdir(root):
            continue
        found = True
        for base, directories, names in os.walk(root, onerror=unlistable):
            directories.sort()
            for name in sorted(names):
                full = os.path.join(base, name)
                relative = os.path.relpath(full, include)
                try:
                    content = sha256_file(full)
                except OSError as error:
                    raise VulkanError(
                        f"the Vulkan header {full} cannot be read ({error.strerror or error}); {holdings(full)}",
                        status=1,
                    ) from error
                digest.update(relative.encode("utf-8") + b"\0" + content.encode("ascii") + b"\n")
    if not found:
        raise VulkanError(
            f"{include} holds none of the Vulkan header directories {', '.join(HEADER_TREES)}; {holdings(include)}",
            status=1,
        )
    return digest.hexdigest()


def pkg_config_version(path: str) -> str:
    """The ``Version:`` field of a pkg-config file, read without running pkg-config.

    The loader's own package description is the one thing beside the binary that
    states which loader it is, so the pinned version is cross-checked against it
    rather than asserted by the pin alone.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise VulkanError(f"the loader's package description {path} is unreadable ({error}); {holdings(path)}", status=1) from error
    for line in text.splitlines():
        if line.startswith("Version:"):
            return line.split(":", 1)[1].strip()
    raise VulkanError(f"the loader's package description {path} states no Version", status=1)


def glslang_version(executable: str) -> str:
    """What the compiler says it is, from its own first line.

    ``glslangValidator --version`` prints ``Glslang Version: %d:%d.%d.%d%s`` —
    an epoch, the release, and an optional flavour such as ``.dev`` — so the
    last colon-separated field is the release and whatever the build appended
    to it. Both are returned; the caller decides how much of it the pin fixes.
    Nothing is compiled to ask.
    """
    try:
        process = subprocess.run([executable, "--version"], capture_output=True, check=False)
    except OSError as error:
        raise VulkanError(f"cannot run the pinned glslang compiler {executable}: {error}", status=1) from error
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise VulkanError(f"{executable} --version exited {process.returncode}: {detail or 'no output'}", status=1)
    lines = process.stdout.decode("utf-8", errors="replace").strip().splitlines()
    if not lines:
        raise VulkanError(f"{executable} --version printed nothing", status=1)
    return lines[0].split(":")[-1].strip()


# --------------------------------------------------------------------------
# Resolving every input


def resolve(target: str, pin: dict[str, str] | None = None) -> dict:
    """Locate and qualify every Vulkan input this platform pins.

    The result is the identity a prefix is provisioned from and the identity a
    provisioned prefix is checked against, so cold provisioning and warm reuse
    ask exactly the same question of the machine.
    """
    pinned = pinned_inputs(target, pin if pin is not None else read_pin())

    loader = qualify("loader", pinned["loader"]["path"], pinned["loader"]["sha256"])
    # The loader's package description decides what the prefix's own generated
    # one says, so it is an input with an identity rather than a file that came
    # along with one.
    description = qualify(
        "loader package description", pinned["loader"]["pkg_config"], pinned["loader"]["pkg_config_sha256"]
    )
    described = pkg_config_version(description["resolved"])
    expected_version = pinned["loader"]["version"]
    if not (described == expected_version or described.startswith(expected_version + ".")):
        raise VulkanError(
            f"{pinned['loader']['pkg_config']} describes Vulkan loader {described}, not the pinned "
            f"{expected_version}; the loader beside it is not the one this recipe qualified",
            status=1,
        )
    loader.update(
        {
            "version": expected_version,
            "described_version": described,
            "source_pkg_config": description["resolved"],
            "source_pkg_config_sha256": description["sha256"],
        }
    )
    # macOS writes its own link beside the copy it installs; a referenced
    # loader is linked through the one already beside it, so that link is a
    # source input and is qualified here, before anything is provisioned.
    if target != "Darwin":
        loader["link"] = qualify_loader_link(loader)

    driver = qualify("driver", pinned["driver"]["path"], pinned["driver"]["sha256"])
    driver_document = read_manifest("driver", driver["resolved"])
    driver["library"] = manifest_library(
        "driver", driver["resolved"], driver_document, "ICD", pinned["driver"]["library"]
    )
    driver_library = qualify_library("driver", driver, pinned["driver"]["library_sha256"])
    driver.update(
        {
            "name": pinned["driver"]["name"],
            "api_version": driver_document.get("ICD", {}).get("api_version"),
            "library_resolved": driver_library["resolved"],
            "library_sha256": driver_library["sha256"],
        }
    )

    layer = qualify("layer", pinned["layer"]["path"], pinned["layer"]["sha256"])
    layer_document = read_manifest("layer", layer["resolved"])
    layer["library"] = manifest_library(
        "layer", layer["resolved"], layer_document, "layer", pinned["layer"]["library"]
    )
    layer_library = qualify_library("layer", layer, pinned["layer"]["library_sha256"])
    declared = layer_document.get("layer", {})
    if declared.get("name") != pinned["layer"]["name"]:
        raise VulkanError(
            f"the layer manifest {layer['resolved']} declares {declared.get('name')!r}, not the pinned "
            f"{pinned['layer']['name']!r}",
            status=1,
        )
    api_version = declared.get("api_version") or ""
    if not (api_version == pinned["layer"]["version"] or api_version.startswith(pinned["layer"]["version"] + ".")):
        raise VulkanError(
            f"the layer manifest {layer['resolved']} declares API version {api_version!r}, not the pinned "
            f"{pinned['layer']['version']!r}; a validation layer of another version is a different layer",
            status=1,
        )
    layer.update(
        {
            "name": pinned["layer"]["name"],
            "api_version": api_version,
            "implementation_version": declared.get("implementation_version"),
            "library_resolved": layer_library["resolved"],
            "library_sha256": layer_library["sha256"],
        }
    )

    glslang = qualify("glslang", pinned["glslang"]["path"], pinned["glslang"]["sha256"])
    reported = glslang_version(glslang["resolved"])
    # The release has to be the pinned one exactly; a flavour the build appended
    # after it is recorded rather than rejected, because it is part of what this
    # compiler is and not a different release. `15.1.01` is not `15.1.0`, so the
    # boundary is checked rather than just the prefix.
    expected = pinned["glslang"]["version"]
    flavour = reported[len(expected) :]
    if not reported.startswith(expected) or (flavour[:1].isdigit() or flavour[:1] == "."):
        raise VulkanError(
            f"the glslang compiler at {glslang['resolved']} reports {reported}, not the pinned "
            f"{expected}",
            status=1,
        )
    glslang["version"] = reported

    include = pinned["loader"]["include"]
    # The package revision says which headers were installed, not that the tree
    # at this path is still theirs, so the tree is held to its own pinned
    # digest. Without it, headers substituted before the first record would be
    # adopted, and every later check would compare against the substitute.
    headers = headers_digest(include)
    if headers != pinned["loader"]["headers_sha256"]:
        raise VulkanError(
            f"the Vulkan headers at {include} have digest {headers}, not the pinned "
            f"{pinned['loader']['headers_sha256']}; substituted headers are never adopted, and an "
            f"upgrade is an explicit requalification that moves {PIN_NAME}",
            status=1,
        )
    return {
        "schema_version": 1,
        "loader": loader,
        "driver": driver,
        "layer": layer,
        "glslang": glslang,
        "include": include,
        "headers_sha256": headers,
        "packages": installed_packages(target, pinned["packages"]),
    }


def installed_packages(target: str, pinned: list[dict[str, str]]) -> list[dict[str, str]]:
    """The distribution revisions actually installed, held to the ones pinned.

    Read back from ``dpkg`` rather than assumed from the ``=`` constraint the
    package step passed, so what the prefix records is what the machine has.
    """
    if not pinned:
        return []
    resolved = []
    for package in pinned:
        try:
            process = subprocess.run(
                ["dpkg-query", "--show", "--showformat=${Version}", package["name"]],
                capture_output=True,
                check=False,
            )
        except OSError as error:
            raise VulkanError(f"cannot ask dpkg about {package['name']}: {error}", status=1) from error
        if process.returncode != 0:
            detail = process.stderr.decode("utf-8", errors="replace").strip()
            raise VulkanError(
                f"the pinned package {package['name']} is not installed ({detail or 'no output'}); "
                f"the image's package step installs it at exactly {package['version']}",
                status=1,
            )
        installed = process.stdout.decode("utf-8", errors="replace").strip()
        if installed != package["version"]:
            raise VulkanError(
                f"{package['name']} {installed} is installed, not the pinned {package['version']}; "
                f"an upgrade is an explicit requalification that moves {PIN_NAME}",
                status=1,
            )
        resolved.append({"name": package["name"], "version": installed})
    return resolved


# --------------------------------------------------------------------------
# The provisioned prefix


def vulkan_prefix(prefix: str) -> str:
    return os.path.join(prefix, VULKAN_DIRECTORY)


def driver_manifest_path(prefix: str, name: str) -> str:
    return os.path.join(vulkan_prefix(prefix), "share", "vulkan", "icd.d", f"{name}_icd.json")


def layer_manifest_path(prefix: str, name: str) -> str:
    return os.path.join(vulkan_prefix(prefix), "share", "vulkan", "explicit_layer.d", f"{name}.json")


def layer_directory(prefix: str) -> str:
    return os.path.join(vulkan_prefix(prefix), "share", "vulkan", "explicit_layer.d")


def wrapper_path(prefix: str) -> str:
    return os.path.join(vulkan_prefix(prefix), "bin", "glslangValidator")


def pkg_config_path(prefix: str) -> str:
    return os.path.join(vulkan_prefix(prefix), "lib", "pkgconfig")


def loader_directory(prefix: str) -> str:
    return os.path.join(vulkan_prefix(prefix), "lib")


WRAPPER = """#!/usr/bin/env bash
# Generated by tools/native/vulkan.py for the private native prefix. Do not
# edit: `python3 tools/native/native.py check` refuses a prefix whose wrapper is
# not the one this configuration writes.
#
# It runs the qualified compiler by absolute path, so what it executes does not
# depend on PATH and an unrelated glslangValidator earlier on PATH cannot be
# reached through it. Given its own identity flag it answers from the identity
# recorded when the prefix was provisioned, compiling nothing.
set -euo pipefail

compiler={compiler}
version={version}
digest={digest}

if [ "${{1:-}}" = "{flag}" ]; then
  printf 'glslang %s\\n' "$version"
  printf 'compiler %s\\n' "$compiler"
  printf 'sha256 %s\\n' "$digest"
  exit 0
fi

exec "$compiler" "$@"
"""


def write_wrapper(prefix: str, glslang: dict) -> dict:
    path = wrapper_path(prefix)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    body = WRAPPER.format(
        compiler=shell_quote(glslang["resolved"]),
        version=shell_quote(glslang["version"]),
        digest=shell_quote(glslang["sha256"]),
        flag=IDENTITY_FLAG,
    )
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.chmod(path, 0o755)
    return {"path": path, "sha256": sha256_file(path), "mode": stat.S_IMODE(os.stat(path).st_mode)}


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


PKG_CONFIG = """# Generated by tools/native/vulkan.py for the private native prefix. It
# describes the loader this recipe qualified, so `pkgconfig-depends: vulkan`
# resolves the project-managed prefix rather than a machine-wide one.
prefix={prefix}
exec_prefix=${{prefix}}
libdir={libdir}
includedir={includedir}

Name: Vulkan-Loader
Description: The Vulkan loader this repository pins
Version: {version}
Libs: -L${{libdir}} -lvulkan
Cflags: -I${{includedir}}
"""


def write_pkg_config(prefix: str, loader: dict, libdir: str, includedir: str) -> dict:
    path = os.path.join(pkg_config_path(prefix), "vulkan.pc")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(
            PKG_CONFIG.format(
                prefix=vulkan_prefix(prefix),
                libdir=libdir,
                includedir=includedir,
                version=loader["described_version"],
            )
        )
    return {"path": path, "sha256": sha256_file(path)}


def write_manifest(path: str, document: dict) -> dict:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return {"path": path, "sha256": sha256_file(path)}


def install_loader(prefix: str, target: str, loader: dict) -> tuple[dict, str]:
    """Put the qualified loader where a consumer can link it, and say where that is.

    On macOS the loader's own install name is ``@rpath/libvulkan.1.dylib``, so a
    consumer that merely pointed at the SDK would need an rpath and would record
    a machine path in every product. The qualified file is copied into the
    prefix and given an absolute install name instead, which is what lets
    ``cabal.project.vulkan`` link against the prefix with no generated project
    file and no rpath at all. The copy is re-signed ad hoc because editing a
    Mach-O invalidates its signature and macOS refuses to load an unsigned one.

    On Linux the loader is referenced where its pinned package installed it: its
    soname is already absolute enough for the dynamic linker, and copying an ELF
    out of a package directory would only hide which package supplied it. The
    link ``-lvulkan`` opens beside it was qualified by :func:`resolve` and is
    recorded here, so verification holds it exactly as it holds macOS's.

    The Mach-O edit needs macOS's own tools, so it is done where those exist.
    Describing a Darwin prefix from another host is something only a fixture
    does — ``build`` refuses a target that is not the host — and such a prefix
    records its own identity honestly rather than pretending to be runnable.
    """
    if target != "Darwin":
        return {
            "path": loader["resolved"],
            "sha256": loader["sha256"],
            "installed": False,
            "link": loader["link"]["path"],
            "link_target": loader["link"]["target"],
        }, os.path.dirname(loader["resolved"])
    directory = loader_directory(prefix)
    os.makedirs(directory, exist_ok=True)
    installed = os.path.join(directory, LOADER_FILE)
    shutil.copyfile(loader["resolved"], installed)
    os.chmod(installed, 0o755)
    # `-lvulkan` opens this name, so it is what a link actually goes through.
    # It is a link rather than a second copy so that one file carries the
    # identity, and it is recorded below so that removing it, pointing it
    # somewhere else, or replacing it with a file is refused rather than left to
    # surface as a link failure in whatever builds next.
    link = os.path.join(directory, LOADER_LINK)
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(LOADER_FILE, link)
    if platform.system() == "Darwin":
        run(["install_name_tool", "-id", installed, installed])
        run(["codesign", "--force", "--sign", "-", installed])
    return {
        "path": installed,
        "sha256": sha256_file(installed),
        "installed": True,
        "link": link,
        "link_target": LOADER_FILE,
    }, directory


def run(command: list[str]) -> None:
    process = subprocess.run(command, capture_output=True, check=False)
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise VulkanError(f"{' '.join(command)} exited {process.returncode}: {detail or 'no output'}", status=1)


def install_headers(prefix: str, target: str, include: str) -> str:
    """Where the Vulkan headers a consumer compiles against live.

    Copied on macOS beside the copied loader, so the prefix is self-contained
    for a link that names no machine path; referenced on Linux, where the pinned
    development package owns them.
    """
    if target != "Darwin":
        return include
    destination = os.path.join(vulkan_prefix(prefix), "include")
    if os.path.lexists(destination):
        shutil.rmtree(destination)
    os.makedirs(destination, exist_ok=True)
    for directory in ("vulkan", "vk_video"):
        source = os.path.join(include, directory)
        if os.path.isdir(source):
            shutil.copytree(source, os.path.join(destination, directory))
    if not os.path.isdir(os.path.join(destination, "vulkan")):
        raise VulkanError(f"{include} holds no vulkan/ headers to provision; {holdings(include)}", status=1)
    return destination


def provision(prefix: str, target: str, pin: dict[str, str] | None = None) -> dict:
    """Establish ``<prefix>/vulkan`` from the qualified inputs, and record it.

    Every product written here is derived from an input that was qualified
    first, so provisioning a prefix twice from an unchanged machine writes the
    same bytes and records the same identities.
    """
    resolved = resolve(target, pin)
    root = vulkan_prefix(prefix)
    if os.path.lexists(root):
        shutil.rmtree(root)
    os.makedirs(root, exist_ok=True)

    loader, libdir = install_loader(prefix, target, resolved["loader"])
    includedir = install_headers(prefix, target, resolved["include"])
    generated = write_pkg_config(prefix, resolved["loader"], libdir, includedir)

    # The driver and layer manifests are written here rather than copied, with
    # the library each one names spelled absolutely. The loader is then given
    # one file, not a directory to search, and the manifest in the prefix cannot
    # silently start naming a different binary because a relative path resolved
    # somewhere else.
    driver = write_manifest(
        driver_manifest_path(prefix, resolved["driver"]["name"]),
        {
            "file_format_version": "1.0.0",
            "ICD": {
                "library_path": resolved["driver"]["library_resolved"],
                "api_version": resolved["driver"]["api_version"],
                "is_portability_driver": target == "Darwin",
            },
        },
    )
    layer_document = read_manifest("layer", resolved["layer"]["resolved"])
    layer_document["layer"]["library_path"] = resolved["layer"]["library_resolved"]
    layer = write_manifest(layer_manifest_path(prefix, resolved["layer"]["name"]), layer_document)
    wrapper = write_wrapper(prefix, resolved["glslang"])

    return {
        "schema_version": 1,
        "loader": {
            "version": resolved["loader"]["version"],
            "described_version": resolved["loader"]["described_version"],
            "source": resolved["loader"]["resolved"],
            "source_sha256": resolved["loader"]["sha256"],
            "path": loader["path"],
            "sha256": loader["sha256"],
            "installed": loader["installed"],
            "link": loader["link"],
            "link_target": loader["link_target"],
            "include": includedir,
            "headers_sha256": headers_digest(includedir),
            "source_headers_sha256": resolved["headers_sha256"],
            "pkg_config": generated["path"],
            "pkg_config_sha256": generated["sha256"],
            "source_pkg_config": resolved["loader"]["source_pkg_config"],
            "source_pkg_config_sha256": resolved["loader"]["source_pkg_config_sha256"],
        },
        "driver": {
            "name": resolved["driver"]["name"],
            "api_version": resolved["driver"]["api_version"],
            "source": resolved["driver"]["resolved"],
            "source_sha256": resolved["driver"]["sha256"],
            "manifest": driver["path"],
            "manifest_sha256": driver["sha256"],
            "library": resolved["driver"]["library_resolved"],
            "library_sha256": resolved["driver"]["library_sha256"],
        },
        "layers": [
            {
                "name": resolved["layer"]["name"],
                "api_version": resolved["layer"]["api_version"],
                "implementation_version": resolved["layer"]["implementation_version"],
                "source": resolved["layer"]["resolved"],
                "source_sha256": resolved["layer"]["sha256"],
                "manifest": layer["path"],
                "manifest_sha256": layer["sha256"],
                "library": resolved["layer"]["library_resolved"],
                "library_sha256": resolved["layer"]["library_sha256"],
            }
        ],
        "glslang": {
            "version": resolved["glslang"]["version"],
            "compiler": resolved["glslang"]["resolved"],
            "compiler_sha256": resolved["glslang"]["sha256"],
            "wrapper": wrapper["path"],
            "wrapper_sha256": wrapper["sha256"],
            "wrapper_mode": wrapper["mode"],
        },
        "packages": resolved["packages"],
    }


# --------------------------------------------------------------------------
# Checking a provisioned prefix


def files_of(recorded: dict) -> list[tuple[str, str, str]]:
    """Every file the record claims, as ``(description, path, digest)``.

    Both halves of each input are here — the manifest *and* the binary it names,
    the wrapper *and* the compiler it runs — because verifying only the half
    that is cheap to hash is how a substituted binary passes a check.
    """
    loader = recorded["loader"]
    driver = recorded["driver"]
    glslang = recorded["glslang"]
    entries = [
        ("the Vulkan loader", loader["path"], loader["sha256"]),
        ("the loader's package description", loader["pkg_config"], loader["pkg_config_sha256"]),
        ("the driver manifest", driver["manifest"], driver["manifest_sha256"]),
        (f"the {driver['name']} driver library", driver["library"], driver["library_sha256"]),
        ("the glslangValidator wrapper", glslang["wrapper"], glslang["wrapper_sha256"]),
        ("the glslang compiler", glslang["compiler"], glslang["compiler_sha256"]),
    ]
    if loader.get("installed"):
        entries.append(("the loader this prefix was provisioned from", loader["source"], loader["source_sha256"]))
    for layer in recorded["layers"]:
        entries.append((f"the {layer['name']} manifest", layer["manifest"], layer["manifest_sha256"]))
        entries.append((f"the {layer['name']} library", layer["library"], layer["library_sha256"]))
    return entries


def verify(prefix: str, target: str, recorded, pin: dict[str, str] | None = None) -> list[str]:
    """Hold a provisioned prefix to its record and to the pin, naming every problem.

    Two independent questions are asked, and both have to be answered. Is every
    file the record names still exactly the file that was recorded — read and
    hashed now, never taken from the record itself? And does this machine still
    qualify under the pin, so that a prefix provisioned here today would resolve
    the same inputs? A prefix that passes one and fails the other is refused.
    """
    if not isinstance(recorded, dict):
        return ["the manifest records no Vulkan inputs"]
    problems: list[str] = []

    # The products this recipe writes belong to the prefix being checked. A
    # record that names them somewhere else describes a different prefix, and
    # hashing those files would then say nothing about this one.
    root = vulkan_prefix(prefix)
    owned = [
        ("the loader's package description", recorded["loader"].get("pkg_config")),
        ("the loader's linker-facing link", recorded["loader"].get("link")),
        ("the driver manifest", recorded["driver"].get("manifest")),
        ("the glslangValidator wrapper", recorded["glslang"].get("wrapper")),
    ] + [(f"the {layer.get('name')} manifest", layer.get("manifest")) for layer in recorded.get("layers", [])]
    for description, path in owned:
        if path is None and description == "the loader's linker-facing link":
            # Only a prefix that installed the loader owns a link to it.
            continue
        if description == "the loader's linker-facing link" and not recorded["loader"].get("installed"):
            # A referenced loader's link belongs to its package, not to this
            # prefix; it is held below to the one the pin qualifies instead.
            continue
        if not isinstance(path, str) or os.path.commonpath([root, os.path.abspath(path)]) != root:
            problems.append(f"{description} is recorded at {path!r}, which is not inside {root}")

    # The link `-lvulkan` opens. Its identity is not a digest — it is that it is
    # a symbolic link, and which file it names. A check that only hashed the
    # versioned loader beside it would pass a prefix whose link was deleted,
    # retargeted, or replaced by a file, and every one of those either fails a
    # clean build or silently links a different loader.
    link = recorded["loader"].get("link")
    if isinstance(link, str):
        expected_target = recorded["loader"].get("link_target")
        if not os.path.islink(link):
            problems.append(
                f"the loader's linker-facing link is missing from {link} ({holdings(link)}); "
                "`-lvulkan` opens that name, so a prefix without it does not link"
            )
        else:
            actual_target = os.readlink(link)
            if actual_target != expected_target:
                problems.append(
                    f"the loader's linker-facing link at {link} points at {actual_target!r}, "
                    f"not the recorded {expected_target!r}"
                )
            elif os.path.realpath(link) != os.path.realpath(recorded["loader"]["path"]):
                problems.append(
                    f"the loader's linker-facing link at {link} resolves to {os.path.realpath(link)}, "
                    f"not the recorded loader {recorded['loader']['path']}"
                )

    # The directory exported as `VK_LAYER_PATH` is searched, not selected from:
    # the loader offers every manifest it finds there. So hashing the recorded
    # manifest proves nothing about what else the loader can discover, and the
    # directory has to hold exactly the recorded set and nothing beside it.
    selections: dict[str, set[str]] = {}
    for layer in recorded.get("layers", []):
        manifest = layer.get("manifest")
        if isinstance(manifest, str):
            selections.setdefault(os.path.dirname(manifest), set()).add(os.path.basename(manifest))
    for directory, expected in sorted(selections.items()):
        try:
            present = set(os.listdir(directory))
        except OSError as error:
            problems.append(f"the layer directory {directory} is not readable ({error})")
            continue
        unrecorded = sorted(present - expected)
        if unrecorded:
            problems.append(
                f"the layer directory {directory} holds {', '.join(unrecorded)} beside the recorded "
                f"{', '.join(sorted(expected))}; the loader searches that directory, so an unqualified "
                "manifest there is a layer it can load"
            )

    # The headers the prefix offers, re-walked rather than taken from the
    # record: on macOS they are a copy inside the prefix, and a copy nobody
    # re-reads is a copy nobody would notice an edit to.
    try:
        actual_headers = headers_digest(recorded["loader"]["include"])
    except (VulkanError, KeyError, TypeError) as failure:
        problems.append(f"the Vulkan headers this prefix compiles against are unreadable ({failure})")
    else:
        if actual_headers != recorded["loader"].get("headers_sha256"):
            problems.append(
                f"the Vulkan headers at {recorded['loader']['include']} hash to {actual_headers[:12]}, "
                f"not the recorded {str(recorded['loader'].get('headers_sha256'))[:12]}"
            )

    for description, path, digest in files_of(recorded):
        if not isinstance(path, str) or not isinstance(digest, str):
            problems.append(f"{description} is not recorded as a path and a digest")
            continue
        if not os.path.isfile(path):
            problems.append(f"{description} is missing from {path} ({holdings(path)})")
            continue
        try:
            actual = sha256_file(path)
        except OSError as error:
            problems.append(f"{description} at {path} is not readable ({error})")
            continue
        if actual != digest:
            problems.append(
                f"{description} at {path} hashes to {actual[:12]}, not the recorded {digest[:12]}; "
                "a substituted input invalidates every receipt gathered under the recorded one"
            )

    # The wrapper is the compiler as far as anything else here is concerned, so
    # what matters is not only that its bytes are the recorded ones but that it
    # still runs and still answers for the compiler that was recorded. Bytes
    # alone would pass a wrapper whose execute bits were cleared: direct use
    # then fails outright, and a PATH lookup walks past it to whatever else is
    # called `glslangValidator`.
    wrapper = recorded["glslang"].get("wrapper")
    if isinstance(wrapper, str) and os.path.isfile(wrapper):
        mode = stat.S_IMODE(os.stat(wrapper).st_mode)
        if mode != recorded["glslang"].get("wrapper_mode"):
            problems.append(
                f"the glslangValidator wrapper at {wrapper} has mode {mode:04o}, not the recorded "
                f"{recorded['glslang'].get('wrapper_mode', 0):04o}"
            )
        if not os.access(wrapper, os.X_OK):
            problems.append(
                f"the glslangValidator wrapper at {wrapper} is not executable, so nothing can run the "
                "qualified compiler through it and a PATH lookup would walk past it"
            )
        else:
            problems.extend(wrapper_reports(wrapper, recorded["glslang"]))

    try:
        current = resolve(target, pin)
    except VulkanError as failure:
        problems.append(f"this machine no longer qualifies under {PIN_NAME}: {failure}")
        return problems

    for field, recorded_value, actual_value in (
        ("loader version", recorded["loader"].get("version"), current["loader"]["version"]),
        ("loader source", recorded["loader"].get("source"), current["loader"]["resolved"]),
        ("loader source digest", recorded["loader"].get("source_sha256"), current["loader"]["sha256"]),
        ("header digest", recorded["loader"].get("source_headers_sha256"), current["headers_sha256"]),
        (
            "loader package description digest",
            recorded["loader"].get("source_pkg_config_sha256"),
            current["loader"]["source_pkg_config_sha256"],
        ),
        ("driver", recorded["driver"].get("name"), current["driver"]["name"]),
        ("driver source digest", recorded["driver"].get("source_sha256"), current["driver"]["sha256"]),
        ("driver library digest", recorded["driver"].get("library_sha256"), current["driver"]["library_sha256"]),
        ("glslang version", recorded["glslang"].get("version"), current["glslang"]["version"]),
        ("glslang compiler digest", recorded["glslang"].get("compiler_sha256"), current["glslang"]["sha256"]),
    ):
        if recorded_value != actual_value:
            problems.append(f"the recorded {field} is {recorded_value!r}, but this machine resolves {actual_value!r}")

    if not recorded["loader"].get("installed"):
        current_link = current["loader"].get("link") or {}
        for field, recorded_value, actual_value in (
            ("loader's linker-facing link", recorded["loader"].get("link"), current_link.get("path")),
            ("loader's linker-facing link target", recorded["loader"].get("link_target"), current_link.get("target")),
        ):
            if recorded_value != actual_value:
                problems.append(f"the recorded {field} is {recorded_value!r}, but this machine resolves {actual_value!r}")

    recorded_layers = {layer.get("name"): layer for layer in recorded.get("layers", [])}
    if current["layer"]["name"] not in recorded_layers:
        problems.append(
            f"the manifest records layers {sorted(recorded_layers)}, but this configuration pins "
            f"{current['layer']['name']}"
        )
    else:
        layer = recorded_layers[current["layer"]["name"]]
        for field, recorded_value, actual_value in (
            ("api version", layer.get("api_version"), current["layer"]["api_version"]),
            ("manifest digest", layer.get("source_sha256"), current["layer"]["sha256"]),
            ("library digest", layer.get("library_sha256"), current["layer"]["library_sha256"]),
        ):
            if recorded_value != actual_value:
                problems.append(
                    f"the recorded {current['layer']['name']} {field} is {recorded_value!r}, "
                    f"but this machine resolves {actual_value!r}"
                )

    if recorded.get("packages") != current["packages"]:
        problems.append(
            f"the manifest records packages {recorded.get('packages')!r}, but this machine has {current['packages']!r}"
        )
    return problems


# --------------------------------------------------------------------------
# What a consumer is told


def wrapper_reports(wrapper: str, glslang: dict) -> list[str]:
    """Run the wrapper's own identity flag and hold it to what was recorded.

    This compiles nothing — the flag is answered by the wrapper itself — so it
    is a cheap way to establish the thing a digest cannot: that the file still
    executes, and that what it would run is the compiler the manifest names.
    """
    try:
        process = subprocess.run([wrapper, IDENTITY_FLAG], capture_output=True, check=False)
    except OSError as error:
        return [f"the glslangValidator wrapper at {wrapper} could not be run ({error})"]
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        return [f"the glslangValidator wrapper at {wrapper} exited {process.returncode}: {detail or 'no output'}"]
    reported = dict(
        line.split(" ", 1)
        for line in process.stdout.decode("utf-8", errors="replace").splitlines()
        if " " in line
    )
    expected = {
        "glslang": glslang.get("version"),
        "compiler": glslang.get("compiler"),
        "sha256": glslang.get("compiler_sha256"),
    }
    return [
        f"the glslangValidator wrapper at {wrapper} reports {name} {reported.get(name)!r}, "
        f"not the recorded {value!r}"
        for name, value in expected.items()
        if reported.get(name) != value
    ]


def environment(prefix: str, recorded: dict) -> dict[str, str]:
    """The discovery a consumer of this prefix is given, as NAME=VALUE.

    One driver manifest and one layer directory, both inside the prefix, so a
    run selects what was qualified rather than enumerating what a machine holds.
    """
    return {
        "VK_DRIVER_FILES": recorded["driver"]["manifest"],
        "VK_LAYER_PATH": os.path.dirname(recorded["layers"][0]["manifest"]),
        "HETOIMASIA_VULKAN_PREFIX": vulkan_prefix(prefix),
        # Where the qualified loader and its headers are, for a consumer whose
        # own declaration cannot read a package description — the binding names
        # `extra-libraries: vulkan` on macOS, with no directory to find it in.
        # These are what let a build point at the prefix on the command line
        # instead of through a generated project file.
        "HETOIMASIA_VULKAN_LIBDIR": os.path.dirname(recorded["loader"]["path"]),
        "HETOIMASIA_VULKAN_INCLUDEDIR": recorded["loader"]["include"],
        "HETOIMASIA_GLSLANG": recorded["glslang"]["wrapper"],
    }


def summary(recorded: dict) -> list[str]:
    """One line per input, for a command that reports what a prefix holds."""
    lines = [
        "loader {} ({}) at {}{}".format(
            recorded["loader"]["version"],
            recorded["loader"]["sha256"][:12],
            recorded["loader"]["path"],
            ", opened as " + os.path.basename(recorded["loader"]["link"]) if recorded["loader"].get("link") else "",
        ),
        "driver {} {} ({}) via {}".format(
            recorded["driver"]["name"],
            recorded["driver"]["api_version"],
            recorded["driver"]["library_sha256"][:12],
            recorded["driver"]["manifest"],
        ),
    ]
    for layer in recorded["layers"]:
        lines.append(
            "layer {} {} ({}) via {}".format(
                layer["name"], layer["api_version"], layer["library_sha256"][:12], layer["manifest"]
            )
        )
    lines.append("headers {} at {}".format(recorded["loader"]["headers_sha256"][:12], recorded["loader"]["include"]))
    lines.append(
        "glslang {} ({}) behind {}".format(
            recorded["glslang"]["version"], recorded["glslang"]["compiler_sha256"][:12], recorded["glslang"]["wrapper"]
        )
    )
    for package in recorded.get("packages", []):
        lines.append("package {} {}".format(package["name"], package["version"]))
    return lines


# --------------------------------------------------------------------------
# The identity a plan, an image, and a receipt carry


# The toolchain-map entries the Vulkan runtime contributes. ``vulkan`` is the
# whole identity in one digest, which is what makes a cache key and a receipt
# incompatible the moment any input changes; the four beside it name the inputs
# in a form a reader can compare against a record without recomputing anything.
TOOLCHAIN_IDENTITY = "vulkan"
TOOLCHAIN_ENTRIES = ("vulkan", "vulkan-loader", "vulkan-driver", "vulkan-layers", "glslang")


def identity_digest(recorded: dict) -> str:
    """One digest over every Vulkan identity a prefix records.

    Taken over the recorded section as a whole, so a changed loader, driver
    manifest, driver binary, layer manifest, layer binary, compiler, or package
    revision all move it. Nothing may be excluded from it to keep an identity
    stable across an upgrade: an upgrade is meant to move this.
    """
    encoded = json.dumps(recorded, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def toolchain_entries(recorded: dict) -> dict[str, str]:
    """What a plan declares and a worker must independently arrive at."""
    driver = recorded["driver"]
    glslang = recorded["glslang"]
    return {
        "vulkan": identity_digest(recorded),
        "vulkan-loader": "{} {}".format(recorded["loader"]["version"], recorded["loader"]["sha256"][:12]),
        "vulkan-driver": "{} {} {}".format(driver["name"], driver["api_version"], driver["library_sha256"][:12]),
        "vulkan-layers": "; ".join(
            "{} {} {}".format(layer["name"], layer["api_version"], layer["library_sha256"][:12])
            for layer in recorded["layers"]
        ),
        "glslang": "{} {}".format(glslang["version"], glslang["compiler_sha256"][:12]),
    }


def recorded_from(manifest_file: str) -> dict:
    """The Vulkan section of a native manifest, refused when it is not one."""
    try:
        with open(manifest_file, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise VulkanError(f"the native manifest {manifest_file} is unreadable ({error})", status=1) from error
    recorded = manifest.get("vulkan") if isinstance(manifest, dict) else None
    if not isinstance(recorded, dict):
        raise VulkanError(f"the native manifest {manifest_file} records no Vulkan inputs", status=1)
    return recorded
