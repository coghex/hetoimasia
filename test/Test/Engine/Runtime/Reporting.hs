-- | Examples for 'Hetoimasia.Runtime.Reporting', the adapter that explains
-- recovery outcomes and terminal failures through an injected logger.
--
-- Every example drives the real 'recover' boundary with injected typed failures
-- and observes what a caller can see: the outcome it holds, the failure that
-- propagated with its evidence, the records an injected sink was handed, and an
-- append-only trace of attempts, releases, and sink calls.
--
-- Cancellation is coordinated with 'MVar's, never with a sleep; 'bounded' only
-- stops an example that has already hung.
module Test.Engine.Runtime.Reporting (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall
  , Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeException
  , annotateIO
  , evaluate
  , fromException
  , someExceptionContext
  , throwIO
  , try
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , Operation
  , failureEvidence
  , failureEvidenceInContext
  , operation
  , throwFailure
  , withOperationContext
  )
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (..)
  , Logger
  , SourceLocation (..)
  , callbackSink
  , defaultLogFilter
  , logInfo
  , mkLoggerWith
  , unsafeComponent
  )
import Hetoimasia.Foundation.Recovery
  ( AttemptFailure (..)
  , Disposition (..)
  , Outcome (..)
  , Recovered (..)
  , RecoveryHistory (..)
  , RecoveryPolicy (..)
  , Strategy (..)
  , Unavailability (..)
  , recover
  , recoveryHistory
  )
import Hetoimasia.Foundation.Resource
  ( allocResource
  , cleanupFailureLabel
  , cleanupFailures
  , withResourceLabelled
  , withScoped
  )
import Hetoimasia.Runtime.Reporting
  ( DiagnosticFailure (..)
  , ReportResult (..)
  , markDiagnostic
  , reportOutcome
  , reportTerminalFailure
  , terminalReportAttempted
  )
import System.IO.Error (ioeGetErrorString)
import Test.Engine.Logging.Support (bounded, fixedMetadata, newCollector, summaries)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldNotBe
  , shouldReturn
  , shouldSatisfy
  )

spec ∷ Spec
spec = describe "Outcome reporting" $ do
  describe "Levels and dispositions" $ do
    it "warns once for a recovered result, with its attempt history"
      testRecoveredWarning
    it "reports nothing for a first-attempt success"
      testFirstAttemptSilent
    it "warns once for an exhausted optional operation"
      testUnavailableWarning
    it "reports a terminal required failure once as an error and rethrows it"
      testTerminalError
    it "reports a first-attempt terminal failure's recovery as unrecorded"
      testFirstAttemptTerminalError

  describe "Origin" $ do
    it "reports the failure's origin in fields distinct from the reporting site"
      testOriginDistinctFromReportingSite
    it "reports a failure with no recorded origin without inventing one"
      testUnrecordedOrigin

  describe "Disposition before diagnostics" $ do
    it "keeps an optional outcome unavailable before and after its warning fails"
      testUnavailableBeforeWarningFails
    it "keeps the outcome and its attempt evidence when the filter drops the report"
      testFilteredReport

  describe "Bounded reports" $ do
    it "emits one terminal error for a multi-attempt chain crossing two boundaries"
      testNoDuplicateTerminalError

  describe "Diagnostic failures" $ do
    it "keeps the primary failure, completed cleanup, and attempt count when the sink fails"
      testSinkFailureKeepsPrimary
    it "keeps the primary failure and its evidence when formatting the report throws"
      testTerminalFormattingFailure
    it "keeps a recovered outcome when formatting its report throws"
      testRecoveredFormattingFailure
    it "never reports a marked diagnostic's own failure through the same sink"
      testMarkedDiagnosticNotReported

  describe "Cancellation" $ do
    it "escapes cancellation delivered while a terminal report blocks"
      (bounded testCancelledWhileReporting)
    it "escapes a cancellation an outcome report raised, with its context"
      testCancellationFromOutcomeReport

