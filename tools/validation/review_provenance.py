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
  repository's own workflow identity by the mutation job that confirmed the
  label attached at the pushed head, naming the run and attempt that wrote it.
  A record is only as good as that job's conclusion: it is posted while the
  job is still running, so the proof verifies through the Actions jobs listing
  that the named attempt's ``dismiss-stale-approval`` concluded ``success`` at
  exactly the recorded head. A job that failed or was cancelled after posting,
  or that has not finished, leaves a record that proves nothing.

A ``before`` whose own decision was superseded, failed, cancelled, or never ran
is therefore unproven, however the trees compare. A revision whose newest
canonical verdict requests changes is a terminal denial: it is not approved,
and no recorded carry passes through it, until that exact revision is approved
again. A fresh canonical approval at any head is a new origin: it needs no
chain behind it and survives an earlier strip.

The feed and the jobs listings are read from files the caller fetched, so that
this decision is proven in tests against fixtures exactly as it runs in the
workflow. Evidence that is missing, unreadable, malformed, or incomplete
proves nothing — it is reported as ``unproven`` with the reason, never as
``proven`` from tree equality or replay eligibility, and never as a refusal
that would abort the workflow before the label removal it justifies.

**Every outcome this tool can reach is an answer, so it always exits 0.** Only a
usage error fails (exit 2, from ``argparse``). Output is ``key=value`` lines
safe to append to ``$GITHUB_OUTPUT``::

    provenance=proven|unproven
    provenance_reason=<one line saying why>
    origin=<the canonically approved revision the approval originates from, or empty>
    chain=<origin,...,before: every revision the carry passed through, or empty>
    head_verdict=approved|denied|none   what the newest canonical review of the pushed head itself said

A pushed head that was approved directly is its own origin: ``origin`` names
it and ``chain`` is empty, whatever the starting point would have proven,
because nothing is being carried.

``--list-runs`` instead prints one ``<run id> <attempt>`` line per run the
records name, so the caller can fetch exactly those jobs listings.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

PROVEN = "proven"
UNPROVEN = "unproven"

# The identity GitHub gives a workflow's own token. Every record the mutation
# job writes is authored by it, and nothing a person posts can be.
WORKFLOW_IDENTITY = "github-actions[bot]"

# The canonical coordinator's marker, and the drainer's own single-reviewer
# spelling that the same publisher may post in its place. Both name the exact
# head the verdict was reached for and a reviewer brand this pipeline knows;
# neither is taken from any other author. Anything the owner posts that opens
# like one of these and is not one is malformed evidence, which the proof
# refuses rather than reads past: a truncated withdrawal must not leave the
# approval it withdrew standing. Openings are recognised in any case, so a
# differently cased marker is refused rather than overlooked; the marker
# itself is matched exactly as the coordinator publishes it.
REVIEW_OPENING = re.compile(r"<!--\s*pr-review:v", re.IGNORECASE)
REVIEW_MARKER = re.compile(
    r"<!--\s*pr-review:v(?:2\s+reviewers=(?:claude|codex)(?:,(?:claude|codex))*\s+models=\S+"
    r"|1\s+reviewer=(?:claude|codex))\s+"
    r"head=(?P<head>[0-9a-fA-F]{40})\s+verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED)\s*-->"
)

# One record per carried push, written by `dismiss-stale-approval` after it
# confirmed the label attached at `after`, naming the run and attempt that
# wrote it. Its `origin` is the canonically approved revision that decision
# traced the carry back to; the proof below re-walks the links rather than
# trusting that field.
RECORD_OPENING = re.compile(r"<!--\s*approval-provenance:", re.IGNORECASE)
CARRY_RECORD = re.compile(
    r"<!--\s*approval-provenance:v1\s+origin=(?P<origin>[0-9a-fA-F]{40})\s+"
    r"before=(?P<before>[0-9a-fA-F]{40})\s+after=(?P<after>[0-9a-fA-F]{40})\s+"
    r"run=(?P<run>[0-9]+)\s+attempt=(?P<attempt>[0-9]+)\s*-->"
)

# The job whose successful conclusion a record depends on, in the workflow
# that writes it.
RECORDING_JOB = "dismiss-stale-approval"
RECORDING_WORKFLOW = "review-gate"

NO_STARTING_POINT = "0000000000000000000000000000000000000000"


