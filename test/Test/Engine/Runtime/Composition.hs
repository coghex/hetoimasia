-- | Examples for 'runScopedApplication', the generic application lifecycle.
--
-- Two unrelated applications drive the same runner: a workshop whose
-- dependencies are a store and a composite bench, whose services carry a
-- supervised service worker; and a station whose dependencies are a required
-- logbook and an optional radio built with 'allocComponent', whose services
-- publish the radio's availability. Neither type is known to the runtime.
--
-- The examples prove the composition, not the matrices it reuses: supervision's
-- classification and closing are proven by "Test.Engine.Runtime.Supervision",
-- whose fixtures these examples borrow, and the finalization matrix by
-- "Test.Engine.Runtime.Lifetime". Coordination is explicit, through gates,
-- STM, and 'awaitBlockedOnSTM'; nothing sleeps.
module Test.Engine.Runtime.Composition (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , throwIO
  , try
  , tryWithContext
  )
import Control.Monad (void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Foundation.Log
  ( LogEntry (..)
  , LogLevel (..)
  , Logger
  , callbackSinkWith
  , defaultLogFilter
  , mkLoggerWith
  )
import Hetoimasia.Foundation.Recovery
  ( AttemptFailure (..)
  , Outcome (..)
  , RecoveryPolicy (..)
  , Recovered (..)
  , Strategy (Retry)
  , Unavailability (..)
  , allocComponent
  )
import Hetoimasia.Foundation.Failure (operation)
import Hetoimasia.Foundation.Resource
  ( Scoped
  , acquirePart
  , allocComposite
  , allocResource
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , releaseRank
  , restoredStep
  )
import Hetoimasia.Foundation.Worker (awaitStopRequest, workerDefinition)
import Hetoimasia.Runtime.Application (runScopedApplication)
import Hetoimasia.Runtime.Logging (failedReportsInContext, withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Disposition (..)
  , Role (..)
  , RuntimeControl
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerStatus (..)
  , awaitSupervised
  , startSupervised
  , workerStatus
  )
import System.IO.Error (ioeGetErrorString)
import Test.Engine.Logging.Support (fixedMetadata)
import Test.Engine.Runtime.Supervision.Support
  ( Broken (..)
  , Trace
  , awaitBlockedOnSTM
  , boundedSupervision
  , brokenIs
  , expectFailure
  , expectStarted
  , failingAfter
  , newGate
  , newTrace
  , openGate
  , optional
  , record
  , required
  , serviceUntilStopped
  , traced
  )
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  , shouldSatisfy
  )

spec ∷ Spec
spec = describe "Application lifecycle" $ do
  describe "Order" $ do
    it "runs startup and the action on the calling thread, drains workers, then disposes dependents before dependencies"
      testLifecycleOrder
    it "publishes an optional component's unavailability truthfully in the services value"
      testOptionalUnavailable
  describe "Partial startup and cancellation" $ do
    it "disposes what construction acquired without running startup, then reports once before the flush"
      testConstructionFailure
    it "drains a worker a failing startup started before disposing its dependencies"
      testStartupFailure
    it "drains workers before dependency disposal on owner cancellation, unreported and unflushed"
      testCancellation
  describe "Truthful outcomes" $ do
    it "never turns a caught supervised failure into a successful run"
      testCaughtSupervisedFailure
    it "observes a worker failure that arrives while closing before accepting the result"
      testFailureWhileClosing
    it "keeps a component cleanup failure in the one terminal report, after disposal and before the flush"
      testCleanupFailureReported
    it "fails a successful run whose final flush fails, flushing once and reporting nothing"
      testFlushFailure
    it "attempts no terminal report once a managed report has failed"
      testKnownFailedDiagnostic

-- Harness ----------------------------------------------------------------------

-- | A collecting logger whose writes and flushes land in the same trace as the
-- acquisitions and releases, as @write <message>@ and @flush@, before the
-- injected write or flush outcome runs.
data Harness = Harness
  { harnessTrace ∷ Trace
  , harnessEntries ∷ IORef [LogEntry]
  , harnessLogger ∷ Logger
  }

newHarness ∷ (LogEntry → IO ()) → IO () → IO Harness
newHarness onWrite onFlush = do
  trace ← newTrace
  entries ← newIORef []
  let write entry = do
        atomicModifyIORef' entries (\collected → (collected <> [entry], ()))
        record trace ("write " <> entryMessage entry)
        onWrite entry
      flush = record trace "flush" >> onFlush
  pure (Harness trace entries (mkLoggerWith defaultLogFilter fixedMetadata (callbackSinkWith write flush)))

