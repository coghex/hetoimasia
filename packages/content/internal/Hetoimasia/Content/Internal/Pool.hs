-- | The owned, bounded pool of verified-read workers (LFE-10).
--
-- A pool turns the synchronous 'Hetoimasia.Content.Inventory.readVerified' into asynchronous
-- work for any number of consumers (raw data now; module sources and texture sources later)
-- without becoming a general executor: it runs only verified reads of an anchored inventory,
-- on a fixed number of worker threads, from a queue whose size is bounded by reservations the
-- consumers made before they submitted.
--
-- = Who owns what
--
-- * The /pool/ is one 'withPool' scope. It starts its workers inside a foundation worker group
--   and runs inside the scopes of the root and the inventory its reader borrows, so the group's
--   drain finishes every started read before either of them can be released. The scope is never
--   reopened.
-- * A /consumer/ owns what it reserved. 'reserveSlot' takes one unit of queue capacity, with the
--   consumer's other admission reservations and in the same transaction; 'releaseSlot' gives it
--   back after the consumer has seen its job retire. A job can be submitted only against a
--   reservation, so the queue, the active reads and the completions in flight are bounded by the
--   reservations that exist, and a job that was accepted can never be refused or retried for want
--   of room.
-- * The /buffer/ of a successful read belongs to the verified reader until the sink is called with
--   it; from then on the consumer owns that one allocation. The pool keeps no cache, no copy and
--   no second reference.
--
-- = A job
--
-- @Queued@ (in the queue, no file touched) becomes @Issued@ (a worker took it; it may be cancelled
-- but not withdrawn), then @Delivering@ (the worker decided to call the sink, and the job's claim
-- on its slot is over) and then @Done@ (the sink returned); or @Done@ directly when interest was
-- withdrawn before delivery and the call is suppressed; or @Withdrawn@ (it left the queue before
-- issuance, on a cancel or when the pool closed or failed). Every transition out of @Queued@,
-- @Issued@ and into @Delivering@ is an STM transaction on the one pool state, so a cancel and an
-- issuance, or a cancel and the decision to deliver, cannot both win. 'retired' is true from @Done@
-- or @Withdrawn@ on: it is the per-job evidence a consumer's own retirement reading is made of,
-- and the one a group drain or a worker's exit cannot give.
--
-- A worker releases its execution slot as soon as the sink returned. The sink is a consumer's
-- non-blocking completion whose room the consumer reserved when it admitted the job (for the Lua
-- provider, the request's reserved result slot): a worker never waits for a logical due tick, a
-- take, evaluation, decoding or another job.
--
-- = Failure
--
-- An expected outcome of a verified read ('ReadFailed') is data for the sink. Anything else a read
-- or a sink raises is a defect: the job's sink is told ('ReadDefect'), every queued job is
-- withdrawn and told, the pool latches the first defect (read by 'awaitFailure' and rethrown by the
-- scope), no further job is accepted, and the worker ends with the defect so that supervision of
-- the surrounding group sees it. Nothing restarts. An asynchronous exception ends the worker,
-- settles the job it interrupted as abandoned, and is not a defect.
module Hetoimasia.Content.Internal.Pool
  ( -- * The pool
    ReadPool
  , PoolSpec (..)
  , poolSpec
  , PoolSpecRefusal (..)
  , VerifiedRead
  , withPool
  , withPoolWith
  , PoolHooks (..)
  , noHooks

    -- * Capacity
  , reserveSlot
  , releaseSlot

    -- * Jobs
  , ReadRequest (..)
  , ReadPriority (..)
  , ReadResult (..)
  , SubmitRefusal (..)
  , ReadTicket
  , submit
  , cancel
  , withdrawQueued
  , CancelOutcome (..)
  , retired
  , ticketKey

    -- * Observation
  , PoolStatus (..)
  , PoolPhase (..)
  , status
  , awaitFailure
  , poolFailureEvidence
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVar
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException (SomeAsyncException)
  , SomeException
  , fromException
  , mask
  , mask_
  , displayException
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (forM, forM_, when)
import Data.ByteString (ByteString)
import Data.Functor ((<&>))
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Content.Internal.Identity.Types (ContentKey)
import Hetoimasia.Content.Internal.Inventory.Types (Inventory, ReadFailure)
import Hetoimasia.Content.Internal.Inventory.Read (readVerified)
import Hetoimasia.Content.Internal.Root (ContentRoot)
import Hetoimasia.Content.Internal.Types (ContentDefect (..), Defect (..))
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext, composeCleanup)
import Hetoimasia.Foundation.Worker
  ( Completion (completionCleanup, completionLabel, completionResult)
  , GroupReport (reportDrained, reportExitedBeforeClosing, reportObservedFailures)
  , Result (Cancelled, Failed, Succeeded)
  , StartOutcome (Started, StartRejected, StartupFailed)
  , StopToken
  , Worker
  , WorkerCancelled (WorkerCancelled)
  , closeWorkerGroup
  , startWorker
  , stopRequested
  , withWorkerGroup
  , workerDefinition
  )
import qualified Data.Text as Text

-- The specification -----------------------------------------------------------------------

-- | The two numbers a pool is built from. Nothing here is a default: the assembly passes the
-- profile's worker count (two for M1) and the queue capacity its consumers' reservations add up
-- to.
data PoolSpec = PoolSpec
  { poolWorkers ∷ !Int
  -- ^ Worker threads: the most reads in flight at once.
  , poolSlots ∷ !Int
  -- ^ The most jobs queued, issued or finishing at once: the capacity 'reserveSlot' hands out.
  }
  deriving (Eq, Show)

-- | Why a specification is not usable.
data PoolSpecRefusal
  = -- | Fewer than one worker.
    WorkersNotPositive !Int
  | -- | Fewer than one slot.
    SlotsNotPositive !Int
  deriving (Eq, Show)

-- | Check a specification.
poolSpec ∷ Int → Int → Either PoolSpecRefusal PoolSpec
poolSpec workers slots
  | workers < 1 = Left (WorkersNotPositive workers)
  | slots < 1 = Left (SlotsNotPositive slots)
  | otherwise = Right (PoolSpec workers slots)

-- | How verified bytes are produced for a key within a byte allowance:
-- @'readVerified' inventory root@ in production. A caller that supplies its own (to gate or fail a
-- read in a test) is responsible for what it borrows outliving the pool.
type VerifiedRead = ContentKey → Int → IO (Either ReadFailure ByteString)

-- | Coordination points of the pool's own transitions, for this package's tests. Production
-- uses 'noHooks'. A hook runs on the thread making the transition, outside any transaction.
data PoolHooks = PoolHooks
  { hookWorkerStart ∷ !(Int → IO ())
  -- ^ Before worker @i@ (from zero) is started.
  , hookWorkerStarted ∷ !(Int → Worker () → IO ())
  -- ^ After worker @i@ was started, with its handle: for a test that stops or cancels one from
  -- outside the scope.
  , hookIssued ∷ !(ContentKey → IO ())
  -- ^ A worker took the job off the queue and has not yet asked the reader to open anything.
  , hookRead ∷ !(ContentKey → IO ())
  -- ^ The reader returned (bytes, refusal or exception) and nothing was published yet.
  , hookSettled ∷ !(ContentKey → IO ())
  -- ^ The sink returned (or was suppressed) and the job is not yet marked done.
  }

-- | No hooks.
noHooks ∷ PoolHooks
noHooks = PoolHooks (\_ → pure ()) (\_ _ → pure ()) (\_ → pure ()) (\_ → pure ()) (\_ → pure ())

-- Jobs ------------------------------------------------------------------------------------

-- | Which queued job a worker takes first. Within a class the oldest accepted job goes first.
data ReadPriority
  = -- | The read an active dependency chain is waiting for: ahead of unrelated prefetch. The
    -- class is the consumer's to assign (module loading, LFE-11); raw data is never this.
    DependencyProgress
  | -- | Any other read.
    OrdinaryRead
  deriving (Eq, Ord, Show, Bounded, Enum)

-- | What a consumer asks of the pool.
data ReadRequest = ReadRequest
  { requestKey ∷ !ContentKey
  , requestAllowance ∷ !Int
  -- ^ The most bytes this read may return: the consumer's own already-reserved bounded
  -- allowance, never below zero. The pool imposes none of its own.
  , requestPriority ∷ !ReadPriority
  , requestSink ∷ ReadResult → IO ()
  -- ^ How the outcome is handed over. It must not block or wait for anything the consumer's own
  -- owner provides, and the consumer reserved room for what it does before submitting; it is
  -- called at most once, on a worker's thread, and never for a job whose interest was withdrawn
  -- after issuance.
  }

-- | What a job came to.
data ReadResult
  = -- | The whole verified buffer. It is the consumer's from here.
    ReadSucceeded !ByteString
  | -- | An expected refusal of the verified read, classified by the content layer.
    ReadFailed !ReadFailure
  | -- | The reader or a sink raised something that is not an expected outcome: an engine or
    -- provider defect. It is also latched on the pool and rethrown by its scope.
    ReadDefect !SomeException
  | -- | The job was issued or queued when the pool closed, or a worker was cancelled under it,
    -- without interest having been withdrawn: no read result exists.
    ReadAbandoned

-- | Why a job was not accepted. The pool was not able to take any job at all.
data SubmitRefusal
  = -- | The pool's scope is ending or ended.
    PoolIsClosed
  | -- | A worker or sink failed earlier; that failure.
    PoolHasFailed !SomeException

-- | The consumer's record of one accepted job.
data ReadTicket = ReadTicket !(TVar PoolState) !Job

-- | The key the ticket reads.
ticketKey ∷ ReadTicket → ContentKey
ticketKey (ReadTicket _ job) = jobKey job

data JobState
  = JobQueued
  | -- | A worker took it. The flag says interest was withdrawn.
    JobIssued !Bool
  | -- | A worker decided to hand the result to the sink, or is doing so. The slot's claim is
    -- over; the job is not retired until the sink returned.
    JobDelivering
  | JobDone
  | -- | Left the queue unissued and has been withdrawn with no sink to tell: retired.
    JobWithdrawn
  | -- | Left the queue unissued because the pool closed or failed, and its sink is yet to be
    -- told: not retired until it has been. The flag says interest was withdrawn meanwhile, which
    -- suppresses the call if it has not been made.
    JobNotifying !Bool

data Job = Job
  { jobKey ∷ !ContentKey
  , jobAllowance ∷ !Int
  , jobOrder ∷ !(Int, Word64)
  , jobSink ∷ ReadResult → IO ()
  , jobState ∷ !(TVar JobState)
  }

-- The state ---------------------------------------------------------------------------------

-- | Whether the scope still accepts jobs.
data PoolPhase = PoolOpen | PoolClosed
  deriving (Eq, Show)

-- | The whole state of one pool, in one variable, so every invariant is a property of a
-- transaction and not of an interleaving.
--
-- Owner: the pool's scope. Writers: consumers ('reserveSlot', 'releaseSlot', 'submit', 'cancel')
-- and workers (issuance and settlement), always in STM. Readers: anyone, through 'status'.
-- Invariant: @queued <= live <= reserved <= capacity@ and @active <= live@.
data PoolState = PoolState
  { psPhase ∷ !PoolPhase
  , psFailure ∷ !(Maybe (ExceptionWithContext SomeException))
  -- ^ The first failure: set once, by the transaction that finds none.
  , psEvidence ∷ ![(Text.Text, ExceptionWithContext SomeException)]
  -- ^ Every later failure and every failure raised while telling a job, in the order they were
  -- recorded. Append-only: each is added by a transaction that reads the current list.
  , psQueue ∷ !(Map (Int, Word64) Job)
  , psNext ∷ !Word64
  , psReserved ∷ !Int
  , psLive ∷ !Int
  , psActive ∷ !Int
  }

-- | The pool.
data ReadPool = ReadPool
  { poolSpecOf ∷ !PoolSpec
  , poolState ∷ !(TVar PoolState)
  , poolReader ∷ VerifiedRead
  , poolHooks ∷ !PoolHooks
  }

-- | A coherent reading of the pool.
data PoolStatus = PoolStatus
  { statusPhase ∷ !PoolPhase
  , statusFailed ∷ !Bool
  , statusWorkers ∷ !Int
  , statusCapacity ∷ !Int
  , statusReserved ∷ !Int
  -- ^ Slots consumers hold.
  , statusQueued ∷ !Int
  -- ^ Jobs waiting for a worker.
  , statusActive ∷ !Int
  -- ^ Jobs a worker took and has not finished.
  , statusLive ∷ !Int
  -- ^ Queued and active.
  }
  deriving (Eq, Show)

-- | Read the pool in one transaction.
status ∷ ReadPool → STM PoolStatus
status pool = do
  st ← readTVar (poolState pool)
  pure
    PoolStatus
      { statusPhase = psPhase st
      , statusFailed = maybe False (const True) (psFailure st)
      , statusWorkers = poolWorkers (poolSpecOf pool)
      , statusCapacity = poolSlots (poolSpecOf pool)
      , statusReserved = psReserved st
      , statusQueued = Map.size (psQueue st)
      , statusActive = psActive st
      , statusLive = psLive st
      }

-- | Wait, in STM, for the first defect a worker or sink raised, so a supervisor can compose it
-- into a supervised wait.
awaitFailure ∷ ReadPool → STM (ExceptionWithContext SomeException)
awaitFailure pool = readTVar (poolState pool) >>= maybe retry pure . psFailure

-- | The evidence recorded beside the first failure so far, oldest first: later worker failures and
-- failures raised while telling a queued job's sink.
poolFailureEvidence ∷ ReadPool → STM [(Text.Text, ExceptionWithContext SomeException)]
poolFailureEvidence pool = psEvidence <$> readTVar (poolState pool)

-- | The one writer of the evidence list: it reads the current list in its own transaction and
-- appends, so concurrent additions are all kept.
appendEvidence ∷ ReadPool → Text.Text → ExceptionWithContext SomeException → STM ()
appendEvidence pool label found = do
  st ← readTVar (poolState pool)
  writeTVar (poolState pool) st {psEvidence = psEvidence st <> [(label, found)]}

-- | The latched failure with all the evidence recorded so far composed beside it, if one is latched.
latchedFailure ∷ ReadPool → IO (Maybe (ExceptionWithContext SomeException))
latchedFailure pool = do
  st ← readTVarIO (poolState pool)
  case psFailure st of
    Nothing → pure Nothing
    Just first → Just <$> withEvidence first (psEvidence st)

-- The scope -------------------------------------------------------------------------------

-- | Run a body over a pool of verified reads of this inventory through this root.
--
-- Call it inside the root's scope: the root and the inventory are borrowed for every read, and
-- the scope's exit drains every started read before it returns, so the root closes after them.
withPool ∷ PoolSpec → Inventory → ContentRoot → (ReadPool → IO a) → IO a
withPool spec inventory root = withPoolWith noHooks spec (readVerified inventory root)

-- | 'withPool' over a reader the caller supplies and hooks.
--
-- The scope, in order: the worker group; the pool state; the workers, each started with
-- registration checked; the body. On any exit the pool closes first (admission stops and every
-- queued job is withdrawn and told it was abandoned), then the group drains: every read already
-- started runs to its end, with its job settled, before the borrowed dependencies unwind. A body
-- that returned while a worker had failed rethrows that failure.
withPoolWith ∷ PoolHooks → PoolSpec → VerifiedRead → (ReadPool → IO a) → IO a
withPoolWith hooks spec reader body = withWorkerGroup $ \group → do
  var ← newTVarIO (PoolState PoolOpen Nothing [] Map.empty 0 0 0 0)
  let pool = ReadPool spec var reader hooks
  result ← mask $ \restore → do
    outcome ← tryWithContext @SomeException $ restore $ do
      forM_ [0 .. poolWorkers spec - 1] $ \index → do
        hookWorkerStart hooks index
        startWorker group (workerDefinition (Text.pack ("content-read-" <> show index)) (\_ → pure ()) (\token () → runWorker pool token)) >>= \case
          Started worker → hookWorkerStarted hooks index worker
          StartupFailed _ _ → throwIO (ContentDefect (ReadWorkerNotStarted index))
          StartRejected _ → throwIO (ContentDefect (ReadWorkerNotStarted index))
      body pool
    -- The pool closes whether or not the body ended well; a failure closing is kept beside the
    -- primary one.
    closed ← tryWithContext @SomeException (closePool pool)
    -- A failure a worker latched while the body ran is evidence of the exit whatever else ends it.
    latched ← latchedFailure pool
    let kept = [("content read pool worker failure", found) | Just found ← [latched]]
    case (outcome, closed) of
      (Right value, Right ()) → pure (Right value)
      (Right _, Left closing) → Left <$> withEvidence closing kept
      (Left primary, Right ()) → Left <$> withEvidence primary kept
      (Left primary, Left closing) → Left <$> withEvidence primary (("content read pool close", closing) : kept)
  case result of
    Left failure → rethrowIO failure
    Right value → do
      -- The body returned. A worker's failure from here on is still the scope's failure: the
      -- report of the workers' own outcomes is read, and anything but a clean return is raised.
      report ← closeWorkerGroup group
      latched ← latchedFailure pool
      case latched of
        Just failure → rethrowIO failure
        Nothing →
          unclean report >>= \case
            Nothing → pure value
            Just failure → rethrowIO failure

-- | A failure with this evidence kept beside it, if there is any.
withEvidence ∷ ExceptionWithContext SomeException → [(Text.Text, ExceptionWithContext SomeException)] → IO (ExceptionWithContext SomeException)
withEvidence primary [] = pure primary
withEvidence primary evidence = fromMaybe primary <$> composeCleanup (Just primary) evidence

-- | What a group's report holds that is not a clean exit: a worker that failed or was cancelled
-- or retained a cleanup failure. Raised when the body returned and no worker latched a failure,
-- since a worker that was not asked to cancel and did not return cleanly is a failure of the pool.
unclean ∷ GroupReport → IO (Maybe (ExceptionWithContext SomeException))
unclean report = do
  let summaries = reportExitedBeforeClosing report <> reportDrained report <> reportObservedFailures report
      evidence =
        concat
          [ [(completionLabel found, raised) | raised ← resultFailure (completionResult found)]
            <> [(cleanupFailureLabel cleanup, cleanupFailureException cleanup) | cleanup ← completionCleanup found]
          | found ← summaries
          ]
  if null evidence
    then pure Nothing
    else do
      raised ← tryWithContext @SomeException (throwIO (ContentDefect ReadWorkerReportedUnclean))
      primary ← either pure (\() → throwIO (ContentDefect ReadWorkerReportedUnclean)) raised
      Just <$> withEvidence primary evidence
  where
    resultFailure = \case
      Succeeded () → []
      Failed raised → [raised]
      Cancelled raised → [raised]

-- Capacity -------------------------------------------------------------------------------

-- | Take one unit of queue capacity, in the consumer's admission transaction. 'False' when none is
-- left. It does not depend on the pool's phase: a pool that has closed or failed refuses at
-- 'submit', where the consumer can tell it from a full queue.
reserveSlot ∷ ReadPool → STM Bool
reserveSlot pool = do
  st ← readTVar (poolState pool)
  if psReserved st >= poolSlots (poolSpecOf pool)
    then pure False
    else True <$ writeTVar (poolState pool) st {psReserved = psReserved st + 1}

-- | Give a unit of capacity back, once, after the job it was reserved for has retired. Releasing
-- one while every reserved unit is held by a live job, or more than were reserved, is a defect
-- of the caller and raises.
releaseSlot ∷ ReadPool → STM ()
releaseSlot pool = do
  st ← readTVar (poolState pool)
  when (psReserved st <= psLive st) $ throwSTM (ContentDefect ReadSlotReleasedWhileLive)
  writeTVar (poolState pool) st {psReserved = psReserved st - 1}

-- Submitting and cancelling ----------------------------------------------------------------

-- | Accept a job against a reserved slot, or say why the pool cannot take any. Never blocks, opens
-- nothing, and never waits for a worker. A job beyond the reservations, or with a negative
-- allowance, is a defect of the caller and raises; the transaction then leaves nothing behind.
submit ∷ ReadPool → ReadRequest → STM (Either SubmitRefusal ReadTicket)
submit pool request = do
  when (requestAllowance request < 0) $ throwSTM (ContentDefect (BadReadCeiling (requestAllowance request)))
  st ← readTVar (poolState pool)
  case (psFailure st, psPhase st) of
    (Just (ExceptionWithContext _ failure), _) → pure (Left (PoolHasFailed failure))
    (_, PoolClosed) → pure (Left PoolIsClosed)
    _ → do
      when (psLive st >= psReserved st) $ throwSTM (ContentDefect ReadSubmittedWithoutSlot)
      -- Sequence numbers order the queue and are never reused or wrapped.
      when (psNext st == maxBound) $ throwSTM (ContentDefect ReadSequenceExhausted)
      state ← newTVar JobQueued
      let order = (fromEnum (requestPriority request), psNext st)
          job = Job (requestKey request) (requestAllowance request) order (requestSink request) state
      writeTVar
        (poolState pool)
        st
          { psQueue = Map.insert order job (psQueue st)
          , psNext = psNext st + 1
          , psLive = psLive st + 1
          }
      pure (Right (ReadTicket (poolState pool) job))

-- | What withdrawing interest in a job came to.
data CancelOutcome
  = -- | It was still queued: it left the queue, no file was opened and its sink will not be
    -- called. It is retired.
    CancelWithdrawn
  | -- | A worker already took it. Unless it had begun to hand the result over, its sink is not
    -- called; either way it retires when the worker is done with it.
    CancelInFlight
  | -- | It had finished or been withdrawn.
    CancelTooLate
  deriving (Eq, Show)

-- | Withdraw interest in a job. This and issuance are transactions on one state, so exactly one of
-- them wins a job that is still queued.
cancel ∷ ReadTicket → STM CancelOutcome
cancel (ReadTicket var job) =
  readTVar (jobState job) >>= \case
    JobQueued → do
      st ← readTVar var
      writeTVar var st {psQueue = Map.delete (jobOrder job) (psQueue st), psLive = psLive st - 1}
      writeTVar (jobState job) JobWithdrawn
      pure CancelWithdrawn
    JobIssued _ → CancelInFlight <$ writeTVar (jobState job) (JobIssued True)
    JobDelivering → pure CancelInFlight
    JobDone → pure CancelTooLate
    JobNotifying _ → CancelInFlight <$ writeTVar (jobState job) (JobNotifying True)
    JobWithdrawn → pure CancelTooLate

-- | Withdraw a job only if no worker has taken it. 'True' when it was still queued: it left the
-- queue, no file was opened, its sink will not be called and it has retired. 'False' otherwise, with
-- nothing changed: a worker holds it (or it finished), and its sink will still be called unless the
-- consumer 'cancel's it. A consumer that must get its sink call back for every job a worker took
-- (to return the slot it reserved from there) uses this and never 'cancel's an issued job. It and
-- issuance are transactions on one state, so exactly one of them wins a job that is still queued.
withdrawQueued ∷ ReadTicket → STM Bool
withdrawQueued (ReadTicket var job) =
  readTVar (jobState job) >>= \case
    JobQueued → do
      st ← readTVar var
      writeTVar var st {psQueue = Map.delete (jobOrder job) (psQueue st), psLive = psLive st - 1}
      writeTVar (jobState job) JobWithdrawn
      pure True
    _ → pure False

-- | Whether the job has retired: its sink has been called (or suppressed), or it was withdrawn.
-- A pure reading with no write, as a retirement reading must be.
retired ∷ ReadTicket → STM Bool
retired (ReadTicket _ job) =
  readTVar (jobState job) >>= \case
    JobDone → pure True
    JobWithdrawn → pure True
    _ → pure False

-- Workers -------------------------------------------------------------------------------

-- | A worker: take the oldest job of the strongest class, read it, settle it; until the pool
-- closes or fails, or the worker is asked to stop with nothing queued.
--
-- The whole loop is masked and a read runs unmasked inside it, so the only places an asynchronous
-- exception can arrive are the wait for a job (nothing is issued yet) and the read itself (whose
-- job is then settled as abandoned). A job taken off the queue is therefore always settled.
--
-- A worker is never allowed to end quietly while its pool is open: whether it returned because it
-- was asked to stop, was terminated by an asynchronous exception nobody in this scope sent, or
-- raised, the pool is then failed (it will not run what is queued, and the queued jobs are told),
-- so nothing accepted is left pending behind a pool that looks healthy. The scope's own exit closes
-- the pool before it stops or cancels a worker, so that exit is not a failure.
runWorker ∷ ReadPool → StopToken → IO ()
runWorker pool token = mask $ \restore → do
  outcome ← tryWithContext @SomeException (loop restore)
  healthy ← atomically (isHealthy pool)
  case outcome of
    Right ()
      -- Returned after the scope closed the pool, or after a failure was latched: a clean stop.
      | not healthy → pure ()
      | otherwise → exitFailure outcome >>= latchFailure pool >>= rethrowIO
    Left caught@(ExceptionWithContext trail raised)
      -- The scope's own cancellation of a worker, once the pool is closed or failed and with no
      -- cleanup failure retained, is the drain doing its work.
      | not healthy && isTeardown raised && null (cleanupFailuresInContext trail) → rethrowIO caught
      -- A synchronous exception left a job already latched by 'onSynchronousFailure'.
      | not (isAsynchronous raised) → rethrowIO caught
      -- An asynchronous exception nobody in this scope sent, or one that retained cleanup
      -- evidence, whether the pool is open or draining: the pool's failure, with the evidence kept.
      | otherwise → exitFailure outcome >>= latchFailure pool >>= rethrowIO
  where
    loop ∷ (∀ x. IO x → IO x) → IO ()
    loop restore =
      atomically (takeNext pool token) >>= \case
        Nothing → pure ()
        Just job → do
          runJob restore pool job `onSynchronousFailure` latchFailure pool
          loop restore
    isTeardown raised = case fromException raised of
      Just WorkerCancelled → True
      Nothing → False

isAsynchronous ∷ SomeException → Bool
isAsynchronous failure = case fromException failure of
  Just (SomeAsyncException _) → True
  Nothing → False

-- | Open and with no latched failure.
isHealthy ∷ ReadPool → STM Bool
isHealthy pool = do
  st ← readTVar (poolState pool)
  pure (psPhase st == PoolOpen && isNothing (psFailure st))

-- | What an exit of a worker from an open pool is, as a failure with its context. When the worker
-- ended by an exception, that exception is kept beside the defect with every cleanup failure it had
-- retained, so none of the evidence of the termination is lost in the wrapping.
exitFailure ∷ Either (ExceptionWithContext SomeException) () → IO (ExceptionWithContext SomeException)
exitFailure outcome = do
  let defect = case outcome of
        Right () → ReadWorkerEndedOpen
        Left (ExceptionWithContext _ failure) → ReadWorkerTerminated (displayException failure)
  raised ← tryWithContext @SomeException (throwIO (ContentDefect defect))
  primary ← either pure (\() → throwIO (ContentDefect defect)) raised
  case outcome of
    Right () → pure primary
    Left terminated@(ExceptionWithContext trail _) → do
      let retained = [(cleanupFailureLabel found, cleanupFailureException found) | found ← cleanupFailuresInContext trail]
      composed ← composeCleanup (Just primary) (("content read worker termination", terminated) : retained)
      pure (fromMaybe primary composed)

-- | The next job, or 'Nothing' when this worker should end.
takeNext ∷ ReadPool → StopToken → STM (Maybe Job)
takeNext pool token = do
  st ← readTVar (poolState pool)
  case Map.minView (psQueue st) of
    Just (job, rest) → do
      writeTVar (poolState pool) st {psQueue = rest, psActive = psActive st + 1}
      -- Issuance: from here a cancel finds the job in a worker's hands.
      writeTVar (jobState job) (JobIssued False)
      pure (Just job)
    Nothing
      | psPhase st /= PoolOpen || maybe False (const True) (psFailure st) → pure Nothing
      | otherwise → do
          stopping ← stopRequested token
          if stopping then pure Nothing else retry

-- | What a worker found when it ran an issued job.
data Ran
  = -- | Interest was withdrawn before the reader was asked for anything: no file was touched.
    Skipped
  | Read !(Either ReadFailure ByteString)

-- | Read one issued job and settle it, always: the reader's return, a failure, or an asynchronous
-- exception each end in 'settle', which marks the job done after its sink was called or suppressed.
runJob ∷ (∀ x. IO x → IO x) → ReadPool → Job → IO ()
runJob restore pool job = do
  outcome ← tryWithContext @SomeException $ restore $ do
    hookIssued (poolHooks pool) (jobKey job)
    withdrawn ← readTVarIO (jobState job) <&> \case JobIssued flag → flag; _ → False
    if withdrawn
      then pure Skipped
      else do
        found ← poolReader pool (jobKey job) (jobAllowance job)
        hookRead (poolHooks pool) (jobKey job)
        pure (Read found)
  case outcome of
    Right Skipped → settle pool job ReadAbandoned Nothing
    Right (Read (Right bytes)) → settle pool job (ReadSucceeded bytes) Nothing
    Right (Read (Left refusal)) → settle pool job (ReadFailed refusal) Nothing
    Left caught@(ExceptionWithContext _ failure)
      | Just (SomeAsyncException _) ← fromException failure → settle pool job ReadAbandoned (Just caught)
      | otherwise → settle pool job (ReadDefect failure) (Just caught)

-- | Hand the result to the sink unless interest was withdrawn, then mark the job done and release
-- the execution slot. @pending@ is the failure to rethrow after, once the job is settled.
--
-- The decision to deliver and the end of the job's claim on its slot are one transaction, taken
-- /before/ the sink is called: the consumer's reply may be accounted, and its slot released, as
-- soon as the sink has run, and the job must by then no longer need it. The job is not /retired/
-- until the sink has returned, so a consumer that reads retirement after withdrawing interest
-- never sees the work over while a worker still holds the buffer it is about to hand over.
settle ∷ ReadPool → Job → ReadResult → Maybe (ExceptionWithContext SomeException) → IO ()
settle pool job result pending = do
  deliver ← atomically $
    readTVar (jobState job) >>= \case
      JobIssued True → False <$ finish
      JobIssued False → do
        writeTVar (jobState job) JobDelivering
        st ← readTVar (poolState pool)
        writeTVar (poolState pool) st {psLive = psLive st - 1}
        pure True
      _ → pure False
  delivered ← tryWithContext @SomeException $ do
    when deliver (jobSink job result)
    hookSettled (poolHooks pool) (jobKey job)
  when deliver $ atomically $ do
    writeTVar (jobState job) JobDone
    st ← readTVar (poolState pool)
    writeTVar (poolState pool) st {psActive = psActive st - 1}
  case (pending, delivered) of
    (Just failure, Right ()) → rethrowIO failure
    (Nothing, Right ()) → pure ()
    (Nothing, Left sinkFailure) → rethrowIO sinkFailure
    (Just failure, Left sinkFailure) → do
      composed ← composeCleanup (Just failure) [("content read sink", sinkFailure)]
      rethrowIO (maybe failure id composed)
  where
    -- Interest was withdrawn before delivery: done at once, nothing to hand over.
    finish = do
      writeTVar (jobState job) JobDone
      st ← readTVar (poolState pool)
      writeTVar (poolState pool) st {psActive = psActive st - 1, psLive = psLive st - 1}

-- | Run an action; if it raises a synchronous exception, give it to the handler, which answers the
-- exception to raise (the same, or one that keeps the handler's own failure beside it).
onSynchronousFailure ∷ IO () → (ExceptionWithContext SomeException → IO (ExceptionWithContext SomeException)) → IO ()
onSynchronousFailure action handler =
  tryWithContext @SomeException action >>= \case
    Right () → pure ()
    Left caught@(ExceptionWithContext _ failure)
      | isAsynchronous failure → rethrowIO caught
      | otherwise → mask_ (handler caught) >>= rethrowIO

-- | The first defect: latch it with its context, refuse every later job, and tell every queued job
-- so that none stays pending. Answers the exception to raise: the defect itself, or, when telling a
-- queued job's sink raised, the defect with that failure kept beside it (also what the pool keeps).
latchFailure ∷ ReadPool → ExceptionWithContext SomeException → IO (ExceptionWithContext SomeException)
latchFailure pool caught@(ExceptionWithContext _ failure) = do
  withdrawn ← atomically $ do
    st ← readTVar (poolState pool)
    case psFailure st of
      Just _ → do
        -- Not the first: kept beside it, appended to the evidence as it now stands.
        appendEvidence pool "content read subsequent failure" caught
        pure Nothing
      Nothing → Just <$> withdrawQueue pool st {psFailure = Just caught}
  case withdrawn of
    Nothing → pure caught
    Just jobs →
      tellAll jobs (ReadDefect failure) >>= \case
        Nothing → pure caught
        Just notification → do
          atomically (appendEvidence pool "content read sink" notification)
          fromMaybe caught <$> composeCleanup (Just caught) [("content read sink", notification)]

-- | Close admission and withdraw what is queued, telling each job it was abandoned.
closePool ∷ ReadPool → IO ()
closePool pool = mask_ $ do
  withdrawn ← atomically $ do
    st ← readTVar (poolState pool)
    withdrawQueue pool st {psPhase = PoolClosed}
  tellAll withdrawn ReadAbandoned >>= maybe (pure ()) rethrowIO

-- | Empty the queue into the notifying state, in the same transaction that records the new state.
-- A withdrawn job is not retired until its sink has been told ('tellAll'); its claim on its slot
-- ends here, as a delivering job's does, because the sink may be accounted as soon as it has run.
withdrawQueue ∷ ReadPool → PoolState → STM [Job]
withdrawQueue pool st = do
  let jobs = Map.elems (psQueue st)
  forM_ jobs $ \job → writeTVar (jobState job) (JobNotifying False)
  writeTVar (poolState pool) st {psQueue = Map.empty, psLive = psLive st - length jobs}
  pure jobs

-- | Tell every job in order, each retired only after its own sink returned, and unless interest was
-- withdrawn first. Each is told whatever another's sink raised; the first failure is answered with
-- the others kept beside it.
tellAll ∷ [Job] → ReadResult → IO (Maybe (ExceptionWithContext SomeException))
tellAll jobs result = do
  outcomes ← forM jobs $ \job → do
    deliver ← atomically (readTVar (jobState job) <&> \case JobNotifying False → True; _ → False)
    told ← tryWithContext @SomeException (when deliver (jobSink job result))
    atomically (writeTVar (jobState job) JobWithdrawn)
    pure told
  case [failure | Left failure ← outcomes] of
    [] → pure Nothing
    first : others → do
      composed ← composeCleanup (Just first) [("content read sink", other) | other ← others]
      pure (Just (fromMaybe first composed))