-- Fixtures --------------------------------------------------------------------

-- | A component's own exception type. 'WidgetUnprintable' is an ordinary
-- failure whose rendered text faults, so only formatting a report of it throws.
data WidgetFailure
  = WidgetBroken Int
  | WidgetUnprintable
  deriving (Eq, Show)

instance Exception WidgetFailure where
  displayException WidgetUnprintable = error "the widget failure's text faulted"
  displayException failure = show failure

-- | Rides on a cancellation the sink raises, so an example can tell that
-- cancellation from an identical one whose context was replaced.
data ReportMark = ReportMark
  deriving (Eq, Show)

instance ExceptionAnnotation ReportMark where
  displayExceptionAnnotation _ = "raised by the reporting sink"

widgets ∷ Component
widgets = unsafeComponent "test.widgets"

reporting ∷ Component
reporting = unsafeComponent "test.reporting"

loadWidget ∷ Operation
loadWidget = operation "load-widget"

-- | Fail one attempt with an engine origin naming it.
failAttempt ∷ Int → IO a
failAttempt number =
  throwFailure widgets loadWidget [("attempt", Text.pack (show number))] (WidgetBroken number)

-- | Count one attempt, fail it with 'failAttempt' while @failures@ attempts
-- have not yet failed, and otherwise return the attempt's number.
flaky ∷ IORef Int → Int → IO Int
flaky attempts failures = do
  number ← atomicModifyIORef' attempts (\count → (count + 1, count + 1))
  if number <= failures then failAttempt number else pure number

-- | A policy that retries every 'WidgetFailure' and recognizes nothing else.
retrying ∷ Disposition → Int → RecoveryPolicy a
retrying disposition budget = RecoveryPolicy
  { policyDisposition = disposition
  , policyBudget = budget
  , policyClassifier = \failure → pure $ case attemptException failure of
      ExceptionWithContext _ exception → case fromException exception of
        Just (_ ∷ WidgetFailure) → Just Retry
        Nothing → Nothing
  , policyWait = \_ → pure ()
  }

loggerFor ∷ (LogEntry → IO ()) → Logger
loggerFor = mkLoggerWith defaultLogFilter fixedMetadata . callbackSink

-- | A sink that records how many records it was handed, then fails on each.
newFailingSink ∷ IORef [Text] → IO (Logger, IO Int)
newFailingSink trace = do
  handed ← newIORef (0 ∷ Int)
  let sink _ = do
        atomicModifyIORef' handed (\count → (count + 1, ()))
        note trace "sink"
        ioError (userError "sink unavailable")
  pure (loggerFor sink, readIORef handed)

-- | A sink that forces every field value of each record it is handed, as a
-- formatting sink would, and then records it.
newFormattingSink ∷ IO (Logger, IO Int, IO [LogEntry])
newFormattingSink = do
  handed ← newIORef (0 ∷ Int)
  formatted ← newIORef []
  let sink entry = do
        atomicModifyIORef' handed (\count → (count + 1, ()))
        _ ← evaluate (sum (map Text.length (Map.elems (entryFields entry))))
        atomicModifyIORef' formatted (\entries → (entries <> [entry], ()))
  pure (loggerFor sink, readIORef handed, readIORef formatted)

note ∷ IORef [Text] → Text → IO ()
note trace entry = atomicModifyIORef' trace (\entries → (entries <> [entry], ()))

expectFailure ∷ IO a → IO SomeException
expectFailure action = do
  outcome ← try action
  case outcome of
    Left failure → pure failure
    Right _ → fail "expected the boundary to fail, but it returned"

single ∷ [LogEntry] → IO LogEntry
single [entry] = pure entry
single entries = fail ("expected exactly one record, got " <> show (length entries))

field ∷ Text → LogEntry → Maybe Text
field key entry = Map.lookup key (entryFields entry)

