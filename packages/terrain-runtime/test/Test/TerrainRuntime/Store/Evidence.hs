-- | The measurements the TRA-20 evidence records, asserted and printed.
--
-- Each example checks a bound and prints @EVIDENCE@ lines naming the fixture, the seed
-- and the figures, so the evidence document is the output of one command
-- (@cabal test ... --test-option=--match --test-option="TRA-20 evidence"@), not a
-- paraphrase. These are observations of the pure model and the codec: encoded page
-- counts, total writes, peak RAM reservations and working copies, used, staged,
-- retired, free and protected bytes, pinned roots and the most bounded read and
-- planning steps; they are not physical filesystem, durability or latency figures.
module Test.TerrainRuntime.Store.Evidence (spec) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Discovery (maxBatchUpdates, Record, RecordKey, pendingObligations)
import Data.Word (Word64)
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Admission (worstTransactionCharge)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Test.Hspec
import Test.TerrainRuntime.Store.Bounds (allocationRatios, findExact256, wide)
import Test.TerrainRuntime.Store.Cycles (CycleReport (..), runCycles)
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Scenes
import Test.TerrainRuntime.Store.Trees (drive, growAndShrink)
import Test.TerrainRuntime.Store.Workload

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

ev ∷ String → IO ()
ev line = putStrLn ("EVIDENCE " <> line)

mibI ∷ Integer
mibI = 1024 * 1024

-- | The usage of a store as one evidence line.
usageLine ∷ Usage → String
usageLine u =
  "allowance=" <> show (usAllowanceBytes u)
    <> " used=" <> show (usUsedBytes u)
    <> " live=" <> show (usLiveBytes u)
    <> " staged=" <> show (usStagedBytes u)
    <> " retired(pending reclaim)=" <> show (usRetiredBytes u)
    <> " loose=" <> show (usLooseBytes u)
    <> " free=" <> show (usFreeBytes u)
    <> " protected=" <> show (usProtectedBytes u)
    <> " available=" <> show (usAvailableBytes u)
    <> " readers=" <> show (usReaders u)
    <> " pinnedVersions=" <> show (usPinnedVersions u)

