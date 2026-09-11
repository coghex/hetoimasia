#!/usr/bin/env python3
"""Execute one planned validation group and write its receipt.

The resolved plan is the runner's only authority. A group's command, its
timeout, and the plan identity a receipt must name all come from the plan file
supplied with ``--plan``, so a runner never has to infer a request-dependent
selection from a group ID and a checkout. That is also what lets the workflow
tests drive real executions against a fixture catalog: plan with
``plan.py --catalog <fixture>``, then run against that same plan.

The receipt is the result contract later slices consume. It records what ran,
where it ran, and how it ended — including a timeout as an outcome distinct
from a failure, because an exhausted budget and a disagreeing test are
different obstacles.

Exit status: ``0`` when the group passed, ``1`` when it failed or timed out
(its receipt is still written), and ``2`` for a diagnostic that prevented any
execution at all.
"""

from __future__ import annotations

import argparse
import os
import platform
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

import receipts
from receipts import EvidenceError

# How long a timed-out process group is given to exit on SIGTERM before it is
# killed outright.
TERMINATION_GRACE_SECONDS = 10


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def git_output(root: str, *arguments: str) -> str:
    process = subprocess.run(
        ("git", "-C", root) + arguments, capture_output=True, check=False
    )
    if process.returncode != 0:
        stderr = process.stderr.decode("utf-8", errors="replace").strip()
        raise EvidenceError("git " + " ".join(arguments) + " failed: " + (stderr or "no output"))
    return process.stdout.decode("utf-8", errors="replace").strip()


def source_run_url() -> str:
    """Where this execution can be read back from, when a run produced it.

    An execution that no later run can attribute is not reusable evidence, so
    the attribution is recorded from the environment the run publishes rather
    than reconstructed from an artifact's metadata afterwards.
    """
    server = os.environ.get("GITHUB_SERVER_URL")
    repository = os.environ.get("GITHUB_REPOSITORY")
    run_id = os.environ.get("GITHUB_RUN_ID")
    if not (server and repository and run_id):
        return ""
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT") or "1"
    return f"{server}/{repository}/actions/runs/{run_id}/attempts/{attempt}"


def group_alive(group: int | None) -> bool:
    """Whether any process still belongs to the command's process group."""
    if group is None:
        return False
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except OSError:
        # The group exists but this process may not signal it. Alive is the
        # conservative answer: a survivor must not be reported as reaped.
        return True
    return True


def signal_group(process: subprocess.Popen, group: int | None, number: int) -> None:
    try:
        if group is None:
            process.send_signal(number)
        else:
            os.killpg(group, number)
    except (OSError, ValueError):
        pass


def reaped(process: subprocess.Popen, seconds: int) -> bool:
    try:
        process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        return False
    return True


def terminate_group(process: subprocess.Popen) -> None:
    """End the command and every descendant it started.

    The launched process exiting is not the same as the group ending. A
    descendant that ignores SIGTERM keeps running under the same group
    identifier long after the shell that started it has gone, so liveness is
    probed on the *group* rather than inferred from the process this runner
    happens to hold a handle to. Anything still there after the grace period is
    killed outright: the budget has already expired, and a survivor would keep
    holding the runner's CPU and scratch space.
    """
    try:
        group = os.getpgid(process.pid)
    except OSError:
        group = None
    signal_group(process, group, signal.SIGTERM)
    leader_exited = reaped(process, TERMINATION_GRACE_SECONDS)
    if not leader_exited or group_alive(group):
        signal_group(process, group, signal.SIGKILL)
    if not reaped(process, TERMINATION_GRACE_SECONDS):
        process.kill()
        process.wait()