widgetOf ∷ SomeException → Maybe WidgetFailure
widgetOf = fromException

accepted ∷ ReportResult → Expectation
accepted ReportAccepted = pure ()
accepted other = expectationFailure ("expected an accepted report, got " <> show other)

failedWith ∷ ReportResult → IO SomeException
failedWith (ReportFailed (ExceptionWithContext _ failure)) = pure failure
failedWith other = fail ("expected a failed report, got " <> show other)

available ∷ Outcome a → Bool
available (Available _) = True
available (Unavailable _) = False

recoveredValueOf ∷ Outcome a → IO a
recoveredValueOf (Available recovered) = pure (recoveredValue recovered)
recoveredValueOf (Unavailable _) = fail "expected an available outcome"

-- | Signals arrival, then blocks on an 'MVar' the example holds and never
-- fills, which keeps the block interruptible rather than a detected deadlock.
blockedAt ∷ MVar () → MVar () → IO a
blockedAt entered held = do
  putMVar entered ()
  takeMVar held
  fail "a blocked action was released"

-- Levels and dispositions -----------------------------------------------------

testRecoveredWarning ∷ Expectation
testRecoveredWarning = do
  (sink, collected) ← newCollector
  attempts ← newIORef 0
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  outcome ← recover loadWidget (retrying Required 3) (flaky attempts 2)
  recoveredValueOf outcome `shouldReturn` 3
  reportOutcome logger reporting loadWidget outcome >>= accepted
  entries ← collected
  summaries entries `shouldBe` [(Warning, "test.reporting", "Operation recovered")]
  entry ← single entries
  field "operation" entry `shouldBe` Just "load-widget"
  field "disposition" entry `shouldBe` Just "recovered"
  field "availability" entry `shouldBe` Just "available"
  field "recovered.by" entry `shouldBe` Just "retry"
  field "attempts" entry `shouldBe` Just "3"
  field "attempts.failed" entry `shouldBe` Just "1:initial,2:retry"
  field "reason" entry `shouldBe` Just "WidgetBroken 2"
  field "origin" entry `shouldBe` Just "engine"
  field "origin.component" entry `shouldBe` Just "test.widgets"
  field "origin.operation" entry `shouldBe` Just "load-widget"
  field "origin.identifiers" entry `shouldBe` Just "\"attempt\"=\"2\""
  -- Reporting ran after the boundary returned, so it caused no attempt.
  readIORef attempts `shouldReturn` 3

testFirstAttemptSilent ∷ Expectation
testFirstAttemptSilent = do
  (sink, collected) ← newCollector
  attempts ← newIORef 0
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  outcome ← recover loadWidget (retrying Required 3) (flaky attempts 0)
  result ← reportOutcome logger reporting loadWidget outcome
  case result of
    NoReport → pure ()
    other → expectationFailure ("expected no report, got " <> show other)
  collected `shouldReturn` []

testUnavailableWarning ∷ Expectation
testUnavailableWarning = do
  (sink, collected) ← newCollector
  attempts ← newIORef 0
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  outcome ← recover loadWidget (retrying Optional 2) (flaky attempts 5)
  available outcome `shouldBe` False
  reportOutcome logger reporting loadWidget outcome >>= accepted
  entries ← collected
  summaries entries `shouldBe` [(Warning, "test.reporting", "Operation unavailable")]
  entry ← single entries
  field "disposition" entry `shouldBe` Just "unavailable"
  field "availability" entry `shouldBe` Just "unavailable"
  field "attempts" entry `shouldBe` Just "2"
  field "attempts.failed" entry `shouldBe` Just "1:initial,2:retry"
  field "reason" entry `shouldBe` Just "WidgetBroken 2"
  field "origin.identifiers" entry `shouldBe` Just "\"attempt\"=\"2\""

