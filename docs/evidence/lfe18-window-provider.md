# LFE-18 window provider: evidence

Issue [#533](https://github.com/coghex/hetoimasia/issues/533). Contract: [`packages/lua-engine-graphics/README.md`](../../packages/lua-engine-graphics/README.md#the-window-provider-lfe-18).

## Real windows (native subgroup `window provider`)

Command (macOS, under the owner's standing native-session approval, confirmed on `#het-lfsolve` for this suite):

```sh
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:lua-engine-graphics-native-tests -- --match 'window provider'
```

| Field | Value |
| --- | --- |
| revision | `430a5f1641eaecd87b78a82009bd0dabcd9db6de` (source digest `bbe169d8c97cf64c71c4e16a0aecc20aaf8e8b6a41cbedf2fe92af89fff3b5af`); the later commits only add the recorded-step masks and docs |
| platform | darwin/aarch64, GHC 9.14.1 |
| driver | MoltenVK (`icd.d/MoltenVK_icd.json` of the private native prefix), loader `libvulkan.1.dylib` of that prefix, held to the recorded loader by the suite |
| validation | `VK_LAYER_KHRONOS_validation`, synchronization validation |
| examples | 3 run, 0 failed (a nonzero count is enforced: `configFailOnEmpty`) |
| windows | 5 native windows made by the examples, each destroyed before its example ended |
| diagnostic verdict | clean, 68 records delivered, computed after the last teardown callback |
| native calls | 237; swapchains and surfaces destroyed before the device, device before messenger, instance last |

What the examples showed: two instances' windows exist at once; each success followed the owner's admission
(`readTargetStanding == TargetUsable`) and an empty scene was published to it; ending one instance destroyed only its window
after retirement while the peer's remained usable and no session stop was requested; a real creation cancelled before its
ticket was collected left the slot occupied until the late window had been closed and destroyed, after which a fresh
request succeeded; a genuine native close request made by the platform (`Hetoimasia.GLFW.NativeCheck.requestNativeClose`,
answer `NativeCloseDelivered`) was routed to exactly one session stop, left the window in place, and the instance's own
cleanup close added no second stop. No visual pixel and no completed GPU frame is claimed: readiness is the owner's
admission and the right to publish, as the contract says.

## Negative controls (broken once locally, never committed)

Each mutation was applied to the provider, the headless `window provider` group was rebuilt and run under
`HETOIMASIA_EXAMPLE_BOUND_SECONDS=6`, and the source was restored.

| Mutation | Result |
| --- | --- |
| a window counted retired once graphics retired, without the native window's destruction | 1 example failed: "closes a late native result once, and frees the slot only after native retirement" |
| the genuine close not routed to the stop endpoint | 2 failed: the routing examples (pending setup with capacity full; the race with the cleanup close) |
| the provider's own cleanup close routed to the stop endpoint | 3 failed: the late-result example, the peer-retirement example and "does not stop the session or a peer when only an instance's cleanup closes its window" |
| (round 1) abandonment of an offered, never-built result removed (the swallowed-adoption wrapper also withholds `workCancel`, as the host does once a reply is accepted) | 1 failed: "takes apart a window whose offered result was never built because the request was cancelled first, without the result being taken" |
| (round 1) the host queue's progress baseline sampled after the attempt instead of before (replaced in round 2 by waiting on the queue's room, which has no baseline) | 1 failed: "issues again when the host queue drained between the refusal and the waiter, and closes likewise" |

Each failed within its bound and unwound its cleanup (the rig opens every hold and calls `endWindows` on every exit, then the provider's scope drains). The first abandonment run, before `endWindows` existed in the rig, hung in teardown until the hard timeout (the instance's end waits for the provider, the provider's scope for the instance); that is why the rig ends windows itself.

## Same-shape sweep

Shapes fixed: *a native thing exists before the record that tracks it.*

| Site | Shape | Result |
| --- | --- | --- |
| `Provider.issue` | creation command admitted by the host queue → token recorded | closed: the whole step is masked; `portIssueCreate` is a nonblocking submission |
| `Host.portIssueCreate` | `submitWindowCommand` accepted → ticket stored in the port's table | closed: masked in one step (found by this sweep) |
| `Host.attach` | `handOverVulkanTarget` returned an attachment → its service stored | closed: masked in one step; otherwise a second handover would meet an occupied slot, which is fatal (found by this sweep) |
| `Provider.stepOf` (created) | ticket outcome → window token recorded | one pump transaction reads the outcome and writes the token |
| `Provider.stepOf` (admitted → offered) | standing and target read → success claimed | one pump transaction; the answer runs after, and a non-adopted answer ends the acquisition |
| `adoptionFor` | resource built into the lease → acquisition marked adopted | one transaction on the owner's thread |
| `windowMainStep` | `portAttach` answered → phase recorded | a lost record repeats the attach, which the port turns into an announcement on the same attachment, never a second surface |
| `route` | stop endpoint called → newest number recorded | idempotent endpoint: a repeat is safe, a lost record only repeats it |
| any pump effect that raises | state unchanged → effect chosen again | closed in round 1: the acquisition is marked unretryable, once |
| `Host.createOutcome`, `Host.retirement` | outcome read → port record kept | closed in round 1: consumed / forgotten in the reading transaction; failed retirements kept |

## The one change outside the adapter's package

`Submission.submissionSettled ∷ STM Bool` (`packages/scripting-lua`, `Provider/Types.hs`; set in `Admission.hs` and
`Request.hs` from the existing `settledNumber`). Additive, read-only, non-blocking: no existing provider reads it and nothing
in the host's behaviour, bounds or approved contracts changes (the manager classified it as not a contract change on
`#het-lfsolve`). Without it a window whose request is cancelled between the host's acceptance of a resource reply and the
build stays open until the settled result is taken or discarded, because the host reports that provider's work over at the
reply and skips the cancel. Documented in `packages/scripting-lua/README.md`. All `scripting-lua` suites pass (`lua-host-tests` 631,
`lua-runtime-tests` 1141, `lua-domains-tests` 403).

## Round 2

Codex round 2 (head `d0e62866`) kept four blockers, all repaired: the queue wakeup now waits on the queue's capacity
(`commandsPending < commandsCapacity`) rather than on equality of statistics, which a fill-and-drain cycle can restore; a
pump failure (an outcome read that raises, an asynchronous interruption) leaves every acquisition as retained terminal
evidence with its slot held; an interrupted creation (`CreateFatal`) is that same evidence rather than a retirement; and the
provider's endpoints are exercised on a real `runSession` coordinator (`Test.LuaEngine.Graphics.Window.Coordinator`).
What a real coordinator cannot show here is a Lua role opening a window, because that binding is LFE-21's; the roles run an
empty behavior, so a required-creation failure reaches the session through the provider's fatal endpoint, not through a role's
required request (that record, `required_request` at stage `request`, is #527's policy for instances of its own VMs, and is
asserted on the instance's failure in the composition examples, which carries `window_error`).

## Round 3 and the owner's amendment

Round 3 (head `3bc81fc0`) found three races, repaired: a request handed to the provider after its pump failed is recorded as
terminal evidence (it would otherwise wait for a thread that is gone); the adoption recipe tolerates a window already taken
apart and forgotten (the host may run a recipe it had claimed after the request settled); and a stop routing that raised is
attempted once for that request (its number is recorded before the attempt). The fourth finding, a test where a session role's
unread clean creation refusal produces the coordinator's `required_request`/`request` failure, cannot be written until LFE-21
gives a role a way to call the window service: the delivered session installs its facade with no extra bindings or endpoints
(`Session/Run.hs`, `installFacade facade [] [] base`). The owner deferred it to #536 (comments 6503374434 and 6503458006).

Deferred to #536, by name: (a) the coordinator role-failure record (`required_request`, stage `request`) from a real session
role, for an unread and for a caught clean creation refusal; (b) the startup-gate close case driven from such a role ("before
root init returns", "while the startup gate is closed"); (c) the session escalation of a required creation failure from a real
role. Proven here instead: a genuine native close routed to one idempotent session stop on a real `runSession`, with the
records bank full, both while the setup is pending and after readiness; the take record and the instance-level required failure
carrying `window_error` and attributed to the endpoint `window`; `cleanup_failure` and `host_failure` latched through the real
coordinator; and the full race matrix over the gated port.

Negative controls of round 3 (broken once, restored): adoption recipe throwing for an untracked window → 1 example failed;
stop routing recorded after the attempt, and the late handoff recorded without terminal evidence → each hangs (the spin and the
drain that wait forever are the defects), ended by the hard timeout; the unmutated code passes both in well under a second.

## Round 4

Four coverage findings, repaired: the claimed-adoption interleaving now runs through the real request and lease machinery (the
adoption recipe is held after the owner claims it, the application advances the epoch, the provider takes the window apart,
the recipe resumes over a window that is gone; no success is delivered, nothing fails, the slot is returned once and a fresh
request succeeds); the exact bounded `take` record (code, message cut at 2 KiB, no root or path) is read by a script through an
optional request, with the required request's latch asserted on its instance failure; the after-readiness close runs with the
records bank asserted exhausted (the result is waited for, not taken); and an earlier primary failure survives a later failed
destruction (the real session keeps one terminal failure and acknowledges a later one without replacing it; the provider
retains the cleanup failure as its own evidence and closes the window once).

Negative controls of round 4 (broken once, restored): adoption throwing for an untracked window → the real-machinery example and
the direct one failed (2); the cut at 2 KiB widened to 4 KiB → the bounded-record example failed (1). The window group ran
three more times in a row without a failure. The complete native profile (eight examples, windows included) ran in about
four seconds of wall time, inside the group's 30-second watchdog.
