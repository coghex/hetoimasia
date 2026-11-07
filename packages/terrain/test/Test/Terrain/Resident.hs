-- | Examples for sparse resident detail: explicit coverage, top-only demand,
-- separated segments, reconstruction from source plus retained removals across
-- discard cycles, and independence from demand order.
module Test.Terrain.Resident (spec) where

import Control.Monad (foldM, forM_)
import Data.List (sort)
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Changes
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), axisValue)
import Hetoimasia.Terrain.Palette
import Hetoimasia.Terrain.Resident
import Hetoimasia.Terrain.Segment
import Hetoimasia.Terrain.Source
import Test.Hspec
import Test.QuickCheck
import Test.Terrain.Model

limitless ∷ ChangeLimits
limitless = ChangeLimits 1000000

soil ∷ Source
soil = mustSource soilOverStone

-- | Materialize one request, failing the example on a refusal.
demand ∷ Source → Changes → (Palette, Resident) → (Integer, Integer, Integer, Integer) → (Palette, Resident)
demand source changes (palette, resident) (x, y, lo, hi) =
  either (error . show) id (materialize 8192 source changes palette resident (mustColumn x y) (mustRange lo hi))

start ∷ (Palette, Resident)
start = (either (error . show) id (internSourceMaterials soil emptyPalette), emptyResident)

cellsOf ∷ Palette → Resident → Integer → Integer → [Integer] → [Maybe (Maybe (String, Int))]
cellsOf palette resident x y zs =
  [ either (error . show) (fmap fromCell) (residentCell palette resident (mustTile x y z))
  | z ← zs
  ]

remove ∷ Source → Changes → (Integer, Integer, Integer) → Changes
remove source changes (x, y, z) = either (error . show) removeResult (removeCell limitless source (mustTile x y z) changes)

spec ∷ Spec
spec = describe "Resident detail" $ do
  coverageSpec
  reconstructionSpec
  modelSpec

