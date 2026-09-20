#!/usr/bin/env python3
"""Resolve which validation groups a candidate change requires, and explain why.

The planner reads the declarative catalog (``tools/validation/catalog.json`` by
default), derives each group's inputs from the local Cabal package graph plus
the group's explicitly declared non-Haskell inputs, compares two revisions, and
emits a plan naming every catalog group with a selection reason.

It also fingerprints the integration candidate's own tree, as an ``input_identity``
and a ``policy_version``. Selection answers what a contribution touches; those
digests answer the different question of whether this candidate's content is
content an earlier execution already proved, which a two-endpoint diff cannot.

It depends on Python 3 and Git alone: no GHC, no Cabal, no ``dist-newstyle/``.

See ``docs/validation.md`` for the catalog schema, the selection policy, the
request block, and the plan's JSON structure.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys

# A one-shot tool must not write into the checkout it is validating. Importing a
# sibling module would leave a ``__pycache__`` beside it — a file the candidate
# does not carry, which the runner is right to refuse — so bytecode writing is
# turned off before the imports that would create it.
sys.dont_write_bytecode = True

import ci_image
import receipts

# The catalog's schema and the plan's are separate contracts: the plan gained
# the identity fields this slice added, while the catalog's keys did not move.
CATALOG_SCHEMA_VERSION = 1
PLAN_SCHEMA_VERSION = receipts.PLAN_SCHEMA_VERSION
IDENTITY_SCHEMA_VERSION = 1
DEFAULT_CATALOG = "tools/validation/catalog.json"
PROJECT_FILE = "cabal.project"

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

COMPONENT_KINDS = ("lib", "exe", "test")
FRAMEWORKS = ("hspec", "none")
RUNNERS = receipts.RUNNER_CLASSES
CATEGORIES = ("build", "test", "smoke", "probe")

ID_PATTERN = re.compile(r"^[a-z0-9]+(\.[a-z0-9-]+)+$")
FIELD_PATTERN = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:(.*)$")
STANZA_PATTERN = re.compile(r"^([A-Za-z][A-Za-z0-9-]*)(?:\s+(\S+))?\s*$")
CONDITIONAL_PATTERN = re.compile(r"^(if|elif|else)\b")
OS_CONDITIONAL_PATTERN = re.compile(r"^if\s+os\(\s*[A-Za-z][A-Za-z0-9_-]*\s*\)$")
PACKAGE_NAME_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9-]*")

# The only fields an operating-system conditional may declare. None of them
# names a source, a dependency, or anything else a group's inputs are derived
# from: the link fields choose what an ordinary link adds on one platform, and
# `buildable` chooses whether the stanza is compiled there at all.
#
# `buildable` is deliberately invisible to input derivation. A component that is
# not built on this platform still has its sources, its package description, and
# its declared inputs counted, so a change to a platform-only probe is reported
# as a changed input on every platform. Whether the group that owns it is then
# selected is the group's own business -- the macOS probe's is optional and the
# Linux one's is not -- and that is the point: what a candidate's inputs are
# must not depend on which machine planned it, or the same candidate would mean
# two things.
LINK_ONLY_FIELDS = frozenset({"extra-libraries", "frameworks"})
CONDITIONAL_FIELDS = LINK_ONLY_FIELDS | frozenset({"buildable"})

STANZA_KEYWORDS = {
    "library",
    "executable",
    "test-suite",
    "benchmark",
    "common",
    "source-repository",
    "flag",
    "custom-setup",
    "foreign-library",
}

REQUEST_FENCE = "validation-request"
ALL_HSPEC = "all-hspec"


class PlannerError(Exception):
    """A diagnostic the planner reports instead of producing a plan."""


# --------------------------------------------------------------------------
# Paths


def join_path(*parts: str) -> str:
    """Join and normalize repository-relative POSIX path segments."""
    segments: list[str] = []
    for part in parts:
        for segment in part.replace("\\", "/").split("/"):
            if segment in ("", "."):
                continue
            if segment == "..":
                if not segments:
                    raise PlannerError(f"path escapes the repository root: {'/'.join(parts)}")
                segments.pop()
            else:
                segments.append(segment)
    return "/".join(segments)


def matches_input(path: str, entry: str) -> bool:
    """An input entry is a directory prefix when it ends in ``/``, else an exact path."""
    if entry.endswith("/"):
        return path == entry[:-1] or path.startswith(entry)
    if entry == "":
        return True
    return path == entry


def matches_class(path: str, pattern: str) -> bool:
    """Match a non-affecting class pattern.

    A pattern containing ``/`` is anchored at the repository root and its ``*``
    does not cross a directory separator; a pattern without ``/`` matches any
    file whose basename matches it.
    """
    if "/" in pattern:
        regex = "".join(r"[^/]*" if char == "*" else re.escape(char) for char in pattern)
        return re.fullmatch(regex, path) is not None
    basename = path.rsplit("/", 1)[-1]
    regex = "".join(r"[^/]*" if char == "*" else re.escape(char) for char in pattern)
    return re.fullmatch(regex, basename) is not None


# --------------------------------------------------------------------------
# Trees


def decode(raw: bytes, description: str) -> str:
    """Decode strictly: silently repaired metadata is not readable metadata."""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PlannerError(f"{description} is not valid UTF-8: {error}") from error


def run_git(root: str, *args: str) -> str:
    process = subprocess.run(
        ("git", "-C", root) + args,
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        stderr = process.stderr.decode("utf-8", errors="replace").strip()
        raise PlannerError("git " + " ".join(args) + " failed: " + (stderr or "no output"))
    return decode(process.stdout, "git " + " ".join(args) + " output")


class GitTree:
    """The tracked contents of one resolved commit."""

    def __init__(self, root: str, revision: str) -> None:
        self.root = root
        self.revision = revision
        try:
            self.commit = run_git(root, "rev-parse", "--verify", "--quiet", revision + "^{commit}").strip()
        except PlannerError as error:
            raise PlannerError(f"cannot resolve revision {revision!r}: {error}") from error
        if not self.commit:
            raise PlannerError(f"cannot resolve revision {revision!r} to a commit")
        self.tree = run_git(root, "rev-parse", "--verify", self.commit + "^{tree}").strip()
        listing = run_git(root, "ls-tree", "-r", "-z", "--name-only", self.commit)
        self._files = frozenset(entry for entry in listing.split("\0") if entry)

    @property
    def label(self) -> str:
        return f"{self.revision} ({self.commit[:12]})"

    def files(self) -> frozenset[str]:
        return self._files

    def exists(self, path: str) -> bool:
        return path in self._files

    def read(self, path: str) -> str:
        if not self.exists(path):
            raise PlannerError(f"{path} does not exist at {self.label}")
        process = subprocess.run(
            ("git", "-C", self.root, "show", f"{self.commit}:{path}"),
            capture_output=True,
            check=False,
        )
        if process.returncode != 0:
            raise PlannerError(f"cannot read {path} at {self.label}")
        return decode(process.stdout, f"{path} at {self.label}")


class WorkTree:
    """The working-tree contents under a root directory, without consulting Git."""

    label = "working tree"
    commit = None
    tree = None
    revision = "working tree"

    def __init__(self, root: str) -> None:
        self.root = root
        found: set[str] = set()
        for directory, names, filenames in os.walk(root):
            names[:] = [name for name in names if name not in (".git", "dist-newstyle")]
            for filename in filenames:
                absolute = os.path.join(directory, filename)
                found.add(os.path.relpath(absolute, root).replace(os.sep, "/"))
        self._files = frozenset(found)

    def files(self) -> frozenset[str]:
        return self._files

    def exists(self, path: str) -> bool:
        return os.path.isfile(os.path.join(self.root, path))

    def read(self, path: str) -> str:
        try:
            with open(os.path.join(self.root, path), "rb") as handle:
                raw = handle.read()
        except OSError as error:
            raise PlannerError(f"cannot read {path}: {error}") from error
        return decode(raw, path)


# --------------------------------------------------------------------------
# Cabal parsing
#
# Supported syntax is deliberately bounded to what this repository uses:
# layout-style stanzas, ``common``/``import``, multiline fields, package
# relative ``hs-source-dirs``, ``main-is``, ``c-sources``/``cxx-sources`` and
# ``include-dirs``, ``build-depends`` (including a
# ``package:library`` sublibrary dependency) and ``build-tool-depends``, and an
# ``if os(...)``/``else`` block inside a stanza that declares only link fields or
# ``buildable``. Any other conditional, and brace-delimited syntax, can change
# dependencies, so it is rejected with a diagnostic rather than ignored.


class Package:
    def __init__(self, name: str, directory: str, cabal_path: str) -> None:
        self.name = name
        self.directory = directory
        self.cabal_path = cabal_path
        self.components: dict[tuple[str, str], dict[str, list[str]]] = {}


def field_values(raw: str) -> list[str]:
    cleaned = raw.replace(",", " ")
    return [token for token in cleaned.split() if token]


def parse_cabal(text: str, path: str) -> tuple[str, dict[tuple[str, str], dict[str, list[str]]]]:
    """Parse one package description into its name and its components' fields."""
    package_name = ""
    commons: dict[str, dict[str, list[str]]] = {}
    components: dict[tuple[str, str], dict[str, list[str]]] = {}
    top_level: dict[str, list[str]] = {}

    stanza: dict[str, list[str]] = top_level
    field: str | None = None
    field_indent = 0
    # An open operating-system conditional: its indentation, whether it is the
    # `if` an `else` may follow, and the indentation of the field it is reading.
    conditional_indent: int | None = None
    conditional_is_if = False
    conditional_field_indent: int | None = None

    for number, line in enumerate(text.splitlines(), start=1):
        without_comment = line.split("--", 1)[0] if line.lstrip().startswith("--") else line
        if not without_comment.strip():
            continue
        indent = len(without_comment) - len(without_comment.lstrip())
        content = without_comment.strip()

        closed_if: int | None = None
        if conditional_indent is not None:
            if indent > conditional_indent:
                if conditional_field_indent is not None and indent > conditional_field_indent:
                    continue
                body = FIELD_PATTERN.match(content)
                if not body or body.group(1).lower() not in CONDITIONAL_FIELDS:
                    raise PlannerError(
                        f"{path}:{number}: an operating-system conditional may declare only "
                        f"{', '.join(sorted(CONDITIONAL_FIELDS))}; anything else inside it can "
                        "change dependencies or inputs silently"
                    )
                conditional_field_indent = indent
                continue
            closed_if = conditional_indent if conditional_is_if else None
            conditional_indent = None
            conditional_field_indent = None

        if CONDITIONAL_PATTERN.match(content) or content in ("{", "}") or content.endswith("{"):
            opens_if = OS_CONDITIONAL_PATTERN.fullmatch(content) is not None
            opens_else = content == "else" and closed_if == indent
            if indent > 0 and stanza is not top_level and (opens_if or opens_else):
                conditional_indent = indent
                conditional_is_if = opens_if
                conditional_field_indent = None
                field = None
                continue
            raise PlannerError(
                f"{path}:{number}: conditional or brace-delimited Cabal syntax is not supported "
                "by the validation planner; it can change dependencies silently (only an "
                "`if os(...)` or `else` block inside a stanza declaring link fields is accepted)"
            )

        if field is not None and indent > field_indent:
            stanza.setdefault(field, []).extend(field_values(content))
            continue

        stanza_match = STANZA_PATTERN.match(content)
        if indent == 0 and stanza_match and stanza_match.group(1).lower() in STANZA_KEYWORDS:
            keyword = stanza_match.group(1).lower()
            label = stanza_match.group(2) or ""
            stanza = {}
            field = None
            if keyword == "common":
                commons[label] = stanza
            elif keyword == "library":
                components[("lib", label or "@package")] = stanza
            elif keyword == "executable":
                components[("exe", label)] = stanza
            elif keyword in ("test-suite", "benchmark"):
                components[("test" if keyword == "test-suite" else "bench", label)] = stanza
            continue

        match = FIELD_PATTERN.match(content)
        if match:
            name = match.group(1).lower()
            values = field_values(match.group(2))
            if indent == 0:
                stanza = top_level
                if name == "name" and values:
                    package_name = values[0]
            stanza.setdefault(name, []).extend(values)
            field = name
            field_indent = indent
            continue

        raise PlannerError(f"{path}:{number}: unsupported Cabal syntax: {content!r}")

    if not package_name:
        raise PlannerError(f"{path}: the package description declares no name")

    resolved: dict[tuple[str, str], dict[str, list[str]]] = {}
    for (kind, label), fields in components.items():
        merged: dict[str, list[str]] = {}
        for imported in fields.get("import", []):
            if imported not in commons:
                raise PlannerError(f"{path}: stanza imports undefined common stanza {imported!r}")
            for key, values in commons[imported].items():
                merged.setdefault(key, []).extend(values)
        for key, values in fields.items():
            if key == "import":
                continue
            merged.setdefault(key, []).extend(values)
        resolved[(kind, package_name if label == "@package" else label)] = merged
    return package_name, resolved


