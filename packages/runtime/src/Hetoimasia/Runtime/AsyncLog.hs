-- | An optional bounded asynchronous adapter over a borrowed synchronous
-- 'LogSink'.
--
-- The foundation's sinks write and flush on the emitting thread, so one blocked
-- handle write stalls whatever turn emitted it. This adapter takes that I/O off
-- the producers: 'withAsyncLogAdapter' borrows an existing sink and, for the
-- duration of an explicit 'IO' callback, lends back an adapter 'LogSink' plus a
-- handle for status and flushing. Nothing about 'Hetoimasia.Foundation.Log'
-- changes — existing sinks, loggers, and callers keep their synchronous
-- semantics — and an application opts in by injecting a logger built over
-- 'adapterSink' instead of over the borrowed sink.
--
-- This is not the Vulkan native-capture path. That capture is C-only, owned by
-- the graphics backend, and never reached through this adapter.
--
-- __Admission.__ The adapter sink's write prepares a bounded copy of the entry
-- on the producer thread, then enqueues it in one non-blocking transaction. It
-- never waits for queue space and never falls back to writing through the
-- borrowed sink itself, so a normal return proves neither admission nor
-- delivery: 'adapterStatus' is the only account of what happened.
--
-- __What a queued record retains.__ Every textual member the adapter keeps —
-- message, component, field keys and values, breadcrumbs, thread, and source
-- text — is copied at admission, so a short slice cannot hold an oversized
-- producer buffer alive, and the copy is completed and forced before the record
-- is published to the queue. Their UTF-8 byte lengths, plus the truncation
-- marker when one is present, are summed against one per-record budget:
-- 'asyncTextBudget', which defaults to 4,096 bytes and accepts 256 through
-- 65,536. That bound is on retained text; it claims nothing about Haskell
-- object overhead. A record keeps at most 'maxRetainedFields' field entries and
-- 'maxRetainedBreadcrumbs' breadcrumbs, counting empty ones; on a truncated
-- record the marker is one of those field entries, so the total never exceeds
-- the bound.
--
-- __Truncation.__ An entry over a bound is never rejected. What does not fit is
-- shortened or omitted and the record carries the reserved 'truncationField'
-- marker naming the affected categories and their counts; an oversized
-- component becomes 'truncationComponent'. The marker's own maximum size is
-- reserved inside the budget, so even at the 256-byte minimum a record is
-- admitted with its marker, with the message reduced as far as empty text.
--
-- __Loss.__ A record arriving at a full queue is discarded and counted by
-- severity. Records still queued when the writer is gone are counted as
-- unattempted-abandoned. A record whose write failed, or was interrupted in
-- flight, is counted as exactly that and is never replayed and never reported
-- as definitely undelivered.
--
-- __The writer.__ It dequeues in admission order, formats, and writes through
-- the borrowed sink. A synchronous failure of a write, or of a flush, latches
-- on the adapter and terminates the writer: nothing after it is attempted, and
-- the failure is never reported back through the writer itself. A latched
-- failure is reported through 'adapterStatus' and through the flush barrier; it
-- never becomes an exception the adapter raises on its own account, and it
-- never replaces an application failure.
--
-- __Flushing.__ 'flushAdapter' is a precise barrier: every record admitted
-- before the request is written before the borrowed sink's flush is attempted,
-- and records admitted after it do not extend it. It reports a typed
-- 'FlushOutcome' rather than waiting forever — a waiter observes writer
-- termination — and a successful barrier resets no counter. The adapter sink's
-- own flush is that same barrier, raising 'AsyncLogFlushFailure' for an
-- unsuccessful result, so 'Hetoimasia.Foundation.Log.flushLogger' over an
-- adapter logger behaves like a flush of any other sink. Control requests and
-- their waiter registrations have their own bound, 'asyncControlCapacity',
-- covering pending requests as well: an excess request fails with
-- 'FlushRejected' without waiting for record-queue space, and cancelling a
-- waiter releases its registration. That bound covers a request the writer has
-- taken and not yet settled as well as a registration still waiting, and
-- 'statusControlPending' accounts for both.
--
-- __Lifetime.__ 'withAsyncLogAdapter' must enclose
-- 'Hetoimasia.Runtime.Logging.withLoggingLifetime', so it outlives every
-- producer, graphics teardown, and terminal report. Once the callback has
-- returned or thrown, admission stops, the writer drains what is left, and the
-- adapter joins it before ending its borrow. The borrowed sink's resources stay
-- the caller's: the adapter never closes them. It adds no second final flush
-- and never retries a failed one, so the logging lifetime keeps its own
-- final-flush and primary-failure precedence.
--
-- Under cancellation the adapter requests the writer's cancellation and then
-- performs a protected drain with the borrowed sink still live, exactly as
-- 'Hetoimasia.Foundation.Worker' drains a group: a further asynchronous
-- exception does not end that drain and does not release the borrow early, and
-- the original outcome propagates unchanged. Cancellation need not flush, and
-- the backlog is accounted as unattempted-abandoned. A write blocked in an
-- interruptible operation ends promptly once cancellation is delivered; an
-- uncancellable sink, such as a foreign call, can hold the lifetime open
-- indefinitely. The writer is never detached, no competing write or flush is
-- run to force progress, there is no deadline, and no sink I/O runs in an
-- uninterruptible release.
--
-- See @docs/logging.md@, \"Asynchronous adapter\", for the same contract in
-- prose, including every piece of state and its owner.
module Hetoimasia.Runtime.AsyncLog
  ( -- * Configuration
    AsyncLogConfig (..)
  , defaultAsyncLogConfig
  , AsyncLogConfigError (..)
  , validateAsyncLogConfig
  , minimumTextBudget
  , maximumTextBudget
  , maxRetainedFields
  , maxRetainedBreadcrumbs
  , truncationComponent
  , truncationField

    -- * The adapter lifetime
  , AsyncLogAdapter
  , withAsyncLogAdapter
  , adapterSink
  , AsyncLogWriterUnavailable (..)

    -- * Flushing
  , FlushOutcome (..)
  , flushAdapter
  , AsyncLogFlushFailure (..)

    -- * Status
  , AsyncLogStatus (..)
  , adapterStatus
  , adapterStatusSTM
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVar
  , newTVarIO
  , readTVar
  , retry
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , displayException
  , evaluate
  , finally
  , fromException
  , mask
  , onException
  , rethrowIO
  , throwIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (when)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Sequence (Seq, ViewL (EmptyL, (:<)), (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Foreign (lengthWord8)
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , LogLevel
  , LogSink
  , SourceLocation (..)
  , callbackSinkWith
  , componentText
  , flushSink
  , mkComponent
  , unsafeComponent
  , writeEntry
  )
import Hetoimasia.Foundation.Resource (Scoped)
import Hetoimasia.Foundation.Worker
  ( StartOutcome (Started, StartRejected, StartupFailed)
  , WorkerDefinition
  , startWorker
  , withWorkerGroup
  , workerDefinition
  )

-- Configuration ---------------------------------------------------------------

-- | What an adapter bounds. Every field is validated by
-- 'validateAsyncLogConfig' before a writer starts.
data AsyncLogConfig = AsyncLogConfig
  { asyncQueueCapacity ∷ !Int
    -- ^ Records the queue holds before admission starts discarding, at least
    -- one. Defaults to 1,024.
  , asyncTextBudget ∷ !Int
    -- ^ The per-record total of retained UTF-8 text bytes, from
    -- 'minimumTextBudget' through 'maximumTextBudget'. Defaults to 4,096.
  , asyncControlCapacity ∷ !Int
    -- ^ Concurrent control requests the adapter retains, at least one.
    -- Defaults to 16.
  }
  deriving (Eq, Show)

-- | 1,024 records, a 4,096-byte retained-text budget, and 16 control requests.
defaultAsyncLogConfig ∷ AsyncLogConfig
defaultAsyncLogConfig = AsyncLogConfig
  { asyncQueueCapacity = 1024
  , asyncTextBudget = 4096
  , asyncControlCapacity = 16
  }

-- | The smallest retained-text budget an adapter accepts. The truncation
-- marker's maximum size and 'truncationComponent' both fit inside it, so a
-- record is still admitted here.
minimumTextBudget ∷ Int
minimumTextBudget = 256

-- | The largest retained-text budget an adapter accepts.
maximumTextBudget ∷ Int
maximumTextBudget = 65536

-- | Field entries one queued record retains, counting entries with empty text.
-- On a truncated record the adapter's own 'truncationField' marker is one of
-- them, so at most one fewer producer field survives there.
maxRetainedFields ∷ Int
maxRetainedFields = 64

-- | Breadcrumbs one queued record retains, counting empty ones.
maxRetainedBreadcrumbs ∷ Int
maxRetainedBreadcrumbs = 32

-- | Which configured bound was out of range, with the value that was rejected.
data AsyncLogConfigError
  = QueueCapacityRejected !Int
  | TextBudgetRejected !Int
  | ControlCapacityRejected !Int
  deriving (Eq, Show)

instance Exception AsyncLogConfigError

-- | Check every bound without performing IO. 'withAsyncLogAdapter' runs this
-- first and raises the rejection synchronously, before any writer exists, so an
-- out-of-range value is never a latched writer failure.
validateAsyncLogConfig ∷ AsyncLogConfig → Either AsyncLogConfigError AsyncLogConfig
validateAsyncLogConfig config
  | asyncQueueCapacity config < 1 = Left (QueueCapacityRejected (asyncQueueCapacity config))
  | budget < minimumTextBudget || budget > maximumTextBudget = Left (TextBudgetRejected budget)
  | asyncControlCapacity config < 1 = Left (ControlCapacityRejected (asyncControlCapacity config))
  | otherwise = Right config
  where
    budget = asyncTextBudget config

-- Truncation ------------------------------------------------------------------

-- | The valid component a record carries when its own component does not fit.
truncationComponent ∷ Component
truncationComponent = unsafeComponent "log.truncated"

-- | The reserved field key carrying the truncation marker. A producer field of
-- this name is the adapter's to write: it is removed at admission, and its
-- removal is itself counted as a dropped field.
truncationField ∷ Text
truncationField = "log.truncated"

-- | The marker's largest rendered size in bytes, key included, reserved inside
-- the budget whenever a record is truncated. Each count renders in at most five
-- bytes, clamped to @9999+@ beyond four digits.
markerReserve ∷ Int
markerReserve = 64

-- | Which categories a record lost text from, and how much.
data Truncation = Truncation
  { lostMessage ∷ !Bool
  , lostComponent ∷ !Bool
  , lostFields ∷ !Int
  , lostBreadcrumbs ∷ !Int
  , lostThread ∷ !Bool
  , lostSource ∷ !Bool
  }

noTruncation ∷ Truncation
noTruncation = Truncation False False 0 0 False False

truncated ∷ Truncation → Bool
truncated note =
  lostMessage note
    || lostComponent note
    || lostFields note > 0
    || lostBreadcrumbs note > 0
    || lostThread note
    || lostSource note

-- | The marker's value: the affected categories in a fixed order, with the
-- dropped counts for the two collections.
renderMarker ∷ Truncation → Text
renderMarker note = Text.intercalate "," (concat parts)
  where
    parts =
      [ ["msg" | lostMessage note]
      , ["cmp" | lostComponent note]
      , ["fields=" <> count (lostFields note) | lostFields note > 0]
      , ["crumbs=" <> count (lostBreadcrumbs note) | lostBreadcrumbs note > 0]
      , ["thread" | lostThread note]
      , ["source" | lostSource note]
      ]
    count value
      | value > 9999 = "9999+"
      | otherwise = Text.pack (show value)

-- Status ----------------------------------------------------------------------

-- | What the adapter has accounted for. Every counter is cumulative: a
-- successful flush barrier resets none of them.
data AsyncLogStatus = AsyncLogStatus
  { statusAdmitted ∷ !Int
    -- ^ Records placed on the queue.
  , statusWritten ∷ !Int
    -- ^ Records the borrowed sink's write returned successfully for.
  , statusTruncated ∷ !Int
    -- ^ Admitted records carrying a truncation marker.
  , statusDropped ∷ !(Map LogLevel Int)
    -- ^ Records discarded because the queue was full, by severity.
  , statusRefused ∷ !Int
    -- ^ Records offered after admission had stopped.
  , statusFailedWrites ∷ !Int
    -- ^ Record writes that raised synchronously. Delivery is unknown: the sink
    -- may have written part of the record. Never a flush failure.
  , statusInterruptedWrites ∷ !Int
    -- ^ Record writes ended by an asynchronous exception in flight. Delivery is
    -- unknown for the same reason.
  , statusAbandoned ∷ !Int
    -- ^ Records still queued when the writer was gone, never attempted.
  , statusControlPending ∷ !Int
    -- ^ Control requests the adapter still retains: those waiting, and one the
    -- writer has taken and not yet settled. Never above
    -- 'asyncControlCapacity'.
  , statusWriterFailure ∷ !(Maybe Text)
    -- ^ The latched synchronous failure of a write or a flush, if one
    -- happened, rendered with 'displayException'.
  , statusWriterTerminated ∷ !Bool
    -- ^ Whether the writer has published its terminal state. Independent of
    -- 'statusWriterFailure': a writer that drained and stopped is terminal with
    -- no failure.
  }
  deriving (Eq, Show)

-- Flushing ---------------------------------------------------------------------

-- | What a flush barrier reported.
data FlushOutcome
  = FlushCompleted
    -- ^ Every record admitted before the request was written, and the borrowed
    -- sink's flush returned.
  | FlushRejected
    -- ^ The control bound was already reached. Nothing was registered and
    -- nothing waited.
  | FlushWriterFailed !Text
    -- ^ The writer had latched, or latched during this barrier, the rendered
    -- synchronous failure of a write or a flush.
  | FlushWriterStopped
    -- ^ The writer was terminal without a latched failure, so the barrier could
    -- not complete.
  deriving (Eq, Show)

-- | The exception an adapter sink's flush raises for an unsuccessful barrier,
-- so a flush of an adapter logger fails like a flush of any other sink.
newtype AsyncLogFlushFailure = AsyncLogFlushFailure FlushOutcome
  deriving (Eq, Show)

instance Exception AsyncLogFlushFailure

-- | Raised by 'withAsyncLogAdapter' when its group could not start a writer.
-- Nothing was borrowed and no record was accepted.
data AsyncLogWriterUnavailable = AsyncLogWriterUnavailable
  deriving (Eq, Show)

instance Exception AsyncLogWriterUnavailable

-- State ------------------------------------------------------------------------

-- | One pending control request and the cell its caller waits on.
data Waiter = Waiter
  { waiterId ∷ !Int
  , waiterBarrier ∷ !Int
    -- ^ The number of dequeued records the writer must reach before the
    -- borrowed flush is attempted for this waiter.
  , waiterOutcome ∷ !(TVar (Maybe FlushOutcome))
  }

data WriterState
  = WriterRunning
  | WriterTerminal
  deriving (Eq)

-- | Every mutable field of one adapter, in one transactional cell.
data AdapterState = AdapterState
  { stateQueue ∷ !(Seq LogEntry)
  , stateQueued ∷ !Int
  , stateAdmitting ∷ !Bool
  , stateAdmittedSeq ∷ !Int
  , stateDequeuedSeq ∷ !Int
  , stateControl ∷ !(Seq Waiter)
  , stateInFlight ∷ !(Maybe Waiter)
    -- ^ The request the writer has taken and not yet settled. It is still
    -- retained, so it still counts against 'stateControlCount'.
  , stateControlCount ∷ !Int
  , stateNextRequest ∷ !Int
  , stateWriter ∷ !WriterState
  , stateLatched ∷ !(Maybe Text)
  , stateCounters ∷ !Counters
  }

data Counters = Counters
  { countAdmitted ∷ !Int
  , countWritten ∷ !Int
  , countTruncated ∷ !Int
  , countDropped ∷ !(Map LogLevel Int)
  , countRefused ∷ !Int
  , countFailedWrites ∷ !Int
  , countInterruptedWrites ∷ !Int
  , countAbandoned ∷ !Int
  }

emptyCounters ∷ Counters
emptyCounters = Counters 0 0 0 Map.empty 0 0 0 0

initialState ∷ AdapterState
initialState = AdapterState
  { stateQueue = Seq.empty
  , stateQueued = 0
  , stateAdmitting = True
  , stateAdmittedSeq = 0
  , stateDequeuedSeq = 0
  , stateControl = Seq.empty
  , stateInFlight = Nothing
  , stateControlCount = 0
  , stateNextRequest = 0
  , stateWriter = WriterRunning
  , stateLatched = Nothing
  , stateCounters = emptyCounters
  }

-- | The adapter's own state and the sink it borrows.
data Adapter = Adapter
  { adapterSettings ∷ !AsyncLogConfig
  , adapterBorrowed ∷ !LogSink
  , adapterCell ∷ !(TVar AdapterState)
  }

-- | The handle a lifetime lends its callback: the adapter sink to inject, and
-- the status and flush operations. Its representation is not exported, so the
-- sink beside a status can only be the one this lifetime created.
data AsyncLogAdapter = AsyncLogAdapter
  { adapterCore ∷ !Adapter
  , adapterSink ∷ LogSink
    -- ^ The sink to build the opted-in logger over. Every write through it is
    -- an admission; its flush is 'flushAdapter'.
  }

-- The lifetime ------------------------------------------------------------------

-- | Borrow a synchronous sink for the duration of a callback, lending an
-- adapter handle over it.
--
-- The configuration is validated first: an out-of-range bound is raised here,
-- synchronously, before a writer exists. The module header describes admission,
-- retention, loss, flushing, and the shutdown this performs once the callback
-- has returned or thrown.
withAsyncLogAdapter ∷ AsyncLogConfig → LogSink → (AsyncLogAdapter → IO a) → IO a
withAsyncLogAdapter config borrowed body = do
  validated ← either throwIO pure (validateAsyncLogConfig config)
  cell ← newTVarIO initialState
  let core = Adapter validated borrowed cell
      handle = AsyncLogAdapter core (callbackSinkWith (admit core) (flushThrough core))
  run core handle `finally` uninterruptibleMask_ (atomically (abandonBacklog cell))
  where
    run core handle = withWorkerGroup $ \group → do
      started ← startWorker group (writerDefinition core)
      case started of
        Started _ → pure ()
        StartupFailed _ _ → throwIO AsyncLogWriterUnavailable
        StartRejected _ → throwIO AsyncLogWriterUnavailable
      body handle `finally` uninterruptibleMask_ (atomically (stopAdmission (adapterCell core)))

-- | Close admission. The writer stops once it has drained what is queued.
stopAdmission ∷ TVar AdapterState → STM ()
stopAdmission cell = do
  state ← readTVar cell
  writeTVar cell state { stateAdmitting = False }

-- | Account every record the writer never attempted. Run once the writer is
-- terminal, after the group has drained.
abandonBacklog ∷ TVar AdapterState → STM ()
abandonBacklog cell = do
  state ← readTVar cell
  let counters = stateCounters state
  writeTVar cell state
    { stateQueue = Seq.empty
    , stateQueued = 0
    , stateCounters = counters { countAbandoned = countAbandoned counters + stateQueued state }
    }

-- Admission ---------------------------------------------------------------------

-- | Prepare a bounded copy on the producer thread, then enqueue it in one
-- transaction that never retries.
admit ∷ Adapter → LogEntry → IO ()
admit adapter entry = do
  let (prepared, note) = boundEntry (asyncTextBudget (adapterSettings adapter)) entry
  -- The whole retained payload is completed here, so nothing published to the
  -- queue is a deferred copy over the producer's own buffers.
  published ← evaluate (forceEntry prepared)
  atomically (enqueue (asyncQueueCapacity (adapterSettings adapter)) published (truncated note) cell)
  where
    cell = adapterCell adapter

enqueue ∷ Int → LogEntry → Bool → TVar AdapterState → STM ()
enqueue capacity entry wasTruncated cell = do
  state ← readTVar cell
  let counters = stateCounters state
  writeTVar cell $ case () of
    ()
      | not (stateAdmitting state) →
          state { stateCounters = counters { countRefused = countRefused counters + 1 } }
      | stateQueued state >= capacity →
          state
            { stateCounters = counters
                { countDropped =
                    Map.insertWith (+) (entryLevel entry) 1 (countDropped counters)
                }
            }
      | otherwise →
          state
            { stateQueue = stateQueue state |> entry
            , stateQueued = stateQueued state + 1
            , stateAdmittedSeq = stateAdmittedSeq state + 1
            , stateCounters = counters
                { countAdmitted = countAdmitted counters + 1
                , countTruncated = countTruncated counters + (if wasTruncated then 1 else 0)
                }
            }

-- The writer ----------------------------------------------------------------------

-- | What the writer does next. The queue and the control requests are one
-- ordered decision, so a satisfied barrier runs before later records and a
-- record runs before an unsatisfied barrier.
data Work
  = WriteRecord !LogEntry
  | RunBarrier !Waiter
  | WriterDone

nextWork ∷ TVar AdapterState → STM Work
nextWork cell = do
  state ← readTVar cell
  case Seq.viewl (stateControl state) of
    waiter :< rest
      | waiterBarrier waiter <= stateDequeuedSeq state → do
          -- Taken, not released: the request is retained until it settles, so
          -- a barrier the borrowed flush is still inside keeps its slot.
          writeTVar cell state { stateControl = rest, stateInFlight = Just waiter }
          pure (RunBarrier waiter)
    _ → case Seq.viewl (stateQueue state) of
      entry :< rest → do
        writeTVar cell state
          { stateQueue = rest
          , stateQueued = stateQueued state - 1
          , stateDequeuedSeq = stateDequeuedSeq state + 1
          }
        pure (WriteRecord entry)
      EmptyL
        | not (stateAdmitting state) && Seq.null (stateControl state) → pure WriterDone
        | otherwise → retry

-- | The writer worker. Its startup allocates nothing, so no sink I/O can ever
-- run in a release, and its terminal state is published however it ends.
writerDefinition ∷ Adapter → WorkerDefinition ()
writerDefinition adapter =
  workerDefinition "runtime.async-log.writer" (\_ → pure () ∷ Scoped ()) $ \_ () →
    writerLoop adapter `finally` uninterruptibleMask_ (atomically (finalizeWriter cell))
  where
    cell = adapterCell adapter

-- | Dequeue and attempt, under a mask that leaves exactly one interruptible
-- point: the borrowed operation itself. A record taken off the queue, or a
-- waiter taken off the control queue, is therefore always accounted for.
--
-- Each step returns whether the writer continues, so the recursion is outside
-- the mask and a long-lived writer accumulates no frames.
writerLoop ∷ Adapter → IO ()
writerLoop adapter = loop
  where
    cell = adapterCell adapter
    borrowed = adapterBorrowed adapter

    loop = do
      continues ← step
      when continues loop

    step = mask $ \restore → do
      -- A retrying transaction stays interruptible and commits nothing, so an
      -- interruption here loses no record.
      work ← atomically (nextWork cell)
      case work of
        WriterDone → pure False
        WriteRecord entry → do
          attempted ← tryWithContext (restore (writeEntry borrowed entry))
          case attempted of
            Right () → do
              atomically (countRecord (\c → c { countWritten = countWritten c + 1 }) cell)
              pure True
            Left failure@(ExceptionWithContext _ raised)
              | isCancellation raised → do
                  uninterruptibleMask_ . atomically $
                    countRecord (\c → c { countInterruptedWrites = countInterruptedWrites c + 1 }) cell
                  rethrowIO failure
              | otherwise → do
                  uninterruptibleMask_ . atomically $ do
                    countRecord (\c → c { countFailedWrites = countFailedWrites c + 1 }) cell
                    latch (render raised) cell
                  pure False
        RunBarrier waiter → do
          attempted ← tryWithContext (restore (flushSink borrowed))
          case attempted of
            -- A flush outcome is not a record outcome: it invents no in-flight
            -- record and reclassifies no completed write.
            Right () → do
              atomically (finishBarrier waiter FlushCompleted cell)
              pure True
            Left failure@(ExceptionWithContext _ raised)
              | isCancellation raised → do
                  uninterruptibleMask_ (atomically (finishBarrier waiter FlushWriterStopped cell))
                  rethrowIO failure
              | otherwise → do
                  uninterruptibleMask_ . atomically $ do
                    let reason = render raised
                    finishBarrier waiter (FlushWriterFailed reason) cell
                    latch reason cell
                  pure False

render ∷ SomeException → Text
render = Text.pack . displayException

isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)

countRecord ∷ (Counters → Counters) → TVar AdapterState → STM ()
countRecord step cell = do
  state ← readTVar cell
  writeTVar cell state { stateCounters = step (stateCounters state) }

-- | Latch the writer's first synchronous failure. A later one never replaces
-- it, and it is never reported back through the writer.
latch ∷ Text → TVar AdapterState → STM ()
latch reason cell = do
  state ← readTVar cell
  case stateLatched state of
    Just _ → pure ()
    Nothing → writeTVar cell state { stateLatched = Just reason }

settle ∷ Waiter → FlushOutcome → STM ()
settle waiter outcome = writeTVar (waiterOutcome waiter) (Just outcome)

-- | Settle the request the writer took and give its slot back, which is the
-- only thing that releases an in-flight barrier's hold on the control bound.
finishBarrier ∷ Waiter → FlushOutcome → TVar AdapterState → STM ()
finishBarrier waiter outcome cell = do
  settle waiter outcome
  state ← readTVar cell
  writeTVar cell state
    { stateInFlight = Nothing
    , stateControlCount = stateControlCount state - 1
    }

-- | Publish the writer's terminal state and wake every waiter still registered,
-- so none of them waits for a barrier that can no longer complete.
finalizeWriter ∷ TVar AdapterState → STM ()
finalizeWriter cell = do
  state ← readTVar cell
  let outcome = terminalOutcome (stateLatched state)
  for_ (stateControl state) (\waiter → settle waiter outcome)
  for_ (stateInFlight state) (\waiter → settle waiter outcome)
  writeTVar cell state
    { stateWriter = WriterTerminal
    , stateControl = Seq.empty
    , stateInFlight = Nothing
    , stateControlCount = 0
    }

terminalOutcome ∷ Maybe Text → FlushOutcome
terminalOutcome = maybe FlushWriterStopped FlushWriterFailed

-- Flushing -----------------------------------------------------------------------

-- | Wait on the barrier: every record admitted before this call is written
-- before the borrowed sink's flush is attempted, and later admissions do not
-- extend it. It reports rather than waiting forever, and it resets no counter.
flushAdapter ∷ AsyncLogAdapter → IO FlushOutcome
flushAdapter = requestFlush . adapterCore

requestFlush ∷ Adapter → IO FlushOutcome
requestFlush adapter = do
  registered ← atomically (register (asyncControlCapacity (adapterSettings adapter)) cell)
  case registered of
    Left outcome → pure outcome
    Right waiter →
      atomically (readTVar (waiterOutcome waiter) >>= maybe retry pure)
        `onException` uninterruptibleMask_ (atomically (release waiter cell))
  where
    cell = adapterCell adapter

-- | Take one of the bounded control slots, or report why not. It never waits
-- for record-queue space and holds nothing the writer needs.
register ∷ Int → TVar AdapterState → STM (Either FlushOutcome Waiter)
register capacity cell = do
  state ← readTVar cell
  case stateWriter state of
    WriterTerminal → pure (Left (terminalOutcome (stateLatched state)))
    WriterRunning
      | stateControlCount state >= capacity → pure (Left FlushRejected)
      | otherwise → do
          outcome ← newTVar Nothing
          let waiter = Waiter
                { waiterId = stateNextRequest state
                , waiterBarrier = stateAdmittedSeq state
                , waiterOutcome = outcome
                }
          writeTVar cell state
            { stateControl = stateControl state |> waiter
            , stateControlCount = stateControlCount state + 1
            , stateNextRequest = stateNextRequest state + 1
            }
          pure (Right waiter)

-- | Give a cancelled waiter's registration back, so repeated registration and
-- cancellation cannot accumulate orphaned requests. A waiter the writer has
-- already taken is not released here: the writer still holds it, and settling
-- it is what gives its slot back.
release ∷ Waiter → TVar AdapterState → STM ()
release waiter cell = do
  state ← readTVar cell
  let (kept, removed) =
        Seq.partition ((/= waiterId waiter) . waiterId) (stateControl state)
  if Seq.null removed
    then pure ()
    else writeTVar cell state
      { stateControl = kept
      , stateControlCount = stateControlCount state - Seq.length removed
      }

-- | The adapter sink's flush: the same barrier, with an unsuccessful typed
-- result raised synchronously.
flushThrough ∷ Adapter → IO ()
flushThrough adapter = do
  outcome ← requestFlush adapter
  case outcome of
    FlushCompleted → pure ()
    unsuccessful → throwIO (AsyncLogFlushFailure unsuccessful)

-- | What the adapter has accounted for so far.
adapterStatus ∷ AsyncLogAdapter → IO AsyncLogStatus
adapterStatus = atomically . adapterStatusSTM

-- | 'adapterStatus' as a transaction, so a caller can wait on the adapter's own
-- account instead of polling it.
adapterStatusSTM ∷ AsyncLogAdapter → STM AsyncLogStatus
adapterStatusSTM handle = do
  state ← readTVar (adapterCell (adapterCore handle))
  let counters = stateCounters state
  pure AsyncLogStatus
    { statusAdmitted = countAdmitted counters
    , statusWritten = countWritten counters
    , statusTruncated = countTruncated counters
    , statusDropped = countDropped counters
    , statusRefused = countRefused counters
    , statusFailedWrites = countFailedWrites counters
    , statusInterruptedWrites = countInterruptedWrites counters
    , statusAbandoned = countAbandoned counters
    , statusControlPending = stateControlCount state
    , statusWriterFailure = stateLatched state
    , statusWriterTerminated = stateWriter state == WriterTerminal
    }

-- Bounded retention -----------------------------------------------------------------

-- | UTF-8 bytes of a text, which is what the budget counts.
byteLength ∷ Text → Int
byteLength = lengthWord8

-- | The longest whole-code-point prefix fitting in @limit@ bytes.
takeBytes ∷ Int → Text → Text
takeBytes limit text
  | limit <= 0 = Text.empty
  | byteLength text <= limit = text
  | otherwise = Text.take (fitting 0 0 text) text
  where
    fitting characters used rest = case Text.uncons rest of
      Nothing → characters
      Just (character, more)
        | used + utf8Width character > limit → characters
        | otherwise → fitting (characters + 1) (used + utf8Width character) more

utf8Width ∷ Char → Int
utf8Width character
  | point < 0x80 = 1
  | point < 0x800 = 2
  | point < 0x10000 = 3
  | otherwise = 4
  where
    point = fromEnum character

-- | Detach a text from the producer's buffer, so retaining a short slice cannot
-- keep an oversized array alive.
detach ∷ Text → Text
detach = Text.copy

-- | The bounded copy of an entry, and what it lost.
--
-- A record already inside every bound keeps its text verbatim, copied. Anything
-- else reserves the marker's maximum size and then fits the members in
-- attribution order: component, thread, source, fields, breadcrumbs, and last
-- the message, which is the one member that shortens gracefully. So what
-- survives at a small budget is what identifies the record, and the message is
-- reduced as far as empty text rather than costing the record its context.
boundEntry ∷ Int → LogEntry → (LogEntry, Truncation)
boundEntry budget entry
  | fitsVerbatim = (verbatim, noTruncation)
  | otherwise = (bounded, note)
  where
    supplied = Map.delete truncationField (entryFields entry)
    reservedTaken = Map.size supplied /= Map.size (entryFields entry)
    suppliedFields = Map.toAscList supplied
    fieldCount = Map.size (entryFields entry)
    crumbCount = length (entryBreadcrumbs entry)
    component = entryComponent entry

    verbatimBytes =
      byteLength (entryMessage entry)
        + byteLength (componentText component)
        + sum [byteLength key + byteLength value | (key, value) ← suppliedFields]
        + sum (map byteLength (entryBreadcrumbs entry))
        + byteLength (entryThread entry)
        + maybe 0 sourceBytes (entrySource entry)
    fitsVerbatim =
      not reservedTaken
        && fieldCount <= maxRetainedFields
        && crumbCount <= maxRetainedBreadcrumbs
        && verbatimBytes <= budget

    verbatim = entry
      { entryComponent = detachComponent component
      , entryMessage = detach (entryMessage entry)
      , entryFields = Map.fromList [(detach key, detach value) | (key, value) ← suppliedFields]
      , entryBreadcrumbs = map detach (entryBreadcrumbs entry)
      , entryThread = detach (entryThread entry)
      , entrySource = detachSource <$> entrySource entry
      }

    allowance = max 0 (budget - markerReserve)

    (keptComponent, componentLost, afterComponent)
      | byteLength (componentText component) <= allowance =
          (detachComponent component, False, allowance - byteLength (componentText component))
      | otherwise =
          ( truncationComponent
          , True
          , max 0 (allowance - byteLength (componentText truncationComponent))
          )

    keptThread = detach (takeBytes afterComponent (entryThread entry))
    threadLost = byteLength keptThread < byteLength (entryThread entry)
    afterThread = afterComponent - byteLength keptThread

    (keptSource, sourceLost, afterSource) = case entrySource entry of
      Nothing → (Nothing, False, afterThread)
      Just location
        | sourceBytes location <= afterThread →
            (Just (detachSource location), False, afterThread - sourceBytes location)
        | otherwise → (Nothing, True, afterThread)

    -- One of the retained entries is the marker this record is about to carry.
    (keptFields, afterFields) =
      fitPairs afterSource (take (maxRetainedFields - 1) suppliedFields)
    (keptCrumbs, afterCrumbs) =
      fitTexts afterFields (take maxRetainedBreadcrumbs (entryBreadcrumbs entry))

    keptMessage = detach (takeBytes afterCrumbs (entryMessage entry))
    messageLost = byteLength keptMessage < byteLength (entryMessage entry)

    note = Truncation
      { lostMessage = messageLost
      , lostComponent = componentLost
      , lostFields = fieldCount - length keptFields
      , lostBreadcrumbs = crumbCount - length keptCrumbs
      , lostThread = threadLost
      , lostSource = sourceLost
      }

    bounded = entry
      { entryComponent = keptComponent
      , entryMessage = keptMessage
      , entryFields = Map.insert truncationField (renderMarker note) (Map.fromList keptFields)
      , entryBreadcrumbs = keptCrumbs
      , entryThread = keptThread
      , entrySource = keptSource
      }

sourceBytes ∷ SourceLocation → Int
sourceBytes location = byteLength (sourceFile location) + byteLength (sourceFunction location)

detachSource ∷ SourceLocation → SourceLocation
detachSource location = location
  { sourceFile = detach (sourceFile location)
  , sourceFunction = detach (sourceFunction location)
  }

-- | Re-validating the copied name keeps the component opaque and forces the
-- copy; a name that was valid stays valid, so the fallback is unreachable.
detachComponent ∷ Component → Component
detachComponent component =
  either (const truncationComponent) id (mkComponent (detach (componentText component)))

-- | Keep the leading entries whose key and value both fit, detached; stop at the
-- first that does not, so what is kept is a prefix rather than a selection.
fitPairs ∷ Int → [(Text, Text)] → ([(Text, Text)], Int)
fitPairs remaining [] = ([], remaining)
fitPairs remaining ((key, value) : rest)
  | needed > remaining = ([], remaining)
  | otherwise =
      let (kept, left) = fitPairs (remaining - needed) rest
       in ((detach key, detach value) : kept, left)
  where
    needed = byteLength key + byteLength value

fitTexts ∷ Int → [Text] → ([Text], Int)
fitTexts remaining [] = ([], remaining)
fitTexts remaining (text : rest)
  | needed > remaining = ([], remaining)
  | otherwise =
      let (kept, left) = fitTexts (remaining - needed) rest
       in (detach text : kept, left)
  where
    needed = byteLength text

-- | Complete every retained copy before the record is published, so nothing
-- reaching the queue is still a deferred slice of a producer's buffer.
forceEntry ∷ LogEntry → LogEntry
forceEntry entry =
  componentText (entryComponent entry)
    `seq` entryMessage entry
    `seq` entryThread entry
    `seq` forceFields (entryFields entry)
    `seq` maybe () forceSource (entrySource entry)
    `seq` crumbs
    `seq` entry { entryBreadcrumbs = crumbs }
  where
    crumbs = forceTexts (entryBreadcrumbs entry)

forceFields ∷ Map Text Text → ()
forceFields = Map.foldlWithKey' (\() key value → key `seq` value `seq` ()) ()

forceSource ∷ SourceLocation → ()
forceSource location = sourceFile location `seq` sourceFunction location `seq` ()

-- | Forcing the result walks the whole spine: each step forces its own tail,
-- which is another call to this function.
forceTexts ∷ [Text] → [Text]
forceTexts [] = []
forceTexts (text : rest) = text `seq` rest' `seq` (text : rest')
  where
    rest' = forceTexts rest
