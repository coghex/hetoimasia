"""What a pull request asks of the planner, and the rules it is held to.

A pull request body may carry one ``validation-request`` block naming optional
groups to run. A pull-request range is also held to the contribution rules,
which refuse a change for what it touches regardless of any request. See
``docs/validation.md`` for the request block and the MEMORY.md rule.
"""

from __future__ import annotations

import re

from plan_repository import PlannerError

REQUEST_FENCE = "validation-request"
ALL_HSPEC = "all-hspec"


# --------------------------------------------------------------------------
# Requests


def parse_request(text: str, source: str) -> tuple[list[str], bool]:
    """Read the ``validation-request`` fenced block from a PR body.

    Fence nesting is honoured: a ``validation-request`` example shown inside an
    outer fenced block is documentation, not a request. A fence whose info
    string starts with the reserved word but carries anything else is a
    malformed request rather than a block to ignore.
    """
    opener = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
    blocks: list[list[str]] = []
    body: list[str] = []
    fence = ""
    collecting = False
    for line in text.splitlines():
        match = opener.match(line.rstrip())
        if fence:
            closes = (
                match is not None
                and match.group(1)[0] == fence[0]
                and len(match.group(1)) >= len(fence)
                and not match.group(2).strip()
            )
            if closes:
                if collecting:
                    blocks.append(body)
                    body, collecting = [], False
                fence = ""
            elif collecting:
                body.append(line.strip())
            continue
        if match is None:
            continue
        fence = match.group(1)
        info = match.group(2).strip()
        if info.split()[0:1] == [REQUEST_FENCE]:
            if info != REQUEST_FENCE:
                raise PlannerError(
                    f"{source}: malformed validation-request info string {info!r}; "
                    f"the fence takes the bare word {REQUEST_FENCE!r}"
                )
            collecting = True

    if collecting:
        raise PlannerError(f"{source}: the validation-request block is never closed")
    if not blocks:
        return [], False
    if len(blocks) > 1:
        raise PlannerError(f"{source}: more than one validation-request block; the request is ambiguous")

    identifiers: list[str] = []
    all_hspec = False
    for entry in blocks[0]:
        if not entry:
            continue
        if len(entry.split()) > 1:
            raise PlannerError(f"{source}: malformed request line {entry!r}; use one catalog ID per line")
        if entry == ALL_HSPEC:
            all_hspec = True
        elif entry not in identifiers:
            identifiers.append(entry)
    return identifiers, all_hspec


# --------------------------------------------------------------------------
# Contribution rules
#
# Selection never refuses a change for what it touches; these rules do, and
# only for a pull request. A push has already landed — a documentation landing
# through `tools/docs_land.sh`, or a pull request's merge commit — so failing it
# would report a verdict nobody can act on. The rules have no override: no
# request entry, label, or environment variable reaches them.

MEMORY_FILE = "MEMORY.md"


def memory_rule(changes: list[dict]) -> str | None:
    """Refuse a pull request that changes the root MEMORY.md beside anything but Markdown.

    Both endpoints of a rename are in ``changes``, so renaming MEMORY.md away,
    renaming another file onto it, and renaming it to a path that is not
    Markdown all count as changing it.
    """
    paths = [change["path"] for change in changes]
    if MEMORY_FILE not in paths:
        return None
    others = [path for path in paths if not path.endswith(".md")]
    if not others:
        return None
    return (
        f"the MEMORY.md rule refuses this pull request: it changes {MEMORY_FILE} together with "
        f"non-Markdown files ({', '.join(others)}). Implementation pull requests do not edit "
        f"{MEMORY_FILE}. Drop the {MEMORY_FILE} edit, and record status in the pull request body "
        f"and the owning subsystem document instead; an owner-requested {MEMORY_FILE} change "
        "belongs in a standalone Markdown-only change"
    )
