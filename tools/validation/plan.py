#!/usr/bin/env python3
"""Resolve which validation groups a candidate change requires, and explain why.

The planner reads the declarative catalog (``tools/validation/catalog.json`` by
default), derives each group's inputs from the local Cabal package graph plus
the group's explicitly declared non-Haskell inputs, compares two revisions, and
emits a plan naming every catalog group with a selection reason.

It depends on Python 3 and Git alone: no GHC, no Cabal, no ``dist-newstyle/``.

See ``docs/validation.md`` for the catalog schema, the selection policy, the
request block, and the plan's JSON structure.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

SCHEMA_VERSION = 1
DEFAULT_CATALOG = "tools/validation/catalog.json"
PROJECT_FILE = "cabal.project"

COMPONENT_KINDS = ("lib", "exe", "test")
FRAMEWORKS = ("hspec", "none")
RUNNERS = ("cpu",)
CATEGORIES = ("build", "test", "smoke", "probe")

ID_PATTERN = re.compile(r"^[a-z0-9]+(\.[a-z0-9-]+)+$")
FIELD_PATTERN = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:(.*)$")
STANZA_PATTERN = re.compile(r"^([A-Za-z][A-Za-z0-9-]*)(?:\s+(\S+))?\s*$")
CONDITIONAL_PATTERN = re.compile(r"^(if|elif|else)\b")

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


def run_git(root: str, *args: str) -> str:
    process = subprocess.run(
        ("git", "-C", root) + args,
        capture_output=True,
        text=True,
        check=False,
    )
    if process.returncode != 0:
        raise PlannerError(
            "git " + " ".join(args) + " failed: " + (process.stderr.strip() or "no output")
        )
    return process.stdout


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
        return process.stdout.decode("utf-8", errors="replace")


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
            with open(os.path.join(self.root, path), "r", encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except OSError as error:
            raise PlannerError(f"cannot read {path}: {error}") from error


# --------------------------------------------------------------------------
# Cabal parsing
#
# Supported syntax is deliberately bounded to what this repository uses:
# layout-style stanzas, ``common``/``import``, multiline fields, package
# relative ``hs-source-dirs``, ``main-is``, ``build-depends`` and
# ``build-tool-depends``. Conditional and brace-delimited syntax can change
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

    for number, line in enumerate(text.splitlines(), start=1):
        without_comment = line.split("--", 1)[0] if line.lstrip().startswith("--") else line
        if not without_comment.strip():
            continue
        indent = len(without_comment) - len(without_comment.lstrip())
        content = without_comment.strip()

        if CONDITIONAL_PATTERN.match(content) or content in ("{", "}") or content.endswith("{"):
            raise PlannerError(
                f"{path}:{number}: conditional or brace-delimited Cabal syntax is not supported "
                "by the validation planner; it can change dependencies silently"
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
            if re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*", token) and previous not in (">=", "<", "==", "&&", ">", "<="):
                if token in packages:
                    pending.append((token, "lib", token))
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


def validate_catalog(document: dict, path: str, packages: dict[str, Package] | None) -> list[str]:
    """Return every structural or referential problem in a catalog document."""
    problems: list[str] = []

    for key, expected in TOP_LEVEL_KEYS.items():
        if key not in document:
            problems.append(f"{path}: missing required key {key!r}")
        elif not isinstance(document[key], expected) or isinstance(document[key], bool):
            problems.append(f"{path}: key {key!r} must be a {expected.__name__}")
    for key in document:
        if key not in TOP_LEVEL_KEYS:
            problems.append(f"{path}: unknown top-level key {key!r}")
    if problems:
        return problems

    if document["schema_version"] != SCHEMA_VERSION:
        problems.append(
            f"{path}: schema_version {document['schema_version']} is not the supported version {SCHEMA_VERSION}"
        )
    if document["policy_version"] < 1:
        problems.append(f"{path}: policy_version must be a positive integer")
    for key in ("policy_inputs", "non_affecting_paths", "floor"):
        for entry in document[key]:
            if not isinstance(entry, str) or not entry:
                problems.append(f"{path}: every {key} entry must be a non-empty string")
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
        for key in group:
            if key not in GROUP_KEYS:
                problems.append(f"{where} has unknown key {key!r}")

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
    return problems


# --------------------------------------------------------------------------
# Requests


def parse_request(text: str, source: str) -> tuple[list[str], bool]:
    """Read the ``validation-request`` fenced block from a PR body."""
    lines = text.splitlines()
    blocks: list[list[str]] = []
    index = 0
    while index < len(lines):
        stripped = lines[index].strip()
        match = re.fullmatch(r"(`{3,}|~{3,})\s*([A-Za-z0-9_-]*)\s*", stripped)
        if match and match.group(2) == REQUEST_FENCE:
            fence = match.group(1)[0] * len(match.group(1))
            body: list[str] = []
            index += 1
            closed = False
            while index < len(lines):
                candidate = lines[index].strip()
                if re.fullmatch(re.escape(fence) + r"`*~*\s*", candidate):
                    closed = True
                    break
                body.append(candidate)
                index += 1
            if not closed:
                raise PlannerError(f"{source}: the validation-request block is never closed")
            blocks.append(body)
        index += 1

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
# Planning


def build_plan(
    root: str,
    base: GitTree,
    head: GitTree,
    catalog: dict,
    catalog_source: str,
    request_ids: list[str],
    request_all_hspec: bool,
    request_source: str | None,
    base_packages: dict[str, Package],
    head_packages: dict[str, Package],
) -> dict:
    groups = catalog["groups"]
    groups_by_id = {group["id"]: group for group in groups}

    # Inputs are derived from both revisions so a removed or relocated source
    # still counts for the group that used to own it.
    inputs_by_group: dict[str, set[str]] = {}
    for group in groups:
        derived = component_inputs(head_packages, group["component"])
        derived |= component_inputs(base_packages, group["component"])
        derived |= {entry for entry in group["inputs"]}
        if not group["optional"]:
            derived |= set(catalog["policy_inputs"])
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

    entries: list[dict] = []
    for group in groups:
        identifier = group["id"]
        optional = group["optional"]
        changed = identifier in affected
        if not optional and fallback:
            # Uncertainty must never reach a downstream consumer as equivalence.
            changed = True
        if optional:
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
                "framework": group["framework"],
                "category": group["category"],
                "runner": group["runner"],
                "timeout_seconds": group["timeout_seconds"],
                "command": list(group["command"]),
            }
        )

    return {
        "schema_version": SCHEMA_VERSION,
        "policy_version": catalog["policy_version"],
        "catalog": {"source": catalog_source, "groups": len(groups)},
        "base": {"revision": base.revision, "commit": base.commit, "tree": base.tree},
        "head": {"revision": head.revision, "commit": head.commit, "tree": head.tree},
        "base_package_metadata": "present" if base_packages else "absent",
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
    }


def render_prose(plan: dict) -> str:
    lines = ["Validation plan"]
    lines.append(f"  base     {plan['base']['revision']} ({plan['base']['commit'][:12]})")
    lines.append(f"  head     {plan['head']['revision']} ({plan['head']['commit'][:12]})")
    lines.append(
        f"  catalog  {plan['catalog']['source']} "
        f"({plan['catalog']['groups']} groups, policy version {plan['policy_version']})"
    )
    request = plan["request"]
    if request["resolved"]:
        lines.append(f"  request  {', '.join(request['resolved'])} (from {request['source']})")
    else:
        lines.append("  request  none")
    if plan["base_package_metadata"] == "absent":
        lines.append("  note     the base revision carries no package metadata; head inputs alone were derived")

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
    for entry in plan["groups"]:
        mark = "run " if entry["selected"] else "skip"
        lines.append(
            f"  [{mark}] {entry['id']:<{width}}  {entry['reason']:<19} "
            f"inputs changed: {'yes' if entry['inputs_changed'] else 'no':<3}  "
            f"{' '.join(entry['command'])}"
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
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
        except OSError as error:
            raise PlannerError(f"cannot read catalog {override}: {error}") from error
        return load_catalog_document(override, text), override
    if not tree.exists(DEFAULT_CATALOG):
        raise PlannerError(f"{DEFAULT_CATALOG} does not exist at {tree.label}")
    source = f"{DEFAULT_CATALOG}@{tree.label}"
    return load_catalog_document(source, tree.read(DEFAULT_CATALOG)), source


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="plan.py",
        description="Resolve and explain the validation groups a change requires.",
    )
    parser.add_argument("--base", help="base revision of the comparison")
    parser.add_argument("--head", help="head revision of the comparison")
    parser.add_argument("--request-file", help="file holding a PR body with a validation-request block")
    parser.add_argument("--catalog", help="fixture catalog path, read from the filesystem")
    parser.add_argument("--repo-root", help="repository to plan for (default: the enclosing checkout)")
    parser.add_argument("--catalog-check", action="store_true", help="validate the catalog and exit")
    parser.add_argument("--json", action="store_true", dest="as_json", help="emit the plan as JSON")
    arguments = parser.parse_args(argv)

    root = repository_root(arguments.repo_root)

    if arguments.catalog_check:
        for name in ("base", "head", "request_file"):
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

    request_ids: list[str] = []
    request_all_hspec = False
    request_source = None
    if arguments.request_file:
        request_source = arguments.request_file
        try:
            with open(arguments.request_file, "r", encoding="utf-8") as handle:
                request_text = handle.read()
        except OSError as error:
            raise PlannerError(f"cannot read request file {arguments.request_file}: {error}") from error
        request_ids, request_all_hspec = parse_request(request_text, request_source)

    plan = build_plan(
        root,
        base,
        head,
        document,
        catalog_source,
        request_ids,
        request_all_hspec,
        request_source,
        base_packages,
        head_packages,
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
