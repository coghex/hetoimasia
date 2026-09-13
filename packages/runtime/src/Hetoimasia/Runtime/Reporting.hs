-- | Reporting recovery outcomes and terminal failures through an injected
-- logger.
--
-- "Hetoimasia.Foundation.Recovery" returns what happened as data and
-- "Hetoimasia.Foundation.Failure" attaches where a failure came from as
-- exception evidence. Neither takes a logger. This module is the runtime adapter
-- that explains both through one, and it is the only place in the runtime that
-- turns them into records.
--
-- Two boundaries use it:
--
-- * __A caller that already holds an 'Outcome'__ calls 'reportOutcome'. The
--   outcome is the caller's before the report is attempted, so the caller
--   records the availability it selected first and then reports. Nothing the
--   report does can change that outcome: a failed report is returned as
--   'ReportFailed' rather than thrown.
--
-- * __A boundary that handles a terminal failure__ wraps its work in
--   'reportTerminalFailure'. An ordinary failure gets one guarded @Error@
--   attempt and is then rethrown preservingly, marked so that no enclosing
--   boundary reports it again.
--
-- The level follows the logging contract. A recovered result and an optional
-- operation that is now unavailable are @Warning@: the enclosing application
-- continues. A terminal failure is @Error@. The level comes from which of those
-- happened, never from the exception's type.
--
-- The rules every report follows:
--
-- * __Bounded by what happened.__ A first-attempt success produces no record. A
--   recovered or unavailable outcome produces one, summarizing its attempts. A
--   terminal failure gets one attempt, at the first boundary that handles it.
--
-- * __Best effort, and only here.__ A synchronous failure while formatting or
--   emitting a report never replaces the failure being reported, never changes
--   an outcome, and never causes another attempt of the operation: the report
--   runs after the operation and its cleanup have finished. There is no retry
--   of a failed emission, and filtering is never bypassed. Ordinary logger calls
--   elsewhere keep their own behavior: a sink failure propagates to their
--   caller.
--
-- * __A diagnostic's own failure is never reported.__ Every emission here is
--   marked with 'DiagnosticFailure', and a caller marks its own lifecycle
--   records with 'markDiagnostic'. 'reportTerminalFailure' does not report a
--   marked failure, because the sink that would carry the report is the one
--   that just failed.
--
-- * __Cancellation is never reported and never displaced.__ Anything thrown as
--   asynchronous escapes unreported with its existing context, including one
--   arriving during a report, which wins over the failure being reported.
--
-- * __No diagnostic runs inside a release or between an acquisition and its
--   protection.__ Both boundaries run their report after the work they wrap has
--   returned or thrown, and so after every scope inside that work has unwound.
--
-- A report's entry records the site that called the boundary as its
-- 'Hetoimasia.Foundation.Log.SourceLocation'. The failure's origin is a
-- different fact and goes in @origin.*@ fields; see @docs/logging.md@.
module Hetoimasia.Runtime.Reporting
  ( -- * Outcomes
    reportOutcome
  , ReportResult (..)

    -- * Terminal failures
  , reportTerminalFailure
  , terminalReportAttempted

    -- * Lifecycle diagnostics
  , DiagnosticFailure (..)
  , markDiagnostic
  , raisedByDiagnostic
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
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , FailureSite (..)
  , Operation
  , OperationContext (..)
  , failureEvidenceInContext
  , operationText
  )
import Hetoimasia.Foundation.Log
  ( Component
  , LogLevel (..)
  , Logger
  , SourceLocation (..)
  , componentText
  , logEvent
  )
import Hetoimasia.Foundation.Recovery
  ( AttemptFailure (..)
  , AttemptKind (..)
  , Outcome (..)
  , Recovered (..)
  , RecoveryHistory (..)
  , Unavailability (..)
  , recoveryHistoryInContext
  )
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)

-- Lifecycle diagnostics --------------------------------------------------------

