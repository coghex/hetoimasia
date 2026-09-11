# Kanban repository support

`docs_land.sh` and `docs_land_paths.py` are vendored from
`coghex/kanban` at commit
`427b0ae19f5e6e3edab1b6456024db15d7a7e35f`.
Their upstream MIT notice is retained in [KANBAN-LICENSE](KANBAN-LICENSE).
Hetoimasia's engine remains GPL-3.0-only.

Local adaptations are limited to the suggested worktree path and support for
Hetoimasia's regular, authoritative `AGENTS.md`. Existing `AGENTS.md` symlinks
still require upstream's alias integrity checks, including staged replacement
and publication-tip checks. Git publication, reconciliation, selected-path
isolation, and reachability verification remain upstream behavior.

The scripts require Bash, Python 3, Git, `origin/master`, and registered
`master` and `docs-wip` worktrees. Use the installed `kanban:push-docs` skill
after the owner requests publication; inspect help, inventory, and the dry run
before landing. They are for standalone documentation only. Documentation
required by implementation belongs in that implementation's PR.

Shared review backends and the CLI plugins are installed from Kanban's
`tools/setup_workflows.py`; they are not duplicated here. Managed services
have separate installers and remain opt-in.

Run the local Hspec integration checks with:

```sh
cabal test workflow-tests --test-show-details=direct
```

The checks exercise the real scripts with temporary Git repositories and a
local bare origin. They require no GitHub authentication or network access.
When updating the vendor copy, also run Kanban's existing `test_docs_land.py`
behavioral cases against these files; its plugin-asset checks belong upstream.

Setup validation on 2026-09-10: all three local Hspec cases passed; the upstream
behavioral suite ran 90 cases against the vendored files with no failures and
one platform-dependent skip. Shell/Python syntax, `cabal check`, and source
distribution inclusion also passed.
