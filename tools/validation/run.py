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

# The import path is narrowed before anything shadowable is imported, and that
# is the first line of the bootstrap. ``python3 tools/validation/run.py`` puts
# that directory first on ``sys.path``, so a file dropped beside this one — a
# ``platform.py``, a ``json.py`` — would be imported in place of the standard
# library module of that name and would run before anything had looked at its
# path. That is the same pre-validation execution the deferred ``receipts`` and
# ``plan`` imports exist to prevent, and it has to be closed here rather than
# there, because it happens at the top of this file.
#
# ``sys`` is built into the interpreter and cannot be shadowed by a file.
# ``os`` is already loaded before any script begins, so naming it here binds the
# module the interpreter started with. Everything after this point resolves
# against the standard library alone; this module reaches its own siblings
# deliberately, by path, once the checkout has been proven.
import sys
import os

TOOLS_DIRECTORY = os.path.dirname(os.path.abspath(__file__))

# The interpreter has to be isolated from its first instruction, not from this
# one. Python runs ``sitecustomize`` and ``usercustomize`` during startup and
# searches ``PYTHONPATH`` for them, so a hook dropped in the checkout executes
# before this file is read at all — early enough to delete itself, rewrite the
# environment, or patch this module before anything has looked at its path.
# Re-execing here would be too late for that, so the runner refuses instead and
# every caller starts it isolated: the workflow's worker steps, the documented
# command, and the workflow tests all pass ``-I``. That also ignores the
# environment, skips user site directories, and (from 3.11) prepends neither the
# script's directory nor the working directory.
if not sys.flags.isolated:
    print(
        "error: run.py must be started with an isolated interpreter — "
        "python3 -I tools/validation/run.py ... — because Python runs a "
        "checkout's own sitecustomize before this script, and a run that has "
        "already executed unproven code cannot vouch for the candidate",
        file=sys.stderr,
    )
    raise SystemExit(2)

# Kept for an interpreter older than the one that made ``-I`` imply ``-P``: on
# those, the script's own directory is still prepended and has to be dropped.
sys.path = [
    entry for entry in sys.path if entry and os.path.abspath(entry) != TOOLS_DIRECTORY
]

import argparse
import hashlib
import json
import platform
import shutil
import signal
import stat
import subprocess
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


def candidate_module(name: str):
    """Load one of the candidate's own validation modules, by path.

    Loaded from its file rather than by putting `tools/validation/` back on the
    import path, so the narrowing above stays in force: these modules' own
    imports keep resolving to the standard library, and nothing dropped beside
    them can answer for a name they ask for.
    """
    import importlib.util

    if name in sys.modules:
        return sys.modules[name]
    path = os.path.join(TOOLS_DIRECTORY, name + ".py")
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise ProvenanceError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    # Registered before execution because these modules import each other by
    # name, and that name has to find this copy rather than search a path.
    sys.modules[name] = module
    try:
        specification.loader.exec_module(module)
    except Exception as failure:
        del sys.modules[name]
        raise ProvenanceError(f"cannot load {path}: {failure}") from failure
    return module


# ``plan`` is deliberately not imported here either. The planner is the
# candidate's own classifier, loaded from the checkout being validated, so
# importing it would run code this run has not yet established is the
# candidate's — and its `harmless_prose` is exactly what decides whether an edit
# to it matters. The provenance check refuses any difference under a policy root
# before the import happens; see `candidate_classification`.

# The planner's modules beside `plan.py`, in dependency order: each imports only
# the standard library, `receipts`, and modules earlier in this list. The
# narrowed import path finds none of them, so they are loaded by path in this
# order, and each name one of them asks for is already registered to the
# candidate's own copy. All of them are loaded, not only those the
# classification reads, as importing `plan.py` itself would.
PLANNER_MODULES = (
    "plan_repository",
    "plan_cabal",
    "plan_catalog",
    "plan_request",
    "plan_identity",
    "plan_selection",
    "plan_render",
)

# The roots a candidate can never exempt itself from, restated here rather than
# read from the catalog or from the planner. Both of those live under these very
# prefixes: taking the list from them would let an edited policy narrow the
# check that is meant to notice it. `plan_identity.py` unions the same roots
# into every candidate's identity, as `REQUIRED_POLICY_ROOTS`, so this is a
# restatement of that contract, not a second one.
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


