-- | Examples for 'Hetoimasia.Foundation.Messaging.Channel'.
--
-- Waits are coordinated explicitly: a thread is known to be blocked once
-- 'awaitBlockedOnSTM' says it has parked in a transaction, and producers start
-- from a gate. No example sleeps, and none asserts an order between producers
-- that only timing could decide; 'boundedExample' only stops an example that
-- has already hung.
--
-- The examples that settle a supervised worker's outcome around a channel wait
-- exercise the runtime's supervision and are registered by the root suite's
-- @Runtime@ group, in "Test.Engine.Runtime.Messaging".
module Test.Foundation.Messaging.Channel (spec) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (STM, atomically, catchSTM, orElse, retry, throwSTM)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , throwIO
  , try
  , tryWithContext
  )
import Control.Monad (forM, forM_, replicateM, void, when)
import Data.Foldable (traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
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
import Hetoimasia.Foundation.Messaging.Channel
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)
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
import System.IO.Unsafe (unsafePerformIO)
import Test.Foundation.Messaging.Support (awaitBlockedOnSTM, boundedExample, newGate, openGate)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  describe "Channel construction" $ do
    it "rejects zero, negative, and above-maximum capacities with a typed failure and engine origin"
      testConstructionFailures

  describe "Channel admission and order" $ do
    it "receives entries in the order their admissions committed"
      testFifoOrder
    it "keeps each of several concurrent producers' entries in order"
      (boundedExample testConcurrentProducers)
    it "accepts up to capacity and then reports Full with the queue and counters unchanged"
      testFullLeavesUnchanged
    it "reports Closed rather than Full once admission has ended by close or abort"
      testClosedOverFull

  describe "Channel close and abort" $ do
    it "drains a closed channel in order and then reports the end of the stream"
      testDrainAfterClose
    it "discards only queued entries, strengthens close, and returns zero when repeated"
      testAbort
    it "wakes blocked waiting sends and receives on close and on abort with the terminal result"
      (boundedExample testTerminalWakes)
    it "releases a blocked waiting send by one dequeue and a blocked waiting receive by one admission"
      (boundedExample testProgressWakes)

  describe "Channel counters and transactions" $ do
    it "conserves accepted entries and keeps high-water monotone through contention, rollback, failed admission, drain, and abort"
      (boundedExample testConservation)
    it "never delivers an entry whose admission rolled back"
      testRollbackNeverReappears
    it "forwards a received prepared payload to another channel without evaluating it again"
      testForwarding

  describe "Channel composition" $ do
    it "leaves a blocked waiting send through a worker's stop request with the channel unchanged"
      (boundedExample testStopDuringSend)
    it "leaves a blocked waiting receive through a worker's stop request with the channel unchanged"
      (boundedExample testStopDuringReceive)

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

expectConserved ∷ ChannelStatistics → Expectation
expectConserved statistics = do
  statisticsAccepted statistics
    `shouldBe` statisticsDequeued statistics + statisticsDiscarded statistics + statisticsDepth statistics
  statisticsHighWater statistics `shouldSatisfy` (<= statisticsCapacity statistics)
  statisticsDepth statistics `shouldSatisfy` (<= statisticsHighWater statistics)

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

-- | Start producers from one gate. Each sends its own numbered entries with a
-- waiting send, and the returned action waits for all of them to finish.
produce ∷ Sender (Int, Int) → [Int] → Int → IO (IO ())
produce sender producers count = do
  start ← newGate
  finished ← forM producers $ \producer → do
    done ← newEmptyMVar
    _ ← forkIO $ do
      outcome ← try @SomeException $ do
        readMVar start
        forM_ [1 .. count] $ \sequenceNumber → do
          payload ← prepare (producer, sequenceNumber)
          admission ← atomically (awaitSend sender payload)
          when (admission /= Admitted) (throwIO (userError ("producer saw " <> show admission)))
      putMVar done outcome
    pure done
  openGate start
  pure (traverse_ (\done → takeMVar done >>= either throwIO pure) finished)

