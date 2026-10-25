{-# LANGUAGE OverloadedStrings #-}

-- | Diagnostics never gate the lifecycle (D-82/T4, as D-87 decides it). No step of the driver, no stop pass and no
-- step of the teardown calls the session's logger: a diagnostic is data in the lifecycle record, and a writer of the
-- session's own is the sink's only caller. Once every role has retired, a writer still in the sink is cancelled and
-- not waited for, and what it had not delivered is recorded in the outcome as evidence, never as the session's failure.
-- A sink that raises, or whose write is cancelled, is evidence of the same kind.
--
-- These examples hold the logger at each class of site, with a gate the example owns, and show that a stop is handed,
-- an owner's end accounted, its drain proven, its releases run and its retirement published, and that the call to
-- 'runSession' returns, while the logger stays held; the facts are read from the outcome the call returned, and the
-- gate is let go afterwards.
--
-- The classes are the first note of the session, the diagnostic of the start gate opening, the diagnostics of a failure
-- and of the closure, the final note, a sink that fails, and (beside them) the module coordinator's warning and the
-- authored output an owner's @print@ writes, both on the owner's own thread. Two negative controls remove a protection
-- through the private harness: the writer (the driver writes, as it did) and the abandonment (the call waits for the
-- writer, as it did).
module Test.LuaEngine.Session.Diagnostics (spec) where

import Control.Concurrent (forkIO, killThread, throwTo)
import Control.Concurrent.MVar (MVar, isEmptyMVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, finally, mask, onException, throwIO, try)
import Control.Monad (void, when)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), Logger, callbackSink, defaultLogFilter, mkLogger)
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, openEverything, openGate)
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "diagnostics" $ do
  classes
  failing
  controls

-- | A logger whose sink holds the write of each entry with one of these messages until it is let go, and then, if told
-- to, fails it.
data Held = Held
  { heldLogger ∷ !Logger
  , heldEntered ∷ !(TVar [Text])
  -- ^ The messages whose write has begun, newest first.
  , heldGate ∷ !(TVar Bool)
  , heldFails ∷ !(TVar Bool)
  }

