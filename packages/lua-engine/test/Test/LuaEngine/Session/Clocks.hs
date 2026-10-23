{-# LANGUAGE OverloadedStrings #-}

-- | The session's two clocks: the logical clock, whose ticks the coordinator grants at a real-time rate over
-- the Lua host's scheduler, and the presentation role's elapsed clock, which its own owner keeps. The
-- injected clock and the fake timer move only when an example moves them, so a tick or a refresh is due when
-- the example says it is.
module Test.LuaEngine.Session.Clocks (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, retry, writeTVar)
import Control.Monad (void, when)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.LuaEngine.Session.Pacing (luaTickCeiling)
import Test.Hspec
import Test.LuaEngine.Session.Support

spec ∷ Spec
spec = describe "clocks" $ do
  logical
  interleaving
  elapsed
  limits

-- | The lines of the output that begin with this.
linesWith ∷ Text → World → IO [Text]
linesWith prefix world = filter (prefix `Text.isPrefixOf`) <$> outLines world

-- | The tick numbers of the grants the coordinator issued, in order.
grantsIssued ∷ Recorder → IO [Word64]
grantsIssued recorder = (\points → [number | GrantIssued number ← points]) <$> recorded recorder

-- | A gameplay-only script whose update prints its tick and its @dt@.
ticking ∷ Script
ticking =
  printScript
    { scInit = []
    , scShutdown = []
    , scUpdate = ["print(string.format('tick %d dt %.9f', api.time.tick(), dt))"]
    }

-- The logical clock -----------------------------------------------------------------------------------------

logical ∷ Spec
logical = describe "the logical clock" $ do
  it "grants every tick that is due, one at a time and in order, each exactly the manifest's duration, none skipped or merged" $
    withSetup ((setup (roleScript ticking)) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      void . runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        -- three ticks of wall time pass at once: three ticks are granted, not one stretched tick
        passTime world 3000000 ((>= 3) . length <$> linesWith "tick" world)
        out ← linesWith "tick" world
        take 3 out `shouldBe` ["tick 1 dt 0.001000000", "tick 2 dt 0.001000000", "tick 3 dt 0.001000000"]
        grants ← grantsIssued recorder
        take 3 grants `shouldBe` [1, 2, 3]
        requestStop session StopQuit

  it "leaves the logical time where it is while a slow hook holds a tick, and never skips a tick afterwards" $
    withSetup ((setup (roleScript ticking)) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      holdSink world "tick 1 dt 0.001000000"
      void . runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        advanceClock world 1000000
        fireTimers world
        awaitSinkEntered world "tick 1 dt 0.001000000"
        -- four more ticks of wall time pass while the first tick's hook is still running
        advanceClock world 4000000
        fireTimers world
        releaseSink world
        pumpUntil world ((>= 5) . length <$> linesWith "tick" world)
        out ← linesWith "tick" world
        map (Text.takeWhile (/= ' ') . Text.drop 5) (take 5 out) `shouldBe` ["1", "2", "3", "4", "5"]
        requestStop session StopQuit

  it "owes nothing for the wall time before the gate opened, and none after it is behind" $
    withSetup ((setup (roleScript ticking)) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched g0)
      void . runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPoint recorder (Dispatched g0)
        -- a second of wall time passes before the init runs
        advanceClock world 1000000000
        releaseHold recorder (Dispatched g0)
        awaitPhase session Gameplay Running
        -- the first tick is due one tick after the gate opened
        awaitRegistration world 1000
        out ← linesWith "tick" world
        out `shouldBe` []
        passTime world 1000000 ((>= 1) . length <$> linesWith "tick" world)
        out' ← linesWith "tick" world
        take 1 out' `shouldBe` ["tick 1 dt 0.001000000"]
        requestStop session StopQuit

  it "takes the origin before the gate's own diagnostics can delay it: a logger held at the gate's opening owes the time it held" $
    withSetup ((setup (roleScript ticking)) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      held ← newTVarIO True
      let logger =
            mkLogger defaultLogFilter . callbackSink $ \entry →
              when (entryMessage entry == "start gate opened") (atomically (readTVar held >>= \isHeld → when isHeld retry))
          env' = env {seSpec = (seSpec env) {sxLogger = logger}}
      void . runScenario env' $ \session → do
        -- the gate has opened in the state; the driver is stuck in the logger that says so
        awaitPhase session Gameplay Running
        advanceClock world 5000000
        atomically (writeTVar held False)
        -- five ticks of the time that passed while the diagnostic was held are owed, each granted by itself
        passTime world 1000000 ((>= 5) . length <$> linesWith "tick" world)
        out ← linesWith "tick" world
        take 5 out `shouldBe` ["tick 1 dt 0.001000000", "tick 2 dt 0.001000000", "tick 3 dt 0.001000000", "tick 4 dt 0.001000000", "tick 5 dt 0.001000000"]
        requestStop session StopQuit

-- Two instances on one VM -----------------------------------------------------------------------------------------------

interleaving ∷ Spec
interleaving = describe "two admitted instances" $ do
  it "serves them first in, first out, with a yielding hook going behind the other's ready work" $
    withSetup
      (setup (roleScript printScript {scInit = [], scShutdown = [], scUpdate = ["if api.role == 'gameplay' then print('a ' .. api.instance_id .. ' ' .. api.time.tick()); api.time.yield(); print('b ' .. api.instance_id .. ' ' .. api.time.tick()) end"]}))
        { suShape = GameplayAlone
        , suHarness = noHarness {harnessSecond = [Gameplay]}
        }
      $ \env → do
        let world = seWorld env
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          passTime world 1000000 ((>= 4) . length <$> outLines world)
          out ← outLines world
          take 4 out `shouldBe` ["a inst-1 1", "a inst-2 1", "b inst-1 1", "b inst-2 1"]
          requestStop session StopQuit

  it "never starts an update on an instance whose earlier update is still suspended in a wait" $
    withSetup
      ((setup (roleScript printScript {scInit = [], scShutdown = [], scUpdate = ["if api.role == 'gameplay' then print('start ' .. api.time.tick()); api.time.wait_ticks(2); print('end ' .. api.time.tick()) end"]})) {suShape = GameplayAlone})
      $ \env → do
        let world = seWorld env
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          passTime world 4000000 (elem "start 4" <$> outLines world)
          out ← outLines world
          take 3 out `shouldBe` ["start 1", "end 3", "start 4"]
          requestStop session StopQuit

-- The elapsed clock ------------------------------------------------------------------------------------------------------------

elapsed ∷ Spec
elapsed = describe "the presentation role's elapsed clock" $ do
  let uiScript = printScript {scInit = [], scShutdown = [], scUpdate = ["print(string.format('ui seconds %.1f dt %.3f', api.time.seconds(), dt))"]}

  it "coalesces the refreshes a stall missed into one, handed the time that actually passed, and goes on from the next point in the future" $
    withSetup ((setup (roleScript uiScript)) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      void . runScenario env $ \session → do
        awaitPhase session Presentation Running
        -- three and a half cadences pass at once
        passTime world 3500000000 (elem "ui seconds 3.5 dt 3.500" <$> outLines world)
        passTime world 500000000 (elem "ui seconds 4.0 dt 0.500" <$> outLines world)
        out ← linesWith "ui" world
        out `shouldBe` ["ui seconds 3.5 dt 3.500", "ui seconds 4.0 dt 0.500"]
        requestStop session StopQuit

  it "starts its cadence from its own successful init while its public elapsed time starts at the root init's start" $
    withSetup
      ((setup (roleScript uiScript {scInit = ["print('ui init')"]})) {suShape = PresentationAlone})
      $ \env → do
        let world = seWorld env
        holdSink world "ui init"
        void . runScenario env $ \session → do
          awaitSinkEntered world "ui init"
          -- five seconds pass inside the init
          advanceClock world 5000000000
          releaseSink world
          awaitPhase session Presentation Running
          -- the first refresh is a second after the init succeeded, which is six seconds after the init began
          passTime world 1000000000 (elem "ui seconds 6.0 dt 1.000" <$> outLines world)
          requestStop session StopQuit

-- Arithmetic at the limits --------------------------------------------------------------------------------------------------------

limits ∷ Spec
limits = describe "arithmetic at the limits" $ do
  it "grants the last tick a Lua integer holds and ends the session instead of granting the next, never publishing a wrapped tick" $
    withSetup ((setup (roleScript ticking)) {suShape = GameplayAlone, suHarness = noHarness {harnessTickBase = luaTickCeiling' - 1}}) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      outcome ← runScenarioWith env (recordingHarness recorder (sxHarness (seSpec env))) $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "tick 9223372036854775807 dt 0.001000000" <$> outLines world)
        -- the next tick is past what a Lua integer holds: the clock offers it, and the session ends
        advanceClock world 1000000
        fireTimers world
        void (awaitRetired session)
      out ← linesWith "tick" world
      out `shouldBe` ["tick 9223372036854775807 dt 0.001000000"]
      grants ← grantsIssued recorder
      grants `shouldBe` [luaTickCeiling']
      outVerdict outcome `shouldBe` VerdictFailure
      fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
      fmap eeStage (erPrimary (outEngine outcome)) `shouldBe` Just OnEngine
      fmap (Text.isInfixOf "Lua integer" . eeMessage) (erPrimary (outEngine outcome)) `shouldBe` Just True

  it "refuses a first deadline the clock cannot count before any Lua runs" $
    withSetup ((setup (roleScript ticking)) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      setClock world (maxBound - 5)
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines world
      out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictFailure
      fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
      fmap (Text.isInfixOf "past the end of the clock" . eeMessage) (erPrimary (outEngine outcome)) `shouldBe` Just True
      fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]

  it "ends the session when a later deadline passes the end of the clock, after the tick that was due, never wrapping" $
    withSetup ((setup (roleScript ticking)) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      -- room for exactly one tick after the gate opens
      setClock world (maxBound - 1500000)
      recorder ← newRecorder
      outcome ← runScenarioWith env (recordingHarness recorder (sxHarness (seSpec env))) $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "tick 1 dt 0.001000000" <$> outLines world)
        void (awaitRetired session)
      out ← linesWith "tick" world
      out `shouldBe` ["tick 1 dt 0.001000000"]
      grants ← grantsIssued recorder
      grants `shouldBe` [1]
      outVerdict outcome `shouldBe` VerdictFailure
      fmap (Text.isInfixOf "past the end of the clock" . eeMessage) (erPrimary (outEngine outcome)) `shouldBe` Just True
  where
    luaTickCeiling' = luaTickCeiling

g0 ∷ InstanceKey
g0 = InstanceKey Gameplay 0
