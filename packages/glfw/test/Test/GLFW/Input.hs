-- | Examples for window input feeds and their acknowledged reset, driven by the
-- private producer and by scripted native callbacks on the CPU.
--
-- Every example drives the production feed model in
-- "Hetoimasia.GLFW.Internal.Input": the owner's production, overflow, warning,
-- resumption, and closure operations, and the consumer's reader and admission
-- control. Callback-staging examples attach a feed to a seam window and deliver
-- scripted input callbacks through 'seamDrive'. Nothing initializes GLFW.
--
-- Threads are coordinated with 'MVar's and STM, never with a sleep, and a
-- transaction that would wait is observed by composing it with 'orElse'.
module Test.GLFW.Input (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM, atomically, orElse)
import Control.Exception (AsyncException (ThreadKilled), IOException, SomeException, fromException, throwIO, try)
import Control.Monad (forM, forM_, replicateM, replicateM_, when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Log
  ( LogEntry (..)
  , LogLevel (Warning)
  , Logger
  , callbackSink
  , componentText
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  )
import Hetoimasia.GLFW.Internal.Input
import Hetoimasia.GLFW.Internal.Seam
  ( DriveOrigin (..)
  , Seam
  , WindowEvent (..)
  , asProcessMainThread
  , defaultScript
  , newSeam
  , seamDrive
  , seamDriveWith
  )
import Hetoimasia.GLFW.Internal.Window (attachWindowInputFeed, inputStagingCapacity)
import Hetoimasia.GLFW.Window
  ( Window
  , WindowId
  , WindowObservation
  , WindowResult (..)
  , hiddenTestWindowConfig
  , observedCursorPosition
  , observedCursorInside
  , windowIdentity
  , windowObservations
  , withWindow
  )
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Test.GLFW.Support (boundedExample, caughtAs, entered, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldNotBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW input feeds" $ do
  describe "events and gates" $ do
    it "delivers key, text, button, scroll, and focus as distinct, uncoalesced events tagged with their window and epoch"
      (boundedExample testDistinctEvents)
    it "gates input before readiness and while unfocused, needs no reset to stay disabled before readiness, and delivers the focus loss that closes the focus gate"
      (boundedExample testGates)
    it "keeps a button event's captured cursor position and modifiers after later cursor motion"
      (boundedExample testButtonPosition)
    it "clears held state on focus loss, so a later repeat or release is unpaired until a fresh press"
      (boundedExample testFocusLossClearsHeld)

  describe "overflow reset" $ do
    it "keeps one stable token per episode across repeated overflow, suppressing into bounded, exact counters"
      (boundedExample testStableToken)
    it "accounts the discarded backlog exactly, apart from the overflowing event and from events already delivered"
      (boundedExample testDiscardAccounting)
    it "delivers no old backlog after the reset, and no new-epoch input before acknowledgement and resumption"
      (boundedExample testNoBacklogNoEarlyInput)
    it "answers foreign, duplicate, stale, and closed acknowledgements as specified"
      (boundedExample testAcknowledgements)
    it "leaves a feed paused and closable when its consumer is cancelled before acknowledging"
      (boundedExample testCancelledConsumer)
    it "ends reads at closure during a pending or acknowledged reset, without delivering the reset first"
      (boundedExample testClosureDuringReset)
    it "loses resumption to a closure committed after the candidate channel was allocated, publishing no channel"
      (boundedExample testResumptionLosesToClosure)
    it "gives a key or button held at a reset no synthetic press in the new epoch, while a fresh press is delivered"
      (boundedExample testHeldAcrossReset)
    it "overflows two windows' feeds independently"
      (boundedExample testIndependentWindows)

  describe "overflow warning" $ do
    it "writes one warning per episode through the injected logger, and blocks resumption until the attempt completes"
      (boundedExample testWarningBlocksResumption)
    it "retains an episode whose warning sink failed in final observations, without trying the sink again"
      (boundedExample testWarningFailure)
    it "retains an episode whose warning attempt shutdown cancelled, or prevented, in final observations"
      (boundedExample testWarningCancelled)

  describe "callback staging" $ do
    it "delivers key, character, button, and scroll from callbacks as tagged, uncoalesced events, and coalesces cursor into the observation"
      (boundedExample testCallbackEvents)
    it "keeps a button event's captured coordinates after later cursor motion through callbacks"
      (boundedExample testCallbackButtonPosition)
    it "keeps a button event's captured coordinates when motion and the button occur in separate owner turns"
      (boundedExample testCallbackButtonAcrossTurns)
    it "sets the staging loss latch while the buffer is full and begins the same reset, replaying no captured prefix"
      (boundedExample testStagingOverflow)
    it "keeps the focus gate current when focus loss is discarded with a staging overflow"
      (boundedExample testStagingOverflowFocus)
    it "publishes a captured batch to completion before a cancellation at the publication boundary"
      (boundedExample testPublishCancellationSafe)
    it "does not synthesize a press from a release delivered through a callback"
      (boundedExample testCallbackUnpairedRelease)
    it "gates callback input until admission is opened explicitly"
      (boundedExample testCallbackAdmission)
    it "leaves a second window's feed running when the first window's staging overflows"
      (boundedExample testCallbackIndependentWindows)
    it "delivers focus loss and gain in native order, and a focus transition that cannot be admitted starts the reset"
      (boundedExample testCallbackFocus)

  describe "application suspension" $ do
    it "leaves no backlog or held state after press, suspend, suppressed release, and enable, and needs acknowledgement, resumption, and a fresh press"
      (boundedExample testSuspendBetweenPressAndRelease)
    it "resumes only once acknowledged and re-enabled, in either order"
      (boundedExample testAcknowledgeAndEnableOrder)
    it "keeps one token and epoch through repeated toggles during one reset"
      (boundedExample testRepeatedToggles)
    it "preserves an overflow reset's token and warning obligation when input is suspended during it"
      (boundedExample testSuspendDuringOverflow)
    it "lets closure win every suspension and resumption race, and a changed gate leave the candidate unpublished"
      (boundedExample testClosureWinsSuspension)

-- ---------------------------------------------------------------------------
-- Events and gates

testDistinctEvents ∷ Expectation
testDistinctEvents = do
  [window] ← windowIdentities 1
  feed ← readyFeedFor window 16
  let shifted = noModifiers {modifierShift = True}
  produceInput feed (KeyInput (KeyEvent 65 38 KeyPressed shifted)) `shouldReturn` ProductionAdmitted
  produceInput feed (TextInput 'A') `shouldReturn` ProductionAdmitted
  recordCursor feed (CursorPosition 3 4)
  produceButton feed 1 ButtonPressed noModifiers `shouldReturn` ProductionAdmitted
  produceInput feed (ScrollInput (ScrollEvent 0 1)) `shouldReturn` ProductionAdmitted
  produceInput feed (ScrollInput (ScrollEvent 0 1)) `shouldReturn` ProductionAdmitted
  produceInput feed (TextInput 'A') `shouldReturn` ProductionAdmitted
  produceInput feed (FocusInput False) `shouldReturn` ProductionAdmitted
  (events, final) ← drain (feedReader feed)
  map inputPayload events
    `shouldBe` [ KeyInput (KeyEvent 65 38 KeyPressed shifted)
               , TextInput 'A'
               , ButtonInput (ButtonEvent 1 ButtonPressed (Just (CursorPosition 3 4)) noModifiers)
               , ScrollInput (ScrollEvent 0 1)
               , ScrollInput (ScrollEvent 0 1)
               , TextInput 'A'
               , FocusInput False
               ]
  map inputWindow events `shouldBe` replicate 7 window
  map (epochNumber . inputEpoch) events `shouldBe` replicate 7 1
  final `shouldBe` InputEmpty
  statistics ← statisticsOf feed
  (statisticsAdmitted statistics, statisticsDelivered statistics) `shouldBe` (7, 7)

testGates ∷ Expectation
testGates = do
  feed ← newFeed 8
  let control = feedControl feed
  produceInput feed (TextInput 'a') `shouldReturn` ProductionGated
  atomically (suspendInput control) `shouldReturn` AdmissionUnchanged
  before ← statisticsOf feed
  (statisticsPhase before, statisticsAdmission before, statisticsResets before) `shouldBe` (InputRunning, AwaitingReadiness, 0)
  atomically (enableInput control) `shouldReturn` AdmissionOpened
  atomically (enableInput control) `shouldReturn` AdmissionUnchanged
  produceInput feed (FocusInput False) `shouldReturn` ProductionAdmitted
  produceInput feed (TextInput 'b') `shouldReturn` ProductionGated
  produceInput feed (KeyInput (KeyEvent 65 0 KeyPressed noModifiers)) `shouldReturn` ProductionGated
  produceInput feed (ScrollInput (ScrollEvent 1 0)) `shouldReturn` ProductionGated
  produceInput feed (FocusInput True) `shouldReturn` ProductionAdmitted
  produceInput feed (TextInput 'c') `shouldReturn` ProductionAdmitted
  (events, _) ← drain (feedReader feed)
  map inputPayload events `shouldBe` [FocusInput False, FocusInput True, TextInput 'c']
  after ← statisticsOf feed
  (statisticsGated after, statisticsResets after, statisticsFocused after) `shouldBe` (4, 0, True)

testButtonPosition ∷ Expectation
testButtonPosition = do
  feed ← readyFeed 8
  let shifted = noModifiers {modifierShift = True}
  produceButton feed 0 ButtonPressed shifted `shouldReturn` ProductionAdmitted
  recordCursor feed (CursorPosition 1 2)
  produceButton feed 0 ButtonReleased shifted `shouldReturn` ProductionAdmitted
  produceButton feed 0 ButtonPressed noModifiers `shouldReturn` ProductionAdmitted
  recordCursor feed (CursorPosition 50 60)
  recordCursor feed (CursorPosition 70 80)
  (events, _) ← drain (feedReader feed)
  map inputPayload events
    `shouldBe` [ ButtonInput (ButtonEvent 0 ButtonPressed Nothing shifted)
               , ButtonInput (ButtonEvent 0 ButtonReleased (Just (CursorPosition 1 2)) shifted)
               , ButtonInput (ButtonEvent 0 ButtonPressed (Just (CursorPosition 1 2)) noModifiers)
               ]

testFocusLossClearsHeld ∷ Expectation
testFocusLossClearsHeld = do
  feed ← readyFeed 16
  produceInput feed (key 65 KeyPressed) `shouldReturn` ProductionAdmitted
  produceButton feed 2 ButtonPressed noModifiers `shouldReturn` ProductionAdmitted
  statisticsHeld <$> statisticsOf feed `shouldReturn` 2
  produceInput feed (FocusInput False) `shouldReturn` ProductionAdmitted
  statisticsHeld <$> statisticsOf feed `shouldReturn` 0
  produceInput feed (FocusInput True) `shouldReturn` ProductionAdmitted
  produceInput feed (key 65 KeyRepeated) `shouldReturn` ProductionUnpaired
  produceInput feed (key 65 KeyReleased) `shouldReturn` ProductionUnpaired
  produceButton feed 2 ButtonReleased noModifiers `shouldReturn` ProductionUnpaired
  produceInput feed (key 65 KeyPressed) `shouldReturn` ProductionAdmitted
  produceInput feed (key 65 KeyRepeated) `shouldReturn` ProductionAdmitted
  produceInput feed (key 65 KeyReleased) `shouldReturn` ProductionAdmitted
  -- A key outside the named domain gains no held state.
  produceInput feed (key (-1) KeyPressed) `shouldReturn` ProductionAdmitted
  produceInput feed (key (-1) KeyReleased) `shouldReturn` ProductionUnpaired
  (events, _) ← drain (feedReader feed)
  map inputPayload events
    `shouldBe` [ key 65 KeyPressed
               , ButtonInput (ButtonEvent 2 ButtonPressed Nothing noModifiers)
               , FocusInput False
               , FocusInput True
               , key 65 KeyPressed
               , key 65 KeyRepeated
               , key 65 KeyReleased
               , key (-1) KeyPressed
               ]
  statisticsUnpaired <$> statisticsOf feed `shouldReturn` 4

-- ---------------------------------------------------------------------------
-- Overflow reset

testStableToken ∷ Expectation
testStableToken = do
  feed ← readyFeed 2
  fill feed 2
  token ← overflow feed
  resetReason token `shouldBe` InputOverflowed
  epochNumber (resetEpoch token) `shouldBe` 2
  outcomes ← replicateM suppressedCount (produceInput feed (TextInput 's'))
  outcomes `shouldSatisfy` all (== ProductionSuppressed)
  -- Overflow-shaped production during the episode changes nothing either.
  produceInput feed (key 65 KeyPressed) `shouldReturn` ProductionSuppressed
  readNow feed `shouldReturn` InputResetRequired token
  readNow feed `shouldReturn` InputResetRequired token
  statistics ← statisticsOf feed
  statisticsPhase statistics `shouldBe` InputResetPending
  epochNumber (statisticsEpoch statistics) `shouldBe` 1
  statisticsResets statistics `shouldBe` 1
  statisticsGenerations statistics `shouldBe` 1
  statisticsSuppressed statistics `shouldBe` fromIntegral suppressedCount + 1
  statisticsQueued statistics `shouldBe` 0
  statisticsLastReset statistics
    `shouldBe` Just
      ResetSummary
        { summaryEpoch = resetEpoch token
        , summaryReason = InputOverflowed
        , summaryDiscarded = 2
        , summaryUnadmitted = 1
        , summarySuppressed = fromIntegral suppressedCount + 1
        , summaryWarning = WarningOwed
        }
  where
    suppressedCount = 20000

testDiscardAccounting ∷ Expectation
testDiscardAccounting = do
  feed ← readyFeed 4
  fill feed 4
  InputDelivered _ ← readNow feed
  produceInput feed (TextInput 'e') `shouldReturn` ProductionAdmitted
  _ ← overflow feed
  statistics ← statisticsOf feed
  ( statisticsAdmitted statistics
    , statisticsDelivered statistics
    , statisticsDiscardedByReset statistics
    , statisticsOverflowed statistics
    , statisticsDiscardedAtClose statistics
    )
    `shouldBe` (5, 1, 4, 1, 0)
  (summaryDiscarded <$> statisticsLastReset statistics, summaryUnadmitted <$> statisticsLastReset statistics)
    `shouldBe` (Just 4, Just 1)
  -- Closure discards a running backlog separately.
  resume feed
  fill feed 3
  atomically (closeInputFeed feed)
  closed ← statisticsOf feed
  (statisticsDiscardedByReset closed, statisticsDiscardedAtClose closed, statisticsAdmitted closed) `shouldBe` (4, 3, 8)

testNoBacklogNoEarlyInput ∷ Expectation
testNoBacklogNoEarlyInput = do
  feed ← readyFeed 3
  let reader = feedReader feed
  mapM_ (\character → produceInput feed (TextInput character) `shouldReturn` ProductionAdmitted) ['a', 'b', 'c']
  InputDelivered first ← readNow feed
  inputPayload first `shouldBe` TextInput 'a'
  produceInput feed (TextInput 'd') `shouldReturn` ProductionAdmitted
  token ← overflow feed
  readNow feed `shouldReturn` InputResetRequired token
  awaitNow reader `shouldReturn` Just (InputResetRequired token)
  produceInput feed (TextInput 'n') `shouldReturn` ProductionSuppressed
  resumeInput feed `shouldReturn` ResumeAwaitingAcknowledgement
  atomically (acknowledgeReset reader token) `shouldReturn` Right Acknowledged
  readNow feed `shouldReturn` InputPaused
  readNow feed `shouldReturn` InputPaused
  -- A wait keeps waiting rather than demanding the reset again.
  awaitNow reader `shouldReturn` Nothing
  produceInput feed (TextInput 'p') `shouldReturn` ProductionSuppressed
  attemptOverflowWarning quietLogger feed `shouldReturn` WarningLogged
  readNow feed `shouldReturn` InputPaused
  resumeInput feed `shouldReturn` Resumed (resetEpoch token)
  readNow feed `shouldReturn` InputEmpty
  produceInput feed (TextInput 'z') `shouldReturn` ProductionAdmitted
  (events, final) ← drain reader
  map inputPayload events `shouldBe` [TextInput 'z']
  map inputEpoch events `shouldBe` [resetEpoch token]
  final `shouldBe` InputEmpty
  resumeInput feed `shouldReturn` ResumeNotNeeded

testAcknowledgements ∷ Expectation
testAcknowledgements = do
  [first, second] ← windowIdentities 2
  feed ← readyFeedFor first 1
  other ← readyFeedFor second 1
  let reader = feedReader feed
  fill feed 1
  token ← overflow feed
  -- Misuse is checked before the other feed's readiness or terminal state.
  atomically (acknowledgeReset (feedReader other) token) `shouldReturn` Left (ForeignResetToken first second)
  atomically (closeInputFeed other)
  atomically (acknowledgeReset (feedReader other) token) `shouldReturn` Left (ForeignResetToken first second)
  atomically (acknowledgeReset reader token) `shouldReturn` Right Acknowledged
  atomically (acknowledgeReset reader token) `shouldReturn` Right AlreadyAcknowledged
  _ ← attemptOverflowWarning quietLogger feed
  resumeInput feed `shouldReturn` Resumed (resetEpoch token)
  atomically (acknowledgeReset reader token) `shouldReturn` Right AlreadyAcknowledged
  fill feed 1
  newer ← overflow feed
  newer `shouldNotBe` token
  epochNumber (resetEpoch newer) `shouldBe` 3
  atomically (acknowledgeReset reader token) `shouldReturn` Right StaleAcknowledgement
  readNow feed `shouldReturn` InputResetRequired newer
  -- Closure wins over the valid acknowledgement.
  atomically (closeInputFeed feed)
  atomically (acknowledgeReset reader newer) `shouldReturn` Right AcknowledgementClosed
  atomically (acknowledgeReset reader token) `shouldReturn` Right AcknowledgementClosed
  statisticsPhase <$> statisticsOf feed `shouldReturn` InputFeedClosed

testCancelledConsumer ∷ Expectation
testCancelledConsumer = do
  feed ← readyFeed 2
  let reader = feedReader feed
  fill feed 2
  token ← overflow feed
  seen ← newEmptyMVar
  never ← newEmptyMVar
  finished ← newEmptyMVar
  consumer ← forkIO $ do
    outcome ← try $ do
      found ← atomically (awaitInput reader)
      putMVar seen found
      takeMVar never ∷ IO ()
    putMVar finished (outcome ∷ Either SomeException ())
  takeMVar seen `shouldReturn` InputResetRequired token
  killThread consumer
  ended ← takeMVar finished
  either (\caught → fromException caught `shouldBe` Just ThreadKilled) (\() → unexpected "the consumer returned") ended
  statisticsPhase <$> statisticsOf feed `shouldReturn` InputResetPending
  attemptOverflowWarning quietLogger feed `shouldReturn` WarningLogged
  resumeInput feed `shouldReturn` ResumeAwaitingAcknowledgement
  produceInput feed (TextInput 'x') `shouldReturn` ProductionSuppressed
  readNow feed `shouldReturn` InputResetRequired token
  atomically (closeInputFeed feed)
  atomically (awaitInput reader) `shouldReturn` InputClosed
  resumeInput feed `shouldReturn` ResumeClosed

testClosureDuringReset ∷ Expectation
testClosureDuringReset = do
  pending ← readyFeed 1
  fill pending 1
  token ← overflow pending
  atomically (closeInputFeed pending)
  atomically (closeInputFeed pending)
  readNow pending `shouldReturn` InputClosed
  atomically (awaitInput (feedReader pending)) `shouldReturn` InputClosed
  produceInput pending (TextInput 'x') `shouldReturn` ProductionClosed
  resumeInput pending `shouldReturn` ResumeClosed
  frozen ← statisticsOf pending
  statisticsPhase frozen `shouldBe` InputFeedClosed
  summaryEpoch <$> statisticsLastReset frozen `shouldBe` Just (resetEpoch token)
  (statisticsDiscardedByReset frozen, statisticsOverflowed frozen, statisticsSuppressed frozen) `shouldBe` (1, 1, 0)

  acknowledged ← readyFeed 1
  fill acknowledged 1
  later ← overflow acknowledged
  atomically (acknowledgeReset (feedReader acknowledged) later) `shouldReturn` Right Acknowledged
  atomically (closeInputFeed acknowledged)
  readNow acknowledged `shouldReturn` InputClosed
  atomically (awaitInput (feedReader acknowledged)) `shouldReturn` InputClosed

testResumptionLosesToClosure ∷ Expectation
testResumptionLosesToClosure = do
  feed ← readyFeed 2
  fill feed 2
  token ← overflow feed
  atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
  attemptOverflowWarning quietLogger feed `shouldReturn` WarningLogged
  resumeInputWith (atomically (closeInputFeed feed)) feed `shouldReturn` ResumeClosed
  statistics ← statisticsOf feed
  (statisticsPhase statistics, statisticsGenerations statistics, epochNumber (statisticsEpoch statistics))
    `shouldBe` (InputFeedClosed, 1, 1)
  produceInput feed (TextInput 'x') `shouldReturn` ProductionClosed
  readNow feed `shouldReturn` InputClosed

testHeldAcrossReset ∷ Expectation
testHeldAcrossReset = do
  feed ← readyFeed 3
  produceInput feed (key 65 KeyPressed) `shouldReturn` ProductionAdmitted
  produceButton feed 0 ButtonPressed noModifiers `shouldReturn` ProductionAdmitted
  produceInput feed (key 65 KeyRepeated) `shouldReturn` ProductionAdmitted
  -- The held key's repeat is what overflows.
  ProductionOverflowed token ← produceInput feed (key 65 KeyRepeated)
  statisticsHeld <$> statisticsOf feed `shouldReturn` 0
  atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
  _ ← attemptOverflowWarning quietLogger feed
  resumeInput feed `shouldReturn` Resumed (resetEpoch token)
  produceInput feed (key 65 KeyRepeated) `shouldReturn` ProductionUnpaired
  produceInput feed (key 65 KeyReleased) `shouldReturn` ProductionUnpaired
  produceButton feed 0 ButtonReleased noModifiers `shouldReturn` ProductionUnpaired
  readNow feed `shouldReturn` InputEmpty
  produceInput feed (key 65 KeyPressed) `shouldReturn` ProductionAdmitted
  produceInput feed (key 65 KeyReleased) `shouldReturn` ProductionAdmitted
  (events, _) ← drain (feedReader feed)
  map inputPayload events `shouldBe` [key 65 KeyPressed, key 65 KeyReleased]
  map inputEpoch events `shouldBe` replicate 2 (resetEpoch token)

testIndependentWindows ∷ Expectation
testIndependentWindows = do
  [first, second] ← windowIdentities 2
  one ← readyFeedFor first 2
  two ← readyFeedFor second 2
  fill one 2
  produceInput two (TextInput 't') `shouldReturn` ProductionAdmitted
  oneToken ← overflow one
  resetWindow oneToken `shouldBe` first
  statisticsPhase <$> statisticsOf two `shouldReturn` InputRunning
  produceInput two (TextInput 'u') `shouldReturn` ProductionAdmitted
  InputDelivered event ← readNow two
  (inputWindow event, inputPayload event, epochNumber (inputEpoch event)) `shouldBe` (second, TextInput 't', 1)
  produceInput two (TextInput 'v') `shouldReturn` ProductionAdmitted
  twoToken ← overflow two
  resetWindow twoToken `shouldBe` second
  atomically (acknowledgeReset (feedReader one) twoToken) `shouldReturn` Left (ForeignResetToken second first)
  atomically (acknowledgeReset (feedReader one) oneToken) `shouldReturn` Right Acknowledged
  _ ← attemptOverflowWarning quietLogger one
  resumeInput one `shouldReturn` Resumed (resetEpoch oneToken)
  produceInput one (TextInput 'w') `shouldReturn` ProductionAdmitted
  readNow two `shouldReturn` InputResetRequired twoToken
  oneStatistics ← statisticsOf one
  twoStatistics ← statisticsOf two
  (statisticsPhase oneStatistics, statisticsResets oneStatistics, statisticsDiscardedByReset oneStatistics)
    `shouldBe` (InputRunning, 1, 2)
  (statisticsPhase twoStatistics, statisticsResets twoStatistics, statisticsDiscardedByReset twoStatistics)
    `shouldBe` (InputResetPending, 1, 2)

-- ---------------------------------------------------------------------------
-- Overflow warning

testWarningBlocksResumption ∷ Expectation
testWarningBlocksResumption = do
  [window] ← windowIdentities 1
  feed ← readyFeedFor window 2
  started ← newEmptyMVar
  release ← newEmptyMVar
  entries ← newIORef []
  let logger =
        mkLoggerWith defaultLogFilter systemMetadata . callbackSink $ \entry → do
          putMVar started ()
          takeMVar release
          atomicModifyIORef' entries (\recorded → (entry : recorded, ()))
  fill feed 2
  token ← overflow feed
  -- Acknowledged before the warning is attempted: the obligation survives.
  atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
  resumeInput feed `shouldReturn` ResumeAwaitingWarning
  attempted ← newEmptyMVar
  _ ← forkIO (try (attemptOverflowWarning logger feed) >>= putMVar attempted)
  takeMVar started
  (summaryWarning <$>) . statisticsLastReset <$> statisticsOf feed `shouldReturn` Just WarningAttempting
  resumeInput feed `shouldReturn` ResumeAwaitingWarning
  produceInput feed (TextInput 'x') `shouldReturn` ProductionSuppressed
  attemptOverflowWarning logger feed `shouldReturn` NoWarningDue
  putMVar release ()
  (takeMVar attempted ∷ IO (Either SomeException WarningAttempt)) >>= either throwIO (`shouldBe` WarningLogged)
  attemptOverflowWarning logger feed `shouldReturn` NoWarningDue
  resumeInput feed `shouldReturn` Resumed (resetEpoch token)
  written ← readIORef entries
  map (\entry → (entryLevel entry, componentText (entryComponent entry), entryMessage entry)) written
    `shouldBe` [(Warning, "glfw.input", "Input overflowed; the feed was reset")]
  map (Map.toList . entryFields) written
    `shouldBe` [[("discarded", "2"), ("epoch", "2"), ("unadmitted", "1"), ("window", "1")]]
  (summaryWarning <$>) . statisticsLastReset <$> statisticsOf feed `shouldReturn` Just WarningWritten

testWarningFailure ∷ Expectation
testWarningFailure = do
  feed ← readyFeed 1
  calls ← newIORef (0 ∷ Int)
  let failing =
        mkLoggerWith defaultLogFilter systemMetadata . callbackSink $ \_ → do
          atomicModifyIORef' calls (\count → (count + 1, ()))
          ioError (userError "the sink failed")
  fill feed 1
  token ← overflow feed
  _ ← caughtAs (attemptOverflowWarning failing feed) ∷ IO (IOException, SomeException)
  attemptOverflowWarning failing feed `shouldReturn` NoWarningDue
  readIORef calls `shouldReturn` 1
  atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
  -- The failed attempt completed, so it no longer holds resumption back.
  resumeInput feed `shouldReturn` Resumed (resetEpoch token)
  atomically (closeInputFeed feed)
  final ← statisticsOf feed
  statisticsPhase final `shouldBe` InputFeedClosed
  statisticsLastReset final
    `shouldBe` Just (ResetSummary (resetEpoch token) InputOverflowed 1 1 0 WarningFailed)
  (statisticsResets final, statisticsDiscardedByReset final, statisticsOverflowed final) `shouldBe` (1, 1, 1)

testWarningCancelled ∷ Expectation
testWarningCancelled = do
  feed ← readyFeed 1
  started ← newEmptyMVar
  never ← newEmptyMVar
  let blocking =
        mkLoggerWith defaultLogFilter systemMetadata . callbackSink $ \_ → do
          putMVar started ()
          takeMVar never
  fill feed 1
  token ← overflow feed
  attempted ← newEmptyMVar
  attempt ← forkIO (try (attemptOverflowWarning blocking feed) >>= putMVar attempted)
  takeMVar started
  -- Shutdown: the feed closes and the owner is cancelled mid-attempt.
  atomically (closeInputFeed feed)
  killThread attempt
  outcome ← takeMVar attempted ∷ IO (Either SomeException WarningAttempt)
  either (\caught → fromException caught `shouldBe` Just ThreadKilled) (\_ → unexpected "the attempt finished") outcome
  final ← statisticsOf feed
  statisticsPhase final `shouldBe` InputFeedClosed
  statisticsLastReset final
    `shouldBe` Just (ResetSummary (resetEpoch token) InputOverflowed 1 1 0 WarningInterrupted)
  attemptOverflowWarning blocking feed `shouldReturn` NoWarningDue
  resumeInput feed `shouldReturn` ResumeClosed

  -- Shutdown before any attempt leaves the obligation visibly unmet.
  prevented ← readyFeed 1
  calls ← newIORef (0 ∷ Int)
  let counting = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → atomicModifyIORef' calls (\count → (count + 1, ()))))
  fill prevented 1
  _ ← overflow prevented
  atomically (closeInputFeed prevented)
  attemptOverflowWarning counting prevented `shouldReturn` NoWarningDue
  readIORef calls `shouldReturn` 0
  (summaryWarning <$>) . statisticsLastReset <$> statisticsOf prevented `shouldReturn` Just WarningOwed

-- ---------------------------------------------------------------------------
-- Application suspension

testSuspendBetweenPressAndRelease ∷ Expectation
testSuspendBetweenPressAndRelease = do
  feed ← readyFeed 8
  let control = feedControl feed
      reader = feedReader feed
  produceInput feed (key 65 KeyPressed) `shouldReturn` ProductionAdmitted
  produceButton feed 0 ButtonPressed noModifiers `shouldReturn` ProductionAdmitted
  token ← suspended control
  resetReason token `shouldBe` AdmissionSuspended
  produceInput feed (key 65 KeyReleased) `shouldReturn` ProductionSuppressed
  produceButton feed 0 ButtonReleased noModifiers `shouldReturn` ProductionSuppressed
  atomically (enableInput control) `shouldReturn` AdmissionOpened
  readNow feed `shouldReturn` InputResetRequired token
  resumeInput feed `shouldReturn` ResumeAwaitingAcknowledgement
  atomically (acknowledgeReset reader token) `shouldReturn` Right Acknowledged
  readNow feed `shouldReturn` InputPaused
  calls ← newIORef (0 ∷ Int)
  let counting = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → atomicModifyIORef' calls (\count → (count + 1, ()))))
  attemptOverflowWarning counting feed `shouldReturn` NoWarningDue
  readIORef calls `shouldReturn` 0
  resumeInput feed `shouldReturn` Resumed (resetEpoch token)
  readNow feed `shouldReturn` InputEmpty
  produceInput feed (key 65 KeyRepeated) `shouldReturn` ProductionUnpaired
  produceInput feed (key 65 KeyReleased) `shouldReturn` ProductionUnpaired
  produceButton feed 0 ButtonReleased noModifiers `shouldReturn` ProductionUnpaired
  readNow feed `shouldReturn` InputEmpty
  produceInput feed (key 65 KeyPressed) `shouldReturn` ProductionAdmitted
  (events, _) ← drain reader
  map inputPayload events `shouldBe` [key 65 KeyPressed]
  map inputEpoch events `shouldBe` [resetEpoch token]
  statistics ← statisticsOf feed
  statisticsLastReset statistics
    `shouldBe` Just (ResetSummary (resetEpoch token) AdmissionSuspended 2 0 2 NoWarningOwed)
  (statisticsOverflowed statistics, statisticsDiscardedByReset statistics, statisticsHeld statistics) `shouldBe` (0, 2, 1)

testAcknowledgeAndEnableOrder ∷ Expectation
testAcknowledgeAndEnableOrder = do
  acknowledgedFirst ← readyFeed 4
  first ← suspended (feedControl acknowledgedFirst)
  atomically (acknowledgeReset (feedReader acknowledgedFirst) first) `shouldReturn` Right Acknowledged
  resumeInput acknowledgedFirst `shouldReturn` ResumeAdmissionClosed
  readNow acknowledgedFirst `shouldReturn` InputPaused
  atomically (enableInput (feedControl acknowledgedFirst)) `shouldReturn` AdmissionOpened
  resumeInput acknowledgedFirst `shouldReturn` Resumed (resetEpoch first)

  enabledFirst ← readyFeed 4
  second ← suspended (feedControl enabledFirst)
  atomically (enableInput (feedControl enabledFirst)) `shouldReturn` AdmissionOpened
  resumeInput enabledFirst `shouldReturn` ResumeAwaitingAcknowledgement
  readNow enabledFirst `shouldReturn` InputResetRequired second
  atomically (acknowledgeReset (feedReader enabledFirst) second) `shouldReturn` Right Acknowledged
  resumeInput enabledFirst `shouldReturn` Resumed (resetEpoch second)

  -- Focus is a separate gate on resumption.
  unfocused ← readyFeed 4
  third ← suspended (feedControl unfocused)
  produceInput unfocused (FocusInput False) `shouldReturn` ProductionSuppressed
  atomically (enableInput (feedControl unfocused)) `shouldReturn` AdmissionOpened
  atomically (acknowledgeReset (feedReader unfocused) third) `shouldReturn` Right Acknowledged
  resumeInput unfocused `shouldReturn` ResumeUnfocused
  produceInput unfocused (FocusInput True) `shouldReturn` ProductionSuppressed
  resumeInput unfocused `shouldReturn` Resumed (resetEpoch third)

testRepeatedToggles ∷ Expectation
testRepeatedToggles = do
  feed ← readyFeed 4
  let control = feedControl feed
  token ← suspended control
  toggles ← forM [1 ∷ Int .. 5] (\_ → (,) <$> atomically (enableInput control) <*> atomically (suspendInput control))
  toggles `shouldBe` replicate 5 (AdmissionOpened, AdmissionClosedDuringReset)
  atomically (suspendInput control) `shouldReturn` AdmissionUnchanged
  readNow feed `shouldReturn` InputResetRequired token
  atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
  replicateM_ 3 $ do
    atomically (enableInput control) `shouldReturn` AdmissionOpened
    atomically (suspendInput control) `shouldReturn` AdmissionClosedDuringReset
  statistics ← statisticsOf feed
  (statisticsResets statistics, statisticsPhase statistics, epochNumber (statisticsEpoch statistics))
    `shouldBe` (1, InputResetAcknowledged, 1)
  summaryEpoch <$> statisticsLastReset statistics `shouldBe` Just (resetEpoch token)
  atomically (enableInput control) `shouldReturn` AdmissionOpened
  resumeInput feed `shouldReturn` Resumed (resetEpoch token)
  epochNumber (resetEpoch token) `shouldBe` 2

testSuspendDuringOverflow ∷ Expectation
testSuspendDuringOverflow = do
  feed ← readyFeed 1
  let control = feedControl feed
  fill feed 1
  token ← overflow feed
  atomically (suspendInput control) `shouldReturn` AdmissionClosedDuringReset
  atomically (enableInput control) `shouldReturn` AdmissionOpened
  atomically (suspendInput control) `shouldReturn` AdmissionClosedDuringReset
  readNow feed `shouldReturn` InputResetRequired token
  statistics ← statisticsOf feed
  (summaryReason <$> statisticsLastReset statistics, summaryWarning <$> statisticsLastReset statistics)
    `shouldBe` (Just InputOverflowed, Just WarningOwed)
  statisticsResets statistics `shouldBe` 1
  atomically (enableInput control) `shouldReturn` AdmissionOpened
  atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
  resumeInput feed `shouldReturn` ResumeAwaitingWarning
  entries ← newIORef (0 ∷ Int)
  let counting = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → atomicModifyIORef' entries (\count → (count + 1, ()))))
  attemptOverflowWarning counting feed `shouldReturn` WarningLogged
  readIORef entries `shouldReturn` 1
  resumeInput feed `shouldReturn` Resumed (resetEpoch token)

testClosureWinsSuspension ∷ Expectation
testClosureWinsSuspension = do
  -- Closure before a suspension, or during the reset it began.
  closedFirst ← readyFeed 2
  atomically (closeInputFeed closedFirst)
  atomically (suspendInput (feedControl closedFirst)) `shouldReturn` AdmissionFeedClosed
  atomically (enableInput (feedControl closedFirst)) `shouldReturn` AdmissionFeedClosed
  statisticsResets <$> statisticsOf closedFirst `shouldReturn` 0

  closedPending ← readyFeed 2
  fill closedPending 1
  pendingToken ← suspended (feedControl closedPending)
  atomically (closeInputFeed closedPending)
  readNow closedPending `shouldReturn` InputClosed
  atomically (acknowledgeReset (feedReader closedPending) pendingToken) `shouldReturn` Right AcknowledgementClosed
  atomically (enableInput (feedControl closedPending)) `shouldReturn` AdmissionFeedClosed

  -- Closure between the candidate's allocation and its install.
  racing ← acknowledgedSuspension
  resumeInputWith (atomically (closeInputFeed racing)) racing `shouldReturn` ResumeClosed
  published racing `shouldReturn` (InputFeedClosed, 1)
  readNow racing `shouldReturn` InputClosed

  -- A suspension or a focus loss in the same window leaves the candidate
  -- unpublished, and a later resumption proceeds.
  suspendedMeanwhile ← acknowledgedSuspension
  resumeInputWith (() <$ atomically (suspendInput (feedControl suspendedMeanwhile))) suspendedMeanwhile
    `shouldReturn` ResumeAdmissionClosed
  published suspendedMeanwhile `shouldReturn` (InputResetAcknowledged, 1)
  atomically (enableInput (feedControl suspendedMeanwhile)) `shouldReturn` AdmissionOpened
  resumeInput suspendedMeanwhile >>= (`shouldSatisfy` isResumed)
  published suspendedMeanwhile `shouldReturn` (InputRunning, 2)

  unfocusedMeanwhile ← acknowledgedSuspension
  resumeInputWith (() <$ produceInput unfocusedMeanwhile (FocusInput False)) unfocusedMeanwhile
    `shouldReturn` ResumeUnfocused
  published unfocusedMeanwhile `shouldReturn` (InputResetAcknowledged, 1)
  atomically (closeInputFeed unfocusedMeanwhile)
  resumeInput unfocusedMeanwhile `shouldReturn` ResumeClosed
  where
    acknowledgedSuspension = do
      feed ← readyFeed 2
      token ← suspended (feedControl feed)
      atomically (enableInput (feedControl feed)) `shouldReturn` AdmissionOpened
      atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
      pure feed
    published feed = (\statistics → (statisticsPhase statistics, statisticsGenerations statistics)) <$> statisticsOf feed
    isResumed = \case
      Resumed _ → True
      _ → False

-- ---------------------------------------------------------------------------
-- Callback staging

testCallbackEvents ∷ Expectation
testCallbackEvents =
  withLiveFeed 16 $ \seam window feed → do
    drive seam window
      [ CursorMovedTo 3 4
      , CursorEnterChanged True
      , KeyEventAt 65 38 1 1
      , CharEventAt (fromEnum 'A')
      , ButtonEventAt 1 1 0
      , ScrollEventAt 0 1
      , ScrollEventAt 0 1
      , CharEventAt (fromEnum 'A')
      , FocusChanged False
      ]
    observation ← currentObservation window
    observedCursorPosition observation `shouldBe` Just (CursorPosition 3 4)
    observedCursorInside observation `shouldBe` Just True
    (events, _) ← drain (feedReader feed)
    map inputPayload events
      `shouldBe` [ KeyInput (KeyEvent 65 38 KeyPressed (noModifiers {modifierShift = True}))
                 , TextInput 'A'
                 , ButtonInput (ButtonEvent 1 ButtonPressed (Just (CursorPosition 3 4)) noModifiers)
                 , ScrollInput (ScrollEvent 0 1)
                 , ScrollInput (ScrollEvent 0 1)
                 , TextInput 'A'
                 , FocusInput False
                 ]
    map inputWindow events `shouldBe` replicate 7 (windowIdentity window)
    map (epochNumber . inputEpoch) events `shouldBe` replicate 7 1

testCallbackButtonPosition ∷ Expectation
testCallbackButtonPosition =
  withLiveFeed 8 $ \seam window feed → do
    drive seam window [CursorMovedTo 1 2, ButtonEventAt 0 1 1, CursorMovedTo 50 60, CursorMovedTo 70 80, ButtonEventAt 0 0 1]
    (events, _) ← drain (feedReader feed)
    map inputPayload events
      `shouldBe` [ ButtonInput (ButtonEvent 0 ButtonPressed (Just (CursorPosition 1 2)) (noModifiers {modifierShift = True}))
                 , ButtonInput (ButtonEvent 0 ButtonReleased (Just (CursorPosition 70 80)) (noModifiers {modifierShift = True}))
                 ]
    observedCursorPosition <$> currentObservation window `shouldReturn` Just (CursorPosition 70 80)

testCallbackButtonAcrossTurns ∷ Expectation
testCallbackButtonAcrossTurns =
  withLiveFeed 8 $ \seam window feed → do
    drive seam window [CursorMovedTo 9 10]
    drive seam window [ButtonEventAt 0 1 0]
    (events, _) ← drain (feedReader feed)
    map inputPayload events
      `shouldBe` [ButtonInput (ButtonEvent 0 ButtonPressed (Just (CursorPosition 9 10)) noModifiers)]

testStagingOverflow ∷ Expectation
testStagingOverflow =
  withLiveFeed 16 $ \seam window feed → do
    let overflowed = CharEventAt (fromEnum 'x') : replicate inputStagingCapacity (CharEventAt (fromEnum 'a'))
    drive seam window overflowed
    readNow feed >>= \case
      InputResetRequired token → do
        resetReason token `shouldBe` InputOverflowed
        summary ← statisticsLastReset <$> statisticsOf feed
        fmap summaryUnadmitted summary `shouldBe` Just (fromIntegral (inputStagingCapacity + 1))
        drain (feedReader feed) >>= \(events, _) → events `shouldBe` []
        atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
        _ ← attemptOverflowWarning quietLogger feed
        resumeInput feed `shouldReturn` Resumed (resetEpoch token)
        drive seam window [CharEventAt (fromEnum 'b')]
        (events, _) ← drain (feedReader feed)
        map inputPayload events `shouldBe` [TextInput 'b']
        map (epochNumber . inputEpoch) events `shouldBe` [2]
      other → unexpected ("staging overflow did not reset: " <> show other)

testStagingOverflowFocus ∷ Expectation
testStagingOverflowFocus =
  withLiveFeed 16 $ \seam window feed → do
    let overflowed = replicate inputStagingCapacity (CharEventAt (fromEnum 'a')) <> [FocusChanged False]
    drive seam window overflowed
    token ←
      readNow feed >>= \case
        InputResetRequired reset → pure reset
        other → unexpected ("staging overflow did not reset: " <> show other)
    summary ← statisticsLastReset <$> statisticsOf feed
    fmap summaryUnadmitted summary `shouldBe` Just (fromIntegral (inputStagingCapacity + 1))
    fmap summarySuppressed summary `shouldBe` Just 0
    statisticsFocused <$> statisticsOf feed `shouldReturn` False
    atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
    _ ← attemptOverflowWarning quietLogger feed
    resumeInput feed `shouldReturn` ResumeUnfocused
    drive seam window [FocusChanged True]
    resumeInput feed `shouldReturn` Resumed (resetEpoch token)

testPublishCancellationSafe ∷ Expectation
testPublishCancellationSafe =
  withLiveFeed 8 $ \seam window feed → do
    calls ← newIORef (0 ∷ Int)
    let hook = do
          n ← atomicModifyIORef' calls (\count → (count + 1, count))
          when (n >= 1) (throwIO ThreadKilled)
    (killed, _) ← caughtAs (seamDriveWith hook seam window DuringPoll [CharEventAt (fromEnum 'a'), CharEventAt (fromEnum 'b')])
    killed `shouldBe` ThreadKilled
    (events, _) ← drain (feedReader feed)
    map inputPayload events `shouldBe` [TextInput 'a', TextInput 'b']

testCallbackUnpairedRelease ∷ Expectation
testCallbackUnpairedRelease =
  withLiveFeed 8 $ \seam window feed → do
    drive seam window [KeyEventAt 65 0 0 0, KeyEventAt 65 0 2 0, ButtonEventAt 0 0 0]
    (events, _) ← drain (feedReader feed)
    events `shouldBe` []
    statisticsUnpaired <$> statisticsOf feed `shouldReturn` 3
    drive seam window [KeyEventAt 65 0 1 0, KeyEventAt 65 0 0 0]
    (pressed, _) ← drain (feedReader feed)
    map inputPayload pressed `shouldBe` [key 65 KeyPressed, key 65 KeyReleased]

testCallbackAdmission ∷ Expectation
testCallbackAdmission = do
  seam ← newSeam defaultScript
  asProcessMainThread seam . entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "input" 64 48) $ \window → do
      feed ← newInputFeed (windowIdentity window) 8 True
      attachWindowInputFeed window feed
      drive seam window [CharEventAt (fromEnum 'a')]
      (events, _) ← drain (feedReader feed)
      events `shouldBe` []
      statisticsGated <$> statisticsOf feed `shouldReturn` 1
      statisticsResets <$> statisticsOf feed `shouldReturn` 0
      atomically (enableInput (feedControl feed)) `shouldReturn` AdmissionOpened
      drive seam window [CharEventAt (fromEnum 'b')]
      (delivered, _) ← drain (feedReader feed)
      map inputPayload delivered `shouldBe` [TextInput 'b']

testCallbackIndependentWindows ∷ Expectation
testCallbackIndependentWindows = do
  seam ← newSeam defaultScript
  asProcessMainThread seam . entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "one" 64 48) $ \first →
      withWindow session (hiddenTestWindowConfig "two" 64 48) $ \second → do
        feedOne ← attached first 16
        feedTwo ← attached second 16
        let overflowed = replicate (inputStagingCapacity + 1) (CharEventAt (fromEnum 'x'))
        drive seam first overflowed
        drive seam second [CharEventAt (fromEnum 'y')]
        readNow feedOne >>= \case
          InputResetRequired _ → pure ()
          other → unexpected ("first window did not reset: " <> show other)
        (events, _) ← drain (feedReader feedTwo)
        map inputPayload events `shouldBe` [TextInput 'y']
        statisticsPhase <$> statisticsOf feedTwo `shouldReturn` InputRunning

