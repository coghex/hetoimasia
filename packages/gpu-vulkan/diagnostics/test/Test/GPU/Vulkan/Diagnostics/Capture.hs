-- | The C capture storage, driven directly through the package-local producer
-- entry: the callback data is built on a C frame and handed to the production
-- producer, and records come back out through the storage's one consumer.
--
-- Nothing here runs a worker, so what these examples read is the storage's
-- own state: what it admitted, copied, cut, dropped, latched and counted.
module Test.GPU.Vulkan.Diagnostics.Capture (spec) where

import Control.Concurrent (forkIO, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (bracket, finally)
import Control.Monad (forM, forM_, replicateM_, when)
import qualified Data.ByteString.Char8 as Char8
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)
import Foreign.Ptr (nullPtr)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Capture
  ( CapturedLabels (..)
  , CapturedObject (..)
  , CapturedRecord (..)
  , Counter (..)
  , Latch (..)
  , LimitError (..)
  , Limits (..)
  , Offer (..)
  , Severity (..)
  , Storage
  , closeStorage
  , counterValue
  , checkLimits
  , createStorage
  , recordFootprint
  , storageClosed
  , freeStorage
  , latchSet
  , offer
  , offerMissingData
  , plainOffer
  , newHold
  , offerAnnounced
  , offerHeld
  , slotStatus
  , holdArrived
  , releaseHold
  , presetCounter
  , storageUserData
  , takeRecord
  )
import Test.Support.Bounded (bounded)

-- | A storage for one example, closed and freed afterwards.
withStorage ∷ Limits → (Storage → IO a) → IO a
withStorage bounds = bracket (createStorage bounds) freeStorage

limits ∷ Int → Int → Int → Limits
limits capacity budget objects = labelled capacity budget objects 2

labelled ∷ Int → Int → Int → Int → Limits
labelled capacity budget objects labels =
  Limits {limitQueueCapacity = capacity, limitTextBudget = budget, limitObjectLimit = objects, limitLabelLimit = labels}

noLabels ∷ CapturedLabels
noLabels = CapturedLabels {labelsReported = 0, labelNames = []}

offerInto ∷ Storage → Offer → IO ()
offerInto storage = offer (storageUserData storage)

drainAll ∷ Storage → IO [CapturedRecord]
drainAll storage =
  takeRecord storage >>= \case
    Nothing → pure []
    Just record → (record :) <$> drainAll storage

counters ∷ Storage → IO [(Counter, Word64)]
counters storage = forM [minBound .. maxBound] $ \counter → (,) counter <$> counterValue storage counter

