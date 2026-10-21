# Hetoimasia project memory

Owner decisions in force, open owner decisions, and facts that were expensive to
learn. Status lives in [README.md](README.md), the owning design or contract, and
the guide cursor; working rules live in [AGENTS.md](AGENTS.md). The memory as it
stood before 2026-10-21 is [archived](docs/archive/history/memory_before_2026-10-21.md):
history, not a work queue.

The heading is [the vision](docs/vision.md). `$guide` (`/guide` in Claude Code)
checks merged work and changed issues against it and resumes from
[the guide cursor](docs/guide/CURSOR.md). It is advisory and approves nothing.

## Where things stand

- Lua: [runtime design](docs/lua_runtime_design.md), trusted milestone delivered
  and owner-accepted 2026-10-21 (#500). The confined mod branch (LUA-9 to LUA-13,
  LUA-16, LUA-17) waits on Q-5. The [Lua-first engine design](docs/designs/lua_first_engine_design.md)
  is `exploring`; its questions go to `#het-luafirst`.
- Rendering: the [2D renderer design](docs/designs/render_2d_design.md) is delivered
  except deferred #446; [GPU backend contract](docs/gpu_backend.md);
  [samples](samples/README.md).
- Runtime and windowing contracts: [resources](docs/resources.md),
  [supervision](docs/supervision.md), [workers](docs/workers.md),
  [messaging](docs/messaging.md), [time](docs/time.md),
  [scheduling](docs/scheduling.md), [GLFW](docs/glfw.md), [logging](docs/logging.md),
  [failures](docs/failures.md), [recovery](docs/recovery.md).
- Review coverage: the [project-review ledger](docs/project_review/ledger.md).

## Owner decisions in force

- 2026-09-26, [module conventions](docs/module_conventions.md): flexible `Base`/`Types`,
  dedicated type modules, module types under the owning module's directory
  (`Camera/Types.hs`), `Base`/`Types` under about 600 lines. `packages/math`
  imports no other local or graphics package.
- 2026-09-22: first-party game scripts are trusted and run in-process in the UI
  and gameplay VM owners
  ([Lua D-12](docs/lua_runtime_design.md#d-12-run-first-party-scripts-trusted-and-in-process));
  mods keep confined processes, and both share one registration layer. D-13/D-14:
  trusted slices proceed independently of Q-5.
- 2026-09-22: quit may be bounded by an application-level watchdog that names the
  stuck owner, flushes best-effort and exits without unwinding. Foundation keeps
  its no-deadline drain
  ([V-3](docs/vision.md#v-3-ownership-and-completion-are-correctness-boundaries)).
- 2026-09-18: Lua cancellation targets a VM's execution owner. A callback never
  publishes its `ThreadId` or outlives its return; nothing promises to interrupt
  running Lua.
- GLFW stays on the main thread; rendering runs on a separate supervised graphics
  owner (Vulkan D-29 to D-33). A live resize is coalesced for 16 ms from its first
  sighting, built from the newest extent, and the active generation keeps
  presenting while a replacement waits (P-15 as amended).
- Vulkan: 1.3 minimum, one shared loader, managed retention, present-fence
  retirement, two frame slots by default.
- Never weaken isolation to turn an inconclusive confinement proof into support.
- Not committed: a game save schema, a full Synarchy port, permanent RTS tuning,
  an engine-wide rendering abstraction.

## Open owner decisions

- Q-5 on Linux ([verdict](docs/archive/lua_linux_confinement_verdict.md)): Ubuntu
  24.04's `kernel.apparmor_restrict_unprivileged_userns=1` and the CI container
  both deny usable unprivileged user namespaces. Options: relax the restriction,
  ship an AppArmor profile, a file-capability helper, or Landlock (unprivileged,
  no namespace), the one worth evaluating next.
- Q-5 on macOS ([verdict](docs/archive/macos_confinement_verdict.md)): accept the
  unsupported-SPI profile (`sandbox_init_with_parameters`,
  `posix_spawnattr_setjetsam_ext`), accept App Sandbox's weaker contract, or drop
  macOS from untrusted-mod targets.
- [Runtime tracing](docs/runtime_tracing_design.md): backend, viewer and cost
  choices; RTC-1 unprocessed.
- #446, sampling an offscreen pass's target: deferred; Q-10 is settled before it
  is specified.

## Facts not worth rediscovering

- Cocoa: a live resize or menu tracking blocks GLFW's event call for the whole
  interaction (68.9 s and 13.3 s measured); a window move does not. The graphics
  owner keeps presenting, but window commands and observations still wait
  ([verdict](docs/archive/graphics_owner_interaction_verdict.md)).
- MoltenVK 1.4.2 or later: 1.4.0 sets the drawable to 1x1 when a swapchain is
  recreated over an in-flight presentation.
- The KHR swapchain-maintenance spelling is an alias neither MoltenVK nor
  Lavapipe resolves; use the EXT extension. A present fence's status before it
  is waited on is no contract: wait for it. Device idle is not presentation
  retirement. No device loss was induced natively; those rows are specification
  evidence.
- The `lua` package's `-allow-unsafe-gc` is a correctness setting: a VM that held
  a Haskell callback re-enters the RTS from its collector. An asynchronous
  exception cannot cancel a thread inside Lua.
- Linux confinement probe: `unshare(CLONE_NEWUSER)` is refused to a threaded
  process, so fork first; `RLIMIT_AS` counts the RTS reservation (`-xr256m`); a
  read-only bind remount must carry the source's locked flags; lowering
  `RLIMIT_NOFILE` closes nothing, so sweep descriptors before the exec.
- macOS confinement: a spawn-time jetsam limit is cleared by any later `exec` (so
  `sandbox-exec` drops it); the cap is physical footprint; `RLIMIT_AS`/`RLIMIT_DATA`
  cannot go below the RTS's ~1.44 TiB reservation; an unprivileged process cannot
  delete an App Sandbox container; a profile does not cover inherited descriptors
  (`FD_CLOEXEC`, `POSIX_SPAWN_CLOEXEC_DEFAULT`).
- Remote CI is Linux-only; macOS native evidence is local.
