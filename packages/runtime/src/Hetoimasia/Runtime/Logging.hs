-- | The borrowed logging lifetime and its final flush.
--
-- A logger over a borrowed sink needs one more thing after its producers have
-- stopped and its subsystems have unwound: a final flush, attempted while the
-- sink is still live and never inside a controlled resource release. This
-- module owns that obligation and nothing else. 'withLoggingLifetime' is an
-- explicit 'IO' callback boundary, outside the @Scoped@ runner, that borrows an
-- existing 'Logger', lends it to the callback through a narrow
-- 'LoggingLifetime' handle, and finalizes once the callback has returned or
-- thrown.
--
-- __What the handle lends.__ The logger, through 'lifetimeLogger', and a place
-- to record what became of each runtime-managed reporting attempt, through
-- 'recordReport'. It looks up no other service, owns no handle, changes no
-- buffering, creates no output backend, and changes nothing about how an
-- ordinary 'Logger' call behaves or fails: a direct @logInfo@ whose sink throws
-- still throws to its caller. It is not an application environment.
--
-- __What the callback owes.__ Every producer — a worker, a subsystem, a thread
-- the callback started — has stopped emitting before the callback returns, and
-- every component scope inside it has unwound. The chosen terminal-report
-- owner, such as 'Hetoimasia.Runtime.Resources.resourceSmoke', has made its one
-- report inside the callback too. The lifetime itself reports nothing: it never
-- turns a callback failure into a record.
--
-- __The order.__ Producers stop, component cleanup unwinds, the terminal-report
-- owner reports, the callback returns or throws, and then the lifetime makes at
-- most one final flush. A caller that owns the handle behind the sink closes it
-- only after 'withLoggingLifetime' has returned.
--
-- __The final flush.__ At most one attempt per lifetime, through
-- 'Hetoimasia.Foundation.Log.flushLogger'. It runs with the caller's masking
-- state, so it keeps its ordinary interruptibility: no bounded flush duration is
-- promised, and no successful flush during cancellation either. Never call
-- 'withLoggingLifetime' from a release callback, which runs under
-- 'Control.Exception.uninterruptibleMask_' and must not contain a write or a
-- flush with no controlled duration.
--
-- __Finalization follows the settled outcome.__
--
-- * The callback returned and diagnostics remain usable: flush, and return the
--   result only if the flush succeeds. A synchronous flush failure fails the
--   run with the flush's own exception, marked with
--   'Hetoimasia.Runtime.Reporting.DiagnosticFailure'.
-- * The callback threw synchronously and diagnostics remain usable: flush, and
--   rethrow the callback's failure with its type, value, and context. If the
--   flush also failed synchronously, the flush failure rides on that context as
--   secondary evidence 'flushFailures' reads back; no
--   'Hetoimasia.Foundation.Resource.CleanupFailure' is forged for it.
-- * A runtime-managed diagnostic attempt has already failed: no flush, and no
--   new attempt through that path. A returned result is returned, and a thrown
--   failure is rethrown, with every failed attempt recorded on this handle
--   attached as evidence 'failedReports' reads back. The handle's
--   'recordedReports' holds them either way.
-- * The callback is being cancelled: the cancellation propagates with its
--   context, with no report and no flush.
-- * A cancellation arrives during the flush: it propagates as itself, with its
--   own context, in place of whatever outcome was settled. It is never turned
--   into a synchronous logger failure, and the flush is not retried.
--
-- Whether diagnostics remain usable is decided from explicit provenance only: a
-- failure the callback threw that carries the 'DiagnosticFailure' mark, or a
-- 'ReportFailed' outcome recorded here. An exception's type is never consulted;
-- an 'IOException' from a sink and one from a release look alike. There is no
-- global sink-health registry.
--
-- __State.__ The handle holds one mutable cell: the recorded outcomes of
-- managed reporting attempts, newest first.
--
-- * Owner: the 'withLoggingLifetime' call that created it. Nothing outlives the
--   call except the handle value itself, if a callback retains it.
-- * Writers: 'recordReport', from any thread holding the handle, atomically.
--   Nothing is ever removed.
-- * Readers: 'recordedReports', from any thread, and finalization, once, on the
--   thread that called 'withLoggingLifetime', after the callback has finished.
-- * Lifetime and reset: created empty per call and never reset or shared
--   between calls. A record written after finalization has read the cell is
--   kept but has no effect on that finalization.
--
-- The flush attempt is not shared state: finalization decides it and makes it
-- on the calling thread, exactly once or not at all, and its outcome is the
-- lifetime's own result or the evidence attached to a failure.
--
-- Configuration parsing and logger construction happen before this boundary.
-- A failure there propagates as its own typed failure, with no promise of a
-- record, because no managed logger exists yet.
--
-- See @docs/logging.md@, \"Logging lifetime\", for the same contract in prose.
module Hetoimasia.Runtime.Logging
  ( -- * The lifetime
    LoggingLifetime
  , withLoggingLifetime
  , withHandleLoggingLifetime
  , lifetimeLogger

    -- * Managed reporting attempts
  , recordReport
  , recordedReports

    -- * Secondary evidence
  , flushFailures
  , flushFailuresInContext
  , failedReports
  , failedReportsInContext
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , displayException
  , fromException
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
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Log (LogFilter, Logger, flushLogger, handleLogger)
import Hetoimasia.Runtime.Reporting
  ( ReportResult (..)
  , markDiagnostic
  , raisedByDiagnostic
  )
import System.IO (Handle)

-- | The runtime-owned handle a logging lifetime lends its callback.
--
-- Its representation is not exported, so a handle is only ever the one
-- 'withLoggingLifetime' created: its logger cannot be swapped out from under
-- the outcomes recorded beside it.
data LoggingLifetime = LoggingLifetime
  { borrowedLogger ∷ !Logger
  , reportOutcomes ∷ !(IORef [ReportResult])
  }

-- | The borrowed logger. Every logger derived from it shares its sink, and the
-- final flush flushes what all of them wrote.
lifetimeLogger ∷ LoggingLifetime → Logger
lifetimeLogger = borrowedLogger

-- | Record what became of one runtime-managed reporting attempt.
--
-- Pass it as the recorder of
-- 'Hetoimasia.Runtime.Reporting.reportTerminalFailureWith', or call it with the
-- 'ReportResult' that 'Hetoimasia.Runtime.Reporting.reportOutcome' returned. A
-- 'ReportFailed' outcome tells finalization that this path's diagnostics have
-- already failed. Recording never blocks and never throws.
recordReport ∷ LoggingLifetime → ReportResult → IO ()
recordReport lifetime outcome =
  atomicModifyIORef' (reportOutcomes lifetime) (\recorded → (outcome : recorded, ()))

-- | Every reporting outcome recorded on this handle, oldest first.
recordedReports ∷ LoggingLifetime → IO [ReportResult]
recordedReports lifetime = reverse <$> readIORef (reportOutcomes lifetime)

-- | Run a callback inside a logging lifetime over a logger constructed by the
-- caller, then finalize it as the module header describes.
withLoggingLifetime ∷ Logger → (LoggingLifetime → IO a) → IO a
withLoggingLifetime logger callback = do
  lifetime ← LoggingLifetime logger <$> newIORef []
  outcome ← tryWithContext (callback lifetime)
  recorded ← recordedReports lifetime
  let failed = [attempt | ReportFailed attempt ← recorded]
  case outcome of
    Right value
      | null failed → do
          flushed ← finalFlush logger
          either rethrowIO (const (pure value)) flushed
      | otherwise → pure value
    Left current@(ExceptionWithContext context failure)
      | isCancellation failure → rethrowIO current
      | not (null failed) →
          rethrowIO (ExceptionWithContext (addExceptionAnnotation (FailedReports failed) context) failure)
      | raisedByDiagnostic context → rethrowIO current
      | otherwise → do
          flushed ← finalFlush logger
          case flushed of
            Right () → rethrowIO current
            Left secondary →
              rethrowIO (ExceptionWithContext (addExceptionAnnotation (FlushFailure secondary) context) failure)

-- | 'withLoggingLifetime' over one 'handleLogger' constructed on a borrowed
-- handle, such as the console's @stderr@. The handle stays the caller's: it is
-- never closed and its buffering is never changed.
withHandleLoggingLifetime ∷ LogFilter → Handle → (LoggingLifetime → IO a) → IO a
withHandleLoggingLifetime configuration handle callback = do
  logger ← handleLogger configuration handle
  withLoggingLifetime logger callback

-- | The one final flush attempt, marked as a diagnostic. A synchronous failure
-- is handed back; a cancellation during it leaves from here, as itself.
finalFlush ∷ Logger → IO (Either (ExceptionWithContext SomeException) ())
finalFlush logger = do
  flushed ← tryWithContext (markDiagnostic (flushLogger logger))
  case flushed of
    Left failed@(ExceptionWithContext _ raised) | isCancellation raised → rethrowIO failed
    _ → pure flushed

-- Secondary evidence -------------------------------------------------------------

-- | A final flush that failed synchronously after the callback had already
-- failed. Attached only by 'withLoggingLifetime'.
newtype FlushFailure = FlushFailure (ExceptionWithContext SomeException)

instance ExceptionAnnotation FlushFailure where
  displayExceptionAnnotation (FlushFailure (ExceptionWithContext _ failure)) =
    "the final log flush also failed: " <> displayException failure

-- | The failed reporting attempts a lifetime had recorded when it finalized
-- without flushing. Attached only by 'withLoggingLifetime'.
newtype FailedReports = FailedReports [ExceptionWithContext SomeException]

instance ExceptionAnnotation FailedReports where
  displayExceptionAnnotation (FailedReports attempts) =
    "a diagnostic report already failed, so no final log flush was attempted: "
      <> unwords [displayException failure | ExceptionWithContext _ failure ← attempts]

-- | The final flush failures retained on a failure a logging lifetime
-- rethrew, innermost lifetime first, each with the type, value, and context the
-- flush raised it with. Empty when no flush failed. Reading them needs no
-- logger.
flushFailures ∷ SomeException → [ExceptionWithContext SomeException]
flushFailures = flushFailuresInContext . someExceptionContext

-- | 'flushFailures' for a caller holding the context directly.
flushFailuresInContext ∷ ExceptionContext → [ExceptionWithContext SomeException]
flushFailuresInContext context =
  reverse [failure | FlushFailure failure ← getExceptionAnnotations context]

-- | The failed managed reporting attempts a logging lifetime attached to a
-- failure it rethrew without flushing, innermost lifetime first and oldest
-- attempt first within one lifetime.
failedReports ∷ SomeException → [ExceptionWithContext SomeException]
failedReports = failedReportsInContext . someExceptionContext

-- | 'failedReports' for a caller holding the context directly.
failedReportsInContext ∷ ExceptionContext → [ExceptionWithContext SomeException]
failedReportsInContext context =
  concat (reverse [attempts | FailedReports attempts ← getExceptionAnnotations context])

isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)
