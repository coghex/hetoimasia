#!/usr/bin/env python3
"""Decide the review gate's two verdicts from current GitHub state.

Neither verdict is read from the event payload. A ``synchronize`` run exists
precisely because the head moved, and the same push starts the stale-approval
decision that may be about to remove ``reviewed:approve``; answering from the
payload would report the state from before that decision. So both subcommands
are given what was read from GitHub *now* and refuse to answer at all for a head
the pull request has already moved past — a delayed run must not strip an
approval that belongs to a newer head, nor publish a success for code the pull
request no longer proposes.

``dismissal`` decides what should happen to the approval label after a push.
``verdict`` decides whether ``review-approved`` may report success.

``dismissal`` does not judge the push's history itself: ``review_replay.py``
does that, in the checkout, and hands its ``keep``/``strip`` here;
``review_provenance.py`` decides whether the push's starting point was ever
proven approved, and hands its ``proven``/``unproven`` here. What lives here is
the composition — an approval is carried only from a proven starting point, and
then by either of two independent proofs that the push itself changed nothing a
reviewer read (it moved no tracked file at all, or it is exactly the clean
replay of the approved work onto the base it incorporated); a canonical review
naming the pushed head itself settles it before either — an approval is a new
origin that needs neither, a denial strips whatever they prove — and the
states in which no answer may be given at all.

Both run in read-only jobs. The job that actually mutates the label holds the
only write token in this repository's workflows and therefore runs no repository
code at all — not this file either — so its own guard is inline shell in
``review-gate.yml``, executed by ``workflow-tests`` against a stubbed ``gh``.

The label state is a *tri-state*, not a boolean. A read of the labels can fail,
and a failed read is not an absent label: treating it as one would let a
transient API error dismiss a push as harmless and leave a stale approval
standing. ``unknown`` therefore refuses rather than guesses.

Exit status: ``0`` decided, ``1`` not approved (``verdict`` only), ``2`` a usage
diagnostic, ``3`` the head moved while this run was working, ``4`` the required
stale-approval decision did not complete successfully (``verdict`` only), ``5``
the label state could not be read.
"""

from __future__ import annotations

import argparse
import sys

STALE_HEAD = 3
DISMISSAL_INCOMPLETE = 4
UNREADABLE_LABELS = 5

# What a label read produced. ``unknown`` is a failed read, and it is never
# folded into ``absent``: the whole point of reading is to distinguish them.
ATTACHED = "attached"
ABSENT = "absent"
UNKNOWN = "unknown"

# The action whose runs must wait for the stale-approval decision. Every other
# action leaves the head alone, so that job is deliberately skipped and its
# skipped result is the expected one rather than a missing decision.
SYNCHRONIZE = "synchronize"

# What `review_replay.py` decided about this push's history.
KEEP = "keep"
STRIP = "strip"

# What `review_provenance.py` decided about this push's starting point.
PROVEN = "proven"
UNPROVEN = "unproven"

# What the newest canonical review of the pushed head itself said, from the
# same tool. Tri-state on purpose: a denial is not the absence of an approval.
APPROVED = "approved"
DENIED = "denied"
NO_VERDICT = "none"


def label_state(value: str) -> str:
    lowered = value.strip().lower()
    if lowered in ("true", "yes", "1", ATTACHED):
        return ATTACHED
    if lowered in ("false", "no", "0", ABSENT):
        return ABSENT
    if lowered == UNKNOWN:
        return UNKNOWN
    raise argparse.ArgumentTypeError(
        f"expected true, false, or unknown, not {value!r}"
    )


def report_unreadable(label: str, doing: str) -> int:
    print(
        f"error: whether {label} is attached could not be read, and an unreadable "
        f"label state is not an absent one; refusing to {doing}",
        file=sys.stderr,
    )
    return UNREADABLE_LABELS


def superseded(event_head: str, current_head: str) -> bool:
    return event_head != current_head


def report_superseded(event_head: str, current_head: str, doing: str) -> int:
    print(
        f"error: this run was started for head {event_head[:12]}, but the pull "
        f"request's head is now {current_head[:12]}; refusing to {doing} for a "
        "superseded head",
        file=sys.stderr,
    )
    return STALE_HEAD


