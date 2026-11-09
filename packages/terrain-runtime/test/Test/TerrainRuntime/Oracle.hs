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
import Data.List (isInfixOf, sort)
import Data.Maybe (isNothing)
import Data.Word (Word64)
import Hetoimasia.Terrain.Coordinate (decomposeTile, mkLocalCoord)
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

-- | A model that charges the jobs the predicate selects no more than the given resident
-- reservation and scratch, however much they should be charged: the ledgers fall by what
-- was taken away, as they would in a faulty accounting.
chargingJobsWhere ∷ (ChargedJob → Bool) → Word64 → Word64 → Charged → Charged
chargingJobsWhere selects resident scratch c =
  c
    { cJobs = [if selects j then j {cjResident = min resident (cjResident j), cjScratch = min scratch (cjScratch j)} else j | j ← cJobs c]
    , cResident = lessReserved (sum [cjResident j - min resident (cjResident j) | j ← cJobs c, selects j]) (cResident c)
    , cStaging = lessReserved (sum [cjScratch j - min scratch (cjScratch j) | j ← cJobs c, selects j]) (cStaging c)
    }

-- | Every job charged no more than the given amounts.
chargingJobs ∷ Word64 → Word64 → Charged → Charged
chargingJobs = chargingJobsWhere (const True)

mentions ∷ String → [String] → Bool
mentions needle = any (needle `isInfixOf`)

