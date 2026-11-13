-- | Growth: serialized, checked growth against the committed allowance, an extra
-- reservation that is prepared and not spendable until the owner commits it, and a
-- release that can fail, be retained as a bounded pending record and be retried.
--
-- The owner's part (the store model's @proposeGrowth@, @beginGrowth@,
-- @growthReserved@ and @commitGrowth@) is driven here exactly as the owner would
-- drive it; the backend's part is the production one on a real file.
module Test.TerrainRuntime.Storage.Growth (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM_)
import Data.Word (Word64)
import qualified Foreign.C.Error as C
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgAllowanceBytes)
import Test.Hspec
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec, specOf)

er ∷ C.Errno → Errno
er (C.Errno c) = Errno (fromIntegral c)

mib ∷ Word64
mib = 1024 * 1024

h0 ∷ H
h0 = newStoreH smallSpec

big ∷ H
big = newStoreH (specOf (128 * 1024 * 1024) Nothing)

isSetLength ∷ Word64 → NativeOp → Bool
isSetLength n op = op == OpSetFileLength n

isReserve ∷ NativeOp → Bool
isReserve op = case op of OpReserveRange _ _ → True; _ → False

allocatedOf ∷ Env → IO Word64
allocatedOf env = do
  fds ← fdHandles (envProbe env)
  case fds of
    fd : _ → either (fail . show) (pure . nsAllocated) =<< nativeStat posixNative fd
    [] → fail "no descriptor"

grow ∷ Env → Backing → Word64 → Word64 → IO Outcome
grow env b from to = submitGrowth (envSvc env) b from to >>= outcomeOf env

-- | The file occupies what it did before the growth, to one block: a filesystem may keep one block of its
-- own bookkeeping accounted after a release (ext4 kept one extent block in the Linux repeats; APFS none).
backTo ∷ Word64 → Word64 → Bool
backTo held a = a <= held + 4096

-- | What the service holds reserved on the volume, in bytes.
reservedTotal ∷ Env → IO Word64
reservedTotal env = sum . svReserved <$> atomically (serviceView (envSvc env))

view ∷ Env → Backing → IO BackingView
view env b = atomically (backingView (envSvc env) b) >>= maybe (fail "no backing") pure

readOk ∷ Env → Backing → H → Word64 → IO ()
readOk env b h n = readPages env b (hCfg h) n 1 ReadProbe >>= (`shouldSatisfy` either (const False) ((== 1) . length))

