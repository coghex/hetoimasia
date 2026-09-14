-- | Examples for 'Hetoimasia.Runtime.Inbox'.
--
-- Every example starts a real inbox service with real 'withSupervision',
-- 'startInboxService', and 'awaitSupervised', inside a logging lifetime over a
-- collecting sink, with synthetic typed failures. The traced component contexts
-- and handlers come from "Test.Engine.Runtime.Inbox.Support"; the graceful
-- finish examples live in "Test.Engine.Runtime.InboxFinish".
--
-- Coordination is explicit: a handler signals entry through an 'MVar' and
-- waits on a gate, and 'awaitBlockedOnSTM' decides when the application thread
-- has reached closing's drain. No example sleeps; 'boundedSupervision' only
-- stops an example that has already hung.
module Test.Engine.Runtime.Inbox (spec) where

import Control.Concurrent (forkIO, killThread, myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , throwIO
  , try
  , tryWithContext
  )
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Channel (SendResult (..))
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Resource (allocResource, cleanupFailuresInContext, withScoped)
import Hetoimasia.Foundation.Worker (Completion (..), Requested (..), Result (..), RunEnd (..), RunExit (..))
import Hetoimasia.Runtime.Inbox
import Hetoimasia.Runtime.Supervision
  ( UnexpectedWorkerTermination (..)
  , WorkerStatus (..)
  , awaitSupervised
  , checkRuntime
  , withSupervision
  )
import Test.Engine.Runtime.Inbox.Support
import Test.Engine.Runtime.Supervision.Support
  ( Broken (..)
  , CollectedLifetime (..)
  , Trace
  , awaitBlockedOnSTM
  , boundedSupervision
  , brokenIs
  , expectFailure
  , newGate
  , newTrace
  , openGate
  , record
  , traced
  , warningCount
  , withCollectedLifetime
  )
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Inbox services" $ do
  describe "Failed starts" $ do
    it "propagates a required context failure with no endpoint and the context released"
      (boundedSupervision testStartupFailure)
    it "rejects a start after closing without constructing anything"
      (boundedSupervision testRejectedStart)
    it "returns an optional recognized context failure as unavailable, with no endpoint and one warning"
      (boundedSupervision testUnavailableStart)
    it "propagates owner cancellation during context construction with the context released"
      (boundedSupervision testCancelledConstruction)

  describe "Handoff and immediate exit" $ do
    it "returns a usable endpoint from a start whose handoff is already full"
      (boundedSupervision testHandoffDelivers)
    it "closes the inbox before teardown when a service stops straight after acknowledgement"
      (boundedSupervision testImmediateExit)

  describe "Stop with a full inbox" $ do
    it "aborts the backlog on an ordinary stop and retains its discard count"
      (boundedSupervision testStopWithFullInbox)
    it "aborts the backlog on closing's stop when the application returns"
      (boundedSupervision testGroupTriggeredStop)

  describe "Stop races" $ do
    it "lets a requested stop win over a simultaneously ready message"
      (boundedSupervision testStopWinsReadyMessage)
    it "completes an in-flight message once without retrying it"
      (boundedSupervision testInFlightOnce)

  describe "Handler exceptions" $ do
    it "fails a required service with the handler's type and context, aborting the queued messages"
      (boundedSupervision (testHandlerFailureFatal requiredInbox))
    it "fails an optional service whose classifier does not recognize the failure"
      (boundedSupervision (testHandlerFailureFatal unrecognizedOptionalInbox))
    it "leaves a recognized optional failure unavailable with one warning, aborting the queued messages"
      (boundedSupervision testHandlerFailureUnavailable)
    it "handles the following message after a handler recovers explicitly"
      (boundedSupervision testHandlerRecovers)

  describe "Failure evidence" $ do
    it "closes the endpoint before teardown for a cancellation after the handoff and before any dispatch"
      (boundedSupervision testCancellationBeforeDispatch)
    it "keeps an in-flight cancellation's completion without an exit record"
      (boundedSupervision testCancellationEvidence)
    it "keeps a cleanup failure's completion without an exit record"
      (boundedSupervision testCleanupFailureEvidence)

  describe "Dependencies" $ do
    it "keeps a borrowed dependency usable until the service's cleanup finishes"
      (boundedSupervision testBorrowedDependency)

