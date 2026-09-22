# The qualified toolchain

This is the durable record of the compiler, build tool, dependency index, and
Vulkan binding this repository has proved and pinned, and of what was rejected
to get there. It is the record [#146](https://github.com/coghex/hetoimasia/issues/146)
consumes as its shared-toolchain prerequisite, and it is the answer to "which
versions may I assume" for every later slice.

It is not a changelog. When the baseline moves, this file is rewritten to
describe the new one, and the qualification that established it is named by
commit so the old state stays recoverable from history rather than from prose
kept here.

## The baseline

| What | Value | Declared in |
| --- | --- | --- |
| Compiler | GHC **9.14.1** (`base-4.22.0.0`) | `tools/ci-image/toolchain.pin`, the `GHC_VERSION` env of both workflows, every package's `tested-with` |
| Build tool | cabal-install **3.18.1.0** | `tools/ci-image/toolchain.pin`, the `CABAL_VERSION` env of both workflows |
| Dependency index | `index-state: 2026-09-18T00:00:00Z` | `cabal.project.common` |
| Vulkan binding | `vulkan-3.27` with `vulkan-utils-0.5.11.0` | `tools/toolchain/binding.pin` |
| Binding flags | `+safe-foreign-calls`, `-darwin-lib-dirs` | `tools/toolchain/binding.pin` |

Qualified by [#157](https://github.com/coghex/hetoimasia/issues/157).
[`toolchain/README.md`](toolchain/README.md) names the revision each piece of
evidence was executed at, and every receipt names its own.

These identities are synchronized by construction rather than by convention:
`tools/ci-image/provision.sh` refuses to finish a toolchain layer whose
installed `ghc`/`cabal` disagree with `toolchain.pin`, the validation planner
refuses a candidate whose committed image descriptor disagrees with the
workflow pins, and `tools/test/CiImage.hs` and `tools/test/Reuse.hs` assert the
same literals. A pin changed in one place and not the others fails rather than
drifts.

## What was considered, and what excluded the newer candidate

Design records D-8 and D-13 in
[the Vulkan backend design](vulkan_backend_design.md) ask for the newest
*compatible* compiler, build tool, and dependencies, explicitly permit release
candidates, and require a compatibility proof on Linux and local macOS before
anything is pinned. "Permitted" is not "preferred": a release candidate is
qualified on the same evidence as a release and is selected only if it passes.

Candidates available on 2026-09-18, newest first:

| Candidate | Outcome |
| --- | --- |
| GHC **9.14.2-rc2** (bindists versioned `9.14.1.20260916`, `base-4.22.1.0`) | **Rejected — compatibility blocker, below.** |
| GHC **9.14.1** (`base-4.22.0.0`) | **Selected.** `cabal build all` warning-clean under `-Werror` on both project files; all five suites pass; smoke exits zero. |
| GHC 9.12.4 / 9.12.5-rc3 (`base-4.21.x`) | Not considered further: older than a candidate that qualified, so D-13 excludes them. |
| cabal-install **3.18.1.0** | **Selected.** Newest release; resolves and builds the whole tree and the binding. |

### The blocker that excluded GHC 9.14.2-rc2

The release candidate builds this repository warning-clean, and `runtime-tests`,
`glfw-tests`, `hetoimasia-tests`, and `workflow-tests` all pass on it. It
changes exception-context propagation, and two `foundation-tests` examples that
assert that contract fail on it and pass on 9.14.1:

```
Resources, Resource scope evidence retention,
  finds evidence through a caller's plain catch and rethrow
    expected: 0
     but got: 1
Resources, Resource scope evidence retention,
  loses evidence through a try followed by a plain throwIO
    expected: 0
     but got: 1
```

Both examples assert that context is *dropped* on a path the foundation
documents as lossy: a bare typed `catch`/`try` that rethrows the caught value,
and a plain `throwIO` of an already-caught exception. On 9.14.2-rc2 the cleanup
evidence survives both. That is a change in the exact behaviour
[the resource ownership design](resource_ownership_design.md) and
[`docs/resources.md`](resources.md) build on to distinguish `throwIO` from
`rethrowIO` and `catchNoPropagate`, and #157 requires that the foundation's
exception-context behaviour be unchanged across this refresh.

Adopting the candidate would therefore mean re-deriving that contract and the
documents that state it, on a prerelease, as part of a toolchain refresh. That
is its own decision with its own evidence, not a detail of this one. 9.14.1 is
the newest candidate that leaves the contract as documented, so it is the
qualified compiler.

**Recheck this when GHC 9.14.2 is released.** If the change is deliberate and
kept, the foundation's evidence-retention contract needs revisiting before the
compiler moves; if it was a regression, 9.14.2 final qualifies on this same
evidence. The candidate is not installed by this repository and nothing here
depends on it.

## The resolution

### The application

Boot libraries come from GHC 9.14.1 itself. Bounds moved deliberately for this
compiler, in every package that declares them:

| Dependency | Was | Now | Why |
| --- | --- | --- | --- |
| `base` | `>=4.21 && <4.22` | `>=4.22 && <4.23` | GHC 9.14.1 ships `base-4.22.0.0`. |
| `containers` | `>=0.7 && <0.8` | `>=0.8 && <0.9` | GHC 9.14.1 ships `containers-0.8`. |
| `time` | `>=1.14 && <1.15` | `>=1.15 && <1.16` | GHC 9.14.1 ships `time-1.15`. |

No other bound moved: `bytestring`, `deepseq`, `directory`, `filepath`,
`process`, `stm`, and `text` are all still satisfied by this compiler's own
boot libraries within their existing bounds.

The third-party packages the index resolves, as observed on local macOS. No
package here is selected conditionally — the only `if os(…)` stanzas in this
repository's package descriptions are two in `hetoimasia-glfw`, choosing
frameworks and `extra-libraries`, never a `build-depends` entry — so the same
index and bounds select the same set wherever the solver runs. Linux CI resolves and builds it under the published
image on every run:

```
HUnit-1.6.2.0              hspec-2.11.17              quickcheck-io-0.2.0
QuickCheck-2.18.0.0        hspec-core-2.11.17         random-1.3.1
ansi-terminal-1.1.5        hspec-discover-2.11.17     splitmix-0.1.3.2
ansi-terminal-types-1.1.3  hspec-expectations-0.8.4   temporary-1.3
call-stack-0.4.0           colour-2.3.7               haskell-lexer-1.2.1
```

The resolution is replayable rather than merely recorded: `cabal.project.common`
pins `index-state`, every dependency carries an explicit bound, and no
`cabal.project.freeze` exists, so re-resolving at that index on this compiler
reproduces this set. `cabal build all --dry-run` prints it.

### The binding

`vulkan-3.27` and `vulkan-utils-0.5.11.0` — the newest pair at this index, and
the pair `vulkan-utils`'s own `vulkan >=3.27 && <3.28` bound requires. Neither
is a dependency of any package this repository builds: there is no
`packages/gpu-vulkan` Cabal package, `cabal.project` does not list one, and the
Linux CI image gains no Vulkan input. They are proved here so VK-2 and later
inherit a proven pair instead of re-deciding it.

Both flags are set opposite to the package's own defaults, and
`tools/toolchain/binding.pin` records why:

- `+safe-foreign-calls` marks the foreign imports `safe`, so a Vulkan call may
  re-enter Haskell. Debug-utils messenger and allocation callbacks are exactly
  that re-entry; with the default `unsafe` imports they corrupt the RTS.
- `-darwin-lib-dirs` stops the package appending `/usr/local/lib` to
  `extra-lib-dirs` on macOS whether or not a loader is there. The loader is
  named by this repository instead.

The effective flag set the solver actually reported, on both platforms:

```
-darwin-lib-dirs -generic-instances +safe-foreign-calls -trace-calls
```

#### The platform difference, and the one thing it costs

The binding finds the loader differently per platform, and this is a real
difference rather than an accident:

- **Linux** — `vulkan` declares `pkgconfig-depends: vulkan`. A package
  description is the entire configuration.
- **macOS** — `vulkan` declares `extra-libraries: vulkan` and, with
  `darwin-lib-dirs` off, supplies no search path at all. A library directory
  has to be named.

VK-4 answered both from one place. `tools/native/vulkan.py` provisions the
loader into the private native prefix and writes
`<prefix>/vulkan/lib/pkgconfig/vulkan.pc` describing it, so on Linux
`pkgconfig-depends: vulkan` resolves the project-managed prefix rather than
whatever a distribution installed; and `native.py prepare` prints
`HETOIMASIA_VULKAN_LIBDIR` and `HETOIMASIA_VULKAN_INCLUDEDIR`, which
`tools/vulkan-proof/run-proof.sh` passes to Cabal as `--extra-lib-dirs` and
`--extra-include-dirs` on the one command line. Those are configure flags, so
unlike `--ghc-options` they reach a dependency the store builds. Nothing is
generated on disk and nothing names a machine path.

#### Why the loader is copied on macOS, and why there is no rpath

Naming a library directory is necessary but not sufficient, and the
qualification is what found that. `vulkan-utils` runs Template Haskell against
the compiled `vulkan` library, so GHC `dlopen`s it *while compiling*, and a
dylib linked against the vendor SDK's loader records its dependency as
`@rpath/libvulkan.1.dylib`. `extra-lib-dirs` is a link-time search path and
contributes no rpath, so the compile-time load fails with
`Library not loaded: @rpath/libvulkan.1.dylib` even though the link succeeded.
An rpath cannot be supplied from the command line either, for the reason above:
`--ghc-options` never reaches a dependency.

So the recipe removes the `@rpath` rather than working around it. The qualified
loader is copied into `<prefix>/vulkan/lib` and given an **absolute install
name**, and the copy is re-signed ad hoc because editing a Mach-O invalidates
its signature. Everything linked against it then records that absolute path, and
no rpath, no generated project file, and no machine path is involved at any
stage. `tools/toolchain/qualify-binding.sh` predates this and still emits its
own `package vulkan` stanza against `MACOS_VULKAN_PREFIX`; that remains the
qualification's own retained invocation, and the provisioned prefix satisfies
the same shape — `<prefix>/vulkan/lib` holds the loader and
`<prefix>/vulkan/lib/pkgconfig/vulkan.pc` describes it — so
`HETOIMASIA_VULKAN_PREFIX` may be pointed at it.

The `darwin-lib-dirs` default hid the whole problem by hard-coding a path that
happened to hold a loader.

## Running the qualification

`tools/toolchain/qualify-binding.sh` is the retained invocation. It reads the
compiler and build-tool versions from `tools/ci-image/toolchain.pin`, the index
from `cabal.project.common`, and the binding and flags from
`tools/toolchain/binding.pin`, so it cannot silently qualify something other
than what this repository pins — it refuses outright if the `ghc` or `cabal` on
`PATH` disagrees. It builds a throwaway consumer in a temporary directory, and
prints the resolved versions, the effective flags, the platform and loader it
ran against, and the repository revision it exercised, then exits zero.

On macOS, with the qualified toolchain on `PATH`:

```bash
bash tools/toolchain/qualify-binding.sh
```

On Linux, inside the pinned throwaway container
`tools/toolchain/Dockerfile.linux-binding`, which pins its base image by digest
and installs the toolchain from the same checksummed bindists the CI image uses:

```bash
docker build -f tools/toolchain/Dockerfile.linux-binding \
  --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  -t hetoimasia-binding-qualification .
docker run --rm hetoimasia-binding-qualification
```

`SOURCE_REVISION` is how the container can report what it qualified: there is no
checkout inside it to ask, only the handful of files the recipe copies.

That container is not the CI image and nothing published depends on it. It
carries `libvulkan-dev`, which is exactly the input the CI image must not gain
until VK-4 provisions it deliberately; keeping the two recipes separate is what
lets this slice prove the binding without changing what every validation worker
pulls.

Its inputs are pinned so a rebuild qualifies against the same thing: the base
image by digest, the distribution packages by an Ubuntu archive snapshot, the
toolchain by `toolchain.pin`'s checksummed bindists. A snapshot pins what the
archive *offered*, though, not what was actually taken, so the resolved package
set is recorded at `/opt/packages.txt`, travels with the qualification bundle,
and its SHA-256 is part of the platform identity the run reports.

Not even the trust material comes from a mutable archive. The snapshot host
redirects to HTTPS and the pinned base image ships no CA bundle, so reaching it
at all needs `ca-certificates` — and taking that from the default archive would
pull whatever `openssl` is current that day, which is the drift the snapshot
exists to prevent. Apt does not rely on TLS for integrity: it verifies each
archive's `InRelease` GPG signature against the Ubuntu keyring the pinned base
image already carries. So the recipe disables peer verification for the snapshot
host alone, long enough to install that snapshot's own `ca-certificates`, then
removes the exemption; every later fetch is both signature-verified and
TLS-verified. A tampered archive is refused either way.

One deliberate difference from the CI image: GHC's HTML documentation is dropped
before installing. Nothing in the container reads it, and on an emulated x86_64
host installing those files dominates the build badly enough to make re-running
this qualification impractical. It changes no compiler, library, or link
behaviour.

`HETOIMASIA_QUALIFICATION_OUT=<dir>` exports the whole throwaway consumer to
that directory — the project, the package description, the source module they
name, the resolved package set on Linux, and a `REPLAY` note giving the exact
`ghc` and `cabal` to use. That is a directory you can `cabal build all` in
as-is, which is what makes a recorded qualification replayable rather than only
readable. The exported bundles are retained in
[`docs/toolchain/`](toolchain/).

## Evidence

Retained with this record in [`docs/toolchain/`](toolchain/), whose README says
what each file is, which revision produced it, and which matches of the old
versions are kept on purpose.

In summary, all on the qualified toolchain:

- `cabal build all` and `cabal build all --project-file cabal.project.cpu` are
  warning-clean under the existing `-Werror` policy.
- `foundation-tests` (336), `runtime-tests` (184), `glfw-tests` (423),
  `hetoimasia-tests` (11) and `workflow-tests` (335) pass with no failures, and
  `cabal run exe:hetoimasia -- --smoke` exits zero.
- Every headless validation group has a passing local receipt, produced by the
  planner and runner against a committed candidate.
- `test.glfw-native` has no local receipt on purpose. It takes over the desktop
  it runs on, and [AGENTS.md](../AGENTS.md) requires explicit per-run human
  approval before an agent starts such a session; qualifying a toolchain is not
  that approval. Linux CI runs the group on its own isolated X11 display.
- `tools/toolchain/qualify-binding.sh` exits zero on local macOS and inside the
  pinned Linux container, reporting the pinned pair and the required flags on
  both.

## Keeping Synarchy out of it

`~/work/synarchy` keeps its own compiler, pins, and installation. GHC 9.12.2
remains installed, Synarchy's `cabal.project` continues to select its own
`index-state: 2026-08-14T00:00:00Z`, its own bounds, and its own
`vulkan-utils-0.5.10.6`, and nothing in this qualification edits a file there.
Verified by resolving Synarchy against its own project files after this refresh:
the resolution is complete and its working tree is clean.

One piece of shared workstation state does move, and it is worth naming rather
than discovering later. Installing cabal-install 3.18.1.0 makes it `ghcup`'s
active `cabal`, so Synarchy is now resolved by 3.18.1.0 rather than 3.16.1.0.
That is a build tool, not a pin: Synarchy declares no `with-compiler` and no
Cabal version, and the verification above was run in exactly that state. The
*compiler* `ghcup` selects is unchanged, so Synarchy still builds on GHC 9.12.2
unless someone changes it deliberately.

The qualified compiler is selected by `PATH`, not by a `with-compiler` line
here, because `Test.Support.ExternalClient` requires the `ghc` on `PATH` to be
the one each suite was built with — an external client compiled by a different
compiler does not answer the question those examples ask. Activate the qualified
toolchain for this repository's work; that is what makes
`ghc --numeric-version` report the pin.