testCallbackFocus ∷ Expectation
testCallbackFocus =
  withLiveFeed 2 $ \seam window feed → do
    drive seam window [FocusChanged False, FocusChanged True]
    (events, _) ← drain (feedReader feed)
    map inputPayload events `shouldBe` [FocusInput False, FocusInput True]
    fill feed 2
    drive seam window [FocusChanged False]
    readNow feed >>= \case
      InputResetRequired token → resetReason token `shouldBe` InputOverflowed
      other → unexpected ("a focus transition into a full feed did not reset: " <> show other)

-- ---------------------------------------------------------------------------
-- Support

withLiveFeed ∷ Integer → (Seam → Window → InputFeed → IO a) → IO a
withLiveFeed capacity action = do
  seam ← newSeam defaultScript
  asProcessMainThread seam . entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "input" 64 48) $ \window → do
      feed ← attached window capacity
      action seam window feed

attached ∷ Window → Integer → IO InputFeed
attached window capacity = do
  feed ← newInputFeed (windowIdentity window) capacity True >>= enabled
  attachWindowInputFeed window feed
  pure feed

drive ∷ Seam → Window → [WindowEvent] → IO ()
drive seam window events =
  seamDrive seam window DuringPoll events >>= \case
    WindowAvailable () → pure ()
    WindowEnded identity → unexpected ("window ended during drive: " <> show identity)

