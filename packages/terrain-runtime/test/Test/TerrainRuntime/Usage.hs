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
module Test.TerrainRuntime.Usage (usageDisagreements) where

import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime (ArenaCensus (..), Census (..), RequestCensus (..))

-- | Every place a ledger or slot count differs from what the service holds.
usageDisagreements ∷ Census → Model → [String]
usageDisagreements census m =
  [ what <> ": the model counts " <> show counted <> " but the service holds " <> show held <> (if slack == 0 then "" else " (the model may exceed it by at most " <> show slack <> ")")
  | (what, counted, held, slack) ← rows <> regionRows
  , counted < held || counted > held + slack
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
    -- A removal's resident growth is a model constant the model does not export; what is
    -- checked is that none is held for a removal the service no longer holds.
    removalGrowth = if removals == 0 then 0 else modelGrowth
    modelGrowth = sumW (map requestResidentActive (modelRequests m)) + sumW (map requestResidentDeferred (modelRequests m))
    -- Resident detail, region by region: what the arena's detail itself holds there (a
    -- region's fixed metadata, an index entry per column and each segment) against what
    -- the model charges for that region. A region the owner has discarded but the model
    -- has not yet released (it is evicting) is charged until its victim is released.
    serviceRegions = [((censusArena a, region), bytes) | a ← censusArenas census, (region, bytes) ← Map.toList (censusRegionBytes a)]
    modelRegionBytes = Map.fromList [((regionArena r, regionCoord r), (regionBytes r, regionEvicting r)) | r ← modelRegions m]
    modelGenerations = Map.fromList [((regionArena r, regionCoord r), regionGeneration r) | r ← modelRegions m]
    -- The model reserves a removal's growth at its worst case and keeps a conservative
    -- charge once it commits, so a region that has had removals may be charged a little
    -- above what its detail holds (at most the worst case of a segment's payload, 64
    -- bytes, per removal); a region with none is charged exactly what it holds.
    slackOf key = 64 * Map.findWithDefault 0 key modelGenerations
    regionRows =
      [ ("resident bytes of region " <> show key <> ": the model", modelBytes, bytes, slackOf key)
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
    resident = sumW (map snd serviceRegions) + sumW [bytes | (key, (bytes, True)) ← Map.toList modelRegionBytes, key `notElem` map fst serviceRegions]
    rows =
      [ ("resident bank occupied (every arena's resident detail, retiring included)", ledgerOccupied (ledger ResidentBank), resident, sumW [slackOf key | (key, _) ← serviceRegions])
      , ("resident growth reserved for removals the service holds", modelGrowth, removalGrowth, 0)
      , ("edit bank occupied (every arena's retained changes, retiring included)", ledgerOccupied (ledger EditBank), sumW (map censusRetainedBytes (censusArenas census)), 0)
      , ("edit bank reserved by removals", ledgerReserved (ledger EditBank), removals * removalRetainedBytes, 0)
      ,
        ( "staging bank occupied"
        , ledgerOccupied (ledger StagingBank)
        , sumW [commandRecordBytes (fromIntegral (censusRegions r)) | r ← held']
            + len (modelInterests m) * interestRecordBytes
            + sumW [len regions * holdRecordBytes | (_, _, _, regions) ← modelHolds m]
            + sumW [descriptionBytes (len (viewDemand v)) | v ← modelViews m]
            + sumW [d | Just d ← map regionHandoff (modelRegions m)]
        , 0
        )
      , ("staging bank reserved", ledgerReserved (ledger StagingBank), sumW (map jobScratch (modelJobs m)) + removals * removalStagingBytes, 0)
      , ("command slots (every request the service holds a model record for)", slotInUse m CommandSlot, len held', 0)
      , ("snapshot holds", len [() | (_, _, Borrow, _) ← modelHolds m], fromIntegral (censusBorrows census), 0)
      ]