receiveTagged ∷ Receiver (Int, Int) → Int → IO [(Int, Int)]
receiveTagged receiver count =
  replicateM count $
    atomically (awaitReceive receiver) >>= \case
      Delivered payload → pure (preparedValue payload)
      Ended termination → throwIO (userError ("the channel ended early: " <> show termination))

-- Construction ---------------------------------------------------------------

testConstructionFailures ∷ Expectation
testConstructionFailures = do
  rejects 0 (CapacityNotPositive 0)
  rejects (-3) (CapacityNotPositive (-3))
  -- Above the limit is rejected by comparison, before anything is allocated.
  rejects (maximumCapacity + 1) (CapacityAboveMaximum (maximumCapacity + 1))
  -- The controls: the smallest and the largest accepted capacities.
  void (newIntChannel 1)
  largest ← newIntChannel maximumCapacity
  statisticsOf largest `shouldReturn` ChannelStatistics (fromInteger maximumCapacity) 0 0 0 0 0
  where
    rejects capacity expected = do
      outcome ← tryWithContext @ChannelCapacityRejected (newIntChannel capacity)
      case outcome of
        Right _ → expectationFailure ("expected capacity " <> show capacity <> " to be rejected")
        Left (ExceptionWithContext context failure) → do
          failure `shouldBe` expected
          let evidence = failureEvidenceInContext context
          failureContexts evidence `shouldBe` []
          case failureCause evidence of
            EngineOrigin origin → do
              originComponent origin `shouldBe` messagingComponent
              originOperation origin `shouldBe` newChannelOperation
              originIdentifiers origin `shouldBe` [("capacity", Text.pack (show capacity))]
              fmap (sourceFile . siteLocation) (originSite origin)
                `shouldSatisfy` maybe False ("Test/Foundation/Messaging/Channel.hs" `Text.isSuffixOf`)
            NativeCause → expectationFailure ("expected an engine origin, but found " <> show evidence)

-- Admission and order --------------------------------------------------------

testFifoOrder ∷ Expectation
testFifoOrder = do
  control ← newIntChannel 8
  let receiver = channelReceiver control
  -- Two producers' endpoints, admissions committed alternately.
  let first = channelSender control
      second = channelSender control
  forM_ [(first, 1), (second, 2), (first, 3), (second, 4), (first, 5)] $ \(sender, value) →
    sendAll sender [value] `shouldReturn` [Accepted]
  receiveAll receiver `shouldReturn` ["item 1", "item 2", "item 3", "item 4", "item 5", "empty"]

testConcurrentProducers ∷ Expectation
testConcurrentProducers = do
  control ← newChannel @(Int, Int) 4
  let producers = [1, 2, 3]
      count = 50
  finished ← produce (channelSender control) producers count
  received ← receiveTagged (channelReceiver control) (length producers * count)
  finished
  forM_ producers $ \producer →
    [sequenceNumber | (tag, sequenceNumber) ← received, tag == producer] `shouldBe` [1 .. count]
  statistics ← statisticsOf control
  expectConserved statistics
  (statisticsAccepted statistics, statisticsDequeued statistics, statisticsDepth statistics)
    `shouldBe` (150, 150, 0)

testFullLeavesUnchanged ∷ Expectation
testFullLeavesUnchanged = do
  control ← newIntChannel 2
  let sender = channelSender control
      receiver = channelReceiver control
  sendAll sender [1, 2] `shouldReturn` [Accepted, Accepted]
  before ← statisticsOf control
  before `shouldBe` ChannelStatistics 2 2 2 2 0 0
  kept ← prepare 3
  atomically (send sender kept) `shouldReturn` Full
  statisticsOf control `shouldReturn` before
  receiveAll receiver `shouldReturn` ["item 1", "item 2", "empty"]
  -- The refused payload is still the caller's to send again.
  atomically (send sender kept) `shouldReturn` Accepted
  receiveAll receiver `shouldReturn` ["item 3", "empty"]

