-- | What the accounted-bytes constants of the store really retain.
--
-- Every figure a plan's RAM charge, a window bound or the admission is sized from is a constant of bytes. Reasoned from an ENCODED
-- size, it counted the wrong thing whenever the thing retained is a Haskell heap structure (the read facts: 152 charged for 576
-- retained). Each constant is therefore measured against its largest valid instance, forced and held, by the live heap a major
-- collection leaves (the method of the suite's allocation evidence): the measured bytes per instance must not exceed what is
-- accounted for it.
module Test.TerrainRuntime.Store.Memory (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.IORef (newIORef, readIORef)
import Data.Word (Word64)
import GHC.Stats (RTSStats (..), GCDetails (..), getRTSStats)
import Hetoimasia.Terrain.Discovery (ReadSet (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Page
import Hetoimasia.Terrain.Runtime.Store.Internal.Records
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import System.Mem (performMajorGC)
import Test.Hspec
import Test.TerrainRuntime.Store.Harness

live ∷ IO Word64
live = performMajorGC >> performMajorGC >> (gcdetails_live_bytes . gc <$> getRTSStats)

-- | The live heap one element of a structure retains: the structure is built from @n@ distinct inputs, forced, held across a major
-- collection, and the growth of the live heap is divided by @n@. The inputs are built (and held) BEFORE the first reading, so what
-- is measured is the structure and not what it was made from.
retainedPer ∷ Int → [a] → (a → Int) → ([a] → IO b) → (b → IO Int) → IO Double
retainedPer n inputs sizeOf build force = do
  -- the inputs are forced all the way down first (a page's bytes included), so they are in the heap before the first reading
  _ ← evaluate (sum (map sizeOf inputs))
  heapBefore ← live
  structure ← build inputs
  -- held through an IORef across the collection: nothing can fuse the construction into the traversal, and the structure is
  -- reachable (and so counted) when the heap is read
  ref ← newIORef structure
  _ ← readIORef ref >>= force
  heapAfter ← live
  _ ← readIORef ref >>= force
  pure (fromIntegral (heapAfter - heapBefore) / fromIntegral n)
{-# NOINLINE retainedPer #-}

-- | One accounted constant: what it stands for, the bytes accounted for one instance, and the bytes measured for the largest valid one.
data Row = Row {rowName ∷ String, rowAccounted ∷ Int, rowMeasured ∷ Double}

spec ∷ Spec
spec = describe "the accounted-bytes constants against what is retained (forced live heap)" $ do
  let total = 1000000
      ints ∷ Int → [Int]
      ints n = [1 .. n]
      encPage tree pno es = either (error . show) id (encodePage ident0 (Page tree 0 (PageNo pno) (Leaf es)))
      runPage pno = encPage TreeRuns pno [(encodeKey (runKey 0 0 1), encodeValue (runRec 5))]
      -- a page whose first key is the longest a page holds (a 52-byte source node key)
      linkPage pno = encPage TreeLinks pno [(encodeKey (linkKey (srcNode 5 5 5)), encodeValue (childRec (srcNode 1 1 1)))]
      -- a dense bookkeeping page of the smallest entries (free extents, 8 + 8 bytes): the most entries a page holds
      densePage pno = encPage TreeFree pno [(be64 (fromIntegral (2 * j)), be64 1) | j ← [1 .. 225 ∷ Int]]
      nFacts = maxReadFactBytes `div` recordFactBytes
  rows ← runIO $ do
    mPage ← retainedPer 2000 [(fromIntegral i, runPage (fromIntegral i)) | i ← ints 2000] (BS.length . snd) (\ps → pure (foldl (\w (p, bs) → either (error . show) id (windowInsert total (PageNo p) bs w)) (emptyWindow ident0 0) ps)) (\w → evaluate (windowSize w))
    mProbe ← retainedPer 5000 [(fromIntegral i, linkPage (fromIntegral i)) | i ← ints 5000] (BS.length . snd) (\ps → pure (foldl (\w (p, bs) → windowProbe total (PageNo p) bs w) (emptyWindow ident0 0) ps)) (\w → evaluate (windowProbeCount w + sum [maybe 0 (const 1) (windowProbeOf (PageNo p) w) | p ← [1, 5000]]))
    -- the facts a plan may hold, packed: as many as the ceiling allows of the largest kind (a source node key and a source node child)
    mFact ← retainedPer nFacts (ints nFacts) id (\is → pure (windowCheckpoint (Facts (Fingerprint ident0 1 [] []) [] (ReadSet [(linkKey (srcNode (toInteger i) 5 5), Just (childRec (srcNode 1 (toInteger i) 1))) | i ← is] [])) (emptyWindow ident0 1))) (\w → evaluate (windowReadFactCount w + windowReadFactBytes w * 0))
    mProof ← retainedPer 20000 (ints 20000) id (\is → pure (Set.fromList [FactGone (fromIntegral i) (PageNo (fromIntegral i)) | i ← is])) (\st → evaluate (Set.foldl' (\acc f → case f of FactGone v (PageNo q) → acc + fromIntegral (v + q); _ → acc) (0 ∷ Int) st))
    mCell ← retainedPer 200000 (ints 200000) id (\is → pure (map (\i → PageNo (fromIntegral i * 7919)) is)) (\ps → evaluate (foldl' (\acc (PageNo q) → acc + fromIntegral q) (0 ∷ Int) ps))
    mRoots ← retainedPer 100 (ints 100) id (\is → pure [(emptyRoots (ArenaId 1)) {rVersion = fromIntegral i, rLoose = [PageNo (fromIntegral (j + i) * 7919) | j ← [1 .. looseCap]], rRootCrcs = [(TreeRuns, 1), (TreeLinks, 2), (TreeTodo, 3), (TreeFree, 4), (TreeRetire, 5)]} | i ← is]) (\rs → evaluate (sum [fromIntegral q | r ← rs, PageNo q ← rLoose r] + sum [fromIntegral c | r ← rs, (_, c) ← rRootCrcs r] + length rs))
    mPin ← retainedPer 1000 (ints 1000) id (\is → pure [Pins {pinVersion = fromIntegral i, pinRuns = Just (PageNo (fromIntegral i + 7)), pinLinks = Just (PageNo (fromIntegral i + 8)), pinTodo = Just (PageNo (fromIntegral i + 9)), pinCrcs = [(TreeRuns, fromIntegral i), (TreeLinks, fromIntegral i + 1), (TreeTodo, fromIntegral i + 2)], pinHw = fromIntegral i + 100} | i ← is]) (\ps → evaluate (sum [fromIntegral c | p ← ps, (_, c) ← pinCrcs p] + length [() | p ← ps, Just _ ← [pinRuns p, pinLinks p, pinTodo p]]))
    mWrite ← retainedPer 3000 (ints 3000) id (\is → pure [(linkKey (srcNode (toInteger i) 5 5), Just (childRec (srcNode 1 (toInteger i) 1))) | i ← is]) (\ws → evaluate (length (concatMap (\(k, v) → show k <> show v) ws)))
    mHot ← retainedPer 300 [(fromIntegral i, densePage (fromIntegral i)) | i ← ints 300] (BS.length . snd) (\bufs → pure [either (error . show) id (decodePage ident0 total (PageNo pno) bs) | (pno, bs) ← bufs]) (\ps → evaluate (sum [length es | Page _ _ _ (Leaf es) ← ps]))
    mState ← retainedPer 25600 (ints 25600) id (\is → pure (Map.fromList [(PageNo (fromIntegral i * 7919), ()) | i ← is])) (\m → evaluate (Map.size m))
    -- an overlay page: a new page held packed, its full payload and the entry around it, as an edit keeps it
    mOverlay ← retainedPer 400 (ints 400) id (\is → pure (either (error . show) fst (runM (mapM (\i → buildProbe TreeFree (PLeaf [(be64 (fromIntegral (i * 1000 + 2 * j)), be64 1) | j ← [1 .. 225 ∷ Int]])) is) (newEdit maxBound (emptyWindow ident0 0))))) (\refs → evaluate (length refs))
    pure
      [ Row "window page (buffer + map entry)" (pageSize + windowPageOverhead) mPage
      , Row "probe (map entry + key)" probeBytes mProbe
      , Row "read fact, packed (key + value + entry), at the ceiling" recordFactBytes mFact
      , Row "proof fact in a Set" factBytes mProof
      , Row "page-list cell (replaced / supply / loose lists)" pageListCellBytes mCell
      , Row "root set at the loose cap" rootRecordBytes mRoots
      , Row "reader pin record" readerRecordBytes mPin
      , Row "typed record write (key + value)" writeRetainedBytes mWrite
      , Row "parsed dense node in the hot set (225 entries)" hotNodeBytes mHot
      , Row "page-state map entry of the active transaction" pageStateEntryBytes mState
      , Row "overlay page (packed payload + entry), full" (overlayNodeBytes 4050) mOverlay
      ]
  it "TABLE: every accounted constant, what it stands for, accounted against measured (forced live heap, the largest valid instance)" $ do
    forM_ rows $ \r → putStrLn ("MEMORY " <> rowName r <> ": measured " <> show (round (rowMeasured r) ∷ Int) <> " B, accounted " <> show (rowAccounted r) <> " B")
    -- the constants that are LEDGER terms, not retained structures: no object of the store stands behind them
    putStrLn "MEMORY ledger terms (no store heap structure): ramPagePins (16 per window page), ramContinuation (1,024 + 8 per window page), the 4,096-byte scratch, descriptorRecordBytes (queued I/O descriptors of the admission)"
  forM_ rows $ \r →
    it ("retains no more than it is charged: " <> rowName r) $
      (rowMeasured r <= fromIntegral (rowAccounted r)) `shouldBe` True
  it "the read facts at their ceiling retain no more than the ceiling: N of them, near maxReadFactBytes, in total" $ do
    mTotal ← retainedPer 1 [()] (const 0) (\_ → pure (windowCheckpoint (Facts (Fingerprint ident0 1 [] []) [] (ReadSet [(linkKey (srcNode (toInteger i) 5 5), Just (childRec (srcNode 1 (toInteger i) 1))) | i ← ints nFacts] [])) (emptyWindow ident0 1))) (\w → evaluate (windowReadFactCount w))
    putStrLn ("MEMORY read facts at the ceiling: " <> show nFacts <> " facts retain " <> show (round mTotal ∷ Int) <> " B of " <> show maxReadFactBytes)
    (mTotal <= fromIntegral maxReadFactBytes) `shouldBe` True
