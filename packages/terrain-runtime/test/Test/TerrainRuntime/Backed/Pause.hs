-- | A storage failure pauses only the arena it belongs to (requirement 8): its last committed
-- terrain stays readable, its new removals settle at once with the recorded fault, and another
-- arena of the same session keeps committing. Faults are injected at the native seam, so a real
-- worker meets a real failure.
module Test.TerrainRuntime.Backed.Pause (spec) where

import Control.Concurrent.STM (check, readTVar, retry)
import Control.Exception (finally)
import Hetoimasia.Terrain.Coordinate (decomposeTile, mkLocalCoord)
import Hetoimasia.Terrain.Residency (RegionDemand (..), coverageTile)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

isRead ∷ NativeOp → Bool
isRead = \case OpReadAt {} → True; _ → False

spec ∷ Spec
spec = describe "A paused arena" $ do
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

  -- storage_full through the real path (requirement 8): a reader pins an old
  -- version (its page read held at the seam, once), so the pages each later commit retires cannot be
  -- reclaimed; buried removals then fill the 64 MiB allowance until the planner finds the transaction
  -- no longer fits beside the protected reclamation reserve.
  it "pauses the arena storage_full when its allowance cannot take the next transaction, keeps its terrain readable, and grows out of it" $ do
    probe ← H.newProbe
    withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
      (client, lease) ← openMain svc "main"
      _ ← removeCell' svc lease (tile 0 0 (-32))
      -- nothing else reads now (internal work after that commit has finished), so the one held read is
      -- the load's
      waitFor (backedAtRestSTM svc >>= check)
      -- the pin: a view's load job whose page read is held (only that one). A load is not a request,
      -- so no removal waits for it in admission order; its region is far from the removals.
      gate ← H.addGateOnce probe isRead
      view ← okOf (openView svc client)
      let (far, _) = decomposeTile (tile 100 100 0)
      (refusedAt, refusedHost, againHost, againAt) ← flip finally (H.openGate gate) $ do
        _ ← okOf (setViewDemand svc view lease [RegionDemand far (either (error . show) coverageTile (mkLocalCoord 0 0 0))])
        H.awaitReached gate 1
        -- buried removals, one region's worth at most, until one is refused storage_full
        let cells = [(x, y, z) | z ← [-31 .. -1], y ← [0 .. 15], x ← [0 .. 15]]
            go [] n = pure (n, Nothing)
            go ((x, y, z) : rest) n = do
              host ← newHost True
              request ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile x y z) Nothing)
              settled ← waitFor (readTVar (hostSettled host) >>= \s' → if null s' then retry else pure s')
              -- the result is taken (its record retired), as a host does
              retire svc request
              case settled of
                [Succeeded _] → go rest (n + 1)
                _ → pure (n, Just ((x, y, z), host, rest))
        (committed, refused) ← go cells (0 ∷ Int)
        (refusedAt, refusedHost, untouched) ← case refused of
          Just found@(_, host, _) → do
            settledOf host >>= \case
              [Failed (StorageFailed (FaultFull (AllowanceExhausted needed available protected)))] →
                -- the free pages could not take the transaction beside the protected reserve
                (needed + protected > available) `shouldBe` True
              other → expectationFailure ("expected storage_full, got " <> show other)
            pure found
          Nothing → expectationFailure ("no removal was refused after " <> show committed) >> fail "unreachable"
        status ← arenaStatus svc lease >>= expectRight
        statusStorage status `shouldBe` StoragePaused [CondCapacity]
        -- what was committed stays readable; a new removal settles at once with the same fault
        (cellIs <$> readCell svc lease (tile 0 0 (-31))) `shouldReturn` True
        againHost ← newHost True
        let (ax, ay, az) = case untouched of c : _ → c; [] → (15, 15, -1)
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing againHost) lease (tile ax ay az) Nothing)
        _ ← waitFor (readTVar (hostSettled againHost) >>= \s' → if null s' then retry else pure s')
        settledOf againHost >>= (`shouldSatisfy` \case [Failed (StorageFailed (FaultFull _))] → True; _ → False)
        pure (refusedAt, refusedHost, againHost, (ax, ay, az))
      -- the load's read returns and its pin goes; growth clears the capacity pause (and nothing else),
      -- and edits commit again
      okOf (clearViewDemand svc view)
      closeView svc view
      grown ← growArena svc lease (128 * 1024 * 1024) >>= expectRight >>= await svc
      fmap grownChanged grown `shouldBe` Right True
      cleared ← arenaStatus svc lease >>= expectRight
      statusStorage cleared `shouldBe` StorageReady
      -- nothing refused is repeated after recovery: both refused cells are still solid, and each
      -- refused removal settled exactly once
      let (rx, ry, rz) = refusedAt
          (ax, ay, az) = againAt
      (cellIs <$> readCell svc lease (tile rx ry rz)) `shouldReturn` False
      (cellIs <$> readCell svc lease (tile ax ay az)) `shouldReturn` False
      (length <$> settledOf refusedHost) `shouldReturn` 1
      (length <$> settledOf againHost) `shouldReturn` 1
      resumed ← removeCell' svc lease (tile 9 9 (-2))
      removeChangedFlag resumed `shouldBe` True
      settleChecks svc