holding ∷ [Text] → IO Held
holding messages = do
  entered ← newTVarIO []
  gate ← newTVarIO True
  fails ← newTVarIO False
  let sink entry = when (entryMessage entry `elem` messages) $ do
        atomically (modifyTVar' entered (entryMessage entry :))
        atomically (readTVar gate >>= \held → when held retry)
        failing' ← readTVarIO fails
        when failing' (throwIO (userError "the sink failed"))
  pure (Held (mkLogger defaultLogFilter (callbackSink sink)) entered gate fails)

-- | A logger whose sink fails the write of each entry with one of these messages, at once.
failingAt ∷ [Text] → IO Held
failingAt messages = do
  held ← holding messages
  atomically (writeTVar (heldGate held) False >> writeTVar (heldFails held) True)
  pure held

-- | The session with this logger.
loggedBy ∷ Held → SessionEnv → SessionEnv
loggedBy held env = env {seSpec = (seSpec env) {sxLogger = heldLogger held}}

-- | Block until the write of an entry with this message has begun: the sink is holding it.
awaitEntered ∷ Held → Text → IO ()
awaitEntered held message = bounded (atomically (readTVar (heldEntered held) >>= \seen → when (message `notElem` seen) retry))

timesEntered ∷ Held → Text → IO Int
timesEntered held message = length . filter (== message) <$> readTVarIO (heldEntered held)

letGo ∷ Held → IO ()
letGo held = atomically (writeTVar (heldGate held) False)

isHeld ∷ Held → IO Bool
isHeld = readTVarIO . heldGate

-- | Run a body, and let the sink go however it ends, so that a failing example fails instead of leaving a thread held.
whileHeld ∷ Held → IO a → IO a
whileHeld held body = body `finally` letGo held

-- | What a session returned, and whether its call has returned yet.
data Returning = Returning
  { awaitReturn ∷ IO SessionOutcome
  -- ^ Block until the call to 'runSession' has returned, and answer its outcome.
  , hasReturned ∷ IO Bool
  }

-- | Run the session on this thread and a scenario on another that is handed the session and a view of whether its call
-- has returned. A scenario that raises stops the session, and what it raises is raised here once the session has
-- ended; the held sinks are the example's to let go (an example that fails lets them go with 'whileHeld').
runHeld ∷ SessionEnv → Harness → (Session → Returning → IO ()) → IO SessionOutcome
runHeld env harness scenario = do
  handleVar ← newEmptyMVar
  returned ← newEmptyMVar ∷ IO (MVar SessionOutcome)
  resultVar ← newEmptyMVar
  terminated ← newEmptyMVar
  thread ← mask $ \restore →
    forkIO $
      ( do
          session ← readMVar handleVar
          result ← try (restore (scenario session (Returning (bounded (readMVar returned)) (not <$> isEmptyMVar returned))))
          case result of
            Left (failure ∷ SomeException) → requestStop session StopQuit >> putMVar resultVar (Left failure)
            Right () → putMVar resultVar (Right ())
          releaseSink (seWorld env)
          openEverything (wSession (seWorld env))
      )
        `finally` putMVar terminated ()
  outcome ← runSession (scenarioSpec env harness) (putMVar handleVar) `onException` (killThread thread >> takeMVar terminated)
  putMVar returned outcome
  result ← bounded (readMVar resultVar)
  takeMVar terminated
  either throwIO (const (pure outcome)) result

-- | The messages the outcome records as not delivered.
undelivered ∷ SessionOutcome → [Text]
undelivered = deUndeliveredFirst . outDiagnostics

-- | Whether the outcome's diagnostics evidence mentions this text, as a sink failure or as an undelivered diagnostic.
mentions ∷ Text → SessionOutcome → Bool
mentions text outcome = any (Text.isInfixOf text) (deSinkFirst (outDiagnostics outcome) <> undelivered outcome)

-- The classes of site ------------------------------------------------------------------------------------------------

classes ∷ Spec
classes = describe "with the logger held at" $ do
  it "the first note of the session: both roles are built, validated and started, a stop retires them, the call returns, and the note is recorded undelivered" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["session starting"]
      outcome ← runHeld (loggedBy held env) noHarness $ \session returning → whileHeld held $ do
        awaitEntered held "session starting"
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        found ← awaitReturn returning
        outRetired found `shouldBe` True
        isHeld held `shouldReturn` True
      outRetired outcome `shouldBe` True
      outVerdict outcome `shouldBe` VerdictSuccess
      undelivered outcome `shouldSatisfy` elem "session starting"
      deUndelivered (outDiagnostics outcome) `shouldSatisfy` (>= 2)
      timesEntered held "session starting" `shouldReturn` 1

  it "the diagnostic the start gate opened, with a stop from another thread (no cancellation): both stops handed, both owners' ends accounted, both roles retired, the call returned" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["start gate opened"]
      outcome ← runHeld (loggedBy held env) noHarness $ \session returning → whileHeld held $ do
        awaitEntered held "start gate opened"
        requestStop session StopQuit
        found ← awaitReturn returning
        outRetired found `shouldBe` True
        historyNow session >>= \history → historyStopped history `shouldBe` [Gameplay, Presentation]
        out ← outLines (seWorld env)
        out `shouldSatisfy` elem "shutdown gameplay stopped"
        out `shouldSatisfy` elem "shutdown presentation stopped"
        isHeld held `shouldReturn` True
      outVerdict outcome `shouldBe` VerdictSuccess
      -- what the sink was holding and what was queued behind it are recorded, by message, and none is lost silently
      undelivered outcome `shouldSatisfy` elem "start gate opened"
      undelivered outcome `shouldSatisfy` elem "session stopping"
      deUndelivered (outDiagnostics outcome) `shouldSatisfy` (>= 2)
      deSinkFailures (outDiagnostics outcome) `shouldBe` 0

  it "the diagnostic of a role's failure: the failure is latched, the owner stopped and retired, the call returns, and the failure is not hidden by the undelivered record" $
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error('boom')"]})) {suShape = GameplayAlone}) $ \env → do
      held ← holding ["role failed"]
      let world = seWorld env
      outcome ← runHeld (loggedBy held env) noHarness $ \session returning → whileHeld held $ do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        awaitEntered held "role failed"
        void (awaitReturn returning)
        isHeld held `shouldReturn` True
      outcome `shouldSatisfy` ((== VerdictFailure) . outVerdict)
      fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]
      outRetired outcome `shouldBe` True
      undelivered outcome `shouldSatisfy` elem "role failed"

  it "the diagnostic of an engine failure: the session ends, its roles retire, the call returns, and the engine failure stays the primary" $ do
    _ ←
      fatalSetup (setup (roleScript printScript {scPrelude = ["print('load')"]})) $ \env → do
        let world = seWorld env
        held ← holding ["session engine failure"]
        failSinkOn world "load"
        outcome ← runHeld (loggedBy held env) noHarness $ \_ returning → whileHeld held $ do
          awaitEntered held "session engine failure"
          void (awaitReturn returning)
          isHeld held `shouldReturn` True
        outVerdict outcome `shouldBe` VerdictFailure
        outRetired outcome `shouldBe` True
        fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
        undelivered outcome `shouldSatisfy` elem "session engine failure"
    pure ()

  it "the diagnostic of the closure when the caller is cancelled: the unwinding stops and retires the owners, the call returns with the sink held, and the write is cancelled once and recorded" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["session stopping"]
      (ended, session) ← runCaught (loggedBy held env) noHarness $ \driver session → (`onException` letGo held) $ do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        throwTo driver ThreadKilled
      -- the cancellation is what was raised, and the call returned with the sink still holding the write
      raisedKilled ended `shouldBe` True
      isHeld held `shouldReturn` True
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      found ← outcomeNow session
      outRetired found `shouldBe` True
      undelivered found `shouldSatisfy` elem "session stopping"
      -- the writer was cancelled where it was, and the write is not written again
      bounded . atomically $ do
        history ← sessionHistory session
        when (("session stopping", DiagInterrupted) `notElem` historyDiagnostics history) retry
      letGo held
      timesEntered held "session stopping" `shouldReturn` 1

  it "the final note: the call returns without it, retired, and the note is recorded undelivered" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["session ended"]
      outcome ← runHeld (loggedBy held env) noHarness $ \session returning → whileHeld held $ do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitReturn returning)
        isHeld held `shouldReturn` True
      outRetired outcome `shouldBe` True
      outVerdict outcome `shouldBe` VerdictSuccess
      undelivered outcome `shouldSatisfy` elem "session ended"

  it "the module coordinator's warning for a failure nobody waits for, written on the owner's own thread: the stops are handed at once and the peer role retires" $
    withSetup
      ( addFile
          ("lua/bad.lua", "this is not lua (")
          (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then self.module = api.content.module('lua/bad.lua'); api.request.cancel(self.module) end"]}))
      )
      $ \env → do
        let probe = ssProbeOf env
            warning = "a module failed and no request was waiting for it"
        held ← holding [warning]
        closeGate probe "lua/bad.lua"
        _ ← runScenario (loggedBy held env) $ \session → whileHeld held $ do
          -- the read the cancelled request started is let go: the module fails, nobody waits for it, and the logical owner
          -- is in the logger for the warning
          awaitReadOf env "lua/bad.lua"
          openGate probe "lua/bad.lua"
          awaitEntered held warning
          requestStop session StopQuit
          void (awaitStatus session (maybe False ((== Retired) . rolePhase) . presentationOf))
          found ← historyNow session
          historyStopped found `shouldBe` [Gameplay, Presentation]
          status ← statusNow session
          fmap rolePhase (gameplayOf status) `shouldSatisfy` (/= Just Retired)
          letGo held
          void (awaitRetired session)
        pure ()

  it "an owner's authored output, written on the owner's own thread (D-71's synchronous print, not a session diagnostic): both stops are handed at once, and the roles retire when the write returns" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      holdSink world "init gameplay"
      outcome ← runScenario env $ \session → do
        -- the logical owner is in its first print, and the output is one stream: what that print holds, the owners that
        -- write hold with it, and the driver is not among them
        awaitSinkEntered world "init gameplay"
        requestStop session StopQuit
        found ← historyNow session
        historyStopped found `shouldBe` [Gameplay, Presentation]
        status ← statusNow session
        statusStopping status `shouldBe` True
        retiredBoth status `shouldBe` False
        releaseSink world
        void (awaitRetired session)
      outRetired outcome `shouldBe` True

-- A sink that fails ------------------------------------------------------------------------------------------------

failing ∷ Spec
failing = describe "with a sink that fails" $ do
  it "is evidence and never the session's failure: the session goes on, ends as it would have, and records the failure" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← failingAt ["start gate opened"]
      outcome ← runScenario (loggedBy held env) $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        -- the failure is recorded by the writer, and the session has not been ended by it
        bounded . atomically $ do
          found ← sessionOutcomeNow session
          when (deSinkFailures (outDiagnostics found) == 0) retry
        status ← statusNow session
        statusStopping status `shouldBe` False
        requestStop session StopQuit
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictSuccess
      erPrimary (outEngine outcome) `shouldBe` Nothing
      outFailures outcome `shouldBe` []
      mentions "a diagnostic could not be written" outcome `shouldBe` True
      deSinkFailures (outDiagnostics outcome) `shouldBe` 1
      timesEntered held "start gate opened" `shouldReturn` 1

  it "is evidence beside a failure the session already has, which stays the primary" $
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error('boom')"]})) {suShape = GameplayAlone}) $ \env → do
      held ← failingAt ["role failed"]
      let world = seWorld env
      outcome ← runScenario (loggedBy held env) $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]
      fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just LuaError
      -- "role failed" was attempted once, and the failure of the sink is not in the engine report at all
      timesEntered held "role failed" `shouldReturn` 1
      mentions "a diagnostic could not be written" outcome `shouldBe` True