coverageSpec ∷ Spec
coverageSpec = describe "explicit coverage" $ do
  it "keeps an unrequested cell unmaterialized, never air" $ do
    let (palette, resident) = demand soil emptyChanges start (0, 0, 0, 1)
    cellsOf palette resident 0 0 [0] `shouldBe` [Just (Just ("soil", 0))]
    cellsOf palette resident 0 0 [1, -1, 31, -4, lowest, highest] `shouldBe` replicate 6 Nothing
    cellsOf palette resident 1 0 [0] `shouldBe` [Nothing]
  it "materializes air when air was requested, as a known value" $ do
    let (palette, resident) = demand soil emptyChanges start (0, 0, 5, 6)
    cellsOf palette resident 0 0 [5] `shouldBe` [Just Nothing]
  it "creates one known cell for a top-only request, not a 32-cell region" $ do
    let (_, resident) = demand soil emptyChanges start (0, 0, 0, 1)
        stats = residentStats resident
    (statColumns stats, statSegments stats, statKnownCells stats, statPayloadBytes stats) `shouldBe` (1, 1, 1, 2)
    map segmentLength (residentSegments resident (mustColumn 0 0)) `shouldBe` [1]
  it "creates a one-cell segment at great depth and does not fill the buried cells" $ do
    let (palette, resident) = demand soil emptyChanges start (0, 0, lowest + 5, lowest + 6)
        stats = residentStats resident
    (statSegments stats, statKnownCells stats, statPayloadBytes stats) `shouldBe` (1, 1, 2)
    cellsOf palette resident 0 0 [lowest + 4, lowest + 5, lowest + 6] `shouldBe` [Nothing, Just (Just ("stone", 0)), Nothing]
  it "does not materialize the gap between widely separated known segments" $ do
    let steps = [(0, 0, 0, 1), (0, 0, -(2 ^ (50 ∷ Int)), -(2 ^ (50 ∷ Int)) + 1), (0, 0, 2 ^ (60 ∷ Int), 2 ^ (60 ∷ Int) + 3), (0, 0, lowest, lowest + 1)]
        (palette, resident) = foldl (demand soil emptyChanges) start steps
        stats = residentStats resident
    (statSegments stats, statKnownCells stats) `shouldBe` (4, 1 + 1 + 3 + 1)
    cellsOf palette resident 0 0 [-1, -(2 ^ (50 ∷ Int)) + 1, 2 ^ (60 ∷ Int) - 1, 2 ^ (60 ∷ Int) + 3] `shouldBe` replicate 4 Nothing
  it "keeps two known cells of one region as two segments, and joins adjacent ones" $ do
    let (_, apart) = foldl (demand soil emptyChanges) start [(0, 0, 0, 1), (0, 0, 31, 32)]
        (_, joined) = foldl (demand soil emptyChanges) start [(0, 0, 0, 1), (0, 0, 2, 3), (0, 0, 1, 2)]
    map segmentLength (residentSegments apart (mustColumn 0 0)) `shouldBe` [1, 1]
    map segmentLength (residentSegments joined (mustColumn 0 0)) `shouldBe` [3]
  it "never lets a segment cross a vertical region boundary, on either side of zero" $ do
    let (palette, resident) = demand soil emptyChanges start (0, 0, -3, 4)
        lengthsOf col = map (\s → (axisValue (segmentStart s), segmentLength s)) (residentSegments resident col)
    lengthsOf (mustColumn 0 0) `shouldBe` [(-3, 3), (0, 4)]
    cellsOf palette resident 0 0 [-3, -1, 0, 3] `shouldBe` [Just (Just ("soil", 0)), Just (Just ("soil", 0)), Just (Just ("soil", 0)), Just Nothing]
    let (_, deep) = demand soil emptyChanges start (0, 0, -33, -31)
    map (\s → (axisValue (segmentStart s), segmentLength s)) (residentSegments deep (mustColumn 0 0)) `shouldBe` [(-33, 1), (-32, 1)]
  it "makes a full 32-level region a 32-cell segment" $ do
    let (_, resident) = demand soil emptyChanges start (0, 0, -32, 0)
    map segmentLength (residentSegments resident (mustColumn 0 0)) `shouldBe` [32]
    map segmentEncoding (residentSegments resident (mustColumn 0 0)) `shouldBe` [Runs]
    map segmentPayloadBytes (residentSegments resident (mustColumn 0 0)) `shouldBe` [8]
  it "refuses an oversized request and a full palette, preserving the previous value" $ do
    let (palette, resident) = demand soil emptyChanges start (0, 0, 0, 1)
    materialize 8192 soil emptyChanges palette resident (mustColumn 0 0) (mustRange 0 8193) `shouldBe` Left (MaterializeTooLarge 8193 8192)
    materialize 8192 soil emptyChanges palette resident (mustColumn 0 0) (mustRange 0 8192) `shouldSatisfy` isRight'
    let full = foldl (\p i → either (error . show) snd (internMaterial (mustMaterial ("x" <> show i)) p)) emptyPalette [1 .. 4095 ∷ Int]
    materialize 8192 soil emptyChanges full emptyResident (mustColumn 0 0) (mustRange 0 1) `shouldBe` Left (ResidentPalette PaletteFull)
    cellsOf palette resident 0 0 [0] `shouldBe` [Just (Just ("soil", 0))]
  it "reports payload, segment metadata and column index separately" $ do
    let (_, resident) = foldl (demand soil emptyChanges) start [(0, 0, 0, 1), (0, 0, -32, 0), (1, 1, 0, 1)]
        stats = residentStats resident
    (statColumns stats, statSegments stats, statKnownCells stats) `shouldBe` (2, 3, 34)
    statPayloadBytes stats `shouldBe` 2 + 8 + 2
    statMetadataBytes stats `shouldBe` 3 * 32 + 2 * columnIndexBytes
  where
    isRight' = either (const False) (const True)

