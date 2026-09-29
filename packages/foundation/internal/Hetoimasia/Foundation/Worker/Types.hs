-- | The worker group's state representation: the group, each worker's entry,
-- the closing snapshot, the drain-status records, the coordination probe, the
-- worker handle, and the worker definition.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Worker.Internal" re-exports
-- the types for the rest of the package, and the other worker modules import
-- this module directly. It is private so 'WorkerGroup', 'Worker', and
-- 'WorkerDefinition' keep their constructors and fields away from clients,
-- and so 'Entry' and 'ClosingSnapshot' stay unnamed outside the package.
--
-- It imports "Hetoimasia.Foundation.Worker.Base",
-- "Hetoimasia.Foundation.Worker.Outcome", and the resource family's
-- "Hetoimasia.Foundation.Resource.Scoped", and defines no operation on the
-- state beyond the handle's two readers and the definition's constructor.
--
-- = State
--
-- Every variable of a group is a field declared here, and none is created or
-- written here. "Hetoimasia.Foundation.Worker.Group" creates the group and
-- writes its phase, closing snapshot, and report;
-- "Hetoimasia.Foundation.Worker.Startup" registers entries and writes each
-- worker's thread, gate, acknowledgement, run exit, and completion;
-- "Hetoimasia.Foundation.Worker.Requests" writes requests, the helper count,
-- and the sent and delivered flags; "Hetoimasia.Foundation.Worker.Observation"
-- writes the observed flag and retires settled workers. @docs/workers.md@
-- lists each variable's readers, thread, and lifetime.
module Hetoimasia.Foundation.Worker.Types
  ( -- * Drain status
    Outstanding (..)
  , OutstandingWorker (..)
  , GroupStatus (..)

    -- * Group state
  , Entry (..)
  , ClosingSnapshot (..)
  , WorkerGroup (..)

    -- * Coordination probe
  , GroupProbe (..)
  , noProbe

    -- * Handles and definitions
  , Worker (..)
  , workerId
  , workerLabel
  , WorkerDefinition (..)
  , workerDefinition
  , StartOutcome (..)
  ) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.STM (TVar)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Hetoimasia.Foundation.Resource.Scoped (Scoped)
import Hetoimasia.Foundation.Worker.Base (GroupPhase, Phase, Requested, StopToken, WorkerId)
import Hetoimasia.Foundation.Worker.Outcome
  ( Completion
  , GroupReport
  , RunExit
  , StartRejection
  , WorkerSummary
  )

-- Drain status ---------------------------------------------------------------

-- | What the drain still waits for on one worker.
data Outstanding
  = AwaitingTerminal
    -- ^ The worker has not published its terminal outcome.
  | AwaitingHelpers
    -- ^ The worker is terminal, and a cancellation helper that targets it has
    -- not yet finished.
  deriving (Eq, Show)

-- | One worker the drain would still wait for: observed state, not a cause.
data OutstandingWorker = OutstandingWorker
  { outstandingWorker ∷ !WorkerId
  , outstandingLabel ∷ !Text
  , outstandingAcknowledged ∷ !Bool
    -- ^ Startup was acknowledged.
  , outstandingRequested ∷ !Requested
    -- ^ The strongest request made so far.
    -- 'Hetoimasia.Foundation.Worker.CancelWasRequested' is also a stop
    -- request.
  , outstandingCancelDelivered ∷ !Bool
    -- ^ A cancellation helper's 'Control.Concurrent.throwTo' returned, so
    -- 'Hetoimasia.Foundation.Worker.WorkerCancelled' was raised in the
    -- worker's thread. A reserved, blocked, skipped, or failed attempt is not
    -- delivery, and delivery proves neither that worker code handled the
    -- exception nor that the worker terminated. Never cleared.
  , outstandingState ∷ !Outstanding
  , outstandingHelpers ∷ !Int
    -- ^ Cancellation helpers still targeting the worker.
  }
  deriving (Eq, Show)

-- | One coherent snapshot of a group, read in a single transaction.
data GroupStatus = GroupStatus
  { statusPhase ∷ !GroupPhase
  , statusOutstanding ∷ ![OutstandingWorker]
    -- ^ In registration order; always empty once
    -- 'Hetoimasia.Foundation.Worker.GroupClosed'.
  }
  deriving (Eq, Show)

-- Group state ----------------------------------------------------------------

