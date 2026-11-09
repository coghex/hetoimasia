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
  , presentationOver
  , gameplayOver
  , soilOverStone
  , terrainPrelude
  , Gate
  , newGate
  , gatedProbe
  , awaitReached
  , openGate
  , armGate
  , disarmGate
  ) where

import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (when)
import Data.Text (Text)
import Data.Unique (Unique, newUnique)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Terrain
import Hetoimasia.Terrain.Runtime
import Test.LuaEngine.Facade.Support (VmShape (..), gameplayShape, presentationShape)
import Test.Support.Bounded (bounded)

-- | The real service and the adapter over it.
data Rig = Rig
  { rgService ∷ !Service
  , rgFacade ∷ !TerrainFacade
  , rgSession ∷ !Unique
  , rgPicks ∷ !TerrainPicks
  }

quiet ∷ Logger
quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))

-- | A rig over the default service configuration and no probe.
withRig ∷ (Rig → IO a) → IO a
withRig = withRigProbe defaultConfig noProbe

withRigConfig ∷ Config → (Rig → IO a) → IO a
withRigConfig config = withRigProbe config noProbe

withRigProbe ∷ Config → Probe → (Rig → IO a) → IO a
withRigProbe config probe body =
  withWorkerGroup $ \group →
    withTerrainService config (Ports alwaysAdmitting (standaloneSupervisor group) quiet probe) $ \service → do
      picks ← newTerrainPicks
      session ← newUnique
      body
        Rig
          { rgService = service
          , rgFacade = TerrainFacade fixedM1Profile service config picks noTerrainHooks [] 4096
          , rgSession = session
          , rgPicks = picks
          }

presentationOver, gameplayOver ∷ Rig → VmShape
presentationOver rig = presentationShape {shTerrain = Just (terrainInjection (rgFacade rig), rgSession rig)}
gameplayOver rig = gameplayShape {shTerrain = Just (terrainInjection (rgFacade rig), rgSession rig)}

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

-- | Let a held owner go, and every later arrival through.
openGate ∷ Gate → IO ()
openGate gate = disarmGate gate >> putMVar (gateOpen gate) ()