testClosedOverFull ∷ Expectation
testClosedOverFull = do
  closed ← newIntChannel 1
  sendAll (channelSender closed) [1, 2] `shouldReturn` [Accepted, Full]
  atomically (closeChannel closed)
  sendAll (channelSender closed) [2] `shouldReturn` [Closed]
  payload ← prepare 2
  atomically (awaitSend (channelSender closed) payload) `shouldReturn` AdmissionClosed
  statisticsOf closed `shouldReturn` ChannelStatistics 1 1 1 1 0 0

  aborted ← newIntChannel 1
  sendAll (channelSender aborted) [1, 2] `shouldReturn` [Accepted, Full]
  atomically (abortChannel aborted) `shouldReturn` 1
  -- A sender sees the same result whether the channel was closed or aborted.
  sendAll (channelSender aborted) [2] `shouldReturn` [Closed]
  atomically (awaitSend (channelSender aborted) payload) `shouldReturn` AdmissionClosed
  statisticsOf aborted `shouldReturn` ChannelStatistics 1 0 1 1 0 1

-- Close and abort ------------------------------------------------------------

testDrainAfterClose ∷ Expectation
testDrainAfterClose = do
  control ← newIntChannel 4
  let sender = channelSender control
      receiver = channelReceiver control
  sendAll sender [1, 2, 3] `shouldReturn` [Accepted, Accepted, Accepted]
  atomically (closeChannel control)
  atomically (closeChannel control)
  sendAll sender [4] `shouldReturn` [Closed]
  receiveText receiver `shouldReturn` "item 1"
  receiveText receiver `shouldReturn` "item 2"
  deliveryText <$> atomically (awaitReceive receiver) `shouldReturn` "item 3"
  receiveText receiver `shouldReturn` "Drained"
  deliveryText <$> atomically (awaitReceive receiver) `shouldReturn` "Drained"
  statistics ← statisticsOf control
  statistics `shouldBe` ChannelStatistics 4 0 3 3 3 0
  expectConserved statistics

testAbort ∷ Expectation
testAbort = do
  control ← newIntChannel 4
  let sender = channelSender control
      receiver = channelReceiver control
  -- Aborting an empty open channel discards nothing and counts nothing.
  spare ← newIntChannel 2
  atomically (abortChannel spare) `shouldReturn` 0
  statisticsOf spare `shouldReturn` ChannelStatistics 2 0 0 0 0 0
  receiveText (channelReceiver spare) `shouldReturn` "Aborted"

  sendAll sender [1, 2, 3] `shouldReturn` [Accepted, Accepted, Accepted]
  receiveText receiver `shouldReturn` "item 1"
  atomically (closeChannel control)
  -- Abort strengthens the close and cannot recall the entry already received.
  atomically (abortChannel control) `shouldReturn` 2
  receiveText receiver `shouldReturn` "Aborted"
  afterAbort ← statisticsOf control
  afterAbort `shouldBe` ChannelStatistics 4 0 3 3 1 2
  expectConserved afterAbort
  -- Repeated, it discards nothing and changes no counter.
  atomically (abortChannel control) `shouldReturn` 0
  statisticsOf control `shouldReturn` afterAbort
  -- A later close never weakens the abort.
  atomically (closeChannel control)
  receiveText receiver `shouldReturn` "Aborted"
  deliveryText <$> atomically (awaitReceive receiver) `shouldReturn` "Aborted"
  sendAll sender [4] `shouldReturn` [Closed]
  statisticsOf control `shouldReturn` afterAbort

