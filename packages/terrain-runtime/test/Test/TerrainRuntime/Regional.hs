-- | Regional terrain-and-knowledge snapshots (#690) through the real service, store and storage
-- backend.
--
-- A snapshot's every cell is compared with the service's existing reads ('cellAt' and 'knowledgeAt' at
-- the snapshot's revisions) and with this suite's own independent expectations, which share no code
-- with the library: 'expectedMaterial' for terrain, and for knowledge a flood of the empty cells from
-- the sky ('expectedKnowledge', below). The accounting is read from the service's own figures and
-- checked by its invariants after every example. Every wait is a causal gate or a bounded wait for
-- state; nothing sleeps; every thread is owned; every example builds its own service.
module Test.TerrainRuntime.Regional (spec, fullSpec) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), finally, throwIO, try)
import Control.Monad (forM, forM_)
import Data.IORef
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Changes (ChangeLimits (..), changesFromIntervals)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), axisValue)
import qualified Hetoimasia.Terrain.Discovery as D
import qualified Hetoimasia.Terrain.Query as Q
import Hetoimasia.Terrain.Residency (LimitsSpec (..), Revision (..), mkLimits, modelHolds, modelRegions, regionCoord, regionLastUse)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.State (minAllowanceBytes)
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Hetoimasia.Terrain.Runtime.Backed.Backend (Closing (..))
import Hetoimasia.Terrain.Runtime.Backed.RegionCopy (RegionCopy (..))
import Hetoimasia.Terrain.Runtime.Backed.Regional (BProgress (..), Build, buildDraining, buildVersion, endBuild, startBuild, stepBuild)
import Hetoimasia.Terrain.Runtime.Backed.Txn (Io (..))
import qualified Hetoimasia.Terrain.Runtime.Storage.Internal.Service as Storage
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (WorkClass (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Store)
import Test.Hspec hiding (after, before, pending)
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec)
import qualified Test.TerrainRuntime.Store.Scenes as Scenes

-- | The routine examples: a representative every-cell oracle over the two regions that hold every fixture
-- shape side by side, and every other contract.
spec ∷ Spec
spec = describe "Regional snapshots" $ do
  oracleSpec
  reducedExtentSpec
  convertibilitySpec
  compressionSpec
  chargeSpec
  coherenceSpec
  fairnessSpec
  pendingSpec
  pressureSpec
  buildPressureSpec
  failureSpec
  ownershipSpec
  admissionSpec

-- ---------------------------------------------------------------------------
-- Fixtures: the issue's six, each a definition, the cells removed from it and the regions held

type Cell3 = (Integer, Integer, Integer)

data Fixture = Fixture
  { fxName ∷ String
  , fxSpec ∷ SourceSpec
  , fxRemovals ∷ [Cell3]
  , fxHeld ∷ [RegionCoord]
  }

-- | Stone up to a sky at level 8, air above, with patches.
ground ∷ [PatchSpec] → SourceSpec
ground = SourceSpec ["stone", "slab"] [LayerSpec Nothing (Just 8) "stone" 0]

caveRow ∷ Integer → Integer → Integer → Integer → [PatchSpec]
caveRow y z x0 x1 = [PatchSpec x y z (z + 1) SpecAir | x ← [x0 .. x1]]

cavity, roof, ramp, shaft, buried, twoOpenings ∷ Fixture
cavity = Fixture "a cavity opened to the sky" (ground (caveRow 0 5 2 6)) [(2, 0, 7), (2, 0, 6)] [region 0 0 0]
-- A cell removed under the cave's roof joins the cave; a shaft elsewhere opens the cave to the sky, so the
-- gap is known and the roof over it is seen from below.
roof = Fixture "a roof over a removed gap" (ground (caveRow 0 5 2 8)) [(4, 0, 6), (8, 1, 7), (8, 1, 6), (8, 1, 5)] [region 0 0 0]
-- A known corridor beside an N ramp whose empty side is unknown, and a sealed cavity across the Y seam.
ramp =
  Fixture
    "a ramp beside an undiscovered void"
    ( ground $
        caveRow 1 5 1 7
          <> [PatchSpec 4 0 5 6 (SpecSolid "slab" 1), PatchSpec 4 0 6 7 (SpecSolid "stone" 0)]
          <> [PatchSpec 2 (-3) 5 6 SpecAir, PatchSpec 2 (-2) 5 6 SpecAir]
    )
    [(1, 1, 7), (1, 1, 6), (1, 1, 5)]
    [region 0 0 0, region 0 (-1) 0]
shaft = Fixture "a deep shaft across a region seam" (ground []) [(2, 1, z) | z ← [7, 6 .. -20]] [region 0 0 0, region 0 0 (-1)]
buried = Fixture "buried removals" (ground []) [(3, 1, -2), (3, 1, -3), (4, 1, -3), (5, 2, 1)] [region 0 0 0, region 0 0 (-1)]
twoOpenings =
  Fixture
    "a two-opening reveal"
    (ground (caveRow 0 5 2 8 <> [PatchSpec 5 y 5 6 SpecAir | y ← [1 .. 3]]))
    (openingA <> openingB)
    [region 0 0 0]

openingA, openingB ∷ [Cell3]
openingA = [(1, 0, z) | z ← [5 .. 7]]
openingB = [(9, 0, z) | z ← [5 .. 7]]

-- | A shaft from the sky just beside the region's west edge: the region's knowledge at its seam depends on
-- a column of the region beside it, read as a dependency and not held.
seam ∷ Fixture
seam = Fixture "a shaft beside the region's seam, which its knowledge depends on" (ground []) [(-1, 1, z) | z ← [7, 6 .. 2]] [region 0 0 0]

fixtures ∷ [Fixture]
fixtures = [cavity, roof, ramp, shaft, buried, twoOpenings, seam]

