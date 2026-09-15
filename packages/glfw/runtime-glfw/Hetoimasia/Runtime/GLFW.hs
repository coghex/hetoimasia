-- | The window host and its supervised owner loop: GLFW composed with the
-- runtime's application lifecycle.
--
-- A 'WindowHost' is an application dependency. It owns a GLFW session, the
-- windows created in it, and their command bookkeeping, and it is built by
-- 'allocWindowHost' as a 'Scoped' value before supervision is entered, so a
-- construction failure rolls back through ordinary scoped release before any
-- worker exists. It is never a service the startup callback returns. Workers
-- receive only client capabilities from the host the application already owns
-- — 'hostCommandPort', a window's read-only observations, the monitor
-- inventory's read endpoint 'hostMonitors', and 'hostActivity' —
-- and startup transfers no native ownership to anyone.
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
--    its callback reported a change, then every window, and the collection of
--    close requests not yet surfaced;
-- 4. a control check;
-- 5. bounded command work: at most 'hostCommandBudget' commands claimed and
--    settled;
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
-- closes the host's command admission and settles every queued command as
-- 'Hetoimasia.GLFW.Command.NotExecuted'. It destroys nothing, pumps nothing,
-- waits on nothing, and is idempotent. The runner runs it on every exit from
-- the supervised region before supervision's boundary drain, so a worker
-- awaiting a ticket is released to observe its stop request. The ordinary
-- boundary order is therefore:
--
-- 1. quiescence: admission closes and queued callers settle;
-- 2. supervision requests every live worker to stop and drains them;
-- 3. the dependency scope unwinds: the host's own release closes admission
--    again (a no-op after quiescence), its windows are destroyed, and then its
--    session, when the host owns it, is terminated;
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
-- | Session and windows      | The host  | Created by construction; the     | Owner                | The host's scope      | Windows destroyed, then the      |
-- |                          |           | loop pumps and reconciles them   |                      |                       | session, when the scope unwinds  |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Command host             | The host  | Ports admit; the loop executes;  | Admit: any; execute  | The host's scope      | Closed by quiescence and again   |
-- |                          |           | quiescence and release close     | and close: owner     |                       | at release; never reopened       |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Surfaced close requests  | The host  | The loop writes the latest       | Owner                | The host              | Never reset; replaced by a newer |
-- |                          |           | request surfaced per window      |                      |                       | request                          |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
-- | Activity                 | The host  | The loop writes around each      | Write: owner; read:  | The host, while       | Left at the last turn            |
-- |                          |           | event step; 'hostActivity' reads | any                  | referenced            |                                  |
-- +--------------------------+-----------+----------------------------------+----------------------+-----------------------+----------------------------------+
--
-- The loop's turn number and idleness live in its own recursion and end with
-- it. None of this is application state.
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
  , hostWindows
  , hostMonitors
  , hostCommandPort
  , hostCommandStatistics
  , quiesceWindowHost
  , HostActivity (..)
  , hostActivity

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

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (Exception, finally)
import Control.Monad (forM, void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader, observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.GLFW.Command
  ( CommandStatistics (..)
  , WindowCommandHost
  , WindowCommandPort
  , closeWindowCommands
  , commandStatistics
  , newWindowCommandHost
  , windowCommandPort
  )
import Hetoimasia.GLFW.Internal.Command (ExecutionStep (..), executeCommand, executeNextWith)
import Hetoimasia.GLFW.Internal.Session (ownerOperation, reconcileMonitorEvents)
import Hetoimasia.GLFW.Internal.Window
  ( EventProcessing (..)
  , processWindowEvents
  , reconcileWindowEvents
  , rejectCloseRequest
  )
import Hetoimasia.GLFW.Monitor (MonitorInventory, monitorInventory)
import Hetoimasia.GLFW.Session (Session, SessionConfig, allocSession, defaultSessionConfig)
import Hetoimasia.GLFW.Window
  ( CloseRequest
  , Window
  , WindowConfig
  , WindowId
  , WindowResult (..)
  , allocWindow
  , closeRequestWindow
  , observedCloseRequest
  , windowIdentity
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
    -- ^ The windows created in the session, in order. It may be empty.
  , hostCommandCapacity ∷ !Integer
    -- ^ How many commands the port holds queued.
  , hostCommandBudget ∷ !Int
    -- ^ The most commands one turn attempts. At least one.
  , hostEventBudget ∷ !Int
    -- ^ The most application events one turn dispatches. At least one.
  , hostIdleWait ∷ !Double
    -- ^ The most seconds an idle turn waits for a native event. Finite, above
    -- zero, and at most 'maximumIdleWait'.
  }
  deriving (Eq, Show)

-- | The platform's own session, the given windows, a capacity of 64, budgets of
-- 16, and a 0.1-second idle wait.
defaultHostConfig ∷ [WindowConfig] → HostConfig
defaultHostConfig windows =
  HostConfig
    { hostSessionConfig = defaultSessionConfig
    , hostWindowConfigs = windows
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
  deriving (Eq, Show)

instance Exception HostConfigRejected

-- | The longest idle wait a configuration may ask for, in seconds.
maximumIdleWait ∷ Double
maximumIdleWait = 60

-- | Check the budgets and the idle wait. The session, window, and capacity
-- settings are checked by the operations they configure.
validateHostConfig ∷ HostConfig → Either HostConfigRejected ()
validateHostConfig config
  | hostCommandBudget config < 1 = Left (CommandBudgetRejected (hostCommandBudget config))
  | hostEventBudget config < 1 = Left (EventBudgetRejected (hostEventBudget config))
  -- Written so a NaN, which fails every comparison, is refused too.
  | not (wait > 0 && wait <= maximumIdleWait) = Left (IdleWaitRejected wait)
  | otherwise = Right ()
  where
    wait = hostIdleWait config

-- | The component a host's own failures are attributed to.
hostComponent ∷ Component
hostComponent = unsafeComponent "glfw.runtime"

constructOperation, loopOperation, rejectOperation ∷ Operation
constructOperation = operation "construct window host"
loopOperation = operation "run owner loop"
rejectOperation = operation "reject close request"

-- ---------------------------------------------------------------------------
-- Hosts

-- | A session, its windows, and their command bookkeeping, owned together. Its
-- representation is private: no session, native handle, executor, or release
-- authority can be taken from it.
data WindowHost = WindowHost
  { hostSession ∷ !Session
  , hostWindowList ∷ ![Window]
  , hostCommands ∷ !WindowCommandHost
  , hostSettings ∷ !HostConfig
  , hostSurfaced ∷ !(IORef (Map WindowId CloseRequest))
  , hostActivityState ∷ !(TVar HostActivity)
  }

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
-- The configuration is validated first. Then the session is entered, each
-- window created in order, and the command host created. A failure at any
-- stage releases what the stages before it acquired and propagates. When the
-- scope ends, admission closes, the windows are destroyed, and the session ends.
allocWindowHost ∷ HasCallStack ⇒ HostConfig → Scoped WindowHost
allocWindowHost config = allocWindowHostIn (allocSession (hostSessionConfig config)) config

-- | 'allocWindowHost' over a session scope the caller supplies, such as a test
-- seam's session. The host owns the session only if that scope does.
allocWindowHostIn ∷ HasCallStack ⇒ Scoped Session → HostConfig → Scoped WindowHost
allocWindowHostIn sessionScope config = do
  liftIO (either (throwFailure hostComponent constructOperation []) pure (validateHostConfig config))
  session ← sessionScope
  windows ← traverse (allocWindow session) (hostWindowConfigs config)
  commands ← liftIO (newWindowCommandHost session (hostCommandCapacity config))
  -- Released first: admission closes before any window is destroyed.
  allocResource (pure ()) (\() → void (atomically (closeWindowCommands commands)))
  surfaced ← liftIO (newIORef Map.empty)
  activity ← liftIO (newTVarIO (HostActivity 0 False))
  pure (WindowHost session windows commands config surfaced activity)

-- | The host's windows, in creation order. A window handle carries no release
-- authority, and its owner operations refuse other threads.
hostWindows ∷ WindowHost → [Window]
hostWindows = hostWindowList

-- | The read endpoint of the host session's monitor inventory, which any thread
-- may read. It carries no native pointer and no authority to resolve an
-- identity; resolution is an owner-thread operation of "Hetoimasia.GLFW.Monitor".
hostMonitors ∷ WindowHost → SnapshotReader MonitorInventory
hostMonitors = monitorInventory . hostSession

-- | The client port workers submit commands through.
hostCommandPort ∷ WindowHost → WindowCommandPort
hostCommandPort = windowCommandPort . hostCommands

-- | The command bookkeeping, read in one transaction.
hostCommandStatistics ∷ WindowHost → STM CommandStatistics
hostCommandStatistics = commandStatistics . hostCommands

-- | What the owner loop is doing.
hostActivity ∷ WindowHost → STM HostActivity
hostActivity = readTVar . hostActivityState

-- | Close the host's command admission and settle every queued command as not
-- executed, in the calling transaction. Finite, non-retrying, and idempotent;
-- it destroys nothing, pumps nothing, and waits on nothing.
quiesceWindowHost ∷ WindowHost → STM ()
quiesceWindowHost = void . closeWindowCommands . hostCommands

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
    -- ^ Commands attempted, rejected ones included.
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
      queued ← commandsQueued <$> atomically (hostCommandStatistics host)
      let waited = idle && queued == 0
      processEvents host number waited
      reconcileMonitorEvents (hostSession host)
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

-- | Reconcile every window, and answer the close requests not yet surfaced.
surfaceCloseRequests ∷ WindowHost → IO [CloseRequest]
surfaceCloseRequests host =
  fmap catMaybes . forM (hostWindowList host) $ \window →
    reconcileWindowEvents window >>= \case
      WindowEnded _ → pure Nothing
      WindowAvailable () → do
        observation ← preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))
        case observedCloseRequest observation of
          Nothing → pure Nothing
          Just request → do
            surfaced ← Map.lookup (windowIdentity window) <$> readIORef (hostSurfaced host)
            if surfaced == Just request
              then pure Nothing
              else do
                modifyIORef' (hostSurfaced host) (Map.insert (windowIdentity window) request)
                pure (Just request)

-- | Claim and settle queued commands until the budget is spent or none is
-- queued, answering how many were attempted.
dispatchCommands ∷ WindowHost → Int → IO Int
dispatchCommands host budget = go 0
  where
    go attempted
      | attempted >= budget = pure attempted
      | otherwise =
          executeNextWith (pure ()) (hostCommands host) (executeCommand (hostWindowList host)) >>= \case
            Executed _ _ → go (attempted + 1)
            NothingQueued → pure attempted
            CommandsEnded → pure attempted

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
-- whether it was. A request for a window the host does not own, or one that has
-- ended, answers 'False'.
rejectHostCloseRequest ∷ WindowHost → CloseRequest → IO Bool
rejectHostCloseRequest host request =
  ownerOperation (hostSession host) rejectOperation [] $
    case find ((== closeRequestWindow request) . windowIdentity) (hostWindowList host) of
      Nothing → pure False
      Just window →
        rejectCloseRequest window request >>= \case
          WindowAvailable cleared → pure cleared
          WindowEnded _ → pure False

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