spec ∷ Spec
spec = describe "Capture" $ do
  describe "labels" $ do
    it "copies both label arrays apart, in the callback's order, with what each reported" $
      withStorage (labelled 4 64 2 3) $ \storage → do
        offerInto
          storage
          (plainOffer SeverityError "inside a batch")
            { offerQueueLabels = Just [Just "submit 1"]
            , offerCommandBufferLabels = Just [Just "batch 3", Just "pass 3", Nothing]
            }
        [record] ← drainAll storage
        recordQueueLabels record `shouldBe` CapturedLabels {labelsReported = 1, labelNames = [Just "submit 1"]}
        recordCommandBufferLabels record
          `shouldBe` CapturedLabels {labelsReported = 3, labelNames = [Just "batch 3", Just "pass 3", Nothing]}
        recordTruncated record `shouldBe` False
        counterValue storage Truncated `shouldReturn` 0

    it "copies at most the label limit from each array, and counts the record truncated once" $
      withStorage (labelled 4 64 2 2) $ \storage → do
        offerInto
          storage
          (plainOffer SeverityInfo "labels")
            { offerQueueLabels = Just [Just "q1", Just "q2", Just "q3"]
            , offerCommandBufferLabels = Just [Just "c1", Just "c2", Just "c3", Just "c4"]
            }
        [record] ← drainAll storage
        recordQueueLabels record `shouldBe` CapturedLabels {labelsReported = 3, labelNames = [Just "q1", Just "q2"]}
        recordCommandBufferLabels record `shouldBe` CapturedLabels {labelsReported = 4, labelNames = [Just "c1", Just "c2"]}
        recordTruncated record `shouldBe` True
        counterValue storage Truncated `shouldReturn` 1

    it "copies exactly the label limit without truncating" $
      withStorage (labelled 4 64 2 2) $ \storage → do
        offerInto storage (plainOffer SeverityInfo "labels") {offerCommandBufferLabels = Just [Just "c1", Just "c2"]}
        [record] ← drainAll storage
        labelNames (recordCommandBufferLabels record) `shouldBe` [Just "c1", Just "c2"]
        recordTruncated record `shouldBe` False

    it "treats a positive label count with no array as truncation, copying none" $
      withStorage (labelled 4 64 2 2) $ \storage → do
        offerInto
          storage
          (plainOffer SeverityInfo "missing")
            { offerQueueLabels = Nothing
            , offerQueueLabelCount = Just 2
            , offerCommandBufferLabels = Nothing
            , offerCommandBufferLabelCount = Just 1
            }
        [record] ← drainAll storage
        recordQueueLabels record `shouldBe` CapturedLabels {labelsReported = 2, labelNames = []}
        recordCommandBufferLabels record `shouldBe` CapturedLabels {labelsReported = 1, labelNames = []}
        recordTruncated record `shouldBe` True
        counterValue storage Truncated `shouldReturn` 1

    it "takes a zero label count with no array as no labels, and nothing cut" $
      withStorage (labelled 4 64 2 2) $ \storage → do
        offerInto storage (plainOffer SeverityInfo "none") {offerQueueLabels = Nothing, offerCommandBufferLabels = Nothing}
        [record] ← drainAll storage
        recordQueueLabels record `shouldBe` noLabels
        recordCommandBufferLabels record `shouldBe` noLabels
        recordTruncated record `shouldBe` False

    it "shares the text budget in order: id name, message, objects, queue labels, command-buffer labels" $
      withStorage (labelled 4 16 2 2) $ \storage → do
        -- 2 + 3 + 3 bytes leave 8: the queue label takes 4, the first
        -- command-buffer label the last 4 of its 5, and the second none.
        offerInto
          storage
          (plainOffer SeverityInfo "msg")
            { offerIdName = Just "id"
            , offerObjects = Just [(1, 1, Just "obj")]
            , offerQueueLabels = Just [Just "qqqq"]
            , offerCommandBufferLabels = Just [Just "ccccc", Just "dd"]
            }
        [record] ← drainAll storage
        recordIdName record `shouldBe` Just "id"
        recordMessage record `shouldBe` "msg"
        map objectName (recordObjects record) `shouldBe` [Just "obj"]
        labelNames (recordQueueLabels record) `shouldBe` [Just "qqqq"]
        labelNames (recordCommandBufferLabels record) `shouldBe` [Just "cccc", Just ""]
        recordTruncated record `shouldBe` True
        counterValue storage Truncated `shouldReturn` 1

    it "counts a record whose objects and labels were both cut as one truncation" $
      withStorage (labelled 4 64 1 1) $ \storage → do
        offerInto
          storage
          (plainOffer SeverityInfo "both")
            { offerObjects = Just [(1, 1, Nothing), (2, 2, Nothing)]
            , offerCommandBufferLabels = Just [Just "a", Just "b"]
            }
        [_] ← drainAll storage
        counterValue storage Truncated `shouldReturn` 1

    it "leaves one record's labels out of the next record that reuses its space" $
      withStorage (labelled 1 64 2 2) $ \storage → do
        offerInto storage (plainOffer SeverityInfo "first") {offerCommandBufferLabels = Just [Just "batch 1", Just "pass 1"]}
        [first] ← drainAll storage
        labelNames (recordCommandBufferLabels first) `shouldBe` [Just "batch 1", Just "pass 1"]
        offerInto storage (plainOffer SeverityInfo "second")
        [second] ← drainAll storage
        recordCommandBufferLabels second `shouldBe` noLabels

    it "rejects a label limit that is not positive or that the storage cannot count" $ do
      checkLimits (labelled 1 1 1 0) `shouldBe` Left (LabelLimitRejected 0)
      let beyond = fromIntegral (maxBound ∷ Word32) + 1
      checkLimits (labelled 1 1 1 beyond) `shouldBe` Left (LabelLimitRejected beyond)

    it "includes both label arrays' records in the allocation it checks" $ do
      let footprint = recordFootprint . labelled 1 1 1
      (footprint 3 - footprint 1) `shouldSatisfy` (> 0)
      -- Two arrays of labels per record: two more labels cost exactly twice
      -- what one more does.
      (footprint 3 - footprint 1) `shouldBe` 2 * (footprint 2 - footprint 1)

  describe "bounded copying" $ do
    it "copies every field of a record that fits, and marks nothing truncated" $
      withStorage (limits 4 64 2) $ \storage → do
        offerInto
          storage
          (plainOffer SeverityWarning "a message")
            { offerIdName = Just "VUID-example"
            , offerIdNumber = 42
            , offerTypes = 0x6
            , offerObjects = Just [(10, 0xdeadbeef, Just "buffer"), (11, 7, Nothing)]
            }
        [record] ← drainAll storage
        record
          `shouldBe` CapturedRecord
            { recordSeverity = SeverityWarning
            , recordTypes = 0x6
            , recordIdNumber = 42
            , recordIdName = Just "VUID-example"
            , recordMessage = "a message"
            , recordTruncated = False
            , recordObjectsReported = 2
            , recordObjects =
                [ CapturedObject {objectType = 10, objectHandle = 0xdeadbeef, objectName = Just "buffer"}
                , CapturedObject {objectType = 11, objectHandle = 7, objectName = Nothing}
                ]
            , recordQueueLabels = noLabels
            , recordCommandBufferLabels = noLabels
            }
        counterValue storage Truncated `shouldReturn` 0

    it "fills the text budget exactly without truncating" $
      withStorage (limits 4 16 2) $ \storage → do
        offerInto storage (plainOffer SeverityInfo "0123456789abcdef")
        [record] ← drainAll storage
        recordMessage record `shouldBe` "0123456789abcdef"
        recordTruncated record `shouldBe` False
        counterValue storage Truncated `shouldReturn` 0

    it "cuts a message one byte over the budget, and counts the record once" $
      withStorage (limits 4 16 2) $ \storage → do
        offerInto storage (plainOffer SeverityInfo "0123456789abcdefX")
        [record] ← drainAll storage
        recordMessage record `shouldBe` "0123456789abcdef"
        recordTruncated record `shouldBe` True
        counterValue storage Truncated `shouldReturn` 1

    it "shares one budget between the message id name, the message and the object names" $
      withStorage (limits 4 16 4) $ \storage → do
        -- 6 bytes of id name and 6 of message leave 4 for the names: the first
        -- takes 3, the second the last 1, and the third none.
        offerInto
          storage
          (plainOffer SeverityInfo "second")
            { offerIdName = Just "first-"
            , offerObjects = Just [(1, 1, Just "abc"), (2, 2, Just "defg"), (3, 3, Just "hij")]
            }
        [record] ← drainAll storage
        recordIdName record `shouldBe` Just "first-"
        recordMessage record `shouldBe` "second"
        map objectName (recordObjects record) `shouldBe` [Just "abc", Just "d", Just ""]
        recordTruncated record `shouldBe` True

    it "copies at most the object limit, and records how many the callback carried" $
      withStorage (limits 4 64 2) $ \storage → do
        offerInto
          storage
          (plainOffer SeverityInfo "objects")
            {offerObjects = Just [(fromIntegral n, n, Nothing) | n ← [1 .. 5]]}
        [record] ← drainAll storage
        map objectHandle (recordObjects record) `shouldBe` [1, 2]
        recordObjectsReported record `shouldBe` 5
        recordTruncated record `shouldBe` True
        counterValue storage Truncated `shouldReturn` 1

    it "copies exactly the object limit without truncating" $
      withStorage (limits 4 64 2) $ \storage → do
        offerInto storage (plainOffer SeverityInfo "objects") {offerObjects = Just [(1, 1, Nothing), (2, 2, Nothing)]}
        [record] ← drainAll storage
        length (recordObjects record) `shouldBe` 2
        recordTruncated record `shouldBe` False

    it "treats an object count with no array as content it could not copy" $
      withStorage (limits 4 64 2) $ \storage → do
        offerInto storage (plainOffer SeverityInfo "no array") {offerObjects = Nothing, offerObjectCount = Just 3}
        [record] ← drainAll storage
        recordObjects record `shouldBe` []
        recordObjectsReported record `shouldBe` 3
        recordTruncated record `shouldBe` True

    it "admits a record with no message and no id name" $
      withStorage (limits 4 64 2) $ \storage → do
        offerInto storage (plainOffer SeverityVerbose "") {offerMessage = Nothing}
        [record] ← drainAll storage
        recordMessage record `shouldBe` ""
        recordIdName record `shouldBe` Nothing

  describe "severity and the error latch" $ do
    it "classifies the most severe bit present" $
      withStorage (limits 8 64 2) $ \storage → do
        for_ [0x1, 0x10, 0x100, 0x1000, 0x1100, 0x0] $ \bits →
          offerInto storage (plainOffer SeverityInfo "classified") {offerSeverity = bits}
        map recordSeverity
          <$> drainAll storage
          `shouldReturn` [ SeverityVerbose
                         , SeverityInfo
                         , SeverityWarning
                         , SeverityError
                         , SeverityError
                         , SeverityUnclassified 0
                         ]

    it "latches nothing for warnings" $
      withStorage (limits 4 64 2) $ \storage → do
        offerInto storage (plainOffer SeverityWarning "a warning")
        latchSet storage ErrorLatch `shouldReturn` False

    it "latches an error that a full queue drops" $
      withStorage (limits 2 64 2) $ \storage → do
        replicateM_ 2 (offerInto storage (plainOffer SeverityInfo "filler"))
        offerInto storage (plainOffer SeverityError "the error that did not fit")
        latchSet storage ErrorLatch `shouldReturn` True
        counterValue storage Errors `shouldReturn` 1
        counterValue storage Dropped `shouldReturn` 1
        map recordMessage <$> drainAll storage `shouldReturn` ["filler", "filler"]

    it "keeps the latch after the error's record is consumed and the queue refills" $
      withStorage (limits 2 64 2) $ \storage → do
        offerInto storage (plainOffer SeverityError "an error")
        _ ← drainAll storage
        replicateM_ 3 (offerInto storage (plainOffer SeverityInfo "later"))
        _ ← drainAll storage
        latchSet storage ErrorLatch `shouldReturn` True

  describe "saturation" $ do
    it "drops what does not fit, counts it, and admits again once there is room" $
      withStorage (limits 3 64 2) $ \storage → do
        forM_ [1 .. 5 ∷ Int] $ \n → offerInto storage (plainOffer SeverityInfo (Char8.pack (show n)))
        map recordMessage <$> drainAll storage `shouldReturn` ["1", "2", "3"]
        offerInto storage (plainOffer SeverityInfo "6")
        map recordMessage <$> drainAll storage `shouldReturn` ["6"]
        Map.fromList
          <$> counters storage
          `shouldReturn` Map.fromList
            [(Offered, 6), (Admitted, 4), (Dropped, 2), (Truncated, 0), (CaptureFailed, 0), (Errors, 0)]

    it "drops rather than overwrites when a one-record queue is full" $
      withStorage (limits 1 64 2) $ \storage → do
        offerInto storage (plainOffer SeverityInfo "kept")
        offerInto storage (plainOffer SeverityInfo "dropped")
        map recordMessage <$> drainAll storage `shouldReturn` ["kept"]
        offerInto storage (plainOffer SeverityInfo "next")
        map recordMessage <$> drainAll storage `shouldReturn` ["next"]
        counterValue storage Dropped `shouldReturn` 1

    it "saturates each counter at its ceiling instead of wrapping" $
      withStorage (limits 1 64 2) $ \storage → do
        for_ [minBound .. maxBound] $ \counter → presetCounter storage counter (maxBound - 1)
        -- One admitted error and one dropped error reach every ceiling but
        -- the truncation and failure counters, which take a cut record and a
        -- missing payload.
        offerInto storage (plainOffer SeverityError "0123456789") {offerObjects = Nothing, offerObjectCount = Just 1}
        replicateM_ 2 (offerInto storage (plainOffer SeverityError "dropped"))
        replicateM_ 2 (offerMissingData (storageUserData storage) (plainOffer SeverityInfo "missing"))
        map snd <$> counters storage `shouldReturn` replicate 6 maxBound

  describe "producer failures" $ do
    it "contains missing callback data, latches capture failure, and keeps admitting" $
      withStorage (limits 4 64 2) $ \storage → do
        offerMissingData (storageUserData storage) (plainOffer SeverityInfo "unseen")
        offerInto storage (plainOffer SeverityInfo "after")
        latchSet storage CaptureFailureLatch `shouldReturn` True
        counterValue storage CaptureFailed `shouldReturn` 1
        map recordMessage <$> drainAll storage `shouldReturn` ["after"]

    it "still latches an error whose callback data is missing" $
      withStorage (limits 4 64 2) $ \storage → do
        offerMissingData (storageUserData storage) (plainOffer SeverityError "unseen")
        latchSet storage ErrorLatch `shouldReturn` True

    it "ignores a report with no user data, answering normally" $
      -- There is no storage to latch anything in; the example is that the call
      -- returns rather than touching memory it was not given.
      offer nullPtr (plainOffer SeverityError "nowhere") `shouldReturn` ()

    it "counts a report that begins only after close and free as a capture failure, in memory that is still live" $ do
      -- A report not yet begun when the storage closes: closing cannot see
      -- it, and the storage is freed while it waits. What it touches first is
      -- the storage's static slot, which is never freed, and it finds
      -- admission closed there.
      storage ← createStorage (limits 4 64 2)
      hold ← newHold
      done ← newEmptyMVar
      _ ← forkIO (offerHeld (storageUserData storage) hold SeverityError "held" >> putMVar done ())
      bounded (untilM (holdArrived hold))
      closeStorage storage
      freeStorage storage
      releaseHold hold
      bounded (takeMVar done)
      counterValue storage CaptureFailed `shouldReturn` 1
      counterValue storage Admitted `shouldReturn` 0
      latchSet storage CaptureFailureLatch `shouldReturn` True
      latchSet storage ErrorLatch `shouldReturn` True

    it "makes closing wait for a producer that has announced itself" $
      withStorage (limits 4 64 2) $ \storage → do
        hold ← newHold
        producerDone ← newEmptyMVar
        closed ← newEmptyMVar
        _ ← forkIO (offerAnnounced (storageUserData storage) hold SeverityWarning "announced" >> putMVar producerDone ())
        bounded (untilM (holdArrived hold))
        _ ← forkIO (closeStorage storage >> putMVar closed ())
        -- Once the closer has set the flag it is waiting for the producer.
        bounded (untilM (storageClosed storage))
        tryTakeMVar closed `shouldReturn` Nothing
        releaseHold hold
        bounded (takeMVar producerDone)
        bounded (takeMVar closed)
        -- Admission closed while it waited, so it counted itself as refused.
        counterValue storage CaptureFailed `shouldReturn` 1
        counterValue storage Admitted `shouldReturn` 0

    it "reclaims every storage, so more lifetimes than the table has slots never run out" $
      forM_ [1 .. 3 * 64 ∷ Int] $ \_ → do
        storage ← createStorage (limits 1 16 1)
        offerInto storage (plainOffer SeverityInfo "one")
        freeStorage storage

    it "names nothing through a stale user data once its slot serves another storage" $ do
      first ← createStorage (limits 1 16 1)
      let stale = storageUserData first
      freeStorage first
      -- Claim slots until the first one is reused.
      let claim acquired = do
            storage ← createStorage (limits 1 16 1)
            reused ← (== Nothing) <$> slotStatus stale
            if reused || length acquired >= 64
              then pure (storage : acquired)
              else claim (storage : acquired)
      reclaimed ← claim []
      ( do
          slotStatus stale `shouldReturn` Nothing
          offer stale (plainOffer SeverityError "stale")
          mapM_ (\storage → counterValue storage Offered `shouldReturn` 0) reclaimed
        )
        `finally` mapM_ freeStorage reclaimed

    it "refuses a record offered after closing, as a capture failure" $
      withStorage (limits 4 64 2) $ \storage → do
        closeStorage storage
        offerInto storage (plainOffer SeverityWarning "too late")
        counterValue storage CaptureFailed `shouldReturn` 1
        latchSet storage CaptureFailureLatch `shouldReturn` True
        drainAll storage `shouldReturn` []

  describe "concurrent producers" $
    it "admits or drops every record from several threads, intact and in each thread's order" $
      withStorage (limits 64 64 2) $ \storage → do
        let producers = 8 ∷ Int
            each = 2000 ∷ Int
        finished ← newTVarIO (0 ∷ Int)
        forM_ [1 .. producers] $ \producer →
          forkIO $ do
            forM_ [1 .. each] $ \n →
              offerInto storage (plainOffer SeverityInfo (Char8.pack (show producer <> ":" <> show n)))
            atomically (modifyTVar' finished (+ 1))
        -- The consumer runs beside the producers, so the queue is both full
        -- and refilling while they race for positions. Every producer
        -- publishes before it says it has finished, so the pass that follows
        -- reading all of them finished sees the last record there will be.
        --
        -- An empty pass yields: a loop of short unsafe calls that allocates
        -- nothing never reaches a point where the runtime can stop it, and the
        -- other capabilities would then wait for it forever at the next
        -- collection.
        let consume collected = do
              done ← (== producers) <$> readTVarIO finished
              batch ← drainAll storage
              if done
                then pure (collected <> batch)
                else do
                  when (null batch) yield
                  consume (collected <> batch)
        collected ← bounded (consume [])
        admitted ← counterValue storage Admitted
        dropped ← counterValue storage Dropped
        counterValue storage Offered `shouldReturn` fromIntegral (producers * each)
        admitted + dropped `shouldBe` fromIntegral (producers * each)
        fromIntegral (length collected) `shouldBe` admitted
        let parsed = [parse (recordMessage record) | record ← collected]
            byProducer = Map.fromListWith (flip (<>)) [(producer, [n]) | Just (producer, n) ← parsed]
        length [() | Nothing ← parsed] `shouldBe` 0
        forM_ (Map.toList byProducer) $ \(producer, sequenceNumbers) →
          (producer, and (zipWith (<) sequenceNumbers (drop 1 sequenceNumbers))) `shouldBe` (producer, True)
  where
    untilM condition = condition >>= \ok → if ok then pure () else yield >> untilM condition
    parse message = case Char8.split ':' message of
      [producer, n] → (,) <$> readInt producer <*> readInt n
      _ → Nothing
    readInt text = case Char8.readInt text of
      Just (value, rest) | Char8.null rest → Just value
      _ → Nothing
