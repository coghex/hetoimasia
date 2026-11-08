-- | The independent accounting oracle, and the controls that prove it can fail.
--
-- The owner thread keeps a read-only record of the work it runs (each load job with its
-- reservation, scratch and slot, the preparation, each handoff duplicate), written where
-- that work starts and ends. The oracle ("Test.TerrainRuntime.Usage") compares that
-- record and the service's own data with the model's charges under the owner's rule:
-- never under-charged. These examples
--
-- * pin what the record says, in literal amounts worked out by hand from the data the
--   work holds (not from the model, and not from the cost functions the model uses);
-- * hold the owner at the point where each kind of work runs, and show the honest model
--   passes the comparison there; and
-- * damage the model's side the way a faulty accounting would (a job charged 1 byte
--   instead of 400, a scratch of 1 instead of 258, a handoff duplicate zeroed, a job
--   forgotten early, a preparation's record or growth dropped) and require the
--   comparison to fail, naming what is under-charged.
--
-- The record is read by no production decision; reading it changes nothing.
module Test.TerrainRuntime.Oracle (spec) where

import Control.Concurrent.STM (atomically, check, readTVar)
import Control.Exception (finally)
import Control.Monad (forM_, void)
import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import Data.Word (Word64)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.TerrainRuntime.Fixtures
import Test.TerrainRuntime.Usage

-- | The model and the service's census, in one look.
snap ∷ Service → IO (Model, Census)
snap svc = atomically ((,) <$> inspectModelSTM svc <*> inspectCensusSTM svc)

-- | The same, as plain data.
look ∷ Service → IO (Model, Held, Charged)
look svc = (\(m, c) → (m, heldOf c, chargedOf m)) <$> snap svc

-- | A ledger with some of its reserved or occupied bytes taken away.
lessReserved, lessOccupied ∷ Word64 → Ledger → Ledger
lessReserved n l = l {ledgerReserved = ledgerReserved l - min n (ledgerReserved l)}
lessOccupied n l = l {ledgerOccupied = ledgerOccupied l - min n (ledgerOccupied l)}

-- | A model that charges every job the given resident reservation and scratch, however
-- much it should: the ledgers fall by what was taken away, as they would in a faulty
-- accounting.
chargingJobs ∷ Word64 → Word64 → Charged → Charged
chargingJobs resident scratch c =
  c
    { cJobs = [j {cjResident = min resident (cjResident j), cjScratch = min scratch (cjScratch j)} | j ← cJobs c]
    , cResident = lessReserved (sum [cjResident j - min resident (cjResident j) | j ← cJobs c]) (cResident c)
    , cStaging = lessReserved (sum [cjScratch j - min scratch (cjScratch j) | j ← cJobs c]) (cStaging c)
    }

mentions ∷ String → [String] → Bool
mentions needle = any (needle `isInfixOf`)

