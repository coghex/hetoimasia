{-# LANGUAGE OverloadedStrings #-}

-- | What the terrain examples share: the real terrain service (TRA-4) in its own worker group, the real adapter over it, and
-- real Lua instances of real supervised owners (the facade's world) that call @api.terrain@.
--
-- The service, the adapter, the facade, the owners and the Lua are real. What an example injects is only a /window/: the
-- owner's probe, which holds the terrain owner at a named point so that an example decides which side of a race wins by what it
-- does and never by how long it waits; and the adapter's hooks. No example sleeps.
module Test.LuaEngine.Terrain.Support
  ( Rig (..)
  , withRig
  , withRigConfig
  , withRigProbe
  , withRigHooks
  , holdAt
  , defaultConfigForRaces
  , noProbeForRaces
  , presentationOver
  , presentationOverSession
  , gameplayOver
  , soilOverStone
  , terrainPrelude
  , Step (..)
  , stepsScript
  , tightRigConfig
  , signalRig
  , Case (..)
  , Verdict (..)
  , caseLua
  , checkCases
  , limitHeld
  , observeCell
  , arenaName
  , untilPrinted
  , untilPrintedBy
  , Gate
  , newGate
  , gatedProbe
  , removalProbe
  , awaitReached
  , pumpUntilReached
  , openGate
  , armGate
  , disarmGate
  ) where

import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, tryPutMVar, tryTakeMVar)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (onException)
import Control.Monad (void, when)
import Data.List (find)
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, hashUnique, newUnique)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.LuaEngine.Facade (terrainPickType)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Registration (Binding, asynchronousNativeRequestIn)
import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability, SInteger, SText), Value (VInteger, VText))
import Hetoimasia.LuaEngine.Terrain
import Hetoimasia.Terrain.Cell (Cell (..), materialIdString)
import Hetoimasia.Terrain.Coordinate (tileCoord)
import Hetoimasia.Terrain.Residency (LimitsSpec (..), Revision (..), mkLimits)
import Data.Maybe (fromMaybe, listToMaybe)
import Hetoimasia.Terrain.Runtime
import Test.Hspec (Expectation, expectationFailure)
import Hetoimasia.Scripting.Lua.Instance (InstanceFailure (failureMessage))
import qualified Hetoimasia.Scripting.Lua.Instance as Instance
import Test.LuaEngine.Facade.Support (Script (..), Spawned, VmShape (..), World, advanceClock, errLines, gameplayShape, outLines, phaseOf, presentationShape, pumpUntil, script, settledFailure)
import Test.Support.Bounded (bounded)

-- | The real service and the adapter over it.
data Rig = Rig
  { rgService ∷ !Service
  , rgFacade ∷ !TerrainFacade
  , rgSession ∷ !Unique
  , rgPicks ∷ !TerrainPicks
  , rgSignals ∷ !(TVar (Set.Set Text))
  -- ^ The names an example has signalled: @TEST_WAIT(name)@ returns once its name is among them.
  }

quiet ∷ Logger
quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))

-- | A rig over the default service configuration and no probe.
withRig ∷ (Rig → IO a) → IO a
withRig = withRigProbe defaultConfig noProbe

withRigConfig ∷ Config → (Rig → IO a) → IO a
withRigConfig config = withRigProbe config noProbe

withRigProbe ∷ Config → Probe → (Rig → IO a) → IO a
withRigProbe config probe = withRigHooks config probe noTerrainHooks

-- | A rig whose adapter tells these hooks of the windows a race is decided in.
withRigHooks ∷ Config → Probe → TerrainHooks → (Rig → IO a) → IO a
withRigHooks config probe terrainHooks body =
  withWorkerGroup $ \group →
    withTerrainService config (Ports alwaysAdmitting (standaloneSupervisor group) quiet probe) $ \service → do
      facade ← newTerrainFacade fixedM1Profile service config
      session ← newUnique
      signals ← newTVarIO Set.empty
      body
        Rig
          { rgService = service
          , rgFacade = facade {tfHooks = terrainHooks, tfExtraBindings = [pickFixture, awaitOfferFixture facade, waitFixture signals]}
          , rgSession = session
          , rgPicks = tfPicks facade
          , rgSignals = signals
          }

presentationOver, gameplayOver ∷ Rig → VmShape
presentationOver rig = presentationShape {shTerrain = Just (terrainInjection (rgFacade rig), rgSession rig), shInitialChunks = pickChunk}
gameplayOver rig = gameplayShape {shTerrain = Just (terrainInjection (rgFacade rig), rgSession rig), shInitialChunks = pickChunk}

