#!/usr/bin/env python3
"""Resolve the two revisions a candidate's plan is computed from.

The two events this repository validates ask different questions, and the
difference is not cosmetic.

A **pull request** contributes a merge-base range: upstream commits its branch
never touched are not its work, so comparing its head against the fork point is
what isolates what it proposes.

A **push** contributes exactly what it moved the branch by, which is the range
the event itself names. The merge base of those two endpoints is *not* a
conservative stand-in for it: when a push replaces history rather than extending
it, the common ancestor can be older than the work being dropped, and a diff
taken from there simply does not contain the removal. A push that reverts a
source file by resetting onto its ancestor would look like whatever else the new
tip happens to add. So ``before`` is used as given, and a ``before`` that cannot
be resolved is a diagnostic rather than a range guessed from something else.

Exit status: ``0`` with ``base=`` and ``head=`` on stdout, or ``2`` with a
diagnostic naming the endpoint that could not be resolved.
"""

from __future__ import annotations

import argparse
import sys

# A one-shot tool must not write into the checkout it is validating. Importing a
# sibling module would leave a ``__pycache__`` beside it — a file the candidate
# does not carry, which the runner is right to refuse — so bytecode writing is
# turned off before the imports that would create it.
sys.dont_write_bytecode = True

from plan import PlannerError, run_git

EMPTY_COMMIT = "0" * 40


def resolve(root: str, revision: str, description: str) -> str:
    try:
        resolved = run_git(root, "rev-parse", "--verify", "--quiet", revision + "^{commit}").strip()
    except PlannerError as error:
        raise PlannerError(f"cannot resolve the {description} {revision!r}: {error}") from error
    if not resolved:
        raise PlannerError(f"cannot resolve the {description} {revision!r} to a commit")
    return resolved


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="range.py",
        description="Resolve the base and head revisions a validation plan compares.",
    )
    parser.add_argument("--event", required=True, choices=("pull_request", "push"))
    parser.add_argument("--repo-root", default=".", help="the checkout to resolve against")
    parser.add_argument("--base-sha", help="a pull request's base branch tip")
    parser.add_argument("--head-sha", help="a pull request's head")
    parser.add_argument("--before", help="the commit a push started from")
    parser.add_argument("--after", help="the commit a push landed on")
    arguments = parser.parse_args(argv)

    if arguments.event == "pull_request":
        if not arguments.base_sha or not arguments.head_sha:
            raise PlannerError("a pull request needs both --base-sha and --head-sha")
        base_tip = resolve(arguments.repo_root, arguments.base_sha, "base branch tip")
        head = resolve(arguments.repo_root, arguments.head_sha, "head")
        try:
            base = run_git(arguments.repo_root, "merge-base", base_tip, head).strip()
        except PlannerError as error:
            raise PlannerError(
                f"cannot find the fork point of {base_tip[:12]} and {head[:12]}: {error}"
            ) from error
    else:
        if not arguments.after:
            raise PlannerError("a push needs --after")
        head = resolve(arguments.repo_root, arguments.after, "pushed commit")
        if not arguments.before or arguments.before == EMPTY_COMMIT:
            raise PlannerError(
                "this push names no starting commit, so there is no range to compare; "
                "refusing to plan against an assumed base"
            )
        # Deliberately the event's own `before`, never its merge base with the
        # new tip: a push that replaced history has to be compared against what
        # it replaced, or the work it dropped is invisible.
        base = resolve(arguments.repo_root, arguments.before, "starting commit")

    print(f"base={base}")
    print(f"head={head}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except PlannerError as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
