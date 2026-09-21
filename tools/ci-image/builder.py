#!/usr/bin/env python3
"""Resolve or publish the Linux CI image for one recipe fingerprint.

The builder is the only thing that publishes the image, and it decides with one
rule: the image for a fingerprint is published at most once, to the tag
``fp-<fingerprint>``, and a tag that exists is never overwritten.

- ``resolve`` looks the tag up. A validated existing image is a *hit* and
  returns its digest; a tag the registry confirms is absent is a *miss*. A
  lookup that errors is neither, and neither is an existing image whose
  metadata does not describe this fingerprint: both fail without publishing.
- ``publish`` runs serialized per fingerprint. It looks the tag up again, so a
  concurrent builder that already published returns that image rather than
  building a second one; on a confirmed miss it builds, validates the candidate
  (compiler versions, native manifest, link check), pushes once, and reads the
  published metadata back before reporting the digest.
- ``descriptor`` writes the tracked descriptor the author commits.
- ``stage`` extracts exactly the recipe inputs the fingerprint covers into a
  build context, so the image cannot be built from anything it does not name.

The registry is reached through an executable (``--registry``) speaking a small
protocol, which ``registry.py`` implements against GHCR and Docker:

- ``lookup REFERENCE:TAG`` prints ``{"digest": ..., "labels": {...}}`` and exits
  ``0``, or exits ``3`` when the registry confirms the tag is absent;
- ``build CONTEXT LOCAL FINGERPRINT`` prints ``{"native_manifest": ...}``;
- ``validate LOCAL FINGERPRINT NATIVE_MANIFEST GHC CABAL WESTON`` exits ``0``;
- ``push LOCAL REFERENCE:TAG`` exits ``0``.

Any other exit status is a registry error. See ``docs/validation.md``.
"""

from __future__ import annotations

import argparse
import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile

sys.dont_write_bytecode = True

