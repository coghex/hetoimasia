{-# LANGUAGE OverloadedStrings #-}

-- | A session whose construction fails or is cancelled part of the way: every component acquired is registered with
-- the lifecycle record in the step that acquires it, so every constructed owner is found and stopped, every
-- registered release runs once and none runs for a component that was never acquired; the failure that stopped it is
-- the one the session raises and the outcome's, and a release that fails too is kept beside it.
--
-- The failures are injected at the harness's points, which name the steps; what they exercise is real: the owners
-- started, the scopes unwound, the workers waited for.
module Test.LuaEngine.Session.Construction (spec) where

import Control.Concurrent (forkIO, myThreadId, throwTo)
import Control.Concurrent.MVar (isEmptyMVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, throwIO, toException, try)
import Control.Monad (forM_, void, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), callbackSink, defaultLogFilter, mkLogger)
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, openGate)
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "construction" $ do
  it "releases every built it made exactly once, and makes the failure that stopped it the outcome's" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Built Presentation BuildFacade) (toException (userError "construction failed"))
      (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \_ session → void (awaitRetired session)
      released ← releasedSteps recorder
      -- the owner of the first role was running and is stopped and awaited; the second role got as far as its facade
      released `shouldBe` sort [(Gameplay, built) | built ← [BuildCoordinator, BuildData, BuildFacade, BuildOwner]] <> sort [(Presentation, built) | built ← [BuildCoordinator, BuildData, BuildFacade]]
      out ← outLines (seWorld env)
      out `shouldBe` []
      -- the failure that stopped construction is what the call raised, and the outcome's
      raisedMessage ended `shouldSatisfy` Text.isInfixOf "construction failed"
      outcome ← outcomeNow session
      outVerdict outcome `shouldBe` VerdictFailure
      outRetired outcome `shouldBe` True
      fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
      fmap (Text.isInfixOf "construction failed" . eeMessage) (erPrimary (outEngine outcome)) `shouldBe` Just True

  it "keeps the failures of releases beside the failure that stopped construction, and releases the rest regardless" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Built Presentation BuildOwner) (toException (userError "construction failed"))
      failAt recorder (Released (ReleaseBuild Gameplay BuildFacade)) (toException (userError "the gameplay facade's release failed"))
      failAt recorder (Released (ReleaseBuild Presentation BuildCoordinator)) (toException (userError "the presentation coordinator's release failed"))
      (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \_ session → void (awaitStatus session statusStopping)
      released ← releasedSteps recorder
      -- every release was attempted once, whatever the others did
      released `shouldBe` sort [(role, built) | role ← [Gameplay, Presentation], built ← [BuildCoordinator, BuildData, BuildFacade, BuildOwner]]
      raisedMessage ended `shouldSatisfy` Text.isInfixOf "construction failed"
      outcome ← outcomeNow session
      outVerdict outcome `shouldBe` VerdictFailure
      let report = outEngine outcome
      fmap eeMessage (erPrimary report) `shouldSatisfy` maybe False (Text.isInfixOf "construction failed")
      messages (erSecondary report) `shouldSatisfy` any (Text.isInfixOf "the gameplay facade's release failed")
      messages (erSecondary report) `shouldSatisfy` any (Text.isInfixOf "the presentation coordinator's release failed")
      mapM_ (\entry → eeCode entry `shouldBe` CleanupFailure) (erSecondary report)
      reportAccounted report `shouldBe` 3
      -- a release that failed does not prove its role retired: both roles hold a failed release, and neither is published
      status ← statusNow session
      phasesOf status `shouldBe` (Just Stopping, Just Stopping)
      outRetired outcome `shouldBe` False

  it "refuses a second instance of a role the session does not have, before any Lua" $
    withSetup ((setup (roleScript printScript)) {suShape = GameplayAlone, suHarness = noHarness {harnessSecond = [Presentation]}}) $ \env → do
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines (seWorld env)
      out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictFailure
      fmap eeRole (erPrimary (outEngine outcome)) `shouldBe` Just (Just Presentation)

  it "retires nothing early: a role is retired only after its owner has ended and everything it borrowed was released" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      void . runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitRetired session)
      points ← recorded recorder
      -- each owner ended before its built was released
      mapM_
        ( \role → do
            let ended = indexOf (OwnerEnded role) points
                released = indexOf (Released (ReleaseBuild role BuildOwner)) points
            (ended, released) `shouldSatisfy` (\(a, b) → maybe False id ((<) <$> a <*> b))
        )
        [Gameplay, Presentation]
  cancellation
  drainage
  acquisition
  abandonedStarts
  intents
  registrations
  callbacks
  drainProof
  where
    messages = map eeMessage
    indexOf point points = lookup point (zip points [0 ∷ Int ..])