def parse_project(text: str, path: str) -> list[str]:
    """Read the ``packages:`` field of a ``cabal.project``."""
    entries: list[str] = []
    collecting = False
    indent = 0
    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("--") or not line.strip():
            continue
        current = len(line) - len(line.lstrip())
        content = line.strip()
        if collecting and current > indent:
            entries.extend(field_values(content))
            continue
        collecting = False
        match = FIELD_PATTERN.match(content)
        if match and match.group(1).lower() == "packages":
            collecting = True
            indent = current
            entries.extend(field_values(match.group(2)))
    for entry in entries:
        if any(character in entry for character in "*?["):
            raise PlannerError(
                f"{path}: glob package entry {entry!r} is not supported by the validation planner"
            )
    return entries


def load_packages(tree, required: bool) -> dict[str, Package]:
    """Read the local package graph from one tree.

    ``required`` distinguishes the head revision, where the project metadata must
    exist, from a base revision that may predate it.
    """
    if not tree.exists(PROJECT_FILE):
        if required:
            raise PlannerError(f"{PROJECT_FILE} does not exist at {tree.label}")
        return {}
    directories = parse_project(tree.read(PROJECT_FILE), f"{PROJECT_FILE}@{tree.label}")
    packages: dict[str, Package] = {}
    for entry in directories:
        directory = join_path(entry)
        candidates = sorted(
            path
            for path in tree.files()
            if path.endswith(".cabal") and join_path(os.path.dirname(path)) == directory
        )
        if not candidates:
            if required:
                raise PlannerError(
                    f"no package description under {entry!r} at {tree.label}; "
                    f"{PROJECT_FILE} lists it as a local package"
                )
            continue
        if len(candidates) > 1:
            raise PlannerError(f"{entry!r} contains more than one package description at {tree.label}")
        cabal_path = candidates[0]
        name, components = parse_cabal(tree.read(cabal_path), f"{cabal_path}@{tree.label}")
        package = Package(name, directory, cabal_path)
        package.components = components
        if name in packages:
            raise PlannerError(f"two local packages are named {name!r} at {tree.label}")
        packages[name] = package
    return packages


