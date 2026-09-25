#!/usr/bin/env python3
"""The evidence contract shared by the validation runner and the aggregate.

A plan produced by ``tools/validation/plan.py`` is the only authority for what
a run must execute: the runner reads a group's exact command and timeout from
it, and the aggregate decides the verdict against it. Both sides therefore need
one derivation of *plan identity* — the fingerprint every receipt names, so a
result can never be credited to a plan that did not ask for it — and one
definition of the fields a receipt must carry. Keeping both here is what stops
the two scripts from drifting into disagreeing about the same evidence.

See ``docs/validation.md`` for the receipt fields and the aggregate's rules.
"""

from __future__ import annotations

import hashlib
import json
import os
import re

# Version 4 of both carries a group's optional preparation stage: the plan
# declares it, the plan identity binds it, and a receipt records how it ended
# beside the execution it prepared, with a deadline's expiry kept apart from the
# cleanup that followed it. A version 3 reader would run a prepared group's
# command without its preparation, so the versions move rather than the field
# being added silently.
PLAN_SCHEMA_VERSION = 4
RECEIPT_SCHEMA_VERSION = 4
APPLICABILITY_SCHEMA_VERSION = 1

# The execution environments a group can require and a worker can provide.
# `cpu` is an ordinary headless worker; `display` is one that owns a windowing
# session — an isolated X11 display on Linux. A worker declares its classes
# explicitly; nothing is ever inferred from its name.
RUNNER_CLASSES = ("cpu", "display")

WORKER_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")

# A plan resolved without worker declarations still explains selection, but it
# names nobody who could run what it selected, so it is never executable.
INSPECTION_ONLY = (
    "was resolved without worker declarations, so it describes selection only and "
    "nothing may execute, reuse evidence, or decide a verdict against it; resolve it "
    "again with one --worker NAME=CLASS[+CLASS]:GROUP[,GROUP] per worker"
)

# The fields an earlier execution and the current candidate must agree on
# before that execution's result may stand in for one. They are deliberately
# the whole comparison: content, policy, toolchain, and platform.
COMPATIBILITY_FIELDS = ("input_identity", "policy_version", "toolchain", "runner_os")

# The artifact one group's receipt is published under. The identity is in the
# name so a lookup asks for evidence about *these* inputs rather than fetching
# every receipt a group ever produced and filtering afterwards. It is defined
# here because both the side that publishes evidence and the side that reads a
# record back have to agree on what a stored artifact was named.
ARTIFACT_PREFIX = "receipt"


def artifact_name(group: str, identity: str) -> str:
    return f"{ARTIFACT_PREFIX}-{group}-{identity}"

# Outcomes a receipt may record. ``timeout`` is distinct from ``failed``
# because a group that exhausted its declared budget is a different obstacle
# from one that ran to completion and disagreed with the code.
OUTCOMES = ("passed", "failed", "timeout")

# The reason a group is omitted because the plan's platform does not build the
# components its command targets. It is kept apart from the other omissions
# because they describe work this platform *could* have done and did not need
# to, while this one describes work no execution here could have performed: a
# receipt or an earlier execution offered for it is refused rather than
# ignored, so an omission can never be read back as coverage.
PLATFORM_INAPPLICABLE = "platform-inapplicable"

# Selection reasons that explain a group away without any execution. Every
# other reason names work the aggregate expects a receipt for.
OMITTED_REASONS = ("unaffected", "optional-unrequested", PLATFORM_INAPPLICABLE)


class EvidenceError(Exception):
    """A diagnostic reported instead of a result or a verdict."""


# --------------------------------------------------------------------------
# Reading documents
#
# Every document is decoded as strict UTF-8 and required to be a JSON object.
# Evidence that would have to be repaired to parse is not evidence.


def read_document(path: str, description: str) -> dict:
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as error:
        raise EvidenceError(f"cannot read {description} {path}: {error}") from error
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError(f"{description} {path} is not valid UTF-8: {error}") from error
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise EvidenceError(f"{description} {path} is not valid JSON: {error}") from error
    if not isinstance(document, dict):
        raise EvidenceError(f"{description} {path} is not a JSON object")
    return document


