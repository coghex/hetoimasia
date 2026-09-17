-- | Examples for 'runScopedApplication' and
-- 'runScopedApplicationWithQuiescence', the generic application lifecycle.
--
-- Two unrelated applications drive the same runner: a workshop whose
-- dependencies are a store and a composite bench, whose services carry a
-- supervised service worker; and a station whose dependencies are a required
-- logbook and an optional radio built with 'allocComponent', whose services
-- publish the radio's availability. Neither type is known to the runtime. The
-- quiescence examples add a counter, whose dependency is a reply desk a worker
-- may be left waiting on.
--
-- The examples prove the composition, not the matrices it reuses: supervision's
-- classification and closing are proven by "Test.Engine.Runtime.Supervision",
-- whose fixtures these examples borrow, and the finalization matrix by
-- "Test.Engine.Runtime.Lifetime". Coordination is explicit, through gates,
-- STM, and 'awaitBlockedOnSTM'; nothing sleeps.
module Test.Engine.Runtime.Composition (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, throwSTM, writeTVar)
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
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
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
import Hetoimasia.Foundation.Worker (StopToken, WorkerDefinition, awaitStopRequest, stopRequested, workerDefinition)
import Hetoimasia.Runtime.Application (runScopedApplication, runScopedApplicationWithQuiescence)
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
  , supervisedWorker
  , workerStatus
  )
