#!/usr/bin/env python3
"""The Linux CI image contract: recipe fingerprint, descriptor, and worker check.

Ordinary Linux validation runs inside one published image holding the pinned
GHC and Cabal, the C build prerequisites, and the compiled private GLFW prefix.
Which image that is lives in a tracked *descriptor*,
``tools/ci-image/descriptor.json``, which the author commits after the dedicated
builder returns it. This module is the one definition of what that descriptor
must say and of how the planner, the builder, and each worker check it:

- the **recipe fingerprint** is a digest over every recipe input — the image
  recipe, its copied scripts and pin files, the native recipe, and the builder
  workflow — taken from one commit's tree, with the descriptor itself excluded
  so committing it cannot change the fingerprint it records;
- the **planner** reads the descriptor from the integration candidate without
  pulling anything, and refuses one whose fingerprint or GHC and Cabal versions
  disagree with the candidate, naming the builder as the fix;
- each **worker**, running in a container bound to the descriptor's digest,
  checks the fingerprint the image embeds, the native manifest it actually
  carries, the Vulkan loader, driver, layer, and compiler identities that
  manifest records against the files actually on disk, the compilers it
  actually runs, the compositor package it actually has installed, and the
  Cabal store it resolves, then declares the toolchain map it verified, which
  must equal the plan's.

See ``docs/validation.md`` for the image, the descriptor, and the builder.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

# A one-shot tool must not write into the checkout it is validating.
sys.dont_write_bytecode = True

DESCRIPTOR_PATH = "tools/ci-image/descriptor.json"
DESCRIPTOR_SCHEMA_VERSION = 2
FINGERPRINT_SCHEMA_VERSION = 1

# A candidate carries an image recipe when this file exists. One that does not
# has no image to plan against and keeps the toolchain its workflow declares.
RECIPE_MARKER = "tools/ci-image/Dockerfile"

# Every recipe input: a trailing ``/`` is a directory prefix, anything else an
# exact path. The builder workflow is one, because it decides how the recipe
# is built and tagged, and so is this module, because the builder and its
# registry transport load it to decide what a valid image is.
RECIPE_ROOTS = (
    "tools/ci-image/",
    "tools/native/",
    ".github/workflows/ci-image.yml",
    "tools/validation/ci_image.py",
)

# The toolchain map entries this image contributes beside ``ghc`` and ``cabal``.
IMAGE_ENTRY = "ci-image"
MANIFEST_ENTRY = "native-manifest"

# The Vulkan runtime the native prefix provisions, as the plan's toolchain map
# carries it. ``vulkan`` is every loader, driver, layer, and compiler identity
# in one digest, so a changed input moves the cache environment key and makes a
# receipt gathered under the old identities unusable; the four beside it name
# those inputs in the descriptor in a form a reader can compare directly. The
# descriptor field for each is the entry name with its hyphen as an underscore,
# except ``glslang``, which is spelled the same in both.
VULKAN_ENTRIES = ("vulkan", "vulkan-loader", "vulkan-driver", "vulkan-layers", "glslang")


def descriptor_field(entry: str) -> str:
    return entry.replace("-", "_")

# The headless compositor the display helper starts, identified by the exact
# package revision the image installed. It is part of the environment identity
# because a different compositor is a different display environment, however
# identical everything else is.
COMPOSITOR_ENTRY = "weston"

# The operating system whose workers run in the image. A plan for any other
# platform describes a machine that never ran it.
IMAGE_RUNNER_OS = "Linux"

# The fixed locations inside the image. Workers, cache steps, and provisioning
# all use these, whatever HOME a job or a container step happens to have.
IMAGE_ROOT = "/opt/hetoimasia"
EMBEDDED_NAME = "image.json"
NATIVE_PREFIX = "native/glfw"
NATIVE_MANIFEST_NAME = "hetoimasia-native-manifest.json"

LABELS = {
    "recipe_fingerprint": "org.hetoimasia.ci-image.recipe-fingerprint",
    "native_manifest": "org.hetoimasia.ci-image.native-manifest",
    "ghc": "org.hetoimasia.ci-image.ghc",
    "cabal": "org.hetoimasia.ci-image.cabal",
    "weston": "org.hetoimasia.ci-image.weston",
    **{descriptor_field(entry): f"org.hetoimasia.ci-image.{entry}" for entry in VULKAN_ENTRIES},
}

BUILDER_INSTRUCTION = (
    "run the ci-image builder (.github/workflows/ci-image.yml) for this candidate, by workflow "
    "dispatch or by pushing the image-input change to a same-repository pull request, and commit "
    "the descriptor it returns as " + DESCRIPTOR_PATH + "; an older image is never selected instead"
)

HEX64 = re.compile(r"^[0-9a-f]{64}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
REFERENCE = re.compile(r"^[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+$")
VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
# A Debian package revision, such as ``13.0.0-4build3``: an upstream version and
# the distribution's own revision, which a bare dotted version cannot express.
PACKAGE_VERSION = re.compile(r"^[0-9][A-Za-z0-9.+~]*(?:-[A-Za-z0-9.+~]+)*$")

DESCRIPTOR_FIELDS = {
    "schema_version": int,
    "reference": str,
    "digest": str,
    "recipe_fingerprint": str,
    "native_manifest": str,
    "platform": str,
    "architecture": str,
    "ghc": str,
    "cabal": str,
    "weston": str,
    **{descriptor_field(entry): str for entry in VULKAN_ENTRIES},
}


class ImageError(Exception):
    """A diagnostic reported instead of a plan, a descriptor, or a verified worker."""


# --------------------------------------------------------------------------
# Fingerprints


def git_output(root: str, *arguments: str) -> str:
    process = subprocess.run(("git", "-C", root) + arguments, capture_output=True, check=False)
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise ImageError("git " + " ".join(arguments) + " failed: " + (detail or "no output"))
    return process.stdout.decode("utf-8")


def tree_entries(root: str, revision: str) -> list[tuple[str, str, str, str]]:
    """Every tracked path of one revision with its mode, type, and object id."""
    entries = []
    for record in git_output(root, "ls-tree", "-r", "-z", revision).split("\0"):
        if not record:
            continue
        metadata, separator, path = record.partition("\t")
        fields = metadata.split()
        if not separator or len(fields) != 3:
            raise ImageError(f"cannot read the tree of {revision}: unexpected entry {record!r}")
        entries.append((path, fields[0], fields[1], fields[2]))
    return sorted(entries)


def is_recipe_input(path: str) -> bool:
    if path == DESCRIPTOR_PATH:
        return False
    for root in RECIPE_ROOTS:
        if root.endswith("/"):
            if path.startswith(root):
                return True
        elif path == root:
            return True
    return False


def recipe_inputs(entries: list[tuple[str, str, str, str]]) -> list[tuple[str, str, str, str]]:
    return [entry for entry in entries if is_recipe_input(entry[0])]


def fingerprint(entries: list[tuple[str, str, str, str]]) -> str:
    """The recipe fingerprint of one tree.

    Each input contributes its path, mode, type, and content id, so a renamed
    script, a file that becomes executable, and an edited pin all move it, and
    two commits carrying identical recipe inputs share it whatever else differs.
    """
    payload = {
        "fingerprint_schema_version": FINGERPRINT_SCHEMA_VERSION,
        "entries": [list(entry) for entry in recipe_inputs(entries)],
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def has_recipe(entries: list[tuple[str, str, str, str]]) -> bool:
    return any(entry[0] == RECIPE_MARKER for entry in entries)


# --------------------------------------------------------------------------
# Descriptors


def validate_descriptor(document, source: str) -> dict:
    """Hold a descriptor to its shape, naming every problem at once."""
    if not isinstance(document, dict):
        raise ImageError(f"{source} is not a JSON object; {BUILDER_INSTRUCTION}")
    problems: list[str] = []
    for key, expected in DESCRIPTOR_FIELDS.items():
        if key not in document:
            problems.append(f"missing {key!r}")
        elif not isinstance(document[key], expected) or isinstance(document[key], bool):
            problems.append(f"{key!r} is not a {expected.__name__}")
    for key in document:
        if key not in DESCRIPTOR_FIELDS:
            problems.append(f"unknown key {key!r}")
    if not problems:
        if document["schema_version"] != DESCRIPTOR_SCHEMA_VERSION:
            problems.append(f"schema_version {document['schema_version']} is not {DESCRIPTOR_SCHEMA_VERSION}")
        if not REFERENCE.match(document["reference"]):
            problems.append(f"reference {document['reference']!r} is not a registry repository without a tag")
        if not DIGEST.match(document["digest"]):
            problems.append(f"digest {document['digest']!r} is not a sha256 digest")
        if not HEX64.match(document["recipe_fingerprint"]):
            problems.append("recipe_fingerprint is not a 64-digit lowercase hex digest")
        if not HEX64.match(document["native_manifest"]):
            problems.append("native_manifest is not a 64-digit lowercase hex digest")
        if document["platform"] != "linux":
            problems.append(f"platform {document['platform']!r} is not 'linux'")
        if not document["architecture"]:
            problems.append("architecture is empty")
        for key in ("ghc", "cabal"):
            if not VERSION.match(document[key]):
                problems.append(f"{key} {document[key]!r} is not a version")
        if not PACKAGE_VERSION.match(document["weston"]):
            problems.append(f"weston {document['weston']!r} is not a package version")
        if not HEX64.match(document["vulkan"]):
            problems.append("vulkan is not a 64-digit lowercase hex identity digest")
        for entry in VULKAN_ENTRIES[1:]:
            if not document[descriptor_field(entry)].strip():
                problems.append(f"{descriptor_field(entry)} names no identity")
    if problems:
        raise ImageError(f"{source} is malformed: " + "; ".join(problems) + f"; {BUILDER_INSTRUCTION}")
    return document


def parse_descriptor(text: str, source: str) -> dict:
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise ImageError(f"{source} is not valid JSON ({error}); {BUILDER_INSTRUCTION}") from error
    return validate_descriptor(document, source)


def plan_image(read, entries, toolchain: dict[str, str], runner_os: str, label: str):
    """The image a plan's workers run, and the toolchain map they must declare.

    ``read`` returns one path's text from the integration candidate, and
    ``entries`` is that candidate's tree, so the descriptor and the fingerprint
    are both taken from the tree workers execute rather than from the head or
    the working tree. Returns ``(None, toolchain)`` for a plan with no image:
    another platform, or a candidate that carries no recipe.
    """
    if runner_os != IMAGE_RUNNER_OS:
        if IMAGE_ENTRY in toolchain:
            raise ImageError(
                f"a {runner_os} plan declares the Linux image digest as {IMAGE_ENTRY}; only Linux "
                "workers run that image, and a local run records its own native manifest instead"
            )
        return None, dict(toolchain)
    if not has_recipe(entries):
        return None, dict(toolchain)
    if not any(entry[0] == DESCRIPTOR_PATH for entry in entries):
        raise ImageError(f"{DESCRIPTOR_PATH} does not exist at {label}, which carries an image recipe; {BUILDER_INSTRUCTION}")
    descriptor = parse_descriptor(read(DESCRIPTOR_PATH), f"{DESCRIPTOR_PATH}@{label}")

    problems: list[str] = []
    recomputed = fingerprint(entries)
    if descriptor["recipe_fingerprint"] != recomputed:
        problems.append(
            f"it records recipe fingerprint {descriptor['recipe_fingerprint'][:12]}, but the candidate's "
            f"recipe inputs fingerprint to {recomputed[:12]}"
        )
    expected = {
        "ghc": descriptor["ghc"],
        "cabal": descriptor["cabal"],
        IMAGE_ENTRY: descriptor["digest"],
        MANIFEST_ENTRY: descriptor["native_manifest"],
        COMPOSITOR_ENTRY: descriptor["weston"],
        **{entry: descriptor[descriptor_field(entry)] for entry in VULKAN_ENTRIES},
    }
    for name, value in expected.items():
        if name in toolchain and toolchain[name] != value:
            problems.append(f"it records {name} {value}, but the workflow pins {toolchain[name]}")
    if problems:
        raise ImageError(f"{DESCRIPTOR_PATH}@{label} does not describe this candidate: " + "; ".join(problems) + f"; {BUILDER_INSTRUCTION}")
    return descriptor, {**toolchain, **expected}


def environment_key(plan: dict) -> str:
    """The cache environment boundary: the planned platform and toolchain map.

    Derived from the map rather than from the descriptor file or the commit
    carrying it, so a new image or native manifest moves every cache key while
    re-committing the same descriptor moves none. No fallback key may cross it.
    """
    payload = {"runner_os": plan["runner_os"], "toolchain": dict(plan["toolchain"])}
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------
# Workers


def command_output(command: list[str]) -> str:
    try:
        process = subprocess.run(command, capture_output=True, check=False)
    except OSError as error:
        raise ImageError(f"cannot run {command[0]}: {error}") from error
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise ImageError(f"{' '.join(command)} exited {process.returncode}: {detail or 'no output'}")
    return process.stdout.decode("utf-8", errors="replace").strip()


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def vulkan_identities(repo_root: str, manifest_file: str) -> dict[str, str]:
    """The Vulkan toolchain entries this machine's own native manifest yields.

    Computed through the recipe that wrote them, so the planner reading a
    descriptor and the worker reading a prefix arrive at one spelling of an
    identity rather than two that can drift apart.
    """
    recipe = os.path.join(repo_root, "tools", "native")
    if recipe not in sys.path:
        sys.path.insert(0, recipe)
    try:
        import vulkan
    except ImportError as error:
        raise ImageError(f"the native recipe at {recipe} has no Vulkan module ({error})") from error
    try:
        return vulkan.toolchain_entries(vulkan.recorded_from(manifest_file))
    except vulkan.VulkanError as failure:
        raise ImageError(str(failure)) from failure
    except (KeyError, TypeError) as error:
        raise ImageError(f"the native manifest {manifest_file} records incomplete Vulkan inputs ({error})") from error


def verify_image(descriptor: dict, image_root: str, repo_root: str) -> dict[str, str]:
    """Check a running container is the image one descriptor describes.

    A worker is bound to the descriptor's digest by the container runtime and
    then verified against the plan; a route that pulls the image itself has no
    plan, and the descriptor is excluded from the recipe fingerprint — so it can
    carry the fingerprint a candidate expects while naming another digest
    entirely, and an older image built from the same native recipe would run
    `native.py check` quite happily. This asks the image what it is instead of
    taking the reference on trust: the fingerprint it embeds, the native
    manifest it carries, the Vulkan identities its own prefix yields, and the
    compilers, compositor, platform, and architecture it records and runs, each
    against the descriptor's corresponding field.
    """
    validate_descriptor(descriptor, "the committed descriptor")
    problems: list[str] = []

    embedded_path = os.path.join(image_root, EMBEDDED_NAME)
    try:
        with open(embedded_path, encoding="utf-8") as handle:
            embedded = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ImageError(f"this container embeds no readable {embedded_path} ({error}); it is not a CI image") from error
    if not isinstance(embedded, dict):
        raise ImageError(f"{embedded_path} is not a JSON object; it is not a CI image")
    if embedded.get("recipe_fingerprint") != descriptor["recipe_fingerprint"]:
        problems.append(
            f"this image embeds recipe fingerprint {str(embedded.get('recipe_fingerprint'))[:12]}, not the "
            f"descriptor's {descriptor['recipe_fingerprint'][:12]}"
        )

    prefix = os.path.join(image_root, NATIVE_PREFIX)
    manifest_file = os.path.join(prefix, NATIVE_MANIFEST_NAME)
    try:
        actual_manifest = sha256_file(manifest_file)
    except OSError as error:
        raise ImageError(f"this container carries no native manifest at {manifest_file} ({error})") from error
    if actual_manifest != descriptor["native_manifest"]:
        problems.append(
            f"the native manifest this image carries hashes to {actual_manifest[:12]}, not the descriptor's "
            f"{descriptor['native_manifest'][:12]}"
        )

    native = subprocess.run(
        [sys.executable, os.path.join(repo_root, "tools", "native", "native.py"), "check", "--prefix", prefix],
        capture_output=True,
        check=False,
    )
    if native.returncode != 0:
        problems.append("the native prefix check failed: " + native.stderr.decode("utf-8", errors="replace").strip())

    declared: dict[str, str] = {}
    try:
        declared = vulkan_identities(repo_root, manifest_file)
    except ImageError as failure:
        problems.append(str(failure))
    for entry in VULKAN_ENTRIES:
        expected = descriptor[descriptor_field(entry)]
        if declared.get(entry) != expected:
            problems.append(
                f"this image's {entry} is {declared.get(entry)!r}, but the descriptor names {expected!r}"
            )

    # The compilers and the compositor, each established twice over: what the
    # image embedded when it was stamped, and what it actually runs now. Any of
    # these could otherwise be misstated over an unchanged digest and
    # fingerprint and still be believed, since the descriptor is excluded from
    # that fingerprint. The platform and architecture have no embedded copy,
    # so they are asked of the running container alone. The reference and
    # digest need no answer from the image: the route runs `reference@digest`,
    # so the container runtime has already bound them.
    installed: dict[str, str] = {}
    for field, command in (
        ("ghc", ["ghc", "--numeric-version"]),
        ("cabal", ["cabal", "--numeric-version"]),
        (COMPOSITOR_ENTRY, ["dpkg-query", "--show", "--showformat=${Version}", "weston"]),
        ("platform", ["uname", "-s"]),
        ("architecture", ["dpkg", "--print-architecture"]),
    ):
        expected = descriptor[field]
        if field in ("ghc", "cabal", COMPOSITOR_ENTRY) and embedded.get(field) != expected:
            problems.append(
                f"this image embeds {field} {embedded.get(field)!r}, but the descriptor names {expected!r}"
            )
        try:
            actual = command_output(command)
        except ImageError as failure:
            problems.append(f"this image cannot report its {field} ({failure})")
            continue
        if field == "platform":
            actual = actual.lower()
        if actual != expected:
            problems.append(f"this image runs {field} {actual!r}, but the descriptor names {expected!r}")
        installed[field] = actual

    if problems:
        raise ImageError(
            "this container is not the image the committed descriptor describes: " + "; ".join(problems)
        )
    return {**declared, **installed, MANIFEST_ENTRY: actual_manifest}


def verify_worker(plan: dict, image_root: str, repo_root: str) -> dict[str, str]:
    """Check this execution environment is the planned image, and declare its map.

    The container runtime's digest-addressed launch establishes which image
    runs; this establishes that it is the image the descriptor describes, and
    that what it actually carries — the embedded fingerprint, the native
    manifest, the compilers, the installed compositor package, and the Cabal
    store — agrees with the plan. The declared map is built from those actual
    values and must equal the plan's in its entirety.
    """
    image = plan.get("ci_image")
    if not isinstance(image, dict):
        raise ImageError("the plan names no CI image, so there is no environment to verify this worker against")
    validate_descriptor(image, "the plan's ci_image")

    problems: list[str] = []
    rebuild = False
    embedded_path = os.path.join(image_root, EMBEDDED_NAME)
    try:
        with open(embedded_path, encoding="utf-8") as handle:
            embedded = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ImageError(f"this container embeds no readable {embedded_path} ({error}); it is not a CI image") from error
    if not isinstance(embedded, dict) or embedded.get("recipe_fingerprint") != image["recipe_fingerprint"]:
        found = embedded.get("recipe_fingerprint") if isinstance(embedded, dict) else None
        problems.append(
            f"this container embeds recipe fingerprint {str(found)[:12]}, not the descriptor's "
            f"{image['recipe_fingerprint'][:12]}"
        )
        rebuild = True

    # The compositor is established twice over: what the image recorded when it
    # was built, and what dpkg says is installed now. Neither is taken from the
    # descriptor, so a descriptor that names a compositor the image does not
    # carry is a refusal rather than a value copied forward.
    embedded_compositor = embedded.get("weston") if isinstance(embedded, dict) else None
    if not isinstance(embedded_compositor, str) or not PACKAGE_VERSION.match(embedded_compositor):
        problems.append(
            f"this container embeds compositor version {embedded_compositor!r}, which is not a package version"
        )
        rebuild = True
    try:
        installed_compositor = command_output(["dpkg-query", "--show", "--showformat=${Version}", "weston"])
    except ImageError as failure:
        installed_compositor = None
        problems.append(f"this container has no installed weston package ({failure})")
        rebuild = True
    if (
        isinstance(embedded_compositor, str)
        and installed_compositor is not None
        and embedded_compositor != installed_compositor
    ):
        problems.append(
            f"this container embeds compositor version {embedded_compositor}, but has weston "
            f"{installed_compositor} installed"
        )
        rebuild = True

    prefix = os.path.join(image_root, NATIVE_PREFIX)
    manifest_file = os.path.join(prefix, NATIVE_MANIFEST_NAME)
    try:
        actual_manifest = sha256_file(manifest_file)
    except OSError as error:
        raise ImageError(f"this container carries no native manifest at {manifest_file} ({error})") from error
    if actual_manifest != image["native_manifest"]:
        problems.append(
            f"the native manifest this container carries hashes to {actual_manifest[:12]}, not the "
            f"descriptor's {image['native_manifest'][:12]}"
        )
        rebuild = True
    native = subprocess.run(
        [sys.executable, os.path.join(repo_root, "tools", "native", "native.py"), "check", "--prefix", prefix],
        capture_output=True,
        check=False,
    )
    if native.returncode != 0:
        problems.append("the native prefix check failed: " + native.stderr.decode("utf-8", errors="replace").strip())

    # The Vulkan identities are taken from the manifest this container actually
    # carries, not from the descriptor, and only after the check above has read
    # and re-hashed every file that manifest names. A container whose loader,
    # driver, layer, or compiler was replaced therefore declares a different map
    # here and is refused, rather than passing because the manifest still looks
    # well-formed.
    vulkan_declared: dict[str, str] = {}
    try:
        vulkan_declared = vulkan_identities(repo_root, manifest_file)
    except ImageError as failure:
        problems.append(str(failure))

    ghc = command_output(["ghc", "--numeric-version"])
    cabal = command_output(["cabal", "--numeric-version"])
    expected_directory = os.path.join(image_root, "cabal")
    expected_store = os.path.join(expected_directory, "store")
    if os.environ.get("CABAL_DIR") != expected_directory:
        problems.append(f"CABAL_DIR is {os.environ.get('CABAL_DIR')!r}, not {expected_directory}")
    store = command_output(["cabal", "path", "--store-dir"])
    if os.path.normpath(store) != expected_store:
        problems.append(f"Cabal resolves its store at {store!r}, not {expected_store}")

    declared = {
        "ghc": ghc,
        "cabal": cabal,
        IMAGE_ENTRY: image["digest"],
        MANIFEST_ENTRY: actual_manifest,
        **vulkan_declared,
    }
    if installed_compositor is not None:
        declared[COMPOSITOR_ENTRY] = installed_compositor
    planned = plan.get("toolchain") or {}
    for name in sorted(set(declared) | set(planned)):
        if declared.get(name) != planned.get(name):
            problems.append(
                f"toolchain entry {name!r}: the plan declares {planned.get(name)!r}, this worker {declared.get(name)!r}"
            )
    if problems:
        suffix = f"; {BUILDER_INSTRUCTION}" if rebuild else ""
        raise ImageError("this worker is not running the planned environment: " + "; ".join(problems) + suffix)
    return declared


# --------------------------------------------------------------------------
# Entry point


def load_plan(path: str) -> dict:
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import receipts

    try:
        return receipts.load_plan(path)
    except receipts.EvidenceError as failure:
        raise ImageError(str(failure)) from failure


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="ci_image.py", description="The Linux CI image contract.")
    commands = parser.add_subparsers(dest="command", required=True)

    printed = commands.add_parser("fingerprint", help="print one revision's recipe fingerprint")
    printed.add_argument("--repo-root", default=".", help="the repository (default: the working directory)")
    printed.add_argument("--revision", default="HEAD", help="the revision whose tree is fingerprinted")

    outputs = commands.add_parser("outputs", help="print a plan's image reference and cache environment key")
    outputs.add_argument("--plan", required=True)

    described = commands.add_parser(
        "verify-image", help="verify this container is the image the committed descriptor describes"
    )
    described.add_argument("--descriptor", default=DESCRIPTOR_PATH, help="the committed descriptor to check against")
    described.add_argument("--image-root", default=IMAGE_ROOT)
    described.add_argument("--repo-root", default=".")

    verified = commands.add_parser("verify-worker", help="verify this worker runs the planned image")
    verified.add_argument("--plan", required=True)
    verified.add_argument("--image-root", default=IMAGE_ROOT)
    verified.add_argument("--repo-root", default=".")
    verified.add_argument("--toolchain-file", required=True, help="where the declared NAME=VALUE lines are written")

    arguments = parser.parse_args(argv)
    if arguments.command == "fingerprint":
        print(fingerprint(tree_entries(os.path.abspath(arguments.repo_root), arguments.revision)))
    elif arguments.command == "outputs":
        plan = load_plan(arguments.plan)
        image = plan.get("ci_image")
        print("image=" + (f"{image['reference']}@{image['digest']}" if isinstance(image, dict) else ""))
        print("environment=" + environment_key(plan))
    elif arguments.command == "verify-image":
        with open(arguments.descriptor, encoding="utf-8") as handle:
            declared = verify_image(json.load(handle), arguments.image_root, os.path.abspath(arguments.repo_root))
        print("verified: " + ", ".join(f"{name} {declared[name]}" for name in sorted(declared)))
    elif arguments.command == "verify-worker":
        plan = load_plan(arguments.plan)
        declared = verify_worker(plan, arguments.image_root, os.path.abspath(arguments.repo_root))
        with open(arguments.toolchain_file, "w", encoding="utf-8") as handle:
            for name in sorted(declared):
                handle.write(f"{name}={declared[name]}\n")
        print("verified: " + ", ".join(f"{name} {declared[name]}" for name in sorted(declared)))
        print("environment=" + environment_key({"runner_os": plan["runner_os"], "toolchain": declared}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ImageError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
