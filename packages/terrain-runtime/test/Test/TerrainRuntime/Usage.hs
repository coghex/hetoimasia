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
--   scratch and slot, the preparation, each handoff duplicate), written where that work
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
  , HeldHandoff (..)
  , Charged (..)
  , ChargedJob (..)
  , ChargedRegion (..)
  , heldOf
  , chargedOf
  , disagreements
  , usageDisagreements
  , jobStartDisagreements
  , removalGrowthBound
  ) where

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
  , handoffWorkArena
  , handoffWorkDuplicate
  , handoffWorkRegion
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
  , runningHandoffs
  , runningHolds
  , runningJobs
  , runningPreparation
  , runningViews
  )
import Hetoimasia.Terrain.Segment (maxSegmentLevels)

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
  }

-- | An accepted load job: what the model granted it, the least its coverage can hold, and
-- the load-job slot it holds (1 while the owner runs it).
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

-- | The most the job must be charged: what it was granted or, if that was too little,
-- what its coverage can hold.
hjMustResident, hjMustScratch ∷ HeldJob → Word64
hjMustResident j = max (hjGrantedResident j) (hjResident j)
hjMustScratch j = max (hjGrantedScratch j) (hjScratch j)

-- | The preparation the owner is running: the request, and for a removal the resident
-- growth its buffers can hold.
data HeldPreparation = HeldPreparation
  { hpRequest ∷ RequestId
  , hpRemoval ∷ Bool
  , hpGrowth ∷ Word64
  }

data HeldHandoff = HeldHandoff
  { hhArena ∷ ArenaId
  , hhRegion ∷ RegionCoord
  , hhDuplicate ∷ Word64
  }

data Held = Held
  { heldArenas ∷ [HeldArena]
  , heldRequests ∷ [HeldRequest]
  , heldBorrows ∷ Int
  , heldJobs ∷ [HeldJob]
  , heldPreparation ∷ Maybe HeldPreparation
  , heldHandoffs ∷ [HeldHandoff]
  , -- | Each outstanding borrow and the regions its snapshot covers.
    heldHolds ∷ [(HoldId, Word64)]
  , -- | Each view with an accepted demand and the regions it describes.
    heldViews ∷ [(ViewId, Word64)]
  }

