-- | Supervision of owned workers through checkpoints and supervised waits on the
-- application thread.
--
-- "Hetoimasia.Foundation.Worker" publishes raw evidence: a terminal 'Completion',
-- the run-exit record that fixes whether a run action ended before a stop was
-- requested, cleanup failures, and a 'GroupReport' at closing. It decides
-- nothing. This module is the runtime layer that turns that evidence into a
-- decision, on the thread that owns the application, and nowhere else.
--
-- __The boundary.__ 'withSupervision' runs a body inside one worker group,
-- lending it a 'RuntimeControl'. Call it inside the scopes of every component
-- the workers borrow and inside the 'LoggingLifetime' that carries optional
-- warnings. The control is for worker management and supervision only: it
-- looks up no engine or application service. It belongs to the application
-- thread and is never given to a worker action; a worker receives its
-- 'Hetoimasia.Foundation.Worker.StopToken' and the component handles it needs.
--
-- __Policy.__ 'startSupervised' registers a 'WorkerPolicy' for the worker
-- before any of the worker's own code runs: its 'Role' (a 'Service' runs until
-- asked to stop, a 'Job' may finish), its 'Disposition' ('Required' or
-- 'Optional'), and the component's classifier, which says whether a failure is
-- one the component supports as an exhausted, recognized failure. Required or
-- optional is a per-worker choice by the code that starts it, never a severity
-- attached to an exception type.
--
-- __Checkpoints and supervised waits.__ Nothing interrupts the application.
-- 'checkRuntime' observes pending worker outcomes when it is called; place it
-- before and after starting a worker, at each loop iteration, and before
-- accepting a final result. 'awaitSupervised' waits for an STM transaction the
-- caller supplies and observes worker outcomes in the same transaction, so a
-- worker failure wakes it without a monitor thread. When an outcome and the
-- caller's result are both ready, the outcome is handled first and the
-- caller's transaction is not committed. Only framework-owned STM reads are
-- supervised: a foreign call, an ordinary @takeMVar@, or arbitrary 'IO' is not
-- interrupted, and no exception is ever injected into the application thread.
--
-- __How an outcome is handled.__ Pending outcomes are selected in STM without
-- being marked, classified outside STM, committed as a status and an observed
-- worker in one transaction that rechecks each worker is still pending, and
-- only then warned about or rethrown in 'IO'. A failure that arrives after a
-- transaction committed is handled at the next checkpoint.
--
-- +------------------------------------------------------------+-------------------------------------------------------------+
-- | Terminal outcome                                           | Status                                                      |
-- +============================================================+=============================================================+
-- | A 'Job' returned                                           | 'WorkerCompleted'; the result stays on the worker handle    |
-- +------------------------------------------------------------+-------------------------------------------------------------+
-- | A 'Service' returned before a stop was requested           | An 'UnexpectedServiceExit' failure, judged by the policy    |
-- +------------------------------------------------------------+-------------------------------------------------------------+
-- | Returned or cancelled after the owner asked it to stop,    | 'WorkerStopped', keeping the actual result or cancellation  |
-- | with successful cleanup                                    |                                                             |
-- +------------------------------------------------------------+-------------------------------------------------------------+
-- | Cancelled without an owner request                         | An 'UnexpectedWorkerTermination' failure, judged by policy  |
-- +------------------------------------------------------------+-------------------------------------------------------------+
-- | A synchronous failure, even after a stop request           | That failure, with its own type, judged by the policy       |
-- +------------------------------------------------------------+-------------------------------------------------------------+
-- | Any retained cleanup failure                               | 'WorkerFatal', whatever the policy: the failure, or a       |
-- |                                                            | 'WorkerCleanupFailed' when the worker was cancelled         |
-- +------------------------------------------------------------+-------------------------------------------------------------+
--
-- A failure is judged by the policy: an 'Optional' worker whose classifier
-- 'Recognized' it is 'WorkerUnavailable', and every other failure — required,
-- or not recognized — is 'WorkerFatal'. An unavailable worker's status is
-- committed first; then one @Warning@ is attempted through the lifetime's
-- managed reporting, unless a managed report has already failed. It is never
-- attempted again, and its failure changes no status.
--
-- __The fatal latch.__ The first fatal status committed in an invocation is
-- latched as its primary failure. Every later checkpoint and supervised wait,
-- and the boundary's own exit, rethrows it again: catching a delivery does not
-- clear it. When one checkpoint commits several failures, the primary is the
-- fatal one registered first — registration order, not a claim about which
-- thread failed first — and every other failure is retained beside it as
-- 'SupervisedFailure' evidence that 'supervisedFailures' reads back. A
-- synchronous worker failure propagates with its own type, value, and context.
--
-- A classifier that throws stops supervision: its failure becomes the worker's
-- fatal status, carrying the worker failure it was handling as a
-- 'Control.Exception.WhileHandling' annotation, as
-- "Hetoimasia.Foundation.Recovery" does for its own policy. A cancellation during
-- classification propagates as the owner's cancellation, commits nothing, and
-- the boundary still drains every worker.
--
-- __Closing.__ When the body returns, the boundary closes the group with
-- 'closeWorkerGroup', which snapshots every already-published outcome before
-- it requests any stop, closes registration, and drains. A later start is
-- 'WorkerStartRejected'. When the body throws, the group's own exit does the
-- same and also requests cancellation. Either way every worker is drained with
-- its dependencies live, and then every outcome not yet handled is handled:
-- an outcome published before closing is judged as it would have been at a
-- checkpoint, so a service that had already exited is not a stop, and a
-- worker still live at closing was asked to stop by its owner. The boundary
-- then returns the body's result, rethrows the latched failure, or rethrows
-- the body's own failure — which stays primary — with every worker failure
-- retained beside it.
--
-- A cancelled body is the exception: once the drain finishes, the cancellation
-- propagates as itself with nothing more classified or warned about, so no
-- classifier and no warning runs while the owner is being cancelled. It
-- carries the group's 'Hetoimasia.Foundation.Worker.GroupExit' report as raw
-- evidence, and the failures committed before it.
--
-- The boundary does not report the application's terminal failure, and it
-- does not flush or finalize the logger: both belong to the application runner
-- and the 'LoggingLifetime' around it.
--
-- __State.__ One 'withSupervision' invocation owns all of it, and none of it
-- outlives or is shared between invocations.
--
-- +--------------------------+------------------------------------------+-----------------------------+----------------------------------+
-- | State                    | Readers and writers                      | Thread                      | Lifetime and reset               |
-- +==========================+==========================================+=============================+==================================+
-- | Pending registrations    | 'startSupervised' inserts before the     | Application thread; the     | One invocation; a worker leaves  |
-- |                          | worker runs; commits remove; checkpoints | boundary at closing         | when its outcome is committed    |
-- |                          | and waits read                           |                             |                                  |
-- +--------------------------+------------------------------------------+-----------------------------+----------------------------------+
-- | Owner stop request flag  | 'stopSupervised', 'cancelSupervised',    | Application thread          | One worker; set once, never      |
-- |                          | and an abandoned start write;            |                             | cleared                          |
-- |                          | classification reads                     |                             |                                  |
-- +--------------------------+------------------------------------------+-----------------------------+----------------------------------+
-- | Worker status            | Commits write once; 'workerStatus' reads | Application thread writes;  | One worker; 'WorkerLive' until   |
-- |                          |                                          | any thread reads, in STM    | committed, then never changes    |
-- +--------------------------+------------------------------------------+-----------------------------+----------------------------------+
-- | Committed failures and   | Commits append and latch; deliveries and | Application thread          | One invocation; append-only; the |
-- | the fatal latch          | the boundary read                        |                             | latch is set once, never cleared |
-- +--------------------------+------------------------------------------+-----------------------------+----------------------------------+
-- | Warning attempts         | Consumed by the commit that makes a      | Application thread          | At most one per worker, never    |
-- |                          | worker unavailable, then attempted once  |                             | repeated                         |
-- +--------------------------+------------------------------------------+-----------------------------+----------------------------------+
--
-- Raw observation stays available: the handle 'supervisedWorker' returns is the
-- foundation 'Worker', whose 'Hetoimasia.Foundation.Worker.awaitCompletion' any
-- number of readers may use, for instance to inspect a finished job's result.
--
-- See @docs/supervision.md@ for the same contract in prose.
module Hetoimasia.Runtime.Supervision
  ( -- * The boundary
    withSupervision
  , RuntimeControl

    -- * Policy
  , WorkerPolicy (..)
  , Role (..)
  , Disposition (..)
  , Recognition (..)

    -- * Supervised workers
  , SupervisedWorker
  , supervisedWorker
  , SupervisedStart (..)
  , startSupervised
  , stopSupervised
  , cancelSupervised
  , WorkerStatus (..)
  , workerStatus

    -- * Checkpoints and supervised waits
  , checkRuntime
  , awaitSupervised

    -- * Failures
  , UnexpectedServiceExit (..)
  , UnexpectedWorkerTermination (..)
  , WorkerCleanupFailed (..)
  , SupervisedFailure (..)
  , Severity (..)
  , supervisedFailures
  , supervisedFailuresInContext
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , WhileHandling (WhileHandling)
  , evaluate
  , fromException
  , mask_
  , rethrowIO
  , someExceptionContext
  , toException
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context
  ( ExceptionContext
  , addExceptionAnnotation
  , emptyExceptionContext
  , getExceptionAnnotations
  )
import Control.Monad (unless, when)
import Data.Foldable (for_, traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Maybe (isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure (operation)
import Hetoimasia.Foundation.Log (Component)
import Hetoimasia.Foundation.Recovery
  ( AttemptFailure (..)
  , AttemptKind (..)
  , Disposition (..)
  , Outcome (Unavailable)
  , Unavailability (..)
  )
import Hetoimasia.Foundation.Worker
  ( Completion (..)
  , GroupReport (..)
  , Requested (..)
  , Result (..)
  , RunEnd (..)
  , RunExit (..)
  , StartRejection (..)
  , Worker
  , WorkerDefinition
  , WorkerEvidence (..)
  , WorkerGroup
  , WorkerId
  , WorkerSummary
  , awaitStartup
  , closeWorkerGroup
  , observeCompletion
  , pollCompletion
  , requestCancel
  , requestStop
  , startWorkerWith
  , withWorkerGroup
  , workerEvidenceInContext
  , workerId
  , workerLabel
  )
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger, recordReport, recordedReports)
import Hetoimasia.Runtime.Reporting (ReportResult (..), reportOutcome)

-- Policy -----------------------------------------------------------------------

-- | Whether a worker is expected to run until its owner stops it.
data Role
  = Service
    -- ^ Runs until asked to stop. Returning before a stop was requested is a
    -- failure.
  | Job
    -- ^ Finite work. Returning is completion, and its result stays inspectable
    -- on the worker handle.
  deriving (Eq, Show)

-- | What a component's classifier says about one worker failure.
data Recognition
  = Recognized
    -- ^ A failure the component supports: whatever bounded recovery it has is
    -- exhausted, and an optional worker may be left unavailable.
  | Unrecognized
    -- ^ An unknown failure. It is fatal whatever the worker's disposition.
  deriving (Eq, Show)

-- | The supervision policy the starter registers for one worker.
data WorkerPolicy = WorkerPolicy
  { policyRole ∷ !Role
  , policyDisposition ∷ !Disposition
  , policyComponent ∷ !Component
    -- ^ The component an optional worker's warning is reported under.
  , policyClassifier ∷ ExceptionWithContext SomeException → IO Recognition
    -- ^ Supplied by the component that knows its failures. It sees the
    -- worker's synchronous failure, or a synthetic 'UnexpectedServiceExit' or
    -- 'UnexpectedWorkerTermination', never a failure with retained cleanup
    -- evidence. It chooses a disposition only.
  }

-- Statuses and failures --------------------------------------------------------

-- | What supervision has decided about one worker.
data WorkerStatus
  = WorkerLive
    -- ^ No terminal outcome has been handled yet.
  | WorkerCompleted
    -- ^ A job returned.
  | WorkerStopped
    -- ^ The worker ended after its owner asked it to stop, with successful
    -- cleanup. Its actual result, or cancellation, is on its handle.
  | WorkerUnavailable !(ExceptionWithContext SomeException)
    -- ^ An optional worker failed with a recognized failure, and the run
    -- continues without it.
  | WorkerFatal !(ExceptionWithContext SomeException)
    -- ^ The failure stops the run.
  deriving (Show)

-- | Whether a committed failure stops the run.
data Severity
  = Fatal
  | Tolerated
    -- ^ An optional worker left unavailable.
  deriving (Eq, Show)

-- | One worker failure a supervision invocation committed.
data SupervisedFailure = SupervisedFailure
  { failedWorker ∷ !WorkerId
  , failedLabel ∷ !Text
  , failedSeverity ∷ !Severity
  , failedException ∷ !(ExceptionWithContext SomeException)
    -- ^ With its own type, value, and context.
  }
  deriving (Show)

-- | A service returned normally before any stop was requested. It carries the
-- worker's terminal evidence.
newtype UnexpectedServiceExit = UnexpectedServiceExit WorkerSummary

instance Show UnexpectedServiceExit where
  show (UnexpectedServiceExit summary) = "UnexpectedServiceExit " <> describe summary

instance Exception UnexpectedServiceExit where
  displayException (UnexpectedServiceExit summary) =
    "service " <> describe summary <> " returned before a stop was requested"

-- | A worker was cancelled although its owner had not asked it to stop. It
-- carries the worker's terminal evidence, whose result holds the cancellation
-- with its own context; the observer is never cancelled by it.
newtype UnexpectedWorkerTermination = UnexpectedWorkerTermination WorkerSummary

instance Show UnexpectedWorkerTermination where
  show (UnexpectedWorkerTermination summary) = "UnexpectedWorkerTermination " <> describe summary

instance Exception UnexpectedWorkerTermination where
  displayException (UnexpectedWorkerTermination summary) =
    "worker " <> describe summary <> " was cancelled without a request from its owner"

-- | A cancelled worker's cleanup failed. It carries the worker's terminal
-- evidence, including the cleanup failures, so the cancellation is not
-- rethrown to the observer.
newtype WorkerCleanupFailed = WorkerCleanupFailed WorkerSummary

instance Show WorkerCleanupFailed where
  show (WorkerCleanupFailed summary) = "WorkerCleanupFailed " <> describe summary

instance Exception WorkerCleanupFailed where
  displayException (WorkerCleanupFailed summary) =
    "worker " <> describe summary <> " was cancelled and its cleanup failed"

describe ∷ WorkerSummary → String
describe summary = show (Text.unpack (completionLabel summary)) <> " (" <> show (completionWorker summary) <> ")"

-- State ------------------------------------------------------------------------

-- | One worker registered with supervision.
data Managed = Managed
  { managedId ∷ !WorkerId
  , managedLabel ∷ !Text
  , managedPolicy ∷ !WorkerPolicy
  , managedPoll ∷ !(STM (Maybe WorkerSummary))
  , managedObserve ∷ !(STM ())
  , managedRequested ∷ !(TVar Bool)
  , managedStatus ∷ !(TVar WorkerStatus)
  }

-- | Supervision state for one invocation. See the module header for its owner,
-- readers, writers, and lifetime.
data Supervision = Supervision
  { supervisionLifetime ∷ !LoggingLifetime
  , supervisionPending ∷ !(TVar [Managed])
    -- ^ In registration order.
  , supervisionFailures ∷ !(TVar [SupervisedFailure])
    -- ^ Newest first.
  , supervisionLatch ∷ !(TVar (Maybe SupervisedFailure))
  }

-- | The narrow handle a supervision boundary lends the application thread.
--
-- It manages and supervises workers and does nothing else. Do not give it to a
-- worker action.
data RuntimeControl = RuntimeControl !WorkerGroup !Supervision

-- | A worker started under supervision.
data SupervisedWorker r = SupervisedWorker
  { supervisedWorker ∷ !(Worker r)
    -- ^ The foundation handle, for raw observation such as a job's result.
    -- Stop and cancel it through 'stopSupervised' and 'cancelSupervised', so
    -- supervision knows its owner asked.
  , supervisedManaged ∷ !Managed
  }

-- | What 'startSupervised' returns.
data SupervisedStart r
  = WorkerStarted !(SupervisedWorker r)
    -- ^ Startup was acknowledged. A job may already have completed, and a
    -- service may already have been stopped; 'workerStatus' says.
  | WorkerStartUnavailable !(SupervisedWorker r) !(ExceptionWithContext SomeException)
    -- ^ An optional worker failed with a recognized failure, during startup or
    -- as soon as it acknowledged. Its status is already committed.
  | WorkerStartRejected
    -- ^ The boundary had closed registration. Nothing was forked.

-- The boundary -----------------------------------------------------------------

-- | Run a body that supervises one worker group, then close, drain, and settle
-- every worker outcome before returning or rethrowing.
--
-- Call it inside the scopes of every component the workers borrow and inside
-- the logging lifetime it is given. See the module header for closing and for
-- what the boundary returns or rethrows.
withSupervision ∷ LoggingLifetime → (RuntimeControl → IO a) → IO a
withSupervision lifetime body = do
  state ← Supervision lifetime <$> newTVarIO [] <*> newTVarIO [] <*> newTVarIO Nothing
  outcome ← tryWithContext $ withWorkerGroup $ \group → do
    result ← body (RuntimeControl group state)
    report ← closeWorkerGroup group
    settleClosing state report
    deliver state
    pure result
  case outcome of
    Right result → pure result
    Left failure@(ExceptionWithContext context exception) → do
      unless (isCancellation exception) $ for_ (groupReport context) (settleClosing state)
      failures ← atomically (readTVar (supervisionFailures state))
      let delivered = deliveredWorker context
          retained = reverse [entry | entry ← failures, Just (failedWorker entry) /= delivered]
      if null retained
        then rethrowIO failure
        else rethrowIO (withFailures retained failure)

-- | The report the group attached when it drained with this failure pending.
groupReport ∷ ExceptionContext → Maybe GroupReport
groupReport context = listToMaybe (reverse [report | GroupExit report ← workerEvidenceInContext context])

-- | Handle every outcome closing drained that no checkpoint handled. A worker
-- still live when closing began was asked to stop by its owner.
settleClosing ∷ Supervision → GroupReport → IO ()
settleClosing state report = do
  let drained = [(completionWorker summary, summary) | summary ← reportDrained report]
      published = [(completionWorker summary, summary) | summary ← reportExitedBeforeClosing report]
  batch ← atomically $ do
    pending ← readTVar (supervisionPending state)
    concat
      <$> traverse
        ( \managed → do
            owner ← readTVar (managedRequested managed)
            pure $ case (lookup (managedId managed) published, lookup (managedId managed) drained) of
              (Just summary, _) → [(managed, summary, owner)]
              (_, Just summary) → [(managed, summary, True)]
              _ → []
        )
        pending
  settle state batch

-- Starting ---------------------------------------------------------------------

-- | Why a startup wait stopped waiting. Never escapes this module.
data StartupInterrupted = StartupInterrupted
  deriving (Show)

instance Exception StartupInterrupted

-- | Start a worker under a policy and wait for its startup through a supervised
-- wait.
--
-- The policy is registered before any of the worker's code runs. The wait also
-- wakes when an already-registered worker's outcome is certainly fatal —
-- required, or with failed cleanup — or when a fatal failure is already
-- latched; the new worker is then drained before this rethrows that failure. An
-- owner cancellation of the wait drains it too.
--
-- Once startup has ended, the worker's own outcome, if it already has one, is
-- handled here exactly once: a startup failure after the worker drained, or a
-- worker that acknowledged and has already finished. A fatal outcome is
-- rethrown; a recognized optional failure is 'WorkerStartUnavailable'. The
-- start itself is never retried, and nothing restarts a worker.
startSupervised ∷ RuntimeControl → WorkerPolicy → WorkerDefinition r → IO (SupervisedStart r)
startSupervised (RuntimeControl group state) policy definition = do
  registered ← newIORef Nothing
  let prepare worker = mask_ $ do
        managed ← newManaged worker policy
        atomically $ modifyTVar' (supervisionPending state) (sortOn managedId . (<> [managed]))
        writeIORef registered (Just managed)
      wait worker = do
        latched ← isJust <$> readTVar (supervisionLatch state)
        others ← filter (\(managed, _, _) → managedId managed /= workerId worker) <$> pendingOutcomes state
        when (latched || any certainlyFatal others) (throwSTM StartupInterrupted)
        awaitStartup worker
  started ← tryWithContext (startWorkerWith group definition prepare wait)
  case started of
    Left failure@(ExceptionWithContext _ exception) → do
      readIORef registered >>= traverse_ (\managed → atomically (writeTVar (managedRequested managed) True))
      case fromException exception of
        Just StartupInterrupted → checkRuntime (RuntimeControl group state)
        Nothing → pure ()
      rethrowIO failure
    Right (Left RegistrationClosed) → pure WorkerStartRejected
    Right (Right (worker, _)) → do
      managed ← readIORef registered >>= maybe (fail "startSupervised: preparation did not register") pure
      let handle = SupervisedWorker worker managed
      own ← atomically (filter (\(entry, _, _) → managedId entry == workerId worker) <$> pendingOutcomes state)
      settle state own
      deliver state
      status ← atomically (readTVar (managedStatus managed))
      pure $ case status of
        WorkerUnavailable failure → WorkerStartUnavailable handle failure
        _ → WorkerStarted handle
  where
    -- Fatal without consulting a classifier: failed cleanup, or any failure of
    -- a required worker.
    certainlyFatal (managed, summary, owner) = case judge (managedPolicy managed) owner summary of
      FatalNow _ → True
      Classify _ → policyDisposition (managedPolicy managed) == Required
      _ → False

newManaged ∷ Worker r → WorkerPolicy → IO Managed
newManaged worker policy =
  Managed (workerId worker) (workerLabel worker) policy
    (fmap (() <$) <$> pollCompletion worker)
    (() <$ observeCompletion worker)
    <$> newTVarIO False
    <*> newTVarIO WorkerLive

-- | Ask a supervised worker to stop, recording that its owner asked.
stopSupervised ∷ SupervisedWorker r → IO ()
stopSupervised handle = atomically $ do
  writeTVar (managedRequested (supervisedManaged handle)) True
  requestStop (supervisedWorker handle)

-- | Request cancellation of a supervised worker, recording that its owner asked.
cancelSupervised ∷ SupervisedWorker r → IO ()
cancelSupervised handle = do
  atomically (writeTVar (managedRequested (supervisedManaged handle)) True)
  requestCancel (supervisedWorker handle)

-- | What supervision has committed about a worker so far.
workerStatus ∷ SupervisedWorker r → STM WorkerStatus
workerStatus = readTVar . managedStatus . supervisedManaged

-- Checkpoints and waits --------------------------------------------------------

-- | Handle every pending worker outcome, then rethrow the latched fatal
-- failure if there is one.
checkRuntime ∷ RuntimeControl → IO ()
checkRuntime (RuntimeControl _ state) = do
  batch ← atomically (pendingOutcomes state)
  settle state batch
  deliver state

-- | Wait for a transaction while supervising.
--
-- In one transaction, pending worker outcomes are read first. If any exist, or a
-- fatal failure is latched, the caller's transaction does not run: the
-- outcomes are handled as at 'checkRuntime', a fatal one is rethrown, and
-- otherwise the wait starts again. Only when nothing is pending does the
-- caller's transaction run, and its result is returned. A retry waits on the
-- caller's reads and on every supervised worker's terminal state together.
--
-- A failure in the caller's transaction propagates with nothing marked.
awaitSupervised ∷ RuntimeControl → STM a → IO a
awaitSupervised (RuntimeControl _ state) work = loop
  where
    loop = do
      step ← atomically $ do
        batch ← pendingOutcomes state
        latched ← isJust <$> readTVar (supervisionLatch state)
        if not (null batch) || latched
          then pure (Left batch)
          else Right <$> work
      case step of
        Right result → pure result
        Left batch → settle state batch >> deliver state >> loop

-- | Every registered worker with a published outcome not yet handled, in
-- registration order, with whether its owner asked it to stop.
pendingOutcomes ∷ Supervision → STM [(Managed, WorkerSummary, Bool)]
pendingOutcomes state = do
  pending ← readTVar (supervisionPending state)
  concat
    <$> traverse
      ( \managed →
          managedPoll managed >>= \case
            Nothing → pure []
            Just summary → (\owner → [(managed, summary, owner)]) <$> readTVar (managedRequested managed)
      )
      pending

-- Classification ---------------------------------------------------------------

-- | The structural part of a classification, before any classifier runs.
data Judgement
  = Complete
  | Stop
  | FatalNow !(ExceptionWithContext SomeException)
    -- ^ Fatal whatever the policy says: failed cleanup.
  | Classify !(ExceptionWithContext SomeException)
    -- ^ A failure the policy judges.

-- | The classification table, without the classifier. The owner flag says
-- whether the owner asked this worker to stop.
judge ∷ WorkerPolicy → Bool → WorkerSummary → Judgement
judge policy owner summary = case completionResult summary of
  Succeeded ()
    | policyRole policy == Job → Complete
    | requestedAtExit → Stop
    | otherwise → Classify (synthetic (UnexpectedServiceExit summary))
  Failed failure
    | hasCleanup → FatalNow failure
    | otherwise → Classify failure
  Cancelled _
    | hasCleanup → FatalNow (synthetic (WorkerCleanupFailed summary))
    | policyRole policy == Service, exit == RunExited RunReturned NothingRequested →
        Classify (synthetic (UnexpectedServiceExit summary))
    | requestedAtExit || (owner && ownerMayExplain) → Stop
    | otherwise → Classify (synthetic (UnexpectedWorkerTermination summary))
  where
    exit = completionExit summary
    hasCleanup = not (null (completionCleanup summary))
    requestedAtExit = case exit of
      RunExited _ requested → requested /= NothingRequested
      RunNotEntered → False
    -- A cancellation the run action itself received before any request stays
    -- unexpected, even if the owner asked later.
    ownerMayExplain = case exit of
      RunNotEntered → True
      RunExited RunReturned _ → True
      RunExited _ _ → False

synthetic ∷ Exception e ⇒ e → ExceptionWithContext SomeException
synthetic failure = ExceptionWithContext emptyExceptionContext (toException failure)

-- | The status a handled outcome commits.
classify ∷ Managed → WorkerSummary → Bool → IO WorkerStatus
classify managed summary owner = case judge policy owner summary of
  Complete → pure WorkerCompleted
  Stop → pure WorkerStopped
  FatalNow failure → pure (WorkerFatal failure)
  Classify failure → do
    recognized ← tryWithContext (policyClassifier policy failure >>= evaluate)
    case recognized of
      Left raised@(ExceptionWithContext context exception)
        | isCancellation exception → rethrowIO raised
        | otherwise →
            pure (WorkerFatal (ExceptionWithContext (addExceptionAnnotation (WhileHandling (toException failure)) context) exception))
      Right Recognized | policyDisposition policy == Optional → pure (WorkerUnavailable failure)
      Right _ → pure (WorkerFatal failure)
  where
    policy = managedPolicy managed

-- | Classify a batch outside STM, commit it, then attempt its warnings.
settle ∷ Supervision → [(Managed, WorkerSummary, Bool)] → IO ()
settle _ [] = pure ()
settle state batch = do
  decided ← traverse (\(managed, summary, owner) → (,) managed <$> classify managed summary owner) batch
  warnings ← atomically (concat <$> traverse commit decided)
  traverse_ (warn state) warnings
  where
    commit (managed, status) = do
      pending ← readTVar (supervisionPending state)
      if managedId managed `notElem` map managedId pending
        then pure []
        else do
          writeTVar (supervisionPending state) (filter ((/= managedId managed) . managedId) pending)
          managedObserve managed
          writeTVar (managedStatus managed) status
          case status of
            WorkerFatal failure → do
              let entry = failed managed Fatal failure
              modifyTVar' (supervisionFailures state) (entry :)
              readTVar (supervisionLatch state) >>= \case
                Nothing → writeTVar (supervisionLatch state) (Just entry)
                Just _ → pure ()
              pure []
            WorkerUnavailable failure → do
              modifyTVar' (supervisionFailures state) (failed managed Tolerated failure :)
              pure [(managed, failure)]
            _ → pure []
    failed managed = SupervisedFailure (managedId managed) (managedLabel managed)

-- | The one warning for an optional worker left unavailable, through the
-- lifetime's managed reporting, unless a managed report has already failed.
warn ∷ Supervision → (Managed, ExceptionWithContext SomeException) → IO ()
warn state (managed, failure) = do
  let lifetime = supervisionLifetime state
  recorded ← recordedReports lifetime
  unless (any reportFailed recorded) $ do
    let name = operation ("supervise worker " <> managedLabel managed)
        outcome = Unavailable (Unavailability name (AttemptFailure 1 InitialAttempt failure) [])
    result ← reportOutcome (lifetimeLogger lifetime) (policyComponent (managedPolicy managed)) name outcome
    recordReport lifetime result
  where
    reportFailed (ReportFailed _) = True
    reportFailed _ = False

-- | Rethrow the latched fatal failure, with every other committed failure
-- retained beside it.
deliver ∷ Supervision → IO ()
deliver state = do
  (latch, failures) ← atomically ((,) <$> readTVar (supervisionLatch state) <*> readTVar (supervisionFailures state))
  for_ latch $ \primary → do
    let ExceptionWithContext context exception = failedException primary
        retained = reverse [entry | entry ← failures, failedWorker entry /= failedWorker primary]
        marked = ExceptionWithContext (addExceptionAnnotation (Delivered (failedWorker primary)) context) exception
    rethrowIO (if null retained then marked else withFailures retained marked)

-- Evidence ---------------------------------------------------------------------

-- | Marks a delivery of the latched failure, naming its worker.
newtype Delivered = Delivered WorkerId

instance ExceptionAnnotation Delivered where
  displayExceptionAnnotation (Delivered worker) = "fatal supervised failure of worker " <> show worker

deliveredWorker ∷ ExceptionContext → Maybe WorkerId
deliveredWorker context = listToMaybe [worker | Delivered worker ← getExceptionAnnotations context]

-- | The failures retained beside a propagated failure, with their attachment
-- position so the latest attachment wins.
data FailuresEntry = FailuresEntry !Int ![SupervisedFailure]

instance ExceptionAnnotation FailuresEntry where
  displayExceptionAnnotation (FailuresEntry _ failures) =
    "supervised worker failures retained: "
      <> unwords [show (Text.unpack (failedLabel entry)) <> " " <> show (failedSeverity entry) | entry ← failures]

withFailures ∷ [SupervisedFailure] → ExceptionWithContext SomeException → ExceptionWithContext SomeException
withFailures failures (ExceptionWithContext context exception) =
  ExceptionWithContext (addExceptionAnnotation (FailuresEntry position failures) context) exception
  where
    position = length (getExceptionAnnotations context ∷ [FailuresEntry])

-- | The worker failures a supervision boundary or checkpoint retained beside the
-- failure it propagated, in commit order: registration order within one
-- checkpoint. The propagated failure itself is not repeated. Empty when none.
supervisedFailures ∷ SomeException → [SupervisedFailure]
supervisedFailures = supervisedFailuresInContext . someExceptionContext

-- | 'supervisedFailures' for a caller holding the context directly.
supervisedFailuresInContext ∷ ExceptionContext → [SupervisedFailure]
supervisedFailuresInContext context =
  maybe [] snd . listToMaybe . reverse . sortOn fst $
    [(position, failures) | FailuresEntry position failures ← getExceptionAnnotations context]

isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)