reconstructionSpec ∷ Spec
reconstructionSpec = describe "reconstruction from source plus retained removals" $ do
  it "shows a cell removed while it was not resident as absent when materialized later" $ do
    let changes = remove soil emptyChanges (0, 0, 0)
        (palette, resident) = demand soil changes start (0, 0, -1, 1)
    cellsOf palette resident 0 0 [-1, 0] `shouldBe` [Just (Just ("soil", 0)), Just Nothing]
  it "keeps every change when resident detail is discarded, then reconstructs the same answer" $ do
    let changes0 = remove soil emptyChanges (0, 0, 0)
        first = demand soil changes0 start (0, 0, -3, 2)
        dropped = (fst first, discardRange (mustColumn 0 0) (mustRange (-3) 2) (snd first))
        changes1 = remove soil changes0 (0, 0, -1)
        second = demand soil changes1 dropped (0, 0, -3, 2)
    residentColumns (snd dropped) `shouldBe` []
    cellsOf (fst second) (snd second) 0 0 [-3 .. 1]
      `shouldBe` [Just (Just ("soil", 0)), Just (Just ("soil", 0)), Just Nothing, Just Nothing, Just Nothing]
  it "survives repeated materialize / remove / discard / reconstruct cycles without resurrecting terrain" $ do
    let cycleStep (palette, resident, changes) z =
          let removed = remove soil changes (0, 0, z)
              (grown, loaded) = demand soil removed (palette, resident) (0, 0, -6, 2)
              dropped = discardRegion (RegionCoord 0 0 (-1)) (discardRegion (RegionCoord 0 0 0) loaded)
           in (grown, dropped, removed)
        (palette1, resident1, final) = foldl cycleStep (fst start, snd start, emptyChanges) [0, -1, -2, -1]
        (palette2, resident2) = demand soil final (palette1, resident1) (0, 0, -6, 2)
    residentColumns resident1 `shouldBe` []
    cellsOf palette2 resident2 0 0 [-6 .. 1]
      `shouldBe` [Just (Just ("stone", 0)), Just (Just ("stone", 0)), Just (Just ("stone", 0)), Just (Just ("soil", 0)), Just Nothing, Just Nothing, Just Nothing, Just Nothing]
  it "starts a fresh session with no inherited change" $ do
    let dirty = remove soil emptyChanges (0, 0, 0)
        (pOld, rOld) = demand soil dirty start (0, 0, 0, 1)
        (pNew, rNew) = demand soil emptyChanges start (0, 0, 0, 1)
    cellsOf pOld rOld 0 0 [0] `shouldBe` [Just Nothing]
    cellsOf pNew rNew 0 0 [0] `shouldBe` [Just (Just ("soil", 0))]
  it "reconstructs only the requested cells of a region" $ do
    let (palette, resident) = demand soil emptyChanges start (3, 3, -32, -31)
    statKnownCells (residentStats resident) `shouldBe` 1
    cellsOf palette resident 3 3 [-32, -31, -1, 0] `shouldBe` [Just (Just ("stone", 0)), Nothing, Nothing, Nothing]
  it "discards a region's detail and nothing else" $ do
    let (palette, resident) = foldl (demand soil emptyChanges) start [(0, 0, 0, 1), (15, 15, -1, 0), (16, 0, 0, 1), (0, 0, 40, 41)]
        trimmed = discardRegion (RegionCoord 0 0 0) resident
    cellsOf palette trimmed 0 0 [0, 40] `shouldBe` [Nothing, Just Nothing]
    cellsOf palette trimmed 15 15 [-1] `shouldBe` [Just (Just ("soil", 0))]
    cellsOf palette trimmed 16 0 [0] `shouldBe` [Just (Just ("soil", 0))]
    discardRegion (RegionCoord maxBound maxBound maxBound) resident `shouldBe` resident
  it "trims a segment that straddles a discarded interval" $ do
    let (palette, resident) = demand soil emptyChanges start (0, 0, -3, 5)
        trimmed = discardRange (mustColumn 0 0) (mustRange 0 2) resident
    cellsOf palette trimmed 0 0 [-3, -1, 0, 1, 2, 4] `shouldBe` [Just (Just ("soil", 0)), Just (Just ("soil", 0)), Nothing, Nothing, Just Nothing, Just Nothing]
    map (\s → (axisValue (segmentStart s), segmentLength s)) (residentSegments trimmed (mustColumn 0 0)) `shouldBe` [(-3, 3), (2, 3)]
    discardColumn (mustColumn 0 0) trimmed `shouldBe` emptyResident
  it "yields the same known values whatever order the demands arrive in" $ do
    let changes = foldl (remove soil) emptyChanges [(0, 0, 0), (0, 0, -2), (1, 0, -1)]
        demands = [(0, 0, -4, 2), (0, 0, 40, 45), (1, 0, -3, 1), (0, 0, 0, 3), (1, 0, 0, 5), (0, 1, 7, 8)]
        outcome order =
          let (p, r) = foldl (demand soil changes) start order
           in ( [ (col, [(axisValue (segmentStart s), segmentLength s) | s ← residentSegments r col])
                | col ← residentColumns r
                ]
              , [cellsOf p r x y [-6 .. 50] | (x, y) ← [(0, 0), (1, 0), (0, 1)]]
              )
    forM_ [reverse demands, drop 2 demands <> take 2 demands, sort demands] $ \order →
      outcome order `shouldBe` outcome demands

