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
import json
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

# Neither ``receipts`` nor ``plan`` is imported here, and that is the whole
# bootstrap. Both live under ``tools/validation/``, so both are mandatory policy
# inputs of the very candidate this run has not yet confirmed it is standing in;
# importing either would execute code out of the mutable checkout before
# anything had established it is the candidate's — code that supplies the
# receipt contract and the classification the check itself depends on. So this
# module reads the plan's candidate for itself, proves the checkout with its own
# code and Git plumbing alone, refuses any difference under a policy root, and
# only then imports them. See `main`.


class ProvenanceError(Exception):
    """A refusal reported instead of an execution."""


# ``plan`` is deliberately not imported here either. It is the candidate's own
# classifier, loaded from the checkout being validated, so importing it would
# run code this run has not yet established is the candidate's — and its
# `harmless_prose` is exactly what decides whether an edit to it matters. The
# provenance check refuses any difference under a policy root before the import
# happens; see `candidate_classification`.

# The roots a candidate can never exempt itself from, restated here rather than
# read from the catalog or from `plan.py`. Both of those live under these very
# prefixes: taking the list from them would let an edited policy narrow the
# check that is meant to notice it. `plan.py` unions the same roots into every
# candidate's identity, so this is a restatement of that contract, not a second
# one.
POLICY_ROOTS = ("tools/validation/", ".github/workflows/")

# Environment variables that would point Git at another repository, index, or
# working tree than the one this run is validating. A redirected listing would
# describe a directory the commands never read.
REDIRECTING_GIT_VARIABLES = (
    "GIT_DIR",
    "GIT_COMMON_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
    "GIT_CEILING_DIRECTORIES",
)


def git_environment() -> dict:
    """The environment Git is asked in, with every substitution removed.

    Replacement objects are refused as well as redirection. A `refs/replace`
    entry for the candidate's tree leaves ``rev-parse HEAD`` and
    ``rev-parse HEAD^{tree}`` reporting the planned identifiers while every
    listing, index, and checked-out file describes some other tree — which is
    exactly a different revision wearing the candidate's name.
    """
    environment = {
        name: value
        for name, value in os.environ.items()
        if name not in REDIRECTING_GIT_VARIABLES
    }
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    return environment

# How long a timed-out process group is given to exit on SIGTERM before it is
# killed outright.
TERMINATION_GRACE_SECONDS = 10


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def git_output(root: str, *arguments: str) -> str:
    process = subprocess.run(
        ("git", "-C", root) + arguments, capture_output=True, check=False, env=git_environment()
    )
    if process.returncode != 0:
        stderr = process.stderr.decode("utf-8", errors="replace").strip()
        raise ProvenanceError("git " + " ".join(arguments) + " failed: " + (stderr or "no output"))
    return process.stdout.decode("utf-8", errors="replace").strip()


def git_records(root: str, *arguments: str) -> list[str]:
    """Run a NUL-separated Git query, keeping every byte of every field.

    ``git_output`` strips its result, which is right for a revision but wrong
    for a path listing: a path may legitimately begin or end with a space, and
    a stripped field would name a file that does not exist.
    """
    process = subprocess.run(
        ("git", "-C", root) + arguments, capture_output=True, check=False, env=git_environment()
    )
    if process.returncode != 0:
        stderr = process.stderr.decode("utf-8", errors="replace").strip()
        raise ProvenanceError("git " + " ".join(arguments) + " failed: " + (stderr or "no output"))
    output = process.stdout.decode("utf-8", errors="replace")
    return [field for field in output.split("\0") if field]


