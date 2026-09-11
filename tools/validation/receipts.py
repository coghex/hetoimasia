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

PLAN_SCHEMA_VERSION = 2
RECEIPT_SCHEMA_VERSION = 2
APPLICABILITY_SCHEMA_VERSION = 1

# The fields an earlier execution and the current candidate must agree on
# before that execution's result may stand in for one. They are deliberately
# the whole comparison: content, policy, toolchain, and platform.
COMPATIBILITY_FIELDS = ("input_identity", "policy_version", "toolchain", "runner_os")

# Outcomes a receipt may record. ``timeout`` is distinct from ``failed``
# because a group that exhausted its declared budget is a different obstacle
# from one that ran to completion and disagreed with the code.
OUTCOMES = ("passed", "failed", "timeout")

# Selection reasons that explain a group away without any execution. Every
# other reason names work the aggregate expects a receipt for.
OMITTED_REASONS = ("unaffected", "optional-unrequested")


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
        require_str_list(entry, "command", description)
        timeout = require_int(entry, "timeout_seconds", description)
        if timeout <= 0:
            raise EvidenceError(f"{description} declares a non-positive timeout")

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
    return document


def plan_identity(plan: dict) -> str:
    """The fingerprint a receipt names so evidence cannot cross plans.

    It covers everything that decides what must run and how: the plan and
    policy revisions, the candidate's input identity and pinned toolchain, all
    three revisions, the normalized request, and every group's selection and
    exact execution definition. It deliberately omits the catalog and request
    *paths*, which are run-local filenames rather than contract, and the
    changed-path listing, which explains a selection without being able to
    alter it.
    """
    payload = {
        "plan_schema_version": plan["schema_version"],
        "policy_version": plan["policy_version"],
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
                "command": list(entry["command"]),
                "timeout_seconds": entry["timeout_seconds"],
            }
            for entry in plan["groups"]
        ],
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def plan_group(plan: dict, identifier: str) -> dict:
    for entry in plan["groups"]:
        if entry["id"] == identifier:
            return entry
    raise EvidenceError(f"the plan registers no group {identifier!r}")


# --------------------------------------------------------------------------
# Receipts


def receipt_path(directory: str, identifier: str) -> str:
    return os.path.join(directory, identifier + ".json")


def load_receipt(path: str) -> dict:
    """Read a receipt, rejecting any shape that cannot support a verdict."""
    document = read_document(path, "receipt")
    schema = require_int(document, "schema_version", "receipt")
    if schema != RECEIPT_SCHEMA_VERSION:
        raise EvidenceError(
            f"receipt {path} declares schema version {schema}, but this tool reads {RECEIPT_SCHEMA_VERSION}"
        )
    require_str(document, "group", "receipt")
    require_str_list(document, "command", "receipt")
    outcome = require_str(document, "outcome", "receipt")
    if outcome not in OUTCOMES:
        raise EvidenceError(
            f"receipt {path} records outcome {outcome!r}, which is not one of " + ", ".join(OUTCOMES)
        )
    require_int(document, "exit_status", "receipt")
    require_str(document, "started_at", "receipt")
    require_str(document, "ended_at", "receipt")
    require_number(document, "duration_seconds", "receipt")
    require_int(document, "timeout_seconds", "receipt")
    require_str(document, "plan_identity", "receipt")
    require_str(document, "head_commit", "receipt")
    require_str(document, "executed_commit", "receipt")
    require_str(document, "executed_tree", "receipt")
    require_str(document, "runner_os", "receipt")
    require_str(document, "runner_arch", "receipt")
    require_str(document, "input_identity", "receipt")
    require_str(document, "policy_version", "receipt")
    require_str(document, "source_run_url", "receipt")
    require_toolchain(document, "toolchain", f"receipt {path}")
    return document


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
        require_str(record, "source_run_url", where)
        require_str(record, "executed_commit", where)
        require_str(record, "executed_tree", where)
        require_dict(record, "receipt", where)
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