import System.IO.Error (ioeGetErrorString)
import Test.Engine.Runtime.LogFixture (fixedMetadata)
import Test.Engine.Runtime.Supervision.Support
  ( Broken (..)
  , Trace
  , awaitBlockedOnSTM
  , awaitTerminal
  , boundedSupervision
  , brokenIs
  , expectFailure
  , expectStarted
  , failingAfter
  , job
  , newGate
  , newTrace
  , openGate
  , optional
  , owned
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
  describe "Quiescence" $ do
    it "releases a worker awaiting a reply from a dependency-owned service so the boundary drain completes"
      testQuiescenceReleasesReplyWait
    describe "runs exactly once, with dependencies live, on every exit from the supervised region" $ do
      it "startup callback failure" (testQuiescenceOnce StartupFails)
      it "post-startup checkpoint failure" (testQuiescenceOnce StartupCheckpointFails)
      it "action failure" (testQuiescenceOnce ActionFails)
      it "final checkpoint failure" (testQuiescenceOnce FinalCheckpointFails)
      it "successful action return" (testQuiescenceOnce ActionReturns)
      it "action cancellation" testQuiescenceOnCancellation
    it "does not run when dependency construction fails"
      testQuiescenceSkippedOnConstructionFailure
    it "precedes the boundary's stop requests on ordinary shutdown"
      testQuiescencePrecedesBoundaryStop
    it "may follow a stop the fatal latch already requested"
      testFatalLatchStopPrecedesQuiescence
    it "may follow the drain of a worker whose managed startup was cancelled"
      testAbandonedStartupDrainPrecedesQuiescence
    it "retains its failure as cleanup evidence while an action failure stays primary"
      testQuiescenceFailureDuringFailure
    it "retains its failure as cleanup evidence while cancellation propagates unreported and unflushed"
      testQuiescenceFailureDuringCancellation
    it "discards a successful result when it fails, then drains, disposes, reports, and flushes"
      testQuiescenceFailureAfterSuccess
    it "leaves runScopedApplication identical to a no-op quiescence action"
      testNoOpQuiescenceIdentical

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

-- Quiescence ---------------------------------------------------------------------

-- | The runner with a quiescence action, over the harness's logger.
runQuiescentIn
  ∷ Harness → Scoped d → (d → STM ()) → (d → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
runQuiescentIn harness = runScopedApplicationWithQuiescence (withLoggingLifetime (harnessLogger harness)) "test-app"

-- | A dependency-local journal: quiescence writes to it inside its transaction,
-- and the counter's release and its workers write to it too, so one list orders
-- all of them.
type Journal = TVar [Text]

note ∷ Journal → Text → STM ()
note journal entry = modifyTVar' journal (<> [entry])

noteIO ∷ Journal → Text → IO ()
noteIO journal = atomically . note journal

-- | The counter: a journal allocated as a traced dependency, whose release
-- notes itself.
counter ∷ Journal → Scoped Journal
counter journal = allocResource (noteIO journal "acquire counter" >> pure journal) (\_ → noteIO journal "release counter")

quiesceCounter ∷ Journal → STM ()
quiesceCounter journal = note journal "quiesce"

-- | A reply desk owned by a dependency: a worker files a request and waits for
-- a reply that only the calling thread would give, or for the desk to close.
data Desk = Desk
  { deskJournal ∷ Journal
  , deskWaiting ∷ TVar Bool
  , deskClosed ∷ TVar Bool
  }

-- | A job that files a request and waits for its reply, ignoring its stop
-- token: only quiescence closing the desk lets it return.
awaitReply ∷ Desk → WorkerDefinition ()
awaitReply desk = job "requester" $ \_ → do
  atomically (writeTVar (deskWaiting desk) True)
  atomically (readTVar (deskClosed desk) >>= \closed → if closed then pure () else retry)
  noteIO (deskJournal desk) "reply refused"

testQuiescenceReleasesReplyWait ∷ Expectation
testQuiescenceReleasesReplyWait = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  journal ← newTVarIO []
  desk ← Desk journal <$> newTVarIO False <*> newTVarIO False
  let quiesce d = writeTVar (deskClosed d) True >> note (deskJournal d) "quiesce"
  result ←
    runQuiescentIn harness (allocResource (pure desk) (\d → noteIO (deskJournal d) "release desk")) quiesce
      (\d control → startSupervised control (required Job) (awaitReply d) >>= expectStarted >> pure d)
      ( \d control → do
          -- The requester is parked on its reply before the action returns.
          awaitSupervised control (readTVar (deskWaiting d) >>= \waiting → if waiting then pure () else retry)
          pure (5 ∷ Int)
      )
  result `shouldBe` 5
  readTVarIO journal `shouldReturn` ["quiesce", "reply refused", "release desk"]
  errorEntries harness `shouldReturn` []

-- | How a run leaves the supervised region.
data Exit
  = StartupFails
  | StartupCheckpointFails
  | ActionFails
  | FinalCheckpointFails
  | ActionReturns
  deriving (Eq, Show)

-- | A required job that fails, has been observed terminal by raw observation,
-- and is left for the next checkpoint to handle.
failedUnhandled ∷ Trace → RuntimeControl → IO ()
failedUnhandled trace control = do
  gate ← newGate
  worker ← startSupervised control (required Job) (failingAfter trace "breaker" gate (Broken "checkpoint failed")) >>= expectStarted
  openGate gate
  void (awaitTerminal (supervisedWorker worker))

testQuiescenceOnce ∷ Exit → Expectation
testQuiescenceOnce exit = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  journal ← newTVarIO []
  outcome ←
    tryWithContext $
      runQuiescentIn harness (counter journal) quiesceCounter
        ( \built control → do
            when (exit == StartupFails) (throwIO (Broken "startup failed"))
            when (exit == StartupCheckpointFails) (failedUnhandled trace control)
            pure built
        )
        ( \_ control → do
            when (exit == ActionFails) (throwIO (Broken "action failed"))
            when (exit == FinalCheckpointFails) (failedUnhandled trace control)
            pure (3 ∷ Int)
        )
  case (exit, outcome) of
    (ActionReturns, Right result) → result `shouldBe` 3
    (ActionReturns, Left _) → expectationFailure "a successful run failed"
    (_, Right _) → expectationFailure "a failing run returned"
    (StartupFails, Left failure) → failure `shouldSatisfy` brokenIs "startup failed"
    (ActionFails, Left failure) → failure `shouldSatisfy` brokenIs "action failed"
    (_, Left failure) → failure `shouldSatisfy` brokenIs "checkpoint failed"
  readTVarIO journal `shouldReturn` ["acquire counter", "quiesce", "release counter"]
  flushes harness `shouldReturn` 1

testQuiescenceOnCancellation ∷ Expectation
testQuiescenceOnCancellation = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  journal ← newTVarIO []
  entered ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $
    try
      ( runQuiescentIn harness (counter journal) quiesceCounter (\built _ → pure built) $ \_ control → do
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
  readTVarIO journal `shouldReturn` ["acquire counter", "quiesce", "release counter"]
  errorEntries harness `shouldReturn` []
  flushes harness `shouldReturn` 0

testQuiescenceSkippedOnConstructionFailure ∷ Expectation
testQuiescenceSkippedOnConstructionFailure = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  journal ← newTVarIO []
  let failing = do
        built ← counter journal
        allocResource (throwIO (Broken "no mast")) (\() → pure ())
        pure built
  propagated ←
    expectFailure $
      runQuiescentIn harness failing quiesceCounter (\built _ → pure built) (\_ _ → pure ())
  propagated `shouldSatisfy` brokenIs "no mast"
  readTVarIO journal `shouldReturn` ["acquire counter", "release counter"]
  void (expectOneReport harness)

-- | A dependency a service publishes its stop token into, and in which
-- quiescence records whether that token had already been asked to stop.
data Switchboard = Switchboard
  { switchToken ∷ TVar (Maybe StopToken)
  , switchSeen ∷ TVar (Maybe Bool)
  }

newSwitchboard ∷ IO Switchboard
newSwitchboard = Switchboard <$> newTVarIO Nothing <*> newTVarIO Nothing

-- | A service that publishes its stop token from startup, then runs until
-- stopped.
publishingService ∷ Trace → Switchboard → WorkerDefinition ()
publishingService trace board =
  workerDefinition "operator" (\token → liftIO (atomically (writeTVar (switchToken board) (Just token))) >> owned trace "operator") $
    \token () → atomically (awaitStopRequest token)

-- | Record, without retrying, whether the published token was already asked
-- to stop.
quiesceSwitchboard ∷ Switchboard → STM ()
quiesceSwitchboard board =
  readTVar (switchToken board) >>= \case
    Nothing → writeTVar (switchSeen board) Nothing
    Just token → stopRequested token >>= writeTVar (switchSeen board) . Just

testQuiescencePrecedesBoundaryStop ∷ Expectation
testQuiescencePrecedesBoundaryStop = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  board ← newSwitchboard
  runQuiescentIn harness (pure board) quiesceSwitchboard
    (\b control → startSupervised control (required Service) (publishingService trace b) >>= expectStarted >> pure b)
    (\_ _ → record trace "action")
  readTVarIO (switchSeen board) `shouldReturn` Just False
  traced trace `shouldReturn` ["acquire operator", "action", "release operator", "flush"]

testFatalLatchStopPrecedesQuiescence ∷ Expectation
testFatalLatchStopPrecedesQuiescence = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  board ← newSwitchboard
  gate ← newGate
  propagated ←
    expectFailure $
      runQuiescentIn harness (pure board) quiesceSwitchboard
        ( \b control → do
            void (startSupervised control (required Service) (publishingService trace b) >>= expectStarted)
            void (startSupervised control (required Service) (failingAfter trace "fuse" gate (Broken "fuse blew")) >>= expectStarted)
            pure b
        )
        (\_ control → openGate gate >> awaitSupervised control retry)
  propagated `shouldSatisfy` brokenIs "fuse blew"
  -- Settling the fuse latched it and asked the operator to stop in the same
  -- transaction, before the wait rethrew and quiescence ran.
  readTVarIO (switchSeen board) `shouldReturn` Just True
  void (expectOneReport harness)

testAbandonedStartupDrainPrecedesQuiescence ∷ Expectation
testAbandonedStartupDrainPrecedesQuiescence = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  journal ← newTVarIO []
  entered ← newEmptyMVar
  never ← newGate
  outcome ← newEmptyMVar
  let stalled =
        workerDefinition "stalled"
          ( \_ → do
              allocResource (noteIO journal "acquire stalled") (\() → noteIO journal "release stalled")
              liftIO (putMVar entered () >> takeMVar never)
          )
          (\_ () → pure ())
  runner ← forkIO $
    try
      ( runQuiescentIn harness (counter journal) quiesceCounter
          (\built control → startSupervised control (required Service) stalled >>= expectStarted >> pure built)
          (\_ _ → pure ())
      )
      >>= putMVar outcome
  takeMVar entered
  awaitBlockedOnSTM runner
  killThread runner
  takeMVar outcome >>= \case
    Right () → expectationFailure "the cancelled application returned"
    Left (failure ∷ SomeException) → (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
  readTVarIO journal `shouldReturn`
    ["acquire counter", "acquire stalled", "release stalled", "quiesce", "release counter"]
  flushes harness `shouldReturn` 0

-- | A quiescence action that fails. Its transaction's writes roll back with the
-- throw, so the retained @application quiescence@ label is what shows it ran.
failingQuiescence ∷ d → STM ()
failingQuiescence _ = throwSTM (Broken "quiescence failed")

quiescenceLabels ∷ ExceptionWithContext SomeException → [Text]
quiescenceLabels (ExceptionWithContext context _) = map cleanupFailureLabel (cleanupFailuresInContext context)

testQuiescenceFailureDuringFailure ∷ Expectation
testQuiescenceFailureDuringFailure = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  journal ← newTVarIO []
  propagated ←
    expectFailure $
      runQuiescentIn harness (counter journal) failingQuiescence (\built _ → pure built)
        (\_ _ → throwIO (Broken "action failed"))
  propagated `shouldSatisfy` brokenIs "action failed"
  quiescenceLabels propagated `shouldBe` ["application quiescence"]
  readTVarIO journal `shouldReturn` ["acquire counter", "release counter"]
  entry ← expectOneReport harness
  Map.lookup "cleanup.labels" (entryFields entry) `shouldBe` Just "application quiescence"
  flushes harness `shouldReturn` 1

testQuiescenceFailureDuringCancellation ∷ Expectation
testQuiescenceFailureDuringCancellation = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  journal ← newTVarIO []
  entered ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $
    tryWithContext
      ( runQuiescentIn harness (counter journal) failingQuiescence (\built _ → pure built) $ \_ control → do
          putMVar entered ()
          awaitSupervised control retry
      )
      >>= putMVar outcome
  takeMVar entered
  awaitBlockedOnSTM runner
  killThread runner
  takeMVar outcome >>= \case
    Right () → expectationFailure "the cancelled application returned"
    Left (failure@(ExceptionWithContext _ exception) ∷ ExceptionWithContext SomeException) → do
      (fromException exception ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      quiescenceLabels failure `shouldBe` ["application quiescence"]
  readTVarIO journal `shouldReturn` ["acquire counter", "release counter"]
  errorEntries harness `shouldReturn` []
  flushes harness `shouldReturn` 0

testQuiescenceFailureAfterSuccess ∷ Expectation
testQuiescenceFailureAfterSuccess = boundedSupervision $ do
  harness ← newHarness ignoreWrites (pure ())
  let trace = harnessTrace harness
  propagated ←
    expectFailure $
      runQuiescentIn harness (workshop trace (pure ())) failingQuiescence (openFloor trace)
        (\_ _ → record trace "action" >> pure (9 ∷ Int))
  propagated `shouldSatisfy` brokenIs "quiescence failed"
  quiescenceLabels propagated `shouldBe` ["application quiescence"]
  -- The polisher tolerates the failure-path cancellation and settles as stopped:
  -- it drains before the dependencies unwind, then the one report and the flush.
  traced trace `shouldReturn`
    workshopBoot
      <> ["startup", "acquire polisher", "action", "release polisher"]
      <> workshopDisposal
      <> ["write Application failed", "flush"]
  entry ← expectOneReport harness
  Map.lookup "cleanup.labels" (entryFields entry) `shouldBe` Just "application quiescence"

testNoOpQuiescenceIdentical ∷ Expectation
testNoOpQuiescenceIdentical = boundedSupervision $ do
  let scenario ∷ (∀ d s a. Harness → Scoped d → (d → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a) → Bool → IO ([Text], [(Text, Map.Map Text Text)])
      scenario runner failing = do
        harness ← newHarness ignoreWrites (pure ())
        let trace = harnessTrace harness
        _ ←
          tryWithContext
            ( runner harness (workshop trace (pure ())) (openFloor trace) $ \_ _ → do
                record trace "action"
                when failing (throwIO (Broken "action failed"))
            )
            ∷ IO (Either (ExceptionWithContext SomeException) ())
        entries ← errorEntries harness
        (,) <$> traced trace <*> pure [(entryMessage entry, entryFields entry) | entry ← entries]
      noOp harness dependencies = runQuiescentIn harness dependencies (\_ → pure ())
  for_ [False, True] $ \failing → do
    plain ← scenario runIn failing
    quiescent ← scenario noOp failing
    quiescent `shouldBe` plain