def object_format(root: str) -> str:
    """The hash this repository names its objects with."""
    algorithm = git_output(root, "rev-parse", "--show-object-format")
    if algorithm not in ("sha1", "sha256"):
        raise ProvenanceError(
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
        raise ProvenanceError(
            f"cannot read {path} to compare it with the candidate: {error}"
        ) from error
    mode = "100755" if status.st_mode & 0o111 else "100644"
    return mode, blob_id(content, algorithm)


def head_entries(root: str, commit: str) -> dict[str, tuple[str, str, str]]:
    """Every path one commit records, with its mode, kind, and object id.

    Read here rather than through the planner's own copy of this listing,
    because the planner is one of the files being compared: the check that
    notices an edited classifier cannot be built on the classifier.
    """
    entries: dict[str, tuple[str, str, str]] = {}
    for record in git_records(root, "ls-tree", "-r", "-z", commit):
        metadata, separator, path = record.partition("\t")
        fields = metadata.split()
        if not separator or len(fields) != 3 or not path:
            raise ProvenanceError(f"cannot read the tree of {commit}: unexpected entry {record!r}")
        mode, kind, object_name = fields
        entries[path] = (mode, kind, object_name)
    return entries


def index_entries(root: str) -> tuple[dict[str, tuple[str, str]], set[str]]:
    """Every path the index records, with its mode and object id, and conflicts."""
    entries: dict[str, tuple[str, str]] = {}
    conflicted: set[str] = set()
    for record in git_records(root, "ls-files", "-s", "-z"):
        metadata, separator, path = record.partition("\t")
        fields = metadata.split()
        if not separator or len(fields) != 3 or not path:
            raise ProvenanceError(f"cannot read this checkout's index: unexpected entry {record!r}")
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
    recorded = {path: (mode, object_name) for path, (mode, _, object_name) in head.items()}
    entries, conflicted = index_entries(root)
    submodules = {path for path, (_, kind, _) in head.items() if kind == "commit"}
    added = {
        prefix + path
        for path in added_files(root, set(recorded) | set(entries), submodules)
    }
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
    except ProvenanceError:
        return {here}, set()


def added_files(root: str, recorded: set[str], submodules: set[str]) -> set[str]:
    """Every file under this checkout that neither the candidate nor the index records.

    Walked here rather than asked of Git. ``git ls-files --others`` answers for
    whichever working tree Git has been pointed at, and a repository-local
    ``core.worktree``, an inherited ``GIT_WORK_TREE``, or an ignore rule can all
    make that a different directory — or a shorter list — than the one the
    command will run in. The filesystem under the root the command uses is the
    only thing that can answer this, so it is read directly.

    A directory is an addition too, and has to be, because Git records no empty
    ones: a directory the candidate's paths do not put in the tree is content
    the candidate does not have, and a command can read that — a check for an
    empty directory under a declared input, say. Such a directory is named and
    not descended into, since everything beneath it is equally an addition.

    A directory carrying its own ``.git`` is another repository. One the
    candidate records as a submodule is compared on its own terms; any other is
    an addition this checkout cannot look inside, and is named as one.
    """
    implied = implied_directories(recorded)
    found: set[str] = set()
    pending = [(root, "")]
    while pending:
        directory, base = pending.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError as error:
            raise ProvenanceError(
                f"cannot read {base or '.'} to compare this checkout: {error}"
            ) from error
        for entry in entries:
            if not base and entry.name == ".git":
                continue
            relative = base + entry.name
            if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                if relative not in recorded:
                    found.add(relative)
                continue
            if relative in submodules:
                continue
            here = relative + "/"
            if here not in implied or os.path.lexists(os.path.join(entry.path, ".git")):
                found.add(here)
                continue
            pending.append((entry.path, here))
    return found


def implied_directories(recorded: set[str]) -> set[str]:
    """Every directory the recorded paths put in a tree, named with a ``/``."""
    directories: set[str] = set()
    for path in recorded:
        while "/" in path:
            path = path.rsplit("/", 1)[0]
            directories.add(path + "/")
    return directories


def generated(planner, path: str, catalog: dict, consumed: set[str]) -> bool:
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


def under_policy_root(path: str) -> bool:
    """Whether a path is one the candidate's own policy is written in."""
    return any(path.startswith(root) or path == root.rstrip("/") for root in POLICY_ROOTS)


def relevant_uncommitted(
    root: str, plan: dict, changed: set[str], added: set[str]
) -> list[str]:
    """Every uncommitted path that keeps this checkout from being the candidate.

    The order here is the point. Differences are found first, with this module's
    own code and nothing else, because the classifier is one of the files being
    compared: `plan.py` decides what counts as harmless prose, and it lives
    under a policy root, so a checkout that had edited it could otherwise have
    that edit excuse itself. Any difference under a policy root is therefore
    refused outright, before the classifier is so much as imported — no
    classification, and no chance for an edited one to run.

    Only then is the candidate's classification consulted, for the differences
    that remain. Relevance is read from the classification that produced the
    plan — the candidate's package graph, and the catalog that plan was resolved
    with, the fixture when one was supplied and the candidate's own otherwise —
    rather than from whatever the working tree holds now.

    Tracked and added paths are then held to the same conservative rule:
    everything is relevant unless it is harmless prose, the complement the
    candidate's `input_identity` already covers. Consumed Markdown,
    `cabal.project`, and any `.cabal` file are never harmless however they are
    spelled — and neither is a file no group declares at all, such as a
    `cabal.project.local` that every Cabal command would read. The one exemption
    is what the candidate's catalog declares as a run's own output.
    """
    planner, catalog, packages = candidate_classification(root, plan)
    consumed = planner.consumed_entries(catalog, packages)
    changed |= {path for path in added if not generated(planner, path, catalog, consumed)}
    return sorted(path for path in changed if not planner.harmless_prose(path, consumed, catalog))


def candidate_classification(root: str, plan: dict):
    """The classifier, catalog, and package graph the plan's identity came from.

    The import happens here rather than at module scope: `plan.py` is the
    candidate's own code read out of the checkout being validated, and this is
    the first point at which the caller has established that the checkout's copy
    of it is the candidate's.

    The candidate's package graph comes from its commit and cannot have moved.
    Its catalog usually comes from there too, but a plan resolved with
    ``--catalog`` names a file on the mutable filesystem, which could have been
    rewritten since — into one that stops consuming the very path an edit is
    about. So the plan records what that catalog said, and a document that no
    longer digests to it is refused rather than believed: a classification this
    plan was not built from cannot say what a dirty checkout means.
    """
    import plan as planner
    from plan import PlannerError

    override = plan["catalog"]["override"]
    try:
        candidate = planner.GitTree(root, plan["candidate"]["commit"])
        catalog, source = planner.read_catalog(candidate, override, root)
        packages = planner.load_packages(candidate, required=True)
    except PlannerError as failure:
        raise ProvenanceError(
            f"cannot read the classification this plan was resolved with: {failure}"
        ) from failure
    recorded = plan["catalog"]["candidate_digest"]
    if planner.digest(catalog) != recorded:
        raise ProvenanceError(
            f"the catalog at {source} is not the one this plan was resolved with "
            f"({recorded[:12]}), so it cannot say what this checkout holds"
        )
    return planner, catalog, packages


def bootstrap_candidate(path: str) -> dict:
    """The candidate a plan names, read without the candidate's own code.

    ``receipts.load_plan`` is the full contract and is applied later, once the
    checkout has been proven. This reads only what the proof itself needs, with
    the standard library alone, because the module that would validate the rest
    is one of the files the proof is about.
    """
    try:
        with open(path, "rb") as handle:
            document = json.loads(handle.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"cannot read plan {path}: {error}") from error
    if not isinstance(document, dict):
        raise ProvenanceError(f"plan {path} is not a JSON object")
    candidate = document.get("candidate")
    if not isinstance(candidate, dict):
        raise ProvenanceError(f"plan {path} declares no candidate")
    commit = candidate.get("commit")
    tree = candidate.get("tree")
    if not isinstance(commit, str) or not isinstance(tree, str):
        raise ProvenanceError(f"plan {path} does not name the candidate's commit and tree")
    return {"commit": commit, "tree": tree}


def confirm_checkout(root: str, candidate: dict) -> tuple[str, str, set[str], set[str]]:
    """Refuse to go further unless this checkout is the plan's candidate.

    The commit is compared as well as the tree because two commits can share a
    tree, and a receipt naming the wrong one would misdescribe what was
    validated even where the bytes agreed. The candidate is the comparison, not
    the head: a pull request is validated on an integration revision that is
    neither endpoint, and a plan resolved for one still executes from a checkout
    of it.

    A difference under a mandatory policy root ends the run here, before any of
    the candidate's own code has been imported. That ordering is the point: the
    classifier and the receipt contract both live under those roots, so a
    checkout that had edited either could otherwise have the edited copy decide
    whether its own edit mattered.

    The differences are returned rather than recomputed, because classifying
    them is the caller's next step once the policy it would classify them with
    has been shown to be the candidate's.
    """
    executed_commit = git_output(root, "rev-parse", "HEAD")
    executed_tree = git_output(root, "rev-parse", "HEAD^{tree}")
    if executed_commit != candidate["commit"]:
        raise ProvenanceError(
            f"this checkout is at {executed_commit}, which is not the plan's candidate "
            f"{candidate['commit']}; an execution here would be recorded against a "
            "revision it never read"
        )
    if executed_tree != candidate["tree"]:
        raise ProvenanceError(
            f"this checkout's tree is {executed_tree}, which is not the candidate "
            f"{candidate['commit']}'s tree {candidate['tree']}"
        )
    changed, added = checkout_differences(root, candidate["commit"], object_format(root))
    policy = sorted(path for path in changed | added if under_policy_root(path))
    if policy:
        raise ProvenanceError(
            "this checkout has changed the policy that decides what a result means, "
            f"so the candidate {candidate['commit']} cannot answer for it: "
            + ", ".join(policy)
        )
    return executed_commit, executed_tree, changed, added


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

    # Nothing runs, and nothing of the candidate's is imported, until this
    # checkout is the candidate the plan describes. There is no override: a
    # revision the receipt would have to be told about is precisely the one no
    # execution here can vouch for.
    executed_commit, executed_tree, changed, added = confirm_checkout(
        root, bootstrap_candidate(arguments.plan)
    )

    # The policy under this checkout is now known to be the candidate's, so its
    # own modules may be read.
    import receipts
    from receipts import EvidenceError

    try:
        plan = receipts.load_plan(arguments.plan)
        identity = receipts.plan_identity(plan)
        group = receipts.plan_group(plan, arguments.group)
        # The declared toolchain is exactly what reuse compares against the
        # candidate's pinned versions, so the interpreter this runner happens
        # to be is recorded beside it rather than inside it.
        toolchain = receipts.parse_toolchain(arguments.toolchain)
    except EvidenceError as failure:
        raise ProvenanceError(str(failure)) from failure
    if not group["selected"]:
        raise ProvenanceError(
            f"the plan did not select {arguments.group!r} ({group['reason']}); "
            "an omitted group has no execution to record"
        )
    relevant = relevant_uncommitted(root, plan, changed, added)
    if relevant:
        raise ProvenanceError(
            "this checkout carries uncommitted changes to inputs the candidate "
            f"{plan['candidate']['commit']} classifies as relevant, so an execution here "
            "would not be of that candidate: " + ", ".join(relevant)
        )

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
        raise ProvenanceError(f"cannot execute {arguments.group}: {error}") from error

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
    try:
        written = receipts.write_receipt(arguments.receipts, receipt)
    except EvidenceError as failure:
        raise ProvenanceError(str(failure)) from failure
    print(
        f"validation: {arguments.group} {outcome} after {duration:.1f}s "
        f"(exit {status}); receipt {written}",
        flush=True,
    )
    return 0 if outcome == "passed" else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ProvenanceError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
