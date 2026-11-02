-- | A sibling's failure while a start is in progress: its status is committed before the new worker
-- is drained, however long the new worker is held.
--
-- Every example holds the new worker where nothing can end it: inside an uninterruptible wait that
-- only the example's own gate leaves. Cancellation and stop requests cannot release it, so a drain
-- of that worker cannot finish until the example lets it go, and anything that waits for the drain
-- cannot be what makes a sibling's status readable. The held worker says when it first sees a
-- request to stop or to be cancelled, and the example reads the sibling's status from another
-- thread at that moment, while the worker is still held: a latched failure stops every pending
-- worker in the transaction that commits it, so the status is there when the stop arrives, and a
-- status committed only after the drain is not.
--
-- Every example releases its held worker whatever its own observation found, and reports what it
-- found only after the drain: a failed observation ends the example with its own message, never with
-- a drain that waits for a worker nothing releases. The only deadline here (@deadline@) lets an
-- observation that nothing signals fail the example; it never decides what a correct run does.
module Test.Runtime.Supervision.Startup (spec) where

import Control.Concurrent (killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , finally
  , fromException
  , rethrowIO
  , throwIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (LogEntry (..), LogLevel (..))
import Hetoimasia.Foundation.Worker
  ( WorkerDefinition
  , WorkerEvidence (..)
  , awaitStopRequest
  , stopRequested
  , workerDefinition
  , workerEvidenceInContext
  )
import Hetoimasia.Runtime.Supervision
import System.Timeout (timeout)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Runtime.OwnedControl
  ( ControlProbe (..)
  , Scope
  , Unowned
  , endedAfterScope
  , endings
  , newControlProbe
  , recordSelf
  , runEnding
  , startUnowned
  , withRescue
  )
import Test.Support.Owned (withOwnedThreadOpening)
import Test.Runtime.Supervision.Support

spec ∷ Spec
spec = describe "A sibling's failure while a start is in progress" $ do
  describe "is committed before the new worker is drained" $ do
    it "for a required worker, while the new worker is held in its startup"
      (boundedSupervision (testFatalSibling (required Service)))
    it "for an optional worker whose failure is not recognized, while the new worker is held in its startup"
      (boundedSupervision (testFatalSibling (recognizing Service Optional (const False))))
    it "for a recognized optional worker: the tolerated status is readable while the new worker is held, and the start goes on"
      (boundedSupervision testToleratedSibling)
  describe "is not classified once the owner has cancelled the start" $ do
    it "during a classifier the start is running, which commits nothing and still drains the new worker first"
      (boundedSupervision testCancelledDuringClassification)
    it "after a tolerated sibling was committed and the start went back to waiting"
      (boundedSupervision testCancelledAfterTolerated)
  -- The owners above run a start whose drain waits for a worker held uninterruptibly; the held worker's release is part of the
  -- owner's own start, so it is open however the example ends, including before the observer exists (#597).
  describe "The owner of a start that holds a worker (withOwnedThreadOpening)" $
    for_ endings $ \(label, ending) → do
      it ("has ended and been joined, the held worker released, when the example " <> label) $ do
        probe ← newControlProbe
        held ← newHeld
        trace ← newTrace
        runEnding (ownedHeldStart held probe) (const (heldStart trace held probe)) probe ending
        endedAfterScope probe >>= (`shouldBe` True)

      it ("negative control: the previous unowned start leaves the owner held when the example " <> label) $ do
        probe ← newControlProbe
        held ← newHeld
        trace ← newTrace
        withRescue $ \started → do
          runEnding (unownedHeldStart started held probe) (const (heldStart trace held probe)) probe ending
          -- The failed judgement is recorded before anything independent touches the owner.
          judgement ← endedAfterScope probe
          judgement `shouldBe` False
        -- The rescue released the held worker, then stopped and joined the owner.
        endedAfterScope probe >>= (`shouldBe` True)

-- Fixtures ----------------------------------------------------------------------

-- | How long an observation that nothing may signal is waited for before the example fails. It
-- never decides what a correct run does.
deadline ∷ Int
deadline = 10 * 1000 * 1000

-- | Take a signal, or fail the example with this message when none comes in time.
within ∷ String → MVar () → Expectation
within message signal = timeout deadline (takeMVar signal) >>= maybe (expectationFailure message) pure

-- | What an example shares with the worker it holds.
data Held = Held
  { heldEntered ∷ MVar ()
    -- ^ Put when the worker is in its hold.
  , heldSeen ∷ MVar ()
    -- ^ Put when the worker first sees a request to stop or to be cancelled.
  , heldRelease ∷ Gate
  , heldRan ∷ MVar Bool
    -- ^ Put by the run action when it begins, with whether a stop had been requested by then.
  }

newHeld ∷ IO Held
newHeld = Held <$> newEmptyMVar <*> newEmptyMVar <*> newGate <*> newEmptyMVar

-- | A service held in its startup where nothing can end it, until the example opens 'heldRelease'.
--
-- With @onRequest@ it first waits for a request to stop or to be cancelled, and says so before it is
-- held, so the example knows when to read the sibling's status. Without it the worker is held at
-- once and a request changes nothing until it is released. Once released it acknowledges, and its run
-- action records whether a stop had been requested of it by then.
heldService ∷ Trace → Text → Bool → Held → WorkerDefinition ()
heldService trace name onRequest held =
  workerDefinition name (\token → owned trace name >> liftIO (hold token)) $ \token () → do
    stopped ← atomically (stopRequested token)
    void (tryPutMVar (heldRan held) stopped)
    atomically (awaitStopRequest token)
  where
    hold token = do
      void (tryPutMVar (heldEntered held) ())
      when onRequest $ do
        _ ← try @SomeException (atomically (awaitStopRequest token))
        void (tryPutMVar (heldSeen held) ())
      uninterruptibleMask_ (readMVar (heldRelease held))

-- | The status of a worker, with the failure it holds.
isFatalBroken ∷ Text → WorkerStatus → Bool
isFatalBroken expected = \case
  WorkerFatal failure → brokenIs expected failure
  _ → False

isUnavailableBroken ∷ Text → WorkerStatus → Bool
isUnavailableBroken expected = \case
  WorkerUnavailable failure → brokenIs expected failure
  _ → False

-- | Wait until a worker's status is no longer live, and answer it.
awaitCommitted ∷ SupervisedWorker r → IO WorkerStatus
awaitCommitted worker =
  atomically $
    workerStatus worker >>= \case
      WorkerLive → retry
      status → pure status

-- | Run the observation on a thread the scope owns, and release the held worker when it is over, whatever
-- it found: its result, or its failure, is what the example reports after the drain.
--
-- The observer supplies what the drain waits for (the held worker's release), so its scope encloses that drain: it is ended
-- and joined after the exit it serves, never before it. The release is also part of the scope's stop, in the same
-- uninterruptible step and before the kill, so an example that fails or is cancelled before the observation finishes cannot
-- leave the drain waiting for the held worker, and the join cannot wait for an observer the drain is waiting on.
--
-- The thread records its outcome and ends (it is the subject the example inspects, and a cancellation it receives is part of
-- that record, not swallowed: the thread ends with it).
withObserving ∷ Held → IO a → (MVar (Either SomeException a) → IO b) → IO b
withObserving held observation body = do
  outcome ← newEmptyMVar
  withOwnedThreadOpening
    (openGate (heldRelease held))
    ((try observation >>= putMVar outcome) `finally` openGate (heldRelease held))
    (\_ _ → body outcome)

-- | The observation, after the drain: its failure is the example's.
reported ∷ MVar (Either SomeException a) → IO a
reported outcome = takeMVar outcome >>= either throwIO pure

-- | A sibling that fails while a new worker is held: its status is already its failure when the held
-- worker first sees the stop the latch asks of it, and the start still drains the new worker before
-- it rethrows that failure, once.
testFatalSibling ∷ WorkerPolicy → Expectation
testFatalSibling policy = do
  trace ← newTrace
  gate ← newGate
  held ← newHeld
  -- The supervision runs on a thread the example owns, whose stop releases the held worker first (see 'runOwnedScope').
  failure ← runOwnedScope (openGate (heldRelease held)) $ expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      sibling ← expectStarted =<< startSupervised control policy (failingAfter trace "audio" gate (Broken "audio"))
      withObserving held
        ( do
            readMVar (heldEntered held) >> openGate gate
            within "the held worker never saw a request" (heldSeen held)
            -- Still held: only the example's release lets the worker go.
            atomically (workerStatus sibling)
        )
        $ \observed → do
          started ← attempt (startSupervised control (required Service) (heldService trace "streaming" True held))
          record trace "start unwound"
          status ← reported observed
          -- Committed before the drain, which the start then waited for.
          status `shouldSatisfy` isFatalBroken "audio"
          case started of
            Left raised → rethrowIO raised
            Right _ → expectationFailure "the start returned"
  failure `shouldSatisfy` brokenIs "audio"
  -- Rethrown to the starter, once and not retained beside itself; the new worker was stopped by its
  -- owner and drained before the start unwound.
  retainedLabels failure `shouldBe` []
  entries ← traced trace
  [entry | entry ← entries, entry `elem` ["release streaming", "start unwound"]] `shouldBe` ["release streaming", "start unwound"]

-- | A recognized optional sibling that fails while a new worker is held: its tolerated status is
-- readable while the new worker is held, its one warning is attempted once, and the healthy new worker
-- is neither stopped nor cancelled: its start completes when it is released.
testToleratedSibling ∷ Expectation
testToleratedSibling = do
  trace ← newTrace
  gate ← newGate
  held ← newHeld
  -- The supervision runs on a thread the example owns, whose stop releases the held worker first (see 'runOwnedScope').
  (observed, warnings, newStatus, afterwards) ← runOwnedScope (openGate (heldRelease held)) $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \control → do
      sibling ← expectStarted =<< startSupervised control (optional Service) (failingAfter trace "telemetry" gate (Broken "telemetry"))
      withObserving held
        ( do
            readMVar (heldEntered held) >> openGate gate
            -- The tolerated commit is no signal of its own: it is read, and the deadline only fails the
            -- example when it never comes while the worker is held.
            timeout deadline (awaitCommitted sibling)
        )
        $ \observed → do
          started ← startSupervised control (required Service) (heldService trace "streaming" False held)
          worker ← expectStarted started
          status ← reported observed
          stopped ← takeMVar (heldRan held)
          checkRuntime control
          warnings ← warningCount collected
          newStatus ← statusOf worker
          stopSupervised worker
          pure (status, warnings, newStatus, stopped)
  observed `shouldSatisfy` maybe False (isUnavailableBroken "telemetry")
  warnings `shouldBe` 1
  newStatus `shouldBe` "live"
  -- No stop had reached the healthy worker by the time its run began.
  afterwards `shouldBe` False

-- | The owner cancels the start while the start is running a sibling's classifier: nothing is
-- committed and no further classifier runs, the new worker is drained before the cancellation
-- propagates, and it propagates as itself, with the abandoned start as evidence.
testCancelledDuringClassification ∷ Expectation
testCancelledDuringClassification = do
  trace ← newTrace
  gate ← newGate
  held ← newHeld
  classifying ← newEmptyMVar
  classifyGate ← newGate
  classified ← newIORef (0 ∷ Int)
  done ← newEmptyMVar
  ended ← newEmptyMVar
  let policy = WorkerPolicy Service Required supervisionComponent $ \_ → do
        atomicModifyIORef' classified (\count → (count + 1, ()))
        void (tryPutMVar classifying ())
        readMVar classifyGate
        pure Unrecognized
  withOwnedThreadOpening
    (openGate (heldRelease held))
    ( do
        outcome ← attempt $ withCollectedLifetime ignoreWrites $ \collected →
          withSupervision (collectedLifetime collected) $ \control → do
            sibling ← expectStarted =<< startSupervised control policy (failingAfter trace "audio" gate (Broken "audio"))
            started ← attempt (startSupervised control (required Service) (heldService trace "streaming" False held))
            record trace "start unwound"
            siblingStatus ← statusOf sibling
            count ← readIORef classified
            putMVar done (started, siblingStatus, count)
            -- The boundary settles the sibling at closing, as it would have at a checkpoint.
            openGate classifyGate
        putMVar ended outcome
    )
    $ \owner _ → do
      withObserving held
        ( do
            readMVar (heldEntered held) >> openGate gate
            within "the start never classified the sibling" classifying
            killThread owner
        )
        $ \observed → do
          -- The cancellation is delivered and the drain waits for the held worker, which the observation
          -- released: what the owner saw is reported once the start has unwound.
          reported observed
          (started, siblingStatus, count) ← takeMVar done
          case started of
            Right _ → expectationFailure "the cancelled start returned"
            Left (ExceptionWithContext context raised) → do
              fromException raised `shouldBe` Just ThreadKilled
              length [() | AbandonedStart _ ← workerEvidenceInContext context] `shouldBe` 1
          siblingStatus `shouldBe` "live"
          count `shouldBe` 1
          closing ← takeMVar ended
          -- At closing the sibling's failure is settled and rethrown, as ever.
          either (brokenIs "audio") (const False) closing `shouldBe` True
          traced trace >>= (`shouldSatisfy` elem "release streaming")

-- | The owner cancels the start after a tolerated sibling was committed and the start went back to
-- waiting: the cancellation propagates as itself after the drain, a sibling failing meanwhile is
-- classified by nothing, and the abandoned start is evidence.
testCancelledAfterTolerated ∷ Expectation
testCancelledAfterTolerated = do
  trace ← newTrace
  telemetryGate ← newGate
  videoGate ← newGate
  held ← newHeld
  warned ← newEmptyMVar
  videoSlot ← newEmptyMVar
  done ← newEmptyMVar
  ended ← newEmptyMVar
  videoClassified ← newIORef (0 ∷ Int)
  let videoPolicy = WorkerPolicy Service Required supervisionComponent $ \_ → do
        atomicModifyIORef' videoClassified (\count → (count + 1, ()))
        pure Unrecognized
      onWrite entry = when (entryLevel entry == Warning) (void (tryPutMVar warned ()))
  withOwnedThreadOpening
    (openGate (heldRelease held))
    ( do
        outcome ← attempt $ withCollectedLifetime onWrite $ \collected →
          withSupervision (collectedLifetime collected) $ \control → do
            telemetry ← expectStarted =<< startSupervised control (optional Service) (failingAfter trace "telemetry" telemetryGate (Broken "telemetry"))
            video ← expectStarted =<< startSupervised control videoPolicy (failingAfter trace "video" videoGate (Broken "video"))
            putMVar videoSlot video
            started ← attempt (startSupervised control (required Service) (heldService trace "streaming" False held))
            statuses ← (,) <$> statusOf telemetry <*> statusOf video
            count ← readIORef videoClassified
            warnings ← warningCount collected
            putMVar done (started, statuses, count, warnings)
        putMVar ended outcome
    )
    $ \owner _ → do
      video ← takeMVar videoSlot
      withObserving held
        ( do
            readMVar (heldEntered held) >> openGate telemetryGate
            -- The warning is the tolerated commit's last act; the start then parks in its wait again.
            within "the start never committed the tolerated sibling" warned
            awaitBlockedOnSTM owner
            killThread owner
            openGate videoGate
            void (awaitTerminal (supervisedWorker video))
        )
        $ \observed → do
          reported observed
          (started, (telemetryStatus, videoStatus), count, warnings) ← takeMVar done
          case started of
            Right _ → expectationFailure "the cancelled start returned"
            Left (ExceptionWithContext context raised) → do
              fromException raised `shouldBe` Just ThreadKilled
              length [() | AbandonedStart _ ← workerEvidenceInContext context] `shouldBe` 1
          telemetryStatus `shouldBe` "unavailable"
          warnings `shouldBe` 1
          -- Published after the cancellation: nothing classified it while the start unwound.
          videoStatus `shouldBe` "live"
          count `shouldBe` 0
          closing ← takeMVar ended
          either (brokenIs "video") (const False) closing `shouldBe` True
          traced trace >>= (`shouldSatisfy` elem "release streaming")

-- | An owner whose start is held: it starts a worker that waits uninterruptibly for the example to release it, so its drain
-- cannot finish until then.
heldStart ∷ Trace → Held → ControlProbe → IO ()
heldStart trace held probe = do
  recordSelf probe
  void . attempt $
    withCollectedLifetime ignoreWrites $ \collected →
      withSupervision (collectedLifetime collected) $ \control →
        void (startSupervised control (required Service) (heldService trace "streaming" False held))

-- | The owner is held once the worker has entered its hold: the signal the endings wait for.
ownedHeldStart ∷ Held → ControlProbe → Scope
ownedHeldStart held probe action body =
  withOwnedThreadOpening (openGate (heldRelease held)) action $ \owner _ → do
    readMVar (heldEntered held)
    putMVar (controlParked probe) ()
    body owner

-- | The previous start of the same owner: nothing releases the held worker when the example ends.
unownedHeldStart ∷ IORef [Unowned] → Held → ControlProbe → Scope
unownedHeldStart started held probe action body = do
  owner ← startUnowned started (openGate (heldRelease held)) action
  readMVar (heldEntered held)
  putMVar (controlParked probe) ()
  body owner

-- Helpers ----------------------------------------------------------------------

ignoreWrites ∷ LogEntry → IO ()
ignoreWrites _ = pure ()

statusOf ∷ SupervisedWorker r → IO Text
statusOf worker =
  atomically (workerStatus worker) >>= \case
    WorkerLive → pure "live"
    WorkerCompleted → pure "completed"
    WorkerStopped → pure "stopped"
    WorkerUnavailable _ → pure "unavailable"
    WorkerFatal _ → pure "fatal"

retainedLabels ∷ ExceptionWithContext SomeException → [(Text, Severity)]
retainedLabels (ExceptionWithContext context _) =
  [(failedLabel entry, failedSeverity entry) | entry ← supervisedFailuresInContext context]

attempt ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
attempt = tryWithContext
