-- | The small rules every wait of the launcher's shutdown follows, in one place.
--
-- * A wait for something that must finish (a child ending, a session settling, a writer ending) is /never/
--   made uninterruptible, and a cancellation delivered meanwhile is /remembered/ and raised after the wait
--   has completed, never instead of it ('remembering').
-- * Catching a failure to examine it must not swallow a cancellation: 'attemptSync' hands back only synchronous
--   failures, with their context, and lets an asynchronous exception go on ('isAsynchronous').
-- * A diagnostic that cannot be written must not replace what it reports ('bestEffort'), and its failure is marked
--   as the diagnostics' own ('diagnostic').
-- * A write to the diagnostic path that fails is /recorded on the logging lifetime where it occurs/, from inside
--   the sink ('withRecordingLifetime'): the lifetime then knows that path has failed, flushes nothing through it,
--   and nothing writes through it again, whoever asks and whenever they run.
-- * Several failures that belong together are combined with the cleanup machinery's own evidence, so none
--   is lost ('combine').
module Hetoimasia.Run.Settle
  ( remembering
  , rememberingInterruption
  , answering
  , attemptSync
  , isAsynchronous
  , bestEffort
  , diagnostic
  , reportDiagnostic
  , withRecordingLifetime
  , notePathFailure
  , pathFailed
  , combine
  , withEvidence
  ) where

import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , displayException
  , fromException
  , mask
  , rethrowIO
  , throwIO
  , try
  , tryWithContext
  )
import Control.Concurrent.MVar (MVar, putMVar)
import Control.Monad (unless, when)
import Data.Foldable (traverse_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogFilter, LogSink, callbackSinkWith, flushSink, mkLogger, writeEntry)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, composeCleanup, displayCleanupFailure)
import Hetoimasia.Runtime.Logging (LoggingLifetime, recordReport, recordedReports, withLoggingLifetime)
import Hetoimasia.Runtime.Reporting (ReportResult (ReportFailed), markDiagnostic)

-- | Whether a caught failure is an asynchronous exception (a cancellation).
isAsynchronous ∷ ExceptionWithContext SomeException → Bool
isAsynchronous (ExceptionWithContext _ failure) = case fromException failure of
  Just (_ ∷ SomeAsyncException) → True
  Nothing → False

-- | Run an action and hand back a /synchronous/ failure with its context. An asynchronous exception is not caught
-- here: it goes on, as itself.
attemptSync ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
attemptSync action =
  tryWithContext action >>= \case
    Left failure | isAsynchronous failure → rethrowIO failure
    other → pure other

-- | Run an action that must finish, running it again whenever an asynchronous exception interrupts it, and answer
-- the first such interruption (with its context) once the action has completed undisturbed.
--
-- /Called with asynchronous exceptions masked/ (every caller in the launcher is: a @mask@ body, a cleanup, the
-- finalizer of 'Hetoimasia.Run.finalizing'), which is what makes the loop's own continuation safe between two
-- runs of the action.
rememberingInterruption ∷ IO () → IO (Maybe (ExceptionWithContext SomeException))
rememberingInterruption act = go Nothing
  where
    go pending =
      tryWithContext act >>= \case
        Right () → pure pending
        Left interruption
          | isAsynchronous interruption → go (Just (fromMaybe interruption pending))
          | otherwise → rethrowIO interruption

-- | 'rememberingInterruption', raising the interruption after the action has completed.
remembering ∷ IO () → IO ()
remembering act = rememberingInterruption act >>= traverse_ rethrowIO

-- | Run a diagnostic and ignore a synchronous failure of it, once. A cancellation still goes on.
bestEffort ∷ IO () → IO ()
bestEffort action = () <$ attemptSync action

-- | Run a write to the diagnostic path, marking a synchronous failure of it as the diagnostics' own, so the logging
-- lifetime that sees it knows that path has failed and does not flush through it again.
diagnostic ∷ IO a → IO a
diagnostic = markDiagnostic

-- | Whether a write to the lifetime's diagnostic path has already failed.
pathFailed ∷ LoggingLifetime → IO Bool
pathFailed lifetime = any failed <$> recordedReports lifetime
  where
    failed = \case
      ReportFailed _ → True
      _ → False

-- | Record that the diagnostic path has failed, once: the first failure is the evidence the lifetime keeps.
notePathFailure ∷ LoggingLifetime → ExceptionWithContext SomeException → IO ()
notePathFailure lifetime failure = do
  already ← pathFailed lifetime
  unless already (recordReport lifetime (ReportFailed failure))

