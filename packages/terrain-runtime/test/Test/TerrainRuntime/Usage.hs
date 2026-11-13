-- | What every bank, slot and arena of the accounting model must hold, stated from
-- what the service itself holds and not from the model's own ledgers.
--
-- Two plain views are compared, each built once from its source and then only read:
--
-- * 'Held' is what the service holds. It comes from the service's own data structures
--   (`inspectCensusSTM`): the bytes of each arena's resident detail and retained
--   changes, live or retiring, taken from the detail itself; every request it holds,
--   withdrawn ones included; its outstanding snapshots; and the read-only record the
--   owner thread keeps of the work it is running (each load job with its reservation,
--   scratch and slot, and the preparation), written where that work
--   starts and ends (every accepted load job, with the reservation and scratch the model
--   granted it at admission and the least its coverage can hold from the data layer's own
--   sizes; the regions each outstanding borrow covers, from the snapshot handed out; the
--   regions each view's accepted demand describes, from the receipt).
-- * 'Charged' is what the model charges: its ledgers, slots and the entities it keeps.
--
-- The rule is the owner's: never under-charged. For every bank, slot and arena, in every
-- state, the charge is at least what the service holds; the comparison is exact only
-- where the issue states an exact charge (a request's command record, a removal's edit
-- and staging reservations, the command slots, the snapshot holds). Both views are plain
-- data, so a test can damage one of them the way a faulty model would and require the
-- comparison to fail: that is how the oracle is itself tested.
module Test.TerrainRuntime.Usage
  ( Held (..)
  , HeldArena (..)
  , HeldRequest (..)
  , HeldJob (..)
  , HeldPreparation (..)
  , Charged (..)
  , ChargedJob (..)
  , ChargedRegion (..)
  , heldOf
  , chargedOf
  , disagreements
  , usageDisagreements
  , usageSTM
  , withRetained
  , jobStartDisagreements
  , removalGrowthBound
  ) where

import Control.Concurrent.STM (STM)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Word (Word64)
import Hetoimasia.Terrain.Coordinate (RegionCoord)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
  ( Census
  , censusArena
  , censusArenas
  , censusBorrows
  , censusModelRecord
  , censusRegionBytes
  , censusRegions
  , censusRemoval
  , censusRequests
  , censusRetainedBytes
  , censusRetiring
  , censusRunning
  , censusSettled
  , inspectCensusSTM
  , inspectModelSTM
  , inspectRetainedChargesSTM
  , Service
  , jobWorkArena
  , jobWorkGrantedResident
  , jobWorkGrantedScratch
  , jobWorkJob
  , jobWorkRegion
  , jobWorkResident
  , jobWorkScratch
  , jobWorkSlots
  , preparationRemoval
  , preparationRequest
  , preparationResident
  , runningHolds
  , runningJobs
  , runningPreparation
  , runningViews
  )
import Hetoimasia.Terrain.Segment (maxSegmentLevels)

-- | The unit prices the design states for records the service keeps (P-5 and the #639
-- accounting: a command record 128 bytes and 32 a region, an interest 64, a hold record
-- 64 a region, a view description 128 and 64 a region, a removal's retained edit 64, 16 for
-- the interval and 48 for the column entry, and its staging 512). They are literals here,
-- stated from the design, and not the model's own functions: the expected side of every
-- comparison below names no model accessor and no cost function.
commandRecord, descriptionOf ∷ Word64 → Word64
commandRecord n = 128 + 32 * n
descriptionOf n = 128 + 64 * n

interestRecord, holdRecord, removalRetained, removalStaging, resultRecord ∷ Word64
interestRecord = 64
holdRecord = 64
removalRetained = 64
removalStaging = 512
-- | The retained bank's record for each request the service holds (the design's figure for a
-- result or record not charged elsewhere).
resultRecord = 160