testTerminalWakes ∷ Expectation
testTerminalWakes = do
  sendWokenBy "close" (closeChannel) >>= (`shouldBe` (AdmissionClosed, ChannelStatistics 1 1 1 1 0 0))
  sendWokenBy "abort" (void . abortChannel) >>= (`shouldBe` (AdmissionClosed, ChannelStatistics 1 0 1 1 0 1))
  receiveWokenBy (closeChannel) >>= (`shouldBe` ("Drained", ChannelStatistics 1 0 0 0 0 0))
  receiveWokenBy (void . abortChannel) >>= (`shouldBe` ("Aborted", ChannelStatistics 1 0 0 0 0 0))
  where
    sendWokenBy ∷ String → (ChannelControl Int → STM ()) → IO (Admission, ChannelStatistics)
    sendWokenBy _ wake = do
      control ← newIntChannel 1
      sendAll (channelSender control) [1] `shouldReturn` [Accepted]
      payload ← prepare 2
      (admission, ()) ← blockedUntil (awaitSend (channelSender control) payload) (wake control)
      (,) admission <$> statisticsOf control
    receiveWokenBy ∷ (ChannelControl Int → STM ()) → IO (String, ChannelStatistics)
    receiveWokenBy wake = do
      control ← newIntChannel 1
      (delivery, ()) ← blockedUntil (awaitReceive (channelReceiver control)) (wake control)
      (,) (deliveryText delivery) <$> statisticsOf control

testProgressWakes ∷ Expectation
testProgressWakes = do
  full ← newIntChannel 1
  sendAll (channelSender full) [1] `shouldReturn` [Accepted]
  second ← prepare 2
  (admission, receipt) ←
    blockedUntil (awaitSend (channelSender full) second) (receive (channelReceiver full))
  admission `shouldBe` Admitted
  receiptText receipt `shouldBe` "item 1"
  statisticsOf full `shouldReturn` ChannelStatistics 1 1 1 2 1 0
  receiveAll (channelReceiver full) `shouldReturn` ["item 2", "empty"]

  empty ← newIntChannel 1
  seven ← prepare 7
  (delivery, result) ←
    blockedUntil (awaitReceive (channelReceiver empty)) (send (channelSender empty) seven)
  result `shouldBe` Accepted
  deliveryText delivery `shouldBe` "item 7"
  statisticsOf empty `shouldReturn` ChannelStatistics 1 0 1 1 1 0
  receiveText (channelReceiver empty) `shouldReturn` "empty"

-- Counters and transactions --------------------------------------------------

testConservation ∷ Expectation
testConservation = do
  control ← newIntChannel 3
  previousHighWater ← newIORef 0
  let sender = channelSender control
      receiver = channelReceiver control
      checkpoint = do
        statistics ← statisticsOf control
        expectConserved statistics
        previous ← readIORef previousHighWater
        statisticsHighWater statistics `shouldSatisfy` (>= previous)
        writeIORef previousHighWater (statisticsHighWater statistics)
        pure statistics

  -- Rollback: neither a retried branch nor a thrown transaction counts.
  payload ← prepare 0
  atomically ((send sender payload >> retry) `orElse` pure Full) `shouldReturn` Full
  void (try @Boom (atomically (send sender payload >> throwSTM Boom)))
  checkpoint `shouldReturn` ChannelStatistics 3 0 0 0 0 0

  -- Contention: two producers against one consumer at a small capacity.
  tagged ← newChannel @(Int, Int) 3
  finished ← produce (channelSender tagged) [1, 2] 10
  _ ← receiveTagged (channelReceiver tagged) 20
  finished
  contended ← statisticsOf tagged
  expectConserved contended
  (statisticsAccepted contended, statisticsDequeued contended, statisticsDepth contended)
    `shouldBe` (20, 20, 0)

  -- Failed admission.
  sendAll sender [1, 2, 3, 4] `shouldReturn` [Accepted, Accepted, Accepted, Full]
  checkpoint `shouldReturn` ChannelStatistics 3 3 3 3 0 0

  -- Drain, before and after close.
  receiveText receiver `shouldReturn` "item 1"
  checkpoint `shouldReturn` ChannelStatistics 3 2 3 3 1 0
  atomically (closeChannel control)
  sendAll sender [5] `shouldReturn` [Closed]
  receiveText receiver `shouldReturn` "item 2"
  checkpoint `shouldReturn` ChannelStatistics 3 1 3 3 2 0

  -- Abort.
  atomically (abortChannel control) `shouldReturn` 1
  checkpoint `shouldReturn` ChannelStatistics 3 0 3 3 2 1

