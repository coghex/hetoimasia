# LFE-20 (#535): the two native `scene retention` failures, diagnosed

Evidence for PR #572 (`issue-535-lfe20-scene-publication`), written for the round 6 owner decision: reproduce the
two observed failures at `Native/Scenes.hs:69` (`expected: 1 but got: 0`, the live-texture count reading zero
before the scene was replaced) under instrumentation, and decide whether the cause is premature retirement (a
retention bug), a backend failure, or a legitimate window or target teardown.

## Verdict

**None of the three. The two failures were produced by a stale native test executable that still carried the
negative-control mutation I had built a minute earlier; the committed source never retired a held texture.**

The mutation was "the release of a delivered texture ignores the holds" (`deliveredReleaseAction` releases the
table handle when `deviceHeld` is true). I built it into `dist-vulkan` to record the negative control, restored the
source in the same command, and then ran `tools/vulkan/run.sh native` three times before the next
`tools/vulkan/run.sh build`. `run.sh native` does not rebuild, and its header (`repository revision`,
`source digest`) describes the source tree at run time, not the executable, so the stale runs reported a clean
tree. There is no product bug, no backend failure and no teardown in the product code; nothing in the product code
changes for this finding.

## What was observed

Local clock (PDT), 2026-10-29, from the run logs in the solver's scratchpad (`logs/r4`):

| Time | Event |
| --- | --- |
| 19:13:54 | `Backend.hs` copied to `Backend.orig`; the holds-ignored mutation applied |
| 19:14:09 | `run.sh build` of `lua-engine-graphics-native-tests`: the executable now contains the mutation |
| 19:14:13 | one `--match 'scene retention'` run of that executable (4 examples, all passed: the mutation fails an example about half the time, so this is unremarkable) |
| 19:14:13 | the source restored from `Backend.orig` (end of the same command; `git status` clean) |
| 19:15:05 | `--complete` run 1: **failed** at `Scenes.hs:69`, `expected: 1, but got: 0`; header `repository revision 8f7b923b…` (no `(dirty)`) |
| 19:15:29 | run 2: passed |
| 19:15:31 | run 3: **failed**, the same check |
| 19:15:34, 19:15:35 | runs 4 and 5: passed |
| 19:16:02 | the next `run.sh build` (a diagnostic variant): the executable is relinked from the restored source |
| 19:16:10 onward | about 300 `--complete` runs of the rebuilt executable (plain, under CPU burners, with GPU suites in parallel, with the diagnostic, with the final head): **no failure** |

Two failures in the five runs before the first rebuild, none in the 300 after it. That is the signature of a
changed executable, not of a rare race: the failure rate is about 50% (below) before the rebuild and zero after it.
The earlier explanation I gave in the PR, an unexplained environmental intermittent, was wrong; I had not looked at
the build order.

The line-69 check is the second `readingLive … shouldBe 1` of the first example: after Lua released the texture,
the first check (one live texture) passed, a frame was recorded with revision 1, and the second check found no
live texture. That is exactly what a release that proceeds under the hold produces (the release is in progress, so
one texture is still non-terminal, then it retires).

## Reproduction, with the sources the failures had

Instrumentation (temporary, not committed; `patch.py` in the solver's scratchpad `exp/`): the test source as of
`8f7b923b` (the count checks the two failures hit), a watcher thread that logs every change of
`(texture stages, ledger holds, host scene state)` with a monotonic timestamp, and one line at the top of
`deliveredReleaseAction` logging what `deviceHeld` answered and which branch ran. Events are ordered by the
timestamps of the STM changes themselves; nothing sleeps.

| Executable | Source | `--complete` runs | Failures |
| --- | --- | --- | --- |
| mutated (holds ignored) + trace, series 1 | tree dirty | 12 | 8 |
| mutated (holds ignored) + trace, series 2 | tree dirty | 12 | 6 |
| **the stale executable**: the mutated one, source restored without rebuilding | tree clean, header `b6504279`, committed digest | 8 | 3 |
| clean + trace + old count checks | committed `Backend.hs` | 40 | **0** |
| rebuilt from the committed head | `b6504279` | 60 | **0** |

The third row is the observed situation reproduced: a clean tree, a clean header, the committed digest, and
failures at the same check, with the trace still printing `RELEASING UNDER THE HOLD (mutation)` from the old
executable.

### The failing run (mutated executable): premature retirement, hold still recorded

`win:` is the host's scene state for the one window (`pub` the latest published revision, `adopted` the revision
its target holds, `awaiting` the revisions awaiting release); `holds` is the ledger's held texture identities;
`stages` is every non-terminal texture's stage (empty: retired). Times are seconds from the example's first event.

```
+0.000  stages=[] holds=[] win:[]
+0.059  stages=[] holds=[] win:[pub=0 adopted=0 awaiting=[]]
+0.066  stages=["live"] holds=[] win:[pub=0 adopted=0 awaiting=[]]                          texture loaded
+0.066  stages=["live"] holds=[] win:[pub=1 adopted=0 awaiting=[]]                          Lua publishes revision 1
+0.066  stages=["live"] holds=[17179869184] win:[pub=1 adopted=1 awaiting=[0]]              the owner adopts it; the hold is recorded
+0.074  release action on the owner: held=True -> RELEASING UNDER THE HOLD (mutation)       Lua released the texture
+0.076  stages=["releasing"] holds=[17179869184] win:[pub=1 adopted=1 awaiting=[]]
+0.076  stages=["retiring"] holds=[17179869184] win:[pub=1 adopted=1 awaiting=[]]
+0.079  stages=[] holds=[17179869184] win:[pub=1 adopted=1 awaiting=[]]                      retired: hold recorded, revision 1 still adopted
        (the check at Scenes.hs:69 reads zero live textures and fails; the window is then torn down by the example's cleanup)
```

