-- | Bounded budgets against real owned data: admissions that cannot overbook,
-- snapshots that stay charged, shared interests that retire at a safe point,
-- and latest-value demand that stays bounded.
module Test.TerrainRuntime.Budgets (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forM, forM_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe, listToMaybe)
import Hetoimasia.Terrain.Cell (Cell (..))
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), decomposeTile, mkLocalCoord)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Test.Hspec
import Test.Support.Bounded (bounded)
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

-- | Limits whose camera description may name far more regions than the resident bank
-- holds: one explicit region per query, a resident bank of about two one-cell regions,
-- and a camera cap of 64 regions. The explicit request guarantee (the minimum budgets)
-- holds at these figures; the camera demand has no capacity guarantee.
overBudget ∷ Config
overBudget = defaultConfig {configLimits = limits, configRetainedBytes = 2000}
  where
    spec' bytes staging =
      LimitsSpec
        { specResidentBytes = bytes
        , specEditBytes = 4096
        , specStagingBytes = staging
        , specLoadJobs = 4
        , specQueuedCommands = 8
        , specPinsPerView = 1
        , specAgingQuanta = 3
        , specQueryRegions = 1
        , specExtentX = 1
        , specExtentY = 1
        , specExtentZ = 2
        , specHoldRegions = 0
        , specCameraRegions = 64
        }
    valid bytes staging = either (const Nothing) Just (mkLimits (spec' bytes staging))
    smallest = fromMaybe (error "no resident bank") (listToMaybe [r | r ← [100, 150 .. 200000], Just _ ← [valid r 1000000]])
    stagingFor bytes = fromMaybe (error "no staging bank") (listToMaybe [s | s ← [500, 1000 .. 2000000], Just _ ← [valid bytes s]])
    limits = fromMaybe (error "over-budget limits are invalid") (valid (smallest + 700) (stagingFor smallest + 40000))

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
  -- #639's scheduling assumption, through the service: foreground work is dispatched ahead
  -- of background (camera) work, but a job passed over by 'limitAgingQuanta' dispatches is
  -- served ahead of the foreground work still queued behind it. The owner is held at the
  -- first job while a camera job and five explicit reads queue; the order the owner then
  -- runs them in is observed at the probe, on the owner's own thread.
  it "serves a background job that was passed over for the aging quanta ahead of the foreground work still queued" $ do
    gate <- newDisarmedGate
    order <- newIORef []
    let recorder = Probe $ \point → do
          case point of
            PointJob _ loaded → modifyIORef' order (loaded :)
            _ → pure ()
          probePoint (gatedProbe (\p → case p of PointJob {} → True; _ → False) gate) point
        regionOf k = let (x, y, z) = spread k in fst (decomposeTile (tile x y z))
        cell k = let (x, y, z) = spread k in tile x y z
    withServiceUsing (tightConfig (2, 1, 2) 20 512) alwaysAdmitting recorder $ \svc → (\act → act `finally` openGate gate) $ do
      (client, lease) <- openMain svc "main"
      view <- okOf (openView svc client)
      armGate gate
      first <- okOf (cellAt svc lease (cell 0))
      awaitReached gate
      disarmGate gate
      -- A background job first, then five foreground reads in distinct regions.
      receipt <- okOf (setViewDemand svc view lease [oneCell (regionOf 6)])
      receiptAdmitted receipt `shouldBe` [regionOf 6]
      foreground <- forM [1 .. 5] $ \k → okOf (cellAt svc lease (cell k))
      openGate gate
      _ <- await svc first
      forM_ foreground (await svc)
      waitFor (inspectModelSTM svc >>= \m → check (null (modelJobs m)))
      ran <- reverse <$> readIORef order
      -- Foreground first; the background job, passed over by three dispatches (the aging
      -- quanta of these limits), then goes ahead of the two foreground jobs still queued.
      ran `shouldBe` map regionOf [0, 1, 2, 3, 6, 4, 5]
      okOf (clearViewDemand svc view)
      closeView svc view
      settleChecks svc

  -- D-42 (the owner's rule for camera demand): a demand larger than the banks is never
  -- refused as invalid. It is admitted best effort, in the producer's order, and the
  -- remainder stays pending; it must not block or starve explicit work. Here the demand
  -- stays registered throughout (it is never withdrawn), and an explicit query and a
  -- removal are both admitted and complete beside it.
  it "admits an over-budget view demand best effort, and still completes an explicit query and a removal without withdrawing it" $
    withService overBudget $ \svc → do
      (client, lease) <- openMain svc "main"
      view <- okOf (openView svc client)
      -- Twelve one-cell regions along one row: far more than the resident bank holds.
      let demanded = [RegionCoord (fromIntegral n) 0 0 | n ← [0 .. 11 ∷ Int]]

      receipt <- okOf (setViewDemand svc view lease (map oneCell demanded))
      -- The setup this example stands on: some of the demand is admitted and the rest is
      -- pending, so the test cannot pass without capacity pressure.
      receiptAdmitted receipt `shouldSatisfy` (not . null)
      receiptPending receipt `shouldSatisfy` (not . null)
      length (receiptAdmitted receipt) + length (receiptPending receipt) `shouldBe` length demanded
      -- The demand is registered with a pending remainder, in the model's own record.
      pendingBefore <- viewPendingOf svc
      pendingBefore `shouldSatisfy` (not . null)
      -- An explicit query outside the demand completes with the right material (never air).
      let (x, y, z) = (16 * 14, 0, 0)
      answer <- readCellPatient svc lease (tile x y z)
      cellMaterial (cellValue answer) `shouldBe` expectedMaterial soilOverStone [] (x, y, z)
      -- And an explicit removal commits at the next revision.
      removed <- bounded (removePatient svc lease (tile x y z))
      (removeChangedFlag removed, removeRevision removed) `shouldBe` (True, Revision 1)
      -- The demand was never withdrawn: the view still has its whole demand registered, and
      -- the part that cannot fit is still pending (unloaded terrain stays unknown).
      views <- modelViews <$> inspectModel svc
      map (length . viewDemand) views `shouldBe` [length demanded]
      viewPendingOf svc >>= (`shouldSatisfy` (not . null))
      inspectDefects svc >>= (`shouldBe` [])
      inspectInvariants svc >>= (`shouldBe` [])
      okOf (clearViewDemand svc view)
      closeView svc view
      settleChecks svc

  where
    bounded' wait = wait
    isKnown c = case c of Known _ → True; _ → False
    jobsOf svc = modelJobs <$> inspectModel svc
    viewPendingOf svc = concatMap viewPending . modelViews <$> inspectModel svc
    -- A removal that waits out a refusal for a region the owner has not finished evicting.
    removePatient svc lease at = go
      where
        go =
          removeAt svc lease at Nothing >>= \case
            Right request → await svc request >>= expectSuccess
            Left (RefusedBusy (BusyModel (RegionEvicting _))) → yield >> go
            Left refusal → expectationFailure ("expected a removal, got " <> show refusal) >> fail "unreachable"

