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
  carries, the compilers it actually runs, and the Cabal store it resolves,
  then declares the toolchain map it verified, which must equal the plan's.

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
DESCRIPTOR_SCHEMA_VERSION = 1
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


def verify_worker(plan: dict, image_root: str, repo_root: str) -> dict[str, str]:
    """Check this execution environment is the planned image, and declare its map.

    The container runtime's digest-addressed launch establishes which image
    runs; this establishes that it is the image the descriptor describes, and
    that what it actually carries — the embedded fingerprint, the native
    manifest, the compilers, and the Cabal store — agrees with the plan. The
    declared map is built from those actual values and must equal the plan's
    in its entirety.
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
    }
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
