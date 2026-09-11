#!/usr/bin/env python3
"""Decide which of this candidate's groups an earlier execution already proved.

A prose-only push produces a new commit, a new run, and a new plan, but not new
code. This step asks whether some finished run already executed a selected group
against byte-identical inputs, under the same policy, toolchain, and platform,
and records the answer in an applicability document the workers and the
aggregate both read.

It is deliberately fail-safe toward execution. An expired, missing, malformed,
failed, incompatible, or unreachable receipt is never a pass: it is an obstacle
this step reports and the group executes. Every lookup runs inside one budget,
so an unresponsive API leaves the plan job time to dispatch the work instead.

The only evidence store is GitHub Actions artifacts, read with the `actions:
read` permission the workflow already holds. Retention is therefore GitHub's
artifact default, and an artifact that has expired or been deleted simply
returns the candidate to execution.

Exit status: ``0`` once an applicability document has been written — including
one that reuses nothing — and ``2`` for a diagnostic that prevented writing one
at all.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import zipfile

import receipts
from receipts import EvidenceError

# The artifact name every worker uploads a receipt under. The identity is in
# the name so a lookup asks for evidence about *these* inputs rather than
# fetching every receipt a group ever produced and filtering afterwards.
ARTIFACT_PREFIX = "receipt"

# Run conclusions that describe a finished execution. A run still in progress
# has not finished the group, and a cancelled or timed-out one may have uploaded
# a receipt for work it never completed.
FINISHED_CONCLUSIONS = ("success", "failure")

# No single API call may consume the whole budget, or one hung request would
# spend the time the remaining groups need.
CALL_SECONDS = 30


def artifact_name(group: str, identity: str) -> str:
    return f"{ARTIFACT_PREFIX}-{group}-{identity}"


class Budget:
    """One deadline shared by every lookup this step performs."""

    def __init__(self, seconds: float) -> None:
        self.deadline = time.monotonic() + seconds

    def remaining(self) -> float:
        return self.deadline - time.monotonic()

    def exhausted(self) -> bool:
        return self.remaining() <= 0


class ApiError(Exception):
    """A lookup that did not answer. Never a rejection of evidence."""


class Api:
    """The GitHub REST surface this step reads, through the `gh` CLI."""

    def __init__(self, executable: str, budget: Budget) -> None:
        self.executable = executable
        self.budget = budget

    def _call(self, path: str) -> bytes:
        remaining = self.budget.remaining()
        if remaining <= 0:
            raise ApiError("the lookup budget was exhausted before " + path)
        try:
            process = subprocess.run(
                (self.executable, "api", path),
                capture_output=True,
                check=False,
                timeout=min(remaining, CALL_SECONDS),
            )
        except subprocess.TimeoutExpired:
            raise ApiError(f"{path} did not answer within the lookup budget") from None
        except OSError as error:
            raise ApiError(f"cannot run {self.executable}: {error}") from error
        if process.returncode != 0:
            detail = process.stderr.decode("utf-8", errors="replace").strip().splitlines()
            raise ApiError(f"{path} failed: " + (detail[-1] if detail else "no output"))
        return process.stdout

    def json(self, path: str) -> dict:
        raw = self._call(path)
        try:
            document = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ApiError(f"{path} did not answer with JSON: {error}") from error
        if not isinstance(document, dict):
            raise ApiError(f"{path} did not answer with a JSON object")
        return document

    def zip_member(self, path: str, member: str) -> bytes:
        raw = self._call(path)
        try:
            archive = zipfile.ZipFile(io.BytesIO(raw))
            names = archive.namelist()
            if names != [member]:
                raise ApiError(f"{path} holds {names!r} rather than exactly {member!r}")
            return archive.read(member)
        except (zipfile.BadZipFile, KeyError) as error:
            raise ApiError(f"{path} is not a readable artifact archive: {error}") from error


def newest_first(artifacts: list[dict]) -> list[dict]:
    """Order candidate artifacts newest first, deterministically.

    Two artifacts can share a creation timestamp — a rerun attempt, or two
    workers finishing together — so the identifier breaks the tie. Without a
    total order the same lookup could prefer different evidence on two runs.
    """
    return sorted(
        artifacts,
        key=lambda artifact: (str(artifact.get("created_at") or ""), int(artifact.get("id") or 0)),
        reverse=True,
    )


def usable_artifacts(document: dict, name: str) -> list[dict]:
    listing = document.get("artifacts")
    if not isinstance(listing, list):
        raise ApiError("the artifact listing has no 'artifacts' array")
    usable: list[dict] = []
    for artifact in listing:
        if not isinstance(artifact, dict) or artifact.get("name") != name:
            continue
        if artifact.get("expired") is True:
            continue
        if not isinstance(artifact.get("id"), int):
            continue
        usable.append(artifact)
    return newest_first(usable)


def run_url(run: dict, artifact: dict) -> str:
    url = run.get("html_url")
    if isinstance(url, str) and url:
        return url
    workflow_run = artifact.get("workflow_run")
    identifier = workflow_run.get("id") if isinstance(workflow_run, dict) else None
    return f"run {identifier}" if identifier else "an unattributed run"


class Rejection(Exception):
    """Evidence that was found and refused. It is reported, never hidden."""

    def __init__(self, reason: str, url: str = "") -> None:
        super().__init__(reason)
        self.reason = reason
        self.url = url


def source_run(api: Api, repository: str, artifact: dict, workflow: str) -> dict:
    """The completed run of this repository's validation workflow that produced it."""
    workflow_run = artifact.get("workflow_run")
    if not isinstance(workflow_run, dict) or not isinstance(workflow_run.get("id"), int):
        raise Rejection("the artifact names no source run")
    run = api.json(f"repos/{repository}/actions/runs/{workflow_run['id']}")
    url = run_url(run, artifact)
    home = run.get("repository")
    if not isinstance(home, dict) or home.get("full_name") != repository:
        raise Rejection("the artifact was produced outside this repository", url)
    if run.get("path") != workflow:
        raise Rejection(f"the artifact was produced by {run.get('path')!r}, not {workflow}", url)
    if run.get("status") != "completed":
        raise Rejection(f"its run is {run.get('status')!r} rather than completed", url)
    if run.get("conclusion") not in FINISHED_CONCLUSIONS:
        raise Rejection(f"its run concluded {run.get('conclusion')!r}", url)
    return run


