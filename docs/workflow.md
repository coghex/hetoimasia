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
Local standalone design work uses a `docs-wip` worktree. There is no CI or
configured per-repository drainer yet.
Installed plugins being available in a conversation does not establish readiness
of a future CLI session or repository service.

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

This describes the intended workflow, not an installed per-repository service.
Per-repository service installation remains a separate setup task.

## Worktrees and documentation

After the initial commit, keep the primary checkout clean and implement in
isolated worktrees. Resolve an existing docs worktree by its `docs-wip` branch.
Standalone design/report work may accumulate there. Documentation accompanying
code belongs in the code worktree and PR, regardless of its extension.

No `tools/docs_land.sh` exists here. Do not use another project's helper against
this repository. A future standalone-doc publication policy/helper must be
established before relying on `$push-docs`.

## Local checks

Use `cabal build all`, the console smoke, and the focused `hetoimasia-tests`
Hspec suite for the current bootstrap. Prefer Hspec for future integration and
resource tests too; use Python probes only where Hspec cannot reasonably exercise
the boundary. Run `cabal check` in the root and each active
package directory when editing package metadata. Vulkan validation, offscreen
captures, and meaningful performance workloads arrive with rendering.