def component_closure(
    packages: dict[str, Package], start: list[tuple[str, str, str]]
) -> set[tuple[str, str, str]]:
    """Follow local ``build-depends`` and ``build-tool-depends`` transitively."""
    seen: set[tuple[str, str, str]] = set()
    pending = list(start)
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        package_name, kind, component_name = current
        package = packages.get(package_name)
        if package is None:
            continue
        fields = package.components.get((kind, component_name))
        if fields is None:
            continue
        previous = ""
        for token in fields.get("build-depends", []):
            names_package = previous not in (">=", "<", "==", "&&", ">", "<=")
            if PACKAGE_NAME_PATTERN.fullmatch(token) and names_package:
                if token in packages:
                    pending.append((token, "lib", token))
            elif ":" in token and names_package:
                # `package:library` names one library of a package: a sublibrary,
                # or the main library when the two names agree, which is how the
                # main library is keyed.
                dependency, _, library = token.partition(":")
                if library.startswith("{"):
                    raise PlannerError(
                        f"{package.cabal_path}: the braced sublibrary dependency {token!r} is not "
                        "supported by the validation planner; name each library on its own"
                    )
                if (
                    PACKAGE_NAME_PATTERN.fullmatch(dependency)
                    and PACKAGE_NAME_PATTERN.fullmatch(library)
                    and dependency in packages
                ):
                    pending.append((dependency, "lib", library))
            previous = token
        for token in fields.get("build-tool-depends", []):
            if ":" in token:
                tool_package, _, tool_name = token.partition(":")
                tool_name = tool_name.split()[0] if tool_name.split() else tool_name
                if tool_package in packages:
                    pending.append((tool_package, "exe", tool_name))
    return seen


def component_inputs(packages: dict[str, Package], component: str | None) -> set[str]:
    """Derive the input paths of a catalog group's Cabal component."""
    if component is None:
        return set()
    if component == "all":
        start = [
            (package.name, kind, name)
            for package in packages.values()
            for (kind, name) in package.components
        ]
    else:
        package_name, kind, name = component.split(":")
        if package_name not in packages:
            return set()
        if (kind, name) not in packages[package_name].components:
            return set()
        start = [(package_name, kind, name)]

    inputs: set[str] = {PROJECT_FILE}
    for package_name, kind, name in component_closure(packages, start):
        package = packages.get(package_name)
        if package is None:
            continue
        inputs.add(package.cabal_path)
        fields = package.components.get((kind, name))
        if fields is None:
            continue
        directories = fields.get("hs-source-dirs", []) or ["."]
        for directory in directories:
            prefix = join_path(package.directory, directory)
            inputs.add(prefix + "/" if prefix else "")
            for main in fields.get("main-is", []):
                inputs.add(join_path(prefix, main))
        # Native sources are compiled into the component as surely as its
        # Haskell is, and they are declared relative to the package rather than
        # to a Haskell source directory, so neither is reached by the loop
        # above. A group whose C changed and whose plan said nothing would be
        # evidence about a component that was not the one built.
        for source in fields.get("c-sources", []) + fields.get("cxx-sources", []):
            inputs.add(join_path(package.directory, source))
        for directory in fields.get("include-dirs", []):
            prefix = join_path(package.directory, directory)
            inputs.add(prefix + "/" if prefix else "")
    return inputs


