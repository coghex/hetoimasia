# Hetoimasia

A modular Haskell/Vulkan game engine with a planned Lua scripting host and
separate 2D and 3D rendering modules. Synarchy is a potential future client.

**Current implementation:** an injectable logging library, a small runtime
entry point, a console smoke executable, and focused Hspec tests. Vulkan,
Lua, input, fonts, and rendering are not implemented yet. Planned directories
are explicitly marked and are not included in the Cabal package list.

## Start here

- [Working agreements](AGENTS.md)
- [Project memory and decisions](MEMORY.md)
- [Foundation design and dependency diagram](docs/engine_foundation_design.md)
- [Proposed resource ownership model](docs/resource_ownership.md)
- [Kanban development workflow](docs/workflow.md)

## Build and run

Toolchain: GHC **9.12.2**, Cabal **3.16.1.0**. This initial console program
does not require Vulkan, Lua, a display, or a running Synarchy process.

```sh
cabal build all
cabal run exe:hetoimasia -- --smoke
cabal test hetoimasia-tests --test-show-details=direct
```

Run `cabal update` if the local Hackage index does not cover the pinned
`index-state` in `cabal.project`. Local packages build with warnings as errors.
`cabal build all` does not run or build the test suite by default.

Expected smoke output on stderr:

```text
[INFO] runtime: Starting hetoimasia
[INFO] console: Hello from Hetoimasia.
[INFO] runtime: Completed hetoimasia
```

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
| `test/` | GPU-free Hspec logging/runtime checks | Buildable |

The two libraries have separate source roots and declared dependencies. Neither
can import root application modules. Add future packages explicitly to
`cabal.project` when they contain useful implementations.

## Project status

The bootstrap uses `master` and the owner-selected GitHub repository
[coghex/hetoimasia](https://github.com/coghex/hetoimasia). Repository, local
directory, and Haskell package names all use `hetoimasia`.
CI and per-repository Kanban services remain to be configured.

## License

GNU General Public License version 3 (`GPL-3.0-only`), selected by the owner.
See [LICENSE](LICENSE). Each distributable package includes the same license text.
