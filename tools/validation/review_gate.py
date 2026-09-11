#!/usr/bin/env python3
"""Decide the ``review-approved`` verdict from current GitHub state.

The verdict is never read from the event payload that started the run. A
``synchronize`` run exists precisely because the head moved, and the same push
starts the stale-approval job that may be about to remove ``reviewed:approve``;
publishing from the payload would report the label state from before that
decision. So this tool is given three things read from GitHub *now* — the head
the pull request currently has, whether the approval label is currently
attached, and how the stale-approval job concluded — and refuses to publish a
success unless all three agree that the head this run is about to answer for is
still the current one and is genuinely approved.

Exit status: ``0`` approved, ``1`` not approved, ``2`` a usage diagnostic,
``3`` the head moved while this run was working, ``4`` the required
stale-approval decision did not complete successfully.
"""

from __future__ import annotations

import argparse
import sys

STALE_HEAD = 3
DISMISSAL_INCOMPLETE = 4

# The action whose runs must wait for the stale-approval decision. Every other
# action leaves the head alone, so that job is deliberately skipped and its
# skipped result is the expected one rather than a missing decision.
SYNCHRONIZE = "synchronize"


def boolean(value: str) -> bool:
    lowered = value.strip().lower()
    if lowered in ("true", "yes", "1"):
        return True
    if lowered in ("false", "no", "0"):
        return False
    raise argparse.ArgumentTypeError(f"expected true or false, not {value!r}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="review_gate.py",
        description="Decide the review-approved verdict from current repository state.",
    )
    parser.add_argument("--event-action", required=True, help="the pull_request action that started this run")
    parser.add_argument("--event-head", required=True, help="the head commit this run was started for")
    parser.add_argument("--current-head", required=True, help="the head commit the pull request has now")
    parser.add_argument(
        "--dismissal-result",
        required=True,
        help="how the stale-approval job concluded: success, failure, cancelled, or skipped",
    )
    parser.add_argument(
        "--label-attached",
        required=True,
        type=boolean,
        help="whether the approval label is currently attached",
    )
    parser.add_argument("--label", default="reviewed:approve", help="the approval label's name")
    arguments = parser.parse_args(argv)

    if arguments.event_head != arguments.current_head:
        # A delayed run answering for an older head would publish a verdict
        # about code the pull request no longer proposes. The run started for
        # the newer head is the one entitled to answer.
        print(
            f"error: this run was started for head {arguments.event_head[:12]}, "
            f"but the pull request's head is now {arguments.current_head[:12]}; "
            "refusing to publish a verdict for a superseded head",
            file=sys.stderr,
        )
        return STALE_HEAD

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

    if not arguments.label_attached:
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


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
