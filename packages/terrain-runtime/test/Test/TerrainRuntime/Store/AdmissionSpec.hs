-- | The storage-aware admission decisions of the edit bank.
--
-- The division of the 64 MiB edit bank (48 MiB caches, 8 MiB staging with 4 MiB
-- protected for a foreground mutation, 8 MiB control) is validated; a request's
-- credits are funded all together or none; eviction releases only backed, unpinned
-- copies, least recently used first, and never a copy that is the only one; camera
-- work cannot take the protected staging, and a worst-case foreground transaction is
-- funded in the worst occupied state the configuration allows (camera staging at its
-- limit, readers' pins at their maximum, a full cache of evictable copies), which is
-- what makes the supported minimum removal never wait in a circle. Temporary
-- pressure, impossible requests, exhausted disk allowance and integrity failure keep
-- their own classes. The baseline's 64 MiB edit bank and its outcomes are unchanged.
module Test.TerrainRuntime.Store.AdmissionSpec (spec) where

import Control.Monad (foldM, forM_)
import Data.Word (Word64)
import Hetoimasia.Terrain.Residency (ArenaId (..), Bank (..), defaultLimits, limitBytes)
import Hetoimasia.Terrain.Runtime.Store.Admission
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (AdmitRefusal (..), Condition (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (TreeId (..))
import Test.Hspec

mibW ∷ Word64
mibW = 1024 * 1024

must ∷ Show e ⇒ Either e a → IO a
must = either (\e → expectationFailure (show e) >> fail "refused") pure

config ∷ IO EditBankConfig
config = must (mkEditBankConfig defaultEditBankSpec)

a1, a2 ∷ ArenaId
a1 = ArenaId 1
a2 = ArenaId 2

-- | Fill the cache with @n@ one-MiB entries of an arena and backing.
fillCache ∷ Admission → ArenaId → Backing → Int → IO (Admission, [EntryId])
fillCache adm arena backing n = foldM step (adm, []) [1 .. n]
  where
    step (a, ids) _ = do
      (g, a') ← must (reserve Foreground [CacheCredit arena mibW backing False] a)
      pure (a', ids ++ grantEntries g)

spec ∷ Spec
spec = describe "storage-aware edit-bank admission" $ do
  describe "the division" $ do
    it "accepts the approved division and agrees with the baseline's 64 MiB edit bank" $ do
      cfg ← config
      (ebCacheBytes cfg, ebStagingBytes cfg, ebControlBytes cfg, ebProtectedStagingBytes cfg) `shouldBe` (48 * mibW, 8 * mibW, 8 * mibW, 4 * mibW)
      ebTotalBytes cfg `shouldBe` limitBytes defaultLimits EditBank
    it "refuses a division that cannot fund a foreground transaction or exceeds the bank, by field" $ do
      let d = defaultEditBankSpec
          m = 1024 * 1024
          refused s = either Just (const Nothing) (mkEditBankConfig s)
      refused d {ebsCache = 0} `shouldBe` Just (EditBankNotPositive "cache" 0)
      refused d {ebsStaging = -1} `shouldBe` Just (EditBankNotPositive "staging" (-1))
      refused d {ebsCache = 2 ^ (41 ∷ Int)} `shouldBe` Just (EditBankUnrepresentable "cache" (2 ^ (41 ∷ Int)))
      refused d {ebsCache = 49 * m} `shouldBe` Just (AccountsExceedBank (65 * m) (64 * m))
      refused d {ebsProtectedStaging = 9 * m} `shouldBe` Just (ProtectedExceedsStaging (9 * m) (8 * m))
      refused d {ebsProtectedStaging = m} `shouldSatisfy` isProtectedBelow
      refused d {ebsControl = 16384} `shouldSatisfy` isControlBelow
      refused d {ebsCache = 6 * m, ebsStaging = 8 * m} `shouldSatisfy` isCacheBelow
  describe "all or nothing" $ do
    it "funds every credit or none, leaving the occupancy as it was" $ do
      cfg ← config
      let adm0 = newAdmission cfg
      -- control is nearly full, so a request needing control as well as cache and staging fails whole
      (g1, adm1) ← must (reserve Foreground [ControlCredit (8 * mibW - 10)] adm0)
      let ledgerBefore = ledgers adm1
          request = [StagingCredit mibW, CacheCredit a1 (2 * mibW) Backed True, ControlCredit 100]
      case reserve Foreground request adm1 of
        Left (RefusedBusy (ControlPressure _ _)) → pure ()
        other → expectationFailure ("expected control pressure: " <> either show (const "funded") other)
      ledgers adm1 `shouldBe` ledgerBefore
      -- and once the control credit is released the same request is funded in full
      let adm2 = release g1 adm1
      (g2, adm3) ← must (reserve Foreground request adm2)
      length (grantEntries g2) `shouldBe` 1
      (lgStagingForeground (ledgers adm3), lgControlReserved (ledgers adm3)) `shouldBe` (mibW, 100)
    it "refuses an empty request, a camera request for a control record and a credit no account could ever hold" $ do
      cfg ← config
      let adm = newAdmission cfg
      either Just (const Nothing) (reserve Foreground [] adm) `shouldBe` Just (RefusedInvalid EmptyRequest)
      either Just (const Nothing) (reserve Camera [ControlCredit 1] adm) `shouldBe` Just (RefusedInvalid CameraControl)
      either Just (const Nothing) (reserve Foreground [CacheCredit a1 (49 * mibW) Backed False] adm) `shouldBe` Just (RefusedInvalid (CreditExceedsAccount "cache" (49 * mibW) (48 * mibW)))
      either Just (const Nothing) (reserve Foreground [StagingCredit (9 * mibW)] adm) `shouldBe` Just (RefusedInvalid (CreditExceedsAccount "staging" (9 * mibW) (8 * mibW)))
      either Just (const Nothing) (reserve Camera [StagingCredit (5 * mibW)] adm) `shouldBe` Just (RefusedInvalid (CreditExceedsAccount "staging" (5 * mibW) (4 * mibW)))
  describe "protected staging" $ do
    it "lets camera work take at most the unprotected half, and still funds a foreground mutation" $ do
      cfg ← config
      let adm0 = newAdmission cfg
      (_, adm1) ← must (reserve Camera [StagingCredit (4 * mibW)] adm0)
      case reserve Camera [StagingCredit 1] adm1 of
        Left (RefusedBusy (StagingPressure _ _)) → pure ()
        other → expectationFailure (either show (const "funded") other)
      -- the foreground transaction's staging is inside the protected 4 MiB
      let credits = transactionCredits a1 worstTransactionCharge
      (g, adm2) ← must (reserve Foreground credits adm1)
      (lgStagingCamera (ledgers adm2), lgStagingForeground (ledgers adm2) <= 4 * mibW) `shouldBe` (4 * mibW, True)
      length (grantEntries g) `shouldBe` 1
  describe "eviction" $ do
    it "evicts only backed, unpinned copies, least recently used first, and exactly enough" $ do
      cfg ← config
      (adm1, ids) ← fillCache (newAdmission cfg) a1 Backed 48
      length ids `shouldBe` 48
      -- use the first and third entries so they are the most recently used
      let adm2 = touchEntry (ids !! 2) (touchEntry (head' ids) adm1)
      (g, adm3) ← must (reserve Foreground [CacheCredit a1 (2 * mibW) Backed False] adm2)
      grantEvicted g `shouldBe` [ids !! 1, ids !! 3]
      lgCacheBacked (ledgers adm3) `shouldBe` 48 * mibW
    it "never evicts a copy that is the only one, or a pinned one" $ do
      cfg ← config
      (adm1, ids) ← fillCache (newAdmission cfg) a1 RamOnly 48
      case reserve Foreground [CacheCredit a1 mibW Backed False] adm1 of
        Left (RefusedBusy (CachePressure needed evictable)) → (needed, evictable) `shouldBe` (mibW, 0)
        other → expectationFailure (either show (const "funded") other)
      either Just (const Nothing) (dropEntry (head' ids) adm1) `shouldBe` Just DropNotBacked
      -- once backed it can go; pinned it cannot
      let adm2 = markBacked (head' ids) adm1
          adm3 = pinEntry (head' ids) adm2
      either Just (const Nothing) (dropEntry (head' ids) adm3) `shouldBe` Just DropPinned
      (g, _) ← must (reserve Foreground [CacheCredit a1 mibW Backed False] (unpinEntry (head' ids) adm3))
      grantEvicted g `shouldBe` [head' ids]
      -- an entry that was evicted is unknown afterwards
      (_, adm4) ← must (reserve Foreground [CacheCredit a1 mibW Backed False] (unpinEntry (head' ids) adm3))
      either Just (const Nothing) (dropEntry (head' ids) adm4) `shouldBe` Just DropUnknown
    it "keeps authoritative state out of the cache's reach: backing is the only thing eviction needs to know" $ do
      cfg ← config
      (adm1, ids) ← fillCache (newAdmission cfg) a1 RamOnly 10
      (adm2, _) ← fillCache adm1 a1 Backed 38
      -- the ten RAM-only copies survive whatever is evicted
      (g, _) ← must (reserve Foreground [CacheCredit a1 (30 * mibW) Backed False] adm2)
      forM_ ids $ \i → grantEvicted g `shouldNotContain` [i]
      length (grantEvicted g) `shouldBe` 30
    it "shares one cache across arenas and charges each arena's copies to it alone" $ do
      cfg ← config
      (adm1, _) ← fillCache (newAdmission cfg) a1 Backed 30
      (adm2, _) ← fillCache adm1 a2 Backed 18
      (arenaCacheBytes a1 adm2, arenaCacheBytes a2 adm2) `shouldBe` (30 * mibW, 18 * mibW)
      -- arena 2 needs room: arena 1's backed copies are the shared cache's victims
      (g, adm3) ← must (reserve Foreground [CacheCredit a2 (10 * mibW) Backed False] adm2)
      length (grantEvicted g) `shouldBe` 10
      arenaCacheBytes a2 adm3 `shouldBe` 28 * mibW
      lgCacheBacked (ledgers adm3) `shouldBe` 48 * mibW
  describe "the supported minimum removal never waits in a circle" $ do
    it "is funded with camera staging at its limit, readers' pins at their maximum and a full cache of evictable copies" $ do
      cfg ← config
      let pinnedEach = readerPinnedCacheBytes
          readers = 4 * 16 ∷ Int
      (adm1, _) ← fillCache (newAdmission cfg) a1 Backed 40
      -- readers' pinned copies at their maximum, charged as pinned cache
      adm2 ← foldM (\a _ → do
                      (g, a') ← must (reserve Camera [CacheCredit a2 pinnedEach Backed True] a)
                      pure (seq g a')) adm1 [1 .. readers]
      (_, adm3) ← must (reserve Camera [StagingCredit (4 * mibW)] adm2)
      (g, adm4) ← must (reserve Foreground (transactionCredits a1 worstTransactionCharge) adm3)
      (lgCachePinned (ledgers adm4) >= fromIntegral readers * pinnedEach) `shouldBe` True
      length (grantEvicted g) `shouldSatisfy` (> 0)
      -- every evicted copy was backed and unpinned: nothing authoritative was released
      lgCacheRamOnly (ledgers adm4) `shouldBe` 0
  describe "checked credit arithmetic" $ do
    it "refuses credits whose sum would wrap, in every account, without changing the admission" $ do
      cfg ← config
      let adm = newAdmission cfg
          ledgerBefore = ledgers adm
          bigs = maxBound ∷ Word64
      -- two cache credits of maxBound and 1 wrap to zero as a Word64 sum
      case reserve Foreground [CacheCredit a1 bigs Backed False, CacheCredit a1 1 Backed False] adm of
        Left (RefusedInvalid (CreditExceedsAccount "cache" _ limit)) → limit `shouldBe` ebCacheBytes cfg
        other → expectationFailure (either show (const "funded") other)
      case reserve Foreground [StagingCredit bigs, StagingCredit 1] adm of
        Left (RefusedInvalid (CreditExceedsAccount "staging" _ _)) → pure ()
        other → expectationFailure (either show (const "funded") other)
      case reserve Foreground [ControlCredit bigs, ControlCredit 2] adm of
        Left (RefusedInvalid (CreditExceedsAccount "control" _ _)) → pure ()
        other → expectationFailure (either show (const "funded") other)
      case reserve Camera [StagingCredit (bigs - 1), StagingCredit 3] adm of
        Left (RefusedInvalid (CreditExceedsAccount "staging" _ _)) → pure ()
        other → expectationFailure (either show (const "funded") other)
      ledgers adm `shouldBe` ledgerBefore
      -- a single credit of maxBound is refused the same way
      case reserve Foreground [CacheCredit a1 bigs Backed False] adm of
        Left (RefusedInvalid (CreditExceedsAccount "cache" _ _)) → pure ()
        other → expectationFailure (either show (const "funded") other)
  describe "queued descriptors" $ do
    it "charges at most eight descriptors' metadata to the control account" $ do
      cfg ← config
      credits ← must (descriptorCredits maxQueuedDescriptors)
      credits `shouldBe` [ControlCredit (8 * descriptorRecordBytes)]
      (_, adm) ← must (reserve Foreground credits (newAdmission cfg))
      lgControlReserved (ledgers adm) `shouldBe` 8 * descriptorRecordBytes
      descriptorCredits (maxQueuedDescriptors + 1) `shouldBe` Left (CreditExceedsAccount "queued descriptors" 9 8)
      descriptorCredits 0 `shouldBe` Left EmptyRequest
  describe "classes of failure" $ do
    it "keeps temporary pressure, impossible requests, exhausted disk, integrity and replanning apart" $ do
      classifyPlan (Capacity (DiskFull 1 0 0)) `shouldBe` FailDisk
      classifyPlan (Capacity (TxnPagesExceeded 300)) `shouldBe` FailTooLarge
      classifyPlan (Capacity (WindowExceeded 600)) `shouldBe` FailTooLarge
      classifyPlan (Integrity (BrokenInvariant TreeRuns)) `shouldBe` FailIntegrity
      classifyPlan (Integrity CorruptCounters) `shouldBe` FailIntegrity
      classifyPlan (Invalid ForeignArena) `shouldBe` FailInvalid
      classifyPlan (Stale (StaleWindow 1 2)) `shouldBe` FailReplan
      classifyAdmit BusyTransaction `shouldBe` FailBusy
      classifyAdmit BusyGrowth `shouldBe` FailBusy
      classifyAdmit StalePlan `shouldBe` FailReplan
      classifyAdmit (NoCapacity 5 1) `shouldBe` FailDisk
      classifyAdmit (Paused CondIntegrity) `shouldBe` FailPaused CondIntegrity
  where
    head' (x : _) = x
    head' [] = error "empty"
    isProtectedBelow r = case r of Just (ProtectedBelowForeground _ _) → True; _ → False
    isControlBelow r = case r of Just (ControlBelowNeed _ _) → True; _ → False
    isCacheBelow r = case r of Just (CacheBelowNeed _ _) → True; _ → False
