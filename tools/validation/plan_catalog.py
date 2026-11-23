"""The validation catalog's contract: reading a catalog and checking its schema.

The catalog (``tools/validation/catalog.json``) is the one declaration of every
validation group. This module reads it from a revision or a fixture path, reads
the base revision's declarations selection unions in, and reports every
structural or referential problem a document has rather than stopping at the
first. See ``docs/validation.md`` for the schema.
"""

from __future__ import annotations

import json
import os
import re

import receipts
from plan_cabal import COMPONENT_KINDS, Package, resolve_component
from plan_repository import GitTree, PlannerError, decode

# The catalog's schema and the plan's are separate contracts: the plan gained
# identity fields while the catalog's keys did not move. The plan's own version
# is `plan_selection.PLAN_SCHEMA_VERSION`.
CATALOG_SCHEMA_VERSION = 1
DEFAULT_CATALOG = "tools/validation/catalog.json"

FRAMEWORKS = ("hspec", "none")
RUNNERS = receipts.RUNNER_CLASSES
CATEGORIES = ("build", "test", "smoke", "probe")

ID_PATTERN = re.compile(r"^[a-z0-9]+(\.[a-z0-9-]+)+$")


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
    "preparation": dict,
}

# A preparation stage: a command the runner executes to completion before the
# group's own command, under a budget of its own, and records separately. It
# exists for a group whose ``timeout_seconds`` is a measurement rather than a
# ceiling — a native check whose budget counts its display, fixture, examples
# and teardown but not the compilation that produced its executable. Its command
# is part of the plan's identity exactly as the group's own is, so evidence
# gathered under one preparation never answers for another; and it can never
# stand in for the command it prepares, because a group whose preparation did
# not pass is a group that did not run.
PREPARATION_KEYS = {
    "command": list,
    "timeout_seconds": int,
}


def preparation_problems(preparation: dict, where: str) -> list[str]:
    """Every problem with one group's preparation declaration."""
    problems: list[str] = []
    for key in PREPARATION_KEYS:
        if key not in preparation:
            problems.append(f"{where} preparation is missing required key {key!r}")
    for key in preparation:
        if key not in PREPARATION_KEYS:
            problems.append(f"{where} preparation has unknown key {key!r}")
    command = preparation.get("command")
    if "command" in preparation and (
        not isinstance(command, list)
        or not command
        or not all(isinstance(token, str) and token for token in command)
    ):
        problems.append(f"{where} preparation 'command' must be a non-empty list of non-empty strings")
    timeout = preparation.get("timeout_seconds")
    if "timeout_seconds" in preparation and (
        not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0
    ):
        problems.append(f"{where} preparation 'timeout_seconds' must be a positive integer")
    return problems


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
            named = [entry for entry in platforms if isinstance(entry, str) and entry]
            if len(named) != len(platforms):
                problems.append(f"{where} has a non-string platforms entry")
            # Asked of the entries that are names, because a catalog is
            # arbitrary JSON: an array or object entry is unhashable, and
            # counting it would raise where a diagnostic is owed.
            elif len(set(named)) != len(named):
                problems.append(f"{where} names a platform more than once")
        preparation = group.get("preparation")
        if isinstance(preparation, dict):
            problems.extend(preparation_problems(preparation, where))

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
