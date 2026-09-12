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

Before anything executes, the checkout is held to being the plan's *candidate*:
the commit, the tree, and the absence of uncommitted changes to anything that
candidate's own classification counts as an input. A receipt names the plan's
identity and copies the candidate's input identity, so an execution from any
other tree would hand this run's result to a revision it never read. That is a
refusal rather than a recorded mismatch, because a run that cannot describe the
candidate has no evidence to offer about it.

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

# A one-shot tool must not write into the checkout it is validating. Importing a
# sibling module would leave a ``__pycache__`` beside it — a file the candidate
# does not carry, which the runner is right to refuse — so bytecode writing is
# turned off before the imports that would create it.
sys.dont_write_bytecode = True

import plan as planner
import receipts
from plan import PlannerError
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


def git_records(root: str, *arguments: str) -> list[str]:
    """Run a NUL-separated Git query, keeping every byte of every field.

    ``git_output`` strips its result, which is right for a revision but wrong
    for a path listing: a path may legitimately begin or end with a space, and
    a stripped field would name a file that does not exist.
    """
    process = subprocess.run(
        ("git", "-C", root) + arguments, capture_output=True, check=False
    )
    if process.returncode != 0:
        stderr = process.stderr.decode("utf-8", errors="replace").strip()
        raise EvidenceError("git " + " ".join(arguments) + " failed: " + (stderr or "no output"))
    output = process.stdout.decode("utf-8", errors="replace")
    return [field for field in output.split("\0") if field]


def tracked_changes(root: str) -> set[str]:
    """Every tracked path this checkout holds differently from its HEAD commit.

    Staged and unstaged edits are asked about separately, because neither
    implies the other: a working-tree diff misses a mode change that lives only
    in the index, and an index diff misses an edit that was never added. Both
    report deletions and both endpoints of a rename.
    """
    paths: set[str] = set()
    for staged in (("--cached",), ()):
        fields = git_records(root, "diff", "--name-status", "-z", *staged, "HEAD")
        index = 0
        while index < len(fields):
            status = fields[index]
            index += 1
            # A rename or a copy names both endpoints, and both of them differ
            # from the candidate: the source is gone and the target is new.
            needed = 2 if status[0] in ("R", "C") else 1
            if index + needed > len(fields):
                raise EvidenceError(
                    f"git diff --name-status reported status {status!r} with no path"
                )
            paths.update(fields[index : index + needed])
            index += needed
    return paths


def untracked_files(root: str) -> set[str]:
    """Every file in this checkout that no commit of it carries.

    Deliberately without ``--exclude-standard`` or any other exclude source. A
    `.gitignore`, a `.git/info/exclude`, or a machine's global excludes could
    otherwise hide a newly added source, consumed document, or package
    description from this question entirely, and two of those three are not even
    part of the candidate. Whether such a file matters is then decided by the
    candidate's own classification, below, rather than by what some ignore rule
    was willing to mention.
    """
    return set(git_records(root, "ls-files", "--others", "-z"))


def reaches_an_execution(path: str, consumed: set[str]) -> bool:
    """Whether an added file could reach an execution of this candidate.

    A file the candidate's tree does not carry matters when some registered
    group would read it: it falls under a declared input, a component's own
    sources, or one of the mandatory policy roots. Packaging is always in, on
    the same grounds the identity refuses to treat it as prose — it decides what
    is compiled however a catalog classifies it. Everything else — a build
    tree, a capture, a local configuration file, a run's own plan and receipts —
    is output or scratch that no command the plan selected reads as input.
    """
    if path in planner.NEVER_HARMLESS_PATHS or path.endswith(planner.NEVER_HARMLESS_SUFFIXES):
        return True
    return any(planner.matches_input(path, entry) for entry in consumed)


def relevant_uncommitted(root: str, plan: dict) -> list[str]:
    """Every uncommitted path that keeps this checkout from being the candidate.

    Relevance is read from the classification that produced the plan — the
    candidate's package graph, and the catalog that plan was resolved with,
    which is the fixture when one was supplied and the candidate's own otherwise
    — rather than from whatever the working tree holds now. An edit must not be
    able to reclassify itself as prose on the way past, and a rewritten catalog
    in the working tree is exactly the change this refusal exists to notice.

    A tracked path is relevant unless it is harmless prose, which is the same
    complement the candidate's `input_identity` already covers: consumed
    Markdown and a mandatory policy input are never harmless however they are
    spelled. An added path is relevant when it could reach an execution, which
    is the narrower question its absence from every tree makes the right one.
    """
    tracked = tracked_changes(root)
    untracked = untracked_files(root)
    if not tracked and not untracked:
        return []
    catalog, packages = candidate_classification(root, plan)
    consumed = planner.consumed_entries(catalog, packages)
    relevant = {path for path in tracked if not planner.harmless_prose(path, consumed, catalog)}
    relevant |= {path for path in untracked if reaches_an_execution(path, consumed)}
    return sorted(relevant)


def candidate_classification(root: str, plan: dict) -> tuple[dict, dict]:
    """The catalog and package graph the plan's own identity was taken from."""
    override = plan["catalog"]["override"]
    try:
        candidate = planner.GitTree(root, plan["candidate"]["commit"])
        catalog, _ = planner.read_catalog(candidate, override, root)
        packages = planner.load_packages(candidate, required=True)
    except PlannerError as failure:
        raise EvidenceError(
            "cannot classify this checkout's uncommitted changes against the "
            f"candidate: {failure}"
        ) from failure
    return catalog, packages


def confirm_candidate(root: str, plan: dict) -> tuple[str, str]:
    """Refuse to execute unless this checkout is the plan's candidate.

    The commit is compared as well as the tree because two commits can share a
    tree, and a receipt naming the wrong one would misdescribe what was
    validated even where the bytes agreed. The candidate is the comparison, not
    the head: a pull request is validated on an integration revision that is
    neither endpoint, and a plan resolved for one still executes from a checkout
    of it.
    """
    candidate = plan["candidate"]
    executed_commit = git_output(root, "rev-parse", "HEAD")
    executed_tree = git_output(root, "rev-parse", "HEAD^{tree}")
    if executed_commit != candidate["commit"]:
        raise EvidenceError(
            f"this checkout is at {executed_commit}, which is not the plan's candidate "
            f"{candidate['commit']}; an execution here would be recorded against a "
            "revision it never read"
        )
    if executed_tree != candidate["tree"]:
        raise EvidenceError(
            f"this checkout's tree is {executed_tree}, which is not the candidate "
            f"{candidate['commit']}'s tree {candidate['tree']}"
        )
    relevant = relevant_uncommitted(root, plan)
    if relevant:
        raise EvidenceError(
            "this checkout carries uncommitted changes to inputs the candidate "
            f"{candidate['commit']} classifies as relevant, so an execution here would "
            "not be of that candidate: " + ", ".join(relevant)
        )
    return executed_commit, executed_tree


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

    # Nothing runs until this checkout is the candidate the plan describes.
    # There is no override: a revision the receipt would have to be told about
    # is precisely the one no execution here can vouch for.
    executed_commit, executed_tree = confirm_candidate(root, plan)

    # The declared toolchain is exactly what reuse compares against the
    # candidate's pinned versions, so the interpreter this runner happens to
    # be is recorded beside it rather than inside it.
    toolchain = receipts.parse_toolchain(arguments.toolchain)

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
