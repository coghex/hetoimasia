#!/usr/bin/env python3
"""Report where a validation run's wall time actually went.

CI wall time is the metric this pipeline optimizes, and a single total hides
which part to act on: waiting for a runner, provisioning the toolchain, and
executing the selected groups have different remedies. This reads one workflow
run attempt's job listing — as returned by
``gh api repos/OWNER/REPO/actions/runs/ID/attempts/N/jobs`` — and renders queue,
setup, and execution time per job.

It never decides a verdict. A job whose timings are unavailable is reported as
unavailable; that is a reporting gap, not a result.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime

# The step GitHub inserts before a job's own steps. Its duration is the
# provisioning cost that neither queueing nor the job's own work explains.
SETUP_STEP = "Set up job"

UNAVAILABLE = "—"


def moment(value) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def span(start, end) -> float | None:
    first, last = moment(start), moment(end)
    if first is None or last is None:
        return None
    return max((last - first).total_seconds(), 0.0)


def render(seconds: float | None) -> str:
    if seconds is None:
        return UNAVAILABLE
    if seconds < 60:
        return f"{seconds:.0f}s"
    minutes, remainder = divmod(int(round(seconds)), 60)
    return f"{minutes}m{remainder:02d}s"


def setup_seconds(job: dict) -> float | None:
    for step in job.get("steps") or []:
        if isinstance(step, dict) and step.get("name") == SETUP_STEP:
            return span(step.get("started_at"), step.get("completed_at"))
    return None


def job_rows(document: dict) -> list[list[str]]:
    rows: list[list[str]] = []
    for job in document.get("jobs") or []:
        if not isinstance(job, dict):
            continue
        queued = span(job.get("created_at"), job.get("started_at"))
        setup = setup_seconds(job)
        total = span(job.get("created_at"), job.get("completed_at"))
        ran = span(job.get("started_at"), job.get("completed_at"))
        execution = None if ran is None else max(ran - (setup or 0.0), 0.0)
        rows.append(
            [
                str(job.get("name") or "?"),
                str(job.get("conclusion") or job.get("status") or "?"),
                render(queued),
                render(setup),
                render(execution),
                render(total),
            ]
        )
    return rows


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="timings.py",
        description="Render per-job queue, setup, and execution timings for one workflow run.",
    )
    parser.add_argument("--jobs", required=True, help="a file holding the run attempt's job listing")
    parser.add_argument("--summary", help="a Markdown file the table is appended to")
    arguments = parser.parse_args(argv)

    try:
        with open(arguments.jobs, "rb") as handle:
            document = json.loads(handle.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        print(f"error: cannot read the job listing {arguments.jobs}: {error}", file=sys.stderr)
        return 2
    if not isinstance(document, dict):
        print(f"error: the job listing {arguments.jobs} is not a JSON object", file=sys.stderr)
        return 2

    rows = job_rows(document)
    headers = ["Job", "Result", "Queued", "Setup", "Execution", "Total"]
    lines = ["## Run timings", "", "| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    lines += ["| " + " | ".join(row) + " |" for row in rows]
    lines.append("")
    table = "\n".join(lines)
    print(table)
    if arguments.summary:
        try:
            with open(arguments.summary, "a", encoding="utf-8") as handle:
                handle.write(table)
        except OSError as error:
            print(f"error: cannot write the summary {arguments.summary}: {error}", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