### The same example on the committed source: held, then released only once the hold ended

```
+0.000  stages=[] holds=[] win:[]
+0.038  stages=[] holds=[] win:[pub=0 adopted=0 awaiting=[]]
+0.044  stages=["live"] holds=[] win:[pub=0 adopted=0 awaiting=[]]
+0.045  stages=["live"] holds=[] win:[pub=1 adopted=0 awaiting=[]]
+0.045  stages=["live"] holds=[17179869184] win:[pub=1 adopted=1 awaiting=[0]]
+0.048  stages=["release-requested"] holds=[17179869184] win:[pub=1 adopted=1 awaiting=[]]
+0.049  stages=["releasing"] holds=[17179869184] win:[pub=1 adopted=1 awaiting=[]]
+0.049  release action on the owner: held=True -> deferring: an adopted scene holds the texture
+0.049  stages=["held"] holds=[17179869184] win:[pub=1 adopted=1 awaiting=[]]
+0.061  stages=["held"] holds=[17179869184] win:[pub=2 adopted=1 awaiting=[]]                replacement published
+0.061  stages=["held"] holds=[17179869184] win:[pub=2 adopted=2 awaiting=[1]]              replacement adopted; revision 1 awaits release
+0.063  release action on the owner: held=False -> releasing the table handle                revision 1 released: the hold ended
+0.063  stages=["releasing"] holds=[] win:[pub=2 adopted=2 awaiting=[]]
+0.063  stages=["retiring"] holds=[] win:[pub=2 adopted=2 awaiting=[]]
+0.063  stages=[] holds=[] win:[pub=2 adopted=2 awaiting=[]]                                 retired, after the hold
```

(The watcher wakes on STM changes and may coalesce two adjacent ones, as `release-requested` is missing from the
first trace; the release action's own line is written on the owner's thread and is not coalesced.)

## The three candidate causes, against the traces

* **Premature retirement in the product (a retention bug)?** No. On the committed source the release action reads
  `held=True` and defers every time it is asked under an adopted scene (198 times across 40 traced runs, none
  released under a hold); the texture stays `held` until the replacement is adopted and the old revision is released, and
  only then releases the table handle. The retirement-with-hold-recorded sequence appears only when the executable
  contains the mutation.
* **A backend failure?** No. No trace of the 72 traced runs (series 1 and 2, the stale runs, and the clean series) passes through a failed stage or carries a failure text; the
  stages seen are `live`, `release-requested`, `releasing`, `retiring` and retired (empty), with no `TexFailed`
  and no recorded defect (`readingDefects` is checked by the examples that pass).
* **A legitimate window or target teardown?** No. In the failing traces the window stays published 1 and adopted 1
  with the hold recorded while the texture retires; no target ended and no hold ended before the retirement. (The
  ledger releases a revision when its target ends or a newer one is adopted; neither happened.) The re-ask after the
  last hold goes through the barrier lane, so a window whose target was replaced would still keep its texture
  (`Texture.Backend`, the `TexHeld` step); this run exercised no replacement.

## Why the earlier hunt found nothing

Every run after 19:16:02 was of a rebuilt executable, so none could reproduce a failure that only the stale
executable had. The CPU-burner, GPU-load and diagnostic series were all of that kind. The evidence was
informative about the product (about 300 clean passes) and misleading about the cause, which I should have found
by comparing the failing runs' times with the build log. The weak oracle was a separate, real finding (the count
check failed only about half the time under the mutation), and round 5's change to assert the `held` stage already
makes the check strict: the holds-ignored mutation fails 6 of 6 natively with it.

## Fixes and the sweep (D-80)

* **Product code:** none; there is no defect.
* **Test synchronization:** none needed beyond round 5's (`awaitHeld`/`expectHeld` assert the `held` stage and fail
  with the stages, the ledger and the scene state). The deterministic example for the invariant is the headless
  `scene retention` matrix (the holds-ignored mutation fails 5 examples, each in at most 4 s) and the native
  held-stage checks (6 of 6).
* **The shape: a verification run whose executable is not the source it reports.** The sites in this work:
  `run.sh native` (does not rebuild; header describes the tree) and every negative control that restored a
  mutated source. Every native run recorded in the PR body is now preceded, in the same command, by
  `run.sh build` of the same component, and the final-head record names that. The headless groups
  (`run.sh test`, `cabal test`) rebuild what they run and cannot be stale. I did not change `tools/vulkan/run.sh`
  (outside #535's scope); a follow-up for it would be to refuse `native` when the executable is older than the
  newest input, or to record the executable's own build identity in the header.

## Reproducing

From the worktree (toolchain and `PKG_CONFIG_PATH` as in `docs/toolchain.md`), with the temporary patch applied:

```
python3 -I patch.py mutated      # or: clean
bash tools/vulkan/run.sh build hetoimasia-lua-engine-graphics:lua-engine-graphics-native-tests
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:lua-engine-graphics-native-tests -- --complete
git checkout -- packages/lua-engine-graphics      # and do not rebuild: the stale executable keeps failing
```
