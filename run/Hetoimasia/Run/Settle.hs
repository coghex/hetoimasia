-- | The small rules every wait of the launcher's shutdown follows, in one place.
--
-- * A wait for something that must finish (a child ending, a session settling, a writer ending) is /never/
--   made uninterruptible, and a cancellation delivered meanwhile is /remembered/ and raised after the wait
--   has completed, never instead of it ('remembering').
-- * Catching a failure to examine it must not swallow a cancellation: 'attemptSync' hands back only synchronous
--   failures, with their context, and lets an asynchronous exception go on ('isAsynchronous').
-- * A diagnostic that cannot be written must not replace what it reports ('bestEffort'), and its failure is marked
--   as the diagnostics' own ('diagnostic').
-- * A write to the diagnostic path that fails while something else is being unwound is /recorded on the logging
--   lifetime/ ('reportDiagnostic'), never dropped: the lifetime then knows that path has failed, flushes nothing
--   through it, and the launcher writes nothing more through it ('pathFailed').
-- * Several failures that belong together are combined with the cleanup machinery's own evidence, so none
--   is lost ('combine').
module Hetoimasia.Run.Settle
  ( remembering
  , rememberingInterruption
  , attemptSync
  , isAsynchronous
  , bestEffort
  , diagnostic
  , reportDiagnostic
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
  , rethrowIO
  , tryWithContext
  )
import Control.Monad (unless)
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, composeCleanup, displayCleanupFailure)
import Hetoimasia.Runtime.Logging (LoggingLifetime, recordReport, recordedReports)
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

-- | A write to the diagnostic path, made while a failure is being unwound and so not allowed to replace it: skipped
-- when the path has already failed; otherwise run, marked, and when it fails synchronously the failure is recorded
-- on the lifetime instead of being raised. A cancellation still goes on.
reportDiagnostic ∷ LoggingLifetime → IO () → IO ()
reportDiagnostic lifetime write = do
  already ← pathFailed lifetime
  unless already (attemptSync (markDiagnostic write) >>= either (notePathFailure lifetime) pure)

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
