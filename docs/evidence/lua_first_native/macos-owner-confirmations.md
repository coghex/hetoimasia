# LFE-25: macOS owner visual confirmations (pending)

Issue [#540](https://github.com/coghex/hetoimasia/issues/540), epic #514. **Every entry below is PENDING.** This file is
what the pull request carries, and it deliberately holds no confirmation: macOS has no OS capture (no `screencapture`, no
Screen Recording request), so what the quad, the resize clipping and the surviving peer look like is confirmed by the
owner, once, at the approved head, through the manager (owner decision of 2026-11-01, issue comment 6558502797). A
confirmation that arrives after the review is recorded in the pull request body and in a separate record landed with
`docs-push`, which supersedes this file; nothing here is edited after approval, so the approval stands. No test and no tool
reads any value in this file or requires one.

The record that supersedes this file is `docs/evidence/lua_first_native/macos-owner-confirmations-record.md`, landed with
`docs-push` after the merge. Until it exists and names the approved head, these entries are not confirmed.

## What is confirmed, and by which run

Both runs are made by the manager in a clean detached worktree at the exact approved head, each built first, after the
owner says they are at the keyboard. The first is supervised (the desktop consent with the `--match` selection, which
holds at each checkpoint on the operator's line on standard input); the second is the actual command.

```sh
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia:run-native-tests -- --match 'Lua native milestone'
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia:exe:hetoimasia -- run --vulkan-validation samples/lua-quad/content
```

| # | Entry | What the owner confirms | Status |
| --- | --- | --- | --- |
| M-1 | Checkpoint `two-instances-quads` | the textured quad is visible in both harness windows, the same picture in each | PENDING |
| M-2 | Checkpoint `peer-survival` | A's window is gone and B's window still shows the correct quad, never reloaded | PENDING |
| M-3 | Checkpoint `resize-smaller` | the quad keeps its size and top-left position in the smaller window, clipped where the window is too small and never stretched or re-centred | PENDING |
| M-4 | Checkpoint `resize-larger` | the same in the larger window | PENDING |
| M-5 | Checkpoint `restore` | the restored window shows the quad again | PENDING |
| M-6 | Actual command | the quad is visible in the real command's window, and the owner closes that window; the command exits 0 | PENDING |

The record that supersedes this file states, for each entry: the time and provenance of the owner's confirmation, the
owning process id and the native window identity, the metrics actually reported, and the lifecycle and exit evidence
(for M-6 the command's exit status and its drained diagnostics, including the validation record).

## Limits stated now

* The native zero-area framebuffer row is **unexercised** on macOS (the framebuffer of a minimized window was never
  reported with zero area); the controlled zero-metrics coverage belongs to its owning prerequisites and is not claimed as native.
* A restored window used to stay ineligible to draw on macOS until something sampled it again
  ([#581](https://github.com/coghex/hetoimasia/issues/581), fixed in `bb163cfa`). The restore case now takes no explicit
  sample and requires the restored window to report itself drawable by itself; the earlier explicit-sample readings (revision 8
  `visible=False`, revision 9 `visible=True` after a sample) are history, kept in the receipts' evidence of that earlier head.
