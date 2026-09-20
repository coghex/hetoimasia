# Owner-loop progress during macOS window interactions: RR-4's verdict

**Observed, not inferred: a Cocoa live resize and a Cocoa menu-bar interaction
each block the owner turn's native event call for as long as the person keeps
interacting.** The longest measured block is **68.92 s** during a window resize
and **13.30 s** during menu navigation. For the whole of each block no owner
turn began and no update opportunity was offered.

**Observed, and the useful negative: a Cocoa window move does not block it.**
Across 20 s of continuous title-bar dragging the loop took 2128 turns and
offered 2128 update opportunities, and its longest stretch without one was
101.1 ms — the configured idle wait.

**This verdict chooses nothing.** [What the owner has to
decide](#what-the-owner-has-to-decide) states the three candidate policies RR-4
names and what the measurement says about each. Choosing one is a reviewed
design decision before VK-16.

This is a Cocoa result. No Linux or X11 run substitutes for it, and none was
used here.

## Identities

| | |
| --- | --- |
| OS | macOS 26.6 (`25G5065a`), arm64 |
| GLFW | 3.4 (`glfw3.pc` reports `3.4.0`), static Cocoa build from `tools/native/glfw.pin`, deployment target 13.0, native manifest `f28f062c0b13c9ec8d4d3627a06e7abc545d5661c7572bce73e3453f25e6354a` |
| Compiler | GHC 9.14.1, Cabal 3.18.1.0; Apple clang 21.0.0 built the prefix |
| Measured revision | `50e9b31`, the commit that adds the probe, on `issue-200-owner-loop-interaction-probe` off `master@d40c387` |
| Loop | `runOwnerLoop` over one `WindowHost` in the shared native session |
| Pacing | `defaultHostConfig`: idle wait **0.100 s**, command budget 16, event budget 16, window limit 16, one shown 640×480 window |
| Human approval | The owner was told what the run does to the desktop and approved each session before it ran, on 2026-09-20. Three sessions were approved and run. |

## The approved commands

Each was run from the issue worktree with the qualified toolchain on `PATH` and
`PKG_CONFIG_PATH` naming the prepared GLFW prefix, exactly as written, and
nowhere else:

```bash
HETOIMASIA_NATIVE_SESSION=desktop \
HETOIMASIA_INTERACTION_PROBE_SECONDS=20 \
HETOIMASIA_INTERACTION_PROBE_OUTPUT=/tmp/owner-loop-interaction-trace-2.tsv \
  cabal test glfw-native-tests --test-show-details=direct \
  --test-options='--match "/GLFW native/owner-loop progress during window interactions/"'
```

```bash
HETOIMASIA_NATIVE_SESSION=desktop \
HETOIMASIA_INTERACTION_PROBE_SECONDS=10 \
HETOIMASIA_INTERACTION_PROBE_OUTPUT=/tmp/owner-loop-interaction-trace-3.tsv \
  cabal test glfw-native-tests --test-show-details=direct \
  --test-options='--match "/GLFW native/owner-loop progress during window interactions/"'
```

The second produced the move and resize numbers below; the third produced the
menu-bar numbers and corroborates the other two. A first session, at 20 s,
preceded both and is reported separately under [the first
session](#the-first-session-attribution-unreliable) because its phases cannot be
attributed.

`HETOIMASIA_NATIVE_SESSION=desktop` authorized only the one command it was
written on. `HETOIMASIA_INTERACTION_PROBE_SECONDS` is what makes the probe run
at all; without it the example is pending and opens no window, which is how the
mandatory `test.glfw-native` group meets it. See
[docs/glfw.md](glfw.md#the-interaction-probe).

## How it was measured

The session's bounded interaction trace
(`Hetoimasia.GLFW.Internal.Trace`) stamps, from one monotonic clock: each owner
turn's beginning with its number; the native call's entry and exit, with whether
it polled or waited and the seconds it asked for; each window callback as it is
delivered, before it copies its payload; and the update hook's entry and exit.
Recording is one clock reading and one non-blocking `IORef` update under
`uninterruptibleMask_` — no sink, no lock, no wait, no output — so the
measurement adds no synchronous logging stall of its own. Nothing is printed
inside a measured interval; the phase banners and the whole report are printed
between intervals and after the run.

Because every record shares one clock and one order, a callback delivered from
inside a blocked native call appears **between** that call's entry and its exit.
That is the whole mechanism of the finding.

The storage is bounded at 32768 records per phase and reports what it could not
keep: it numbers dropped records so a gap is visible, counts a recording it
could not make as a fault, and marks evidence with either count above zero as
incomplete. **Every phase of every session reported 0 lost and 0 faults**, so no
number below is read from truncated evidence, and no absence below is a missing
record.

## What was measured

Read every duration as: the person was interacting for about that long, and the
block lasted as long as the interaction. None of these is a timeout or a bound
the loop chose — the call simply did not return.

### Idle baseline — no stall

| Session | Span | Owner turns | Update opportunities | Longest stretch with no update opportunity | Callbacks |
| --- | --- | --- | --- | --- | --- |
| 20 s | 20 057 ms | 311 | 311 | **101.1 ms** | 128 — 125 cursor position, 1 cursor enter, 1 focus, 1 refresh |
| 10 s | 10 041 ms | 102 | 102 | **101.1 ms** | 2 — 1 focus, 1 refresh, both inside the creation poll |

101.1 ms is the configured 100 ms idle wait plus about 1.1 ms. This is what
ordinary waiting looks like, and it is the baseline every number below is read
against.

### Window move — no stall

The person pressed and held the title bar and dragged the window continuously
for the whole phase.

| Session | Span | Owner turns | Update opportunities | Longest stretch with no update opportunity | Callbacks |
| --- | --- | --- | --- | --- | --- |
| 20 s | 20 003 ms | 2128 | 2128 | **101.1 ms** | 299 — 151 `window position`, 112 cursor position, 36 cursor enter |
| 10 s | 10 002 ms | 1113 | 1113 | **101.1 ms** | 182 — 74 `window position`, 107 cursor position, 1 cursor enter |

2128 turns in 20.003 s is one turn every 9.4 ms: the finite waits were returning
early on arriving events rather than running out their 100 ms. No pump interval
in either session exceeded its requested bound by more than 1.2 ms. **On this
macOS and GLFW build a window move runs no blocking modal loop; position events
are delivered to the ordinary pump and the owner loop keeps full progress.**

### Window resize — stall observed

The person pressed and held a corner and dragged continuously.

| Session | Longest single native call | Requested bound | Over by | Callbacks delivered from inside that one call |
| --- | --- | --- | --- | --- |
| 20 s | **68 918.5 ms** | 100.0 ms | 68 818.5 ms | **22 945** — 7648 `window size`, 7648 `framebuffer size`, 7648 `window refresh`, 1 cursor enter |
| 10 s | **9645.6 ms** | 100.0 ms | 9545.6 ms | **3238** — 1079 `window size`, 1079 `framebuffer size`, 1079 `window refresh`, 1 cursor enter |

For the whole of each block: **no owner turn began, and no update opportunity
was offered.** In the 20 s session the resize phase recorded 366 turns over a
72 493 ms span, and 68 918 ms of that span is the one call. In the 10 s session
it recorded 165 turns over 11 287 ms, of which 9646 ms is the one call.

Two things about the callbacks matter beyond the count:

- Cocoa delivers a **complete redraw request set** — logical size, framebuffer
  size, and refresh — at about **111 per second** throughout the block (7648
  sets in 68.92 s; 1079 in 9.65 s). The platform is asking the application to
  redraw, continuously, for the entire time the application cannot act.
- Those callbacks behaved exactly as
  [their contract](glfw.md#callbacks-and-the-reconciliation-boundary) says:
  each recorded into the window's capture latch and returned. Nothing was
  reconciled, published, or drawn until the call returned and the turn reached
  its next owner boundary, where the 7648 sizes coalesce into one observation.
  The example passed, so no latched callback fault was rethrown at the
  following boundary, and the trace itself recorded no recording fault.

### Menu-bar interaction — stall observed

The person opened a menu in the macOS menu bar three times: twice briefly, then
once held open while actively moving up and down a submenu's items until the
phase ended.

| Block | Native call | Requested bound | Over by | Callbacks delivered from inside |
| --- | --- | --- | --- | --- |
| first menu | **2435.5 ms** | 100.0 ms | 2335.5 ms | 1 cursor position, at +2434.1 ms |
| second menu | **2245.2 ms** | 100.0 ms | 2145.2 ms | 2 cursor position, at +2243.9 ms |
| submenu navigation | **13 295.1 ms** | 100.0 ms | 13 195.1 ms | 2 cursor position, at +13 292.8 ms |

For the whole of each block: **no owner turn began, and no update opportunity
was offered.** The phase recorded 196 turns over a 20 003 ms span for a 10 s
phase, because it cannot end while the owner is blocked.

This block differs from the resize in a way the policy decision should not miss:
**nothing at all was delivered during it.** The only callbacks inside each block
are one or two cursor positions in its final 2 ms, as the cursor came back over
the window while the tracking loop released. Where a live resize floods the
application with redraw requests it cannot answer, a menu tracking loop tells it
nothing.

## What is measured and what is inferred

**Measured**, directly, from records in one clock domain:

- the native call's entry and exit instants, and so each block's duration;
- that the call was a finite wait, and the seconds it asked for;
- every callback delivered, by name and instant, and therefore that callbacks
  continued to be delivered from inside a blocked call;
- that no `TurnBegan` and no update-hook entry or exit was recorded for the
  duration of any block.

**Inferred**, from the loop's fixed structure rather than from an observation:

- that **queued commands** were not dispatched. `runOwnerLoop`
  (`packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:1404-1406`)
  runs `processEvents`, then `turnWork` — which reconciles, retires, surfaces
  close requests, and dispatches commands — then `loopUpdate`, in that order in
  the same turn. No turn began, so none of that ran. **No command was queued
  during the measurement**, so this is read off the order, not observed.
- that **other windows** stall with it. The host serves every window from the
  same owner turn. **The probe held one window**, so this is read off the
  structure, not observed.
- that **simulation** stops. Simulation is application work behind `loopUpdate`,
  which was not entered. **The probe ran no simulation**, so this is read off
  the structure, not observed.
- that **future owner-driven rendering** stops. VK-16 currently specifies
  rendering on the owner loop. **No renderer exists**, so this is a statement
  about that design, not a measured rendering defect.
- that a **shorter idle wait would not help**. The blocked call asked for 100 ms
  and returned after 68 918 ms, so the bound is not what holds it; this follows
  from the measurement but was not tested by varying the bound.

`runScheduledOwnerLoop` has the same ordering
(`Internal.hs:1782-1786`) and was **not** exercised: every session used
`runOwnerLoop`. Nothing here measures the scheduled path.

## Requested cases not performed

- **`runScheduledOwnerLoop`**: not run.
- **A second window**: not opened, so the effect on another window is inferred.
- **Queued commands, application events, simulation, an attachment, or a
  renderer**: none present during any measurement.
- **Linux or X11**: not measured. RR-4 excludes Linux evidence as a substitute
  and none was used.
- **Other interactions**: the traffic-light buttons, a zoom or maximize, a
  fullscreen transition, a window drag from a non-title-bar region, and a
  window-menu or dock interaction were not requested by #200 and were not
  performed.
- **A second machine or a second macOS build**: not measured. Every number here
  is from the one host in [Identities](#identities).

### The first session: attribution unreliable

A first 20 s session preceded the two above. Its phases cannot be attributed:
the terminal was full-screen, the person could not see the banners and was
pacing from memory, and the trace shows the interactions landing one phase late
— nothing at all during the phase labelled "window move", a window move during
the phase labelled "window resize", and a live resize during the phase labelled
"menu-bar interaction". It is recorded here only because its one unambiguous
measurement corroborates the resize finding: a single `glfwWaitEventsTimeout`
of 100 ms that did not return for **29 591.9 ms**, with **10 173** callbacks
delivered from inside it — 3390 each of `window size`, `framebuffer size`, and
`window refresh`, a redraw-request rate of about 115 a second. Its menu-bar phase was
never performed. No claim in this verdict rests on that session alone.

## What the owner has to decide

RR-4 names three candidate policies. The measurement above says something about
each. **This document selects none, and nothing here has been implemented.**
Record-only callbacks and main-thread ownership are unchanged, no rendering runs
inside a callback, and no render-worker design is introduced.

### 1. Temporary acceptance of the stall

Accept that, while a person resizes a window or holds a menu open, the owner
turn does not run.

- **Other windows:** frozen for the interaction's whole duration — inferred, and
  the duration is unbounded above, because it is however long the person holds
  the mouse down. 68.9 s was measured simply because that is how long the drag
  lasted.
- **Simulation:** does not advance. Whether that is acceptable depends on
  whether simulation is owner-driven, which the scheduling design leaves to the
  application.
- **Queued commands:** none dispatched, and none rejected either — they stay
  queued and are dispatched when the call returns. Command capacity is finite
  (`hostCommandCapacity`, 64 by default), so a producer submitting during a long
  interaction can fill a port and be refused. That is not a measured outcome; no
  command was queued here.
- **What the measurement adds:** the window is visibly resizing throughout while
  Cocoa requests a redraw ~112 times a second, so this policy means an
  application that renders on the owner loop shows a stale or stretched surface
  for the whole interaction. It also means a move costs nothing, so the policy
  is only about resize and menus.

### 2. A narrowly controlled redraw path

Let the refresh callback, or something it signals, drive a bounded redraw while
the pump is blocked.

- **Other windows and simulation:** still frozen. This buys a current surface
  during the interaction, nothing else. Continuous simulation is not implied by
  it.
- **Queued commands:** still not dispatched, unless the path is widened beyond a
  redraw, which is a different policy.
- **What the measurement adds:** the platform is already asking, on its own
  schedule, at a workable rate — 7648 complete size/framebuffer/refresh sets in
  68.9 s, about 111 a second. So the trigger exists and is well-behaved. The cost is that whatever
  answers it runs **inside a C callback frame**, which is precisely what the
  current record-only contract forbids and what `#200` puts out of scope. That
  contract exists for reasons this measurement does not weigh: callbacks
  currently take no lock, wait for nothing, and let nothing unwind into C.
- **Unmeasured:** nothing here establishes that a redraw can complete within a
  callback, or what it would do to the capture latch and the reconciliation
  boundary.

### 3. A separate rendering owner

Move rendering off the thread that owns the pump.

- **Other windows:** still not serviced — window commands remain owner-only, so
  a second window's commands still wait. Only rendering is freed.
- **Simulation:** could progress if it also moves off the owner thread, which is
  a further decision this evidence does not speak to.
- **Queued commands:** unchanged.
- **What the measurement adds:** the menu-bar block delivers nothing at all, so
  a rendering owner would be the only one of the three options that keeps
  producing frames while a menu is open. Against that, it is the largest change:
  GLFW's main-thread rule still binds every window operation, so this splits
  rendering from window ownership rather than relieving the owner.
- **Unmeasured:** no surface, swapchain, or presentation exists here, so nothing
  in this run says what a second rendering owner would cost.

## Reproducing this

The probe is in the tree and is selectable at any time. It is pending unless
`HETOIMASIA_INTERACTION_PROBE_SECONDS` asks for it, so no routine run, CI run,
or mandatory validation group performs it, and it needs the same explicit human
approval every desktop session needs. The command, the variables, and what the
report contains are in
[docs/glfw.md](glfw.md#the-interaction-probe). What an owner turn offers the
trace, the bound, and its loss and fault reporting are asserted headlessly over
the test seam in `Test.GLFW.Trace`, which needs no desktop and no observed
stall.

One property of the probe is worth knowing before reading a future run: a phase
ends when its deadline is noticed in the update hook, and that hook is exactly
what a stall prevents. **A phase cannot end while the owner is blocked**, so a
phase containing a stall spans longer than the seconds asked for, and the report
prints the real span. That is a consequence of the finding, not a defect.