def resolve_component(packages: dict[str, Package], component: str) -> bool:
    if component == "all":
        return bool(packages)
    parts = component.split(":")
    if len(parts) != 3 or parts[1] not in COMPONENT_KINDS:
        return False
    package_name, kind, name = parts
    package = packages.get(package_name)
    return package is not None and (kind, name) in package.components


# --------------------------------------------------------------------------
# Catalog


def load_catalog_document(path: str, text: str) -> dict:
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise PlannerError(f"{path} is not valid JSON: {error}") from error
    if not isinstance(document, dict):
        raise PlannerError(f"{path} must contain a JSON object")
    return document


TOP_LEVEL_KEYS = {
    "schema_version": int,
    "policy_version": int,
    "policy_inputs": list,
    "non_affecting_paths": list,
    "floor": list,
    "groups": list,
}

# Paths a run leaves in a checkout that no execution reads as input: build
# trees, a run's own plan and receipts, editor and interpreter debris. The
# runner exempts them when deciding whether a checkout is still its candidate,
# and nothing else consults them — they classify no committed path, so they
# cannot excuse one. Optional because exempting nothing is the safe default for
# a catalog that has not thought about it.
OPTIONAL_TOP_LEVEL_KEYS = {
    "generated_paths": list,
}

GROUP_KEYS = {
    "id": str,
    "description": str,
    "command": list,
    "component": (str, type(None)),
    "inputs": list,
    "framework": str,
    "runner": str,
    "timeout_seconds": int,
    "category": str,
    "optional": bool,
}

# The platforms a group's command can actually be executed on, named by the
# plan's own ``runner_os`` values. Optional because the ordinary group runs
# everywhere, and declaring nothing is what says so; a declaration narrows and
# can never widen. It is a statement about what the machine builds, not about
# what a change touches: input derivation, the unknown-input fallback, and the
# identity digests never read it, so the same candidate means the same thing
# wherever it is planned.
OPTIONAL_GROUP_KEYS = {
    "platforms": list,
}


def validate_catalog(document: dict, path: str, packages: dict[str, Package] | None) -> list[str]:
    """Return every structural or referential problem in a catalog document."""
    problems: list[str] = []

    for key, expected in TOP_LEVEL_KEYS.items():
        if key not in document:
            problems.append(f"{path}: missing required key {key!r}")
        elif not isinstance(document[key], expected) or isinstance(document[key], bool):
            problems.append(f"{path}: key {key!r} must be a {expected.__name__}")
    for key, expected in OPTIONAL_TOP_LEVEL_KEYS.items():
        if key in document and (
            not isinstance(document[key], expected) or isinstance(document[key], bool)
        ):
            problems.append(f"{path}: key {key!r} must be a {expected.__name__}")
    for key in document:
        if key not in TOP_LEVEL_KEYS and key not in OPTIONAL_TOP_LEVEL_KEYS:
            problems.append(f"{path}: unknown top-level key {key!r}")
    if problems:
        return problems

    if document["schema_version"] != CATALOG_SCHEMA_VERSION:
        problems.append(
            f"{path}: schema_version {document['schema_version']} is not the supported version "
            f"{CATALOG_SCHEMA_VERSION}"
        )
    if document["policy_version"] < 1:
        problems.append(f"{path}: policy_version must be a positive integer")
    for key in ("policy_inputs", "non_affecting_paths", "floor"):
        for entry in document[key]:
            if not isinstance(entry, str) or not entry:
                problems.append(f"{path}: every {key} entry must be a non-empty string")
    # An empty entry would match every path, exempting the whole checkout from
    # the question the runner asks.
    for entry in document.get("generated_paths", []):
        if not isinstance(entry, str) or not entry:
            problems.append(f"{path}: every generated_paths entry must be a non-empty string")
    if not document["groups"]:
        problems.append(f"{path}: the catalog registers no groups")

    identifiers: set[str] = set()
    for index, group in enumerate(document["groups"]):
        where = f"{path}: group {index}"
        if not isinstance(group, dict):
            problems.append(f"{where} is not an object")
            continue
        identifier = group.get("id")
        if isinstance(identifier, str) and identifier:
            where = f"{path}: group {identifier!r}"
        for key, expected in GROUP_KEYS.items():
            if key not in group:
                problems.append(f"{where} is missing required key {key!r}")
                continue
            value = group[key]
            if key == "optional":
                if not isinstance(value, bool):
                    problems.append(f"{where} key 'optional' must be a boolean")
                continue
            if key == "timeout_seconds":
                if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                    problems.append(f"{where} key 'timeout_seconds' must be a positive integer")
                continue
            if not isinstance(value, expected):
                names = expected.__name__ if isinstance(expected, type) else "string or null"
                problems.append(f"{where} key {key!r} must be a {names}")
        for key, expected in OPTIONAL_GROUP_KEYS.items():
            if key in group and not isinstance(group[key], expected):
                problems.append(f"{where} key {key!r} must be a {expected.__name__}")
        for key in group:
            if key not in GROUP_KEYS and key not in OPTIONAL_GROUP_KEYS:
                problems.append(f"{where} has unknown key {key!r}")

        # An empty declaration would name a group nothing may ever execute,
        # which is a retired group rather than a platform-only one.
        platforms = group.get("platforms")
        if isinstance(platforms, list):
            if not platforms:
                problems.append(
                    f"{where} key 'platforms' must name at least one platform, or be omitted "
                    "to declare the group applicable everywhere"
                )
            for entry in platforms:
                if not isinstance(entry, str) or not entry:
                    problems.append(f"{where} has a non-string platforms entry")
            if len(set(platforms)) != len(platforms):
                problems.append(f"{where} names a platform more than once")

        if not isinstance(identifier, str) or not ID_PATTERN.match(identifier or ""):
            problems.append(f"{where} has an invalid id; expected dotted lowercase, e.g. 'test.engine'")
        elif identifier in identifiers:
            problems.append(f"{where} duplicates an earlier group id")
        else:
            identifiers.add(identifier)

        command = group.get("command")
        if isinstance(command, list) and (
            not command or not all(isinstance(token, str) and token for token in command)
        ):
            problems.append(f"{where} key 'command' must be a non-empty list of non-empty strings")
        if isinstance(group.get("framework"), str) and group["framework"] not in FRAMEWORKS:
            problems.append(f"{where} framework {group['framework']!r} is not one of {list(FRAMEWORKS)}")
        if isinstance(group.get("runner"), str) and group["runner"] not in RUNNERS:
            problems.append(f"{where} runner {group['runner']!r} is not one of {list(RUNNERS)}")
        if isinstance(group.get("category"), str) and group["category"] not in CATEGORIES:
            problems.append(f"{where} category {group['category']!r} is not one of {list(CATEGORIES)}")
        inputs = group.get("inputs")
        if isinstance(inputs, list):
            for entry in inputs:
                if not isinstance(entry, str) or not entry:
                    problems.append(f"{where} has a non-string input entry")
                elif entry.startswith("/") or ".." in entry.split("/"):
                    problems.append(f"{where} input {entry!r} must be a relative path inside the repository")
        component = group.get("component")
        if isinstance(component, str):
            if component != "all" and len(component.split(":")) != 3:
                problems.append(
                    f"{where} component {component!r} must be null, \"all\", or \"package:kind:name\""
                )
            elif component != "all" and component.split(":")[1] not in COMPONENT_KINDS:
                problems.append(
                    f"{where} component {component!r} names an unknown kind; expected one of {list(COMPONENT_KINDS)}"
                )
            elif packages is not None and not resolve_component(packages, component):
                problems.append(f"{where} component {component!r} does not exist in the local package graph")

    groups_by_id = {
        group["id"]: group
        for group in document["groups"]
        if isinstance(group, dict) and isinstance(group.get("id"), str)
    }
    for identifier in document["floor"]:
        if identifier not in groups_by_id:
            problems.append(f"{path}: floor names unregistered group {identifier!r}")
        elif groups_by_id[identifier].get("optional") is True:
            problems.append(f"{path}: floor names optional group {identifier!r}; the floor contains no optional group")
        elif "platforms" in groups_by_id[identifier]:
            # The floor is the evidence every candidate carries on every
            # machine. A floor group that some platform omits would make the
            # floor mean one thing on Linux and another on Darwin, so the
            # catalog refuses the declaration rather than the plan refusing it
            # later on one platform only.
            problems.append(
                f"{path}: floor names platform-restricted group {identifier!r}; "
                "the mandatory floor is selected on every platform"
            )
    return problems


