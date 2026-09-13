-- | Owned CPU worker threads: scoped startup, cooperative stop, cancellation,
-- terminal observation, and a protected drain before borrowed dependencies
-- unwind.
--
-- A 'WorkerGroup' is one lifetime owner for the workers started through it.
-- 'withWorkerGroup' is an 'IO' lifetime boundary that runs /inside/ the scopes
-- of the components its workers borrow, and 'allocWorkerGroup' composes the
-- same boundary in 'Scoped'. Every exit from that boundary — a normal return, a
-- startup failure, a body failure, owner cancellation, and a further
-- cancellation delivered while it drains — closes registration, requests a
-- cooperative stop from every live worker before waiting for any, requests
-- cancellation of live workers when the owner is failing, and then waits until
-- every worker has published its terminal outcome and every cancellation
-- helper has finished. Only then does the owner return or rethrow, so the
-- enclosing dependency scopes cannot unwind under a worker still using them.
-- A worker that never stops keeps the owner waiting with its dependencies live:
-- there is no deadline, no detach, and no process termination.
--
-- The drain is deliberately not an 'Hetoimasia.Foundation.Resource.allocResource'
-- release. A release runs under 'Control.Exception.uninterruptibleMask_' and
-- must have a controlled blocking duration, and waiting for a thread has none.
--
-- A worker is a 'WorkerDefinition': a startup written as a 'Scoped' construction
-- and a run action. The four operations on a started worker are distinct:
--
-- * startup acknowledgement, observed with 'awaitStartup';
-- * a cooperative stop request, 'requestStop', which the worker reads through
--   its 'StopToken';
-- * a cancellation request, 'requestCancel', delivered by a group-owned helper;
-- * terminal observation, 'awaitCompletion' for any number of raw readers and
--   'observeCompletion' for the owner that commits an observation.
--
-- Observation never stops or cancels a worker, and observing a worker's
-- cancellation never cancels the observer: a 'Completion' is data.
--
-- This module publishes raw evidence — the terminal 'Result', the 'RunExit'
-- record that fixes whether the run action exited before a stop was requested,
-- the cleanup failures, and a 'GroupReport' at closing. It does not classify
-- services, finite jobs, or required and optional workers; that is supervision,
-- which belongs to the runtime. It makes no OS-thread-affinity guarantee, no
-- wall-clock termination guarantee, and no promise to interrupt arbitrary
-- blocking 'IO'.
--
-- The module takes no logger. 'allocWorkerGroup' builds its 'Scoped' value
-- through the foundation library's hidden implementation seam, so the 'Scoped'
-- constructor stays unexported and no catch instance is added to it.
--
-- See @docs/workers.md@ for the same contract in prose, including every piece
-- of state, its owner, readers and writers, thread, lifetime, and reset.
module Hetoimasia.Foundation.Worker
  ( -- * Group lifetime
    WorkerGroup
  , withWorkerGroup
  , allocWorkerGroup
  , closeWorkerGroup
  , activeWorkerCount

    -- * Definitions
  , WorkerDefinition
  , workerDefinition
  , StopToken
  , stopRequested
  , awaitStopRequest

    -- * Starting
  , Worker
  , workerId
  , workerLabel
  , WorkerId
  , StartOutcome (..)
  , StartRejection (..)
  , startWorker
  , startWorkerWith

    -- * Requests
  , requestStop
  , requestCancel
  , WorkerCancelled (..)

    -- * Observation
  , Startup (..)
  , awaitStartup
  , awaitCompletion
  , pollCompletion
  , observeCompletion

    -- * Outcomes
  , Completion (..)
  , Result (..)
  , RunExit (..)
  , RunEnd (..)
  , Requested (..)
  , WorkerSummary
  , GroupReport (..)

    -- * Evidence on a propagated failure
  , WorkerEvidence (..)
  , workerEvidence
  , workerEvidenceInContext
  ) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVar
  , newTVarIO
  , readTVar
  , retry
  , writeTVar
  )
