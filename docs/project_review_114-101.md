# Project Review Findings: PRs #114–#101

Correctness and architecture audit of `coghex/hetoimasia` at
`727f59a1c04818958a127c64f69dbbf386b257c4`, completed on 2026-09-15 local
time. Reviewed exactly PRs **#114, #113, #112, #111, #110, #109, #108,
#107, #106, #105, #104, #103, #102, and #101**, newest first, against
their linked issues **#87–#100**, effective canonical specification
amendments, commits, merged changes, current consumers, and the accepted
GLFW/runtime design. The first-parent interval after `3a4c1c2` contains
these fourteen PR merges and no direct commits. All fourteen children are
closed; epics #86 and #49 remain open. This is a review, not an epic closure
or authorization to change the tracker.

The architecture remains aligned with the intended modular engine. Foundation
owns CPU resource collection and messaging; runtime owns supervision and the
application lifecycle; GLFW owns native session/window state. The runtime GLFW
adapter is a separate public Cabal sublibrary with its own source root. Native
handles and bindings remain private, applications receive narrow capabilities,
and no universal environment or game-specific manager has appeared. The host
is a scoped dependency constructed before supervision, with quiescence before
the supervision boundary drains workers. Dynamic windows, persistent command
outcomes, bounded input with explicit reset, and honest platform observations
are substantial, useful infrastructure.

Four current defects require bounded repairs before building GPU ownership on
top. Two existing tests currently require the problematic behavior, so a green
suite alone does not settle them. These findings do not call for replacing the
runtime or redesigning the component boundaries.

**Follow-up tracking:** The owner approved all four repair drafts, now filed
as #115–#118. Checked entries below mean the findings have been processed into
issues, not that the repairs have been implemented or verified.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Status