-- | A write to the diagnostic path, made while a failure is being unwound and so not allowed to replace it: a
-- synchronous failure of it is marked as the diagnostics' own and ignored. That the path has failed is already on
-- the lifetime: the sink records it where it happens ('recordingSink'). A cancellation still goes on.
reportDiagnostic ∷ IO () → IO ()
reportDiagnostic = bestEffort . diagnostic

-- | The lifetime a run is entered in, over a sink that /records its own refusals where they occur/.
--
-- The first write or flush the sink refuses is recorded on the lifetime as a failed report, at that moment and
-- from inside the sink, whichever component, thread or scope made it: the session's diagnostics writer, a boot
-- diagnostic, a drain's report, the verdict's warning, and a reporting boundary of the native application
-- alike. Every later write or flush is refused without touching the sink. So any enclosing boundary that runs at
-- any later point already sees the path as failed, and the lifetime makes no final flush through it; no
-- snapshot, finalizer or join is the source of truth, and nothing waits for any of them. The refusal is still
-- raised to the writer that met it (the session counts it in its own evidence), and a cancellation is never
-- recorded as a refusal.
withRecordingLifetime ∷ LogFilter → LogSink → (LoggingLifetime → IO r) → IO r
withRecordingLifetime configuration sink use = do
  held ← newIORef Nothing
  withLoggingLifetime (mkLogger configuration (recordingSink held sink)) $ \lifetime → do
    writeIORef held (Just lifetime)
    use lifetime

-- | A sink that records its first refusal on the lifetime in the cell, once there is one, and refuses everything
-- after it. See 'withRecordingLifetime'.
recordingSink ∷ IORef (Maybe LoggingLifetime) → LogSink → LogSink
recordingSink held sink = callbackSinkWith (guarded . writeEntry sink) (guarded (flushSink sink))
  where
    -- One masked step from the capture of the refusal to its recording: only the sink operation itself runs with
    -- the caller's interruptibility restored. A caught failure's continuation does not resume unmasked, so a
    -- cancellation queued while the sink was throwing cannot land before the refusal has been recorded; it is
    -- delivered after, when the step ends.
    guarded action = mask $ \restore → do
      lifetime ← readIORef held
      already ← maybe (pure False) pathFailed lifetime
      when already (ioError (userError "the diagnostic path has already failed"))
      tryWithContext (restore action) >>= \case
        Right () → pure ()
        Left failure
          | isAsynchronous failure → rethrowIO failure
          | otherwise → traverse_ (`notePathFailure` failure) lifetime >> rethrowIO failure

-- | A primary failure with these further failures retained beside it, each under its label, as the cleanup
-- machinery retains evidence: none is lost, and the primary keeps its type, value and context.
combine ∷ ExceptionWithContext SomeException → [(Text, ExceptionWithContext SomeException)] → IO (ExceptionWithContext SomeException)
combine primary others = fromMaybe primary <$> composeCleanup (Just primary) others

-- | A failure as one line of text for a report: what it says, then each cleanup failure retained beside it in its
-- context. Turning a typed failure into text anywhere in the launcher goes through here with the context in hand,
-- so a failure that the layer below deliberately kept beside another (a descriptor that would not close after a
-- read failed) is never reduced to the primary one alone. The caller bounds and escapes the line.
withEvidence ∷ Exception e ⇒ ExceptionWithContext e → Text
withEvidence (ExceptionWithContext context failure) =
  Text.intercalate "; " $
    Text.pack (displayException failure) : ["cleanup: " <> Text.pack (displayCleanupFailure retained) | retained ← cleanupFailuresInContext context]

-- | Hand the outcome of an action to a waiter, always. For work that is posted to another thread and waited for
-- there (a job for the process main thread): the outcome, a failure included, is put in the answer in one masked
-- step with its capture, so a cancellation of the running thread cannot land between the two and leave the waiter
-- blocked for ever; and a cancellation is not swallowed on the way, it is handed to the waiter and then goes on.
answering ∷ MVar (Either SomeException a) → IO a → IO ()
answering answer action = mask $ \restore → do
  outcome ← try (restore action)
  putMVar answer outcome
  case outcome of
    Left failure | Just (_ ∷ SomeAsyncException) ← fromException failure → throwIO failure
    _ → pure ()
