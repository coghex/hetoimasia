# Hetoimasia

A modular Haskell/Vulkan game engine with a planned Lua scripting host and
separate 2D and 3D rendering modules. Synarchy is a potential future client.

**Current implementation:** logging, scoped CPU resources, failures and bounded
recovery, monotonic scheduling, application composition, supervised workers,
bounded messaging, and GLFW with dynamic windows, controls, monitor-aware modes,
input feeds, native wake, and protected graphics-owner attachment lifetimes.
Vulkan, Lua, fonts, and rendering remain planned; their directories contain
ownership notes and are not in the Cabal package list.

The original GLFW arc and its completion repairs (#115–#118 and #123) are
merged and reviewed; epic #86 is complete. Native desktop tests now require
explicit per-session consent (#124). The children of the
[package-owned tests](docs/test_architecture_design.md) (#49),
[scheduling and native wake](docs/runtime_scheduling_design.md) (#131), and
[window/graphics retirement](docs/window_graphics_lifetime_design.md) (#140)
arcs have merged. The [latest review](docs/project_review_165-150.md) identifies
four retirement/reporting follow-ups before real GPU attachments.
The [Vulkan](docs/vulkan_backend_design.md) (#155) and
[Lua](docs/lua_runtime_design.md) (#145) designs are ready for staged processing.
Shared toolchain qualification (#157) precedes their initial implementation;
native graphics and mod confinement require their separate platform proofs.

## Start here

- [Working agreements](AGENTS.md)
- [Project memory and decisions](MEMORY.md)
- [Foundation design and dependency diagram](docs/engine_foundation_design.md)
- [Logging contract](docs/logging.md)
- [Resource ownership contract](docs/resources.md)
- [Runtime supervision](docs/supervision.md)
- [Messaging contract](docs/messaging.md)
- [Monotonic time contract](docs/time.md)
- [Scheduling update policy](docs/scheduling.md)
- [GLFW contract and native tests](docs/glfw.md)
- [Validation and evidence reuse](docs/validation.md)
- [Vulkan backend design — staged qualification](docs/vulkan_backend_design.md)
- [Kanban development workflow](docs/workflow.md)

## Build and run

Toolchain: GHC **9.14.1**, Cabal **3.18.1.0**, qualified and pinned in
[docs/toolchain.md](docs/toolchain.md). Console execution needs no
Vulkan, Lua, display, or Synarchy process. Building all components requires
the pinned GLFW dependency: follow the
[native prerequisites](docs/validation.md#developer-prerequisites-and-macos)
to build/cache it and prepare the local environment. Linux CI uses the pinned image.

```sh
cabal build all
cabal run exe:hetoimasia -- --smoke
cabal run exe:hetoimasia -- --resource-smoke
cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct
cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct
cabal test hetoimasia-glfw:glfw-tests --test-show-details=direct
cabal test hetoimasia-tests --test-show-details=direct
```

Run `cabal update` if the local Hackage index does not cover the pinned
`index-state` in `cabal.project`. Local packages build with warnings as errors.
`cabal build all` compiles the GLFW native test suite under this project's
configuration but runs no tests or native session. The package and root suites,
`glfw-tests` included, initialize no GLFW; the separate native suite requires Cocoa locally or isolated X11 on Linux,
and refuses to enter a session without the per-run consent
[docs/glfw.md](docs/glfw.md#the-native-suite) describes — on a person's
desktop, a human's explicit approval for that one run.

Expected smoke output on stderr — three `INFO` records in the
[logging record layout](docs/logging.md#record-layout), with the timestamp,
thread, and source line of the run:

```text
2026-09-10T12:34:56.789Z INFO runtime thread=4 src=src/Hetoimasia/Runtime.hs:16 msg="Starting hetoimasia"
2026-09-10T12:34:56.790Z INFO console thread=4 src=app/Main.hs:99 msg="Hello from Hetoimasia."
2026-09-10T12:34:56.790Z INFO runtime thread=4 src=src/Hetoimasia/Runtime.hs:18 msg="Completed hetoimasia"
```

`--resource-smoke` is the owned-resource path. It acquires a workspace and a
composite channel through the [resource scopes](docs/resources.md), does bounded
work with them, releases everything, and reports the lifecycle — the consumer
that shows the two contracts composing. Expected output on stderr, again with
the timestamp, thread, and source line of the run:

```text
2026-09-10T12:34:56.789Z INFO runtime thread=4 src=src/Hetoimasia/Runtime.hs:16 msg="Starting hetoimasia"
2026-09-10T12:34:56.790Z INFO runtime.resources thread=4 src=src/Hetoimasia/Runtime/Resources.hs:303 crumbs=resource-smoke msg="Acquired resource" id=1 resource=workspace
2026-09-10T12:34:56.790Z INFO runtime.resources thread=4 src=src/Hetoimasia/Runtime/Resources.hs:307 crumbs=resource-smoke msg="Acquired composite" buffer=2 resource=channel store=3
2026-09-10T12:34:56.791Z INFO runtime.resources thread=4 src=src/Hetoimasia/Runtime/Resources.hs:349 crumbs=resource-smoke msg="Completed bounded work" published=2 staged=3
2026-09-10T12:34:56.791Z INFO runtime.resources thread=4 src=src/Hetoimasia/Runtime/Resources.hs:453 crumbs=resource-smoke msg="Released resource" entries=2 id=2 resource=channel.buffer
2026-09-10T12:34:56.792Z INFO runtime.resources thread=4 src=src/Hetoimasia/Runtime/Resources.hs:453 crumbs=resource-smoke msg="Released resource" entries=1 id=3 resource=channel.store
2026-09-10T12:34:56.792Z INFO runtime.resources thread=4 src=src/Hetoimasia/Runtime/Resources.hs:453 crumbs=resource-smoke msg="Released resource" entries=3 id=1 resource=workspace
2026-09-10T12:34:56.793Z INFO runtime.resources thread=4 src=src/Hetoimasia/Runtime/Resources.hs:286 crumbs=resource-smoke msg="Resource smoke completed" entries=5
2026-09-10T12:34:56.793Z INFO runtime thread=4 src=src/Hetoimasia/Runtime.hs:18 msg="Completed hetoimasia"
```

The composite's parts are released in the order its constructor declared — the
buffer before the store it is bound to, which is acquisition order rather than
the reverse of it — and the workspace, allocated first by the enclosing scope,
is released last. Nothing is written to stdout and no file is left behind.
[Application lifecycle](docs/resources.md#application-lifecycle) is the
contract these records follow.

Logging is configured from the environment, read once at startup:
`HETOIMASIA_LOG_LEVEL` sets the global threshold, `HETOIMASIA_LOG_LEVELS` sets
exact per-component thresholds, and `HETOIMASIA_DEBUG` selects which components
may emit `Debug`. An absent variable keeps its default; a present but invalid
one fails startup with a non-zero exit and a message naming it. `--help` lists
the accepted forms, and
[startup configuration](docs/logging.md#startup-configuration) is the contract.

```sh
HETOIMASIA_LOG_LEVEL=warn cabal run exe:hetoimasia -- --smoke      # no records
HETOIMASIA_LOG_LEVELS=runtime=warn cabal run exe:hetoimasia -- --smoke
HETOIMASIA_LOG_LEVEL=warn cabal run exe:hetoimasia -- --resource-smoke
```

Every lifecycle record above is `Info`, so the last command still acquires,
uses, and releases both resources and still exits 0 — it just says nothing.

## Layout

| Directory | Purpose | Status |
|---|---|---|
| `app/` | Application composition and console consumer | Buildable |
| `packages/foundation/` | Logging, CPU scopes/collections, failures, recovery, workers and messaging | Buildable |
| `packages/runtime/` | Application composition, reporting, supervision and inbox services | Buildable |
| `packages/glfw/` | Private binding, windows, monitors, input and separate runtime adapter components | Buildable; original arc and repairs complete |
| `packages/render-api/` | Backend-independent rendering contracts | Planned |
| `packages/gpu-vulkan/` | Vulkan resource and submission ownership | Planned |
| `packages/render-2d/`, `packages/render-3d/` | Dedicated rendering paths | Planned |
| `packages/scripting-lua/` | Lua host and registration mechanism | Planned |
| `samples/` | Future independent rendering consumers | Planned |
| `integrations/` | Game adapters | Planned |
| `packages/foundation/test/` | Foundation-owned headless Hspec contracts | Buildable without GLFW through `cabal.project.cpu` |
| `test/` | Root runtime, GLFW and console coverage until #129/#130 finish migration | Buildable |
| `packages/glfw/native-tests/` | Shared native Hspec fixture and platform verification | Cocoa locally; Linux X11 in CI |
| `tools/test/` | Workflow, validation and provisioning Hspec examples | Buildable |

The libraries and Cabal components have separate source roots and declared
dependencies. Lower components cannot import root application modules. Add packages to
`cabal.project` when they contain useful implementations.

## Project status

The bootstrap uses `master` and the owner-selected GitHub repository
[coghex/hetoimasia](https://github.com/coghex/hetoimasia). Repository, local
directory, and Haskell package names all use `hetoimasia`.
Kanban's issue-approval and PR-drainer jobs were installed during bootstrap;
check their current running state through the board/controllers. Linux CI plans
required and requested groups, reuses compatible evidence, and runs native GLFW
checks when affected. macOS native verification remains local.

## License

GNU General Public License version 3 (`GPL-3.0-only`), selected by the owner.
See [LICENSE](LICENSE). Each distributable package includes the same license text.
