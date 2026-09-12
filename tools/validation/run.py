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
import hashlib
import os
import platform
import signal
import stat
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


def git_records(root: str, *arguments: str, environment: dict | None = None) -> list[str]:
    """Run a NUL-separated Git query, keeping every byte of every field.

    ``git_output`` strips its result, which is right for a revision but wrong
    for a path listing: a path may legitimately begin or end with a space, and
    a stripped field would name a file that does not exist.
    """
    process = subprocess.run(
        ("git", "-C", root) + arguments, capture_output=True, check=False, env=environment
    )
    if process.returncode != 0:
        stderr = process.stderr.decode("utf-8", errors="replace").strip()
        raise EvidenceError("git " + " ".join(arguments) + " failed: " + (stderr or "no output"))
    output = process.stdout.decode("utf-8", errors="replace")
    return [field for field in output.split("\0") if field]


def object_format(root: str) -> str:
    """The hash this repository names its objects with."""
    algorithm = git_output(root, "rev-parse", "--show-object-format")
    if algorithm not in ("sha1", "sha256"):
        raise EvidenceError(
            f"this repository names objects with {algorithm!r}, which is not read here"
        )
    return algorithm


def blob_id(content: bytes, algorithm: str) -> str:
    """Git's object id for a blob holding exactly these bytes."""
    digest = hashlib.new(algorithm)
    digest.update(b"blob " + str(len(content)).encode("ascii") + b"\0")
    digest.update(content)
    return digest.hexdigest()


def worktree_entry(root: str, path: str, algorithm: str) -> tuple[str, str] | None:
    """The mode and object id this checkout actually holds at one path.

    Read from the filesystem and hashed here rather than asked of Git, because
    every Git-side answer passes through machinery a repository can configure.
    A clean filter declared in ``.git/info/attributes`` can emit the committed
    bytes for a file that has been edited, and ``core.symlinks=false`` can make
    a tracked symlink replaced by a regular file of the same text look
    untouched; in both cases the command would read something the candidate
    does not carry while the receipt claimed otherwise. Raw bytes and ``lstat``
    have no such machinery: a symlink hashes its target, a regular file its
    contents, and anything else holds no blob at all.
    """
    absolute = os.path.join(root, path)
    try:
        status = os.lstat(absolute)
    except OSError:
        return None
    if stat.S_ISLNK(status.st_mode):
        return "120000", blob_id(os.readlink(os.fsencode(absolute)), algorithm)
    if not stat.S_ISREG(status.st_mode):
        # A directory, a socket, a device: whatever it is, it is not the blob
        # the candidate recorded here.
        return None
    try:
        with open(absolute, "rb") as handle:
            content = handle.read()
    except OSError as error:
        raise EvidenceError(
            f"cannot read {path} to compare it with the candidate: {error}"
        ) from error
    mode = "100755" if status.st_mode & 0o111 else "100644"
    return mode, blob_id(content, algorithm)


def head_entries(root: str, commit: str) -> dict[str, tuple[str, str, str]]:
    """Every path the candidate records, with its mode, kind, and object id."""
    try:
        listing = planner.tree_entries(root, commit)
    except PlannerError as failure:
        raise EvidenceError(f"cannot read the candidate's tree: {failure}") from failure
    return {path: (mode, kind, object_name) for path, mode, kind, object_name in listing}


def index_entries(root: str) -> tuple[dict[str, tuple[str, str]], set[str]]:
    """Every path the index records, with its mode and object id, and conflicts."""
    entries: dict[str, tuple[str, str]] = {}
    conflicted: set[str] = set()
    for record in git_records(root, "ls-files", "-s", "-z"):
        metadata, separator, path = record.partition("\t")
        fields = metadata.split()
        if not separator or len(fields) != 3 or not path:
            raise EvidenceError(f"cannot read this checkout's index: unexpected entry {record!r}")
        mode, object_name, stage = fields
        if stage != "0":
            conflicted.add(path)
        entries[path] = (mode, object_name)
    return entries, conflicted


def checkout_differences(
    root: str, commit: str, algorithm: str, prefix: str = ""
) -> tuple[set[str], set[str]]:
    """Every path this checkout holds differently from one recorded commit.

    The tracked differences and the additions come back separately, because only
    an addition can be a run's own output; a tracked path that differs is a
    change to the candidate whatever a catalog calls it.

    Three questions, because none implies another: the index is what a commit
    from here would carry, the working tree is what a command actually reads,
    and an untracked file is the unstaged form of an addition. All three are
    answered by comparing recorded modes and object ids — plumbing rather than a
    diff — so none can be quieted by an attribute, a filter, or a configuration
    setting.

    ``prefix`` is what makes the same answer work one level down, for a
    submodule whose paths have to be named from the superproject.
    """
    head = head_entries(root, commit)
    added = {prefix + path for path in untracked_files(root)}
    recorded = {path: (mode, object_name) for path, (mode, _, object_name) in head.items()}
    entries, conflicted = index_entries(root)
    # An unmerged path is a difference by definition: it records no single thing.
    changed = {prefix + path for path in conflicted}
    changed |= {
        prefix + path
        for path in set(recorded) | set(entries)
        if recorded.get(path) != entries.get(path)
    }
    for path, (mode, kind, object_name) in head.items():
        if kind == "commit":
            deeper, deeper_added = submodule_differences(root, path, object_name, prefix)
            changed |= deeper
            added |= deeper_added
        elif worktree_entry(root, path, algorithm) != (mode, object_name):
            changed.add(prefix + path)
    return changed, added