# --------------------------------------------------------------------------
# Requests


def parse_request(text: str, source: str) -> tuple[list[str], bool]:
    """Read the ``validation-request`` fenced block from a PR body.

    Fence nesting is honoured: a ``validation-request`` example shown inside an
    outer fenced block is documentation, not a request. A fence whose info
    string starts with the reserved word but carries anything else is a
    malformed request rather than a block to ignore.
    """
    opener = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
    blocks: list[list[str]] = []
    body: list[str] = []
    fence = ""
    collecting = False
    for line in text.splitlines():
        match = opener.match(line.rstrip())
        if fence:
            closes = (
                match is not None
                and match.group(1)[0] == fence[0]
                and len(match.group(1)) >= len(fence)
                and not match.group(2).strip()
            )
            if closes:
                if collecting:
                    blocks.append(body)
                    body, collecting = [], False
                fence = ""
            elif collecting:
                body.append(line.strip())
            continue
        if match is None:
            continue
        fence = match.group(1)
        info = match.group(2).strip()
        if info.split()[0:1] == [REQUEST_FENCE]:
            if info != REQUEST_FENCE:
                raise PlannerError(
                    f"{source}: malformed validation-request info string {info!r}; "
                    f"the fence takes the bare word {REQUEST_FENCE!r}"
                )
            collecting = True

    if collecting:
        raise PlannerError(f"{source}: the validation-request block is never closed")
    if not blocks:
        return [], False
    if len(blocks) > 1:
        raise PlannerError(f"{source}: more than one validation-request block; the request is ambiguous")

    identifiers: list[str] = []
    all_hspec = False
    for entry in blocks[0]:
        if not entry:
            continue
        if len(entry.split()) > 1:
            raise PlannerError(f"{source}: malformed request line {entry!r}; use one catalog ID per line")
        if entry == ALL_HSPEC:
            all_hspec = True
        elif entry not in identifiers:
            identifiers.append(entry)
    return identifiers, all_hspec


# --------------------------------------------------------------------------
# Changed paths


def changed_paths(root: str, base: GitTree, head: GitTree) -> list[dict]:
    """Both endpoints of a rename and the removed path of a deletion count as changed."""
    raw = run_git(root, "diff", "--name-status", "-z", "--find-renames", base.commit, head.commit)
    fields = [entry for entry in raw.split("\0") if entry != ""]
    changes: dict[str, str] = {}
    index = 0
    while index < len(fields):
        status = fields[index]
        index += 1
        if status[0] in ("R", "C"):
            old, new = fields[index], fields[index + 1]
            index += 2
            changes.setdefault(old, "R-source")
            changes[new] = "R-target" if status[0] == "R" else "C-target"
        else:
            path = fields[index]
            index += 1
            changes.setdefault(path, status)
    return [{"path": path, "status": changes[path]} for path in sorted(changes)]


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


# --------------------------------------------------------------------------
# Planning


