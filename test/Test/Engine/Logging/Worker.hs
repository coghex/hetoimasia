-- | Examples for the terminal reporting boundary a worker owns.
--
-- The worker example from the "Usage" section of docs/logging.md is mirrored
-- here verbatim so the guide and the behaviour these cases assert cannot drift.
module Test.Engine.Logging.Worker (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , IOException
  , SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  , try
  )
import Control.Monad (void)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log
import System.IO.Error (ioeGetErrorString)
import Test.Engine.Logging.Support (fixedMetadata, newCollector, summaries)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldReturn
  )
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "Worker reporting boundary" $ do
  it "emits the success diagnostic for completed work" testWorkerSuccess
  it "reports an ordinary failure once and ends the worker" testWorkerFailure
  it "propagates cancellation delivered to blocked work, unreported" testWorkerCancelled
  it "keeps the work's exception when its report fails" testWorkerReportingFailure
  it "propagates cancellation delivered while the report blocks" testWorkerCancelledWhileReporting
  it "propagates a failing success diagnostic" testWorkerSuccessDiagnosticFailure

uploadComponent ∷ Component
uploadComponent = unsafeComponent "upload"

-- The terminal reporting boundary for one uploader.
uploaderWorker ∷ Logger → Int → (Logger → IO Int) → IO ()
uploaderWorker logger worker work = do
  let scoped = withFields [("worker", Text.pack (show worker))] logger
  outcome ← try (work scoped)
  case outcome of
    Right uploaded →
      logInfo scoped uploadComponent "Uploads drained"
        [("uploaded", Text.pack (show uploaded))]
    Left failure
      | isCancellation failure → throwIO failure
      | otherwise → reportAbandoned scoped failure

-- One reporting attempt, and never a second one through the same sink.
reportAbandoned ∷ Logger → SomeException → IO ()
reportAbandoned scoped failure = do
  reported ← try (logError scoped uploadComponent "Uploads abandoned"
                    [("reason", Text.pack (show failure))])
  case reported of
    Right () → pure ()
    Left reportingFailure
      | isCancellation reportingFailure → throwIO reportingFailure
      | otherwise → throwIO failure

-- Anything thrown as asynchronous is cancellation, so ThreadKilled,
-- UserInterrupt, and the exception a timeout delivers are classified alike.
isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)

-- | The work's own failure, distinguishable from any sink failure by both its
-- type and its payload.
uploadFailure ∷ ErrorCall
uploadFailure = ErrorCall "upload queue exploded"

-- | The example body on its own thread, with its outcome published rather than
-- left to escape into the runner.
workerOutcome ∷ Logger → (Logger → IO Int) → IO (Either SomeException ())
workerOutcome logger work = do
  outcome ← newEmptyMVar
  void . forkIO $ try (uploaderWorker logger 7 work) >>= putMVar outcome
  bounded (takeMVar outcome)

-- | The same, killed once the gate proves the worker has parked at an
-- interruptible point. The gate is the coordination: nothing here sleeps.
cancelledWorkerOutcome
  ∷ Logger → MVar () → (Logger → IO Int) → IO (Either SomeException ())
cancelledWorkerOutcome logger entered work = do
  outcome ← newEmptyMVar
  worker ← forkIO $ try (uploaderWorker logger 7 work) >>= putMVar outcome
  bounded (takeMVar entered)
  bounded (killThread worker)
  bounded (takeMVar outcome)

-- | Signals that it has arrived, then blocks on an `MVar` the test holds and
-- never fills. That retained reference is what makes this an interruptible
-- block rather than a deadlock the runtime would report as an ordinary failure.
blockedAt ∷ MVar () → MVar () → IO a
blockedAt entered held = do
  putMVar entered ()
  takeMVar held
  throwIO (ErrorCall "a blocked action was released")

-- | The worker ended normally; anything that escaped is the failure.
completed ∷ Either SomeException () → Expectation
completed (Right ()) = pure ()
completed (Left failure) =
  expectationFailure ("the worker failed with " <> show failure)

