{-# LANGUAGE OverloadedStrings #-}

-- | How a session starts: the validation that precedes both roots, the dispatch of their @init@s, the
-- order they finish in, the first logical tick, and a stop or a failure on each side of each gate.
--
-- Every example runs real Lua on real supervised owners the coordinator starts, over a real content root
-- and manifest. What an example holds it holds with a gate (a sink that parks the writer of one line, a
-- harness point that parks the thread that reaches it, a read the pool's reader parks), and it knows what
-- has happened from what the Lua printed or from the status, never from a delay.
module Test.LuaEngine.Session.Startup (spec) where

import Control.Monad (void)
import Data.List (isInfixOf)
import Data.Maybe (catMaybes)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, openGate)
import Test.LuaEngine.Session.Support

spec ∷ Spec
spec = describe "startup" $ do
  orders
  composition
  validation
  windows
  content

g0, p0 ∷ InstanceKey
g0 = InstanceKey Gameplay 0
p0 = InstanceKey Presentation 0

-- | The positions of the lines among the output, for an ordering the example asserts.
positionOf ∷ Text → [Text] → Maybe Int
positionOf line out = lookup line (zip out [0 ..])

-- The order the roots' inits finish in ----------------------------------------------------------------------

orders ∷ Spec
orders = describe "the roots' inits" $ do
  it "starts the presentation role on its own success while the logical init is held, and opens the logical clock only at the joint gate, owing no time for the wait" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched g0)
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPoint recorder (Dispatched g0)
        awaitPhase session Presentation Running
        status ← statusNow session
        phasesOf status `shouldBe` (Just Starting, Just Running)
        (roleInitialized <$> gameplayOf status) `shouldBe` Just False
        (roleInitialized <$> presentationOf status) `shouldBe` Just True
        statusStopping status `shouldBe` False
        -- the presentation role's services run while the logical init is held
        passTime world 1000000000 (elem "update presentation 0" <$> outLines world)
        -- ten milliseconds of wall time the logical role must not earn
        advanceClock world 10000000
        releaseHold recorder (Dispatched g0)
        awaitPhase session Gameplay Running
        -- the first tick is due one tick after the instant the gate opened, not one tick after the start
        awaitRegistration world 1000
        passTime world 1000000 (elem "update gameplay 1" <$> outLines world)
        requestStop session StopQuit
      outVerdict outcome `shouldBe` VerdictSuccess
      outRetired outcome `shouldBe` True

  it "waits ready, with no tick, when the logical init finishes first, and opens at the presentation init's success" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched p0)
      void . runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPoint recorder (Dispatched p0)
        awaitPhase session Gameplay Ready
        status ← statusNow session
        phasesOf status `shouldBe` (Just Ready, Just Starting)
        (roleInitialized <$> gameplayOf status) `shouldBe` Just True
        advanceClock world 10000000
        releaseHold recorder (Dispatched p0)
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "update gameplay 1" <$> outLines world)
        requestStop session StopQuit

  it "dispatches both inits without either waiting for the other to finish" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched g0)
      holdAt recorder (Dispatched p0)
      void . runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        -- both are dispatched, neither has run a line, and so neither waited for the other to finish
        awaitPoint recorder (Dispatched g0)
        awaitPoint recorder (Dispatched p0)
        out ← outLines world
        out `shouldBe` []
        status ← statusNow session
        phasesOf status `shouldBe` (Just Starting, Just Starting)
        releaseHold recorder (Dispatched g0)
        releaseHold recorder (Dispatched p0)
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit

  it "starts the presentation role while a logical init is running in Lua, parked in its sink" $
    withSetup (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then print('init gameplay') end"]})) $ \env → do
      let world = seWorld env
      holdSink world "init gameplay"
      void . runScenario env $ \session → do
        awaitSinkEntered world "init gameplay"
        awaitPhase session Presentation Running
        status ← statusNow session
        (rolePhase <$> gameplayOf status) `shouldBe` Just Starting
        releaseSink world
        awaitPhase session Gameplay Running
        requestStop session StopQuit

-- Composition ------------------------------------------------------------------------------------------------------------

composition ∷ Spec
composition = describe "the composition" $ do
  it "evaluates a common entry separately in each VM, whatever order the manifest lists the roles" $
    mapM_
      ( \reversed →
          withSetup ((setup (roleScript printScript {scPrelude = ["print('load')"]})) {suReversed = reversed}) $ \env → do
            let world = seWorld env
            void . runScenario env $ \session → do
              awaitPhase session Gameplay Running
              awaitPhase session Presentation Running
              out ← outLines world
              length (filter (== "load") out) `shouldBe` 2
              requestStop session StopQuit
      )
      [False, True]

  it "gives each role its own entry when the manifest names them" $
    withSetup
      (setup (roleScript printScript))
        { suEntries = Just ("lua/game.lua", "lua/ui.lua")
        , suFiles =
            [ ("lua/game.lua", roleScript printScript {scPrelude = ["print('load game')"]})
            , ("lua/ui.lua", roleScript printScript {scPrelude = ["print('load ui')"]})
            ]
        }
      $ \env → do
        let world = seWorld env
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          out ← outLines world
          (filter ("load" `Text.isPrefixOf`) out) `shouldMatchList` ["load game", "load ui"]
          requestStop session StopQuit

  it "runs a gameplay-only session from its own init, and a presentation-only one from its own" $ do
    withSetup ((setup (roleScript printScript)) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      void . runScenario env $ \session → do
        awaitPhase session Gameplay Running
        status ← statusNow session
        presentationOf status `shouldBe` Nothing
        awaitRegistration world 1000
        passTime world 1000000 (elem "update gameplay 1" <$> outLines world)
        requestStop session StopQuit
    withSetup ((setup (roleScript printScript)) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      void . runScenario env $ \session → do
        awaitPhase session Presentation Running
        status ← statusNow session
        gameplayOf status `shouldBe` Nothing
        passTime world 1000000000 (elem "update presentation 0" <$> outLines world)
        requestStop session StopQuit

  it "treats a missing init as the successful empty one" $
    withSetup (setup (roleScript printScript {scHasInit = False})) $ \env → do
      let world = seWorld env
      void . runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        status ← statusNow session
        (roleInitialized <$> gameplayOf status) `shouldBe` Just True
        out ← outLines world
        filter ("init" `Text.isPrefixOf`) out `shouldBe` []
        requestStop session StopQuit

-- Validation before either init ------------------------------------------------------------------------------------------

validation ∷ Spec
validation = describe "validation before either root is dispatched" $ do
  it "starts neither root when the second role's cadence is invalid" $
    withSetup (setup (roleScript printScript {scEverySeconds = "nil"})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines world
      out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictFailure
      case outFailures outcome of
        [found] → do
          rfRole found `shouldBe` Presentation
          rfCode found `shouldBe` ModuleError
          rfStage found `shouldBe` OnModule
          rfInstance found `shouldSatisfy` (/= Nothing)
        other → expectationFailure ("expected one failure, found " <> show other)

  it "validates every instance of the role before any init runs, so a first init that edits the behavior cannot invalidate the second after the roots have run" $
    withSetup
      (setup (roleScript printScript))
        { suShape = GameplayAlone
        , suEntries = Just ("lua/game.lua", "lua/ui.lua")
        , suHarness = noHarness {harnessSecond = [Gameplay]}
        , suFiles =
            [ ( "lua/game.lua"
              , luaMain
                  [ "local behavior"
                  , "behavior = {"
                  , "  every_ticks = 1,"
                  , "  init = function(self, api) print('init ' .. api.instance_id) behavior.every_ticks = 0 end,"
                  , "  update = function() end,"
                  , "}"
                  , "return { gameplay = behavior }"
                  ]
              )
            , ("lua/ui.lua", roleScript printScript)
            ]
        }
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → do
          awaitPhase session Gameplay Running
          requestStop session StopQuit
          void (awaitRetired session)
        out ← outLines world
        -- both captured the behavior before either init ran, so the second is valid whatever the first did
        filter (Text.isPrefixOf "init") out `shouldBe` ["init inst-1", "init inst-2"]
        outFailures outcome `shouldBe` []
        outVerdict outcome `shouldBe` VerdictSuccess

  it "starts neither root when the first role's cadence is invalid either" $
    withSetup
      (setup (roleScript printScript))
        { suEntries = Just ("lua/game.lua", "lua/ui.lua")
        , suFiles =
            [ ("lua/game.lua", luaMain ["return { gameplay = { every_ticks = 0, init = function(self, api) print('init gameplay') end, update = function() end } }"])
            , ("lua/ui.lua", roleScript printScript)
            ]
        }
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → void (awaitRetired session)
        out ← outLines world
        out `shouldBe` []
        fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]
        fmap rfStage (outFailures outcome) `shouldBe` [OnModule]

  it "latches a boot failure the moment its entry answers, in either role, while the other role's entry is still being read" $
    mapM_
      ( \(failing, brokenPath, heldPath) →
          withSetup
            (setup (roleScript printScript))
              { suEntries = Just ("lua/game.lua", "lua/ui.lua")
              , suFiles =
                  [ ("lua/game.lua", if brokenPath == "lua/game.lua" then luaMain ["return {"] else roleScript printScript)
                  , ("lua/ui.lua", if brokenPath == "lua/ui.lua" then luaMain ["return {"] else roleScript printScript)
                  ]
              }
            $ \env → do
              let world = seWorld env
              closeGate (ssProbeOf env) (fromString heldPath)
              outcome ← runScenario env $ \session → do
                awaitReadOf env (fromString heldPath)
                -- the peer's entry is held in the middle of its read; the failure is published and the session stops anyway
                status ← awaitStatus session (\found → any roleFailed (catMaybes [statusGameplay found, statusPresentation found]))
                statusStopping status `shouldBe` True
                openGate (ssProbeOf env) (fromString heldPath)
                void (awaitRetired session)
              out ← outLines world
              out `shouldBe` []
              fmap rfRole (outFailures outcome) `shouldBe` [failing]
              fmap rfStage (outFailures outcome) `shouldBe` [OnModule]
      )
      ([(Gameplay, "lua/game.lua", "lua/ui.lua"), (Presentation, "lua/ui.lua", "lua/game.lua")] ∷ [(Role, FilePath, FilePath)])

  it "carries the traceback of a module-only boot failure into the role's failure record, with no instance" $
    withSetup
      (setup (roleScript printScript))
        { suShape = GameplayAlone
        , suEntries = Just ("lua/game.lua", "lua/ui.lua")
        , suFiles =
            [ ("lua/game.lua", luaMain ["local function inner() error('entry boom') end", "local function outer() inner() end", "outer()"])
            , ("lua/ui.lua", roleScript printScript)
            ]
        }
      $ \env → do
        outcome ← runScenario env $ \session → void (awaitRetired session)
        case outFailures outcome of
          [found] → do
            rfInstance found `shouldBe` Nothing
            rfMessage found `shouldSatisfy` Text.isInfixOf "entry boom"
            rfTraceback found `shouldSatisfy` maybe False (Text.isInfixOf "inner")
          other → expectationFailure ("expected one failure, found " <> show other)

  it "starts neither root when an entry does not evaluate, and attributes the failure to the module, with no instance" $
    withSetup
      (setup (roleScript printScript))
        { suEntries = Just ("lua/game.lua", "lua/ui.lua")
        , suFiles =
            [ ("lua/game.lua", roleScript printScript)
            , ("lua/ui.lua", luaMain ["return {"])
            ]
        }
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → void (awaitRetired session)
        out ← outLines world
        out `shouldBe` []
        case outFailures outcome of
          [found] → do
            rfRole found `shouldBe` Presentation
            rfCode found `shouldBe` ModuleError
            rfStage found `shouldBe` OnModule
            rfInstance found `shouldBe` Nothing
            rfPath found `shouldBe` Just "lua/ui.lua"
          other → expectationFailure ("expected one failure, found " <> show other)

-- A stop or a failure on each side of each gate ----------------------------------------------------------------------------------

windows ∷ Spec
windows = describe "stop and failure on each side of the gates" $ do
  let -- a stop in a window ends the session without running either root
      stopIn point = withSetup (setup (roleScript printScript)) $ \env → do
        recorder ← newRecorder
        holdAt recorder point
        outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
          awaitPoint recorder point
          requestStop session StopQuit
          releaseHold recorder point
        out ← outLines (seWorld env)
        pure (outcome, out)

  it "stops between the intent and the issuance of a root without admitting it" $ do
    (outcome, out) ← stopIn (Intended g0)
    out `shouldBe` []
    outVerdict outcome `shouldBe` VerdictSuccess
    outRetired outcome `shouldBe` True

  it "stops after the owner accepted a root and before it was tracked: the root cannot run until it is tracked, and then it must not" $ do
    (outcome, out) ← stopIn (Issued g0)
    out `shouldBe` []
    outVerdict outcome `shouldBe` VerdictSuccess
    outRetired outcome `shouldBe` True

  it "stops while a root waits at the dispatch gate: its init does not run, and neither does the other's" $ do
    (outcome, out) ← stopIn (Validating p0)
    out `shouldBe` []
    outVerdict outcome `shouldBe` VerdictSuccess
    outRetired outcome `shouldBe` True

  it "stops while a role is still being built: the owner it gets afterwards is asked to stop as it appears, and no root runs" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      let building = Built Presentation BuildCoordinator
      holdAt recorder building
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        -- the logical role is built and has its stopper; the presentation role has nothing yet
        awaitPoint recorder building
        requestStop session StopQuit
        releaseHold recorder building
      out ← outLines (seWorld env)
      out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictSuccess
      outRetired outcome `shouldBe` True

  it "stops while either init is held: the init that succeeds late is shut down as stopped, and the gate stays shut" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched g0)
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPoint recorder (Dispatched g0)
        awaitPhase session Presentation Running
        requestStop session StopQuit
        releaseHold recorder (Dispatched g0)
      out ← outLines world
      out `shouldSatisfy` elem "init gameplay"
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      out `shouldSatisfy` elem "shutdown presentation stopped"
      filter ("update gameplay" `Text.isPrefixOf`) out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictSuccess

  it "stops just before the joint gate would open: the late success is eligible for shutdown and cannot open it" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched p0)
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPoint recorder (Dispatched p0)
        awaitPhase session Gameplay Ready
        requestStop session StopInterrupt
        releaseHold recorder (Dispatched p0)
      out ← outLines world
      out `shouldSatisfy` elem "shutdown presentation stopped"
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      filter ("update" `Text.isPrefixOf`) out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictInterrupted

  it "stops while a logical init is running in Lua, and a late success is still shut down" $
    withSetup (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then print('init gameplay') end"]})) $ \env → do
      let world = seWorld env
      holdSink world "init gameplay"
      outcome ← runScenario env $ \session → do
        awaitSinkEntered world "init gameplay"
        awaitPhase session Presentation Running
        requestStop session StopQuit
        releaseSink world
      out ← outLines world
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      filter ("update gameplay" `Text.isPrefixOf`) out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictSuccess

  it "fails the boot when an init fails after the other role's init succeeded, shutting the survivor down and giving the failed init no shutdown" $
    withSetup (setup (roleScript printScript {scInit = [rolePrint "init", "if api.role == 'gameplay' then error('init failed') end"]})) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched g0)
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPoint recorder (Dispatched g0)
        awaitPhase session Presentation Running
        releaseHold recorder (Dispatched g0)
        void (awaitRetired session)
      out ← outLines world
      out `shouldSatisfy` elem "shutdown presentation stopped"
      out `shouldSatisfy` (not . any ("shutdown gameplay" `Text.isPrefixOf`))
      outVerdict outcome `shouldBe` VerdictFailure
      case outFailures outcome of
        found : _ → do
          rfRole found `shouldBe` Gameplay
          rfCode found `shouldBe` LuaError
          rfStage found `shouldBe` OnInit
          rfMessage found `shouldSatisfy` (Text.isInfixOf "init failed")
          rfContent found `shouldBe` Just "modules-test"
        [] → expectationFailure "expected the failure"

  it "does not wait for the other init to report before asking it to stop" $
    withSetup (setup (roleScript printScript {scInit = [rolePrint "init", "if api.role == 'presentation' then error('ui failed') end"]})) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched g0)
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPoint recorder (Dispatched g0)
        -- the presentation init failed while the gameplay init is still held: both are already stopping
        void (awaitStatus session (\status → fmap rolePhase (gameplayOf status) == Just Stopping))
        status ← statusNow session
        statusStopping status `shouldBe` True
        fmap roleFailed (presentationOf status) `shouldBe` Just True
        fmap roleFailed (gameplayOf status) `shouldBe` Just False
        releaseHold recorder (Dispatched g0)
      out ← outLines world
      -- the held init returns, succeeds late, and is shut down as stopped; it never started a tick
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      filter ("update gameplay" `Text.isPrefixOf`) out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictFailure
      fmap rfRole (outFailures outcome) `shouldBe` [Presentation]