testTerminalError ∷ Expectation
testTerminalError = do
  (sink, collected) ← newCollector
  attempts ← newIORef 0
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  propagated ←
    expectFailure $
      reportTerminalFailure logger reporting "Widget load failed" (pure [("widget", "w1")]) $
        recover loadWidget (retrying Required 2) (flaky attempts 5)
  -- The latest attempt's own failure propagates, its history intact.
  widgetOf propagated `shouldBe` Just (WidgetBroken 2)
  map (map attemptNumber . historyAttempts) (recoveryHistory propagated) `shouldBe` [[1]]
  terminalReportAttempted propagated `shouldBe` True
  entries ← collected
  summaries entries `shouldBe` [(Error, "test.reporting", "Widget load failed")]
  entry ← single entries
  field "disposition" entry `shouldBe` Just "propagated"
  field "availability" entry `shouldBe` Just "unavailable"
  field "recovery" entry `shouldBe` Just "recorded"
  field "operation" entry `shouldBe` Just "load-widget"
  field "attempts" entry `shouldBe` Just "2"
  field "attempts.earlier" entry `shouldBe` Just "1:initial"
  -- The propagated attempt is the terminal one, named by its number.
  field "attempts.terminal" entry `shouldBe` Just "2"
  field "attempts.failed" entry `shouldBe` Nothing
  field "cleanup.failures" entry `shouldBe` Just "0"
  field "widget" entry `shouldBe` Just "w1"
  readIORef attempts `shouldReturn` 2

-- | 'recover' attaches no history to a failure of its first attempt, so the
-- report cannot tell it from a failure that never passed through 'recover' and
-- says so rather than inventing an operation or a count.
testFirstAttemptTerminalError ∷ Expectation
testFirstAttemptTerminalError = do
  (sink, collected) ← newCollector
  attempts ← newIORef 0
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  propagated ←
    expectFailure $
      reportTerminalFailure logger reporting "Widget load failed" (pure []) $
        recover loadWidget (retrying Required 1) (flaky attempts 5)
  widgetOf propagated `shouldBe` Just (WidgetBroken 1)
  recoveryHistory propagated `shouldSatisfy` null
  entry ← single =<< collected
  entryLevel entry `shouldBe` Error
  field "disposition" entry `shouldBe` Just "propagated"
  field "recovery" entry `shouldBe` Just "unrecorded"
  field "attempts.earlier" entry `shouldBe` Just "none"
  field "attempts.terminal" entry `shouldBe` Nothing
  field "attempts" entry `shouldBe` Nothing
  field "operation" entry `shouldBe` Nothing
  -- The origin still names the operation that raised the failure.
  field "origin.operation" entry `shouldBe` Just "load-widget"
  readIORef attempts `shouldReturn` 1

-- Origin ----------------------------------------------------------------------

testOriginDistinctFromReportingSite ∷ Expectation
testOriginDistinctFromReportingSite = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  void . expectFailure $
    reportTerminalFailure logger reporting "Widget load failed" (pure []) $
      failAttempt 1
  entry ← single =<< collected
  -- The entry's source is where the boundary was called.
  source ← maybe (fail "the entry recorded no source") pure (entrySource entry)
  sourceFunction source `shouldBe` "reportTerminalFailure"
  sourceFile source `shouldSatisfy` Text.isSuffixOf "Test/Engine/Runtime/Reporting.hs"
  -- The origin is where the failure was raised, in its own fields.
  field "origin.function" entry `shouldBe` Just "throwFailure"
  field "origin.site" entry `shouldSatisfy` maybe False (Text.isInfixOf "Test/Engine/Runtime/Reporting.hs:")
  field "origin.site" entry
    `shouldNotBe` Just (sourceFile source <> ":" <> Text.pack (show (sourceLine source)))

