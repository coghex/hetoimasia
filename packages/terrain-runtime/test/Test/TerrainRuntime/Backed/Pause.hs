-- | A storage failure pauses only the arena it belongs to (requirement 8): its last committed
-- terrain stays readable, its new removals settle at once with the recorded fault, and another
-- arena of the same session keeps committing. Faults are injected at the native seam, so a real
-- worker meets a real failure.
module Test.TerrainRuntime.Backed.Pause (spec) where

import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

isRead ∷ NativeOp → Bool
isRead = \case OpReadAt {} → True; _ → False

spec ∷ Spec
spec = describe "A paused arena" $
  it "pauses only the arena whose page read back short, keeps its committed terrain readable, and lets another arena commit" $ do
    probe ← H.newProbe
    withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
      client ← okOf (registerClient svc)
      first ← okOf (openArena svc client "first" soilOverStone) >>= await svc >>= expectSuccess
      second ← okOf (openArena svc client "second" soilOverStone) >>= await svc >>= expectSuccess
      -- history in the first arena's store: its next staging read reads a page
      _ ← removeCell' svc first (tile 3 4 9)
      -- that read comes back short: a page that ended inside itself is storage_integrity
      H.addRule probe 1 isRead H.ZeroBytes
      failed ← removeAt svc first (tile 3 4 5) Nothing >>= expectRight >>= await svc
      failed `shouldSatisfy` \case Left (Failed (StorageFailed (FaultIntegrity _))) → True; _ → False
      firstView ← inspectArena svc first >>= maybe (fail "arena vanished") pure
      viewPaused firstView `shouldBe` [CondIntegrity]
      -- its committed terrain is still read, at its committed revision
      kept ← readCell svc first (tile 3 4 9)
      (cellIs kept, cellRevision kept) `shouldBe` (True, viewRevision firstView)
      -- a new removal settles at once with the recorded fault; nothing is repeated
      again ← removeAt svc first (tile 6 6 6) Nothing >>= expectRight >>= await svc
      again `shouldSatisfy` \case Left (Failed (StorageFailed (FaultIntegrity _))) → True; _ → False
      -- the other arena is not paused and commits
      other ← removeCell' svc second (tile 3 4 5)
      removeChangedFlag other `shouldBe` True
      secondView ← inspectArena svc second >>= maybe (fail "arena vanished") pure
      viewPaused secondView `shouldBe` []
      -- a successful read since does not clear an integrity pause
      status ← arenaStatus svc first >>= expectRight
      statusStorage status `shouldBe` StoragePaused [CondIntegrity]
      settleChecks svc