-- | Every fixture's shape side by side in one region: the cavity, the roof over a removed gap, the ramp
-- beside an undiscovered void (its corridor opened, a sealed cavity apart), the deep shaft (it crosses the
-- region's floor into the region below, which is not held), the buried removals and the two-opening reveal,
-- each on rows of its own with stone between, so no two interact; and the seam's shaft just beside the
-- region's west edge. The region's knowledge depends on the regions beside it and below it, read as
-- dependencies and not held.
together ∷ Fixture
together =
  Fixture
    "every fixture's shape side by side"
    ( ground $
        caveRow 0 5 2 6
          <> caveRow 3 5 2 8
          <> caveRow 7 5 1 7
          <> [PatchSpec 4 6 5 6 (SpecSolid "slab" 1), PatchSpec 12 9 5 6 SpecAir, PatchSpec 12 10 5 6 SpecAir]
          <> caveRow 12 5 2 8
          <> [PatchSpec 5 y 5 6 SpecAir | y ← [13 .. 15]]
    )
    ( [(2, 0, 7), (2, 0, 6)]
        <> [(4, 3, 6), (8, 4, 7), (8, 4, 6), (8, 4, 5)]
        <> [(1, 7, 7), (1, 7, 6), (1, 7, 5)]
        <> [(1, 12, z) | z ← [5 .. 7]]
        <> [(9, 12, z) | z ← [5 .. 7]]
        <> [(10, 10, 3), (10, 10, 2), (11, 10, 2), (12, 11, 1)]
        <> [(14, 14, z) | z ← [7, 6 .. -20]]
        <> [(-1, 1, z) | z ← [7, 6 .. 2]]
    )
    [region 0 0 0]

-- | Open an arena over a definition, remove cells and let discovery and reclamation drain.
openWith ∷ Service → SourceSpec → [Cell3] → IO (Client, ArenaLease)
openWith svc definition removed = do
  client ← okOf (registerClient svc)
  lease ← okOf (openArena svc client "regional" definition) >>= await svc >>= expectSuccess
  forM_ removed $ \(x, y, z) → removeCell' svc lease (tile x y z)
  settled svc lease
  pure (client, lease)

prepared ∷ Service → Fixture → IO ArenaLease
prepared svc fx = snd <$> openWith svc (fxSpec fx) (fxRemovals fx)

-- | Wait until discovery and reclamation have drained and the owner's backed work is at rest.
settled ∷ Service → ArenaLease → IO ()
settled svc lease = waitFor $ do
  arenaStatusSTM svc lease >>= \case
    Right st → check (statusDiscovery st == DiscoveryIdle && statusPendingReclaimBytes st == 0)
    Left _ → retry
  backedAtRestSTM svc >>= check

-- | The borrows an example has taken: each is released when the example exits, however it exits (a
-- release is idempotent), so a failed expectation fails its example instead of leaving a borrow that
-- keeps its service's drain waiting. Each example has its own.
data Taken = Taken !Service !(IORef [RegionBorrow])

guarded ∷ Service → (Taken → IO a) → IO a
guarded svc body = do
  ref ← newIORef []
  body (Taken svc ref) `finally` (readIORef ref >>= mapM_ (releaseRegionBorrow svc))

-- | Record a borrow the example has taken.
keep ∷ Taken → RegionBorrow → IO RegionBorrow
keep (Taken _ ref) borrow = borrow <$ atomicModifyIORef' ref (\bs → (borrow : bs, ()))

-- | Request a snapshot, wait for it and take its borrow.
borrowOf ∷ Taken → ArenaLease → [RegionCoord] → IO RegionBorrow
borrowOf taken@(Taken svc _) lease regions = okOf (requestRegionSnapshot svc lease regions) >>= await svc >>= expectSuccess >>= keep taken

-- | A host's one settlement, once it has one.
settlementOf ∷ Host → IO Settlement
settlementOf host = waitFor $ readTVar (hostSettled host) >>= \case
  [] → retry
  s : _ → pure s

borrowIn ∷ Settlement → IO RegionBorrow
borrowIn = \case
  Succeeded (ARegions borrow) → pure borrow
  other → expectationFailure ("expected a regional snapshot, got " <> show other) >> fail "unreachable"

isStep ∷ Point → Bool
isStep = \case PointRegionStep {} → True; _ → False

isRead, isWrite ∷ NativeOp → Bool
isRead = \case OpReadAt {} → True; _ → False
isWrite = \case OpWriteAt {} → True; _ → False

-- | Every cell of a region.
cellsOf ∷ RegionCoord → [Cell3]
cellsOf (RegionCoord rx ry rz) =
  [ (x, y, z)
  | x ← [16 * toInteger rx .. 16 * toInteger rx + 15]
  , y ← [16 * toInteger ry .. 16 * toInteger ry + 15]
  , z ← [32 * toInteger rz .. 32 * toInteger rz + 31]
  ]

-- | Every answer a snapshot gives for its regions' cells.
answersOf ∷ RegionSnapshot → [(Cell3, RegionPart (Maybe (String, Int)), RegionPart D.CellKnowledge)]
answersOf snapshot =
  [ (c, fmap cellMaterial (regionCell snapshot (tile x y z)), regionCellKnowledge snapshot (tile x y z))
  | r ← regionSnapshotRegions snapshot
  , c@(x, y, z) ← cellsOf r
  ]

-- | What the retained bank holds, the regional charges, the model's holds and every service-wide limit.
accountsOf ∷ Service → IO (Word64, [RegionalCharge], [(String, Word64, Word64)], Int)
accountsOf svc = do
  (use, _) ← atomically (inspectRetainedChargesSTM svc)
  regional ← atomically (inspectRegionalSTM svc)
  limits ← inspectLimits svc
  model ← inspectModel svc
  pure (use, regional, [(limitRowName r, limitRowCounted r, limitRowHeld r) | r ← limits], length (modelHolds model))

-- | The arena's revisions and generation, and the residency the model records (region and recency).
residencyOf ∷ Service → ArenaLease → IO ((Revision, Revision, Revision, Word), [(RegionCoord, Word64)])
residencyOf svc lease = do
  view ← inspectArena svc lease >>= maybe (fail "the arena is gone") pure
  model ← inspectModel svc
  pure ((viewRevision view, viewKnowledgeRevision view, viewStoreRevision view, viewGeneration view), sort [(regionCoord r, regionLastUse r) | r ← modelRegions model])

-- | The structural work of a region's build: columns and runs read, classes, pieces, evaluations and
-- per-level evaluations.
workOf ∷ RegionWork → (Int, Int, Int, Int, Int, Int)
workOf w = (workColumnsRead w, workRunsRead w, workClasses w, workPieces w, workEvaluations w, workPerLevelEvaluations w)

-- ---------------------------------------------------------------------------
-- The independent expectation

-- | What a cell holds, from the definition and the removed cells alone.
data Content = CAir | CBlock | CShape
  deriving stock (Eq, Show)

contentOf ∷ SourceSpec → [Cell3] → Cell3 → Content
contentOf definition removed c = case expectedMaterial definition removed c of
  Nothing → CAir
  Just (_, 0) → CBlock
  Just _ → CShape

-- | The cells the flood covers: each region held and one cell around it.
windowOf ∷ [RegionCoord] → Cell3 → Bool
windowOf regions (x, y, z) = any inBox regions
  where
    inBox (RegionCoord rx ry rz) =
      let x0 = 16 * toInteger rx; y0 = 16 * toInteger ry; z0 = 32 * toInteger rz
       in x >= x0 - 1 && x <= x0 + 16 && y >= y0 - 1 && y <= y0 + 16 && z >= z0 - 1 && z <= z0 + 32

-- | The empty cells known: every empty cell joined face to face to the open sky (the air at level 8,
-- above the ground). Shaped cells are left out of the flood: no fixture joins anything through one.
knownAir ∷ SourceSpec → [Cell3] → [RegionCoord] → Set Cell3
knownAir definition removed regions = go Set.empty seeds
  where
    inWindow = windowOf regions
    seeds =
      [ c
      | RegionCoord rx ry _ ← regions
      , x ← [16 * toInteger rx - 1 .. 16 * toInteger rx + 16]
      , y ← [16 * toInteger ry - 1 .. 16 * toInteger ry + 16]
      , let c = (x, y, 8)
      , inWindow c
      , contentOf definition removed c == CAir
      ]
    go seen [] = seen
    go seen (c : rest)
      | Set.member c seen = go seen rest
      | otherwise = go (Set.insert c seen) ([n | n ← faces c, inWindow n, not (Set.member n seen), contentOf definition removed n == CAir] <> rest)

faces ∷ Cell3 → [Cell3]
faces (x, y, z) = [(x + 1, y, z), (x - 1, y, z), (x, y + 1, z), (x, y - 1, z), (x, y, z + 1), (x, y, z - 1)]

-- | What a cell's knowledge should be: an empty cell's void is known when it is joined to the sky; a
-- full block's solid is known when one of its faces meets a known empty cell. 'Nothing' for a cell that
-- is shaped or beside a shaped cell, which this expectation does not model.
expectedKnowledge ∷ SourceSpec → [Cell3] → Set Cell3 → Cell3 → Maybe D.CellKnowledge
expectedKnowledge definition removed known c
  | any ((== CShape) . contentOf definition removed) (c : faces c) = Nothing
  | otherwise = Just $ case contentOf definition removed c of
      CAir → D.CellKnowledge D.NoSolid (if Set.member c known then D.VoidKnown else D.VoidUnknown)
      _ → D.CellKnowledge (if any (`Set.member` known) (faces c) then D.SolidKnown else D.SolidUnknown) D.NoVoidHere

-- | Where a snapshot's cells differ from the independent expectation for a definition and its removals.
expectationMismatches ∷ SourceSpec → [Cell3] → RegionSnapshot → [String]
expectationMismatches definition removed snapshot =
  take 10 $
    [ show c <> ": terrain " <> show got <> ", expected " <> show want
    | r ← regions
    , c@(x, y, z) ← cellsOf r
    , let got = fmap cellMaterial (regionCell snapshot (tile x y z))
          want = PartReady (expectedMaterial definition removed c)
    , got /= want
    ]
      <> [ show c <> ": knowledge " <> show got <> ", expected " <> show want
         | r ← regions
         , c@(x, y, z) ← cellsOf r
         , Just want ← [expectedKnowledge definition removed known c]
         , let got = regionCellKnowledge snapshot (tile x y z)
         , got /= PartReady want
         ]
  where
    regions = regionSnapshotRegions snapshot
    known = knownAir definition removed regions

-- | Where a snapshot's cells differ from the service's own reads of them, or the reads' revisions from
-- the snapshot's.
readMismatches ∷ Service → ArenaLease → RegionSnapshot → [Cell3] → IO [String]
readMismatches svc lease snapshot cells = fmap (take 10 . concat) . forM cells $ \c@(x, y, z) → do
  cell ← readCell svc lease (tile x y z)
  knowledge ← okOf (knowledgeAt svc lease (tile x y z)) >>= await svc >>= expectSuccess
  let revisions = (cellRevision cell, knowledgeContent knowledge, knowledgeRevision knowledge)
      expected = (regionSnapshotContentRevision snapshot, regionSnapshotContentRevision snapshot, regionSnapshotKnowledgeRevision snapshot)
      at = tile x y z
  pure $
    [show c <> ": read at " <> show revisions <> ", snapshot at " <> show expected | revisions /= expected]
      <> [show c <> ": cellAt " <> show (cellValue cell) <> ", snapshot " <> show (regionCell snapshot at) | PartReady (cellValue cell) /= regionCell snapshot at]
      <> [ show c <> ": knowledgeAt " <> show (knowledgeValue knowledge) <> ", snapshot " <> show (regionCellKnowledge snapshot at)
         | PartReady (knowledgeValue knowledge) /= regionCellKnowledge snapshot at
         ]

-- ---------------------------------------------------------------------------
-- The oracle

oracleSpec ∷ Spec
oracleSpec =
  it "answers every cell of the region holding every fixture's shape as cellAt and knowledgeAt do at its revisions, and as the independent expectation says" $
    withService defaultConfig $ \svc → guarded svc $ \taken → do
      lease ← prepared svc together
      borrow ← borrowOf taken lease (fxHeld together)
      let snapshot = regionBorrowSnapshot borrow
      everyCell svc lease together snapshot
      -- the seams: the solid beside the shaft at x = -1 is known from a column of the region beside it, and
      -- the shaft's lowest held cell sits on the shaft's part in the region below; neither is held
      (regionCellKnowledge snapshot (tile 0 1 4), regionCell snapshot (tile (-1) 1 4)) `shouldBe` (PartReady (D.CellKnowledge D.SolidKnown D.NoVoidHere), PartNotHeld)
      (regionCellKnowledge snapshot (tile 14 14 0), regionCell snapshot (tile 14 14 (-1))) `shouldBe` (PartReady (D.CellKnowledge D.NoSolid D.VoidKnown), PartNotHeld)
      releaseRegionBorrow svc borrow
      settleChecks svc

-- | Every cell of every region a fixture holds, compared with the service's reads and the independent
-- expectation.
everyCell ∷ Service → ArenaLease → Fixture → RegionSnapshot → IO ()
everyCell svc lease fx snapshot = do
  regionSnapshotRegions snapshot `shouldBe` sort (fxHeld fx)
  expectationMismatches (fxSpec fx) (fxRemovals fx) snapshot `shouldBe` []
  readMismatches svc lease snapshot (concatMap cellsOf (fxHeld fx)) >>= (`shouldBe` [])

-- | The full depth (terrain-runtime-full-depth-tests): every fixture on its own, every cell of every region
-- it holds (ten regions in all), compared with cellAt, knowledgeAt and the independent expectation. The
-- routine suite runs the same comparison over the two regions that hold every fixture's shape side by side.
fullSpec ∷ Spec
fullSpec = describe "Regional snapshots (full depth): every cell of every region each fixture holds is what cellAt and knowledgeAt answer at its revisions, and what the independent expectation says" $
  forM_ fixtures $ \fx → it (fxName fx) $ withService defaultConfig $ \svc → guarded svc $ \taken → do
    lease ← prepared svc fx
    borrow ← borrowOf taken lease (fxHeld fx)
    everyCell svc lease fx (regionBorrowSnapshot borrow)
    releaseRegionBorrow svc borrow
    settleChecks svc

-- | A configuration whose extent covers two columns, one row and two levels of each region, whose
-- resident bank holds about two regions (so reads of other regions evict one), and whose retained bank
-- has room for a regional snapshot's reservation.
reducedConfig ∷ Config
reducedConfig = defaultConfig {configLimits = limits, configRetainedBytes = retained}
  where
    retained = 2 * 1024 * 1024
    spec' resident staging =
      LimitsSpec
        { specResidentBytes = resident
        , specEditBytes = 4096
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
    valid resident staging = either (const Nothing) Just (mkLimits (spec' resident staging))
    first' = fromMaybe (error "no valid reduced limits") . listToMaybe
    smallest = first' [r | r ← [100, 200 .. 4000000], Just _ ← [valid r 1000000]]
    stagingFor resident = first' [t | t ← [1000, 2000 .. 4000000], Just _ ← [valid resident t]]
    resident' = smallest + 2 * 400
    limits = fromMaybe (error "reduced limits are invalid") (valid resident' (3 * stagingFor resident' + toInteger retained))

reducedExtentSpec ∷ Spec
reducedExtentSpec =
  it "answers every cell of a region under an extent smaller than it: inside the extent as cellAt and knowledgeAt do, outside it as the definition alone, and widens no request's reach" $
    withService reducedConfig $ \svc → guarded svc $ \taken → do
      let definition = ground (caveRow 0 5 2 6)
          removed = [(1, 0, 1), (1, 0, 0)]
      (_, lease) ← openWith svc definition removed
      borrow ← borrowOf taken lease [region 0 0 0]
      let snapshot = regionBorrowSnapshot borrow
      expectationMismatches definition removed snapshot `shouldBe` []
      -- the cells inside the extent: the region's first two columns of its first row, two levels each
      readMismatches svc lease snapshot [(x, 0, z) | x ← [0, 1], z ← [0, 1]] >>= (`shouldBe` [])
      -- a cell outside it is still refused to every request
      outside ← cellAt svc lease (tile 5 5 5)
      case refusedWith outside of
        Just (RefusedInvalid _) → pure ()
        other → expectationFailure ("a read outside the extent: " <> show other)
      releaseRegionBorrow svc borrow
      settleChecks svc

-- ---------------------------------------------------------------------------
-- Convertibility: a test-only adapter that builds a consumer's inputs from the snapshot alone, through
-- public interfaces, and compares them with values of the terrain package

-- | A region's knowledge as a consumer keeps it: one summary when it is uniform, else each column's runs.
data Summary = Uniform D.CellKnowledge | Columns (Map.Map (Integer, Integer) [(Integer, Integer, D.CellKnowledge)])
  deriving stock (Eq, Show)

summaryOf ∷ D.RegionKnowledge → Summary
summaryOf rk = case D.regionKnowledgeUniform rk of
  Just k → Uniform k
  Nothing ->
    Columns $
      Map.fromList
        [ ((toInteger (axisValue x), toInteger (axisValue y)), [(toInteger a, toInteger b, k) | (a, b, k) ← runs])
        | c@(Column x y) ← D.regionColumns (D.regionKnowledgeRegion rk)
        , Just runs ← [D.regionKnowledgeColumn rk c]
        ]

summaryAt ∷ Map.Map RegionCoord Summary → Cell3 → Maybe D.CellKnowledge
summaryAt summaries (x, y, z) = case Map.lookup (RegionCoord (fromInteger (x `div` 16)) (fromInteger (y `div` 16)) (fromInteger (z `div` 32))) summaries of
  Just (Uniform k) → Just k
  Just (Columns columns) → listToMaybe [k | (a, b, k) ← Map.findWithDefault [] (x, y) columns, a <= z, z < b]
  Nothing → Nothing

convertibilitySpec ∷ Spec
convertibilitySpec =
  it "lets a consumer build Changes, readiness and knowledge summaries from the snapshot alone, and they agree with the independent expectation" $
    withService defaultConfig $ \svc → guarded svc $ \taken → do
      let fx = shaft
          pristine = region 5 5 (-1)
          regions = fxHeld fx <> [pristine]
      lease ← prepared svc fx
      borrow ← borrowOf taken lease regions
      let snapshot = regionBorrowSnapshot borrow
          held' = regionSnapshotRegions snapshot
          ready = \case PartReady _ → True; _ → False
          readiness = [(r, ready (regionTerrain snapshot r) && ready (regionKnowledge snapshot r)) | r ← held']
          intervals = [interval | r ← held', PartReady ivs ← [regionTerrain snapshot r], interval ← ivs]
          summaries = Map.fromList [(r, summaryOf rk) | r ← held', PartReady rk ← [regionKnowledge snapshot r]]
      readiness `shouldBe` [(r, True) | r ← sort regions]
      case changesFromIntervals (ChangeLimits maxBound) intervals of
        Left failure → expectationFailure (show failure)
        Right changes →
          take 10
            [ (c, got, want)
            | r ← regions
            , c@(x, y, z) ← cellsOf r
            , let got = cellMaterial (Q.cellAt (regionSnapshotSource snapshot) changes (tile x y z))
                  want = expectedMaterial (fxSpec fx) (fxRemovals fx) c
            , got /= want
            ]
            `shouldBe` []
      Map.lookup pristine summaries `shouldBe` Just (Uniform (D.CellKnowledge D.SolidUnknown D.NoVoidHere))
      let known = knownAir (fxSpec fx) (fxRemovals fx) regions
      take 10
        [ (c, got, want)
        | r ← regions
        , c ← cellsOf r
        , Just want ← [expectedKnowledge (fxSpec fx) (fxRemovals fx) known c]
        , let got = summaryAt summaries c
        , got /= Just want
        ]
        `shouldBe` []
      releaseRegionBorrow svc borrow
      settleChecks svc

-- ---------------------------------------------------------------------------
-- Compression

compressionSpec ∷ Spec
compressionSpec = describe "compression" $ do
  it "holds a pristine region in a constant footprint, finds a uniformly undiscovered or discovered region's one summary with three evaluations, and changes no residency, recency or revision" $
    withService defaultConfig $ \svc → guarded svc $ \taken → do
      (_, lease) ← openWith svc (ground []) []
      let below = region 5 5 (-1)
          above = region 5 5 1
      -- a region made resident first, whose recency a snapshot of it must not touch
      _ ← readCell svc lease (tile 80 80 (-32))
      settled svc lease
      before ← residencyOf svc lease
      borrow ← borrowOf taken lease [below, above]
      residencyOf svc lease >>= (`shouldBe` before)
      let snapshot = regionBorrowSnapshot borrow
      -- the record (128) and, for each region, its entry (200), an empty terrain part (16) and a
      -- knowledge part of one class of one run (5 bytes: 24)
      regionSnapshotFootprint snapshot `shouldBe` 128 + 2 * (200 + 16 + 24)
      regionTerrain snapshot below `shouldBe` PartReady []
      fmap D.regionKnowledgeUniform (regionKnowledge snapshot below) `shouldBe` PartReady (Just (D.CellKnowledge D.SolidUnknown D.NoVoidHere))
      fmap D.regionKnowledgeUniform (regionKnowledge snapshot above) `shouldBe` PartReady (Just (D.CellKnowledge D.NoSolid D.VoidKnown))
      fmap (length . D.regionKnowledgeClasses) (regionKnowledge snapshot above) `shouldBe` PartReady 1
      -- 256 columns and the 64 beside them read, no run; one class, one piece, three evaluations
      map (fmap workOf . regionSnapshotWork snapshot) [below, above] `shouldBe` replicate 2 (Just (320, 0, 1, 1, 3, 0))
      releaseRegionBorrow svc borrow
      settleChecks svc

  it "holds one removal in a bounded constant more, absolutely: its interval and its column's runs, found by evaluating its column and the four beside it" $
    withService defaultConfig $ \svc → guarded svc $ \taken → do
      (_, lease) ← openWith svc (ground []) []
      let below = region 5 5 (-1)
      pristine ← borrowOf taken lease [below]
      regionSnapshotFootprint (regionBorrowSnapshot pristine) `shouldBe` 128 + 200 + 16 + 24
      _ ← removeCell' svc lease (tile 88 88 (-16))
      settled svc lease
      one ← borrowOf taken lease [below]
      let snapshot = regionBorrowSnapshot one
      -- terrain: one column, one interval (4 bytes: 24); knowledge: two classes (the removed column's three
      -- runs and everyone else's one) and the column map (268 bytes: 288)
      regionSnapshotFootprint snapshot `shouldBe` 128 + 200 + 24 + 288
      regionSnapshotFootprint snapshot - regionSnapshotFootprint (regionBorrowSnapshot pristine) `shouldBe` 272
      regionTerrain snapshot below `shouldBe` PartReady [(column 88 88, range (-16) (-15))]
      fmap (length . D.regionKnowledgeClasses) (regionKnowledge snapshot below) `shouldBe` PartReady 2
      -- the removed column and its four side neighbours are classes of their own (three pieces, seven
      -- evaluations each), every other column one class of three
      fmap workOf (regionSnapshotWork snapshot below) `shouldBe` Just (320, 1, 6, 16, 38, 0)
      expectationMismatches (ground []) [(88, 88, -16)] snapshot `shouldBe` []
      mapM_ (releaseRegionBorrow svc) [pristine, one]
      settleChecks svc

  it "evaluates every level of a box whose components keep the level, and counts those evaluations apart" $
    withService defaultConfig $ \svc → guarded svc $ \taken → do
      -- a covered stack of N ramps: stacked non-flat cells never connect between levels
      let definition = ground [PatchSpec 2 2 0 8 (SpecSolid "slab" 1)]
      (_, lease) ← openWith svc definition []
      borrow ← borrowOf taken lease [region 0 0 0]
      let snapshot = regionBorrowSnapshot borrow
      fmap workPerLevelEvaluations (regionSnapshotWork snapshot (region 0 0 0)) `shouldSatisfy` maybe False (> 0)
      readMismatches svc lease snapshot [(x, y, z) | x ← [1 .. 3], y ← [1 .. 3], z ← [0 .. 9]] >>= (`shouldBe` [])
      expectationMismatches definition [] snapshot `shouldBe` []
      releaseRegionBorrow svc borrow
      settleChecks svc

-- ---------------------------------------------------------------------------
-- The charge

chargeSpec ∷ Spec
chargeSpec =
  it "reserves at admission the most its result can hold, charges the snapshot's exact footprint from its settlement, and returns it only at its release" $ do
    gate ← newDisarmedGate
    withGatedServiceUsing (gatedProbe isStep gate) gate $ \svc → guarded svc $ \taken → do
      (_, lease) ← openWith svc (ground []) []
      (base, _, _, _) ← accountsOf svc
      armGate gate
      pending ← okOf (requestRegionSnapshot svc lease [region 5 5 (-1)])
      awaitReached gate
      -- built, not settled: the reservation and the request's record are charged
      reserved ← atomically (inspectRegionalSTM svc)
      [(regionalChargeRegions c, regionalChargeReserved c, regionalChargeFootprint c, regionalChargeTaken c) | c ← reserved]
        `shouldBe` [(1, regionSnapshotReservation 1, Nothing, False)]
      (use, _, rows, _) ← accountsOf svc
      use `shouldBe` base + regionSnapshotReservation 1 + 160
      [(counted, held') | (name, counted, held') ← rows, name == "retained bank"] `shouldBe` [(use, use)]
      disarmGate gate
      openGate gate
      borrow ← await svc pending >>= expectSuccess >>= keep taken
      let footprint = regionSnapshotFootprint (regionBorrowSnapshot borrow)
      afterTake ← atomically (inspectRegionalSTM svc)
      [(regionalChargeReserved c, regionalChargeFootprint c, regionalChargeTaken c) | c ← afterTake] `shouldBe` [(regionSnapshotReservation 1, Just footprint, True)]
      (use', _, _, _) ← accountsOf svc
      use' `shouldBe` base + footprint
      releaseRegionBorrow svc borrow
      (released, regional, _, holds) ← accountsOf svc
      (released, regional, holds) `shouldBe` (base, [], 0)
      -- a second release changes nothing
      releaseRegionBorrow svc borrow
      accountsOf svc >>= \(again, _, _, _) → again `shouldBe` base
      settleChecks svc

-- ---------------------------------------------------------------------------
-- Coherence

coherenceSpec ∷ Spec
coherenceSpec = describe "coherence" $ do
  it "is labelled with the one version it pinned while removals and discovery commit between its admission and its settlement, and keeps its every answer through later removals, growth, a storage pause and the arena's closure" $ do
    storage ← H.newProbe
    gate ← newDisarmedGate
    withServiceSeam quiet defaultConfig alwaysAdmitting (gatedProbe isStep gate) (H.seamFor storage) $ \svc → flip finally (openGate gate) . guarded svc $ \taken → do
      let before = openingA
      (_, lease) ← openWith svc (fxSpec twoOpenings) before
      host ← newHost False
      armGate gate
      request ← okOf (regionsWith svc (hostEndpoint svc Nothing host) lease [region 0 0 0])
      -- the build has pinned its version and is held before its first quantum
      awaitReached gate
      ((pinnedContent, pinnedKnowledge, _, pinnedGeneration), _) ← residencyOf svc lease
      removals ← forM openingB $ \(x, y, z) → okOf (removeAt svc lease (tile x y z) Nothing)
      disarmGate gate
      openGate gate
      forM_ removals $ \pending → await svc pending >>= expectSuccess
      settled svc lease
      waitFor (readTVar (hostReady host) >>= check . (>= 1))
      ((content, knowledge, _, _), _) ← residencyOf svc lease
      -- the removals and the discovery they started committed after the pin, and before the settlement
      settledOf host >>= (`shouldBe` [])
      (content > pinnedContent, knowledge > pinnedKnowledge) `shouldBe` (True, True)
      grant host
      borrow ← settlementOf host >>= borrowIn >>= keep taken
      atomically (takeSTM svc request)
      let snapshot = regionBorrowSnapshot borrow
      (regionSnapshotContentRevision snapshot, regionSnapshotKnowledgeRevision snapshot, regionSnapshotGeneration snapshot)
        `shouldBe` (pinnedContent, pinnedKnowledge, fromIntegral pinnedGeneration)
      expectationMismatches (fxSpec twoOpenings) before snapshot `shouldBe` []
      let answers = answersOf snapshot
      -- later: a removal and its discovery, a growth, a storage pause and the arena's closure
      _ ← removeCell' svc lease (tile 5 3 6)
      settled svc lease
      _ ← growArena svc lease (toInteger minAllowanceBytes + 1024 * 1024) >>= expectRight >>= await svc >>= expectSuccess
      H.addRule storage 1 isWrite (H.FailWith (Errno 5))
      failed ← okOf (removeAt svc lease (tile 6 3 6) Nothing) >>= await svc
      case failed of
        Left (Failed (StorageFailed _)) → pure ()
        other → expectationFailure ("a removal whose write fails: " <> show other)
      arenaStatus svc lease >>= expectRight >>= \st → statusStorage st `shouldSatisfy` \case StoragePaused _ → True; _ → False
      _ ← releaseLease svc lease
      answersOf snapshot `shouldBe` answers
      releaseRegionBorrow svc borrow
      settleChecks svc

  it "builds each region from a fresh window on the one version it pinned: a removal committed while the second region's first read waits is in neither" $ do
    storage ← H.newProbe
    gate ← newDisarmedGate
    let secondRegion = \case PointRegionStep _ 1 → True; _ → False
    withServiceSeam quiet defaultConfig alwaysAdmitting (gatedProbe secondRegion gate) (H.seamFor storage) $ \svc → flip finally (openGate gate) . guarded svc $ \taken → do
      (_, lease) ← openWith svc (ground []) [(88, 88, -16)]
      let first = region 5 5 (-1)
          second = region 6 5 (-1)
      armGate gate
      pending ← okOf (requestRegionSnapshot svc lease [first, second])
      -- the first region is copied; the owner is held before the second region's first quantum
      awaitReached gate
      nextRead ← H.addGateOnce storage isRead
      flip finally (H.openGate nextRead) $ do
        disarmGate gate
        openGate gate
        -- the second region's fresh window needs a page of the pinned version: the build waits for it
        H.awaitReached nextRead 1
        -- meanwhile a removal in the second region commits
        removed ← removeCell' svc lease (tile 100 88 (-16))
        removeRevision removed `shouldBe` Revision 2
        H.openGate nextRead
        borrow ← await svc pending >>= expectSuccess >>= keep taken
        let snapshot = regionBorrowSnapshot borrow
        regionSnapshotContentRevision snapshot `shouldBe` Revision 1
        fmap cellMaterial (regionCell snapshot (tile 100 88 (-16))) `shouldBe` PartReady (Just ("stone", 0))
        expectationMismatches (ground []) [(88, 88, -16)] snapshot `shouldBe` []
        releaseRegionBorrow svc borrow
      settleChecks svc

  it "keeps a settled snapshot's every answer through the eviction and the reload of its region" $
    withService reducedConfig $ \svc → guarded svc $ \taken → do
      let definition = ground []
          removed = [(1, 0, 1)]
          held' = region 0 0 0
      (_, lease) ← openWith svc definition removed
      borrow ← borrowOf taken lease [held']
      let snapshot = regionBorrowSnapshot borrow
          answers = answersOf snapshot
          resident = any ((== held') . regionCoord) . modelRegions <$> inspectModel svc
          others = [(x, y, z) | z ← [0, -32, 64], y ← [0, 16, -16], x ← [16, 32, -16, 48, -32]]
          press [] = pure False
          press ((x, y, z) : rest) = do
            _ ← readCell svc lease (tile x y z)
            stays ← resident
            if stays then press rest else pure True
      _ ← readCell svc lease (tile 0 0 0)
      resident >>= (`shouldBe` True)
      press others >>= (`shouldBe` True)
      _ ← readCell svc lease (tile 1 0 1)
      resident >>= (`shouldBe` True)
      answersOf snapshot `shouldBe` answers
      expectationMismatches definition removed snapshot `shouldBe` []
      releaseRegionBorrow svc borrow
      settleChecks svc

-- ---------------------------------------------------------------------------
-- Fairness

fairnessSpec ∷ Spec
fairnessSpec =
  it "yields between its quanta: a removal made eligible while the build is held is granted before the build's next quantum, and commits before the snapshot settles" $ do
    logged ← newIORef ([] ∷ [Point])
    gate ← newDisarmedGate
    storage ← H.newProbe
    let gated = gatedProbe isStep gate
        noted = \case
          PointRegionStep {} → True
          PointGranted (Just _) _ → True
          PointCommitted {} → True
          _ → False
        probe = Probe $ \point → do
          if noted point then atomicModifyIORef' logged (\l → (point : l, ())) else pure ()
          probePoint gated point
    withServiceSeam quiet defaultConfig alwaysAdmitting probe (H.seamFor storage) $ \svc → flip finally (openGate gate) . guarded svc $ \taken → do
      -- one removal, so the build has pages to read
      (_, lease) ← openWith svc (ground []) [(88, 88, -16)]
      -- the build's first page read is held in the storage backend: the build waits, the owner does not
      firstRead ← H.addGateOnce storage isRead
      flip finally (H.openGate firstRead) $ do
        snapshotHost ← newHost False
        request ← okOf (regionsWith svc (hostEndpoint svc Nothing snapshotHost) lease [region x 0 (-1) | x ← [0 .. 15]])
        H.awaitReached firstRead 1
        -- meanwhile a removal is prepared and staged, its host not yet eligible
        removalHost ← newHost False
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing removalHost) lease (tile 3 3 7) Nothing)
        waitFor (readTVar (hostReady removalHost) >>= check . (>= 1))
        readTVarIO (hostReady snapshotHost) >>= (`shouldBe` 0)
        -- the build's read returns, and the owner is held at the build's next quantum
        armGate gate
        H.openGate firstRead
        awaitReached gate
        heldAt ← length <$> readIORef logged
        grant removalHost
        disarmGate gate
        openGate gate
        settlementOf removalHost >>= \case
          Succeeded (ARemoved answer) → removeChangedFlag answer `shouldBe` True
          other → expectationFailure ("the removal: " <> show other)
        -- the snapshot's host is eligible only now: the removal committed before it settled
        grant snapshotHost
        borrow ← settlementOf snapshotHost >>= borrowIn >>= keep taken
        atomically (takeSTM svc request)
        points ← reverse <$> readIORef logged
        let afterHeld = drop heldAt points
            isGrant = \case PointGranted (Just _) _ → True; _ → False
        -- after the held quantum, the removal's grant comes before the build takes another
        any isGrant (takeWhile (not . isStep) afterHeld) `shouldBe` True
        -- and the snapshot is of the version it pinned, before the removal
        regionSnapshotContentRevision (regionBorrowSnapshot borrow) `shouldBe` Revision 1
        releaseRegionBorrow svc borrow
      settleChecks svc

-- ---------------------------------------------------------------------------
-- Pending, failure and cancellation through the storage backend

pendingSpec ∷ Spec
pendingSpec = describe "a page that has not arrived" $ do
  it "keeps the request pending, its reservation charged, until the page arrives" $ do
    storage ← H.newProbe
    withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor storage) $ \svc → guarded svc $ \taken → do
      -- one removal, so the arena's store has pages a build must read
      (_, lease) ← openWith svc (ground []) [(88, 88, -16)]
      held' ← H.addGateOnce storage isRead
      flip finally (H.openGate held') $ do
        host ← newHost True
        request ← okOf (regionsWith svc (hostEndpoint svc Nothing host) lease [region 5 5 (-1)])
        H.awaitReached held' 1
        settledOf host >>= (`shouldBe` [])
        map regionalChargeFootprint <$> atomically (inspectRegionalSTM svc) >>= (`shouldBe` [Nothing])
        H.openGate held'
        borrow ← settlementOf host >>= borrowIn >>= keep taken
        atomically (takeSTM svc request)
        expectationMismatches (ground []) [(88, 88, -16)] (regionBorrowSnapshot borrow) `shouldBe` []
        releaseRegionBorrow svc borrow
      settleChecks svc

  it "decides a cancellation at once but keeps what its read in flight uses charged until the read has drained, then returns all of it once" $ do
    storage ← H.newProbe
    withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor storage) $ \svc → guarded svc $ \_ → do
      (_, lease) ← openWith svc (ground []) [(88, 88, -16)]
      (base, _, _, _) ← accountsOf svc
      held' ← H.addGateOnce storage isRead
      flip finally (H.openGate held') $ do
        host ← newHost True
        request ← okOf (regionsWith svc (hostEndpoint svc Nothing host) lease [region 5 5 (-1)])
        H.awaitReached held' 1
        cancel svc request >>= (`shouldBe` CancelWon)
        settledOf host >>= (`shouldBe` [Cancelled])
        -- the outcome is decided; the build's read is still in flight, so its charges stay
        (use, regional, _, holds) ← accountsOf svc
        (use, map regionalChargeReserved regional, holds) `shouldBe` (base + regionSnapshotReservation 1, [regionSnapshotReservation 1], 1)
        H.openGate held'
        waitFor (inspectRegionalSTM svc >>= check . null)
        (after, _, _, holds') ← accountsOf svc
        (after, holds') `shouldBe` (base, 0)
        settledOf host >>= (`shouldBe` [Cancelled])
      settleChecks svc

pressureSpec ∷ Spec
pressureSpec =
  it "waits, never refused or settled, while the storage service is full, and completes once it drains" $ do
    storage ← H.newProbe
    withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor storage) $ \svc → guarded svc $ \taken → do
      (_, lease) ← openWith svc (ground []) [(88, 88, -16)]
      -- every page read is held at the seam; removals elsewhere fill the two workers and the queue's eight
      gate ← H.addGate storage isRead
      fillers ← flip finally (H.openGate gate) $ do
        fillers ← forM [0 .. 13] $ \x → do
          h ← newHost True
          _ ← okOf (removeWith svc (hostEndpoint svc Nothing h) lease (tile x 4 3) Nothing)
          pure h
        waitFor (readTVar (H.gReached gate) >>= check . (>= 2))
        waitFor (inspectStorageQueuedSTM svc >>= check . (>= 8))
        -- admitted at once; its pinned read waits for the storage service to have room
        host ← newHost True
        request ← okOf (regionsWith svc (hostEndpoint svc Nothing host) lease [region 5 5 (-1)])
        settledOf host >>= (`shouldBe` [])
        map regionalChargeFootprint <$> atomically (inspectRegionalSTM svc) >>= (`shouldBe` [Nothing])
        inspectDefects svc >>= (`shouldBe` [])
        H.openGate gate
        borrow ← settlementOf host >>= borrowIn >>= keep taken
        atomically (takeSTM svc request)
        expectationMismatches (ground []) [(88, 88, -16)] (regionBorrowSnapshot borrow) `shouldBe` []
        releaseRegionBorrow svc borrow
        pure fillers
      forM_ fillers $ \h → settlementOf h >>= \case
        Succeeded (ARemoved _) → pure ()
        other → expectationFailure ("a filler: " <> show other)
      settleChecks svc

-- | A build's read refused for pressure in the middle of the build (the storage service's queue full), driven
-- directly: the build is stepped by hand against a real store on a real file, so no storage worker can take a
-- queued job between the moment the queue is full and the build's next read. Through the service a worker
-- that finishes the build's held read takes the next queued job at once, so that moment cannot be held.
buildPressureSpec ∷ Spec
buildPressureSpec =
  it "keeps a build whose read is refused for pressure mid-build on its pin, and resumes it to an uninterrupted build's result once the storage service drains" $
    H.withEnv $ \env → do
      let h0 = H.newStoreH smallSpec
          cfg = hCfg h0
          denv = Scenes.envFor (Scenes.limitsWith 64) Scenes.twoOpenings
          regions = [region 0 0 0]
      backing ← H.openBacking env (hIdent h0) cfg
      -- a committed run record in the region's columns, written to the file: a build must read its page
      plan ← either fail pure (H.planFor h0 1)
      store ← H.runTxn env backing (hStore h0) plan >>= H.finishPublish
      let io = Io (H.envSvc env) backing ExplicitWork
          toEnd ∷ Store → Build → IO (Build, Either String [(RegionCoord, RegionCopy)])
          toEnd st b = do
            (b', p) ← stepBuild io OwnerRunning st b
            case p of
              BMore → toEnd st b'
              BNoted h → pure (b', Left ("noted " <> show h))
              BBlocked wait → atomically wait >> toEnd st b'
              BDone copies → pure (b', Right copies)
              BPressed busy → pure (b', Left ("pressed " <> show busy))
              BFailed h → pure (b', Left ("failed " <> show h))
              BDrained → pure (b', Left "drained")
          parts copies = [(r, rcTerrain c, rcKnowledge c, rcWork c) | (r, c) ← copies]
      -- the uninterrupted build
      (pinned1, b1) ← either (fail . show) pure (startBuild store denv regions)
      (b1', done1) ← toEnd pinned1 b1
      uninterrupted ← either fail (pure . parts) done1
      _ ← pure (endBuild pinned1 b1')
      -- the same build with every storage worker held and the queue full before its first read
      (pinned2, b2) ← either (fail . show) pure (startBuild store denv regions)
      held ← H.addGate (H.envProbe env) isRead
      let submit = Storage.submitRead (H.envSvc env) backing ExplicitWork cfg (PageNo 1) 1 Storage.ReadValidated
          fill acc = submit >>= \case
            Right t → fill (t : acc)
            Left _ → pure acc
      -- both workers take a read and are held at the seam; then reads are queued until the queue refuses one
      first ← fmap concat . forM [1, 2 ∷ Int] $ \_ → either (const []) pure <$> submit
      H.awaitReached held 2
      queued ← fill []
      let tickets = first <> queued
      atomically (Storage.snQueued <$> Storage.snapshotOf (H.envSvc env)) >>= (`shouldBe` 8)
      (b2', refused) ← stepBuild io OwnerRunning pinned2 b2
      case refused of
        BPressed _ → pure ()
        other → expectationFailure ("the build's read under a full queue: " <> showProgress other)
      -- still on its pin, not draining, nothing copied yet
      (buildVersion b2', buildDraining b2') `shouldBe` (buildVersion b2, False)
      H.openGate held
      forM_ tickets $ \t → atomically (Storage.awaitTicket (H.envSvc env) t) >> Storage.discardTicket (H.envSvc env) t
      (b2'', done2) ← toEnd pinned2 b2'
      resumed ← either fail (pure . parts) done2
      _ ← pure (endBuild pinned2 b2'')
      resumed `shouldBe` uninterrupted
  where
    showProgress = \case
      BMore → "more"
      BNoted h → "noted " <> show h
      BBlocked _ → "blocked"
      BPressed b → "pressed " <> show b
      BDone _ → "done"
      BFailed h → "failed " <> show h
      BDrained → "drained"

failureSpec ∷ Spec
failureSpec =
  it "makes unavailable, at every cell, each part a failed page was needed for, records the failure as any read's, reads that page once, and keeps every region established without it" $ do
    storage ← H.newProbe
    withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor storage) $ \svc → guarded svc $ \taken → do
      let definition = ground []
          surface = [(x, y, 7) | x ← [0 .. 15], y ← [0 .. 3]]
          damaged = region 0 0 0
          beside = region 1 0 0
          apart = region (-3) 0 0
      -- 64 removals, one run in each of 64 of the region's columns and their discovery: the store spans pages
      -- the region's build reads and a far region's does not
      (_, lease) ← openWith svc definition surface
      let pagesReadFor regions = do
            settled svc lease
            H.clearEvents storage
            borrow ← borrowOf taken lease regions
            releaseRegionBorrow svc borrow
            settled svc lease
            Set.fromList . mapMaybe (\case OpReadAt o _ → Just o; _ → Nothing) <$> H.events storage
      ofDamaged ← pagesReadFor [damaged]
      ofApart ← pagesReadFor [apart]
      let failing = Set.difference ofDamaged ofApart
      failing `shouldSatisfy` (not . Set.null)
      before ← residencyOf svc lease
      H.clearEvents storage
      H.addRule storage (-1) (\case OpReadAt o _ → Set.member o failing; _ → False) (H.FailWith (Errno 5))
      borrow ← borrowOf taken lease [damaged, beside, apart]
      let snapshot = regionBorrowSnapshot borrow
          unavailable = \case PartUnavailable → True; _ → False
          parts r = (unavailable (regionTerrain snapshot r), unavailable (regionKnowledge snapshot r))
          known = knownAir definition surface [damaged, beside, apart]
      -- the damaged region lost at least one part
      parts damaged `shouldSatisfy` uncurry (||)
      -- a part that is unavailable is so at every cell, never air, fog or the source; a part that is
      -- ready is right
      take 10
        [ (c, t, k)
        | r ← [damaged, beside, apart]
        , let (noTerrain, noKnowledge) = parts r
        , c@(x, y, z) ← cellsOf r
        , let t = regionCell snapshot (tile x y z)
              k = regionCellKnowledge snapshot (tile x y z)
        , (if noTerrain then t /= PartUnavailable else fmap cellMaterial t /= PartReady (expectedMaterial definition surface c))
            || (if noKnowledge then k /= PartUnavailable else maybe False (\want → k /= PartReady want) (expectedKnowledge definition surface known c))
        ]
        `shouldBe` []
      -- the region apart needed no failed page: it is whole
      parts apart `shouldBe` (False, False)
      -- each failed page was read once: a later need of it is answered from the build's record of it
      native ← H.events storage
      [o | o ← Set.toList failing, length [() | OpReadAt o' _ ← native, o' == o] > 1] `shouldBe` []
      -- the arena recorded the failure as any failed read: it is paused for I/O
      arenaStatus svc lease >>= expectRight >>= \st → statusStorage st `shouldSatisfy` \case StoragePaused conditions → CondIo `elem` conditions; _ → False
      -- and nothing of the arena's residency, recency or revisions moved
      residencyOf svc lease >>= (`shouldBe` before)
      releaseRegionBorrow svc borrow
      settleChecks svc

-- ---------------------------------------------------------------------------
-- Ownership and release

ownershipSpec ∷ Spec
ownershipSpec = describe "ownership" $ do
  it "holds no reader pin once settled, and the pages its version held retire while it is held" $
    withService defaultConfig $ \svc → guarded svc $ \taken → do
      (_, lease) ← openWith svc (fxSpec twoOpenings) openingA
      borrow ← borrowOf taken lease [region 0 0 0]
      waitFor (backedAtRestSTM svc >>= check)
      inspectBacked svc >>= (`shouldBe` [])
      let answers = answersOf (regionBorrowSnapshot borrow)
      -- removals replace the pages of the version it read; reclamation retires them while it is held
      forM_ openingB $ \(x, y, z) → removeCell' svc lease (tile x y z)
      settled svc lease
      answersOf (regionBorrowSnapshot borrow) `shouldBe` answers
      releaseRegionBorrow svc borrow
      settleChecks svc

  it "returns its charge at its scope's exit, normal or failed, and at nothing before" $
    withService defaultConfig $ \svc → guarded svc $ \_ → do
      (_, lease) ← openWith svc (ground []) []
      (base, _, _, _) ← accountsOf svc
      inside ← withRegionSnapshot svc lease [region 5 5 (-1)] $ \case
        Right snapshot → do
          charges ← atomically (inspectRegionalSTM svc)
          pure [(regionalChargeTaken c, regionalChargeFootprint c == Just (regionSnapshotFootprint snapshot)) | c ← charges]
        Left settlement → fail ("the snapshot ended " <> show settlement)
      inside `shouldBe` Right [(True, True)]
      accountsOf svc >>= \(use, regional, _, holds) → (use, regional, holds) `shouldBe` (base, [], 0)
      failed ← try (withRegionSnapshot svc lease [region 5 5 (-1)] (\_ → throwIO (ErrorCall "the body failed") ∷ IO ()))
      failed `shouldBe` Left (ErrorCall "the body failed")
      accountsOf svc >>= \(use, regional, _, holds) → (use, regional, holds) `shouldBe` (base, [], 0)
      settleChecks svc

  it "releases a result nobody took when its request is cancelled before settlement or retired after it, each once" $
    withService defaultConfig $ \svc → guarded svc $ \_ → do
      (_, lease) ← openWith svc (ground []) []
      (base, _, _, _) ← accountsOf svc
      -- staged, waiting for its host: cancelled
      waiting ← newHost False
      first ← okOf (regionsWith svc (hostEndpoint svc Nothing waiting) lease [region 5 5 (-1)])
      waitFor (readTVar (hostReady waiting) >>= check . (>= 1))
      cancel svc first >>= (`shouldBe` CancelWon)
      settledOf waiting >>= (`shouldBe` [Cancelled])
      accountsOf svc >>= \(use, regional, _, holds) → (use, regional, holds) `shouldBe` (base, [], 0)
      -- settled, never taken: retired
      eligible ← newHost True
      second ← okOf (regionsWith svc (hostEndpoint svc Nothing eligible) lease [region 5 5 (-1)])
      _ ← settlementOf eligible >>= borrowIn
      map regionalChargeTaken <$> atomically (inspectRegionalSTM svc) >>= (`shouldBe` [False])
      atomically (retireSTM svc second)
      accountsOf svc >>= \(use, regional, _, holds) → (use, regional, holds) `shouldBe` (base, [], 0)
      atomically (retireSTM svc second)
      accountsOf svc >>= \(use, _, _, _) → use `shouldBe` base
      settleChecks svc

  it "releases a result nobody took at the arena's closure and the client's end, and leaves a taken borrow charged, its arena retiring, until its holder releases it" $
    withService defaultConfig $ \svc → guarded svc $ \taken → do
      let arenasCounted = (\(_, _, rows, _) → [counted | (name, counted, _) ← rows, name == "arenas"]) <$> accountsOf svc
          untakenOf lease = do
            host ← newHost True
            _ ← okOf (regionsWith svc (hostEndpoint svc Nothing host) lease [region 5 5 1])
            _ ← settlementOf host >>= borrowIn
            pure ()
      -- the arena's closure
      (_, closing) ← openWith svc (ground []) []
      kept ← borrowOf taken closing [region 5 5 (-1)]
      untakenOf closing
      map regionalChargeTaken <$> atomically (inspectRegionalSTM svc) >>= (`shouldBe` [True, False])
      _ ← releaseLease svc closing
      map regionalChargeTaken <$> atomically (inspectRegionalSTM svc) >>= (`shouldBe` [True])
      arenasCounted >>= (`shouldBe` [1])
      releaseRegionBorrow svc kept
      atomically (inspectRegionalSTM svc) >>= (`shouldBe` [])
      waitFor (backedAtRestSTM svc >>= check)
      arenasCounted >>= (`shouldBe` [0])
      -- the client's end
      (client, ending) ← openWith svc (ground []) []
      kept' ← borrowOf taken ending [region 5 5 (-1)]
      untakenOf ending
      endClient svc client
      map regionalChargeTaken <$> atomically (inspectRegionalSTM svc) >>= (`shouldBe` [True])
      arenasCounted >>= (`shouldBe` [1])
      releaseRegionBorrow svc kept'
      atomically (inspectRegionalSTM svc) >>= (`shouldBe` [])
      settleChecks svc

  it "keeps the service live while a taken borrow is outstanding, then ends in order" $ do
    events ← newMVar ([] ∷ [String])
    let note e = modifyMVar_ events (pure . (e :))
    boxed ← newEmptyMVar
    holding ← newEmptyMVar
    bodyDone ← newEmptyMVar
    release ← newEmptyMVar
    returned ← newEmptyMVar
    let served = do
          withService defaultConfig $ \svc → do
            (_, lease) ← openWith svc (ground []) []
            putMVar boxed (svc, lease)
            bounded (readMVar holding)
            note "body done"
            putMVar bodyDone svc
          note "service returned"
          putMVar returned ()
        borrower = do
          (svc, lease) ← bounded (readMVar boxed)
          _ ← withRegionSnapshot svc lease [region 5 5 (-1)] $ \_ → do
            putMVar holding ()
            readMVar release
            note "borrow finished"
          pure ()
    withOwnedThread served $ \_ waitServed →
      withOwnedThread borrower $ \_ waitBorrower → do
        svc ← bounded (readMVar bodyDone)
        -- the body has finished and the service is closing: admission is closed
        waitFor (serviceAdmitting svc >>= check . not)
        -- closing cannot finish while the borrow is outstanding
        tryReadMVar returned >>= (`shouldBe` Nothing)
        putMVar release ()
        bounded waitBorrower
        bounded waitServed
    chronological ← reverse <$> readMVar events
    chronological `shouldBe` ["body done", "borrow finished", "service returned"]

  it "refuses a snapshot whose reservation the retained bank cannot make, with nothing created" $
    withService defaultConfig {configRetainedBytes = regionSnapshotReservation 1 - 1} $ \svc → guarded svc $ \_ → do
      (_, lease) ← openWith svc (ground []) []
      before ← accountsOf svc
      refused ← requestRegionSnapshot svc lease [region 5 5 (-1)]
      refusedWith refused `shouldBe` Just (RefusedBusy BusyRetained)
      accountsOf svc >>= (`shouldBe` before)
      settleChecks svc

-- ---------------------------------------------------------------------------
-- Admission

admissionSpec ∷ Spec
admissionSpec =
  it "refuses an empty set, a duplicate region, a region of unsupported coordinates, more regions than a hold may and a released lease, each leaving every account as it was" $
    withService (configWith (\s → s {specHoldRegions = 2})) $ \svc → guarded svc $ \_ → do
      (client, lease) ← openWith svc (ground []) []
      before ← accountsOf svc
      forM_ [[], [region 0 0 0, region 0 0 0], [RegionCoord maxBound 0 0], [region i 0 0 | i ← [0 .. 2]]] $ \regions → do
        refused ← requestRegionSnapshot svc lease regions
        case refusedWith refused of
          Just (RefusedInvalid _) → pure ()
          other → expectationFailure (show regions <> ": " <> show other)
        accountsOf svc >>= (`shouldBe` before)
      attached ← okOf (attachArena svc client "regional") >>= await svc >>= expectSuccess
      _ ← releaseLease svc attached
      refusedWith <$> requestRegionSnapshot svc attached [region 0 0 0] >>= (`shouldBe` Just RefusedAuthority)
      accountsOf svc >>= (`shouldBe` before)
      settleChecks svc

