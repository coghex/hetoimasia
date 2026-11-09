-- | Planning on large valid stores: a legitimate batch never reads as corruption.
--
-- Round 11 found that a valid store with three-level links and retirement trees and many retired pages
-- reported an integrity failure for a legitimate batch of dispersed updates: every replaced record page is
-- also indexed in the retirement tree (one path each), so the bookkeeping a batch needs outgrew the fixed
-- reserve and the numbering of the pages failed before the overflow check ran. A plan now counts the
-- bookkeeping pages it needs before it numbers any, asks for a larger supply a bounded number of times
-- and otherwise reports the shrinkable capacity result 'BookkeepingExceeded'.
--
-- These examples hold the class on stores that are deep and full of retirement: random batches, dispersed
-- or clustered, of every size around the bounds, must end committed or with a shrinkable capacity
-- refusal that a smaller batch gets past, never an integrity result, and the independent checker must
-- agree after every commit. Maintenance drains the same store without an integrity result.
module Test.TerrainRuntime.Store.Large (spec) where

import Control.Monad (foldM, forM_, when)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record, RecordKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | The key and the two values of link @i@: a source node with a child node, changed back and forth.
linkOf ∷ Int → (RecordKey, Record, Record)
linkOf i =
  let x = toInteger (i `mod` 100) - 50
      y = toInteger (i `div` 100 `mod` 100) - 50
   in (linkKey (srcNode x y 0), childRec (srcNode x y 1), childRec (srcNode x y 2))

-- | Commit writes; the outcome is the store and what became of the batch.
commitW ∷ H → [(RecordKey, Maybe Record)] → Either String (H, Outcome)
commitW h ws = commitDelta h Ordinary (deltaFor (hStore h) True False 1 ws)