def fetch_receipt(api: Api, repository: str, artifact: dict, group: str, url: str) -> dict:
    raw = api.zip_member(
        f"repos/{repository}/actions/artifacts/{artifact['id']}/zip", f"{group}.json"
    )
    # The downloaded receipt is read through the shared contract rather than
    # parsed here, so a reused receipt is held to exactly the shape a fresh one
    # is. It lands in a scratch directory that leaves nothing in the checkout
    # this candidate's own identity was fingerprinted from.
    with tempfile.TemporaryDirectory(prefix="validation-reuse-") as scratch:
        path = os.path.join(scratch, f"{group}.json")
        try:
            with open(path, "wb") as handle:
                handle.write(raw)
            return receipts.load_receipt(path)
        except OSError as error:
            raise Rejection(f"its receipt could not be read: {error}", url) from error
        except EvidenceError as failure:
            raise Rejection(f"its receipt is malformed: {failure}", url) from failure


def check_receipt(receipt: dict, group: str, entry: dict, candidate: dict, run: dict, url: str) -> None:
    if receipt["group"] != group:
        raise Rejection(f"its receipt records group {receipt['group']!r}", url)
    if receipt["command"] != list(entry["command"]):
        raise Rejection("its receipt records a different command from the plan's", url)
    identifier = run.get("id")
    if f"/actions/runs/{identifier}/" not in (receipt["source_run_url"] + "/"):
        raise Rejection("its receipt attributes itself to another run", url)
    problems = receipts.compatibility_problems(candidate, receipt, "its receipt")
    if problems:
        raise Rejection("; ".join(problems), url)
    # Outcome is checked last so an incompatible failure is reported as
    # incompatible rather than as a failure this candidate inherited.
    if receipt["outcome"] != "passed" or receipt["exit_status"] != 0:
        raise Rejection(
            f"its receipt records {receipt['outcome']} (exit {receipt['exit_status']})", url
        )


def consider(
    api: Api, repository: str, workflow: str, group: str, entry: dict, plan: dict, candidate: dict
) -> dict | None:
    """Decide one group: an applicability record, a raised rejection, or nothing.

    Only the newest artifact for this identity is ever considered. Reaching
    past a newer failure for an older pass would publish a green verdict while
    a known failure for the very same inputs sat unmentioned one artifact back.
    """
    name = artifact_name(group, plan["input_identity"])
    listing = api.json(
        f"repos/{repository}/actions/artifacts?name={urllib.parse.quote(name)}&per_page=100"
    )
    usable = usable_artifacts(listing, name)
    if not usable:
        return None
    artifact = usable[0]
    run = source_run(api, repository, artifact, workflow)
    url = run_url(run, artifact)
    receipt = fetch_receipt(api, repository, artifact, group, url)
    check_receipt(receipt, group, entry, candidate, run, url)
    return {
        "group": group,
        "receipt": receipt,
        "executed_commit": receipt["executed_commit"],
        "executed_tree": receipt["executed_tree"],
        "source_run_url": url,
        "artifact": {
            "id": artifact["id"],
            "name": name,
            "created_at": artifact.get("created_at") or "",
        },
        "proof": dict(candidate),
    }


def resolve(api: Api, repository: str, workflow: str, plan: dict) -> dict:
    candidate = receipts.candidate_identity(plan)
    document = {
        "schema_version": receipts.APPLICABILITY_SCHEMA_VERSION,
        "plan_identity": receipts.plan_identity(plan),
        **candidate,
        "candidate_commit": plan["candidate"]["commit"],
        "reused": [],
        "rejected": [],
        "obstacles": [],
    }
    for entry in plan["groups"]:
        if not entry["selected"]:
            continue
        group = entry["id"]
        if api.budget.exhausted():
            document["obstacles"].append(
                f"{group} was not looked up: the lookup budget was exhausted"
            )
            continue
        try:
            record = consider(api, repository, workflow, group, entry, plan, candidate)
        except Rejection as rejection:
            document["rejected"].append(
                {"group": group, "reason": rejection.reason, "source_run_url": rejection.url}
            )
        except ApiError as error:
            document["obstacles"].append(f"{group} could not be looked up: {error}")
        else:
            if record is not None:
                document["reused"].append(record)
    return document