def submodule_differences(
    root: str, path: str, object_name: str, prefix: str
) -> tuple[set[str], set[str]]:
    """The same question, asked of a submodule the candidate records.

    A gitlink records one commit and says nothing about the tree beside it, so a
    submodule sitting at the right commit can still carry staged, unstaged, or
    untracked changes — and neither the superproject's index nor its untracked
    listing reaches inside. Commands read that content, so the comparison
    descends rather than stopping at the commit. A submodule this checkout
    cannot read at all is a difference too: it is not the tree the candidate
    named, and no run can vouch for what is not there.
    """
    inside = os.path.join(root, path)
    here = prefix + path
    try:
        if git_output(inside, "rev-parse", "HEAD") != object_name:
            return {here}, set()
        return checkout_differences(inside, object_name, object_format(inside), here + "/")
    except EvidenceError:
        return {here}, set()


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


def generated(path: str, catalog: dict, consumed: set[str]) -> bool:
    """Whether the candidate's catalog declares this path as a run's own output.

    A declaration never outranks an input. A path some group consumes, or that
    packaging makes an input whatever a catalog says, is answered for by the
    ordinary classification even where a `generated_paths` entry would have
    matched it — otherwise declaring `plan.json` or `*.pyc` would quietly exempt
    a `tools/validation/plan.json` or a `__pycache__` sitting inside a mandatory
    policy root, which is precisely a path the runner must not overlook.

    Entries say what they look like: a trailing ``/`` is a directory prefix, an
    entry containing ``*`` is one of the basename classes `non_affecting_paths`
    already uses, and anything else is an exact repository-relative path. A
    catalog that declares none exempts nothing.
    """
    if path in planner.NEVER_HARMLESS_PATHS or path.endswith(planner.NEVER_HARMLESS_SUFFIXES):
        return False
    if any(planner.matches_input(path, entry) for entry in consumed):
        return False
    for entry in catalog.get("generated_paths", ()):
        if entry.endswith("/"):
            if planner.matches_input(path, entry):
                return True
        elif "*" in entry:
            if planner.matches_class(path, entry):
                return True
        elif path == entry:
            return True
    return False


def relevant_uncommitted(root: str, plan: dict) -> list[str]:
    """Every uncommitted path that keeps this checkout from being the candidate.

    Relevance is read from the classification that produced the plan — the
    candidate's package graph, and the catalog that plan was resolved with,
    which is the fixture when one was supplied and the candidate's own otherwise
    — rather than from whatever the working tree holds now. An edit must not be
    able to reclassify itself as prose on the way past, and a rewritten catalog
    in the working tree is exactly the change this refusal exists to notice.

    Tracked and added paths are held to the same conservative rule: everything
    is relevant unless it is harmless prose, the complement the candidate's
    `input_identity` already covers. Consumed Markdown, a mandatory policy
    input, `cabal.project`, and any `.cabal` file are never harmless however
    they are spelled — and neither is a file no group declares at all, such as a
    `cabal.project.local` that every Cabal command would read. The one exemption
    is what the candidate's catalog declares as a run's own output.
    """
    catalog, packages = candidate_classification(root, plan)
    consumed = planner.consumed_entries(catalog, packages)
    changed, added = checkout_differences(
        root, plan["candidate"]["commit"], object_format(root)
    )
    changed |= {path for path in added if not generated(path, catalog, consumed)}
    return sorted(path for path in changed if not planner.harmless_prose(path, consumed, catalog))


def candidate_classification(root: str, plan: dict) -> tuple[dict, dict]:
    """The catalog and package graph the plan's own identity was taken from.

    The candidate's package graph comes from its commit and cannot have moved.
    Its catalog usually comes from there too, but a plan resolved with
    ``--catalog`` names a file on the mutable filesystem, which could have been
    rewritten since — into one that stops consuming the very path an edit is
    about. So the plan records what that catalog said, and a document that no
    longer digests to it is refused rather than believed: a classification this
    plan was not built from cannot say what a dirty checkout means.
    """
    override = plan["catalog"]["override"]
    try:
        candidate = planner.GitTree(root, plan["candidate"]["commit"])
        catalog, source = planner.read_catalog(candidate, override, root)
        packages = planner.load_packages(candidate, required=True)
    except PlannerError as failure:
        raise EvidenceError(
            "cannot read the classification this plan was resolved with: " f"{failure}"
        ) from failure
    recorded = plan["catalog"]["candidate_digest"]
    if planner.digest(catalog) != recorded:
        raise EvidenceError(
            f"the catalog at {source} is not the one this plan was resolved with "
            f"({recorded[:12]}), so it cannot say what this checkout holds"
        )
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
