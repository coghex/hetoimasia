#!/usr/bin/env python3
"""Install the small Hetoimasia skill routes; preserve Synarchy and other repos.

Explicit --apply only. Back up each replaced file beside it before mutation.
The repo README owns the lab contract; skills never copy its selector or writer.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re

FLAKE = '''---
name: flake
description: "Run a coordinated flake measurement, inspect retained evidence, or manage probe deferrals. Supports Synarchy and Hetoimasia; Hetoimasia can investigate optional probes and Hspec examples and propose missing reproducers when useful existing work is exhausted. Do not use for ordinary one-shot test execution or playtesting."
---

# Operate the Flake Lab

Resolve the actual Git repository and read its AGENTS.md before acting. Keep the
primary checkout clean. Repository tools own selection, claims and history.

- **Synarchy:** read [the existing Synarchy workflow](references/synarchy.md)
  in full and follow it. Its census and measurement contract are unchanged.
- **Hetoimasia:** read `tools/flake/README.md` in that repository and use the
  workflow below. If the lab is absent at that checkout, report it unavailable;
  never run Synarchy's tools against another repository or silently test stale code.
- Other repositories: report that no adapter is installed. Do not infer a
  compatible lab from similarly named scripts.

## Hetoimasia

Activate its qualified toolchain. With no narrower request, run exactly one
`python3 tools/flake/lab.py run`. The tool refreshes upstream, selects a workload,
uses a pinned detached build, records every trial, and updates the coordinator.
An explicitly requested candidate uses `--ref REV`; state clearly that it is
candidate evidence. An explicit registered probe can use `--probe ID` but cannot
bypass deferral, platform or consent. Do not repeat a batch to obtain a pass.

For status, deferral, resumption, local Hspec registration, proposal disposition
and evidence export, use the README's matching lab commands. Never hand-edit the
SQLite database or generated coordinator page. Native desktop tests need explicit
human approval for the described disruption before using per-run `--desktop`.

Read the final result and relevant logs. Distinguish completed measurement,
assertion failures, timeouts, crashes, incomplete evidence and harness blockers;
none alone establishes a production bug. Report the probe, exact commit/build,
counts, limitations, result path and coordinator path. This workflow measures;
it does not fix production code, create issues/PRs or invoke a review pipeline.

When no useful existing candidate remains, inspect skipped reasons and pending
proposals. Busy/deferred/wrong-platform work is not a coverage gap. If a distinct
valuable gap exists, record one proposal through `lab.py propose` with a stable
id, source revision, question, evidence of the gap, scenario, oracle, tier and
cost. Present it for approval and stop. Do not duplicate an open proposal or
silently implement a new probe. A proposed Hspec reproducer should reuse its
existing assertion where possible; Python owns repetition and process isolation.
'''

TEST_ROUTE = '''## Hetoimasia repository adapter

For Hetoimasia, read `tools/flake/README.md` and use its shared coordinator
**instead of the generic coordinator workflow below**. The repository adapter
owns selection, claims, pinned worktrees, execution and recording. Run one
`python3 tools/flake/lab.py run --mode test`; an explicitly requested revision
uses `--ref REV`. Test mode selects optional probes only. CI-covered Hspec
investigations belong to `$flake`, even if they use the same executable.

Read its final result and relevant logs, then return the exact revision,
execution outcome, interpreted observations/limitations, and the final result
and coordinator paths. A recorded run is the adapter's standard result artifact;
do not also create a generic registry claim or a second worktree/report. Respect
shared deferrals and obtain explicit session consent before any desktop run.

On no-candidate, inspect exclusions and pending proposals. If useful existing
work is exhausted and a distinct coverage gap is verified, record one proposal
with the README's `lab.py propose` command, present all its fields for approval,
and stop. Do not duplicate an open proposal, run a CI test, or implement a new
probe without authorization. A busy or unavailable environment is not itself a
missing-test proposal. If this checkout lacks the adapter, report that fact;
never silently substitute a different repository's lab.
'''

AUTO_ROUTE = '''## Hetoimasia result adapter

In Hetoimasia, `$test` uses the repository's shared test/flake lab. Its completed
handoff names a recorded run and final `result.json`, rather than a generic
`*.test-result.md`. Count a terminal recorded run with its interpretation as one
iteration; a busy/no-candidate result or a new-probe proposal counts as zero.
Apply the same stopping rules below: a proposal pauses for approval, and a
blocker stops unless the documented independent-work exception applies. Keep
iterations serial and delegate selection to `$test`; never add a separate probe
selector or registry. Other repositories keep the existing artifact contract.
'''


def add_route(text, route, marker):
    block = f"<!-- {marker}:start -->\n{route}\n<!-- {marker}:end -->"
    pattern = rf"<!-- {marker}:start -->.*?<!-- {marker}:end -->"
    if re.search(pattern, text, re.S):
        return re.sub(pattern, lambda _: block, text, flags=re.S)
    # Keep frontmatter and all existing workflow text intact.
    front = text.find("\n---", 3)
    if not text.startswith("---\n") or front < 0:
        raise ValueError("skill has no YAML frontmatter")
    offset = front + len("\n---")
    return text[:offset] + "\n\n" + block + text[offset:]


def write(path, text, apply):
    previous = path.read_text() if path.exists() else None
    if previous == text:
        return
    print(path)
    if apply:
        path.parent.mkdir(parents=True, exist_ok=True)
        if previous is not None:
            sha = hashlib.sha256(previous.encode()).hexdigest()[:12]
            backup = path.with_name(path.name + ".before-hetoimasia-" + sha)
            if not backup.exists():
                backup.write_text(previous)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(text)
        temporary.replace(path)


def install(root, apply):
    flake = root / "flake/SKILL.md"
    original = flake.read_text()
    reference = root / "flake/references/synarchy.md"
    if "references/synarchy.md" not in original:
        if not all(term in original for term in ("Synarchy", "tools/probe_census.py", "tools/deflake.py")):
            raise ValueError("unrecognized flake skill; preserve it and review the integration manually")
        if reference.exists() and reference.read_text() != original:
            raise ValueError("existing Synarchy reference differs; preserve it")
        write(reference, original, apply)
    elif not reference.exists():
        raise ValueError("Synarchy reference is missing")
    write(flake, FLAKE, apply)
    for skill, route in [("test", TEST_ROUTE), ("autotest", AUTO_ROUTE)]:
        path = root / skill / "SKILL.md"
        write(path, add_route(path.read_text(), route, "hetoimasia-lab"), apply)
    metadata = root / "flake/agents/openai.yaml"
    if metadata.exists():
        text = metadata.read_text().replace('short_description: "Run and manage the Synarchy de-flake lab"',
                                            'short_description: "Measure and track flaky tests across supported repositories"')
        text = text.replace('default_prompt: "Use $flake to run the next eligible Synarchy flake census measurement."',
                            'default_prompt: "Use $flake to run the next eligible measurement in this repository and retain the evidence."')
        write(metadata, text, apply)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skills-root", type=Path, default=Path.home() / ".codex/skills")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    install(args.skills_root, args.apply)


if __name__ == "__main__":
    main()
