# TRA-17: CI timeline of the required native groups

Requirement 10: every required Vulkan native group stays under 30 seconds as measured on CI, including
`test.vulkan-native` and `test.vulkan-wayland`. The bounded scenario `tra17-terrain-ci` is the only TRA-17
scenario in them; the full `tra17-terrain` (116 fixtures, 56.8 s on the recorded device) is opt-in and excluded from
`--complete`, run directly under the documented mechanism. No watchdog or child deadline was raised.

Pull request #677, head `8d6e496a639164339c6b8b7dc4f06b49472d6ef0` (CI's merge candidate, which merges master:
repository revision `47e3182cbb135c83ac2294c25cf8f66789e343e6`, tree `29daa79f298d94f900502c8b05a5d01f0d61b703`).

## Common identity

| | |
| --- | --- |
| Worker | job `vulkan`, GitHub-hosted `ubuntu-latest`, Linux X64, in the CI image `sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb` |
| Device | `llvmpipe (LLVM 20.1.2, 256 bits)` (Mesa lavapipe, `lvp_icd.json`), `subPixelPrecisionBits = 8` (queried from the session, recorded per pass in the CI device's terrain record) |
| Toolchain | ghc 9.14.1, cabal 3.18.1.0, glslang 15.1.0 `96ea85d4228d` |
| Source identity | repository revision `47e3182cbb135c83ac2294c25cf8f66789e343e6`, source digest `a7766bac7af0ace6b2dba18089a73d7e11b050ae789d09a8fefdca86a6ea0b0e` (equal to the digest of the local clean tree at `8d6e496a`), input identity `e551d0ceae211cef09440effb82ade8532b1682f869d65903bdff8b6ab7001cb`, plan identity `1430007927712e59a038eb9c5f3959f130bfcd35c46027c896b7db005e817a30` |
| Executable | `vulkan-native-tests` built by each group's preparation from that revision in `dist-vulkan` (the stamp the runner reads is the revision and digest above) |

## The groups

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

## Bounded scenario on CI's device

`tra17-terrain-ci`: 11 fixtures, 2.4 s scenario, all passing; `subPixelPrecisionBits = 8`; the v3 band leaves 0 pixels
undecided in every fixture (the record is `bounded/tra17-terrain-ci-fixtures-ci-device.json`; its run record is
`ci-device-bounded-run-record.md`).
