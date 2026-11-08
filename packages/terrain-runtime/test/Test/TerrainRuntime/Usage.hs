-- | What every bank and slot of the accounting model must hold, stated from what the
-- service itself holds and not from the model's own fields.
--
-- The service's census (`inspectCensusSTM`) is read from its own data structures: the
-- bytes of each arena's resident detail and retained changes, live or retiring, taken
-- from the detail itself; the regions that detail covers; every request it holds,
-- withdrawn ones included, and whether it holds a removal reservation; and its
-- outstanding snapshots. The expectation below is built from that, plus the few
-- entities that exist only in the model (the load jobs the model dispatches, interests,
-- hold and view records, and a transfer's duplicate), taken from the model's own entity
-- lists. If a model record disappears while the service still holds the resource, the
-- two disagree: that is the point.
module Test.TerrainRuntime.Usage (usageDisagreements, jobRunningDisagreements) where

import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Coordinate (RegionCoord)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime (ArenaCensus (..), Census (..), RequestCensus (..))
import Hetoimasia.Terrain.Segment (maxSegmentLevels)

-- | How a count is compared with what the service holds.
data Rule = Exact | AtLeast

-- | The most a whole-cell removal can raise the payload of the segment it edits: a dense
-- segment of 'maxSegmentLevels' cells is two bytes a cell, a uniform one two bytes in
-- all. The model reserves exactly this for each removal.
removalGrowthBound ∷ Word64
removalGrowthBound = 2 * fromIntegral maxSegmentLevels - 2

-- | Every place a ledger, slot or arena is charged less than the service holds (or, where
-- the charge is exact, differently), and every record that exists on one side only.
usageDisagreements ∷ Census → Model → [String]
usageDisagreements census m =
  [ what <> ": the model counts " <> show counted <> " but the service holds " <> show held
  | (what, counted, held, rule) ← rows <> regionRows <> arenaRows
  , case rule of Exact → counted /= held; AtLeast → counted < held
  ]
    <> regionGaps
    <> [ "arena " <> show (censusArena a) <> ": the service holds it (" <> (if censusRetiring a then "retiring" else "live") <> ") but the model does not"
       | a ← censusArenas census
       , censusArena a `notElem` map arenaId (modelArenas m)
       ]
    <> [ "arena " <> show (arenaId info) <> ": the model holds it but the service does not"
       | info ← modelArenas m
       , arenaId info `notElem` map censusArena (censusArenas census)
       ]
  where
    sumW ∷ [Word64] → Word64
    sumW = sum
    len ∷ [a] → Word64
    len = fromIntegral . length
    ledger bank = bankLedger m bank
    -- What the service's requests hold in the model: one record each, and a removal's
    -- reservations.
    held' = [r | r ← censusRequests census, censusModelRecord r]
    removals = len [() | r ← held', censusRemoval r]
    modelGrowth = sumW (map requestResidentActive (modelRequests m)) + sumW (map requestResidentDeferred (modelRequests m))
    -- Resident detail, region by region: what the arena's detail itself holds there (a
    -- region's fixed metadata, an index entry per column and each segment) against what
    -- the model charges for that region. A region the owner has discarded but the model
    -- has not yet released (it is evicting) is still charged until its victim is released.
    serviceRegions = [((censusArena a, region), bytes) | a ← censusArenas census, (region, bytes) ← Map.toList (censusRegionBytes a)]
    modelRegionBytes = Map.fromList [((regionArena r, regionCoord r), (regionBytes r, regionEvicting r)) | r ← modelRegions m]
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
      [ ("retained bytes of arena " <> show (censusArena a) <> ": the model", arenaRetainedBytes info, censusRetainedBytes a, AtLeast)
      | a ← censusArenas census
      , info ← modelArenas m
      , arenaId info == censusArena a
      ]
    rows =
      [ ("resident bank occupied (every arena's resident detail, retiring included)", ledgerOccupied (ledger ResidentBank), resident, AtLeast)
      , ("resident growth reserved for the removals the service holds (each at least the worst case of a segment)", modelGrowth, removals * removalGrowthBound, AtLeast)
      , ("edit bank occupied (every arena's retained changes, retiring included)", ledgerOccupied (ledger EditBank), sumW (map censusRetainedBytes (censusArenas census)), AtLeast)
      , ("edit bank reserved by removals", ledgerReserved (ledger EditBank), removals * removalRetainedBytes, Exact)
      ,
        ( "staging bank occupied"
        , ledgerOccupied (ledger StagingBank)
        , sumW [commandRecordBytes (fromIntegral (censusRegions r)) | r ← held']
            + len (modelInterests m) * interestRecordBytes
            + sumW [len regions * holdRecordBytes | (_, _, _, regions) ← modelHolds m]
            + sumW [descriptionBytes (len (viewDemand v)) | v ← modelViews m]
            + sumW [d | Just d ← map regionHandoff (modelRegions m)]
        , Exact
        )
      , ("staging bank reserved (each removal's staging reservation, beside the jobs' scratch)", ledgerReserved (ledger StagingBank), removals * removalStagingBytes, AtLeast)
      , ("command slots (every request the service holds a model record for)", slotInUse m CommandSlot, len held', Exact)
      , ("snapshot holds", len [() | (_, _, Borrow, _) ← modelHolds m], fromIntegral (censusBorrows census), Exact)
      ]

-- | What must hold while the owner is about to run a load job for a region: the model
-- still holds that job as running, with its slot and its resident and staging
-- reservations. The owner running the work is the service's own fact; a model that has
-- already forgotten the job is under-charging it.
jobRunningDisagreements ∷ Model → ArenaId → RegionCoord → [String]
jobRunningDisagreements m arena region =
  [ "the owner is about to run the job for " <> show (arena, region) <> " but the model holds no running (or cancelling) job for it (its jobs: " <> show [jobPhase j | j ← modelJobs m, jobArena j == arena, jobRegion j == region] <> ")"
  | null running
  ]
    <> [ what <> ": the owner runs a job but the model counts " <> show counted
       | (what, counted) ←
           [ ("load-job slots", slotInUse m LoadJobSlot)
           , ("resident bank reserved", ledgerReserved (bankLedger m ResidentBank))
           , ("staging bank reserved", ledgerReserved (bankLedger m StagingBank))
           ]
       , counted == 0
       ]
  where
    -- A job cancelled while it waited for its turn still holds its slot and credits until
    -- the owner acknowledges it.
    running = [j | j ← modelJobs m, jobArena j == arena, jobRegion j == region, jobPhase j `elem` [JobRunningPhase, JobCancellingPhase]]
