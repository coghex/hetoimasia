-- | Examples for 'Hetoimasia.Foundation.Messaging.Snapshot'.
--
-- Waits are coordinated explicitly: a thread is known to be blocked once
-- 'awaitBlockedOnSTM' says it has parked in a transaction, concurrent readers
-- start from a gate, and worker outcomes are read raw with 'awaitTerminal'
-- before a supervised wait is entered. That a read does not wait is proven with
-- 'orElse', which takes its alternative only if the read retried. No example
-- sleeps; 'boundedSupervision' only stops an example that has already hung.
module Test.Engine.Messaging.Snapshot (spec) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (STM, atomically, newTVarIO, orElse, readTVarIO, retry, throwSTM, writeTVar)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , throwIO
  , try
  , tryWithContext
  )
import Control.Monad (forM, forM_, unless, void)
import Data.Foldable (traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , FailureSite (..)
  , failureEvidenceInContext
  )
import Hetoimasia.Foundation.Log (SourceLocation (..))
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
import Hetoimasia.Foundation.Worker
  ( Completion (..)
  , Result (..)
  , StartOutcome (..)
  , awaitCompletion
  , awaitStopRequest
  , requestStop
  , startWorker
  , withWorkerGroup
  , workerDefinition
  )
import Hetoimasia.Runtime.Supervision
  ( Role (..)
  , WorkerStatus (..)
  , awaitSupervised
  , startSupervised
  , supervisedWorker
  , withSupervision
  , workerStatus
  )
import System.IO.Unsafe (unsafePerformIO)
import Test.Engine.Runtime.Supervision.Support
  ( Broken (..)
  , awaitBlockedOnSTM
  , awaitTerminal
  , boundedSupervision
  , brokenIs
  , collectedLifetime
  , expectFailure
  , expectStarted
  , failingAfter
  , newGate
  , newTrace
  , openGate
  , optional
  , required
  , warningCount
  , withCollectedLifetime
  )
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  describe "Snapshot publication" $ do
    it "observes the initial value at revision zero before any publication"
      testInitialValue
    it "advances the revision for a publication of an equal value"
      testEqualValueAdvances
    it "delivers the newest publication to each waiting reader without acknowledging for the others"
      (boundedSupervision testIndependentReaders)
    it "never pairs a value with another publication's revision under concurrent publication and reads"
      (boundedSupervision testCoherentPairs)
    it "leaves value and revision unchanged when a publication rolls back"
      testRollback
    it "publishes an observed prepared payload to another snapshot without evaluating it again"
      testForwarding

  describe "Snapshot close" $ do
    it "delivers an unseen final publication before end-of-stream and keeps the final value"
      testUnseenFinalBeforeEnd
    it "ends a waiter holding the initial cursor when closed before any publication, and again when repeated"
      testCloseBeforePublication
    it "wakes a blocked waiting read with end-of-stream"
      (boundedSupervision testCloseWakes)

  describe "Snapshot cursor mismatch" $ do
    it "raises a typed failure with engine origin, without waiting, for a cursor from another snapshot at the same revision"
      testForeignCursor

  describe "Snapshot composition" $ do
    it "leaves a blocked waiting read through a worker's stop request"
      (boundedSupervision testStopDuringWait)
    it "settles a nonfatal worker outcome before a ready supervised waiting read commits"
      (boundedSupervision testNonfatalBeforeWait)
    it "never commits a ready supervised waiting read while a fatal worker failure is pending"
      (boundedSupervision testFatalPreventsWait)

-- Fixtures -------------------------------------------------------------------

data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | A payload whose 'NFData' instance counts how many times it runs.
data Counted = Counted (IORef Int) [Text]

instance NFData Counted where
  rnf (Counted evaluations names) = countEvaluation evaluations `seq` rnf names