-- | The service's own census as plain data.
heldOf ∷ Census → Held
heldOf census =
  Held
    { heldArenas = [HeldArena (censusArena a) (censusRetiring a) (censusRegionBytes a) (censusRetainedBytes a) | a ← censusArenas census]
    , heldRequests = [HeldRequest (censusRegions r) (censusRemoval r) (censusModelRecord r) | r ← censusRequests census]
    , heldBorrows = censusBorrows census
    , heldJobs = [HeldJob (jobWorkJob j) (jobWorkArena j) (jobWorkRegion j) (jobWorkGrantedResident j) (jobWorkGrantedScratch j) (jobWorkResident j) (jobWorkScratch j) (jobWorkSlots j) | j ← runningJobs running]
    , heldPreparation = (\p → HeldPreparation (preparationRequest p) (preparationRemoval p) (preparationResident p)) <$> runningPreparation running
    , heldHandoffs = [HeldHandoff (handoffWorkArena h) (handoffWorkRegion h) (handoffWorkDuplicate h) | h ← runningHandoffs running]
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
        len (modelInterests m) * interestRecordBytes
          + sumW [len regions * holdRecordBytes | (_, _, _, regions) ← modelHolds m]
          + sumW [descriptionBytes (len (viewDemand v)) | v ← modelViews m]
    , cCommandSlots = slotInUse m CommandSlot
    , cLoadSlots = slotInUse m LoadJobSlot
    , cBorrows = len [() | (_, _, Borrow, _) ← modelHolds m]
    , cHolds = [(h, len regions) | (h, _, Borrow, regions) ← modelHolds m]
    , cViews = [(viewId v, len (viewDemand v)) | v ← modelViews m]
    }

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
    <> concatMap handoffDisagreements (heldHandoffs h)
    <> maybe [] preparationDisagreements (heldPreparation h)
  where
    -- What the service's requests hold in the model: one record each, and a removal's
    -- reservations.
    held' = [r | r ← heldRequests h, hrModelRecord r]
    removals = len [() | r ← held', hrRemoval r]
    -- Every accepted job, running or not, must be charged what it was granted, or what its
    -- coverage can hold if that is more.
    jobsResident = sumW (map hjMustResident (heldJobs h))
    jobsScratch = sumW (map hjMustScratch (heldJobs h))
    jobSlots = sumW (map hjSlots (heldJobs h))
    duplicates = sumW (map hhDuplicate (heldHandoffs h))
    -- What the staging bank must hold for records the service itself keeps: the request
    -- table's command records and, for each held request, one interest for each region
    -- it demands; each outstanding borrow's hold, one record for each region its snapshot
    -- covers; each view's description; and the owner's duplicates. A camera demand's
    -- interests exist only in the model's own records, so they are not claimed here.
    stagingHeld =
      sumW [commandRecordBytes (fromIntegral (hrRegions r)) + fromIntegral (hrRegions r) * interestRecordBytes | r ← held']
        + sumW [n * holdRecordBytes | (_, n) ← heldHolds h]
        + sumW [descriptionBytes n | (_, n) ← heldViews h]
        + duplicates
    modelGrowth = sumW [g | (_, _, g) ← cRequests c]
    -- Resident detail, region by region: what the arena's detail itself holds there (a
    -- region's fixed metadata, an index entry per column and each segment) against what
    -- the model charges for that region. A region the owner has discarded but the model
    -- has not yet released (it is evicting) is still charged until its victim is released.
    serviceRegions = [((haArena a, region), bytes) | a ← heldArenas h, (region, bytes) ← Map.toList (haRegionBytes a)]
    modelRegionBytes = Map.fromList [((crArena r, crRegion r), (crBytes r, crEvicting r)) | r ← cRegions c]
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
    resident = sumW (map snd serviceRegions)
    -- Each arena's retained changes, live or retiring, against the arena's own charge.
    arenaRows =
      [ ("retained bytes of arena " <> show (haArena a) <> ": the model", charged, haRetained a, AtLeast)
      | a ← heldArenas h
      , (aid, charged) ← cArenas c
      , aid == haArena a
      ]
    rows =
      [ ("resident bank occupied (every arena's resident detail, retiring included)", ledgerOccupied (cResident c), resident, AtLeast)
      , ("resident growth reserved for the removals the service holds (each at least the worst case of a segment)", modelGrowth, removals * removalGrowthBound, AtLeast)
      , -- Reserved and deferred together: the jobs' reservations (what their coverage can store)
        -- and the removals' growth, however much of it still waits for victims.
        ("resident bank reserved (every accepted job's reservation and the removals' growth)", ledgerReserved (cResident c) + cResidentDeferred c, jobsResident + removals * removalGrowthBound, AtLeast)
      , ("edit bank occupied (every arena's retained changes, retiring included)", ledgerOccupied (cEdit c), sumW (map haRetained (heldArenas h)), AtLeast)
      , ("edit bank reserved by removals", ledgerReserved (cEdit c), removals * removalRetainedBytes, Exact)
      , -- Independent: what the service's own records need.
        ("staging bank occupied (request records and interests, borrows, view descriptions, duplicates, from the service)", ledgerOccupied (cStaging c), stagingHeld, AtLeast)
      , -- The ledger against the model's own entity lists (interests, holds, views, camera interests
        -- included): consistency of the model with itself, not an independent expectation.
        ( "staging bank occupied (the ledger against the model's own entities)"
        , ledgerOccupied (cStaging c)
        , sumW [commandRecordBytes (fromIntegral (hrRegions r)) | r ← held'] + cEntityStaging c + duplicates
        , Exact
        )
      , ("staging bank reserved (each removal's staging reservation and every accepted job's scratch)", ledgerReserved (cStaging c), removals * removalStagingBytes + jobsScratch, AtLeast)
      , ("command slots (every request the service holds a model record for)", cCommandSlots c, len held', Exact)
      , ("load-job slots (every job the owner is running)", cLoadSlots c, jobSlots, AtLeast)
      , ("snapshot holds", cBorrows c, fromIntegral (heldBorrows h), Exact)
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
        [ "job " <> show (hjArena j, hjRegion j) <> " " <> what <> ": the model counts " <> show counted <> " but the service holds " <> show held
        | (what, counted, held) ← [("resident reservation", cjResident x, hjMustResident j), ("scratch", cjScratch x, hjMustScratch j)]
        , counted < held
        ]
    -- Each borrow's hold covers the regions of its snapshot.
    holdDisagreements (hid, n) = case lookup hid (cHolds c) of
      Nothing → ["the service lends a snapshot of " <> show n <> " regions (" <> show hid <> ") but the model holds no such borrow"]
      Just charged
        | charged < n → ["hold " <> show hid <> ": the model names " <> show charged <> " regions but the snapshot covers " <> show n]
        | otherwise → []
    -- Each view's description names the regions of the accepted demand.
    viewDisagreements (vid, n) = case lookup vid (cViews c) of
      Nothing → ["the service accepted a demand of " <> show n <> " regions for " <> show vid <> " but the model holds no view"]
      Just charged
        | charged < n → ["view " <> show vid <> ": the model's description names " <> show charged <> " regions but the accepted demand describes " <> show n]
        | otherwise → []
    -- The duplicate the owner holds while it transfers a region is charged to staging.
    handoffDisagreements d = case [r | r ← cRegions c, crArena r == hhArena d, crRegion r == hhRegion d] of
      [] → ["the owner holds a duplicate for " <> show (hhArena d, hhRegion d) <> " but the model holds no such region"]
      r : _ → case crDuplicate r of
        Nothing → ["the owner holds a duplicate of " <> show (hhDuplicate d) <> " bytes for " <> show (hhArena d, hhRegion d) <> " but the model charges none"]
        Just charged
          | charged < hhDuplicate d → ["handoff duplicate of " <> show (hhArena d, hhRegion d) <> ": the model counts " <> show charged <> " but the service holds " <> show (hhDuplicate d)]
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
       , (what, n) ← [("resident reservation", hjMustResident j), ("scratch", hjMustScratch j), ("slot", hjSlots j)]
       , n == 0
       ]
    <> usageDisagreements census m
  where
    recorded = [j | j ← heldJobs (heldOf census), hjArena j == arena, hjRegion j == region, hjSlots j > 0]