-- | The same VM of another session over the same service: its names are its own.
presentationOverSession ∷ Rig → Unique → VmShape
presentationOverSession rig session = (presentationOver rig) {shTerrain = Just (terrainInjection (rgFacade rig), session)}

-- | How a fixture hands a script a pick authority the host issued: @TEST_PICK(key)@. It is a host-created fixture of the seam
-- and nothing Lua can construct: a real script has no such function.
pickChunk ∷ [Text]
pickChunk = ["TEST_PICK = hetoimasia_engine.terrain_test_pick", "TEST_AWAIT_OFFER = hetoimasia_engine.terrain_test_await_offer", "TEST_WAIT = hetoimasia_engine.terrain_test_wait"]

pickFixture ∷ Binding
pickFixture =
  asynchronousNativeRequestIn "terrain_test_pick" [SInteger] [SCapability terrainPickType] $ \_ values → case values of
    [VInteger key] → pure [pickValue (fromIntegral key)]
    _ → pure []

-- | How a fixture holds a script until the example says so: @TEST_WAIT(name)@ returns once the example has signalled that name
-- ('signalRig'). It runs on the script's own thread and waits on the rig's own state and nothing else; a real script has no such function.
waitFixture ∷ TVar (Set.Set Text) → Binding
waitFixture signals =
  asynchronousNativeRequestIn "terrain_test_wait" [SText] [] $ \_ values → case values of
    [VText name] → [] <$ bounded (atomically (readTVar signals >>= \seen → if Set.member name seen then pure () else retry))
    _ → pure []