spec ∷ Spec
spec = describe "TRA-20 evidence" $ do
  it "reference comparison: generated histories against the independent traversal" $
    forM_ [11, 29, 47 ∷ Word64] $ \seed → do
      (h, ref) ← must (drive seed 400 30 50)
      let m = hMaxes h
          ArenaId a = siArena (hIdent h)
          o = ownership a (siSource (hIdent h)) (hStore h) (diskRead (hDisk h))
      ev ("trees seed=" <> show seed <> " steps=400 records=" <> show (Map.size ref) <> " commits=" <> show (mxPlans m)
            <> " totalPageWrites=" <> show (mxWrites m) <> " maxPagesPerTransaction=" <> show (mxPages m)
            <> " maxRam=" <> show (mxRam m) <> " maxWindowPages=" <> show (mxWindow m) <> " maxReadSteps=" <> show (mxSteps m)
            <> " maxClaim=" <> show (mxClaim m))
      ev ("trees seed=" <> show seed <> " heights=" <> show (owHeights o)
            <> " live=" <> show (length (owLive o)) <> " retired=" <> show (length (owRetired o)) <> " free=" <> show (length (owFree o)) <> " loose=" <> show (length (owLoose o))
            <> " highWater=" <> show (rHw (storeRoots (hStore h))) <> " violations=" <> show (length (owViolations o)))
      owViolations o `shouldBe` []
      mxRam m `shouldSatisfy` (<= txnRamLimit)
  it "grows to several levels and gives them back" $ do
    (grown, shrunk) ← must (growAndShrink 5)
    ev ("growAndShrink seed=5 runsTreeHeightAtPeak=" <> show grown <> " rootAfterDeletingEverything=" <> (if shrunk == 0 then "empty" else "present"))
    grown `shouldSatisfy` (>= 3)
  it "transaction bounds: exactly 256 pages, one past refused, RAM and window" $ do
    (h, keys) ← must (wide 20000)
    (p, n) ← must (findExact256 h keys)
    let m = plMeasure p
    ev ("bounds history=20000runs exactPlan pages=" <> show (mPagesWritten m) <> " bytes=" <> show (mPagesWritten m * pageSize)
          <> " recordPages=" <> show (mRecordPages m) <> " listPages=" <> show (mListPages m) <> " bookkeepingPages=" <> show (mBookkeepingPages m)
          <> " replacedRecordPages=" <> show (mReplacedRecord m) <> " replacedBookkeepingPages=" <> show (mReplacedBookkeeping m)
          <> " slack=" <> show (mSlack m) <> " claimed=" <> show (mClaimed m) <> " windowPages=" <> show (mWindowPages m)
          <> " readSteps=" <> show (mReadSteps m) <> " ramTotal=" <> show (ramTotal (mRam m)))
    ev ("bounds onePastPages=" <> show n <> " refused=TxnPagesExceeded")
    let w = worstTransactionCharge
    ev ("bounds worstTransactionRam io=" <> show (ramIoBuffers w) <> " decoded=" <> show (ramDecodedCopies w) <> " keys=" <> show (ramKeys w)
          <> " scratch=" <> show (ramScratch w) <> " pagePins=" <> show (ramPagePins w) <> " rootControl=" <> show (ramRootControl w)
          <> " continuation=" <> show (ramContinuation w) <> " total=" <> show (ramTotal w) <> " limit=" <> show txnRamLimit)
    ev ("bounds format maxLevel=" <> show maxLevel <> " worstUpdatePagesAtMaxHeight=" <> show (2 * (maxLevel + 1) + 1)
          <> " bookkeepingReserve=" <> show bookkeepingReserve <> " maxClaimPages=" <> show maxClaimPages
          <> " minimumRemovalPages=" <> show minimumRemovalPages <> " minimumRemovalRam=" <> show minimumRemovalRam)
    mPagesWritten m `shouldBe` 256
    -- the component-wise worst holds the read facts at their ceiling ('maxReadFactBytes'): the sum of the worst of every component is a
    -- bound for the ACCOUNTS (at the measured costs it exceeds the plan limit by design); a plan's own total is checked against
    -- 'txnRamLimit' by the planner's one gate
    ramTotal (worstChargeWith maxTxnPages (3 * maxBatchUpdates) 0) `shouldSatisfy` (> txnRamLimit)
    ramContinuation w - ramContinuation (worstChargeWith maxTxnPages (3 * maxBatchUpdates) 0) `shouldBe` maxReadFactBytes
  it "two openings with a pending continuation, replayed through pages" $ do
    let run0 = newRun smallSpec twoOpenings 1
    r1 ← must (foldM' (\r (x, y, z) → removeCell r (tileAt x y z)) run0 openingA)
    (r2, _) ← must (batchStep r1)
    let pendingMid = pendingObligations (storeHeader (hStore (runH r2)))
    r3 ← must (foldM' (\r (x, y, z) → removeCell r (tileAt x y z)) r2 openingB)
    (r4, batches) ← must (drain r3)
    let maxUpdates = maximum (0 : map (mUpdates . plMeasure) (runPlans r4))
        maxPages = maximum (0 : map (mPagesWritten . plMeasure) (runPlans r4))
    ev ("replay twoOpenings batch=1 pendingAfterFirstBatch=" <> show pendingMid <> " drainBatches=" <> show batches
          <> " plans=" <> show (length (runPlans r4)) <> " maxStructuralUpdates=" <> show maxUpdates <> " maxPagesPerTransaction=" <> show maxPages
          <> " pendingAtEnd=" <> show (pendingObligations (storeHeader (hStore (runH r4)))))
    pendingMid `shouldSatisfy` (> 0)
    maxUpdates `shouldSatisfy` (<= 64)
  it "fault and reader traces" $ do
    -- a staged transaction abandoned after every prefix of its writes
    (h, ref, plan) ← faultFixture
    let n = length (plPages plan)
    outcomes ← mapM (\k → prefixOutcome h ref plan k) [0 .. n]
    ev ("fault fixture pages=" <> show n <> " prefixes=" <> show (length outcomes) <> " oldRootIntactInEvery=" <> show (and outcomes)
          <> " rollbackWrites=0 usageRestored=True")
    and outcomes `shouldBe` True
    -- readers pinned across later writes, then released
    (hr, tok1, tok2, v1, v2) ← readerFixture
    ev ("readers pinnedVersions=" <> show [v1, v2] <> " retiredBytesWhileHeld=" <> show (usRetiredBytes (usage (hStore hr)))
          <> " oldestPin=" <> show (oldestPin (hStore hr)))
    (hpre, preSteps) ← must (reclaimAll hr)
    ev ("readers reclaimedBeforeThePin transactions=" <> show preSteps <> " retiredBytesStillHeld=" <> show (usRetiredBytes (usage (hStore hpre))))
    (blocked, _, _) ← must (fillWith hpre (planMaintenance (hStore hpre)))
    ev ("readers reclaimOutcomeWhileHeld=" <> (case blocked of BlockedByReader e o → "BlockedByReader entry=" <> show e <> " pin=" <> show o; other → show (fmap' other)))
    (case blocked of BlockedByReader {} → pure (); other → expectationFailure (show (fmap' other)))
    let (_, s1) = releaseReader tok2 (hStore hpre)
        (_, s2) = releaseReader tok1 s1
    (hd, steps) ← must (reclaimAll hpre {hStore = s2})
    ev ("readers afterLastRelease reclaimTransactions=" <> show steps <> " retiredBytes=" <> show (usRetiredBytes (usage (hStore hd)))
          <> " maxPagesPerTransaction=" <> show (mxPages (hMaxes hd)) <> " totalPagesFreed=" <> show (mxFreed (hMaxes hd)))
    must (checkH hd)
  it "exhaustion, the protected reserve and incremental reclamation" $ do
    let tight = specOf (64 * mibI) (Just (48 * mibI))
        loop h ref g i
          | i > (4000 ∷ Int) = Left "never filled"
          | otherwise = do
              let (ws, g') = genWrites g ref 30
              p ← fillPlan h (stepDelta (hStore h) 0 ws) Ordinary
              case p of
                Refused r@(Capacity (DiskFull {})) → Right (h, r, i)
                other → do
                  (h', _) ← runPlanned h other
                  loop h' (applyRef ws ref) g' (i + 1)
    (hf, why, commits) ← must (loop (newH tight ident0) Map.empty (mkRng 5) 0)
    ev ("exhaustion tight=64MiB allowance, 48MiB overhead commits=" <> show commits <> " refusal=" <> show why)
    ev ("exhaustion at refusal " <> usageLine (usage (hStore hf)))
    (hr, steps) ← must (reclaimAll hf)
    ev ("exhaustion after " <> show steps <> " reclaim transactions " <> usageLine (usage (hStore hr)))
    ev ("exhaustion maxPagesPerTransaction=" <> show (mxPages (hMaxes hr)) <> " totalPagesFreed=" <> show (mxFreed (hMaxes hr)))
    usProtectedBytes (usage (hStore hf)) `shouldBe` 8 * fromIntegral mibI
  it "cycles" $
    forM_ [101, 202, 303] $ \seed → do
      (_, r) ← must (runCycles seed 450)
      ev ("cycles " <> show r)
      crMaxPages r `shouldSatisfy` (<= 256)
  it "allocation: work independent of the history" $ do
    (h, keys) ← must (wide 20000)
    rows ← allocationRatios h keys
    forM_ rows $ \(name, small, big) →
      ev ("allocation " <> name <> " history500runs=" <> show small <> "B history20000runs=" <> show big <> "B ratio=" <> show (fromIntegral big / fromIntegral (max 1 small) ∷ Double))
    length rows `shouldBe` 5
  where
    foldM' f z xs = go z xs
      where
        go acc [] = Right acc
        go acc (y : ys) = f acc y >>= \acc' → go acc' ys
    fmap' p = case p of Planned _ → "Planned"; NoWork → "NoWork"; Pending _ → "Pending"; PendingProbes _ → "Pending"; Checkpoint _ → "Checkpoint"; Refused r → "Refused " <> show r; BlockedByReader _ _ → "Blocked"

faultFixture ∷ IO (H, Map.Map RecordKey Record, Plan)
faultFixture = do
  let go g h ref i
        | i >= (60 ∷ Int) = Right (h, ref, g)
        | otherwise = do
            let (ws, g') = genWrites g ref 25
            (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
            go g' h' (applyRef ws ref) (i + 1)
  (h, ref, g) ← must (go (mkRng 2024) (newH smallSpec ident0) Map.empty 0)
  let (ws, _) = genWrites g ref 40
  p ← must (fillPlan h (stepDelta (hStore h) 0 ws) Ordinary)
  case p of
    Planned plan → pure (h, ref, plan)
    other → expectationFailure (show other) >> fail "no plan"

-- | Whether abandoning the plan after @k@ completed writes and a failed one leaves
-- the committed roots, usage, records and pages as they were, without a write.
prefixOutcome ∷ H → Map.Map RecordKey Record → Plan → Int → IO Bool
prefixOutcome h ref plan k = do
  (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h)))
  let (done, rest) = splitAt k (plPages plan)
      step (s, d) (p, bs) = let (_, sa) = dispatchWrite tid p s; (_, sb) = completeWrite tid p WriteDone sa in (sb, diskWrite p bs d)
      (s2, d2) = foldl step (s1, hDisk h) done
      s3 = case rest of
        ((p, _) : _) → snd (completeWrite tid p WriteFailed (snd (dispatchWrite tid p s2)))
        [] → s2
  s4 ← must (either (Left . show) Right (abortTransaction tid s3))
  let h4 = h {hStore = s4, hDisk = d2}
  pure
    ( storeRoots s4 == storeRoots (hStore h)
        && usage s4 == usage (hStore h)
        && checkH h4 == Right ()
        && compareRecords (Map.toList ref) h4 == Right ()
    )

readerFixture ∷ IO (H, ReaderToken, ReaderToken, Word64, Word64)
readerFixture = do
  let churn' (h, ref, g) = do
        let (ws, g') = genWrites g ref 30
        (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
        Right (h', applyRef ws ref, g')
      run st n = foldl (\acc _ → acc >>= churn') (Right st) [1 .. n ∷ Int]
  st1@(h1, ref1, g1) ← must (run (newH smallSpec ident0, Map.empty, mkRng 77) 40)
  _ ← pure st1
  (t1, s1) ← must (either (Left . show) Right (acquireReader (hStore h1)))
  (h2, ref2, g2) ← must (run (h1 {hStore = s1}, ref1, g1) 25)
  (t2, s2) ← must (either (Left . show) Right (acquireReader (hStore h2)))
  (h3, _, _) ← must (run (h2 {hStore = s2}, ref2, g2) 40)
  v1 ← must (either (const (Left "stale")) Right (readerVersion s1 t1))
  v2 ← must (either (const (Left "stale")) Right (readerVersion s2 t2))
  pure (h3, t1, t2, v1, v2)
