# Window and graphics lifetime integration design

Establish the ownership boundary between dynamic GLFW windows and graphics
dependents before adding surfaces, swapchains, or submitted GPU work.

Design state: `ready for issue processing`

Owner: `coghex/hetoimasia`. Started 2026-09-16. The owner accepted one exclusive
graphics owner per window and protected retirement after worker drain, before
dependency release. The owner's requested final review completed on 2026-09-16
against `master@e2d30ea`; D-5 records its clarifications. Epic #140 and all four
children (#141–#144) are merged. The ledger records processing,
not implementation; canonical approval amendments are part of each issue's spec.
On 2026-09-20 the owner added D-6, the surviving graphics-owner lifetime that
the Vulkan arc's D-29/D-33 require; it revises D-4's ordering and is delivered
by Vulkan VK-18/VK-7, so this arc's ledger is unchanged and complete. The
owner's requested 2026-09-20 review signs off that revision with the Vulkan
design; it does not claim that today's implementation already supports it.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Retain windows until graphics dependents safely retire — [#140]
- [x] LIFE-1. Model exclusive window attachments and retirement evidence — [#141]
- [x] LIFE-2. Compose managed dependency lifetimes around application supervision — [#142]
- [x] LIFE-3. Establish the protected host retirement boundary — [#143]
- [x] LIFE-4. Expose exclusive attachments with independent dynamic retirement — [#144]

## Epic contract

- **Goal:** a graphics integration can retain exactly its window until all its
  dependent use and disposal have ended, on dynamic close and every application
  exit, without putting GPU waits in uninterruptible foundation releases.
- **Done when:** a scripted graphics owner demonstrates registration rollback,
  independent close, successful and failed retirement, repeated cancellation,
  and all-exit application drain. Ordinary window users remain compatible and
  no native handle is exposed to game code.
- **Users and operators:** future Vulkan owner, the main-thread window host,
  application composition, and agents implementing lifecycle tests.
- **Arc label:** existing `resources`; crossing slices use `runtime`/`glfw`
  during processing. No new graphics package or label is required yet.

## Current handoff — 2026-09-21

D-6's lifetime is delivered, by the Vulkan arc's VK-18/#218 as D-6 said it
would be, and not by a new LIFE slice: the ledger above stays complete. What
exists now is the machinery, with its backend operations injected; VK-7
supplies the Vulkan ones.

`Hetoimasia.Runtime.GLFW.withGraphicsOwnerHost` is the additive protected-host
constructor D-6 describes, beside `withProtectedWindowHost`, which keeps its
signature and its behaviour, as does every other window-only entry point. Under
it, a whole-session exit runs D-6's four steps exactly: quiescence closes the
host's admission and then the owner's own bounded lifetime port; ordinary
workers stop and drain, untouched by the owner's separate worker group; the
owner stays alive and retires each target and then itself through its injected
operations, publishing each certified fact through the existing completion
publisher; and the main-thread boundary services the host's own bounded native
housekeeping while it awaits verified retirement, validating each exact
attachment's terminal evidence and never the owner's completion, before joining
the owner and letting the windows, session and parents unwind.

D-6's retention rules are delivered as written. The owner's run action installs
its protected retirement before any dependent construction, and an expected
stop, a startup failure, a run failure and cancellation all enter that same
drain; nothing driver-shaped is placed in a `Scoped` startup release. A
terminal owner failure is latched as soon as it is known and reaches
application checkpoints through `superviseGraphicsOwner`, which registers one
ordinary supervised service in the application's own group — a separate worker
group gives supervision no connection by itself, so the connection is explicit.
An owner that ends without the injected whole-owner destruction returning
evidence does not let the boundary finish: the main thread keeps servicing
housekeeping, the windows, the session and every borrowed parent stay
retained, and `OwnerDestructionUnverified` is written once as the diagnostic
that says so. That is D-4's retention rule applied to the owner's own shared
state, and it authorizes nothing: not a disposal, and not a replay of the work
that failed. Only independent evidence ends it —
`publishOwnerDestruction`, from a thread that established it, which is the
same shape the attachment model already has for a fact certified by a thread
other than the owner — and operator process termination remains the escape.
Whole-owner retirement is independent of the attachment count in both
directions: it happens for an owner that never held a target, and after the
last one has detached.

An individual close or detach is not that: `releaseGraphicsTarget` retires one
target, the owner publishes that target's exact evidence, the main thread
acknowledges it and its window is released, and the shared owner and every
other target stay live. Only a whole-host exit requires the final join.

A terminal failure under a `Required` disposition is terminal at once: the same
transaction that latches it closes every admission into the owner's handoff,
and its run ends there and enters the drain, so nothing further is handed to
an owner that is about to retire. The latch stays for supervision, which
reaches application checkpoints through one ordinary supervised service the
composition registers in the application's own group.

One rule the delivered machinery makes explicit that D-6 left implicit: the
owner never retires an attachment the main thread still holds. When a target's
construction cannot be used — a partial construction, one the backend could not
verify a rollback for, or one that was interrupted — the owner keeps whatever
it owns and /reports/ it through `readTargetStanding`. Beginning that
attachment's retirement stays the main thread's, because the attachment and its
window's exclusive slot are the main thread's; the owner is given no
cross-thread authority over either.

## Current handoff — 2026-09-20

At `master@3a8abdc`, LIFE-1 through LIFE-4 and the retirement/reporting repairs
#166–#169 are merged. The implemented host/attachment contract is in
[glfw.md](glfw.md); the [review ledger](project_review/ledger.md) records current
review outcomes. The [#170 review](project_review/170.md) confirms the
metadata repair but records an older callback-comment contradiction: finite,
nonblocking native work is permitted; blocking GPU waits are not. The Vulkan
proof and pure GPU model now exist separately,
while production surfaces, submissions, and GPU completion still belong to the
[Vulkan arc](vulkan_backend_design.md). The checklist above records completed
processing; do not recreate its children as native graphics work.

## Historical state and evidence

Source observations verified at `master@e2d30ea` on 2026-09-16 still describe
the unimplemented attachment boundary at `9300962`. Tracker state below was
refreshed on 2026-09-17:

- `Runtime/GLFW/Internal.hs` under `packages/glfw/runtime-glfw-core/Hetoimasia`:
  `beginClose` publishes closing, closes command admission and input, and calls
  `retireClosing`. Retirement observes CPU collection borrows only.
- `allocWindowHostWith` allocates a collection whose scope exit disposes all
  remaining members. Guarding `retireClosing` alone would not guard host exit.
- `packages/runtime/src/Hetoimasia/Runtime/Application.hs` constructs `Scoped`
  dependencies around supervision. Its finite STM quiescence guard settles
  admission before workers drain; the dependency scope then unwinds.
- Foundation release callbacks run uninterruptibly and outer releases continue
  after a release failure. Throwing from an inner finalizer cannot safely keep
  its parent window/device alive. CPU scope exit proves no GPU completion.
- Ordinary window borrows end when their callback returns. There is no surface
  integration or durable graphics attachment. Vulkan is still a package note.
- #115–#118 merged through #119–#122. Monitor follow-up #123 merged in #126;
  LIFE-4's external repair gate is satisfied. GLFW epic #86 is closed.
- Epic #140 owns this CPU lifetime work; #131 owns its wake/scheduling
  prerequisites. Vulkan surface and actual GPU completion remain owned by
  the Vulkan design's P-5/Q-7 and are not implemented by these issues.

## Scope and desired experience

The application can close one rendered window while another keeps working.
The closing window stops admitting new rendering, retains its native lifetime,
lets the owner retire its dependents, and is destroyed on the main thread only
after retirement is safe. Whole-application failure follows the same lifetime
rule even though ordinary application updates have stopped.

In scope: backend-neutral ownership/evidence state, a narrow application
composition extension, a protected IO lifetime for an attachment-capable host,
and dynamic retirement. Use scripted dependents first.

Out of scope: Vulkan handles/bindings, actual surfaces or GPU submissions,
swapchain implementation, asset management, GPU resource pools, multiple
independent graphics owners of one window, mandatory render workers, hard
shutdown deadlines, or redesigning foundation resource release semantics.

## Decisions

### D-1. One exclusive graphics owner per window

Owner accepted 2026-09-16. A window permits one live graphics attachment. Multiple
2D/3D renderers can use the graphics owner's services rather than registering
independent owners. A later owner may attach only after the earlier one has
safely retired and only while the window remains open.

### D-2. Preserve established failure and ownership policy

Existing accepted direction: no universal EngineEnv, no graphics dependency in
the ordinary window API, caller-thread application composition, retained primary
and cleanup evidence, and recovery only after safety is established. Repeated
cancellation does not authorize releasing resources still in use. The existing
worker policy retains dependencies and waits when stopping cannot be proved;
D-4 accepts the corresponding rule for graphics dependents.

### D-3. Preserve test and platform boundaries

Use Hspec and scripted lifetimes for failure/ordering proofs, isolated X11 for
native window lifetime, and local Cocoa only after asking for and receiving
the human user's explicit approval for that test session. No hosted macOS CI.
GLFW-only evidence is not GPU-completion evidence.

### D-4. Protect retirement between worker drain and dependency release

Owner accepted 2026-09-16: the main thread retires graphics after worker drain
and before releasing windows or their dependencies, with a protected IO host
lifetime. If safety cannot be established, retain those resources and wait.
No timeout, cancellation, or cleanup error supplies permission to destroy them.

### D-5. Final review and delivery boundaries

The final review checked the continuation seam against the current application
runner and the protected host against collection exit and fixture/worker drain
contracts. P-1 through P-5 are the reviewed contract for D-1 through D-4. The four
slices are ready for issue processing, with cancellation handoff, construction
ownership, and retirement progression clarified below. Actual Vulkan completion
remains deliberately gated in Q-3, outside every LIFE slice.

### D-6. The graphics owner survives worker drain and retires on its own thread

Owner accepted 2026-09-20, mirroring Vulkan
[D-33](vulkan_backend_design.md#d-33-keep-the-graphics-owner-alive-through-protected-retirement)
after [D-29](vulkan_backend_design.md#d-29-render-from-one-supervised-graphics-owner-keep-glfw-on-the-main-thread)
moved rendering to one supervised graphics owner. This is the "different
explicitly designed lifetime" P-3 reserved for a backend that needs a live
retirement worker, and it revises D-4's assumption that the main thread
retires graphics after every worker has drained:

1. Quiescence closes admission; ordinary application workers stop and drain.
2. The graphics owner stays alive to finish GPU retirement and destroy its
   own resources on its own thread.
3. The main-thread protected boundary services the native housekeeping that
   retirement needs and awaits verified retirement, bounded per turn as D-5
   requires; it performs no GPU work.
4. After verified retirement and destruction, join the graphics owner before
   final host disposal releases the remaining windows and dependencies. The
   main thread validates exact attachment evidence; worker completion alone
   is not retirement evidence.

This is whole-session exit. Ordinary close/detach of one window retires only
its dependents and publishes evidence for that exact attachment. The main
thread can acknowledge it and release that window while the shared graphics
owner and other targets remain live; it neither joins the shared owner nor
releases shared device/instance roots.

The graphics owner uses a component-owned worker/supervision lifetime separate
from the ordinary application group. Its run action installs protected IO
retirement before dependent construction, covering startup failure, run
failure, stop and repeated cancellation. GPU destruction does not belong in
its `Scoped` startup finalizers. Terminal failure is latched and made available
to application checkpoints immediately, even if retirement must continue.
The main-thread boundary services housekeeping while observing retirement and
worker completion; it cannot first block in a generic group join that prevents
that housekeeping. Unexpected completion without safe retirement retains the
dependencies and evidence. Vulkan D-33 specifies this additive composition;
the existing worker primitives and window-only entry points keep their rules.

Cancellation follows the same dependency ordering. D-4's retention rule is
unchanged: no timeout, cancellation or cleanup error supplies permission to
destroy a resource whose GPU use is unverified. The delivered LIFE-1–LIFE-4
contracts stand; the surviving-owner lifetime is delivered by the Vulkan arc's
VK-18 and VK-7, not by a new LIFE slice, and this ledger stays complete.

## Design

### P-1. Attachment ownership and state

The host owns per-window registration and close state. The graphics integration
owns dependent resources, retirement work, and evidence that no dependent can
still use the window. The public application holds an opaque graphics service;
it does not obtain a raw native pointer or a destruction function.

The phases are registration/construction, active, retiring, and retired.
Failure evidence is recorded separately from whether release is safe. A failed
operation is not automatically a retired attachment. Bind the attachment to its
host, session, window identity, and unique incarnation so stale completion from
one owner cannot release a replacement owner or a later window.

Only the integration holding retirement authority can report its completion.
GLFW cannot inspect or independently certify GPU work. An opaque acknowledgement
prevents accidental cross-window misuse; it is not proof that a dishonest or
incorrect backend really finished. The backend's tested contract supplies that
proof. Duplicate completion for the same terminal attachment is harmless and
cannot rerun disposal; foreign or invalid authority produces typed misuse.

Registration, construction, and rollback have one owner. Establish the native
lifetime guard before creating any dependent. If construction fails, keep its
original failure, run owned rollback, and acknowledge retirement only if rollback
establishes safety. Cancellation cannot leave a constructed dependent outside
registration. Do not publish a usable graphics capability before construction
and registration have completed. Refuse attachment to closing/ended windows,
another host/session, or an already occupied window before acquisition effects.

Construction failures with unsafe rollback follow P-3, including when no service
was handed to the application. Keep state bounded by the host's window limit
and live/retiring attachments; old identities must not require an ever-growing
tombstone registry.

Host attachment authority is main-thread-only. Under D-6 the graphics owner
disposes its own backend dependents on its worker and publishes exact terminal
evidence; only the main thread validates it and removes the attachment or
destroys the GLFW window. Other threads may observe status or publish bounded
notifications but gain no disposal authority. Validate identity and ownership before
construction/retirement effects, just as for current window operations.
Dependents must stay owned by this controller until retirement: do not return
handles from an already ended `withScoped` callback, or install their only
destructors in a worker scope that exits before graphics completion. Worker
services borrow these capabilities; they do not own early GPU destruction.

### P-2. Dynamic close and ordinary detach

On accepted close, atomically end normal command/render admission and publish
closing state before any new use can begin. Keep existing close-ticket semantics
explicit: accepting a close is not acknowledgement of native destruction.
Provide observable retirement state so consumers need not infer destruction
from a close result. Ordinary input closes as today; retirement does not run
input or game handlers.
Keep attachment retirement and native window disposal outcomes distinct. A
native release failure must retain its existing evidence and must not publish
a fabricated successful destruction or cause a second release attempt.

The graphics owner revokes new use, accounts for already issued CPU capabilities
that may submit work, waits for accepted work according to its completion policy,
and disposes dependents. Only then does the host acknowledge retirement and
allow native destruction, also respecting ordinary CPU borrows. One window's
pending retirement does not block servicing another window: progress is bounded
per turn and follows the scheduling arc's deadline/wake model.

In the delivered LIFE protocol, attachment progress executes on the main thread
outside foundation finalizers. Under D-6 that callback requests/observes
progress from the surviving graphics owner; backend GPU effects and disposal
execute on that worker. Both paths are trusted, narrow component operations,
not arbitrary game callbacks.
Each progress opportunity either advances finitely or declares when progress
may next be possible. No blocking GPU wait is allowed in a normal main-thread
owner turn.
If the platform itself blocks inside a native call, no hard latency guarantee
is claimed. The backend must document that limit.

Detaching an owner while keeping its window open uses the same retirement rule.
The exclusive slot becomes free only after safe disposal. A new attachment gets
a fresh incarnation. Swapping render modules inside one backend is not detach;
swapchain generations remain that backend's responsibility.

### P-3. Protect the entire host lifetime on every exit

An attachment-capable host needs a dedicated IO continuation boundary. Keep the
existing `Scoped` window-only constructor and behavior for current clients, but
do not let it accept graphics attachments: its finalizers cannot implement this
contract. A caller must select the protected host lifetime before attaching.

Composition, outer to inner:

1. Managed logging lifetime.
2. Parent component scopes such as a future Vulkan instance/device as appropriate
   to the backend's dependency graph; every borrowed parent outlives retirement.
3. The protected window-host lifetime and its owned retirement state.
4. Supervised workers, the existing finite quiescence guard, startup, and action.

Application exit then proceeds in this order:

1. Existing quiescence closes normal admission and settles queued commands.
   The composition includes the attachment owner's finite bookkeeping to end
   new graphics use; it performs no GPU calls or waits in that transaction.
2. Existing supervision stops and drains workers, retaining their outcomes.
3. With worker borrowers ended but dependencies still live, the main thread
   closes any remaining attachments and services their retirement protocol.
4. Only after all dependents are safe, unwind CPU windows, their session and
   other parents in the actual dependency order; retain disposal failures.
5. Existing terminal reporting and logging lifetime settle the result.

Fatal supervision can already ask workers to stop before quiescence; preserve
that rule. Neither worker finalizers nor graphics retirement may await a command
handled only by the departed normal loop. Initial graphics retirement work is
owner-thread-owned and must remain progressable after worker drain. A backend
that needs a live retirement worker requires a different explicitly designed
lifetime; this arc does not silently add one. D-6 is that lifetime, and
`withGraphicsOwnerHost` is its delivered composition: under it
step 2 drains ordinary workers only, step 3's GPU retirement runs on the
surviving graphics owner while the main thread services housekeeping and
awaits verified retirement, and the owner is joined before step 4.

The protected boundary covers failed dependency construction after host setup,
failed startup, action failure, owner-loop failure, normal return, and repeated
cancellation. Install it before any attachment/dependent construction, rather
than in the application action. Nested parent scopes cannot unwind while it is
waiting. Keep native event processing needed for retirement and internal wake
support live, with ordinary application callbacks disabled.

The host boundary itself must close attachment/new-use admission on every exit,
even if application construction fails before the quiescence hook is installed
or a caller omitted that hook. Application quiescence normally performs the
early close before worker drain; the host's idempotent close is its own final
safeguard, not a replacement for that runtime ordering.

The nesting sketch is not permission to release a device or surface from an
inner ordinary scope before retirement. The eventual Vulkan composition must
map its real dependency graph: every parent is either outside the protected
boundary or owned by its retirement controller through final disposal. Device
selection can require an already created surface; this CPU arc does not impose
an impossible device-before-window construction order.

Waiting belongs in ordinary IO under an explicit protected drain. Do not put
GPU waits, worker joins, event pumping, or logging in the existing finite STM
quiescence hook or an uninterruptible resource finalizer. Preserve the initiating
primary failure and retain later failures without replacing it. Additional
cancellation is deferred until safe retirement; cancellation is not completion.

Install the protected exit handler under masking before handing the host to
its consumer or restoring interruptibility for dependent construction. Record
the initiating outcome before interruptible drain work. The body failure stays
primary; after a successful body, the first drain failure becomes primary. Keep
that outcome protected across the transition to CPU disposal so a pending later
cancellation cannot replace it or release parents before safety is recorded.
Use interruptible waits with repeated cancellation retained/deferred, not one
uninterruptible mask around the entire drain. Never catch arbitrary synchronous
failures and blindly retry the failed disposal operation.

After workers have drained, retirement must not depend on normal `loopUpdate`
or call a supervisor checkpoint that only rethrows an already latched fatal
outcome. It uses a narrow owner-thread progress path with internal completion
notifications and finite waits. Native callbacks may still record component
state; ordinary application handlers stay disabled. A suspended/closing window
still has retirement demand, so render eligibility cannot suppress that path.
Give each pending attachment a bounded opportunity, also during final host
drain, so one stalled attachment does not prevent another from safely retiring.

When a retirement step fails, preserve its origin/evidence and apply the existing
required/optional service policy to application disposition. Safety is separate:
neither disposition authorizes destruction of an unsafe dependent. Do not
blindly replay the failed step. A component may continue
only through an explicit safe progress path. If no path can establish safety,
retain the affected dependency chain, cease unsafe work, and report the stalled
state through a protected diagnostic attempt without letting diagnostic failure
unwind the retained scopes. Wait rather than fabricate retirement. Operator
process termination is the escape; forced exit promises no orderly cleanup.
Timeouts may diagnose a stall but never grant destruction authority. There is
no detach-and-hope or catch-a-finalizer-error-and-continue release path.

### P-4. Application composition seam

Provide an additive application runner accepting a managed dependency lifetime
of the form `forall r. (dependencies -> IO r) -> IO r`, with the same logger,
quiescence, startup, action, and supervision behavior as today's runner. This
lets a component enclose all borrowers in its own protected IO boundary.

The current `Scoped dependencies` entry points adapt through `withScoped` and
retain their existing signatures, order, tests, and failure semantics. The new
runner does not invent an arbitrary list of shutdown callbacks, a second
supervisor, or a global resource registry. Once construction succeeds, the
supplied lifetime invokes its consumer exactly once, synchronously on the
calling thread, while all dependencies remain live. Failed construction invokes
it zero times. It may not fork, retain, retry, or later re-enter the consumer,
or turn a failed consumer into success. It owns acquisition, rollback, and
protected release, preserving the existing primary/cleanup outcome table.
Document this trust contract just as with existing continuation-based owners.

This seam alone is not safe graphics teardown. LIFE-3 supplies the actual
protected host owner before LIFE-4 exposes public attachments. Prove the runner
order with a scripted managed dependency whose drain executes after worker
completion and before parent release, including construction/startup failures.

### P-5. Completion policy belongs to the backend

Keep three distinct facts:

| Fact | Owner and meaning |
|---|---|
| Logical release | Application stops wanting a frame/resource; it does not prove last use. |
| CPU-use retirement | No retained capability/snapshot/pending producer can submit another use. |
| Backend retirement | Submitted uses and presentation obligations have ended, and dependent disposal is safe under the backend's verified contract. |

A normal body return, a CPU callback ending, a timeout, cancellation, or a device
error cannot stand in for backend retirement. Attachments retain generation
identity until safe completion. With a scripted owner, independent completion
signals must demonstrate that neither CPU retirement nor submission completion
alone releases a window when presentation still depends on it.

Actual Vulkan capability requirements and submission/presentation proof remain
Q-2 of the [Vulkan design](vulkan_backend_design.md). That design owns the narrow
surface-creation bridge: copied required extension names and creation for an
attached live window, with the graphics owner disposing the surface. It must not
expose arbitrary native-handle borrowing to bypass this lifetime. Do not add a
Vulkan FFI signature or select a maintenance extension in these CPU-only slices.

## Open questions

### Q-1. How many graphics owners may attach to one window?

Resolved by D-1.

### Q-2. Approve the concrete scope/composition seam and delivery split?

Resolved by D-5 after the owner's requested final review. P-1 through P-4 specify
the boundary implementing D-1/D-4: one IO lifetime enclosing supervision and a
compatible managed-dependency runner. The composition contract is explicit;
do not replace it with a generic uninterruptible finalizer hook.

### Q-3. Which Vulkan mechanism proves completion?

Delegated to Vulkan Q-2, whose native compatibility gate was fulfilled by
merged #158/PR #174 and whose exceptional cleanup was repaired by #181/#182.
That arc selects maintenance present fences and unused-image release. No LIFE
slice itself creates GPU work or a surface: its CPU flags and fake completion
tests remain no proof of native retirement. Native implementation consumes the
[compatibility record](vulkan_compatibility_record.md) and still owes its own
production evidence and any changed-input requalification.

## Verification strategy

Use coordinated Hspec with independent flags for admission closed, CPU uses
ended, submitted work ended, presentation ended, dependents disposed, window
destroyed, and session terminated. Check ordering rather than timing sleeps.

Cover attachment exclusivity, foreign/stale/duplicate identities, callback
reentrancy, partial construction and unsafe rollback, close during construction,
detach then reattach, closing either of two windows, all-exit shutdown, repeated
cancellation, and failure during diagnostics/disposal. Once safe retirement is
recorded, destruction runs once. An unsafe/stuck fake dependency must keep its
parent live; the test can then supply independent safe evidence to finish and
join its threads, rather than leaking a hung test process.
Include cancellation queued at each handoff, a failed constructor that never
enters supervision, omitted early quiescence, an already latched supervisor
failure, and two attachments where only one can retire. Assert that progress
and retained failure evidence survive these orderings.

Ensure ordinary window-only callers need no attachment and retain their current
behavior. No public attachment can be used with the old unprotected constructor.
Public-client checks prove opacity and absence of native-pointer escape. X11
native tests exercise real window destruction after a fake owner's completion;
they do not claim GPU synchronization coverage. Cocoa tests require prior human
approval. Each implementation PR includes its own tests and current contracts.
Put examples with the owning component's tests using the suite layout current
when the issue is processed. A package-suite migration changes test plumbing,
not the required lifetime proofs, and is not a new dependency of this arc.

## Delivery plan

`Depends on` names local ledger IDs. External prerequisites refer to the
matching slices in `runtime_scheduling_design.md`. Before drafting LIFE-3 or
LIFE-4, verify those external entries are linked to actual tracker issues;
include `depends on #N` in the child body using those real numbers. If an
external prerequisite is not filed, defer the affected slice with that concrete
precondition rather than omitting it or inventing a number. Filing does not
prove implementation; solving waits for its prerequisites to merge.

### LIFE-1. Model exclusive window attachments and retirement evidence

- **Outcome:** backend-neutral state transitions and authority checks are proven
  without exposing a usable unsafe attachment API.
- **Scope:** P-1/P-5 model, bounded bookkeeping, pure/scripted Hspec cases.
- **Phase:** independent ownership model.
- **Depends on:** none.
- **Ordering:** can land alongside TIME-1/2/3.
- **Relevant decisions:** D-1, D-2, D-4.
- **Acceptance signals:** both CPU and backend retirement are required; foreign
  or stale completion cannot authorize destruction; exclusivity/rollback hold.
- **Out of scope:** public attachments, native destruction, GPU types.
- **Open questions:** None within this slice; this document's Q-3 is outside its scope.

### LIFE-2. Compose managed dependency lifetimes around application supervision

- **Outcome:** P-4's additive runner supports component-owned IO lifetimes.
- **Scope:** reuse current runtime orchestration and prove the nesting contract
  with a scripted component. Update application contracts and compatibility tests.
- **Phase:** composition prerequisite.
- **Depends on:** none.
- **Ordering:** independent of the model and scheduling; avoid unrelated runtime
  refactoring and retain the old entry points.
- **Relevant decisions:** D-2, D-3, D-4.
- **Acceptance signals:** workers end before managed dependency drain; parents
  and logger remain live; constructor/startup/action/cancellation paths retain
  failure identity; old runner examples remain green.
- **Out of scope:** native host integration, new supervision semantics.
- **Open questions:** None.

### LIFE-3. Establish the protected host retirement boundary

- **Outcome:** an attachment-capable IO host lifetime protects all-exit drain.
- **Scope:** P-3 composed through LIFE-2; private/scripted attachment construction,
  completion and disposal, repeated cancellation, parent ownership proof.
- **Phase:** safe integration prerequisite.
- **Depends on:** LIFE-1, LIFE-2.
- **External prerequisite:** scheduling TIME-4 (production wake handoff).
- **Ordering:** before any public attachment can create a dependent.
- **Relevant decisions:** D-1, D-2, D-3, D-4.
- **Acceptance signals:** collection exit never bypasses retirement; unknown
  safety retains parents; original exceptions and cleanup evidence survive;
  native wake remains safe through retirement and eventual session termination.
- **Out of scope:** public dynamic attachment API, surfaces, Vulkan waits.
- **Open questions:** None within this slice; this document's Q-3 is outside its scope.

### LIFE-4. Expose exclusive attachments with independent dynamic retirement

- **Outcome:** trusted integrations can safely attach, retire, and replace their
  window-dependent services while unrelated windows continue progressing.
- **Scope:** P-1/P-2 public contract on the protected host only; owner-loop
  progress/deadlines; dynamic close and detach; compatibility and native tests.
- **Phase:** usable pre-Vulkan boundary.
- **Depends on:** LIFE-3.
- **External prerequisite:** scheduling TIME-5 (deadline-driven owner turns)
  and the satisfied repair #123 (monitor association, merged in PR #126).
- **Ordering:** completes this arc; #123 is repaired before changing the
  window controller in this slice.
- **Relevant decisions:** D-1, D-2, D-3, D-4.
- **Acceptance signals:** two-window retirement stays independent; close and
  actual destruction are separately observable; publication and construction
  races cannot escape the guard; stale acknowledgements never release a new owner.
- **Out of scope:** creating actual surfaces, GPU submissions, render workers.
- **Open questions:** None within this slice; GPU implementation remains Q-3.

## Sources and handoff

The [Khronos presentation guide](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
distinguishes presentation-related reuse from ordinary submission completion.
The [GLFW Vulkan guide](https://www.glfw.org/docs/3.4/vulkan_guide.html) describes
surface creation. These inform the future backend contract; they do not turn
CPU flags into real GPU completion evidence.

The [scheduling design](runtime_scheduling_design.md) owns TIME dependencies.
The Vulkan design owns the later surface bridge, concrete completion strategy,
and real graphics fixture. Do not draft duplicate CPU lifetime issues there.
Both prerequisite arcs are already processed and implemented. This document
and the revised Vulkan design are ready for issue processing; the remaining
work belongs to Vulkan's existing epic #155. Continue that design, reconciling
the epic first and then handling one child per invocation. Do not redraft
LIFE-1–LIFE-4: D-6's additive surviving-owner lifetime belongs to VK-18/VK-7.
