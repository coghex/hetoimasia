{-# LANGUAGE OverloadedStrings #-}

-- | Diagnostics never gate the lifecycle (D-82/T4). No step of the driver, no stop pass and no step of the teardown
-- calls the session's logger: a diagnostic is data in the lifecycle record, and a writer of the session's own is the
-- sink's only caller. These examples hold the logger at each class of site, with a gate the example owns, and show
-- that a stop is handed, an owner's end accounted, its drain proven, its releases run and its retirement published
-- while the logger is held; the facts are read from the handle, before the gate is let go.
--
-- The classes are the first note of the session, the diagnostic of the start gate opening, the diagnostics of a
-- failure and of the closure, the final note, a sink that fails while the teardown is under way, and (beside them) the
-- authored output an owner's @print@ writes on the owner's own thread. A negative control removes the writer through
-- the private harness: the driver writes, as it did, and the same examples show it held.
module Test.LuaEngine.Session.Diagnostics (spec) where

import Control.Concurrent (throwTo)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), finally, onException, throwIO)
import Control.Monad (unless, void, when)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), Logger, callbackSink, defaultLogFilter, mkLogger)
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, openGate)
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "diagnostics" $ do
  classes
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
        failing ← readTVarIO fails
        when failing (throwIO (userError "the sink failed"))
  pure (Held (mkLogger defaultLogFilter (callbackSink sink)) entered gate fails)

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

-- | Run a body, and let the sink go however it ends, so that a failing example fails instead of waiting for the writer.
whileHeld ∷ Held → IO a → IO a
whileHeld held body = body `finally` letGo held

-- | Run a body, and let the sink go if it fails, so that a failing example fails instead of waiting for the writer. A
-- body that succeeds leaves the sink held, for the example to let go after it has looked at the held call.
unlessItFails ∷ Held → IO a → IO a
unlessItFails held body = body `onException` letGo held

-- | Block until the diagnostic with this message is no longer in the lifecycle record: it was written and acknowledged.
awaitWritten ∷ Session → Text → IO ()
awaitWritten session message = bounded . atomically $ do
  found ← sessionHistory session
  when (message `elem` map fst (historyDiagnostics found)) retry

inFlight ∷ Session → Text → IO ()
inFlight session message = do
  found ← historyNow session
  historyDiagnostics found `shouldSatisfy` elem (message, DiagInFlight)

-- The classes of site ------------------------------------------------------------------------------------------------