spec ∷ Spec
spec = describe "The accounting oracle and its controls" $ do
  -- A load job: a one-cell read in a fresh region. Its coverage is one column and one
  -- segment. The model grants it 400 bytes of resident (48 for the column index, 32 of segment
  -- metadata and the 64 of dense payload a segment can need, and the 256 the region's metadata
  -- costs) and 258 of scratch (a 256-byte frame and two bytes for the one cell). The record holds
  -- that grant and, separately, the least the coverage can hold, worked out from the data layer's
  -- sizes: 82 (48 + 32 + the two payload bytes of a uniform segment) and 258.
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
        -- The record: the job as granted (400 and 258, the figures the reviewer's control reduced)
        -- and the least its coverage can hold from the data layer's sizes (one column index entry,
        -- 48, and one uniform segment, 32 of metadata and 2 of payload, 82; the scratch, 258).
        [(hjGrantedResident j, hjGrantedScratch j, hjResident j, hjScratch j, hjSlots j) | j ← heldJobs held] `shouldBe` [(400, 258, 82, 258, 1)]
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
        -- as granted: 400 and 258, so a charge one byte short of either is under-charged
        mentions "resident reservation" (disagreements held (chargingJobs 399 258 charged)) `shouldBe` True
        mentions "scratch" (disagreements held (chargingJobs 400 257 charged)) `shouldBe` True
        disagreements held (chargingJobs 400 258 charged) `shouldBe` []
    it "fails the comparison when the model forgot the job early (acknowledged it while it runs)" $
      atJob $ \svc → do
        (model, census) <- snap svc
        case [jobId j | j ← modelJobs model, jobPhase j == JobRunningPhase] of
          jid : _ → do
            usageDisagreements census model `shouldBe` []
            let forgotten = fst (step model (JobFailed jid))
            mentions "holds no such job" (usageDisagreements census forgotten) `shouldBe` True
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

  -- A job that has been accepted but is not running (it waits for the owner) holds its
  -- reservation and its scratch all the same: the record holds every accepted job, with the
  -- amounts the model granted it, and a model that releases a waiting job's charge early is
  -- under-charging it.
  describe "a job that waits for the owner" $ do
    let withWaiting act = do
          gate <- newDisarmedGate
          withGatedService defaultConfig alwaysAdmitting (\p → case p of PointJob {} → True; _ → False) gate $ \svc → (\a → a `finally` openGate gate) $ do
            client <- okOf (registerClient svc)
            lease <- okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
            armGate gate
            first <- newHost True
            second <- newHost True
            _ <- okOf (cellWith svc (hostEndpoint svc Nothing first) lease (tile 1 1 1))
            awaitReached gate
            -- The owner is held at the first job; a second one is admitted and waits.
            _ <- okOf (cellWith svc (hostEndpoint svc Nothing second) lease (tile 17 1 1))
            void (act svc)
            openGate gate
            void (waitFor (settledSTM first))
            void (waitFor (settledSTM second))
    it "is recorded as granted, holds no slot, and the honest model charges it" $
      withWaiting $ \svc → do
        (_, held, charged) <- look svc
        sort [(hjGrantedResident j, hjGrantedScratch j, hjSlots j) | j ← heldJobs held] `shouldBe` [(400, 258, 0), (400, 258, 1)]
        disagreements held charged `shouldBe` []
    it "fails the comparison when the model releases only the waiting job's 400 bytes of resident and 258 of scratch" $
      withWaiting $ \svc → do
        (_, held, charged) <- look svc
        let waiting = [hjJob j | j ← heldJobs held, hjSlots j == 0]
            damaged = chargingJobsWhere ((`elem` waiting) . cjJob) 0 0 charged
            found = disagreements held damaged
        length waiting `shouldBe` 1
        mentions "resident reservation" found `shouldBe` True
        mentions "scratch" found `shouldBe` True
        -- only the waiting job: the running one is still charged in full
        length [() | s ← found, "job " `isInfixOf` s] `shouldBe` 2
    it "fails the comparison for a waiting job charged one byte short" $
      withWaiting $ \svc → do
        (_, held, charged) <- look svc
        let waiting = [hjJob j | j ← heldJobs held, hjSlots j == 0]
        mentions "resident reservation" (disagreements held (chargingJobsWhere ((`elem` waiting) . cjJob) 399 258 charged)) `shouldBe` True
        mentions "scratch" (disagreements held (chargingJobsWhere ((`elem` waiting) . cjJob) 400 257 charged)) `shouldBe` True

  -- A borrow's hold names the regions its snapshot covers, and a view's description the
  -- regions its accepted demand describes: both are read from what the service handed out
  -- or accepted, not from the model's records of them.
  describe "a borrow and a view description" $ do
    it "records the regions a borrowed snapshot covers, and a model that names fewer fails the comparison" $
      withService defaultConfig $ \svc → do
        (_, lease) <- openMain svc "main"
        _ <- readCell svc lease (tile 1 1 1)
        _ <- readCell svc lease (tile 1 1 33)
        let regions = [fst (decomposeTile (tile 1 1 1)), fst (decomposeTile (tile 1 1 33))]
        outcome <- withSnapshot svc lease regions $ \_ → do
          (_, held, charged) <- look svc
          map snd (heldHolds held) `shouldBe` [2]
          disagreements held charged `shouldBe` []
          -- the model's record of the borrow shortened to one region, its staging charge with it
          let shortened =
                charged
                  { cHolds = [(h, 1) | (h, _) ← cHolds charged]
                  , cStaging = lessOccupied 64 (cStaging charged)
                  }
              found = disagreements held shortened
          mentions "hold" found `shouldBe` True
          mentions "staging bank occupied (request records and interests, borrows" found `shouldBe` True
          -- and a model that lost the borrow altogether
          mentions "no such borrow" (disagreements held charged {cHolds = []}) `shouldBe` True
        either (expectationFailure . show) pure outcome
    it "records the regions a view's accepted demand describes, and a model that names fewer fails the comparison" $
      withService defaultConfig $ \svc → do
        (client, lease) <- openMain svc "main"
        view <- okOf (openView svc client)
        let demanded = [fst (decomposeTile (tile 1 1 1)), fst (decomposeTile (tile 17 1 1))]
        _ <- okOf (setViewDemand svc view lease [RegionDemand r (coverageTile (either (error . show) id (mkLocalCoord 0 0 0))) | r ← demanded])
        (_, held, charged) <- look svc
        map snd (heldViews held) `shouldBe` [2]
        disagreements held charged `shouldBe` []
        let shortened = charged {cViews = [(v, 1) | (v, _) ← cViews charged], cStaging = lessOccupied 64 (cStaging charged)}
            found = disagreements held shortened
        -- The description is checked entity by entity (the camera's own interests, held only in
        -- the model, leave the staging total above what the service can claim here).
        mentions "description" found `shouldBe` True
        mentions "holds no view" (disagreements held charged {cViews = []}) `shouldBe` True
        okOf (clearViewDemand svc view)
        (_, held', _) <- look svc
        heldViews held' `shouldSatisfy` null
        closeView svc view
        settleChecks svc

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
