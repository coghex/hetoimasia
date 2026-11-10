{-# LANGUAGE OverloadedStrings #-}

-- | What the session coordinator's examples share: a world of a real content root with a real manifest,
-- inventory and read pool, the boot checkpoint made over it, recording sinks for authored output, an
-- injected clock and a fake timer, real supervised Lua owners started by the coordinator itself, and a
-- scenario thread that acts on the session while the coordinator runs on the example's own thread.
--
-- Evidence from the real adapters and evidence that is injected are kept apart by name: the content, the
-- manifest, the checkpoint, the pool, the modules, the data service, the facade, the owners and the
-- coordinator are real; the sinks, the clock, the timer and the harness's probe are the controlled
-- endpoints the coordinator is injected with.
--
-- Nothing sleeps. An example knows what has happened from the authored output (its Lua prints what it saw),
-- from a gate it holds or from STM it blocks in, and the whole example is bounded. A scenario that raises
-- stops the session, is waited for to its end and is raised again, so a failed assertion in it is never
-- swallowed and never leaves a thread behind.
module Test.LuaEngine.Session.Support
  ( -- * Setting up
    Shape (..)
  , Setup (..)
  , setup
  , SessionEnv (..)
  , withSetup
  , fatalSetup
  , manifestBytes

    -- * Running
  , runScenario
  , runScenarioWith
  , RunnerSeams (..)
  , noRunnerSeams
  , runScenarioSeamed
  , letScenarioGo
  , withOwnedThreadsOpening
  , runCaught
  , Caught
  , historyNow
  , outcomeMessages
  , raisedMessage
  , raisedKilled
  , awaitBlockedOnException
  , scenarioSpec
  , awaitStatus
  , awaitPhase
  , gameplayOf
  , presentationOf
  , phasesOf
  , outcomeNow
  , statusNow

    -- * Authoring
  , roleScript
  , printScript
  , Lua
  , rolePrint

    -- * The pool's reader
  , ssProbeOf
  , awaitReadOf

    -- * Driving the clock
  , nudge
  , nudgeArmed
  , addFile
  , awaitRegistration
  , awaitRetired
  , retiredBoth
  , passTime
  , tickMillis
  , awaitOutputLines

    -- * Probes
  , Recorder
  , newRecorder
  , recorded
  , recordingHarness
  , awaitPoint
  , holdAt
  , releaseHold
  , failAt
  , failWith

    -- * Re-exports
  , module Test.LuaEngine.Facade.Support
  , module Hetoimasia.LuaEngine.Session
  , module Hetoimasia.LuaEngine.Session.Harness
  , module Hetoimasia.LuaEngine.Session.State
  , module Hetoimasia.LuaEngine.Session.Failure
  ) where

import Control.Concurrent (ThreadId, killThread, myThreadId, yield)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception.Context (emptyExceptionContext)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), ExceptionWithContext (ExceptionWithContext), SomeException, displayException, fromException, mask, rethrowIO, throwIO, try, tryWithContext)
import Test.HUnit.Lang (HUnitFailure)
import Control.Monad (unless, void, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.ByteString (ByteString)
import System.IO (hPutStrLn, stderr)
import Data.Maybe (catMaybes)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Boot (Checkpoint, bootCheckpoint)
import Hetoimasia.LuaEngine.Profile (Profile, fixedM1Profile)
import Hetoimasia.LuaEngine.Session
import Hetoimasia.LuaEngine.Session.Failure
import Hetoimasia.LuaEngine.Session.Harness
import Hetoimasia.LuaEngine.Session.State
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Test.LuaEngine.Facade.Support hiding (Session (..))
import Test.LuaEngine.Modules.Support (Probe, ReaderOf, openEverything, realReader, ssInventory, ssLogger, ssPool, ssProbe, startedPaths)
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThreadOpening)

-- Setting up ---------------------------------------------------------------------------------------

-- | Which roles the manifest selects.
data Shape = BothRoles' | GameplayAlone | PresentationAlone
  deriving (Eq, Show)