-- | The runner over the harness's logger, under one application name.
runIn ∷ Harness → Scoped d → (d → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
runIn harness = runScopedApplication (withLoggingLifetime (harnessLogger harness)) "test-app"

ignoreWrites ∷ LogEntry → IO ()
ignoreWrites _ = pure ()

errorEntries ∷ Harness → IO [LogEntry]
errorEntries harness = filter ((== Error) . entryLevel) <$> readIORef (harnessEntries harness)

flushes ∷ Harness → IO Int
flushes harness = length . filter (== "flush") <$> traced (harnessTrace harness)

-- | The trace from the first occurrence of an entry on.
from ∷ Text → [Text] → [Text]
from entry = dropWhile (/= entry)

-- | Exactly one @Application failed@ record, naming the application.
expectOneReport ∷ Harness → IO LogEntry
expectOneReport harness =
  errorEntries harness >>= \case
    [entry] → do
      entryMessage entry `shouldBe` "Application failed"
      Map.lookup "application" (entryFields entry) `shouldBe` Just "test-app"
      pure entry
    entries → do
      expectationFailure ("expected one terminal report, found " <> show (length entries))
      throwIO (userError "unreachable")

-- The workshop ---------------------------------------------------------------

-- | The workshop's dependencies: a store, and a bench built on it as a
-- composite whose declared release order is its acquisition order.
newtype Workshop = Workshop {workshopBench ∷ Text}

-- | The workshop's services, assembled by its startup.
data Floor = Floor
  { floorBench ∷ Text
  , floorPolisher ∷ SupervisedWorker ()
  }

-- | Construct the workshop, with an injected outcome for the store's release.
workshop ∷ Trace → IO () → Scoped Workshop
workshop trace storeRelease = do
  store ← allocResource (record trace "acquire store" >> pure "store") (\_ → record trace "release store" >> storeRelease)
  bench ← allocComposite $ do
    acquirePart "frame" (releaseRank 0) (record trace "acquire frame") (\() → record trace "release frame")
    acquirePart "vice" (releaseRank 1) (record trace "acquire vice") (\() → record trace "release vice")
    pure (store <> " bench")
  pure (Workshop bench)

-- | Start the polisher, a required service using the bench, and publish the
-- floor.
openFloor ∷ Trace → Workshop → RuntimeControl → IO Floor
openFloor trace built control = do
  record trace "startup"
  polisher ← startSupervised control (required Service) (serviceUntilStopped trace "polisher") >>= expectStarted
  pure (Floor (workshopBench built) polisher)

-- | Everything the workshop acquires, in boot order.
workshopBoot ∷ [Text]
workshopBoot = ["acquire store", "acquire frame", "acquire vice"]

-- | The workshop's disposal: dependents first, the composite in its declared
-- order, the store last.
workshopDisposal ∷ [Text]
workshopDisposal = ["release frame", "release vice", "release store"]

-- The station ------------------------------------------------------------------

-- | The station's dependencies: a required logbook and an optional radio.
data Station = Station Text (Outcome Text)

-- | The station's services: its logbook, and whether the radio is on the air or
-- why not.
data Schedule = Schedule Text (Either Text Text)
  deriving (Eq, Show)

-- | Construct the station. The radio's one attempt acquires an antenna and then
-- fails with a recognized failure, so the optional component binds
-- 'Unavailable' after rolling the antenna back.
station ∷ Trace → Scoped Station
station trace = do
  logbook ← allocResource (record trace "acquire logbook" >> pure "logbook") (\_ → record trace "release logbook")
  radio ← allocComponent (operation "radio") radioPolicy $ do
    acquirePart "antenna" (releaseRank 0) (record trace "acquire antenna") (\() → record trace "release antenna")
    restoredStep (throwIO (Broken "no signal"))
  pure (Station logbook radio)
  where
    radioPolicy = RecoveryPolicy
      { policyDisposition = Optional
      , policyBudget = 1
      , policyClassifier = \_ → pure (Just Retry)
      , policyWait = \_ → pure ()
      }

-- | Publish the schedule from the radio's availability value.
publishSchedule ∷ Trace → Station → RuntimeControl → IO Schedule
publishSchedule trace (Station logbook radio) _ = do
  record trace "startup"
  pure . Schedule logbook $ case radio of
    Available recovered → Right (recoveredValue recovered)
    Unavailable unavailability → case attemptException (unavailableReason unavailability) of
      ExceptionWithContext _ failure → Left (maybe "unrecognized" (\(Broken reason) → reason) (fromException failure))

-- Order ------------------------------------------------------------------------

testLifecycleOrder ∷ Expectation
testLifecycleOrder = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  caller ← myThreadId
  threads ← newIORef ([] ∷ [ThreadId])
  let onThread = myThreadId >>= \thread → atomicModifyIORef' threads (\seen → (seen <> [thread], ()))
  result ←
    runIn harness (workshop trace (pure ()))
      (\built control → onThread >> openFloor trace built control)
      ( \services _ → do
          onThread
          record trace ("action on " <> floorBench services)
          -- The services value carries the live worker handle startup published.
          status ← atomically (workerStatus (floorPolisher services))
          case status of
            WorkerLive → pure (42 ∷ Int)
            _ → throwIO (userError "the polisher was not live during the action")
      )
  result `shouldBe` 42
  readIORef threads `shouldReturn` [caller, caller]
  -- Dependencies boot first; the polisher is drained, its own resource released,
  -- before the bench it used, which goes before the store it was built on; the
  -- flush is last.
  traced trace `shouldReturn`
    workshopBoot
      <> ["startup", "acquire polisher", "action on store bench", "release polisher"]
      <> workshopDisposal
      <> ["flush"]
  errorEntries harness `shouldReturn` []

testOptionalUnavailable ∷ Expectation
testOptionalUnavailable = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  published ← runIn harness (station trace) (publishSchedule trace) (\schedule _ → pure schedule)
  published `shouldBe` Schedule "logbook" (Left "no signal")
  traced trace `shouldReturn`
    ["acquire logbook", "acquire antenna", "release antenna", "startup", "release logbook", "flush"]
  errorEntries harness `shouldReturn` []

-- Partial startup and cancellation ------------------------------------------------

testConstructionFailure ∷ Expectation
testConstructionFailure = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
      failingStation = do
        _ ← station trace
        allocResource (record trace "acquire mast" >> throwIO (Broken "no mast")) (\() → record trace "release mast")
  propagated ←
    expectFailure $
      runIn harness failingStation (\_ _ → record trace "startup") (\_ _ → record trace "action")
  propagated `shouldSatisfy` brokenIs "no mast"
  traced trace `shouldReturn`
    [ "acquire logbook", "acquire antenna", "release antenna", "acquire mast"
    , "release logbook", "write Application failed", "flush"
    ]
  void (expectOneReport harness)

testStartupFailure ∷ Expectation
testStartupFailure = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  propagated ←
    expectFailure $
      runIn harness (workshop trace (pure ()))
        (\built control → openFloor trace built control >> throwIO (Broken "startup failed"))
        (\_ _ → record trace "action")
  propagated `shouldSatisfy` brokenIs "startup failed"
  traced trace `shouldReturn`
    workshopBoot
      <> ["startup", "acquire polisher", "release polisher"]
      <> workshopDisposal
      <> ["write Application failed", "flush"]
  void (expectOneReport harness)

testCancellation ∷ Expectation
testCancellation = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  entered ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $
    try
      ( runIn harness (workshop trace (pure ())) (openFloor trace) $ \_ control → do
          record trace "action"
          putMVar entered ()
          awaitSupervised control retry
      )
      >>= putMVar outcome
  takeMVar entered
  awaitBlockedOnSTM runner
  killThread runner
  takeMVar outcome >>= \case
    Right () → expectationFailure "the cancelled application returned"
    Left (failure ∷ SomeException) → (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
  -- The polisher drains before any dependency is disposed; nothing is reported
  -- and nothing is flushed.
  traced trace `shouldReturn`
    workshopBoot <> ["startup", "acquire polisher", "action", "release polisher"] <> workshopDisposal
  errorEntries harness `shouldReturn` []

-- Truthful outcomes ------------------------------------------------------------

testCaughtSupervisedFailure ∷ Expectation
testCaughtSupervisedFailure = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  gate ← newGate
  propagated ←
    expectFailure $
      runIn harness (workshop trace (pure ()))
        ( \built control → do
            grinder ← startSupervised control (required Service) (failingAfter trace "grinder" gate (Broken "grinder failed"))
            void (expectStarted grinder)
            pure built
        )
        ( \_ control → do
            openGate gate
            delivered ← tryWithContext (awaitSupervised control retry)
            case delivered of
              Left (failure ∷ ExceptionWithContext SomeException) → failure `shouldSatisfy` brokenIs "grinder failed"
              Right () → expectationFailure "the supervised wait returned"
            pure (7 ∷ Int)
        )
  propagated `shouldSatisfy` brokenIs "grinder failed"
  from "release store" <$> traced trace `shouldReturn` ["release store", "write Application failed", "flush"]
  void (expectOneReport harness)

testFailureWhileClosing ∷ Expectation
testFailureWhileClosing = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
      sander =
        workerDefinition "sander" (\_ → allocResource (record trace "acquire sander") (\() → record trace "release sander")) $
          \token () → do
            _ ← awaitStopRequestIO token
            throwIO (Broken "sander failed while stopping")
      awaitStopRequestIO token = atomically (awaitStopRequest token)
  propagated ←
    expectFailure $
      runIn harness (workshop trace (pure ()))
        (\built control → startSupervised control (required Service) sander >>= expectStarted >> pure built)
        (\_ _ → record trace "action" >> pure (1 ∷ Int))
  propagated `shouldSatisfy` brokenIs "sander failed while stopping"
  traced trace `shouldReturn`
    workshopBoot
      <> ["acquire sander", "action", "release sander"]
      <> workshopDisposal
      <> ["write Application failed", "flush"]
  void (expectOneReport harness)

testCleanupFailureReported ∷ Expectation
testCleanupFailureReported = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  propagated ←
    expectFailure $
      runIn harness (workshop trace (throwIO (Broken "store release failed"))) (openFloor trace)
        (\_ _ → record trace "action")
  propagated `shouldSatisfy` brokenIs "store release failed"
  case propagated of
    ExceptionWithContext context _ →
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["resource release"]
  -- The report follows every release, while the logger is live, and precedes the
  -- flush.
  from "release polisher" <$> traced trace `shouldReturn`
    ["release polisher"] <> workshopDisposal <> ["write Application failed", "flush"]
  entry ← expectOneReport harness
  Map.lookup "cleanup.failures" (entryFields entry) `shouldBe` Just "1"
  Map.lookup "cleanup.labels" (entryFields entry) `shouldBe` Just "resource release"

testFlushFailure ∷ Expectation
testFlushFailure = boundedSupervision $ do
  harness ← newHarness ignoreWrites (ioError (userError "flush failed"))
  let trace = harnessTrace harness
  outcome ← try (runIn harness (station trace) (publishSchedule trace) (\_ _ → pure ()))
  case outcome of
    Right () → expectationFailure "a run whose flush failed returned"
    Left failure → ioeGetErrorString failure `shouldBe` "flush failed"
  flushes harness `shouldReturn` 1
  errorEntries harness `shouldReturn` []
  from "release logbook" <$> traced trace `shouldReturn` ["release logbook", "flush"]

testKnownFailedDiagnostic ∷ Expectation
testKnownFailedDiagnostic = boundedSupervision $ do
  harness ← newHarness failWarningsAndErrors (pure ())
  let trace = harnessTrace harness
  gate ← newGate
  openGate gate
  propagated ←
    expectFailure $
      runIn harness (station trace)
        ( \built control → do
            tuner ← startSupervised control (optional Service) (failingAfter trace "tuner" gate (Broken "tuner failed"))
            handle ← case tuner of
              WorkerStarted started → pure started
              WorkerStartUnavailable started _ → pure started
              WorkerStartRejected → throwIO (userError "the tuner was rejected")
            -- Wait until supervision has committed the tuner as unavailable, which
            -- is when its one warning has been attempted.
            status ← awaitSupervised control $
              workerStatus handle >>= \case
                WorkerLive → retry
                settled → pure settled
            case status of
              WorkerUnavailable _ → pure built
              _ → throwIO (userError "the tuner was not left unavailable")
        )
        (\_ _ → throwIO (Broken "action failed"))
  propagated `shouldSatisfy` brokenIs "action failed"
  case propagated of
    ExceptionWithContext context _ → length (failedReportsInContext context) `shouldBe` 1
  -- The warning was attempted once and failed; no terminal report and no flush
  -- follow through the path that failed.
  writes ← filter (`elem` ["write Operation unavailable", "write Application failed"]) <$> traced trace
  writes `shouldBe` ["write Operation unavailable"]
  flushes harness `shouldReturn` 0
  where
    failWarningsAndErrors entry =
      when (entryLevel entry `elem` [Warning, Error]) (ioError (userError "sink unavailable"))
