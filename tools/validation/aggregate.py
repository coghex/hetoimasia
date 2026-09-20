#!/usr/bin/env python3
"""Decide one honest verdict for a resolved plan and the receipts it produced.

The aggregate is the only thing that turns execution into a published status,
so it is deliberately suspicious of its own inputs. A selected group passes
only when a well-formed receipt says it passed, names this plan's identity and
head commit, records an execution *of this plan's candidate*, and agrees with
the candidate on every compatibility field a reused execution is already held
to. A group the plan explained away needs no receipt. Nothing else is a pass: a
missing receipt, a failed or timed-out one, a malformed one, one that belongs to
another plan, head, or candidate, and any worker that did not conclude
``success`` while its groups were selected all fail, because a selected gate
nothing vouched for has not been satisfied.

The candidate and compatibility questions are asked here as well as by the
runner deliberately. The runner refuses to execute from the wrong checkout, but
a verdict rests on the receipt in front of it rather than on the run that is
supposed to have produced it, so a document claiming an execution this plan did
not describe is refused on its own terms.

``--applicability`` adds the second way a selected group can be satisfied: an
earlier execution of byte-identical inputs, recorded by ``reuse.py``. A reused
group is reported as an earlier execution and links the run that produced it;
it never reads as a fresh pass, and a fresh receipt always outranks it.

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

# A one-shot tool must not write into the checkout it is validating. Importing a
# sibling module would leave a ``__pycache__`` beside it — a file the candidate
# does not carry, which the runner is right to refuse — so bytecode writing is
# turned off before the imports that would create it.
sys.dont_write_bytecode = True

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
    def __init__(self, name: str, result: str, groups: list[str] | None) -> None:
        self.name = name
        self.result = result
        self.groups = groups


def parse_worker(entry: str) -> Worker:
    """A worker's job result, optionally restating the groups it owns.

    Which groups a worker owns is the plan's validated assignment. A restated
    group list is accepted only when it is exactly that assignment, so no
    second, unchecked copy of the routing can account for another worker's work.
    """
    usage = f"--worker expects NAME=RESULT or NAME=RESULT:GROUP[,GROUP...], not {entry!r}"
    name, separator, remainder = entry.partition("=")
    if not separator or not name:
        raise EvidenceError(usage)
    result, colon, group_list = remainder.partition(":")
    if not result or (colon and not group_list):
        raise EvidenceError(usage)
    if not colon:
        return Worker(name, result, None)
    groups = group_list.split(",")
    if not all(groups):
        raise EvidenceError(usage)
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


def worker_problems(plan: dict, workers: list[Worker], covered: set[str]) -> list[str]:
    """A worker only has to account for the groups it was actually asked to run.

    The groups each worker owns come from the plan's validated assignment. A job
    skipped because every group it owns was satisfied by earlier evidence left
    nothing unvouched for, so it is not an obstacle. A job that was asked to
    execute something and did not conclude ``success`` still is, and so is one
    whose result nobody reported: another worker's success cannot stand in for
    it.
    """
    selected = set(plan["selected"]) - covered
    reported = {worker.name: worker for worker in workers}
    problems: list[str] = []
    for declared in plan["workers"]:
        owned = [identifier for identifier in declared["groups"] if identifier in selected]
        if not owned:
            continue
        worker = reported.get(declared["name"])
        if worker is None:
            problems.append(
                f"worker {declared['name']} reported no result while the plan selected "
                + ", ".join(owned)
            )
        elif worker.result != SATISFYING_RESULT:
            problems.append(
                f"worker {worker.name} was {worker.result} while the plan selected "
                + ", ".join(owned)
            )
    return problems


def reuse_finding(record: dict, entry: dict, plan: dict) -> Finding:
    """Judge one applicability record against the group it claims to satisfy.

    The record carries an older run's receipt, so this deliberately does not ask
    the questions a fresh receipt answers — the plan identity and the head
    commit belong to the run that executed, not to this one. What it does ask is
    whether that execution was of this candidate's inputs, under this policy,
    toolchain, and platform, and whether it actually passed.
    """
    identifier = entry["id"]
    reason = entry["reason"]
    receipt = record["receipt"]
    problems = receipts.compatibility_problems(
        receipts.candidate_identity(plan), receipt, "the reused receipt"
    )
    if receipt.get("group") != identifier:
        problems.append(f"the reused receipt records group {receipt.get('group')!r}")
    if receipt.get("command") != list(entry["command"]):
        problems.append("the reused receipt records a different command from the one the plan selected")
    problems += receipts.routing_problems(plan, entry, receipt, "the reused receipt")
    if receipt.get("outcome") != "passed" or receipt.get("exit_status") != 0:
        problems.append(f"the reused receipt records outcome {receipt.get('outcome')!r}")
    if problems:
        return Finding(identifier, reason, "unusable", "; ".join(problems), False)
    return Finding(
        identifier,
        reason,
        "reused",
        f"an earlier execution at {record['executed_commit'][:12]}, from {record['source_run_url']}",
        True,
    )


def inspect_group(
    entry: dict, plan: dict, identity: str, directory: str, applicable: dict[str, dict]
) -> Finding:
    identifier = entry["id"]
    reason = entry["reason"]
    if not entry["selected"]:
        if reason == receipts.PLATFORM_INAPPLICABLE:
            # The one omission that also refuses evidence. The other two
            # describe work this platform could have done and did not need to,
            # so a stray receipt beside them is merely superfluous. This one
            # describes a command whose components this platform does not
            # build, so nothing here could have executed it: a document
            # claiming otherwise is a contradiction, and accepting it silently
            # is exactly how an omission would be read back as coverage.
            if os.path.exists(receipts.receipt_path(directory, identifier)):
                return Finding(
                    identifier,
                    reason,
                    "invalid",
                    f"a receipt was collected for a group this plan's {plan['runner_os']} workers "
                    "do not build, so no execution in this run can have produced it",
                    False,
                )
            return Finding(
                identifier,
                reason,
                "omitted",
                f"not built on {plan['runner_os']}; nothing executed it and no receipt stands for it",
                True,
            )
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
        # A fresh receipt outranks an applicability record, so this is reached
        # only when nothing executed the group in this run at all. A fresh
        # failure is never overridden by an older pass.
        if identifier in applicable:
            return reuse_finding(applicable[identifier], entry, plan)
        return Finding(
            identifier,
            reason,
            "missing",
            "neither an execution nor an applicable earlier receipt vouched for a selected group",
            False,
        )
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
    # A fresh execution is of the candidate itself, so its provenance and its
    # compatibility fields are both the plan's. A reused execution is judged
    # differently, in `reuse_finding`, because it belongs to an earlier run.
    problems: list[str] = []
    candidate = plan["candidate"]
    if receipt["executed_commit"] != candidate["commit"]:
        problems.append(
            f"the receipt records an execution at {receipt['executed_commit'][:12]}, "
            f"not the plan's candidate {candidate['commit'][:12]}"
        )
    if receipt["executed_tree"] != candidate["tree"]:
        problems.append(
            f"the receipt records the tree {receipt['executed_tree'][:12]}, "
            f"not the candidate's {candidate['tree'][:12]}"
        )
    problems += receipts.compatibility_problems(
        receipts.candidate_identity(plan), receipt, "the receipt"
    )
    # A receipt from another route is not the evidence the plan asked for: a
    # display group's result has to come from the display worker assigned it.
    problems += receipts.routing_problems(plan, entry, receipt, "the receipt")
    if problems:
        return Finding(identifier, reason, "mismatched", "; ".join(problems), False)
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


def render_summary(
    findings: list[Finding],
    problems: list[str],
    plan: dict,
    identity: str,
    rejected: list[dict],
) -> str:
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
    reused = [finding for finding in findings if finding.outcome == "reused"]
    if reused:
        lines += ["", "### Reused evidence", ""]
        lines += [
            f"- `{finding.group}` was not executed by this run: it is {finding.detail}."
            for finding in reused
        ]
    if rejected:
        # A known failure for these very inputs stays visible beside the
        # execution it forced, rather than disappearing behind a green run.
        lines += ["", "### Refused evidence", ""]
        lines += [
            f"- `{record['group']}` executed instead of reusing "
            f"{record['source_run_url'] or 'an unattributed run'}: {record['reason']}"
            for record in rejected
        ]
    if problems:
        lines += ["", "### Obstacles", ""]
        lines += [f"- {problem}" for problem in problems]
    lines.append("")
    return "\n".join(lines)


def read_applicability(
    path: str | None, plan: dict, identity: str
) -> tuple[dict[str, dict], list[dict], list[str]]:
    """Read the applicability document, keeping only records this plan may use.

    A document resolved for another plan or another candidate is stale, and a
    stale record cannot satisfy anything: it is reported as an obstacle so the
    verdict fails rather than quietly excusing a group nothing ran. A record
    for a group this plan's platform does not build is reported the same way,
    for the same reason from the other direction: it is evidence from a machine
    this plan is not about.
    """
    if not path:
        return {}, [], []
    document = receipts.load_applicability(path)
    problems = receipts.applicability_problems(document, plan, identity)
    if problems:
        # A stale document's refusals describe another candidate's evidence, so
        # they are dropped rather than reported against this one.
        return {}, [], problems
    selected = set(plan["selected"])
    # A platform-inapplicable group is unselected, so its records would be
    # dropped by the filter below like any other unselected group's. They are
    # named instead: an earlier execution offered for a command this plan's
    # workers do not build describes another platform's machine, and silently
    # discarding it would leave the document looking like it vouched for
    # something. Nothing here can turn the omission into a pass either way.
    inapplicable = {
        entry["id"]
        for entry in plan["groups"]
        if entry["reason"] == receipts.PLATFORM_INAPPLICABLE
    }
    offered = [
        f"the applicability document offers an earlier execution of {record['group']}, which "
        f"this plan's {plan['runner_os']} workers do not build"
        for record in document["reused"]
        if record["group"] in inapplicable
    ]
    applicable: dict[str, dict] = {}
    for record in document["reused"]:
        if record["group"] in selected:
            applicable[record["group"]] = record
    return applicable, list(document["rejected"]), offered


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="aggregate.py",
        description="Decide the validation verdict for a plan and the receipts it produced.",
    )
    parser.add_argument("--plan", required=True, help="the resolved plan the verdict is about")
    parser.add_argument("--receipts", required=True, help="directory holding the collected receipts")
    parser.add_argument(
        "--applicability",
        help="the applicability document recording earlier executions that still apply",
    )
    parser.add_argument(
        "--worker",
        action="append",
        default=[],
        metavar="NAME=RESULT[:GROUP,...]",
        help="one of the plan's workers and its job result, optionally restating the groups the "
        "plan assigns it, which must agree exactly; repeatable",
    )
    parser.add_argument("--expect-head", help="the pull request's current head commit")
    parser.add_argument("--expect-base", help="the pull request's current merge base")
    parser.add_argument("--expect-request-file", help="a file holding the pull request's current body")
    parser.add_argument("--summary", help="a Markdown file the verdict table is appended to")
    arguments = parser.parse_args(argv)

    plan = receipts.load_plan(arguments.plan)
    identity = receipts.plan_identity(plan)
    workers = [parse_worker(entry) for entry in arguments.worker]
    conflicts: list[str] = []
    names: set[str] = set()
    for worker in workers:
        if worker.name in names:
            conflicts.append(f"worker {worker.name!r} is reported more than once")
        names.add(worker.name)
        conflicts += receipts.declared_routing_problems(plan, worker.name, worker.groups)
    if conflicts:
        raise EvidenceError("the worker arguments conflict with the plan: " + "; ".join(conflicts))

    applicable, rejected, problems = read_applicability(arguments.applicability, plan, identity)
    problems += freshness_problems(plan, arguments)
    problems += worker_problems(plan, workers, set(applicable))
    findings = [
        inspect_group(entry, plan, identity, arguments.receipts, applicable)
        for entry in plan["groups"]
    ]

    width = max((len(finding.group) for finding in findings), default=1)
    reason_width = max((len(finding.reason) for finding in findings), default=1)
    print(f"validation verdict for plan {identity[:12]} at head {plan['head']['commit'][:12]}")
    for finding in findings:
        print(
            f"  {finding.group.ljust(width)}  {finding.reason.ljust(reason_width)}  "
            f"{finding.outcome:<10} {finding.detail}"
        )
    for record in rejected:
        # A known failure for these very inputs stays in the log as well as in
        # the summary, beside the execution it forced.
        print(
            f"  refused:  {record['group']} executed instead of reusing "
            f"{record['source_run_url'] or 'an unattributed run'}: {record['reason']}"
        )
    for problem in problems:
        print(f"  obstacle: {problem}")

    if arguments.summary:
        try:
            with open(arguments.summary, "a", encoding="utf-8") as handle:
                handle.write(render_summary(findings, problems, plan, identity, rejected))
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
