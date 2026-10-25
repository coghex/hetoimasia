{-# LANGUAGE OverloadedStrings #-}

-- | The session's one commit and the effects it owes. Every event is committed by one masked, non-retrying primitive:
-- the state, the markers, the evidence by the identities it had and the historical facts the event means change in one
-- transaction, together with the stops and the diagnostics it owes, which the state carries to whoever pays them. A
-- recovery or a cancellation path only commits: it writes no diagnostic, tells no probe inside the commit, and a probe
-- beside it that fails or blocks cannot keep the next mandatory step from running.
--
-- These examples hold or cancel the committer at each boundary (just after the commit, between steps, inside an
-- effect) and check that nothing the event meant is lost, half applied or done twice. Each has a control that removes
-- the protection it proves, through the private harness, and shows the proof detects its absence.
module Test.LuaEngine.Session.Commit (spec) where

import Control.Concurrent (forkIO, myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, fromException, onException, throwIO, toException, try)
import Control.Exception.Context (emptyExceptionContext)
import Control.Monad (void, when)
import Data.List (isInfixOf, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, composeCleanup, displayCleanupFailure)
import Hetoimasia.Foundation.Time (readInstant, scriptedSource)
import Test.Hspec
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "the one commit" $ do
  bundles
  boundaries
  effects
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

closeFailures ∷ SessionOutcome → Int
closeFailures found = length [entry | entry ← entriesOf found, eeCode entry == CleanupFailure, Text.isInfixOf "close failed" (eeMessage entry)]

reportAccountedOf ∷ SessionOutcome → Int
reportAccountedOf found = length (entriesOf found) + erOmitted (outEngine found)

-- | A harness that records, with these protections removed.
recording ∷ Recorder → [Protection] → Harness
recording recorder removedProtections = (recordingHarness recorder noHarness) {harnessRemoved = removedProtections}

-- One bundle, whole ---------------------------------------------------------------------------------------------------

-- | Run a gameplay-only session whose owner retires with a failing close, stop it, and look at the session where the
-- driver is held: right after the commit of the owner's end (or, with the bundle removed, of its claim).
atBoundary ∷ [Protection] → Point → (Session → IO ()) → IO ()
atBoundary removedProtections point look = do
  _ ←
    fatalSetup (setup (roleScript suspending)) {suShape = GameplayAlone} $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder point
      void . runCaught env (recording recorder removedProtections) $ \_ session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        passTime world 1000000 ((>= 1) . length . filter (Text.isPrefixOf "suspended") <$> outLines world)
        requestStop session StopQuit
        awaitPoint recorder point
        look session
        releaseHold recorder point
  pure ()

bundles ∷ Spec
bundles = describe "an owner's end, its evidence and the facts its settlements prove" $ do
  it "are committed together: at the boundary after the commit the claim, the cleanup it retained and the init it proves are all there" $
    atBoundary [] (Committed "OwnerFinalized") $ \session → do
      found ← outcomeNow session
      -- the retained cleanup is in the report (once), and the history already holds the instance's settlement
      closeFailures found `shouldBe` 1
      history ← historyNow session
      Map.size (historyFacts history) `shouldBe` 1
      status ← statusNow session
      fmap roleInitialized (gameplayOf status) `shouldBe` Just True
      -- the owner has been asked to stop, and its completion is accounted: nothing is owed it
      historyStopped history `shouldBe` [Gameplay]

  describe "with the bundle removed (a negative control)" $
    it "leaves the claim without its evidence and its facts at the boundary, which the proof above detects" $
      atBoundary [ProtectBundle] (Committed "OwnerClaimed") $ \session → do
        found ← outcomeNow session
        -- the claim is committed, and neither the cleanup nor the init it should have carried is
        closeFailures found `shouldBe` 0
        history ← historyNow session
        Map.null (historyFacts history) `shouldBe` True

  it "commits a failure of the composition and every cleanup failure attached to it together, and counts them once however many scopes it leaves" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      -- the injected exception carries two cleanup failures of its own
      cause ←
        composeCleanup
          (Just (caught "construction failed"))
          [("first release", caught "the first release failed"), ("second release", caught "the second release failed")]
      maybe (pure ()) (failWith recorder (Built Presentation BuildOwner)) cause
      holdAt recorder (Committed "Account")
      (ended, session) ← runCaught env (recording recorder []) $ \_ session → do
        awaitPoint recorder (Committed "Account")
        -- right after the commit the primary and both cleanup failures are accounted, whole, and the session is closed
        found ← outcomeNow session
        reportAccountedOf found `shouldBe` 3
        outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "the first release failed")
        outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "the second release failed")
        status ← statusNow session
        statusStopping status `shouldBe` True
        releaseHold recorder (Committed "Account")
      raisedMessage ended `shouldSatisfy` Text.isInfixOf "construction failed"
      -- the exception left every scope between the owner and the caller, and none of them counted it again
      found ← outcomeNow session
      reportAccountedOf found `shouldBe` 3
  where
    caught message = ExceptionWithContext emptyExceptionContext (toException (userError message))

