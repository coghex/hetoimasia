#!/usr/bin/env python3
"""Decide whether a push's starting point is a proven approved revision.

``review_replay.py`` proves that a push is exactly Git's clean merge of its
starting point with the base, and ``review_gate.py`` proves that a push moved
no tracked file. Neither proves that the *starting point* was ever entitled to
the approval it carries. A delayed dismissal for an earlier push refuses to act
once the head has moved on — correctly, since the newer head is someone else's
to judge — but that leaves ``reviewed:approve`` standing on a head nobody
proved, and the next push inherits it through a rule that only ever asked
whether the label was attached.

So this tool answers the question those two cannot: is ``before`` a proven
approved revision? One is

- a head a **canonical review** named: a ``pr-review`` marker comment on this
  pull request, authored by the repository owner's account (the identity the
  Kanban coordinator and drainer publish under), whose newest marker naming
  that exact head reads ``verdict=APPROVE``; or
- a head reached from such a revision through an **unbroken chain of recorded
  carries**: one ``approval-provenance`` record per push, authored by this
  repository's own workflow identity and written only by the mutation job that
  confirmed the label attached at the pushed head after a successful decision.

A ``before`` whose own decision was superseded, failed, cancelled, or never ran
left no record and is therefore unproven, however the trees compare. A fresh
canonical approval at any head is a new origin: it needs no chain behind it and
survives an earlier strip.

The feed is read from a file the caller fetched, so that this decision is
proven in tests against fixture feeds exactly as it runs in the workflow. A
feed that is missing, unreadable, malformed, or incomplete proves nothing — it
is reported as ``unproven`` with the reason, never as ``proven`` from tree
equality or replay eligibility, and never as a refusal that would abort the
workflow before the label removal it justifies.

**Every outcome this tool can reach is an answer, so it always exits 0.** Only a
usage error fails (exit 2, from ``argparse``). Output is ``key=value`` lines
safe to append to ``$GITHUB_OUTPUT``::

    provenance=proven|unproven
    provenance_reason=<one line saying why>
    origin=<the canonically approved revision the carried review originates from, or empty>
    chain=<origin,...,before: every revision the carry passed through, or empty>
    head_approved=true|false   whether a canonical review named the pushed head itself
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PROVEN = "proven"
UNPROVEN = "unproven"

# The identity GitHub gives a workflow's own token. Every record the mutation
# job writes is authored by it, and nothing a person posts can be.
WORKFLOW_IDENTITY = "github-actions[bot]"

# The canonical coordinator's marker, and the drainer's own single-reviewer
# spelling that the same publisher may post in its place. Both name the exact
# head the verdict was reached for; neither is taken from any other author.
REVIEW_MARKER = re.compile(
    r"<!--\s*pr-review:v(?:2\s+reviewers=\S+\s+models=\S+|1\s+reviewer=\S+)\s+"
    r"head=(?P<head>[0-9a-fA-F]{40})\s+verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED)\s*-->"
)

# One record per carried push, written by `dismiss-stale-approval` after it
# confirmed the label attached at `after`. Its `origin` is the canonically
# approved revision that decision traced the carry back to; the proof below
# re-walks the links rather than trusting that field.
CARRY_RECORD = re.compile(
    r"<!--\s*approval-provenance:v1\s+origin=(?P<origin>[0-9a-fA-F]{40})\s+"
    r"before=(?P<before>[0-9a-fA-F]{40})\s+after=(?P<after>[0-9a-fA-F]{40})\s*-->"
)

NO_STARTING_POINT = "0000000000000000000000000000000000000000"


def short(revision: str) -> str:
    return revision[:12] if revision else "(none)"


def render(verdict: str, reason: str, origin: str, chain: list[str], head_approved: bool) -> int:
    print(f"provenance={verdict}")
    print(f"provenance_reason={reason}")
    print(f"origin={origin}")
    print(f"chain={','.join(chain)}")
    print(f"head_approved={'true' if head_approved else 'false'}")
    return 0


def load_feed(path: str) -> tuple[list[dict], str]:
    """The comments, flattened, or the reason they could not be read.

    Accepts one page or the list of pages ``gh api --paginate --slurp``
    writes. Anything that is not a list of comment objects is malformed, and a
    malformed feed is not an empty one: no comment in it can be trusted to be
    the whole story, so nothing in it proves anything.
    """
    if not path:
        return [], "no provenance feed was supplied"
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        return [], f"the provenance feed could not be read ({error.strerror or error})"
    try:
        document = json.loads(text)
    except ValueError:
        return [], "the provenance feed is not valid JSON"
    if not isinstance(document, list):
        return [], "the provenance feed is not a list of comments"
    comments: list[dict] = []
    pages = document if all(isinstance(item, list) for item in document) else [document]
    for page in pages:
        if not isinstance(page, list):
            return [], "the provenance feed is not a list of comments"
        for comment in page:
            if not isinstance(comment, dict):
                return [], "the provenance feed contains an entry that is not a comment"
            comments.append(comment)
    return comments, ""


def author_of(comment: dict) -> str:
    user = comment.get("user")
    login = user.get("login") if isinstance(user, dict) else None
    return login.casefold() if isinstance(login, str) else ""


def ordered(comments: list[dict]) -> list[dict]:
    """Oldest first, so a later verdict on the same head is the one that wins."""

    def key(comment: dict) -> tuple[str, int]:
        created = comment.get("created_at")
        identifier = comment.get("id")
        return (
            created if isinstance(created, str) else "",
            identifier if isinstance(identifier, int) else 0,
        )

    return sorted(comments, key=key)


def canonical_approvals(comments: list[dict], owner: str) -> set[str]:
    """Every head whose newest owner-authored review marker approves it."""
    verdicts: dict[str, str] = {}
    for comment in ordered(comments):
        if author_of(comment) != owner.casefold():
            continue
        body = comment.get("body")
        if not isinstance(body, str):
            continue
        for marker in REVIEW_MARKER.finditer(body):
            verdicts[marker.group("head").lower()] = marker.group("verdict")
    return {head for head, verdict in verdicts.items() if verdict == "APPROVE"}


def recorded_carries(comments: list[dict], recorder: str) -> dict[str, list[str]]:
    """Each pushed head, mapped to the starting points recorded as carried into it."""
    carries: dict[str, list[str]] = {}
    for comment in ordered(comments):
        if author_of(comment) != recorder.casefold():
            continue
        body = comment.get("body")
        if not isinstance(body, str):
            continue
        for record in CARRY_RECORD.finditer(body):
            after = record.group("after").lower()
            before = record.group("before").lower()
            if before not in carries.setdefault(after, []):
                carries[after].append(before)
    return carries


def prove(
    before: str, approvals: set[str], carries: dict[str, list[str]]
) -> tuple[str, list[str], str]:
    """Trace ``before`` back to a canonical approval through recorded carries.

    Returns the origin and the chain from it to ``before`` when one exists.
    Otherwise the origin is empty and the third field names the revision at
    which the trace ran out — the link that could not be proven.
    """
    pending = [(before, [before])]
    visited: set[str] = set()
    # The furthest revision the records reached without arriving anywhere:
    # that is the link a reader needs named, not the starting point it began at.
    dead_end, dead_end_depth = before, 0
    while pending:
        revision, path = pending.pop()
        if revision in approvals:
            return revision, list(reversed(path)), ""
        if revision in visited:
            continue
        visited.add(revision)
        previous = carries.get(revision, [])
        if not previous and len(path) > dead_end_depth:
            dead_end, dead_end_depth = revision, len(path)
        for earlier in previous:
            if earlier not in visited:
                pending.append((earlier, path + [earlier]))
    return "", [], dead_end


def decide(before: str, after: str, feed: str, owner: str, recorder: str) -> int:
    comments, failure = load_feed(feed)
    if failure:
        return render(UNPROVEN, f"{failure}, so no starting point can be proven approved", "", [], False)

    approvals = canonical_approvals(comments, owner)
    carries = recorded_carries(comments, recorder)
    head_approved = after.lower() in approvals

    if not before or before == NO_STARTING_POINT:
        return render(UNPROVEN, "the push named no starting point", "", [], head_approved)

    origin, chain, dead_end = prove(before.lower(), approvals, carries)
    if origin == before.lower():
        return render(
            PROVEN,
            f"a canonical review approved the starting point {short(before)} itself",
            origin,
            chain,
            head_approved,
        )
    if origin:
        hops = len(chain) - 1
        return render(
            PROVEN,
            f"the starting point {short(before)} was reached from the canonically approved "
            f"{short(origin)} through {hops} recorded carr{'y' if hops == 1 else 'ies'}",
            origin,
            chain,
            head_approved,
        )
    if dead_end == before.lower():
        reason = (
            f"the starting point {short(before)} has no canonical approval and no "
            "recorded carry leads into it"
        )
    else:
        reason = (
            f"the carry into {short(before)} is recorded, but it traces back to "
            f"{short(dead_end)}, which has no canonical approval and no recorded carry into it"
        )
    return render(UNPROVEN, reason, "", [], head_approved)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="review_provenance.py",
        description="Decide whether a push's starting point is a proven approved revision.",
    )
    parser.add_argument("--before", required=True, help="the head the push started from")
    parser.add_argument("--after", required=True, help="the head the push landed on")
    parser.add_argument(
        "--comments",
        required=True,
        help="a file holding the pull request's comment feed as GitHub returned it",
    )
    parser.add_argument(
        "--owner",
        required=True,
        help="the login whose review markers are canonical: the repository owner",
    )
    parser.add_argument(
        "--recorder",
        default=WORKFLOW_IDENTITY,
        help="the login that authors carry records: the workflow's own identity",
    )
    arguments = parser.parse_args(argv)
    return decide(
        arguments.before, arguments.after, arguments.comments, arguments.owner, arguments.recorder
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
