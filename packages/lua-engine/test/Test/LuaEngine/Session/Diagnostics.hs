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

import Control.Concurrent (forkIO, killThread, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, isEmptyMVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, displayException, finally, fromException, mask, onException, throwIO, toException, try, tryWithContext, uninterruptibleMask_)
import Control.Monad (void, when)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Conc (getUncaughtExceptionHandler, setUncaughtExceptionHandler)
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), Logger, callbackSink, defaultLogFilter, mkLogger)
import Test.Hspec
import Hetoimasia.LuaEngine.Profile (ByteLimit (EngineReportBytes, SecondarySummaryBytes), CountLimit (SecondarySummaries))
import Test.LuaEngine.Modules.Support (closeGate, openEverything, openGate)
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "diagnostics" $ do
  classes
  failing
  free
  construction
  machine
  controls

-- | A logger whose sink holds the write of each entry with one of these messages until it is let go, and then, if told
-- to, fails it.
data Held = Held
  { heldLogger ∷ !Logger
  , heldEntered ∷ !(TVar [Text])
  -- ^ The messages held or failed whose write has begun, newest first.
  , heldAll ∷ !(TVar [Text])
  -- ^ Every message whose write has begun, newest first.
  , heldGate ∷ !(TVar Bool)
  , heldFails ∷ !(TVar Bool)
  , heldAsync ∷ !(TVar Bool)
  -- ^ A failure raises an exception of an asynchronous type: the sink's own cancellation.
  }

holding ∷ [Text] → IO Held
holding = holdingWith False

-- | The same, with the sink holding inside an uninterruptible region: a cancellation cannot reach it until it returns.
holdingUninterruptibly ∷ [Text] → IO Held
holdingUninterruptibly = holdingWith True