-- | One worker's group-owned state. See @docs/workers.md@ for the owner,
-- readers, writers, and lifetime of each field.
data Entry = Entry
  { entryId ∷ !WorkerId
  , entryLabel ∷ !Text
  , entryThread ∷ !(TVar (Maybe ThreadId))
  , entryRequests ∷ !(TVar Requested)
  , entryGate ∷ !(TVar Bool)
  , entryAcknowledged ∷ !(TVar Bool)
  , entryExit ∷ !(TVar RunExit)
  , entrySummary ∷ !(TVar (Maybe WorkerSummary))
  , entryObserved ∷ !(TVar Bool)
  , entryHelpers ∷ !(TVar Int)
  , entryCancelSent ∷ !(TVar Bool)
  , entryCancelDelivered ∷ !(TVar Bool)
  }

-- | What closing captured when it began.
data ClosingSnapshot = ClosingSnapshot
  { closingExited ∷ ![WorkerSummary]
  , closingObserved ∷ ![WorkerSummary]
  , closingLive ∷ ![Entry]
  }

-- | The owner of the workers started through it, for one invocation of
-- 'Hetoimasia.Foundation.Worker.withWorkerGroup'.
data WorkerGroup = WorkerGroup
  { groupPhase ∷ !(TVar Phase)
  , groupNextId ∷ !(TVar Int)
  , groupActive ∷ !(TVar (Map WorkerId Entry))
  , groupRetained ∷ !(TVar (Map WorkerId WorkerSummary))
  , groupClosing ∷ !(TVar (Maybe ClosingSnapshot))
  , groupReport ∷ !(TVar (Maybe GroupReport))
  , groupProbe ∷ !GroupProbe
  }

-- Coordination probe ---------------------------------------------------------

-- | Coordination points on the group's own production path, for the
-- foundation's tests. Every production group uses 'noProbe'.
data GroupProbe = GroupProbe
  { probeHelperDelivering ∷ WorkerId → IO ()
    -- ^ Runs on a cancellation helper that has found the worker's thread with
    -- the worker not yet terminal, immediately before the helper delivers
    -- 'Hetoimasia.Foundation.Worker.WorkerCancelled' to it with 'throwTo'.
    -- It runs on the helper's own thread, so a probe can name that thread
    -- and then observe it blocked in the delivery. A synchronous failure it
    -- raises is discarded and the delivery still happens.
  , probeHelperSettling ∷ WorkerId → IO ()
    -- ^ Runs on a cancellation helper once its delivery attempt has ended —
    -- delivered, skipped because the worker was already terminal, or failed —
    -- and before the helper records the attempt and deregisters. Until it
    -- returns, the helper still counts as pending: the worker stays in
    -- 'Hetoimasia.Foundation.Worker.groupStatus' and the drain cannot
    -- complete. A synchronous failure it raises is discarded.
  }

-- | The probe of every production group: it does nothing.
noProbe ∷ GroupProbe
noProbe = GroupProbe (\_ → pure ()) (\_ → pure ())

-- Handles and definitions ----------------------------------------------------

-- | A handle to one started worker.
--
-- The handle stays valid after the worker is retired and after its group has
-- closed: it always exposes the same immutable
-- 'Hetoimasia.Foundation.Worker.Completion'.
data Worker r = Worker
  { workerGroup ∷ !WorkerGroup
  , workerEntry ∷ !Entry
  , workerCompletion ∷ !(TVar (Maybe (Completion r)))
  }

-- | The worker's identity, in registration order.
workerId ∷ Worker r → WorkerId
workerId = entryId . workerEntry

-- | The label the worker was defined with.
workerLabel ∷ Worker r → Text
workerLabel = entryLabel . workerEntry

-- | A worker's startup and run action.
data WorkerDefinition r = WorkerDefinition !Text (StopToken → Scoped (IO r))

-- | Define a worker.
--
-- The startup runs on the worker's own thread as a 'Scoped' construction: what
-- it allocates is owned by the worker, stays live for the whole run action, and
-- is released when the run action returns or throws, before the terminal
-- outcome is published. Acknowledgement is published only after startup
-- succeeded, from inside that scope.
--
-- The run action receives the stop token and what startup built. It runs
-- unmasked, whatever masking state the starter had. Its result is evaluated
-- to weak head normal form inside the worker's scope; a result whose validity
-- depends on the worker's resources must be fully produced there, under the
-- borrowing rules of "Hetoimasia.Foundation.Resource".
workerDefinition ∷ Text → (StopToken → Scoped s) → (StopToken → s → IO r) → WorkerDefinition r
workerDefinition label startup run = WorkerDefinition label (\token → run token <$> startup token)

-- | What 'Hetoimasia.Foundation.Worker.startWorker' returns.
data StartOutcome r
  = Started !(Worker r)
    -- ^ Acknowledged.
  | StartupFailed !(Worker r) !(Completion r)
    -- ^ Terminal before acknowledgement; its cleanup has already finished.
  | StartRejected !StartRejection
    -- ^ The group had closed registration. Nothing was forked.
