-- | Examples for the graceful finish of 'Hetoimasia.Runtime.Inbox' services,
-- and the combined command-and-snapshot example.
--
-- Every example starts a real inbox service with real 'withSupervision',
-- 'startInboxService', 'finishInboxService', 'stopSupervised' through the
-- service handle, and 'awaitSupervised', inside a logging lifetime over a
-- collecting sink. Coordination is explicit: a handler signals entry through
-- an 'MVar' and waits on a gate, 'awaitBlockedOnSTM' decides when the
-- application thread has parked in the finish's supervised wait, and a
-- classifier waiting on a gate holds that wait between two outcomes. No example
-- sleeps; 'boundedSupervision' only stops an example that has already hung.
module Test.Engine.Runtime.InboxFinish (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , throwIO
  , tryWithContext
  )
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Messaging.Channel (SendResult (..), send)
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( Update (..)
  , awaitSnapshot
  , closeSnapshot
  , newSnapshot
  , observedCursor
  , observedValue
  , publish
  , readSnapshot
  , snapshotReader
  )
import Hetoimasia.Foundation.Resource (allocResource, cleanupFailuresInContext, withScoped)
import Hetoimasia.Foundation.Worker (Completion (..), Requested (..), Result (..), RunEnd (..), RunExit (..))
import Hetoimasia.Runtime.Inbox
import Hetoimasia.Runtime.Supervision
  ( Disposition (..)
  , Recognition (..)
  , Role (..)
  , UnexpectedWorkerTermination (..)
  , WorkerPolicy (..)
  , WorkerStatus (..)
  , awaitSupervised
  , checkRuntime
  , startSupervised
  , withSupervision
  , workerStatus
  )
import Test.Engine.Runtime.Inbox.Support
import Test.Engine.Runtime.Supervision.Support
  ( Broken (..)
  , CollectedLifetime (..)
  , Gate
  , awaitBlockedOnSTM
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
  , record
  , required
  , supervisionComponent
  , traced
  , warningCount
  , withCollectedLifetime
  )
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Inbox finish" $ do
  describe "In-flight and backlog work" $ do
    it "handles the in-flight message and every accepted message once, in order, before acknowledging the drain"
      (boundedSupervision testFinishHandlesBacklog)

  describe "Stop or cancellation before the drain" $ do
    it "reports a stop requested before the drain as unfinished, discarding the backlog"
      (boundedSupervision testStopBeforeDrain)
    it "reports a cancellation committed before the dispatch decision as unfinished, with no acknowledgement"
      (boundedSupervision testCancellationBeforeDrain)
    it "never acknowledges a drain when a stop races the final empty-inbox observation"
      (boundedSupervision testStopRacesFinalObservation)

  describe "Failures during finish" $ do
    it "reports a recognized optional handler failure as unavailable with one warning, without waiting for a drain"
      (boundedSupervision testUnavailableDuringFinish)
    it "propagates a required handler failure with its original evidence"
      (boundedSupervision (testFatalDuringFinish requiredInbox))
    it "propagates an unrecognized optional handler failure with its original evidence"
      (boundedSupervision (testFatalDuringFinish unrecognizedOptionalInbox))
    it "propagates a cleanup failure after the drain with its evidence, keeping the acknowledgement"
      (boundedSupervision testCleanupFailureDuringFinish)

  describe "Unrelated outcomes" $ do
    it "settles a completed job and an unavailable optional worker during the finish wait, then finishes"
      (boundedSupervision testUnrelatedOutcomes)

  describe "Cancellation after the drain" $ do
    it "keeps the acknowledgement and the cancelled completion, is not a successful finish, and repeats nothing"
      (boundedSupervision testCancellationAfterDrain)

  describe "Owner cancellation" $ do
    it "keeps a borrowed dependency usable until the service's cleanup finishes"
      (boundedSupervision testOwnerCancelledDuringFinish)

  describe "Combined example" $ do
    it "publishes each handled command's state after handling it, and keeps the final snapshot readable after finish"
      (boundedSupervision testCommandSnapshotService)

-- Reading outcomes -------------------------------------------------------------

exitText ∷ InboxExit → Text
exitText exit = "discarded " <> showText (inboxDiscarded exit) <> ", " <> drainText (inboxDrain exit)

