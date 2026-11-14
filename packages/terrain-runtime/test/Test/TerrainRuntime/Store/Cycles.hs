-- | Repeated update, abort, publish, read and reclaim cycles.
--
-- Generated sequences (each names its seed) interleave committed edits, transactions
-- abandoned after a random prefix of their writes, transactions whose write fails,
-- readers pinned and released, reads through fresh windows (the caches dropped) and
-- reclamation steps, while the page-resident history grows far past anything a window
-- could hold. After every operation the committed store is unchanged by an abandoned
-- transaction; every pinned reader still answers from exactly the records of its
-- version; and at checkpoints the independent traversal decides from the bytes that
-- the pages still partition the page space and the records equal the reference map.
-- At the end every reader is released, reclamation drains, nothing remains retired and
-- the same committed version reads back from pages alone.
module Test.TerrainRuntime.Store.Cycles (spec, fullSpec, cycleSeeds, runCycles, CycleReport (..)) where

import Control.Monad (foldM, forM_)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record, RecordKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Test.Hspec
import Test.TerrainRuntime.Store.Depth (Depth (..), atDepth)
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Workload

-- | What a run did and the bounds it observed.
data CycleReport = CycleReport
  { crSeed ∷ !Word64
  , crCommits ∷ !Int
  , crAborts ∷ !Int
  , crFailedWrites ∷ !Int
  , crReads ∷ !Int
  , crReclaims ∷ !Int
  , crMaxReaders ∷ !Int
  , crMaxPages ∷ !Int
  , crMaxWindow ∷ !Int
  , crMaxRam ∷ !Int
  , crMaxSteps ∷ !Int
  , crPagesWritten ∷ !Int
  , crHighWater ∷ !Word64
  , crRecords ∷ !Int
  }
  deriving stock (Eq, Show)

data St = St
  { stH ∷ !H
  , stRef ∷ !(Map.Map RecordKey Record)
  , stReaders ∷ [(ReaderToken, Map.Map RecordKey Record)]
  , stRng ∷ !Rng
  , stRep ∷ !CycleReport
  }

-- | Drive one seeded sequence.
runCycles ∷ Word64 → Int → Either String (St, CycleReport)
runCycles seed steps = do
  let st0 = St (newH smallSpec ident0) Map.empty [] (mkRng seed) (CycleReport seed 0 0 0 0 0 0 0 0 0 0 0 0 0)
  st ← foldM step st0 [1 .. steps]
  finish st
  where
    step st i = do
      let (op, g1) = below 100 (stRng st)
          st1 = st {stRng = g1}
      st2 ← apply st1 (fromIntegral op ∷ Int)
      if i `mod` 60 == (0 ∷ Int)
        then do
          checkH (stH st2)
          compareRecords (Map.toList (stRef st2)) (stH st2)
          checkReaders st2
          Right st2
        else Right st2
    apply st op
      | op < 42 = commit st
      | op < 52 = abandon st False
      | op < 57 = abandon st True
      | op < 67 = pin st
      | op < 77 = unpin st
      | op < 90 = readSome st
      | otherwise = reclaim st

