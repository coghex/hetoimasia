-- | Shared fixtures: a service in a worker group, a source, gates and hosts.
--
-- Nothing here sleeps. A gate is an 'MVar' the owner blocks on at a named
-- point, so an example decides which side of a race wins by what it does, not by
-- how long it waits.
module Test.TerrainRuntime.Fixtures
  ( -- * Services
    withService
  , withServiceUsing
  , quiet
  , soilOverStone
  , tile
  , column
  , range
  , region

    -- * Gates
  , Gate
  , newGate
  , openGate
  , gatedProbe
  , awaitReached

    -- * Hosts
  , Host (..)
  , newHost
  , hostEndpoint
  , grant
  , settledOf
  , seenAtSettle

    -- * Waiting
  , waitFor
  , expectRight
  , expectSuccess
  , okOf
  ) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.Terrain.Cell (Column, ZRange, mkColumn, mkZRange)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord, tileCoord)
import Hetoimasia.Terrain.Residency (Revision (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
import Test.Hspec (HasCallStack, expectationFailure)
import Test.Support.Bounded (bounded)

quiet ∷ Logger
quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))

-- | Run a body with a service in its own worker group, always admitting.
withService ∷ Config → (Service → IO a) → IO a
withService config = withServiceUsing config alwaysAdmitting noProbe

withServiceUsing ∷ Config → SessionAdmission → Probe → (Service → IO a) → IO a
withServiceUsing config admission probe body =
  withWorkerGroup $ \group → withTerrainService config (Ports admission (standaloneSupervisor group) quiet probe) body

-- | Stone below level -3, soil from -3 to 40: cells of the first two vertical
-- regions are solid, the rest air.
soilOverStone ∷ SourceSpec
soilOverStone =
  SourceSpec
    { specMaterials = ["soil", "stone"]
    , specLayers =
        [ LayerSpec {layerMin = Nothing, layerMax = Just (-3), layerMaterial = "stone", layerShape = 0}
        , LayerSpec {layerMin = Just (-3), layerMax = Just 40, layerMaterial = "soil", layerShape = 0}
        ]
    , specPatches = []
    }

tile ∷ Integer → Integer → Integer → TileCoord
tile x y z = either (error . show) id (tileCoord x y z)

column ∷ Integer → Integer → Column
column x y = either (error . show) id (mkColumn x y)

range ∷ Integer → Integer → ZRange
range a b = either (error . show) id (mkZRange a b)

region ∷ Integer → Integer → Integer → RegionCoord
region x y z = RegionCoord (fromInteger x) (fromInteger y) (fromInteger z)

-- ---------------------------------------------------------------------------
-- Gates

-- | A point the owner can be held at, with a signal that it arrived.
data Gate = Gate
  { gateArrived ∷ MVar ()
  , gateOpen ∷ MVar ()
  }

newGate ∷ IO Gate
newGate = Gate <$> newEmptyMVar <*> newEmptyMVar

-- | Idempotent and non-blocking.
openGate ∷ Gate → IO ()
openGate gate = () <$ tryPutMVar (gateOpen gate) ()

-- | A probe that holds the owner at every point the predicate selects, until the
-- gate opens, and says it arrived.
gatedProbe ∷ (Point → Bool) → Gate → Probe
gatedProbe selects gate = Probe $ \point →
  if selects point
    then do
      _ <- tryPutMVar (gateArrived gate) ()
      readMVar (gateOpen gate)
    else pure ()

awaitReached ∷ Gate → IO ()
awaitReached gate = bounded (readMVar (gateArrived gate))

-- ---------------------------------------------------------------------------
-- Hosts

-- | A fixture host: it can delay its eligibility, and it records what it saw.
data Host = Host
  { hostEligible ∷ TVar Bool
  , hostReady ∷ TVar Int
  , hostSettled ∷ TVar [Settlement]
  , hostSeen ∷ TVar [Maybe (Integer, Bool)]
  }

newHost ∷ Bool → IO Host
newHost eligible = Host <$> newTVarIO eligible <*> newTVarIO 0 <*> newTVarIO [] <*> newTVarIO []

-- | The endpoint of a host. When given an arena to watch, each settlement
-- records the content revision and removal state the arbitration had published
-- by the time the settlement was delivered, inside the same transaction.
hostEndpoint ∷ Service → Maybe ArenaLease → Host → Endpoint
hostEndpoint svc watch host =
  Endpoint
    { endpointReady = modifyTVar' (hostReady host) (+ 1)
    , endpointEligible = readTVar (hostEligible host)
    , endpointSettle = \settlement → do
        modifyTVar' (hostSettled host) (settlement :)
        seen <- case watch of
          Nothing → pure Nothing
          Just lease → fmap (\v → (revisionNumber (viewRevision v), False)) <$> inspectArenaSTM svc lease
        modifyTVar' (hostSeen host) (seen :)
    }
  where
    revisionNumber (Revision n) = toInteger n

grant ∷ Host → IO ()
grant host = atomically (writeTVar (hostEligible host) True)

settledOf ∷ Host → IO [Settlement]
settledOf host = reverse <$> readTVarIO (hostSettled host)

seenAtSettle ∷ Host → IO [Maybe (Integer, Bool)]
seenAtSettle host = reverse <$> readTVarIO (hostSeen host)

-- ---------------------------------------------------------------------------
-- Waiting

-- | Wait, without a timer, until a transaction is satisfied. Bounded, so a
-- state that never arrives fails the example instead of hanging the run.
waitFor ∷ STM a → IO a
waitFor = bounded . atomically

expectRight ∷ (HasCallStack, Show e) ⇒ Either e a → IO a
expectRight = either (\e → expectationFailure ("expected success, got " <> show e) >> fail "unreachable") pure

expectSuccess ∷ (HasCallStack, Show a) ⇒ Either Settlement a → IO a
expectSuccess = either (\e → expectationFailure ("expected success, got " <> show e) >> fail "unreachable") pure

okOf ∷ (HasCallStack, Show e) ⇒ IO (Either e a) → IO a
okOf action = action >>= expectRight