drainText ∷ Maybe DrainAcknowledgement → Text
drainText = maybe "no drain" (\acknowledgement → "drained after " <> showText (drainHandled acknowledgement))

completionText ∷ Completion InboxExit → Text
completionText completion = case completionResult completion of
  Succeeded exit → "succeeded with " <> exitText exit
  Failed _ → "failed"
  Cancelled _ → "cancelled"

finishText ∷ InboxFinish → Text
finishText = \case
  InboxFinished exit → "finished: " <> exitText exit
  InboxUnfinished drain completion → "unfinished: " <> drainText drain <> "; " <> completionText completion
  InboxFinishUnavailable _ → "unavailable"

acknowledgedText ∷ InboxService a → IO Text
acknowledgedText started = drainText <$> atomically (inboxAcknowledgedDrain started)

-- | Open a gate once the thread is parked in a supervised wait.
openWhenWaiting ∷ ThreadId → Gate → IO ()
openWhenWaiting thread gate = void (forkIO (awaitBlockedOnSTM thread >> openGate gate))

-- In-flight and backlog work ---------------------------------------------------

testFinishHandlesBacklog ∷ Expectation
testFinishHandlesBacklog = do
  trace ← newTrace
  probe ← newEmptyMVar
  firstEntered ← newEmptyMVar
  firstGate ← newGate
  lastEntered ← newEmptyMVar
  lastGate ← newGate
  duringLast ← newEmptyMVar
  application ← myThreadId
  let holding value
        | value == 1 = putMVar firstEntered () >> readMVar firstGate
        | value == 4 = putMVar lastEntered () >> readMVar lastGate
        | otherwise = pure ()
  (first, second, exit, late, acknowledged, status, warnings) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 holding)
      _ ← offer started 1
      takeMVar firstEntered
      traverse_ (offer started) [2, 3, 4]
      -- Message 1 is in flight with three queued behind it when the finish is
      -- requested. Inside the last handler the drain is not yet acknowledged.
      _ ← forkIO $ do
        awaitBlockedOnSTM application
        openGate firstGate
        takeMVar lastEntered
        acknowledgedText started >>= putMVar duringLast
        openGate lastGate
      first ← finishInboxService control started
      record trace "finished"
      second ← finishInboxService control started
      late ← offer started 5
      completion ← atomically (awaitInboxCompletion started)
      (,,,,,,) (finishText first) (finishText second) (completionExit completion) late
        <$> acknowledgedText started
        <*> statusOf started
        <*> warningCount collected
  takeMVar duringLast >>= (`shouldBe` "no drain")
  first `shouldBe` "finished: discarded 0, drained after 4"
  second `shouldBe` first
  -- The stop request came before the service returned, so it is an expected
  -- stop rather than an unexpected service exit.
  exit `shouldBe` RunExited RunReturned StopWasRequested
  late `shouldBe` Closed
  acknowledged `shouldBe` "drained after 4"
  status `shouldBe` "stopped"
  warnings `shouldBe` 0
  traced trace
    >>= (`shouldBe` ["acquire context", "handle 1", "handle 2", "handle 3", "handle 4", "release context: inbox closed", "finished"])

-- Stop or cancellation before the drain ----------------------------------------