classes ∷ Spec
classes = describe "with the logger held at" $ do
  it "the first note of the session: both roles are built, validated and started, and a stop retires them" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["session starting"]
      outcome ← runScenario (loggedBy held env) $ \session → whileHeld held $ do
        awaitEntered held "session starting"
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitRetired session)
        inFlight session "session starting"
        isHeld held `shouldReturn` True
      outRetired outcome `shouldBe` True

  it "the diagnostic the start gate opened, with a stop from another thread: both owners are stopped, accounted and retired" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["start gate opened"]
      outcome ← runScenario (loggedBy held env) $ \session → whileHeld held $ do
        awaitEntered held "start gate opened"
        requestStop session StopQuit
        void (awaitRetired session)
        found ← historyNow session
        historyStopped found `shouldBe` [Gameplay, Presentation]
        inFlight session "start gate opened"
        out ← outLines (seWorld env)
        out `shouldSatisfy` elem "shutdown gameplay stopped"
        out `shouldSatisfy` elem "shutdown presentation stopped"
        -- the outcome and the status are readable, retired, while the sink is held
        status ← statusNow session
        retiredBoth status `shouldBe` True
        isHeld held `shouldReturn` True
      outRetired outcome `shouldBe` True

  it "the diagnostic of a role's failure: the failure is latched, the owner stopped and retired, and the outcome readable" $
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error('boom')"]})) {suShape = GameplayAlone}) $ \env → do
      held ← holding ["role failed"]
      let world = seWorld env
      outcome ← runScenario (loggedBy held env) $ \session → whileHeld held $ do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        awaitEntered held "role failed"
        void (awaitRetired session)
        found ← outcomeNow session
        outVerdict found `shouldBe` VerdictFailure
        fmap rfRole (outFailures found) `shouldBe` [Gameplay]
        isHeld held `shouldReturn` True
      outRetired outcome `shouldBe` True

  it "the diagnostic of an engine failure: the session ends and its roles retire" $ do
    _ ←
      fatalSetup (setup (roleScript printScript {scPrelude = ["print('load')"]})) $ \env → do
        let world = seWorld env
        held ← holding ["session engine failure"]
        failSinkOn world "load"
        outcome ← runScenario (loggedBy held env) $ \session → whileHeld held $ do
          awaitEntered held "session engine failure"
          void (awaitRetired session)
          found ← outcomeNow session
          outVerdict found `shouldBe` VerdictFailure
          isHeld held `shouldReturn` True
        outRetired outcome `shouldBe` True
    pure ()

  it "the diagnostic of the closure when the caller is cancelled: the unwinding stops and retires the owners, and the call returns" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["session stopping"]
      (ended, session) ← runCaught (loggedBy held env) noHarness $ \driver session → unlessItFails held $ do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        throwTo driver ThreadKilled
        awaitEntered held "session stopping"
        void (awaitRetired session)
        found ← historyNow session
        historyStopped found `shouldBe` [Gameplay, Presentation]
        inFlight session "session stopping"
      -- the cancellation is what was raised, and the call returned with the sink still holding the write
      raisedKilled ended `shouldBe` True
      isHeld held `shouldReturn` True
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      -- the writer finishes the write in hand by itself, and no other
      letGo held
      awaitWritten session "session stopping"
      timesEntered held "session stopping" `shouldReturn` 1

  it "the final note: the outcome is readable, retired, while the call waits for it; a cancellation ends the wait" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["session ended"]
      (ended, session) ← runCaught (loggedBy held env) noHarness $ \driver session → unlessItFails held $ do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        awaitEntered held "session ended"
        found ← outcomeNow session
        outRetired found `shouldBe` True
        inFlight session "session ended"
        -- the caller is cancelled while it waits for the note
        throwTo driver ThreadKilled
      -- it left with the sink still holding the write, raising the cancellation, and the writer finishes by itself
      raisedKilled ended `shouldBe` True
      isHeld held `shouldReturn` True
      letGo held
      awaitWritten session "session ended"
      timesEntered held "session ended" `shouldReturn` 1

  it "the final note, let go: the call returns the outcome after the note is written" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["session ended"]
      outcome ← runScenario (loggedBy held env) $ \session → whileHeld held $ do
        awaitPhase session Gameplay Running
        requestStop session StopQuit
        awaitEntered held "session ended"
        void (awaitRetired session)
      outRetired outcome `shouldBe` True
      outVerdict outcome `shouldBe` VerdictSuccess

  it "a sink that fails once let go, with the teardown over: the failure is an engine failure of the outcome, and nothing is retried" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["start gate opened"]
      outcome ← runScenario (loggedBy held env) $ \session → whileHeld held $ do
        awaitEntered held "start gate opened"
        requestStop session StopQuit
        void (awaitRetired session)
        atomically (writeTVar (heldFails held) True)
      outRetired outcome `shouldBe` True
      outVerdict outcome `shouldBe` VerdictFailure
      outcomeMessages outcome `shouldSatisfy` any (Text.isInfixOf "a diagnostic could not be written")
      timesEntered held "start gate opened" `shouldReturn` 1

  it "an owner's authored output, written on the owner's own thread (D-71's synchronous print, not a diagnostic): both stops are handed at once, and the roles retire when the write returns" $
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

-- The negative controls -----------------------------------------------------------------------------------------------

controls ∷ Spec
controls = describe "with the writer removed (a negative control: the driver writes the diagnostics itself)" $ do
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
        unless (not (retiredBoth status)) (expectationFailure "a role retired while the driver was in the sink")
        letGo held
        void (awaitRetired session)
  where
    isBuilding = \case
      Acquiring {} → True
      Built {} → True
      _ → False