def _value(document: dict, key: str, description: str):
    if key not in document:
        raise EvidenceError(f"{description} is missing {key!r}")
    return document[key]


def require_str(document: dict, key: str, description: str) -> str:
    value = _value(document, key, description)
    if not isinstance(value, str):
        raise EvidenceError(f"{description} field {key!r} is not a string")
    return value


def require_bool(document: dict, key: str, description: str) -> bool:
    value = _value(document, key, description)
    if not isinstance(value, bool):
        raise EvidenceError(f"{description} field {key!r} is not a boolean")
    return value


def require_int(document: dict, key: str, description: str) -> int:
    value = _value(document, key, description)
    # ``bool`` is a subclass of ``int``; a flag is never a count or a budget.
    if isinstance(value, bool) or not isinstance(value, int):
        raise EvidenceError(f"{description} field {key!r} is not an integer")
    return value


def require_number(document: dict, key: str, description: str) -> float:
    value = _value(document, key, description)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{description} field {key!r} is not a number")
    return float(value)


def require_dict(document: dict, key: str, description: str) -> dict:
    value = _value(document, key, description)
    if not isinstance(value, dict):
        raise EvidenceError(f"{description} field {key!r} is not an object")
    return value


def require_list(document: dict, key: str, description: str) -> list:
    value = _value(document, key, description)
    if not isinstance(value, list):
        raise EvidenceError(f"{description} field {key!r} is not an array")
    return value


def require_str_list(document: dict, key: str, description: str) -> list[str]:
    value = require_list(document, key, description)
    for element in value:
        if not isinstance(element, str):
            raise EvidenceError(f"{description} field {key!r} contains a non-string entry")
    return value


def parse_toolchain(entries: list[str]) -> dict[str, str]:
    """Read repeated ``NAME=VERSION`` declarations into one mapping.

    The planner and the runner both declare a toolchain, and reuse compares the
    two for equality, so they parse the declaration the same way here rather
    than twice.
    """
    toolchain: dict[str, str] = {}
    for entry in entries:
        name, separator, version = entry.partition("=")
        if not separator or not name:
            raise EvidenceError(f"--toolchain expects NAME=VERSION, not {entry!r}")
        toolchain[name] = version
    return toolchain


def parse_worker_declaration(entry: str) -> dict:
    """Read one ``NAME=CLASS[+CLASS...]:GROUP[,GROUP...]`` worker declaration.

    The planner is the only reader. Every other tool takes the assignment the
    plan recorded after validating it, so a second copy of this routing cannot
    disagree with the first unnoticed.
    """
    usage = f"--worker expects NAME=CLASS[+CLASS...]:GROUP[,GROUP...], not {entry!r}"
    name, separator, remainder = entry.partition("=")
    classes, colon, groups = remainder.partition(":")
    if not separator or not colon or not name or not classes or not groups:
        raise EvidenceError(usage)
    runner_classes = classes.split("+")
    identifiers = groups.split(",")
    if not all(runner_classes) or not all(identifiers):
        raise EvidenceError(usage)
    return {"name": name, "runner_classes": runner_classes, "groups": identifiers}


def normalized_workers(workers: list[dict], groups: list[dict]) -> list[dict]:
    """One canonical spelling of a worker assignment: workers by name, classes
    sorted, and each worker's groups in the plan's own group order."""
    order = {entry["id"]: index for index, entry in enumerate(groups)}
    return [
        {
            "name": worker["name"],
            "runner_classes": sorted(worker["runner_classes"]),
            "groups": sorted(worker["groups"], key=lambda identifier: (order.get(identifier, len(order)), identifier)),
        }
        for worker in sorted(workers, key=lambda worker: worker["name"])
    ]