testStopBeforeDrain ∷ Expectation
testStopBeforeDrain = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  application ← myThreadId
  (outcome, acknowledged, status) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 (holdingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      traverse_ (offer started) [2, 3]
      stopInboxService started
      openWhenWaiting application gate
      outcome ← finishInboxService control started
      (,,) (finishText outcome) <$> acknowledgedText started <*> statusOf started
  -- An ordinary stop keeps its real discard count and records no drain.
  outcome `shouldBe` "unfinished: no drain; succeeded with discarded 2, no drain"
  acknowledged `shouldBe` "no drain"
  status `shouldBe` "stopped"
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testCancellationBeforeDrain ∷ Expectation
testCancellationBeforeDrain = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  (outcome, exit, acknowledged, status) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 (holdingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      _ ← offer started 2
      -- The cancellation is committed while message 1 is in flight, before the
      -- next dispatch decision; the gate never opens.
      cancelInboxService started
      outcome ← finishInboxService control started
      completion ← atomically (awaitInboxCompletion started)
      (,,,) (finishText outcome) (completionExit completion) <$> acknowledgedText started <*> statusOf started
  outcome `shouldBe` "unfinished: no drain; cancelled"
  exit `shouldBe` RunExited RunCancelled CancelWasRequested
  acknowledged `shouldBe` "no drain"
  status `shouldBe` "stopped"
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testStopRacesFinalObservation ∷ Expectation
testStopRacesFinalObservation = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  application ← myThreadId
  (outcome, acknowledged) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 (holdingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      -- Message 1 is the last accepted message. The stop is requested and
      -- admission closed before its handler returns, so the requested stop and
      -- the closed, empty inbox are both ready at the next decision.
      stopInboxService started
      openWhenWaiting application gate
      outcome ← finishInboxService control started
      (,) (finishText outcome) <$> acknowledgedText started
  outcome `shouldBe` "unfinished: no drain; succeeded with discarded 0, no drain"
  acknowledged `shouldBe` "no drain"
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

-- Failures during finish -------------------------------------------------------

testUnavailableDuringFinish ∷ Expectation
testUnavailableDuringFinish = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  application ← myThreadId
  (outcome, acknowledged, status, warnings) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control optionalInbox (inbox trace probe 4 (failingFirst entered gate))
      _ ← offer started 1
      takeMVar entered
      traverse_ (offer started) [2, 3]
      openWhenWaiting application gate
      outcome ← finishInboxService control started
      checkRuntime control
      (,,,) outcome <$> acknowledgedText started <*> statusOf started <*> warningCount collected
  case outcome of
    InboxFinishUnavailable failure → failure `shouldSatisfy` brokenIs "handler"
    _ → expectationFailure ("expected an unavailable finish, found " <> show (finishText outcome))
  acknowledged `shouldBe` "no drain"
  status `shouldBe` "unavailable"
  warnings `shouldBe` 1
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testFatalDuringFinish ∷ InboxPolicy → Expectation
testFatalDuringFinish policy = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  retained ← newIORef Nothing
  application ← myThreadId
  ExceptionWithContext context raised ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control policy (inbox trace probe 4 (failingFirst entered gate))
      writeIORef retained (Just started)
      _ ← offer started 1
      takeMVar entered
      traverse_ (offer started) [2, 3]
      openWhenWaiting application gate
      finishInboxService control started
  fromException raised `shouldBe` Just (Broken "handler")
  [name | Provenance name ← getExceptionAnnotations context] `shouldBe` ["handler"]
  Just started ← readIORef retained
  acknowledgedText started >>= (`shouldBe` "no drain")
  statusOf started >>= (`shouldBe` "fatal")
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

testCleanupFailureDuringFinish ∷ Expectation
testCleanupFailureDuringFinish = do
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
      _ ← offer started 1
      finishInboxService control started
  failure `shouldSatisfy` brokenIs "release"
  length (cleanupFailuresInContext context) `shouldBe` 1
  Just started ← readIORef retained
  acknowledgedText started >>= (`shouldBe` "drained after 1")
  completion ← atomically (awaitInboxCompletion started)
  completionText completion `shouldBe` "failed"
  length (completionCleanup completion) `shouldBe` 1
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])

-- Unrelated outcomes -----------------------------------------------------------

testUnrelatedOutcomes ∷ Expectation
testUnrelatedOutcomes = do
  trace ← newTrace
  others ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  jobGate ← newGate
  failureGate ← newGate
  application ← myThreadId
  (outcome, acknowledged, statuses, warnings) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control requiredInbox (inbox trace probe 4 (holdingFirst entered gate))
      counted ← expectStarted =<< startSupervised control (required Job) (job "count" (\_ → readMVar jobGate >> pure (7 ∷ Int)))
      flaky ← expectStarted =<< startSupervised control (optional Service) (failingAfter others "flaky" failureGate (Broken "flaky"))
      let settled worker = atomically (workerStatus worker >>= \case WorkerLive → retry; _ → pure ())
      _ ← offer started 1
      takeMVar entered
      _ ← offer started 2
      -- While the finish waits with message 1 in flight, the job completes and
      -- the optional worker fails; each is settled before the drain can happen.
      _ ← forkIO $ do
        awaitBlockedOnSTM application
        openGate jobGate
        settled counted
        awaitBlockedOnSTM application
        openGate failureGate
        settled flaky
        awaitBlockedOnSTM application
        openGate gate
      outcome ← finishInboxService control started
      statuses ← atomically ((,) <$> workerStatus counted <*> workerStatus flaky)
      (,,,) (finishText outcome) <$> acknowledgedText started <*> pure (bimap statusName statusName statuses) <*> warningCount collected
  outcome `shouldBe` "finished: discarded 0, drained after 2"
  acknowledged `shouldBe` "drained after 2"
  statuses `shouldBe` ("completed", "unavailable")
  warnings `shouldBe` 1
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "handle 2", "release context: inbox closed"])
  where
    bimap f g (a, b) = (f a, g b)