def short(revision: str) -> str:
    return revision[:12] if revision else "(none)"


HEAD_VERDICTS = {"APPROVE": "approved", "CHANGES_REQUESTED": "denied"}


def render(verdict: str, reason: str, origin: str, chain: list[str], head_verdict: str) -> int:
    print(f"provenance={verdict}")
    print(f"provenance_reason={reason}")
    print(f"origin={origin}")
    print(f"chain={','.join(chain)}")
    print(f"head_verdict={head_verdict}")
    return 0


# What every comment has to carry before anything in the feed is believed:
# its identity and timestamp, which order it against the others; its author,
# which decides whether it may say anything at all; and its body.
COMMENT_FIELDS = ("id", "created_at", "user", "body")

# The one timestamp shape GitHub writes. Requiring it exactly is what makes
# the string comparison in `ordered` a chronological one: an empty or
# differently written timestamp would sort somewhere it does not belong, and
# so would a well-shaped one naming no real instant, which is why the value
# also has to parse and print back unchanged.
TIMESTAMP = "%Y-%m-%dT%H:%M:%SZ"


def real_timestamp(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return datetime.strptime(value, TIMESTAMP).strftime(TIMESTAMP) == value
    except ValueError:
        return False


def incomplete(comment: dict) -> str:
    """Which required field a comment lacks or cannot be used, or empty."""
    for name in COMMENT_FIELDS:
        if name not in comment:
            return name
    identifier = comment["id"]
    # A boolean is an int to Python and an identifier to nobody.
    if isinstance(identifier, bool) or not isinstance(identifier, int) or identifier <= 0:
        return "id"
    if not real_timestamp(comment["created_at"]):
        return "created_at"
    user = comment["user"]
    login = user.get("login") if isinstance(user, dict) else None
    if not isinstance(login, str) or not login.strip():
        return "user.login"
    if not isinstance(comment["body"], str):
        return "body"
    return ""


def load_feed(path: str) -> tuple[list[dict], str]:
    """The comments, flattened, or the reason they could not be read.

    Accepts one page or the list of pages ``gh api --paginate --slurp``
    writes. Anything that is not a list of comment objects is malformed, and
    so is a comment missing a field the proof needs: a marker that cannot be
    ordered could be taken for older than the verdict it withdrew, and one
    that cannot be attributed could be taken for the owner's. An incomplete
    feed is not an empty one — no comment in it can be trusted to be the
    whole story, so nothing in it proves anything.
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
            missing = incomplete(comment)
            if missing:
                return [], f"the provenance feed contains a comment without a usable {missing}"
            comments.append(comment)
    return comments, ""


def author_of(comment: dict) -> str:
    return comment["user"]["login"].casefold()


def ordered(comments: list[dict]) -> list[dict]:
    """Oldest first, so a later verdict on the same head is the one that wins.

    Every comment carries both keys: ``load_feed`` refused the feed otherwise.
    """
    return sorted(comments, key=lambda comment: (comment["created_at"], comment["id"]))


def malformed_evidence(comments: list[dict], owner: str, recorder: str) -> str:
    """Why the feed's evidence cannot be read at all, or empty when it can.

    Every comment the owner posts that opens like a review marker has to be
    exactly one canonical marker, and every comment the workflow posts that
    opens like a carry record has to be exactly one canonical record. One that
    is truncated, misspelled, names a reviewer this pipeline does not know, or
    carries two of them is not skipped: skipping a malformed withdrawal would
    leave the approval it withdrew authoritative. Prose that merely mentions a
    marker's name opens nothing and is not evidence either way.
    """
    for comment in comments:
        author, body = author_of(comment), comment["body"]
        if author == owner.casefold():
            openings = len(REVIEW_OPENING.findall(body))
            markers = len(REVIEW_MARKER.findall(body))
            if openings != markers or markers > 1:
                return f"comment {comment['id']} by the owner carries a malformed or duplicated review marker"
        if author == recorder.casefold():
            openings = len(RECORD_OPENING.findall(body))
            records = len(CARRY_RECORD.findall(body))
            if openings != records or records > 1:
                return f"comment {comment['id']} by the workflow carries a malformed or duplicated carry record"
    return ""


def canonical_verdicts(comments: list[dict], owner: str) -> dict[str, str]:
    """Each head's newest owner-authored review verdict."""
    verdicts: dict[str, str] = {}
    for comment in ordered(comments):
        if author_of(comment) != owner.casefold():
            continue
        for marker in REVIEW_MARKER.finditer(comment["body"]):
            verdicts[marker.group("head").lower()] = marker.group("verdict")
    return verdicts


def records_by(comments: list[dict], recorder: str) -> list[re.Match[str]]:
    """Every carry record the workflow identity posted, oldest first."""
    records: list[re.Match[str]] = []
    for comment in ordered(comments):
        if author_of(comment) != recorder.casefold():
            continue
        records.extend(CARRY_RECORD.finditer(comment["body"]))
    return records


def recording_succeeded(record: re.Match[str], runs: str) -> str:
    """Why the run a record names does not vouch for it, or empty if it does.

    The jobs listing for that run attempt is a file the caller fetched. It
    has to show this workflow's mutation job concluded ``success`` at exactly
    the recorded head; a listing that is missing, malformed, or shows
    anything else — a failure, a cancellation, a job still running — leaves
    the record unusable, because the record was posted before that job
    reached its conclusion.
    """
    run, attempt, after = record.group("run"), record.group("attempt"), record.group("after").lower()
    where = f"run {run} attempt {attempt}"
    if not runs:
        return f"the jobs of {where} were not fetched, so the record cannot be verified"
    try:
        document = json.loads(Path(runs, f"{run}-{attempt}.json").read_text(encoding="utf-8"))
    except OSError:
        return f"the jobs of {where} could not be read, so the record cannot be verified"
    except ValueError:
        return f"the jobs listing of {where} is not valid JSON"
    jobs = document.get("jobs") if isinstance(document, dict) else None
    if not isinstance(jobs, list):
        return f"the jobs listing of {where} names no jobs"
    for job in jobs:
        if not isinstance(job, dict) or job.get("name") != RECORDING_JOB:
            continue
        if job.get("workflow_name") != RECORDING_WORKFLOW:
            return f"{where} is not a {RECORDING_WORKFLOW} run"
        if str(job.get("run_attempt", attempt)) != attempt:
            return f"the jobs listing of {where} is for another attempt"
        head = job.get("head_sha")
        if not isinstance(head, str) or head.lower() != after:
            return f"{where} ran for another head than the recorded {short(after)}"
        conclusion = job.get("conclusion")
        if conclusion != "success":
            state = conclusion if isinstance(conclusion, str) and conclusion else "unfinished"
            return f"{RECORDING_JOB} in {where} was {state}, not success"
        return ""
    return f"{where} has no {RECORDING_JOB} job"


def recorded_carries(
    comments: list[dict], recorder: str, runs: str
) -> tuple[dict[str, list[str]], dict[str, str]]:
    """Each pushed head, mapped to the starting points verifiably carried into it.

    The second result explains, per pushed head, why a record into it could
    not be used — the reason a reader needs when that head is where a proof
    ran out.
    """
    carries: dict[str, list[str]] = {}
    unusable: dict[str, str] = {}
    for record in records_by(comments, recorder):
        after = record.group("after").lower()
        before = record.group("before").lower()
        failure = recording_succeeded(record, runs)
        if failure:
            unusable.setdefault(after, failure)
        elif before not in carries.setdefault(after, []):
            carries[after].append(before)
    return carries, unusable


def prove(
    before: str, verdicts: dict[str, str], carries: dict[str, list[str]]
) -> tuple[str, list[str], str]:
    """Trace ``before`` back to a canonical approval through recorded carries.

    Returns the origin and the chain from it to ``before`` when one exists.
    Otherwise the origin is empty and the third field names the revision at
    which the trace ran out — the link that could not be proven. A revision
    whose newest verdict requests changes is such a link: the denial is
    terminal, and no carry recorded into it is followed.
    """
    pending = [(before, [before])]
    visited: set[str] = set()
    # The furthest revision the records reached without arriving anywhere:
    # that is the link a reader needs named, not the starting point it began at.
    dead_end, dead_end_depth = before, 0
    while pending:
        revision, path = pending.pop()
        if verdicts.get(revision) == "APPROVE":
            return revision, list(reversed(path)), ""
        if revision in visited:
            continue
        visited.add(revision)
        previous = [] if revision in verdicts else carries.get(revision, [])
        if not previous and len(path) > dead_end_depth:
            dead_end, dead_end_depth = revision, len(path)
        for earlier in previous:
            if earlier not in visited:
                pending.append((earlier, path + [earlier]))
    return "", [], dead_end


def explain(revision: str, before: str, verdicts: dict[str, str], unusable: dict[str, str]) -> str:
    """Why the trace ran out at ``revision``."""
    if verdicts.get(revision) == "CHANGES_REQUESTED":
        what = "its newest canonical review requested changes"
    elif revision in unusable:
        what = f"the carry recorded into it cannot be trusted: {unusable[revision]}"
    else:
        what = "it has no canonical approval and no verified carry leads into it"
    if revision == before:
        return f"the starting point {short(before)} is not a proven approved revision: {what}"
    return (
        f"the carry into {short(before)} is recorded, but it traces back to "
        f"{short(revision)}, and {what}"
    )


def list_runs(feed: str, recorder: str) -> int:
    comments, failure = load_feed(feed)
    if failure or malformed_evidence(comments, "", recorder):
        return 0
    seen: set[tuple[str, str]] = set()
    for record in records_by(comments, recorder):
        key = (record.group("run"), record.group("attempt"))
        if key not in seen:
            seen.add(key)
            print(f"{key[0]} {key[1]}")
    return 0


def decide(before: str, after: str, feed: str, runs: str, owner: str, recorder: str) -> int:
    comments, failure = load_feed(feed)
    if failure:
        return render(UNPROVEN, f"{failure}, so no starting point can be proven approved", "", [], "none")

    failure = malformed_evidence(comments, owner, recorder)
    if failure:
        return render(UNPROVEN, f"{failure}, so no starting point can be proven approved", "", [], "none")

    verdicts = canonical_verdicts(comments, owner)
    carries, unusable = recorded_carries(comments, recorder, runs)
    # Tri-state on purpose: a denial of the pushed head is not the absence of
    # an approval of it. The gate strips on a denial whatever the starting
    # point proves, and keeps on an approval whatever it fails to prove.
    head_verdict = HEAD_VERDICTS.get(verdicts.get(after.lower(), ""), "none")

    if not before or before == NO_STARTING_POINT:
        verdict, reason = UNPROVEN, "the push named no starting point"
        origin, chain = "", []
    else:
        origin, chain, dead_end = prove(before.lower(), verdicts, carries)
        if origin == before.lower():
            verdict = PROVEN
            reason = f"a canonical review approved the starting point {short(before)} itself"
        elif origin:
            hops = len(chain) - 1
            verdict = PROVEN
            reason = (
                f"the starting point {short(before)} was reached from the canonically approved "
                f"{short(origin)} through {hops} recorded carr{'y' if hops == 1 else 'ies'}"
            )
        else:
            verdict = UNPROVEN
            reason = explain(dead_end, before.lower(), verdicts, unusable)

    if head_verdict == "approved":
        # Nothing is carried into a head a reviewer approved in its own right:
        # it is the origin, whatever the starting point would have been.
        origin, chain = after.lower(), []
    return render(verdict, reason, origin, chain, head_verdict)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="review_provenance.py",
        description="Decide whether a push's starting point is a proven approved revision.",
    )
    parser.add_argument("--before", default="", help="the head the push started from")
    parser.add_argument("--after", default="", help="the head the push landed on")
    parser.add_argument(
        "--comments",
        required=True,
        help="a file holding the pull request's comment feed as GitHub returned it",
    )
    parser.add_argument(
        "--runs",
        default="",
        help="a directory holding each recorded run attempt's jobs listing as <run>-<attempt>.json",
    )
    parser.add_argument(
        "--list-runs",
        action="store_true",
        help="print the run attempts the records name, one per line, instead of deciding",
    )
    parser.add_argument(
        "--owner",
        default="",
        help="the login whose review markers are canonical: the repository owner",
    )
    parser.add_argument(
        "--recorder",
        default=WORKFLOW_IDENTITY,
        help="the login that authors carry records: the workflow's own identity",
    )
    arguments = parser.parse_args(argv)
    if arguments.list_runs:
        return list_runs(arguments.comments, arguments.recorder)
    for name in ("before", "after", "owner"):
        if not getattr(arguments, name):
            parser.error(f"--{name} is required to decide")
    return decide(
        arguments.before,
        arguments.after,
        arguments.comments,
        arguments.runs,
        arguments.owner,
        arguments.recorder,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
