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
-- 'Hetoimasia.GLFW.Command.WindowClient', the monitor inventory's read endpoint
-- 'hostMonitors', 'hostActivity', and 'hostWindowCapabilities' — and startup
-- transfers no native ownership to anyone.
--
-- 'runOwnerLoop' is the owner loop. The application's action runs it on the
-- process main thread, the session's owner, while background workers use the
-- runtime as usual. It is the only production executor of the host's command
-- port.
--
-- = The owner turn
--
-- Every turn performs, in order:
--
-- 1. a supervised control check, 'checkRuntime';
-- 2. native event processing: a poll, or on an idle turn a finite wait;
-- 3. callback and state reconciliation: the session's monitor inventory, when
--    its callback reported a change, then the retirement of every closing
--    window no borrow defers, then every window, and the collection of close
--    requests not yet surfaced for windows that are not closing;
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
-- beside a command port of its own, with nothing interruptible between the two
-- registrations. 'withHostWindow' lends a window to an owner-thread callback it
-- must not escape; no public operation returns a window or reaches the
-- collection.
--
-- A creation command, admitted only through 'hostCommandPort', checks the
-- configuration, the limit, and poisoning before any native effect, each a typed
-- rejection. A native failure during construction is a typed rejection after
-- its rollback, registering nothing and consuming no capacity; anything else
-- raised propagates with its cleanup evidence, and the command is interrupted.
-- Success settles as 'Hetoimasia.GLFW.Command.WindowCreated' and hands over the
-- window's client capabilities beside that prepared data. An unawaited ticket
-- relinquishes nothing: 'hostWindowIdentities' still enumerates the window, and
-- the host disposes it at shutdown.
--
-- The close protocol — begun by a close command through any port serving the
-- window, 'closeHostWindow', or 'honourHostCloseRequest' — prepares the closing
-- observation, then in one transaction marks the window closing, closes its
-- port, settles its queued commands as not executed, and publishes the
-- 'Hetoimasia.GLFW.Window.WindowClosing' phase, with nothing interruptible
-- after it, and retires the window through the collection once no owner-thread borrow is
-- in progress; a turn retries a deferred retirement, and retirement never waits.
-- A window stays registered, and occupies capacity, until its retirement is
-- attempted. A retirement whose release fails is never attempted again: the
-- collection latches the failure, which poisons creation and is kept for its
-- final exit, and the window's observations report the failed disposal.
--
-- = Idle waits
--
-- A turn is idle when the turn before it attempted no command and dispatched no
-- application event, and no command is queued at its entry. An active turn
-- polls; an idle turn waits at most 'hostIdleWait' seconds for a native event,
-- so a checkpoint follows even when no native input arrives. No wait is
-- indefinite, and a host with no windows waits on each idle turn rather than
-- spinning. The bound is a latency, not a shutdown deadline. There is no
-- wake-on-post: a command submitted during a wait waits for the wait to end, and
-- the same turn's command work then serves it. Native waits are safe foreign
-- calls, so background workers run while the owner is inside one.
-- 'hostActivity' reports the turn and whether its owner has begun its finite
-- wait: the flag is set immediately before the native call and cleared once it
-- returns, so it is a hint that a wait is starting or in progress, not proof that
-- the call has been entered.
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
-- closes the admission of the host's port and of every window's port, and
-- settles every queued command as 'Hetoimasia.GLFW.Command.NotExecuted'. It
-- destroys nothing, pumps nothing, waits on nothing, and is idempotent. The
-- runner runs it on every exit from the supervised region before supervision's
-- boundary drain, so a worker awaiting a ticket is released to observe its stop
-- request. The ordinary boundary order is therefore:
--
-- 1. quiescence: every port's admission closes and queued callers settle;
-- 2. supervision requests every live worker to stop and drains them;
-- 3. the dependency scope unwinds: the host's own release closes every port's
--    admission again (a no-op after quiescence), the collection's final exit
--    releases every window still registered, closing ones included, once each
--    and newest first, retaining every cleanup failure it latched or observed,
--    and then the session, when the host owns it, is terminated;
-- 4. the runtime's terminal report and final flush.
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
-- The loop's turn number and idleness live in its own recursion and end with
-- it. None of this is application state, and every piece of it is bounded by
-- the live windows, never by how many were ever created.
--
-- = Logging
--
-- The component takes no logger and writes to no sink. Its failures are raised,
-- never logged: a configuration rejection under the @glfw.runtime@ component
-- and @construct window host@ operation, native failures under GLFW's own
-- operations, and supervised failures as the runtime delivers them. The
-- application runner makes the one terminal report.
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
  , hostComponent

    -- * The owner loop
  , runOwnerLoop
  , LoopHooks (..)
  , noApplicationEvents
  , Turn (..)
  , TurnStep (..)
  , rejectHostCloseRequest

    -- * Applications
  , runWindowApplication
  ) where

import Hetoimasia.Runtime.GLFW.Internal
