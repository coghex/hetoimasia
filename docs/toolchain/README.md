# Qualification evidence

What [`../toolchain.md`](../toolchain.md) asserts, as the files that assert it.
Everything here was produced by the commands that record are named in that
document; nothing here is transcribed by hand.

## Local macOS

| File | What it is |
| --- | --- |
| `receipts-darwin/*.json` | The validation receipts for every headless group, written by `tools/validation/run.py` against a committed candidate. |
| `binding-darwin.txt` | `tools/toolchain/qualify-binding.sh` output. |
| `binding-darwin.cabal.project` | The resolution input that run generated, so it can be replayed. |

The receipts record their own `executed_commit`, `runner_os: Darwin`,
`runner_arch: arm64`, and the toolchain map actually observed — GHC, Cabal, and
the native GLFW manifest hash. They deliberately carry **no** `ci-image` entry:
a local run records its own identity and never claims the Linux image digest, so
these can never satisfy a Linux plan. See
[validation.md](../validation.md#planning-and-verifying-against-the-image).

`test.glfw-native` is selected by the plan and has no receipt here. It shows,
focuses, resizes, and takes fullscreen windows on the desktop it runs on, and
[AGENTS.md](../../AGENTS.md) requires explicit per-run human approval before an
agent starts such a session. Qualifying a toolchain is not that approval. Linux
CI runs the group on its own isolated X11 display.

## Linux

| File | What it is |
| --- | --- |
| `binding-linux.txt` | The same `qualify-binding.sh`, run inside the container `tools/toolchain/Dockerfile.linux-binding` builds. |
| `binding-linux.cabal.project` | That run's generated resolution input. |

The two `cabal.project` files differ in exactly one way, and it is the platform
difference [`../toolchain.md`](../toolchain.md#the-platform-difference-and-the-one-thing-it-costs)
explains: the macOS one carries a `package vulkan` stanza naming the loader
prefix and an rpath, because with `darwin-lib-dirs` disabled the binding supplies
no search path of its own. The Linux one names nothing, because the binding
declares `pkgconfig-depends: vulkan` there.

The Linux CI receipts for this candidate are not copied here. They are produced
by the validation workflow on this pull request, inside the published image
whose descriptor the same pull request commits, and they live with that run.

## The old-version audit

The issue's acceptance asked for a `grep` with no remaining `9.12.2` or
`base >=4.21 && <4.22` matches. The trusted review replaced that with an audit:
active pins, bounds, fixtures, and current setup instructions must move, while
accurately dated evidence and version-specific source citations must not,
because rewriting those would misrepresent what was actually observed and when.

Everything active moved. These tracked matches are retained deliberately:

| Where | Why it stays |
| --- | --- |
| `docs/resource_ownership_design.md` | States the verification baseline the recorded probes ran on, and cites `base-4.21.0.0` API pages for behaviour observed there. |
| `docs/resources.md`, `docs/runtime_foundation_design.md`, `docs/messaging_design.md` | Version-specific `base-4.21.0.0` and GHC 9.12.2 citations supporting behaviour claims probed on that compiler. |
| `docs/glfw_integration_design.md`, `docs/lua_runtime_design.md` | Links into the GHC 9.12.2 and Cabal 3.16 documentation the design reasoned from. |
| `docs/project_review_*.md` | Dated audit evidence naming the toolchain each review actually ran on. |
| `docs/ci_validation_design.md` | The CI-2 row records the boundary settled at design time; it is a historical decision record, not current policy. `../toolchain.md` is the authority for the current baseline. |
| `docs/vulkan_backend_design.md` | Records #146's former GHC 9.12.2 requirement, Synarchy's build plan (which genuinely still uses 9.12.2), and another project's 9.12.2 / `vulkan-3.26.6` precedent. |
| `docs/history/` | History, by definition. |

Re-run the audit with `git ls-files` rather than a filesystem walk, so build
output and caches cannot appear as findings:

```bash
git ls-files -z | xargs -0 grep -n '9\.12\.2\|3\.16\.1\.0\|base >=4\.21'
```

Every match it reports should be in the table above.