def worker_assignment_problems(workers: list[dict], groups: list[dict]) -> list[str]:
    """Why these workers cannot route these groups, if they cannot.

    ``groups`` are catalog or plan entries carrying ``id`` and ``runner``, and a
    plan entry's ``selected``. Every problem is named at once: an invalid or
    repeated worker, an unknown runner class, an unknown group, a group owned by
    two workers, a group whose runner class its worker does not declare, and a
    selected group no compatible worker owns.
    """
    problems: list[str] = []
    by_id = {entry["id"]: entry for entry in groups}
    owners: dict[str, str] = {}
    names: set[str] = set()
    for worker in workers:
        name = worker["name"]
        if name in names:
            problems.append(f"worker {name!r} is declared more than once")
            continue
        names.add(name)
        if not WORKER_NAME_PATTERN.match(name):
            problems.append(f"worker name {name!r} is not lowercase letters, digits, and hyphens")
        classes = worker["runner_classes"]
        for runner in classes:
            if runner not in RUNNER_CLASSES:
                problems.append(
                    f"worker {name!r} declares unknown runner class {runner!r}; "
                    f"expected one of {list(RUNNER_CLASSES)}"
                )
        if len(set(classes)) != len(classes):
            problems.append(f"worker {name!r} declares a runner class more than once")
        if len(set(worker["groups"])) != len(worker["groups"]):
            problems.append(f"worker {name!r} is assigned a group more than once")
        for identifier in worker["groups"]:
            entry = by_id.get(identifier)
            if entry is None:
                problems.append(f"worker {name!r} is assigned unknown group {identifier!r}")
                continue
            if identifier in owners and owners[identifier] != name:
                problems.append(
                    f"group {identifier!r} is assigned to both {owners[identifier]!r} and {name!r}"
                )
                continue
            owners[identifier] = name
            if entry["runner"] not in classes:
                problems.append(
                    f"group {identifier!r} requires the {entry['runner']} runner class, but worker "
                    f"{name!r} declares only {'+'.join(classes)}"
                )
    for entry in groups:
        if entry.get("selected") and entry["id"] not in owners:
            problems.append(
                f"selected group {entry['id']!r} is assigned to no worker declaring its "
                f"{entry['runner']} runner class"
            )
    return problems


def require_workers(document: dict, groups: list[dict], description: str) -> list[dict]:
    """A plan's recorded worker assignment, held to the rules that produced it."""
    if "workers" not in document:
        raise EvidenceError(f"{description} is missing 'workers'")
    workers = document["workers"]
    if workers is None:
        raise EvidenceError(f"{description} {INSPECTION_ONLY}")
    if not isinstance(workers, list) or not workers:
        raise EvidenceError(f"{description} field 'workers' is not a non-empty array")
    for worker in workers:
        if not isinstance(worker, dict):
            raise EvidenceError(f"{description} field 'workers' contains a non-object entry")
        name = require_str(worker, "name", f"{description} worker")
        require_str_list(worker, "runner_classes", f"{description} worker {name}")
        require_str_list(worker, "groups", f"{description} worker {name}")
    problems = worker_assignment_problems(workers, groups)
    if problems:
        raise EvidenceError(f"{description} routes its groups inconsistently: " + "; ".join(problems))
    return workers


def assigned_worker(plan: dict, identifier: str) -> dict | None:
    """The worker a validated plan assigns one group to, if any."""
    for worker in plan["workers"]:
        if identifier in worker["groups"]:
            return worker
    return None


def plan_worker(plan: dict, name: str) -> dict | None:
    for worker in plan["workers"]:
        if worker["name"] == name:
            return worker
    return None