def build_plan(
    root: str,
    base: GitTree,
    head: GitTree,
    candidate: GitTree,
    identity: dict,
    catalog: dict,
    catalog_source: str,
    request_ids: list[str],
    request_all_hspec: bool,
    request_source: str | None,
    base_packages: dict[str, Package],
    head_packages: dict[str, Package],
    base_catalog: dict | None,
    base_catalog_state: str,
    catalog_override: str | None,
    candidate_catalog: dict,
    workers: list[dict] | None,
) -> dict:
    groups = catalog["groups"]
    groups_by_id = {group["id"]: group for group in groups}

    base_inputs: dict[str, list[str]] = {}
    base_policy_inputs: list[str] = []
    if base_catalog is not None:
        base_policy_inputs = base_catalog["policy_inputs"]
        base_inputs = {group["id"]: group["inputs"] for group in base_catalog["groups"]}

    # Inputs are derived from both revisions so a removed or relocated source,
    # or an input a group used to declare, still counts for that group. Policy
    # inputs reach every group, optional ones included: an optional group's
    # definition can change without selecting it, and a downstream consumer must
    # not read that as an unchanged execution definition.
    inputs_by_group: dict[str, set[str]] = {}
    for group in groups:
        derived = component_inputs(head_packages, group["component"])
        derived |= component_inputs(base_packages, group["component"])
        derived |= set(group["inputs"])
        derived |= set(base_inputs.get(group["id"], []))
        derived |= set(catalog["policy_inputs"])
        derived |= set(base_policy_inputs)
        inputs_by_group[group["id"]] = derived

    for identifier in request_ids:
        if identifier not in groups_by_id:
            raise PlannerError(
                f"{request_source}: requested group {identifier!r} is not registered in {catalog_source}"
            )
    requested = set(request_ids)
    if request_all_hspec:
        hspec = [group["id"] for group in groups if group["framework"] == "hspec"]
        if not hspec:
            raise PlannerError(
                f"{request_source}: '{ALL_HSPEC}' matched no Hspec group in {catalog_source}"
            )
        requested.update(hspec)

    changes = changed_paths(root, base, head)
    affected: set[str] = set()
    classified: list[dict] = []
    unknown_inputs: list[str] = []
    for change in changes:
        path = change["path"]
        consumers = sorted(
            identifier
            for identifier, entries in inputs_by_group.items()
            if any(matches_input(path, entry) for entry in entries)
        )
        if consumers:
            # An explicitly consumed input outranks a non-affecting class, so a
            # test-consumed Markdown file still invalidates its consumers.
            classification = "consumed"
            affected.update(consumers)
        elif any(matches_class(path, pattern) for pattern in catalog["non_affecting_paths"]):
            classification = "non-affecting"
        else:
            classification = "unknown"
            unknown_inputs.append(path)
        classified.append({**change, "classification": classification, "consumers": consumers})

    floor = set(catalog["floor"])
    fallback = bool(unknown_inputs)

    runner_os = identity["runner_os"]

    entries: list[dict] = []
    for group in groups:
        identifier = group["id"]
        optional = group["optional"]
        platforms = group.get("platforms")
        changed = identifier in affected
        if not optional and fallback:
            # Uncertainty must never reach a downstream consumer as equivalence.
            changed = True
        # Platform eligibility is asked first, and it is the one answer a
        # request cannot argue with. A group whose command targets components
        # this platform does not build has no execution available to it, so
        # selecting it would produce either a plan no worker can route or a
        # command that fails before any probe runs. Naming it here, with a
        # reason of its own, is what keeps that omission distinguishable from
        # one this platform merely did not need — and from a pass.
        #
        # `changed` is decided above and deliberately left alone: what a
        # candidate touches is a property of the candidate, so an inapplicable
        # group still reports its changed inputs, and the unknown-input
        # fallback still marks it, exactly as it does on the platform that
        # builds it.
        if platforms is not None and runner_os not in platforms:
            selected = False
            reason = receipts.PLATFORM_INAPPLICABLE
        elif optional:
            selected = identifier in requested
            reason = "requested" if selected else "optional-unrequested"
        else:
            selected = True
            if identifier in floor:
                reason = "floor"
            elif identifier in affected:
                reason = "affected"
            elif identifier in requested:
                reason = "requested"
            elif fallback:
                reason = "unknown-input"
            else:
                selected = False
                reason = "unaffected"
        entries.append(
            {
                "id": identifier,
                "description": group["description"],
                "selected": selected,
                "inputs_changed": changed,
                "reason": reason,
                "optional": optional,
                # `null` for a group applicable everywhere, so a consumer reads
                # the declaration rather than inferring it from the reason.
                "platforms": list(platforms) if platforms is not None else None,
                "framework": group["framework"],
                "category": group["category"],
                "runner": group["runner"],
                "timeout_seconds": group["timeout_seconds"],
                "command": list(group["command"]),
            }
        )

    # Routing is decided here, once, against the groups this plan selected. A
    # plan that nobody could execute is refused before it exists rather than
    # discovered by a worker that cannot run it or an aggregate missing a
    # receipt. Without declarations the plan is an inspection of selection
    # alone, and every tool that would act on it refuses it.
    routed = None
    if workers is not None:
        routed = receipts.normalized_workers(workers, entries)
        problems = receipts.worker_assignment_problems(routed, entries)
        if problems:
            raise PlannerError("the worker declarations cannot route this plan: " + "; ".join(problems))

    return {
        "schema_version": PLAN_SCHEMA_VERSION,
        # The catalog's declared revision stays an integer a person can read,
        # and is the one recorded here under its own name. `policy_version` is
        # the digest reuse compares, because a classification change that never
        # touches the declared revision still has to invalidate evidence.
        "catalog_policy_version": catalog["policy_version"],
        "policy_version": identity["policy_version"],
        "input_identity": identity["input_identity"],
        "toolchain": dict(identity["toolchain"]),
        # The platform an execution's result is a claim about. A receipt from
        # another operating system describes another machine's behaviour.
        "runner_os": identity["runner_os"],
        # The descriptor of the image Linux workers run, read from the
        # candidate and already checked against it, or null when the plan has
        # no image. Its digest and native manifest are also in `toolchain`,
        # which is what every compatibility comparison reads.
        "ci_image": identity["ci_image"],
        # `override` and `candidate_digest` describe the classification the
        # runner has to reproduce before it can judge its own checkout: which
        # catalog decided this candidate's inputs, and exactly what that catalog
        # said. A fixture catalog lives on the mutable filesystem rather than in
        # the candidate's tree, so naming the path alone would let it be
        # rewritten between planning and execution; the digest is what binds its
        # contents. The path itself stays out of `plan_identity`, which
        # deliberately omits run-local filenames.
        "catalog": {
            "source": catalog_source,
            "override": catalog_override,
            "candidate_digest": digest(candidate_catalog),
            "groups": len(groups),
        },
        "base": {"revision": base.revision, "commit": base.commit, "tree": base.tree},
        "head": {"revision": head.revision, "commit": head.commit, "tree": head.tree},
        # Selection compares the contribution; execution happens on the
        # integration candidate, and that is the tree identity fingerprints.
        "candidate": {
            "revision": candidate.revision,
            "commit": candidate.commit,
            "tree": candidate.tree,
        },
        "base_package_metadata": "present" if base_packages else "absent",
        "base_catalog": base_catalog_state,
        "request": {
            "source": request_source,
            "ids": sorted(request_ids),
            "all_hspec": request_all_hspec,
            "resolved": sorted(requested),
        },
        "changed_paths": classified,
        "unknown_inputs": sorted(unknown_inputs),
        "groups": entries,
        "selected": [entry["id"] for entry in entries if entry["selected"]],
        "workers": routed,
    }


