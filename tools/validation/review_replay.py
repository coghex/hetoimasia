#!/usr/bin/env python3
"""Decide whether a push replays approved work onto the base it incorporated.

An approval belongs to a tree, not to a branch name. The gate's first slice
therefore invalidated one on every content-changing push, which costs a fresh
review for every branch update the drainer asks for. The design's D-5 selects a
narrower rule: when the push is *exactly* Git's own clean merge of the approved
head with a commit the base already contains, the submitted tree is the one Git
would have produced from work that was already reviewed, and no human or agent
decision is hidden in it.

So this tool answers one question and answers it from Git alone::

    after is a two-parent merge whose first parent is the approved head,
    its second parent is contained in the base,
    replaying the approved head onto that second parent merges cleanly,
    and the replay's tree is the tree that was actually pushed
    => keep

Anything else is ``strip``. A push that adds an edit on top of the merge, a
conflict someone resolved by hand, an authored revert, a rename Git could not
carry, a history rewrite that left the approved head unreachable — each changes
the tree away from the replay, or leaves the replay unprovable, and neither is
something an earlier review covers. No commit message is read and no revert is
detected semantically: a base commit that itself reverts code is ordinary base
history, and inheriting through it is the rule working, not a hole in it.

**Every outcome this tool can reach is an answer, so it always exits 0.** The
caller removes a label on ``strip``, and a conservative ``strip`` is exactly what
an unreadable object or a failed Git read has to produce; exiting non-zero for
those would abort the workflow *before* it reached the removal, leaving the
stale approval standing on the very histories that are least trustworthy. Only a
usage error fails (exit 2, from ``argparse``).

Output is ``key=value`` lines, one per line and safe to append to
``$GITHUB_OUTPUT``. Keys are prefixed ``replay_`` where they would otherwise
collide with ``review_gate.py``'s own outputs in the same step::

    replay_decision=keep|strip
    replay_reason=<one line saying why>
    approved_head=<the head the decision was made against, or empty>
    incorporated_base=<the base commit the update merged in, or empty>
    replay_tree=<the tree the replay produced, or empty>
    resulting_head=<the head that was pushed, or empty>

``approved_head`` is the immediately preceding approval-bearing head. Repeated
clean updates carry an approval through a chain of them, so it is not
necessarily the revision a reviewer read; the provenance the caller publishes
says so rather than claiming the new integration tree was examined.
"""

from __future__ import annotations

import argparse
import subprocess
import sys

KEEP = "keep"
STRIP = "strip"

# `git merge-tree --write-tree` distinguishes "these do not merge" from "I could
# not answer": exit 1 is a conflict it resolved as far as it could, anything
# above that is Git failing. Both strip, and saying which is what makes a broken
# checkout distinguishable from a genuine conflict in the job log.
CONFLICTED = 1

# `git merge-base --is-ancestor` answers "no" with exit 1 and fails with more.
# The distinction matters for the same reason: a broken object is not a proof of
# non-containment, even though both are conservative strips.
UNCONTAINED = 1


def short(revision: str) -> str:
    return revision[:12] if revision else "(none)"