def dismissal(arguments: argparse.Namespace) -> int:
    """What a push should do to the approval label.

    A canonical review that named the pushed head itself settles the question
    first, whatever the push that reached it looked like. An approval means
    the label belongs to this head: that is what lets a fresh approval survive
    a decision that was still queued when it was granted, and what lets a head
    approved after an earlier strip start a new chain. A denial means no
    approval may stand on it, however proven its starting point and however
    clean the push: an inherited approval must not outlive a reviewer's
    refusal of the very revision it stands on.

    Otherwise the starting point has to be a proven approved revision, decided
    by ``review_provenance.py`` and arriving here as ``proven`` or ``unproven``.
    An attached label proves nothing about it: a delayed dismissal for an
    earlier push refuses to touch a superseded head, and the label it left
    standing there was never earned. Tree equality and a clean replay only say
    that *this* push changed nothing a reviewer read; they cannot say that
    anyone read the starting point, so an unproven one strips.

    From a proven starting point, two independent things can leave an approval
    standing, and neither one lets unreviewed code inherit it.

    The first is a push that moved nothing. That is a question about *trees*,
    not commits: a re-pushed identical tree changes nothing a reviewer read. A
    starting point that could not be resolved counts as a change, because an
    unreadable comparison cannot establish that nothing moved.

    The second is the replay rule, decided in the checkout by
    ``review_replay.py`` and arriving here as ``keep`` or ``strip``. A ``keep``
    means the pushed tree is the one Git itself produces by merging the approved
    head with a commit the base already contains, so the earlier review still
    covers every line of it.

    An absent label is not a third outcome. When nothing is attached there is
    nothing to carry, so the replay's verdict is reported as eligibility and no
    inheritance is claimed.
    """
    if superseded(arguments.event_head, arguments.current_head):
        return report_superseded(arguments.event_head, arguments.current_head, "change approval")
    if arguments.label_attached == UNKNOWN:
        return report_unreadable(arguments.label, "decide this push's effect on approval")

    changed = not arguments.before_tree or arguments.before_tree != arguments.after_tree
    if arguments.head_verdict == DENIED:
        carries = False
        reason = f"a canonical review requested changes on head {arguments.event_head[:12]} itself"
    elif arguments.head_verdict == APPROVED:
        carries = True
        reason = f"a canonical review approved head {arguments.event_head[:12]} itself"
    elif arguments.provenance != PROVEN:
        carries = False
        reason = arguments.provenance_reason or "the push's starting point is not a proven approved revision"
    elif not changed:
        carries, reason = True, "the push changed no tracked file"
    elif arguments.replay_decision == KEEP:
        carries, reason = True, arguments.replay_reason or "the push replays the approved work"
    else:
        carries, reason = False, arguments.replay_reason or "the push changed tracked files"

    if arguments.label_attached == ABSENT:
        action, expected = "none", "absent"
        reason = f"{reason}, and {arguments.label} was not attached"
    elif carries:
        action, expected = "none", "kept"
    else:
        action, expected = "remove", "removed"
    print(f"action={action}")
    print(f"expected={expected}")
    print(f"reason={reason}")
    return 0


def verdict(arguments: argparse.Namespace) -> int:
    if superseded(arguments.event_head, arguments.current_head):
        return report_superseded(
            arguments.event_head, arguments.current_head, "publish a verdict"
        )
    if arguments.label_attached == UNKNOWN:
        return report_unreadable(arguments.label, "publish a verdict")

    if arguments.event_action == SYNCHRONIZE:
        if arguments.dismissal_result != "success":
            print(
                "error: the stale-approval decision for this push was "
                f"{arguments.dismissal_result}; approval cannot be published without it",
                file=sys.stderr,
            )
            return DISMISSAL_INCOMPLETE
    elif arguments.dismissal_result not in ("skipped", "success"):
        print(
            f"error: the stale-approval job was {arguments.dismissal_result} on a "
            f"{arguments.event_action!r} event, where it is expected to be skipped",
            file=sys.stderr,
        )
        return DISMISSAL_INCOMPLETE

    if arguments.label_attached == ABSENT:
        print(
            f"{arguments.label} is not attached to this pull request; "
            "the review gate is not satisfied"
        )
        return 1

    print(
        f"{arguments.label} is attached at head {arguments.current_head[:12]}; "
        "the review gate is satisfied"
    )
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="review_gate.py",
        description="Decide the review gate's verdicts from current repository state.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    for name in ("dismissal", "verdict"):
        command = commands.add_parser(name)
        command.add_argument("--label", default="reviewed:approve", help="the approval label's name")
        command.add_argument("--event-head", required=True, help="the head this run was started for")
        command.add_argument("--current-head", required=True, help="the head the pull request has now")
        command.add_argument(
            "--label-attached",
            required=True,
            type=label_state,
            help="whether the approval label is attached: true, false, or unknown",
        )
        if name == "dismissal":
            command.add_argument("--before-tree", default="", help="the tree the push started from")
            command.add_argument("--after-tree", required=True, help="the tree the push landed on")
            command.add_argument(
                "--replay-decision",
                required=True,
                choices=(KEEP, STRIP),
                help="what review_replay.py decided about this push's history",
            )
            command.add_argument(
                "--replay-reason",
                default="",
                help="the one-line reason review_replay.py gave for that decision",
            )
            command.add_argument(
                "--provenance",
                required=True,
                choices=(PROVEN, UNPROVEN),
                help="what review_provenance.py decided about the push's starting point",
            )
            command.add_argument(
                "--provenance-reason",
                default="",
                help="the one-line reason review_provenance.py gave for that decision",
            )
            command.add_argument(
                "--head-verdict",
                required=True,
                choices=(APPROVED, DENIED, NO_VERDICT),
                help="what the newest canonical review of the pushed head itself said",
            )
        else:
            command.add_argument(
                "--event-action", required=True, help="the pull_request action that started this run"
            )
            command.add_argument(
                "--dismissal-result",
                required=True,
                help="how the stale-approval job concluded: success, failure, cancelled, or skipped",
            )

    arguments = parser.parse_args(argv)
    return (dismissal if arguments.command == "dismissal" else verdict)(arguments)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