def execute(command: list[str], root: str, timeout_seconds: int) -> tuple[int, bool, float, str, str]:
    started_at = timestamp()
    started = time.monotonic()
    # A new session gives the command its own process group, so a timeout can
    # reap the descendants it spawned rather than only the process it launched.
    process = subprocess.Popen(command, cwd=root, start_new_session=True)
    timed_out = False
    try:
        process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_group(process)
    duration = time.monotonic() - started
    return process.returncode, timed_out, duration, started_at, timestamp()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="run.py",
        description="Execute one group of a resolved validation plan and write its receipt.",
    )
    parser.add_argument("group", help="the catalog group to execute")
    parser.add_argument("--plan", required=True, help="the resolved plan this execution belongs to")
    parser.add_argument("--receipts", required=True, help="directory the receipt is written to")
    parser.add_argument("--repo-root", help="the checkout to execute in (default: the working directory)")
    parser.add_argument("--executed-commit", help="override the executed commit recorded in the receipt")
    parser.add_argument("--executed-tree", help="override the executed tree recorded in the receipt")
    parser.add_argument(
        "--toolchain",
        action="append",
        default=[],
        metavar="NAME=VERSION",
        help="a toolchain version to record; repeatable",
    )
    parser.add_argument(
        "--source-run-url",
        help="where this execution can be read back from (default: this run, from the environment)",
    )
    arguments = parser.parse_args(argv)

    root = os.path.abspath(arguments.repo_root or os.getcwd())
    plan = receipts.load_plan(arguments.plan)
    identity = receipts.plan_identity(plan)
    group = receipts.plan_group(plan, arguments.group)
    if not group["selected"]:
        raise EvidenceError(
            f"the plan did not select {arguments.group!r} ({group['reason']}); "
            "an omitted group has no execution to record"
        )

    # The declared toolchain is exactly what reuse compares against the
    # candidate's pinned versions, so the interpreter this runner happens to
    # be is recorded beside it rather than inside it.
    toolchain = receipts.parse_toolchain(arguments.toolchain)

    executed_commit = arguments.executed_commit or git_output(root, "rev-parse", "HEAD")
    executed_tree = arguments.executed_tree or git_output(root, "rev-parse", "HEAD^{tree}")

    command = list(group["command"])
    timeout_seconds = group["timeout_seconds"]
    print(
        f"validation: running {arguments.group} ({group['reason']}) "
        f"under a {timeout_seconds}s budget: " + " ".join(command),
        flush=True,
    )
    try:
        status, timed_out, duration, started_at, ended_at = execute(command, root, timeout_seconds)
    except OSError as error:
        raise EvidenceError(f"cannot execute {arguments.group}: {error}") from error

    if timed_out:
        outcome = "timeout"
    elif status == 0:
        outcome = "passed"
    else:
        outcome = "failed"

    receipt = {
        "schema_version": receipts.RECEIPT_SCHEMA_VERSION,
        "group": arguments.group,
        "command": command,
        "outcome": outcome,
        "exit_status": status,
        "started_at": started_at,
        "ended_at": ended_at,
        "duration_seconds": round(duration, 3),
        "timeout_seconds": timeout_seconds,
        "plan_identity": identity,
        "head_commit": plan["head"]["commit"],
        "executed_commit": executed_commit,
        "executed_tree": executed_tree,
        "runner_os": os.environ.get("RUNNER_OS") or platform.system(),
        "runner_arch": os.environ.get("RUNNER_ARCH") or platform.machine(),
        "runner_python": platform.python_version(),
        "toolchain": toolchain,
        # Copied from the plan rather than recomputed: the receipt has to name
        # the identity the candidate was planned under, and a runner that
        # derived its own could disagree with the plan it is executing.
        "input_identity": plan["input_identity"],
        "policy_version": plan["policy_version"],
        "source_run_url": arguments.source_run_url or source_run_url(),
    }
    written = receipts.write_receipt(arguments.receipts, receipt)
    print(
        f"validation: {arguments.group} {outcome} after {duration:.1f}s "
        f"(exit {status}); receipt {written}",
        flush=True,
    )
    return 0 if outcome == "passed" else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except EvidenceError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
