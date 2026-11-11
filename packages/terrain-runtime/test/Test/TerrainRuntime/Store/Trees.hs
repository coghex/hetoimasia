-- | The copy-on-write indexes against a reference map.
--
-- Generated sequences of record writes (insertion, replacement, deletion, coalescing
-- shapes, extreme legal coordinates) are committed through the production planner
-- and a disk, and after checkpoints the store's records, read back through the
-- production reader from pages alone, are compared with a plain 'Data.Map' the test
-- maintains, while the independent traversal of "Test.TerrainRuntime.Store.Reference"
-- decides from the bytes that every tree is ordered, bounded, a quarter full and
-- that the pages partition the page space. Every sequence names its seed.
module Test.TerrainRuntime.Store.Trees (spec, drive, growAndShrink) where

import Control.Monad (forM_, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Workload

-- | Drive @steps@ generated deltas from a seed, comparing at checkpoints.
drive ∷ Word64 → Int → Int → Int → Either String (H, Map.Map RecordKey Record)
drive seed steps perStep every = go (mkRng seed) (newH smallSpec ident0) Map.empty 0
  where
    go g h ref i
      | i >= steps = finish h ref
      | otherwise = do
          let (n, g1) = below (fromIntegral perStep) g
              (ws, g2) = genWrites g1 ref (fromIntegral n + 1)
              (flag, g3) = below 3 g2
              d = deltaFor (hStore h) (flag == 0) (flag == 1) (length ws) ws
          (h', _) ← commitDelta h Ordinary d
          let ref' = applyRef ws ref
          when (i `mod` every == every - 1) $ do
            checkH h'
            compareRecords (Map.toList ref') h'
          go g3 h' ref' (i + 1)
    finish h ref = do
      checkH h
      compareRecords (Map.toList ref) h
      Right (h, ref)

spec ∷ Spec
spec = describe "copy-on-write indexes against a reference map" $ do
  forM_ [(11, 400), (29, 400), (47, 400)] $ \(seed, steps) →
    it ("agrees with the reference map and the independent traversal through inserts, replacements and deletions (seed " <> show seed <> ")") $
      case drive seed steps 30 50 of
        Left e → expectationFailure e
        Right (h, ref) → do
          Map.size ref `shouldSatisfy` (> 200)
          mxPages (hMaxes h) `shouldSatisfy` (<= 256)
  it "splits leaves, internal pages and the root, and merges them back, as the traversal sees (seed 5)" $
    case growAndShrink 5 of
      Left e → expectationFailure e
      Right (grown, shrunk) → do
        grown `shouldSatisfy` (>= 3)
        shrunk `shouldBe` 0

-- | Insert many records so a tree grows to several levels, then delete them all in
-- a random order: the tree gives its levels back and ends empty.
growAndShrink ∷ Word64 → Either String (Int, Int)
growAndShrink seed = do
  let h0 = newH smallSpec ident0
      keys = [(runKey x y (100 * s), runRec (100 * s + 3)) | x ← [-20 .. 20], y ← [-20 .. 20], s ← [0 .. 6 ∷ Integer]]
      chunks xs = case splitAt 40 xs of
        ([], _) → []
        (a, b) → a : chunks b
  h1 ← foldlM' (\h chunk → fst <$> commitDelta h Ordinary (deltaFor (hStore h) True False (length chunk) [(k, Just v) | (k, v) ← chunk])) h0 (chunks keys)
  checkH h1
  compareRecords keys h1
  let height t = maybe 0 id (lookup t (owHeights (ownershipOf h1)))
      grown = height TreeRuns
      (order, _) = shuffle (map fst keys) (mkRng seed)
  h2 ← foldlM' (\h chunk → fst <$> commitDelta h Ordinary (deltaFor (hStore h) True False (length chunk) [(k, Nothing) | k ← chunk])) h1 (chunks order)
  checkH h2
  compareRecords [] h2
  when (isJust (committedRoot (hStore h2) TreeRuns)) $ Left "the emptied tree still has a root"
  Right (grown, if isJust (committedRoot (hStore h2) TreeRuns) then 1 else 0)
  where
    foldlM' f z xs = go z xs
      where
        go acc [] = Right acc
        go acc (y : ys) = f acc y >>= \acc' → go acc' ys
    ownershipOf h = let ArenaId a = siArena (hIdent h) in ownership a (siSource (hIdent h)) (hStore h) (diskRead (hDisk h))
