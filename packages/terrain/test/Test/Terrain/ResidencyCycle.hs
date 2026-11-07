-- | The residency model driven the way the later terrain service will drive it,
-- over the real data layer of TRA-2.
--
-- The test plays the owner: it feeds events to the pure model and performs the
-- effects each decision asks for with the real 'Hetoimasia.Terrain.Resident',
-- 'Hetoimasia.Terrain.Changes' and 'Hetoimasia.Terrain.Query' values. What a job
-- stored, what a removal retained and what an eviction discarded are measured
-- from those values, so the model's conservative reservations are reconciled
-- against real costs, and the expected cell answers come from the independent
-- naive model of "Test.Terrain.Model".
--
-- One cycle removes a cell, hands its changes off, evicts the edited region
-- under pressure from other demand, and reconstructs it from the source plus
-- the retained changes. Several cycles run in a row, so a removal made in an
-- earlier cycle must survive every later offload and reload.
module Test.Terrain.ResidencyCycle (spec) where

import Control.Monad (foldM, forM_)
import Data.List (sort)
import Hetoimasia.Terrain.Cell (Column, ZRange)
import Hetoimasia.Terrain.Changes
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Palette
import Hetoimasia.Terrain.Query (cellAt)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Resident
import Hetoimasia.Terrain.Segment (segmentLength)
import Hetoimasia.Terrain.Source (Source, SourceSpec (..))
import Test.Hspec
import Test.Terrain.Model
import Test.Terrain.ResidencySupport

data World = World
  { wModel ∷ !Model
  , wChanges ∷ !Changes
  , wPalette ∷ !Palette
  , wResident ∷ !Resident
  }

-- | Soil over stone, with soil from level -3 up to level 40, so cells of the first
-- two vertical regions are solid.
deepSoil ∷ SourceSpec
deepSoil =
  SourceSpec
    { specMaterials = ["soil", "stone"]
    , specLayers = [softLayer Nothing (Just (-3)) "stone" 0, layer (-3) 40 "soil" 0]
    , specPatches = []
    }

source ∷ Source
source = mustSource deepSoil

changeLimits ∷ ChangeLimits
changeLimits = ChangeLimits 1000000

-- | Two columns and two levels of a region (the edits touch levels 0 and 1 of the
-- first region and level 0 of the one above), two regions per request: a region
-- stores at most 488 bytes (every cell its own segment) and a job beyond that
-- reserves 288, so the bank holds 1,552 at the least. Other demand (two queries of
-- two fresh regions, 544 reserved bytes each) does not fit beside an edited region,
-- so it must evict it, and reconstructing the edited regions must in turn evict that
-- demand.
limits ∷ Limits
limits = limitsWith $ \s → s {specResidentBytes = 1552, specEditBytes = 256, specExtentX = 2, specExtentZ = 2}

initial ∷ IO World
initial = initialWith limits

initialWith ∷ Limits → IO World
initialWith lim = do
  (m, _) ← stepOk (newModel lim) (OpenArena a1 rev0)
  palette ← either (fail . show) pure (internSourceMaterials source emptyPalette)
  pure (World m emptyChanges palette emptyResident)

-- | The real columns and level ranges a region-local coverage names.
realPieces ∷ RegionCoord → Coverage → [(Column, ZRange)]
realPieces (RegionCoord rx ry rz) cover =
  [ (mustColumn (toInteger rx * 16 + toInteger lx) (toInteger ry * 16 + toInteger ly), mustRange (toInteger rz * 32 + toInteger lo) (toInteger rz * 32 + toInteger hi))
  | ((lx, ly), intervals) ← coverageIntervals cover
  , (lo, hi) ← intervals
  ]

