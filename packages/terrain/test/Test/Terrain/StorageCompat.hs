-- | What the temporary store (TRA-20) must not change in the baseline.
--
-- Until the terrain owner adopts the store (TRA-22) the RAM-only baseline keeps its
-- admission outcomes: the three service-wide banks of 256, 64 and 128 MiB, the
-- retained-edit charge that is funded at a removal and kept for the arena's life
-- (an offload or an eviction never credits it), the exhausted outcome that is neither
-- busy nor invalid, and reads that continue beside it. The store's own edit-bank
-- division (48 MiB caches, 8 MiB staging, 8 MiB control) lives in
-- @hetoimasia-terrain-runtime@ and never shrinks the baseline's retained capacity or
-- reclassifies its refusals. The one addition to this package for the store, the
-- inverse of a component key's origin and parameters, is checked here too.
module Test.Terrain.StorageCompat (spec) where

import Hetoimasia.Terrain.Connectivity (Axis (..), keyOrigin, keyParameters, mkComponentKey)
import Hetoimasia.Terrain.Coordinate (axisFromInteger, tileCoord)
import Hetoimasia.Terrain.Residency
import Test.Hspec
import Test.Terrain.ConnectivityFixtures (compiled, keyAt)
import Test.Terrain.Model (mustTile)
import Test.Terrain.ResidencySupport
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))

mibB ∷ Word
mibB = 1024 * 1024

spec ∷ Spec
spec = describe "the RAM-only baseline beside the temporary store" $ do
  it "keeps the 256, 64 and 128 MiB banks and the retained edits' lifetime charge as its limits" $ do
    (fromIntegral (limitBytes defaultLimits ResidentBank) ∷ Word) `shouldBe` 256 * mibB
    (fromIntegral (limitBytes defaultLimits EditBank) ∷ Word) `shouldBe` 64 * mibB
    (fromIntegral (limitBytes defaultLimits StagingBank) ∷ Word) `shouldBe` 128 * mibB
  it "keeps a removal's retained charge after the region is handed off and evicted" $ do
    m0 ← fst <$> stepOk (newModel tiny) (OpenArena a1 rev0)
    (m1, accepted) ← stepOk m0 (SubmitRemoval (RequestId 1) a1 rev0 (either (error . show) id (tileCoord 0 0 0)))
    _ ← pure accepted
    m2 ← stepsOk m1 [Dispatch, JobCompleted (JobId 0) oneCellCost]
    m3 ← fst <$> stepOk m2 (RemovalCommitted (RequestId 1) (Revision 1) 64 0)
    ledgersOf m3 `shouldBe` Ledgers (338, 0) (64, 0) (0, 0)
    -- the baseline holds the only copy of the edit: a handoff protects the detail until
    -- its transfer is confirmed, and even then the retained bytes stay charged
    m4 ← stepsOk m3 [BeginHandoff a1 (reg 0 0 0) 64, HandoffConfirmed a1 (reg 0 0 0)]
    ledgersOf m4 `shouldBe` Ledgers (338, 0) (64, 0) (0, 0)
    (m5, evicting) ← stepOk m4 (SubmitQuery (RequestId 2) a1 (Revision 1) [demand (reg 1 0 0) (cell 0 0 0), demand (reg 2 0 0) (cell 0 0 0)])
    case reportDecision evicting of
      Accepted a → admissionVictims a `shouldBe` [(a1, reg 0 0 0)]
      other → expectationFailure (show other)
    -- the retained edit bytes are the edit bank's, unchanged by the eviction
    let Ledgers _ edit _ = ledgersOf m5
    edit `shouldBe` (64, 0)
    [arenaRetainedBytes a | a ← modelArenas m5] `shouldBe` [64]
  it "still answers exhausted, neither busy nor invalid, at the retained bound, and keeps serving reads" $ do
    let limits = limitsWith $ \s → s {specEditBytes = 64, specResidentBytes = 4000, specStagingBytes = 8192, specLoadJobs = 5, specHoldRegions = 1, specCameraRegions = 64}
    m0 ← fst <$> stepOk (newModel limits) (OpenArena a1 rev0)
    (m1, _) ← stepOk m0 (SubmitRemoval (RequestId 1) a1 rev0 (either (error . show) id (tileCoord 0 0 0)))
    m2 ← stepsOk m1 [Dispatch, JobCompleted (JobId 0) oneCellCost]
    m3 ← fst <$> stepOk m2 (RemovalCommitted (RequestId 1) (Revision 1) 64 0)
    refusal ← stepRefused m3 (SubmitRemoval (RequestId 2) a1 (Revision 1) (either (error . show) id (tileCoord 16 0 0)))
    refusal `shouldBe` RetainedEditsExhausted EditBank 64 64 64
    (m4, read') ← stepOk m3 (SubmitQuery (RequestId 3) a1 (Revision 1) [demand (reg 1 0 0) (cell 0 0 0)])
    case reportDecision read' of
      Accepted _ → pure ()
      other → expectationFailure (show other)
    [arenaRetainedBytes a | a ← modelArenas m4] `shouldBe` [64]
  describe "the component key's inverse for the store's codec" $ do
    it "rebuilds every key of a layered source from its origin and parameters" $ do
      let spec' = SourceSpec ["stone", "slab"] [LayerSpec Nothing (Just 8) "stone" 0] [PatchSpec x 0 5 6 SpecAir | x ← [2 .. 8]]
          c = compiled spec'
          keys = [k | x ← [-3 .. 12], z ← [3 .. 9], Just k ← [keyAt c (x, 0, z)]]
      length keys `shouldSatisfy` (> 5)
      mapM_ (\k → mkComponentKey (keyOrigin k) (keyParameters k) `shouldBe` Just k) keys
    it "refuses parameters that are not in strictly ascending axis order" $ do
      let ax n = either (error . show) id (axisFromInteger n)
          origin = mustTile 1 2 3
      mkComponentKey origin [(AxisY, ax 1), (AxisX, ax 2)] `shouldBe` Nothing
      mkComponentKey origin [(AxisX, ax 1), (AxisX, ax 2)] `shouldBe` Nothing
      mkComponentKey origin [(AxisZ, ax 1), (AxisY, ax 2)] `shouldBe` Nothing
      fmap keyParameters (mkComponentKey origin [(AxisX, ax 1), (AxisZ, ax 2)]) `shouldBe` Just [(AxisX, ax 1), (AxisZ, ax 2)]
      fmap keyOrigin (mkComponentKey origin []) `shouldBe` Just origin
