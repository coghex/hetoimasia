# TRA-23 evidence: terrain storage status, growth and recovery through Lua

Code head `cf882d1f` (the allow-list fix `44eab160` reran `lua-engine-tests` alone), run on 2026-11-15 from 15:24 to
16:01 UTC on macOS (arm64), qualified GHC 9.14.1 and Cabal 3.18.1.0 on `PATH`, after removing the build directories
of `hetoimasia-lua-engine` and `hetoimasia-terrain-runtime`. Other projects loaded the machine (load average 6.8 to
9.9); nothing else of this repository ran a suite. Contract: `packages/lua-engine/README.md` (the terrain calls,
storage) and `packages/terrain-runtime/README.md` (an open's allowance, the test seam library).

## Commands and results

```sh
cabal build --project-file cabal.project.cpu hetoimasia-lua-engine lib:hetoimasia-terrain-runtime
cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
cabal test workflow-tests --test-show-details=direct
```

| Suite or check | Examples | Failures | "Finished in" |
| --- | --- | --- | --- |
| build (cpu project) | — | warning-free under `-Werror` | — |
| lua-engine-tests at `44eab160` | 1,398 | 0 | 48.8 s |
| lua-runtime-tests | 1,182 | 0 | 1.7 s |
| terrain-runtime-tests | 1,045 | 1 (`Recovery.hs:182`, the one-shot-fault isolation intermittent #685 repairs) | 172.1 s |
| workflow-tests | 965 | 0 | 709.2 s |
| `cabal check` (both packages), `plan.py --catalog-check` | — | exit 0 | — |

Every planner-selected group also passed: `build.all`, `test.engine` 159, `test.foundation` 482, `test.runtime` 243,
`test.glfw` 1,097, `smoke.console`, `test.vulkan-headless` (11 suites, 0 failures), `test.vulkan-lua-engine-native`
31 and `test.vulkan-run-native` 59, the native groups under the standing desktop consent.

## What the Lua examples show

`Test.LuaEngine.Terrain.Storage` and `Test.LuaEngine.Terrain.StorageFaults` (15 examples) run real Lua over the
production backed service; faults and causal gates are injected at its native storage seam
(`hetoimasia-terrain-runtime:testing`), and every arena has a 64 MiB allowance in a fresh temporary directory.

| Item | Observed |
| --- | --- |
| Refusals before admission | 43 malformed arguments, options, arities and authorities: ordinary errors; all 16 request places free after; one arena, two leases, one file created |
| Both creator roles; attachment | status through creator and attachment equal; the creator's own attachment cannot grow or retry; growth 96 MiB `changed=true`, equal `changed=false`, smaller and a superseded second growth `storage_size_not_increased`; ready retry `changed=false` |
| Every new code, read and unread, both roles | `source_complexity`, `storage_unsupported`, `reservation_failed`, `storage_io`, `storage_integrity`, `storage_full`, `storage_size_not_increased`; the instance kept running and its next update ran after each |
| Pause and recovery | `storage_io` then `storage_integrity`: status reason `storage_integrity`; growth while paused clears neither; persistent retry keeps both; retries clear integrity, then I/O; the failed removal's cell still solid, then removed by a new request |
| `storage_full` | buried removals under a pinned reader until `storage_full`; another read and unread settle `storage_full`, not busy; growth to 128 MiB while paused: `ready`; discovery idle with 0 items after |
| Status against the service | fresh, after an edit, while discovery is held (`pending`, 1 item), under a pinned reader (pending reclaim > 0), after the pin (smaller), and after a changed copy: each equal to the service's own status |
| Growth windows | held at its reservation: 64 MiB stands; cancel wins; cancel after the commit `already_settled`; an extra whose give-back failed stays visible (48 MiB), a retry releases it; 2^63 − 2^20 refused its reservation at the seam |
| Logical time and lifetimes | a gameplay growth reserves and commits only at its tick, presentation updating meanwhile; a growth held at its creator's end leaves no arena, lease or backed defect |