-- | Do a job's work on the real resident detail and measure what it stored.
realMaterialize ∷ World → RegionCoord → Coverage → IO (World, Cost)
realMaterialize w region cover = do
  let stored = residentStats (wResident w)
  (palette, resident) ←
    foldM
      (\(p, r) (column, range) → either (fail . show) pure (materialize 8192 source (wChanges w) p r column range))
      (wPalette w, wResident w)
      (realPieces region cover)
  let stored' = residentStats resident
      grew f = fromIntegral (max 0 (f stored' - f stored))
  pure
    ( w {wPalette = palette, wResident = resident}
    , -- Columns are attributed to the region (its own columns), not read from the
      -- shared index's growth: the data layer keeps one index entry per column
      -- across vertical regions, and a region must keep its own charge.
      Cost (coverageColumns cover) (grew statSegments) (grew statPayloadBytes)
    )

-- | The accounted bytes of the real resident detail: payload, segment metadata and
-- column index entries.
realBytes ∷ World → Int
realBytes w = let st = residentStats (wResident w) in statPayloadBytes st + statMetadataBytes st

-- | The model never charges less than the real detail occupies: every resident
-- region's own metadata plus the accounted bytes of the real detail.
assertCharged ∷ World → Expectation
assertCharged w = do
  let charged = sum [toInteger (regionBytes r) | r ← modelRegions (wModel w)]
      physical = 256 * toInteger (length (modelRegions (wModel w))) + toInteger (realBytes w)
  charged `shouldSatisfy` (>= physical)

-- | Perform the effects of every victim: discard its real detail, then report.
release ∷ World → RegionKey → IO World
release w (a, region) = do
  (m, _) ← stepOk (wModel w) (VictimReleased a region)
  let w' = w {wModel = m, wResident = discardRegion region (wResident w)}
  -- After each individual release the survivors are still charged for what they hold.
  assertCharged w'
  pure w'

-- | Submit an event that admits work and perform its victims' releases.
submit ∷ World → Event → IO World
submit w event = do
  (m, report) ← stepOk (wModel w) event
  case reportDecision report of
    Accepted admission → foldM release w {wModel = m} (admissionVictims admission)
    other → expectationFailure ("expected an admission, got " <> show other) >> pure w {wModel = m}

-- | Dispatch and complete every queued job against the real data.
drain ∷ World → IO World
drain w = do
  (m, report) ← stepOk (wModel w) Dispatch
  case reportDecision report of
    NothingToDispatch → pure w {wModel = m}
    Dispatched job (_, region) cover → do
      (w', cost) ← realMaterialize w {wModel = m} region cover
      (m', _) ← stepOk (wModel w') (JobCompleted job cost)
      drain w' {wModel = m'}
    other → expectationFailure ("unexpected " <> show other) >> pure w {wModel = m}

settle ∷ World → Integer → IO World
settle w rid = do
  (m, _) ← stepOk (wModel w) (Withdraw (RequestId (fromInteger rid)))
  pure w {wModel = m}

-- | The cells removed so far, as the independent model reads them.
removals ∷ [(Integer, Integer)] → [Removal]
removals cells = [(x, 0, z, z + 1) | (x, z) ← cells]

-- | Every cell in a small box agrees with the independent model.
agreeWithModel ∷ World → [(Integer, Integer)] → Expectation
agreeWithModel w cells =
  forM_ [(x, 0, z) | x ← [0 .. 2], z ← [-4 .. 35]] $ \(x, y, z) →
    fromCell (cellAt source (wChanges w) (mustTile x y z)) `shouldBe` modelCell deepSoil (removals cells) (x, y, z)

-- | What the resident detail says about the cell: unmaterialized, or its value.
residentAnswer ∷ World → Integer → Integer → Integer → Maybe (Maybe (String, Int))
residentAnswer w x y z = either (error . show) (fmap fromCell) (residentCell (wPalette w) (wResident w) (mustTile x y z))

regionOf ∷ Integer → Integer → Integer → (RegionCoord, Coverage)
regionOf x y z = let (r, l) = decomposeTile (mustTile x y z) in (r, coverageTile l)

spec ∷ Spec
spec = describe "Residency over the real data layer" $ do
  it "keeps every retained removal through repeated reserve, commit, handoff, evict and reconstruct cycles" $ do
    w0 ← initial
    let plan = [(0, 0), (1, 0), (0, 1), (1, 1), (0, 32), (1, 32)] ∷ [(Integer, Integer)]
    (final, done, _) ←
      foldM
        ( \(w, removed, rid) (x, z) → do
            let tile = mustTile x 0 z
                (region, cover) = regionOf x 0 z
                Revision n = revisionOf w
                next = Revision (n + 1)
            -- Reserve and load: the removal's cell becomes resident.
            w1 ← submit w (SubmitRemoval (RequestId (fromInteger rid)) a1 (revisionOf w) tile) >>= drain
            -- The real removal and its measured retained growth.
            let retainedBefore' = changesBytes (wChanges w1)
            outcome ← either (fail . show) pure (removeCell changeLimits source tile (wChanges w1))
            removeChanged outcome `shouldBe` True
            let changes' = removeResult outcome
                grown = changesBytes changes' - retainedBefore'
            -- Stage the edit: recompute the resident cell from source plus changes.
            (w2, _) ← realMaterialize w1 {wChanges = changes'} region cover
            residentAnswer w2 x 0 z `shouldBe` Just Nothing
            -- What the rebuilt segment now accounts beyond the old one.
            let regrown = max 0 (realBytes w2 - realBytes w1)
            (m3, committed) ← stepOk (wModel w2) (RemovalCommitted (RequestId (fromInteger rid)) next (fromIntegral grown) (fromIntegral regrown))
            assertCharged w2 {wModel = m3}
            -- What was reserved but not needed (64 minus the real growth) returns.
            reportDecision committed `shouldBe` Committed next (64 - fromIntegral grown) [] [] []
            -- Hand the changes off; the retained bytes do not grow again.
            let retainedBefore = [arenaRetainedBytes a | a ← modelArenas m3]
            m4 ← stepsOk m3 [BeginHandoff a1 region (fromIntegral (changesBytes changes')), HandoffConfirmed a1 region]
            [arenaRetainedBytes a | a ← modelArenas m4] `shouldBe` retainedBefore
            -- Pressure from other demand evicts the clean, unused regions.
            let fillersAt k = [demand (reg (k + 2 * rid) 0 0) (box 0 2 0 1 0 2), demand (reg (k + 1 + 2 * rid) 0 0) (box 0 2 0 1 0 2)]
            w3 ← submit w2 {wModel = m4, wChanges = changes'} (SubmitQuery (RequestId (fromInteger rid + 1000)) a1 next (fillersAt 40)) >>= drain
            w3b ← settle w3 (rid + 1000)
            w3c ← submit w3b (SubmitQuery (RequestId (fromInteger rid + 1500)) a1 next (fillersAt 80)) >>= drain
            w4 ← settle w3c (rid + 1500)
            -- The edited region is no longer resident: unknown, not air.
            residentAnswer w4 x 0 z `shouldBe` Nothing
            [regionCoord r | r ← modelRegions (wModel w4)] `shouldSatisfy` notElem region
            -- Reconstruct every removed cell together from source plus changes.
            let removed' = removed <> [(x, z)]
                demands = [uncurry demand (regionOf cx 0 cz) | (cx, cz) ← removed']
                merged = mergeDemands demands
            w5 ← submit w4 (SubmitQuery (RequestId (fromInteger rid + 2000)) a1 next merged) >>= drain
            forM_ removed' $ \(cx, cz) → residentAnswer w5 cx 0 cz `shouldBe` Just Nothing
            agreeWithModel w5 removed'
            w6 ← settle w5 (rid + 2000)
            pure (w6, removed', rid + 1)
        )
        (w0, [], 1)
        plan
    -- The model's retained bytes are the real changes' accounted size: two
    -- columns and two intervals each (levels 0 and 1 coalesce; level 32 is apart).
    changesBytes (wChanges final) `shouldBe` 2 * 48 + 4 * 16
    [arenaRetainedBytes a | a ← modelArenas (wModel final)] `shouldBe` [fromIntegral (changesBytes (wChanges final))]
    done `shouldBe` plan
    -- Nothing is left reserved and every bank is within its limit.
    let Ledgers (_, residentReserved) (_, editReserved) (stagingOccupied, stagingReserved) = ledgersOf (wModel final)
    (residentReserved, editReserved, stagingOccupied, stagingReserved) `shouldBe` (0, 0, 0, 0)
  it "reconciles every conservative reservation against the real stored cost" $ do
    -- Levels up to 20 of one column: a region stores at most 256 + 48 + 21 x 34 = 1,018
    -- bytes here and a job reserves at most 1,104 more.
    w0 ← initialWith (limitsWith $ \s → s {specResidentBytes = 5000, specStagingBytes = 4096, specExtentZ = 21})
    -- A request over several widely separated cells of one column: the model
    -- reserves for each interval, the real detail stores exactly that.
    let cells = [cell 0 0 0, cell 0 0 10, cell 0 0 20]
        demands = [demand (reg 0 0 0) (foldr1 coverageUnion cells)]
    (m, report) ← stepOk (wModel w0) (SubmitQuery (RequestId 1) a1 rev0 demands)
    let reserved = [jobActive j | j ← modelJobs m]
    length (admissionJobs (admission' report)) `shouldBe` 1
    w1 ← drain w0 {wModel = m}
    -- 256 metadata + 48 column + 3 x 32 segments + 3 x 2 payload = 406 actually
    -- stored: the three cells do not merge into one segment. The reservation is the
    -- dense bound, 64 payload bytes for each of the three intervals.
    let stats = residentStats (wResident w1)
    (statColumns stats, statSegments stats, statKnownCells stats) `shouldBe` (1, 3, 3)
    map regionBytes (modelRegions (wModel w1)) `shouldBe` [256 + 48 + 3 * 32 + 3 * 2]
    -- The reservation covered it (and was larger, by the payload bound).
    reserved `shouldBe` [256 + 48 + 3 * 32 + 3 * 64]
  it "reserves the growth of a compressed segment and reconciles it with the real rebuilt segment" $ do
    -- A column of 32 levels: a region stores at most 256 + 48 + 32 x 34 = 1,392 bytes
    -- and a job beyond it reserves 1,584, so one region per query needs 2,976 bytes.
    -- Eight pinned one-cell regions (8 x 338) and the uniform segment (338) leave
    -- exactly 124 of 3,166: room for two removals' growth (62 each).
    w00 ← initialWith (limitsWith $ \s → s {specResidentBytes = 3166, specStagingBytes = 4096, specQueuedCommands = 16, specQueryRegions = 1, specExtentZ = 32})
    w0 ← foldM (\w i → submit w (SubmitQuery (RequestId (fromInteger i)) a1 rev0 [demand (reg (10 + i) 0 0) (cell 0 0 0)]) >>= drain) w00 [11 .. 18]
    -- Region (0,0,-2) is levels -64..-33: all stone, one uniform segment of 2 bytes.
    w1 ← submit w0 (SubmitQuery (RequestId 1) a1 rev0 [demand (reg 0 0 (-2)) (box 0 1 0 1 0 32)]) >>= drain >>= \w → settle w 1
    map regionBytes [r | r ← modelRegions (wModel w1), regionCoord r == reg 0 0 (-2)] `shouldBe` [338]
    map segmentLength (residentSegments (wResident w1) (mustColumn 0 0)) `shouldBe` [32]
    let tile = mustTile 0 0 (-50)
        (region, cover) = regionOf 0 0 (-50)
    (w2, accepted) ← submitAdmission w1 (SubmitRemoval (RequestId 2) a1 rev0 tile)
    -- The cell is resident: no job, and the growth is reserved from the free 62.
    admissionJobs accepted `shouldBe` []
    ledgersOf (wModel w2) `shouldBe` Ledgers (3042, 62) (0, 64) (2016, 512)
    -- A second removal takes the other 62; a third finds the bank full: busy,
    -- since nothing may be evicted (every other region is pinned).
    (w2b, _) ← submitAdmission w2 (SubmitRemoval (RequestId 3) a1 rev0 (mustTile 0 0 (-51)))
    ledgersOf (wModel w2b) `shouldBe` Ledgers (3042, 124) (0, 128) (2240, 1024)
    refusal ← stepRefused (wModel w2b) (SubmitRemoval (RequestId 5) a1 rev0 (mustTile 0 0 (-52)))
    case refusal of
      Busy (NoEligibleEviction 62 0 _) → pure ()
      other → expectationFailure ("expected a busy refusal for the growth, got " <> show other)
    -- Abandoning the second returns its reservations.
    w2c ← settle w2b 3
    -- The real removal splits the uniform segment into three runs: 2 -> 12 bytes.
    outcome ← either (fail . show) pure (removeCell changeLimits source tile (wChanges w2c))
    let changes' = removeResult outcome
    (w3, _) ← realMaterialize w2c {wChanges = changes'} region cover
    let regrown = realBytes w3 - realBytes w2c
    regrown `shouldBe` 10
    (m4, committed) ← stepOk (wModel w3) (RemovalCommitted (RequestId 2) (Revision 1) (fromIntegral (changesBytes changes')) (fromIntegral regrown))
    reportDecision committed `shouldBe` Committed (Revision 1) 0 [] [] []
    -- Occupied now includes the growth; the unused 52 of the reservation returned.
    ledgersOf m4 `shouldBe` Ledgers (3052, 0) (64, 0) (1792, 0)
    assertCharged w3 {wModel = m4}
    -- The segment now occupies 348 bytes: another removal's 62 still fits (114 free).
    (w4, again) ← submitAdmission w3 {wModel = m4, wChanges = changes'} (SubmitRemoval (RequestId 4) a1 (Revision 1) (mustTile 0 0 (-51)))
    admissionJobs again `shouldBe` []
    ledgersOf (wModel w4) `shouldBe` Ledgers (3052, 62) (64, 64) (2016, 512)
  it "keeps a region's accumulated charge within the configured stored maximum as separate jobs fill it" $ do
    -- One 32-level column per region, one region per query, the least bank the
    -- configuration allows (a region stores at most 256 + 48 + 32 x 34 = 1,392 bytes and
    -- a job beyond it reserves 1,584: 2,976). Sixteen separate queries load levels 0, 2,
    -- ..., 30 of the column, each completed with the real net growth and withdrawn: the
    -- column entry is charged once, so the region holds the 848 bytes the real detail
    -- needs (256 + 48 + 16 x 34), not a column entry for every job.
    w0 ← initialWith (limitsWith $ \s → s {specResidentBytes = 2976, specStagingBytes = 4096, specQueryRegions = 1, specExtentZ = 32})
    evens ← foldM (\w z → submit w (SubmitQuery (RequestId (fromInteger z + 1)) a1 rev0 [demand (reg 0 0 0) (cell 0 0 z)]) >>= drain >>= \x → settle x (z + 1)) w0 [0, 2 .. 30]
    map regionBytes (modelRegions (wModel evens)) `shouldBe` [848]
    assertCharged evens
    -- The levels in between are one job of sixteen separate intervals, which the bank still holds.
    let odds = foldr1 coverageUnion [cell 0 0 z | z ← [1, 3 .. 31]]
    (_, admitted) ← stepOk (wModel evens) (SubmitQuery (RequestId 100) a1 rev0 [demand (reg 0 0 0) odds])
    length (admissionJobs (admission' admitted)) `shouldBe` 1
    admissionVictims (admission' admitted) `shouldBe` []
  it "keeps a surviving region charged for the shared column index after each individual release" $ do
    -- Two vertical regions of one column share one real column index entry; each
    -- is charged for its own column, so evicting either leaves the other charged.
    w0 ← initialWith (limitsWith $ \s → s {specResidentBytes = 964})
    w1 ← submit w0 (SubmitQuery (RequestId 1) a1 rev0 [demand (reg 0 0 0) (cell 0 0 0)]) >>= drain >>= \w → settle w 1
    w2 ← submit w1 (SubmitQuery (RequestId 2) a1 rev0 [demand (reg 0 0 1) (cell 0 0 0)]) >>= drain >>= \w → settle w 2
    statColumns (residentStats (wResident w2)) `shouldBe` 1
    map regionBytes (modelRegions (wModel w2)) `shouldBe` [338, 338]
    assertCharged w2
    -- Another region needs room: the older region is released first, and the check
    -- inside the release sees the survivor still charged its own 338 bytes.
    w3 ← submit w2 (SubmitQuery (RequestId 3) a1 rev0 [demand (reg 40 0 0) (cell 0 0 0)]) >>= drain
    sort [regionCoord r | r ← modelRegions (wModel w3)] `shouldBe` sort [reg 0 0 1, reg 40 0 0]
    assertCharged w3
    map regionBytes [r | r ← modelRegions (wModel w3), regionCoord r == reg 0 0 1] `shouldBe` [338]
  where
    submitAdmission w event = do
      (m, report) ← stepOk (wModel w) event
      case reportDecision report of
        Accepted a → (\w' → (w', a)) <$> foldM release w {wModel = m} (admissionVictims a)
        other → expectationFailure ("expected an admission, got " <> show other) >> fail "not admitted"
    revisionOf w = case [arenaRevision a | a ← modelArenas (wModel w)] of
      [r] → r
      _ → error "one arena expected"
    admission' report = case reportDecision report of
      Accepted a → a
      other → error (show other)

-- | Combine demands for the same region into one demand (union of coverage).
mergeDemands ∷ [RegionDemand] → [RegionDemand]
mergeDemands ds =
  [ RegionDemand r (foldr1 coverageUnion [demandCoverage d | d ← ds, demandRegion d == r])
  | r ← uniq (map demandRegion ds)
  ]
  where
    uniq = foldl (\acc x → if x `elem` acc then acc else acc <> [x]) []