ABSENT = 3
REPOSITORY_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_contract():
    path = os.path.join(REPOSITORY_ROOT, "tools", "validation", "ci_image.py")
    specification = importlib.util.spec_from_file_location("ci_image", path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


contract = load_contract()


class BuilderError(Exception):
    """A refusal reported instead of a published or resolved image."""


def tag_for(image: str, fingerprint: str) -> str:
    return f"{image}:fp-{fingerprint}"


def call(registry: str, *arguments: str) -> tuple[int, str, str]:
    try:
        process = subprocess.run([registry, *arguments], capture_output=True, check=False)
    except OSError as error:
        raise BuilderError(f"cannot run the registry transport {registry}: {error}") from error
    return (
        process.returncode,
        process.stdout.decode("utf-8", errors="replace"),
        process.stderr.decode("utf-8", errors="replace").strip(),
    )


def document_from(output: str, description: str) -> dict:
    try:
        document = json.loads(output)
    except json.JSONDecodeError as error:
        raise BuilderError(f"{description} did not answer with JSON: {error}") from error
    if not isinstance(document, dict):
        raise BuilderError(f"{description} did not answer with a JSON object")
    return document


def lookup(registry: str, reference: str) -> dict | None:
    status, output, errors = call(registry, "lookup", reference)
    if status == ABSENT:
        return None
    if status != 0:
        raise BuilderError(
            f"looking up {reference} failed (exit {status}): {errors or 'no output'}; a registry error "
            "is not a miss, so nothing is published"
        )
    return document_from(output, f"the lookup of {reference}")


def validated(record: dict, reference: str, fingerprint: str, ghc: str, cabal: str, weston: str) -> dict:
    """An existing image's metadata, refused unless it describes this fingerprint."""
    problems: list[str] = []
    digest = record.get("digest")
    if not isinstance(digest, str) or not contract.DIGEST.match(digest):
        problems.append(f"its digest {digest!r} is not a sha256 digest")
    labels = record.get("labels")
    if not isinstance(labels, dict):
        labels = {}
        problems.append("it carries no labels")
    native_manifest = labels.get(contract.LABELS["native_manifest"])
    if labels.get(contract.LABELS["recipe_fingerprint"]) != fingerprint:
        problems.append(
            f"its recipe fingerprint label is {labels.get(contract.LABELS['recipe_fingerprint'])!r}"
        )
    if not isinstance(native_manifest, str) or not contract.HEX64.match(native_manifest):
        problems.append(f"its native manifest label is {native_manifest!r}")
    for name, expected in (("ghc", ghc), ("cabal", cabal), ("weston", weston)):
        if labels.get(contract.LABELS[name]) != expected:
            problems.append(f"its {name} label is {labels.get(contract.LABELS[name])!r}, not {expected}")
    if problems:
        raise BuilderError(
            f"{reference} exists but is not a validated image for fingerprint {fingerprint[:12]}: "
            + "; ".join(problems)
            + "; the tag is never overwritten, so delete that package version deliberately if it must be replaced"
        )
    return {"digest": digest, "native_manifest": native_manifest, "ghc": ghc, "cabal": cabal, "weston": weston}


def resolve(registry: str, image: str, fingerprint: str, ghc: str, cabal: str, weston: str) -> dict:
    reference = tag_for(image, fingerprint)
    record = lookup(registry, reference)
    if record is None:
        return {"status": "miss", "reference": reference}
    return {"status": "hit", "reference": reference, **validated(record, reference, fingerprint, ghc, cabal, weston)}


def publish(registry: str, image: str, fingerprint: str, ghc: str, cabal: str, weston: str, context: str) -> dict:
    reference = tag_for(image, fingerprint)
    # The recheck. This runs serialized per fingerprint, so a builder that
    # published while this one waited is found here and nothing is rebuilt.
    record = lookup(registry, reference)
    if record is not None:
        return {
            "status": "hit",
            "published": False,
            "reference": reference,
            **validated(record, reference, fingerprint, ghc, cabal, weston),
        }

    local = f"hetoimasia-ci-candidate:{fingerprint[:16]}"
    status, output, errors = call(registry, "build", context, local, fingerprint)
    if status != 0:
        raise BuilderError(f"building the candidate image failed (exit {status}): {errors or 'no output'}")
    built = document_from(output, "the candidate build")
    native_manifest = built.get("native_manifest")
    if not isinstance(native_manifest, str) or not contract.HEX64.match(native_manifest):
        raise BuilderError(f"the candidate build reported native manifest {native_manifest!r}")

    status, _, errors = call(registry, "validate", local, fingerprint, native_manifest, ghc, cabal, weston)
    if status != 0:
        raise BuilderError(f"the candidate image failed validation (exit {status}): {errors or 'no output'}; nothing was published")

    status, _, errors = call(registry, "push", local, reference)
    if status != 0:
        raise BuilderError(f"pushing {reference} failed (exit {status}): {errors or 'no output'}")

    published = lookup(registry, reference)
    if published is None:
        raise BuilderError(f"{reference} is absent immediately after it was pushed")
    result = validated(published, reference, fingerprint, ghc, cabal, weston)
    if result["native_manifest"] != native_manifest:
        raise BuilderError(
            f"{reference} reports native manifest {result['native_manifest'][:12]} after publication, "
            f"not the validated {native_manifest[:12]}"
        )
    return {"status": "published", "published": True, "reference": reference, **result}


def descriptor(
    image: str,
    digest: str,
    fingerprint: str,
    native_manifest: str,
    ghc: str,
    cabal: str,
    weston: str,
    architecture: str,
) -> dict:
    document = {
        "schema_version": contract.DESCRIPTOR_SCHEMA_VERSION,
        "reference": image,
        "digest": digest,
        "recipe_fingerprint": fingerprint,
        "native_manifest": native_manifest,
        "platform": "linux",
        "architecture": architecture,
        "ghc": ghc,
        "cabal": cabal,
        "weston": weston,
    }
    try:
        return contract.validate_descriptor(document, "the returned descriptor")
    except contract.ImageError as failure:
        raise BuilderError(str(failure)) from failure


def stage(root: str, revision: str, output: str) -> list[str]:
    """Extract exactly the fingerprinted recipe inputs of one revision."""
    try:
        paths = [entry[0] for entry in contract.recipe_inputs(contract.tree_entries(root, revision))]
    except contract.ImageError as failure:
        raise BuilderError(str(failure)) from failure
    if not paths:
        raise BuilderError(f"{revision} carries no recipe inputs to stage")
    process = subprocess.run(
        ["git", "-C", root, "archive", "--format=tar", revision, "--", *paths],
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        raise BuilderError("git archive failed: " + process.stderr.decode("utf-8", errors="replace").strip())
    os.makedirs(output, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(process.stdout)) as archive:
        archive.extractall(output, filter="data")
    return paths


def write_outputs(path: str | None, result: dict) -> None:
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        for key in ("status", "published", "digest", "native_manifest"):
            if key in result:
                value = result[key]
                handle.write(f"{key.replace('_', '-')}={str(value).lower() if isinstance(value, bool) else value}\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="builder.py", description="Resolve or publish the Linux CI image.")
    commands = parser.add_subparsers(dest="command", required=True)

    def image_options(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--image", required=True, help="the registry repository, without a tag")
        sub.add_argument("--fingerprint", required=True)
        sub.add_argument("--ghc", required=True)
        sub.add_argument("--cabal", required=True)
        sub.add_argument("--weston", required=True, help="the pinned compositor package revision")
        sub.add_argument("--registry", required=True, help="the registry transport executable")
        sub.add_argument("--github-output", default=None)

    resolved = commands.add_parser("resolve")
    image_options(resolved)
    published = commands.add_parser("publish")
    image_options(published)
    published.add_argument("--context", required=True, help="the staged build context")
    written = commands.add_parser("descriptor")
    written.add_argument("--image", required=True)
    written.add_argument("--digest", required=True)
    written.add_argument("--fingerprint", required=True)
    written.add_argument("--native-manifest", required=True)
    written.add_argument("--ghc", required=True)
    written.add_argument("--cabal", required=True)
    written.add_argument("--weston", required=True)
    written.add_argument("--architecture", default="amd64")
    written.add_argument("--output", required=True)
    staged = commands.add_parser("stage")
    staged.add_argument("--repo-root", default=".")
    staged.add_argument("--revision", default="HEAD")
    staged.add_argument("--output", required=True)

    arguments = parser.parse_args(argv)
    if arguments.command in ("resolve", "publish"):
        if not contract.HEX64.match(arguments.fingerprint):
            raise BuilderError(f"{arguments.fingerprint!r} is not a recipe fingerprint")
        if arguments.command == "resolve":
            result = resolve(
                arguments.registry, arguments.image, arguments.fingerprint, arguments.ghc, arguments.cabal, arguments.weston
            )
        else:
            result = publish(
                arguments.registry,
                arguments.image,
                arguments.fingerprint,
                arguments.ghc,
                arguments.cabal,
                arguments.weston,
                arguments.context,
            )
        write_outputs(arguments.github_output, result)
        print(json.dumps(result, indent=2, sort_keys=True))
    elif arguments.command == "descriptor":
        document = descriptor(
            arguments.image,
            arguments.digest,
            arguments.fingerprint,
            arguments.native_manifest,
            arguments.ghc,
            arguments.cabal,
            arguments.weston,
            arguments.architecture,
        )
        with open(arguments.output, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print(json.dumps(document, indent=2, sort_keys=True))
    elif arguments.command == "stage":
        for path in stage(os.path.abspath(arguments.repo_root), arguments.revision, arguments.output):
            print(path)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BuilderError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
