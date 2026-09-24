-- | Bounded capture of Vulkan validation diagnostics, drained into the
-- caller's logger by a worker the diagnostic lifetime owns.
--
-- A debug-utils messenger reports from inside Vulkan calls, on whatever thread
-- the driver or a layer is running, and under the backend's audited @unsafe@
-- recording imports it reports from a call that must not re-enter Haskell. So
-- the callback is C: 'captureCallback', with 'captureUserData' as its user
-- data. It copies a capped record into storage this lifetime owns, latches an
-- error before it attempts admission, counts what it drops or cuts, and
-- returns. It never allocates from the Haskell heap, waits for space, writes to
-- a sink, calls Vulkan, or raises.
--
-- A drain worker, in a foundation worker group this lifetime owns rather than
-- the application's, takes those records and hands them to the caller's logger
-- under 'diagnosticsComponent'. Latches and counters live in the storage
-- itself, so 'captureStatus' answers from any thread at any time, with the
-- worker slow, blocked, failed, or finished, and nothing the worker or a sink
-- does ever clears one.
--
-- 'withDiagnosticCapture' is the lifetime. Its body enables messengers, runs
-- every Vulkan operation that could report, and finishes the last
-- callback-producing destruction — @vkDestroyInstance@, whose create-info
-- messenger reports after the explicit messenger is gone — through
-- 'afterLastCallback', which is the only source of the 'Quiesced' evidence the
-- body must return. That destruction's return is what establishes quiescence:
-- Vulkan invokes a messenger's callback only from inside a Vulkan call, so once
-- the last call that could invoke it has returned, no invocation can be running
-- or begin. The capture cannot observe that from inside — an invocation that
-- has not executed its first instruction touches nothing — which is why it is
-- the owner's evidence rather than the capture's inference, and why a verdict
-- without it is not clean. The lifetime then, in this order and on every exit:
--
-- 1. closes admission and waits for every producer that has announced itself
--    inside the callback — announcing is the callback's first memory operation;
-- 2. asks the worker for its final drain and waits for its completion,
--    explicitly, rather than relying on the worker group's default drain;
-- 3. accounts for every admitted record the worker did not deliver, including
--    one it had taken when it was cancelled;
-- 4. frees the storage — unless the body retained it with 'retainStorage'
--    because a messenger that names it may still report — and only then
--    returns, or rethrows the body's failure unchanged.
--
-- What a producer touches before it knows admission is open — its
-- announcement, the close handshake, the latches and the counters — lives in a
-- slot of a fixed static table in the C capture, never on the heap, and the
-- user data names that slot and a generation rather than the storage. So a
-- report that has not even begun when admission closes, which the body's
-- contract rules out, is still memory-safe: it finds admission closed and
-- counts itself as a capture failure, outside the verdict, and 'captureStatus'
-- shows it until the slot serves another lifetime.
--
-- The result is a 'DiagnosticVerdict' covering every record offered before
-- step 1, including those delivered during instance destruction. A failed body
-- carries the verdict on its exception's context, readable with
-- 'diagnosticVerdict'; the body's failure is never replaced by a diagnostic
-- one. A sink failure is the consumer's own terminal status in the verdict,
-- never a replacement for the body's failure and never a reason to release
-- anything early. A sink that blocks forever keeps the lifetime in step 2 with
-- the storage and the logger still borrowed: there is no deadline and no
-- detach, and the process's external termination is the escape.
--
-- The logger is borrowed. This lifetime derives its own context from it,
-- writes to it only from the worker, and never flushes or closes it; it must
-- run inside the application's logging lifetime.
--
-- State, owner, readers and writers:
--
-- +--------------------+---------------------+----------------------------+---------------------------+---------------------------------+
-- | State              | Owner               | Writers                    | Readers                   | Lifetime and reset              |
-- +====================+=====================+============================+===========================+=================================+
-- | C storage: queue,  | this lifetime       | producers (any thread),    | the worker; the lifetime  | allocated at entry; freed in    |
-- | objects, text      |                     | the worker (consumption)   | after it                  | step 4 unless retained          |
-- +--------------------+---------------------+----------------------------+---------------------------+---------------------------------+
-- | C slot: latches,   | this lifetime, then | producers (any thread),    | the lifetime;             | static; claimed at entry, reset |
-- | counters, handshake| the next claimant   | the lifetime (close)       | 'captureStatus'           | only when claimed again         |
-- +--------------------+---------------------+----------------------------+---------------------------+---------------------------------+
-- | status snapshot    | this lifetime       | step 4, once, before free  | 'captureStatus' once the  | per lifetime                    |
-- |                    |                     |                            | slot serves another       |                                 |
-- +--------------------+---------------------+----------------------------+---------------------------+---------------------------------+
-- | phase              | this lifetime       | the lifetime's thread      | any thread                | per lifetime; only advances     |
-- +--------------------+---------------------+----------------------------+---------------------------+---------------------------------+
-- | taken and          | the worker          | the worker                 | any thread; the lifetime  | per lifetime; only grow         |
-- | delivered counts   |                     |                            | after the worker          |                                 |
-- +--------------------+---------------------+----------------------------+---------------------------+---------------------------------+
-- | wake and final     | this lifetime       | 'requestDrain'; the        | the worker                | per lifetime; final is set once |
-- | requests           |                     | lifetime (final)           |                           |                                 |
-- +--------------------+---------------------+----------------------------+---------------------------+---------------------------------+
module Hetoimasia.GPU.Vulkan.Diagnostics
  ( -- * Configuration
    CaptureConfig (..)
  , defaultCaptureConfig
  , CaptureConfigError (..)
  , LimitError (..)
  , validateCaptureConfig

    -- * The diagnostic lifetime
  , DiagnosticCapture
  , withDiagnosticCapture
  , Quiesced
  , afterLastCallback
  , captureUserData
  , CaptureCallback
  , captureCallback
  , requestDrain
  , retainStorage

    -- * Observation
  , CapturePhase (..)
  , capturePhase
  , CaptureStatus (..)
  , CaptureCounters (..)
  , captureStatus
  , deliveredCount

    -- * The verdict
  , DiagnosticVerdict (..)
  , ConsumerOutcome (..)
  , VerdictIssue (..)
  , verdictIssues
  , verdictClean
  , diagnosticVerdict
  , diagnosticVerdictInContext

    -- * Delivery
  , diagnosticsComponent
  , Severity (..)
  , severityLevel
  ) where

