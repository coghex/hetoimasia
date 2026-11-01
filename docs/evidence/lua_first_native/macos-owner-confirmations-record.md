# LFE-25: macOS owner visual confirmations (confirmed)

Issue [#540](https://github.com/coghex/hetoimasia/issues/540), epic #514, pull request
[#582](https://github.com/coghex/hetoimasia/pull/582) (merged as `4f5c3b40`). **All six entries are CONFIRMED** by the
owner at the approved head `f7ffd77af2200ee0b90fcdc481a1acf58d6ae9e2`. This record supersedes
[the pending file](macos-owner-confirmations.md) that the pull request carried, as that file says it will. macOS has no OS
capture: nothing here comes from a screenshot or a test output standing in for the owner; each confirmation is the owner's
own answer, relayed by the manager (owner decision of 2026-11-01, issue comment 6558502797). No test and no tool reads any
value in this file.

## How the confirmations were made

The manager ran both commands once, in a clean detached worktree (`smoke-540-f7ffd77a`) at the approved head, built first
(exit 0), source digest `bfea44470fded54aa0c029bdb924aaba61f3394c72351337241a3fefe87842dd`, with the owner at the keyboard
throughout. Each acknowledgment line the manager entered on the supervised run's standard input carried the owner's answer,
which was "yes" each time.

1. Supervised run, 2026-11-01 23:21:27Z to 23:24:36Z, owning pid 57617: 16 examples, 0 failures, exit 0, "result: every
   check passed".

   ```sh
   HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia:run-native-tests -- --match 'Lua native milestone'
   ```

2. Actual command, 2026-11-01 23:25:24Z to 23:25:29Z, exit 0.

   ```sh
   HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia:exe:hetoimasia -- run --vulkan-validation samples/lua-quad/content
   ```

## The entries

| # | Entry | Status | Acknowledged (UTC, 2026-11-01) | Native window and metrics reported |
| --- | --- | --- | --- | --- |
| M-1 | Checkpoint `two-instances-quads`: the quad in both windows | CONFIRMED | 23:22:26.391Z | WindowId 1 and 2, 640x480 logical, 1280x960 framebuffer |
| M-2 | Checkpoint `peer-survival`: A gone, B's quad correct | CONFIRMED | 23:23:31.627Z | B is WindowId 2 at revision 79 |
| M-3 | Checkpoint `resize-smaller`: clipped, not stretched or re-centred | CONFIRMED | 23:24:04.390Z | WindowId 1, 320x240 logical / 640x480 framebuffer; clipped, not stretched or re-centred |
| M-4 | Checkpoint `resize-larger` | CONFIRMED | 23:24:17.851Z | WindowId 1, 800x600 logical / 1600x1200 framebuffer |
| M-5 | Checkpoint `restore` | CONFIRMED | 23:24:32.079Z | WindowId 1 at revision 236, visible=True, iconified=False, with no explicit sample |
| M-6 | Actual command: the quad, then the owner closes the window; exit 0 | CONFIRMED | n/a (the second run) | exit 0; see below |

The M-5 reading is the [#581](https://github.com/coghex/hetoimasia/issues/581) behaviour: the restored window reported
itself drawable by itself, with no further sample (the earlier explicit-sample readings, revision 8 `visible=False` and
revision 9 `visible=True`, are history).

## M-6 lifecycle and exit evidence

* The command's log has the validation record once: "vulkan validation resolved" with `requested=true layer=enabled
  feature=enabled`.
* The session stopped with `interrupt=false quit=true` (the owner's close of the window, a quit, not an interrupt) and ended
  with `failures=0 verdict=VerdictSuccess`.
* The command exited 0. The owner saw the quad and closed the window ("looked good").

## Limits

* The native zero-area framebuffer row stays **unexercised** on macOS, as the pending file stated.
* The owner confirmed what a window presented; the retirement ordering evidence is the Linux lifecycle records and the
  host's own events, not these confirmations.
* The unattended macOS `--complete` receipt (54 examples, 0 failures) remains separate and still records the checkpoints as
  pending; this record is the owner's answer to them.