-- | Marks an exception raised by a lifecycle diagnostic, rather than by a
-- resource, a release, or the work being reported.
--
-- An 'IOException' from a sink looks exactly like an 'IOException' from a
-- release by the time it reaches a boundary, so the emission is marked instead
-- of the exception being guessed at.
data DiagnosticFailure = DiagnosticFailure
  deriving (Eq, Show)

instance ExceptionAnnotation DiagnosticFailure where
  displayExceptionAnnotation _ = "raised by a lifecycle diagnostic"

-- | Run one lifecycle diagnostic, marking a synchronous failure it raises with
-- 'DiagnosticFailure'.
--
-- The failure is rethrown with its type, value, and context, plus the mark. A
-- cancellation is rethrown with its context unchanged.
markDiagnostic ∷ IO a → IO a
markDiagnostic diagnostic = do
  outcome ← tryWithContext diagnostic
  case outcome of
    Right value → pure value
    Left failed@(ExceptionWithContext context failure)
      | isCancellation failure → rethrowIO failed
      | otherwise →
          rethrowIO (ExceptionWithContext (addExceptionAnnotation DiagnosticFailure context) failure)

-- | Whether the exception carrying this context came out of a marked lifecycle
-- diagnostic.
raisedByDiagnostic ∷ ExceptionContext → Bool
raisedByDiagnostic context =
  not (null (getExceptionAnnotations context ∷ [DiagnosticFailure]))

-- Outcomes ---------------------------------------------------------------------

-- | What became of one reporting attempt. The outcome being reported is not in
-- here: the caller already holds it, whatever this says.
data ReportResult
  = NoReport
    -- ^ Nothing happened that needed a record: the first attempt succeeded.
  | ReportAccepted
    -- ^ The logger accepted the record. Its filter may still have dropped it.
  | ReportFailed !(ExceptionWithContext SomeException)
    -- ^ Formatting or emitting the record failed synchronously. The failure is
    -- handed back rather than thrown or reported, because the sink that would
    -- carry a report of it is the one that failed.
  deriving (Show)

-- | Explain one recovery outcome the caller already holds.
--
-- * A first-attempt success is not a recovery and produces no record.
-- * A result recovered after failed attempts produces one @Warning@,
--   @Operation recovered@, naming how it recovered and every failed attempt.
-- * An 'Unavailable' outcome produces one @Warning@, @Operation unavailable@,
--   naming the reason and every attempt.
--
-- Record the availability the outcome selects before calling this. The outcome
-- is returned by 'Hetoimasia.Foundation.Recovery.recover', not by this
-- function, so it stays the caller's whether the report succeeds, fails, or is
-- filtered out; a failure is returned as 'ReportFailed'. A cancellation during
-- the report propagates as itself.
--
-- The operation names the operation given to @recover@; an 'Unavailable'
-- outcome names its own.
reportOutcome ∷ HasCallStack ⇒ Logger → Component → Operation → Outcome a → IO ReportResult
reportOutcome logger component name outcome = case outcome of
  Available recovered → case recoveredFailures recovered of
    [] → pure NoReport
    failures →
      attemptReport logger Warning component "Operation recovered" $
        pure (recoveredFields name recovered failures)
  Unavailable unavailability →
    attemptReport logger Warning component "Operation unavailable" $
      pure (unavailableFields unavailability)

-- Terminal failures -------------------------------------------------------------

-- | Marks a failure a terminal boundary has already made its one reporting
-- attempt for. Not exported: only 'reportTerminalFailure' attaches it.
data TerminalReport = TerminalReport

instance ExceptionAnnotation TerminalReport where
  displayExceptionAnnotation _ = "reported by a terminal boundary"

-- | Whether a terminal boundary has already attempted to report this failure.
terminalReportAttempted ∷ SomeException → Bool
terminalReportAttempted = terminalReportAttemptedInContext . someExceptionContext