- [x] PRR-1. Preserve the creation failure when rollback cleanup also fails — [#115]
- [x] PRR-2. Keep disconnect recovery pending across ordinary window observation — [#116]
- [x] PRR-3. Restore the last windowed placement after a partial departure — [#117]
- [x] PRR-4. Protect the native fixture's borrower drain from repeated cancellation — [#118]

## 1. Dynamic construction failure

### [#115] PRR-1. Preserve the creation failure when rollback cleanup also fails

> **Captured note:** P1. PR #110 converts a native construction failure into
> an ordinary rejected ticket even when its context contains a failed rollback.
> The owner loop continues, and eventual collection exit promotes the cleanup
> exception to primary. Propagate the original fatal failure and its retained
> cleanup evidence through the host instead.

**Verification:** The existing `testRollbackCleanupPoisons` example passes at
the audited revision and demonstrates the defect. It injects a native error
during callback attachment and an `IOException` during window destruction.
The first ticket becomes `Rejected (WindowCreationFailed ...)`; the owner
executes later turns, including another creation rejected as poisoned; only
after the body returns does the collection throw `user error (release raised)`.
That cleanup exception, rather than the original native construction failure,
is asserted as primary. The native diagnostic survives in the first ticket's
copied data, but its exception and origin context no longer propagate as the
host's primary failure.

**Evidence:**

- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:567` —
  `createWindow` catches construction with context and converts a recognized
  native failure into `Completed (Left ...)` without checking retained cleanup
  failures.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Command.hs:1221` —
  `nativeRejectionOf` filters callback-origin failures, but otherwise extracts
  copied native data without preserving the exception context.
- `packages/foundation/src/Hetoimasia/Foundation/Resource/Collection.hs:364`
  — failed acquisition correctly latches cleanup failures and rethrows the
  original primary with them retained. The information is available to the
  host; the collection is not where it is initially lost.
- `packages/foundation/src/Hetoimasia/Foundation/Resource/Collection.hs:306`
  — when the host body subsequently returns successfully, final collection
  exit selects the first latched cleanup failure as primary.
- `packages/glfw/window-examples/Test/GLFW/Dynamic.hs:217` — the passing test
  explicitly expects continued execution, rejected tickets, and the cleanup
  exception as final primary.
- [Issue #95's authoritative amendment](https://github.com/coghex/hetoimasia/issues/95#issuecomment-5668018423)
  requires typed creation rejection to preserve the primary and cleanup
  evidence, with fatal failures continuing on the host failure path.

**Handoff context:**

- **Current behavior:** Construction plus failed rollback is treated as a
  recoverable command rejection. Poisoning prevents more creation, but does
  not restore the original failure or end the owner action at that boundary.
- **Expected behavior:** A cleanup-bearing construction failure propagates
  immediately with its original type, value, origin, and retained cleanup
  failures. Its claimed command settles through the existing interrupted
  outcome path; pending commands settle during normal quiescence. A recognized
  native construction failure with a clean rollback can remain a typed
  rejection.
- **Scope and constraints:** Repair the host's classification boundary and
  its regression expectations. Preserve collection poisoning, exactly-once
  cleanup, cancellation propagation, and deduplicated retained evidence. Do
  not turn cleanup exceptions into a second independently reported primary
  or retry a failed destructor.
- **Verification target:** Replace the wrong expectation in the coordinated
  dynamic test. Assert original native primary plus cleanup evidence, no
  subsequent normal owner turn, terminal tickets, and one rollback attempt.
  Keep clean-rollback rejection and construction-cancellation coverage.
- **Deduplication:** Open/closed search for `rollback creation` found the
  completed implementation issues, including #95, #87 and #90; no open repair
  tracks this surviving behavior. Epic #86 is the arc tracker.
- **Remaining uncertainty:** None about the observed failure replacement.
  No actual native destructor was made to fail; verification uses the existing
  production host/collection path with its deterministic native seam.

## 2. Window mode recovery

### [#116] PRR-2. Keep disconnect recovery pending across ordinary window observation

> **Captured note:** P2. PR #113 decides whether automatic disconnect fallback
> is needed solely from the current applied mode. An intervening ordinary
> observation can overwrite that mode with GLFW's already-windowed state and
> erase the obligation to execute the configured recovery.

**Verification:** An additional CPU probe used the production mode controller
and the existing two-monitor seam. It entered fullscreen on `left` with one
windowed fallback attempt, removed `left`, refreshed the monitor inventory,
called public `synchronizeWindow`, then ran the owner's `reconcileWindowMode`.
The ordinary observation reported `AppliedWindowed`; reconciliation returned
`WindowAvailable Nothing`. Geometry stayed at `(0,0), 1920x1080`, the seam's
post-disconnect native state, rather than executing restoration from the
saved `(40,30), 800x600` windowed placement. No fallback outcome was produced.

This is an ordering defect, not a claim that every monitor disconnect fails.
The normal loop's monitor-refresh-then-mode-reconcile path has a passing
disconnect test. It does not exercise an intervening observation, despite
observation being a supported owner operation.

Reproduction at the audited revision, without a native display:

```text
PKG_CONFIG_PATH=<prepared GLFW prefix>/lib/pkgconfig cabal repl exe:glfw-window-examples
:module *Test.GLFW.Mode
```

Run the following expression in that module's context:

```haskell
withDesk tracked $ \desk -> withWindowIn desk "review-disconnect" $ \window -> do
  _ <- execute desk [window]
    (mode window (modeRequest
      (fullscreenMode (deskLeft desk) currentVideoMode) (windowedFallback 1)))
  seamSetMonitorTopology (deskSeam desk)
    (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents (deskSeam desk) [MonitorDetached 1]
  _ <- synchronizeMonitors (deskSession desk)
  _ <- synchronizeWindow window
  print . modeApplied =<< recordOf window
  print =<< reconcileWindowMode window
  print =<< geometry window
```

Use GHCi's multiline delimiters for the expression. The probe owns and closes
all its resources through `withDesk` and `withWindowIn`.

**Evidence:**

- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:1518` —
  `presentationFrom` replaces the mode's applied state from every full native
  sample, including ordinary synchronization.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:1599` — public
  `synchronizeWindow` takes and reconciles such a sample.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:2183` —
  `reconcileWindowMode` computes `ended` only from the current applied mode's
  monitor. `AppliedWindowed` has no monitor, so fallback is skipped.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:720`
  — the ordinary loop orders monitor refresh before mode reconciliation;
  this explains why the existing straightforward disconnect example passes.
- [Issue #98's authoritative amendment](https://github.com/coghex/hetoimasia/issues/98#issuecomment-5668180207)
  requires recovery after an applied monitor disconnects without another user
  command, using reachable placement and preserving the saved placement.

**Handoff context:**

- **Current behavior:** Sampling truthful native state can accidentally cancel
  an unresolved recovery policy before it runs.
- **Expected behavior:** Truthful observations and pending recovery are
  distinct facts. An ordinary sample must not erase the required bounded
  fallback/disposition for the disconnected application of a mode. Preserve
  the observed native state; do not solve this by pretending the window remains
  fullscreen or treating requested mode as observed mode.
- **Scope and constraints:** Keep the fix in the mode controller's state and
  reconciliation contract. Preserve finite recovery, monitor identities,
  fullscreen claim safety, saved placement, and zero-monitor exhaustion.
  Recovery must not repeat indefinitely on subsequent samples.
- **Verification target:** Add the reproduced observation-before-recovery
  ordering alongside the normal ordering, including fullscreen and borderless
  cases. Assert one bounded recovery, the correct outcome and geometry, and
  no repeated attempt on later observations. Exercise the supported observation
  command path as well as direct synchronization.
- **Deduplication:** Open/closed `monitor fallback` search found closed #98
  and the open arc epic #86, but no repair issue for this ordering defect.
- **Remaining uncertainty:** Physical hotplug was not rerun during this audit.
  The reproduced failure is in production Haskell state handling; the seam
  supplies the native post-disconnect state.

### [#117] PRR-3. Restore the last windowed placement after a partial departure

> **Captured note:** P2. PR #113 captures the latest observed windowed geometry
> only after an entire departure succeeds. If decoration changes successfully
> but placement then fails, the window has left windowed mode while its saved
> placement is stale. A later successful return restores the wrong geometry.

**Verification:** A CPU probe extended `testPartialFailure`'s scenario. Start
at `(40,30), 800x600`, move the window to `(111,222)`, then request borderless
on `left`. Inject a reported error only into the placement step for that
borderless target, after decoration was successfully disabled. Permit the
subsequent explicit windowed return to succeed. The final placement is
`(40,30), 800x600`, losing the user's last valid `(111,222)` placement.

The existing test already exposes the stale cache but asserts it as correct:
it checks that the failed departure leaves an undecorated window while retaining
the original `(40,30)` cache. Its issue's acceptance requires the placement
cache to stay unchanged after a partial failure. That rule needs qualification:
preserving a successfully observed *pre-departure* windowed placement is not
recording the failed target as though it succeeded.

The probe used `Test.GLFW.Mode`'s helpers in GHCi, with this script override:

```haskell
tracked
  { scriptWindowControl = \call reporter -> case call of
      SetWindowMonitor _ 0 (-1900) _ _ _ _ ->
        reportError reporter platformErrorCode "placement failed"
      _ -> pure ()
  }
```

Inside `withDesk` and `withWindowIn`, run `seamDrive ... DuringPoll
[MovedTo 111 222]`, execute `borderlessOn (deskLeft desk)`, then execute
`windowed` and inspect `geometry`. The first command reports partial failure;
the second succeeds at the stale placement.

**Evidence:**

- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:1969` —
  `modeAttempt` computes `leaving` from the current observed windowed state.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:2008` — only the
  successful `runModeSteps` branch applies `recordSaved leaving`; a partial
  failure samples the resulting presentation without saving that known-good
  prior placement.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:2005` — the return
  plan uses `modeSavedPlacement`, so the stale cache becomes a real placement
  effect, not just inaccurate telemetry.
- `packages/glfw/window-examples/Test/GLFW/Mode.hs:540` —
  `testPartialFailure` asserts the stale cache and the resulting borderless
  applied mode but never tests the subsequent return.
- [Issue #98](https://github.com/coghex/hetoimasia/issues/98) requires user
  windowed movement to survive mode transitions, while its partial-failure
  acceptance broadly asks for an unchanged cache. This is partly a
  specification/acceptance defect, not merely an implementation deviation.

**Handoff context:**

- **Current behavior:** A partially successful departure loses the latest
  restorable placement; a later return can jump to initialization or an older
  successful departure's geometry.
- **Expected behavior:** When an attempted departure actually takes the window
  out of windowed presentation, subsequent restoration retains the last valid
  observed windowed placement. Failed target geometry never becomes the saved
  placement. Repeated inert requests, rejected requests without effects,
  return-to-windowed operations, and transitions between non-windowed modes
  must still obey the existing preservation rules.
- **Scope and constraints:** Clarify the cache invariant in the mode contract,
  adjust the departure/failure boundary, and repair the misleading test.
  Preserve cancellation, partial-step reporting, safe cleanup, constraints,
  and actual-versus-requested observations. Do not simply cache the native
  geometry observed after the failed target.
- **Verification target:** Prove move and resize survive both an immediate
  configured fallback and a later explicit return after partial departure.
  Retain successful-transition chains and refusal/no-effect checks; include
  constraints that make stale and current placements materially different.
- **Deduplication:** Open/closed `windowed placement` search returned closed
  #98 and #96; no open issue repairs this post-failure restoration behavior.
- **Remaining uncertainty:** None about the reproduced stale restoration.
  The exact safe cache update point belongs to the repair design; the report
  specifies behavior rather than prescribing a speculative state mutation.

## 3. Shared native fixture lifetime

### [#118] PRR-4. Protect the native fixture's borrower drain from repeated cancellation

> **Captured note:** P2. PR #107 waits for the Hspec borrower inside an
> interruptible exception handler. A second owner cancellation can escape that
> wait and release the shared resource before the borrower has settled.

**Verification:** A deterministic probe exercised the actual `runOwned`
fixture with a scripted `Scoped ()` resource; it did not initialize GLFW.
MVars coordinated every step, with no sleeps:

1. Dispatch a blocking operation and wait until the owner enters it.
2. Send the owner `ThreadKilled`. The borrower observes the resulting dispatch
   failure, signals that fact, and pauses before finishing.
3. Send the owner a second `ThreadKilled` while `stopServing` waits for the
   borrower's completion.
4. Wait for the scripted resource's release signal, then inspect the
   borrower's completion signal. It is still empty (`Nothing`).
5. Permit the borrower to finish and join the owner, leaving no probe thread
   running. The borrower result is `Right ()`; the defect is the order of
   release, not an intentionally failed assertion.

The eight existing scripted fixture examples also pass. They cover ordinary
failure/cancellation settlement but do not protect or test this second
cancellation during the drain.

**Evidence:**

- `packages/glfw/native-tests/Test/GLFW/Native/Fixture.hs:220` —
  `stopServing` marks the fixture ended and waits for `finished` using a
  blocking STM transaction.
- `packages/glfw/native-tests/Test/GLFW/Native/Fixture.hs:224` — the owner
  catches its first failure and invokes `stopServing` before rethrowing.
  A catch handler's masking is still interruptible at that STM wait.
- `packages/glfw/native-tests/Test/GLFW/Native/Fixture.hs:242` — the
  handler runs inside `withScoped`; a second cancellation escaping it causes
  resource release before the borrower is finished.
- `packages/glfw/native-tests/Test/GLFW/Native/Fixture.hs:263` — another
  `stopServing` occurs outside the resource scope, too late to keep the
  shared resource alive during the unfinished borrower's settlement.
- [Issue #93's authoritative amendment](https://github.com/coghex/hetoimasia/issues/93#issuecomment-5667981576)
  explicitly requires observable teardown proving borrowers settle before
  session release, preserving primary and cleanup evidence.

**Handoff context:**

- **Current behavior:** Repeated cancellation can make fixture teardown
  precede Hspec borrower settlement, contrary to its shared-lifetime guarantee.
- **Expected behavior:** Once settlement begins, keep the owned resource alive
  until the borrower has finished, even if the owner receives further
  cancellation. Preserve the initiating failure and all cleanup evidence;
  settle dispatched/queued replies without double execution or release.
- **Scope and constraints:** This is the test-only native dispatcher, not a
  finding against runtime worker supervision. Follow the accepted protected
  drain policy rather than detaching a stuck borrower or inventing a timeout.
  Avoid introducing synchronizing cancellation delivery into an uninterruptible
  release. No generic second runtime framework is needed.
- **Verification target:** Add a gated repeated-owner-cancellation example to
  the scripted fixture harness. Prove release cannot happen before borrower
  completion, the first failure remains primary, cleanup evidence survives,
  queued operations settle, and acquisition/release counts remain correct.
- **Deduplication:** Open/closed `fixture cancellation` search found completed
  #93 and the open tracking epics #49/#86, but no specific repair. Foundation
  worker issues concern a separate implementation.
- **Remaining uncertainty:** No native use-after-free was demonstrated. The
  verified defect is premature scope release in the fixture protocol; its
  importance increases when later fixtures borrow GPU-dependent resources.

## Review coverage and validation

| PR | Issue / slice | Reviewed focus at current HEAD |
| --- | --- | --- |
| #114 | #100 / GLFW-12 | Native input callback capture, staging bounds, reset, closure, ownership |
| #113 | #98 / GLFW-6 | Mode transitions, claims, constraints, restoration and fallback; PRR-2/3 |
| #112 | #99 / GLFW-8 | Prepared input, overflow/reset protocol, held state and reader lifetime |
| #111 | #96 / GLFW-5 | Validated controls, native outcomes, constraints, observation revisions |
| #110 | #95 / GLFW-9 | Dynamic registration, retirement, capability handoff, fair ports; PRR-1 |
| #109 | #97 / GLFW-11 | Monitor inventory, pointer reuse/disconnect identity, zero-monitor handling |
| #108 | #94 / GLFW-3 | Dependency-owned host, bounded loop, callbacks, supervision and shutdown |
| #107 | #93 / GLFW-7 | Shared fixture, real thread checks, display runner routing and receipts; PRR-4 |
| #106 | #91 / GLFW-13 | Command admission, persistent completion, interruption and quiescence |
| #105 | #90 / GLFW-2 | Window assembly, rollback, callback lifetime and coherent observations |
| #104 | #92 / GLFW-4 | Generic pre-drain quiescence hook and failure preservation |
| #103 | #89 / GLFW-1 | Private native binding, main-thread session, native error capture |
| #102 | #88 / GLFW-14 | Pinned native recipe, static link discovery, public image identity and caching |
| #101 | #87 / GLFW-10 | Collection ownership, early release, borrowing, poisoning and bounded bookkeeping |

Local verification at the audited HEAD, using GHC 9.12.2 and Cabal 3.16.1.0:

- `python3 tools/native/native.py prepare --build-dir dist-newstyle` verified
  the local private GLFW prefix and prepared the build stamp.
- `cabal build all` passed.
- `cabal test hetoimasia-tests --test-show-details=direct` passed:
  **517 examples, zero failures**, including the GLFW CPU/model subprocess
  coverage. The count is the outer engine suite's reported count.
- `cabal test workflow-tests --test-show-details=direct` passed:
  **331 examples, zero failures**.
- `cabal test glfw-native-tests --test-show-details=direct
  --test-options='--match "with a scripted owner"'` passed:
  **8 examples, zero failures, zero native session acquisitions**.
- `python3 tools/native/native.py link-check` passed against the prepared
  static library and explicit macOS frameworks; GLFW reported version 3.4.0.
- `cabal run exe:hetoimasia -- --smoke` passed without a display.
- Additional coordinated CPU/fixture probes reproduced PRR-2, PRR-3 and PRR-4.
  PRR-1 is demonstrated by the existing passing dynamic rollback test and its
  current host/collection failure path. No production source or test file was
  changed by this audit.

The real Linux X11 worker on
[PR #114's validation run](https://github.com/coghex/hetoimasia/actions/runs/35040834782/job/104620144575)
executed **55 examples, zero failures, one pending**. It acquired the shared
session once, recorded 43 native operations on the process main thread, passed
setup/teardown thread checks, and wrote the native receipt. The pending example
is physical monitor hotplug, explicitly unexercised on Xvfb. The
[current master run](https://github.com/coghex/hetoimasia/actions/runs/35041276109)
is green and reused compatible test evidence; it did not rerun the native
suite. Its dependency-cache seed did execute successfully.

No interactive Cocoa launch or hardware hotplug was rerun during this review.
Existing native evidence and Linux logs were inspected; local build, static
linking and CPU tests are not claimed as fresh visual/native verification.
No additional confirmed fixed-later or already-tracked defect needs a new
entry from this batch.

## Direction after these repairs

Keep the architecture. The CI design still separates CPU and display work,
keeps required-when-affected native checks outside the floor, reuses compatible
evidence, and provisions the pinned GLFW toolchain through cached artifacts.
Remote macOS CI has not been introduced. The current concrete components are
adequate foundations for the next design phase once these failure paths are
repaired.

Before Vulkan, explicitly design GPU completion and surface/window retirement
together: CPU scope exit or collection retirement alone must not become proof
that submitted GPU work has finished. Rendering will also need explicit frame
scheduling; the current owner loop's idle decision counts dispatched commands
and events, not renderer demand. Those are expected next-phase contracts, not
missing deliverables of this GLFW arc.

The private window implementation has grown past two thousand lines. A small
internal split around capture/observation, controls and modes would help as
those areas change, while preserving the existing public boundary. It is a
maintainability observation, not a fifth correctness issue or a reason to
delay the bounded repairs behind a broad refactor.
