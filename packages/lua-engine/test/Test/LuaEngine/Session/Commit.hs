{-# LANGUAGE OverloadedStrings #-}

-- | The session's one commit and the effects it owes. Every event is committed by one masked primitive: the state,
-- the markers and the historical facts the event means change in one transaction, together with the stops and the
-- diagnostics it owes, which a retained queue carries to whoever runs it next. These examples cancel or fail the
-- committer at each boundary (just after the commit and before its effects, between effects, inside an effect) and
-- check that nothing the event meant is lost, half applied or done twice.
module Test.LuaEngine.Session.Commit (spec) where

import Control.Concurrent (forkIO, killThread, myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO, toException, try, tryWithContext)
import Control.Monad (void, when)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, displayCleanupFailure)
import Hetoimasia.Foundation.Time (readInstant, scriptedSource)
import Test.Hspec
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "the one commit" $ do
  boundaries
  recovery
  facts

-- | A gameplay script whose tick-1 update suspends with a closing handler that fails.
suspending ∷ Script
suspending =
  printScript
    { scInit = []
    , scUpdate =
        [ "if api.time.tick() == 1 then"
        , "  print('suspended ' .. api.instance_id)"
        , "  local guard <close> = setmetatable({}, {__close = function() error('close failed') end})"
        , "  api.time.wait_ticks(100)"
        , "end"
        ]
    }

entriesOf ∷ SessionOutcome → [EngineEntry]
entriesOf outcome = maybe [] pure (erPrimary (outEngine outcome)) <> erSecondary (outEngine outcome)

-- The boundaries ----------------------------------------------------------------------------------------------------