-- Cancellation after the drain -------------------------------------------------

testCancellationAfterDrain ∷ Expectation
testCancellationAfterDrain = do
  trace ← newTrace
  others ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  workerThread ← newEmptyMVar
  failureGate ← newGate
  classifying ← newEmptyMVar
  classifierGate ← newGate
  application ← myThreadId
  let noting =
        inboxDefinition
          "inbox"
          4
          (\_ → probedContext trace probe >> liftIO (myThreadId >>= putMVar workerThread))
          (handling trace (holdingFirst entered gate))
      -- An unrelated optional worker whose classifier waits on a gate, holding
      -- the finish's supervised wait while it settles that worker.
      held =
        WorkerPolicy Service Optional supervisionComponent $ \_ →
          putMVar classifying () >> readMVar classifierGate >> pure Recognized
  (first, second, acknowledged, again, completion, statuses, warnings) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← startedWith probe =<< startInboxService control optionalInbox noting
      flaky ← expectStarted =<< startSupervised control held (failingAfter others "flaky" failureGate (Broken "flaky"))
      worker ← readMVar workerThread
      _ ← offer started 1
      takeMVar entered
      -- With the finish held in the classifier, the service drains and
      -- acknowledges, and is then cancelled while it waits for its stop.
      _ ← forkIO $ do
        awaitBlockedOnSTM application
        openGate failureGate
        takeMVar classifying
        openGate gate
        atomically (inboxAcknowledgedDrain started >>= maybe retry (\_ → pure ()))
        throwTo worker ThreadKilled
        _ ← atomically (awaitInboxCompletion started)
        openGate classifierGate
      first ← finishInboxService control started
      acknowledged ← acknowledgedText started
      second ← finishInboxService control started
      again ← acknowledgedText started
      completion ← atomically (awaitInboxCompletion started)
      statuses ← (,) <$> statusOf started <*> (statusName <$> atomically (workerStatus flaky))
      (,,,,,,) first second acknowledged again completion statuses <$> warningCount collected
  -- Supervision judges the cancellation, which no owner asked for, by the
  -- service's policy; the finish reports that, never a successful finish.
  for2 first second $ \case
    InboxFinishUnavailable (ExceptionWithContext _ failure) → case fromException failure of
      Just (UnexpectedWorkerTermination _) → pure ()
      Nothing → expectationFailure "expected the cancellation to be judged an unexpected termination"
    outcome → expectationFailure ("expected an unavailable finish, found " <> show (finishText outcome))
  acknowledged `shouldBe` "drained after 1"
  again `shouldBe` acknowledged
  completionExit completion `shouldBe` RunExited RunCancelled NothingRequested
  case completionResult completion of
    Cancelled (ExceptionWithContext _ cancellation) → fromException cancellation `shouldBe` Just ThreadKilled
    _ → expectationFailure ("expected a cancelled completion, found " <> show (completionText completion))
  statuses `shouldBe` ("unavailable", "unavailable")
  warnings `shouldBe` 2
  traced trace >>= (`shouldBe` ["acquire context", "handle 1", "release context: inbox closed"])
  where
    for2 a b check = check a >> check b

-- Owner cancellation -----------------------------------------------------------