testUnrecordedOrigin ∷ Expectation
testUnrecordedOrigin = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  -- A native failure observed by a boundary: the boundary is known, the throw
  -- site is not.
  observed ←
    expectFailure $
      reportTerminalFailure logger reporting "Widget file failed" (pure []) $
        withOperationContext widgets (operation "open-widget-file") [("path", "missing.widget")] $
          ioError (userError "no such widget file")
  -- The same kind of failure with no boundary at all.
  bare ←
    expectFailure $
      reportTerminalFailure logger reporting "Widget file failed" (pure []) $
        ioError (userError "no such widget file")
  (ioeGetErrorString <$> (fromException observed ∷ Maybe IOException))
    `shouldBe` Just "no such widget file"
  (ioeGetErrorString <$> (fromException bare ∷ Maybe IOException))
    `shouldBe` Just "no such widget file"
  entries ← collected
  case entries of
    [withBoundary, withoutBoundary] → do
      source ← maybe (fail "the entry recorded no source") pure (entrySource withBoundary)
      let reportingSite = sourceFile source <> ":" <> Text.pack (show (sourceLine source))
      field "origin" withBoundary `shouldBe` Just "unrecorded"
      field "origin.site" withBoundary `shouldBe` Just "unknown"
      field "origin.component" withBoundary `shouldBe` Nothing
      field "observed.component" withBoundary `shouldBe` Just "test.widgets"
      field "observed.operation" withBoundary `shouldBe` Just "open-widget-file"
      field "observed.identifiers" withBoundary `shouldBe` Just "\"path\"=\"missing.widget\""
      field "observed.function" withBoundary `shouldBe` Just "withOperationContext"
      field "observed.site" withBoundary `shouldNotBe` Just reportingSite
      field "origin" withoutBoundary `shouldBe` Just "unrecorded"
      field "origin.site" withoutBoundary `shouldBe` Just "unknown"
      field "observed.site" withoutBoundary `shouldBe` Nothing
    _ → expectationFailure ("expected two records, got " <> show (length entries))

-- Disposition before diagnostics ----------------------------------------------

testUnavailableBeforeWarningFails ∷ Expectation
testUnavailableBeforeWarningFails = do
  attempts ← newIORef 0
  -- The caller's own availability state, and what it held when the warning was
  -- handed to the sink.
  recorded ← newIORef Nothing
  seenBySink ← newIORef Nothing
  let logger = loggerFor $ \_ → do
        readIORef recorded >>= writeIORef seenBySink . Just
        ioError (userError "warning sink unavailable")
  outcome ← recover loadWidget (retrying Optional 2) (flaky attempts 5)
  writeIORef recorded (Just (available outcome))
  result ← reportOutcome logger reporting loadWidget outcome
  reportFailure ← failedWith result
  (ioeGetErrorString <$> fromException reportFailure) `shouldBe` Just "warning sink unavailable"
  -- Unavailable before the warning was attempted, and still unavailable after
  -- it failed, with no further attempt of the operation.
  readIORef seenBySink `shouldReturn` Just (Just False)
  readIORef recorded `shouldReturn` Just False
  available outcome `shouldBe` False
  readIORef attempts `shouldReturn` 2

