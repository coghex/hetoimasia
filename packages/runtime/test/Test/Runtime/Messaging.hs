-- | Examples for supervised waits on the foundation's messaging primitives.
--
-- Each example runs the real 'withSupervision' and 'awaitSupervised' with the
-- fixtures of "Test.Runtime.Supervision.Support", around a channel or
-- snapshot wait, and asserts that a worker outcome already published is settled
-- before the wait commits. Worker outcomes are read raw with 'awaitTerminal'
-- before the supervised wait is entered; no example sleeps, and
-- 'boundedSupervision' only stops an example that has already hung.
--
-- The primitive channel and snapshot contracts these examples sit beside are
-- owned by the foundation package's own suite.
module Test.Runtime.Messaging (spec) where

import Control.Concurrent.STM (STM, atomically, newTVarIO, orElse, readTVarIO, writeTVar)
import Control.Exception (ExceptionWithContext, SomeException)
import Control.Monad (void)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Hetoimasia.Foundation.Messaging.Channel
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
import Hetoimasia.Runtime.Supervision
  ( Role (..)
  , WorkerStatus (..)
  , awaitSupervised
  , startSupervised
  , supervisedWorker
  , withSupervision
  , workerStatus
  )
import Test.Runtime.Supervision.Support
  ( Broken (..)
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
  describe "Channel composition" $ do
    it "settles a nonfatal worker outcome before a ready supervised receive, then receives the entry once"
      (boundedSupervision testNonfatalBeforeReceive)
    it "settles a nonfatal worker outcome before a newly possible supervised send, then admits it once"
      (boundedSupervision testNonfatalBeforeSend)
    it "never commits a ready supervised receive while a fatal worker failure is pending"
      (boundedSupervision testFatalPreventsReceive)
    it "never commits a possible supervised send while a fatal worker failure is pending"
      (boundedSupervision testFatalPreventsSend)

  describe "Snapshot composition" $ do
    it "settles a nonfatal worker outcome before a ready supervised waiting read commits"
      (boundedSupervision testNonfatalBeforeWait)
    it "never commits a ready supervised waiting read while a fatal worker failure is pending"
      (boundedSupervision testFatalPreventsWait)

-- Fixtures -------------------------------------------------------------------

newIntChannel ∷ Integer → IO (ChannelControl Int)
newIntChannel = newChannel

sendAll ∷ Sender Int → [Int] → IO [SendResult]
sendAll sender = traverse (\value → prepare value >>= atomically . send sender)

receiptText ∷ Receipt Int → String
receiptText = \case
  Received payload → "item " <> show (preparedValue payload)
  Empty → "empty"
  Terminated termination → show termination

deliveryText ∷ Delivery Int → String
deliveryText = \case
  Delivered payload → "item " <> show (preparedValue payload)
  Ended termination → show termination

receiveText ∷ Receiver Int → IO String
receiveText = fmap receiptText . atomically . receive

-- | Receive until the channel reports something other than an entry, keeping
-- that final report.
receiveAll ∷ Receiver Int → IO [String]
receiveAll receiver =
  atomically (receive receiver) >>= \case
    Received payload → (("item " <> show (preparedValue payload)) :) <$> receiveAll receiver
    other → pure [receiptText other]

statisticsOf ∷ ChannelControl a → IO ChannelStatistics
statisticsOf = atomically . channelStatistics

newIntSnapshot ∷ Int → IO (SnapshotPublisher Int)
newIntSnapshot initial = prepare initial >>= newSnapshot

publishInt ∷ SnapshotPublisher Int → Int → IO Publication
publishInt publisher value = prepare value >>= atomically . publish publisher

updateText ∷ Update Int → String
updateText = \case
  Updated observation →
    let value = preparedValue (observedValue observation)
        revision = toInteger (cursorRevision (observedCursor observation))
     in "value " <> show value <> " at " <> show revision
  EndOfStream → "end"

-- | A waiting read that must not wait: it reports "retried" if it would have.
immediate ∷ SnapshotReader Int → SnapshotCursor Int → IO String
immediate reader cursor = atomically ((updateText <$> awaitSnapshot reader cursor) `orElse` pure "retried")

ignoreWrites ∷ a → IO ()
ignoreWrites _ = pure ()

-- Channel composition --------------------------------------------------------

-- | Run a supervised wait while an optional worker's failure is already
-- published, recording the channel's statistics each time an entry is written,
-- which is when the worker's warning is attempted.
nonfatalAround ∷ ChannelControl Int → STM r → IO (r, [ChannelStatistics], Int)
nonfatalAround control waiting = do
  trace ← newTrace
  gate ← newGate
  atWrite ← newIORef []
  let onWrite _ = do
        statistics ← statisticsOf control
        modifyIORef' atWrite (<> [statistics])
  withCollectedLifetime onWrite $ \collected →
    withSupervision (collectedLifetime collected) $ \supervision → do
      worker ←
        expectStarted
          =<< startSupervised supervision (optional Service) (failingAfter trace "indexer" gate (Broken "indexer"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      result ← awaitSupervised supervision waiting
      atomically (workerStatus worker) >>= \case
        WorkerUnavailable failure → failure `shouldSatisfy` brokenIs "indexer"
        _ → expectationFailure "expected the optional worker to be settled as unavailable"
      warnings ← warningCount collected
      snapshots ← readIORef atWrite
      pure (result, snapshots, warnings)

testNonfatalBeforeReceive ∷ Expectation
testNonfatalBeforeReceive = do
  control ← newIntChannel 2
  sendAll (channelSender control) [1] `shouldReturn` [Accepted]
  (delivery, snapshots, warnings) ← nonfatalAround control (awaitReceive (channelReceiver control))
  warnings `shouldBe` 1
  -- When the outcome was reported, the entry was still queued.
  snapshots `shouldBe` [ChannelStatistics 2 1 1 1 0 0]
  deliveryText delivery `shouldBe` "item 1"
  statisticsOf control `shouldReturn` ChannelStatistics 2 0 1 1 1 0
  receiveText (channelReceiver control) `shouldReturn` "empty"

testNonfatalBeforeSend ∷ Expectation
testNonfatalBeforeSend = do
  control ← newIntChannel 1
  sendAll (channelSender control) [1] `shouldReturn` [Accepted]
  receiveText (channelReceiver control) `shouldReturn` "item 1"
  payload ← prepare 2
  (admission, snapshots, warnings) ← nonfatalAround control (awaitSend (channelSender control) payload)
  warnings `shouldBe` 1
  -- When the outcome was reported, the send had not been admitted.
  snapshots `shouldBe` [ChannelStatistics 1 0 1 1 1 0]
  admission `shouldBe` Admitted
  statisticsOf control `shouldReturn` ChannelStatistics 1 1 1 2 1 0
  receiveAll (channelReceiver control) `shouldReturn` ["item 2", "empty"]

-- | Run a supervised wait while a required worker's failure is already
-- published, and return what the boundary propagated.
fatalAround ∷ STM r → IO (ExceptionWithContext SomeException)
fatalAround waiting = do
  trace ← newTrace
  gate ← newGate
  expectFailure $ withCollectedLifetime ignoreWrites $ \collected →
    withSupervision (collectedLifetime collected) $ \supervision → do
      worker ←
        expectStarted
          =<< startSupervised supervision (required Service) (failingAfter trace "physics" gate (Broken "physics"))
      openGate gate
      _ ← awaitTerminal (supervisedWorker worker)
      void (awaitSupervised supervision waiting)

testFatalPreventsReceive ∷ Expectation
testFatalPreventsReceive = do
  control ← newIntChannel 2
  sendAll (channelSender control) [1] `shouldReturn` [Accepted]
  failure ← fatalAround (awaitReceive (channelReceiver control))
  failure `shouldSatisfy` brokenIs "physics"
  statisticsOf control `shouldReturn` ChannelStatistics 2 1 1 1 0 0
  receiveAll (channelReceiver control) `shouldReturn` ["item 1", "empty"]

testFatalPreventsSend ∷ Expectation
testFatalPreventsSend = do
  control ← newIntChannel 2
  sendAll (channelSender control) [1] `shouldReturn` [Accepted]
  payload ← prepare 2
  failure ← fatalAround (awaitSend (channelSender control) payload)
  failure `shouldSatisfy` brokenIs "physics"
  statisticsOf control `shouldReturn` ChannelStatistics 2 1 1 1 0 0
  receiveAll (channelReceiver control) `shouldReturn` ["item 1", "empty"]

-- Snapshot composition -------------------------------------------------------

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
