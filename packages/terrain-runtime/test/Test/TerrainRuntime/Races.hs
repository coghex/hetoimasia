-- | Cancellation against commit, in both host fixtures.
--
-- The arrival fixture is always eligible. The delayed-eligibility fixture stages
-- work, is told it is ready, and commits only when it is granted. Every example
-- decides which side wins by a gate or a grant, never by a delay, and checks that
-- the disposition, the overlay and the revision agree.
module Test.TerrainRuntime.Races (spec) where

import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), throwIO)
import Control.Monad (forM_)
import Hetoimasia.Terrain.Cell (Cell (..))
import Hetoimasia.Terrain.Coordinate (decomposeTile)
import Hetoimasia.Terrain.Residency (ArenaId (..), ArenaInfo (..), Revision (..), modelArenas)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.TerrainRuntime.Fixtures

-- | The cell the examples remove.
victim ∷ (Integer, Integer, Integer)
victim = (3, 4, 5)

at ∷ (Integer, Integer, Integer) → Service → ArenaLease → IO CellAnswer
at (x, y, z) svc lease = readCell svc lease (tile x y z)

spec ∷ Spec
spec = describe "Cancellation, staging and commit" $ do
  forM_ [("arrival", True), ("delayed-eligibility", False)] $ \(label, eligible) → describe label $ do
    it "cancelled before staging commits nothing" $ do
      gate <- newGate
      withGatedService defaultConfig alwaysAdmitting (\p → case p of PointStaging _ → True; _ → False) gate $ \svc → do
        (_, lease) <- openMain svc "main"
        host <- newHost eligible
        request <- okOf (let (x, y, z) = victim in removeWith svc (hostEndpoint svc (Just lease) host) lease (tile x y z) Nothing)
        awaitReached gate
        cancel svc request >>= (`shouldBe` CancelWon)
        openGate gate
        settledOf host `shouldReturn` [Cancelled]
        grant host
        -- Duplicate and late settlement are harmless.
        cancel svc request >>= (`shouldBe` AlreadySettled)
        settledOf host `shouldReturn` [Cancelled]
        answer <- at victim svc lease
        (cellRevision answer, cellIs answer) `shouldBe` (Revision 0, False)
        settleChecks svc

    it "cancelled at the commit boundary leaves the cell and the revision" $ do
      gate <- newDisarmedGate
      withGatedService defaultConfig alwaysAdmitting (\p → case p of PointBeforeCommit _ → True; _ → False) gate $ \svc → do
        (_, lease) <- openMain svc "main"
        armGate gate
        host <- newHost eligible
        request <- okOf (let (x, y, z) = victim in removeWith svc (hostEndpoint svc (Just lease) host) lease (tile x y z) Nothing)
        grant host
        awaitReached gate
        cancel svc request >>= (`shouldBe` CancelWon)
        openGate gate
        answer <- at victim svc lease
        (cellRevision answer, cellIs answer) `shouldBe` (Revision 0, False)
        settledOf host `shouldReturn` [Cancelled]
        settleChecks svc

    it "committed first answers already settled and the edit stands" $
      withService defaultConfig $ \svc → do
        (_, lease) <- openMain svc "main"
        host <- newHost eligible
        request <- okOf (let (x, y, z) = victim in removeWith svc (hostEndpoint svc (Just lease) host) lease (tile x y z) Nothing)
        grant host
        settled <- waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
        settled `shouldBe` [Succeeded (ARemoved (RemoveAnswer (ArenaId 0) (Revision 1) True))]
        cancel svc request >>= (`shouldBe` AlreadySettled)
        cancel svc request >>= (`shouldBe` AlreadySettled)
        settledOf host `shouldReturn` settled
        -- The success never preceded its edit: the arbitration had already
        -- published revision 1 when the settlement was delivered.
        seenAtSettle host `shouldReturn` [Just (1, False)]
        answer <- at victim svc lease
        (cellRevision answer, cellIs answer) `shouldBe` (Revision 1, True)
        settleChecks svc

  it "stages without committing, announces readiness, and commits only when granted" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      host <- newHost False
      _ <- okOf (let (x, y, z) = victim in removeWith svc (hostEndpoint svc (Just lease) host) lease (tile x y z) Nothing)
      -- Ready is distinct from eligible and from settled.
      waitFor (readTVar (hostReady host) >>= \n → if n == 0 then retry else pure ())
      settledOf host `shouldReturn` []
      untouched <- at victim svc lease
      (cellRevision untouched, cellIs untouched) `shouldBe` (Revision 0, False)
      grant host
      _ <- waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
      done <- at victim svc lease
      (cellRevision done, cellIs done) `shouldBe` (Revision 1, True)
      settleChecks svc

  it "fails a request whose preparation fails and keeps the previous state" $ do
    armed <- newTVarIO True
    let probe = Probe $ \point → case point of
          PointStaging _ → do
            fire <- atomically (swapTVar armed False)
            if fire then throwIO (ErrorCall "injected preparation failure") else pure ()
          _ → pure ()
    withServiceUsing defaultConfig alwaysAdmitting probe $ \svc → do
      (_, lease) <- openMain svc "main"
      let (x, y, z) = victim
      outcome <- okOf (removeAt svc lease (tile x y z) Nothing) >>= await svc
      case outcome of
        Left (Failed (HostFailure _)) → pure ()
        other → expectationFailure ("expected a host failure, got " <> show other)
      stillSolid <- at victim svc lease
      (cellRevision stillSolid, cellIs stillSolid) `shouldBe` (Revision 0, False)
      -- The service goes on, and the same removal now succeeds.
      removed <- removeCell' svc lease (tile x y z)
      removeRevision removed `shouldBe` Revision 1
      settleChecks svc

  it "abandons the whole commit when the settlement callback fails" $ do
    gate <- newDisarmedGate
    withGatedService defaultConfig alwaysAdmitting (\p → case p of PointBeforeCommit _ → True; _ → False) gate $ \svc → do
      (_, lease) <- openMain svc "main"
      let (x, y, z) = victim
          (victimRegion, _) = decomposeTile (tile x y z)
      -- Load the cell, then hold a snapshot of it so the arena's accounting
      -- stays observable after the owner has ended.
      loaded <- at victim svc lease
      cellRevision loaded `shouldBe` Revision 0
      armGate gate
      held <- withSnapshot svc lease [victimRegion] $ \snapshot → do
        host <- newHost True
        let failing = (hostEndpoint svc Nothing host) {endpointSettle = \_ → throwSTM (ErrorCall "host settlement failed")}
        _ <- okOf (removeWith svc failing lease (tile x y z) Nothing)
        awaitReached gate
        openGate gate
        awaitOwnerStopped svc
        -- Nothing was committed, and nothing was told: the host's callback ran
        -- inside the abandoned transaction, whose effects are gone.
        settledOf host `shouldReturn` []
        model <- inspectModel svc
        [(arenaId info, arenaRevision info, arenaRetainedBytes info) | info <- modelArenas model]
          `shouldBe` [(ArenaId 0, Revision 0, 0)]
        snapshotCell snapshot (tile x y z) `shouldSatisfy` isSolid
        pure ()
      held `shouldBe` Right ()
      defects <- inspectDefects svc
      case defects of
        ProviderDefect _ : _ → pure ()
        other → expectationFailure ("expected a provider defect first, got " <> show other)
      inspectInvariants svc >>= (`shouldBe` [])
  where
    isSolid = \case Known (Solid {}) → True; _ → False