def execution_problems(plan: dict, identifier: str, name: str, declared: list[str]) -> list[str]:
    """Why this worker, declaring these runner classes, may not execute a group.

    The class a group requires is checked against what the executing worker
    declares, and that declaration against the classes the plan recorded for
    the same worker, so a CPU job can neither run display work nor claim a
    display it was not planned with.
    """
    entry = plan_group(plan, identifier)
    problems: list[str] = []
    if entry["runner"] not in declared:
        problems.append(
            f"{identifier!r} requires the {entry['runner']} runner class, which this execution "
            f"does not declare ({'+'.join(sorted(set(declared))) or 'none'})"
        )
    worker = plan_worker(plan, name)
    if worker is None:
        problems.append(f"the plan declares no worker {name!r}")
        return problems
    if sorted(set(declared)) != sorted(worker["runner_classes"]):
        problems.append(
            f"this execution declares runner class {'+'.join(sorted(set(declared))) or 'none'}, "
            f"but the plan declares worker {name!r} as {'+'.join(worker['runner_classes'])}"
        )
    if identifier not in worker["groups"]:
        owner = assigned_worker(plan, identifier)
        problems.append(
            f"the plan assigns {identifier!r} to "
            f"{repr(owner['name']) if owner else 'no worker'}, not {name!r}"
        )
    return problems


def declared_routing_problems(plan: dict, name: str, groups: list[str] | None) -> list[str]:
    """Why a tool's own worker argument disagrees with the plan's assignment.

    Reuse and the aggregate accept a worker's name, and optionally its groups,
    only as a restatement: a name the plan does not declare, or a group list
    that is not exactly the one it recorded, is a conflicting route and refused.
    """
    worker = plan_worker(plan, name)
    if worker is None:
        return [f"worker {name!r} is not one this plan declares"]
    if groups is None:
        return []
    if len(set(groups)) != len(groups) or sorted(groups) != sorted(worker["groups"]):
        return [
            f"worker {name!r} is given groups {','.join(groups)}, which conflicts with the "
            f"plan's validated assignment {','.join(worker['groups'])}"
        ]
    return []


def routing_problems(plan: dict, entry: dict, receipt: dict, description: str) -> list[str]:
    """Why a receipt was not produced by the route the plan assigns its group."""
    problems: list[str] = []
    if receipt.get("runner_class") != entry["runner"]:
        problems.append(
            f"{description} records runner class {receipt.get('runner_class')!r}, not the "
            f"{entry['runner']} class {entry['id']!r} requires"
        )
    owner = assigned_worker(plan, entry["id"])
    expected = owner["name"] if owner else None
    if receipt.get("worker") != expected:
        problems.append(
            f"{description} records worker {receipt.get('worker')!r}, not {expected!r}, "
            f"which the plan assigns {entry['id']!r} to"
        )
    return problems


def require_toolchain(document: dict, key: str, description: str) -> dict[str, str]:
    value = require_dict(document, key, description)
    for name, version in value.items():
        if not isinstance(version, str):
            raise EvidenceError(f"{description} records a non-string version for {name!r}")
    return value


# --------------------------------------------------------------------------
# Plans