currentObservation ∷ Window → IO WindowObservation
currentObservation window = preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))


-- | Distinct window identities from windows created, and released, in a seam
-- session. A feed needs only the identity.
windowIdentities ∷ Int → IO [WindowId]
windowIdentities count = do
  seam ← newSeam defaultScript
  asProcessMainThread seam . entered seam $ \session →
    replicateM count (withWindow session (hiddenTestWindowConfig "input" 64 48) (pure . windowIdentity))

-- | A focused feed awaiting readiness.
newFeed ∷ Integer → IO InputFeed
newFeed capacity = windowIdentities 1 >>= \case
  [window] → newInputFeed window capacity True
  _ → unexpected "expected one window identity"

-- | A focused feed with input enabled.
readyFeed ∷ Integer → IO InputFeed
readyFeed capacity = newFeed capacity >>= enabled

readyFeedFor ∷ WindowId → Integer → IO InputFeed
readyFeedFor window capacity = newInputFeed window capacity True >>= enabled

enabled ∷ InputFeed → IO InputFeed
enabled feed = do
  atomically (enableInput (feedControl feed)) `shouldReturn` AdmissionOpened
  pure feed

key ∷ Int → KeyAction → InputPayload
key code action = KeyInput (KeyEvent code 0 action noModifiers)