import Control.Exception
  ( Exception (fromException, toException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , asyncExceptionFromException
  , asyncExceptionToException
  , evaluate
  , mask
  , mask_
  , rethrowIO
  , someExceptionContext
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context
  ( ExceptionContext
  , addExceptionAnnotation
  , getExceptionAnnotations
  )
import Control.Monad (unless, void, when)
import Data.Foldable (for_, traverse_)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (CleanupFailure, cleanupFailuresInContext)
import Hetoimasia.Foundation.Resource.Internal
  ( Scoped (Scoped)
  , retainCleanupFailures
  , withScoped
  )

-- Identity and requests ------------------------------------------------------

-- | A worker's identity within its group. Identifiers are issued in
-- registration order, which is the order every report lists workers in; it is
-- not a claim about the wall-clock order of racing threads.
newtype WorkerId = WorkerId Int
  deriving (Eq, Ord, Show)

-- | The strongest request made of a worker so far. Requests only strengthen:
-- a stop never resets a cancellation, and nothing resets either to running.
data Requested
  = NothingRequested
  | StopWasRequested
  | CancelWasRequested
    -- ^ A cancellation request is also a stop request.
  deriving (Eq, Ord, Show)

-- | The worker's own view of its stop request.
--
-- It is the only piece of control state a worker receives. Reading it is an
-- STM transaction, so a worker can combine it with the rest of its own wait.
newtype StopToken = StopToken (TVar Requested)

-- | Whether a stop, or a cancellation, has been requested.
stopRequested ∷ StopToken → STM Bool
stopRequested (StopToken requests) = (/= NothingRequested) <$> readTVar requests

-- | Retry until a stop, or a cancellation, has been requested.
awaitStopRequest ∷ StopToken → STM ()
awaitStopRequest token = stopRequested token >>= check

-- Outcomes -------------------------------------------------------------------

-- | How the run action itself ended.
data RunEnd
  = RunReturned
  | RunFailed
    -- ^ The run action raised a synchronous exception.
  | RunCancelled
    -- ^ The run action was ended by an asynchronous exception.
  deriving (Eq, Show)

-- | The record the worker writes when its run action exits, before any of its
-- own cleanup begins.
data RunExit
  = RunNotEntered
    -- ^ The run action never started: startup failed or was cancelled, the
    -- start handoff was abandoned, or the fork itself failed.
  | RunExited !RunEnd !Requested
    -- ^ The run action ended this way, and this was the strongest request
    -- already made when it did. The record is written in the same transaction
    -- that reads the requests, so a request arriving during cleanup cannot
    -- change it.
  deriving (Eq, Show)

-- | The terminal result of one worker, published after its scopes unwound.
data Result r
  = Succeeded r
    -- ^ The run action returned this value, evaluated to weak head normal
    -- form inside the worker's scope, and every release succeeded.
  | Failed !(ExceptionWithContext SomeException)
    -- ^ A synchronous failure of startup, the run action, or a release, with
    -- its own context: its origin and cleanup evidence stay inspectable.
  | Cancelled !(ExceptionWithContext SomeException)
    -- ^ An asynchronous exception ended the worker, with its own context.
  deriving (Show, Functor)

-- | One worker's terminal outcome.
--
-- It is published exactly once, after the worker's startup scope and every
-- allocation in it have unwound, and it never changes. After it is published
-- no worker code or finalizer of that worker touches a borrowed dependency.
data Completion r = Completion
  { completionWorker ∷ !WorkerId
  , completionLabel ∷ !Text
  , completionExit ∷ !RunExit
  , completionResult ∷ !(Result r)
  , completionCleanup ∷ ![CleanupFailure]
    -- ^ The cleanup failures the terminal failure retained, in observation
    -- order; empty for a success.
  }
  deriving (Functor)

-- | A 'Completion' with its result value discarded, as a group retains it.
type WorkerSummary = Completion ()

-- | What 'awaitStartup' reports.
data Startup r
  = Acknowledged
    -- ^ Startup succeeded and the worker's resources are live for its run.
    -- The worker may also have completed since; check 'pollCompletion'.
  | NotAcknowledged !(Completion r)
    -- ^ The worker ended before acknowledging. Its 'completionExit' is
    -- 'RunNotEntered', and its cleanup has finished.

-- | Why a start forked nothing.
data StartRejection = RegistrationClosed
  deriving (Eq, Show)

-- | What 'startWorker' returns.
data StartOutcome r
  = Started !(Worker r)
    -- ^ Acknowledged.
  | StartupFailed !(Worker r) !(Completion r)
    -- ^ Terminal before acknowledgement; its cleanup has already finished.
  | StartRejected !StartRejection
    -- ^ The group had closed registration. Nothing was forked.

-- | What a group reports once it has closed and drained.
--
-- Every list is in registration order.
data GroupReport = GroupReport
  { reportExitedBeforeClosing ∷ ![WorkerSummary]
    -- ^ Workers whose terminal outcome was published but not observed with
    -- 'observeCompletion' when closing began. None of them was asked to stop
    -- by closing.
  , reportDrained ∷ ![WorkerSummary]
    -- ^ Workers still live when closing began, after the drain. Their
    -- 'RunExit' says whether each run action ended before closing's request.
  , reportObservedFailures ∷ ![WorkerSummary]
    -- ^ Outcomes other than 'Succeeded' that an owner had already observed
    -- before closing began, including retired ones.
  }

-- | A cancellation delivered by 'requestCancel'.
data WorkerCancelled = WorkerCancelled
  deriving (Eq, Show)

instance Exception WorkerCancelled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- State ----------------------------------------------------------------------

data Phase
  = Open
  | Closing
  | Closed
  deriving (Eq)

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
  }

-- | What closing captured when it began.
data ClosingSnapshot = ClosingSnapshot
  { closingExited ∷ ![WorkerSummary]
  , closingObserved ∷ ![WorkerSummary]
  , closingLive ∷ ![Entry]
  }

-- | The owner of the workers started through it, for one invocation of
-- 'withWorkerGroup'.
data WorkerGroup = WorkerGroup
  { groupPhase ∷ !(TVar Phase)
  , groupNextId ∷ !(TVar Int)
  , groupActive ∷ !(TVar (Map WorkerId Entry))
  , groupRetained ∷ !(TVar (Map WorkerId WorkerSummary))
  , groupClosing ∷ !(TVar (Maybe ClosingSnapshot))
  , groupReport ∷ !(TVar (Maybe GroupReport))
  }

-- | A handle to one started worker.
--
-- The handle stays valid after the worker is retired and after its group has
-- closed: it always exposes the same immutable 'Completion'.
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

-- Group lifetime -------------------------------------------------------------

-- | Run a body that owns a worker group, and drain every worker before
-- returning or rethrowing.
--
-- Call this inside the scopes of every component the workers borrow. The body
-- runs with the caller's masking state. When it returns or throws:
--
-- 1. Closing begins, if the body did not already close the group with
--    'closeWorkerGroup': the report's snapshot is taken, registration closes,
--    and a stop is requested from every live worker, all in one transaction.
-- 2. If the body failed or was cancelled, cancellation is requested of every
--    live worker.
-- 3. The owner waits until every worker is terminal and every cancellation
--    helper has finished. An asynchronous exception delivered during this wait
--    does not end it. If the body had returned normally, the first such
--    exception becomes the owner's pending failure and cancellation is
--    requested of the live workers; later ones are absorbed.
--
-- Then the body's result is returned, or the pending failure is rethrown with
-- its own type, value, and context, a 'GroupExit' 'WorkerEvidence' annotation,
-- and every cleanup failure the report's workers retained, which
-- 'Hetoimasia.Foundation.Resource.cleanupFailures' reads back.
--
-- If a worker never becomes terminal, this never returns. A normal return
-- discards the report; a body that needs it calls 'closeWorkerGroup' itself.
withWorkerGroup ∷ (WorkerGroup → IO a) → IO a
withWorkerGroup body = mask $ \restore → do
  group ← newWorkerGroup
  outcome ← trySome (restore (body group))
  atomically (beginClosing group)
  initial ← case outcome of
    Left failure → Just <$> escalate group failure
    Right _ → pure Nothing
  (report, pending) ← drainGroup group initial
  let attach = attachEvidence (GroupExit report) (reportCleanup report)
  case pending of
    Just failure → rethrowIO (attach failure)
    Nothing → either (rethrowIO . attach) pure outcome

-- | 'withWorkerGroup' composed in 'Scoped'.
--
-- The group's lifetime is the rest of the enclosing 'withScoped' continuation.
-- Allocations made before this line outlive the drain; allocations made after
-- it are released before the drain begins and must not be borrowed by the
-- group's workers.
allocWorkerGroup ∷ Scoped WorkerGroup
allocWorkerGroup = Scoped withWorkerGroup

-- | Close the group and wait for its report.
--
-- Closing begins as in step 1 of 'withWorkerGroup', and then this waits for
-- every worker and helper. The wait is cancellable: a cancellation escapes to
-- the owner, whose exit then requests cancellation of the remaining workers and
-- performs the protected drain. Calling it again, or after the owner has
-- drained, returns the same report. A worker of this group must not call it,
-- since the wait includes that worker.
closeWorkerGroup ∷ WorkerGroup → IO GroupReport
closeWorkerGroup group = do
  atomically (beginClosing group)
  atomically (awaitReport group)

-- | How many workers the group still keeps in active bookkeeping: every worker
-- not yet retired by 'observeCompletion'. Zero once the group has closed.
activeWorkerCount ∷ WorkerGroup → STM Int
activeWorkerCount group = Map.size <$> readTVar (groupActive group)

newWorkerGroup ∷ IO WorkerGroup
newWorkerGroup =
  WorkerGroup
    <$> newTVarIO Open
    <*> newTVarIO 0
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Nothing
    <*> newTVarIO Nothing

-- | Take the closing snapshot, close registration, and request a stop from
-- every live worker, once. Every outcome published before this commits is in
-- the snapshot, and every run exit recorded after it sees the stop request.
beginClosing ∷ WorkerGroup → STM ()
beginClosing group = do
  phase ← readTVar (groupPhase group)
  when (phase == Open) $ do
    entries ← Map.elems <$> readTVar (groupActive group)
    states ← traverse entryState entries
    retained ← Map.elems <$> readTVar (groupRetained group)
    let exited = [summary | (_, Just summary, False) ← states]
        observed =
          sortOn completionWorker $
            retained <> [summary | (_, Just summary, True) ← states, not (succeeded summary)]
        live = [entry | (entry, Nothing, _) ← states]
    for_ live $ \entry → modifyTVar' (entryRequests entry) (max StopWasRequested)
    writeTVar (groupClosing group) (Just (ClosingSnapshot exited observed live))
    writeTVar (groupPhase group) Closing
  where
    entryState entry =
      (,,) entry <$> readTVar (entrySummary entry) <*> readTVar (entryObserved entry)

-- | Retry until every worker is terminal and every helper has finished, then
-- publish the report and mark the group closed, once.
awaitReport ∷ WorkerGroup → STM GroupReport
awaitReport group =
  readTVar (groupReport group) >>= \case
    Just report → pure report
    Nothing → do
      snapshot ← readTVar (groupClosing group) >>= maybe retry pure
      entries ← Map.elems <$> readTVar (groupActive group)
      traverse_ settledSummary entries
      drained ← traverse settledSummary (closingLive snapshot)
      let report = GroupReport (closingExited snapshot) drained (closingObserved snapshot)
      writeTVar (groupReport group) (Just report)
      writeTVar (groupPhase group) Closed
      writeTVar (groupClosing group) Nothing
      writeTVar (groupActive group) Map.empty
      writeTVar (groupRetained group) Map.empty
      pure report

-- | The worker's summary once it is terminal and no helper targets it.
settledSummary ∷ Entry → STM WorkerSummary
settledSummary entry = do
  summary ← readTVar (entrySummary entry) >>= maybe retry pure
  helpers ← readTVar (entryHelpers entry)
  check (helpers == 0)
  pure summary

-- | The protected drain: wait for the report, absorbing interruptions.
drainGroup
  ∷ WorkerGroup
  → Maybe (ExceptionWithContext SomeException)
  → IO (GroupReport, Maybe (ExceptionWithContext SomeException))
drainGroup group = loop
  where
    loop pending = do
      settled ← trySome (atomically (awaitReport group))
      case settled of
        Right report → pure (report, pending)
        Left interruption → case pending of
          Just _ → loop pending
          Nothing → escalate group interruption >>= loop . Just

-- | Request cancellation of every live worker on behalf of a failing owner,
-- keeping the owner's failure primary. A helper that cannot be forked leaves
-- that worker's stop and cancellation requests in place, and the drain still
-- waits for it.
escalate
  ∷ WorkerGroup
  → ExceptionWithContext SomeException
  → IO (ExceptionWithContext SomeException)
escalate group failure = do
  entries ← atomically (Map.elems <$> readTVar (groupActive group))
  for_ entries $ \entry → trySome (requestCancelEntry group entry)
  pure failure

reportCleanup ∷ GroupReport → [CleanupFailure]
reportCleanup report =
  concatMap completionCleanup $
    reportObservedFailures report <> reportExitedBeforeClosing report <> reportDrained report

-- Starting -------------------------------------------------------------------

-- | Start a worker and wait cancellably for its startup.
--
-- This is 'startWorkerWith' with no preparation and 'awaitStartup' as the
-- wait. A failed or cancelled wait drains the worker before propagating, as
-- 'startWorkerWith' describes.
startWorker ∷ WorkerGroup → WorkerDefinition r → IO (StartOutcome r)
startWorker group definition = do
  started ← startWorkerWith group definition (\_ → pure ()) awaitStartup
  pure $ case started of
    Left rejection → StartRejected rejection
    Right (worker, Acknowledged) → Started worker
    Right (worker, NotAcknowledged completion) → StartupFailed worker completion

-- | Start a worker with an explicit preparation step and a caller-composed
-- startup wait.
--
-- The handoff, in order:
--
-- 1. Registration: in one transaction the group is checked for open
--    registration and the worker is registered in it. A closed group returns
--    @'Left' 'RegistrationClosed'@ and forks nothing.
-- 2. The fork, masked and with nothing interruptible between registration and
--    it. The child starts at a closed gate: it runs none of its definition.
--    If the fork itself fails, the worker is published as a terminal failure
--    with 'RunNotEntered' and the failure propagates.
-- 3. @prepare@ runs with the caller's masking state and the worker handle,
--    before any of the child's user code. A later supervisor registers its
--    own policy for the worker here.
-- 4. The gate opens and @wait@ runs with the caller's masking state. It is an
--    STM transaction the caller composes, typically 'awaitStartup' combined
--    with another condition, and its result is returned with the handle.
--
-- If @prepare@ or @wait@ fails or is cancelled, cancellation of the worker is
-- requested and the starter waits, absorbing further interruptions, until the
-- worker is terminal and its helper has finished. The failure then propagates
-- with its own context, an 'AbandonedStart' 'WorkerEvidence' annotation, and
-- the worker's cleanup failures retained. The worker cannot outlive the
-- dependencies the starter borrowed.
--
-- A @wait@ that returns without acknowledgement leaves the worker running and
-- owned by the group.
startWorkerWith
  ∷ WorkerGroup
  → WorkerDefinition r
  → (Worker r → IO ())
  → (Worker r → STM a)
  → IO (Either StartRejection (Worker r, a))
startWorkerWith group (WorkerDefinition label startup) prepare wait = mask $ \restore → do
  declared ← evaluate label
  reserved ← atomically (register group declared)
  case reserved of
    Nothing → pure (Left RegistrationClosed)
    Just worker → do
      let entry = workerEntry worker
      forked ← trySome (forkIOWithUnmask (runChild worker startup))
      case forked of
        Left failure → do
          atomically (publish worker (failureResult failure))
          rethrowIO failure
        Right thread → atomically (writeTVar (entryThread entry) (Just thread))
      handoff ← trySome $ do
        restore (prepare worker)
        atomically (writeTVar (entryGate entry) True)
        restore (atomically (wait worker))
      case handoff of
        Right waited → pure (Right (worker, waited))
        Left failure → do
          summary ← drainWorker worker
          rethrowIO (attachEvidence (AbandonedStart summary) (completionCleanup summary) failure)

-- | Register a new worker if registration is open.
register ∷ WorkerGroup → Text → STM (Maybe (Worker r))
register group label = do
  phase ← readTVar (groupPhase group)
  if phase /= Open
    then pure Nothing
    else do
      next ← readTVar (groupNextId group)
      writeTVar (groupNextId group) (next + 1)
      entry ←
        Entry (WorkerId next) label
          <$> newTVar Nothing
          <*> newTVar NothingRequested
          <*> newTVar False
          <*> newTVar False
          <*> newTVar RunNotEntered
          <*> newTVar Nothing
          <*> newTVar False
          <*> newTVar 0
          <*> newTVar False
      completion ← newTVar Nothing
      modifyTVar' (groupActive group) (Map.insert (entryId entry) entry)
      pure (Just (Worker group entry completion))

-- | The child thread. It starts masked, with its outcome handler installed
-- before anything interruptible, waits at the gate, and publishes exactly one
-- terminal outcome after its scope has unwound.
runChild ∷ Worker r → (StopToken → Scoped (IO r)) → (∀ x. IO x → IO x) → IO ()
runChild worker startup unmask = do
  outcome ← trySome $ do
    atomically (readTVar (entryGate entry) >>= check)
    unmask $ withScoped (startup (StopToken (entryRequests entry))) $ \run →
      mask $ \restore → do
        atomically (writeTVar (entryAcknowledged entry) True)
        exited ← trySome (restore (run >>= evaluate))
        atomically $ do
          requested ← readTVar (entryRequests entry)
          writeTVar (entryExit entry) (RunExited (runEnd exited) requested)
        either rethrowIO pure exited
  atomically (publish worker (either failureResult Succeeded outcome))
  where
    entry = workerEntry worker
    runEnd (Right _) = RunReturned
    runEnd (Left failure) = case failureResult failure of
      Cancelled _ → RunCancelled
      _ → RunFailed

-- | Publish the terminal outcome: the typed completion for the handle and the
-- summary the group reads, in one transaction.
publish ∷ Worker r → Result r → STM ()
publish worker result = do
  exit ← readTVar (entryExit entry)
  let completion = Completion (entryId entry) (entryLabel entry) exit result (resultCleanup result)
  writeTVar (workerCompletion worker) (Just completion)
  writeTVar (entrySummary entry) (Just (void completion))
  where
    entry = workerEntry worker

-- | Request cancellation of one worker and wait for it and its helper,
-- absorbing interruptions, for a starter that is already failing.
drainWorker ∷ Worker r → IO WorkerSummary
drainWorker worker = do
  _ ← trySome (requestCancelEntry (workerGroup worker) (workerEntry worker))
  let loop = trySome (atomically (settledSummary (workerEntry worker))) >>= either (const loop) pure
  loop

-- Requests -------------------------------------------------------------------

-- | Request a cooperative stop.
--
-- A non-blocking transition of the worker's stop token: it runs no callback,
-- is idempotent, and never weakens a cancellation request or resets the token.
-- The worker decides how to exit. Requesting a stop of a terminal worker
-- changes nothing observable.
requestStop ∷ Worker r → STM ()
requestStop worker = modifyTVar' (entryRequests (workerEntry worker)) (max StopWasRequested)

-- | Request cancellation.
--
-- The request is recorded at once, and it is also a stop request. The first
-- request of a live worker registers and forks one group-owned helper thread
-- that delivers 'WorkerCancelled' to the worker with 'throwTo'. Delivery can
-- block, for as long as the worker is inside an uninterruptible region or a
-- foreign call, so it never runs on the requesting thread and never inside a
-- resource release. The helper is joined by the group's drain; it is never
-- detached. Later requests fork nothing.
--
-- A worker already terminal forks no helper.
requestCancel ∷ Worker r → IO ()
requestCancel worker = requestCancelEntry (workerGroup worker) (workerEntry worker)

requestCancelEntry ∷ WorkerGroup → Entry → IO ()
requestCancelEntry group entry = mask_ $ do
  send ← atomically $ do
    writeTVar (entryRequests entry) CancelWasRequested
    settled ← isJust <$> readTVar (entrySummary entry)
    sent ← readTVar (entryCancelSent entry)
    if settled || sent
      then pure False
      else do
        writeTVar (entryCancelSent entry) True
        modifyTVar' (entryHelpers entry) (+ 1)
        pure True
  when send $ do
    forked ← trySome (forkIO (deliverCancellation group entry))
    case forked of
      Right _ → pure ()
      Left failure → do
        atomically $ do
          writeTVar (entryCancelSent entry) False
          modifyTVar' (entryHelpers entry) (subtract 1)
          retireIfSettled group entry
        rethrowIO failure

-- | The helper: wait for the worker's thread, deliver the cancellation unless
-- the worker is already terminal, and deregister.
deliverCancellation ∷ WorkerGroup → Entry → IO ()
deliverCancellation group entry = do
  _ ← trySome $ do
    target ← atomically $
      readTVar (entrySummary entry) >>= \case
        Just _ → pure Nothing
        Nothing → readTVar (entryThread entry) >>= maybe retry (pure . Just)
    traverse_ (`throwTo` WorkerCancelled) target
  atomically $ do
    modifyTVar' (entryHelpers entry) (subtract 1)
    retireIfSettled group entry

-- Observation ----------------------------------------------------------------

-- | Retry until the worker acknowledges startup or ends without acknowledging.
--
-- Acknowledgement is independent of completion: a worker that acknowledged and
-- has already finished reports 'Acknowledged', and its completion is ready
-- too.
awaitStartup ∷ Worker r → STM (Startup r)
awaitStartup worker = do
  acknowledged ← readTVar (entryAcknowledged (workerEntry worker))
  if acknowledged
    then pure Acknowledged
    else readTVar (workerCompletion worker) >>= maybe retry (pure . NotAcknowledged)

-- | Retry until the worker's terminal outcome is published.
--
-- This is a raw read: any number of readers may wait, it consumes nothing, it
-- does not stop, cancel, or retire the worker, and a reader cancelled while
-- waiting leaves the worker untouched.
awaitCompletion ∷ Worker r → STM (Completion r)
awaitCompletion worker = readTVar (workerCompletion worker) >>= maybe retry pure

-- | The terminal outcome if it has been published. A raw read, like
-- 'awaitCompletion'.
pollCompletion ∷ Worker r → STM (Maybe (Completion r))
pollCompletion worker = readTVar (workerCompletion worker)

-- | Commit the owner's observation of a terminal outcome, if one is published.
--
-- Once observed and once its cancellation helper, if any, has finished, the
-- worker is retired from active bookkeeping. A retired success is dropped from
-- the group; a retired 'Failed' or 'Cancelled' outcome is kept for the
-- 'GroupReport'. The handle still exposes the same outcome. A worker that is
-- not terminal is neither observed nor retired, and raw readers never retire
-- anything.
observeCompletion ∷ Worker r → STM (Maybe (Completion r))
observeCompletion worker =
  readTVar (workerCompletion worker) >>= \case
    Nothing → pure Nothing
    Just completion → do
      writeTVar (entryObserved (workerEntry worker)) True
      retireIfSettled (workerGroup worker) (workerEntry worker)
      pure (Just completion)

retireIfSettled ∷ WorkerGroup → Entry → STM ()
retireIfSettled group entry = do
  observed ← readTVar (entryObserved entry)
  summary ← readTVar (entrySummary entry)
  helpers ← readTVar (entryHelpers entry)
  phase ← readTVar (groupPhase group)
  case summary of
    Just settled | observed, helpers == 0, phase /= Closed → do
      modifyTVar' (groupActive group) (Map.delete (entryId entry))
      unless (succeeded settled) $
        modifyTVar' (groupRetained group) (Map.insert (entryId entry) settled)
    _ → pure ()

-- Evidence -------------------------------------------------------------------

-- | Worker evidence attached to a failure that propagated out of a protected
-- drain.
data WorkerEvidence
  = AbandonedStart !WorkerSummary
    -- ^ 'startWorkerWith' failed or was cancelled and drained this worker.
  | GroupExit !GroupReport
    -- ^ 'withWorkerGroup' drained its group while this failure was pending.

-- | Entries carry their attachment position, so reading them back returns
-- attachment order as a property of this module.
data EvidenceEntry = EvidenceEntry !Int !WorkerEvidence

instance ExceptionAnnotation EvidenceEntry where
  displayExceptionAnnotation (EvidenceEntry _ evidence) = case evidence of
    AbandonedStart summary →
      "abandoned worker start: " <> describeSummary summary
    GroupExit report →
      "worker group drained: "
        <> show (length (reportExitedBeforeClosing report))
        <> " exited before closing, "
        <> show (length (reportDrained report))
        <> " drained, "
        <> show (length (reportObservedFailures report))
        <> " observed failures"

describeSummary ∷ WorkerSummary → String
describeSummary summary =
  show (Text.unpack (completionLabel summary))
    <> " #"
    <> show identifier
    <> " "
    <> case completionResult summary of
      Succeeded _ → "succeeded"
      Failed _ → "failed"
      Cancelled _ → "cancelled"
  where
    WorkerId identifier = completionWorker summary

-- | The worker evidence on an exception a caller caught, in attachment order.
workerEvidence ∷ SomeException → [WorkerEvidence]
workerEvidence = workerEvidenceInContext . someExceptionContext

-- | 'workerEvidence' for a caller holding the context directly.
workerEvidenceInContext ∷ ExceptionContext → [WorkerEvidence]
workerEvidenceInContext context =
  [evidence | EvidenceEntry _ evidence ← sortOn position (getExceptionAnnotations context)]
  where
    position (EvidenceEntry index _) = index

attachEvidence
  ∷ WorkerEvidence
  → [CleanupFailure]
  → ExceptionWithContext SomeException
  → ExceptionWithContext SomeException
attachEvidence evidence failures (ExceptionWithContext context exception) =
  retainCleanupFailures failures (ExceptionWithContext (addExceptionAnnotation entry context) exception)
  where
    position = length (getExceptionAnnotations context ∷ [EvidenceEntry])
    entry = EvidenceEntry position evidence

-- Helpers --------------------------------------------------------------------

-- | Catch anything, including a cancellation, with the context it carried.
trySome ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
trySome = tryWithContext

failureResult ∷ ExceptionWithContext SomeException → Result r
failureResult caught@(ExceptionWithContext _ exception)
  | isJust (fromException exception ∷ Maybe SomeAsyncException) = Cancelled caught
  | otherwise = Failed caught

resultCleanup ∷ Result r → [CleanupFailure]
resultCleanup (Succeeded _) = []
resultCleanup (Failed (ExceptionWithContext context _)) = cleanupFailuresInContext context
resultCleanup (Cancelled (ExceptionWithContext context _)) = cleanupFailuresInContext context

succeeded ∷ Completion r → Bool
succeeded completion = case completionResult completion of
  Succeeded _ → True
  _ → False