-- The negative controls -----------------------------------------------------------------------------------------------

controls ∷ Spec
controls = describe "with a protection removed (a negative control)" $ do
  describe "the writer (the driver writes the diagnostics itself)" $ do
    it "holds the whole session at its first note, before anything is built, which the example above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        held ← holding ["session starting"]
        recorder ← newRecorder
        void . runScenarioWith (loggedBy held env) (recordingHarness recorder noHarness {harnessRemoved = [ProtectOffDriver]}) $ \session → whileHeld held $ do
          awaitEntered held "session starting"
          -- the driver is in the sink, before the callback's session has anything: nothing has been constructed
          points ← recorded recorder
          [point | point ← points, isBuilding point] `shouldBe` []
          letGo held
          requestStop session StopQuit

    it "leaves both roles unretired, though their owners have ended, while the driver is in the sink for the start gate" $
      withSetup (setup (roleScript printScript)) $ \env → do
        held ← holding ["start gate opened"]
        let world = seWorld env
        void . runScenarioWith (loggedBy held env) noHarness {harnessRemoved = [ProtectOffDriver]} $ \session → whileHeld held $ do
          awaitEntered held "start gate opened"
          requestStop session StopQuit
          -- both owners have stopped and run their shutdowns, and the driver, in the sink, has accounted neither
          out ← awaitOutputLines world 4
          out `shouldSatisfy` elem "shutdown gameplay stopped"
          out `shouldSatisfy` elem "shutdown presentation stopped"
          status ← statusNow session
          retiredBoth status `shouldBe` False
          letGo held
          void (awaitRetired session)

  describe "the abandonment (the call waits for the writer to write the queue)" $
    it "has not returned, though every role has retired, while the sink holds a write, which the example above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        held ← holding ["start gate opened"]
        recorder ← newRecorder
        outcome ← runHeld (loggedBy held env) (recordingHarness recorder noHarness {harnessRemoved = [ProtectAbandon]}) $ \session returning → whileHeld held $ do
          awaitEntered held "start gate opened"
          requestStop session StopQuit
          -- every role has retired and the call is in its wait for the writer
          void (awaitRetired session)
          awaitPoint recorder WriterWait
          hasReturned returning `shouldReturn` False
          letGo held
          void (awaitReturn returning)
        outRetired outcome `shouldBe` True
  where
    isBuilding = \case
      Acquiring {} → True
      Built {} → True
      _ → False