countEvaluation ∷ IORef Int → ()
countEvaluation evaluations = unsafePerformIO (modifyIORef' evaluations (+ 1))
{-# NOINLINE countEvaluation #-}

newIntSnapshot ∷ Int → IO (SnapshotPublisher Int)
newIntSnapshot initial = prepare initial >>= newSnapshot

publishInt ∷ SnapshotPublisher Int → Int → IO Publication
publishInt publisher value = prepare value >>= atomically . publish publisher

-- | A read as the value and revision it paired.
current ∷ SnapshotReader Int → IO (Int, Integer)
current reader = pairOf <$> atomically (readSnapshot reader)

pairOf ∷ Observation Int → (Int, Integer)
pairOf observation =
  (preparedValue (observedValue observation), toInteger (cursorRevision (observedCursor observation)))

updateText ∷ Update Int → String
updateText = \case
  Updated observation →
    let (value, revision) = pairOf observation
     in "value " <> show value <> " at " <> show revision
  EndOfStream → "end"

-- | A waiting read that must not wait: it reports "retried" if it would have.
immediate ∷ SnapshotReader Int → SnapshotCursor Int → IO String
immediate reader cursor = atomically ((updateText <$> awaitSnapshot reader cursor) `orElse` pure "retried")

-- | Run a wait on its own thread, perform the wake once that thread has parked
-- in its transaction, and return both results.
blockedUntil ∷ STM r → STM w → IO (r, w)
blockedUntil wait wake = do
  result ← newEmptyMVar
  waiter ← forkIO (atomically wait >>= putMVar result)
  awaitBlockedOnSTM waiter
  woke ← atomically wake
  waited ← takeMVar result
  pure (waited, woke)

ignoreWrites ∷ a → IO ()
ignoreWrites _ = pure ()

-- Publication ----------------------------------------------------------------

testInitialValue ∷ Expectation
testInitialValue = do
  publisher ← newIntSnapshot 5
  let reader = snapshotReader publisher
  current reader `shouldReturn` (5, 0)
  initial ← atomically (readSnapshot reader)
  -- Nothing newer: an open snapshot retries rather than returning the initial
  -- value again.
  immediate reader (observedCursor initial) `shouldReturn` "retried"
  current reader `shouldReturn` (5, 0)

testEqualValueAdvances ∷ Expectation
testEqualValueAdvances = do
  publisher ← newIntSnapshot 5
  let reader = snapshotReader publisher
  initial ← atomically (readSnapshot reader)
  publishInt publisher 5 `shouldReturn` Published
  current reader `shouldReturn` (5, 1)
  immediate reader (observedCursor initial) `shouldReturn` "value 5 at 1"
  -- The very same handle published again still advances the revision.
  atomically (publish publisher (observedValue initial)) `shouldReturn` Published
  current reader `shouldReturn` (5, 2)

testIndependentReaders ∷ Expectation
testIndependentReaders = do
  publisher ← newIntSnapshot 0
  let reader = snapshotReader publisher
  start ← observedCursor <$> atomically (readSnapshot reader)
  first ← newEmptyMVar
  second ← newEmptyMVar
  firstThread ← forkIO (atomically (awaitSnapshot reader start) >>= putMVar first)
  secondThread ← forkIO (atomically (awaitSnapshot reader start) >>= putMVar second)
  awaitBlockedOnSTM firstThread
  awaitBlockedOnSTM secondThread
  publishInt publisher 1 `shouldReturn` Published
  firstUpdate ← takeMVar first
  secondUpdate ← takeMVar second
  updateText firstUpdate `shouldBe` "value 1 at 1"
  updateText secondUpdate `shouldBe` "value 1 at 1"
  -- Neither reader acknowledged anything for the other or for a later reader:
  -- the original cursor still sees the publication.
  immediate reader start `shouldReturn` "value 1 at 1"

  -- The first reader advances its own cursor and misses nothing but the
  -- intermediate publications, which it never receives.
  advanced ← case firstUpdate of
    Updated observation → pure (observedCursor observation)
    EndOfStream → throwIO (userError "expected an update")
  immediate reader advanced `shouldReturn` "retried"
  forM_ [2, 3, 4] $ \value → publishInt publisher value `shouldReturn` Published
  immediate reader advanced `shouldReturn` "value 4 at 4"
  immediate reader start `shouldReturn` "value 4 at 4"

testCoherentPairs ∷ Expectation
testCoherentPairs = do
  -- Publication n carries value n, so a coherent read always has value equal to
  -- revision.
  publisher ← newIntSnapshot 0
  let reader = snapshotReader publisher
      count = 500
  -- Every reader starts from the initial cursor, captured before any
  -- publication, so a waiting reader scheduled after the last publication still
  -- has something newer to receive.
  initial ← observedCursor <$> atomically (readSnapshot reader)
  start ← newGate
  let checkedReader waiting = do
        done ← newEmptyMVar
        _ ← forkIO $ do
          outcome ← try @SomeException $ do
            readMVar start
            let loop cursor = do
                  observation ←
                    if waiting
                      then
                        atomically (awaitSnapshot reader cursor) >>= \case
                          Updated observation → pure observation
                          EndOfStream → throwIO (userError "ended before the last publication")
                      else atomically (readSnapshot reader)
                  let (value, revision) = pairOf observation
                  unless (toInteger value == revision) $
                    throwIO (userError ("value " <> show value <> " paired with revision " <> show revision))
                  unless (value == count) (loop (observedCursor observation))
            loop initial
          putMVar done outcome
        pure done
  readers ← forM [True, True, False, False] checkedReader
  openGate start
  forM_ [1 .. count] $ \value → publishInt publisher value `shouldReturn` Published
  traverse_ (\done → takeMVar done >>= either throwIO pure) readers
  current reader `shouldReturn` (count, toInteger count)

testRollback ∷ Expectation
testRollback = do
  publisher ← newIntSnapshot 1
  let reader = snapshotReader publisher
  payload ← prepare 2
  thrown ← try @Boom (atomically (publish publisher payload >> (throwSTM Boom ∷ STM ())))
  thrown `shouldBe` Left Boom
  current reader `shouldReturn` (1, 0)
  atomically ((publish publisher payload >> retry) `orElse` pure PublicationClosed)
    `shouldReturn` PublicationClosed
  current reader `shouldReturn` (1, 0)
  atomically (publish publisher payload) `shouldReturn` Published
  current reader `shouldReturn` (2, 1)

testForwarding ∷ Expectation
testForwarding = do
  evaluations ← newIORef 0
  prepared ← prepare (Counted evaluations ["left", "right"])
  readIORef evaluations `shouldReturn` 1
  first ← newSnapshot prepared
  seed ← prepare (Counted evaluations [])
  readIORef evaluations `shouldReturn` 2
  second ← newSnapshot seed
  observed ← atomically (readSnapshot (snapshotReader first))
  atomically (publish second (observedValue observed)) `shouldReturn` Published
  arrived ← atomically (readSnapshot (snapshotReader second))
  let Counted arrivedRef arrivedNames = preparedValue (observedValue arrived)
  (arrivedRef == evaluations) `shouldBe` True
  arrivedNames `shouldBe` ["left", "right"]
  cursorRevision (observedCursor arrived) `shouldBe` 1
  readIORef evaluations `shouldReturn` 2
  -- The control: preparing again does run the instance, so the counter would
  -- have seen an evaluation by either snapshot.
  void (prepare (preparedValue (observedValue arrived)))
  readIORef evaluations `shouldReturn` 3

-- Close ----------------------------------------------------------------------

testUnseenFinalBeforeEnd ∷ Expectation
testUnseenFinalBeforeEnd = do
  publisher ← newIntSnapshot 0
  let reader = snapshotReader publisher
  start ← observedCursor <$> atomically (readSnapshot reader)
  publishInt publisher 1 `shouldReturn` Published
  publishInt publisher 2 `shouldReturn` Published
  atomically (closeSnapshot publisher)
  final ←
    atomically (awaitSnapshot reader start) >>= \case
      Updated observation → pure observation
      EndOfStream → throwIO (userError "end-of-stream hid an unseen final publication")
  pairOf final `shouldBe` (2, 2)
  immediate reader (observedCursor final) `shouldReturn` "end"
  current reader `shouldReturn` (2, 2)
  publishInt publisher 3 `shouldReturn` PublicationClosed
  current reader `shouldReturn` (2, 2)
  atomically (closeSnapshot publisher)
  publishInt publisher 3 `shouldReturn` PublicationClosed
  immediate reader (observedCursor final) `shouldReturn` "end"
  current reader `shouldReturn` (2, 2)

testCloseBeforePublication ∷ Expectation
testCloseBeforePublication = do
  publisher ← newIntSnapshot 7
  let reader = snapshotReader publisher
  initial ← atomically (readSnapshot reader)
  atomically (closeSnapshot publisher)
  immediate reader (observedCursor initial) `shouldReturn` "end"
  afterClose ← atomically (readSnapshot reader)
  pairOf afterClose `shouldBe` (7, 0)
  (observedCursor afterClose == observedCursor initial) `shouldBe` True
  atomically (closeSnapshot publisher)
  immediate reader (observedCursor initial) `shouldReturn` "end"
  afterRepeat ← atomically (readSnapshot reader)
  pairOf afterRepeat `shouldBe` (7, 0)
  (observedCursor afterRepeat == observedCursor initial) `shouldBe` True

testCloseWakes ∷ Expectation
testCloseWakes = do
  publisher ← newIntSnapshot 0
  let reader = snapshotReader publisher
  start ← observedCursor <$> atomically (readSnapshot reader)
  (update, ()) ← blockedUntil (awaitSnapshot reader start) (closeSnapshot publisher)
  updateText update `shouldBe` "end"
  current reader `shouldReturn` (0, 0)

-- Cursor mismatch ------------------------------------------------------------

testForeignCursor ∷ Expectation
testForeignCursor = do
  foreignSnapshot ← newIntSnapshot 1
  publishInt foreignSnapshot 2 `shouldReturn` Published
  foreignCursor ← observedCursor <$> atomically (readSnapshot (snapshotReader foreignSnapshot))

  -- An open target at the same revision, where an owned cursor would retry.
  open ← newIntSnapshot 10
  publishInt open 11 `shouldReturn` Published
  ownOpen ← observedCursor <$> atomically (readSnapshot (snapshotReader open))
  cursorRevision ownOpen `shouldBe` cursorRevision foreignCursor
  immediate (snapshotReader open) ownOpen `shouldReturn` "retried"
  rejects (snapshotReader open) foreignCursor

  -- A closed target at the same revision, where an owned cursor would end.
  closed ← newIntSnapshot 20
  publishInt closed 21 `shouldReturn` Published
  ownClosed ← observedCursor <$> atomically (readSnapshot (snapshotReader closed))
  atomically (closeSnapshot closed)
  immediate (snapshotReader closed) ownClosed `shouldReturn` "end"
  rejects (snapshotReader closed) foreignCursor

  -- A retained cursor from a closed earlier lifetime, against its replacement
  -- at the same revision.
  atomically (closeSnapshot foreignSnapshot)
  replacement ← newIntSnapshot 1
  publishInt replacement 2 `shouldReturn` Published
  rejects (snapshotReader replacement) foreignCursor

  -- Nothing about the targets changed.
  current (snapshotReader open) `shouldReturn` (11, 1)
  current (snapshotReader closed) `shouldReturn` (21, 1)
  where
    rejects reader cursor = do
      outcome ← tryWithContext @ForeignSnapshotCursor (immediate reader cursor)
      case outcome of
        Right result → expectationFailure ("expected a cursor mismatch, but the read returned " <> result)
        Left (ExceptionWithContext context failure) → do
          failure `shouldBe` ForeignSnapshotCursor 1
          let evidence = failureEvidenceInContext context
          failureContexts evidence `shouldBe` []
          case failureCause evidence of
            EngineOrigin origin → do
              originComponent origin `shouldBe` messagingComponent
              originOperation origin `shouldBe` awaitSnapshotOperation
              originIdentifiers origin `shouldBe` [("cursor-revision", "1")]
              fmap (sourceFile . siteLocation) (originSite origin)
                `shouldSatisfy` maybe False ("Test/Engine/Messaging/Snapshot.hs" `Text.isSuffixOf`)
            NativeCause → expectationFailure ("expected an engine origin, but found " <> show evidence)

-- Composition ----------------------------------------------------------------

testStopDuringWait ∷ Expectation
testStopDuringWait = do
  publisher ← newIntSnapshot 0
  let reader = snapshotReader publisher
  start ← observedCursor <$> atomically (readSnapshot reader)
  exit ← withWorkerGroup $ \group → do
    parked ← newEmptyMVar
    let definition =
          workerDefinition "snapshot-waiter" (\_ → pure ()) $ \token () → do
            myThreadId >>= putMVar parked
            atomically ((Right <$> awaitSnapshot reader start) `orElse` (Left <$> awaitStopRequest token))
    startWorker group definition >>= \case
      Started worker → do
        takeMVar parked >>= awaitBlockedOnSTM
        atomically (requestStop worker)
        completion ← atomically (awaitCompletion worker)
        case completionResult completion of
          Succeeded (Left ()) → pure "stopped"
          Succeeded (Right update) → pure (updateText update)
          _ → throwIO (userError "the waiting worker did not return")
      _ → throwIO (userError "the waiting worker did not start")
  exit `shouldBe` "stopped"
  current reader `shouldReturn` (0, 0)

-- | A snapshot with one publication its reader has not seen, and the reader's
-- earlier cursor, so a waiting read from that cursor is ready at once.
readyWait ∷ IO (SnapshotReader Int, SnapshotCursor Int)
readyWait = do
  publisher ← newIntSnapshot 0
  let reader = snapshotReader publisher
  start ← observedCursor <$> atomically (readSnapshot reader)
  publishInt publisher 1 `shouldReturn` Published
  pure (reader, start)

testNonfatalBeforeWait ∷ Expectation
testNonfatalBeforeWait = do
  (reader, start) ← readyWait
  -- The waiting read commits a marker, so its commit is observable at the
  -- moment the worker's warning is written.
  committed ← newTVarIO False
  atWrite ← newIORef []
  trace ← newTrace
  gate ← newGate
  let onWrite _ = readTVarIO committed >>= \seen → modifyIORef' atWrite (<> [seen])
  (update, warnings) ← withCollectedLifetime onWrite $ \collected →
    withSupervision (collectedLifetime collected) $ \supervision → do
      worker ←
        expectStarted
          =<< startSupervised supervision (optional Service) (failingAfter trace "indexer" gate (Broken "indexer"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      update ← awaitSupervised supervision (awaitSnapshot reader start <* writeTVar committed True)
      atomically (workerStatus worker) >>= \case
        WorkerUnavailable failure → failure `shouldSatisfy` brokenIs "indexer"
        _ → expectationFailure "expected the optional worker to be settled as unavailable"
      (,) update <$> warningCount collected
  warnings `shouldBe` 1
  readIORef atWrite `shouldReturn` [False]
  updateText update `shouldBe` "value 1 at 1"
  readTVarIO committed `shouldReturn` True

testFatalPreventsWait ∷ Expectation
testFatalPreventsWait = do
  (reader, start) ← readyWait
  committed ← newTVarIO False
  trace ← newTrace
  gate ← newGate
  failure ← expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \supervision → do
      worker ←
        expectStarted
          =<< startSupervised supervision (required Service) (failingAfter trace "physics" gate (Broken "physics"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      void (awaitSupervised supervision (awaitSnapshot reader start <* writeTVar committed True))
  failure `shouldSatisfy` brokenIs "physics"
  readTVarIO committed `shouldReturn` False
  immediate reader start `shouldReturn` "value 1 at 1"