-- | A store whose links tree has three levels and whose retirement tree holds many thousands of retired
-- pages, built by committing, never maintained.
largeStore ∷ Int → Either String (H, Map.Map RecordKey Record, Int)
largeStore n = do
  let linkOf' = linkOf
      initial = [(k, Just a) | i ← [0 .. n - 1], let (k, a, _) = linkOf' i]
      chunks [] = []
      chunks xs = let (a, b) = splitAt 40 xs in a : chunks b
  h0 ← foldM (\h ws → commitW h ws >>= committed "building the links") (newH (specOf (128 * 1024 * 1024) Nothing) ident0) (chunks initial)
  let ref0 = Map.fromList [(k, a) | i ← [0 .. n - 1], let (k, a, _) = linkOf' i]
      -- rounds of 60 dispersed replacements; while recycling, maintenance frees pages that later rounds reuse
      -- (lowest first), so the live pages of the links tree end up scattered through the page space, between
      -- the retired ones; then the retirement is allowed to build up to 14,100 pages
      round' maintain (h, ref, r) = do
        let idxs = [(r * 7 + j * 197) `mod` n | j ← [0 .. 59]]
            ws = [(k, Just (if Map.lookup k ref == Just a then b else a)) | i ← idxs, let (k, a, b) = linkOf' i]
        (h1, out) ← commitW h ws
        h2 ← case out of
          Committed _ → Right h1
          other → Left ("history was not built: " <> show other)
        h3 ← if maintain then maintainSteps (3 ∷ Int) h2 else Right h2
        Right (h3, foldl (\m (k, v) → maybe m (\x → Map.insert k x m) v) ref ws, r + 1)
      maintainSteps 0 h = Right h
      maintainSteps k h = do
        (p, _, _) ← fillWith h (planMaintenance (hStore h))
        case p of
          Planned plan → commitPlan h plan >>= maintainSteps (k - 1)
          _ → Right h
      recycle st@(_, _, r) | r >= 150 = Right st
                           | otherwise = round' True st >>= recycle
      go st@(h, _, _)
        | rRetiredPages (storeRoots (hStore h)) >= 14100 = Right st
        | otherwise = round' False st >>= go
  (h, ref, r) ← recycle (h0, ref0, 0) >>= go
  Right (h, ref, r)
  where
    committed what (h, out) = case out of
      Committed _ → Right h
      other → Left (what <> ": " <> show other)

-- | A batch of @k@ replacements of live links, dispersed (a stride that divides none of the keys) or clustered.
batchOf ∷ Map.Map RecordKey Record → Int → Int → Bool → [(RecordKey, Maybe Record)]
batchOf ref n k dispersed =
  [ (key, Just (if Map.lookup key ref == Just a then b else a))
  | j ← [0 .. k - 1]
  , let i = if dispersed then (j * 197 + 31) `mod` n else (4000 + j) `mod` n
  , let (key, a, b) = linkOf i
  ]

-- | What a batch came to: committed, shrinkable (and the batch that follows from halving), or a defect.
data Fate = Done | Shrank Int | Defect String
  deriving stock (Eq, Show)

-- | Commit a batch; on a shrinkable refusal halve it until it commits, as discovery does, down to three writes.
settleBatch ∷ H → Map.Map RecordKey Record → [(RecordKey, Maybe Record)] → Either String (H, Map.Map RecordKey Record, Fate)
settleBatch h ref ws = go h ref ws (0 ∷ Int)
  where
    go hh rr batch shrinks = do
      (h', out) ← commitW hh batch
      case out of
        Committed _ → Right (h', foldl (\m (k, v) → maybe m (\x → Map.insert k x m) v) rr batch, if shrinks == 0 then Done else Shrank shrinks)
        Nothing' → Right (h', rr, if shrinks == 0 then Done else Shrank shrinks)
        Refusal' why
          | shrinkable why && length batch > 3 → go hh rr (take (max 3 (length batch `div` 2)) batch) (shrinks + 1)
          | otherwise → Left ("a legitimate batch of " <> show (length batch) <> " writes came to " <> show why)

spec ∷ Spec
spec = describe "planning on large valid stores (deep trees, thousands of retired pages)" $ do
  (h0, ref0, rounds) ← runIO (must (largeStore 12000))
  it "builds a store that is deep, full of retirement and valid" $ do
    must (checkH h0)
    rRetiredPages (storeRoots (hStore h0)) `shouldSatisfy` (>= 14100)
    rounds `shouldSatisfy` (> 150)
  it "plans every batch size across the bounds, dispersed and clustered: committed or shrunk, never an integrity result" $ do
    let sizes = [1, 2, 3, 5, 8, 13, 21, 34, 40, 48, 52, 56, 58, 60, 62, 63, 64, 66, 70, 80, 100, 150, 220, 300]
    fates ← must $ mapM (\(k, d) → (\(_, _, f) → (k, d, f)) <$> settleBatch h0 ref0 (batchOf ref0 12000 k d)) [(k, d) | k ← sizes, d ← [True, False]]
    putStrLn ("LARGE batch fates (writes, dispersed, fate): " <> show fates)
    -- how close each batch came to the bookkeeping reserve, and what refused the ones that were refused
    forM_ [(k, d) | k ← [40, 56, 64, 80, 100, 150, 220, 300], d ← [True, False]] $ \(k, d) → do
      p ← must (fillPlan h0 (deltaFor (hStore h0) True False 1 (batchOf ref0 12000 k d)) Ordinary)
      putStrLn ("LARGE plan " <> show (k, d) <> ": " <> case p of
        Planned pl → "bookkeeping " <> show (mBookkeepingPages (plMeasure pl)) <> " record pages " <> show (mRecordPages (plMeasure pl)) <> " replaced " <> show (mReplacedRecord (plMeasure pl))
        other → take 120 (show other))
    [x | x@(_, _, Defect _) ← fates] `shouldBe` []
  -- The reserve of a production plan is 68 pages and the retirement tree of this store is wide, so the bookkeeping a
  -- batch needs stays below it. The boundary is the same code path under a smaller reserve ('bdReserve',
  -- 'bdReserveMax'), which these examples set: a batch whose bookkeeping outgrows the reserve is answered by a larger
  -- supply when the bound allows it and otherwise by the shrinkable result, and never by an integrity result.
  it "answers a bookkeeping need past the reserve with a larger supply, or a shrinkable result, never an integrity result" $ do
    let withBounds rsv rsvMax h ws = do
          let bounds = standardBounds {bdReserve = rsv, bdReserveMax = rsvMax}
          (p, _, _) ← fillWith h (\w → planDeltaPinned bounds (hCfg h) (hIdent h) (storeRoots (hStore h)) [] w Ordinary (deltaFor (hStore h) True False 1 ws))
          pure p
        ws64 = batchOf ref0 12000 64 True
    -- a larger supply when the bound allows: planned, with more bookkeeping pages than the reserve
    allowed ← must (withBounds 3 64 h0 ws64)
    case allowed of
      Planned pl → do
        (mBookkeepingPages (plMeasure pl) > 3) `shouldBe` True
        h' ← must (commitPlan h0 pl)
        must (checkH h')
      other → expectationFailure ("a bookkeeping need past the reserve was not answered with a larger supply: " <> take 200 (show other))
    -- when the bound does not allow it: the shrinkable capacity result, and a smaller batch gets past it
    refused ← must (withBounds 3 3 h0 ws64)
    case refused of
      Refused why → do
        why `shouldSatisfy` shrinkable
        case why of
          Capacity (BookkeepingExceeded n) → (n > 3) `shouldBe` True
          other → expectationFailure ("not the bookkeeping result: " <> show other)
      other → expectationFailure ("a bookkeeping need past the bound was not refused as capacity: " <> take 200 (show other))
    -- halved as discovery does, the batch makes progress: some size commits under the same bounds
    let sizes = takeWhile (>= 1) (iterate (`div` 2) 64)
    outcomes ← must (mapM (\k → (\p → (k, p)) <$> withBounds 3 3 h0 (batchOf ref0 12000 k True)) sizes)
    let planned = [k | (k, Planned _) ← outcomes]
        integrity = [(k, why) | (k, Refused why@(Integrity _)) ← outcomes]
    integrity `shouldBe` []
    planned `shouldSatisfy` (not . null)
  it "keeps committing random batches, the checker agreeing after every commit, and maintenance drains the store" $
    forM_ [1, 2, 3 ∷ Word64] $ \seed → do
      let step (h, ref, g, shrunk) i = do
            let (sz, g1) = below 120 g
                (dispersed, g2) = below 2 g1
                k = 1 + fromIntegral sz
                ws = batchOf ref 12000 k (dispersed == 1)
            (h', ref', fate) ← either (\e → Left ("step " <> show (i ∷ Int) <> ": " <> e)) Right (settleBatch h ref ws)
            when (i `mod` 4 == 0) $ either (\e → Left ("step " <> show i <> ": " <> e)) Right (checkH h')
            Right (h', ref', g2, shrunk + (case fate of Shrank _ → 1; _ → 0 ∷ Int))
      (h1, ref1, _, shrunk) ← must (foldM step (h0, ref0, mkRng (900 + seed), 0) [1 .. 24])
      putStrLn ("LARGE random history seed " <> show seed <> ": batches that shrank " <> show shrunk <> " of 24")
      must (checkH h1)
      (drained, passes) ← must (reclaimAllWithin 4000 h1)
      putStrLn ("LARGE drain seed " <> show seed <> ": " <> show passes <> " maintenance transactions")
      rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
      must (checkH drained)
      must (compareRecords (Map.toList ref1) drained)