commit ∷ St → Either String St
commit st = do
  let (n, g1) = below 25 (stRng st)
      (ws, g2) = genWrites g1 (stRef st) (fromIntegral n + 1)
      h = stH st
  p ← fillPlan h (stepDelta (hStore h) 0 ws) Ordinary
  case p of
    Planned plan → do
      h' ← commitPlan h plan
      let rep = stRep st
      Right st {stH = h', stRef = applyRef ws (stRef st), stRng = g2, stRep = observe (rep {crCommits = crCommits rep + 1}) plan}
    Refused (Capacity (DiskFull {})) → Right st {stRng = g2}
    NoWork → Right st {stRng = g2}
    other → Left ("commit: " <> show other)

observe ∷ CycleReport → Plan → CycleReport
observe r p =
  let m = plMeasure p
   in r
        { crMaxPages = max (crMaxPages r) (mPagesWritten m)
        , crMaxWindow = max (crMaxWindow r) (mWindowPages m)
        , crMaxRam = max (crMaxRam r) (ramTotal (mRam m))
        , crMaxSteps = max (crMaxSteps r) (mReadSteps m)
        , crPagesWritten = crPagesWritten r + mPagesWritten m
        }

-- | Admit a plan, write a random prefix of its pages (or fail one), and abandon it.
abandon ∷ St → Bool → Either String St
abandon st failing = do
  let (n, g1) = below 25 (stRng st)
      (ws, g2) = genWrites g1 (stRef st) (fromIntegral n + 1)
      h = stH st
      rootsBefore = storeRoots (hStore h)
      usedBefore = usage (hStore h)
  p ← fillPlan h (stepDelta (hStore h) 0 ws) Ordinary
  case p of
    Planned plan → do
      (tid, s1) ← either (Left . show) Right (admit plan (hStore h))
      let pages = plPages plan
          (k, g3) = below (fromIntegral (length pages) + 1) g2
          (done, rest) = splitAt (fromIntegral k) pages
          writeOne (s, d) (pg, bs) =
            let (_, sa) = dispatchWrite tid pg s
                (_, sb) = completeWrite tid pg WriteDone sa
             in (sb, diskWrite pg bs d)
          (s2, d2) = foldl writeOne (s1, hDisk h) done
          -- a failed write leaves garbage behind in the claimed page: a page the
          -- committed roots never reach
          (s3, d3) = case rest of
            ((pg, _) : _) | failing →
              let (_, sa) = dispatchWrite tid pg s2
                  (_, sb) = completeWrite tid pg WriteFailed sa
               in (sb, diskWrite pg (BS.replicate 4096 0xEE) d2)
            _ → (s2, d2)
          s4 = snd (requestCancel tid s3)
      s5 ← either (Left . show) Right (abortTransaction tid s4)
      if storeRoots s5 /= rootsBefore || usage s5 /= usedBefore then Left "an abandoned transaction changed the committed store" else Right ()
      let rep = stRep st
          rep' = observe (if failing then rep {crFailedWrites = crFailedWrites rep + 1} else rep {crAborts = crAborts rep + 1}) plan
      Right st {stH = h {hStore = s5, hDisk = d3}, stRng = g3, stRep = rep'}
    _ → Right st {stRng = g2}

pin ∷ St → Either String St
pin st
  | length (stReaders st) >= 6 = Right st
  | otherwise = do
      (tok, s1) ← either (Left . show) Right (acquireReader (hStore (stH st)))
      let rep = stRep st
      Right st {stH = (stH st) {hStore = s1}, stReaders = (tok, stRef st) : stReaders st, stRep = rep {crMaxReaders = max (crMaxReaders rep) (length (stReaders st) + 1)}}

unpin ∷ St → Either String St
unpin st = case stReaders st of
  [] → Right st
  rs → do
    let (i, g1) = below (fromIntegral (length rs)) (stRng st)
        (tok, _) = rs !! fromIntegral i
        (_, s1) = releaseReader tok (hStore (stH st))
    Right st {stH = (stH st) {hStore = s1}, stReaders = [r | (j, r) ← zip [0 ∷ Int ..] rs, j /= fromIntegral i], stRng = g1}

readSome ∷ St → Either String St
readSome st = case stReaders st of
  [] → Right st
  rs → do
    let (i, g1) = below (fromIntegral (length rs)) (stRng st)
        (tok, snapshot) = rs !! fromIntegral i
    seen ← readAll (stH st) tok
    if Map.fromList seen == snapshot then Right () else Left "a pinned reader's answers changed"
    let rep = stRep st
    Right st {stRng = g1, stRep = rep {crReads = crReads rep + 1}}

reclaim ∷ St → Either String St
reclaim st = do
  let h = stH st
  (p, _, _) ← fillWith h (planMaintenance (hStore h))
  case p of
    Planned plan → do
      h' ← commitPlan h plan
      let rep = stRep st
      Right st {stH = h', stRep = (observe rep plan) {crReclaims = crReclaims rep + 1}}
    NoWork → Right st
    BlockedByReader {} → Right st
    other → Left ("reclaim: " <> show other)

checkReaders ∷ St → Either String ()
checkReaders st = mapM_ (\(tok, snapshot) → readAll (stH st) tok >>= \seen → if Map.fromList seen == snapshot then Right () else Left "reader mismatch") (stReaders st)

finish ∷ St → Either String (St, CycleReport)
finish st = do
  -- every reader releases; reclamation drains; the committed version reads back
  let s1 = foldl (\s (tok, _) → snd (releaseReader tok s)) (hStore (stH st)) (stReaders st)
  (h2, _) ← reclaimAll (stH st) {hStore = s1}
  checkH h2
  if usRetiredBytes (usage (hStore h2)) /= 0 then Left "retired pages remain after the last reader" else Right ()
  compareRecords (Map.toList (stRef st)) h2
  let rep = (stRep st) {crHighWater = rHw (storeRoots (hStore h2)), crRecords = Map.size (stRef st)}
  Right (st {stH = h2, stReaders = []}, rep)

-- | The seeds of the cycles: one at the routine depth, the three of the original at the full depth.
cycleSeeds ∷ Depth → [Word64]
cycleSeeds depth = atDepth depth [202] [101, 202, 303]

-- | The routine depth, and every family at its original depth (the optional full-depth probe).
spec, fullSpec ∷ Spec
spec = specAt Routine
fullSpec = specAt Full

specAt ∷ Depth → Spec
specAt depth = describe "repeated update, abort, publish, read and reclaim cycles" $
  forM_ (cycleSeeds depth) $ \seed →
    it ("keeps every pinned version, the partition and the reference through the cycles (seed " <> show seed <> ")") $
      case runCycles seed 450 of
        Left e → expectationFailure e
        Right (_, r) → do
          crCommits r `shouldSatisfy` (> 100)
          crAborts r `shouldSatisfy` (> 10)
          crFailedWrites r `shouldSatisfy` (> 3)
          crReads r `shouldSatisfy` (> 20)
          crReclaims r `shouldSatisfy` (> 3)
          crMaxPages r `shouldSatisfy` (<= 256)
          crMaxWindow r `shouldSatisfy` (<= maxWindowPages)
          crMaxRam r `shouldSatisfy` (<= txnRamLimit)
          -- the history is page-resident and far larger than any window
          crHighWater r `shouldSatisfy` (> fromIntegral (crMaxWindow r))
