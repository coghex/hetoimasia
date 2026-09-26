-- | The diagnostic lifetime: delivery through the caller's logger, the
-- verdict, sink failure and finalization cancellation beside a preserved
-- primary failure, and teardown ordering on every exit.
--
-- Records are offered through the package-local producer entry with the
-- lifetime's own user data, so every one of them goes through the production C
-- capture before the worker sees it. Nothing waits on time: a worker's progress
-- is observed through its delivered count and a gated sink's entry count, and
-- the default poll is replaced by one no example reaches, so what an example
-- sees delivered came from an explicit wake-up or from the final drain.
module Test.GPU.Vulkan.Diagnostics.Lifetime (spec) where

import Control.Concurrent (forkIO, killThread, throwTo, yield)
import Control.Monad (forM_, replicateM_, when)
import Data.Word (Word64)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( AsyncException (ThreadKilled, UserInterrupt)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , annotateIO
  , fromException
  , finally
  , someExceptionContext
  , throwIO
  , try
  )
import Control.Exception.Context (getExceptionAnnotations)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import qualified Data.Text as Text
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  , shouldNotReturn
  , shouldSatisfy
  )

import Hetoimasia.Foundation.Log
  ( LogEntry (..)
  , LogFilter (..)
  , LogLevel (..)
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Worker (activeWorkerCount, withWorkerGroup)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureCounters (..)
  , CapturePhase (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticVerdict (..)
  , FinalizationEvidence (..)
  , VerdictIssue (..)
  , captureStatus
  , capturePhase
  , captureUserData
  , deliveredCount
  , diagnosticVerdict
  , diagnosticsComponent
  , finalizationEvidence
  , afterLastCallback
  , retainStorage
  , verdictClean
  , verdictIssues
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Capture
  ( Offer (..)
  , Severity (..)
  , holdArrived
  , newHold
  , offerAnnounced
  , offerHeld
  , offerMissingData
  , plainOffer
  , releaseHold
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

    it "delivers a record's labels in that record's own scoped context, and no other's" $ do
      (logger, recorded) ← recordingLogger everythingFilter
      _ ←
        capturing logger $ \capture → do
          offerTo
            capture
            (plainOffer SeverityError "inside a labelled region")
              { offerQueueLabels = Just [Just "submission 2"]
              , offerCommandBufferLabels = Just [Just "batch 7", Just "pass 7", Nothing]
              }
          offerTo capture (plainOffer SeverityWarning "outside every region")
      entries ← recordedEntries recorded
      case map entryFields entries of
        [labelled, bare] → do
          Map.filterWithKey (\key _ → any (`Text.isPrefixOf` key) ["queue.", "cmdbuf."]) labelled
            `shouldBe` Map.fromList
              [ ("queue.labels", "1")
              , ("queue.label.1", "submission 2")
              , ("cmdbuf.labels", "3")
              , ("cmdbuf.label.1", "batch 7")
              , ("cmdbuf.label.2", "pass 7")
              ]
          Map.lookup "text" labelled `shouldBe` Just "inside a labelled region"
          Map.filterWithKey (\key _ → any (`Text.isPrefixOf` key) ["queue.", "cmdbuf."]) bare `shouldBe` Map.empty
        other → expectationFailure ("expected two records, got " <> show (length other))

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
              -- It threw before establishing quiescence, which the verdict says
              -- too.
              verdictIssues verdict
                `shouldBe` [ErrorLatched, RecordsUndelivered 1, ConsumerUnsuccessful, QuiescenceUnproven]

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
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → quiescent capture =<< do
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
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → quiescent capture =<< do
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
          -- The body succeeded, so the cancellation is the failure itself, not
          -- evidence beside another.
          finalizationEvidence failure `shouldSatisfy` isNothing
          case diagnosticVerdict failure of
            Nothing → expectationFailure "the cancellation carries no verdict"
            Just verdict → do
              consumerName (verdictConsumer verdict) `shouldBe` "cancelled"
              -- Both admitted records: the one the worker had taken and was
              -- delivering when it was cancelled, and the one still queued.
              verdictUndelivered verdict `shouldBe` 2
              verdictIssues verdict `shouldBe` [RecordsUndelivered 2, ConsumerUnsuccessful]

    it "keeps a failed body's own failure when cancelled while finalizing, with the cancellation beside it" $ do
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
              awaitInSink capture gate
              _ ← afterLastCallback capture (pure ())
              annotateIO (BodyMarker "the body's own context") (throwIO (TaggedFailure 42))
        putMVar done result
      ( do
          capture ← readMVar handle
          -- The body has failed and the worker is still inside the sink.
          awaitPhase capture PhaseClosed
          killThread thread
          result ← bounded (readMVar done)
          atomically (capturePhase capture) `shouldReturn` PhaseReleased
          case result of
            Right _ → expectationFailure "the body's failure was lost"
            Left failure → do
              fromException failure `shouldBe` Just (TaggedFailure 42)
              getExceptionAnnotations (someExceptionContext failure)
                `shouldBe` [BodyMarker "the body's own context"]
              fmap evidenceOf (finalizationEvidence failure)
                `shouldBe` Just (Just ThreadKilled, False)
              case diagnosticVerdict failure of
                Nothing → expectationFailure "the failure carries no verdict"
                Just verdict → do
                  consumerName (verdictConsumer verdict) `shouldBe` "cancelled"
                  verdictUndelivered verdict `shouldBe` 1
                  verdictStorageRetained verdict `shouldBe` False
                  verdictIssues verdict `shouldBe` [RecordsUndelivered 1, ConsumerUnsuccessful]
        )
        `finally` openGate gate

    it "keeps a body's own cancellation when a different one arrives while finalizing" $ do
      gate ← newGate
      (logger, _) ← gatedLogger gate
      handle ← newEmptyMVar
      done ← newEmptyMVar
      never ← newTVarIO False
      thread ← forkIO $ do
        result ←
          try @SomeException $
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → do
              offerTo capture (plainOffer SeverityInfo "never delivered")
              awaitInSink capture gate
              _ ← afterLastCallback capture (pure ())
              putMVar handle capture
              atomically (readTVar never >>= check)
              quiescent capture ()
        putMVar done result
      ( do
          capture ← readMVar handle
          killThread thread
          -- The body was cancelled and the worker is still inside the sink.
          awaitPhase capture PhaseClosed
          throwTo thread UserInterrupt
          result ← bounded (readMVar done)
          -- Still referenced here, so the body's wait was never provably endless.
          atomically (writeTVar never True)
          atomically (capturePhase capture) `shouldReturn` PhaseReleased
          case result of
            Right _ → expectationFailure "the body's cancellation was lost"
            Left failure → do
              fromException failure `shouldBe` Just ThreadKilled
              fmap evidenceOf (finalizationEvidence failure)
                `shouldBe` Just (Just UserInterrupt, False)
              fmap (consumerName . verdictConsumer) (diagnosticVerdict failure)
                `shouldBe` Just "cancelled"
        )
        `finally` openGate gate

    it "finalizes a body that is cancelled, then rethrows the cancellation" $ do
      (logger, recorded) ← recordingLogger everythingFilter
      started ← newEmptyMVar
      done ← newEmptyMVar
      never ← newTVarIO False
      thread ← forkIO $ do
        result ←
          try @SomeException $
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → quiescent capture =<< do
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

    it "answers status reads racing the release without failing" $ do
      (logger, _) ← recordingLogger everythingFilter
      handle ← newEmptyMVar
      reader ← newEmptyMVar
      -- A reader that starts while the body runs and keeps reading until it
      -- has seen the lifetime end, so some of its reads overlap the release.
      _ ← forkIO $ do
        capture ← readMVar handle
        let loop seen = do
              phase ← atomically (capturePhase capture)
              _ ← captureStatus capture
              if phase == PhaseReleased then pure (seen + 1) else loop (seen + 1 ∷ Int)
        result ← try @SomeException (loop 0)
        putMVar reader result
      ((), verdict) ←
        capturing logger $ \capture → do
          putMVar handle capture
          offerTo capture (plainOffer SeverityWarning "while reading")
      result ← bounded (readMVar reader)
      either (Left . show) (const (Right ())) result `shouldBe` Right ()
      verdictClean verdict `shouldBe` True

    it "includes in its verdict a producer that had announced itself when the body returned" $ do
      (logger, _) ← recordingLogger everythingFilter
      hold ← newHold
      done ← newEmptyMVar
      lifetime ← newEmptyMVar
      handle ← newEmptyMVar
      _ ← forkIO $ do
        result ←
          try @SomeException $
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → quiescent capture =<< do
              _ ← forkIO (offerAnnounced (captureUserData capture) hold SeverityWarning "announced" >> putMVar done ())
              bounded (untilM (holdArrived hold))
              putMVar handle capture
        putMVar lifetime result
      capture ← readMVar handle
      -- The lifetime cannot get past closing while the producer is announced.
      atomically (capturePhase capture) `shouldReturn` PhaseCapturing
      releaseHold hold
      bounded (readMVar done)
      result ← bounded (readMVar lifetime)
      case result of
        Left failure → expectationFailure ("the lifetime failed: " <> show failure)
        Right ((), verdict) →
          -- Closing had begun, so it counted itself as refused, and the verdict
          -- saw it.
          verdictIssues verdict `shouldBe` [CaptureFailureLatched, CaptureFailures 1]

    it "counts a report not yet begun when the lifetime ends, in memory that is still live" $ do
      (logger, _) ← recordingLogger everythingFilter
      hold ← newHold
      done ← newEmptyMVar
      saved ← newIORef Nothing
      ((), verdict) ←
        capturing logger $ \capture → do
          writeIORef saved (Just capture)
          _ ← forkIO (offerHeld (captureUserData capture) hold SeverityWarning "late" >> putMVar done ())
          bounded (untilM (holdArrived hold))
      -- The body returned before the report began — a Vulkan call still running
      -- after the body, which the lifetime's contract rules out. The verdict
      -- cannot have seen it; the storage's slot counts it.
      verdictClean verdict `shouldBe` True
      releaseHold hold
      bounded (readMVar done)
      readIORef saved >>= \case
        Nothing → expectationFailure "the body never ran"
        Just capture → do
          atomically (capturePhase capture) `shouldReturn` PhaseReleased
          status ← captureStatus capture
          countCaptureFailed (statusCounters status) `shouldBe` 1
          statusCaptureFailureLatched status `shouldBe` True

    it "counts every delivery the sink received, however a cancellation lands" $ do
      -- Delivering and counting are one step, so the verdict's delivered
      -- count is exactly what the sink received wherever the cancellation
      -- falls: during a write, between writes, or after the last. A
      -- cancellation that lands only once the lifetime has returned reaches
      -- the caller bare, with the lifetime's result discarded; there is nothing
      -- to check then, and the rounds are counted to show the others ran.
      cancelled ← newIORef (0 ∷ Int)
      forM_ [1 .. 300 ∷ Int] $ \attempt → do
        received ← newTVarIO (0 ∷ Word64)
        let sink = callbackSink (\_ → atomically (modifyTVar' received (+ 1)))
            logger = mkLogger everythingFilter sink
        done ← newEmptyMVar
        started ← newEmptyMVar
        thread ← forkIO $ do
          result ←
            try @SomeException $
              withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → quiescent capture =<< do
                mapM_ (\n → offerTo capture (plainOffer SeverityInfo n)) ["1", "2", "3", "4"]
                putMVar started ()
          putMVar done result
        readMVar started
        -- Vary where the cancellation lands relative to the final drain.
        replicateM_ (attempt `mod` 7) yield
        killThread thread
        result ← bounded (readMVar done)
        sunk ← readTVarIO received
        let verdictOf = either diagnosticVerdict (Just . snd) result
        case verdictOf of
          Nothing → either (\failure → fromException failure `shouldBe` Just ThreadKilled) (const (pure ())) result
          Just verdict → do
            when (either (const True) (const False) result) (modifyIORef' cancelled (+ 1))
            (attempt, verdictDelivered verdict) `shouldBe` (attempt, sunk)
            (attempt, verdictDelivered verdict + verdictUndelivered verdict) `shouldBe` (attempt, 4)
      -- Locally about one round in eight is cancelled mid-lifetime; none at all
      -- would mean the example had stopped exercising what it is for.
      readIORef cancelled `shouldNotReturn` 0

    it "is not clean when the owner never established quiescence" $ do
      (logger, _) ← recordingLogger everythingFilter
      outcome ←
        try $
          capturing logger $ \capture → do
            offerTo capture (plainOffer SeverityWarning "before the failure")
            throwIO PrimaryFailure
      case outcome of
        Right _ → expectationFailure "the body's failure was lost"
        Left failure → do
          fromException failure `shouldBe` Just PrimaryFailure
          fmap verdictIssues (diagnosticVerdict failure) `shouldBe` Just [QuiescenceUnproven]

    it "counts quiescence established while a failure unwinds" $ do
      (logger, _) ← recordingLogger everythingFilter
      outcome ←
        try $
          capturing logger $ \capture →
            (offerTo capture (plainOffer SeverityWarning "before the failure") >> throwIO PrimaryFailure)
              `finally` afterLastCallback capture (pure ())
      case outcome of
        Right _ → expectationFailure "the body's failure was lost"
        Left failure → do
          fromException failure `shouldBe` Just PrimaryFailure
          fmap verdictIssues (diagnosticVerdict failure) `shouldBe` Just []

    it "accepts no evidence another capture issued" $ do
      (logger, _) ← recordingLogger everythingFilter
      ((), verdict) ←
        bounded $
          withDiagnosticCapture (quietConfig smallConfig) logger $ \_ → do
            (issuedElsewhere, _) ←
              withDiagnosticCapture (quietConfig smallConfig) logger $ \inner → do
                token ← afterLastCallback inner (pure ())
                pure (token, token)
            pure ((), issuedElsewhere)
      verdictIssues verdict `shouldBe` [QuiescenceUnproven]

    it "records no evidence when the last destruction throws" $ do
      (logger, _) ← recordingLogger everythingFilter
      outcome ←
        try $
          bounded $
            withDiagnosticCapture (quietConfig smallConfig) logger $ \capture → do
              token ← afterLastCallback capture (throwIO PrimaryFailure)
              pure ((), token)
      case outcome of
        Right _ → expectationFailure "the destruction's failure was lost"
        Left failure → fmap verdictIssues (diagnosticVerdict failure) `shouldBe` Just [QuiescenceUnproven]

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
    evidenceOf evidence =
      ( evidenceCancellation evidence >>= \(ExceptionWithContext _ cancellation) → fromException cancellation
      , not (isNothing (evidenceGroupFailure evidence))
      )
    untilM condition = condition >>= \ok → if ok then pure () else yield >> untilM condition
    describeFailure failure =
      ( fromException failure
      , fmap (consumerName . verdictConsumer) (diagnosticVerdict failure)
      )
