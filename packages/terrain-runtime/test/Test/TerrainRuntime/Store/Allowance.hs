-- | The allowance: configuration, accounting, the protected reserve, exhaustion,
-- reclamation progress and growth.
--
-- The allowance (at least 64 MiB, a multiple of 1 MiB, inside the native offset
-- limit) is spent by live, staged, retired and loose pages and by the overhead;
-- free extents are not used bytes and pending reclaim is a subset of used, never
-- more free capacity. A small usable page space is reached through a checked
-- configuration (a 64 MiB allowance with a large stated overhead), not a shortcut, so
-- the public validation is the one in force. The cases run the real planner until
-- ordinary history is refused with the protected 8 MiB intact, show that a pinned
-- reader keeps pages in the used bytes, that reclamation then runs incrementally
-- inside the reserve once the reader releases, and that growth is a conservative,
-- serialised, accounted proposal.
module Test.TerrainRuntime.Store.Allowance (spec) where

import Control.Monad (foldM, forM_)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Discovery (Record, RecordKey)
import Hetoimasia.Terrain.Runtime.Store.Admission (Failure (..), classifyAdmit, classifyPlan)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Workload

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

mibI ∷ Integer
mibI = 1024 * 1024

-- | A 64 MiB allowance whose overhead leaves 16 MiB (4,096 pages) of page space.
tight ∷ StoreSpec
tight = specOf (64 * mibI) (Just (48 * mibI))

-- | The identity that must hold in every state: the bytes partition the allowance.
partitions ∷ Store → Expectation
partitions s = do
  let u = usage s
  usUsedBytes u + usFreeBytes u `shouldBe` usAllowanceBytes u
  usRetiredBytes u `shouldSatisfy` (<= usUsedBytes u)
  usLiveBytes u + usRetiredBytes u + usLooseBytes u + usStagedBytes u + usOverheadBytes u `shouldSatisfy` (<= usUsedBytes u + 4096)