terminalReportAttemptedInContext ∷ ExceptionContext → Bool
terminalReportAttemptedInContext context =
  not (null (getExceptionAnnotations context ∷ [TerminalReport]))

-- | Run work at the boundary that handles its terminal failure.
--
-- A result is returned unchanged, with nothing reported. When the work throws:
--
-- * a cancellation propagates unreported, with its context unchanged;
-- * a failure raised by a diagnostic marked with 'DiagnosticFailure' propagates
--   unreported, because the sink that failed is the one a report would use;
-- * a failure an inner boundary already reported propagates unreported;
-- * any other failure gets one guarded @Error@ attempt with the given message,
--   the fields this module derives from its evidence, and the caller's extra
--   fields, which win on a shared key.
--
-- The failure then propagates with its type, value, and context — origin,
-- cleanup, and recovery evidence included — plus a mark that stops every
-- enclosing boundary from reporting it again. That holds whether the attempt
-- succeeded, was filtered out, or failed synchronously; a failed attempt is not
-- retried. A cancellation arriving during the attempt propagates instead, as
-- itself.
--
-- The extra fields are computed inside the guarded attempt, after the work and
-- every scope inside it have unwound, so reading a ledger its releases wrote is
-- safe and a failure while computing them is treated like any other formatting
-- failure.
reportTerminalFailure
  ∷ HasCallStack
  ⇒ Logger → Component → Text → IO [(Text, Text)] → IO a → IO a
reportTerminalFailure logger component message extra work = do
  outcome ← tryWithContext work
  case outcome of
    Right value → pure value
    Left primary@(ExceptionWithContext context failure)
      | isCancellation failure → rethrowIO primary
      | raisedByDiagnostic context → rethrowIO primary
      | terminalReportAttemptedInContext context → rethrowIO primary
      | otherwise → do
          -- A cancellation during the attempt leaves from inside it.
          _ ←
            attemptReport logger Error component message $
              (terminalFields context failure <>) <$> extra
          rethrowIO (ExceptionWithContext (addExceptionAnnotation TerminalReport context) failure)

-- The one guarded attempt -------------------------------------------------------

-- | Compute the fields and emit one record, marked, catching a synchronous
-- failure of either and letting a cancellation escape as itself.
--
-- Fields are left lazy, so a record the filter drops is never formatted.
attemptReport
  ∷ HasCallStack
  ⇒ Logger → LogLevel → Component → Text → IO [(Text, Text)] → IO ReportResult
attemptReport logger level component message fields = do
  reported ← tryWithContext (markDiagnostic (fields >>= logEvent logger level component message))
  case reported of
    Right () → pure ReportAccepted
    Left failed@(ExceptionWithContext _ raised)
      | isCancellation raised → rethrowIO failed
      | otherwise → pure (ReportFailed failed)

-- Fields ------------------------------------------------------------------------

recoveredFields ∷ Operation → Recovered a → [AttemptFailure] → [(Text, Text)]
recoveredFields name recovered failures =
  [ ("operation", operationText name)
  , ("disposition", "recovered")
  , ("availability", "available")
  , ("recovered.by", renderKind (recoveredBy recovered))
  , ("attempts", number (length failures + 1))
  , ("attempts.failed", renderAttempts failures)
  ]
    <> attemptFields (last failures)

unavailableFields ∷ Unavailability → [(Text, Text)]
unavailableFields unavailability =
  [ ("operation", operationText (unavailableOperation unavailability))
  , ("disposition", "unavailable")
  , ("availability", "unavailable")
  , ("attempts", number (length attempts))
  , ("attempts.failed", renderAttempts attempts)
  ]
    <> attemptFields reason
  where
    reason = unavailableReason unavailability
    attempts = unavailableEarlier unavailability <> [reason]

-- | The latest failed attempt: why it failed and where that came from.
attemptFields ∷ AttemptFailure → [(Text, Text)]
attemptFields attempt = case attemptException attempt of
  ExceptionWithContext context failure →
    ("reason", Text.pack (displayException failure)) : evidenceFields context

