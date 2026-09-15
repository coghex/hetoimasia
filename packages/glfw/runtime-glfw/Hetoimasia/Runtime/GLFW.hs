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
-- 'hostMonitors', and 'hostActivity' — and startup transfers no native
-- ownership to anyone.
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
-- The service bound: with @P@ ports dispatched from when a turn's command work
-- begins, at most @1 + 'hostWindowLimit'@, and budget @B@, a command queued in a
-- port at that moment is attempted within @⌈P / B⌉@ turns' command work,
-- counting that turn, provided turns continue and each dispatch returns. A
-- window created meanwhile joins the order behind the host's port, which its
-- creation just served, so it never delays a waiting port. It is a bound in
-- turns, not a wall-clock deadline. The scheduler's only state is its cursor.
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
-- window, 'closeHostWindow', or 'honourHostCloseRequest' — marks the window
-- closing, closes its port and settles its queued commands as not executed in
-- one transaction, publishes the 'Hetoimasia.GLFW.Window.WindowClosing' phase,
-- and retires the window through the collection once no owner-thread borrow is
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

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, bracket_, finally, fromException, mask_, rethrowIO, tryWithContext)
import Control.Monad (forM, forM_, void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader, observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.Foundation.Resource.Collection
  ( Collection
  , CollectionError (..)
  , Member
  , MemberStatus (..)
  , Retirement (..)
  , acquireMember
  , allocCollection
  , liveMemberCount
  , memberStatus
  , retireMember
  , withMember
  )
import Hetoimasia.GLFW.Command
  ( CommandRejection (..)
  , CommandResult (..)
  , CommandStatistics (..)
  , WindowClient
  , WindowCommandHost
  , WindowCommandPort
  , closeWindowCommands
  , commandStatistics
  , newWindowCommandHost
  , windowCommandPort
  )
import Hetoimasia.GLFW.Internal.Command
  ( CommandOrigin
  , Execution (..)
  , ExecutionStep (..)
  , WindowCommand (..)
  , executeNextWith
  , nativeRejectionOf
  , newWindowClient
  , newWindowPortHost
  , observeWindow
  )
import Hetoimasia.GLFW.Internal.Session (ownerOperation, reconcileMonitorEvents)
import Hetoimasia.GLFW.Internal.Window
  ( EventProcessing (..)
  , beginWindowClosing
  , processWindowEvents
  , reconcileWindowEvents
  , rejectCloseRequest
  , windowAssembly
  )
import Hetoimasia.GLFW.Monitor (MonitorInventory, monitorInventory)
import Hetoimasia.GLFW.Session (Session, SessionConfig, SessionMisuse (SessionPoisoned), allocSession, defaultSessionConfig)
import Hetoimasia.GLFW.Window
  ( CloseRequest
  , Window
  , WindowConfig
  , WindowId
  , WindowResult (..)
  , closeRequestWindow
  , observedCloseRequest
  , validateWindowConfig
  , windowIdentity
  , windowLocalIdentity
  , windowObservations
  )
import Hetoimasia.Runtime.Application (runScopedApplicationWithQuiescence)
import Hetoimasia.Runtime.Logging (LoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl, checkRuntime)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Configuration

-- | What a host is built from. A pure value, validated before anything is
-- acquired.
data HostConfig = HostConfig
  { hostSessionConfig ∷ !SessionConfig
    -- ^ The session 'allocWindowHost' enters. 'allocWindowHostIn' ignores it.
  , hostWindowConfigs ∷ ![WindowConfig]
    -- ^ The windows created when the host is built, in order. It may be empty.
  , hostWindowLimit ∷ !Int
    -- ^ The most windows the host holds live at once, closing windows included.
    -- At least one, and at least as many as 'hostWindowConfigs'.
  , hostCommandCapacity ∷ !Integer
    -- ^ How many commands the host's port, and each window's own port, holds
    -- queued.
  , hostCommandBudget ∷ !Int
    -- ^ The most commands one turn attempts, across every port. At least one.
  , hostEventBudget ∷ !Int
    -- ^ The most application events one turn dispatches. At least one.
  , hostIdleWait ∷ !Double
    -- ^ The most seconds an idle turn waits for a native event. Finite, above
    -- zero, and at most 'maximumIdleWait'.
  }
  deriving (Eq, Show)

-- | The platform's own session, the given windows, a limit of 16 live windows,
-- a capacity of 64, budgets of 16, and a 0.1-second idle wait.
defaultHostConfig ∷ [WindowConfig] → HostConfig
defaultHostConfig windows =
  HostConfig
    { hostSessionConfig = defaultSessionConfig
    , hostWindowConfigs = windows
    , hostWindowLimit = 16
    , hostCommandCapacity = 64
    , hostCommandBudget = 16
    , hostEventBudget = 16
    , hostIdleWait = 0.1
    }

-- | A host configuration refused before anything was acquired.
data HostConfigRejected
  = CommandBudgetRejected !Int
  | EventBudgetRejected !Int
  | IdleWaitRejected !Double
  | WindowLimitRejected !Int
    -- ^ The limit is below one, or below the number of configured windows.
  deriving (Eq, Show)

instance Exception HostConfigRejected

-- | The longest idle wait a configuration may ask for, in seconds.
maximumIdleWait ∷ Double
maximumIdleWait = 60

-- | Check the budgets, the idle wait, and the window limit. The session,
-- window, and capacity settings are checked by the operations they configure.
validateHostConfig ∷ HostConfig → Either HostConfigRejected ()
validateHostConfig config
  | hostCommandBudget config < 1 = Left (CommandBudgetRejected (hostCommandBudget config))
  | hostEventBudget config < 1 = Left (EventBudgetRejected (hostEventBudget config))
  -- Written so a NaN, which fails every comparison, is refused too.
  | not (wait > 0 && wait <= maximumIdleWait) = Left (IdleWaitRejected wait)
  | limit < 1 || limit < length (hostWindowConfigs config) = Left (WindowLimitRejected limit)
  | otherwise = Right ()
  where
    wait = hostIdleWait config
    limit = hostWindowLimit config

-- | The component a host's own failures are attributed to.
hostComponent ∷ Component
hostComponent = unsafeComponent "glfw.runtime"

constructOperation, loopOperation, rejectOperation, borrowOperation, closeOperation, honourOperation, bookkeepingOperation ∷ Operation
constructOperation = operation "construct window host"
loopOperation = operation "run owner loop"
rejectOperation = operation "reject close request"
borrowOperation = operation "borrow host window"
closeOperation = operation "close host window"
honourOperation = operation "honour close request"
bookkeepingOperation = operation "read host bookkeeping"

-- ---------------------------------------------------------------------------
-- Hosts

-- | A session, the windows it owns through a scoped collection, and their
-- command bookkeeping, owned together. Its representation is private: no
-- session, collection, member, native handle, executor, or release authority
-- can be taken from it.
data WindowHost = WindowHost
  { hostSession ∷ !Session
  , hostCollection ∷ !Collection
  , hostCommands ∷ !WindowCommandHost
  , hostSettings ∷ !HostConfig
  , hostEntries ∷ !(TVar (Map WindowId HostEntry))
    -- ^ Every window registered and not yet retired, closing ones included.
  , hostBorrowed ∷ !(IORef (Map WindowId Int))
    -- ^ The windows borrowed on the owner thread, with their borrow counts.
  , hostSurfaced ∷ !(IORef (Map WindowId CloseRequest))
  , hostCursor ∷ !(IORef PortKey)
    -- ^ The port the last dispatch attempt served.
  , hostActivityState ∷ !(TVar HostActivity)
  }

-- | One registered window: its collection member, its own command host, the
-- capabilities handed to clients, and whether its close protocol has begun.
data HostEntry = HostEntry
  { entryMember ∷ !(Member Window)
  , entryCommands ∷ !WindowCommandHost
  , entryClient ∷ !WindowClient
  , entryClosing ∷ !Bool
  }

-- | A command port's place in dispatch order: the host's port first, then each
-- window's in registration order.
data PortKey
  = HostPortKey
  | WindowPortKey !WindowId
  deriving (Eq, Ord)

-- | What the owner loop is doing, as clients may observe it.
data HostActivity = HostActivity
  { activityTurn ∷ !Natural
    -- ^ The turn whose event step last began; zero before the first.
  , activityWaiting ∷ !Bool
    -- ^ Whether the owner has begun that turn's finite native wait: set
    -- immediately before the native call and cleared once it returns.
  }
  deriving (Eq, Show)

-- | Enter a session and build a host in it for the rest of the enclosing scope,
-- on the process main thread.
--
-- The configuration is validated first. Then the session is entered, the
-- window collection allocated, the host's command port created, and each
-- configured window created in order as a collection member with its own port.
-- A failure at any stage releases what the stages before it acquired and
-- propagates. When the scope ends, every port's admission closes, every window
-- still registered is released, newest first, and the session ends.
allocWindowHost ∷ HasCallStack ⇒ HostConfig → Scoped WindowHost
allocWindowHost config = allocWindowHostIn (allocSession (hostSessionConfig config)) config

-- | 'allocWindowHost' over a session scope the caller supplies, such as a test
-- seam's session. The host owns the session only if that scope does.
allocWindowHostIn ∷ HasCallStack ⇒ Scoped Session → HostConfig → Scoped WindowHost
allocWindowHostIn sessionScope config = do
  liftIO (either (throwFailure hostComponent constructOperation []) pure (validateHostConfig config))
  session ← sessionScope
  -- Released after every later part: the collection's exit releases the
  -- windows still registered once admission has closed.
  collection ← allocCollection (hostWindowLimit config)
  commands ← liftIO (newWindowCommandHost session (hostCommandCapacity config))
  entries ← liftIO (newTVarIO Map.empty)
  -- Released first: every port's admission closes before any window is released.
  allocResource (pure ()) (\() → atomically (closeAdmission commands entries))
  host ←
    liftIO $
      WindowHost session collection commands config entries
        <$> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef HostPortKey
        <*> newTVarIO (HostActivity 0 False)
  liftIO (mapM_ (registerWindow host) (hostWindowConfigs config))
  pure host

-- | The read endpoint of the host session's monitor inventory, which any thread
-- may read. It carries no native pointer and no authority to resolve an
-- identity; resolution is an owner-thread operation of "Hetoimasia.GLFW.Monitor".
hostMonitors ∷ WindowHost → SnapshotReader MonitorInventory
hostMonitors = monitorInventory . hostSession

-- | The host's own client port: the one port with creation authority, which
-- also serves observation and close requests for any window the host owns.
hostCommandPort ∷ WindowHost → WindowCommandPort
hostCommandPort = windowCommandPort . hostCommands

-- | The host port's command bookkeeping, read in one transaction.
hostCommandStatistics ∷ WindowHost → STM CommandStatistics
hostCommandStatistics = commandStatistics . hostCommands

-- | What the owner loop is doing.
hostActivity ∷ WindowHost → STM HostActivity
hostActivity = readTVar . hostActivityState

-- | Close the admission of the host's port and of every window's port, and
-- settle every queued command as not executed, in the calling transaction.
-- Finite, non-retrying, and idempotent; it destroys nothing, pumps nothing, and
-- waits on nothing.
quiesceWindowHost ∷ WindowHost → STM ()
quiesceWindowHost host = closeAdmission (hostCommands host) (hostEntries host)

closeAdmission ∷ WindowCommandHost → TVar (Map WindowId HostEntry) → STM ()
closeAdmission commands entries = do
  void (closeWindowCommands commands)
  readTVar entries >>= mapM_ (void . closeWindowCommands . entryCommands)

-- ---------------------------------------------------------------------------
-- Windows

-- | The identities of the windows the host holds, in registration order: every
-- window created and not yet retired, closing ones included. Any thread may
-- read it; it is bounded by the live-window limit.
hostWindowIdentities ∷ WindowHost → STM [WindowId]
hostWindowIdentities host = Map.keys <$> readTVar (hostEntries host)

-- | The client capabilities of a window the host holds: its own command port
-- and its read-only observations. 'Nothing' once the window has been retired,
-- or for an identity the host never held.
hostWindowClient ∷ WindowHost → WindowId → STM (Maybe WindowClient)
hostWindowClient host target = fmap entryClient . Map.lookup target <$> readTVar (hostEntries host)

-- | Lend a window the host holds to an owner-thread callback, closing or not.
-- A window already retired, or never held, answers 'WindowEnded' without
-- running the callback.
--
-- The window must not escape the callback. While it runs, the window cannot be
-- retired: a close protocol begun meanwhile defers retirement until every
-- borrow has ended. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
withHostWindow ∷ WindowHost → WindowId → (Window → IO r) → IO (WindowResult r)
withHostWindow host target action =
  ownerOperation (hostSession host) borrowOperation (windowIdentifiers target) $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure (WindowEnded target)
      Just entry → WindowAvailable <$> borrowWindow host target entry action

borrowWindow ∷ WindowHost → WindowId → HostEntry → (Window → IO r) → IO r
borrowWindow host target entry action =
  bracket_
    (modifyIORef' (hostBorrowed host) (Map.insertWith (+) target 1))
    (modifyIORef' (hostBorrowed host) (Map.update (\count → if count > 1 then Just (count - 1) else Nothing) target))
    (withMember (hostCollection host) (entryMember entry) action)

-- | How a request to begin a window's close protocol was answered.
data CloseStart
  = CloseStarted
    -- ^ The protocol began now.
  | CloseAlreadyStarted
    -- ^ The window was already closing; nothing changed.
  | CloseNotServed
    -- ^ The host holds no window with this identity; nothing changed.
  | CloseRequestSuperseded
    -- ^ The close request is no longer the window's latest; nothing changed.
  deriving (Eq, Show)

-- | Begin a window's close protocol on the owner thread, as a close command
-- does. Refuses other threads with 'Hetoimasia.GLFW.Session.NotSessionOwner'.
closeHostWindow ∷ WindowHost → WindowId → IO CloseStart
closeHostWindow host target =
  ownerOperation (hostSession host) closeOperation (windowIdentifiers target) (beginClose host target)

-- | Honour a surfaced close request on the owner thread: begin its window's
-- close protocol if the request is still that window's latest, after
-- reconciling what its callbacks captured. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
honourHostCloseRequest ∷ WindowHost → CloseRequest → IO CloseStart
honourHostCloseRequest host request =
  ownerOperation (hostSession host) honourOperation (windowIdentifiers target) $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure CloseNotServed
      Just entry
        | entryClosing entry → pure CloseAlreadyStarted
        | otherwise → do
            latest ←
              borrowWindow host target entry $ \window →
                reconcileWindowEvents window >>= \case
                  WindowEnded _ → pure Nothing
                  WindowAvailable () → latestCloseRequest window
            if latest == Just request then beginClose host target else pure CloseRequestSuperseded
  where
    target = closeRequestWindow request

-- | The close protocol, on the owner thread:
--
-- 1. in one transaction, mark the window closing, close its port's admission,
--    and settle its queued commands as not executed;
-- 2. publish the 'Hetoimasia.GLFW.Window.WindowClosing' phase in its
--    observations;
-- 3. retire it through the collection, unless it or another window is
--    borrowed, in which case a later turn retries.
beginClose ∷ WindowHost → WindowId → IO CloseStart
beginClose host target = do
  started ← atomically $
    Map.lookup target <$> readTVar (hostEntries host) >>= \case
      Nothing → pure Nothing
      Just entry
        | entryClosing entry → pure (Just Nothing)
        | otherwise → do
            let closing = entry {entryClosing = True}
            modifyTVar' (hostEntries host) (Map.insert target closing)
            void (closeWindowCommands (entryCommands entry))
            pure (Just (Just closing))
  case started of
    Nothing → pure CloseNotServed
    Just Nothing → pure CloseAlreadyStarted
    Just (Just entry) → do
      void (borrowWindow host target entry beginWindowClosing)
      retireClosing host target entry
      pure CloseStarted

-- | Attempt a closing window's retirement. A borrow of another window defers it
-- without calling the collection, and a borrow of this one defers it with the
-- collection's in-use answer. A retirement that succeeded or failed forgets the
-- window: a failed release is latched by the collection as evidence for its
-- exit and is never attempted again, and the window's observations report it.
retireClosing ∷ WindowHost → WindowId → HostEntry → IO ()
retireClosing host target entry = do
  borrowed ← readIORef (hostBorrowed host)
  if any (/= target) (Map.keys borrowed)
    then pure ()
    else
      tryWithContext (retireMember (hostCollection host) (entryMember entry)) >>= \case
        Right RetirementInUse → pure ()
        Right _ → forget
        Left (caught ∷ ExceptionWithContext SomeException) →
          memberStatus (entryMember entry) >>= \case
            MemberRetirementFailed _ → forget
            _ → rethrowIO caught
  where
    forget = do
      atomically (modifyTVar' (hostEntries host) (Map.delete target))
      modifyIORef' (hostSurfaced host) (Map.delete target)

-- | Retry the retirement of every closing window, in registration order.
retirePending ∷ WindowHost → IO ()
retirePending host = do
  entries ← readTVarIO (hostEntries host)
  forM_ (Map.toAscList entries) $ \(target, entry) →
    if entryClosing entry then retireClosing host target entry else pure ()

-- | Acquire a window as a collection member and register it with its own port.
-- Masked, and with nothing interruptible after the acquisition, so a
-- cancellation cannot separate the collection's registration from the host's.
registerWindow ∷ WindowHost → WindowConfig → IO WindowClient
registerWindow host config = mask_ $ do
  member ← acquireMember (hostCollection host) (windowAssembly (hostSession host) config)
  (identity, reader) ←
    withMember (hostCollection host) member (\window → pure (windowIdentity window, windowObservations window))
  commands ← newWindowPortHost (hostSession host) (hostCommandCapacity (hostSettings host)) identity
  let client = newWindowClient identity commands reader
  atomically (modifyTVar' (hostEntries host) (Map.insert identity (HostEntry member commands client False)))
  pure client

-- | Create a window for a creation command. The configuration and the live
-- limit are checked before any native effect, and poisoning is refused before
-- one too; each is a typed rejection. A native failure during construction,
-- after its rollback, is a typed rejection as well. Anything else — a
-- cancellation, a callback fault, any other exception — propagates with its
-- cleanup evidence.
createWindow ∷ WindowHost → WindowConfig → IO Execution
createWindow host config = case validateWindowConfig config of
  Left invalid → pure (Completed (Left (WindowConfigInvalid invalid)))
  Right () → do
    live ← liveMemberCount (hostCollection host)
    if live >= limit
      then pure (Completed (Left (WindowCapacityReached limit)))
      else
        tryWithContext (registerWindow host config) >>= \case
          Right client → pure (Created client)
          Left caught@(ExceptionWithContext context failure)
            | Just CollectionPoisoned ← fromException failure → rejected WindowCreationPoisoned
            | Just SessionPoisoned ← fromException failure → rejected WindowCreationPoisoned
            | Just (MemberLimitReached reached) ← fromException failure → rejected (WindowCapacityReached reached)
            | Just native ← fromException failure
            , Just (failed, outcome, reports) ← nativeRejectionOf (ExceptionWithContext context native) →
                rejected (WindowCreationFailed failed outcome reports)
            | otherwise → rethrowIO caught
  where
    limit = hostWindowLimit (hostSettings host)
    rejected = pure . Completed . Left

-- | Execute one claimed command, from whichever port it was admitted through.
-- Scope was checked by the executor before this runs.
executeHostCommand ∷ WindowHost → CommandOrigin → WindowCommand → IO Execution
executeHostCommand host _ = \case
  CreateWindow config → createWindow host config
  CloseWindow target →
    beginClose host target >>= \case
      CloseStarted → completed (Right (WindowCloseBegun target))
      CloseAlreadyStarted → completed (Left (WindowIsClosing target))
      _ → completed (Left (WindowNotServed target))
  ObserveWindow target →
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → completed (Left (WindowNotServed target))
      Just entry
        | entryClosing entry → completed (Left (WindowIsClosing target))
        | otherwise → Completed <$> borrowWindow host target entry (observeWindow target)
  where
    completed = pure . Completed

-- | What the host holds, for bounding checks: every count is proportional to the
-- live windows, never to how many were ever created.
data HostBookkeeping = HostBookkeeping
  { bookkeepingWindows ∷ !Int
    -- ^ Windows registered and not yet retired.
  , bookkeepingClosing ∷ !Int
    -- ^ Of those, windows whose close protocol has begun.
  , bookkeepingMembers ∷ !Int
    -- ^ Live members of the host's collection.
  , bookkeepingPorts ∷ !Int
    -- ^ Command ports dispatched from: the host's and one per registered window.
  , bookkeepingPendingCells ∷ !Natural
    -- ^ Completion cells held across every port.
  , bookkeepingSurfaced ∷ !Int
    -- ^ Close requests remembered as surfaced.
  , bookkeepingBorrowed ∷ !Int
    -- ^ Windows currently borrowed on the owner thread.
  }
  deriving (Eq, Show)

-- | Read the host's bookkeeping on the owner thread. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
hostBookkeeping ∷ WindowHost → IO HostBookkeeping
hostBookkeeping host =
  ownerOperation (hostSession host) bookkeepingOperation [] $ do
    (entries, cells) ← atomically $ do
      entries ← readTVar (hostEntries host)
      hostCells ← commandsPending <$> commandStatistics (hostCommands host)
      windowCells ← forM (Map.elems entries) (fmap commandsPending . commandStatistics . entryCommands)
      pure (entries, hostCells + sum windowCells)
    members ← liveMemberCount (hostCollection host)
    surfaced ← Map.size <$> readIORef (hostSurfaced host)
    borrowed ← Map.size <$> readIORef (hostBorrowed host)
    pure
      HostBookkeeping
        { bookkeepingWindows = Map.size entries
        , bookkeepingClosing = Map.size (Map.filter entryClosing entries)
        , bookkeepingMembers = members
        , bookkeepingPorts = 1 + Map.size entries
        , bookkeepingPendingCells = cells
        , bookkeepingSurfaced = surfaced
        , bookkeepingBorrowed = borrowed
        }

windowIdentifiers ∷ WindowId → [(Text, Text)]
windowIdentifiers window = [("window", Text.pack (show (windowLocalIdentity window)))]

latestCloseRequest ∷ Window → IO (Maybe CloseRequest)
latestCloseRequest window =
  observedCloseRequest . preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))

-- ---------------------------------------------------------------------------
-- The owner loop

-- | What the application supplies to the owner loop.
data LoopHooks a = LoopHooks
  { loopEvent ∷ IO Bool
    -- ^ One application event opportunity. 'True' when it dispatched
    -- something, which costs one unit of the event budget; 'False' when nothing
    -- was ready, which ends the turn's event work.
  , loopUpdate ∷ Turn → IO (TurnStep a)
    -- ^ The application-owned update opportunity, once per turn.
  }

-- | An event opportunity that never has anything ready.
noApplicationEvents ∷ IO Bool
noApplicationEvents = pure False

-- | What one turn did, as its update opportunity sees it.
data Turn = Turn
  { turnNumber ∷ !Natural
    -- ^ Starting at one.
  , turnWaited ∷ !Bool
    -- ^ Whether the turn was idle and made a finite native wait.
  , turnCommands ∷ !Int
    -- ^ Commands attempted across every port, rejected ones included.
  , turnEvents ∷ !Int
    -- ^ Application events dispatched.
  , turnCloseRequests ∷ ![CloseRequest]
    -- ^ Close requests surfaced for the first time, in window order.
  }
  deriving (Eq, Show)

-- | Whether the loop continues.
data TurnStep a
  = Continue
  | Finish a
  deriving (Eq, Show)

-- | Run owner turns until 'loopUpdate' answers 'Finish', on the session's owner
-- thread, and return its result once a final control check has passed.
--
-- Another thread is refused with 'Hetoimasia.GLFW.Session.NotSessionOwner'
-- before anything runs. A supervised failure, a native failure, a callback
-- fault rethrown at reconciliation, a command's rethrown interruption, or a
-- hook's failure ends the loop and propagates.
runOwnerLoop ∷ WindowHost → RuntimeControl → LoopHooks a → IO a
runOwnerLoop host control hooks =
  ownerOperation (hostSession host) loopOperation [] (turn 1 False)
  where
    settings = hostSettings host
    turn number idle = do
      checkRuntime control
      queued ← atomically (queuedCommands host)
      let waited = idle && queued == 0
      processEvents host number waited
      reconcileMonitorEvents (hostSession host)
      retirePending host
      closes ← surfaceCloseRequests host
      checkRuntime control
      commands ← dispatchCommands host (hostCommandBudget settings)
      checkRuntime control
      events ← dispatchEvents (loopEvent hooks) (hostEventBudget settings)
      checkRuntime control
      step ← loopUpdate hooks (Turn number waited commands events closes)
      checkRuntime control
      case step of
        Finish result → pure result
        Continue → turn (number + 1) (commands == 0 && events == 0)

-- | Commands queued across every port.
queuedCommands ∷ WindowHost → STM Natural
queuedCommands host = do
  queued ← commandsQueued <$> commandStatistics (hostCommands host)
  entries ← readTVar (hostEntries host)
  windows ← forM (Map.elems entries) (fmap commandsQueued . commandStatistics . entryCommands)
  pure (queued + sum windows)

-- | Poll, or wait the configured bound, publishing the activity around it.
processEvents ∷ WindowHost → Natural → Bool → IO ()
processEvents host number waited = do
  atomically (writeTVar (hostActivityState host) (HostActivity number waited))
  processWindowEvents (hostSession host) processing
    `finally` atomically (writeTVar (hostActivityState host) (HostActivity number False))
  where
    processing
      | waited = AwaitEventsFor (hostIdleWait (hostSettings host))
      | otherwise = ProcessPending

-- | Reconcile every window the host holds, and answer the close requests of
-- windows not closing that were not surfaced before.
surfaceCloseRequests ∷ WindowHost → IO [CloseRequest]
surfaceCloseRequests host = do
  entries ← readTVarIO (hostEntries host)
  fmap catMaybes . forM (Map.toAscList entries) $ \(target, entry) →
    borrowWindow host target entry $ \window →
      reconcileWindowEvents window >>= \case
        WindowEnded _ → pure Nothing
        WindowAvailable ()
          | entryClosing entry → pure Nothing
          | otherwise →
              latestCloseRequest window >>= \case
                Nothing → pure Nothing
                Just request → do
                  surfaced ← Map.lookup target <$> readIORef (hostSurfaced host)
                  if surfaced == Just request
                    then pure Nothing
                    else do
                      modifyIORef' (hostSurfaced host) (Map.insert target request)
                      pure (Just request)

-- | Attempt queued commands, fairly across ports, until the budget is spent or
-- no port has one queued, answering how many were attempted.
--
-- Ports are ordered by 'PortKey'. Each attempt claims the oldest command of the
-- first port after the one the previous attempt served, in that cyclic order,
-- that has one queued, so FIFO holds within each port and no port is attempted
-- twice while another port that had a command queued waits. Windows that are
-- closing have no port to dispatch from.
dispatchCommands ∷ WindowHost → Int → IO Int
dispatchCommands host budget = go 0
  where
    go attempted
      | attempted >= budget = pure attempted
      | otherwise = do
          entries ← readTVarIO (hostEntries host)
          cursor ← readIORef (hostCursor host)
          let ports =
                (HostPortKey, hostCommands host)
                  : [(WindowPortKey target, entryCommands entry) | (target, entry) ← Map.toAscList entries, not (entryClosing entry)]
              (before, after) = span ((<= cursor) . fst) ports
          serve attempted (after <> before)
    serve attempted [] = pure attempted
    serve attempted ((key, commands) : rest) =
      executeNextWith (pure ()) commands (executeHostCommand host) >>= \case
        Executed _ _ → writeIORef (hostCursor host) key >> go (attempted + 1)
        NothingQueued → serve attempted rest
        CommandsEnded → serve attempted rest

-- | Offer event opportunities until the budget is spent or nothing is ready,
-- answering how many dispatched something.
dispatchEvents ∷ IO Bool → Int → IO Int
dispatchEvents opportunity budget = go 0
  where
    go dispatched
      | dispatched >= budget = pure dispatched
      | otherwise = opportunity >>= \ready → if ready then go (dispatched + 1) else pure dispatched

-- | Reject a close request on the owner thread: it is cleared from its window's
-- observation only if it is still that window's latest, and the answer says
-- whether it was. A request for a window the host does not hold answers
-- 'False'.
rejectHostCloseRequest ∷ WindowHost → CloseRequest → IO Bool
rejectHostCloseRequest host request =
  ownerOperation (hostSession host) rejectOperation [] $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure False
      Just entry →
        borrowWindow host target entry (\window → rejectCloseRequest window request) >>= \case
          WindowAvailable cleared → pure cleared
          WindowEnded _ → pure False
  where
    target = closeRequestWindow request

-- ---------------------------------------------------------------------------
-- Applications

-- | 'Hetoimasia.Runtime.Application.runScopedApplicationWithQuiescence' with
-- the host's quiescence action: the fourth argument finds the host among the
-- application's dependencies.
runWindowApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → Scoped dependencies
  → (dependencies → WindowHost)
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runWindowApplication enterLifetime name dependencies host =
  runScopedApplicationWithQuiescence enterLifetime name dependencies (quiesceWindowHost . host)