-- | The steps the session released, sorted, one entry for each release.
releasedSteps ∷ Recorder → IO [(Role, BuildStep)]
releasedSteps recorder = sort . (\points → [(role, built) | Released (ReleaseBuild role built) ← points]) <$> recorded recorder

-- | The session's thread is cancelled while it is parked at a point: everything built is released exactly once,
-- every owner has ended before its step is released, and the cancellation is the exception that comes out.
cancellation ∷ Spec
cancellation = describe "cancellation of the calling thread" $
  mapM_
    ( \(name, point, dispatched) →
        it ("releases everything exactly once when it lands " <> name) $
          withSetup (setup (roleScript printScript)) $ \env → do
            recorder ← newRecorder
            holdAt recorder point
            self ← myThreadId
            handle ← newEmptyMVar
            _ ← forkIO $ do
              session ← readMVar handle
              awaitPoint recorder point
              throwTo self ThreadKilled
              -- the unwinding closes the gates; only then is a point on an owner's thread let go, which that owner
              -- needs in order to end
              void (awaitStatus session (\status → statusStopping status))
              releaseHold recorder point
            result ← try (runSession (scenarioSpec env (recordingHarness recorder (sxHarness (seSpec env)))) (putMVar handle))
            case result of
              Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
              Right _ → expectationFailure "the cancellation was lost"
            points ← recorded recorder
            -- each owner that was built ended before its step was released, and every built step was released once
            let built = [(role, built') | Built role built' ← points]
                releasedOnce = sort [(role, released) | Released (ReleaseBuild role released) ← points]
            releasedOnce `shouldBe` sort built
            out ← outLines (seWorld env)
            -- before the gate opened no root ran; once it had, the inits that were dispatched ran and were shut down,
            -- and no tick was ever granted
            if dispatched
              then out `shouldSatisfy` all (not . Text.isPrefixOf "update")
              else out `shouldBe` []
    )
    [ ("between the intent and the issuance of an admission", Intended (InstanceKey Gameplay 0), False)
    , ("after an admission was accepted and before it was tracked", Issued (InstanceKey Gameplay 0), False)
    , ("while an owner is parked at the dispatch gate", Validating (InstanceKey Presentation 0), False)
    , ("while an owner is dispatched and its init is about to begin", Dispatched (InstanceKey Gameplay 0), True)
    ]

-- Leaving the session by an exception --------------------------------------------------------------------------------------------

drainage ∷ Spec
drainage = describe "the coordinator's drainage on an exceptional exit" $
  it "does not publish a role as retired, or return, while a read its coordinator started is still held" $
    withSetup ((setup (roleScript printScript)) {suShape = GameplayAlone}) $ \env → do
      recorder ← newRecorder
      let path = "lua/main.lua"
      closeGate (ssProbeOf env) path
      self ← myThreadId
      handle ← newEmptyMVar
      observed ← newEmptyMVar
      released ← newEmptyMVar
      _ ← forkIO $ do
        session ← readMVar handle
        awaitReadOf env path
        throwTo self ThreadKilled
        -- the unwinding has ended the owner and is waiting for the held read: the role is still not retired
        awaitPoint recorder (Draining Gameplay)
        status ← statusNow session
        putMVar observed (fmap rolePhase (gameplayOf status))
        putMVar released ()
        openGate (ssProbeOf env) path
      result ← try (runSession (scenarioSpec env (recordingHarness recorder (sxHarness (seSpec env)))) (putMVar handle))
      case result of
        Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the cancellation was lost"
      -- the call did not return until the read had been let go
      isEmptyMVar released `shouldReturn` False
      takeMVar observed `shouldReturn` Just Stopping
      session ← readMVar handle
      status ← statusNow session
      fmap rolePhase (gameplayOf status) `shouldBe` Just Retired

-- Failing or cancelling at every step of the acquisition ------------------------------------------------------------------------

-- | The order the components of the two roles are acquired in.
buildOrder ∷ [(Role, BuildStep)]
buildOrder = [(role, built) | role ← [Gameplay, Presentation], built ← [minBound .. maxBound]]

-- | The components that are registered when the session leaves at this point: those acquired before it, and, at a point
-- reached after an acquisition, that one too, because it is registered in the step that acquires it, before any probe.
registeredAt ∷ Point → [(Role, BuildStep)]
registeredAt = \case
  Acquiring role built → takeWhile (/= (role, built)) buildOrder
  Built role built → takeWhile (/= (role, built)) buildOrder <> [(role, built)]
  _ → []

acquisition ∷ Spec
acquisition = describe "failing or cancelled at each step of the acquisition" $
  forM_ [point | (role, built) ← buildOrder, point ← [Acquiring role built, Built role built]] $ \point → do
    it ("finds, stops and releases exactly what was acquired when the driver throws at " <> show point) $
      withSetup (setup (roleScript printScript)) $ \env → do
        recorder ← newRecorder
        failAt recorder point (toException (userError "construction failed"))
        (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \_ session → void (awaitStatus session statusStopping)
        raisedMessage ended `shouldSatisfy` Text.isInfixOf "construction failed"
        afterwards env recorder session point
        outcome ← outcomeNow session
        outVerdict outcome `shouldBe` VerdictFailure
        fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
    it ("finds, stops and releases exactly what was acquired when the driver is cancelled at " <> show point) $
      withSetup (setup (roleScript printScript)) $ \env → do
        recorder ← newRecorder
        holdAt recorder point
        (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \driver _ → do
          awaitPoint recorder point
          throwTo driver ThreadKilled
        raisedKilled ended `shouldBe` True
        afterwards env recorder session point
        -- a cancellation is not a failure of the engine
        outcome ← outcomeNow session
        outVerdict outcome `shouldBe` VerdictSuccess
        outFailures outcome `shouldBe` []
        erPrimary (outEngine outcome) `shouldBe` Nothing
  where
    afterwards env recorder session point = do
      -- what was registered was released once and nothing else was
      points ← recorded recorder
      sort [(role, built) | Released (ReleaseBuild role built) ← points] `shouldBe` sort (registeredAt point)
      history ← historyNow session
      -- every constructed owner was asked to stop; no owner that was never constructed was
      historyStopped history `shouldBe` [role | role ← [Gameplay, Presentation], (role, BuildOwner) `elem` registeredAt point]
      -- nothing authored ran, and no instance was admitted whose settlement is missing
      outLines (seWorld env) >>= (`shouldBe` [])
      Map.null (historyFacts history) `shouldBe` True
      status ← statusNow session
      retiredBoth status `shouldBe` True

-- A start that is abandoned ----------------------------------------------------------------------------------------------------

abandonedStarts ∷ Spec
abandonedStarts = describe "a start that is abandoned part way" $ do
  it "hands every registered peer its stop from inside the abandonment, before the starter waits for its worker to end" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      -- the presentation owner's start is held in its readiness wait, inside the authored output
      holdSink world "held start"
      holdAt recorder (StartAbandoned Presentation)
      let harness = (recordingHarness recorder noHarness) {harnessStartChunk = [(Presentation, "print('held start')")]}
      (ended, session) ← runCaught env harness $ \driver session → do
        awaitSinkEntered world "held start"
        throwTo driver ThreadKilled
        -- the starter is in its hook, which runs before it begins to wait for the held worker: the peer has its stop
        awaitPoint recorder (StartAbandoned Presentation)
        found ← historyNow session
        historyStopped found `shouldBe` [Gameplay]
        status ← statusNow session
        statusStopping status `shouldBe` True
        -- a stop requested concurrently with the hook finds the pass done and changes nothing: repeating it is harmless
        requestStop session StopQuit
        again ← historyNow session
        historyStopped again `shouldBe` [Gameplay]
        releaseHold recorder (StartAbandoned Presentation)
        releaseSink world
      raisedKilled ended `shouldBe` True
      outcome ← outcomeNow session
      outRetired outcome `shouldBe` True

  it "accounts a failure of the abandonment's own point as a failure of the host, once, and does not displace the cancellation that abandoned the start" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdSink world "held start"
      failAt recorder (StartAbandoned Presentation) (toException (userError "the point failed"))
      let harness = (recordingHarness recorder noHarness) {harnessStartChunk = [(Presentation, "print('held start')")]}
      (ended, session) ← runCaught env harness $ \driver _ → do
        awaitSinkEntered world "held start"
        throwTo driver ThreadKilled
        awaitBlockedOnSTM driver
        releaseSink world
      raisedKilled ended `shouldBe` True
      outcome ← outcomeNow session
      length [message | message ← outcomeMessages outcome, Text.isInfixOf "the point failed" message] `shouldBe` 1
      fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
      outRetired outcome `shouldBe` True

  describe "with the abandonment not told (a negative control)" $
    it "leaves the peer unstopped for as long as the starter waits for its held worker, which the proof above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        let world = seWorld env
        recorder ← newRecorder
        holdSink world "held start"
        let harness = (recordingHarness recorder noHarness) {harnessStartChunk = [(Presentation, "print('held start')")], harnessRemoved = [ProtectStartAbandon]}
        (ended, session) ← runCaught env harness $ \driver session → do
          awaitSinkEntered world "held start"
          throwTo driver ThreadKilled
          -- the starter has stopped its worker and waits for it, held in the output: nobody has stopped the peer
          awaitBlockedOnSTM driver
          found ← historyNow session
          historyStopped found `shouldBe` []
          points ← recorded recorder
          [() | StartAbandoned _ ← points] `shouldBe` []
          releaseSink world
        raisedKilled ended `shouldBe` True
        -- the guard around the start stops the peer once the starter returns, so the session still ends
        outcome ← outcomeNow session
        outRetired outcome `shouldBe` True

-- The intent of an admission, from its commit ----------------------------------------------------------------------------------

intents ∷ Spec
intents = describe "the intent of an admission" $ do
  it "is resolved, and every role retires, when the probe beside its commit throws" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Committed "Intend") (toException (userError "the probe failed"))
      (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \_ session → void (awaitStatus session statusStopping)
      raisedMessage ended `shouldSatisfy` Text.isInfixOf "the probe failed"
      outcome ← outcomeNow session
      outRetired outcome `shouldBe` True
      history ← historyNow session
      Map.null (historyFacts history) `shouldBe` True

  it "is resolved, and every role retires, when the driver is cancelled right after its commit" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      holdAt recorder (Committed "Intend")
      (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \driver _ → do
        awaitPoint recorder (Committed "Intend")
        throwTo driver ThreadKilled
      raisedKilled ended `shouldBe` True
      outcome ← outcomeNow session
      outRetired outcome `shouldBe` True
      outVerdict outcome `shouldBe` VerdictSuccess

  it "is resolved when the probe beside the second role's intent throws, with the first role's root already tracked" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      -- the second Intend: let the first through by failing only once the gameplay root is tracked
      holdAt recorder (Tracking (InstanceKey Gameplay 0))
      (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \_ session → do
        awaitPoint recorder (Tracking (InstanceKey Gameplay 0))
        failAt recorder (Committed "Intend") (toException (userError "the second probe failed"))
        releaseHold recorder (Tracking (InstanceKey Gameplay 0))
        void (awaitStatus session statusStopping)
      raisedMessage ended `shouldSatisfy` Text.isInfixOf "the second probe failed"
      outcome ← outcomeNow session
      outRetired outcome `shouldBe` True

-- | A harness that records, with this protection removed, and tells where the owners can be stopped from outside.
registrationControl ∷ Recorder → TVar (Map.Map Role OwnerHandles) → Harness
registrationControl recorder handles =
  (recordingHarness recorder noHarness)
    { harnessRemoved = [ProtectRegistration]
    , harnessOwner = \role found → atomically (modifyTVar' handles (Map.insert role found))
    }

registrations ∷ Spec
registrations = describe "an owner is registered in the step that starts it" $ do
  it "finds and stops the owner of a role whose construction then fails at the first thing after the start" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Built Presentation BuildOwner) (toException (userError "construction failed"))
      (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \_ session → void (awaitStatus session statusStopping)
      raisedMessage ended `shouldSatisfy` Text.isInfixOf "construction failed"
      history ← historyNow session
      historyStopped history `shouldBe` [Gameplay, Presentation]

  describe "with the registration put after the probe (a negative control)" $
    it "never finds the owner that outlived its failure, which the proof above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        recorder ← newRecorder
        handles ← newTVarIO Map.empty
        failAt recorder (Built Presentation BuildOwner) (toException (userError "construction failed"))
        (ended, session) ← runCaught env (registrationControl recorder handles) $ \_ session → void (awaitStatus session statusStopping)
        raisedMessage ended `shouldSatisfy` Text.isInfixOf "construction failed"
        history ← historyNow session
        -- the presentation owner was started and nobody knows it: it is not stopped, and not released
        historyStopped history `shouldBe` [Gameplay]
        points ← recorded recorder
        [() | Released (ReleaseBuild Presentation BuildOwner) ← points] `shouldBe` []
        -- the example stops the owner it leaked, from outside, as its supervisor would, so that nothing outlives it
        found ← readTVarIO handles
        maybe (expectationFailure "the owner was not told to the harness") ownerStop (Map.lookup Presentation found)

-- The callbacks of the caller ---------------------------------------------------------------------------------------------------------

callbacks ∷ Spec
callbacks = describe "the callback and the first diagnostic" $ do
  it "accounts a callback that throws, closes the session and raises what it threw, with every role retired" $
    withSetup (setup (roleScript printScript)) $ \env → do
      handle ← newIORef Nothing
      result ← try (runSession (scenarioSpec env noHarness) (\session → writeIORef handle (Just session) >> throwIO (userError "the callback failed")))
      case result of
        Left (raised ∷ SomeException) → show raised `shouldSatisfy` Text.isInfixOf "the callback failed" . Text.pack
        Right _ → expectationFailure "the callback's failure was lost"
      Just session ← readIORef handle
      outcome ← outcomeNow session
      outVerdict outcome `shouldBe` VerdictFailure
      outcomeMessages outcome `shouldSatisfy` any (Text.isInfixOf "the callback failed")
      -- a failure before any role exists still reaches the record the caller holds
      status ← statusNow session
      retiredBoth status `shouldBe` True
      statusStopping status `shouldBe` True

  it "raises a cancellation that lands in the callback as itself, without inventing a failure" $
    withSetup (setup (roleScript printScript)) $ \env → do
      handle ← newEmptyMVar
      driver ← myThreadId
      _ ← forkIO (readMVar handle >> throwTo driver ThreadKilled)
      result ← try (runSession (scenarioSpec env noHarness) (\session → putMVar handle session >> blockForever))
      case result of
        Left (raised ∷ SomeException) → fromException raised `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the cancellation was lost"
      session ← readMVar handle
      outcome ← outcomeNow session
      outVerdict outcome `shouldBe` VerdictSuccess
      erPrimary (outEngine outcome) `shouldBe` Nothing
      status ← statusNow session
      retiredBoth status `shouldBe` True

  it "accounts a sink that fails for the first diagnostic as a failure of the engine, and builds nothing" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      let logger =
            mkLogger defaultLogFilter . callbackSink $ \entry →
              when (entryMessage entry == "session starting") (throwIO (userError "the sink failed"))
          env' = env {seSpec = (seSpec env) {sxLogger = logger}}
      (ended, session) ← runCaught env' (recordingHarness recorder noHarness) $ \_ session → void (awaitStatus session statusStopping)
      -- the failure is accounted, not raised, and nothing was constructed
      ended `shouldSatisfy` either (const False) (const True)
      outcome ← outcomeNow session
      outVerdict outcome `shouldBe` VerdictFailure
      outcomeMessages outcome `shouldSatisfy` any (Text.isInfixOf "a diagnostic could not be written")
      points ← recorded recorder
      [point | point <- points, isBuilding point] `shouldBe` []

  it "keeps a first diagnostic that a cancellation interrupted as unfinished data, and does not retry it" $
    withSetup (setup (roleScript printScript)) $ \env → do
      blocked ← newTVarIO True
      written ← newTVarIO (0 ∷ Int)
      let logger =
            mkLogger defaultLogFilter . callbackSink $ \entry →
              when (entryMessage entry == "session starting") $ do
                atomically (modifyTVar' written (+ 1))
                atomically (readTVar blocked >>= \held → when held retry)
          env' = env {seSpec = (seSpec env) {sxLogger = logger}}
      handle ← newEmptyMVar
      driver ← myThreadId
      _ ← forkIO $ do
        session ← readMVar handle
        -- the driver is inside the sink: it is cancelled there
        bounded (atomically (readTVar written >>= \n → when (n == 0) retry))
        throwTo driver ThreadKilled
        void (awaitStatus session statusStopping)
        atomically (writeTVar blocked False)
      result ← try (runSession (scenarioSpec env' noHarness) (putMVar handle))
      case result of
        Left (raised ∷ SomeException) → fromException raised `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the cancellation was lost"
      session ← readMVar handle
      -- the sink was asked once, and the data stays in the queue, marked interrupted
      readTVarIO written `shouldReturn` 1
      found ← historyNow session
      historyDiagnostics found `shouldSatisfy` elem ("session starting", DiagInterrupted)
  where
    blockForever = atomically retry
    isBuilding = \case
      Acquiring {} → True
      Built {} → True
      _ → False

-- Draining before retirement ---------------------------------------------------------------------------------------------------------

drainProof ∷ Spec
drainProof = describe "retirement is published only after the drain is proved" $ do
  it "keeps a role unretired, and its releases unrun, while a data read its coordinator started is held, and finishes when the read is let go" $
    withSetup (addFile ("lua/slow.bin", "slow") ((setup (roleScript reading)) {suShape = GameplayAlone})) $ \env → do
      let probe = ssProbeOf env
      closeGate probe "lua/slow.bin"
      recorder ← newRecorder
      (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \driver session → do
        awaitPhase session Gameplay Running
        awaitReadOf env "lua/slow.bin"
        requestStop session StopQuit
        -- the driver has taken everything it can and is parked: the owner's end waits for the read the provider holds
        awaitBlockedOnSTM driver
        status ← statusNow session
        fmap rolePhase (gameplayOf status) `shouldBe` Just Stopping
        soFar ← recorded recorder
        [built | Released (ReleaseBuild Gameplay built) ← soFar] `shouldBe` []
        openGate probe "lua/slow.bin"
        void (awaitRetired session)
      ended `shouldSatisfy` either (const False) (const True)
      afterwards ← recorded recorder
      sort [built | Released (ReleaseBuild Gameplay built) ← afterwards] `shouldBe` [minBound .. maxBound]
      outcome ← outcomeNow session
      outRetired outcome `shouldBe` True
  where
    reading =
      printScript
        { scInit = ["self.read = api.content.data('lua/slow.bin')"]
        , scShutdown = []
        , scUpdate = []
        }