-- | What an example chooses about its session.
data Setup = Setup
  { suShape ∷ !Shape
  , suReversed ∷ !Bool
  -- ^ The @vms@ array lists presentation before gameplay.
  , suEntries ∷ !(Maybe (Text, Text))
  -- ^ Each role's own entry (gameplay, presentation); the common one otherwise.
  , suFiles ∷ ![(FilePath, ByteString)]
  -- ^ The content tree, including the entry files.
  , suHarness ∷ !Harness
  , suProfile ∷ !Profile
  , suTickSeconds ∷ !Text
  , suReader ∷ !ReaderOf
  -- ^ The pool's reader: the real one, or one with a failure injected for the paths an example names.
  }

-- | Both roles on one common entry, which the example supplies, over the fixed profile.
setup ∷ ByteString → Setup
setup entry =
  Setup
    { suShape = BothRoles'
    , suReversed = False
    , suEntries = Nothing
    , suFiles = [("lua/main.lua", entry)]
    , suHarness = noHarness
    , suProfile = fixedM1Profile
    , suTickSeconds = "0.001"
    , suReader = realReader
    }

-- | The manifest this setup writes at the root.
manifestBytes ∷ Setup → ByteString
manifestBytes found =
  Text.encodeUtf8 . Text.concat $
    [ "{\"format\":1,\"id\":\"modules-test\""
    , maybe ",\"entry\":\"lua/main.lua\"" (const "") (suEntries found)
    , if suShape found == PresentationAlone then "" else ",\"tick_seconds\":\"" <> suTickSeconds found <> "\""
    , ",\"vms\":["
    , Text.intercalate "," (roles (suReversed found))
    , "]}"
    ]
  where
    roles reversed = (if reversed then reverse else id) (declared (suShape found))
    declared = \case
      BothRoles' → [gameplayDecl, presentationDecl]
      GameplayAlone → [gameplayDecl]
      PresentationAlone → [presentationDecl]
    gameplayDecl = "{\"role\":\"gameplay\",\"clock\":\"logical\"" <> entryOf fst <> "}"
    presentationDecl = "{\"role\":\"presentation\",\"clock\":\"elapsed\"" <> entryOf snd <> "}"
    entryOf choose = maybe "" (\entries → ",\"entry\":\"" <> choose entries <> "\"") (suEntries found)

-- | What an example runs against.
data SessionEnv = SessionEnv
  { seWorld ∷ !World
  , seControl ∷ !RuntimeControl
  , seRuntime ∷ !LuaRuntime
  , seSpec ∷ !SessionSpec
  , seCheckpoint ∷ !Checkpoint
  }

