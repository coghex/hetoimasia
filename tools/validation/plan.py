#!/usr/bin/env python3
"""Resolve which validation groups a candidate change requires, and explain why.

The planner reads the declarative catalog (``tools/validation/catalog.json`` by
default), derives each group's inputs from the local Cabal package graph plus
the group's explicitly declared non-Haskell inputs, compares two revisions, and
emits a plan naming every catalog group with a selection reason.

It also fingerprints the integration candidate's own tree, as an ``input_identity``
and a ``policy_version``. Selection answers what a contribution touches; those
digests answer the different question of whether this candidate's content is
content an earlier execution already proved, which a two-endpoint diff cannot.

It depends on Python 3 and Git alone: no GHC, no Cabal, no ``dist-newstyle/``.

This file is the command line: argument handling, and the order in which a
plan is assembled. The work lives beside it, each module importing only the
standard library, ``receipts``, and the modules listed before it:

- ``plan_repository``: ``PlannerError``, path matching, Git trees, changed paths.
- ``plan_cabal``: the local package graph and each component's input paths.
- ``plan_catalog``: reading the catalog and checking its schema.
- ``plan_request``: the request block and the contribution rules.
- ``plan_identity``: the policy and input identities.
- ``plan_selection``: ``build_plan``, which composes them into a plan.
- ``plan_render``: the prose rendering of a plan.

``ci_image`` supplies the Linux image contract. ``run.py`` loads the same
modules, in the same order, from the candidate it has proven.

See ``docs/validation.md`` for the catalog schema, the selection policy, the
request block, and the plan's JSON structure.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys

# A one-shot tool must not write into the checkout it is validating. Importing a
# sibling module would leave a ``__pycache__`` beside it — a file the candidate
# does not carry, which the runner is right to refuse — so bytecode writing is
# turned off before the imports that would create it.
sys.dont_write_bytecode = True

import ci_image
import receipts
from plan_cabal import load_packages
from plan_catalog import read_base_catalog, read_catalog, validate_catalog
from plan_identity import input_identity, policy_identity, tree_entries
from plan_render import render_prose
from plan_repository import GitTree, PlannerError, WorkTree, changed_paths, decode
from plan_request import memory_rule, parse_request
from plan_selection import build_plan


# --------------------------------------------------------------------------
# Entry point


def repository_root(supplied: str | None) -> str:
    if supplied:
        return os.path.abspath(supplied)
    process = subprocess.run(
        ("git", "rev-parse", "--show-toplevel"), capture_output=True, text=True, check=False
    )
    if process.returncode == 0 and process.stdout.strip():
        return process.stdout.strip()
    return os.getcwd()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="plan.py",
        description="Resolve and explain the validation groups a change requires.",
    )
    parser.add_argument("--base", help="base revision of the comparison")
    parser.add_argument("--head", help="head revision of the comparison")
    parser.add_argument(
        "--candidate",
        help="the integration revision workers execute (default: the head revision)",
    )
    parser.add_argument(
        "--toolchain",
        action="append",
        default=[],
        metavar="NAME=VERSION",
        help="a pinned toolchain version the candidate's identity covers; repeatable",
    )
    parser.add_argument(
        "--runner-os",
        help="the operating system the workers execute on (default: this runner's)",
    )
    parser.add_argument(
        "--worker",
        action="append",
        default=[],
        metavar="NAME=CLASS[+CLASS]:GROUP[,GROUP]",
        help="a worker, the runner classes it declares, and the groups it owns; repeatable. "
        "Without any, the plan describes selection only and cannot be executed",
    )
    parser.add_argument(
        "--event",
        choices=("pull_request", "push"),
        help="the event the range belongs to; a pull_request range, which must start at its fork "
        "point, is held to the contribution rules. Without it, no contribution rule applies",
    )
    parser.add_argument("--request-file", help="file holding a PR body with a validation-request block")
    parser.add_argument("--catalog", help="fixture catalog path, read from the filesystem")
    parser.add_argument("--repo-root", help="repository to plan for (default: the enclosing checkout)")
    parser.add_argument("--catalog-check", action="store_true", help="validate the catalog and exit")
    parser.add_argument("--json", action="store_true", dest="as_json", help="emit the plan as JSON")
    arguments = parser.parse_args(argv)

    root = repository_root(arguments.repo_root)

    if arguments.catalog_check:
        for name in ("base", "head", "candidate", "event", "request_file", "worker"):
            if getattr(arguments, name):
                raise PlannerError(f"--catalog-check takes no --{name.replace('_', '-')}")
        tree = WorkTree(root)
        document, source = read_catalog(tree, arguments.catalog, root)
        packages = load_packages(tree, required=True)
        problems = validate_catalog(document, source, packages)
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            return 2
        print(f"catalog {source} is valid: {len(document['groups'])} groups, policy version {document['policy_version']}")
        return 0

    if not arguments.base or not arguments.head:
        raise PlannerError("both --base and --head are required unless --catalog-check is used")

    base = GitTree(root, arguments.base)
    head = GitTree(root, arguments.head)

    # Decided from the event and the range alone, before the catalog or the
    # request is read, so nothing a candidate carries can change the answer.
    if arguments.event == "pull_request":
        refusal = memory_rule(changed_paths(root, base, head))
        if refusal:
            raise PlannerError(refusal)

    document, catalog_source = read_catalog(head, arguments.catalog, root)
    head_packages = load_packages(head, required=True)
    problems = validate_catalog(document, catalog_source, head_packages)
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 2
    base_packages = load_packages(base, required=False)
    base_catalog, base_catalog_state = read_base_catalog(base, arguments.catalog)

    # The candidate defaults to the head so a local plan needs no extra
    # revision; CI supplies the integration commit its workers check out, which
    # is neither endpoint and is the only tree an execution actually reads.
    if arguments.candidate:
        candidate = GitTree(root, arguments.candidate)
    else:
        candidate = head
    if candidate.commit == head.commit:
        candidate_catalog, candidate_catalog_source = document, catalog_source
        candidate_packages = head_packages
    else:
        candidate_catalog, candidate_catalog_source = read_catalog(candidate, arguments.catalog, root)
        candidate_packages = load_packages(candidate, required=True)
        problems = validate_catalog(candidate_catalog, candidate_catalog_source, candidate_packages)
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            return 2

    try:
        toolchain = receipts.parse_toolchain(arguments.toolchain)
        workers = (
            [receipts.parse_worker_declaration(entry) for entry in arguments.worker]
            if arguments.worker
            else None
        )
    except receipts.EvidenceError as failure:
        raise PlannerError(str(failure)) from failure
    runner_os = arguments.runner_os or os.environ.get("RUNNER_OS") or platform.system()
    entries = tree_entries(root, candidate.commit)
    # The toolchain map describes the planned worker environment, not this
    # host. For Linux workers that is the image the candidate's own descriptor
    # names, so its digest and native manifest join the map before identity is
    # taken from it — and a descriptor that no longer describes the candidate
    # stops the plan here, before anything executes.
    try:
        image, toolchain = ci_image.plan_image(candidate.read, entries, toolchain, runner_os, candidate.label)
    except ci_image.ImageError as failure:
        raise PlannerError(str(failure)) from failure
    policy = policy_identity(candidate_catalog, entries)
    identity = {
        "runner_os": runner_os,
        "ci_image": image,
        "policy_version": policy,
        "input_identity": input_identity(
            candidate_catalog, candidate_packages, entries, policy, toolchain
        ),
        "toolchain": toolchain,
    }

    request_ids: list[str] = []
    request_all_hspec = False
    request_source = None
    if arguments.request_file:
        request_source = arguments.request_file
        try:
            with open(arguments.request_file, "rb") as handle:
                raw_request = handle.read()
        except OSError as error:
            raise PlannerError(f"cannot read request file {arguments.request_file}: {error}") from error
        request_ids, request_all_hspec = parse_request(
            decode(raw_request, arguments.request_file), request_source
        )

    plan = build_plan(
        root,
        base,
        head,
        candidate,
        identity,
        document,
        catalog_source,
        request_ids,
        request_all_hspec,
        request_source,
        base_packages,
        head_packages,
        base_catalog,
        base_catalog_state,
        arguments.catalog,
        candidate_catalog,
        workers,
    )
    if arguments.as_json:
        print(json.dumps(plan, indent=2, sort_keys=False))
    else:
        print(render_prose(plan))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except PlannerError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
