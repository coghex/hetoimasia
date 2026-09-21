-- | The window host and its supervised owner loop: GLFW composed with the
-- runtime's application lifecycle.
--
-- A 'WindowHost' is an application dependency. It owns a GLFW session, the
-- windows created in it through a scoped
-- "Hetoimasia.Foundation.Resource.Collection", and their command bookkeeping,
-- and it is built by 'allocWindowHost' as a 'Scoped' value before supervision
-- is entered, so a construction failure rolls back through ordinary scoped
-- release before any worker exists. It is never a service the startup callback
-- returns. Workers receive only client capabilities from the host the
-- application already owns — 'hostCommandPort', a window's
-- 'Hetoimasia.GLFW.Command.WindowClient' with its "Hetoimasia.GLFW.Input" reader
-- and admission control, the monitor inventory's read endpoint
-- 'hostMonitors', 'hostActivity', 'hostWindowCapabilities', and the demand
-- publishers of 'Hetoimasia.GLFW.Demand' — and startup transfers no native
-- ownership to anyone.
--
-- 'runOwnerLoop' is the owner loop. The application's action runs it on the
-- process main thread, the session's owner, while background workers use the
-- runtime as usual. It is the only production executor of the host's command
-- port.
--
-- 'runScheduledOwnerLoop' is the additive scheduled path beside it, for an
-- application that paces itself by absolute deadlines: it samples the host's
-- injected 'hostClock', weighs the schedule its update last answered against
-- the demand its own inspection captured, and waits at most the earlier
-- deadline and at most the configured fallback bound. 'runOwnerLoop',
-- 'LoopHooks', 'Turn', and 'TurnStep' are unchanged by it — same turn order,
-- same idle-or-active choice, same fixed 'hostIdleWait' — and an application
-- using them never reads a clock. See \"The scheduled owner turn\" below.
--
-- 'renderTurn' is the CPU-only helper beside that path, and the one place where
-- an application's simulation demand, a window's captured demand, and the
-- schedule the loop waits on meet. It is pure, keyed by 'WindowId', and reads
-- one 'Hetoimasia.GLFW.Window.WindowObservation' per window to decide
-- eligibility: a window known hidden, minimized, or of zero framebuffer extent
-- is suspended and costs no wait, one whose extent is unknown is deferred, and
-- a closing or ended window has no normal render demand. It calls no graphics
-- API and infers no device readiness, so a rendering backend must add
-- presentation backpressure on top of it, and it gates no retirement. See
-- \"Render demand\" below.
--
-- = The owner turn
--
-- Every turn performs, in order:
--
-- 1. a supervised control check, 'checkRuntime';
-- 2. native event processing: a poll, or on an idle turn a finite wait;
-- 3. callback and state reconciliation: the session's monitor inventory, when
--    its callback reported a change, then the retirement of every closing
--    window no borrow defers, then every window, the collection of close
--    requests not yet surfaced for windows that are not closing, and each
--    window's overflow warning claim and input resumption;
-- 4. a control check;
-- 5. bounded command work: at most 'hostCommandBudget' commands claimed and
--    settled, across every port;
-- 6. a control check;
-- 7. bounded application event work: at most 'hostEventBudget' calls of
--    'loopEvent' that dispatched something;
-- 8. a control check;
-- 9. the application-owned update opportunity, 'loopUpdate', which sees the
--    turn's 'Turn' summary and answers whether to continue;
-- 10. a control check, before a 'Finish' result is returned or the next turn
--     begins.
--
-- A latched supervised failure is rethrown by the first check after it latched,
-- so no further dispatch begins once a check has seen it. A monitor callback
-- fault is rethrown at step 3, once the inventory refresh it forced has
-- committed.
--
-- = Budgets
--
-- A budget bounds how many dispatches are attempted, not how long one takes. A
-- rejected command costs its attempt exactly as a performed one does, so a
-- queue continuously refilled with commands that are all rejected still yields
-- to the next check. At most @max 'hostCommandBudget' 'hostEventBudget'@
-- dispatch attempts separate two consecutive control checks, whatever the
-- producers do. No budget bounds one command's native call or one application
-- event handler: long work belongs in a worker.
--
-- = Fair dispatch
--
-- Command work draws from the host's port and from the port of every window the
-- host holds that is not closing, ordered host port first and then windows in
-- registration order. The host remembers the port its last attempt served, and
-- each attempt claims the oldest command of the first later port, in cyclic
-- order, that has one queued. Commands run FIFO by committed admission within a
-- port, with no order promised across ports; the budget is one total across all
-- ports; and no port is attempted twice while another with a command queued
-- waits.
--
-- The service bound: let @P@ be the most ports dispatched from while a command
-- waits, at most @1 + 'hostWindowLimit'@, and @B@ the budget. Each attempt on a
-- port is followed by at most @P - 1@ attempts on other ports before that port's
-- next, so a command at position @k@ of its port's queue when a turn's command
-- work begins — the oldest is position one — is attempted within @⌈k · P / B⌉@
-- turns' command work, counting that turn, provided turns continue and each
-- dispatch returns. The oldest command of every port with one queued is
-- therefore attempted within @⌈P / B⌉@ turns. A window created meanwhile joins
-- the order behind the host's port, which its creation just served, so it never
-- delays a waiting port. It is a bound in turns, not a wall-clock deadline. The
-- scheduler's only state is its cursor.
--
-- = Windows
--
-- The host holds its windows as members of a collection allocated with the
-- fixed, validated 'hostWindowLimit'. Every window, configured or created later,
-- is acquired through "Hetoimasia.GLFW.Window"'s one assembly and registered
-- beside a command port and an input feed of its own, of 'hostInputCapacity'
-- and focused if its initial observation observed focus, with nothing
-- interruptible between the two registrations. The host owns no input producer
-- and neither warns about nor resumes a feed; native input and that owner-loop
-- integration arrive with GLFW-12. 'withHostWindow' lends a window to an owner-thread callback it
-- must not escape; no public operation returns a window or reaches the
-- collection.
--
-- A creation command, admitted only through 'hostCommandPort', checks the
-- configuration, the limit, and poisoning before any native effect, each a typed
-- rejection. A native failure during construction whose rollback released
-- everything construction acquired is a typed rejection, registering nothing and
-- consuming no capacity. A construction failure whose rollback's own release
-- failed is never downgraded to one: it propagates unchanged with that cleanup
-- evidence, interrupting the command and ending the loop, as does anything else
-- raised — a cancellation, a callback fault, any other exception.
-- Success settles as 'Hetoimasia.GLFW.Command.WindowCreated' and hands over the
-- window's client capabilities beside that prepared data. An unawaited ticket
-- relinquishes nothing: 'hostWindowIdentities' still enumerates the window, and
-- the host disposes it at shutdown.
--
-- The close protocol — begun by a close command through any port serving the
-- window, 'closeHostWindow', or 'honourHostCloseRequest' — prepares the closing
-- observation, then in one transaction marks the window closing, closes its
-- port, settles its queued commands as not executed, closes its input feed
-- without awaiting any reset acknowledgement, and publishes the
-- 'Hetoimasia.GLFW.Window.WindowClosing' phase, with nothing interruptible
-- after it, and retires the window through the collection once no owner-thread borrow is
-- in progress; a turn retries a deferred retirement, and retirement never waits.
-- A window stays registered, and occupies capacity, until its retirement is
-- attempted. A retirement whose release fails is never attempted again: the
-- collection latches the failure, which poisons creation and is kept for its
-- final exit, and the window's observations report the failed disposal.
--
-- = Demand
--
-- A worker that wants a turn without submitting a command publishes demand:
-- 'hostDemandPublisher' is the application's one slot, and
-- 'Hetoimasia.GLFW.Command.clientDemandPublisher' is a window's own, created
-- with the window and closed in its closing transaction. A publication combines
-- immediate demand and the earliest requested deadline into the slot, advances
-- its revision, and then wakes the owner; 'captureHostDemand' and
-- 'captureWindowDemand' take the pending request with its revision on the owner
-- thread and clear exactly what they took, so a publication committed after a
-- capture stays pending for the next one. There is never a slot per worker or
-- per request, and a closed slot answers a typed rejection and makes no native
-- call. 'runOwnerLoop' captures nothing itself and makes nothing of a captured
-- deadline; folding one into the next wait is the scheduled path's, below.
--
-- = Idle waits
--
-- A turn is idle when the turn before it attempted no command and dispatched no
-- application event, and no command is queued at its entry. An active turn
-- polls; an idle turn waits at most 'hostIdleWait' seconds for a native event,
-- so a checkpoint follows even when no native input arrives. No wait is
-- indefinite, and a host with no windows waits on each idle turn rather than
-- spinning. The bound is a latency, not a shutdown deadline.
--
-- An idle wait ends early when an admission or a publication wakes the owner,
-- and that same turn's command work and update opportunity then serve what
-- arrived, so nothing admitted or published waits for the bound to run out.
-- Wakes may be coalesced or spurious, and neither repeats an execution nor a
-- capture: the queue and the slots are authoritative and the wake is only the
-- hint that they changed. After an expected platform wake failure has degraded
-- the session's wake path — reported once through 'loopLogger' under
-- @glfw.wake@ — nothing is posted at all and the finite bound alone keeps work
-- moving. The loop claims that report on every turn and once more as it ends,
-- however it ends, without ever waiting for a notification obligation:
-- admission and publication are still open there, and a worker may keep
-- registering more until supervision stops it. 'runWindowApplication' makes the
-- attempt that does wait, after quiescence and the worker drain, where no new
-- obligation can be registered; 'reportHostWakeDegradation' is that same
-- boundary for an application that owns a different shutdown. Native waits are safe foreign
-- calls, so background workers run while the owner is inside one.
-- 'hostActivity' reports the turn and whether its owner has begun its finite
-- wait: the flag is set immediately before the native call and cleared once it
-- returns, so it is a hint that a wait is starting or in progress, not proof that
-- the call has been entered.
--
-- = The scheduled owner turn
--
-- 'runScheduledOwnerLoop' runs the same turn with its native step chosen from
-- time rather than from the turn before. Each turn samples 'hostClock' once for
-- that choice; captures the application's pending demand and reads the queued
-- command count in one transaction; asks 'scheduledReady' whether an
-- application event is ready, without dispatching one and without spending any
-- of 'hostEventBudget'; and then polls when anything is ready or a deadline has
-- been reached, or waits the shorter of the time remaining to the earliest
-- deadline and the configured fallback bound 'hostIdleWait'. A deadline only
-- ever shortens a wait; no zero or negative timeout reaches GLFW; and a host
-- with no demand at all still waits the bound rather than spinning. That bound
-- is the whole nanosecond at or below the seconds configured, never the nearest
-- one, so it can never exceed them; a wait under a whole nanosecond is refused
-- by 'validateHostConfig' instead.
--
-- It then samples 'hostClock' once more and reconciles, dispatches, and offers
-- 'scheduledUpdate' exactly as 'runOwnerLoop' does, with the same checkpoints,
-- budgets, fair dispatch, retirement, close-request surfacing, and feed
-- recovery, so a due update is never starved by continuous traffic. That second
-- sample is the instant the update is given, so a deadline the wait itself
-- reached is due in the same turn; deadlines stay absolute and the next turn
-- samples afresh, so time spent in callbacks, dispatch, and the update consumes
-- the interval instead of being pushed out by a fresh full wait.
--
-- 'UpdateSchedule' is the application's own ongoing schedule, replaced by each
-- answer and never combined with an earlier one, so finishing an update implies
-- no demand for another; 'scheduledStart' is what holds before the first
-- answer. It is distinct from the coalesced request 'scheduledDemand' carries
-- with its revision, which that turn's inspection already consumed, so an old
-- request never becomes permanent work and an application that still wants an
-- early-delivered deadline retains it in the schedule it answers. Demand
-- arriving after the inspection ends the wait through the existing wake
-- protocol and is inspected on the next turn; the loop adds no second
-- notification mechanism, and a wake with nothing due is an ordinary turn that
-- recomputes its wait.
--
-- = Render demand
--
-- 'renderTurn' composes what an application wants simulated with what each of
-- its windows wants drawn, and is the only place the two meet. It takes the
-- sampled 'Hetoimasia.Foundation.Time.Instant', the application's
-- 'Hetoimasia.Runtime.UpdatePolicy.Demand', and one 'WindowRender' per live
-- window — its latest observation, what this turn captured from its slot with
-- that capture's revision, and the absolute frame deadline the application
-- currently wants for it. It answers the ordered 'RenderOffer's and the
-- 'UpdateSchedule' the loop should continue with, beside an updated
-- 'RenderDemand'. Nothing in it is in 'IO': it reads no clock, sleeps never,
-- starts no thread, and makes no native call.
--
-- 'windowRenderEligibility' reads one observation and nothing else. A closing
-- or terminal window is 'RenderExcluded'; otherwise a /known/ hidden,
-- minimized, or zero-dimension framebuffer observation is 'RenderSuspended',
-- even beside an 'Hetoimasia.GLFW.Window.Unavailable' field; otherwise an
-- unavailable framebuffer extent is 'RenderDeferred'; otherwise it is
-- 'RenderEligible'. An unavailable visible or iconified field asserts nothing.
--
-- A suspended or deferred window keeps its dirtiness, its published deadline,
-- and its frame request, and contributes neither its expired nor its pending
-- deadlines to the schedule, so it can never shorten a wait to nothing.
-- Leaving suspension rebases that window's frame schedule and owes exactly one
-- current frame, held apart from the caller's own replaceable schedule so that
-- replacing it cannot erase a resume frame nothing has served; nothing missed
-- is replayed. At most 'renderBudgetSize'
-- opportunities are offered per turn, each window once, rotating after the
-- window served last, so an always-dirty window starves no other, and due work
-- left beyond the budget is what keeps the next schedule 'UpdateImmediately'.
-- A deadline this turn's own offer already covers is left out of the schedule,
-- so the loop is not woken for work it has just been handed.
-- 'acknowledgeRender' clears only what the offer served: a publication captured
-- since stays pending and is offered again. A window a turn stops listing, or
-- one whose observation reports any phase but
-- 'Hetoimasia.GLFW.Window.WindowOpen', loses its entry — a window's demand slot
-- closes with its closing transaction, so there is nothing left to capture for
-- it — as does one passed to 'forgetRenderWindow'.
--
-- The simulation's demand is carried independently of every window: with every
-- window suspended the schedule is still the simulation's, and with neither
-- there is no demand at all. Retirement is not represented here and is never
-- gated here — hiding or closing a window suppresses only its rendering.
--
-- = Close requests
--
-- A native close request is captured by the window's own callbacks, as
-- "Hetoimasia.GLFW.Window" describes; the host adds no second callback owner.
-- After reconciliation, a request a window's observation carries that this host
-- has not already surfaced appears once in 'turnCloseRequests'. What it means is
-- the application's decision. 'rejectHostCloseRequest' clears it, if it is
-- still the window's latest; leaving it latched is also a decision. The loop
-- ends only when 'loopUpdate' answers 'Finish': a close request, including one
-- for the last window, neither ends the loop nor the runtime, and destroys
-- nothing. Nothing here closes the loop on a close request by default.
--
-- = Quiescence and shutdown order
--
-- 'quiesceWindowHost' is the host's quiescence action for
-- 'Hetoimasia.Runtime.Application.runScopedApplicationWithQuiescence', which
-- 'runWindowApplication' installs. In one finite, non-retrying transaction it
-- closes the admission of the host's port and of every window's port, settles
-- every queued command as 'Hetoimasia.GLFW.Command.NotExecuted', closes every
-- window's input feed, ending its reads without awaiting any reset
-- acknowledgement, and closes the application's demand slot and every window's.
-- It does not disable wake support: a retained port or publisher answers a typed
-- rejection and makes no native call, while the progress that still has to
-- happen keeps its own capability. A window whose creation was claimed before
-- quiescence and finishes after it is registered already closed, and the
-- 'Hetoimasia.GLFW.Command.WindowClient' its ticket hands over revives nothing. It destroys nothing, pumps nothing, waits on nothing, and is
-- idempotent. The
-- runner runs it on every exit from the supervised region before supervision's
-- boundary drain, so a worker awaiting a ticket is released to observe its stop
-- request. The ordinary boundary order is therefore:
--
-- 1. quiescence: every port's admission closes, queued callers settle, and every
--    input feed closes;
-- 2. supervision requests every live worker to stop and drains them;
-- 3. the host waits for the notification obligations still outstanding and makes
--    the wake path's one guarded reporting attempt, with every dependency and
--    the logger still live; a cancellation delivered during that wait completes
--    it uninterruptibly and spends the attempt before it is re-raised;
-- 4. the dependency scope unwinds: the host's own release closes every port's
--    admission again (a no-op after quiescence), the collection's final exit
--    releases every window still registered, closing ones included, once each
--    and newest first, retaining every cleanup failure it latched or observed,
--    and then the session, when the host owns it, is terminated;
-- 5. the runtime's terminal report and final flush.
--
-- As "Hetoimasia.Runtime.Application" specifies, the stop requests the fatal
-- latch makes, and the drain of a worker whose managed startup was abandoned or
-- cancelled, may precede quiescence; quiescence does not precede or unblock
-- them.
--
-- = What the owner thread and workers may wait on
--
-- A public owner-thread operation never blocks on work only the owner turn can
-- execute: on the owner thread, awaiting an unsettled ticket or capacity fails
-- with 'Hetoimasia.GLFW.Command.OwnerThreadWouldWait', and 'runOwnerLoop' and
-- 'rejectHostCloseRequest' refuse any other thread with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
--
-- The owner may be starting or draining a worker instead of running turns, so a
-- worker's startup and cleanup, including rollback and finalizers, must not
-- require a command's completion. An acknowledged run action may submit
-- commands while the loop is running, and should compose its wait with its stop
-- request, so a worker the owner asks to stop never waits on a turn that will
-- not come:
--
-- @
-- awaitOrStop ∷ StopToken → CompletionTicket → IO (Maybe Disposition)
-- awaitOrStop token ticket =
--   atomically $
--     (Just \<$\> (pollCompletion ticket >>= maybe retry pure))
--       \`orElse\` (Nothing \<$ awaitStopRequest token)
-- @
--
-- These are obligations on application and worker code. The runtime's
-- guarantee is unchanged: quiescence precedes the boundary drain and nothing
-- earlier.
--
-- = State
--
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | State                    | Owner     | Readers and writers              | Thread               | Lifetime              | Reset or disposal                |
-- +==========================+===========+==================================+======================+=======================+==================================+
-- | Session and window       | The host  | Created by construction; creation| Owner                | The host's scope      | Remaining windows released newest|
-- | collection               |           | acquires; the close protocol     |                      |                       | first by the collection's exit,  |
-- |                          |           | retires; the loop pumps and      |                      |                       | then the session, when the scope |
-- |                          |           | reconciles                       |                      |                       | unwinds                          |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Window registry          | The host  | Registration inserts; closing    | Write: owner; read:  | Registration until    | Entry removed when a retirement  |
-- |                          |           | marks; retirement removes; ports,| any                  | retirement            | succeeded or failed              |
-- |                          |           | clients, and dispatch read       |                      |                       |                                  |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Command hosts: the host's| The host  | Ports admit; the loop executes;  | Admit: any; execute  | The host's scope; a   | Closed by the close protocol,    |
-- | and one per window       |           | the close protocol, quiescence,  | and close: owner     | window's until it is  | quiescence, or release; never    |
-- |                          |           | and release close                |                      | forgotten             | reopened                         |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Borrow counts            | The host  | Borrows raise and lower them;    | Owner                | The host              | Dropped on every exit from a     |
-- |                          |           | retirement reads them            |                      |                       | borrow                           |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Demand slots: the        | The host  | Publishers combine into them;    | Publish: any;        | The host, and a       | Cleared by each capture; closed  |
-- | application's and one    |           | the owner captures and clears;   | capture and close:   | window's until it is  | by the close protocol,           |
-- | per window               |           | closure closes them              | owner                | forgotten             | quiescence, or release           |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Input feeds: one per     | The host  | The consumer reads and           | Owner operations:    | A window's until it is| Closed by the close protocol,    |
-- | window                   |           | acknowledges; the application    | owner; capabilities: | forgotten             | quiescence, or release; never    |
-- |                          |           | enables and suspends; closure    | any                  |                       | reopened                         |
-- |                          |           | ends reads                       |                      |                       |                                  |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Dispatch cursor          | The host  | Each dispatch attempt writes the | Owner                | The host              | Never reset                      |
-- |                          |           | port it served                   |                      |                       |                                  |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Surfaced close requests  | The host  | The loop writes the latest       | Owner                | The host              | Replaced by a newer request;     |
-- |                          |           | request surfaced per window      |                      |                       | removed when the window is       |
-- |                          |           |                                  |                      |                       | forgotten                        |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Activity                 | The host  | The loop writes around each      | Write: owner; read:  | The host, while       | Left at the last turn            |
-- |                          |           | event step; 'hostActivity' reads | any                  | referenced            |                                  |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
--
-- The loop's turn number and idleness — and, on the scheduled path, the
-- application's ongoing 'UpdateSchedule' and the fallback bound it resolved
-- once at entry — live in its own recursion and end with it. None of this is
-- application state, and every piece of it is bounded by the live windows,
-- never by how many were ever created.
--
-- = Logging
--
-- The component takes no logger and writes to no sink of its own. The owner
-- loop writes through the 'Logger' the application injects on 'LoopHooks', or
-- on 'ScheduledHooks' for the scheduled path: the input overflow warning under
-- @glfw.input@, and the wake path's one
-- degradation warning under @glfw.wake@. Its failures are raised,
-- never logged: a configuration rejection under the @glfw.runtime@ component
-- and @construct window host@ operation, native failures under GLFW's own
-- operations, and supervised failures as the runtime delivers them. The
-- application runner makes the one terminal report.
--
-- = The protected host lifetime
--
-- 'allocWindowHost' builds a host as an ordinary 'Scoped' dependency and keeps
-- every behaviour described above. Its finalizers run uninterruptibly, after the
-- runner has already unwound what a dependent might still need, so such a host
-- accepts no graphics attachment and never will: it is issued no attachment
-- identity, and the private seam refuses it before any effect.
--
-- 'withProtectedWindowHost' and 'withProtectedWindowHostIn' build the same
-- host — same validated configuration, session, collection, port, windows, and
-- admission-closing release — inside a dedicated IO continuation boundary that
-- additionally owns the host's retirement state, and they are the only
-- constructors that do. They have the shape
-- 'Hetoimasia.Runtime.Application.runManagedApplication' accepts, and
-- 'runProtectedWindowApplication' is 'runWindowApplication' over one of them.
--
-- On every exit — a normal return, an action failure, a startup failure, a
-- dependency construction failure after host setup, an owner-loop failure, a
-- latched supervised failure, and cancellation — the boundary closes attachment
-- admission and ends new graphics use in one finite transaction, retires every
-- remaining attachment on the owner thread with the windows, the session, and
-- every parent still live, makes the wake path's one degradation report, and
-- only then lets those windows, that session, and those parents unwind. A body
-- failure stays primary with every later failure retained beside it under the
-- @glfw protected retirement@ label; after a successful body the first drain
-- failure becomes primary. A cancellation delivered during retirement is
-- deferred until retirement is safe and never releases anything early. When no
-- attachment can make safe progress the boundary retains everything, writes one
-- diagnostic under @glfw.retirement@, and waits.
--
-- = Window attachments
--
-- 'attachWindowGraphics' attaches one exclusive graphics owner to one open
-- window of a protected host, on the owner thread. The owner is the caller's —
-- its construction, its owned rollback, one bounded retirement step, the
-- 'CompletionPolicy' those steps are offered under, and how a failed step is
-- classified — and this boundary supplies the exclusivity, the ordering, and the
-- retirement rule. A host built by 'allocWindowHost' owns no retirement state,
-- so it answers 'GraphicsHostUnprotected' before any effect, and every other
-- refusal — a closing or ended window, an occupied one, another host or session,
-- closed admission — is answered before any acquisition effect too.
--
-- The protocol's declarations are values this boundary reads rather than calls
-- it makes, so they are demanded inside the attach call, before anything is
-- reserved: one that raises when it is demanded answers
-- 'GraphicsMetadataRejected' having reserved nothing, registered nothing, and
-- constructed nothing, and never reaches a running owner turn or the protected
-- exit's drain as an unprotected failure. A declaration that fails after the
-- attachment was acquired is contained where it is read, recorded as that
-- attachment's own evidence, and withdraws its progress path; it retires
-- nothing, and the attachment, its window, and the session stay until
-- independent certified evidence retires it.
--
-- A successful attachment hands back an opaque 'GraphicsService' and nothing
-- else: an identity, an incarnation, and its own observation, with no native
-- pointer, no window, no session, and no authority to destroy, release, or
-- certify anything. It is published only once construction and registration have
-- both completed. 'windowGraphicsStatus' and 'readGraphicsService' answer,
-- from any thread and without inference, whether an owner is attached, retiring,
-- or absent, which incarnation holds the slot, which retirement facts are still
-- missing, and whether the window's own native destruction has completed — which
-- stays distinct from the retirement, and distinct again from a native release
-- that failed.
--
-- An accepted close, through any entry point, ends that window's graphics
-- admission in the same transaction that publishes its closing phase, so no new
-- render use can begin after closing is observable; the close ticket's
-- 'Hetoimasia.GLFW.Command.WindowCloseBegun' still implies nothing about
-- destruction. 'detachWindowGraphics' runs the same retirement while the window
-- stays open, and frees the exclusive slot only after safe disposal; a later
-- attachment gets a fresh incarnation, against which the earlier
-- acknowledgement is refused.
--
-- Retirement progresses while the application runs: each turn offers at most
-- 'hostRetirementBudget' opportunities, rotating across the attachments that
-- have begun retiring, so one window's pending retirement never blocks another's
-- commands, close, attachment, or retirement. 'hostRetirementDemand' publishes
-- what the last round left owed, and 'runScheduledOwnerLoop' folds it into the
-- wait it chooses, so a due step is not delayed by the idle bound. An
-- attachment no round has yet offered an opportunity to, and one fresh evidence
-- has just revived, both keep the next turn immediate however short the budget
-- fell; once every one of them has been inspected and is waiting, the turn
-- waits toward the earliest instant they named, bounded by 'hostIdleWait'. No
-- opportunity performs a blocking GPU wait, and an owner declaring
-- 'BlockingCompletion' is refused the opportunity before its step runs. Only the
-- owner thread advances an attachment; other threads read its state and publish
-- bounded completion notices through 'hostGraphicsPublisher', which the owner
-- folds and revalidates exactly as an owner-thread report.
--
-- Nothing here creates a surface, submits GPU work, or waits on a device:
-- evidence that GPU work has completed is the backend's own, supplied through
-- the facts its owner certifies.
--
-- The seam underneath — @attachHostWindow@ and the rest — stays private to the
-- implementation sublibrary for this package's own examples.
--
-- See @docs/glfw.md@, \"The window host and owner loop\", for the same contract
-- in prose.
module Hetoimasia.Runtime.GLFW
  ( -- * Hosts
    WindowHost
  , allocWindowHost
  , allocWindowHostIn
  , hostMonitors
  , hostCommandPort
  , hostCommandStatistics
  , quiesceWindowHost
  , HostActivity (..)
  , hostActivity
  , hostWindowCapabilities

    -- * The wake path
  , hostWakePath
  , hostNotificationsInFlight
  , reportHostWakeDegradation

    -- * Demand
  , hostDemandPublisher
  , captureHostDemand
  , captureWindowDemand
  , hostDemandStatus
  , windowDemandStatus

    -- * Windows
  , hostWindowIdentities
  , hostWindowClient
  , withHostWindow
  , closeHostWindow
  , honourHostCloseRequest
  , CloseStart (..)
  , HostBookkeeping (..)
  , hostBookkeeping

    -- * Configuration
  , HostConfig (..)
  , defaultHostConfig
  , validateHostConfig
  , HostConfigRejected (..)
  , maximumWindowLimit
  , hostComponent

    -- * The owner loop
  , runOwnerLoop
  , LoopHooks (..)
  , noApplicationEvents
  , Turn (..)
  , TurnStep (..)
  , rejectHostCloseRequest

    -- * The scheduled owner loop
  , runScheduledOwnerLoop
  , ScheduledHooks (..)
  , defaultScheduledHooks
  , noApplicationReadiness
  , ScheduledTurn (..)
  , TurnPacing (..)
  , UpdateSchedule (..)
  , ScheduledStep (..)

    -- * Render demand
  , RenderDemand
  , noRenderDemand
  , renderDemandWindows
  , windowRenderState
  , WindowRenderState (..)
  , forgetRenderWindow
  , RenderBudget
  , renderBudget
  , renderBudgetSize
  , RenderBudgetRejected (..)
  , RenderEligibility (..)
  , windowRenderEligibility
  , WindowRender (..)
  , RenderTurn (..)
  , renderTurn
  , RenderResult (..)
  , renderDeadline
  , RenderOffer (..)
  , acknowledgeRender

    -- * The protected host lifetime
  , withProtectedWindowHost
  , withProtectedWindowHostIn
  , runProtectedWindowApplication

    -- * Window attachments
  , attachWindowGraphics
  , GraphicsAttachment (..)
  , AttachmentProtocol (..)
  , CompletionPolicy (..)
  , RetirementProgress (..)
  , RollbackOutcome (..)
  , RolledBack (..)
  , MetadataRejection (..)
  , GraphicsRefusal (..)
  , AttachmentId
  , attachmentWindow
  , attachmentIncarnation
  , Acknowledgement
  , acknowledgedAttachment
  , RetirementFact (..)
  , allRetirementFacts
  , certifyGraphicsFact
  , FactAnswer (..)
  , detachWindowGraphics
  , DetachAnswer (..)

    -- ** Observing an attachment
  , GraphicsService
  , graphicsWindow
  , graphicsAttachment
  , graphicsIncarnation
  , readGraphicsService
  , GraphicsObservation (..)
  , SlotState (..)
  , NativeDisposal (..)
  , WindowGraphics (..)
  , windowGraphicsStatus
  , windowGraphicsService
  , hostPendingAttachments
  , RetirementDemand (..)
  , noRetirementDemand
  , hostRetirementDemand

    -- ** Completion notices from other threads
  , hostGraphicsPublisher
  , CompletionPublisher
  , CompletionNotice
  , completionNotice
  , CompletionPublication (..)
  , NoticeAdmission (..)
  , publishCompletion

    -- * The supervised graphics owner
    -- $owner

    -- ** The injected backend operations
  , GraphicsOperations (..)
  , OwnerStart (..)
  , OwnerReady
  , ownerReady
  , TargetStart (..)
  , TargetHandoff (..)
  , TargetEvidence
  , targetEvidence
  , RollbackEvidence
  , rollbackEvidence
  , OwnerStep (..)
  , TargetStepView (..)
  , StepReport (..)
  , noStepWork
  , NextDeadline (..)
  , TargetRetire (..)
  , TargetRetired
  , targetRetired
  , OwnerRetire (..)
  , OwnerRetired
  , ownerRetired
  , OwnerDestroy (..)
  , OwnerDestroyed
  , ownerDestroyed
  , HasEvidence (..)

    -- ** Configuration
  , GraphicsOwnerConfig (..)
  , graphicsOwnerConfig
  , OwnerTimer
  , ownerTimer
  , realtimeOwnerTimer
  , graphicsOwnerComponent

    -- ** The owner and its protected host
  , GraphicsOwner
  , withGraphicsOwnerHost
  , withGraphicsOwnerHostIn
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner
  , graphicsOwnerWorker
  , wakeGraphicsHost

    -- ** Handing targets over, and taking them back
  , GraphicsHandover (..)
  , handOverGraphicsTarget
  , announceGraphicsTarget
  , graphicsTargetProtocol
  , publishGraphicsObservation
  , releaseGraphicsTarget
  , ReleaseAnswer (..)
  , publishOwnerRetirement
  , publishOwnerDestruction

    -- ** What crosses, and what comes back
  , OwnerHandoff
  , ownerHandoff
  , TargetEvent (..)
  , EventAdmission (..)
  , targetEventsOpen
  , TargetObservation (..)
  , ObservationPublication (..)
  , OwnerDemand (..)
  , noOwnerDemand
  , publishOwnerDemand
  , ScenePublication (..)
  , publishOwnerScene
  , OwnerStatus (..)
  , OwnerPhase (..)
  , readOwnerStatusNow
  , awaitOwnerRound
  , TerminalRecord (..)
  , readTargetTerminalsNow
  , ownerDestructionVerified
  , OwnerTerminal (..)
  , noOwnerTerminal
  , readOwnerTerminalNow
  , readOwnerTargets
  , readOwnerAcknowledged
  , Stage (..)
  , custodyOf
  , readOwnerCustody
  , TargetStanding (..)
  , readTargetStanding
  , readOwnerFailure
  , readOwnerFailures
  , retainedFailureBound
  , ownerTargetAcknowledgement

    -- ** The extent seam
  , TargetGeometry (..)
  , noTargetGeometry
  , ExtentBounds (..)
  , observationFramebuffer
  , observeGeometry
  , boundGeometry
  , SuppliedExtent (..)
  , ChosenExtent (..)
  , ExtentRefusal (..)
  , chooseTargetExtent
  , readOwnerGeometry

    -- ** Failures
  , OwnerDestructionUnverified (..)
  , OwnerHostUnprotected (..)
  , OwnerHandleMissing (..)
  , OwnerHandoverUnsettled (..)

    -- * Applications
  , runWindowApplication
  ) where

import Hetoimasia.Runtime.GLFW.Internal
import Hetoimasia.Runtime.GLFW.Internal.Owner
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
import Hetoimasia.Runtime.GLFW.Internal.RenderDemand

-- $owner
-- 'withGraphicsOwnerHost' is the additive protected-host constructor beside
-- 'withProtectedWindowHost': the same session, host, windows, attachment
-- model, and exit drain, with one supervised graphics owner alive across that
-- drain. Every existing constructor, 'runProtectedWindowApplication', and
-- every window-only entry point keep their signatures and their behaviour, and
-- an application that never asks for an owner never has one.
--
-- The owner runs rendering on a worker of its own while GLFW stays on the
-- process main thread. It makes no GLFW call: the main thread keeps the
-- session, the windows, surface creation, event processing, and every window
-- command, and a platform modal loop there still stalls all of them. What the
-- owner is given instead is a narrow, injected 'GraphicsOperations' record and
-- explicit bounded handoffs in both directions, so the rendering backend is
-- supplied to this machinery rather than built into it.
--
-- See "Hetoimasia.Runtime.GLFW.Internal.Owner" for the exit order, which is
-- the Vulkan design's D-33, and @docs\/glfw.md@ for what an application sees
-- during a main-thread stall.