-- | The most a whole-cell removal can raise the payload of the segment it edits: a dense
-- segment of 'maxSegmentLevels' cells is two bytes a cell, a uniform one two bytes in
-- all. The model reserves exactly this for each removal.
removalGrowthBound ∷ Word64
removalGrowthBound = 2 * fromIntegral maxSegmentLevels - 2

-- ---------------------------------------------------------------------------
-- What the service holds

data HeldArena = HeldArena
  { haArena ∷ ArenaId
  , haRetiring ∷ Bool
  , haRegionBytes ∷ Map RegionCoord Word64
  , haRetained ∷ Word64
  }

data HeldRequest = HeldRequest
  { hrRegions ∷ Int
  , hrRemoval ∷ Bool
  , hrModelRecord ∷ Bool
  , -- | Settled, its result waiting to be taken.
    hrSettled ∷ Bool
  }

-- | An accepted load job: what the model granted it at admission (a stability check of the model
-- against itself, not an expectation), the least the owner's running of it holds (0 while it
-- waits) and the load-job slot it holds (1 while the owner runs it).
data HeldJob = HeldJob
  { hjJob ∷ JobId
  , hjArena ∷ ArenaId
  , hjRegion ∷ RegionCoord
  , hjGrantedResident ∷ Word64
  , hjGrantedScratch ∷ Word64
  , hjResident ∷ Word64
  , hjScratch ∷ Word64
  , hjSlots ∷ Word64
  }


-- | The preparation the owner is running: the request, and for a removal the resident
-- growth its buffers can hold.
data HeldPreparation = HeldPreparation
  { hpRequest ∷ RequestId
  , hpRemoval ∷ Bool
  , hpGrowth ∷ Word64
  }

