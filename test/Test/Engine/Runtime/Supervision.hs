-- | Examples for 'Hetoimasia.Runtime.Supervision'.
--
-- Every example runs real foundation workers inside a real supervision
-- boundary and a logging lifetime over an injected collecting sink, with
-- synthetic typed failures. It observes what an application can see: what a
-- checkpoint or a supervised wait returned or threw, worker statuses, retained
-- failure evidence, warnings the sink received, and a trace of worker
-- resources.
--
-- Coordination is explicit: gates, 'MVar's, raw completion reads, and
-- 'awaitBlockedOnSTM' decide when a thread has reached the point an example
-- needs. No example sleeps, asserts a wall-clock bound, expects arbitrary
-- blocking IO to be interrupted, or uses a generic application runner;
-- 'boundedSupervision' only stops an example that has already hung.
module Test.Engine.Runtime.Supervision (spec) where

import Control.Concurrent (forkIO, killThread, myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (STM, atomically, check, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , WhileHandling (WhileHandling)
  , fromException
  , rethrowIO
  , someExceptionContext
  , throwIO
  , toException
  , try
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (addExceptionAnnotation, emptyExceptionContext, getExceptionAnnotations)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (LogEntry (..), LogLevel (..))
import Hetoimasia.Foundation.Resource (allocResource, cleanupFailuresInContext)
import Hetoimasia.Foundation.Worker
  ( Completion (..)
  , Requested (..)
  , Result (..)
  , RunEnd (..)
  , RunExit (..)
  , WorkerEvidence (..)
  , awaitCompletion
  , WorkerDefinition
  , awaitStopRequest
  , workerDefinition
  , workerEvidenceInContext
  , workerId
  )
import Hetoimasia.Runtime.Logging (recordedReports)
import Hetoimasia.Runtime.Reporting (ReportResult (..))
import Hetoimasia.Runtime.Supervision
import Test.Engine.Runtime.Supervision.Support
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Supervision" $ do
  describe "Waking" $ do
    it "wakes an active supervised wait when a required worker fails"
      (boundedSupervision testWakesSupervisedWait)
    it "wakes a startup wait and drains the new worker before the start unwinds"
      (boundedSupervision testWakesStartupWait)
    it "handles a ready failure before simultaneously ready caller work, leaving the work unconsumed"
      (boundedSupervision testFailureBeforeWork)

  describe "Startup" $ do
    it "handles an optional startup failure once, with one warning and no report at later checkpoints"
      (boundedSupervision testOptionalStartupFailureOnce)
    it "propagates a required startup failure once and never commits it again"
      (boundedSupervision testRequiredStartupFailureOnce)

  describe "Classification" $ do
    it "distinguishes finite-job completion from an expected exit after a requested stop"
      (boundedSupervision testJobAndStoppedService)
    it "fails an unexpected service exit under the service's requirement policy"
      (boundedSupervision testUnexpectedServiceExit)
    it "preserves an unexpected child cancellation as a typed termination without cancelling the observer"
      (boundedSupervision testUnexpectedTermination)
    it "fails the run for a cleanup failure on an optional worker"
      (boundedSupervision testOptionalCleanupFailure)
    it "keeps an unexpected cancellation unexpected when a stop or cancel is requested after publication"
      (boundedSupervision testLateRequestExplainsNothing)

  describe "Warnings and the fatal latch" $ do
    it "commits an optional disposition before its warning, and a failed warning neither repeats nor restores it"
      (boundedSupervision testWarningAfterCommit)
    it "keeps a caught fatal delivery latched through the final settlement"
      (boundedSupervision testCaughtFatalLatched)
    it "initiates owned shutdown on a caught fatal: siblings are asked to stop and a later start forks nothing"
      (boundedSupervision testFatalInitiatesShutdown)

  describe "Simultaneous failures" $ do
    it "selects the primary by registration order and retains every other typed failure"
      (boundedSupervision testRegistrationOrder)
    it "never selects an earlier optional failure as primary over a fatal one"
      (boundedSupervision testMixedBatch)
    it "keeps the application's own failure primary with worker failures beside it"
      (boundedSupervision testApplicationFailurePrimary)

  describe "Evidence across invocations" $ do
    it "retains an outer failure beside an inner primary whose worker has the same local ID"
      (boundedSupervision testNestedSameLocalId)
    it "keeps inner secondary evidence when an outer boundary retains its own failure"
      (boundedSupervision testNestedSecondaryKept)
    it "composes a caught delivery rethrown inside a later independent invocation"
      (boundedSupervision testLaterIndependentInvocation)
    it "retains each secondary once across repeated deliveries and adds a later failure"
      (boundedSupervision testRepeatedDeliveries)

  describe "Classifier failures" $ do
    it "stops supervision on a classifier failure, retaining the handled worker failure"
      (boundedSupervision testClassifierFailure)
    it "propagates cancellation during classification as the owner's and still drains workers"
      (boundedSupervision testCancelledClassification)

  describe "Closing" $ do
    it "keeps an exit before closing's stop request an unexpected service exit"
      (boundedSupervision testExitBeforeStopSurvivesClosing)
    it "observes a failure published before closing before the boundary returns"
      (boundedSupervision testFinalObservation)
    it "returns after an expected owner-requested cancellation and rejects a later start"
      (boundedSupervision testExpectedCancellationAndRejectedStart)

-- Helpers ----------------------------------------------------------------------

-- | Catch anything, keeping its context.
attempt ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
attempt = tryWithContext

ignoreWrites ∷ LogEntry → IO ()
ignoreWrites _ = pure ()

-- | A transaction that never completes on its own.
never ∷ IO (STM ())
never = do
  flag ← newTVarIO False
  pure (readTVar flag >>= check)

statusName ∷ WorkerStatus → Text
statusName = \case
  WorkerLive → "live"
  WorkerCompleted → "completed"
  WorkerStopped → "stopped"
  WorkerUnavailable _ → "unavailable"
  WorkerFatal _ → "fatal"

statusOf ∷ SupervisedWorker r → IO Text
statusOf worker = statusName <$> atomically (workerStatus worker)

retainedLabels ∷ ExceptionWithContext SomeException → [(Text, Severity)]
retainedLabels (ExceptionWithContext context _) =
  [(failedLabel entry, failedSeverity entry) | entry ← supervisedFailuresInContext context]

-- | A context annotation a worker attaches to its own failure.
newtype Provenance = Provenance Text

instance ExceptionAnnotation Provenance where
  displayExceptionAnnotation (Provenance name) = "raised by " <> show name

-- | A worker that throws once its gate opens, with a 'Provenance' naming it in
-- the failure's context.
annotatedFailingAfter ∷ Trace → Text → Gate → WorkerDefinition ()
annotatedFailingAfter trace name gate =
  workerDefinition name (\_ → owned trace name) $ \_ () → do
    readMVar gate
    rethrowIO (ExceptionWithContext (addExceptionAnnotation (Provenance name) emptyExceptionContext) (toException (Broken name)))

-- | What one retained failure preserved: label, severity, worker ID, typed
-- payload, and the provenance its context carries.
data Kept = Kept Text Severity String (Maybe Broken) [Text]
  deriving (Eq, Show)

kept ∷ SupervisedFailure → Kept
kept entry =
  let ExceptionWithContext context raised = failedException entry
   in Kept
        (failedLabel entry)
        (failedSeverity entry)
        (show (failedWorker entry))
        (fromException raised)
        [name | Provenance name ← getExceptionAnnotations context]

-- | Retained evidence read through both public inspection functions, which
-- must agree.
inspected ∷ SomeException → IO [Kept]
inspected raised = do
  let direct = map kept (supervisedFailures raised)
  map kept (supervisedFailuresInContext (someExceptionContext raised)) `shouldBe` direct
  pure direct

-- | The evidence one worker's failure should keep.
keptFor ∷ SupervisedWorker () → Text → Kept
keptFor worker name =
  Kept name Fatal (show (workerId (supervisedWorker worker))) (Just (Broken name)) [name]

expectRaised ∷ IO a → IO SomeException
expectRaised action = try action >>= either pure (\_ → throwIO (userError "expected a failure, but it returned"))

-- Waking -----------------------------------------------------------------------

testWakesSupervisedWait ∷ Expectation
testWakesSupervisedWait = do
  trace ← newTrace
  gate ← newGate
  application ← myThreadId
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      _ ← expectStarted =<< startSupervised control (required Service) (failingAfter trace "renderer" gate (Broken "renderer"))
      _ ← forkIO (awaitBlockedOnSTM application >> openGate gate)
      waiting ← never
      awaitSupervised control waiting
  failure `shouldSatisfy` brokenIs "renderer"
  traced trace >>= (`shouldBe` ["acquire renderer", "release renderer"])

testWakesStartupWait ∷ Expectation
testWakesStartupWait = do
  trace ← newTrace
  gate ← newGate
  entered ← newEmptyMVar
  held ← newEmptyMVar
  application ← myThreadId
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      _ ← expectStarted =<< startSupervised control (required Service) (failingAfter trace "audio" gate (Broken "audio"))
      _ ← forkIO (readMVar entered >> awaitBlockedOnSTM application >> openGate gate)
      let slow =
            workerDefinition
              "streaming"
              (\_ → owned trace "streaming" >> liftIO (putMVar entered () >> takeMVar held))
              (\_ () → pure ())
      started ← attempt (startSupervised control (required Service) slow)
      record trace "start unwound"
      either (\(ExceptionWithContext _ raised) → throwIO raised) (\_ → fail "the start returned") started
  failure `shouldSatisfy` brokenIs "audio"
  -- The new worker was drained, its startup resource released, before the start
  -- operation unwound.
  traced trace
    >>= (`shouldBe` ["acquire audio", "acquire streaming", "release audio", "release streaming", "start unwound"])

testFailureBeforeWork ∷ Expectation
testFailureBeforeWork = do
  trace ← newTrace
  gate ← newGate
  queue ← newTVarIO [1 ∷ Int]
  observed ← newIORef Nothing
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      worker ← expectStarted =<< startSupervised control (required Service) (failingAfter trace "physics" gate (Broken "physics"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      let take' = readTVar queue >>= \case
            item : rest → writeTVar queue rest >> pure item
            [] → retry
      waited ← attempt (awaitSupervised control take')
      writeIORef observed (Just (either (brokenIs "physics") (const False) waited))
  failure `shouldSatisfy` brokenIs "physics"
  readIORef observed >>= (`shouldBe` Just True)
  readTVarIO queue >>= (`shouldBe` [1])

-- Startup ----------------------------------------------------------------------

testOptionalStartupFailureOnce ∷ Expectation
testOptionalStartupFailureOnce = do
  (status, warnings) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ←
        startSupervised control (optional Service) $
          workerDefinition "telemetry" (\_ → liftIO (throwIO (Broken "telemetry"))) (\_ () → pure ())
      worker ← case started of
        WorkerStartUnavailable worker failure → do
          failure `shouldSatisfy` brokenIs "telemetry"
          pure worker
        _ → fail "expected the optional worker to be unavailable"
      first ← warningCount collected
      checkRuntime control
      checkRuntime control
      later ← warningCount collected
      status ← statusOf worker
      pure (status, (first, later))
  status `shouldBe` "unavailable"
  warnings `shouldBe` (1, 1)

testRequiredStartupFailureOnce ∷ Expectation
testRequiredStartupFailureOnce = do
  deliveries ← newIORef []
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      let loader = workerDefinition "loader" (\_ → liftIO (throwIO (Broken "loader"))) (\_ () → pure ())
      started ← attempt (startSupervised control (required Service) loader)
      later ← attempt (checkRuntime control)
      writeIORef deliveries [fmap (const ()) started, later]
  failure `shouldSatisfy` brokenIs "loader"
  retainedLabels failure `shouldBe` []
  delivered ← readIORef deliveries
  map (either (brokenIs "loader") (const False)) delivered `shouldBe` [True, True]
  -- Delivered again, never committed again: nothing else is retained beside it.
  map (either retainedLabels (const [])) delivered `shouldBe` [[], []]

-- Classification ---------------------------------------------------------------

testJobAndStoppedService ∷ Expectation
testJobAndStoppedService = do
  trace ← newTrace
  (value, statuses, exit) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      counted ← expectStarted =<< startSupervised control (required Job) (job "count" (\_ → pure (5 ∷ Int)))
      completion ← awaitSupervised control (awaitCompletion (supervisedWorker counted))
      service ← expectStarted =<< startSupervised control (required Service) (serviceUntilStopped trace "network")
      stopSupervised service
      stopped ← awaitSupervised control (awaitCompletion (supervisedWorker service))
      checkRuntime control
      statuses ← (,) <$> statusOf counted <*> statusOf service
      value ← case completionResult completion of
        Succeeded result → pure result
        _ → fail "the job did not succeed"
      pure (value, statuses, completionExit stopped)
  value `shouldBe` 5
  statuses `shouldBe` ("completed", "stopped")
  exit `shouldBe` RunExited RunReturned StopWasRequested

testUnexpectedServiceExit ∷ Expectation
testUnexpectedServiceExit = do
  trace ← newTrace
  gate ← newGate
  failure@(ExceptionWithContext _ raised) ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      worker ← expectStarted =<< startSupervised control (required Service) (returningAfter trace "cache" gate)
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      checkRuntime control
  case fromException raised of
    Just (UnexpectedServiceExit summary) → do
      completionLabel summary `shouldBe` "cache"
      completionExit summary `shouldBe` RunExited RunReturned NothingRequested
    Nothing → expectationFailure ("expected an unexpected service exit, found " <> show failure)

testUnexpectedTermination ∷ Expectation
testUnexpectedTermination = do
  thread ← newEmptyMVar
  observer ← newIORef False
  failure@(ExceptionWithContext _ raised) ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      let decoder =
            workerDefinition "decoder" (\_ → pure ()) $ \token () → do
              myThreadId >>= putMVar thread
              atomically (awaitStopRequest token)
      worker ← expectStarted =<< startSupervised control (required Service) decoder
      takeMVar thread >>= (`throwTo` ThreadKilled)
      _ ← awaitTerminal (supervisedWorker worker)
      checked ← attempt (checkRuntime control)
      -- The observer is still running: what it caught is synchronous.
      writeIORef observer True
      either (\(ExceptionWithContext _ caught) → throwIO caught) pure checked
  readIORef observer >>= (`shouldBe` True)
  case fromException raised of
    Just (UnexpectedWorkerTermination summary) → do
      completionLabel summary `shouldBe` "decoder"
      case completionResult summary of
        Cancelled (ExceptionWithContext _ cancellation) →
          fromException cancellation `shouldBe` Just ThreadKilled
        _ → expectationFailure "the child's cancellation evidence was lost"
    Nothing → expectationFailure ("expected an unexpected termination, found " <> show failure)

testOptionalCleanupFailure ∷ Expectation
testOptionalCleanupFailure = do
  gate ← newGate
  failure@(ExceptionWithContext context _) ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      let writer =
            workerDefinition
              "cache-writer"
              (\_ → allocResource (pure ()) (\() → throwIO (Broken "release")))
              (\_ () → readMVar gate)
      worker ← expectStarted =<< startSupervised control (optional Job) writer
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      checkRuntime control
  -- Recognized and optional, yet fatal, because its cleanup failed.
  failure `shouldSatisfy` brokenIs "release"
  length (cleanupFailuresInContext context) `shouldBe` 1

testLateRequestExplainsNothing ∷ Expectation
testLateRequestExplainsNothing = do
  thread ← newEmptyMVar
  failure@(ExceptionWithContext _ raised) ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      let decoder =
            workerDefinition "decoder" (\_ → pure ()) $ \token () → do
              myThreadId >>= putMVar thread
              atomically (awaitStopRequest token)
      worker ← expectStarted =<< startSupervised control (required Service) decoder
      -- A foreign cancellation ends the worker before its owner asks anything.
      takeMVar thread >>= (`throwTo` ThreadKilled)
      _ ← awaitTerminal (supervisedWorker worker)
      -- Both requests race in after the outcome was published, before any
      -- checkpoint handled it. Neither may explain that outcome.
      stopSupervised worker
      cancelSupervised worker
      checkRuntime control
  case fromException raised of
    Just (UnexpectedWorkerTermination summary) → do
      completionExit summary `shouldBe` RunExited RunCancelled NothingRequested
      case completionResult summary of
        Cancelled _ → pure ()
        _ → expectationFailure "expected the worker's cancellation to be retained"
    Nothing → expectationFailure ("expected an unexpected termination, found " <> show failure)

-- Warnings and the fatal latch -------------------------------------------------

testWarningAfterCommit ∷ Expectation
testWarningAfterCommit = do
  trace ← newTrace
  gate ← newGate
  slot ← newEmptyMVar
  seen ← newIORef []
  let failingWarning entry = when (entryLevel entry == Warning) $ do
        worker ← readMVar slot
        status ← statusOf worker
        modifyIORef' seen (<> [status])
        ioError (userError "sink unavailable")
  (status, warnings, reports) ← withCollectedLifetime failingWarning $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      worker ← expectStarted =<< startSupervised control (optional Service) (failingAfter trace "overlay" gate (Broken "overlay"))
      putMVar slot worker
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      checkRuntime control
      checkRuntime control
      status ← statusOf worker
      warnings ← warningCount collected
      reports ← recordedReports (collectedLifetime collected)
      pure (status, warnings, [() | ReportFailed _ ← reports])
  readIORef seen >>= (`shouldBe` ["unavailable"])
  status `shouldBe` "unavailable"
  warnings `shouldBe` 1
  reports `shouldBe` [()]

testCaughtFatalLatched ∷ Expectation
testCaughtFatalLatched = do
  trace ← newTrace
  gate ← newGate
  caught ← newIORef []
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      worker ← expectStarted =<< startSupervised control (required Service) (failingAfter trace "input" gate (Broken "input"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      first ← attempt (checkRuntime control)
      second ← attempt (checkRuntime control)
      waited ← attempt (awaitSupervised control (pure ()))
      writeIORef caught (map (either (brokenIs "input") (const False)) [first, second, waited])
      -- The application handled every delivery and returns normally.
      pure ()
  readIORef caught >>= (`shouldBe` [True, True, True])
  failure `shouldSatisfy` brokenIs "input"

testFatalInitiatesShutdown ∷ Expectation
testFatalInitiatesShutdown = do
  trace ← newTrace
  gate ← newGate
  observed ← newIORef Nothing
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      sibling ← expectStarted =<< startSupervised control (required Service) (serviceUntilStopped trace "sibling")
      worker ← expectStarted =<< startSupervised control (required Service) (failingAfter trace "engine" gate (Broken "engine"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      delivered ← attempt (checkRuntime control)
      -- The application caught the delivery, and its sibling was still asked
      -- to stop: waiting for it returns rather than hanging.
      stopped ← awaitTerminal (supervisedWorker sibling)
      late ← attempt (startSupervised control (required Service) (serviceUntilStopped trace "late"))
      writeIORef observed $
        Just
          ( either (brokenIs "engine") (const False) delivered
          , completionExit stopped
          , either (brokenIs "engine") (const False) late
          )
  failure `shouldSatisfy` brokenIs "engine"
  readIORef observed >>= (`shouldBe` Just (True, RunExited RunReturned StopWasRequested, True))
  traced trace >>= (`shouldSatisfy` notElem "acquire late")

-- Simultaneous failures --------------------------------------------------------

testRegistrationOrder ∷ Expectation
testRegistrationOrder = do
  trace ← newTrace
  gates ← traverse (const newGate) [(), (), ()]
  caught ← newIORef Nothing
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      workers ←
        traverse
          (\(name, gate) → expectStarted =<< startSupervised control (required Service) (failingAfter trace name gate (Broken name)))
          (zip ["a", "b", "c"] gates)
      -- They fail in the reverse of registration order, each observed raw.
      mapM_ (\(gate, worker) → openGate gate >> awaitTerminal (supervisedWorker worker)) (reverse (zip gates workers))
      attempt (checkRuntime control) >>= writeIORef caught . Just
  Just delivered ← readIORef caught
  either (brokenIs "a") (const False) delivered `shouldBe` True
  either retainedLabels (const []) delivered `shouldBe` [("b", Fatal), ("c", Fatal)]
  failure `shouldSatisfy` brokenIs "a"
  let ExceptionWithContext context _ = failure
      retained = supervisedFailuresInContext context
  [brokenIs name (failedException entry) | (name, entry) ← zip ["b", "c"] retained] `shouldBe` [True, True]

testMixedBatch ∷ Expectation
testMixedBatch = do
  trace ← newTrace
  hudGate ← newGate
  inputGate ← newGate
  observed ← newIORef Nothing
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      hud ← expectStarted =<< startSupervised control (optional Service) (failingAfter trace "hud" hudGate (Broken "hud"))
      input ← expectStarted =<< startSupervised control (required Service) (failingAfter trace "input" inputGate (Broken "input"))
      openGate hudGate >> openGate inputGate
      _ ← awaitTerminal (supervisedWorker hud)
      _ ← awaitTerminal (supervisedWorker input)
      checked ← attempt (checkRuntime control)
      statuses ← (,) <$> statusOf hud <*> statusOf input
      warnings ← warningCount collected
      writeIORef observed (Just (either (brokenIs "input") (const False) checked, statuses, warnings))
  readIORef observed >>= (`shouldBe` Just (True, ("unavailable", "fatal"), 1))
  failure `shouldSatisfy` brokenIs "input"
  retainedLabels failure `shouldBe` [("hud", Tolerated)]

testApplicationFailurePrimary ∷ Expectation
testApplicationFailurePrimary = do
  trace ← newTrace
  gate ← newGate
  failure@(ExceptionWithContext _ raised) ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      worker ← expectStarted =<< startSupervised control (required Service) (failingAfter trace "ai" gate (Broken "ai"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      throwIO (ErrorCall "application failed") ∷ IO ()
  fromException raised `shouldBe` Just (ErrorCall "application failed")
  retainedLabels failure `shouldBe` [("ai", Fatal)]

-- Classifier failures ----------------------------------------------------------

testClassifierFailure ∷ Expectation
testClassifierFailure = do
  trace ← newTrace
  gate ← newGate
  deliveries ← newIORef []
  let policy = WorkerPolicy Service Optional supervisionComponent (\_ → throwIO (ErrorCall "classifier broke"))
  ExceptionWithContext context raised ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      worker ← expectStarted =<< startSupervised control policy (failingAfter trace "flaky" gate (Broken "flaky"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      first ← attempt (checkRuntime control)
      second ← attempt (checkRuntime control)
      writeIORef deliveries [first, second]
  fromException raised `shouldBe` Just (ErrorCall "classifier broke")
  [fromException handled | WhileHandling handled ← getExceptionAnnotations context]
    `shouldBe` [Just (Broken "flaky")]
  delivered ← readIORef deliveries
  [fromException caught | Left (ExceptionWithContext _ caught) ← delivered]
    `shouldBe` [Just (ErrorCall "classifier broke"), Just (ErrorCall "classifier broke")]

testCancelledClassification ∷ Expectation
testCancelledClassification = do
  trace ← newTrace
  gate ← newGate
  entered ← newEmptyMVar
  held ← newEmptyMVar
  done ← newEmptyMVar
  let blocking = WorkerPolicy Service Optional supervisionComponent $ \_ →
        putMVar entered () >> takeMVar held >> pure Recognized
  owner ← forkIO $ do
    outcome ← attempt $ withCollectedLifetime ignoreWrites $ \collected →
      withSupervision (collectedLifetime collected) $ \control → do
        _ ← expectStarted =<< startSupervised control (required Service) (serviceUntilStopped trace "stream")
        worker ← expectStarted =<< startSupervised control blocking (failingAfter trace "flaky" gate (Broken "flaky"))
        openGate gate
        _ ← awaitTerminal (supervisedWorker worker)
        checkRuntime control
    putMVar done outcome
  takeMVar entered
  killThread owner
  outcome ← takeMVar done
  case outcome of
    Right () → expectationFailure "the cancelled owner returned"
    Left (ExceptionWithContext context raised) → do
      fromException raised `shouldBe` Just ThreadKilled
      -- The group drained first and left its report as raw evidence.
      length [() | GroupExit _ ← workerEvidenceInContext context] `shouldBe` 1
  entries ← traced trace
  entries `shouldSatisfy` elem "release stream"
  entries `shouldSatisfy` elem "release flaky"

-- Closing ----------------------------------------------------------------------

testExitBeforeStopSurvivesClosing ∷ Expectation
testExitBeforeStopSurvivesClosing = do
  trace ← newTrace
  gate ← newGate
  inRelease ← newGate
  releaseGate ← newGate
  handles ← newIORef []
  application ← myThreadId
  failure@(ExceptionWithContext _ raised) ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      let watcher =
            workerDefinition
              "watcher"
              (\_ → allocResource (pure ()) (\() → openGate inRelease >> readMVar releaseGate >> record trace "release watcher"))
              (\_ () → readMVar gate)
      watching ← expectStarted =<< startSupervised control (required Service) watcher
      listening ← expectStarted =<< startSupervised control (required Service) (serviceUntilStopped trace "listener")
      writeIORef handles [watching, listening]
      openGate gate
      -- The run action has exited and its cleanup is still running when the
      -- body returns and closing requests every stop.
      readMVar inRelease
      _ ← forkIO (awaitBlockedOnSTM application >> openGate releaseGate)
      pure ()
  case fromException raised of
    Just (UnexpectedServiceExit summary) → do
      completionLabel summary `shouldBe` "watcher"
      completionExit summary `shouldBe` RunExited RunReturned NothingRequested
    Nothing → expectationFailure ("expected an unexpected service exit, found " <> show failure)
  readIORef handles >>= traverse statusOf >>= (`shouldBe` ["fatal", "stopped"])

testFinalObservation ∷ Expectation
testFinalObservation = do
  trace ← newTrace
  gate ← newGate
  retained ← newIORef Nothing
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      exporter ← expectStarted =<< startSupervised control (required Job) (failingAfter trace "export" gate (Broken "export"))
      writeIORef retained (Just exporter)
      openGate gate
      _ ← awaitTerminal (supervisedWorker exporter)
      -- No checkpoint: the boundary must observe it before returning.
      pure (1 ∷ Int)
  failure `shouldSatisfy` brokenIs "export"
  Just exporter ← readIORef retained
  statusOf exporter >>= (`shouldBe` "fatal")

testExpectedCancellationAndRejectedStart ∷ Expectation
testExpectedCancellationAndRejectedStart = do
  trace ← newTrace
  (result, control, service) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      service ← expectStarted =<< startSupervised control (required Service) (serviceUntilStopped trace "sampler")
      cancelSupervised service
      _ ← awaitTerminal (supervisedWorker service)
      pure (9 ∷ Int, control, service)
  result `shouldBe` 9
  statusOf service >>= (`shouldBe` "stopped")
  late ← startSupervised control (required Service) (serviceUntilStopped trace "late")
  case late of
    WorkerStartRejected → pure ()
    _ → expectationFailure "a start after closing was not rejected"
  -- Nothing of the rejected worker ran.
  traced trace >>= (`shouldBe` ["acquire sampler", "release sampler"])

-- Evidence across invocations --------------------------------------------------

testNestedSameLocalId ∷ Expectation
testNestedSameLocalId = do
  trace ← newTrace
  outerGate ← newGate
  innerGate ← newGate
  handles ← newIORef Nothing
  raised ← expectRaised $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \outer → do
      outerWorker ← expectStarted =<< startSupervised outer (required Job) (annotatedFailingAfter trace "outer" outerGate)
      withSupervision (collectedLifetime collected) $ \inner → do
        innerWorker ← expectStarted =<< startSupervised inner (required Job) (annotatedFailingAfter trace "inner" innerGate)
        writeIORef handles (Just (outerWorker, innerWorker))
        openGate outerGate >> openGate innerGate
        _ ← awaitTerminal (supervisedWorker outerWorker)
        _ ← awaitTerminal (supervisedWorker innerWorker)
        checkRuntime inner
  Just (outerWorker, innerWorker) ← readIORef handles
  -- Both workers have the same local ID in their own groups.
  workerId (supervisedWorker outerWorker) `shouldBe` workerId (supervisedWorker innerWorker)
  fromException raised `shouldBe` Just (Broken "inner")
  inspected raised >>= (`shouldBe` [keptFor outerWorker "outer"])

testNestedSecondaryKept ∷ Expectation
testNestedSecondaryKept = do
  trace ← newTrace
  outerGate ← newGate
  primaryGate ← newGate
  secondaryGate ← newGate
  handles ← newIORef Nothing
  raised ← expectRaised $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \outer → do
      finished ← expectStarted =<< startSupervised outer (required Job) (job "finished" (\_ → pure ()))
      _ ← awaitSupervised outer (awaitCompletion (supervisedWorker finished))
      outerWorker ← expectStarted =<< startSupervised outer (required Job) (annotatedFailingAfter trace "outer" outerGate)
      withSupervision (collectedLifetime collected) $ \inner → do
        primary ← expectStarted =<< startSupervised inner (required Job) (annotatedFailingAfter trace "inner-primary" primaryGate)
        secondary ← expectStarted =<< startSupervised inner (required Job) (annotatedFailingAfter trace "inner-secondary" secondaryGate)
        writeIORef handles (Just (outerWorker, secondary))
        openGate outerGate >> openGate primaryGate >> openGate secondaryGate
        mapM_ (awaitTerminal . supervisedWorker) [outerWorker, primary, secondary]
        checkRuntime inner
  Just (outerWorker, secondary) ← readIORef handles
  fromException raised `shouldBe` Just (Broken "inner-primary")
  inspected raised >>= (`shouldBe` [keptFor secondary "inner-secondary", keptFor outerWorker "outer"])

testLaterIndependentInvocation ∷ Expectation
testLaterIndependentInvocation = do
  trace ← newTrace
  primaryGate ← newGate
  secondaryGate ← newGate
  laterGate ← newGate
  handles ← newIORef Nothing
  raised ← expectRaised $ withCollectedLifetime ignoreWrites $ \collected → do
    earlier ← attempt $ withSupervision (collectedLifetime collected) $ \control → do
      primary ← expectStarted =<< startSupervised control (required Job) (annotatedFailingAfter trace "earlier-primary" primaryGate)
      secondary ← expectStarted =<< startSupervised control (required Job) (annotatedFailingAfter trace "earlier-secondary" secondaryGate)
      openGate primaryGate >> openGate secondaryGate
      mapM_ (awaitTerminal . supervisedWorker) [primary, secondary]
      writeIORef handles (Just (primary, secondary, Nothing))
      checkRuntime control
    delivered ← either pure (\_ → fail "the earlier invocation returned") earlier
    withSupervision (collectedLifetime collected) $ \control → do
      later ← expectStarted =<< startSupervised control (required Job) (annotatedFailingAfter trace "later" laterGate)
      modifyIORef' handles (fmap (\(primary, secondary, _) → (primary, secondary, Just later)))
      openGate laterGate
      _ ← awaitTerminal (supervisedWorker later)
      rethrowIO delivered ∷ IO ()
  Just (primary, secondary, Just later) ← readIORef handles
  -- The later invocation's worker shares its local ID with the delivered primary.
  workerId (supervisedWorker later) `shouldBe` workerId (supervisedWorker primary)
  fromException raised `shouldBe` Just (Broken "earlier-primary")
  inspected raised >>= (`shouldBe` [keptFor secondary "earlier-secondary", keptFor later "later"])

testRepeatedDeliveries ∷ Expectation
testRepeatedDeliveries = do
  trace ← newTrace
  primaryGate ← newGate
  secondaryGate ← newGate
  laterGate ← newGate
  observed ← newIORef Nothing
  raised ← expectRaised $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      primary ← expectStarted =<< startSupervised control (required Job) (annotatedFailingAfter trace "primary" primaryGate)
      secondary ← expectStarted =<< startSupervised control (required Job) (annotatedFailingAfter trace "secondary" secondaryGate)
      later ← expectStarted =<< startSupervised control (required Job) (annotatedFailingAfter trace "later" laterGate)
      openGate primaryGate >> openGate secondaryGate
      mapM_ (awaitTerminal . supervisedWorker) [primary, secondary]
      first ← try @SomeException (checkRuntime control)
      -- A further failure is committed after the first delivery.
      openGate laterGate
      _ ← awaitTerminal (supervisedWorker later)
      second ← try @SomeException (checkRuntime control)
      waited ← try @SomeException (awaitSupervised control (pure ()))
      writeIORef observed (Just (secondary, later, [first, second, waited]))
      -- The application rethrows the first delivery it caught.
      either (\caught → rethrowIO (ExceptionWithContext (someExceptionContext caught) caught)) pure first
  Just (secondary, later, deliveries) ← readIORef observed
  caught ← traverse (either pure (\() → throwIO (userError "a delivery returned"))) deliveries
  map fromException caught `shouldBe` replicate 3 (Just (Broken "primary"))
  evidence ← traverse inspected caught
  evidence
    `shouldBe` [ [keptFor secondary "secondary"]
               , [keptFor secondary "secondary", keptFor later "later"]
               , [keptFor secondary "secondary", keptFor later "later"]
               ]
  fromException raised `shouldBe` Just (Broken "primary")
  inspected raised >>= (`shouldBe` [keptFor secondary "secondary", keptFor later "later"])