def load_plan(path: str) -> dict:
    """Read a plan, rejecting any shape a verdict cannot safely be read from."""
    document = read_document(path, "plan")
    schema = require_int(document, "schema_version", "plan")
    if schema != PLAN_SCHEMA_VERSION:
        raise EvidenceError(
            f"plan {path} declares schema version {schema}, but this tool reads {PLAN_SCHEMA_VERSION}"
        )
    require_str(document, "policy_version", "plan")
    require_int(document, "catalog_policy_version", "plan")
    require_str(document, "input_identity", "plan")
    require_str(document, "runner_os", "plan")
    require_toolchain(document, "toolchain", "plan")
    for endpoint in ("base", "head", "candidate"):
        revision = require_dict(document, endpoint, "plan")
        require_str(revision, "commit", f"plan {endpoint}")
        require_str(revision, "tree", f"plan {endpoint}")
    catalog = require_dict(document, "catalog", "plan")
    require_str(catalog, "source", "plan catalog")
    # A plan resolved against a fixture catalog names it here, because the
    # runner has to read that same document to reproduce the classification the
    # plan was built from. ``None`` is the ordinary case: the candidate's own.
    if "override" not in catalog:
        raise EvidenceError("plan catalog is missing 'override'")
    if catalog["override"] is not None and not isinstance(catalog["override"], str):
        raise EvidenceError("plan catalog field 'override' is neither a string nor null")
    # Naming a mutable path binds nothing on its own, so the plan also records
    # what that catalog said. The runner refuses a catalog that no longer
    # digests to this.
    require_str(catalog, "candidate_digest", "plan catalog")
    request = require_dict(document, "request", "plan")
    require_str_list(request, "ids", "plan request")
    require_bool(request, "all_hspec", "plan request")
    require_str_list(request, "resolved", "plan request")
    groups = require_list(document, "groups", "plan")
    if not groups:
        # A plan that registers nothing selects nothing, so every worker skips
        # and every group is vacuously accounted for. That is a verdict about
        # no work at all, which must never read as a candidate having passed.
        raise EvidenceError("plan registers no groups")
    registered: set[str] = set()
    flagged: list[str] = []
    for entry in groups:
        if not isinstance(entry, dict):
            raise EvidenceError("plan field 'groups' contains a non-object entry")
        identifier = require_str(entry, "id", "plan group")
        if identifier in registered:
            raise EvidenceError(f"plan registers group {identifier!r} more than once")
        registered.add(identifier)
        description = f"plan group {identifier}"
        if require_bool(entry, "selected", description):
            flagged.append(identifier)
        require_str(entry, "reason", description)
        require_str(entry, "runner", description)
        require_str_list(entry, "command", description)
        timeout = require_int(entry, "timeout_seconds", description)
        if timeout <= 0:
            raise EvidenceError(f"{description} declares a non-positive timeout")
        preparation = _value(entry, "preparation", description)
        if preparation is not None:
            if not isinstance(preparation, dict):
                raise EvidenceError(f"{description} field 'preparation' is neither an object nor null")
            require_str_list(preparation, "command", f"{description} preparation")
            if require_int(preparation, "timeout_seconds", f"{description} preparation") <= 0:
                raise EvidenceError(f"{description} declares a non-positive preparation timeout")

    selected = require_str_list(document, "selected", "plan")
    unregistered = [identifier for identifier in selected if identifier not in registered]
    if unregistered:
        raise EvidenceError(
            "plan selects groups it does not register: " + ", ".join(sorted(unregistered))
        )
    if len(set(selected)) != len(selected):
        raise EvidenceError("plan names a group more than once in 'selected'")
    # The selected list and the per-group flags are two statements of the same
    # decision, and the workers read one while the aggregate reads the other. A
    # plan that disagrees with itself would let a group be dispatched and then
    # excused, or excused and then never noticed as missing.
    if selected != flagged:
        raise EvidenceError(
            "plan's 'selected' list does not match the groups it flags as selected: "
            f"{selected} against {flagged}"
        )
    require_workers(document, groups, "plan")
    return document