data Held = Held
  { heldArenas ∷ [HeldArena]
  , heldRequests ∷ [HeldRequest]
  , heldBorrows ∷ Int
  , heldJobs ∷ [HeldJob]
  , heldPreparation ∷ Maybe HeldPreparation
  , -- | Each outstanding borrow, the regions its snapshot covers and the accounted bytes it
    -- backs, both read from the snapshot value when it was handed out (never from the
    -- retained-bank ledger or the model's hold).
    heldHolds ∷ [(HoldId, Word64, Word64)]
  , -- | Each view with an accepted demand and the regions it describes.
    heldViews ∷ [(ViewId, Word64)]
  }

-- | The service's own census as plain data.
heldOf ∷ Census → Held
heldOf census =
  Held
    { heldArenas = [HeldArena (censusArena a) (censusRetiring a) (censusRegionBytes a) (censusRetainedBytes a) | a ← censusArenas census]
    , heldRequests = [HeldRequest (censusRegions r) (censusRemoval r) (censusModelRecord r) (censusSettled r) | r ← censusRequests census]
    , heldBorrows = censusBorrows census
    , heldJobs = [HeldJob (jobWorkJob j) (jobWorkArena j) (jobWorkRegion j) (jobWorkGrantedResident j) (jobWorkGrantedScratch j) (jobWorkResident j) (jobWorkScratch j) (jobWorkSlots j) | j ← runningJobs running]
    , heldPreparation = (\p → HeldPreparation (preparationRequest p) (preparationRemoval p) (preparationResident p)) <$> runningPreparation running
    , heldHolds = runningHolds running
    , heldViews = runningViews running
    }
  where
    running = censusRunning census

-- ---------------------------------------------------------------------------
-- What the model charges

-- | A load job as the model charges it: its phase and what it reserves and holds.
data ChargedJob = ChargedJob
  { cjJob ∷ JobId
  , cjArena ∷ ArenaId
  , cjRegion ∷ RegionCoord
  , cjPhase ∷ JobPhase
  , -- | Resident bytes reserved: active and still deferred.
    cjResident ∷ Word64
  , cjScratch ∷ Word64
  }

-- | A resident region as the model charges it, and its handoff duplicate if any.
data ChargedRegion = ChargedRegion
  { crArena ∷ ArenaId
  , crRegion ∷ RegionCoord
  , crBytes ∷ Word64
  , crEvicting ∷ Bool
  , crDuplicate ∷ Maybe Word64
  }

data Charged = Charged
  { cArenas ∷ [(ArenaId, Word64)]
  , cRegions ∷ [ChargedRegion]
  , cJobs ∷ [ChargedJob]
  , -- | Each request: whether it holds a removal's reservations and the resident growth it
    -- holds (active and deferred).
    cRequests ∷ [(RequestId, Bool, Word64)]
  , cResident ∷ Ledger
  , cEdit ∷ Ledger
  , cStaging ∷ Ledger
  , -- | Resident bytes promised but still waiting for victims, by jobs and by requests.
    cResidentDeferred ∷ Word64
  , -- | Staging held by the interests, holds and view descriptions the model keeps.
    cEntityStaging ∷ Word64
  , cCommandSlots ∷ Word64
  , cLoadSlots ∷ Word64
  , cBorrows ∷ Word64
  , -- | Each borrow's hold and the regions the model's record of it names.
    cHolds ∷ [(HoldId, Word64)]
  , -- | Each view and the regions in the description the model keeps for it.
    cViews ∷ [(ViewId, Word64)]
  , cViewPins ∷ Word64
  , -- | The retained bank's charge and each outstanding snapshot's charge, as the service
    -- accounts them ('withRetained'); absent when not read.
    cRetained ∷ Maybe (Word64, [(HoldId, Word64)])
  }

chargedOf ∷ Model → Charged
chargedOf m =
  Charged
    { cArenas = [(arenaId a, arenaRetainedBytes a) | a ← modelArenas m]
    , cRegions = [ChargedRegion (regionArena r) (regionCoord r) (regionBytes r) (regionEvicting r) (regionHandoff r) | r ← modelRegions m]
    , cJobs = [ChargedJob (jobId j) (jobArena j) (jobRegion j) (jobPhase j) (jobActive j + jobDeferred j) (jobScratch j) | j ← modelJobs m]
    , cRequests = [(requestId r, requestRemoval r, requestResidentActive r + requestResidentDeferred r) | r ← modelRequests m]
    , cResident = bankLedger m ResidentBank
    , cEdit = bankLedger m EditBank
    , cStaging = bankLedger m StagingBank
    , cResidentDeferred = sumW (map jobDeferred (modelJobs m)) + sumW (map requestResidentDeferred (modelRequests m))
    , cEntityStaging =
        len (modelInterests m) * interestRecord
          + sumW [len regions * holdRecord | (_, _, _, regions) ← modelHolds m]
          + sumW [descriptionOf (len (viewDemand v)) | v ← modelViews m]
    , cCommandSlots = slotInUse m CommandSlot
    , cLoadSlots = slotInUse m LoadJobSlot
    , cBorrows = len [() | (_, _, Borrow, _) ← modelHolds m]
    , cHolds = [(h, len regions) | (h, _, Borrow, regions) ← modelHolds m]
    , cViews = [(viewId v, len (viewDemand v)) | v ← modelViews m]
    , cViewPins = slotInUse m ViewPinSlot
    , cRetained = Nothing
    }

-- | The retained bank's charges, read from the service, added to the model's.
withRetained ∷ (Word64, [(HoldId, Word64)]) → Charged → Charged
withRetained charges c = c {cRetained = Just charges}

-- | Every disagreement, in one transaction: the service's census, the model and the retained
-- bank's charges, each read once.
usageSTM ∷ Service → STM [String]
usageSTM svc = do
  census <- inspectCensusSTM svc
  model <- inspectModelSTM svc
  retained <- inspectRetainedChargesSTM svc
  pure (disagreements (heldOf census) (withRetained retained (chargedOf model)))

sumW ∷ [Word64] → Word64
sumW = sum

len ∷ [a] → Word64
len = fromIntegral . length

-- ---------------------------------------------------------------------------
-- The comparison

-- | How a count is compared with what the service holds.
data Rule = Exact | AtLeast

-- | The census and the model, each as plain data, compared.
usageDisagreements ∷ Census → Model → [String]
usageDisagreements census m = disagreements (heldOf census) (chargedOf m)

-- | Every place a ledger, slot, arena or running entity is charged less than the service
-- holds (or, where the charge is exact, differently), and every record that exists on
-- one side only.
disagreements ∷ Held → Charged → [String]
disagreements h c =
  [ what <> ": the model counts " <> show counted <> " but the service holds " <> show held
  | (what, counted, held, rule) ← rows <> regionRows <> arenaRows
  , case rule of Exact → counted /= held; AtLeast → counted < held
  ]
    <> regionGaps
    <> [ "arena " <> show (haArena a) <> ": the service holds it (" <> (if haRetiring a then "retiring" else "live") <> ") but the model does not"
       | a ← heldArenas h
       , haArena a `notElem` map fst (cArenas c)
       ]
    <> [ "arena " <> show aid <> ": the model holds it but the service does not"
       | (aid, _) ← cArenas c
       , aid `notElem` map haArena (heldArenas h)
       ]
    <> concatMap jobDisagreements (heldJobs h)
    <> concatMap holdDisagreements (heldHolds h)
    <> concatMap viewDisagreements (heldViews h)
    -- the backed owner never transfers a region's changes (a commit retains nothing and confirms its
    -- zero-byte handoff in its decision): the model may charge no duplicate for any region
    <> [ "the model charges a handoff duplicate of " <> show d <> " bytes for " <> show (crArena r, crRegion r) <> " but the backed owner never transfers"
       | r ← cRegions c
       , Just d ← [crDuplicate r]
       ]
    <> maybe [] preparationDisagreements (heldPreparation h)
  where
    -- ===== EXPECTED SIDE: built from `h` (what the service holds) and the design's prices only =====
    -- (check: no model accessor, no ledger and no cost function of the residency model appears
    -- between this marker and the END marker; see the pull request body)
    -- What the service's requests hold in the model: one record each, and a removal's reservations.
    held' = [r | r ← heldRequests h, hrModelRecord r]
    removals = len [() | r ← held', hrRemoval r]
    -- The jobs the owner runs hold at least what the coverage they load needs.
    jobsResident = sumW (map hjResident (heldJobs h))
    jobsScratch = sumW (map hjScratch (heldJobs h))
    -- Resident detail, region by region: what the arena's detail itself holds there (a region's
    -- fixed metadata, an index entry per column and each segment).
    serviceRegions = [((haArena a, region), bytes) | a ← heldArenas h, (region, bytes) ← Map.toList (haRegionBytes a)]
    -- The request table's command records and, for each held request, one interest for each region
    -- it demands; each outstanding borrow's hold, one record for each region its snapshot covers;
    -- and each view's description. A camera demand's interests exist only
    -- in the model's own records, so they are not claimed here.
    recordsHeld = sumW [commandRecord (fromIntegral (hrRegions r)) | r ← held']
    stagingHeld =
      recordsHeld
        + sumW [fromIntegral (hrRegions r) * interestRecord | r ← held']
        + sumW [n * holdRecord | (_, n, _) ← heldHolds h]
        + sumW [descriptionOf n | (_, n) ← heldViews h]
    expectResidentOccupied = sumW (map snd serviceRegions)
    expectResidentGrowth = removals * removalGrowthBound
    expectResidentReserved = jobsResident + removals * removalGrowthBound
    expectEditOccupied = sumW (map haRetained (heldArenas h))
    expectEditReserved = removals * removalRetained
    expectStagingReserved = removals * removalStaging + jobsScratch
    expectCommandSlots = len held'
    expectLoadSlots = sumW (map hjSlots (heldJobs h))
    expectBorrows = fromIntegral (heldBorrows h) ∷ Word64
    -- The retained bank: the backing of every snapshot handed out and still borrowed (live or
    -- retiring incarnations alike: a hold ends only when its borrower releases it), and one record
    -- for each request the service holds except a settled read whose record the model charges.
    backingHeld = sumW [bytes | (_, _, bytes) ← heldHolds h]
    expectRetained = backingHeld + resultRecord * len [() | r ← heldRequests h, not (hrSettled r && hrModelRecord r)]
    -- ===== END EXPECTED SIDE =====
    modelGrowth = sumW [g | (_, _, g) ← cRequests c]
    modelRegionBytes = Map.fromList [((crArena r, crRegion r), (crBytes r, crEvicting r)) | r ← cRegions c]
    -- A region the owner has discarded but the model has not yet released (it is evicting) is
    -- still charged until its victim is released.
    regionRows =
      [ ("resident bytes of region " <> show key <> ": the model", modelBytes, bytes, AtLeast)
      | (key, bytes) ← serviceRegions
      , Just (modelBytes, _) ← [Map.lookup key modelRegionBytes]
      ]
    regionGaps =
      [ "region " <> show key <> " holds " <> show bytes <> " bytes in the service but the model has no record of it"
      | (key, bytes) ← serviceRegions
      , not (Map.member key modelRegionBytes)
      ]
        <> [ "region " <> show key <> " is charged " <> show bytes <> " bytes by the model (not evicting) but the service holds none of it"
           | (key, (bytes, False)) ← Map.toList modelRegionBytes
           , key `notElem` map fst serviceRegions
           ]
    -- Each arena's retained changes, live or retiring, against the arena's own charge.
    arenaRows =
      [ ("retained bytes of arena " <> show (haArena a) <> ": the model", charged, haRetained a, AtLeast)
      | a ← heldArenas h
      , (aid, charged) ← cArenas c
      , aid == haArena a
      ]
    rows =
      [ ("resident bank occupied (every arena's resident detail, retiring included)", ledgerOccupied (cResident c), expectResidentOccupied, AtLeast)
      , ("resident growth reserved for the removals the service holds (each at least the worst case of a segment)", modelGrowth, expectResidentGrowth, AtLeast)
      , -- Reserved and deferred together: the running jobs' reservations and the removals' growth,
        -- however much of it still waits for victims.
        ("resident bank reserved (the running jobs' reservations and the removals' growth)", ledgerReserved (cResident c) + cResidentDeferred c, expectResidentReserved, AtLeast)
      , ("edit bank occupied (every arena's retained changes, retiring included)", ledgerOccupied (cEdit c), expectEditOccupied, AtLeast)
      , ("edit bank reserved by removals", ledgerReserved (cEdit c), expectEditReserved, Exact)
      , ("staging bank occupied (request records and interests, borrows, view descriptions, from the service)", ledgerOccupied (cStaging c), stagingHeld, AtLeast)
      , -- The ledger against the model's own entity lists (interests, holds, views, camera interests
        -- included): consistency of the model with itself, not an independent expectation.
        ("staging bank occupied (the ledger against the model's own entities)", ledgerOccupied (cStaging c), recordsHeld + cEntityStaging c, Exact)
      , ("staging bank reserved (each removal's staging reservation and the running jobs' scratch)", ledgerReserved (cStaging c), expectStagingReserved, AtLeast)
      , ("command slots (every request the service holds a model record for)", cCommandSlots c, expectCommandSlots, Exact)
      , ("load-job slots (every job the owner is running)", cLoadSlots c, expectLoadSlots, AtLeast)
      , ("snapshot holds", cBorrows c, expectBorrows, Exact)
      , ("view pin slots (the service never pins a view's revision)", cViewPins c, 0, Exact)
      ]
        <> [ ("retained bank (outstanding snapshots' backing and the request records)", used, expectRetained, AtLeast)
           | Just (used, _) ← [cRetained c]
           ]
    -- Every accepted job is charged, in its own amounts, for as long as the model holds it: a
    -- running job the model has forgotten, or any job charged less than it was granted (or
    -- less than its coverage can hold), is under-charged.
    jobDisagreements j = case [x | x ← cJobs c, cjJob x == hjJob j] of
      [] →
        [ "the owner runs the job for " <> show (hjArena j, hjRegion j) <> " but the model holds no such job"
        | hjSlots j > 0
        ]
      x : _ →
        -- what the owner's running of it holds (the expectation) ...
        [ "job " <> show (hjArena j, hjRegion j) <> " " <> what <> " (what its coverage holds): the model counts " <> show counted <> " but the service holds " <> show held
        | hjSlots j > 0
        , (what, counted, held) ← [("resident reservation", cjResident x, hjResident j), ("scratch", cjScratch x, hjScratch j)]
        , counted < held
        ]
          -- ... and, for every accepted job, running or waiting, the model against its own grant: a
          -- charge reduced while the job still holds the reservation (stability, not an expectation).
          <> [ "job " <> show (hjArena j, hjRegion j) <> " " <> what <> " (as granted at admission): the model counts " <> show counted <> " but granted " <> show held
             | (what, counted, held) ← [("resident reservation", cjResident x, hjGrantedResident j), ("scratch", cjScratch x, hjGrantedScratch j)]
             , counted < held
             ]
    -- Each borrow's hold covers the regions of its snapshot.
    holdDisagreements (hid, n, bytes) =
      ( case lookup hid (cHolds c) of
          Nothing → ["the service lends a snapshot of " <> show n <> " regions (" <> show hid <> ") but the model holds no such borrow"]
          Just charged
            | charged < n → ["hold " <> show hid <> ": the model names " <> show charged <> " regions but the snapshot covers " <> show n]
            | otherwise → []
      )
        <> case cRetained c of
          Nothing → []
          Just (_, perSnapshot) → case lookup hid perSnapshot of
            Nothing → ["the service lends a snapshot backing " <> show bytes <> " bytes (" <> show hid <> ") but the retained bank charges nothing for it"]
            Just charged
              | charged < bytes → ["snapshot " <> show hid <> " backing: the retained bank charges " <> show charged <> " but the snapshot backs " <> show bytes]
              | otherwise → []
    -- Each view's description names the regions of the accepted demand.
    viewDisagreements (vid, n) = case lookup vid (cViews c) of
      Nothing → ["the service accepted a demand of " <> show n <> " regions for " <> show vid <> " but the model holds no view"]
      Just charged
        | charged < n → ["view " <> show vid <> ": the model's description names " <> show charged <> " regions but the accepted demand describes " <> show n]
        | otherwise → []
    -- While the owner prepares a request, the model still holds its record and credits.
    preparationDisagreements p = case [(removal, growth) | (rid, removal, growth) ← cRequests c, rid == hpRequest p] of
      [] → ["the owner is preparing request " <> show (hpRequest p) <> " but the model holds no record of it"]
      (removal, growth) : _ →
        [ "the owner is preparing a removal " <> show (hpRequest p) <> " but the model holds no removal reservation for it"
        | hpRemoval p
        , not removal
        ]
          <> [ "preparation of " <> show (hpRequest p) <> " resident growth: the model counts " <> show growth <> " but the service holds " <> show (hpGrowth p)
             | hpRemoval p
             , growth < hpGrowth p
             ]

-- | What must hold while the owner is about to run a load job for a region: the owner
-- recorded the job it runs (with its slot and its reservation and scratch from its
-- coverage), and every bank, slot and arena still covers what the service holds,
-- that job in its own amounts.
jobStartDisagreements ∷ Census → Model → ArenaId → RegionCoord → [String]
jobStartDisagreements census m arena region =
  [ "the owner is about to run the job for " <> show (arena, region) <> " but it is not recorded as running"
  | null recorded
  ]
    <> [ what <> " of the recorded job is zero"
       | j ← recorded
       , (what, n) ← [("resident reservation", hjResident j), ("scratch", hjScratch j), ("slot", hjSlots j)]
       , n == 0
       ]
    <> usageDisagreements census m
  where
    recorded = [j | j ← heldJobs (heldOf census), hjArena j == arena, hjRegion j == region, hjSlots j > 0]