def render_summary(document: dict, plan: dict) -> str:
    lines = [
        "## Reused evidence",
        "",
        f"Input identity `{plan['input_identity'][:12]}` under policy "
        f"`{plan['policy_version'][:12]}`.",
        "",
    ]
    if document["reused"]:
        lines += ["| Group | Executed at | Earlier run |", "| --- | --- | --- |"]
        for record in document["reused"]:
            lines.append(
                f"| `{record['group']}` | `{record['executed_commit'][:12]}` | "
                f"{record['source_run_url']} |"
            )
    else:
        lines.append("No earlier execution applied to this candidate.")
    if document["rejected"]:
        lines += ["", "### Refused evidence", ""]
        for record in document["rejected"]:
            lines.append(
                f"- `{record['group']}` must execute: {record['reason']} "
                f"({record['source_run_url'] or 'no run recorded'})"
            )
    if document["obstacles"]:
        lines += ["", "### Obstacles", ""]
        lines += [f"- {obstacle}" for obstacle in document["obstacles"]]
    lines.append("")
    return "\n".join(lines)


def parse_worker(entry: str) -> tuple[str, list[str]]:
    name, separator, group_list = entry.partition("=")
    groups = [identifier for identifier in group_list.split(",") if identifier]
    if not separator or not name or not groups:
        raise EvidenceError(f"--worker expects NAME=GROUP[,GROUP...], not {entry!r}")
    return name, groups


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="reuse.py",
        description="Record which selected groups an earlier execution already proved.",
    )
    parser.add_argument("--plan", required=True, help="the resolved plan this candidate was planned by")
    parser.add_argument("--repo", required=True, metavar="OWNER/NAME", help="the repository to read evidence from")
    parser.add_argument("--output", required=True, help="the applicability document to write")
    parser.add_argument(
        "--workflow",
        default=".github/workflows/validation.yml",
        help="the workflow whose runs may produce reusable evidence",
    )
    parser.add_argument(
        "--worker",
        action="append",
        default=[],
        metavar="NAME=GROUP[,GROUP...]",
        help="a worker job and the groups it owns, to decide whether it runs; repeatable",
    )
    parser.add_argument(
        "--budget-seconds",
        type=float,
        default=120.0,
        help="the whole lookup's budget; exhausting it returns the candidate to execution",
    )
    parser.add_argument("--gh", default="gh", help="the GitHub CLI executable to read through")
    parser.add_argument("--summary", help="a Markdown file the reuse table is appended to")
    parser.add_argument(
        "--offline",
        action="store_true",
        help="write an applicability document that reuses nothing, without any lookup",
    )
    arguments = parser.parse_args(argv)

    plan = receipts.load_plan(arguments.plan)
    workers = [parse_worker(entry) for entry in arguments.worker]
    if arguments.budget_seconds <= 0:
        raise EvidenceError("--budget-seconds must be positive")

    if arguments.offline:
        document = {
            "schema_version": receipts.APPLICABILITY_SCHEMA_VERSION,
            "plan_identity": receipts.plan_identity(plan),
            **receipts.candidate_identity(plan),
            "candidate_commit": plan["candidate"]["commit"],
            "reused": [],
            "rejected": [],
            "obstacles": ["no evidence was looked up: this step ran offline"],
        }
    else:
        api = Api(arguments.gh, Budget(arguments.budget_seconds))
        document = resolve(api, arguments.repo, arguments.workflow, plan)

    try:
        with open(arguments.output, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except OSError as error:
        raise EvidenceError(f"cannot write the applicability document: {error}") from error

    covered = {record["group"] for record in document["reused"]}
    execute = [entry["id"] for entry in plan["groups"] if entry["selected"] and entry["id"] not in covered]
    print("execute=" + " ".join(execute))
    print("reused=" + " ".join(sorted(covered)))
    print("input_identity=" + plan["input_identity"])
    for name, groups in workers:
        owned = [identifier for identifier in groups if identifier in execute]
        print(f"run-{name}=" + ("true" if owned else "false"))

    if arguments.summary:
        try:
            with open(arguments.summary, "a", encoding="utf-8") as handle:
                handle.write(render_summary(document, plan))
        except OSError as error:
            raise EvidenceError(f"cannot write the summary: {error}") from error

    for record in document["reused"]:
        print(
            f"reuse: {record['group']} was executed at {record['executed_commit'][:12]} "
            f"by {record['source_run_url']}",
            file=sys.stderr,
        )
    for record in document["rejected"]:
        print(f"reuse: {record['group']} must execute: {record['reason']}", file=sys.stderr)
    for obstacle in document["obstacles"]:
        print(f"reuse: {obstacle}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except EvidenceError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