terminalFields ∷ ExceptionContext → SomeException → [(Text, Text)]
terminalFields context failure =
  [ ("disposition", "propagated")
  , ("availability", "unavailable")
  , ("reason", Text.pack (displayException failure))
  , ("cleanup.failures", number (length cleanup))
  , ("cleanup.labels", Text.intercalate "," (map cleanupFailureLabel cleanup))
  ]
    <> historyFields (recoveryHistoryInContext context)
    <> evidenceFields context
  where
    cleanup = cleanupFailuresInContext context

-- | The innermost recovery that ended in this failure, if one did. The failure
-- itself is the last attempt, so it is counted but not listed.
historyFields ∷ [RecoveryHistory] → [(Text, Text)]
historyFields [] = []
historyFields (history : _) =
  [ ("operation", operationText (historyOperation history))
  , ("attempts", number (length (historyAttempts history) + 1))
  , ("attempts.failed", renderAttempts (historyAttempts history))
  ]

-- | Origin and the innermost observation boundary, as fields.
--
-- A failure with no recorded origin says so: @origin=unrecorded@ and
-- @origin.site=unknown@. A boundary that observed it is reported under
-- @observed.*@, which is where the failure was seen, never where it was thrown,
-- and the reporting site is never used for either.
evidenceFields ∷ ExceptionContext → [(Text, Text)]
evidenceFields context = originFields (failureCause evidence) <> observedFields (failureContexts evidence)
  where
    evidence = failureEvidenceInContext context

originFields ∷ FailureCause → [(Text, Text)]
originFields NativeCause = [("origin", "unrecorded"), ("origin.site", "unknown")]
originFields (EngineOrigin origin) =
  [ ("origin", "engine")
  , ("origin.component", componentText (originComponent origin))
  , ("origin.operation", operationText (originOperation origin))
  ]
    <> identifierFields "origin" (originIdentifiers origin)
    <> siteFields "origin" (originSite origin)

observedFields ∷ [OperationContext] → [(Text, Text)]
observedFields [] = []
observedFields (boundary : _) =
  [ ("observed.component", componentText (contextComponent boundary))
  , ("observed.operation", operationText (contextOperation boundary))
  ]
    <> identifierFields "observed" (contextIdentifiers boundary)
    <> siteFields "observed" (contextBoundary boundary)

identifierFields ∷ Text → [(Text, Text)] → [(Text, Text)]
identifierFields _ [] = []
identifierFields prefix identifiers =
  [ ( prefix <> ".identifiers"
    , Text.intercalate "," [quoted key <> "=" <> quoted value | (key, value) ← identifiers]
    )
  ]

siteFields ∷ Text → Maybe FailureSite → [(Text, Text)]
siteFields prefix Nothing = [(prefix <> ".site", "unknown")]
siteFields prefix (Just site) =
  [ (prefix <> ".site", sourceFile location <> ":" <> number (sourceLine location))
  , (prefix <> ".function", sourceFunction location)
  ]
  where
    location = siteLocation site

-- Rendering ---------------------------------------------------------------------

-- | Attempts as @number:kind@, oldest first.
renderAttempts ∷ [AttemptFailure] → Text
renderAttempts = Text.intercalate "," . map renderAttempt
  where
    renderAttempt attempt = number (attemptNumber attempt) <> ":" <> renderKind (attemptKind attempt)

renderKind ∷ AttemptKind → Text
renderKind InitialAttempt = "initial"
renderKind RetryAttempt = "retry"
renderKind (FallbackAttempt name) = "fallback " <> quoted (operationText name)

-- | Caller-supplied text inside a field value, quoted so a comma or an equals
-- sign in it cannot be mistaken for a separator.
quoted ∷ Text → Text
quoted = Text.pack . show

number ∷ Int → Text
number = Text.pack . show

isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)