import Control.Concurrent (rtsSupportsBoundThreads)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , orElse
  , readTVar
  , readTVarIO
  , registerDelay
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , someExceptionContext
  , throwIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (ExceptionContext, addExceptionAnnotation, getExceptionAnnotations)
import Control.Monad (unless, when)
import Data.Bits (testBit, (.&.))
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import Data.Either (isRight)
import Data.Maybe (isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Text.Encoding.Error as Encoding
import Data.Word (Word32, Word64)
import Foreign.Ptr (Ptr)
import Numeric (showHex)

import Hetoimasia.Foundation.Log
  ( Component
  , LogLevel (..)
  , Logger
  , logEvent
  , unsafeComponent
  , withBreadcrumb
  )
import Hetoimasia.Foundation.Worker
  ( Completion (..)
  , Result (..)
  , StartOutcome (..)
  , StopToken
  , Worker
  , WorkerDefinition
  , awaitCompletion
  , awaitStopRequest
  , requestCancel
  , startWorker
  , stopRequested
  , withWorkerGroup
  , workerDefinition
  )
import Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Capture
  ( CaptureCallback
  , CapturedObject (..)
  , CapturedRecord (..)
  , Counter (..)
  , Latch (..)
  , LimitError (..)
  , Limits (..)
  , Severity (..)
  , Storage
  , captureCallback
  , checkLimits
  , closeStorage
  , SlotStatus (..)
  , createStorage
  , freeStorage
  , slotStatus
  , storageUserData
  , takeRecord
  )

-- Configuration --------------------------------------------------------------

-- | What one diagnostic lifetime is built with.
data CaptureConfig = CaptureConfig
  { captureQueueCapacity ∷ !Int
    -- ^ Records queued at once; 1,024 by default. A record offered while the
    -- queue is full is dropped and counted.
  , captureTextBudget ∷ !Int
    -- ^ Bytes of text copied per record, shared by the message id name, the
    -- message and every object name; 4,096 by default.
  , captureObjectLimit ∷ !Int
    -- ^ Object identifiers copied per record; 16 by default.
  , capturePollInterval ∷ !Int
    -- ^ Microseconds the worker waits for a wake-up before looking at the
    -- queue again; 2,000 by default. The producer cannot wake it — waking
    -- would mean running Haskell — so this bounds how long a record can sit
    -- queued while nothing else happens.
  }
  deriving (Eq, Show)

-- | The limits the design fixes as initial values, and a 2 ms poll.
defaultCaptureConfig ∷ CaptureConfig
defaultCaptureConfig =
  CaptureConfig
    { captureQueueCapacity = 1024
    , captureTextBudget = 4096
    , captureObjectLimit = 16
    , capturePollInterval = 2000
    }

-- | Why a configuration was rejected.
data CaptureConfigError
  = CaptureLimitRejected !LimitError
  | PollIntervalRejected !Int
  | CaptureRequiresThreadedRuntime
    -- ^ The worker's poll and the storage's close both need the threaded
    -- runtime; every native executable here is built with it.
  deriving (Eq, Show)

instance Exception CaptureConfigError

-- | Check a configuration without performing IO. 'withDiagnosticCapture' runs
-- this first and raises the rejection before anything is allocated.
--
-- Every limit must be at least one and fit the storage's 32-bit counts, and
-- the storage they describe must be representable in the sizes its allocation
-- is computed in; see 'LimitError'. An 'Int' is finite, so those bounds are the
-- whole of "positive and finite".
validateCaptureConfig ∷ CaptureConfig → Either CaptureConfigError CaptureConfig
validateCaptureConfig config = do
  _ ← either (Left . CaptureLimitRejected) Right (checkLimits (limitsOf config))
  when (capturePollInterval config < 1) $ Left (PollIntervalRejected (capturePollInterval config))
  pure config

limitsOf ∷ CaptureConfig → Limits
limitsOf config =
  Limits
    { limitQueueCapacity = captureQueueCapacity config
    , limitTextBudget = captureTextBudget config
    , limitObjectLimit = captureObjectLimit config
    }

-- The lifetime -----------------------------------------------------------------

-- | Where a lifetime is. Phases only advance.
data CapturePhase
  = PhaseCapturing
    -- ^ The body is running; producers may report and the worker drains.
  | PhaseClosed
    -- ^ Admission is closed, every producer has left, and the worker has been
    -- asked for its final drain. The storage and the logger are still borrowed.
  | PhaseJoined
    -- ^ The worker has completed and its outcome has been read.
  | PhaseReleased
    -- ^ The records have been freed, or deliberately retained.
  deriving (Eq, Ord, Show)

-- | One diagnostic lifetime's handle. It is valid inside the body it was
-- passed to; 'capturePhase', 'captureStatus' and 'deliveredCount' remain
-- answerable after the lifetime has ended.
data DiagnosticCapture = DiagnosticCapture
  { handleUserData ∷ !(Ptr ())
    -- ^ Names the storage's slot; safe to read status by at any time.
  , handleSnapshot ∷ !(TVar (Maybe CaptureStatus))
    -- ^ Written in step 4 before the storage is freed, and so before its slot
    -- can serve another lifetime.
  , handlePhase ∷ !(TVar CapturePhase)
  , handleTaken ∷ !(TVar Word64)
    -- ^ Records the worker has taken from the storage, delivered or not.
  , handleDelivered ∷ !(TVar Word64)
  , handleWake ∷ !(TVar Bool)
  , handleFinal ∷ !(TVar Bool)
  , handleRetained ∷ !(TVar Bool)
  , handleQuiesced ∷ !(TVar Bool)
    -- ^ Set by 'afterLastCallback' once the owner's last callback-producing
    -- destruction has returned.
  }

-- | Evidence, for one capture, that the last Vulkan call that could invoke its
-- callback has returned. Only 'afterLastCallback' makes one.
newtype Quiesced = Quiesced (Ptr ())

-- | Run the last destruction that could invoke this capture's callback — for
-- an instance, @vkDestroyInstance@ — and, once it has returned, record and
-- return the evidence that the callback is quiescent.
--
-- Call it from the code that owns that destruction, whether the body is
-- returning or unwinding: the lifetime also reads the record it leaves, so
-- quiescence established while a failure propagates still counts. If the
-- destruction throws, no evidence is recorded — a destroy that did not return
-- normally establishes nothing.
afterLastCallback ∷ DiagnosticCapture → IO () → IO Quiesced
afterLastCallback capture destruction = do
  destruction
  atomically (writeTVar (handleQuiesced capture) True)
  pure (Quiesced (handleUserData capture))

-- | The user data to register beside 'captureCallback' on every messenger:
-- the explicit one, and the one chained into @VkInstanceCreateInfo@.
--
-- It names a slot and a generation rather than memory, so it is safe to hand
-- the callback at any time; the storage behind it lives until the lifetime's
-- final step, which the body reaches only after its last callback-producing
-- destruction.
captureUserData ∷ DiagnosticCapture → Ptr ()
captureUserData = handleUserData

-- | Wake the worker now rather than at its next poll.
requestDrain ∷ DiagnosticCapture → IO ()
requestDrain capture = atomically (writeTVar (handleWake capture) True)

-- | Declare that a native object which registered this capture's callback may
-- outlive the body — a native owner that retained its instance, say, because
-- the evidence that destroying it is safe never arrived. The lifetime then
-- never frees the storage's records: they are released by process exit, and
-- the verdict says so. Calling it more than once is harmless.
retainStorage ∷ DiagnosticCapture → IO ()
retainStorage capture = atomically (writeTVar (handleRetained capture) True)

-- | The lifetime's phase.
capturePhase ∷ DiagnosticCapture → STM CapturePhase
capturePhase = readTVar . handlePhase

-- | How many records the worker has handed to the logger so far.
deliveredCount ∷ DiagnosticCapture → STM Word64
deliveredCount = readTVar . handleDelivered

-- | Run a body that owns a diagnostic capture, and finalize it on every exit.
--
-- See the module header for the order. The body runs with the caller's masking
-- state. Returns the body's result and the verdict; a body failure is rethrown
-- with its own type, value and context, and the verdict attached to that
-- context.
--
-- The configuration is validated first, so a rejected one raises
-- 'CaptureConfigError' before anything is allocated.
withDiagnosticCapture
  ∷ CaptureConfig → Logger → (DiagnosticCapture → IO (a, Quiesced)) → IO (a, DiagnosticVerdict)
withDiagnosticCapture config logger body = do
  valid ← either throwIO pure (validateCaptureConfig config)
  unless rtsSupportsBoundThreads (throwIO CaptureRequiresThreadedRuntime)
  mask $ \restore → do
    storage ← createStorage (limitsOf valid)
    capture ← newCapture storage
    finishedRef ← newIORef Nothing
    grouped ←
      trySome
        ( withWorkerGroup $ \group → do
            started ← startWorker group (drainWorker valid (scopedLogger logger) storage capture)
            worker ← case started of
              Started worker → pure worker
              StartupFailed _ completion → failedStartup completion
              StartRejected _ → error "withDiagnosticCapture: a group it just created refused a worker"
            outcome ← trySome (restore (body capture))
            finished ← finish storage capture worker outcome
            -- Kept outside the group: a cancellation during the group's own
            -- closing still leaves the lifetime a verdict to attach.
            writeIORef finishedRef (Just finished)
        )
    -- The group has drained: nothing of the worker's runs any more. What it
    -- took and did not deliver — discarded after a sink failure, or in hand
    -- when it was cancelled — and anything still queued were not delivered,
    -- and all of it is counted before the release.
    remaining ← countRemaining storage
    taken ← readTVarIO (handleTaken capture)
    delivered ← readTVarIO (handleDelivered capture)
    status ← uninterruptibleMask_ (release storage capture)
    reached ← readIORef finishedRef
    case reached of
      -- The body never ran, or finalization never completed: there is no
      -- verdict to give.
      Nothing → either rethrowIO (\() → error "withDiagnosticCapture: finalization left no result") grouped
      Just finished → do
        retained ← readTVarIO (handleRetained capture)
        recorded ← readTVarIO (handleQuiesced capture)
        -- Evidence for this capture: its own record, or a returned token that
        -- names it. A token another capture issued proves nothing here.
        let returned = case finishedOutcome finished of
              Right (_, Quiesced issuer) → issuer == handleUserData capture
              Left _ → False
            verdict =
              DiagnosticVerdict
                { verdictStatus = status
                , verdictDelivered = delivered
                , verdictUndelivered = (taken - delivered) + remaining
                , verdictConsumer = finishedConsumer finished
                , verdictStorageRetained = retained
                , verdictQuiescent = recorded || returned
                }
            attach (ExceptionWithContext context failure) =
              ExceptionWithContext (addExceptionAnnotation (VerdictAnnotation verdict) context) failure
        -- A cancellation during finalization, then one during the group's
        -- closing, then the body's own failure, then its result.
        case (finishedPending finished, either Just (const Nothing) grouped, finishedOutcome finished) of
          (Just cancellation, _, _) → rethrowIO (attach cancellation)
          (Nothing, Just late, _) → rethrowIO (attach late)
          (Nothing, Nothing, Left failure) → rethrowIO (attach failure)
          (Nothing, Nothing, Right (result, _)) → pure (result, verdict)

-- | The worker's startup is trivial, so this is a failure to fork or an
-- asynchronous exception; either is rethrown as itself.
failedStartup ∷ Completion r → IO a
failedStartup completion = case completionResult completion of
  Failed failure → rethrowIO failure
  Cancelled failure → rethrowIO failure
  Succeeded _ → error "withDiagnosticCapture: a worker that never started succeeded"

newCapture ∷ Storage → IO DiagnosticCapture
newCapture storage =
  DiagnosticCapture (storageUserData storage)
    <$> newTVarIO Nothing
    <*> newTVarIO PhaseCapturing
    <*> newTVarIO 0
    <*> newTVarIO 0
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO False

-- | What steps 1 and 2 leave for the rest of the lifetime.
data Finished a = Finished
  { finishedOutcome ∷ !(Either (ExceptionWithContext SomeException) a)
    -- ^ The body's own result or failure.
  , finishedConsumer ∷ !ConsumerOutcome
  , finishedPending ∷ !(Maybe (ExceptionWithContext SomeException))
    -- ^ The first cancellation delivered while waiting for the worker.
  }

-- | Steps 1 and 2, masked: close admission, ask for the final drain, and wait
-- for the worker. A cancellation delivered while waiting does not end the wait;
-- the first one is kept to rethrow and the worker is asked to stop delivering,
-- so a slow sink is abandoned while the storage it reads stays alive.
finish
  ∷ Storage
  → DiagnosticCapture
  → Worker DrainReport
  → Either (ExceptionWithContext SomeException) a
  → IO (Finished a)
finish storage capture worker outcome = do
  closeStorage storage
  atomically $ do
    writeTVar (handleFinal capture) True
    writeTVar (handlePhase capture) PhaseClosed
  pendingRef ← newIORef Nothing
  let await = do
        waited ← trySome (atomically (awaitCompletion worker))
        case waited of
          Right completion → pure completion
          Left failure@(ExceptionWithContext _ exception)
            | isAsynchronous exception → do
                modifyIORef' pendingRef (maybe (Just failure) Just)
                requestCancel worker
                await
            | otherwise → rethrowIO failure
  completion ← await
  atomically (writeTVar (handlePhase capture) PhaseJoined)
  pending ← readIORef pendingRef
  let consumer = case completionResult completion of
        Succeeded report → maybe ConsumerCompleted ConsumerSinkFailed (reportSinkFailure report)
        Failed failure → ConsumerFailed failure
        Cancelled failure → ConsumerCancelled failure
  pure
    Finished
      { finishedOutcome = outcome
      , finishedConsumer = consumer
      , finishedPending = pending
      }
  where
    isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

-- | Count, and discard, what nobody delivered. Only called once the worker is
-- terminal, so this is the storage's one consumer by then.
countRemaining ∷ Storage → IO Word64
countRemaining storage = go 0
  where
    go counted =
      takeRecord storage >>= \case
        Nothing → pure counted
        Just _ → go (counted + 1)

-- | Step 4. Close (again, harmlessly, for an exit that never reached the first
-- close), read the latches and counters the verdict reports and keep them as the
-- snapshot, then free the storage unless the body retained it. Bounded: it
-- waits only for producers that have announced themselves.
release ∷ Storage → DiagnosticCapture → IO CaptureStatus
release storage capture = do
  closeStorage storage
  status ← readStatus (storageUserData storage) >>= maybe (fail "release: a live storage's slot served another") pure
  atomically (writeTVar (handleSnapshot capture) (Just status))
  retained ← readTVarIO (handleRetained capture)
  unless retained (freeStorage storage)
  atomically (writeTVar (handlePhase capture) PhaseReleased)
  pure status

-- Observation ------------------------------------------------------------------

-- | The storage's saturating counters. Each stops at @maxBound@ rather than
-- wrapping.
data CaptureCounters = CaptureCounters
  { countOffered ∷ !Word64
    -- ^ Every report the callback received for this storage.
  , countAdmitted ∷ !Word64
    -- ^ Reports queued for the worker.
  , countDropped ∷ !Word64
    -- ^ Reports lost to a full queue.
  , countTruncated ∷ !Word64
    -- ^ Admitted reports cut to fit the text budget or the object limit.
  , countCaptureFailed ∷ !Word64
    -- ^ Reports that could not be captured at all.
  , countErrors ∷ !Word64
    -- ^ Error-severity reports, whatever became of them.
  }
  deriving (Eq, Show)

-- | What the storage says now.
data CaptureStatus = CaptureStatus
  { statusErrorLatched ∷ !Bool
    -- ^ An error-severity report arrived. Set before its admission was
    -- attempted, whatever the queue, the logger's filter, or the sink did.
  , statusCaptureFailureLatched ∷ !Bool
    -- ^ A report could not be captured at all.
  , statusCounters ∷ !CaptureCounters
  }
  deriving (Eq, Show)

-- | Read the latches and counters, with no worker involved, at any time. They
-- live in the storage's static slot, which is never freed: after the lifetime
-- has ended this still answers the live values — so a report that arrived after
-- the verdict was reached shows here as a capture failure — until the slot
-- serves another lifetime, and then the snapshot taken just before the free.
captureStatus ∷ DiagnosticCapture → IO CaptureStatus
captureStatus capture =
  readStatus (handleUserData capture) >>= \case
    Just status → pure status
    Nothing →
      -- The slot moved on, which it can only do after the free, which follows
      -- the snapshot.
      readTVarIO (handleSnapshot capture)
        >>= maybe (fail "captureStatus: a reclaimed slot left no snapshot") pure

readStatus ∷ Ptr () → IO (Maybe CaptureStatus)
readStatus userData =
  fmap describe <$> slotStatus userData
  where
    describe status =
      let counter which = slotCounters status !! fromEnum which
          latched which = slotLatches status !! fromEnum which
       in CaptureStatus
            { statusErrorLatched = latched ErrorLatch
            , statusCaptureFailureLatched = latched CaptureFailureLatch
            , statusCounters =
                CaptureCounters
                  { countOffered = counter Offered
                  , countAdmitted = counter Admitted
                  , countDropped = counter Dropped
                  , countTruncated = counter Truncated
                  , countCaptureFailed = counter CaptureFailed
                  , countErrors = counter Errors
                  }
            }

-- The verdict -------------------------------------------------------------------

-- | How the drain worker ended.
data ConsumerOutcome
  = ConsumerCompleted
    -- ^ It drained everything after admission closed.
  | ConsumerSinkFailed !(ExceptionWithContext SomeException)
    -- ^ A synchronous logger or sink failure stopped delivery. It went on
    -- accounting for what it could no longer deliver, and reported the
    -- failure only here.
  | ConsumerFailed !(ExceptionWithContext SomeException)
  | ConsumerCancelled !(ExceptionWithContext SomeException)
  deriving (Show)

-- | Everything one lifetime can say about its diagnostics once the last
-- callback has been accounted for.
data DiagnosticVerdict = DiagnosticVerdict
  { verdictStatus ∷ !CaptureStatus
    -- ^ The latches and counters after admission closed.
  , verdictDelivered ∷ !Word64
    -- ^ Records handed to the logger.
  , verdictUndelivered ∷ !Word64
    -- ^ Admitted records that never reached the logger.
  , verdictConsumer ∷ !ConsumerOutcome
  , verdictQuiescent ∷ !Bool
    -- ^ The owner established that no callback could still run, through
    -- 'afterLastCallback'.
  , verdictStorageRetained ∷ !Bool
    -- ^ The body retained the storage for a native object that may outlive it.
  }
  deriving (Show)

-- | One reason a verdict is not clean.
data VerdictIssue
  = ErrorLatched
  | CaptureFailureLatched
  | RecordsDropped !Word64
  | RecordsTruncated !Word64
  | CaptureFailures !Word64
  | RecordsUndelivered !Word64
  | RecordsUnaccounted !Word64 !Word64
    -- ^ Admitted, and delivered plus undelivered, disagree.
  | CounterSaturated
    -- ^ A counter reached its ceiling, so no count can be trusted.
  | ConsumerUnsuccessful
    -- ^ The worker's sink failed, or the worker failed or was cancelled.
  | QuiescenceUnproven
    -- ^ The owner never established that its last callback-producing
    -- destruction had returned, so a callback may still have been on its way.
  | StorageRetained
    -- ^ A registering native object may still report into the storage.
  deriving (Eq, Show)

-- | Every reason the evidence is incomplete or reports a failure, in a fixed
-- order. Warnings are not among them: they are diagnostics, not failures.
verdictIssues ∷ DiagnosticVerdict → [VerdictIssue]
verdictIssues verdict =
  concat
    [ [ErrorLatched | statusErrorLatched status]
    , [CaptureFailureLatched | statusCaptureFailureLatched status]
    , [RecordsDropped (countDropped counters) | countDropped counters > 0]
    , [RecordsTruncated (countTruncated counters) | countTruncated counters > 0]
    , [CaptureFailures (countCaptureFailed counters) | countCaptureFailed counters > 0]
    , [RecordsUndelivered (verdictUndelivered verdict) | verdictUndelivered verdict > 0]
    , [ RecordsUnaccounted (countAdmitted counters) accounted
      | toInteger (countAdmitted counters) /= toInteger (verdictDelivered verdict) + toInteger (verdictUndelivered verdict)
      ]
    , [CounterSaturated | any (== maxBound) (countersOf counters)]
    , [ConsumerUnsuccessful | not (consumerCompleted (verdictConsumer verdict))]
    , [QuiescenceUnproven | not (verdictQuiescent verdict)]
    , [StorageRetained | verdictStorageRetained verdict]
    ]
  where
    status = verdictStatus verdict
    counters = statusCounters status
    accounted = verdictDelivered verdict + verdictUndelivered verdict
    countersOf c =
      [countOffered c, countAdmitted c, countDropped c, countTruncated c, countCaptureFailed c, countErrors c]
    consumerCompleted = \case
      ConsumerCompleted → True
      _ → False

-- | No errors, no loss, no truncation, no capture failure, every record
-- delivered, and a consumer that completed.
verdictClean ∷ DiagnosticVerdict → Bool
verdictClean = null . verdictIssues

newtype VerdictAnnotation = VerdictAnnotation DiagnosticVerdict

instance ExceptionAnnotation VerdictAnnotation where
  displayExceptionAnnotation (VerdictAnnotation verdict) =
    "diagnostic verdict: "
      <> case verdictIssues verdict of
        [] → "clean"
        issues → intercalate ", " (map show issues)

-- | The verdict a failed lifetime attached to its body's failure.
diagnosticVerdict ∷ SomeException → Maybe DiagnosticVerdict
diagnosticVerdict = diagnosticVerdictInContext . someExceptionContext

-- | The same, from an exception's context.
diagnosticVerdictInContext ∷ ExceptionContext → Maybe DiagnosticVerdict
diagnosticVerdictInContext context =
  listToMaybe [verdict | VerdictAnnotation verdict ← getExceptionAnnotations context]

-- The worker ----------------------------------------------------------------------

-- | The component every delivered record carries.
diagnosticsComponent ∷ Component
diagnosticsComponent = unsafeComponent "gpu.vulkan.diagnostics"

-- | The level a record is delivered at. Info and verbose reports are the
-- loader's and the layers' running commentary, so they are 'Debug' detail for
-- someone investigating this component rather than lifecycle 'Info'.
severityLevel ∷ Severity → LogLevel
severityLevel = \case
  SeverityError → Error
  SeverityWarning → Warning
  SeverityInfo → Debug
  SeverityVerbose → Debug
  SeverityUnclassified _ → Warning

scopedLogger ∷ Logger → Logger
scopedLogger = withBreadcrumb "vulkan-diagnostics"

-- | How a worker that finished normally ended. Its progress is in the
-- capture's taken and delivered counts, which a cancelled worker leaves too.
newtype DrainReport = DrainReport
  { reportSinkFailure ∷ Maybe (ExceptionWithContext SomeException)
  }

-- | Drain the storage until the lifetime asks for the final drain, then drain
-- once more and return. The final request is read before the pass that follows
-- it, and admission closed before the request was made, so that pass sees every
-- record there will ever be.
--
-- A synchronous failure delivering a record is the sink's: delivery stops, the
-- failure is kept for the report, and every later record is still taken and
-- counted. It is never logged, since the logger that would carry it is the one
-- that failed. Anything asynchronous ends the worker as a cancellation.
drainWorker ∷ CaptureConfig → Logger → Storage → DiagnosticCapture → WorkerDefinition DrainReport
drainWorker config logger storage capture =
  workerDefinition "gpu.vulkan.diagnostics" (\_ → pure ()) (\token () → run token)
  where
    run token = do
      state ← newIORef (DrainReport Nothing)
      let pass = do
            -- Taking a record and counting it as taken are one step, so a
            -- cancellation cannot leave a record that is in neither the queue
            -- nor the count. Nothing in it is interruptible.
            next ← mask_ $ do
              taken ← takeRecord storage
              when (isJust taken) (atomically (modifyTVar' (handleTaken capture) (+ 1)))
              pure taken
            case next of
              Nothing → pure ()
              Just record → do
                current ← readIORef state
                case reportSinkFailure current of
                  -- Taken, counted, and not delivered: accounted as undelivered.
                  Just _ → pure ()
                  Nothing → do
                    -- Delivering and counting the delivery are one step: the
                    -- sink's own blocking stays interruptible, so a cancellation
                    -- still reaches a stuck sink, but none can land between a
                    -- write that completed and its count.
                    delivered ← mask_ $ do
                      result ← trySome (deliver logger record)
                      when (isRight result) (atomically (modifyTVar' (handleDelivered capture) (+ 1)))
                      pure result
                    case delivered of
                      Right () → pure ()
                      Left failure@(ExceptionWithContext _ exception)
                        | isJust (fromException exception ∷ Maybe SomeAsyncException) → rethrowIO failure
                        | otherwise → writeIORef state (DrainReport (Just failure))
                pass
          loop = do
            final ← readTVarIO (handleFinal capture)
            stopping ← atomically (stopRequested token)
            pass
            if final || stopping
              then readIORef state
              else do
                wait token
                loop
      loop
    wait ∷ StopToken → IO ()
    wait token = do
      timer ← registerDelay (capturePollInterval config)
      atomically $
        (readTVar (handleFinal capture) >>= check)
          `orElse` (readTVar (handleWake capture) >>= check >> writeTVar (handleWake capture) False)
          `orElse` awaitStopRequest token
          `orElse` (readTVar timer >>= check)

-- | Catch everything, synchronous or not, with its context.
trySome ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
trySome = tryWithContext

-- | Hand one record to the logger.
deliver ∷ Logger → CapturedRecord → IO ()
deliver logger record =
  logEvent logger (severityLevel (recordSeverity record)) diagnosticsComponent "Vulkan diagnostic" (recordFields record)

recordFields ∷ CapturedRecord → [(Text, Text)]
recordFields record =
  [ ("severity", describeSeverity (recordSeverity record))
  , ("types", describeTypes (recordTypes record))
  , ("message.number", Text.pack (show (recordIdNumber record)))
  , ("text", decode (recordMessage record))
  ]
    <> [("message.id", decode name) | Just name ← [recordIdName record]]
    <> [("objects", Text.pack (show (recordObjectsReported record))) | recordObjectsReported record > 0]
    <> concat (zipWith objectFields [1 ∷ Int ..] (recordObjects record))
    <> [("truncated", "true") | recordTruncated record]
  where
    objectFields index object =
      let key = "object." <> Text.pack (show index)
       in (key, Text.pack (show (objectType object)) <> ":0x" <> Text.pack (showHex (objectHandle object) ""))
            : [(key <> ".name", decode name) | Just name ← [objectName object]]
    decode = Encoding.decodeUtf8With Encoding.lenientDecode

describeSeverity ∷ Severity → Text
describeSeverity = \case
  SeverityError → "error"
  SeverityWarning → "warning"
  SeverityInfo → "info"
  SeverityVerbose → "verbose"
  SeverityUnclassified bits → "0x" <> Text.pack (showHex bits "")

describeTypes ∷ Word32 → Text
describeTypes bits
  | null named && unknown == 0 = "none"
  | otherwise = Text.intercalate "," (named <> ["0x" <> Text.pack (showHex unknown "") | unknown /= 0])
  where
    known = [(0, "general"), (1, "validation"), (2, "performance"), (3, "device-address-binding")]
    named = [name | (bit, name) ← known, testBit bits bit]
    unknown = bits .&. complementKnown
    complementKnown = 0xFFFFFFF0