-- | A world over this setup's content, its boot checkpoint, and the session specification over both. The
-- checkpoint is made by the boot checkpoint itself, over the manifest's own bytes.
withSetup ∷ Setup → (SessionEnv → IO a) → IO a
withSetup found body =
  withWorldUsing (suReader found) (suProfile found) (Layout (("hetoimasia.json", manifestBytes found) : suFiles found)) $ \world control runtime → do
    let inventory = ssInventory (wSession world)
        bytes = manifestBytes found
    checkpoint ←
      bootCheckpoint (suProfile found) inventory (\_ _ → pure (Right bytes))
        >>= either (\refused → expectationFailure' ("the boot checkpoint refused: " <> show refused)) pure
    body
      SessionEnv
        { seWorld = world
        , seControl = control
        , seRuntime = runtime
        , seCheckpoint = checkpoint
        , seSpec =
            SessionSpec
              { sxProfile = suProfile found
              , sxCheckpoint = checkpoint
              , sxInventory = inventory
              , sxPool = ssPool (wSession world)
              , sxLogger = ssLogger (wSession world)
              , sxOutput = wOutput world
              , sxClock = worldClock world
              , sxTimer = worldTimer world
              , sxRuntime = runtime
              , sxControl = control
              , sxHarness = suHarness found
              , sxGraphics = Nothing
              , sxTerrain = Nothing
              }
        }
  where
    expectationFailure' message = throwIO (userError message)

-- | An example whose owner is expected to end in a failure that supervision then raises at its boundary (a
-- failure of the host: a provider, a sink): runs the body, and answers the failure with its context. A failed
-- assertion in the body is raised as itself.
fatalSetup ∷ Setup → (SessionEnv → IO ()) → IO (ExceptionWithContext SomeException)
fatalSetup found body = do
  finished ← newIORef False
  tryWithContext @SomeException (withSetup found (\env → body env >> writeIORef finished True)) >>= \case
    Left failure@(ExceptionWithContext _ raised)
      | Just (_ ∷ HUnitFailure) ← fromException raised → throwIO raised
      | otherwise → do
          -- the body must have run to its last assertion: a failure raised inside it, a scenario that did not finish,
          -- is the example's failure, not the expected one
          completed ← readIORef finished
          unless completed (throwIO raised)
          pure failure
    Right () → throwIO (userError "expected the owner to fail, but the example returned")

-- | The session specification with this harness.
scenarioSpec ∷ SessionEnv → Harness → SessionSpec
scenarioSpec env harness = (seSpec env) {sxHarness = harness}

-- Running -------------------------------------------------------------------------------------------

-- | Run the session on this thread and a scenario on another that is handed the session as soon as it
-- exists. The scenario ends the session (by a stop, or by something that fails it); if it raises, it stops
-- the session, and the exception is raised here once the session has ended and the scenario's thread has
-- terminated. However the scenario ends, a sink it held is released and every gate of the pool's reader is opened, so that a failing example fails
-- instead of waiting for an owner it left parked. The outcome is what the session answered.
runScenario ∷ SessionEnv → (Session → IO ()) → IO SessionOutcome
runScenario env = runScenarioWith env (sxHarness (seSpec env))

-- | The same, over this harness.
runScenarioWith ∷ SessionEnv → Harness → (Session → IO ()) → IO SessionOutcome
runScenarioWith = runScenarioSeamed noRunnerSeams

-- | The runner's test-side seams (#599), which place a cancellation of the example exactly, as a timing-free example cannot do
-- from outside: what runs on the calling thread once the scenario's thread exists and is known, and what runs once the session
-- has ended and before the scenario is waited for. The ownership regressions raise there; no example of the suite passes
-- anything else.
data RunnerSeams = RunnerSeams
  { seamStarted ∷ ThreadId → IO ()
  , seamEnded ∷ IO ()
  }

noRunnerSeams ∷ RunnerSeams
noRunnerSeams = RunnerSeams {seamStarted = \_ → pure (), seamEnded = pure ()}

-- | 'runScenarioWith' over its seams.
--
-- State owner: the runner owns the scenario thread, the handle and the result cell. Thread: the scenario's, started by
-- 'withOwnedThreadOpening' (#599), so that however the runner ends (a return, an exception, a timeout of the example, a
-- cancellation delivered at any point, including before the scenario started or once the session has ended) the scenario
-- thread has ended and been joined before the runner returns, and the held sink and the pool reader's gates are let go first,
-- so a scenario parked at one cannot hold the join. Lifetime: the call's. Disposal: the facility's release.
runScenarioSeamed ∷ RunnerSeams → SessionEnv → Harness → (Session → IO ()) → IO SessionOutcome
runScenarioSeamed seams env harness scenario = do
  handleVar ← newEmptyMVar
  resultVar ← newEmptyMVar
  withOwnedThreadOpening (letScenarioGo env) (scenarioThread handleVar resultVar) $ \thread terminated → do
    seamStarted seams thread
    -- A session that ends by itself (a failure) leaves the scenario to see that and finish; one whose run is itself
    -- interrupted or raises takes the scenario down with it, through the scope's release.
    outcome ← runSession (scenarioSpec env harness) (putMVar handleVar)
    seamEnded seams
    finished ← try (bounded (readMVar resultVar))
    case finished of
      Left (ErrorCall why) → do
        killThread thread
        terminated
        throwIO (ErrorCall ("the scenario did not finish after the session ended: " <> why))
      Right result → do
        terminated
        either throwIO (const (pure outcome)) result
  where
    scenarioThread handleVar resultVar = mask $ \restore → do
      session ← readMVar handleVar
      result ← try (restore (scenario session))
      case result of
        Left (failure ∷ SomeException) → do
          -- what the session looked like when the scenario gave up, for whoever reads the log
          status ← statusNow session
          out ← outLines (seWorld env)
          err ← errLines (seWorld env)
          hPutStrLn stderr ("scenario failed with " <> show failure <> "\n  status: " <> show status <> "\n  stdout: " <> show out <> "\n  stderr: " <> show err)
          requestStop session StopQuit
          putMVar resultVar (Left failure)
        Right () → putMVar resultVar (Right ())
      letScenarioGo env

-- | Several owned threads, started in nested scopes in order and ended and joined in the reverse order, each released with the
-- same opening first. The body is given their identities.
withOwnedThreadsOpening ∷ IO () → [IO ()] → ([ThreadId] → IO a) → IO a
withOwnedThreadsOpening open = go []
  where
    go started [] body = body (reverse started)
    go started (action : more) body = withOwnedThreadOpening open action (\thread _ → go (thread : started) more body)

-- | Let go what a scenario can be held at: the sink it held, and every gate of the pool's reader. Idempotent and never blocks,
-- so it is safe to run again from a release, and when the scenario never ran.
letScenarioGo ∷ SessionEnv → IO ()
letScenarioGo env = releaseSink (seWorld env) >> openEverything (wSession (seWorld env))

-- | An exception with the context it was raised with.
type Caught = ExceptionWithContext SomeException

-- | Run the session on this thread and a scenario on another, which is handed this thread's identity (to cancel it where
-- an example means to) and the session. Answers what the session raised or returned, with the handle. The scenario is
-- always waited for, and what it raises is raised here: a failed assertion in it is never swallowed. A session that
-- never exposed its handle (its entry was refused) cannot be run with this.
runCaught ∷ SessionEnv → Harness → (ThreadId → Session → IO ()) → IO (Either Caught SessionOutcome, Session)
runCaught env harness scenario = do
  driver ← myThreadId
  handleVar ← newEmptyMVar
  resultVar ← newEmptyMVar
  -- Owned by the call (#599): ended and joined however the call ends, with the held sink and the reader's gates let go first.
  ended ← withOwnedThreadOpening (letScenarioGo env) (scenarioThread driver handleVar resultVar) $ \thread terminated → do
    ended ← tryWithContext @SomeException (runSession (scenarioSpec env harness) (putMVar handleVar))
    finished ← try (bounded (readMVar resultVar))
    case finished of
      Left (ErrorCall why) → do
        killThread thread
        terminated
        throwIO (ErrorCall ("the scenario did not finish after the session ended: " <> why))
      Right result → do
        terminated
        either throwIO (const (pure ())) result
    pure ended
  session ← readMVar handleVar
  pure (ended, session)
  where
    scenarioThread driver handleVar resultVar = mask $ \restore → do
      session ← readMVar handleVar
      result ← try (restore (scenario driver session))
      case result of
        Left (failure ∷ SomeException) → do
          status ← statusNow session
          out ← outLines (seWorld env)
          hPutStrLn stderr ("scenario failed with " <> show failure <> "\n  status: " <> show status <> "\n  stdout: " <> show out)
          requestStop session StopQuit
          putMVar resultVar (Left failure)
        Right () → putMVar resultVar (Right ())
      letScenarioGo env

-- | The history the session holds now.
historyNow ∷ Session → IO History
historyNow = atomically . sessionHistory

-- | Wait until a thread is blocked in a throw to a thread that is not interruptible: it cannot have delivered anything.
awaitBlockedOnException ∷ ThreadId → IO ()
awaitBlockedOnException thread = bounded loop
  where
    loop =
      threadStatus thread >>= \case
        ThreadBlocked BlockedOnException → pure ()
        ThreadFinished → throwIO (userError "the thread ended instead of blocking in its throw")
        ThreadDied → throwIO (userError "the thread died instead of blocking in its throw")
        _ → yield >> loop

-- | What a session raised, as text; empty if it returned.
raisedMessage ∷ Either Caught SessionOutcome → Text
raisedMessage = \case
  Left (ExceptionWithContext _ raised) → Text.pack (displayException raised)
  Right _ → ""

-- | Whether what the session raised is a cancellation of the calling thread.
raisedKilled ∷ Either Caught SessionOutcome → Bool
raisedKilled = \case
  Left (ExceptionWithContext _ raised) → fromException raised == Just ThreadKilled
  Right _ → False

-- | Every message the outcome's engine report accounts for, the primary first.
outcomeMessages ∷ SessionOutcome → [Text]
outcomeMessages found = map eeMessage (maybe [] pure (erPrimary (outEngine found)) <> erSecondary (outEngine found))

-- | Block until the status satisfies this.
awaitStatus ∷ Session → (SessionStatus → Bool) → IO SessionStatus
awaitStatus session wanted = bounded . atomically $ do
  status ← sessionStatus session
  if wanted status then pure status else retry

-- | Block until this role is in this phase.
awaitPhase ∷ Session → Role → Phase → IO ()
awaitPhase session role phase = void (awaitStatus session (\status → fmap rolePhase (pick role status) == Just phase))

pick ∷ Role → SessionStatus → Maybe RoleStatus
pick Gameplay = statusGameplay
pick Presentation = statusPresentation

-- | The gameplay role's status, if present.
gameplayOf ∷ SessionStatus → Maybe RoleStatus
gameplayOf = statusGameplay

-- | The presentation role's status, if present.
presentationOf ∷ SessionStatus → Maybe RoleStatus
presentationOf = statusPresentation

-- | Both roles' phases, absent as 'Nothing'.
phasesOf ∷ SessionStatus → (Maybe Phase, Maybe Phase)
phasesOf status = (rolePhase <$> statusGameplay status, rolePhase <$> statusPresentation status)

-- | The status now.
statusNow ∷ Session → IO SessionStatus
statusNow = atomically . sessionStatus

-- | The outcome data now.
outcomeNow ∷ Session → IO SessionOutcome
outcomeNow = atomically . sessionOutcomeNow

-- Authoring -----------------------------------------------------------------------------------------

-- | Lua source lines.
type Lua = [Text]

-- | A line of Lua that prints the role it runs in and this text: @print("TEXT " .. api.role)@.
rolePrint ∷ Text → Text
rolePrint text = "print(\"" <> text <> " \" .. api.role)"

-- | A behavior whose hooks print these lines, each followed by the role: @init@, the update's tick and
-- @shutdown@'s reason.
printScript ∷ Script
printScript =
  script
    { scInit = [rolePrint "init"]
    , scUpdate = ["print(\"update \" .. api.role .. \" \" .. tostring(api.role == 'gameplay' and api.time.tick() or 0))"]
    , scShutdown = ["print(\"shutdown \" .. api.role .. \" \" .. tostring(reason))"]
    , scEverySeconds = "1"
    }

-- | The module source of a script.
roleScript ∷ Script → ByteString
roleScript = scriptSource

-- The pool's reader -------------------------------------------------------------------------------------

-- | The probe around the pool's reader, whose gates an example closes and opens.
ssProbeOf ∷ SessionEnv → Probe
ssProbeOf = ssProbe . wSession . seWorld

-- | Block until the pool's reader has been handed this path.
awaitReadOf ∷ SessionEnv → ByteString → IO ()
awaitReadOf env path = bounded loop
  where
    loop = do
      started ← startedPaths (ssProbeOf env)
      if path `elem` started then pure () else yield >> loop

-- Driving the clock ---------------------------------------------------------------------------------------

-- | A millisecond, which is the session's tick under the default setup.
tickMillis ∷ Word → Word
tickMillis = (* 1000000)

-- | Move the injected clock on and wake the timers once, with nothing to wait for.
nudge ∷ World → Word → IO ()
nudge world nanoseconds = advanceClock world (fromIntegral nanoseconds) >> fireTimers world

-- | Wait for the timer registration of exactly this many microseconds to be live, and then move the clock on and wake the
-- timers once: the wake cannot be lost to a registration that is not yet made.
nudgeArmed ∷ World → Int → Word → IO ()
nudgeArmed world micros nanoseconds = awaitRegistration world micros >> nudge world nanoseconds

-- | A setup with one more file in its content tree.
addFile ∷ (FilePath, ByteString) → Setup → Setup
addFile file found = found {suFiles = suFiles found <> [file]}

-- | Block until a timer registration of exactly this many microseconds is live: the coordinator has looked
-- at its clock and armed its timer for a tick that is due that long after the reading.
awaitRegistration ∷ World → Int → IO ()
awaitRegistration world micros = bounded loop
  where
    loop = do
      live ← liveRegistrations world
      if micros `elem` live then pure () else yield >> loop

-- | Whether every role the status has is retired.
retiredBoth ∷ SessionStatus → Bool
retiredBoth status = all ((== Retired) . rolePhase) (catMaybes [statusGameplay status, statusPresentation status])

-- | Block until every role is actually retired.
awaitRetired ∷ Session → IO SessionStatus
awaitRetired session = awaitStatus session retiredBoth

-- | Move the injected clock on and wake the timers until the condition holds. The coordinator looks at its
-- clock at each wake, so how often a wake is fired is not what an example depends on.
passTime ∷ World → Word → IO Bool → IO ()
passTime world nanoseconds condition = do
  advanceClock world (fromIntegral nanoseconds)
  pumpUntil world condition

-- | Block until stdout holds this many lines.
awaitOutputLines ∷ World → Int → IO [Text]
awaitOutputLines world count = bounded (awaitOut world count)

-- Probes ----------------------------------------------------------------------------------------------------

-- | The points the session has been through, in order, and the holds and failures an example set.
data Recorder = Recorder
  { rcPoints ∷ !(TVar [Point])
  , rcHolds ∷ !(TVar (Map Text Bool))
  -- ^ A point's name held (True) or not.
  , rcFails ∷ !(TVar (Map Text Caught))
  }

newRecorder ∷ IO Recorder
newRecorder = Recorder <$> newTVarIO [] <*> newTVarIO Map.empty <*> newTVarIO Map.empty

-- | The points so far, oldest first.
recorded ∷ Recorder → IO [Point]
recorded = fmap reverse . readTVarIO . rcPoints

-- | A harness that records every point, parks the thread that reaches a held one until it is released and
-- raises what an example made a point raise.
recordingHarness ∷ Recorder → Harness → Harness
recordingHarness recorder base =
  base
    { harnessProbe = \point → do
        harnessProbe base point
        let name = pointName point
        atomically (modifyTVar' (rcPoints recorder) (point :))
        atomically (readTVar (rcHolds recorder) >>= \holds → when (Map.lookup name holds == Just True) retry)
        raised ← Map.lookup name <$> readTVarIO (rcFails recorder)
        maybe (pure ()) rethrowIO raised
    , -- a release is finite and never held: the recorder notes it and raises what an example made it raise
      harnessRelease = \release → do
        harnessRelease base release
        let point = Released release
        atomically (modifyTVar' (rcPoints recorder) (point :))
        raised ← Map.lookup (pointName point) <$> readTVarIO (rcFails recorder)
        maybe (pure ()) rethrowIO raised
    }

-- | A point as a name an example can hold or fail it by.
pointName ∷ Point → Text
pointName = Text.pack . show

-- | Block until the session has been through this point.
awaitPoint ∷ Recorder → Point → IO ()
awaitPoint recorder point = bounded . atomically $ do
  seen ← readTVar (rcPoints recorder)
  when (point `notElem` seen) retry

-- | Hold the thread that next reaches this point.
holdAt ∷ Recorder → Point → IO ()
holdAt recorder point = atomically (modifyTVar' (rcHolds recorder) (Map.insert (pointName point) True))

-- | Let a held point go.
releaseHold ∷ Recorder → Point → IO ()
releaseHold recorder point = atomically (modifyTVar' (rcHolds recorder) (Map.insert (pointName point) False))

-- | Make the thread that reaches this point raise this.
failAt ∷ Recorder → Point → SomeException → IO ()
failAt recorder point failure = failWith recorder point (ExceptionWithContext emptyExceptionContext failure)

-- | The same, raising an exception that carries the context it was caught with: the cleanup failures it carries stay.
failWith ∷ Recorder → Point → Caught → IO ()
failWith recorder point failure = atomically (modifyTVar' (rcFails recorder) (Map.insert (pointName point) failure))