def plan_identity(plan: dict) -> str:
    """The fingerprint a receipt names so evidence cannot cross plans.

    It covers everything that decides what must run and how: the plan and
    policy revisions, the digest of the catalog that classified the candidate,
    the candidate's input identity and pinned toolchain, all three revisions,
    the normalized request, every group's selection, runner class, and exact
    execution definition, and the validated worker assignment. It deliberately omits the catalog and request *paths*, which are
    run-local filenames rather than contract, and the changed-path listing,
    which explains a selection without being able to alter it.

    The catalog digest is in it because the runner's own check against that
    digest is only self-consistent: a worker holding a rewritten catalog and a
    copy of the plan updated to match would satisfy itself and still produce a
    receipt the original plan accepted. Binding the digest here is what makes
    such a receipt name a different plan.
    """
    payload = {
        "plan_schema_version": plan["schema_version"],
        "policy_version": plan["policy_version"],
        "catalog_digest": plan["catalog"]["candidate_digest"],
        "catalog_policy_version": plan["catalog_policy_version"],
        "input_identity": plan["input_identity"],
        "toolchain": dict(plan["toolchain"]),
        "runner_os": plan["runner_os"],
        "base": {"commit": plan["base"]["commit"], "tree": plan["base"]["tree"]},
        "head": {"commit": plan["head"]["commit"], "tree": plan["head"]["tree"]},
        "candidate": {"commit": plan["candidate"]["commit"], "tree": plan["candidate"]["tree"]},
        "request": {
            "ids": sorted(plan["request"]["ids"]),
            "all_hspec": plan["request"]["all_hspec"],
            "resolved": sorted(plan["request"]["resolved"]),
        },
        "groups": [
            {
                "id": entry["id"],
                "selected": entry["selected"],
                "reason": entry["reason"],
                "runner": entry["runner"],
                "command": list(entry["command"]),
                "timeout_seconds": entry["timeout_seconds"],
                # What is built before the command is part of what the command
                # is: the same command after a different preparation runs a
                # different executable.
                "preparation": entry["preparation"],
            }
            for entry in plan["groups"]
        ],
        # Which worker may execute which group is part of what a receipt answers
        # for: the same selection routed differently is a different plan.
        "workers": normalized_workers(plan["workers"], plan["groups"]),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def preparation_command(document: dict) -> list[str] | None:
    """The preparation command a plan entry declares or a receipt records."""
    preparation = document.get("preparation")
    return None if preparation is None else list(preparation["command"])


def stage_problems(entry: dict, receipt: dict, description: str) -> list[str]:
    """How a receipt's execution definition differs from a plan entry's.

    The command and the preparation are compared together, because either one
    changing means the receipt describes a different execution.
    """
    problems: list[str] = []
    if receipt["command"] != list(entry["command"]):
        problems.append(f"{description} records a different command from the plan's")
    if preparation_command(receipt) != preparation_command(entry):
        problems.append(f"{description} records a different preparation from the plan's")
    return problems


def plan_group(plan: dict, identifier: str) -> dict:
    for entry in plan["groups"]:
        if entry["id"] == identifier:
            return entry
    raise EvidenceError(f"the plan registers no group {identifier!r}")


# --------------------------------------------------------------------------
# Receipts


def receipt_path(directory: str, identifier: str) -> str:
    return os.path.join(directory, identifier + ".json")


def validate_receipt(document: dict, description: str) -> dict:
    """Hold one receipt to the shape a verdict can rest on.

    A receipt read from a file and a receipt carried inside an applicability
    record are the same contract, so both come through here. A reused execution
    is held to exactly what a fresh one is held to; anything less would let a
    truncated document satisfy a group precisely because it was old.
    """
    schema = require_int(document, "schema_version", description)
    if schema != RECEIPT_SCHEMA_VERSION:
        raise EvidenceError(
            f"{description} declares schema version {schema}, "
            f"but this tool reads {RECEIPT_SCHEMA_VERSION}"
        )
    require_str(document, "group", description)
    require_str_list(document, "command", description)
    outcome = require_str(document, "outcome", description)
    if outcome not in OUTCOMES:
        raise EvidenceError(
            f"{description} records outcome {outcome!r}, which is not one of " + ", ".join(OUTCOMES)
        )
    require_int(document, "exit_status", description)
    require_str(document, "started_at", description)
    require_str(document, "ended_at", description)
    require_number(document, "duration_seconds", description)
    require_int(document, "timeout_seconds", description)
    require_str(document, "plan_identity", description)
    require_str(document, "head_commit", description)
    require_str(document, "executed_commit", description)
    require_str(document, "executed_tree", description)
    require_str(document, "runner_os", description)
    require_str(document, "runner_arch", description)
    require_str(document, "worker", description)
    require_str(document, "runner_class", description)
    require_str(document, "input_identity", description)
    require_str(document, "policy_version", description)
    require_str(document, "source_run_url", description)
    require_toolchain(document, "toolchain", description)
    executed = require_bool(document, "executed", description)
    if executed:
        validate_expiry(document, description)
    elif _value(document, "expiry", description) is not None:
        raise EvidenceError(f"{description} records a deadline's expiry for a command that never ran")
    preparation = _value(document, "preparation", description)
    if preparation is not None:
        if not isinstance(preparation, dict):
            raise EvidenceError(f"{description} field 'preparation' is neither an object nor null")
        validate_stage(preparation, f"{description} preparation")
    # The two stages have to tell one story. A group that did not execute was
    # stopped by a preparation that did not pass, and reports that
    # preparation's outcome as its own; a preparation that did not pass can
    # never be followed by an execution, let alone a passing one.
    if not executed:
        if preparation is None or preparation["outcome"] == "passed":
            raise EvidenceError(
                f"{description} records no execution, but no preparation stopped it"
            )
        if document["outcome"] != preparation["outcome"]:
            raise EvidenceError(
                f"{description} records outcome {document['outcome']!r} for a group its "
                f"preparation stopped with {preparation['outcome']!r}"
            )
    elif preparation is not None and preparation["outcome"] != "passed":
        raise EvidenceError(f"{description} records an execution after a preparation that did not pass")
    evidence = require_str_list(document, "evidence", description)
    for path in evidence:
        if os.path.isabs(path) or ".." in path.split("/"):
            raise EvidenceError(f"{description} names evidence outside its receipt directory: {path!r}")
    return document


def validate_stage(document: dict, description: str) -> None:
    """One stage of an execution: what ran, how it ended, and how long it took."""
    require_str_list(document, "command", description)
    outcome = require_str(document, "outcome", description)
    if outcome not in OUTCOMES:
        raise EvidenceError(
            f"{description} records outcome {outcome!r}, which is not one of " + ", ".join(OUTCOMES)
        )
    require_int(document, "exit_status", description)
    require_str(document, "started_at", description)
    require_str(document, "ended_at", description)
    require_number(document, "duration_seconds", description)
    require_int(document, "timeout_seconds", description)
    validate_expiry(document, description)


def validate_expiry(document: dict, description: str) -> None:
    """A deadline's expiry, kept apart from the cleanup that followed it.

    ``expiry`` is null for a stage that ended inside its budget. Otherwise it
    says when the deadline passed, how long the cleanup after it took, and
    whether anything had to be killed — and the stage's outcome is ``timeout``
    whatever the process reported once it was stopped, because an expired
    deadline certifies nothing about how the command would have ended.
    """
    expiry = _value(document, "expiry", description)
    outcome = document.get("outcome")
    if expiry is None:
        if outcome == "timeout":
            raise EvidenceError(f"{description} records a timeout without the deadline's expiry")
        return
    if not isinstance(expiry, dict):
        raise EvidenceError(f"{description} field 'expiry' is neither an object nor null")
    require_str(expiry, "expired_at", f"{description} expiry")
    require_number(expiry, "cleanup_seconds", f"{description} expiry")
    require_bool(expiry, "killed", f"{description} expiry")
    if outcome != "timeout":
        raise EvidenceError(f"{description} records an expired deadline with outcome {outcome!r}")


def load_receipt(path: str) -> dict:
    """Read a receipt, rejecting any shape that cannot support a verdict."""
    return validate_receipt(read_document(path, "receipt"), f"receipt {path}")


def write_receipt(directory: str, receipt: dict) -> str:
    """Write one receipt, replacing any earlier attempt's file atomically."""
    os.makedirs(directory, exist_ok=True)
    target = receipt_path(directory, receipt["group"])
    temporary = target + ".partial"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(receipt, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, target)
    return target


# --------------------------------------------------------------------------
# Applicability
#
# An applicability record is the proof that an earlier execution still applies
# to this candidate. It is deliberately not a receipt: the receipt it carries
# keeps its original timestamps, commit, tree, and run attribution, and the
# record beside it states why that older execution answers this candidate's
# question. Nothing here ever rewrites a receipt into a fresh one.


def candidate_identity(plan: dict) -> dict:
    """The compatibility fields a reusable execution has to match."""
    return {
        "input_identity": plan["input_identity"],
        "policy_version": plan["policy_version"],
        "toolchain": dict(plan["toolchain"]),
        "runner_os": plan["runner_os"],
    }


def compatibility_problems(candidate: dict, evidence: dict, description: str) -> list[str]:
    """Why an execution does not describe this candidate, if it does not."""
    problems: list[str] = []
    for name in COMPATIBILITY_FIELDS:
        if name not in evidence:
            problems.append(f"{description} declares no {name}")
        elif evidence[name] != candidate[name]:
            problems.append(f"{description} records a different {name}")
    return problems


def load_applicability(path: str) -> dict:
    """Read an applicability document, rejecting any shape a verdict cannot rest on."""
    document = read_document(path, "applicability")
    schema = require_int(document, "schema_version", "applicability")
    if schema != APPLICABILITY_SCHEMA_VERSION:
        raise EvidenceError(
            f"applicability {path} declares schema version {schema}, "
            f"but this tool reads {APPLICABILITY_SCHEMA_VERSION}"
        )
    require_str(document, "plan_identity", "applicability")
    require_str(document, "input_identity", "applicability")
    require_str(document, "policy_version", "applicability")
    require_str(document, "runner_os", "applicability")
    require_toolchain(document, "toolchain", f"applicability {path}")
    require_str_list(document, "obstacles", "applicability")
    reused = require_list(document, "reused", "applicability")
    seen: set[str] = set()
    for record in reused:
        if not isinstance(record, dict):
            raise EvidenceError(f"applicability {path} field 'reused' contains a non-object entry")
        identifier = require_str(record, "group", "applicability record")
        if identifier in seen:
            raise EvidenceError(f"applicability {path} records group {identifier!r} more than once")
        seen.add(identifier)
        where = f"applicability record {identifier}"
        source = require_str(record, "source_run_url", where)
        executed_commit = require_str(record, "executed_commit", where)
        executed_tree = require_str(record, "executed_tree", where)
        receipt = validate_receipt(require_dict(record, "receipt", where), f"{where}'s receipt")
        artifact = require_dict(record, "artifact", where)
        require_int(artifact, "id", f"{where}'s artifact")
        require_str(artifact, "created_at", f"{where}'s artifact")
        # The name is where the group and the identity are stored, so it is
        # also where a record can be made to describe evidence it did not come
        # from. It has to name this group under this candidate's inputs.
        expected = artifact_name(identifier, document["input_identity"])
        if require_str(artifact, "name", f"{where}'s artifact") != expected:
            raise EvidenceError(f"{where}'s artifact is not named {expected!r}")
        proof = require_dict(record, "proof", where)
        for name in COMPATIBILITY_FIELDS:
            if name not in proof:
                raise EvidenceError(f"{where}'s proof declares no {name}")
            if proof[name] != document[name]:
                raise EvidenceError(f"{where}'s proof disagrees with the candidate's {name}")
        # The record restates three of the receipt's own fields for legibility.
        # A restatement that disagrees with the receipt it sits beside is not a
        # summary of that execution, so it cannot describe one.
        for name, restated in (
            ("source_run_url", source),
            ("executed_commit", executed_commit),
            ("executed_tree", executed_tree),
        ):
            if receipt[name] != restated:
                raise EvidenceError(f"{where} restates a {name} its receipt does not record")
    rejected = require_list(document, "rejected", "applicability")
    for record in rejected:
        if not isinstance(record, dict):
            raise EvidenceError(f"applicability {path} field 'rejected' contains a non-object entry")
        identifier = require_str(record, "group", "applicability rejection")
        require_str(record, "reason", f"applicability rejection {identifier}")
        require_str(record, "source_run_url", f"applicability rejection {identifier}")
    return document


def applicability_problems(document: dict, plan: dict, identity: str) -> list[str]:
    """Why this applicability document does not describe this plan.

    A record resolved for another plan, another candidate, another policy, or
    another platform is stale rather than merely unrelated, and a stale record
    must never excuse a group from executing.
    """
    problems: list[str] = []
    if document["plan_identity"] != identity:
        problems.append(
            f"the applicability record was resolved for plan {document['plan_identity'][:12]}, "
            f"not {identity[:12]}"
        )
    problems += compatibility_problems(
        candidate_identity(plan), document, "the applicability record"
    )
    return problems