-- | Say that this name's moment has come: the scripts waiting on it go on.
signalRig ∷ Rig → Text → IO ()
signalRig rig name = atomically (modifyTVar' (rgSignals rig) (Set.insert name))

-- | How a fixture holds a script where an offer of the service's open is already made and the host has not adopted it:
-- @TEST_AWAIT_OFFER(name)@ returns once the service holds an offered lease for the open of that name. It runs on the script's own
-- thread, waits on the adapter's own state and nothing else, and a real script has no such function.
awaitOfferFixture ∷ TerrainFacade → Binding
awaitOfferFixture facade =
  asynchronousNativeRequestIn "terrain_test_await_offer" [SText] [] $ \_ values → case values of
    [VText name] →
      [] <$ bounded (atomically (readTVar (tfOffered facade) >>= \held → if any (Text.isSuffixOf ("/" <> name)) (Map.keys held) then pure () else retry))
    _ → pure []

-- | Lua for the soil-over-stone definition the examples share: stone below level -3, four soil levels from -3 to 1.
soilOverStone ∷ Text
soilOverStone = "{ materials = { 'soil', 'stone' }, layers = { { z_max = -3, material = 'stone', shape = 0 }, { z_min = -3, z_max = 1, material = 'soil', shape = 0 } } }"

-- | Lua every terrain example begins with: @DEF@, the shared definition, and @settle(api, request)@, which answers the taken record
-- of a request that is ready and nothing otherwise.
terrainPrelude ∷ [Text]
terrainPrelude =
  [ "local DEF = " <> soilOverStone
  , "local function settle(api, r) if r ~= nil and api.request.ready(r) then return api.request.take(r) end end"
  ]

-- Steps -----------------------------------------------------------------------------------------------------

-- | One step of a 'stepsScript': a label, the body of a Lua function of @(A, api)@ (the arena the script opened, and the api) that
-- returns a request or nothing, and the body of a function of the settled value that returns the text to print after the status.
data Step = Step
  { stLabel ∷ Text
  , stStart ∷ Text
  , stShow ∷ Text
  }

-- | A script that opens @definition@ (a Lua expression) as @main@ and then runs each step in turn. A step whose function returns a
-- request is read: its label, status and the text its show function makes of the value (or the failure's code) are printed at its
-- settlement, and the value is kept as @V[label]@ for later steps. One that returns nothing is unread, and the next step follows at
-- once. @done@ is printed after the last step.
stepsScript ∷ Text → [Text] → [Step] → Script
stepsScript definition prelude list =
  script
    { scPrelude =
        terrainPrelude
          <> prelude
          <> ["local V = {}", "local STEPS = {"]
          <> [ "  { " <> Text.pack (show (Text.unpack (stLabel step))) <> ", function(A, api) " <> stStart step <> " end, function(v) " <> stShow step <> " end },"
             | step ← list
             ]
          <> ["}", "local label, show, i = nil, nil, 0"]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', " <> definition <> ")"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value V.arena = t.value self.s = 1 self.q = nil end"
        , "elseif self.s == 1 then"
        , "  if self.q then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      if t.status == 'success' then V[label] = t.value print(label, t.status, show(t.value)) else print(label, t.status, t.error and t.error.code) end"
        , "      self.q = nil"
        , "    end"
        , "  end"
        , "  if not self.q then"
        , "    i = i + 1"
        , "    local step = STEPS[i]"
        , "    if step then label = step[1] show = step[3] self.q = step[2](self.arena, api)"
        , "    else print('done') self.s = 2 end"
        , "  end"
        , "end"
        ]
    }

-- | The service configuration of the offload examples: validated limits whose resident bank holds only a few regions of a small extent, so
-- that touching more of them evicts what was resident and later reads reload it from the source and the retained removals.
tightRigConfig ∷ Config
tightRigConfig = defaultConfig {configLimits = limits, configRetainedBytes = fromInteger (stagingFor residentBank)}
  where
    spare = 2
    edit = 4096
    spec bytes staging =
      LimitsSpec
        { specResidentBytes = bytes
        , specEditBytes = edit
        , specStagingBytes = staging
        , specLoadJobs = 4
        , specQueuedCommands = 6
        , specPinsPerView = 2
        , specAgingQuanta = 3
        , specQueryRegions = 4
        , specExtentX = 2
        , specExtentY = 1
        , specExtentZ = 2
        , specHoldRegions = 2
        , specCameraRegions = 4
        }
    valid bytes staging = either (const Nothing) Just (mkLimits (spec bytes staging))
    smallest = fromMaybe (error "no resident bank satisfies the minimum budgets") (listToMaybe [r | r ← [100, 200 .. 4000000], Just _ ← [valid r 1000000]])
    stagingFor bytes = fromMaybe (error "no staging bank satisfies the minimum budgets") (listToMaybe [t | t ← [1000, 2000 .. 4000000], Just _ ← [valid bytes t]])
    residentBank = smallest + spare * 400
    limits = fromMaybe (error "tight limits are invalid") (valid residentBank (3 * stagingFor residentBank))

-- Gates -----------------------------------------------------------------------------------------------------

-- | A point the terrain owner can be held at, with a signal that it arrived.
data Gate = Gate
  { gateArrived ∷ MVar ()
  , gateOpen ∷ MVar ()
  , gateArmed ∷ TVar Bool
  }

newGate ∷ IO Gate
newGate = Gate <$> newEmptyMVar <*> newEmptyMVar <*> newTVarIO True

armGate, disarmGate ∷ Gate → IO ()
armGate gate = atomically (writeTVar (gateArmed gate) True)
disarmGate gate = atomically (writeTVar (gateArmed gate) False)

-- | Hold the owner at the points this selects until the gate is opened.
gatedProbe ∷ (Point → Bool) → Gate → Probe
gatedProbe selects gate = Probe $ \point →
  when (selects point) $ do
    armed ← readTVarIO (gateArmed gate)
    when armed $ do
      _ ← tryPutMVar (gateArrived gate) ()
      takeMVar (gateOpen gate)

-- | Wait, bounded, until the owner has arrived at the gate.
awaitReached ∷ Gate → IO ()
awaitReached gate = bounded (takeMVar (gateArrived gate))

-- | Drive the world's clock, bounded, until the owner has arrived at the gate: for an owner that only reaches it at a boundary a
-- clock tick brings.
pumpUntilReached ∷ World → Gate → IO ()
pumpUntilReached world gate = pumpUntil world (advanceClock world 2000000000 >> (isJust <$> tryTakeMVar (gateArrived gate)))

-- | Let a held owner go, and every later arrival through. Idempotent, so a scope can open it as part of its stop.
openGate ∷ Gate → IO ()
openGate gate = disarmGate gate >> void (tryPutMVar (gateOpen gate) ())

-- Cases ---------------------------------------------------------------------------------------------------

-- | What a case's call is expected to do.
data Verdict
  = -- | The call returned (nothing raised).
    Accepted
  | -- | The call raised an ordinary error whose text holds each of these.
    Refused [Text]

-- | A label, the Lua expression the case evaluates under @pcall@, and what it must come to.
data Case = Case Text Text Verdict

-- | The Lua line that runs a case and prints @label => ok ; results@ or @label => false ; error@.
caseLua ∷ Case → Text
caseLua (Case label expression _) = "try(" <> Text.pack (show (Text.unpack label)) <> ", function() return " <> expression <> " end)"

-- | Check what the cases printed against what they must come to, reporting every mismatch together.
checkCases ∷ [Case] → [Text] → Expectation
checkCases cases printed = case concatMap check cases of
  [] → pure ()
  failures → expectationFailure (unlines failures)
  where
    check (Case label _ verdict) = case [Text.drop (Text.length prefix) line | line ← printed, prefix `Text.isPrefixOf` line] of
      [seen] → case verdict of
        Accepted
          | "true" `Text.isPrefixOf` seen → []
          | otherwise → [show label <> " must be accepted, but: " <> Text.unpack seen]
        Refused reasons
          | "false ; " `Text.isPrefixOf` seen && all (`Text.isInfixOf` seen) reasons → []
          | otherwise → [show label <> " must be refused with " <> show reasons <> ", but: " <> Text.unpack seen]
      other → ["the case " <> show label <> " printed " <> show (length other) <> " lines"]
      where
        prefix = label <> " => "

-- | What the service itself holds of a named limit, from its own structures.
limitHeld ∷ Service → String → IO Integer
limitHeld service name = do
  rows ← inspectLimits service
  pure (maybe (-1) (toInteger . limitRowHeld) (find ((== name) . limitRowName) rows))

-- | Advance the presentation clock until the instance has printed this line, and when it does not in time say what it did print.
untilPrinted ∷ World → Text → IO ()
untilPrinted world marker =
  pumpUntil world (advanceClock world 2000000000 >> (elem marker <$> outLines world))
    `onException` do
      printed ← outLines world
      warned ← errLines world
      putStrLn ("waiting for " <> show marker <> "; printed: " <> show printed <> "; warned: " <> show warned)

-- | A probe that holds the owner at the commit of the first removal it stages, and at nothing else: the removal's own request is
-- found at its staging (only a removal is staged through that point), and the gate holds it where it is about to be offered to the
-- arbitration, which for a request on logical time is only once its position has been reached.
removalProbe ∷ Gate → IO Probe
removalProbe gate = do
  removal ← newIORef Nothing
  pure . Probe $ \point → case point of
    PointStaging rid → modifyIORef' removal (\held → maybe (Just rid) Just held)
    PointBeforeCommit rid → do
      mine ← readIORef removal
      when (mine == Just rid) $ do
        armed ← readTVarIO (gateArmed gate)
        when armed $ do
          _ ← tryPutMVar (gateArrived gate) ()
          takeMVar (gateOpen gate)
    _ → pure ()

-- | The service's default configuration, and no probe: what an example that holds nothing runs over.
defaultConfigForRaces ∷ Config
defaultConfigForRaces = defaultConfig

noProbeForRaces ∷ Probe
noProbeForRaces = noProbe

-- | The same, naming the instance whose output it is: when the output does not come and the instance has failed, say how.
untilPrintedBy ∷ World → Spawned → Text → IO ()
untilPrintedBy world spawned marker =
  untilPrinted world marker `onException` do
    phase ← phaseOf spawned
    case phase of
      Just Instance.Failed → settledFailure spawned >>= \failure → putStrLn ("the instance failed: " <> show (failureMessage <$> failure))
      other → putStrLn ("the instance is " <> show other)

-- | The action that holds whoever runs it at the gate until it is opened: for a hook of the adapter.
holdAt ∷ Gate → IO ()
holdAt gate = do
  armed ← readTVarIO (gateArmed gate)
  when armed $ do
    _ ← tryPutMVar (gateArrived gate) ()
    takeMVar (gateOpen gate)

-- | The name the service holds for an arena a Lua instance of this rig's session opened under this content root.
arenaName ∷ Rig → Text → Text → Text
arenaName rig root name = "s" <> Text.pack (show (hashUnique (rgSession rig))) <> "/" <> root <> "/" <> name

-- | What an independent observer of the service, a client of its own with its own attachment, sees of one cell of a named arena: the
-- content revision, and the cell's material (nothing for air). Read through the service's public port alone.
observeCell ∷ Rig → Text → (Integer, Integer, Integer) → IO (Integer, Maybe String)
observeCell rig key (x, y, z) = do
  let service = rgService rig
  Right client ← registerClient service
  Right attaching ← attachArena service client key
  Right lease ← await service attaching
  Right reading ← cellAt service lease (either (error . show) id (tileCoord x y z))
  Right answer ← await service reading
  endClient service client
  let Revision revision = cellRevision answer
  pure (toInteger revision, case cellValue answer of Air → Nothing; Solid material _ → Just (materialIdString material))