-- | The cancellation escaped as itself, rather than as success or as some
-- earlier exception the boundary had in hand.
cancelled ∷ Either SomeException () → Expectation
cancelled (Right ()) = expectationFailure "the cancelled worker reported success"
cancelled (Left failure) =
  (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled

-- | The one field a reporting case cares about, with its count.
reasonFields ∷ [LogEntry] → [Text]
reasonFields = mapMaybe (Map.lookup "reason" . entryFields)

testWorkerSuccess ∷ IO ()
testWorkerSuccess = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  workerOutcome logger (\_ → pure 12) >>= completed
  entries ← collected
  summaries entries `shouldBe` [(Info, "upload", "Uploads drained")]
  map (Map.lookup "uploaded" . entryFields) entries `shouldBe` [Just "12"]
  -- The worker's derived field reaches the record without the caller's logger
  -- having acquired it.
  map (Map.lookup "worker" . entryFields) entries `shouldBe` [Just "7"]

testWorkerFailure ∷ IO ()
testWorkerFailure = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  -- An ordinary failure ends at the boundary: one Error record, and the worker
  -- returns rather than rethrowing to a caller that no longer exists.
  workerOutcome logger (\_ → throwIO uploadFailure) >>= completed
  entries ← collected
  summaries entries `shouldBe` [(Error, "upload", "Uploads abandoned")]
  case reasonFields entries of
    [reason] → Text.unpack reason `shouldContain` "upload queue exploded"
    other → expectationFailure ("unexpected reason fields: " <> show other)

testWorkerCancelled ∷ IO ()
testWorkerCancelled = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  entered ← newEmptyMVar
  held ← newEmptyMVar
  -- Delivered to blocked work, so this is an actual asynchronous exception
  -- rather than a value the test threw synchronously to stand in for one.
  cancelledWorkerOutcome logger entered (\_ → blockedAt entered held) >>= cancelled
  -- Cancellation is reported nowhere: no Error, and no Info either.
  collected `shouldReturn` []

testWorkerReportingFailure ∷ IO ()
testWorkerReportingFailure = do
  attempts ← newMVar (0 ∷ Int)
  let sink = callbackSink $ \_ → do
        modifyMVar_ attempts (pure . (+ 1))
        ioError (userError "sink unavailable")
      logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  outcome ← workerOutcome logger (\_ → throwIO uploadFailure)
  case outcome of
    Right () → expectationFailure "the work failure did not escape"
    Left failure → do
      -- The work's exception, with its payload, and not the sink's.
      (fromException failure ∷ Maybe ErrorCall) `shouldBe` Just uploadFailure
      (fromException failure ∷ Maybe IOException) `shouldBe` Nothing
  -- Exactly one attempt: a failed report is never reported back through the
  -- sink that just failed.
  readMVar attempts `shouldReturn` 1

testWorkerCancelledWhileReporting ∷ IO ()
testWorkerCancelledWhileReporting = do
  entered ← newEmptyMVar
  held ← newEmptyMVar
  let logger = mkLoggerWith defaultLogFilter fixedMetadata
        (callbackSink (\_ → blockedAt entered held))
  -- The work fails synchronously first, so a boundary that let that earlier
  -- exception win would surface ErrorCall here instead of ThreadKilled.
  cancelledWorkerOutcome logger entered (\_ → throwIO uploadFailure) >>= cancelled

testWorkerSuccessDiagnosticFailure ∷ IO ()
testWorkerSuccessDiagnosticFailure = do
  let logger = mkLoggerWith defaultLogFilter fixedMetadata
        (callbackSink (\_ → ioError (userError "sink unavailable")))
  outcome ← workerOutcome logger (\_ → pure 12)
  case outcome of
    Right () →
      expectationFailure "the success diagnostic's sink failure did not propagate"
    Left failure →
      (ioeGetErrorString <$> (fromException failure ∷ Maybe IOException))
        `shouldBe` Just "sink unavailable"