testRollbackNeverReappears ∷ Expectation
testRollbackNeverReappears = do
  control ← newIntChannel 4
  let sender = channelSender control
  rolledBack ← prepare 1
  atomically ((send sender rolledBack >> retry) `orElse` pure Full) `shouldReturn` Full
  thrown ← try @Boom (atomically (send sender rolledBack >> (throwSTM Boom ∷ STM ())))
  thrown `shouldBe` Left Boom
  atomically (catchSTM (send sender rolledBack >> throwSTM Boom) (\Boom → pure Full)) `shouldReturn` Full
  statisticsOf control `shouldReturn` ChannelStatistics 4 0 0 0 0 0
  sendAll sender [2] `shouldReturn` [Accepted]
  atomically (closeChannel control)
  receiveAll (channelReceiver control) `shouldReturn` ["item 2", "Drained"]
  statisticsOf control `shouldReturn` ChannelStatistics 4 0 1 1 1 0

testForwarding ∷ Expectation
testForwarding = do
  evaluations ← newIORef 0
  first ← newChannel @Counted 1
  second ← newChannel @Counted 1
  prepared ← prepare (Counted evaluations ["left", "right"])
  readIORef evaluations `shouldReturn` 1
  atomically (send (channelSender first) prepared) `shouldReturn` Accepted
  relayed ← expectReceived =<< atomically (receive (channelReceiver first))
  atomically (send (channelSender second) relayed) `shouldReturn` Accepted
  arrived ← expectReceived =<< atomically (receive (channelReceiver second))
  let Counted arrivedRef arrivedNames = preparedValue arrived
  (arrivedRef == evaluations) `shouldBe` True
  arrivedNames `shouldBe` ["left", "right"]
  readIORef evaluations `shouldReturn` 1
  -- The control: preparing again does run the instance, so the counter would
  -- have seen an evaluation by either channel.
  void (prepare (preparedValue arrived))
  readIORef evaluations `shouldReturn` 2
  where
    expectReceived ∷ Receipt Counted → IO (Prepared Counted)
    expectReceived = \case
      Received payload → pure payload
      _ → throwIO (userError "expected an entry")

-- Composition ----------------------------------------------------------------

-- | Run one worker whose run action waits on a channel operation or its stop
-- request, stop it once it has parked, and return which branch it left by.
leftByStop ∷ (Either () r → String) → STM r → IO String
leftByStop describeExit waiting = withWorkerGroup $ \group → do
  parked ← newEmptyMVar
  let definition =
        workerDefinition "channel-waiter" (\_ → pure ()) $ \token () → do
          myThreadId >>= putMVar parked
          atomically ((Right <$> waiting) `orElse` (Left <$> awaitStopRequest token))
  startWorker group definition >>= \case
    Started worker → do
      takeMVar parked >>= awaitBlockedOnSTM
      atomically (requestStop worker)
      completion ← atomically (awaitCompletion worker)
      case completionResult completion of
        Succeeded exit → pure (describeExit exit)
        _ → throwIO (userError "the waiting worker did not return")
    _ → throwIO (userError "the waiting worker did not start")

testStopDuringSend ∷ Expectation
testStopDuringSend = do
  control ← newIntChannel 1
  sendAll (channelSender control) [1] `shouldReturn` [Accepted]
  payload ← prepare 2
  exit ← leftByStop (either (const "stopped") show) (awaitSend (channelSender control) payload)
  exit `shouldBe` "stopped"
  statisticsOf control `shouldReturn` ChannelStatistics 1 1 1 1 0 0
  receiveAll (channelReceiver control) `shouldReturn` ["item 1", "empty"]

testStopDuringReceive ∷ Expectation
testStopDuringReceive = do
  control ← newIntChannel 1
  exit ← leftByStop (either (const "stopped") deliveryText) (awaitReceive (channelReceiver control))
  exit `shouldBe` "stopped"
  statisticsOf control `shouldReturn` ChannelStatistics 1 0 0 0 0 0
  receiveText (channelReceiver control) `shouldReturn` "empty"