def sanitize_git_environment() -> None:
    """Remove every substitution Git would otherwise honour, for good.

    Applied to this process's own environment rather than passed to chosen
    calls, because the candidate's classifier shells out to Git as well — to
    read its catalog and its package graph — and a query this module does not
    make is exactly the one that would go unsanitized. Everything started from
    here inherits it, the group's own command included.

    Replacement objects are refused as well as redirection. A `refs/replace`
    entry for the candidate's tree leaves ``rev-parse HEAD`` and
    ``rev-parse HEAD^{tree}`` reporting the planned identifiers while every
    listing, every `git show`, and every checked-out file describes some other
    tree — which is exactly a different revision wearing the candidate's name.
    """
    for name in REDIRECTING_GIT_VARIABLES:
        os.environ.pop(name, None)
    os.environ["GIT_NO_REPLACE_OBJECTS"] = "1"


sanitize_git_environment()

# How long a timed-out stage is given to exit on SIGTERM before it is killed
# outright.
TERMINATION_GRACE_SECONDS = 10

# How long freezing and then killing what survived the grace may take, and how
# long an empty-looking session is given to produce a pass whose bracket held,
# before it is reported as not known to be empty.
KILLING_SECONDS = 10
SETTLING_SECONDS = 2
# The most identifiers a pass's bracket may span and still have each asked
# about directly.
MAX_BRACKET = 4096
# How many times the first termination asks again for a session it could not
# read, before it tells only the process it launched.
FIRST_TERMINATION_ATTEMPTS = 20
# How long expiry cleanup waits for a pass during which nothing was created on
# the machine, before it reports that it could not confirm the session empty.
CONFIRMING_SECONDS = 10


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def git_output(root: str, *arguments: str) -> str:
    process = subprocess.run(
        ("git", "-C", root) + arguments, capture_output=True, check=False
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
        ("git", "-C", root) + arguments, capture_output=True, check=False
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
    # Git's executable bit is the owner's, not any of the three: a file at 0455
    # keeps group and other execution while Git records it as no longer
    # executable, and a comparison that disagreed would miss that change.
    mode = "100755" if status.st_mode & stat.S_IXUSR else "100644"
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
    # An unmerged path is a difference by definition: it records no single thing.
    changed = {prefix + path for path in conflicted}
    additions, opaque = added_files(root, set(recorded) | set(entries), submodules)
    added = {prefix + path for path in additions}
    changed |= {prefix + path for path in opaque}
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
        status = os.lstat(inside)
    except OSError:
        return {here}, set()
    if not stat.S_ISDIR(status.st_mode):
        # A symlink or a file where the candidate records a submodule. Git would
        # follow a link and report whatever clean checkout sits at the other end
        # as this submodule, while the commands read that tree — or the link.
        return {here}, set()
    try:
        if git_output(inside, "rev-parse", "HEAD") != object_name:
            return {here}, set()
        return checkout_differences(inside, object_name, object_format(inside), here + "/")
    except ProvenanceError:
        return {here}, set()


def added_files(
    root: str, recorded: set[str], submodules: set[str]
) -> tuple[set[str], set[str]]:
    """What this checkout holds that neither the candidate nor the index records.

    Walked here rather than asked of Git. ``git ls-files --others`` answers for
    whichever working tree Git has been pointed at, and a repository-local
    ``core.worktree``, an inherited ``GIT_WORK_TREE``, or an ignore rule can all
    make that a different directory — or a shorter list — than the one the
    command will run in. The filesystem under the root the command uses is the
    only thing that can answer this, so it is read directly.

    A directory is an addition too, and has to be, because Git records no empty
    ones: a directory the candidate's paths do not put in the tree is content
    the candidate does not have, and a command can read that — a check for an
    empty directory under a declared input, say. It is named *and* descended
    into, because what lives inside it has to be classified on its own terms: a
    catalog that calls a directory generated is saying its own output goes
    there, not that anything dropped inside it stops being an input.

    Two sets come back. The second holds directories carrying their own
    ``.git`` — another repository, which this one cannot look inside. Those are
    returned as plain differences rather than additions, because a declaration
    cannot honestly exempt content nothing here has read. A submodule the
    candidate records is not among them: it is compared on its own terms.
    """
    implied = implied_directories(recorded)
    found: set[str] = set()
    opaque: set[str] = set()
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
            if entry.is_symlink():
                if relative in recorded or relative in submodules:
                    continue
                # A link standing where a directory would be cannot be walked:
                # it may leave this checkout entirely, and what a command reads
                # through it is not this tree. Opaque, and so never exempt — a
                # `generated_paths` prefix matching the link must not excuse
                # whatever a group declares on the far side of it.
                if entry.is_dir(follow_symlinks=True):
                    opaque.add(relative + "/")
                else:
                    found.add(relative)
                continue
            if not entry.is_dir(follow_symlinks=False):
                if relative not in recorded:
                    found.add(relative)
                continue
            if relative in submodules:
                continue
            here = relative + "/"
            if os.path.lexists(os.path.join(entry.path, ".git")):
                opaque.add(here)
                continue
            if here not in implied:
                found.add(here)
            pending.append((entry.path, here))
    return found, opaque


def implied_directories(recorded: set[str]) -> set[str]:
    """Every directory the recorded paths put in a tree, named with a ``/``."""
    directories: set[str] = set()
    for path in recorded:
        while "/" in path:
            path = path.rsplit("/", 1)[0]
            directories.add(path + "/")
    return directories


def generated(repository, identity, path: str, catalog: dict, consumed: set[str]) -> bool:
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
    if path in identity.NEVER_HARMLESS_PATHS or path.endswith(identity.NEVER_HARMLESS_SUFFIXES):
        return False
    if any(repository.matches_input(path, entry) for entry in consumed):
        return False
    for entry in catalog.get("generated_paths", ()):
        if entry.endswith("/"):
            if repository.matches_input(path, entry):
                return True
        elif "*" in entry:
            if repository.matches_class(path, entry):
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
    compared: `plan_identity.py` decides what counts as harmless prose, and it lives
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
    repository, identity, catalog, packages = candidate_classification(root, plan)
    consumed = identity.consumed_entries(catalog, packages)
    changed |= {
        path for path in added if not generated(repository, identity, path, catalog, consumed)
    }
    return sorted(path for path in changed if not identity.harmless_prose(path, consumed, catalog))


def candidate_classification(root: str, plan: dict):
    """The classifier, catalog, and package graph the plan's identity came from.

    The classifier is the candidate's repository and identity modules, returned
    first. The import happens here rather than at module scope: the planner's
    modules are the candidate's own code read out of the checkout being
    validated, and this is the first point at which the caller has established
    that the checkout's copy of them is the candidate's.

    The candidate's package graph comes from its commit and cannot have moved.
    Its catalog usually comes from there too, but a plan resolved with
    ``--catalog`` names a file on the mutable filesystem, which could have been
    rewritten since — into one that stops consuming the very path an edit is
    about. So the plan records what that catalog said, and a document that no
    longer digests to it is refused rather than believed: a classification this
    plan was not built from cannot say what a dirty checkout means.
    """
    # They live under the same policy root as this runner, so they are just as
    # proven; see `PLANNER_MODULES` for the order.
    modules = {name: candidate_module(name) for name in PLANNER_MODULES}
    repository = modules["plan_repository"]
    identity = modules["plan_identity"]

    override = plan["catalog"]["override"]
    try:
        candidate = repository.GitTree(root, plan["candidate"]["commit"])
        catalog, source = modules["plan_catalog"].read_catalog(candidate, override, root)
        packages = modules["plan_cabal"].load_packages(candidate, required=True)
    except repository.PlannerError as failure:
        raise ProvenanceError(
            f"cannot read the classification this plan was resolved with: {failure}"
        ) from failure
    recorded = plan["catalog"]["candidate_digest"]
    if identity.digest(catalog) != recorded:
        raise ProvenanceError(
            f"the catalog at {source} is not the one this plan was resolved with "
            f"({recorded[:12]}), so it cannot say what this checkout holds"
        )
    return repository, identity, catalog, packages


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


def darwin_process_table() -> list[tuple[int, str]] | None:
    """Every process, from libproc, with ``Z`` for those that have stopped.

    One call lists them, so a pass over the table is quick and the identifiers
    :func:`bracketed_observation` has to ask about directly stay few.
    """
    try:
        import ctypes

        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        wanted = libproc.proc_listpids(1, 0, None, 0)  # PROC_ALL_PIDS
        if wanted <= 0:
            return None
        pids = (ctypes.c_int * (wanted // 4 + 128))()
        written = libproc.proc_listpids(1, 0, pids, ctypes.sizeof(pids))
        if written <= 0:
            return None
        info = ctypes.create_string_buffer(256)
        table: list[tuple[int, str]] = []
        for pid in pids[: written // 4]:
            if pid <= 0:
                continue
            # PROC_PIDTBSDINFO: the status follows the flags in struct proc_bsdinfo.
            got = libproc.proc_pidinfo(pid, 3, 0, info, 256)
            status = int.from_bytes(info.raw[4:8], "little") if got > 0 else 0
            table.append((pid, "Z" if status == 5 else ""))  # SZOMB
        return table
    except (OSError, AttributeError):
        return None


# Processes this runner's own observation has created, which a pass must not
# mistake for the machine's: each ``ps`` it starts is one identifier handed out.
observer_creations = 0


def ps_process_table() -> list[tuple[int, str]] | None:
    """The same, from ``ps``, where libproc is not to be had."""
    global observer_creations
    try:
        listing = subprocess.run(
            ["ps", "-A", "-o", "pid=,stat="],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    observer_creations += 1
    if listing.returncode != 0:
        return None
    table: list[tuple[int, str]] = []
    for line in listing.stdout.splitlines():
        fields = line.split()
        if not fields:
            continue
        try:
            table.append((int(fields[0]), fields[1] if len(fields) > 1 else ""))
        except ValueError:
            return None
    return table


def process_table() -> list[tuple[int, str]] | None:
    """Every process the platform lists, as its identifier and, where the
    listing says, its state; ``None`` when the table cannot be read.

    This is the first half of observing a session — which processes exist — and
    the second half asks each one which session it is in. The two are not one
    atomic step, which is why :func:`session_members` asks directly about every
    process created during a pass that finds nobody.
    """
    if sys.platform.startswith("linux"):
        try:
            names = os.listdir("/proc")
        except OSError:
            return None
        return [(int(name), "") for name in names if name.isdigit()]
    if sys.platform == "darwin":
        table = darwin_process_table()
        if table is not None:
            return table
    return ps_process_table()


def process_session(pid: int, state: str) -> tuple[int, str, int] | None:
    """One listed process's session, state and process group; ``None`` when it
    has gone.

    Raises ``OSError`` when it cannot be asked, which the caller must not read
    as an answer.
    """
    if sys.platform.startswith("linux"):
        try:
            with open(f"/proc/{pid}/stat", "rb") as handle:
                record = handle.read()
        except (FileNotFoundError, ProcessLookupError):
            return None
        # The command name is parenthesised and may itself contain spaces and
        # parentheses, so the fields that follow are found from the last one:
        # state, parent, group, session.
        try:
            fields = record[record.rindex(b")") + 2 :].split()
            return int(fields[3]), fields[0].decode("ascii"), int(fields[2])
        except (ValueError, IndexError) as error:
            raise OSError(f"unreadable process record for {pid}") from error
    try:
        return os.getsid(pid), state, os.getpgid(pid)
    except ProcessLookupError:
        return None


def observe_session(session: int) -> dict[int, int] | None:
    """One pass over the process table: who is in ``session`` and still running,
    each with its process group.

    ``None`` means the table could not be read, which is not an empty session.
    A process that exits during the pass is simply gone, and a zombie has
    already stopped: neither is a member.
    """
    table = process_table()
    if table is None:
        return None
    members: dict[int, int] = {}
    for pid, listed_state in table:
        try:
            found = process_session(pid, listed_state)
        except OSError:
            return None
        if found is None:
            continue
        member_session, state, group = found
        if member_session == session and state[:1] not in ("Z", "X"):
            members[pid] = group
    return members


def newest_pid() -> int | None:
    """The identifier of a process created and reaped just now.

    Identifiers are handed out in sequence, so every process created between
    two of these taken one after the other holds an identifier strictly between
    theirs, wherever on the machine it was created and whether it was a process
    or a thread.
    """
    try:
        pid = os.fork()
    except OSError:
        return None
    if pid == 0:
        os._exit(0)
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    return pid


def bracketed_observation(session: int) -> tuple[dict[int, int] | None, bool]:
    """One pass, with every process created during it asked directly.

    A pass lists the processes and then asks each its session, so a member that
    forks a replacement and exits in between is gone when asked while the
    replacement was never listed. Two throwaway processes bracket the pass, and
    identifiers are handed out in sequence, so every process created while it
    ran holds an identifier between theirs: each is asked its session directly,
    whether or not the listing saw it. Unrelated creations are only more
    identifiers to ask about, not a reason to wait for quiet.

    The second value is whether the bracket could be trusted at all: it cannot
    when the identifiers wrapped, when a marker could not be made, or when more
    were created than ``MAX_BRACKET`` allows asking about.
    """
    before = newest_pid()
    members = observe_session(session)
    after = newest_pid()
    if members is None:
        return None, False
    if before is None or after is None or not before < after <= before + MAX_BRACKET:
        return members, False
    for pid in range(before + 1, after):
        if pid in members:
            continue
        try:
            found = process_session(pid, "")
        except OSError:
            return None, False
        if found is None:
            continue
        member_session, state, group = found
        if member_session == session and state[:1] not in ("Z", "X"):
            members[pid] = group
    return members, True


def strict_observation(session: int) -> tuple[dict[int, int] | None, bool]:
    """One pass, and whether nothing was created anywhere while it ran.

    If nothing at all was created during a pass, every process in the session at
    its end was already there when it began and stayed throughout, so the
    listing holds it, and an empty answer is exact. The two throwaway processes
    bracketing the pass say whether that held: consecutive identifiers mean
    nothing was created between them. Unrelated activity spoils it, which is why
    only expiry cleanup, whose guarantee this serves, asks for it.
    """
    own = observer_creations
    before = newest_pid()
    members = observe_session(session)
    after = newest_pid()
    # The observer's own processes — each ``ps`` it started — are accounted for;
    # anything beyond them spoils the pass.
    expected = 1 + observer_creations - own
    return members, before is not None and after is not None and after == before + expected


def cleanup_observation(
    session: int, limit: float
) -> tuple[dict[int, int] | None, bool]:
    """What is in the session, and whether that answer is exact.

    A member found is reliable, so a pass that finds one answers at once. Finding
    nobody is exact only from a pass nothing was created during
    (:func:`strict_observation`), so passes are repeated until one is or
    ``limit`` passes. A session that could not be read is ``(None, False)``; one
    whose emptiness could not be confirmed in time is ``({}, False)``, and the
    caller must not treat it as clean.
    """
    while True:
        members, strict = strict_observation(session)
        if members is None:
            return None, False
        if members or strict:
            return members, True
        if time.monotonic() >= limit:
            return members, False


def session_members(session: int) -> dict[int, int] | None:
    """Every live process in the stage's session, whichever group it is in.

    A command's session is the one its launch created, so its identifier is the
    command's own process id and no descendant can leave it without a ``setsid``
    of its own. ``None`` is *not knowing*: it is never an empty session.

    Finding a member is reliable. Finding nobody is believed from a pass whose
    bracket held (:func:`bracketed_observation`), repeated for at most
    ``SETTLING_SECONDS`` until one does. That closes every handoff that happens
    during the pass and the queries it makes. It does not close one that happens
    after the closing marker: a member alive at the marker that forks a
    replacement and exits before its own query leaves a replacement nothing
    asked about, so an empty answer can be early. That residual is accepted and
    documented (docs/validation.md); expiry cleanup does not rely on it.
    """
    members = observe_session(session)
    if members != {}:
        return members
    limit = time.monotonic() + SETTLING_SECONDS
    while time.monotonic() < limit:
        members, complete = bracketed_observation(session)
        if members is None or members or complete:
            return members
    return None


def stage_alive(session: int) -> bool:
    """Whether anything the stage started still runs in its session.

    A session that cannot be observed is reported alive, like a group this
    runner may not signal: a survivor must not be reported as gone, and the
    next poll asks again.
    """
    members = session_members(session)
    if members is None:
        return True
    return bool(members)


def signal_member(pid: int, session: int, number: int) -> None:
    """Signal one process, only if it is still in the stage's session.

    The session is asked again immediately before the signal, so a process
    identifier that has meanwhile been reused outside the stage — or the runner
    itself — is never reached.
    """
    if pid == os.getpid():
        return
    try:
        if os.getsid(pid) != session:
            return
        os.kill(pid, number)
    except OSError:
        pass


def signal_members(
    members: dict[int, int],
    session: int,
    number: int,
    groups: bool = False,
    initial: int | None = None,
) -> None:
    """Signal what a pass found: each member, and with ``groups`` each member's
    process group first.

    A group signal is delivered to every process in the group at once, and a
    process forked into the group at that moment is either reached or forked by
    one that was, so it reaches descendants that live too briefly for their own
    identifiers to be signalled one by one. A process group lies wholly inside
    one session, so signalling a member's group stays inside the stage's; the
    session and group are asked again immediately before. It also reaches every
    process already in the group, so it is for signals that can be repeated,
    ``SIGSTOP`` and ``SIGKILL``: ``SIGTERM`` is delivered once to each process,
    because a handler that answers it by resetting the disposition and cleaning
    up would be killed by the second.

    ``initial`` is the group the command was launched in, whose identifier is
    the session's. It is signalled whether or not a pass found anyone in it: a
    chain of descendants that each live for microseconds is rarely caught by a
    pass, yet every one of them is in that group and a group signal reaches
    whichever is alive. It is the group this runner has always signalled.
    """
    if initial is not None and groups:
        try:
            os.killpg(initial, number)
        except OSError:
            pass
    for group in sorted(set(members.values()) if groups else ()):
        for pid, member_group in members.items():
            if member_group != group:
                continue
            try:
                if os.getsid(pid) == session and os.getpgid(pid) == group:
                    os.killpg(group, number)
                    break
            except OSError:
                continue
    for pid in sorted(members):
        signal_member(pid, session, number)


def signal_session(
    process: subprocess.Popen, session: int, group: int | None, number: int
) -> dict[int, int] | None:
    """Signal every live member of the stage's session; return who was seen.

    ``None`` means the session could not be observed, in which case the signal
    goes to the group the command made and the process the runner holds — the
    most that can be named without looking — rather than to nobody.
    """
    members = session_members(session)
    if members is None:
        try:
            if group is None:
                process.send_signal(number)
            else:
                os.killpg(group, number)
        except (OSError, ValueError):
            pass
        return None
    signal_members(
        members, session, number, groups=number != signal.SIGTERM, initial=group
    )
    return members


def sweep_group(group: int | None) -> None:
    """Kill whatever is left in the group the command was launched in."""
    if group is None:
        return
    try:
        os.killpg(group, signal.SIGKILL)
    except OSError:
        pass


def freeze_session(session: int, group: int | None, limit: float) -> bool:
    """Stop every member of the session where it stands, until none is new.

    A stopped process cannot fork, so once a pass nothing was created during
    finds only members already stopped, the session cannot grow and what is in
    it can be killed in one sweep rather than chased. Returns whether that fixed
    point was reached before ``limit``; a session that cannot be observed cannot
    be frozen and is simply killed.
    """
    frozen: set[int] = set()
    while time.monotonic() < limit:
        members, strict = strict_observation(session)
        if members is None:
            return False
        fresh = set(members) - frozen
        signal_members(members, session, signal.SIGSTOP, groups=True, initial=group)
        frozen |= fresh
        if not fresh and strict:
            return True
    return False


def first_termination(process: subprocess.Popen, session: int) -> set[int]:
    """Tell every member of the session to terminate, and say whom.

    The recipients are exactly the processes named in the returned set, each
    told once: that is what lets later polls tell only processes that were not,
    and never one that is already running its cleanup. A session that cannot be
    read is asked again for as long as a second; if it still cannot be, only the
    process this runner launched is told, since a signal to a group would reach
    processes nobody can name, and the rest are told when they are first seen.
    """
    members = None
    for _ in range(FIRST_TERMINATION_ATTEMPTS):
        members = session_members(session)
        if members is not None:
            break
        time.sleep(TEARDOWN_POLL_SECONDS)
    if members is None:
        try:
            process.send_signal(signal.SIGTERM)
        except (OSError, ValueError):
            pass
        return {process.pid}
    signal_members(members, session, signal.SIGTERM)
    return set(members)


def terminate_session(process: subprocess.Popen, session: int, group: int | None) -> bool:
    """End the command and every descendant it started; say whether any was killed.

    The launched process exiting is not the same as the stage ending. A
    descendant that ignores SIGTERM keeps running long after the shell that
    started it has gone, and one that moved into another process group is
    invisible to the group the command was launched with, so liveness is asked
    of the *session* rather than inferred from the process this runner happens
    to hold a handle to. Anything still there after the grace period is killed
    outright: the budget has already expired, and a survivor would keep holding
    the runner's CPU and scratch space. Only members of the session are ever
    signalled; a process that started its own session with ``setsid`` is beyond
    this watchdog, and so is anything outside it.

    SIGTERM comes first and gets its grace period because a command that owns
    a display or a fixture keeps its diagnostics in its own cleanup: a signal it
    can handle lets it retain them before it goes. That cleanup is not part of
    the measurement, and nothing it reports can turn the expiry into a pass.
    Membership is asked again on every poll, so a process created during the
    grace period is told to stop too, once, and a survivor is never reported as
    gone. What survives the grace is first stopped in place, so that nothing can
    keep forking replacements faster than they are found, and then killed.

    The guarantee here is stronger than completion's. A session is believed empty
    only from a pass during which nothing was created on the machine
    (:func:`cleanup_observation`), so a replacement handed off while a pass was
    running cannot hide a member; host activity only delays the confirmation.
    The wait is capped, and when it runs out the cleanup is not reported clean:
    it reports that it killed.
    """
    seen = first_termination(process, session)
    grace = time.monotonic() + TERMINATION_GRACE_SECONDS
    while True:
        members, confirmed = cleanup_observation(
            session, min(grace, time.monotonic() + CONFIRMING_SECONDS)
        )
        leader_exited = process.poll() is not None
        # The leader going is not the session going: its descendants get
        # whatever is left of the same grace before anything is killed.
        if leader_exited and members == {} and confirmed:
            sweep_group(group)
            return False
        if time.monotonic() >= grace:
            break
        found = members or {}
        fresh = set(found) - seen
        if fresh:
            signal_members({pid: found[pid] for pid in fresh}, session, signal.SIGTERM)
        seen |= fresh
        time.sleep(TEARDOWN_POLL_SECONDS)
    reach = time.monotonic() + KILLING_SECONDS
    freeze_session(session, group, reach)
    while True:
        members, confirmed = cleanup_observation(session, reach)
        if members:
            signal_members(members, session, signal.SIGKILL, groups=True, initial=group)
        elif members is None:
            signal_session(process, session, group, signal.SIGKILL)
        if process.poll() is not None and members == {} and confirmed:
            break
        if time.monotonic() >= reach:
            break
        time.sleep(TEARDOWN_POLL_SECONDS)
    if process.poll() is None:
        process.kill()
        process.wait()
    sweep_group(group)
    return True


# How often a finished command's session is asked whether its descendants have
# gone. Nothing signals when it empties, so it is asked.
TEARDOWN_POLL_SECONDS = 0.05


def execute(command: list[str], root: str, timeout_seconds: int, environment: dict[str, str]) -> dict:
    """Run one stage under its deadline, and describe how it ended.

    The measurement is the stage's own: it ends when the command *and every
    descendant it started* have gone, or at the deadline, whichever comes first.
    A command whose leader exits while something it started is still running
    has not finished its teardown, so the runner keeps measuring until that
    command's session is empty, whichever process group a descendant moved into
    — bounded by the same deadline. A descendant that starts a session of its
    own is the one thing it cannot follow. Whatever happens after the
    deadline is cleanup, recorded apart as ``expiry`` and never counted in
    ``duration_seconds``, and an expired stage is a ``timeout`` whatever its
    process reports once it has been stopped.
    """
    started_at = timestamp()
    started = time.monotonic()
    deadline = started + timeout_seconds
    # A new session gives the command a session and a process group of its own,
    # so a timeout can reap the descendants it spawned rather than only the
    # process it launched.
    process = subprocess.Popen(command, cwd=root, start_new_session=True, env=environment)
    # The session's identifier, like its first group's, is the command's own
    # process id. It is taken from there rather than asked of the process,
    # because a command that has already exited — leaving a child running — can
    # no longer answer, and a session nobody could name would be one nobody
    # watched. Descendants stay in it whichever process group they join; only
    # a descendant that starts a session of its own leaves it.
    session: int = process.pid
    group: int | None = process.pid
    expired = False
    try:
        # The deadline is absolute, fixed before the command was started, so
        # whatever starting it cost is spent from the same budget.
        process.wait(timeout=max(0.0, deadline - time.monotonic()))
        while stage_alive(session):
            if time.monotonic() >= deadline:
                expired = True
                break
            time.sleep(TEARDOWN_POLL_SECONDS)
    except subprocess.TimeoutExpired:
        expired = True
    # A command that finished only after its deadline did not finish inside
    # it, however its exit was observed.
    if not expired and time.monotonic() > deadline:
        expired = True
    measured = min(time.monotonic(), deadline) - started
    expiry = None
    if expired:
        expired_at = timestamp()
        killed = terminate_session(process, session, group)
        expiry = {
            "expired_at": expired_at,
            "cleanup_seconds": round(max(0.0, time.monotonic() - started - measured), 3),
            "killed": killed,
        }
    status = process.returncode
    if expiry is not None:
        outcome = "timeout"
    elif status == 0:
        outcome = "passed"
    else:
        outcome = "failed"
    return {
        "command": list(command),
        "outcome": outcome,
        "exit_status": status,
        "started_at": started_at,
        "ended_at": timestamp(),
        "duration_seconds": round(measured, 3),
        "timeout_seconds": timeout_seconds,
        "expiry": expiry,
    }


# The variable a group's command is told its evidence directory by. Whatever a
# stage leaves there — a display server's log, a fixture's record — is listed
# in the receipt and travels with it, which is how a failed or expired run keeps
# the diagnostics its cleanup would otherwise have deleted.
EVIDENCE_VARIABLE = "HETOIMASIA_VALIDATION_EVIDENCE"


def evidence_files(receipts_directory: str, directory: str) -> list[str]:
    """Every file under one group's evidence directory, relative to the receipts."""
    found: list[str] = []
    for base, _, names in os.walk(directory):
        for name in names:
            relative = os.path.relpath(os.path.join(base, name), receipts_directory)
            found.append(relative.replace(os.sep, "/"))
    return sorted(found)


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
        "--worker",
        required=True,
        help="the worker executing this group, as the plan declares it",
    )
    parser.add_argument(
        "--runner-class",
        action="append",
        required=True,
        dest="runner_classes",
        metavar="CLASS",
        help="a runner class this executing worker provides; repeatable",
    )
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
    receipts = candidate_module("receipts")
    EvidenceError = receipts.EvidenceError

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
        detail = (
            "; this platform does not build its components, so there is no command here to run"
            if group["reason"] == receipts.PLATFORM_INAPPLICABLE
            else ""
        )
        raise ProvenanceError(
            f"the plan did not select {arguments.group!r} ({group['reason']}); "
            f"an omitted group has no execution to record{detail}"
        )
    # The executing worker's own declaration against the plan's routing: a
    # group runs only on the worker the plan assigned it to, and only where
    # this execution provides the runner class the group requires.
    refused = receipts.execution_problems(
        plan, arguments.group, arguments.worker, arguments.runner_classes
    )
    if refused:
        raise ProvenanceError(
            f"this worker may not execute {arguments.group!r}: " + "; ".join(refused)
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
    receipts_directory = os.path.abspath(arguments.receipts)
    evidence_directory = os.path.join(receipts_directory, "evidence", arguments.group)
    # Every file the receipt lists must be one this execution left, so whatever
    # an earlier execution of the same group left here goes first. A link
    # standing where the directory belongs is removed, never followed.
    try:
        if os.path.islink(evidence_directory) or os.path.isfile(evidence_directory):
            os.unlink(evidence_directory)
        elif os.path.isdir(evidence_directory):
            shutil.rmtree(evidence_directory)
        os.makedirs(evidence_directory)
    except OSError as error:
        raise ProvenanceError(f"cannot prepare the evidence directory {evidence_directory}: {error}") from error
    environment = dict(os.environ)
    environment[EVIDENCE_VARIABLE] = evidence_directory

    # The preparation, when the group declares one, runs to completion first
    # and is recorded apart. The group's own budget then measures its command
    # alone: what was built is not what was timed.
    preparation = None
    if group["preparation"] is not None:
        stage = group["preparation"]
        print(
            f"validation: preparing {arguments.group} under a {stage['timeout_seconds']}s budget: "
            + " ".join(stage["command"]),
            flush=True,
        )
        try:
            preparation = execute(list(stage["command"]), root, stage["timeout_seconds"], environment)
        except OSError as error:
            raise ProvenanceError(f"cannot prepare {arguments.group}: {error}") from error
        print(
            f"validation: {arguments.group} preparation {preparation['outcome']} after "
            f"{preparation['duration_seconds']:.1f}s (exit {preparation['exit_status']})",
            flush=True,
        )

    if preparation is not None and preparation["outcome"] != "passed":
        # A group whose preparation did not pass did not run, and says so: its
        # outcome is the preparation's, and its command was never started, so
        # nothing about the command's own behaviour is claimed.
        execution = {
            "command": command,
            "outcome": preparation["outcome"],
            "exit_status": preparation["exit_status"],
            "started_at": preparation["ended_at"],
            "ended_at": preparation["ended_at"],
            "duration_seconds": 0,
            "timeout_seconds": timeout_seconds,
            "expiry": None,
        }
        executed = False
        print(f"validation: {arguments.group} did not run, because its preparation did not pass", flush=True)
    else:
        print(
            f"validation: running {arguments.group} ({group['reason']}) "
            f"under a {timeout_seconds}s budget: " + " ".join(command),
            flush=True,
        )
        try:
            execution = execute(command, root, timeout_seconds, environment)
        except OSError as error:
            raise ProvenanceError(f"cannot execute {arguments.group}: {error}") from error
        executed = True

    outcome = execution["outcome"]
    status = execution["exit_status"]
    duration = execution["duration_seconds"]
    receipt = {
        "schema_version": receipts.RECEIPT_SCHEMA_VERSION,
        "group": arguments.group,
        "command": command,
        "outcome": outcome,
        "exit_status": status,
        "started_at": execution["started_at"],
        "ended_at": execution["ended_at"],
        "duration_seconds": duration,
        "timeout_seconds": timeout_seconds,
        "expiry": execution["expiry"],
        "executed": executed,
        "preparation": preparation,
        "evidence": evidence_files(receipts_directory, evidence_directory),
        "plan_identity": identity,
        "head_commit": plan["head"]["commit"],
        "executed_commit": executed_commit,
        "executed_tree": executed_tree,
        "runner_os": os.environ.get("RUNNER_OS") or platform.system(),
        "runner_arch": os.environ.get("RUNNER_ARCH") or platform.machine(),
        "runner_python": platform.python_version(),
        "worker": arguments.worker,
        "runner_class": group["runner"],
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
    expiry = execution["expiry"]
    cleanup = (
        f"; its deadline expired and cleanup took a further {expiry['cleanup_seconds']:.1f}s"
        + (", killing what survived" if expiry["killed"] else "")
        if expiry is not None
        else ""
    )
    print(
        f"validation: {arguments.group} {outcome} after {duration:.1f}s "
        f"(exit {status}){cleanup}; receipt {written}",
        flush=True,
    )
    return 0 if outcome == "passed" else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ProvenanceError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