-- Failed starts ----------------------------------------------------------------

failingContext ∷ Trace → Probe → InboxDefinition Int
failingContext trace probe =
  inboxDefinition "inbox" 4 (\_ → probedContext trace probe >> liftIO (throwIO (Broken "context"))) (handling trace ignore)

testStartupFailure ∷ Expectation
testStartupFailure = do
  trace ← newTrace
  probe ← newEmptyMVar
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      _ ← startedWith probe =<< startInboxService control requiredInbox (failingContext trace probe)
      pure ()
  failure `shouldSatisfy` brokenIs "context"
  traced trace >>= (`shouldBe` ["acquire context", "release context: inbox no endpoint"])

testRejectedStart ∷ Expectation
testRejectedStart = do
  trace ← newTrace
  probe ← newEmptyMVar
  control ← withCollectedLifetime ignoreWrites $ \collected → withSupervision (collectedLifetime collected) pure
  startInboxService control requiredInbox (inbox trace probe 4 ignore) >>= \case
    InboxStartRejected → pure ()
    _ → expectationFailure "a start after closing was not rejected"
  traced trace >>= (`shouldBe` [])

testUnavailableStart ∷ Expectation
testUnavailableStart = do
  trace ← newTrace
  probe ← newEmptyMVar
  (started, warnings) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startInboxService control optionalInbox (failingContext trace probe)
      checkRuntime control
      (,) started <$> warningCount collected
  case started of
    InboxStartUnavailable failure → failure `shouldSatisfy` brokenIs "context"
    _ → expectationFailure "expected the optional inbox service to be unavailable"
  warnings `shouldBe` 1
  traced trace >>= (`shouldBe` ["acquire context", "release context: inbox no endpoint"])

testCancelledConstruction ∷ Expectation
testCancelledConstruction = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  held ← newEmptyMVar
  done ← newEmptyMVar
  let slow =
        inboxDefinition
          "inbox"
          4
          (\_ → probedContext trace probe >> liftIO (putMVar entered () >> takeMVar held))
          (handling trace ignore)
  owner ← forkIO $ do
    outcome ← tryWithContext @SomeException $ withCollectedLifetime ignoreWrites $ \collected →
      withSupervision (collectedLifetime collected) $ \control → do
        _ ← startedWith probe =<< startInboxService control requiredInbox slow
        pure ()
    putMVar done outcome
  takeMVar entered
  killThread owner
  takeMVar done >>= \case
    Left (ExceptionWithContext _ raised) → fromException raised `shouldBe` Just ThreadKilled
    Right () → expectationFailure "the cancelled owner returned"
  traced trace >>= (`shouldBe` ["acquire context", "release context: inbox no endpoint"])

-- Handoff and immediate exit ---------------------------------------------------

testHandoffDelivers ∷ Expectation
testHandoffDelivers = do
  trace ← newTrace
  probe ← newEmptyMVar
  handled ← newEmptyMVar
  (sent, discarded, status) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 (\_ → putMVar handled ()))
      sent ← offer started 1
      takeMVar handled
      stopInboxService started
      completion ← awaitSupervised control (awaitInboxCompletion started)
      checkRuntime control
      (,,) sent (exitOf completion) <$> statusOf started
  sent `shouldBe` Accepted
  discarded `shouldBe` Just 0
  status `shouldBe` "stopped"
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testImmediateExit ∷ Expectation
testImmediateExit = do
  trace ← newTrace
  probe ← newEmptyMVar
  discarded ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 ignore)
      stopInboxService started
      exitOf <$> awaitSupervised control (awaitInboxCompletion started)
  discarded `shouldBe` Just 0
  traced trace >>= (`shouldBe` ["acquire context", "release context: inbox closed"])

-- Stop with a full inbox -------------------------------------------------------

