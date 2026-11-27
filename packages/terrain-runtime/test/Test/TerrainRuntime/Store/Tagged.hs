-- | Tagged replacements through the page-resident store: the version 2 runs, the narrowed cell's void and the planner that splits and
-- coalesces them, each step planned by the production planner against pages read back from the disk and compared with the plain
-- reference ('Retained') that applies the very candidate the pure model produced.
--
-- A run is air or limits each of its levels to a corner mask of that level's source material, so what a cell is comes from the pages
-- and the immutable source together; the effective cells read back are compared with the pure overlay's ('narrowedCell') and the
-- source material at each level.
module Test.TerrainRuntime.Store.Tagged (spec) where

import Control.Monad (foldM, forM_, unless)
import Data.Int (Int64)
import Hetoimasia.Terrain.Cell (Column, mkZRange)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), Changes, Replacement (..), changesFromReplacements, emptyChanges, narrowedCell)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Query (cellAt)
import Hetoimasia.Terrain.Shape (CornerMask, mkCornerMask)
import Hetoimasia.Terrain.Source (LayerSpec (..), Source, SourceSpec (..), defaultSourceLimits, mkSource)
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), StoreIdentity (..), TreeId (..), maxTxnPages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (decodeKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgUsablePages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (Window, windowInsert)
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference (RefBody (..), RefPage (..), diskRead, parsePage)
import Test.TerrainRuntime.Store.Scenes

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | Full cubes of stone below level 10 and of slab from 10 up to 300, open to the sky: one column's levels change source material
-- at 10, and a column can hold a run for every level.
tagged ∷ Scene
tagged = Scene "tagged" (SourceSpec ["stone", "slab"] [LayerSpec Nothing (Just 10) "stone" 0, LayerSpec (Just 10) (Just 1000) "slab" 0] [])

sourceOf ∷ Scene → Source
sourceOf scene = either (error . show) id (mkSource defaultSourceLimits (sceneSpec scene))

mask ∷ Int → CornerMask
mask n = either (error . show) id (mkCornerMask n)

start ∷ Run
start = newRun smallSpec tagged 64

at ∷ Integer → TileCoord
at = tileAt 0 0

col ∷ Column
col = columnAt 0 0

narrowAll ∷ Run → [(Integer, Int)] → Either String Run
narrowAll = foldM (\r (z, m) → narrowCell r (at z) (mask m))

-- | The runs of column (0, 0) the committed store holds, read through pages.
storedRuns ∷ Run → Either String [(Int64, Int64, Replacement)]
storedRuns run = (\rs → [(lo, hi, tag) | (KeyRun c lo, r) ← rs, c == col, Just (hi, tag) ← [payload r]]) <$> allRecords (runH run)

payload ∷ Record → Maybe (Int64, Replacement)
payload = \case
  RecRun hi → Just (hi, ReplaceAir)
  RecMaskRun hi m → Just (hi, ReplaceMask m)
  _ → Nothing

-- | The effective overlay the store's pages hold.
storeChanges ∷ Run → Either String Changes
storeChanges run = do
  rs ← allRecords (runH run)
  runs ← sequence [(\z → (c, z, tag)) <$> either (Left . show) Right (mkZRange (toInteger lo) (toInteger hi)) | (KeyRun c lo, r) ← rs, Just (hi, tag) ← [payload r]]
  either (Left . show) Right (changesFromReplacements (ChangeLimits maxBound) runs)

-- | The lowest level of the second leaf of the runs tree of column (0, 0): the key the root separates its first two leaves by.
leafSeparator ∷ Run → Either String Int64
leafSeparator run = do
  let h = runH run
      ArenaId a = siArena (hIdent h)
  root ← maybe (Left "no runs tree") (\(PageNo p) → Right p) (committedRoot (hStore h) TreeRuns)
  bytes ← maybe (Left "no root page") Right (diskRead (hDisk h) (PageNo root))
  page ← parsePage a (siSource (hIdent h)) bytes
  case rpBody page of
    RefInner ((_, _, _) : (k, _, _) : _) → case decodeKey TreeRuns k of
      Just (KeyRun _ lo) → Right lo
      _ → Left "the separator is not a run key"
    _ → Left "the runs tree has no second leaf"

-- | A read of a pinned version through a window filled page by page from the disk.
through ∷ Show a ⇒ H → ReaderToken → (Window → ReadOutcome a) → Either String a
through h tok f = either (const (Left "stale reader")) go (readerWindow (hStore h) tok)
  where
    go w = case f w of
      Read a → Right a
      ReadNeeds p → case diskRead (hDisk h) p of
        Nothing → Left ("missing page " <> show p)
        Just bs → either (Left . show) go (windowInsert (cfgUsablePages (hCfg h)) p bs w)
      other → Left (show other)

-- | The cell each level holds, from the source and a set of changes.
cellsOf ∷ Source → Changes → [Integer] → [String]
cellsOf src changes zs = [show (cellAt src changes (at z)) | z ← zs]

spec ∷ Spec
spec = describe "tagged replacements through the page-resident store (version 2)" $ do
  it "splits the run an edit lands in, keeps a long run whole and coalesces matching neighbours, as the pure model does" $ do
    r1 ← must (narrowAll start [(z, 12) | z ← [0 .. 19]])
    must (storedRuns r1) `shouldReturn` [(0, 20, ReplaceMask (mask 12))]
    -- a different mask in the middle splits the run in three, and air in a hole after it splits no further than its level
    r2 ← must (narrowCell r1 (at 10) (mask 8))
    must (storedRuns r2) `shouldReturn` [(0, 10, ReplaceMask (mask 12)), (10, 11, ReplaceMask (mask 8)), (11, 20, ReplaceMask (mask 12))]
    r3 ← must (narrowCell r2 (at 10) (mask 0))
    must (storedRuns r3) `shouldReturn` [(0, 10, ReplaceMask (mask 12)), (10, 11, ReplaceAir), (11, 20, ReplaceMask (mask 12))]
    -- a cell above the run takes its mask and coalesces with it; a cell with another mask stays a run of its own beside it
    r4 ← must (narrowAll r3 [(20, 12), (21, 8)])
    must (storedRuns r4) `shouldReturn` [(0, 10, ReplaceMask (mask 12)), (10, 11, ReplaceAir), (11, 21, ReplaceMask (mask 12)), (21, 22, ReplaceMask (mask 8))]
    -- narrowing a cell to the mask it already has is no work on either side, and changes nothing

    r5 ← must (narrowCell r4 (at 3) (mask 12))
    must (storedRuns r5) `shouldReturn` must' (storedRuns r4)
  it "reads a run back whole from a level inside it, and a range that starts inside a long run starts with that run" $ do
    r1 ← must (narrowAll start ([(z, 12) | z ← [0 .. 19]] <> [(10, 8)]))
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore (runH r1))))
    let h = (runH r1) {hStore = s1}
    through h tok (\w → readerFloorRun (hStore h) tok w col 15) `shouldBe` Right (Just (11, 20, ReplaceMask (mask 12)))
    through h tok (\w → readerFloorRun (hStore h) tok w col 5) `shouldBe` Right (Just (0, 10, ReplaceMask (mask 12)))
    through h tok (\w → readerFloorRun (hStore h) tok w col 10) `shouldBe` Right (Just (10, 11, ReplaceMask (mask 8)))
    ranged ← must (through h tok (\w → readerRange (hStore h) tok w TreeRuns (RangeFloor (runKey 0 0 4)) 8))
    [(k, r) | (k@(KeyRun _ lo), r) ← ranged, lo <= 4] `shouldBe` [(runKey 0 0 0, RecMaskRun 10 (mask 12))]
    map fst ranged `shouldBe` [runKey 0 0 0, runKey 0 0 10, runKey 0 0 11]
  it "keeps adjacent unequal tags apart at every level: air and mask alternating, and two masks alternating, over several leaves" $ do
    -- 200 levels, a run for each: more than a leaf of the runs tree holds
    alt ← must (foldM (\r z → narrowCell r (at z) (mask (if even z then 0 else 12))) start [0 .. 199])
    runs ← must (storedRuns alt)
    length runs `shouldBe` 200
    and (zipWith (\(_, h1, t1) (l2, _, t2) → h1 == l2 && t1 /= t2) runs (drop 1 runs)) `shouldBe` True
    heightOf (runH alt) TreeRuns `shouldSatisfy` (>= 2)
    -- two masks at consecutive levels
    twin ← must (foldM (\r z → narrowCell r (at z) (mask (if even z then 12 else 8))) start [0 .. 39])
    must (storedRuns twin) >>= \rs → (length rs, and (zipWith (\(_, _, a) (_, _, b) → a /= b) rs (drop 1 rs))) `shouldBe` (40, True)
    -- every step stayed inside the transaction's page envelope of the worst edit
    forM_ (runPlans alt <> runPlans twin) $ \plan → (mPagesWritten (plMeasure plan) <= minimumRemovalPages, mPagesWritten (plMeasure plan) <= maxTxnPages) `shouldBe` (True, True)
    -- an edit at the separator of two leaves: its two neighbours lie in different leaves, and narrowing it to air joins them, so
    -- the run of one leaf grows over the run of the other and the run it replaces is deleted from its own leaf
    separator ← must (leafSeparator alt)
    let edge = if odd separator then separator else separator - 1
        startOf level = [lo | (lo, hi, _) ← must' (storedRuns alt), lo <= level, level < hi]
    (map (< separator) (startOf (edge - 1)), map (>= separator) (startOf (edge + 1))) `shouldBe` ([True], [True])
    crossing ← must (narrowCell alt (at (toInteger edge)) (mask 0))
    must (storedRuns crossing) >>= \rs → [(lo, hi) | (lo, hi, ReplaceAir) ← rs, lo <= edge - 1, edge + 1 < hi] `shouldBe` [(edge - 1, edge + 2)]
    must (storedRuns crossing) >>= (`shouldSatisfy` ((== 198) . length))
    -- joining the neighbours back, level by level through the leaf boundary, coalesces each pair as the model does
    merged ← must (foldM (\r z → narrowCell r (at z) (mask 0)) alt [1, 3 .. 199])
    must (storedRuns merged) `shouldReturn` [(0, 200, ReplaceAir)]
    checkH' (runH merged)
  it "splits a multi-level run exactly at a leaf separator, and coalesces the pieces with the neighbours across it, as the pure model does" $ do
    -- 130 runs of three levels, masks 12 and 8 alternating: more than a leaf of the runs tree holds
    r0 ← must (foldM (\r z → narrowCell r (at z) (mask (if even (z `div` 3) then 12 else 8))) start [0 .. 3 * 130 - 1])
    runs0 ← must (storedRuns r0)
    length runs0 `shouldBe` 130
    heightOf (runH r0) TreeRuns `shouldSatisfy` (>= 2)
    separator ← must (leafSeparator r0)
    -- the run that starts the second leaf is three levels long
    (lo, hi, tag) ← case [run | run@(l, _, _) ← runs0, l == separator] of
      [run] → pure run
      other → expectationFailure ("no run starts at the separator: " <> show other) >> fail "unreachable"
    hi - lo `shouldBe` 3
    -- an interior level to air splits it in three, inside the second leaf
    r1 ← must (narrowCell r0 (at (toInteger lo + 1)) (mask 0))
    runs1 ← must (storedRuns r1)
    length runs1 `shouldBe` 132
    [run | run@(l, h, _) ← runs1, l >= lo, h <= hi] `shouldBe` [(lo, lo + 1, tag), (lo + 1, lo + 2, ReplaceAir), (lo + 2, hi, tag)]
    -- the first level of that run to air joins the air beside it; the last level of the run before it, in the first leaf, to air
    -- joins that, so one run of air spans the separator
    r2 ← must (narrowCell r1 (at (toInteger lo)) (mask 0))
    must (storedRuns r2) >>= (`shouldContain` [(lo, lo + 2, ReplaceAir)])
    r3 ← must (narrowCell r2 (at (toInteger lo - 1)) (mask 0))
    runs3 ← must (storedRuns r3)
    runs3 `shouldContain` [(lo - 1, lo + 2, ReplaceAir)]
    length runs3 `shouldBe` 131
    checkH' (runH r3)
  it "answers every level with the cell the pure overlay gives, source material included, across a change of material" $ do
    let src = sourceOf tagged
        edits = [(8, 12), (9, 12), (10, 12), (11, 8), (12, 0), (14, 4)]
    r ← must (narrowAll start edits)
    changes ← must (storeChanges r)
    forM_ edits $ \(z, m) → do
      let expected = narrowedCell (cellAt src emptyChanges (at z)) (mask m)
      Just (cellAt src changes (at z)) `shouldBe` expected
    -- a level beside the edits is still the source's, and the two sides of the change of material differ
    cellAt src changes (at 7) `shouldBe` cellAt src emptyChanges (at 7)
    cellAt src changes (at 15) `shouldBe` cellAt src emptyChanges (at 15)
    cellAt src changes (at 9) `shouldNotBe` cellAt src changes (at 10)
    -- and it is what the reference holds
    cellsOf src changes [0 .. 20] `shouldBe` cellsOf src (reference r) [0 .. 20]
  it "keeps an older pinned root readable over a later edit, and reads the new one as the reference does" $ do
    r1 ← must (narrowAll start [(z, 12) | z ← [0 .. 9]])
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore (runH r1))))
    old ← must (readAll ((runH r1) {hStore = s1}) tok)
    r2 ← must (narrowAll r1 {runH = (runH r1) {hStore = s1}} [(4, 8), (5, 0)])
    -- the pinned version still answers what it did, the committed one answers the edit
    readAll (runH r2) tok `shouldBe` Right old
    must (compareRecords (retainedRecords (runRef r2)) (runH r2))
    must (storedRuns r2) `shouldReturn` [(0, 4, ReplaceMask (mask 12)), (4, 5, ReplaceMask (mask 8)), (5, 6, ReplaceAir), (6, 10, ReplaceMask (mask 12))]
    old `shouldNotBe` must' (allRecords (runH r2))
    checkH' (runH r2)
  it "keeps a pending obligation across a narrowing and replays it from the committed roots to the same knowledge" $ do
    r1 ← must (narrowAll start [(9, 12), (10, 8), (11, 0)])
    pendingObligations (storeHeader (hStore (runH r1))) `shouldSatisfy` (> 0)
    pendingObligations (storeHeader (hStore (runH r1))) `shouldBe` pendingObligations (retainedHeader (runRef r1))
    -- obligations stored, then drained batch by batch: the store and the reference agree after each, and nothing is left pending
    (r2, _) ← must (drain r1)
    pendingObligations (storeHeader (hStore (runH r2))) `shouldBe` 0
    must (compareKnowledge r2 [at z | z ← [7 .. 13]])
    -- an edit while an older obligation is still pending adds to it and keeps the earlier one
    r3 ← must (narrowAll r1 [(20, 12)])
    pendingObligations (storeHeader (hStore (runH r3))) `shouldSatisfy` (> pendingObligations (storeHeader (hStore (runH r1))))
    (r4, _) ← must (drain r3)
    must (compareKnowledge r4 [at z | z ← [7 .. 21]])
  where
    must' = either (error . show) id
    reference r = either (error . show) id (changesFromReplacements (ChangeLimits maxBound) [(c, z, t) | (c, z, t) ← retainedReplacements (runRef r)])
    checkH' h = unless (either (const False) (const True) (checkH h)) (expectationFailure "the store's pages are not a valid partition")