-- | Commit generated deltas until the next ordinary plan is refused for the disk.
fillUntilFull ∷ H → Map.Map RecordKey Record → Rng → Either String (H, Map.Map RecordKey Record, Rng, PlanRefusal)
fillUntilFull h0 ref0 g0 = go h0 ref0 g0 (0 ∷ Int)
  where
    go h ref g i
      | i > 4000 = Left "never filled"
      | otherwise = do
          let (ws, g') = genWrites g ref 30
          p ← fillPlan h (stepDelta (hStore h) 0 ws) Ordinary
          case p of
            Refused r@(Capacity (DiskFull {})) → Right (h, ref, g', r)
            Refused r → Left ("unexpected refusal " <> show r)
            other → do
              (h', _) ← runPlanned h other
              go h' (applyRef ws ref) g' (i + 1)

spec ∷ Spec
spec = describe "the allowance, its protected reserve and its growth" $ do
  describe "configuration" $ do
    it "accepts the default 1 GiB, the 64 MiB floor and every whole MiB above it" $ do
      forM_ [1024 * mibI, 64 * mibI, 65 * mibI, 777 * mibI] $ \b →
        either (Just . show) (const Nothing) (mkStoreConfig (specOf b Nothing)) `shouldBe` Nothing
      cfgAllowanceBytes <$> mkStoreConfig defaultStoreSpec `shouldBe` Right defaultAllowanceBytes
    it "refuses below the floor, off the MiB grid, past the offset limit and with an impossible overhead" $ do
      mkStoreConfig (specOf (64 * mibI - mibI) Nothing) `shouldBe'` AllowanceBelowMinimum (63 * mibI)
      mkStoreConfig (specOf (64 * mibI + 1) Nothing) `shouldBe'` AllowanceNotAligned (64 * mibI + 1)
      mkStoreConfig (specOf (65 * mibI - 1) Nothing) `shouldBe'` AllowanceNotAligned (65 * mibI - 1)
      mkStoreConfig (StoreSpec (200 * mibI) Nothing (100 * mibI)) `shouldBe'` AllowanceBeyondOffsetLimit (200 * mibI) (100 * mibI)
      mkStoreConfig (StoreSpec (64 * mibI) Nothing 0) `shouldBe'` OffsetLimitInvalid 0
      mkStoreConfig (specOf (64 * mibI) (Just (-1))) `shouldBe'` OverheadInvalid (-1)
      mkStoreConfig (specOf (64 * mibI) (Just (64 * mibI))) `shouldBe'` OverheadInvalid (64 * mibI)
      -- too little page space for the protected reserve and one transaction
      case mkStoreConfig (specOf (64 * mibI) (Just (60 * mibI))) of
        Left (NoRoomForReserve _ _) → pure ()
        other → expectationFailure (show (either show (const "accepted") other))
      -- an allowance larger than any signed offset does not wrap
      mkStoreConfig (StoreSpec (2 ^ (70 ∷ Int)) Nothing (toInteger defaultOffsetLimit)) `shouldBe'` AllowanceBeyondOffsetLimit (2 ^ (70 ∷ Int)) (toInteger defaultOffsetLimit)
    it "places pages inside the allowance and refuses a wrapping offset or range" $ do
      cfg ← must (either (Left . show) Right (mkStoreConfig smallSpec))
      let last' = cfgUsablePages cfg - 1
      pageFileOffset cfg (PageNo 0) `shouldBe` Right 0
      pageFileOffset cfg (PageNo last') `shouldBe` Right (last' * 4096)
      pageFileOffset cfg (PageNo (last' + 1)) `shouldBe` Left (PageBeyondAllowance (PageNo (last' + 1)))
      pageFileOffset cfg (PageNo maxBound) `shouldBe` Left (PageBeyondAllowance (PageNo maxBound))
      rangeFileEnd cfg (PageNo last') 4096 `shouldBe` Right (cfgUsablePages cfg * 4096)
      rangeFileEnd cfg (PageNo last') 4097 `shouldBe` Left OffsetOverflow
      rangeFileEnd cfg (PageNo 0) maxBound `shouldBe` Left OffsetOverflow
      -- the native limit is checked beside the allowance
      cfg2 ← must (either (Left . show) Right (mkStoreConfig (StoreSpec (64 * mibI) Nothing (64 * mibI))))
      pageFileOffset cfg2 (PageNo (cfgUsablePages cfg2 - 1)) `shouldBe` Right ((cfgUsablePages cfg2 - 1) * 4096)
  describe "accounting" $ do
    it "partitions the allowance through staging, publication, retirement and reclamation" $ do
      let h0 = newH smallSpec ident0
      partitions (hStore h0)
      (h1, ref1, g1) ← must (foldM (\(h, r, g) _ → do
                                       let (ws, g') = genWrites g r 25
                                       (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
                                       pure (h', applyRef ws r, g')) (h0, Map.empty, mkRng 3) [1 .. 40 ∷ Int])
      partitions (hStore h1)
      -- a staged transaction holds its claim, and abort gives it back
      let (ws, _) = genWrites g1 ref1 30
      Planned plan ← must (fillPlan h1 (stepDelta (hStore h1) 0 ws) Ordinary)
      (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h1)))
      partitions s1
      usStagedBytes (usage s1) `shouldBe` fromIntegral (mClaimed (plMeasure plan)) * 4096
      s2 ← must (either (Left . show) Right (abortTransaction tid s1))
      usage s2 `shouldBe` usage (hStore h1)
      -- retirement is a subset of used; reclamation returns pages to free
      let usedBefore = usUsedBytes (usage (hStore h1))
      (usRetiredBytes (usage (hStore h1)) > 0) `shouldBe` True
      (h2, _) ← must (reclaimAll h1)
      partitions (hStore h2)
      usRetiredBytes (usage (hStore h2)) `shouldBe` 0
      (usUsedBytes (usage (hStore h2)) < usedBefore) `shouldBe` True
      must (checkH h2)
    it "counts the overhead as used and free extents as not used" $ do
      let h = newH tight ident0
          u = usage (hStore h)
      usUsedBytes u `shouldBe` usOverheadBytes u
      usFreeBytes u `shouldBe` 16 * fromIntegral mibI
      usProtectedBytes u `shouldBe` 8 * fromIntegral mibI
      usAvailableBytes u `shouldBe` 8 * fromIntegral mibI
  describe "exhaustion and the protected reserve" $ do
    it "refuses ordinary history with the protected 8 MiB intact, and reclamation then makes progress" $ do
      let h0 = newH tight ident0
      (h1, ref1, g1, why) ← must (fillUntilFull h0 Map.empty (mkRng 5))
      classifyPlan why `shouldBe` FailDisk
      let u = usage (hStore h1)
      (usFreeBytes u >= usProtectedBytes u) `shouldBe` True
      -- less is left than one worst-case transaction needs, beyond the reserve
      (usAvailableBytes u < fromIntegral maxClaimPages * 4096) `shouldBe` True
      usProtectedBytes u `shouldBe` 8 * fromIntegral mibI
      -- the refusal changed nothing: the committed state and its records are intact
      must (checkH h1)
      must (compareRecords (Map.toList ref1) h1)
      -- reclamation spends the reserve and frees history that no reader holds
      (h2, n) ← must (reclaimAll h1)
      n `shouldSatisfy` (> 0)
      must (checkH h2)
      mxPages (hMaxes h2) `shouldSatisfy` (<= 256)
      (usRetiredBytes (usage (hStore h2)) == 0) `shouldBe` True
      (usAvailableBytes (usage (hStore h2)) > 0) `shouldBe` True
      -- and ordinary history resumes
      let (ws, _) = genWrites g1 ref1 30
      p ← must (fillPlan h2 (stepDelta (hStore h2) 0 ws) Ordinary)
      case p of
        Planned _ → pure ()
        other → expectationFailure ("ordinary history should resume, got " <> show other)
      must (checkH h2)
    it "keeps a pinned reader's pages in the used bytes, then reclaims incrementally inside the reserve once it releases" $ do
      let h0 = newH tight ident0
      (h1, ref1, g1) ← must (foldM (\(h, r, g) _ → do
                                       let (ws, g') = genWrites g r 30
                                       (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
                                       pure (h', applyRef ws r, g')) (h0, Map.empty, mkRng 8) [1 .. 12 ∷ Int])
      (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h1)))
      (h2, ref2, _, _) ← must (fillUntilFull h1 {hStore = s1} ref1 g1)
      -- ordinary space is exhausted and the reserve remains
      (usAvailableBytes (usage (hStore h2)) < fromIntegral maxClaimPages * 4096) `shouldBe` True
      (usProtectedBytes (usage (hStore h2)) >= 8 * fromIntegral mibI) `shouldBe` True
      -- history older than the pin reclaims at once; what the pin can still reach is held
      (h2b, _) ← must (reclaimAll h2)
      (usRetiredBytes (usage (hStore h2b)) > 0) `shouldBe` True
      (blocked, _, _) ← must (fillWith h2b (planMaintenance (hStore h2b)))
      case blocked of
        BlockedByReader {} → pure ()
        other → expectationFailure ("a pinned reader should block reclamation, got " <> show other)
      (usRetiredBytes (usage (hStore h2b)) <= usUsedBytes (usage (hStore h2b))) `shouldBe` True
      let (rel, s2) = releaseReader tok (hStore h2b)
      rel `shouldBe` Applied
      (h3, n) ← must (reclaimAll h2b {hStore = s2})
      n `shouldSatisfy` (> 1)
      usRetiredBytes (usage (hStore h3)) `shouldBe` 0
      (usAvailableBytes (usage (hStore h3)) > 0) `shouldBe` True
      mxPages (hMaxes h3) `shouldSatisfy` (<= 256)
      must (checkH h3)
      must (compareRecords (Map.toList ref2) h3)
    it "refuses an ordinary admission that would spend the reserve, and the refusal names the disk, not a wait" $ do
      let h0 = newH tight ident0
      (h1, ref1, g1, _) ← must (fillUntilFull h0 Map.empty (mkRng 21))
      let (ws, _) = genWrites g1 ref1 30
          d = stepDelta (hStore h1) 0 ws
      p ← must (fillPlan h1 d Ordinary)
      case p of
        Refused (Capacity (DiskFull needed avail prot)) → do
          prot `shouldBe` reservePages
          (avail < needed + prot) `shouldBe` True
        other → expectationFailure (show other)
      -- the same delta as maintenance is not the ordinary path: it may use the reserve
      classifyAdmit BusyTransaction `shouldBe` FailBusy
  describe "growth" $ do
    it "decides equal, smaller and invalid sizes before any provider work" $ do
      let s = hStore (newH smallSpec ident0)
      proposeGrowth s (64 * mibI) `shouldBe` GrowthNoOp
      proposeGrowth s (200 * mibI - 1) `shouldSatisfy` isInvalid
      proposeGrowth s (32 * mibI) `shouldSatisfy` isInvalid
      proposeGrowth s (toInteger defaultOffsetLimit + 1) `shouldSatisfy` isInvalid
      let s2 = hStore (newH (specOf (128 * mibI) Nothing) ident0)
      proposeGrowth s2 (64 * mibI) `shouldBe` GrowthNotIncreased
      case proposeGrowth s (65 * mibI) of
        GrowthProposed p → (gpFrom p, gpTo p) `shouldBe` (64 * 1024 * 1024, 65 * 1024 * 1024)
        other → expectationFailure (show other)
    it "keeps the old allowance until the reservation is reported and committed" $ do
      let s0 = hStore (newH smallSpec ident0)
      p ← case proposeGrowth s0 (128 * mibI) of
        GrowthProposed x → pure x
        other → expectationFailure (show other) >> fail "no proposal"
      s1 ← must (either (Left . show) Right (beginGrowth p s0))
      usAllowanceBytes (usage s1) `shouldBe` 64 * 1024 * 1024
      usPendingGrowthBytes (usage s1) `shouldBe` 0
      either Just (const Nothing) (commitGrowth s1) `shouldBe` Just GrowthNotReserved
      s2 ← must (either (Left . show) Right (growthReserved s1))
      usPendingGrowthBytes (usage s2) `shouldBe` 64 * 1024 * 1024
      -- pending extra reservation is not spendable space
      usFreeBytes (usage s2) `shouldBe` usFreeBytes (usage s0)
      usAllowanceBytes (usage s2) `shouldBe` 64 * 1024 * 1024
      s3 ← must (either (Left . show) Right (commitGrowth s2))
      usAllowanceBytes (usage s3) `shouldBe` 128 * 1024 * 1024
      usPendingGrowthBytes (usage s3) `shouldBe` 0
      (usFreeBytes (usage s3) > usFreeBytes (usage s0)) `shouldBe` True
    it "preserves the old allowance and records when the growth fails or is cancelled before commitment" $ do
      let h0 = newH smallSpec ident0
      (h1, _, _) ← must (foldM (\(h, r, g) _ → do
                                   let (ws, g') = genWrites g r 20
                                   (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
                                   pure (h', applyRef ws r, g')) (h0, Map.empty, mkRng 2) [1 .. 10 ∷ Int])
      p ← case proposeGrowth (hStore h1) (128 * mibI) of
        GrowthProposed x → pure x
        other → expectationFailure (show other) >> fail "no proposal"
      s1 ← must (either (Left . show) Right (beginGrowth p (hStore h1)))
      -- failure before the reservation was obtained: nothing is pending
      let s2 = growthFailed s1
      usage s2 `shouldBe` usage (hStore h1)
      storeRoots s2 `shouldBe` storeRoots (hStore h1)
      -- failure after it was obtained: the extra reservation stays accounted until released
      s3 ← must (either (Left . show) Right (beginGrowth p (hStore h1) >>= growthReserved))
      let s4 = growthFailed s3
      usPendingGrowthBytes (usage s4) `shouldBe` 64 * 1024 * 1024
      usAllowanceBytes (usage s4) `shouldBe` 64 * 1024 * 1024
      either Just (const Nothing) (beginGrowth p s4) `shouldBe` Just GrowthReleasePending
      -- a release that fails keeps it accounted and reported
      let s5 = growthReleaseFailed s4
      usPendingGrowthBytes (usage s5) `shouldBe` 64 * 1024 * 1024
      (growthView s5) `shouldBe` GrowthView False (64 * 1024 * 1024) True
      -- released: another attempt may begin
      let s6 = growthReleased s5
      usPendingGrowthBytes (usage s6) `shouldBe` 0
      either Just (const Nothing) (beginGrowth p s6) `shouldBe` Nothing
    it "is serialised with mutation, and a stale proposal is refused" $ do
      let h0 = newH smallSpec ident0
      Planned plan ← must (fillPlan h0 (stepDelta (hStore h0) 0 (fst (genWrites (mkRng 1) Map.empty 10))) Ordinary)
      (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h0)))
      p ← case proposeGrowth s1 (128 * mibI) of
        GrowthProposed x → pure x
        other → expectationFailure (show other) >> fail "no proposal"
      either Just (const Nothing) (beginGrowth p s1) `shouldBe` Just GrowthBusyTransaction
      s2 ← must (either (Left . show) Right (abortTransaction tid s1))
      s3 ← must (either (Left . show) Right (beginGrowth p s2))
      -- while a growth executes no transaction is admitted
      either Just (const Nothing) (admit plan s3) `shouldBe` Just BusyGrowth
      s4 ← must (either (Left . show) Right (growthReserved s3 >>= commitGrowth))
      -- a proposal made against the old allowance is stale now
      either Just (const Nothing) (beginGrowth p s4) `shouldBe` Just GrowthStale
    it "does not clear an integrity or I/O pause by growing, and clears only the capacity pause" $ do
      let s0 = pauseFor CondCapacity (pauseFor CondIo (pauseFor CondIntegrity (hStore (newH smallSpec ident0))))
      conditions s0 `shouldBe` [CondCapacity, CondIo, CondIntegrity]
      p ← case proposeGrowth s0 (128 * mibI) of
        GrowthProposed x → pure x
        other → expectationFailure (show other) >> fail "no proposal"
      s1 ← must (either (Left . show) Right (beginGrowth p s0 >>= growthReserved >>= commitGrowth))
      conditions s1 `shouldBe` [CondIo, CondIntegrity]
      -- paused arenas admit no ordinary plan; an integrity pause blocks maintenance too
      let h0 = newH smallSpec ident0
      Planned plan ← must (fillPlan h0 (stepDelta (hStore h0) 0 (fst (genWrites (mkRng 1) Map.empty 10))) Ordinary)
      either Just (const Nothing) (admit plan (pauseFor CondCapacity (hStore h0))) `shouldBe` Just (Paused CondCapacity)
      either Just (const Nothing) (admit plan s1) `shouldBe` Just (Paused CondIntegrity)
      let s2 = clearCondition CondIntegrity (clearCondition CondIo s1)
      conditions s2 `shouldBe` []
    it "never grows or deletes history by itself when the disk is full" $ do
      let h0 = newH tight ident0
      (h1, ref1, _, _) ← must (fillUntilFull h0 Map.empty (mkRng 5))
      usAllowanceBytes (usage (hStore h1)) `shouldBe` 64 * 1024 * 1024
      must (compareRecords (Map.toList ref1) h1)
  where
    shouldBe' r e = either id (error "accepted") r `shouldBe` e
    isInvalid d = case d of GrowthInvalid _ → True; _ → False
