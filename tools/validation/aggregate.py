#!/usr/bin/env python3
"""Decide one honest verdict for a resolved plan and the receipts it produced.

The aggregate is the only thing that turns execution into a published status,
so it is deliberately suspicious of its own inputs. A selected group passes
only when a well-formed receipt says it passed, names this plan's identity, and
names this plan's head commit. A group the plan explained away needs no
receipt. Nothing else is a pass: a missing receipt, a failed or timed-out one,
a malformed one, one that belongs to another plan or head, and any worker that
did not conclude ``success`` while its groups were selected all fail, because a
selected gate nothing vouched for has not been satisfied.

``--expect-head``, ``--expect-base``, and ``--expect-request-file`` add the
freshness question a published verdict depends on: does this plan still
describe the pull request as it stands now? An older run, or a rerun of an
older request on the same commit, answers no and cannot satisfy the newer one.

Exit status: ``0`` when every selected group is satisfied, ``1`` when the
verdict is a failure, and ``2`` for a diagnostic that prevented a verdict.
"""

from __future__ import annotations

import argparse
import os
import sys

import receipts
from plan import PlannerError, parse_request
from receipts import EvidenceError

# The only worker result that accounts for the groups a worker owns. Every
# other result — ``failure``, ``cancelled``, ``skipped`` — leaves selected work
# unvouched for, and receipts in a sibling artifact cannot stand in for it: a
# job can fail after its groups passed, or fail before it wrote a receipt at
# all, so passing evidence elsewhere says nothing about what this job did.
SATISFYING_RESULT = "success"


class Worker:
    def __init__(self, name: str, result: str, groups: list[str]) -> None:
        self.name = name
        self.result = result
        self.groups = groups


def parse_worker(entry: str) -> Worker:
    name, separator, remainder = entry.partition("=")
    if not separator or not name:
        raise EvidenceError(f"--worker expects NAME=RESULT:GROUP[,GROUP...], not {entry!r}")
    result, separator, group_list = remainder.partition(":")
    if not separator or not result:
        raise EvidenceError(f"--worker expects NAME=RESULT:GROUP[,GROUP...], not {entry!r}")
    groups = [identifier for identifier in group_list.split(",") if identifier]
    if not groups:
        raise EvidenceError(f"--worker {name!r} declares no groups")
    return Worker(name, result, groups)


class Finding:
    """One line of the verdict: what a group is, and whether it is satisfied."""

    def __init__(self, group: str, reason: str, outcome: str, detail: str, satisfied: bool) -> None:
        self.group = group
        self.reason = reason
        self.outcome = outcome
        self.detail = detail
        self.satisfied = satisfied


def freshness_problems(plan: dict, arguments: argparse.Namespace) -> list[str]:
    """Why this plan no longer describes the pull request, if it no longer does.

    A verdict is published against the pull request's current state, not the
    state its own run started from, so the endpoints and the request block are
    compared again here. Matching receipts to their own plan proves only that
    one run was internally consistent; it cannot notice that the request was
    edited or the head advanced while that run was still executing.
    """
    problems: list[str] = []
    if arguments.expect_head and plan["head"]["commit"] != arguments.expect_head:
        problems.append(
            f"the plan was resolved for head {plan['head']['commit']}, "
            f"but the pull request's head is now {arguments.expect_head}"
        )
    if arguments.expect_base and plan["base"]["commit"] != arguments.expect_base:
        problems.append(
            f"the plan was resolved against base {plan['base']['commit']}, "
            f"but the pull request's merge base is now {arguments.expect_base}"
        )
    if arguments.expect_request_file:
        try:
            with open(arguments.expect_request_file, "rb") as handle:
                raw = handle.read()
        except OSError as error:
            raise EvidenceError(
                f"cannot read the current request body {arguments.expect_request_file}: {error}"
            ) from error
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise EvidenceError(
                f"the current request body {arguments.expect_request_file} is not valid UTF-8: {error}"
            ) from error
        try:
            identifiers, all_hspec = parse_request(text, arguments.expect_request_file)
        except PlannerError as failure:
            problems.append(f"the pull request's current validation request is invalid: {failure}")
        else:
            if sorted(identifiers) != sorted(plan["request"]["ids"]) or all_hspec != plan["request"]["all_hspec"]:
                problems.append(
                    "the plan was resolved for validation request "
                    f"{describe_request(plan['request']['ids'], plan['request']['all_hspec'])}, "
                    "but the pull request now asks for "
                    f"{describe_request(sorted(identifiers), all_hspec)}"
                )
    return problems


def describe_request(identifiers: list[str], all_hspec: bool) -> str:
    parts = list(identifiers)
    if all_hspec:
        parts.append("all-hspec")
    return ", ".join(parts) if parts else "nothing"


def worker_problems(plan: dict, workers: list[Worker]) -> list[str]:
    selected = set(plan["selected"])
    problems: list[str] = []
    for worker in workers:
        owned = [identifier for identifier in worker.groups if identifier in selected]
        if not owned:
            continue
        if worker.result != SATISFYING_RESULT:
            problems.append(
                f"worker {worker.name} was {worker.result} while the plan selected "
                + ", ".join(owned)
            )
    return problems