-- Cancellation at each boundary -------------------------------------------------------------------------------------------

boundaries ∷ Spec
boundaries = describe "at each boundary between a commit and its effects" $ do
  it "leaves a stop owed when the thread that committed it is cancelled right after the commit, and the driver pays it" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Committed "Stop")
      outcome ← runScenarioWith env (recording recorder []) $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        stopper ← forkIO (requestStop session StopQuit)
        awaitPoint recorder (Committed "Stop")
        throwTo stopper ThreadKilled
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
        (ended, session) ← runCaught env (recording recorder []) $ \driver session → do
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          passTime world 1000000 ((>= 1) . length . filter (Text.isPrefixOf "suspended") <$> outLines world)
          requestStop session StopQuit
          -- the owner ended and its end was committed whole: the thread that committed it is cancelled right there
          awaitPoint recorder (Committed "OwnerFinalized")
          throwTo driver ThreadKilled
          void (awaitStatus session statusStopping)
          releaseHold recorder (Committed "OwnerFinalized")
        case ended of
          Left (ExceptionWithContext attached raised) → do
            fromException raised `shouldBe` Just ThreadKilled
            map displayCleanupFailure (cleanupFailuresInContext attached) `shouldSatisfy` any ("close failed" `isInfixOf`)
          Right _ → expectationFailure "the cancellation was lost"
        found ← outcomeNow session
        -- the retained cleanup is in the report once, whichever thread committed the end first
        closeFailures found `shouldBe` 1
        status ← statusNow session
        fmap rolePhase (gameplayOf status) `shouldBe` Just Retired
    pure ()

-- Effects are not recursive and not retried ---------------------------------------------------------------------------------