def render_prose(plan: dict) -> str:
    lines = ["Validation plan"]
    lines.append(f"  base     {plan['base']['revision']} ({plan['base']['commit'][:12]})")
    lines.append(f"  head     {plan['head']['revision']} ({plan['head']['commit'][:12]})")
    lines.append(f"  candidate {plan['candidate']['revision']} ({plan['candidate']['commit'][:12]})")
    lines.append(
        f"  catalog  {plan['catalog']['source']} "
        f"({plan['catalog']['groups']} groups, policy version {plan['catalog_policy_version']})"
    )
    lines.append(f"  policy   {plan['policy_version'][:12]}")
    lines.append(f"  inputs   {plan['input_identity'][:12]}")
    declared = ", ".join(f"{name} {version}" for name, version in sorted(plan["toolchain"].items()))
    lines.append(f"  pinned   {declared or 'no toolchain'} on {plan['runner_os']}")
    if plan["ci_image"]:
        lines.append(f"  image    {plan['ci_image']['reference']}@{plan['ci_image']['digest']}")
    request = plan["request"]
    if request["resolved"]:
        lines.append(f"  request  {', '.join(request['resolved'])} (from {request['source']})")
    else:
        lines.append("  request  none")
    if plan["base_package_metadata"] == "absent":
        lines.append("  note     the base revision carries no package metadata; head inputs alone were derived")
    if plan["base_catalog"] == "absent":
        lines.append("  note     the base revision carries no catalog; head declarations alone were read")

    lines.append("")
    if plan["changed_paths"]:
        lines.append(f"Changed paths ({len(plan['changed_paths'])})")
        width = max(len(change["path"]) for change in plan["changed_paths"])
        for change in plan["changed_paths"]:
            lines.append(
                f"  {change['status']:<9} {change['path']:<{width}}  {change['classification']}"
            )
    else:
        lines.append("Changed paths (0)")
    if plan["unknown_inputs"]:
        lines.append("")
        lines.append("Unknown inputs select every non-optional group:")
        for path in plan["unknown_inputs"]:
            lines.append(f"  {path}")

    lines.append("")
    lines.append("Groups")
    width = max(len(entry["id"]) for entry in plan["groups"])
    # Widened from the reasons actually present rather than pinned to the
    # longest one the policy can produce, so adding a reason cannot silently
    # ragged the column.
    reason_width = max(len(entry["reason"]) for entry in plan["groups"])
    owners = {
        identifier: worker["name"]
        for worker in plan["workers"] or []
        for identifier in worker["groups"]
    }
    owner_width = max((len(name) for name in owners.values()), default=1)
    for entry in plan["groups"]:
        mark = "run " if entry["selected"] else "skip"
        lines.append(
            f"  [{mark}] {entry['id']:<{width}}  {entry['reason']:<{reason_width}} "
            f"inputs changed: {'yes' if entry['inputs_changed'] else 'no':<3}  "
            f"runner: {entry['runner']:<7}  worker: {owners.get(entry['id'], '-'):<{owner_width}}  "
            f"{' '.join(entry['command'])}"
        )

    lines.append("")
    if plan["workers"] is None:
        lines.append("Workers: none declared; this plan is for inspection only and cannot be executed.")
    else:
        lines.append("Workers")
        for worker in plan["workers"]:
            lines.append(
                f"  {worker['name']} ({'+'.join(worker['runner_classes'])}): {', '.join(worker['groups'])}"
            )

    omitted = [entry for entry in plan["groups"] if not entry["selected"]]
    lines.append("")
    lines.append(
        f"Selected {len(plan['selected'])} of {len(plan['groups'])} groups; "
        f"{len(omitted)} explained omission{'' if len(omitted) == 1 else 's'}."
    )
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Entry point


def repository_root(supplied: str | None) -> str:
    if supplied:
        return os.path.abspath(supplied)
    process = subprocess.run(
        ("git", "rev-parse", "--show-toplevel"), capture_output=True, text=True, check=False
    )
    if process.returncode == 0 and process.stdout.strip():
        return process.stdout.strip()
    return os.getcwd()


def read_catalog(tree, override: str | None, root: str) -> tuple[dict, str]:
    if override:
        path = override if os.path.isabs(override) else os.path.join(root, override)
        try:
            with open(path, "rb") as handle:
                raw = handle.read()
        except OSError as error:
            raise PlannerError(f"cannot read catalog {override}: {error}") from error
        return load_catalog_document(override, decode(raw, override)), override
    if not tree.exists(DEFAULT_CATALOG):
        raise PlannerError(f"{DEFAULT_CATALOG} does not exist at {tree.label}")
    source = f"{DEFAULT_CATALOG}@{tree.label}"
    return load_catalog_document(source, tree.read(DEFAULT_CATALOG)), source


