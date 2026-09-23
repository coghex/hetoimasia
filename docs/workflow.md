# Development through Kanban

The workflow application lives at `~/work/kanban`. Issues and PRs for this
project belong to [coghex/hetoimasia](https://github.com/coghex/hetoimasia).
The installed Kanban
skills own readiness checks, claims, isolated solving, and opposite-agent review.
Use them from interactive CLI sessions as the owner requests.

## Current status

The owner authorized the initial bootstrap on `master`. `origin` is
`https://github.com/coghex/hetoimasia.git`, matching the local project name.
The owner corrected the repository-name typo during setup; the new target was empty.
Local standalone design work uses a `docs-wip` worktree.
GitHub Actions runs the validation pipeline described in
[validation.md](validation.md): `plan` resolves the candidate's groups,
`haskell-engine`, `haskell-workflow`, and `glfw-native` execute the selected ones, and
`build-test` publishes the aggregate verdict, alongside `review-approved` and
its `dismiss-stale-approval` job from the review gate. A ruleset on `master`
requires `build-test` and `review-approved` and requires branches to be up to
date before merging.
An approval survives a push only from a proven approved revision — the head a
canonical review named, or one reached from it through carries the review gate
itself recorded — and only when the push is an identical-tree re-push of that
revision or exactly Git's clean merge of it with a commit `master` already
contains: any other push to a reviewed candidate needs a fresh review, a fresh
canonical approval of the pushed head always stands, and a canonical denial of
it always strips. CI is independent of
that — the affected groups still run on the integrated head, and approval alone
never makes them green. [validation.md](validation.md) documents the rule.
The issue-approval service and PR drainer were installed for this repository
on the owner's machine on 2026-09-10. That installation record does not establish
their current running state; inspect the board or installed controllers when
operating the pipeline. GLFW PRs #101–#114 are merged; completion-review
repairs #115–#118 also merged through PRs #119–#122. Current follow-ups belong
in their reports and the tracker, not this historical bootstrap inventory.
Installed plugins being available in a conversation does not establish readiness
of a future CLI session or repository service.

On 2026-09-10 Kanban's `--doctor` passed against this checkout for all issue
review/revision, solve, auto-solve, and PR review/revision/repair actions. Both
CLI providers and GitHub were authenticated, both Kanban plugins were enabled,
and the shared review backend was present. The canonical setup tool reported
all three components unchanged; no reinstall was necessary. Re-run the doctor
when diagnosing future sessions.

## Launching the board

From the Kanban checkout, in the owner's terminal:

```sh
cd ~/work/kanban
cabal run kanban -- --path ~/work/hetoimasia
```

Read-only workflow preflight:

```sh
cd ~/work/kanban
cabal run kanban -- --path ~/work/hetoimasia --doctor
```

These commands require a usable target checkout and GitHub identity. For setup
or a missing workflow component, consult Kanban's own `docs/workflow-setup.md`;
use its tracked setup tools instead of copying scripts or personal skills here.
Select the owner's intended CLI launch/provider settings in Kanban; the scaffold
does not install plugins, launch agent windows, or start background services.

## Delivery sequence

1. Refine a bounded design with `kanban:design-epic` / `$design-epic` when needed.
2. Process it one tracker artifact at a time with `kanban:process-design-doc`,
   or draft a standalone task with `kanban:issue` / `kanban:autoissue`.
3. Use `kanban:issue-review` for the canonical readiness gate.
4. Use `kanban:solve` or `kanban:autosolve` in an isolated worktree. Keep code,
   required documentation, and evidence together. Honor the effective issue spec.
5. Follow canonical PR review/revision. Preserve the origin marker required by
   the installed workflow; do not manually substitute a label for approval.
6. Let the configured drainer merge eligible PRs. The `kanban:finalize` fallback
   is only for an explicit request meeting that workflow's requirements.

The service installations are local machine state, separate from the tracked
repository and CLI plugins. Kanban's board uses `a` to start/stop issue approval
and `d` to start/stop the PR drainer. Installing either starts no review or merge.
An approval service that has never run can report `unknown` with no status
document; its installed launchd job is still present and not running.

To reproduce the service installation on another machine, first install the
shared components using Kanban's setup guide, then run from `~/work/kanban`:

```sh
python3 tools/install_issue_approval.py --repo ~/work/hetoimasia --dry-run --json
python3 tools/install_drainer.py --repo ~/work/hetoimasia --dry-run --json
```

After inspecting the plans, remove `--dry-run` to install the stopped jobs.
For lifecycle operations use the installed controllers or Kanban's sidebar;
the installed `kanban:drain-prs` skill owns drainer control. Always target
`coghex/hetoimasia` and its primary checkout.

## Worktrees and documentation

After the initial commit, keep the primary checkout clean and implement in
isolated worktrees. Resolve an existing docs worktree by its `docs-wip` branch.
Standalone design/report work may accumulate there. Documentation accompanying
code belongs in the code worktree and PR, regardless of its extension.

The repository vendors `tools/docs_land.sh` and its Python path checker from
Kanban; [the provenance and local adaptation](../tools/README.md) are tracked
with them. `AGENTS.md` remains a regular authoritative document; `CLAUDE.md`
continues to direct Claude sessions to it.

After the owner requests standalone documentation publication, use the installed
`kanban:push-docs` skill. The helper resolves `docs-wip` and `master` by branch,
lands only named Markdown paths, verifies publication to `origin/master`, and
fast-forwards the clean primary checkout. A refusal or warning needs resolution
before publication. For inspection from the primary checkout:

```sh
tools/docs_land.sh -h
tools/docs_land.sh -l
tools/docs_land.sh -n -m "docs: describe the selected change" docs/example_design.md
```

The last command illustrates a selection; replace the example path with the
actual approved document. Remove `-n` only after the dry run succeeds.
The helper accepts Markdown paths when no publication classification contract
exists, as here; callers must still enforce the standalone-task boundary.

Design-processing and report helpers ship inside the plugins. Locate those
installed copies as the skills instruct; do not expect copies in this project's
`tools/` directory. No unattended document-publication path is configured here;
approved ledger changes can accumulate in `docs-wip` for a requested batch landing.

## Local checks

Use `cabal build all`, the console smoke, and the focused
`hetoimasia-foundation:foundation-tests`, `hetoimasia-runtime:runtime-tests`,
`hetoimasia-glfw:glfw-tests`, `hetoimasia-scripting-lua:lua-host-tests`,
`hetoimasia-gpu-vulkan-model:gpu-model-tests`, and `hetoimasia-tests` Hspec suites for
the current bootstrap. Prefer Hspec for future integration and
resource tests too; use Python probes only where Hspec cannot reasonably exercise
the boundary. Run `cabal check` in the root and each active
package directory when editing package metadata. Vulkan validation, offscreen
captures, and meaningful performance workloads arrive with rendering.

For changes to the documentation landing integration or the validation
planner, run `cabal test workflow-tests --test-show-details=direct`. These Hspec
checks use temporary Git repositories and a local bare origin, without GitHub
access.

The X11 and Wayland helper deadline checks, Lua nontermination experiment,
and both confinement feasibility suites are local-only optional probes.
Do not request them in CI or run them merely because their inputs changed.
[Test classification](test_classification.md) records the suite inventory and
how `$test`/`$autotest` can select them occasionally.

To find out which of those checks a change actually requires, run
`python3 tools/validation/plan.py --base origin/master --head HEAD`. It needs
Python 3 and Git only, and explains every group it selects or omits.
[validation.md](validation.md) documents the catalog, the mandatory floor, and
the `validation-request` block a pull request uses to ask for more.