spec ∷ Spec
spec = describe "The accounting oracle and its controls" $ do
  -- A load job: a one-cell read in a fresh region. Its coverage is one column and one
  -- segment: 48 bytes of column index, 32 of segment metadata and 64 of dense payload
  -- (144 in all) and, with the 256 bytes the region's metadata costs, the model reserves
  -- 400; its scratch is a 256-byte frame and two bytes for the one cell (258).
  describe "a running load job" $ do
    let atJob act = do
          gate <- newDisarmedGate
          withGatedService defaultConfig alwaysAdmitting (\p → case p of PointJob {} → True; _ → False) gate $ \svc → (\a → a `finally` openGate gate) $ do
            client <- okOf (registerClient svc)
            lease <- okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
            armGate gate
            host <- newHost True
            _ <- okOf (cellWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1))
            awaitReached gate
            void (act svc)
            openGate gate
            void (waitFor (settledSTM host))
    it "is recorded from the coverage it loads, and the honest model passes" $
      atJob $ \svc → do
        (model, held, charged) <- look svc
        [(hjResident j, hjScratch j, hjSlots j) | j ← heldJobs held] `shouldBe` [(144, 258, 1)]
        -- The model reserves more than the job's coverage alone (it adds the region's
        -- metadata): 400, the figure the reviewer's control reduced.
        [(cjResident j, cjScratch j) | j ← cJobs charged] `shouldBe` [(400, 258)]
        disagreements held charged `shouldBe` []
        slotInUse model LoadJobSlot `shouldBe` 1
    it "fails the comparison when the model reserves 1 byte of resident and 1 of scratch instead of 400 and 258" $
      atJob $ \svc → do
        (_, held, charged) <- look svc
        let found = disagreements held (chargingJobs 1 1 charged)
        mentions "resident reservation" found `shouldBe` True
        mentions "scratch" found `shouldBe` True
        mentions "resident bank reserved" found `shouldBe` True
        mentions "staging bank reserved" found `shouldBe` True
    it "fails the comparison for a reserve one byte short, and for a scratch one byte short" $
      atJob $ \svc → do
        (_, held, charged) <- look svc
        mentions "resident reservation" (disagreements held (chargingJobs 399 258 charged)) `shouldBe` False -- 400 charged, 144 held: still above
        mentions "resident reservation" (disagreements held (chargingJobs 143 258 charged)) `shouldBe` True
        mentions "scratch" (disagreements held (chargingJobs 400 257 charged)) `shouldBe` True
    it "fails the comparison when the model forgot the job early (acknowledged it while it runs)" $
      atJob $ \svc → do
        (model, census) <- snap svc
        case [jobId j | j ← modelJobs model, jobPhase j == JobRunningPhase] of
          jid : _ → do
            usageDisagreements census model `shouldBe` []
            let forgotten = fst (step model (JobFailed jid))
            mentions "holds no running" (usageDisagreements census forgotten) `shouldBe` True
          [] → expectationFailure "the owner is at a job but the model holds none running"
    it "ends the record with the job's report" $ do
      gate <- newDisarmedGate
      withGatedService defaultConfig alwaysAdmitting (\p → case p of PointJob {} → True; _ → False) gate $ \svc → (\a → a `finally` openGate gate) $ do
        client <- okOf (registerClient svc)
        lease <- okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
        armGate gate
        _ <- okOf (cellAt svc lease (tile 1 1 1))
        awaitReached gate
        (length . runningJobs . censusRunning <$> atomically (inspectCensusSTM svc)) `shouldReturn` 1
        openGate gate
        waitFor (inspectCensusSTM svc >>= \census → check (null (runningJobs (censusRunning census))))
        usageOf svc `shouldReturn` []

  -- A handoff: after a removal commits, the owner copies the region's retained changes
  -- (one removed interval, 16 bytes, and one column entry, 48 bytes) to transfer them.
  describe "a handoff duplicate" $ do
    let atHandoff act = do
          gate <- newDisarmedGate
          withGatedService defaultConfig alwaysAdmitting (\p → case p of PointHandoff {} → True; _ → False) gate $ \svc → (\a → a `finally` openGate gate) $ do
            (_, lease) <- openMain svc "main"
            _ <- readCell svc lease (tile 1 1 1)
            armGate gate
            _ <- removeCell' svc lease (tile 1 1 1)
            awaitReached gate
            void (act svc)
            openGate gate
            waitFor (inspectCensusSTM svc >>= \census → check (null (runningHandoffs (censusRunning census))))
            usageOf svc `shouldReturn` []
    it "is recorded while the transfer runs, and the honest model charges it" $
      atHandoff $ \svc → do
        (_, held, charged) <- look svc
        map hhDuplicate (heldHandoffs held) `shouldBe` [64]
        [d | r ← cRegions charged, Just d ← [crDuplicate r]] `shouldBe` [64]
        disagreements held charged `shouldBe` []
    it "fails the comparison when the model's 64-byte duplicate is zeroed" $
      atHandoff $ \svc → do
        (_, held, charged) <- look svc
        let zeroed =
              charged
                { cRegions = [r {crDuplicate = fmap (const 0) (crDuplicate r)} | r ← cRegions charged]
                , cStaging = lessOccupied 64 (cStaging charged)
                }
            found = disagreements held zeroed
        mentions "handoff duplicate" found `shouldBe` True
        mentions "staging bank occupied" found `shouldBe` True
        -- and when the model charges none at all
        mentions "charges none" (disagreements held charged {cRegions = [r {crDuplicate = Nothing} | r ← cRegions charged]}) `shouldBe` True

  -- A preparation: the owner stages a removal; the request's record and reservations must
  -- be in the model for as long as it runs.
  describe "a running preparation" $ do
    let atStaging act = do
          gate <- newDisarmedGate
          withGatedService defaultConfig alwaysAdmitting (\p → case p of PointStaging _ → True; _ → False) gate $ \svc → (\a → a `finally` openGate gate) $ do
            (_, lease) <- openMain svc "main"
            _ <- readCell svc lease (tile 1 1 1)
            armGate gate
            host <- newHost True
            _ <- okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1) Nothing)
            awaitReached gate
            void (act svc)
            openGate gate
            waitFor (inspectCensusSTM svc >>= \census → check (isNothing (runningPreparation (censusRunning census))))
            void (waitFor (settledSTM host))
    it "is recorded from the command it runs, and the honest model holds the request" $
      atStaging $ \svc → do
        (_, census) <- snap svc
        case runningPreparation (censusRunning census) of
          Nothing → expectationFailure "the owner is preparing a removal but recorded none"
          Just p → do
            (preparationRemoval p, preparationResident p, preparationStaging p, preparationEdit p) `shouldBe` (True, 62, 512, 64)
            preparationRecordBytes p `shouldBe` 160
        usageOf svc `shouldReturn` []
    it "fails the comparison when the model forgot the request being prepared, or reserves no growth for it" $
      atStaging $ \svc → do
        (model, held, charged) <- look svc
        case modelRequests model of
          r : _ → do
            mentions "holds no record" (disagreements held (chargedOf (fst (step model (Withdraw (requestId r)))))) `shouldBe` True
            mentions "resident growth" (disagreements held charged {cRequests = [(rid, removal, 0) | (rid, removal, _) ← cRequests charged]}) `shouldBe` True
          [] → expectationFailure "the owner is preparing a removal but the model holds no request"

  it "reads the census and the record without changing the model, its clock, its requests or its limits" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      _ <- readCell svc lease (tile 1 1 1)
      let observe = do
            m <- inspectModel svc
            rows <- inspectLimits svc
            pure (modelClock m, modelRegions m, modelJobs m, modelRequests m, modelHolds m, modelInterests m, map (bankLedger m) allBanks, rows)
      earlier <- observe
      forM_ [1 .. 5 ∷ Int] $ \_ → atomically (inspectCensusSTM svc) >>= \census → length (censusArenas census) `shouldBe` 1
      later <- observe
      later `shouldBe` earlier
      settleChecks svc

  -- The accounting rule does not relax release: whatever conservative excess an arena was
  -- charged (coalescing edits are charged more than they hold) is returned when the arena
  -- retires, and no charge outlives its holder.
  it "returns every account of an arena with coalesced edits when the arena retires" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      _ <- readCell svc lease (tile 1 1 0)
      forM_ [tile 1 1 0, tile 1 1 2, tile 1 1 1] (void . removeCell' svc lease)
      (model, census) <- snap svc
      -- charged more than held while the arena lives (the monotone, conservative charge) ...
      zipWith (>) [arenaRetainedBytes a | a ← modelArenas model] (map censusRetainedBytes (censusArenas census)) `shouldBe` [True]
      releaseLease svc lease >>= (`shouldBe` Right ())
      -- ... and all of it returned when the arena has retired.
      waitFor $ do
        m <- inspectModelSTM svc
        check (null (modelArenas m) && and [ledgerOccupied (bankLedger m b) == 0 && ledgerReserved (bankLedger m b) == 0 | b ← [ResidentBank, EditBank, StagingBank]])
      (m, census') <- snap svc
      [slotInUse m s | s ← allSlots] `shouldBe` map (const 0) allSlots
      (length (censusArenas census'), null (runningJobs (censusRunning census')), null (runningHandoffs (censusRunning census'))) `shouldBe` (0, True, True)
      usageDisagreements census' m `shouldBe` []
      settleChecks svc
  where
    usageOf svc = atomically (usageDisagreements <$> inspectCensusSTM svc <*> inspectModelSTM svc)
    settledSTM host = readTVar (hostSettled host) >>= \settled → check (not (null settled))
