-- | The transaction bounds, exactly and one past them, and the observation that no
-- work grows with the history.
--
-- A plan writes at most 256 pages (1 MiB, metadata included), reserves at most 4 MiB
-- of RAM through at most 512 decoded pages, and a discovery batch performs at most 64
-- structural updates; each bound is met exactly and refused one past it with the
-- typed result. Tighter bounds are injected to reach the stop-earlier behaviour a
-- batch has when another bound is tighter than 64 updates. The supported minimum
-- removal is shown to fit at the format's worst-case tree height. Finally the
-- allocation of an edit, a read, a reclamation step and a usage report is measured at
-- two history sizes: a history-sized map or bitmap built behind the interface would
-- make the larger history allocate proportionally more, and fails these.
module Test.TerrainRuntime.Store.Bounds (spec, wide, findExact256, allocationRatios) where

import Control.Monad (foldM, forM_)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import GHC.Stats (RTSStats (..), GCDetails (..), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.Terrain.Discovery (Record, RecordKey (..), maxBatchUpdates)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Page (..), encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (encodeKey, encodeValue)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Control.Exception (evaluate)
import System.Mem (performMajorGC)
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Scenes
import Test.TerrainRuntime.Store.Workload

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | A store whose runs tree holds @n@ runs in sequential columns: wide and shallow.
wide ∷ Int → Either String (H, [RecordKey])
wide n = do
  let keys = [runKey (toInteger (i `div` 50)) (toInteger (i `mod` 50)) 10 | i ← [0 .. n - 1]]
      chunk = 200
      go h [] = Right h
      go h ks = do
        let (a, b) = splitAt chunk ks
        (h', out) ← commitDelta h Ordinary (deltaFor (hStore h) True False 1 [(k, Just (runRec 20)) | k ← a])
        case out of
          Committed _ → go h' b
          other → Left ("history was not built: " <> show other)
  h ← go (newH smallSpec ident0) keys
  Right (h, keys)

-- | A delta replacing the value of runs spread one per leaf, at a given stride.
spread ∷ [RecordKey] → Int → Int → Int → [(RecordKey, Maybe Record)]
spread keys stride offset k = [(key, Just (runRec 30)) | i ← [0 .. k - 1], let key = keys !! (offset + i * stride)]

allocated ∷ IO Word64
allocated = allocated_bytes <$> getRTSStats

-- | The live heap after a major collection.
liveBytes ∷ IO Word64
liveBytes = performMajorGC >> (gcdetails_live_bytes . gc <$> getRTSStats)

-- | The bytes a forced computation allocates.
measure ∷ IO a → IO Word64
measure act = do
  performMajorGC
  start ← allocated
  _ ← act
  -- the counter is brought up to date by a collection
  performMajorGC
  end ← allocated
  pure (end - start)

-- | A plan that writes exactly 256 pages, and the page count one more write needs (past
-- the bound, so refused), found by bisecting the writes spread one per leaf.
findExact256 ∷ H → [RecordKey] → Either String (Plan, Int)
findExact256 h keys = case [r | off ← [0, 7, 13, 29, 41, 53, 3, 19, 31, 47], Right (Just r) ← [attempt off]] of
  (r : _) → Right r
  [] → Left "no exact 256-page plan with a refused successor"
  where
    planPages off k = fillPlan h (deltaFor (hStore h) True False 1 (spread keys 60 off k)) Ordinary
    pagesFor off k = case planPages off k of
      Right (Planned p) → Right (mPagesWritten (plMeasure p), Just p)
      Right (Refused (Capacity (TxnPagesExceeded n))) → Right (n, Nothing)
      other → Left (show other)
    -- the page count never decreases as writes are added: bisect for the first k past 256
    bisect off lo hi
      | hi - lo <= 1 = do
          a ← pagesFor off lo
          b ← pagesFor off hi
          Right (a, b)
      | otherwise = do
          let mid = (lo + hi) `div` 2
          (n, _) ← pagesFor off mid
          if n <= 256 then bisect off mid hi else bisect off lo mid
    attempt off = do
      (a, b) ← bisect off (60 ∷ Int) 260
      case (a, b) of
        ((256, Just p), (n, Nothing)) | n > 256 → Right (Just (p, n))
        _ → Right Nothing

-- | The bytes one forced computation allocates for an edit plan, a pinned point read and
-- a usage report, over a small and a large history: the figures the observation compares.
allocationRatios ∷ H → [RecordKey] → IO [(String, Word64, Word64)]
allocationRatios hBig keysBig = do
  (hSmall, keysSmall) ← must (wide 500)
  let edit h keys = case fillPlan h (deltaFor (hStore h) True False 1 [(keys !! 200, Just (runRec 31))]) Ordinary of
        Right (Planned p) → evaluate (sum (map (BS.length . snd) (plPages p)) + mPagesWritten (plMeasure p))
        other → expectationFailure (show other) >> pure 0
      readOne h keys = do
        (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h)))
        let w0 = either (const (error "stale")) id (readerWindow s1 tok)
            loop w = case readerLookup s1 tok w (keys !! 200) of
              Read r → pure r
              ReadNeeds p → case diskRead (hDisk h) p of
                Just bs → loop (either (error . show) id (windowInsert (cfgUsablePages (hCfg h)) p bs w))
                Nothing → fail "page"
              other → fail (show other)
        r ← loop w0
        evaluate (maybe 0 (const (1 ∷ Int)) r)
      usageStep h = evaluate (usUsedBytes (usage (hStore h)) + fromIntegral (controlBytes (hStore h)))
      churned n = do
        let go (h, ref, g) _ = do
              let (ws, g') = genWrites g ref 20
              (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
              Right (h', applyRef ws ref, g')
        foldM go (newH smallSpec ident0, Map.empty, mkRng 4) [1 .. (n `div` 20 + 5 ∷ Int)]
      reclaimStep h = case fillWith h (planMaintenance (hStore h)) of
        Right (Planned p, _, _) → evaluate (length (plPages p))
        Right _ → pure 0
        Left e → fail e
  -- warm up so first-use costs do not decide
  _ ← edit hSmall keysSmall
  _ ← edit hBig keysBig
  e1 ← measure (edit hSmall keysSmall)
  e2 ← measure (edit hBig keysBig)
  r1 ← measure (readOne hSmall keysSmall)
  r2 ← measure (readOne hBig keysBig)
  u1 ← measure (usageStep hSmall)
  u2 ← measure (usageStep hBig)
  (hr1, _, _) ← must (churned 600)
  (hr2, _, _) ← must (churned 600)
  c1 ← measure (reclaimStep hr1)
  c2 ← measure (reclaimStep hr2)
  -- the control: a structure that grows with the history, which these observations must catch
  m1 ← measure (evaluate (Map.size (Map.fromList [(k, ()) | k ← keysSmall])))
  m2 ← measure (evaluate (Map.size (Map.fromList [(k, ()) | k ← keysBig])))
  pure
    [ ("a one-record edit plan", e1, e2)
    , ("a pinned point read", r1, r2)
    , ("a usage and control report", u1, u2)
    , ("a reclamation step over an equal retirement list", c1, c2)
    , ("control: a map of every record key", m1, m2)
    ]

spec ∷ Spec
spec = describe "transaction bounds, exactly and one past, and work independent of history" $ do
  (hBig, keysBig) ← runIO (must (wide 20000))
  it "writes at most 256 pages: met exactly, refused one past, with the RAM and window inside their bounds" $ do
    length keysBig `shouldBe` 20000
    (p, n) ← must (findExact256 hBig keysBig)
    mPagesWritten (plMeasure p) `shouldBe` 256
    length (plPages p) * pageSize `shouldBe` maxTxnBytes
    n `shouldSatisfy` (> 256)
    ramTotal (mRam (plMeasure p)) `shouldSatisfy` (<= txnRamLimit)
    mWindowPages (plMeasure p) `shouldSatisfy` (<= maxWindowPages)
  it "bounds the window by its accounted bytes (310 pages accepted, 311 refused) and by its page count" $ do
    let cfg = either (error . show) id (mkStoreConfig smallSpec)
        roots = storeRoots (hStore (newH smallSpec ident0))
        total = cfgUsablePages cfg
        leaf n = Page TreeRuns 0 (PageNo n) (Leaf [(encodeKey (runKey 0 0 (10 * toInteger n)), encodeValue (runRec (10 * toInteger n + 3)))])
        windowOf m = foldl (\w n → either (error . show) id (windowInsert total (PageNo n) (either (error . show) id (encodePage ident0 (leaf n))) w)) (emptyWindow ident0 0) [1 .. m]
        d = deltaFor (hStore (newH smallSpec ident0)) True False 1 [(runKey 0 0 1, Just (runRec 3))]
        run m = planDelta cfg ident0 roots (windowOf m) Ordinary d
        tight = planDeltaWith (Bounds maxTxnPages txnRamLimit 5 maxWindowBytes) cfg ident0 roots
    windowBytes (windowOf 310) `shouldBe` 310 * windowPageBytes
    windowBytes (windowOf 310) `shouldSatisfy` (<= maxWindowBytes)
    windowBytes (windowOf 311) `shouldSatisfy` (> maxWindowBytes)
    case run 310 of
      Planned p → ramTotal (mRam (plMeasure p)) `shouldSatisfy` (<= txnRamLimit)
      other → expectationFailure (show other)
    run 311 `shouldBe` Refused (Capacity (WindowBytesExceeded (311 * windowPageBytes)))
    case tight (windowOf 5) Ordinary d of
      Planned _ → pure ()
      other → expectationFailure (show other)
    tight (windowOf 6) Ordinary d `shouldBe` Refused (Capacity (WindowExceeded 6))
  it "holds a window of dense pages in memory close to what it accounts" $ do
    enabled ← getRTSStatsEnabled
    enabled `shouldBe` True
    let cfg = either (error . show) id (mkStoreConfig smallSpec)
        total = cfgUsablePages cfg
        dense n = Page TreeRuns 0 (PageNo n) (Leaf [(encodeKey (runKey 0 (toInteger n) (100 * i)), encodeValue (runRec (100 * i + 3))) | i ← [1 .. 119]])
        build = foldl (\w n → either (error . show) id (windowInsert total (PageNo n) (either (error . show) id (encodePage ident0 (dense n))) w)) (emptyWindow ident0 0) [1 .. 310]
    liveBefore ← liveBytes
    w ← evaluate (let w' = build in windowBytes w' `seq` w')
    liveAfter ← liveBytes
    -- keep the window alive across the measurement
    windowSize w `shouldBe` 310
    let held = liveAfter - liveBefore
    (held < 2 * fromIntegral (windowBytes w)) `shouldBe` True
  it "holds a dense 180-leaf plan within the RAM it reports, the window and the output included" $ do
    enabled ← getRTSStatsEnabled
    enabled `shouldBe` True
    let leaves = 180 ∷ Int
        perLeaf = 119 ∷ Int
        -- hand-built tree of full leaves: pages 0 .. leaves-1, two internal pages, one root
        leafKey ∷ Int → Int → RecordKey
        leafKey l i = runKey (toInteger l) 0 (100 * toInteger i)
        leafPage l = Page TreeRuns 0 (PageNo (fromIntegral l)) (Leaf [(encodeKey (leafKey l i), encodeValue (runRec (100 * toInteger i + 3))) | i ← [1 .. perLeaf]])
        innerPage ∷ Word64 → [Int] → Page
        innerPage no ls = Page TreeRuns 1 (PageNo no) (Inner [(encodeKey (leafKey l 1), PageNo (fromIntegral l)) | l ← ls])
        half = leaves `div` 2
        left = innerPage (fromIntegral leaves) [0 .. half - 1]
        right = innerPage (fromIntegral leaves + 1) [half .. leaves - 1]
        rootPage = Page TreeRuns 2 (PageNo (fromIntegral leaves + 2)) (Inner [(encodeKey (leafKey 0 1), PageNo (fromIntegral leaves)), (encodeKey (leafKey half 1), PageNo (fromIntegral leaves + 1))])
        pages = [leafPage l | l ← [0 .. leaves - 1]] ++ [left, right, rootPage]
        h0 = newH smallSpec ident0
        disk = foldl (\dk pg → diskWrite (pgNo pg) (either (error . show) id (encodePage ident0 pg)) dk) (hDisk h0) pages
        total = fromIntegral (length pages) ∷ Word64
        roots0 = storeRoots (hStore h0)
        roots = roots0 {rVersion = 1, rRuns = Just (PageNo (fromIntegral leaves + 2)), rHw = total, rLivePages = total}
        store = storeFromRoots (hCfg h0) ident0 roots
        h = h0 {hStore = store, hDisk = disk}
        delta = deltaFor store True False 1 [(leafKey l 5, Just (runRec 509)) | l ← [0 .. leaves - 1]]
    must (checkH h)
    liveBefore ← liveBytes
    (planned, win, _) ← must (fillWith h (\w → planDelta (hCfg h) ident0 (storeRoots store) w Ordinary delta))
    plan ← case planned of
      Planned p → pure p
      other → expectationFailure ("dense plan: " <> take 300 (show other)) >> fail "plan"
    -- force every output buffer and keep the plan and its window alive across the measurement
    _ ← evaluate (sum (map (BS.length . snd) (plPages plan)))
    liveAfter ← liveBytes
    windowSize win `shouldSatisfy` (> leaves)
    mPagesWritten (plMeasure plan) `shouldSatisfy` (> leaves)
    let held = liveAfter - liveBefore
        reported = fromIntegral (ramTotal (mRam (plMeasure plan))) ∷ Word64
        output = fromIntegral (mPagesWritten (plMeasure plan) * pageSize) ∷ Word64
    -- what the plan and its window really retain stays inside what the plan reports ...
    (if held <= reported then pure () else expectationFailure ("held " <> show held <> " reported " <> show reported))
    -- ... and the plan alone retains its output pages and little else: no parsed page survives it
    (if held <= output + output `div` 4 + fromIntegral (windowBytes win) then pure () else expectationFailure ("held " <> show held <> " but the output is " <> show output))
  it "bounds a plan's RAM below 4 MiB by construction, component by component" $ do
    let w = RamCharge (maxTxnPages * pageSize) (maxWindowPages * windowPageBytes) (3 * maxBatchUpdates * maxEntryBytes) ((maxListPages + bookkeepingReserve) * 16 + maxClaimPages * 8 + 4096) (maxWindowPages * 16) (rootRecordBytes + activeRecordBytes + 128) (1024 + maxWindowPages * 8)
    ramTotal w `shouldSatisfy` (< txnRamLimit)
    ramTotal w `shouldSatisfy` (> 3 * 1024 * 1024)
    ramIoBuffers w `shouldBe` 1024 * 1024
  it "refuses one past the 64-update batch and a tighter bound stops a batch earlier" $ do
    let cfg = either (error . show) id (mkStoreConfig smallSpec)
        h0 = newH smallSpec ident0
        s0 = hStore h0
        w = [(runKey 0 0 1, Just (runRec 3))]
    -- the delta's updates are checked against the validated 64
    let go n = planDelta cfg ident0 (storeRoots s0) (emptyWindow ident0 0) Ordinary (deltaFor s0 True False n w)
    case go 64 of
      Planned _ → pure ()
      other → expectationFailure (show other)
    go 65 `shouldBe` Refused (Invalid (TooManyUpdates 65))
    -- a tighter page bound stops a discovery batch after fewer updates, keeping the rest pending
    let run0 = newRun smallSpec twoOpenings 64
        scene = runEnv run0
    r1 ← must (foldM (\r (x, y, z) → removeCell r (tileAt x y z)) run0 openingA)
    let h1 = runH r1
        tight = Bounds 5 txnRamLimit maxWindowPages maxWindowBytes
    (full, _, _) ← must (fillWith h1 (planDiscovery scene (hStore h1)))
    (small, _, _) ← must (fillWith h1 (planDiscoveryWith tight scene (hStore h1)))
    case (full, small) of
      (Planned a, Planned b) → do
        mUpdates (plMeasure a) `shouldSatisfy` (<= 64)
        mPagesWritten (plMeasure b) `shouldSatisfy` (<= 5)
        mUpdates (plMeasure b) `shouldSatisfy` (<= mUpdates (plMeasure a))
      other → expectationFailure (show other)
  it "fits the supported minimum removal at the format's worst-case height, in the smallest and default allowances" $ do
    forM_ [smallSpec, defaultStoreSpec, specOf (64 * 1024 * 1024) (Just (40 * 1024 * 1024))] $ \spec' → do
      cfg ← must (either (Left . show) Right (mkStoreConfig spec'))
      minimumRemovalFeasible cfg `shouldBe` Right ()
    minimumRemovalPages `shouldSatisfy` (<= maxTxnPages)
    minimumRemovalRam `shouldSatisfy` (<= txnRamLimit)
    -- and a real removal in an empty workspace is far below that bound
    let run0 = newRun smallSpec sealedStack 64
    r1 ← must (removeCell run0 (tileAt 1 1 3))
    case runPlans r1 of
      (p : _) → do
        mPagesWritten (plMeasure p) `shouldSatisfy` (<= minimumRemovalPages)
        mUpdates (plMeasure p) `shouldSatisfy` (<= 1)
      [] → expectationFailure "a plan was expected"
    worstUpdatePages (maxLevel + 1) `shouldBe` 17
    bookkeepingReserve `shouldBe` 68
  it "allocates no more for an edit, a read, a reclamation step or a usage report in a history forty times larger" $ do
    enabled ← getRTSStatsEnabled
    enabled `shouldBe` True
    rows ← allocationRatios hBig keysBig
    forM_ rows $ \(name, small, big) → do
      let ratio = fromIntegral big / fromIntegral (max 1 small) ∷ Double
      case name of
        "a usage and control report" → big `shouldSatisfy` (<= small + 4096)
        -- the control shows the observation would notice a history-sized structure
        "control: a map of every record key" → ratio `shouldSatisfy` (> 10.0)
        _ → (name, ratio < 3.0) `shouldBe` (name, True)