def read_base_catalog(tree: GitTree, override: str | None) -> tuple[dict | None, str]:
    """Read the base revision's catalog so a group's retired inputs still count.

    A base predating the catalog is the supported rollout case. A base catalog
    that exists but cannot be read is a diagnostic, never a silent omission. A
    fixture catalog supplied with ``--catalog`` has no base counterpart.
    """
    if override:
        return None, "not-applicable"
    if not tree.exists(DEFAULT_CATALOG):
        return None, "absent"
    source = f"{DEFAULT_CATALOG}@{tree.label}"
    document = load_catalog_document(source, tree.read(DEFAULT_CATALOG))
    groups = document.get("groups")
    policy_inputs = document.get("policy_inputs")
    if not isinstance(groups, list) or not isinstance(policy_inputs, list):
        raise PlannerError(f"{source} declares no readable 'groups' and 'policy_inputs'")
    for group in groups:
        if (
            not isinstance(group, dict)
            or not isinstance(group.get("id"), str)
            or not isinstance(group.get("inputs"), list)
        ):
            raise PlannerError(f"{source} declares a group with no readable 'id' and 'inputs'")
    if not all(isinstance(entry, str) for entry in policy_inputs):
        raise PlannerError(f"{source} declares a non-string policy input")
    return document, "present"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="plan.py",
        description="Resolve and explain the validation groups a change requires.",
    )
    parser.add_argument("--base", help="base revision of the comparison")
    parser.add_argument("--head", help="head revision of the comparison")
    parser.add_argument(
        "--candidate",
        help="the integration revision workers execute (default: the head revision)",
    )
    parser.add_argument(
        "--toolchain",
        action="append",
        default=[],
        metavar="NAME=VERSION",
        help="a pinned toolchain version the candidate's identity covers; repeatable",
    )
    parser.add_argument(
        "--runner-os",
        help="the operating system the workers execute on (default: this runner's)",
    )
    parser.add_argument(
        "--worker",
        action="append",
        default=[],
        metavar="NAME=CLASS[+CLASS]:GROUP[,GROUP]",
        help="a worker, the runner classes it declares, and the groups it owns; repeatable. "
        "Without any, the plan describes selection only and cannot be executed",
    )
    parser.add_argument("--request-file", help="file holding a PR body with a validation-request block")
    parser.add_argument("--catalog", help="fixture catalog path, read from the filesystem")
    parser.add_argument("--repo-root", help="repository to plan for (default: the enclosing checkout)")
    parser.add_argument("--catalog-check", action="store_true", help="validate the catalog and exit")
    parser.add_argument("--json", action="store_true", dest="as_json", help="emit the plan as JSON")
    arguments = parser.parse_args(argv)

    root = repository_root(arguments.repo_root)

    if arguments.catalog_check:
        for name in ("base", "head", "candidate", "request_file", "worker"):
            if getattr(arguments, name):
                raise PlannerError(f"--catalog-check takes no --{name.replace('_', '-')}")
        tree = WorkTree(root)
        document, source = read_catalog(tree, arguments.catalog, root)
        packages = load_packages(tree, required=True)
        problems = validate_catalog(document, source, packages)
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            return 2
        print(f"catalog {source} is valid: {len(document['groups'])} groups, policy version {document['policy_version']}")
        return 0

    if not arguments.base or not arguments.head:
        raise PlannerError("both --base and --head are required unless --catalog-check is used")

    base = GitTree(root, arguments.base)
    head = GitTree(root, arguments.head)

    document, catalog_source = read_catalog(head, arguments.catalog, root)
    head_packages = load_packages(head, required=True)
    problems = validate_catalog(document, catalog_source, head_packages)
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 2
    base_packages = load_packages(base, required=False)
    base_catalog, base_catalog_state = read_base_catalog(base, arguments.catalog)

    # The candidate defaults to the head so a local plan needs no extra
    # revision; CI supplies the integration commit its workers check out, which
    # is neither endpoint and is the only tree an execution actually reads.
    if arguments.candidate:
        candidate = GitTree(root, arguments.candidate)
    else:
        candidate = head
    if candidate.commit == head.commit:
        candidate_catalog, candidate_catalog_source = document, catalog_source
        candidate_packages = head_packages
    else:
        candidate_catalog, candidate_catalog_source = read_catalog(candidate, arguments.catalog, root)
        candidate_packages = load_packages(candidate, required=True)
        problems = validate_catalog(candidate_catalog, candidate_catalog_source, candidate_packages)
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            return 2

    try:
        toolchain = receipts.parse_toolchain(arguments.toolchain)
        workers = (
            [receipts.parse_worker_declaration(entry) for entry in arguments.worker]
            if arguments.worker
            else None
        )
    except receipts.EvidenceError as failure:
        raise PlannerError(str(failure)) from failure
    runner_os = arguments.runner_os or os.environ.get("RUNNER_OS") or platform.system()
    entries = tree_entries(root, candidate.commit)
    # The toolchain map describes the planned worker environment, not this
    # host. For Linux workers that is the image the candidate's own descriptor
    # names, so its digest and native manifest join the map before identity is
    # taken from it — and a descriptor that no longer describes the candidate
    # stops the plan here, before anything executes.
    try:
        image, toolchain = ci_image.plan_image(candidate.read, entries, toolchain, runner_os, candidate.label)
    except ci_image.ImageError as failure:
        raise PlannerError(str(failure)) from failure
    policy = policy_identity(candidate_catalog, entries)
    identity = {
        "runner_os": runner_os,
        "ci_image": image,
        "policy_version": policy,
        "input_identity": input_identity(
            candidate_catalog, candidate_packages, entries, policy, toolchain
        ),
        "toolchain": toolchain,
    }

    request_ids: list[str] = []
    request_all_hspec = False
    request_source = None
    if arguments.request_file:
        request_source = arguments.request_file
        try:
            with open(arguments.request_file, "rb") as handle:
                raw_request = handle.read()
        except OSError as error:
            raise PlannerError(f"cannot read request file {arguments.request_file}: {error}") from error
        request_ids, request_all_hspec = parse_request(
            decode(raw_request, arguments.request_file), request_source
        )

    plan = build_plan(
        root,
        base,
        head,
        candidate,
        identity,
        document,
        catalog_source,
        request_ids,
        request_all_hspec,
        request_source,
        base_packages,
        head_packages,
        base_catalog,
        base_catalog_state,
        arguments.catalog,
        candidate_catalog,
        workers,
    )
    if arguments.as_json:
        print(json.dumps(plan, indent=2, sort_keys=False))
    else:
        print(render_prose(plan))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except PlannerError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