testStopWithFullInbox ∷ Expectation
testStopWithFullInbox = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  (admissions, discarded, repeated) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 3 (holdingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      admissions ← traverse (offer started) [2, 3, 4, 5]
      stopInboxService started
      openGate gate
      completion ← awaitSupervised control (awaitInboxCompletion started)
      again ← atomically (inboxCompletion started)
      pure (admissions, exitOf completion, exitOf <$> again)
  admissions `shouldBe` [Accepted, Accepted, Accepted, Full]
  discarded `shouldBe` Just 3
  repeated `shouldBe` Just (Just 3)
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testGroupTriggeredStop ∷ Expectation
testGroupTriggeredStop = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  application ← myThreadId
  started ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 3 (holdingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      traverse_ (offer started) [2, 3, 4]
      -- The handler is released only once closing has asked for the stop and
      -- the application is waiting in the drain.
      _ ← forkIO (awaitBlockedOnSTM application >> openGate gate)
      pure started
  first ← atomically (inboxCompletion started)
  second ← atomically (inboxCompletion started)
  (exitOf <$> first) `shouldBe` Just (Just 3)
  (exitOf <$> second) `shouldBe` Just (Just 3)
  statusOf started >>= (`shouldBe` "stopped")
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

-- Stop races -------------------------------------------------------------------

testStopWinsReadyMessage ∷ Expectation
testStopWinsReadyMessage = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  discarded ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 (holdingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      -- Message 2 is ready and the stop is requested before the handler
      -- returns, so both are ready at the next choice.
      _ ← offer started 2
      stopInboxService started
      openGate gate
      exitOf <$> awaitSupervised control (awaitInboxCompletion started)
  discarded `shouldBe` Just 1
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testInFlightOnce ∷ Expectation
testInFlightOnce = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  let finishing value = holdingFirst entered gate value >> record trace ("finish " <> showText value)
  discarded ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 finishing)
      _ ← offer started 1
      takeMVar entered
      stopInboxService started
      openGate gate
      exitOf <$> awaitSupervised control (awaitInboxCompletion started)
  discarded `shouldBe` Just 0
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "finish 1", "release context: inbox closed"])

-- Handler exceptions -----------------------------------------------------------