-- Content requested at startup -----------------------------------------------------------------------------------------------------

content ∷ Spec
content = describe "content requested during init" $ do
  it "does not hold the startup gate, and delays only its assigned tick" $
    withSetup
      (setup (roleScript printScript))
        { suFiles =
            [ ( "lua/main.lua"
              , roleScript
                  printScript
                    { scInit = [rolePrint "init", "if api.role == 'gameplay' then self.request = api.content.data('lua/data.bin') end"]
                    , scUpdate = ["if api.role == 'gameplay' then local taken = api.request.take(self.request); print('data ' .. taken.status) end", "print('update ' .. api.role .. ' ' .. tostring(api.role == 'gameplay' and api.time.tick() or 0))"]
                    }
              )
            , ("lua/data.bin", "payload")
            ]
        }
      $ \env → do
        let world = seWorld env
            probe = ssProbeOf env
        closeGate probe "lua/data.bin"
        void . runScenario env $ \session → do
          -- the logical role is running although its request is pending
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          awaitRegistration world 1000
          advanceClock world 1000000
          fireTimers world
          awaitReadOf env "lua/data.bin"
          -- the presentation role goes on while the logical tick waits for its content
          passTime world 1000000000 (elem "update presentation 0" <$> outLines world)
          openGate probe "lua/data.bin"
          passTime world 0 (elem "update gameplay 1" <$> outLines world)
          out ← outLines world
          let ui = positionOf "update presentation 0" out
              tick = positionOf "update gameplay 1" out
          (ui, tick) `shouldSatisfy` (\(a, b) → a < b)
          out `shouldSatisfy` any ("data success" `isInfixOf`) . map Text.unpack
          requestStop session StopQuit