boundaries ∷ Spec
boundaries = describe "at each boundary between a commit and its effects" $ do
  it "leaves a stop owed when the thread that committed it is cancelled right after the commit, and the driver pays it" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Committed "Stop")
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        stopper ← forkIO (requestStop session StopQuit)
        awaitPoint recorder (Committed "Stop")
        killThread stopper
        releaseHold recorder (Committed "Stop")
        void (awaitRetired session)
      out ← outLines world
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      out `shouldSatisfy` elem "shutdown presentation stopped"
      outVerdict outcome `shouldBe` VerdictSuccess

  it "accounts the cleanup the owner retained exactly once when the thread that committed the owner's end is cancelled right after the commit" $ do
    _ ←
      fatalSetup (setup (roleScript suspending)) {suShape = GameplayAlone} $ \env → do
        let world = seWorld env
        recorder ← newRecorder
        holdAt recorder (Committed "OwnerFinalized")
        self ← myThreadId
        handle ← newEmptyMVar
        _ ← forkIO $ do
          session ← readMVar handle
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          passTime world 1000000 ((>= 1) . length . filter (Text.isPrefixOf "suspended") <$> outLines world)
          requestStop session StopQuit
          -- the owner ended and its end was committed whole: the thread that committed it is cancelled right there
          awaitPoint recorder (Committed "OwnerFinalized")
          throwTo self ThreadKilled
          void (awaitStatus session statusStopping)
          releaseHold recorder (Committed "OwnerFinalized")
        result ← tryWithContext @SomeException (runSession (scenarioSpec env (recordingHarness recorder noHarness)) (putMVar handle))
        case result of
          Left (ExceptionWithContext attached raised) → do
            fromException raised `shouldBe` Just ThreadKilled
            map displayCleanupFailure (cleanupFailuresInContext attached) `shouldSatisfy` any ("close failed" `isInfixOf`)
          Right _ → expectationFailure "the cancellation was lost"
        session ← readMVar handle
        found ← atomically (sessionOutcomeNow session)
        -- the retained cleanup is in the report once, whichever thread committed the end first
        length [entry | entry ← entriesOf found, eeCode entry == CleanupFailure, Text.isInfixOf "close failed" (eeMessage entry)] `shouldBe` 1
    pure ()

  it "writes a diagnostic once more, and once, when the thread writing it was interrupted inside the effect" $
    withSetup (setup (roleScript printScript)) $ \env → do
      written ← newTVarIO ([] ∷ [Text])
      interrupted ← newTVarIO False
      self ← myThreadId
      let logger =
            mkLogger defaultLogFilter . callbackSink $ \entry → do
              let message = entryMessage entry
              here ← myThreadId
              already ← readTVarIO interrupted
              -- the driver commits the opening of the start gate, and is interrupted while it says so
              when (message == "start gate opened" && here == self && not already) $ do
                atomically (writeTVar interrupted True)
                throwIO ThreadKilled
              atomically (modifyTVar' written (message :))
          env' = env {seSpec = (seSpec env) {sxLogger = logger}}
      result ← try (runSession (scenarioSpec env' noHarness) (\_ → pure ()))
      case result of
        Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the interruption was lost"
      readTVarIO interrupted `shouldReturn` True
      -- the diagnostic was put back and written by the teardown, once
      messages ← readTVarIO written
      length (filter (== "start gate opened") messages) `shouldBe` 1

-- Recovery and cancellation only commit --------------------------------------------------------------------------------------------

recovery ∷ Spec
recovery = describe "a recovery or a cancellation path only commits" $ do
  it "reaches the unwind and stops the owners while the diagnostic that was interrupted is still blocked, and writes it in the final drain" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      written ← newTVarIO ([] ∷ [Text])
      blocked ← newTVarIO True
      self ← myThreadId
      let logger =
            mkLogger defaultLogFilter . callbackSink $ \entry → do
              let message = entryMessage entry
              here ← myThreadId
              -- the driver says that the start gate opened, and the sink does not return
              when (message == "start gate opened" && here == self) $
                atomically (readTVar blocked >>= \held → when held retry)
              atomically (modifyTVar' written (message :))
          env' = env {seSpec = (seSpec env) {sxLogger = logger}}
      handle ← newEmptyMVar
      _ ← forkIO $ do
        session ← readMVar handle
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        -- the driver is in the sink: it is cancelled there
        throwTo self ThreadKilled
        -- the owners are stopped by the unwinding while the sink is still blocked, so the diagnostic cannot have been
        -- retried before the cancellation propagated
        pumpUntil world ((\out → "shutdown gameplay stopped" `elem` out && "shutdown presentation stopped" `elem` out) <$> outLines world)
        atomically (writeTVar blocked False)
      result ← try (runSession (scenarioSpec env' noHarness) (putMVar handle))
      case result of
        Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the cancellation was lost"
      messages ← readTVarIO written
      length (filter (== "start gate opened") messages) `shouldBe` 1

  it "gives up a stop effect that keeps failing after recording it once, and goes on" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (StopHandoff Gameplay) (toException (userError "the gameplay stop failed"))
      failAt recorder (StopHandoff Presentation) (toException (userError "the presentation stop failed"))
      self ← myThreadId
      handle ← newEmptyMVar
      done ← newEmptyMVar
      _ ← forkIO $ do
        session ← readMVar handle
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        -- every attempt to ask an owner to stop fails: each is recorded and given up, not retried without end
        void (try @SomeException (requestStop session StopQuit))
        putMVar done ()
        void (awaitOutcome session (\found → length [entry | entry ← entriesOf found, Text.isInfixOf "could not be asked to stop" (eeMessage entry)] >= 2))
        -- nothing can now stop the owners but the scope that leaves them: the calling thread is cancelled
        throwTo self ThreadKilled
      result ← try (runSession (scenarioSpec env (recordingHarness recorder noHarness)) (putMVar handle))
      case result of
        Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the cancellation was lost"
      bounded (takeMVar done)
      session ← readMVar handle
      found ← atomically (sessionOutcomeNow session)
      length [entry | entry ← entriesOf found, Text.isInfixOf "could not be asked to stop" (eeMessage entry)] `shouldBe` 2

  it "commits a composition failure and every cleanup failure attached to it whole, and publishes the retirements, before an interruption of its diagnostic is raised" $
    withSetup (setup (roleScript printScript)) $ \env → do
      interrupted ← newTVarIO False
      let logger =
            mkLogger defaultLogFilter . callbackSink $ \entry →
              when (entryMessage entry == "session engine failure") $ do
                already ← readTVarIO interrupted
                when (not already) $ do
                  atomically (writeTVar interrupted True)
                  throwIO ThreadKilled
          env' = env {seSpec = (seSpec env) {sxLogger = logger}}
      recorder ← newRecorder
      failAt recorder (Built Presentation BuildOwner) (toException (userError "construction failed"))
      failAt recorder (Released Gameplay BuildFacade) (toException (userError "the gameplay facade's release failed"))
      failAt recorder (Released Presentation BuildCoordinator) (toException (userError "the presentation coordinator's release failed"))
      handle ← newEmptyMVar
      result ← try (runSession (scenarioSpec env' (recordingHarness recorder noHarness)) (putMVar handle))
      case result of
        Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the interruption of the diagnostic was lost"
      session ← readMVar handle
      status ← statusNow session
      -- the retirements were published before the interruption was raised
      phasesOf status `shouldBe` (Just Retired, Just Retired)
      found ← atomically (sessionOutcomeNow session)
      -- and the primary and both attached release failures are in the report, committed together
      reportAccountedOf found `shouldBe` 3
      map eeMessage (entriesOf found) `shouldSatisfy` any (Text.isInfixOf "the gameplay facade's release failed")
      map eeMessage (entriesOf found) `shouldSatisfy` any (Text.isInfixOf "the presentation coordinator's release failed")

-- The facts a commit proves ------------------------------------------------------------------------------------------

facts ∷ Spec
facts = describe "the facts a commit carries" $ do
  it "latches an instance's failure once when the thread told of it is interrupted right after the commit: the marker is part of the commit" $ do
    _ ←
      withSetup (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'gameplay' then error('boom') end"]})) {suShape = GameplayAlone} $ \env → do
        let world = seWorld env
        recorder ← newRecorder
        failAt recorder (Committed "InstanceFailing") (toException ThreadKilled)
        outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          nudge world 1000000
          void (awaitRetired session)
        fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]
        -- the failure is in the report once: the settlement that follows adds nothing new
        length [entry | entry ← entriesOf outcome, Text.isInfixOf "boom" (eeMessage entry)] `shouldBe` 1
    pure ()

  it "records an init success a settlement proves without a clock when the session is cancelled and the clock fails" $
    withSetup ((setup (roleScript printScript {scUpdate = ["error('the first refresh fails')"]})) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      broken ← newTVarIO False
      let source =
            scriptedSource $ do
              dead ← readTVarIO broken
              when dead (throwIO (userError "the clock failed"))
              readInstant (worldClock world)
          env' = env {seSpec = (seSpec env) {sxClock = source}}
      recorder ← newRecorder
      holdAt recorder (Resumed (InstanceKey Presentation 0))
      self ← myThreadId
      handle ← newEmptyMVar
      _ ← forkIO $ do
        session ← readMVar handle
        awaitPoint recorder (Resumed (InstanceKey Presentation 0))
        pumpUntil world (elem "init presentation" <$> outLines world)
        awaitRegistration world 1000000
        passTime world 1000000000 (maybe False roleFailed . presentationOf <$> statusNow session)
        -- from here every reading of the clock fails, while the session is torn down
        atomically (writeTVar broken True)
        throwTo self ThreadKilled
      result ← try (runSession (scenarioSpec env' (recordingHarness recorder noHarness)) (putMVar handle))
      case result of
        Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the cancellation was lost"
      session ← readMVar handle
      status ← statusNow session
      fmap roleInitialized (presentationOf status) `shouldBe` Just True
      fmap rolePhase (presentationOf status) `shouldBe` Just Retired

-- | Block until the outcome the session holds satisfies this.
awaitOutcome ∷ Session → (SessionOutcome → Bool) → IO SessionOutcome
awaitOutcome session wanted = bounded . atomically $ do
  found ← sessionOutcomeNow session
  if wanted found then pure found else retry

reportAccountedOf ∷ SessionOutcome → Int
reportAccountedOf found = length (entriesOf found) + erOmitted (outEngine found)