def read(*arguments: str) -> tuple[bool, str]:
    """Run one read-only Git command, reporting failure rather than raising.

    A Git that cannot answer is not evidence that nothing changed, so every
    caller turns a false here into ``strip``.
    """
    try:
        completed = subprocess.run(
            ["git", *arguments],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:  # pragma: no cover - Git missing from the image
        return False, str(error)
    if completed.returncode != 0:
        return False, completed.stderr.strip()
    return True, completed.stdout.strip()


def commit(revision: str) -> tuple[bool, str]:
    return read("rev-parse", "--verify", "--quiet", f"{revision}^{{commit}}")


class Decision:
    """One verdict and the provenance the caller publishes beside it."""

    def __init__(self) -> None:
        self.approved_head = ""
        self.incorporated_base = ""
        self.replay_tree = ""
        self.resulting_head = ""

    def strip(self, reason: str) -> tuple[str, str, "Decision"]:
        return STRIP, reason, self

    def keep(self, reason: str) -> tuple[str, str, "Decision"]:
        return KEEP, reason, self


def decide(before: str, after: str, base: str) -> tuple[str, str, Decision]:
    decision = Decision()

    resolved, pushed = commit(after)
    if not resolved:
        return decision.strip(
            f"the pushed head {short(after)} could not be read, so the update cannot be replayed"
        )
    decision.resulting_head = pushed

    resolved, approved = commit(before)
    if not resolved:
        # A force-push that rewrote history leaves the approved head with no ref
        # pointing at it, and an unfetchable starting point cannot be replayed.
        return decision.strip(
            f"the approved head {short(before)} is not in this repository, so the update cannot be replayed"
        )
    decision.approved_head = approved

    resolved, base_tip = commit(base)
    if not resolved:
        return decision.strip(f"the base {base} could not be resolved, so containment is unprovable")

    resolved, line = read("rev-list", "--parents", "-n", "1", pushed)
    if not resolved:
        return decision.strip(f"the pushed head {short(pushed)} has no readable parents")
    parents = line.split()[1:]
    if len(parents) != 2:
        # One parent is an ordinary push; three or more is an octopus merge,
        # which no branch update produces and whose extra sides were never
        # replayed against the approved head.
        return decision.strip(
            f"the pushed head {short(pushed)} has {len(parents)} parent(s), not the two a base merge leaves"
        )

    first, second = parents
    if first != approved:
        # The approved work has to be the side being carried forward. A merge
        # made the other way round, or from a different starting point, is not
        # this update.
        return decision.strip(
            f"the merge's first parent {short(first)} is not the approved head {short(approved)}"
        )
    decision.incorporated_base = second

    contained = subprocess.run(
        ["git", "merge-base", "--is-ancestor", second, base_tip],
        capture_output=True,
        text=True,
        check=False,
    )
    if contained.returncode == UNCONTAINED:
        # Deliberately containment rather than equality: the base tip moves on
        # while a check runs, and the commit the update actually incorporated
        # stays the one to judge.
        return decision.strip(
            f"the incorporated commit {short(second)} is not contained in {base}, "
            "so the merged-in side is not base history"
        )
    if contained.returncode != 0:
        return decision.strip(
            f"Git could not decide whether {short(second)} is contained in {base} "
            f"(merge-base exited {contained.returncode})"
        )

    replayed = subprocess.run(
        ["git", "merge-tree", "--write-tree", approved, second],
        capture_output=True,
        text=True,
        check=False,
    )
    if replayed.returncode == CONFLICTED:
        return decision.strip(
            f"replaying {short(approved)} onto {short(second)} does not merge cleanly, "
            "so the pushed tree contains a resolution no review covers"
        )
    if replayed.returncode != 0:
        return decision.strip(
            f"Git could not replay {short(approved)} onto {short(second)} "
            f"(merge-tree exited {replayed.returncode})"
        )
    tree = replayed.stdout.split("\n", 1)[0].strip()
    if not tree:
        return decision.strip("the replay reported a clean merge but named no tree")
    decision.replay_tree = tree

    resolved, pushed_tree = read("rev-parse", "--verify", "--quiet", f"{pushed}^{{tree}}")
    if not resolved:
        return decision.strip(f"the pushed head {short(pushed)}'s own tree could not be read")
    if tree != pushed_tree:
        # The topology says "base merge" and the content says otherwise: an edit
        # amended onto the merge, or a resolution Git would not have chosen.
        return decision.strip(
            f"the pushed tree {short(pushed_tree)} is not the replay's tree {short(tree)}, "
            "so the update carries more than the merge"
        )

    return decision.keep(
        f"the push is exactly Git's clean merge of {short(approved)} with {short(second)}"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="review_replay.py",
        description="Decide whether a push replays approved work onto the base it incorporated.",
    )
    parser.add_argument("--before", required=True, help="the head the approval was attached to")
    parser.add_argument("--after", required=True, help="the head the push landed on")
    parser.add_argument("--base", required=True, help="the branch the update was supposed to incorporate")
    arguments = parser.parse_args(argv)

    verdict, reason, decision = decide(arguments.before, arguments.after, arguments.base)
    print(f"replay_decision={verdict}")
    print(f"replay_reason={reason}")
    print(f"approved_head={decision.approved_head}")
    print(f"incorporated_base={decision.incorporated_base}")
    print(f"replay_tree={decision.replay_tree}")
    print(f"resulting_head={decision.resulting_head}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
