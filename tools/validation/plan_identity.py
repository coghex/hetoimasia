"""The candidate's identities: its policy fingerprint and its input fingerprint.

See ``docs/validation.md``'s Candidate identity section for the contract these
digests implement.
"""

from __future__ import annotations

import hashlib
import json

from plan_cabal import Package, component_inputs
from plan_repository import PlannerError, matches_class, matches_input, run_git

IDENTITY_SCHEMA_VERSION = 1

# Packaging inputs decide what is compiled, so they are never prose however a
# catalog classifies them. Every other exclusion is derived from the declared
# inputs and the declared non-affecting classes rather than hard-coded here.
NEVER_HARMLESS_PATHS = ("cabal.project",)
NEVER_HARMLESS_SUFFIXES = (".cabal",)

# The policy roots a candidate can never exempt itself from. `policy_inputs` is
# catalog data, and the catalog is one of the files it governs: a candidate that
# dropped these prefixes from its own catalog would otherwise leave the policy
# identity — and therefore the input identity — unmoved while rewriting the very
# scripts that decide what a result means. They are unioned with whatever the
# catalog declares, so declaring more still widens and declaring less cannot
# narrow.
REQUIRED_POLICY_ROOTS = ("tools/validation/", ".github/workflows/")


# --------------------------------------------------------------------------
# Identity
#
# Selection answers "what does this contribution touch?" from a two-endpoint
# diff. Reuse asks a different question: "is this candidate's content the same
# content an earlier execution already proved?" Answering that from a diff would
# be wrong, because a code pull request followed by a prose-only push still
# contains code changes relative to its merge base while its tree is identical
# to the one the previous run validated. So identity is a fingerprint of the
# *candidate tree itself*, derived without looking at either endpoint.


def tree_entries(root: str, commit: str) -> list[tuple[str, str, str, str]]:
    """Every tracked path of one commit with its Git object type, mode, and id.

    The mode and the type are part of the fingerprint because a file that
    becomes executable, or a path that becomes a submodule, changes what an
    execution sees while its content digest stays put. Output is read NUL-safe
    so a path containing a newline or a quote cannot be silently truncated.
    """
    listing = run_git(root, "ls-tree", "-r", "-z", commit)
    entries: list[tuple[str, str, str, str]] = []
    for record in listing.split("\0"):
        if not record:
            continue
        metadata, separator, path = record.partition("\t")
        fields = metadata.split()
        if not separator or len(fields) != 3 or not path:
            raise PlannerError(f"cannot read the tree of {commit}: unexpected entry {record!r}")
        mode, kind, object_name = fields
        entries.append((path, mode, kind, object_name))
    entries.sort()
    return entries


def digest(payload: dict) -> str:
    """A SHA-256 over one canonical JSON encoding of a payload."""
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def policy_identity(catalog: dict, entries: list[tuple[str, str, str, str]]) -> str:
    """A digest of the policy that classified this candidate.

    The catalog, the validation scripts, and the workflows are the catalog's
    declared ``policy_inputs`` unioned with ``REQUIRED_POLICY_ROOTS``, so a
    classification change — a new harmless class, an edited runner, a rewritten
    aggregate — produces a different policy identity and can never inherit
    evidence gathered under the policy it replaced. The union is what stops a
    candidate exempting its own tooling by editing the catalog that names it.
    """
    patterns = sorted(set(catalog["policy_inputs"]) | set(REQUIRED_POLICY_ROOTS))
    included = [
        list(entry) for entry in entries if any(matches_input(entry[0], pattern) for pattern in patterns)
    ]
    return digest(
        {
            "identity_schema_version": IDENTITY_SCHEMA_VERSION,
            "catalog_schema_version": catalog["schema_version"],
            "catalog_policy_version": catalog["policy_version"],
            "entries": included,
        }
    )


def consumed_entries(catalog: dict, packages: dict[str, Package]) -> set[str]:
    """Every input entry any registered group derives, from one tree alone.

    Selection unions both revisions' declarations so a retired input still
    counts for the group that owned it. Identity deliberately does not: a
    fingerprint that depended on the base would differ between two runs over
    the very same tree, which is the equivalence reuse exists to recognize.
    """
    entries: set[str] = set(catalog["policy_inputs"]) | set(REQUIRED_POLICY_ROOTS)
    for group in catalog["groups"]:
        entries |= set(group["inputs"])
        entries |= component_inputs(packages, group["component"])
    return entries


def harmless_prose(path: str, consumed: set[str], catalog: dict) -> bool:
    """Whether one path is prose no execution reads.

    Harmless prose is Markdown that no group declares as an input, plus the
    catalog's declared non-affecting classes. A declared input outranks both, so
    a test-consumed Markdown file, a fixture, a shader, an asset, or any
    packaging description is never harmless however it is spelled.
    """
    if path in NEVER_HARMLESS_PATHS or path.endswith(NEVER_HARMLESS_SUFFIXES):
        return False
    if any(matches_input(path, entry) for entry in consumed):
        return False
    if path.endswith(".md"):
        return True
    return any(matches_class(path, pattern) for pattern in catalog["non_affecting_paths"])


def input_identity(
    catalog: dict,
    packages: dict[str, Package],
    entries: list[tuple[str, str, str, str]],
    policy: str,
    toolchain: dict[str, str],
) -> str:
    """The fingerprint two candidates must share before evidence can cross.

    It covers every included path's name, mode, type, and content id — so
    ``cabal.project``, the package descriptions, and every declared non-Haskell
    input are in it — plus the pinned toolchain and the policy identity. It
    omits commit metadata entirely: an execution reads a tree, not an author or
    a timestamp, so two commits with identical trees are the same candidate.
    """
    consumed = consumed_entries(catalog, packages)
    included = [list(entry) for entry in entries if not harmless_prose(entry[0], consumed, catalog)]
    return digest(
        {
            "identity_schema_version": IDENTITY_SCHEMA_VERSION,
            "policy_version": policy,
            "toolchain": dict(toolchain),
            "entries": included,
        }
    )
