-- | Bounded budgets against real owned data: admissions that cannot overbook,
-- snapshots that stay charged, shared interests that retire at a safe point,
-- and latest-value demand that stays bounded.
module Test.TerrainRuntime.Budgets (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM
import Control.Monad (forM_)
import Hetoimasia.Terrain.Cell (Cell (..))
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), decomposeTile, mkLocalCoord)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Test.Hspec
import Test.Support.Owned (withOwnedThread)
import Test.TerrainRuntime.Fixtures

-- | A one-cell demand in a region.
oneCell ∷ RegionCoord → RegionDemand
oneCell r = RegionDemand r (either (error . show) coverageTile (mkLocalCoord 0 0 0))

-- | Cells in distinct regions of a tight extent, so each needs its own region.
spread ∷ Int → (Integer, Integer, Integer)
spread n = (toInteger (n `mod` 4) * 16, 0, toInteger (n `div` 4 `mod` 5 - 2) * 32)

resident ∷ Model → Word
resident m = fromIntegral (length (modelRegions m))

spec ∷ Spec
spec = describe "Budgets against real owned data" $ do
  it "cannot overbook any bank under concurrent admissions with tiny budgets" $
    withService (tightConfig (2, 1, 2) 2 512) $ \svc → do
      (_, lease) <- openMain svc "main"
      problems <- newTVarIO []
      let worker n = do
            forM_ [n * 7 .. n * 7 + 17] $ \k → do
              let (x, y, z) = spread k
                  attempt = do
                    r <- cellAt svc lease (tile x y z)
                    case r of
                      Left (RefusedBusy _) → yield >> attempt
                      Left other → atomically (modifyTVar' problems (("refused: " <> show other) :))
                      Right p → () <$ await svc p
              attempt
              found <- inspectInvariants svc
              unless' (null found) (atomically (modifyTVar' problems (found <>)))
          unless' c a = if c then pure () else a
      withOwnedThread (worker 0) $ \_ wait0 →
        withOwnedThread (worker 1) $ \_ wait1 →
          withOwnedThread (worker 2) $ \_ wait2 →
            withOwnedThread (worker 3) $ \_ wait3 → mapM_ bounded' [wait0, wait1, wait2, wait3]
      readTVarIO problems `shouldReturn` []
      model <- inspectModel svc
      -- Eviction really happened: far fewer regions are resident than were touched.
      resident model `shouldSatisfy` (< 20)
      settleChecks svc

  it "keeps a held snapshot coherent through an edit and eviction pressure, and keeps its bytes charged" $
    withService (tightConfig (2, 1, 2) 1 512) $ \svc → do
      (_, lease) <- openMain svc "main"
      let (held, _) = decomposeTile (tile 0 0 0)
      earlier <- readCell svc lease (tile 0 0 0)
      cellIs earlier `shouldBe` False
      outcome <- withSnapshot svc lease [held] $ \snapshot → do
        -- The hold charges the region and protects it.
        holds <- modelHolds <$> inspectModel svc
        [(rs) | (_, _, Borrow, rs) ← holds] `shouldBe` [[held]]
        removeCell' svc lease (tile 0 0 0) >>= (`shouldBe` RemoveAnswer (cellIncarnation earlier) (Revision 1) True) . id
        -- Pressure from other regions evicts what it may, never the held one.
        forM_ [4 .. 15] $ \k → do
          let (x, y, z) = spread k
          readCell svc lease (tile x y z)
        regions <- map regionCoord . modelRegions <$> inspectModel svc
        held `elem` regions `shouldBe` True
        -- The snapshot still shows the cell as it was; the live arena shows air.
        snapshotCell snapshot (tile 0 0 0) `shouldSatisfy` \c → case c of Known (Solid {}) → True; _ → False
        (snapshotRevision snapshot) `shouldBe` Revision 0
        live <- readCell svc lease (tile 0 0 0)
        (cellRevision live, cellIs live) `shouldBe` (Revision 1, True)
        snapshotCell snapshot (tile 0 0 1) `shouldSatisfy` \c → c == NotHeld || c == Unloaded || isKnown c
      outcome `shouldBe` Right ()
      holdsAfter <- modelHolds <$> inspectModel svc
      holdsAfter `shouldBe` []
      settleChecks svc

  it "retires a shared job's credits only at the safe point, not at cancellation" $ do
    gate <- newDisarmedGate
    withGatedService defaultConfig alwaysAdmitting (\p → case p of PointJob _ _ → True; _ → False) gate $ \svc → do
      (_, lease) <- openMain svc "main"
      armGate gate
      first' <- okOf (cellAt svc lease (tile 3 4 5))
      second <- okOf (cellAt svc lease (tile 3 4 5))
      awaitReached gate
      jobsOf svc >>= \js → map jobPhase js `shouldBe` [JobRunningPhase]
      -- One interest remains: the work another caller needs is not cancelled.
      cancelPending svc first' >>= (`shouldBe` CancelWon)
      jobsOf svc >>= \js → map jobPhase js `shouldBe` [JobRunningPhase]
      -- The last interest goes: the job is cancelling and still holds its credits.
      cancelPending svc second >>= (`shouldBe` CancelWon)
      js <- jobsOf svc
      map jobPhase js `shouldBe` [JobCancellingPhase]
      model <- inspectModel svc
      (ledgerReserved (bankLedger model ResidentBank) > 0, ledgerReserved (bankLedger model StagingBank) > 0) `shouldBe` (True, True)
      -- The owner's acknowledgement is the safe point.
      openGate gate
      waitFor (inspectModelSTM svc >>= \m → check (null (modelJobs m) && ledgerReserved (bankLedger m ResidentBank) == 0 && ledgerReserved (bankLedger m StagingBank) == 0))
      settleChecks svc

  it "keeps latest-value camera demand bounded across replacement, and explicit work progresses beside it" $
    withService (tightConfig (2, 1, 2) 2 512) $ \svc → do
      (client, lease) <- openMain svc "main"
      view <- okOf (openView svc client)
      forM_ [0 .. 39 ∷ Int] $ \k → do
        let demand = [oneCell (RegionCoord (fromIntegral (j `mod` 3)) 0 (fromIntegral (k `mod` 4) - 2)) | j ← [0 .. 3 ∷ Int]]
        -- Duplicated regions coalesce; the receipt says what happened.
        receipt <- okOf (setViewDemand svc view lease demand)
        length (receiptAdmitted receipt) + length (receiptPending receipt) `shouldSatisfy` (<= 4)
        model <- inspectModel svc
        length (modelViews model) `shouldBe` 1
        sum [length (viewDemand v) | v ← modelViews model] `shouldSatisfy` (<= 4)
        -- An explicit request is never blocked by camera holdings.
        let (x, y, z) = spread (k + 3)
        answer <- readCellPatient svc lease (tile x y z)
        cellMaterial (cellValue answer) `shouldBe` expectedMaterial soilOverStone [] (x, y, z)
        inspectInvariants svc >>= (`shouldBe` [])
      okOf (clearViewDemand svc view)
      closeView svc view
      settleChecks svc
  where
    bounded' wait = wait
    isKnown c = case c of Known _ → True; _ → False
    jobsOf svc = modelJobs <$> inspectModel svc

