# Hetoimasia

A modular Haskell/Vulkan game engine with a planned Lua scripting host and
separate 2D and 3D rendering modules. Synarchy is a potential future client.

**Current implementation:** an injectable logging library with
environment-configured filtering, a small runtime entry point, a console smoke
executable, and focused Hspec tests. Vulkan, Lua, input, fonts, and rendering
are not implemented yet. Planned directories are explicitly marked and are not
included in the Cabal package list.

## Start here

- [Working agreements](AGENTS.md)
- [Project memory and decisions](MEMORY.md)
- [Foundation design and dependency diagram](docs/engine_foundation_design.md)
- [Logging design — ready for processing](docs/logging_design.md)
- [Resource ownership design — ready for processing](docs/resource_ownership_design.md)
- [Kanban development workflow](docs/workflow.md)

## Build and run

Toolchain: GHC **9.12.2**, Cabal **3.16.1.0**. This initial console program
does not require Vulkan, Lua, a display, or a running Synarchy process.

```sh
cabal build all
cabal run exe:hetoimasia -- --smoke
cabal run exe:hetoimasia -- --resource-smoke
cabal test hetoimasia-tests --test-show-details=direct
```

Run `cabal update` if the local Hackage index does not cover the pinned
`index-state` in `cabal.project`. Local packages build with warnings as errors.
`cabal build all` does not run or build the test suite by default.

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
| `packages/foundation/` | Independent services; currently logging | Buildable |
| `packages/runtime/` | Application lifecycle entry point | Buildable |
| `packages/render-api/` | Backend-independent rendering contracts | Planned |
| `packages/gpu-vulkan/` | Vulkan resource and submission ownership | Planned |
| `packages/render-2d/`, `packages/render-3d/` | Dedicated rendering paths | Planned |
| `packages/scripting-lua/` | Lua host and registration mechanism | Planned |
| `samples/` | Future independent rendering consumers | Planned |
| `integrations/` | Game adapters | Planned |
| `test/` | GPU-free Hspec Logging, Runtime, Resources, and Failures examples | Buildable |

The two libraries have separate source roots and declared dependencies. Neither
can import root application modules. Add future packages explicitly to
`cabal.project` when they contain useful implementations.

## Project status

The bootstrap uses `master` and the owner-selected GitHub repository
[coghex/hetoimasia](https://github.com/coghex/hetoimasia). Repository, local
directory, and Haskell package names all use `hetoimasia`.
Kanban's issue-approval and PR-drainer jobs are installed on the owner's machine
and await an explicit start from the board. CI remains to be configured.

## License

GNU General Public License version 3 (`GPL-3.0-only`), selected by the owner.
See [LICENSE](LICENSE). Each distributable package includes the same license text.
