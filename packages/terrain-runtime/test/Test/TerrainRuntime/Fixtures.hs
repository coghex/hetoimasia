-- | Shared fixtures: a service in a worker group, a source, gates and hosts.
--
-- Nothing here sleeps. A gate is an 'MVar' the owner blocks on at a named
-- point, so an example decides which side of a race wins by what it does, not by
-- how long it waits.
module Test.TerrainRuntime.Fixtures
  ( -- * Services
    withService
  , withServiceUsing
  , withServiceLogged
  , quiet
  , soilOverStone
  , tile
  , column
  , range
  , region

    -- * Gates
  , Gate
  , newGate
  , newDisarmedGate
  , armGate
  , openGate
  , gatedProbe
  , awaitReached
  , withGatedService
  , withGatedServiceUsing

    -- * Hosts
  , Host (..)
  , newHost
  , hostEndpoint
  , grant
  , settledOf
  , seenAtSettle

    -- * Budgets and the independent model
  , tightConfig
  , microConfig
  , layered
  , cellMaterial
  , expectedMaterial
  , localCells

    -- * Doing things
  , openMain
  , readCell
  , removeCell'
  , cellIs
  , refusedWith
  , limitsWith
  , configWith
  , settleChecks

    -- * Waiting
  , waitFor
  , expectRight
  , expectSuccess
  , okOf
  ) where

import Control.Concurrent.MVar
import Control.Exception (finally)
import Control.Concurrent.STM
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Hetoimasia.Terrain.Cell (Cell (..), Column, ZRange, mkColumn, mkZRange, materialIdString)
import Hetoimasia.Terrain.Shape (shapeIdValue)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord, tileCoord)
import Hetoimasia.Terrain.Residency (Limits, LimitsSpec (..), Revision (..), mkLimits)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Test.Hspec (HasCallStack, expectationFailure, shouldBe)
import Test.Support.Bounded (bounded)

quiet ∷ Logger
quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))

-- | Run a body with a service in its own worker group, always admitting.
withService ∷ Config → (Service → IO a) → IO a
withService config = withServiceUsing config alwaysAdmitting noProbe

withServiceUsing ∷ Config → SessionAdmission → Probe → (Service → IO a) → IO a
withServiceUsing = withServiceLogged quiet

-- | A service whose logger is the given one.
withServiceLogged ∷ Logger → Config → SessionAdmission → Probe → (Service → IO a) → IO a
withServiceLogged logger config admission probe body =
  withWorkerGroup $ \group → withTerrainService config (Ports admission (standaloneSupervisor group) logger probe) body

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
  , gateArmed ∷ TVar Bool
  }

-- | A gate, armed from the start; 'disarmedGate' starts it open to nothing.
newGate ∷ IO Gate
newGate = Gate <$> newEmptyMVar <*> newEmptyMVar <*> newTVarIO True

-- | A gate that holds nothing until it is armed.
newDisarmedGate ∷ IO Gate
newDisarmedGate = Gate <$> newEmptyMVar <*> newEmptyMVar <*> newTVarIO False

armGate ∷ Gate → IO ()
armGate gate = atomically (writeTVar (gateArmed gate) True)

-- | Idempotent and non-blocking.
openGate ∷ Gate → IO ()
openGate gate = () <$ tryPutMVar (gateOpen gate) ()

-- | A probe that holds the owner at every point the predicate selects, until the
-- gate opens, and says it arrived.
gatedProbe ∷ (Point → Bool) → Gate → Probe
gatedProbe selects gate = Probe $ \point → do
  armed <- readTVarIO (gateArmed gate)
  if selects point && armed
    then do
      _ <- tryPutMVar (gateArrived gate) ()
      readMVar (gateOpen gate)
    else pure ()

-- | A service with the given probe whose gate is opened on every exit from the
-- body, before the service drains its owner.
withGatedServiceUsing ∷ Probe → Gate → (Service → IO a) → IO a
withGatedServiceUsing probe gate body =
  withServiceUsing defaultConfig alwaysAdmitting probe (\svc → body svc `finally` openGate gate)

-- | A service whose owner is held at the points a predicate selects, until the
-- gate opens. The gate is opened on every exit from the body, before the
-- service drains its owner, so a failed example fails instead of deadlocking
-- behind its own gate.
withGatedService ∷ Config → SessionAdmission → (Point → Bool) → Gate → (Service → IO a) → IO a
withGatedService config admission selects gate body =
  withServiceUsing config admission (gatedProbe selects gate) (\svc → body svc `finally` openGate gate)

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
-- Budgets and the independent model

-- | Validated tight limits for a small extent: the smallest resident bank the
-- approved minimum-budget rule accepts, plus room for @spare@ one-cell regions,
-- and a staging bank twice its minimum. The edit bank is a parameter. Queries
-- name at most four regions, holds two and camera descriptions four.
tightConfig ∷ (Integer, Integer, Integer) → Integer → Integer → Config
tightConfig (ex, ey, ez) spare edit = defaultConfig {configLimits = limits, configRetainedBytes = fromInteger (stagingFor residentBank)}
  where
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
        , specExtentX = ex
        , specExtentY = ey
        , specExtentZ = ez
        , specHoldRegions = 2
        , specCameraRegions = 4
        }
    valid bytes staging = either (const Nothing) Just (mkLimits (spec bytes staging))
    smallest = fromMaybe (error "no resident bank satisfies the minimum budgets") (listToMaybe [r | r <- [100, 200 .. 4000000], Just _ <- [valid r 1000000]])
    stagingFor bytes = fromMaybe (error "no staging bank satisfies the minimum budgets") (listToMaybe [t | t <- [1000, 2000 .. 4000000], Just _ <- [valid bytes t]])
    residentBank = smallest + spare * 400
    limits = fromMaybe (error "tight limits are invalid") (valid residentBank (3 * stagingFor residentBank))

