-- | The diagnostic lifetime: delivery through the caller's logger, the
-- verdict, sink failure beside a preserved primary failure, and teardown
-- ordering on every exit.
--
-- Records are offered through the package-local producer entry with the
-- lifetime's own user data, so every one of them goes through the production C
-- capture before the worker sees it. Nothing waits on time: a worker's progress
-- is observed through its delivered count and a gated sink's entry count, and
-- the default poll is replaced by one no example reaches, so what an example
-- sees delivered came from an explicit wake-up or from the final drain.
module Test.GPU.Vulkan.Diagnostics.Lifetime (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , SomeException
  , fromException
  , throwIO
  , try
  )
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  , shouldSatisfy
  )

import Hetoimasia.Foundation.Log
  ( LogEntry (..)
  , LogFilter (..)
  , LogLevel (..)
  )
import Hetoimasia.Foundation.Worker (activeWorkerCount, withWorkerGroup)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureCounters (..)
  , CapturePhase (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticVerdict (..)
  , VerdictIssue (..)
  , captureStatus
  , capturePhase
  , captureUserData
  , deliveredCount
  , diagnosticVerdict
  , diagnosticsComponent
  , retainStorage
  , verdictClean
  , verdictIssues
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Capture
  ( Offer (..)
  , Severity (..)
  , offerMissingData
  , plainOffer
  )
import Test.GPU.Vulkan.Diagnostics.Support

-- | The body's own failure, which nothing the lifetime does may replace.
data PrimaryFailure = PrimaryFailure
  deriving (Eq, Show)

instance Exception PrimaryFailure

consumerName ∷ ConsumerOutcome → String
consumerName = \case
  ConsumerCompleted → "completed"
  ConsumerSinkFailed _ → "sink failed"
  ConsumerFailed _ → "failed"
  ConsumerCancelled _ → "cancelled"

spec ∷ Spec
spec = describe "Lifetime" $ do
  describe "delivery" $ do
    it "delivers each record through the caller's logger, with its level, component, context and fields" $ do
      (logger, recorded) ← recordingLogger everythingFilter
      ((), verdict) ←
        capturing logger $ \capture → do
          offerTo
            capture
            (plainOffer SeverityWarning "a warning")
              { offerIdName = Just "VUID-warning"
              , offerIdNumber = 7
              , offerTypes = 0x2
              , offerObjects = Just [(9, 0xabc, Just "the buffer")]
              }
          offerTo capture (plainOffer SeverityError "an error")
          offerTo capture (plainOffer SeverityInfo "an info")
          offerTo capture (plainOffer SeverityVerbose "a verbose")
      entries ← recordedEntries recorded
      map entryLevel entries `shouldBe` [Warning, Error, Debug, Debug]
      map entryComponent entries `shouldBe` replicate 4 diagnosticsComponent
      map entryMessage entries `shouldBe` replicate 4 "Vulkan diagnostic"
      map entryBreadcrumbs entries `shouldBe` replicate 4 ["vulkan-diagnostics"]
      case entries of
        first : _ →
          entryFields first
            `shouldBe` Map.fromList
              [ ("severity", "warning")
              , ("types", "validation")
              , ("message.id", "VUID-warning")
              , ("message.number", "7")
              , ("text", "a warning")
              , ("objects", "1")
              , ("object.1", "9:0xabc")
              , ("object.1.name", "the buffer")
              ]
        [] → expectationFailure "nothing was delivered"
      verdictDelivered verdict `shouldBe` 4
      verdictIssues verdict `shouldBe` [ErrorLatched]

    it "is clean when only warnings and commentary arrived, and every one was delivered" $ do
      (logger, _) ← recordingLogger everythingFilter
      ((), verdict) ←
        capturing logger $ \capture → do
          offerTo capture (plainOffer SeverityWarning "a warning")
          offerTo capture (plainOffer SeverityInfo "an info")
      verdictIssues verdict `shouldBe` []
      verdictClean verdict `shouldBe` True
      verdictDelivered verdict `shouldBe` 2

    it "drains while the body still runs, when woken" $ do
      (logger, recorded) ← recordingLogger everythingFilter
      _ ←
        capturing logger $ \capture → do
          offerTo capture (plainOffer SeverityInfo "early")
          awaitDelivered capture 1
          map entryFields <$> recordedEntries recorded >>= \delivered →
            map (Map.lookup "text") delivered `shouldBe` [Just "early"]
      pure ()

    it "runs its worker in a group of its own, not the caller's" $ do
      (logger, _) ← recordingLogger everythingFilter
      _ ← withWorkerGroup $ \application →
        capturing logger $ \capture → do
          offerTo capture (plainOffer SeverityInfo "seen")
          awaitDelivered capture 1
          atomically (activeWorkerCount application) `shouldReturn` 0
      pure ()

  describe "the error latch" $ do
    it "latches an error the logger filters out entirely" $ do
      (logger, recorded) ← recordingLogger everythingFilter {filterEnabled = False}
      ((), verdict) ←
        capturing logger $ \capture → do
          offerTo capture (plainOffer SeverityError "filtered")
          awaitDelivered capture 1
          statusErrorLatched <$> captureStatus capture `shouldReturn` True
      recordedEntries recorded `shouldReturn` []
      verdictIssues verdict `shouldBe` [ErrorLatched]

    it "answers the latch while the worker is blocked in the sink" $ do
      gate ← newGate
      (logger, _) ← gatedLogger gate
      ((), verdict) ←
        capturing logger $ \capture → do
          offerTo capture (plainOffer SeverityInfo "holds the worker")
          awaitInSink capture gate
          offerTo capture (plainOffer SeverityError "behind it")
          status ← captureStatus capture
          statusErrorLatched status `shouldBe` True
          countErrors (statusCounters status) `shouldBe` 1
          openGate gate
      verdictIssues verdict `shouldBe` [ErrorLatched]

  describe "an incomplete record" $ do
    it "is not clean when records were dropped, though everything admitted was delivered" $ do
      (logger, _) ← recordingLogger everythingFilter
      ((), verdict) ←
        capturing logger $ \capture →
          mapM_ (\n → offerTo capture (plainOffer SeverityInfo n)) ["1", "2", "3", "4", "5", "6"]
      verdictDelivered verdict `shouldBe` 4
      verdictUndelivered verdict `shouldBe` 0
      verdictIssues verdict `shouldBe` [RecordsDropped 2]
      verdictClean verdict `shouldBe` False

    it "is not clean when a record was truncated" $ do
      (logger, recorded) ← recordingLogger everythingFilter
      ((), verdict) ←
        capturing logger $ \capture →
          offerTo capture (plainOffer SeverityWarning (mconcat (replicate 10 "0123456789")))
      verdictIssues verdict `shouldBe` [RecordsTruncated 1]
      map (Map.lookup "truncated" . entryFields) <$> recordedEntries recorded `shouldReturn` [Just "true"]

    it "is not clean when a producer could not capture a report" $ do
      (logger, _) ← recordingLogger everythingFilter
      ((), verdict) ←
        capturing logger $ \capture →
          offerMissingData (captureUserData capture) (plainOffer SeverityInfo "unseen")
      verdictIssues verdict `shouldBe` [CaptureFailureLatched, CaptureFailures 1]

  describe "sink failure" $ do
    it "is the consumer's own terminal status, accounts for what it could not deliver, and is never logged to itself" $ do
      (logger, attempts) ← failingLogger
      (result, verdict) ←
        capturing logger $ \capture → do
          mapM_ (\n → offerTo capture (plainOffer SeverityWarning n)) ["1", "2", "3"]
          pure "the body's result"
      result `shouldBe` ("the body's result" ∷ String)
      consumerName (verdictConsumer verdict) `shouldBe` "sink failed"
      case verdictConsumer verdict of
        ConsumerSinkFailed failure → show failure `shouldSatisfy` (not . null)
        _ → pure ()
      verdictDelivered verdict `shouldBe` 0
      verdictUndelivered verdict `shouldBe` 3
      verdictIssues verdict `shouldBe` [RecordsUndelivered 3, ConsumerUnsuccessful]
      -- One write reached the sink and failed; nothing was written about it.
      readTVarIO attempts `shouldReturn` 1

    it "stands beside the body's failure, which is rethrown unchanged with the verdict on it" $ do
      (logger, _) ← failingLogger
      outcome ←
        try $
          capturing logger $ \capture → do
            offerTo capture (plainOffer SeverityError "the validation error")
            throwIO PrimaryFailure
      case outcome of
        Right _ → expectationFailure "the body's failure was lost"
        Left failure → do
          fromException failure `shouldBe` Just PrimaryFailure
          case diagnosticVerdict failure of
            Nothing → expectationFailure "the failure carries no verdict"
            Just verdict → do
              consumerName (verdictConsumer verdict) `shouldBe` "sink failed"
              verdictIssues verdict `shouldBe` [ErrorLatched, RecordsUndelivered 1, ConsumerUnsuccessful]

    it "keeps a body failure as it is when the sink works" $ do
      (logger, recorded) ← recordingLogger everythingFilter
      outcome ←
        try $
          capturing logger $ \capture → do
            offerTo capture (plainOffer SeverityWarning "before the failure")
            throwIO PrimaryFailure
      either (Just . describeFailure) (const Nothing) outcome
        `shouldBe` Just (Just PrimaryFailure, Just "completed")
      length <$> recordedEntries recorded `shouldReturn` 1

  describe "teardown ordering" $ do
    it "delivers a record produced while an earlier one is still being delivered" $ do
      gate ← newGate
      (logger, recorded) ← gatedLogger gate
      ((), verdict) ←
        capturing logger $ \capture → do
          offerTo capture (plainOffer SeverityInfo "first")
          awaitInSink capture gate
          offerTo capture (plainOffer SeverityInfo "produced after draining began")
          openGate gate
      map (Map.lookup "text" . entryFields)
        <$> recordedEntries recorded
        `shouldReturn` [Just "first", Just "produced after draining began"]
      verdictDelivered verdict `shouldBe` 2
      verdictClean verdict `shouldBe` True

    it "delivers the body's last record in the final drain, with no poll to rely on" $ do
      (logger, recorded) ← recordingLogger everythingFilter
      ((), verdict) ←
        capturing logger $ \capture →
          -- As a create-info messenger reports inside vkDestroyInstance, after
          -- the explicit messenger has gone: the last thing the body does.
          offerTo capture (plainOffer SeverityInfo "during instance destruction")
      map (Map.lookup "text" . entryFields)
        <$> recordedEntries recorded
        `shouldReturn` [Just "during instance destruction"]
      verdictDelivered verdict `shouldBe` 1

    it "keeps the storage and the logger borrowed while a blocked sink holds the worker" $ do
      gate ← newGate
      (logger, recorded) ← gatedLogger gate
      handle ← newEmptyMVar
      done ← newEmptyMVar
      _ ← forkIO $ do
        result ←
          try @SomeException $
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → do
              putMVar handle capture
              offerTo capture (plainOffer SeverityInfo "blocked")
        putMVar done result
      capture ← readMVar handle
      awaitEntered gate 1
      awaitPhase capture PhaseClosed
      -- The worker is inside the sink; nothing after its join can have run.
      atomically (capturePhase capture) `shouldReturn` PhaseClosed
      countAdmitted . statusCounters <$> captureStatus capture `shouldReturn` 1
      -- A report arriving now is after admission closed. It is still
      -- counted, because the storage is still there to count it in.
      offerTo capture (plainOffer SeverityWarning "after admission closed")
      openGate gate
      result ← bounded (readMVar done)
      atomically (capturePhase capture) `shouldReturn` PhaseReleased
      length <$> recordedEntries recorded `shouldReturn` 1
      case result of
        Left failure → expectationFailure ("the lifetime failed: " <> show failure)
        Right ((), verdict) →
          verdictIssues verdict `shouldBe` [CaptureFailureLatched, CaptureFailures 1]

    it "answers its status from a snapshot once the storage is released" $ do
      (logger, _) ← recordingLogger everythingFilter
      saved ← newIORef Nothing
      _ ←
        capturing logger $ \capture → do
          writeIORef saved (Just capture)
          offerTo capture (plainOffer SeverityError "an error")
      readIORef saved >>= \case
        Nothing → expectationFailure "the body never ran"
        Just capture → do
          atomically (capturePhase capture) `shouldReturn` PhaseReleased
          status ← captureStatus capture
          statusErrorLatched status `shouldBe` True
          countAdmitted (statusCounters status) `shouldBe` 1
          atomically (deliveredCount capture) `shouldReturn` 1

    it "abandons a blocked sink when cancelled while finalizing, and releases only after the worker ends" $ do
      gate ← newGate
      (logger, _) ← gatedLogger gate
      handle ← newEmptyMVar
      done ← newEmptyMVar
      thread ← forkIO $ do
        result ←
          try @SomeException $
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → do
              putMVar handle capture
              offerTo capture (plainOffer SeverityInfo "never delivered")
              offerTo capture (plainOffer SeverityInfo "queued behind it")
        putMVar done result
      capture ← readMVar handle
      awaitEntered gate 1
      awaitPhase capture PhaseClosed
      killThread thread
      result ← bounded (readMVar done)
      atomically (capturePhase capture) `shouldReturn` PhaseReleased
      case result of
        Right _ → expectationFailure "the cancellation was lost"
        Left failure → do
          fromException failure `shouldBe` Just ThreadKilled
          case diagnosticVerdict failure of
            Nothing → expectationFailure "the cancellation carries no verdict"
            Just verdict → do
              consumerName (verdictConsumer verdict) `shouldBe` "cancelled"
              verdictUndelivered verdict `shouldBe` 1
              verdictIssues verdict `shouldSatisfy` elem ConsumerUnsuccessful
              verdictIssues verdict `shouldSatisfy` elem (RecordsUndelivered 1)

    it "finalizes a body that is cancelled, then rethrows the cancellation" $ do
      (logger, recorded) ← recordingLogger everythingFilter
      started ← newEmptyMVar
      done ← newEmptyMVar
      never ← newTVarIO False
      thread ← forkIO $ do
        result ←
          try @SomeException $
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → do
              offerTo capture (plainOffer SeverityWarning "before the cancellation")
              putMVar started ()
              atomically (readTVar never >>= check)
        putMVar done result
      readMVar started
      killThread thread
      result ← bounded (readMVar done)
      -- Still referenced here, so the body's wait was never provably endless.
      atomically (writeTVar never True)
      case result of
        Right _ → expectationFailure "the cancellation was lost"
        Left failure → do
          fromException failure `shouldBe` Just ThreadKilled
          fmap verdictDelivered (diagnosticVerdict failure) `shouldBe` Just 1
      length <$> recordedEntries recorded `shouldReturn` 1

    it "never frees storage the body retained" $ do
      (logger, _) ← recordingLogger everythingFilter
      saved ← newIORef Nothing
      ((), verdict) ←
        capturing logger $ \capture → do
          writeIORef saved (Just capture)
          retainStorage capture
          offerTo capture (plainOffer SeverityInfo "kept")
      verdictIssues verdict `shouldBe` [StorageRetained]
      readIORef saved >>= \case
        Nothing → expectationFailure "the body never ran"
        Just capture → do
          -- A messenger that still names the storage would find it alive.
          offerTo capture (plainOffer SeverityWarning "from a retained messenger")
          countCaptureFailed . statusCounters <$> captureStatus capture `shouldReturn` 1
  where
    describeFailure failure =
      ( fromException failure
      , fmap (consumerName . verdictConsumer) (diagnosticVerdict failure)
      )