-- | Admit this many text events.
fill ∷ InputFeed → Int → IO ()
fill feed count = forM_ [1 .. count] $ \_ → produceInput feed (TextInput 'f') `shouldReturn` ProductionAdmitted

-- | Produce an event into a full feed and answer the reset it began.
overflow ∷ InputFeed → IO ResetToken
overflow feed =
  produceInput feed (TextInput 'o') >>= \case
    ProductionOverflowed token → pure token
    other → unexpected ("the event did not overflow: " <> show other)

-- | Begin a suspension reset and answer its token.
suspended ∷ InputControl → IO ResetToken
suspended control =
  atomically (suspendInput control) >>= \case
    AdmissionReset token → pure token
    other → unexpected ("suspension began no reset: " <> show other)

-- | Acknowledge, warn, and resume a feed whose reset is pending.
resume ∷ InputFeed → IO ()
resume feed =
  readNow feed >>= \case
    InputResetRequired token → do
      atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
      _ ← attemptOverflowWarning quietLogger feed
      resumeInput feed `shouldReturn` Resumed (resetEpoch token)
    other → unexpected ("no reset was pending: " <> show other)

readNow ∷ InputFeed → IO InputRead
readNow = atomically . readInput . feedReader

-- | What a wait would return now, or 'Nothing' if it would wait.
awaitNow ∷ InputReader → IO (Maybe InputRead)
awaitNow reader = atomically ((Just <$> awaitInput reader) `orElse` pure Nothing)

-- | Every event deliverable now, and the read that ended the run.
drain ∷ InputReader → IO ([InputEvent], InputRead)
drain reader = atomically (go [])
  where
    go ∷ [InputEvent] → STM ([InputEvent], InputRead)
    go taken =
      readInput reader >>= \case
        InputDelivered event → go (event : taken)
        other → pure (reverse taken, other)

statisticsOf ∷ InputFeed → IO InputStatistics
statisticsOf = atomically . feedStatistics

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))