testFilteredReport ∷ Expectation
testFilteredReport = do
  handed ← newIORef (0 ∷ Int)
  attempts ← newIORef (0 ∷ Int)
  let logger =
        mkLoggerWith
          defaultLogFilter { filterEnabled = False }
          fixedMetadata
          (callbackSink (\_ → atomicModifyIORef' handed (\count → (count + 1, ()))))
      -- Every attempt fails with a failure whose text would fault if a report
      -- of it were ever formatted.
      unprintable = do
        atomicModifyIORef' attempts (\count → (count + 1, ()))
        throwFailure widgets loadWidget [] WidgetUnprintable
  outcome ← recover loadWidget (retrying Optional 2) unprintable
  reportOutcome logger reporting loadWidget outcome >>= accepted
  readIORef handed `shouldReturn` 0
  readIORef attempts `shouldReturn` 2
  case outcome of
    Available _ → expectationFailure "expected the optional operation to be unavailable"
    Unavailable unavailability → do
      map attemptNumber (unavailableEarlier unavailability) `shouldBe` [1]
      attemptNumber (unavailableReason unavailability) `shouldBe` 2
      case attemptException (unavailableReason unavailability) of
        ExceptionWithContext context failure → do
          widgetOf failure `shouldBe` Just WidgetUnprintable
          case failureCause (failureEvidenceInContext context) of
            EngineOrigin origin → originComponent origin `shouldBe` widgets
            NativeCause → expectationFailure "the attempt lost its origin"

-- Bounded reports -------------------------------------------------------------

testNoDuplicateTerminalError ∷ Expectation
testNoDuplicateTerminalError = do
  (sink, collected) ← newCollector
  attempts ← newIORef 0
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  propagated ←
    expectFailure $
      reportTerminalFailure logger reporting "Application failed" (pure []) $
        withOperationContext widgets (operation "start-widgets") [] $
          reportTerminalFailure logger reporting "Widget load failed" (pure []) $
            recover loadWidget (retrying Required 3) (flaky attempts 10)
  widgetOf propagated `shouldBe` Just (WidgetBroken 3)
  entries ← collected
  -- Three attempts and two boundaries, and one terminal error: at the boundary
  -- that handled it, summarizing the chain.
  summaries entries `shouldBe` [(Error, "test.reporting", "Widget load failed")]
  entry ← single entries
  field "recovery" entry `shouldBe` Just "recorded"
  field "attempts" entry `shouldBe` Just "3"
  field "attempts.earlier" entry `shouldBe` Just "1:initial,2:retry"
  field "attempts.terminal" entry `shouldBe` Just "3"
  readIORef attempts `shouldReturn` 3

-- Diagnostic failures ---------------------------------------------------------

testSinkFailureKeepsPrimary ∷ Expectation
testSinkFailureKeepsPrimary = do
  trace ← newIORef []
  attempts ← newIORef 0
  (logger, handed) ← newFailingSink trace
  let attempt =
        withScoped (allocResource (pure ()) (\_ → note trace "released")) $ \_ → do
          number ← flaky attempts 5
          note trace ("attempt " <> Text.pack (show number))
  propagated ←
    expectFailure $
      reportTerminalFailure logger reporting "Widget load failed" (pure []) $
        recover loadWidget (retrying Required 2) attempt
  -- The latest attempt's failure is still primary, with its history.
  widgetOf propagated `shouldBe` Just (WidgetBroken 2)
  map (map attemptNumber . historyAttempts) (recoveryHistory propagated) `shouldBe` [[1]]
  -- Every release completed before the one diagnostic, and the failed
  -- diagnostic caused no further attempt and no second write.
  readIORef trace `shouldReturn` ["released", "released", "sink"]
  readIORef attempts `shouldReturn` 2
  handed `shouldReturn` 1

testTerminalFormattingFailure ∷ Expectation
testTerminalFormattingFailure = do
  trace ← newIORef []
  attempts ← newIORef (0 ∷ Int)
  (logger, handed, formatted) ← newFormattingSink
  let attempt =
        withResourceLabelled
          "widget handle"
          (pure ())
          (\_ → note trace "released" >> ioError (userError "widget release failed"))
          (\_ → do
             atomicModifyIORef' attempts (\count → (count + 1, ()))
             throwFailure widgets loadWidget [] WidgetUnprintable)
  propagated ←
    expectFailure $
      reportTerminalFailure logger reporting "Widget load failed" (pure []) $
        recover loadWidget (retrying Required 3) attempt
  -- Formatting the report threw, and changed nothing the caller receives: the
  -- failure, its origin, and its retained cleanup evidence.
  widgetOf propagated `shouldBe` Just WidgetUnprintable
  map cleanupFailureLabel (cleanupFailures propagated) `shouldBe` ["widget handle"]
  case failureCause (failureEvidence propagated) of
    EngineOrigin origin → originComponent origin `shouldBe` widgets
    NativeCause → expectationFailure "the failure lost its origin"
  terminalReportAttempted propagated `shouldBe` True
  readIORef trace `shouldReturn` ["released"]
  readIORef attempts `shouldReturn` 1
  handed `shouldReturn` 1
  formatted `shouldReturn` []

testRecoveredFormattingFailure ∷ Expectation
testRecoveredFormattingFailure = do
  attempts ← newIORef (0 ∷ Int)
  (logger, handed, formatted) ← newFormattingSink
  let attempt = do
        number ← atomicModifyIORef' attempts (\count → (count + 1, count + 1))
        when (number == 1) $ throwFailure widgets loadWidget [] WidgetUnprintable
        pure number
  outcome ← recover loadWidget (retrying Required 3) attempt
  result ← reportOutcome logger reporting loadWidget outcome
  formattingFailure ← failedWith result
  (fromException formattingFailure ∷ Maybe ErrorCall) `shouldSatisfy` maybe False (const True)
  -- The recovered result the boundary selected is still the caller's.
  recoveredValueOf outcome `shouldReturn` 2
  readIORef attempts `shouldReturn` 2
  handed `shouldReturn` 1
  formatted `shouldReturn` []

testMarkedDiagnosticNotReported ∷ Expectation
testMarkedDiagnosticNotReported = do
  trace ← newIORef []
  (logger, handed) ← newFailingSink trace
  propagated ←
    expectFailure $
      reportTerminalFailure logger reporting "Widget load failed" (pure []) $
        markDiagnostic (logInfo logger reporting "Widget loaded" [])
  (ioeGetErrorString <$> fromException propagated) `shouldBe` Just "sink unavailable"
  (getExceptionAnnotations (someExceptionContext propagated) ∷ [DiagnosticFailure])
    `shouldBe` [DiagnosticFailure]
  -- Handed exactly the record that failed: no report went back through it.
  handed `shouldReturn` 1
  terminalReportAttempted propagated `shouldBe` False

-- Cancellation ----------------------------------------------------------------

testCancelledWhileReporting ∷ Expectation
testCancelledWhileReporting = do
  trace ← newIORef []
  entered ← newEmptyMVar
  held ← newEmptyMVar
  outcome ← newEmptyMVar
  let logger = loggerFor $ \entry →
        when (entryLevel entry == Error) (blockedAt entered held)
      work =
        withScoped (allocResource (pure ()) (\_ → note trace "released")) $ \_ →
          failAttempt 1 ∷ IO ()
  runner ←
    forkIO $
      try (reportTerminalFailure logger reporting "Widget load failed" (pure []) work)
        >>= putMVar outcome
  takeMVar entered
  killThread runner
  result ← takeMVar outcome
  case result of
    Right () → expectationFailure "the cancelled boundary returned"
    Left failure → do
      -- The cancellation, not the failure being reported.
      (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      widgetOf failure `shouldBe` Nothing
  readIORef trace `shouldReturn` ["released"]

testCancellationFromOutcomeReport ∷ Expectation
testCancellationFromOutcomeReport = do
  attempts ← newIORef 0
  let logger = loggerFor $ \_ → annotateIO ReportMark (throwIO ThreadKilled)
  outcome ← recover loadWidget (retrying Required 3) (flaky attempts 1)
  propagated ← expectFailure (reportOutcome logger reporting loadWidget outcome)
  (fromException propagated ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
  -- It escaped as the exception the sink raised, with its context unchanged.
  (getExceptionAnnotations (someExceptionContext propagated) ∷ [ReportMark])
    `shouldBe` [ReportMark]
  (getExceptionAnnotations (someExceptionContext propagated) ∷ [DiagnosticFailure])
    `shouldBe` []
  -- The outcome was already the caller's.
  recoveredValueOf outcome `shouldReturn` 2
  readIORef attempts `shouldReturn` 2