testHandlerFailureFatal ∷ InboxPolicy → Expectation
testHandlerFailureFatal policy = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  retained ← newIORef Nothing
  ExceptionWithContext context raised ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control policy (inbox trace probe 4 (failingFirst entered gate))
      writeIORef retained (Just started)
      _ ← offer started 1
      takeMVar entered
      traverse_ (offer started) [2, 3]
      openGate gate
      _ ← awaitSupervised control (awaitInboxCompletion started)
      pure ()
  fromException raised `shouldBe` Just (Broken "handler")
  [name | Provenance name ← getExceptionAnnotations context] `shouldBe` ["handler"]
  Just started ← readIORef retained
  completion ← atomically (awaitInboxCompletion started)
  resultName completion `shouldBe` "failed"
  exitOf completion `shouldBe` Nothing
  statusOf started >>= (`shouldBe` "fatal")
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testHandlerFailureUnavailable ∷ Expectation
testHandlerFailureUnavailable = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  (outcome, status, warnings) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control optionalInbox (inbox trace probe 4 (failingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      traverse_ (offer started) [2, 3]
      openGate gate
      completion ← awaitSupervised control (awaitInboxCompletion started)
      checkRuntime control
      status ← atomically (inboxStatus started)
      (,,) (resultName completion) status <$> warningCount collected
  outcome `shouldBe` "failed"
  case status of
    WorkerUnavailable failure → failure `shouldSatisfy` brokenIs "handler"
    _ → expectationFailure ("expected an unavailable service, found " <> show status)
  warnings `shouldBe` 1
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testHandlerRecovers ∷ Expectation
testHandlerRecovers = do
  trace ← newTrace
  probe ← newEmptyMVar
  handled ← newEmptyMVar
  let recovering = \case
        1 →
          try @Broken (throwIO (Broken "transient")) >>= \case
            Left (Broken reason) → record trace ("recovered " <> reason)
            Right () → pure ()
        _ → putMVar handled ()
  discarded ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 recovering)
      traverse_ (offer started) [1, 2]
      takeMVar handled
      stopInboxService started
      exitOf <$> awaitSupervised control (awaitInboxCompletion started)
  discarded `shouldBe` Just 0
  traced trace
    >>= (`shouldBe` ["acquire context", "handle 1", "recovered transient", "handle 2", "release context: inbox closed"])

-- Failure evidence -------------------------------------------------------------

testCancellationBeforeDispatch ∷ Expectation
testCancellationBeforeDispatch = do
  trace ← newTrace
  probe ← newEmptyMVar
  workerThread ← newEmptyMVar
  retained ← newIORef Nothing
  let noting =
        inboxDefinition
          "inbox"
          4
          (\_ → probedContext trace probe >> liftIO (myThreadId >>= putMVar workerThread))
          (handling trace ignore)
  ExceptionWithContext _ raised ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox noting
      writeIORef retained (Just started)
      -- The handoff has returned and no message was ever sent: once the worker
      -- parks in its first receive, a cancellation lands before any dispatch.
      -- An owner's cancellation is also a stop request, which that receive
      -- could honour first, so the cancellation is delivered to the thread.
      thread ← readMVar workerThread
      awaitBlockedOnSTM thread
      throwTo thread ThreadKilled
      _ ← awaitSupervised control (awaitInboxCompletion started)
      pure ()
  case fromException raised of
    Just (UnexpectedWorkerTermination _) → pure ()
    Nothing → expectationFailure "expected the cancellation to be judged an unexpected termination"
  Just started ← readIORef retained
  completion ← atomically (awaitInboxCompletion started)
  completionExit completion `shouldBe` RunExited RunCancelled NothingRequested
  case completionResult completion of
    Cancelled (ExceptionWithContext _ cancellation) → fromException cancellation `shouldBe` Just ThreadKilled
    _ → expectationFailure ("expected a cancelled completion, found " <> Text.unpack (resultName completion))
  exitOf completion `shouldBe` Nothing
  traced trace >>= (`shouldBe` ["acquire context", "release context: inbox closed"])

testCancellationEvidence ∷ Expectation
testCancellationEvidence = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  (outcome, discarded, status) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 (holdingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      _ ← offer started 2
      -- A cancellation is also a stop request, which an idle dispatch loop
      -- would honour first; delivering it inside the handler makes it the exit.
      cancelInboxService started
      completion ← awaitSupervised control (awaitInboxCompletion started)
      checkRuntime control
      openGate gate
      (,,) (resultName completion) (exitOf completion) <$> statusOf started
  outcome `shouldBe` "cancelled"
  discarded `shouldBe` Nothing
  status `shouldBe` "stopped"
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testCleanupFailureEvidence ∷ Expectation
testCleanupFailureEvidence = do
  trace ← newTrace
  probe ← newEmptyMVar
  retained ← newIORef Nothing
  let breaking =
        inboxDefinition
          "inbox"
          4
          (\_ → probedContext trace probe >> allocResource (pure ()) (\() → throwIO (Broken "release")))
          (handling trace ignore)
  failure@(ExceptionWithContext context _) ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox breaking
      writeIORef retained (Just started)
      stopInboxService started
      _ ← awaitSupervised control (awaitInboxCompletion started)
      pure ()
  failure `shouldSatisfy` brokenIs "release"
  length (cleanupFailuresInContext context) `shouldBe` 1
  Just started ← readIORef retained
  completion ← atomically (awaitInboxCompletion started)
  resultName completion `shouldBe` "failed"
  exitOf completion `shouldBe` Nothing
  length (completionCleanup completion) `shouldBe` 1
  traced trace >>= (`shouldBe` ["acquire context", "release context: inbox closed"])

-- Dependencies -----------------------------------------------------------------

testBorrowedDependency ∷ Expectation
testBorrowedDependency = do
  trace ← newTrace
  probe ← newEmptyMVar
  handled ← newEmptyMVar
  live ← newIORef False
  let dependency =
        allocResource
          (writeIORef live True >> record trace "acquire dependency")
          (\() → writeIORef live False >> record trace "release dependency")
      describeLive = (\alive → if alive then "live" else "released") <$> readIORef live
      context _ = allocResource (pure ()) (\() → describeLive >>= \state → record trace ("release context: dependency " <> state))
      handler () message = do
        state ← describeLive
        record trace ("handle " <> showText (preparedValue message) <> ": dependency " <> state)
        putMVar handled ()
  withScoped dependency $ \() →
    withCollectedLifetime ignoreWrites $ \collected →
      withSupervision (collectedLifetime collected) $ \control → do
        started ← startedWith probe =<< startInboxService control requiredInbox (inboxDefinition "inbox" 4 context handler)
        _ ← offer started 1
        takeMVar handled
  traced trace
    >>= (`shouldBe` ["acquire dependency", "handle 1: dependency live", "release context: dependency live", "release dependency"])