-- | The smallest validated limits for a single-cell-wide extent of two levels, one
-- region per query, two commands and no holds or camera: a resident bank that
-- holds about one region, so a region that cannot be evicted leaves no room for
-- another.
microConfig ∷ Config
microConfig = defaultConfig {configLimits = limits, configRetainedBytes = 2000}
  where
    spec resident staging =
      LimitsSpec
        { specResidentBytes = resident
        , specEditBytes = 4096
        , specStagingBytes = staging
        , specLoadJobs = 1
        , specQueuedCommands = 2
        , specPinsPerView = 1
        , specAgingQuanta = 3
        , specQueryRegions = 1
        , specExtentX = 1
        , specExtentY = 1
        , specExtentZ = 2
        , specHoldRegions = 0
        , specCameraRegions = 0
        }
    valid resident staging = either (const Nothing) Just (mkLimits (spec resident staging))
    smallest = fromMaybe (error "no micro bank") (listToMaybe [r | r <- [100, 150 .. 100000], Just _ <- [valid r 1000000]])
    stagingFor resident = fromMaybe (error "no micro staging") (listToMaybe [t | t <- [500, 1000 .. 1000000], Just _ <- [valid resident t]])
    limits = fromMaybe (error "micro limits are invalid") (valid (smallest + 100) (stagingFor smallest + 4000))

-- | A source from layers @(min, max, material, shape)@ and patches, for an
-- independent expectation.
layered ∷ [(Maybe Integer, Maybe Integer, String, Int)] → [PatchSpec] → SourceSpec
layered layers patches =
  SourceSpec
    { specMaterials = foldr (\m acc → if m `elem` acc then acc else m : acc) [] [m | (_, _, m, _) ← layers]
    , specLayers = [LayerSpec lo hi m shape | (lo, hi, m, shape) ← layers]
    , specPatches = patches
    }

-- | The material and shape of a cell, or nothing for air.
cellMaterial ∷ Cell → Maybe (String, Int)
cellMaterial = \case
  Air → Nothing
  Solid m s → Just (materialIdString m, shapeIdValue s)

-- | What a cell should hold, worked out from the definition and the removed
-- cells alone, sharing no code with the library.
expectedMaterial ∷ SourceSpec → [(Integer, Integer, Integer)] → (Integer, Integer, Integer) → Maybe (String, Int)
expectedMaterial spec removed at'@(x, y, z)
  | at' `elem` removed = Nothing
  | otherwise = case [value | PatchSpec px py lo hi value ← specPatches spec, px == x, py == y, lo <= z, z < hi] of
      (SpecAir : _) → Nothing
      (SpecSolid m shape : _) → Just (m, shape)
      [] → case [(m, shape) | LayerSpec lo hi m shape ← specLayers spec, maybe True (<= z) lo, maybe True (z <) hi] of
        (found : _) → Just found
        [] → Nothing

-- | The four cells a tight extent of 2 x 1 x 2 allows in a region, as world tiles.
localCells ∷ RegionCoord → [(Integer, Integer, Integer)]
localCells (RegionCoord rx ry rz) =
  [(toInteger rx * 16 + lx, toInteger ry * 16, toInteger rz * 32 + lz) | lx ← [0, 1], lz ← [0, 1]]

-- ---------------------------------------------------------------------------
-- Doing things

-- | A client with a named arena over the soil-over-stone source.
openMain ∷ Service → Text → IO (Client, ArenaLease)
openMain svc name = do
  client <- okOf (registerClient svc)
  lease <- okOf (openArena svc client name soilOverStone) >>= await svc >>= expectSuccess
  pure (client, lease)

readCell ∷ Service → ArenaLease → TileCoord → IO CellAnswer
readCell svc lease at = okOf (cellAt svc lease at) >>= await svc >>= expectSuccess

removeCell' ∷ Service → ArenaLease → TileCoord → IO RemoveAnswer
removeCell' svc lease at = okOf (removeAt svc lease at Nothing) >>= await svc >>= expectSuccess

-- | Whether a cell answer is air.
cellIs ∷ CellAnswer → Bool
cellIs answer = cellValue answer == Air

-- | The reason an admission was refused, or nothing if it was admitted.
refusedWith ∷ Either Refused a → Maybe Refused
refusedWith = either Just (const Nothing)

-- | Validated limits: the approved profile with some figures changed.
limitsWith ∷ (LimitsSpec → LimitsSpec) → Limits
limitsWith change = either (error . show) id (mkLimits (change approved))
  where
    mib = 1024 * 1024
    approved =
      LimitsSpec
        { specResidentBytes = 256 * mib
        , specEditBytes = 64 * mib
        , specStagingBytes = 128 * mib
        , specLoadJobs = 128
        , specQueuedCommands = 256
        , specPinsPerView = 2
        , specAgingQuanta = 8
        , specQueryRegions = 257
        , specExtentX = 16
        , specExtentY = 16
        , specExtentZ = 32
        , specHoldRegions = 256
        , specCameraRegions = 16384
        }

configWith ∷ (LimitsSpec → LimitsSpec) → Config
configWith change = defaultConfig {configLimits = limitsWith change}

-- | After an example: the state is coherent, nothing is left reserved, and no
-- defect was recorded.
settleChecks ∷ Service → IO ()
settleChecks svc = do
  inspectInvariants svc >>= (`shouldBe` [])
  inspectDefects svc >>= (`shouldBe` [])

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
