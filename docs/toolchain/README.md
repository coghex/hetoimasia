# Qualification evidence

What [`../toolchain.md`](../toolchain.md) asserts, as the files that assert it.
Every file here was produced by the commands that document names; nothing in it
is transcribed by hand.

## Local macOS

| File | What it is |
| --- | --- |
| `receipts-darwin/*.json` | The validation receipts for every headless group, written by `tools/validation/run.py` against a committed candidate. |
| `binding-darwin.txt` | `tools/toolchain/qualify-binding.sh` output, naming the revision, platform, and loader it ran against. |
| `binding-bundle-darwin/` | The complete consumer that run built: project, package description, source module, and a `REPLAY` note. `cabal build all` in a copy of it reproduces the qualification. |
| `cpu-project-darwin.txt` | `cabal build all --project-file cabal.project.cpu`, captured by `tools/toolchain/capture-build.sh` with the command, toolchain, executed revision and tree, and result. |

Every artifact here was executed at commit **`be92703`**, and each says so
itself rather than relying on this sentence: the receipts in `executed_commit`,
the CPU-project capture in `executed-revision` with its tree beside it, and both
binding runs and their bundles in `repository-revision`. The only later commit
is the one adding this evidence, which changes documentation alone.

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
| `binding-linux.txt` | The same `qualify-binding.sh`, run inside the container `tools/toolchain/Dockerfile.linux-binding` builds, naming the revision the recipe was built from and the resolved package set it qualified against. |
| `binding-bundle-linux/` | That run's complete consumer, plus `packages.txt`: the distribution packages actually installed, whose SHA-256 is the `packages=` term of the reported platform identity. |

The two bundles' `cabal.project` files differ in exactly one way, and it is the
platform difference
[`../toolchain.md`](../toolchain.md#the-platform-difference-and-the-one-thing-it-costs)
explains: the macOS one carries a `package vulkan` stanza naming the loader
prefix and an rpath, because with `darwin-lib-dirs` disabled the binding supplies
no search path of its own. The Linux one names nothing, because the binding
declares `pkgconfig-depends: vulkan` there.

There is no separate CPU-project artifact for Linux. `build.all` runs the
ordinary project on every Linux CI run, and `cabal.project.cpu` exists for
building without the GLFW SDK — a constraint the published image does not have,
since it carries the pinned GLFW prefix. The local capture is where that
configuration is actually exercised.

The Linux CI receipts for this candidate are not copied here. They are produced
by the validation workflow on this pull request, inside the published image
whose descriptor the same pull request commits, and they live with that run.

## The old-version audit

The issue's acceptance asked for a `grep` with no remaining `9.12.2` or
`base >=4.21 && <4.22` matches. The trusted review replaced that with an audit:
active pins, bounds, fixtures, and current setup instructions must move, while
accurately dated evidence and version-specific source citations must not,
because rewriting those would misrepresent what was actually observed and when.

Everything active moved. Run the audit with `git ls-files` rather than a
filesystem walk, so build output and caches cannot appear as findings:

```bash
git ls-files -z | xargs -0 grep -n '9\.12\.2\|3\.16\.1\.0\|base >=4\.21'
```

That command reports exactly these files, and every one is retained on purpose:

| Where | Why it stays |
| --- | --- |
| `docs/toolchain.md` | The qualification record. It names the versions it replaced, and the ones Synarchy still uses, because that is what the record is for. |
| `docs/toolchain/README.md` | This file, including the audit command and this table. |
| `docs/resource_ownership_design.md` | States the verification baseline the recorded probes ran on. |
| `docs/runtime_foundation_design.md`, `docs/messaging_design.md` | Behaviour claims probed on GHC 9.12.2, cited with the compiler they were observed on. |
| `docs/glfw_integration_design.md`, `docs/lua_runtime_design.md` | Links into the GHC 9.12.2 and Cabal 3.16 documentation the design reasoned from. |
| `docs/project_review_114-101.md`, `docs/project_review_122-119.md`, `docs/project_review_38-31.md`, `docs/project_review_46-43.md` | Dated audit evidence naming the toolchain each review actually ran on. |
| `docs/ci_validation_design.md` | The CI-2 row records the boundary settled at design time; it is a historical decision record, not current policy. `../toolchain.md` is the authority for the current baseline. |
| `docs/vulkan_backend_design.md` | Records #146's former GHC 9.12.2 requirement, Synarchy's build plan (which genuinely still uses 9.12.2), and another project's 9.12.2 / `vulkan-3.26.6` precedent. |
| `docs/history/memory_before_2026-09-17.md` | History, by definition. |

No tracked file outside `docs/` matches, which is the part that matters: every
pin, bound, fixture, and current instruction moved.

The patterns above are the ones the issue's acceptance named. Several design
documents also cite `base-4.21.0.0` Hackage pages, which those patterns do not
match; they are retained for the same reason as the rest — they cite the API as
it was on the compiler the behaviour was observed on, and rewriting them would
misdescribe the observation.
