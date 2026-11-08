-- | An independent statement of what every bank and slot of the accounting model must
-- hold, derived only from the entities that hold resources: the arenas (live and
-- retiring), regions, jobs, requests (and what a removal reserves), interests, holds
-- (snapshot borrows and pins), views and handed-off duplicates. It shares no code with
-- the model's own ledger, so a resource a ledger forgets to count, or counts for an
-- entity that no longer exists, is a disagreement.
module Test.TerrainRuntime.Usage (usageDisagreements) where

import Data.Word (Word64)
import Hetoimasia.Terrain.Residency

-- | Every place a ledger or slot count differs from the entities' own sum, and every
-- entity that belongs to no arena the model still holds.
usageDisagreements ∷ Model → [String]
usageDisagreements m =
  [ what <> ": the model counts " <> show counted <> " but the entities hold " <> show held
  | (what, counted, held) ← rows
  , counted /= held
  ]
    <> [ "a " <> kind <> " of arena " <> show a <> " outlives every arena the model holds"
       | (kind, a) ← owners
       , a `notElem` arenas
       ]
  where
    arenas = map arenaId (modelArenas m)
    removals = fromIntegral (length [() | r ← modelRequests m, requestRemoval r]) ∷ Word64
    sumW ∷ [Word64] → Word64
    sumW = sum
    len ∷ [a] → Word64
    len = fromIntegral . length
    ledger bank = bankLedger m bank
    rows =
      [ ("resident bank occupied", ledgerOccupied (ledger ResidentBank), sumW (map regionBytes (modelRegions m)))
      , ("resident bank reserved", ledgerReserved (ledger ResidentBank), sumW (map jobActive (modelJobs m)) + sumW (map requestResidentActive (modelRequests m)))
      , ("edit bank occupied (every arena, retiring included)", ledgerOccupied (ledger EditBank), sumW (map arenaRetainedBytes (modelArenas m)))
      , ("edit bank reserved", ledgerReserved (ledger EditBank), removals * removalRetainedBytes)
      ,
        ( "staging bank occupied"
        , ledgerOccupied (ledger StagingBank)
        , sumW [commandRecordBytes (len (requestRegions r)) | r ← modelRequests m]
            + len (modelInterests m) * interestRecordBytes
            + sumW [len regions * holdRecordBytes | (_, _, _, regions) ← modelHolds m]
            + sumW [descriptionBytes (len (viewDemand v)) | v ← modelViews m]
            + sumW [d | Just d ← map regionHandoff (modelRegions m)]
        )
      , ("staging bank reserved", ledgerReserved (ledger StagingBank), sumW (map jobScratch (modelJobs m)) + removals * removalStagingBytes)
      , ("command slots", slotInUse m CommandSlot, len (modelRequests m))
      , ("load-job slots", slotInUse m LoadJobSlot, len [() | j ← modelJobs m, jobPhase j == JobRunningPhase || jobPhase j == JobCancellingPhase])
      ]
    owners =
      [("region", regionArena r) | r ← modelRegions m]
        <> [("job", jobArena j) | j ← modelJobs m]
        <> [("request", requestArena r) | r ← modelRequests m]
        <> [("hold", a) | (_, a, _, _) ← modelHolds m]
        <> [("view", viewArena v) | v ← modelViews m]
        <> [("interest", interestArena i) | i ← modelInterests m]
