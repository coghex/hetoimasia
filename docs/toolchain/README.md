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
binding runs and their bundles in `repository-revision`.

[What they establish](#what-these-artifacts-establish-and-what-would-call-for-new-ones)
below says which later changes bear on them.

The receipts record their own `executed_commit`, `runner_os: Darwin`,
`runner_arch: arm64`, and the toolchain map actually observed — GHC, Cabal, and
the native GLFW manifest hash. They deliberately carry **no** `ci-image` entry:
a local run records its own identity and never claims the Linux image digest, so
these can never satisfy a Linux plan. See
[validation.md](../validation.md#planning-and-verifying-against-the-image).

`test.glfw-native` is selected by the plan and has no receipt here. It shows,
focuses, resizes, and takes fullscreen windows on the desktop it runs on. Under
[AGENTS.md](../../AGENTS.md) the owner's standing approval covers such a session
when an issue or pull request needs the group, with the desktop opt-in on that
run's own command; this qualification record ran none. Linux CI runs the group
on its own isolated X11 display.

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

#171's Linux CI receipts are not copied here, and they are separate evidence
from the `be92703` artifacts, each bound to its own revision. The `validation`
workflow produced them inside the published image whose descriptor #171
committed. For the pull request they were produced by run `35366929880` on head
`cb5fb38` and run `35370852876` on head `057d59a`, each on the merge candidate
GitHub resolved for that head. After the merge they were produced by push run
`35371004187` on `3af4cb2`. They live with those runs, and what they establish
is stated in their own receipts, not in this directory's claim about
`be92703`.

## What these artifacts establish, and what would call for new ones

They record what held at `be92703`. Later commits do not make that record
wrong, and every comparison below names both of its revisions, so it gives the
same answer from any checkout, however far `master` has since moved.

The artifacts exercised these inputs, and only a change to one of them bears on
the toolchain qualification:

| Input | Paths |
| --- | --- |
| Pins | `tools/ci-image/toolchain.pin`, `tools/toolchain/binding.pin`, `tools/native/glfw.pin`, and `.github/workflows/ci-image.yml` and `.github/workflows/validation.yml`, whose env carries `GHC_VERSION` and `CABAL_VERSION` |
| Bounds | every package description, `*.cabal` outside `docs/` |
| Project settings | every `cabal.project*` file |
| Recipes | `tools/ci-image/` and `tools/native/` (the image and native GLFW recipes), `tools/toolchain/Dockerfile.linux-binding` |
| Tools | `tools/toolchain/qualify-binding.sh`, `tools/toolchain/capture-build.sh`, and `tools/validation/run.py`, which wrote the receipts |

`be92703` to `cb5fb38`, the head #171's final review read, changes no path
outside `docs/`:

```bash
git diff --name-only be92703 cb5fb38 -- ':!docs'
```

That prints nothing. #171's final commit, `057d59a`, merged `master` into the
branch, so `be92703` to the merged tree `3af4cb2` does change paths outside
`docs/`: exactly five GLFW implementation and test paths, none of them an input
above:

```bash
git diff --name-only be92703 3af4cb2 -- ':!docs'
```

```text
packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs
packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal/Retirement.hs
packages/glfw/runtime-glfw/Hetoimasia/Runtime/GLFW.hs
packages/glfw/test/Test/GLFW/Attachments.hs
packages/glfw/test/Test/GLFW/Protected.hs
```

Restricted to the inputs, the same range prints nothing:

```bash
git diff --name-only be92703 3af4cb2 -- 'cabal.project*' '*.cabal' \
  tools/ci-image tools/native tools/toolchain tools/validation/run.py \
  .github/workflows/ci-image.yml .github/workflows/validation.yml ':!docs'
```

To ask the same of a later revision, substitute it for `3af4cb2`. If that
prints a path, the historical result still stands as a record of `be92703`, but
it does not extend to the changed configuration until new evidence is
produced for that configuration. If it prints nothing, no input the
qualification exercised has moved, but the receipts here are still only
evidence for `be92703`. They are application-test receipts, and unchanged pins do not make
them reusable for a candidate whose source has changed. Whether a receipt may
stand for a later candidate is decided by its recorded `input_identity` under
[validation.md's candidate identity](../validation.md#candidate-identity), not
by this directory.

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
