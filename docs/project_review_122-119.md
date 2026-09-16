# Project Review Findings: PRs #122–#119

Review of `coghex/hetoimasia` at
`e2d30ea229f105716bfb19a13549a5e998a5994e`, completed 2026-09-16. Reviewed
exactly PRs **#122, #121, #120, and #119**, newest first, against issues
**#118, #117, #116, and #115**, including their canonical issue-review
amendments, final merged patches, commits, current callers, tests, comments,
and contracts. The first-parent interval after `5d381cf` contains these four
merges and no direct commits. All four issues are closed; epics #86/#49 remain
open. No source code or tracker item was changed by this review.

The architecture remains aligned with the accepted runtime: small owning
components, private native capabilities, ordinary CPU scopes under component
lifecycle policies, and retained primary/cleanup evidence. The fixes do not
introduce a global environment, new dependencies, duplicate ownership, or
unrelated generated scaffolding. The changes are focused and readable. One
current mode-recovery defect prevents treating the repair batch as complete.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Status

- [x] PRR-1. Follow the live observed monitor when maintaining disconnect recovery — [#123]

Checked means filed, not repaired. The owner approved the follow-up and it was
filed as [#123](https://github.com/coghex/hetoimasia/issues/123) on 2026-09-16.

## 1. Recovery after a later borderless placement

### [#123] PRR-1. Follow the live observed monitor when maintaining disconnect recovery

> **Captured note:** P2. PR #120 fixes observation erasing pending recovery by
> remembering a monitor only when a mode request settles. That association
> becomes stale when a later legitimate observation moves a borderless window
> onto another still-connected monitor. Disconnecting its current monitor then
> skips recovery; disconnecting the old monitor instead needlessly restores
> windowed mode. Preserve unresolved disconnect recovery without freezing the
> live monitor association at command settlement.

**Verification:** Four additional coordinated Hspec cases, compiled against
the unchanged production libraries at `e2d30ea`, all fail. They reuse the
existing `Test.GLFW.Mode` desk, production controller, and scripted native seam:

1. Create the usual two-monitor desk, with left/A and right/B both live.
2. Enter borderless on A with `windowedFallback 1`.
3. Deliver `MovedTo 100 200` while both monitors are still connected. Assert
   the published applied mode is now `AppliedBorderless B`.
4. Disconnect B, leaving A live; refresh the inventory; reconcile window mode.
   Expected: configured bounded windowed fallback. Actual:
   `WindowAvailable Nothing`.
5. In a fresh case, repeat steps 1–3 and disconnect A instead, leaving B live.
   Expected: keep the observed borderless presentation on B, with no fallback
   setters. Actual: `ModeApplied WindowedFallbackAttempt`, restoring the seeded
   windowed `(40,30), 800x600` placement.

Both cases fail with and without a `synchronizeWindow` between inventory refresh
and mode reconciliation. Result: **4 examples, 4 failures**, seed `1333029724`.
These are CPU seam tests; no GLFW session or real window was initialized.

This is not a new requirement to follow arbitrary requested geometry. The
existing `testDelayedBorderlessConvergence` already verifies observed movement
from A to B through the owner loop. It stops before disconnecting either
monitor. The new obligation no longer follows that established applied-state
behavior. Before PR #120, reconciliation used the applied monitor itself;
static comparison with `020833d` confirms that the new frozen association is
introduced by this repair. The former implementation's observation-loss defect
must remain fixed; reverting to applied state alone is not a solution.

**Evidence:**

- `packages/glfw/model/Hetoimasia/GLFW/Internal/Mode.hs:446` — private recovery
  identity is documented as established only at settlement.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Mode.hs:488` — ordinary applied
  updates leave that identity untouched.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Mode.hs:505` — settlement derives
  the identity from the sample at that instant.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:1525` — full samples
  publish new applied state through the ordinary updater.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:1540` — a movement
  callback re-derives borderless presentation on the newly observed monitor.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:2207` — recovery tests
  only the retained identity against live monitors.
- `packages/glfw/window-examples/Test/GLFW/Mode.hs:466` — the existing accepted
  delayed-placement example confirms that a later observation may move the
  applied monitor without another mode command.
- `docs/glfw.md:1578` — the contract repeats the settlement-only association;
  its correction belongs in the repair PR with the implementation.

The local reproduction is retained at
`/var/folders/xs/kyf0vrg92c340wk3jncyp1fr0000gn/T/hetoimasia-repair-review-7t10e5y_/`:
`Main.hs`, `build-command.json`, `build.log`, `probe`, and `result.log`.
The source is a temporary copy of `Test.GLFW.Mode`, renamed as a standalone
entry point, with the four extra examples. Original production/test sources
were not edited. The essential test below is reusable beside that module's
existing helpers; run the two Boolean arguments over all four combinations.

```haskell
probeMonitorChange disconnectCurrent observeAfter =
  withDesk tracked $ \desk -> withWindowIn desk "review" $ \window -> do
    let seam = deskSeam desk
    entering <- execute desk [window]
      (mode window (modeRequest (borderlessMode (deskLeft desk)) (windowedFallback 1)))
    entering `shouldSatisfy` appliedCleanly
    _ <- seamDrive seam window DuringPoll [MovedTo 100 200]
    before <- recordOf window
    modeApplied before `shouldBe` AppliedBorderless (deskRight desk)
    let topology = if disconnectCurrent
          then MonitorTopology (Just [(1, leftMonitor)]) 1
          else MonitorTopology (Just [(2, rightMonitor)]) 2
        disconnected = if disconnectCurrent then 2 else 1
    seamSetMonitorTopology seam topology
    seamDeliverMonitorEvents seam [MonitorDetached disconnected]
    reconcileMonitorEvents (deskSession desk)
    when observeAfter (synchronizeWindow window >> pure ())
    callsBefore <- setterCalls desk
    result <- reconcileWindowMode window
    callsAfter <- setterCalls desk
    if disconnectCurrent
      then result `shouldSatisfy` \case
        WindowAvailable (Just (ModeApplied WindowedFallbackAttempt _ _)) -> True
        _ -> False
      else do
        result `shouldBe` WindowAvailable Nothing
        callsAfter `shouldBe` callsBefore
```

**Handoff context:**

- **Current behavior:** applied state can follow B while recovery remains tied
  to A. This can strand a borderless window after B disconnects or cause an
  unrelated A disconnect to change the user's working presentation.
- **Expected behavior:** when observations establish movement onto a different
  live monitor while the previous monitor remains live, recovery follows that
  observed connection. When a disconnect has occurred, subsequent observations
  must instead preserve its unresolved recovery. A settled recovery stays
  settled. Requested mode is not proof of applied mode.
- **Scope and constraints:** one controller repair after #116/PR #120, including
  its tests and the affected Mode/Window/host comments and `docs/glfw.md`.
  Preserve saved-placement repairs, bounds, exactly-once settlement, monitor
  generations, truthful observations, optional recovery policy, and existing
  cancellation/cleanup semantics. No new native API, scheduler, or Vulkan work.
- **Verification target:** extend CPU Hspec coverage across later placement,
  both monitor-disconnect choices, callback and full-observation paths, both
  inventory/observation orderings, and no repeated fallback. Existing #116
  regressions, #117 restoration coverage, headless tests, local Cocoa, and
  selected Linux native checks must pass in the repair PR.
- **Deduplication:** open tracker contains only epics #86/#49. Searches over
  open and closed issues for `borderless monitor`, `recovery convergence`, and
  `monitor migration` found no follow-up covering this sequence. Closed #116
  repairs observation loss after disconnect; this finding concerns changed live
  monitor association before disconnect. #86 has no separate child for it.
- **Remaining uncertainty:** not reproduced through physical monitor hotplug.
  The failure is deterministic in the production controller and does not depend
  on a particular native driver's timing. Exact replacement state representation
  is intentionally left to the solver.

## 2. Other repairs and verification

- **#115 / PR #119:** retained cleanup evidence is checked before ordinary
  rejection classification. The original construction exception propagates,
  the executing ticket is interrupted, queued tickets settle through quiescence,
  and collection teardown preserves/deduplicates rollback evidence. The new
  assertions check a real failing construction and exactly-once release. No
  additional correctness defect found.
- **#117 / PR #121:** preserves the observed pre-departure tuple on reported
  partial failure and on interruption after a native step. Both immediate
  fallback and later explicit return use it; the constraint regression rejects
  stale geometry before the repair. No additional correctness defect found.
- **#118 / PR #122:** the final implementation uses interruptible masking around
  scope orchestration, restores the caller's masking state for served operations,
  installs settlement protection before acquisition hands over, absorbs repeated
  cancellation while draining, and records the initiating failure with cleanup
  evidence before deferred cancellation can replace it. The initial PR's
  uninterruptible acquisition and later handoff gap were corrected by its final
  commits; neither remains in the merged code. No additional correctness defect
  found in the requested scope.
- **Fixed during PR #120:** a no-fallback disconnect obligation is consumed by
  its resample. The final code includes that review repair. Indeterminate applied
  state retains its separately documented resampling behavior.

Local checks at `e2d30ea`, GHC 9.12.2 / Cabal 3.16.1.0, using the prepared
native prefix under `~/.cache/hetoimasia/native/glfw`:

```text
python3 tools/native/native.py prepare                                  PASS
cabal build all                                                        PASS
cabal test hetoimasia-tests --test-show-details=direct
  --test-options='--match GLFW'                                         55 examples, 0 failures
cabal test glfw-native-tests --test-show-details=direct
  --test-options='--match "with a scripted owner"'                       13 examples, 0 failures
cabal test glfw-native-tests --test-show-details=direct
  --test-options='--dry-run'                                            60 discovered; no native acquisition
additional mode-recovery Hspec probes                                   4 examples, 4 failures
```

The scripted fixture run also reported zero native acquisitions. The focused
GLFW engine group runs the package's full window-model executable, including
the mode and dynamic-window cases, as well as public API opacity tests. The
new failing probe uses actual merged libraries, with no production patch.

Verified the final PR #122 Linux
[native job](https://github.com/coghex/hetoimasia/actions/runs/35140642389/job/104944057215):
60 examples, zero failures, one pending physical-hotplug check; one shared
session, 43 owner operations, one declined operation, and all native main-thread
checks passed. The same run's
[engine job](https://github.com/coghex/hetoimasia/actions/runs/35140642389/job/104944057464)
passed 517 engine examples and console smoke. The merge's
[master run](https://github.com/coghex/hetoimasia/actions/runs/35141348573)
passed by reusing compatible receipts; it did not rerun these workers. This
review did not rerun interactive Cocoa tests or claim fresh physical-hotplug
evidence.

One follow-up issue is warranted before closing the GLFW repair arc. Clock,
deadline, and wake design can proceed independently, but that next arc must not
obscure this remaining controller defect. The prior unpublished Vulkan design
changes in the docs worktree were preserved.