testOwnerCancelledDuringFinish ∷ Expectation
testOwnerCancelledDuringFinish = do
  trace ← newTrace
  probe ← newEmptyMVar
  entered ← newEmptyMVar
  gate ← newGate
  done ← newEmptyMVar
  live ← newIORef False
  let dependency =
        allocResource
          (writeIORef live True >> record trace "acquire dependency")
          (\() → writeIORef live False >> record trace "release dependency")
      describeLive = (\alive → if alive then "live" else "released") <$> readIORef live
      context _ = allocResource (pure ()) (\() → describeLive >>= \state → record trace ("release context: dependency " <> state))
      handler () message = do
        let value = preparedValue message
        state ← describeLive
        record trace ("handle " <> showText value <> ": dependency " <> state)
        when (value == 1) (putMVar entered () >> readMVar gate)
  owner ← forkIO $ do
    outcome ← tryWithContext @SomeException $ withScoped dependency $ \() →
      withCollectedLifetime ignoreWrites $ \collected →
        withSupervision (collectedLifetime collected) $ \control → do
          started ← startedWith probe =<< startInboxService control requiredInbox (inboxDefinition "inbox" 4 context handler)
          traverse_ (offer started) [1, 2]
          finishInboxService control started
    putMVar done outcome
  takeMVar entered
  -- The owner is parked in the finish's wait with message 1 in flight.
  awaitBlockedOnSTM owner
  killThread owner
  takeMVar done >>= \case
    Left (ExceptionWithContext _ raised) → fromException raised `shouldBe` Just ThreadKilled
    Right outcome → expectationFailure ("the cancelled owner returned " <> show (finishText outcome))
  traced trace
    >>= (`shouldBe` ["acquire dependency", "handle 1: dependency live", "release context: dependency live", "release dependency"])

-- Combined example -------------------------------------------------------------

-- | An application-owned command protocol for a counter.
data Command
  = Add !Int
  | Reset
  deriving (Eq, Show)

instance NFData Command where
  rnf (Add amount) = rnf amount
  rnf Reset = ()

testCommandSnapshotService ∷ Expectation
testCommandSnapshotService = do
  trace ← newTrace
  publisher ← newSnapshot =<< prepare (0 ∷ Int)
  let reader = snapshotReader publisher
      -- The service owns the publication endpoint for its run and closes it
      -- during teardown; the application keeps only the reader.
      counter _ =
        allocResource
          (newIORef 0)
          (\_ → atomically (closeSnapshot publisher) >> record trace "close publication")
      handler total message = do
        let command = preparedValue message
        record trace ("handle " <> showText command)
        modifyIORef' total (\current → case command of Add amount → current + amount; Reset → 0)
        state ← readIORef total
        _ ← prepare state >>= atomically . publish publisher
        record trace ("published " <> showText state)
      command' started command = do
        sent ← prepare command >>= atomically . send (inboxSender started)
        when (sent /= Accepted) (throwIO (userError ("the counter did not accept " <> show command)))
  initial ← atomically (readSnapshot reader)
  (observed, outcome) ← withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      started ← expectInbox =<< startInboxService control requiredInbox (inboxDefinition "counter" 8 counter handler)
      command' started (Add 2)
      -- The application waits for the state the handled command published.
      update ← awaitSupervised control (awaitSnapshot reader (observedCursor initial))
      observed ← case update of
        Updated observation → pure (preparedValue (observedValue observation))
        EndOfStream → throwIO (userError "the snapshot closed before the first command was handled")
      traverse_ (command' started) [Add 5, Reset, Add 3]
      outcome ← finishInboxService control started
      record trace ("finished: " <> finishText outcome)
      pure (observed, outcome)
  observed `shouldBe` 2
  finishText outcome `shouldBe` "finished: discarded 0, drained after 4"
  -- After finish and teardown the last value stays readable, and the closed
  -- snapshot ends a reader that has seen it.
  final ← atomically (readSnapshot reader)
  preparedValue (observedValue final) `shouldBe` 3
  ended ← atomically (awaitSnapshot reader (observedCursor final))
  case ended of
    EndOfStream → pure ()
    Updated _ → expectationFailure "expected the closed snapshot to end the stream"
  traced trace
    >>= ( `shouldBe`
            [ "handle Add 2"
            , "published 2"
            , "handle Add 5"
            , "published 7"
            , "handle Reset"
            , "published 0"
            , "handle Add 3"
            , "published 3"
            , "close publication"
            , "finished: finished: discarded 0, drained after 4"
            ]
        )
  where
    expectInbox = \case
      InboxStarted started → pure started
      InboxStartUnavailable _ → throwIO (userError "expected a started inbox, found an unavailable one")
      InboxStartRejected → throwIO (userError "expected a started inbox, found a rejection")