spec ∷ Spec
spec = describe "Storage backend: growth" $ do
  it "prepares an extra reservation that is not spendable until the owner commits it" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      -- the model decides the size rules; the owner drives its steps around the backend's
      p ← case proposeGrowth (hStore h0) (toInteger (128 * mib)) of
        GrowthProposed p → pure p
        other → fail ("not proposed: " <> show other)
      s1 ← either (fail . show) pure (beginGrowth p (hStore h0))
      o ← grow env b (gpFrom p) (gpTo p)
      case o of
        GrowthPrepared pg rs → do
          -- the extra PAYLOAD was reserved (the file holds the new allowance's usable pages), and the whole file occupies
          -- no more than the new allowance
          rsAllocated rs `shouldSatisfy` (>= payloadBytes (hCfg big))
          rsAllocated rs `shouldSatisfy` (<= 128 * mib)
          rsLength rs `shouldBe` payloadBytes (hCfg big)
          rsOverhead rs `shouldBe` rsAllocated rs - payloadBytes (hCfg big)
          allocatedOf env >>= (`shouldSatisfy` (>= payloadBytes (hCfg big)))
          v ← view env b
          (bvCommittedBytes v, bvGrowthPrepared v) `shouldBe` (64 * mib, True)
          -- a prepared growth is not capacity: a request for the larger allowance is refused
          readPages env b (hCfg big) 20000 1 ReadProbe >>= (`shouldSatisfy` either (\f → case f of InvalidRequest (BeyondCommittedCap {}) → True; _ → False) (const False))
          -- and a second growth is refused while one waits for its commit
          submitGrowth (envSvc env) b (64 * mib) (96 * mib) >>= (`shouldBe` Left (BusyNow GrowthActive)) . fmap (const ())
          s2 ← either (fail . show) pure (growthReserved s1)
          s3 ← either (fail . show) pure (commitGrowth s2)
          cfgAllowanceBytes (storeConfig s3) `shouldBe` 128 * mib
          commitBackingGrowth (envSvc env) b pg >>= (`shouldBe` Right ())
          v2 ← view env b
          (bvCommittedBytes v2, bvGrowthPrepared v2) `shouldBe` (128 * mib, False)
          readOk env b big 20000
        other → expectationFailure ("not prepared: " <> show other)

  it "answers an equal size as an idempotent no-op that reserves nothing, refuses a smaller size and a stale base, and checks the bounds before any work" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg big)
      proposeGrowth (hStore big) (toInteger (128 * mib)) `shouldBe` GrowthNoOp
      proposeGrowth (hStore big) (toInteger (64 * mib)) `shouldBe` GrowthNotIncreased
      grow env b (128 * mib) (128 * mib) >>= (`shouldBe` GrowthNoChange)
      (bvGrowthPrepared <$> view env b) >>= (`shouldBe` False)
      grow env b (128 * mib) (64 * mib) >>= (`shouldBeFailure` (== InvalidRequest (GrowthNotIncreasing (128 * mib) (64 * mib))))
      grow env b (96 * mib) (192 * mib) >>= (`shouldBeFailure` (== InvalidRequest (GrowthStaleBase (96 * mib) (128 * mib))))
      evs ← events (envProbe env)
      length [() | OpReserveRange _ _ ← evs] `shouldBe` 1 -- the open's, and no more: the no-op reserved nothing

  it "preserves the old size and contents when headroom, the allocation or the length fails" $
    forM_ stages $ \(name, setup, expected) →
      withEnv $ \env → do
        b ← openBacking env ident (hCfg h0)
        held0 ← allocatedOf env
        setup (envProbe env)
        o ← grow env b (64 * mib) (128 * mib)
        case o of
          Failed f notes → do
            (name, expected f) `shouldBe` (name, True)
            notes `shouldBe` []
          other → expectationFailure (name <> ": " <> show other)
        -- whatever was obtained was released: the file occupies what it did, nothing is pending
        allocatedOf env >>= (`shouldSatisfy` backTo held0)
        v ← view env b
        (name, bvCommittedBytes v, bvReservedBytes v, bvPendingReservation v) `shouldBe` (name, 64 * mib, 64 * mib, Nothing)
        readOk env b h0 5

  it "releases the extra space when the growth is cancelled after it was obtained" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      held0 ← allocatedOf env
      g ← addGate (envProbe env) isReserve
      t ← submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= either (fail . show) pure
      awaitReached g 1
      cancelTicket (envSvc env) t >>= (`shouldBe` CancelRequested)
      openGate g
      awaitOutcome env t >>= (`shouldBe` Cancelled [])
      allocatedOf env >>= (`shouldSatisfy` backTo held0)
      (bvReservedBytes <$> view env b) >>= (`shouldBe` 64 * mib)

  it "keeps a pending reservation, charged, when its release fails, and blocks growth until it is released" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      -- the growth fails after the allocation (the overhead is beyond the model's), and the one release attempt fails
      addRuleAfter (envProbe env) 1 1 (== OpStatFile) (OverAllocated (10 * mib))
      addRule (envProbe env) 1 (isSetLength (payloadBytes (hCfg h0))) (FailWith (er C.eIO))
      o ← grow env b (64 * mib) (128 * mib)
      case o of
        Failed (ReservationFailed (OverheadExceedsModel _ _)) notes → notes `shouldBe` [CleanupNote IoSetLength (er C.eIO)]
        other → expectationFailure ("unexpected: " <> show other)
      v ← view env b
      bvPendingReservation v `shouldBe` Just (64 * mib)
      reservedTotal env >>= (`shouldBe` 128 * mib)
      -- growth is refused, nothing is deleted and nothing retries by itself
      grow env b (64 * mib) (128 * mib) >>= (`shouldBeFailure` (== ReservationFailed (PendingReservationBlocks (64 * mib))))
      readOk env b h0 5
      -- an explicit retry succeeds and frees it
      t ← submitReleasePending (envSvc env) b >>= either (fail . show) pure
      awaitOutcome env t >>= (`shouldBe` Released)
      v2 ← view env b
      (bvPendingReservation v2, bvReservedBytes v2) `shouldBe` (Nothing, 64 * mib)
      allocatedOf env >>= (`shouldSatisfy` (< 65 * mib))
      grow env b (64 * mib) (128 * mib) >>= (`shouldSatisfy` \x → case x of GrowthPrepared {} → True; _ → False)

  it "releases a pending reservation with the file when the backing closes" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      addRuleAfter (envProbe env) 1 1 (== OpStatFile) (OverAllocated (10 * mib))
      addRule (envProbe env) 1 (isSetLength (payloadBytes (hCfg h0))) (FailWith (er C.eIO))
      _ ← grow env b (64 * mib) (128 * mib)
      rep ← closeBacking (envSvc env) b
      (crClosed rep, crPendingReservation rep) `shouldBe` (True, Just (64 * mib))

  -- A CHECK USES WHAT WAS OBTAINED, NOT WHAT WAS ASKED (growth): exactly the extra range and the headroom are
  -- available, the native allocation occupies 4,096 bytes more, and the growth is refused and given back.
  it "refuses a growth whose obtained bytes, overhead included, leave less than the headroom, and gives it back" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      held0 ← allocatedOf env
      -- the headroom is kept after the extra ALLOWANCE (64 MiB); the platform occupies the budget plus 4,096 bytes beyond it
      let over = budgetBytes (hCfg big) + 4096
      addRule (envProbe env) 1 (== OpStatFilesystem) (FreeBytesAre (64 * mib + minHeadroomBytes))
      addRuleAfter (envProbe env) 1 1 (== OpStatFile) (OverAllocated over)
      o ← grow env b (64 * mib) (128 * mib)
      o `shouldSatisfy` \x → case x of Failed (ReservationFailed (InsufficientHeadroom avail got room)) _ → avail == 64 * mib + minHeadroomBytes && got == payloadBytes (hCfg big) - payloadBytes (hCfg h0) + over && room == minHeadroomBytes; _ → False
      rulesConsumed (envProbe env) >>= (`shouldBe` True)
      -- given back: the slot is idle, nothing prepared or pending, the file is the size it was
      v ← view env b
      (bvGrowthPrepared v, bvPendingReservation v, bvReservedBytes v) `shouldBe` (False, Nothing, 64 * mib)
      allocatedOf env >>= (`shouldSatisfy` backTo held0)
      reservedTotal env >>= (`shouldBe` (64 * mib))

  it "admits a growth that leaves exactly the headroom after the extra allowance, and refuses one byte less" $ do
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      addRule (envProbe env) 1 (== OpStatFilesystem) (FreeBytesAre (64 * mib + minHeadroomBytes))
      o ← grow env b (64 * mib) (128 * mib)
      o `shouldSatisfy` \x → case x of GrowthPrepared {} → True; _ → False
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      addRule (envProbe env) 1 (== OpStatFilesystem) (FreeBytesAre (64 * mib + minHeadroomBytes - 1))
      o ← grow env b (64 * mib) (128 * mib)
      o `shouldSatisfy` \x → case x of Failed (ReservationFailed (InsufficientHeadroom _ got _)) _ → got == 64 * mib; _ → False

  -- THE PHYSICAL INVARIANT AT ITS BOUNDARY, for growth (round 7): after a growth the file occupies at most the NEW
  -- allowance. A seam whose allocation is exactly the new allowance is admitted; one byte more is refused and the extra
  -- is given back (nothing prepared, nothing pending, the file as it was).
  it "admits a growth whose physical allocation is exactly the new allowance, and refuses one byte more, giving it back" $ do
    -- the real overhead the platform adds to this growth, measured without an injection
    real ← withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      o ← grow env b (64 * mib) (128 * mib)
      case o of
        GrowthPrepared _ rv → pure (rsAllocated rv)
        other → fail ("the baseline growth was not prepared: " <> show other)
    let exact = 128 * mib - real
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      addRuleAfter (envProbe env) 1 1 (== OpStatFile) (OverAllocated exact)
      o ← grow env b (64 * mib) (128 * mib)
      case o of
        GrowthPrepared _ rv → rsAllocated rv `shouldBe` 128 * mib
        other → expectationFailure ("an allocation of exactly the new allowance must be admitted: " <> show other)
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      held0 ← allocatedOf env
      addRuleAfter (envProbe env) 1 1 (== OpStatFile) (OverAllocated (exact + 1))
      o ← grow env b (64 * mib) (128 * mib)
      o `shouldSatisfy` \x → case x of Failed (ReservationFailed (OverheadExceedsModel {})) [] → True; _ → False
      rulesConsumed (envProbe env) >>= (`shouldBe` True)
      v ← view env b
      (bvGrowthPrepared v, bvPendingReservation v, bvReservedBytes v) `shouldBe` (False, Nothing, 64 * mib)
      allocatedOf env >>= (`shouldSatisfy` backTo held0)

  it "gives back a prepared growth that will not be committed" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      held0 ← allocatedOf env
      o ← grow env b (64 * mib) (128 * mib)
      pg ← case o of GrowthPrepared pg _ → pure pg; other → fail (show other)
      t ← submitAbandon (envSvc env) b pg >>= either (fail . show) pure
      awaitOutcome env t >>= (`shouldBe` Released)
      allocatedOf env >>= (`shouldSatisfy` backTo held0)
      v ← view env b
      (bvGrowthPrepared v, bvReservedBytes v) `shouldBe` (False, 64 * mib)
  where
    stages =
      [ ("headroom", \p → addRule p 1 (== OpStatFilesystem) (FreeBytesAre (64 * mib + 255 * mib)), \f → case f of ReservationFailed (InsufficientHeadroom {}) → True; _ → False)
      , ("allocation refused", \p → addRule p 1 isReserve (FailWith (er C.eNOSPC)), \f → case f of ReservationFailed (AllocationRefused _) → True; _ → False)
      , ("length established after allocation", \p → addRule p 1 (isSetLength (payloadBytes (hCfg big))) (FailWith (er C.eIO)), \f → case f of ReservationFailed (LengthFailed _) → True; _ → False)
      , ("rounded allocation beyond the model", \p → addRuleAfter p 1 1 (== OpStatFile) (OverAllocated (10 * mib)), \f → case f of ReservationFailed (OverheadExceedsModel _ _) → True; _ → False)
      ]
