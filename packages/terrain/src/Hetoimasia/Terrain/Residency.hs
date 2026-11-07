-- | The pure residency and admission model of the terrain arena arc (TRA-3).
--
-- The model decides; it performs nothing. 'step' takes a 'Model' and an
-- 'Event' and returns the next model with either a 'Refusal' or a 'Report'.
-- A refusal returns the model it was given, byte for byte. There is no worker,
-- no mutable registry, no STM or IO and no Lua or graphics dependency, and the
-- model is not a second authority for terrain contents: it tracks which regions
-- are known, what they cost and who needs them, and the data layer
-- ("Hetoimasia.Terrain.Resident", "Hetoimasia.Terrain.Changes") stays the only
-- place terrain values live.
--
-- == State, ownership and lifetime
--
-- A 'Model' is an immutable value. The later terrain service (TRA-4) owns the
-- one current value on its single owner thread, feeds it events in the order it
-- performs the corresponding effects, and carries out each decision: it
-- discards the detail of every victim a decision names and then reports
-- 'VictimReleased', runs the job a 'Dispatched' decision names and reports
-- 'JobCompleted' with the cost it actually stored, and so on. Arena
-- incarnations, content revisions, request, view and hold identities are
-- supplied by that owner and never reused; the model allocates only job
-- numbers (checked, never wrapped). Time is logical: an event counter orders
-- least-recently-used choices and aging, and no deadline or clock is read.
--
-- == Banks, slots and who is charged
--
-- Three byte banks and three counted slots are service-wide, never multiplied
-- per arena. Every cost category belongs to exactly one:
--
-- * 'ResidentBank' (64 MiB): region metadata (256 bytes for each resident
--   region, however little of it is known), segment metadata (32 bytes each),
--   sparse column indexes (48 bytes each) and packed payload.
-- * 'EditBank' (32 MiB): retained session edits (16 bytes for each removed
--   interval and 48 for each column index entry, as "Hetoimasia.Terrain.Changes"
--   accounts them), reserved before a removal and kept for the arena's life.
-- * 'StagingBank' (64 MiB): load scratch, interest and hold records, accepted
--   command records, the pending latest-value camera description of each view,
--   removal staging and the temporary duplicate of a handoff.
-- * 'LoadJobSlot' (128), 'CommandSlot' (256 accepted, unsettled commands) and
--   'ViewPinSlot' (2 pinned view revisions per view).
--
-- Each bank reports separate occupied and reserved bytes ('bankLedger'):
-- occupied bytes are physically held, reserved bytes are promised to accepted
-- work. Their sum never exceeds the limit. The ledgers are derived from the
-- model's records, so a credit cannot be freed twice or underflow.
--
-- == Admission
--
-- Admission is the only point where work answers busy. An explicit request is
-- one atomic unit over all of its regions; a camera demand is one unit per
-- region job. A unit is funded in full at that moment, from free capacity plus
-- an eviction set chosen and committed in the same step; it is never refused
-- afterwards, and a unit that is not admitted holds nothing. A job funded by
-- committed victims waits only for those victims' 'VictimReleased' events
-- ('JobWaiting'), then becomes queued. A victim cannot regain an interest.
-- Checks run in a fixed order and the first failure is reported: permanently
-- invalid ('Invalid': a request that cannot fit an empty bank or slot), then
-- exhausted retained edits, then busy for the command slot, the job slot, the
-- staging bank, the edit bank and last the resident bank with its eviction
-- set.
--
-- Reads of a hold, a handoff duplicate or a pin also admit small staging
-- records; they answer busy for the same reasons and start nothing when they do.
--
-- Work is shared by arena incarnation, content revision and region. A later
-- caller whose coverage is already resident or already being loaded only gains
-- an interest; if some of its cells are not, a job covers exactly those cells,
-- so no cell is loaded twice and the cells between disjoint demands are never
-- filled. Canceling an interest cancels a job only when no other interest
-- intersects it; a running job that nobody needs is marked cancelling and keeps
-- its scratch and resident reservation until its completion or acknowledgement
-- is reported, and its result is dropped.
--
-- == Content revisions
--
-- A request names the arena's current content revision or is stale; the model
-- never merges work across incarnations or revisions. Revisions change only at
-- 'RemovalCommitted', and a committed removal changes exactly one region (a
-- removal reshapes no neighbour). Work for every other region of the arena
-- carries over to the new revision; queued work for the changed region is
-- dropped, running work for it is marked stale and its result is discarded, and
-- the owners whose demand lost work are reported so that a camera demand can be
-- re-admitted by the next 'Service' and an explicit caller can resubmit.
--
-- == Eviction, holds and handoffs
--
-- A resident region is a victim candidate only when it has no interest, no
-- hold (borrower or publication pin), no job, no pending changes and no
-- handoff in flight. Candidates are taken in least-recently-used order of the
-- logical clock, ties by arena and region. Retained edits are never a victim.
-- A removal's committed changes stay protected ('regionDirty') until a handoff
-- transfers them: the transfer reserves its temporary duplicate in staging,
-- and a confirmed transfer needs no new edit allocation (the retained bytes
-- were funded at the removal) while a failed one keeps the changes and the
-- protection and is not retried by the model.
--
-- == Scheduling
--
-- 'Dispatch' picks one queued job: foreground work (any explicit interest)
-- and any job already passed over for 'limitAgingQuanta' dispatches first, then
-- the job whose interests arrived or were served longest ago, then the lowest
-- job number. Progress assumption: required victims are released, required
-- holds are eventually released and dispatched finite work reports completion.
-- Superseded camera work need not finish solely for an obsolete view.
--
-- == What this model does not do
--
-- It is not a process-RSS or speed claim. The byte figures are conservative
-- accounting. The owner supplies identities, performs the effects, commits the
-- revision and settles the real edit; the Lua mapping of a refusal and every
-- GPU limit belong to later slices.
module Hetoimasia.Terrain.Residency
  ( -- * Limits
    Bank (..)
  , Slot (..)
  , allBanks
  , allSlots
  , LimitsSpec (..)
  , LimitField (..)
  , LimitError (..)
  , Limits
  , mkLimits
  , defaultLimits
  , limitCeiling
  , limitBytes
  , limitSlot
  , limitQueryRegions
  , limitDemandRegions
  , limitExtent
  , limitRegionStoredBytes
  , limitAgingQuanta
  , minimumBytes
  , minimumLoadJobs

    -- * Coverage and charges
  , Coverage
  , CoverageError (..)
  , coverageBox
  , coverageTile
  , coverageUnion
  , coverageDifference
  , coverageIntersects
  , coverageSubset
  , coverageIsEmpty
  , coverageCells
  , coverageColumns
  , coverageSegments
  , coverageIntervals
  , Cost (..)
  , costBytes
  , reserveCost
  , regionMetadataBytes
  , interestRecordBytes
  , holdRecordBytes
  , commandRecordBytes
  , descriptionBytes
  , scratchBytes
  , removalRetainedBytes
  , removalStagingBytes

    -- * The model
  , ArenaId (..)
  , Revision (..)
  , RequestId (..)
  , ViewId (..)
  , HoldId (..)
  , JobId (..)
  , RegionKey
  , Owner (..)
  , HoldKind (..)
  , RegionDemand (..)
  , Event (..)
  , Refusal (..)
  , BusyReason (..)
  , Blockers (..)
  , InvalidReason (..)
  , StaleReason (..)
  , ContractReason (..)
  , Report (..)
  , Decision (..)
  , Admission (..)
  , Model
  , newModel
  , step

    -- * Observation
  , Ledger (..)
  , bankLedger
  , slotInUse
  , viewPins
  , modelLimits
  , modelClock
  , ArenaPhase (..)
  , ArenaInfo (..)
  , modelArenas
  , RegionInfo (..)
  , modelRegions
  , JobPhase (..)
  , JobInfo (..)
  , modelJobs
  , InterestInfo (..)
  , modelInterests
  , ViewInfo (..)
  , modelViews
  , RequestInfo (..)
  , modelRequests
  , modelHolds
  , modelInvariants
  ) where

import Hetoimasia.Terrain.Internal.Residency.Coverage
import Hetoimasia.Terrain.Internal.Residency.Limits
import Hetoimasia.Terrain.Internal.Residency.Model