effects ∷ Spec
effects = describe "the effects a commit owes" $ do
  it "asks a sink that raises once for each diagnostic, accounts each failure once, and still stops, drains and retires" $
    withSetup (setup (roleScript printScript)) $ \env → do
      attempts ← newTVarIO ([] ∷ [Text'])
      -- the first diagnostic is written; every one after it raises, for good
      let sink entry = do
            atomically (modifyTVar' attempts (entryMessage entry :))
            when (entryMessage entry /= "session starting") (throwIO (userError "the sink failed"))
          env' = env {seSpec = (seSpec env) {sxLogger = mkLogger defaultLogFilter (callbackSink sink)}}
      outcome ← runScenario env' $ \session → void (awaitRetired session)
      seen ← reverse <$> readTVarIO attempts
      -- each diagnostic was attempted once: none was retried, and a failure to write one made no diagnostic of its own
      seen `shouldBe` nub seen
      length [entry | entry ← entriesOf outcome, Text.isInfixOf "a diagnostic could not be written" (eeMessage entry)] `shouldBe` length seen - 1
      outRetired outcome `shouldBe` True
      outVerdict outcome `shouldBe` VerdictFailure

  it "does not recurse or repeat a boundary probe that fails every time, or let it keep the owners from stopping or the roles from retiring" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Committed "OwnerFinalized") (toException (userError "the probe failed"))
      failAt recorder (Committed "RoleRetired") (toException (userError "the probe failed"))
      (ended, session) ← runCaught env (recording recorder []) $ \driver session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        throwTo driver ThreadKilled
        void (awaitStatus session retiredBoth)
      -- the cancellation is what is raised; the probe's failures are accounted beside it
      raisedKilled ended `shouldBe` True
      points ← recorded recorder
      -- one boundary for each commit: none was told again to retry the cleanup it observed
      length [() | Committed "OwnerFinalized" ← points] `shouldBe` 2
      length [() | Committed "RoleRetired" ← points] `shouldBe` 2
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      out `shouldSatisfy` elem "shutdown presentation stopped"
      found ← outcomeNow session
      outRetired found `shouldBe` True
      length [entry | entry ← entriesOf found, Text.isInfixOf "the probe failed" (eeMessage entry)] `shouldBe` 4

  it "does not write a diagnostic again when the caller is cancelled while the writer holds it: the data stays in flight, and the cleanup runs meanwhile" $
    withSetup (setup (roleScript printScript)) $ \env → do
      attempts ← newTVarIO (0 ∷ Int)
      blocked ← newTVarIO True
      let logger =
            mkLogger defaultLogFilter . callbackSink $ \entry →
              when (entryMessage entry == "start gate opened") $ do
                atomically (modifyTVar' attempts (+ 1))
                atomically (readTVar blocked >>= \held → when held retry)
          env' = env {seSpec = (seSpec env) {sxLogger = logger}}
      (ended, session) ← runCaught env' noHarness $ \driver session → (`onException` atomically (writeTVar blocked False)) $ do
        -- the writer is in the sink: the caller is cancelled while it is
        bounded (atomically (readTVar attempts >>= \n → when (n == 0) retry))
        throwTo driver ThreadKilled
        -- the owners are stopped and retired by the unwinding while the sink is still blocked
        void (awaitRetired session)
        history ← historyNow session
        historyDiagnostics history `shouldSatisfy` elem ("start gate opened", DiagInFlight)
      raisedKilled ended `shouldBe` True
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      -- the call returned with the sink still blocked; the writer finishes the one write by itself
      readTVarIO blocked `shouldReturn` True
      atomically (writeTVar blocked False)
      bounded . atomically $ do
        found ← sessionHistory session
        when ("start gate opened" `elem` map fst (historyDiagnostics found)) retry
      readTVarIO attempts `shouldReturn` 1

  describe "with the recovery path allowed to write (a negative control)" $
    it "writes the diagnostic of the closure before any owner has its stop, which the proof above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        entered ← newTVarIO False
        blocked ← newTVarIO True
        let logger =
              mkLogger defaultLogFilter . callbackSink $ \entry →
                when (entryMessage entry == "session stopping") $ do
                  atomically (writeTVar entered True)
                  atomically (readTVar blocked >>= \held → when held retry)
            env' = env {seSpec = (seSpec env) {sxLogger = logger}}
        (ended, _) ← runCaught env' noHarness {harnessRemoved = [ProtectRecovery]} $ \driver session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          throwTo driver ThreadKilled
          -- the recovery path is in the sink for the diagnostic of the closure: no owner has been asked to stop
          bounded (atomically (readTVar entered >>= \seen → when (not seen) retry))
          history ← historyNow session
          historyStopped history `shouldBe` []
          atomically (writeTVar blocked False)
        raisedKilled ended `shouldBe` True

-- The facts a commit carries ------------------------------------------------------------------------------------------

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

-- | The messages a sink was asked to write.
type Text' = Text.Text
