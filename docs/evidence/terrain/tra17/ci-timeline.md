# TRA-17: CI timeline of the required native groups

Requirement 10: every required Vulkan native group stays under 30 seconds as measured on CI, including
`test.vulkan-native` and `test.vulkan-wayland`. The bounded scenario `tra17-terrain-ci` is the only TRA-17
scenario in them; the full `tra17-terrain` (133 fixtures, 63.5 s on the recorded device) is opt-in and excluded from
`--complete`, run directly under the documented mechanism. No watchdog or child deadline was raised.

## The final head

Pull request #677, head `7bc5b98c0ddf5c82d65bff91a05907c230af6f66`, validation run
[42661485405](https://github.com/coghex/hetoimasia/actions/runs/42661485405/attempts/1) (success; the `vulkan` job
[129314150169](https://github.com/coghex/hetoimasia/actions/runs/42661485405/job/129314150169)). CI's merge candidate
(the executed commit) is `447380da`, tree `f7cceec2737b`; the source digest the CI device's records carry,
`381400070997224a87bcbcbf809976e68cb0a6a9b03fac44863284cb37557805`, **equals the local clean tree's** at the tested head
(the same digest is in the local records under `full/` and `bounded/`).

| | |
| --- | --- |
| Worker | job `vulkan`, GitHub-hosted `ubuntu-latest`, Linux X64, in the CI image `sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb` |
| Device | `llvmpipe (LLVM 20.1.2, 256 bits)`, driver `llvmpipe`, info `Mesa 25.2.8-0ubuntu0.24.04.2 (LLVM 20.1.2)`, `subPixelPrecisionBits = 8`, all queried from the session and stored in the record |
| Toolchain | ghc 9.14.1, cabal 3.18.1.0, glslang 15.1.0 `96ea85d4228d`, lavapipe `lvp 1.4.318`, validation layer 1.3.275 with synchronization, weston 13.0.0 |
| Input identity | `3da115c29ca0dc4d97935755268aca4c5ced4e325f28c0532756f27856731dab`, plan identity `cc709db6b4c46e14b5045404a20b4e9a0265ec0d67e24202c7b4ddcdb76e8a2a` |

The 30 s watch covers the native command alone; the preparation (the build) is measured separately. Every group passed on
its first execution at this head.

| Group | Native command start | End | Elapsed | Budget | Outcome |
| --- | --- | --- | ---: | ---: | --- |
| `test.vulkan-native` | 2026-11-09T17:09:59.272Z | 17:10:11.059Z | **11.787 s** | 30 s | passed (preparation 22.1 s) |
| `test.vulkan-wayland` | 2026-11-09T17:10:17.441Z | 17:10:29.931Z | **12.490 s** | 30 s | passed (preparation 5.9 s) |
| `test.vulkan-lua-engine-native` | 2026-11-09T17:10:34.505Z | 17:10:44.438Z | 9.933 s | 60 s | passed (preparation 4.1 s) |
| `test.vulkan-run-native` | 2026-11-09T17:10:50.284Z | 17:11:01.725Z | 11.440 s | 30 s | passed (preparation 5.4 s) |

Both required groups are under 30 s with margin. The bounded scenario `tra17-terrain-ci` ran in each of
`test.vulkan-native` (1.35 s scenario) and `test.vulkan-wayland` (1.26 s scenario): 11 fixtures, all passing, the v3/v4 band
leaving 0 pixels undecided in every fixture (the record is `bounded/tra17-terrain-ci-fixtures-ci-device.json`; its run record
is `ci-device-bounded-run-record.md`). Neither bias control is in the bounded selection. `test.vulkan-headless` (40.0 s) and
`test.glfw-native` (11.1 s) also passed.

## An earlier candidate (history)

An earlier head of pull request #677, `8d6e496a639164339c6b8b7dc4f06b49472d6ef0` (CI's merge candidate, which merges master:
repository revision `47e3182cbb135c83ac2294c25cf8f66789e343e6`, tree `29daa79f298d94f900502c8b05a5d01f0d61b703`).

### Common identity

| | |
| --- | --- |
| Worker | job `vulkan`, GitHub-hosted `ubuntu-latest`, Linux X64, in the CI image `sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb` |
| Device | `llvmpipe (LLVM 20.1.2, 256 bits)` (Mesa lavapipe, `lvp_icd.json`), `subPixelPrecisionBits = 8` (queried from the session, recorded per pass in the CI device's terrain record) |
| Toolchain | ghc 9.14.1, cabal 3.18.1.0, glslang 15.1.0 `96ea85d4228d` |
| Source identity | repository revision `47e3182cbb135c83ac2294c25cf8f66789e343e6`, source digest `a7766bac7af0ace6b2dba18089a73d7e11b050ae789d09a8fefdca86a6ea0b0e` (equal to the digest of the local clean tree at `8d6e496a`), input identity `e551d0ceae211cef09440effb82ade8532b1682f869d65903bdff8b6ab7001cb`, plan identity `1430007927712e59a038eb9c5f3959f130bfcd35c46027c896b7db005e817a30` |
| Executable | `vulkan-native-tests` built by each group's preparation from that revision in `dist-vulkan` (the stamp the runner reads is the revision and digest above) |

### The groups

The 30 s watch covers the native command alone; the preparation (the build) is measured separately.

| Group | Run, job | Native command start | End | Elapsed | Budget | Outcome |
| --- | --- | --- | --- | ---: | ---: | --- |
| `test.vulkan-native` | [run 42646516984](https://github.com/coghex/hetoimasia/actions/runs/42646516984/attempts/1), [job 129261287352](https://github.com/coghex/hetoimasia/actions/runs/42646516984/job/129261287352), runner GitHub Actions 1000072854 | 2026-11-09T15:43:00.216Z | 15:43:18.022Z | **17.806 s** | 30 s | passed (preparation 61.8 s); `tra17-terrain-ci` 3.14 s of it |
| `test.vulkan-wayland` (first execution) | same job | 2026-11-09T15:43:27.346Z | 15:43:44.201Z | 16.855 s | 30 s | **failed**, exit 1: the private scenario `wayland-connection-loss` (a Wayland-compositor-loss case outside TRA-17) exited 1 after 0.34 s; `tra17-terrain-ci` ran in the same group in 2.63 s and passed |
| `test.vulkan-wayland` (re-execution) | [run 42646518135](https://github.com/coghex/hetoimasia/actions/runs/42646518135), [job 129266515127](https://github.com/coghex/hetoimasia/actions/runs/42646518135/job/129266515127), runner GitHub Actions 1000072873 | 2026-11-09T15:48:03.7Z | 15:48:18.4Z | **14.7 s** | 30 s | passed (preparation 7.1 s); the other groups' receipts of the first run were reused at the same candidate |

Both required groups are under 30 s with margin (17.8 s and 14.7 s). The first `test.vulkan-wayland` execution failed on
a scenario TRA-17 does not touch and passed on re-execution at the same head and the same source digest; the failure is
recorded here and not hidden. `test.vulkan-lua-engine-native` (18.7 s) and `test.vulkan-run-native` (16.9 s) are the
other native groups of the plan and passed in the first run. The full verdict of the first run (every group's elapsed time) is in the run's
`Decide the verdict` step; the unit and Vulkan device-free groups are not in the 30 s native watch.

### Bounded scenario on CI's device

`tra17-terrain-ci`: 11 fixtures, 2.4 s scenario, all passing; `subPixelPrecisionBits = 8`; the v3 band leaves 0 pixels
undecided in every fixture (the record is `bounded/tra17-terrain-ci-fixtures-ci-device.json`; its run record is
`ci-device-bounded-run-record.md`).