def inspect_group(entry: dict, plan: dict, identity: str, directory: str) -> Finding:
    identifier = entry["id"]
    reason = entry["reason"]
    if not entry["selected"]:
        if reason in receipts.OMITTED_REASONS:
            return Finding(identifier, reason, "omitted", "explained without execution", True)
        return Finding(
            identifier,
            reason,
            "invalid",
            f"unselected with reason {reason!r}, which does not explain an omission",
            False,
        )
    path = receipts.receipt_path(directory, identifier)
    if not os.path.exists(path):
        return Finding(identifier, reason, "missing", "no receipt was produced for a selected group", False)
    try:
        receipt = receipts.load_receipt(path)
    except EvidenceError as failure:
        return Finding(identifier, reason, "malformed", str(failure), False)
    if receipt["group"] != identifier:
        return Finding(
            identifier, reason, "mismatched", f"the receipt records group {receipt['group']!r}", False
        )
    if receipt["plan_identity"] != identity:
        return Finding(
            identifier,
            reason,
            "mismatched",
            f"the receipt names plan {receipt['plan_identity'][:12]}, not {identity[:12]}",
            False,
        )
    if receipt["head_commit"] != plan["head"]["commit"]:
        return Finding(
            identifier,
            reason,
            "mismatched",
            f"the receipt names head {receipt['head_commit'][:12]}, not {plan['head']['commit'][:12]}",
            False,
        )
    if receipt["command"] != list(entry["command"]):
        return Finding(
            identifier,
            reason,
            "mismatched",
            "the receipt records a different command from the one the plan selected",
            False,
        )
    if receipt["outcome"] == "timeout":
        return Finding(
            identifier,
            reason,
            "timeout",
            f"exhausted its {receipt['timeout_seconds']}s budget",
            False,
        )
    if receipt["outcome"] != "passed" or receipt["exit_status"] != 0:
        return Finding(
            identifier, reason, "failed", f"exited {receipt['exit_status']}", False
        )
    return Finding(
        identifier,
        reason,
        "passed",
        f"executed at {receipt['executed_commit'][:12]} in {receipt['duration_seconds']:.1f}s",
        True,
    )


def render_summary(findings: list[Finding], problems: list[str], plan: dict, identity: str) -> str:
    lines = [
        "## Validation verdict",
        "",
        f"Plan `{identity[:12]}` for head `{plan['head']['commit'][:12]}` "
        f"against base `{plan['base']['commit'][:12]}`.",
        "",
        "| Group | Reason | Outcome | Detail |",
        "| --- | --- | --- | --- |",
    ]
    for finding in findings:
        lines.append(
            f"| `{finding.group}` | {finding.reason} | {finding.outcome} | {finding.detail} |"
        )
    if problems:
        lines += ["", "### Obstacles", ""]
        lines += [f"- {problem}" for problem in problems]
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="aggregate.py",
        description="Decide the validation verdict for a plan and the receipts it produced.",
    )
    parser.add_argument("--plan", required=True, help="the resolved plan the verdict is about")
    parser.add_argument("--receipts", required=True, help="directory holding the collected receipts")
    parser.add_argument(
        "--worker",
        action="append",
        default=[],
        metavar="NAME=RESULT:GROUP[,GROUP...]",
        help="a worker job, its result, and the groups it owns; repeatable",
    )
    parser.add_argument("--expect-head", help="the pull request's current head commit")
    parser.add_argument("--expect-base", help="the pull request's current merge base")
    parser.add_argument("--expect-request-file", help="a file holding the pull request's current body")
    parser.add_argument("--summary", help="a Markdown file the verdict table is appended to")
    arguments = parser.parse_args(argv)

    plan = receipts.load_plan(arguments.plan)
    identity = receipts.plan_identity(plan)
    workers = [parse_worker(entry) for entry in arguments.worker]

    problems = freshness_problems(plan, arguments)
    problems += worker_problems(plan, workers)
    findings = [
        inspect_group(entry, plan, identity, arguments.receipts) for entry in plan["groups"]
    ]

    width = max((len(finding.group) for finding in findings), default=1)
    reason_width = max((len(finding.reason) for finding in findings), default=1)
    print(f"validation verdict for plan {identity[:12]} at head {plan['head']['commit'][:12]}")
    for finding in findings:
        print(
            f"  {finding.group.ljust(width)}  {finding.reason.ljust(reason_width)}  "
            f"{finding.outcome:<10} {finding.detail}"
        )
    for problem in problems:
        print(f"  obstacle: {problem}")

    if arguments.summary:
        try:
            with open(arguments.summary, "a", encoding="utf-8") as handle:
                handle.write(render_summary(findings, problems, plan, identity))
        except OSError as error:
            raise EvidenceError(f"cannot write the summary {arguments.summary}: {error}") from error

    unsatisfied = [finding for finding in findings if not finding.satisfied]
    if unsatisfied or problems:
        print(
            "verdict: failed — "
            + ", ".join(
                [f"{finding.group} {finding.outcome}" for finding in unsatisfied] + problems
            )
        )
        return 1
    print("verdict: passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except EvidenceError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