-- | The known-set bookkeeping of a random sequence of demands and discards must
-- match the independent model, and every known value must match source plus
-- removals at the moment it was last reconstructed.
modelSpec ∷ Spec
modelSpec = describe "against the independent model" $
  it "tracks exactly the requested cells through random demands, removals and discards" $
    withNumTests 200 $ property $ forAll (listOf genAction) $ \actions →
      case foldM apply (fst start, snd start, emptyChanges, Set.empty, []) actions of
        Left message → counterexample message False
        Right _ → property True
  where
    apply (palette, resident, changes, known, removals) action = case action of
      RemoveAt cell@(x, y, z) →
        Right (palette, resident, remove soil changes cell, known, if isJust (modelCell soilOverStone removals (x, y, z)) then (x, y, z, z + 1) : removals else removals)
      DemandAt x y lo hi → do
        let (palette', resident') = demand soil changes (palette, resident) (x, y, lo, hi)
            known' = Set.union known (Set.fromList [(x, y, z) | z ← [lo .. hi - 1]])
        check palette' resident' known' removals (Just (x, y, lo, hi))
        pure (palette', resident', changes, known', removals)
      DiscardAt x y lo hi → do
        let resident' = discardRange (mustColumn x y) (mustRange lo hi) resident
            known' = Set.filter (\(kx, ky, kz) → not (kx == x && ky == y && kz >= lo && kz < hi)) known
        check palette resident' known' removals Nothing
        pure (palette, resident', changes, known', removals)
    check palette resident known removals fresh =
      forM_ [(x, y, z) | x ← [0, 1], y ← [0, 1], z ← [-12 .. 12]] $ \(x, y, z) →
        case (Set.member (x, y, z) known, either (const Nothing) id (residentCell palette resident (mustTile x y z))) of
          (True, Nothing) → Left ("known cell " <> show (x, y, z) <> " is unmaterialized")
          (False, Just _) → Left ("unrequested cell " <> show (x, y, z) <> " is materialized")
          (True, Just value)
            | Just (fx, fy, lo, hi) ← fresh, fx == x, fy == y, lo <= z, z < hi
            , fromCell value /= modelCell soilOverStone removals (x, y, z) →
                Left ("stale cell " <> show (x, y, z))
          _ → Right ()

data Action
  = RemoveAt (Integer, Integer, Integer)
  | DemandAt Integer Integer Integer Integer
  | DiscardAt Integer Integer Integer Integer
  deriving stock (Show)

genAction ∷ Gen Action
genAction =
  oneof
    [ RemoveAt <$> ((,,) <$> choose (0, 1) <*> choose (0, 1) <*> choose (-6, 6))
    , range DemandAt
    , range DiscardAt
    ]
  where
    range ctor = do
      x ← choose (0, 1)
      y ← choose (0, 1)
      lo ← choose (-12, 11)
      width ← choose (1, 14)
      pure (ctor x y lo (lo + width))