holdingWith ∷ Bool → [Text] → IO Held
holdingWith uninterruptibly messages = do
  entered ← newTVarIO []
  everything ← newTVarIO []
  gate ← newTVarIO True
  fails ← newTVarIO False
  asynchronously ← newTVarIO False
  let wait = atomically (readTVar gate >>= \held → when held retry)
      sink entry = do
        atomically (modifyTVar' everything (entryMessage entry :))
        when (entryMessage entry `elem` messages) $ do
          atomically (modifyTVar' entered (entryMessage entry :))
          if uninterruptibly then uninterruptibleMask_ wait else wait
          failing' ← readTVarIO fails
          asynchronous ← readTVarIO asynchronously
          when failing' (if asynchronous then throwIO ThreadKilled else throwIO (userError "the sink failed"))
  pure (Held (mkLogger defaultLogFilter (callbackSink sink)) entered everything gate fails asynchronously)

-- | A logger whose sink fails the write of each entry with one of these messages, at once.
failingAt ∷ [Text] → IO Held
failingAt messages = do
  held ← holding messages
  atomically (writeTVar (heldGate held) False >> writeTVar (heldFails held) True)
  pure held

-- | A logger whose sink is cancelled, as if by someone else (an exception of an asynchronous type), for each entry with
-- one of these messages, at once.
cancellingAt ∷ [Text] → IO Held
cancellingAt messages = do
  held ← failingAt messages
  atomically (writeTVar (heldAsync held) True)
  pure held

-- | Run a body that is handed what the uncaught-exception handler was told about the diagnostics writer's abandonment, the
-- handler being the process's and put back after.
withUncaught ∷ (IO [Text] → IO a) → IO a
withUncaught body = do
  seen ← newTVarIO []
  old ← getUncaughtExceptionHandler
  setUncaughtExceptionHandler (\caught → atomically (modifyTVar' seen (Text.pack (displayException caught) :)))
  body (filter (Text.isInfixOf "WriterAbandoned") <$> readTVarIO seen) `finally` setUncaughtExceptionHandler old

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

-- | What a session shows from the outside: its outcome, its status and its history.
snapshot ∷ Session → IO (SessionOutcome, SessionStatus, History)
snapshot session = (,,) <$> outcomeNow session <*> statusNow session <*> historyNow session

-- | Block until the diagnostics writer has ended.
awaitWriterEnd ∷ Session → IO ()
awaitWriterEnd session = bounded (atomically (sessionDiagnosticsEnded session >>= \over → when (not over) retry))

-- The classes of site ------------------------------------------------------------------------------------------------

classes ∷ Spec
classes = describe "with the logger held at" $ do
  -- Blocked during teardown, from before the stop, in the sink as an interruptible block and as an uninterruptible region:
  -- everything the lifecycle owes completes without the gate opened, the outcome carries the exact undelivered record and its
  -- cause, and opening the gate after the call returned lets the writer actually end and changes nothing the session shows.
  mapM_
    ( \(name, make, cancelsAtOnce) →
        it ("a sink blocked " <> name <> " from before a stop: every owner's stop, accounting, drain, retirement and the call's return complete without the gate opened, and the late end of the writer changes nothing") $
          withSetup (setup (roleScript printScript)) $ \env → do
            held ← make ["start gate opened"]
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
              -- a cancellable block ends at once; one inside an uninterruptible region cannot be reached, and the call did not wait
              if cancelsAtOnce
                then awaitWriterEnd session
                else atomically (sessionDiagnosticsEnded session) `shouldReturn` False
              shown ← snapshot session
              letGo held
              awaitWriterEnd session
              shownLater ← snapshot session
              shownLater `shouldBe` shown
            -- the exact record: what was in the sink, and what was queued behind it, in order, with the cause
            deUndelivered (outDiagnostics outcome) `shouldBe` 3
            undelivered outcome `shouldBe` ["start gate opened", "session stopping", "session ended"]
            deCause (outDiagnostics outcome) `shouldBe` Just "the session returned with the diagnostics writer still working"
            deSinkFailures (outDiagnostics outcome) `shouldBe` 0
            outVerdict outcome `shouldBe` VerdictSuccess
    )
    [("interruptibly", holding, True), ("uninterruptibly", holdingUninterruptibly, False)]

  it "a sink blocked at the smallest legal profile (a report of one byte, one summary of one byte): the counts are exact, no text is kept, and the record is within EngineReportBytes" $
    withSetup ((setup (roleScript printScript)) {suProfile = smaller [(SecondarySummaries, 1)] [(EngineReportBytes, 1), (SecondarySummaryBytes, 1)]}) $ \env → do
      held ← holding ["start gate opened"]
      outcome ← runHeld (loggedBy held env) noHarness $ \session returning → whileHeld held $ do
        awaitEntered held "start gate opened"
        requestStop session StopQuit
        void (awaitReturn returning)
      -- the three diagnostics the held sink left are counted exactly, and the budget keeps none of their texts
      deUndelivered (outDiagnostics outcome) `shouldBe` 3
      undelivered outcome `shouldBe` []
      deCause (outDiagnostics outcome) `shouldBe` Nothing
      outRetired outcome `shouldBe` True
      let kept = maybe [] (pure . eeMessage) (erPrimary (outEngine outcome)) <> map eeMessage (erSecondary (outEngine outcome)) <> deSinkFirst (outDiagnostics outcome) <> undelivered outcome <> maybe [] pure (deCause (outDiagnostics outcome))
      sum (map Text.length kept) `shouldSatisfy` (<= 1)

  it "a sink blocked from before a failure, uninterruptibly: the failure is latched and published, the owner retired and the call returned without the gate opened" $
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error('boom')"]})) {suShape = GameplayAlone}) $ \env → do
      held ← holdingUninterruptibly ["session starting"]
      let world = seWorld env
      outcome ← runHeld (loggedBy held env) noHarness $ \session returning → whileHeld held $ do
        awaitEntered held "session starting"
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        found ← awaitReturn returning
        fmap rfRole (outFailures found) `shouldBe` [Gameplay]
        outRetired found `shouldBe` True
        isHeld held `shouldReturn` True
        atomically (sessionDiagnosticsEnded session) `shouldReturn` False
        letGo held
        awaitWriterEnd session
      outVerdict outcome `shouldBe` VerdictFailure
      fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just LuaError
      undelivered outcome `shouldSatisfy` elem "role failed"
      deSinkFailures (outDiagnostics outcome) `shouldBe` 0

  it "a sink blocked while the session is healthy: logical ticks and the presentation role's updates go on" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["start gate opened"]
      let world = seWorld env
      _ ← runHeld (loggedBy held env) noHarness $ \session returning → whileHeld held $ do
        awaitEntered held "start gate opened"
        awaitRegistration world 1000
        passTime world 3000000 ((>= 3) . length . filter (Text.isPrefixOf "update gameplay") <$> outLines world)
        passTime world 1000000000 (any (Text.isPrefixOf "update presentation") <$> outLines world)
        isHeld held `shouldReturn` True
        requestStop session StopQuit
        void (awaitReturn returning)
      pure ()
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
      recorder ← newRecorder
      holdAt recorder CuttingOff
      outcome ← runHeld (loggedBy held env) (recordingHarness recorder noHarness) $ \session returning → whileHeld held $ do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        -- the call is about to cut the diagnostics off, and the writer is in the sink for the failure's note
        awaitPoint recorder CuttingOff
        awaitEntered held "role failed"
        releaseHold recorder CuttingOff
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
        recorder ← newRecorder
        holdAt recorder CuttingOff
        failSinkOn world "load"
        outcome ← runHeld (loggedBy held env) (recordingHarness recorder noHarness) $ \_ returning → whileHeld held $ do
          -- the call is about to cut the diagnostics off, and the writer is in the sink for the engine failure's note
          awaitPoint recorder CuttingOff
          awaitEntered held "session engine failure"
          releaseHold recorder CuttingOff
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
      recorder ← newRecorder
      holdAt recorder CuttingOff
      (ended, session) ← runCaught (loggedBy held env) (recordingHarness recorder noHarness) $ \driver session → (`onException` letGo held) $ do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        throwTo driver ThreadKilled
        -- every role has retired and the call is about to cut the diagnostics off: the writer is in the sink for the
        -- closure's note, which the example has seen it enter
        awaitPoint recorder CuttingOff
        awaitEntered held "session stopping"
        releaseHold recorder CuttingOff
      -- the cancellation is what was raised, and the call returned with the sink still holding the write
      raisedKilled ended `shouldBe` True
      isHeld held `shouldReturn` True
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      found ← outcomeNow session
      outRetired found `shouldBe` True
      undelivered found `shouldSatisfy` elem "session stopping"
      deCause (outDiagnostics found) `shouldBe` Just "the caller was cancelled"
      recorded recorder >>= \points → points `shouldSatisfy` elem (WriterCutOff True)
      -- the writer was cancelled where it was, with the sink still held: it ended, and the write is not written again
      awaitWriterEnd session
      isHeld held `shouldReturn` True
      letGo held
      timesEntered held "session stopping" `shouldReturn` 1

  it "the final note: the call returns without it, retired, and the note is recorded undelivered" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["session ended"]
      recorder ← newRecorder
      holdAt recorder CuttingOff
      outcome ← runHeld (loggedBy held env) (recordingHarness recorder noHarness) $ \session returning → whileHeld held $ do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        -- the writer is in the sink for the final note when the call cuts the diagnostics off
        awaitPoint recorder CuttingOff
        awaitEntered held "session ended"
        releaseHold recorder CuttingOff
        void (awaitReturn returning)
        isHeld held `shouldReturn` True
      outRetired outcome `shouldBe` True
      outVerdict outcome `shouldBe` VerdictSuccess
      undelivered outcome `shouldBe` ["session ended"]

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
      -- after a failure the sink is written no more: what was meant later is counted as undelivered
      readTVarIO (heldAll held) >>= \attempted → reverse attempted `shouldBe` ["session starting", "start gate opened"]
      undelivered outcome `shouldSatisfy` elem "session stopping"
      deCause (outDiagnostics outcome) `shouldSatisfy` (/= Nothing)

  it "is evidence beside a failure the session already has, which stays the primary" $
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error('boom')"]})) {suShape = GameplayAlone}) $ \env → do
      held ← failingAt ["role failed"]
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder CuttingOff
      outcome ← runScenarioWith (loggedBy held env) (recordingHarness recorder noHarness) $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitRetired session)
        -- the writer has met the sink's failure before the call cuts the diagnostics off
        awaitPoint recorder CuttingOff
        bounded . atomically $ do
          found ← sessionOutcomeNow session
          when (deSinkFailures (outDiagnostics found) == 0) retry
        releaseHold recorder CuttingOff
      outVerdict outcome `shouldBe` VerdictFailure
      fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]
      fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just LuaError
      -- "role failed" was attempted once, and the failure of the sink is not in the engine report at all
      timesEntered held "role failed" `shouldReturn` 1
      mentions "a diagnostic could not be written" outcome `shouldBe` True

-- A free sink ----------------------------------------------------------------------------------------------------------

free ∷ Spec
free = describe "with a sink that is free" $ do
  it "does not count what was acknowledged before the cut-off, and counts only what was pending then" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["never"]
      outcome ← runScenario (loggedBy held env) $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        -- the two diagnostics of the start are acknowledged and gone from the queue
        bounded . atomically $ do
          history ← sessionHistory session
          when (any ((`elem` ["session starting", "start gate opened"]) . fst) (historyDiagnostics history)) retry
        requestStop session StopQuit
        void (awaitRetired session)
      undelivered outcome `shouldSatisfy` all (`notElem` ["session starting", "start gate opened"])
      deSinkFailures (outDiagnostics outcome) `shouldBe` 0
      readTVarIO (heldAll held) >>= \attempted → take 2 (reverse attempted) `shouldBe` ["session starting", "start gate opened"]

-- The writer's start ---------------------------------------------------------------------------------------------------

construction ∷ Spec
construction = describe "the writer's start" $ do
  it "is a failure of the composition when it cannot be made, before anything exists, and the sink is never asked" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["never"]
      recorder ← newRecorder
      failAt recorder WriterStarting (toException (userError "the writer could not be started"))
      result ← tryWithContext @SomeException (runSession (scenarioSpec (loggedBy held env) (recordingHarness recorder noHarness)) (\_ → pure ()))
      case result of
        Left (ExceptionWithContext _ raised) → show raised `shouldSatisfy` Text.isInfixOf "the writer could not be started" . Text.pack
        Right _ → expectationFailure "the failure of the composition was lost"
      points ← recorded recorder
      points `shouldSatisfy` elem WriterStarting
      points `shouldSatisfy` notElem WriterStarted
      [point | point ← points, isBuilding point] `shouldBe` []
      readTVarIO (heldAll held) `shouldReturn` []

  it "is cut off when the caller is cancelled right after it is registered: the cancellation escapes, with nothing built and the sink unasked" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["never"]
      recorder ← newRecorder
      holdAt recorder WriterStarted
      driver ← myThreadId
      _ ← forkIO $ do
        awaitPoint recorder WriterStarted
        throwTo driver ThreadKilled
        releaseHold recorder WriterStarted
      result ← tryWithContext @SomeException (runSession (scenarioSpec (loggedBy held env) (recordingHarness recorder noHarness)) (\_ → pure ()))
      case result of
        Left (ExceptionWithContext _ raised) → fromException raised `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the cancellation was lost"
      points ← recorded recorder
      [point | point ← points, isBuilding point] `shouldBe` []
      readTVarIO (heldAll held) >>= \attempted → attempted `shouldSatisfy` all (`notElem` ["start gate opened"])

-- The writer as a state machine -----------------------------------------------------------------------------------------

-- | A session with a sink that fails, once, the write of the entry with this message, and a driver held at the cut-off until
-- the writer has met the failure (or the cancellation): the whole session, both roles, started and then stopped.
sinkFailureRun ∷ SessionEnv → Held → [Protection] → IO SessionOutcome
sinkFailureRun env held removedProtections = do
  recorder ← newRecorder
  holdAt recorder CuttingOff
  runScenarioWith (loggedBy held env) (recordingHarness recorder noHarness {harnessRemoved = removedProtections}) $ \session → do
    awaitPhase session Gameplay Running
    awaitPhase session Presentation Running
    requestStop session StopQuit
    void (awaitRetired session)
    -- the writer has met the sink's failure before the call cuts the diagnostics off
    awaitPoint recorder CuttingOff
    bounded . atomically $ do
      found ← sessionOutcomeNow session
      when (deSinkFailures (outDiagnostics found) == 0) retry
    releaseHold recorder CuttingOff

-- | The states of the writer, and the transitions between them, each proved with the sink held or failed at a gate the
-- example owns and synchronized on the sink's entry or exit; the table of them is in the pull request, and the controls
-- below break each once.
machine ∷ Spec
machine = describe "the writer, transition by transition" $ do
  it "writing → failed-undelivered: a write the sink raised for is kept, with its failure, and counted as undelivered in the exact record, with the ones meant after it; the writer writes no more" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← failingAt ["start gate opened"]
      outcome ← sinkFailureRun env held []
      deSinkFailures (outDiagnostics outcome) `shouldBe` 1
      undelivered outcome `shouldBe` ["start gate opened", "session stopping", "session ended"]
      deUndelivered (outDiagnostics outcome) `shouldBe` 3
      readTVarIO (heldAll held) >>= \attempted → reverse attempted `shouldBe` ["session starting", "start gate opened"]
      outVerdict outcome `shouldBe` VerdictSuccess

  it "writing → cancelled-undelivered: a write the sink's own cancellation ended is evidence and undelivered, the session goes on, and the writer ends" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← cancellingAt ["start gate opened"]
      outcome ← sinkFailureRun env held []
      deSinkFailures (outDiagnostics outcome) `shouldBe` 1
      deSinkFirst (outDiagnostics outcome) `shouldSatisfy` any (Text.isInfixOf "a diagnostic write was cancelled")
      undelivered outcome `shouldBe` ["start gate opened", "session stopping", "session ended"]
      outVerdict outcome `shouldBe` VerdictSuccess

  it "writing → delivered: a write that returned is acknowledged, and not counted" $
    withSetup (setup (roleScript printScript)) $ \env → do
      held ← holding ["never"]
      outcome ← runScenario (loggedBy held env) $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        bounded . atomically $ do
          history ← sessionHistory session
          when (any ((`elem` ["session starting", "start gate opened"]) . fst) (historyDiagnostics history)) retry
        requestStop session StopQuit
        void (awaitRetired session)
      undelivered outcome `shouldSatisfy` all (`notElem` ["session starting", "start gate opened"])

  it "idle-wait → abandoned: a writer that has written all it had is cut off while it waits, ends, and no exception escapes its thread" $
    withSetup (setup (roleScript printScript)) $ \env → withUncaught $ \uncaught → do
      held ← holding ["never"]
      recorder ← newRecorder
      holdAt recorder CuttingOff
      outcome ← runHeld (loggedBy held env) (recordingHarness recorder noHarness) $ \session returning → whileHeld held $ do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        awaitPoint recorder CuttingOff
        -- everything was written and acknowledged: the writer is idle, in its wait
        bounded . atomically $ do
          history ← sessionHistory session
          when (not (null (historyDiagnostics history))) retry
        releaseHold recorder CuttingOff
        void (awaitReturn returning)
        awaitWriterEnd session
      undelivered outcome `shouldBe` []
      deUndelivered (outDiagnostics outcome) `shouldBe` 0
      uncaught >>= (`shouldBe` [])

  it "delivered → abandoned: a writer cut off between two writes, parked on its own thread, is caught by the one handler, ends, and the diagnostics it never claimed are counted exactly" $
    withSetup (setup (roleScript printScript)) $ \env → withUncaught $ \uncaught → do
      held ← holding ["never"]
      recorder ← newRecorder
      holdAt recorder WriterBetween
      outcome ← runHeld (loggedBy held env) (recordingHarness recorder noHarness) $ \session returning → whileHeld held $ do
        -- the writer has acknowledged the first note and is parked before it waits for the next
        awaitPoint recorder WriterBetween
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitReturn returning)
        awaitWriterEnd session
        releaseHold recorder WriterBetween
      -- none of the later diagnostics was ever claimed, and each is counted once
      undelivered outcome `shouldBe` ["start gate opened", "session stopping", "session ended"]
      deUndelivered (outDiagnostics outcome) `shouldBe` 3
      uncaught >>= (`shouldBe` [])

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

  describe "each transition of the writer broken once" $ do
    it "acknowledgement removed (writing → delivered): what the sink wrote is counted as not delivered, which the example above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        held ← holding ["never"]
        recorder ← newRecorder
        holdAt recorder CuttingOff
        outcome ← runScenarioWith (loggedBy held env) (recordingHarness recorder noHarness {harnessRemoved = [ProtectAcknowledge]}) $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          requestStop session StopQuit
          -- both notes of the start were written by the time the call is about to cut the diagnostics off
          awaitPoint recorder CuttingOff
          bounded . atomically $ readTVar (heldAll held) >>= \attempted → when (length attempted < 2) retry
          releaseHold recorder CuttingOff
        undelivered outcome `shouldSatisfy` elem "session starting"

    it "failure not kept (writing → failed-undelivered): the diagnostic the sink raised for is missing from the undelivered record, which the example above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        held ← failingAt ["start gate opened"]
        outcome ← sinkFailureRun env held [ProtectKeepFailed]
        deSinkFailures (outDiagnostics outcome) `shouldBe` 1
        undelivered outcome `shouldSatisfy` notElem "start gate opened"

    it "the sink's own cancellation forgotten (writing → cancelled-undelivered): no evidence of it, which the example above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        held ← cancellingAt ["start gate opened"]
        recorder ← newRecorder
        holdAt recorder CuttingOff
        outcome ← runScenarioWith (loggedBy held env) (recordingHarness recorder noHarness {harnessRemoved = [ProtectCancelEvidence]}) $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          requestStop session StopQuit
          void (awaitRetired session)
          awaitPoint recorder CuttingOff
          -- the sink has been asked for the entry it cancelled
          awaitEntered held "start gate opened"
          awaitWriterEnd session
          releaseHold recorder CuttingOff
        deSinkFailures (outDiagnostics outcome) `shouldBe` 0

    it "one handler removed (idle/writing/between → abandoned): the abandonment of a writer parked between two writes escapes its thread, which the example above detects" $
      withSetup (setup (roleScript printScript)) $ \env → withUncaught $ \uncaught → do
        held ← holding ["never"]
        recorder ← newRecorder
        holdAt recorder WriterBetween
        _ ← runHeld (loggedBy held env) (recordingHarness recorder noHarness {harnessRemoved = [ProtectWriterCatch]}) $ \session returning → whileHeld held $ do
          awaitPoint recorder WriterBetween
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          requestStop session StopQuit
          void (awaitReturn returning)
          awaitWriterEnd session
          releaseHold recorder WriterBetween
        -- the exception reaches the process's handler on the writer's thread, a moment after the thread has ended
        let awaitSeen = uncaught >>= \seen → when (null seen) (yield >> awaitSeen)
        bounded awaitSeen
        uncaught >>= \seen → seen `shouldSatisfy` (not . null)

    it "registration removed (the cut-off finds the writer): no thread is found to cancel, which the example above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        held ← holding ["start gate opened"]
        recorder ← newRecorder
        _ ← runHeld (loggedBy held env) (recordingHarness recorder noHarness {harnessRemoved = [ProtectWriterRegistration]}) $ \session returning → whileHeld held $ do
          awaitEntered held "start gate opened"
          requestStop session StopQuit
          void (awaitReturn returning)
        recorded recorder >>= \points → points `shouldSatisfy` elem (WriterCutOff False)

-- | A point of construction: something of a role is being acquired or has been.
isBuilding ∷ Point → Bool
isBuilding = \case
  Acquiring {} → True
  Built {} → True
  _ → False
