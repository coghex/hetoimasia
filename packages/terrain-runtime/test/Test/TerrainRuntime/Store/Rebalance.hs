-- | Deletion against trees deep enough to merge and redistribute internal nodes.
--
-- The child checksum made an internal entry 12 bytes (1 + key + page 8 + checksum 4); the rebalance of a
-- deletion still counted 8, merged two internal siblings that did not fit one page and refused the legitimate
-- deletion as corruption (round 10). The size of an internal entry is now defined once ('innerKeyBytes') and
-- every sizing decision uses it. These examples hold the class: a legitimate operation never yields an
-- integrity result, and the independent checker agrees after every step.
--
-- The trees are built by hand, page by page, with the real checksums, so that they are as shallow in
-- records and as dense in internal entries as a legitimate tree can be (a leaf just above half full under
-- the minimum, internal nodes of 28 children against a 4,052-byte payload).
module Test.TerrainRuntime.Store.Rebalance (spec) where

import Control.Monad (foldM, forM_, when)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record, RecordKey (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Child (..), Page (..), encodePage, innerKeyBytes)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (encodeKey, encodeValue)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | A runs tree of three levels: leaves of @perLeaf@ records, one internal page per given child count, a root.
-- The records of leaf @l@ are @leafKey l 1 .. leafKey l perLeaf@.
deepStore ∷ Int → [Int] → (H, Map.Map RecordKey Record, [Int])
deepStore perLeaf counts = (h, ref, counts)
  where
    leafKey ∷ Int → Int → RecordKey
    leafKey l i = runKey (toInteger l) 0 (100 * toInteger i)
    recOf i = runRec (100 * toInteger i + 3)
    leaves = sum counts
    leafPage l = Page TreeRuns 0 (PageNo (fromIntegral l)) (Leaf [(encodeKey (leafKey l i), encodeValue (recOf i)) | i ← [1 .. perLeaf]])
    crcOf pg = getLe32' (either (error . show) id (encodePage ident0 pg)) 4092
    childOf pg = Child (pgNo pg) (crcOf pg)
    starts = scanl (+) 0 counts
    inners =
      [ Page TreeRuns 1 (PageNo (fromIntegral (leaves + n))) (Inner [(encodeKey (leafKey l 1), childOf (leafPage l)) | l ← [s .. s + c - 1]])
      | (n, (s, c)) ← zip [0 ..] (zip starts counts)
      ]
    rootPage = Page TreeRuns 2 (PageNo (fromIntegral (leaves + length counts))) (Inner [(encodeKey (leafKey s 1), childOf p) | (s, p) ← zip starts inners])
    pages = [leafPage l | l ← [0 .. leaves - 1]] ++ inners ++ [rootPage]
    h0 = newH smallSpec ident0
    disk = foldl (\dk pg → diskWrite (pgNo pg) (either (error . show) id (encodePage ident0 pg)) dk) (hDisk h0) pages
    total = fromIntegral (length pages) ∷ Word64
    roots0 = storeRoots (hStore h0)
    roots = roots0 {rVersion = 1, rRuns = Just (pgNo rootPage), rHw = total, rLivePages = total, rRootCrcs = [(TreeRuns, crcOf rootPage)]}
    h = h0 {hStore = storeFromRoots (hCfg h0) ident0 roots, hDisk = disk}
    ref = Map.fromList [(leafKey l i, recOf i) | l ← [0 .. leaves - 1], i ← [1 .. perLeaf]]

-- | One commit of writes: a legitimate operation is committed (or is nothing), never refused.
commitWrites ∷ H → [(RecordKey, Maybe Record)] → Either String H
commitWrites h ws = do
  (h', out) ← commitDelta h Ordinary (deltaFor (hStore h) True False 1 ws)
  case out of
    Committed _ → Right h'
    Nothing' → Right h'
    Refusal' why → Left ("a legitimate operation was refused: " <> show why)

spec ∷ Spec
spec = describe "deletion against trees deep enough to merge and redistribute internal nodes" $ do
  it "redistributes two internal siblings whose combined entries do not fit one page (the round-10 case)" $ do
    let (h, ref, _) = deepStore 30 [28, 90]
        key0 = fst (Map.findMin ref)
        entry = innerKeyBytes (encodeKey key0)
        combined = (28 + 90 - 1) * entry
    -- the case is the one that matters: the merged entries (117) overflow a page at the size they encode to, and
    -- would have fitted at the eight-byte child reference the rebalance used to count
    (combined > pagePayloadBytes) `shouldBe` True
    (117 * (entry - 4) <= pagePayloadBytes) `shouldBe` True
    must (checkH h)
    -- delete the first record: the first leaf underflows, merges into its sibling, and the first internal page (28
    -- children) underflows against the second (90)
    h1 ← must (commitWrites h [(key0, Nothing)])
    must (checkH h1)
    must (compareRecords (Map.toList (Map.delete key0 ref)) h1)
    -- the publication is the committed version: a fresh read agrees
    rRuns (storeRoots (hStore h1)) `shouldSatisfy` (/= rRuns (storeRoots (hStore h)))
  forM_ [(30 ∷ Int, [28, 90], 1 ∷ Word64), (30, [28, 28, 28, 28], 2), (30, [28, 90, 28, 60], 3), (40, [20, 90, 28, 100], 4)] $ \(perLeaf, counts, seed) →
    it ("never refuses a legitimate deletion or reinsertion, and the checker agrees after every step (" <> show counts <> ", " <> show perLeaf <> " records a leaf)") $ do
      let (h0, ref0, _) = deepStore perLeaf counts
          original = ref0
          step (h, ref, g) i = do
            let (r, g1) = below 100 g
                (n, g2) = below 40 g1
                count = 1 + fromIntegral n ∷ Int
                -- mostly deletions (a leaf is emptied, merged, redistributed); a fifth re-insert deleted records
                pickKeys gen m = go gen (m ∷ Int) []
                  where
                    go gg 0 acc = (acc, gg)
                    go gg k acc =
                      let (ix, gg') = below (fromIntegral (max 1 (Map.size ref))) gg
                       in if Map.null ref then (acc, gg') else go gg' (k - 1) (fst (Map.elemAt (fromIntegral ix) ref) : acc)
                missing = [(k, v) | (k, v) ← Map.toList original, not (Map.member k ref)]
                (writes, g3)
                  | r < 80 || null missing =
                      let (ks, gg) = pickKeys g2 count in ([(k, Nothing) | k ← Map.keys (Map.fromList [(k, ()) | k ← ks])], gg)
                  | otherwise =
                      let (ix, gg) = below (fromIntegral (length missing)) g2
                          chosen = take count (drop (fromIntegral ix) missing ++ missing)
                       in ([(k, Just v) | (k, v) ← chosen], gg)
                ref' = foldl (\m (k, v) → maybe (Map.delete k m) (\x → Map.insert k x m) v) ref writes
            h' ← either (\e → Left ("step " <> show (i ∷ Int) <> ": " <> e)) Right (commitWrites h writes)
            either (\e → Left ("step " <> show i <> ": " <> e)) Right (checkH h')
            when (i `mod` 6 == 0) $ either (\e → Left ("step " <> show i <> ": " <> e)) Right (compareRecords (Map.toList ref') h')
            Right (h', ref', g3)
      (hEnd, refEnd, _) ← must (foldM step (h0, ref0, mkRng (700 + seed)) [1 .. 45])
      must (checkH hEnd)
      must (compareRecords (Map.toList refEnd) hEnd)
      (drained, _) ← must (reclaimAll hEnd)
      must (checkH drained)
      must (compareRecords (Map.toList refEnd) drained)
