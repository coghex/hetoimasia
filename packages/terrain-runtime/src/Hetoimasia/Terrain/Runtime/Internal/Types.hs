-- | The service's types: authorities, requests, the settlement seam, the
-- configuration and the one state record the transactions share.
--
-- == State, owner and thread
--
-- Every piece of mutable state lives in the single 'St' behind one 'TVar'.
-- Writers are named per field in "Hetoimasia.Terrain.Runtime.Internal.Core":
-- the public port writes the admission bookkeeping (the accounting model, the
-- request table, the leases and names), and /only the owner thread/ writes the
-- contents of an arena (its resident detail, palette, retained changes, content
-- revision and residency generation). One transaction decides each
-- cancellation, admission and settlement race, so there is no second slot that
-- can win independently.
module Hetoimasia.Terrain.Runtime.Internal.Types
  ( -- * Authorities
    Client (..)
  , ArenaLease (..)
  , Request (..)
  , View (..)

    -- * Settlement seam
  , Endpoint (..)
  , Settlement (..)
  , Answer (..)
  , CellAnswer (..)
  , ColumnAnswer (..)
  , SurfaceAnswer (..)
  , RemoveAnswer (..)
  , Failure (..)
  , Refused (..)
  , BusyWhy (..)
  , CancelResult (..)
  , Precondition (..)

    -- * Configuration and ports
  , Config (..)
  , ConfigError (..)
  , SessionAdmission (..)
  , Supervisor (..)
  , OwnerControl (..)
  , Probe (..)
  , Point (..)
  , noProbe
  , Defect (..)
  , DefectRecord (..)

    -- * Service
  , Service (..)

    -- * Commands and requests
  , Cmd (..)
  , Staged (..)
  , StagedWork (..)
  , ReqPhase (..)
  , Req (..)

    -- * Inspection records (read-only, for verification)
  , RunningWork (..)
  , noRunningWork
  , JobWork (..)
  , jobWorkArena
  , jobWorkRegion
  , jobWorkResident
  , jobWorkScratch
  , jobWorkSlots
  , PreparationWork (..)
  , preparationRequest
  , preparationArena
  , preparationRemoval
  , preparationRecordBytes
  , preparationResident
  , preparationStaging
  , preparationEdit
  , HandoffWork (..)
  , handoffWorkArena
  , handoffWorkRegion
  , handoffWorkDuplicate
  , runningJobs
  , runningPreparation
  , runningHandoffs
  , Census (..)
  , ArenaCensus (..)
  , RequestCensus (..)
  , censusArenas
  , censusRequests
  , censusBorrows
  , censusRunning
  , censusArena
  , censusRetiring
  , censusRegionBytes
  , censusRetainedBytes
  , censusRegions
  , censusRemoval
  , censusModelRecord
  , censusSettled
  , censusGhost

    -- * State
  , Arena (..)
  , LeaseRec (..)
  , ClientRec (..)
  , ViewRec (..)
  , NameClaim (..)
  , Phase (..)
  , Turn (..)
  , OwnerPhase (..)
  , St (..)
  , initialState
  ) where

import Control.Concurrent.STM (STM, TVar)
import Control.Exception (Exception)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Unique (Unique)
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Worker (WorkerDefinition)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes (Changes)
import Hetoimasia.Terrain.Coordinate (RegionCoord, TileCoord)
import Hetoimasia.Terrain.Palette (Palette)
import Hetoimasia.Terrain.Query (Occupied, QueryError, QueryLimits, Run)
import Hetoimasia.Terrain.Residency
  ( ArenaId (..)
  , BusyReason
  , HoldId
  , JobId
  , LimitError
  , Limits
  , Model
  , RegionDemand
  , RegionKey
  , RequestId (..)
  , Revision (..)
  , ViewId (..)
  , newModel
  )
import Hetoimasia.Terrain.Resident (Resident)
import Hetoimasia.Terrain.Runtime.Internal.Content (Prepared)
import Hetoimasia.Terrain.Source (Source, SourceError, SourceLimits)

-- ---------------------------------------------------------------------------
-- Authorities

-- | One client of the service, for example one Lua instance. It owns the
-- leases and views made with it. The constructor is private: only the service
-- issues one, and a value made for another service is refused.
data Client = Client !Unique !Word64

instance Eq Client where
  Client a n == Client b m = a == b && n == m

instance Show Client where
  show (Client _ n) = "Client#" <> show n

-- | A client's authority over one arena incarnation. Releasing it, or the
-- arena's closure, revokes it; it is never reused.
data ArenaLease = ArenaLease !Unique !Word64

instance Eq ArenaLease where
  ArenaLease a n == ArenaLease b m = a == b && n == m

instance Show ArenaLease where
  show (ArenaLease _ n) = "ArenaLease#" <> show n

-- | An accepted request. It names a request and carries no authority to settle
-- it: the service alone settles.
data Request = Request !Unique !RequestId

instance Eq Request where
  Request a n == Request b m = a == b && n == m

instance Show Request where
  show (Request _ (RequestId n)) = "Request#" <> show n

-- | A registered view demand producer. Registration creates no window, view or
-- GPU resource.
data View = View !Unique !ViewId

instance Eq View where
  View a n == View b m = a == b && n == m

instance Show View where
  show (View _ (ViewId n)) = "View#" <> show n

-- ---------------------------------------------------------------------------
-- The settlement seam

-- | What a host supplies to take part in the service's arbitration.
--
-- The three operations are distinct. 'endpointReady' announces that work is
-- staged and could be committed; 'endpointEligible' is the host's grant that
-- it may be; 'endpointSettle' delivers the terminal outcome. The service calls
-- 'endpointSettle' inside the transaction that decides the race, so a
-- settlement is atomic with the content change that accompanies it and with
-- any cancellation: there is no second slot that can win. None of the three may
-- block or 'Control.Concurrent.STM.retry'. A host callback that throws is a
-- provider defect: the transaction is abandoned with nothing committed, the
-- request is failed, and the defect reaches supervision.
data Endpoint = Endpoint
  { endpointReady ∷ STM ()
  , endpointEligible ∷ STM Bool
  , endpointSettle ∷ Settlement → STM ()
  }

-- | The one terminal outcome of an accepted request.
data Settlement
  = Succeeded !Answer
  | Failed !Failure
  | Cancelled
  deriving stock (Eq, Show)

-- | A successful answer.
data Answer
  = AOpened !ArenaLease
  | AAttached !ArenaLease
  | ACell !CellAnswer
  | AColumn !ColumnAnswer
  | ASurface !SurfaceAnswer
  | ARemoved !RemoveAnswer
  deriving stock (Eq, Show)

-- | A cell: air, or a material and shape, at one revision of one incarnation.
data CellAnswer = CellAnswer
  { cellIncarnation ∷ !ArenaId
  , cellRevision ∷ !Revision
  , cellValue ∷ !Cell
  }
  deriving stock (Eq, Show)

-- | The complete runs of a finite half-open range of one column.
data ColumnAnswer = ColumnAnswer
  { columnIncarnation ∷ !ArenaId
  , columnRevision ∷ !Revision
  , columnAnswerRuns ∷ ![Run]
  }
  deriving stock (Eq, Show)

-- | The highest occupied cell of a column, or an explicit absence.
data SurfaceAnswer = SurfaceAnswer
  { surfaceIncarnation ∷ !ArenaId
  , surfaceRevision ∷ !Revision
  , surfaceTop ∷ !(Maybe Occupied)
  }
  deriving stock (Eq, Show)

-- | A removal: whether anything changed and the committed content revision.
data RemoveAnswer = RemoveAnswer
  { removeIncarnation ∷ !ArenaId
  , removeRevision ∷ !Revision
  , removeChangedFlag ∷ !Bool
  }
  deriving stock (Eq, Show)

-- | The expected domain failures, with bounded attribution.
data Failure
  = NotFound
  | ArenaClosed
  | StaleView
  | -- | The request was overtaken by a committed edit and can no longer be admitted
    -- (its demand left the configured extent, or the retained edits are full).
    Superseded !Text
  | NameInUse
  | Definition !SourceError
  | TooLarge !QueryError
  | SourceFailure !Text
  | -- | An unexpected defect of the host or its accounting; never air.
    HostFailure !Text
  deriving stock (Eq, Show)

-- | Why the service refused to admit anything. A refusal creates no request,
-- no work and no reservation.
data Refused
  = -- | Temporary pressure, with the model's reason when a bank or slot is full.
    RefusedBusy !BusyWhy
  | -- | Forged, foreign, released or wrong-service authority.
    RefusedAuthority
  | -- | A request that can never succeed.
    RefusedInvalid !Text
  | -- | An identity would wrap.
    RefusedExhausted
  | -- | The service, or the session that admits it, is closed.
    RefusedClosed
  deriving stock (Eq, Show)

-- | What 'Busy' names.
data BusyWhy
  = BusyModel !BusyReason
  | BusyRetainedEdits
  | BusyArenas
  | BusyLeases
  | BusyViews
  | BusyClients
  | BusyRetained
  deriving stock (Eq, Show)

-- | What a cancellation found.
data CancelResult
  = -- | The request was unsettled; cancellation won, nothing was committed.
    CancelWon
  | -- | The request had already reached its terminal outcome.
    AlreadySettled
  | -- | The request belongs to another service.
    CancelForeign
  deriving stock (Eq, Show)

-- | A removal's optional content precondition: the incarnation and the content
-- revision a displayed view was built from.
data Precondition = Precondition !ArenaId !Revision
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Configuration and ports

-- | The service's configuration.
data Config = Config
  { configLimits ∷ !Limits
  , configMaxArenas ∷ !Int
  , configMaxLeases ∷ !Int
  , configMaxViews ∷ !Int
  , -- | Registered clients: a client record is state the service holds, so it is bounded.
    configMaxClients ∷ !Int
  , configSourceLimits ∷ !SourceLimits
  , configQueryLimits ∷ !QueryLimits
  , -- | The first identity every counter issues. The default is zero; a test
    -- raises it to exercise exhaustion without issuing billions.
    configFirstIdentity ∷ !Word64
  , -- | The content revision a new arena starts at, likewise for exhaustion tests.
    configFirstRevision ∷ !Word64
  , -- | The CPU snapshot backing bank, in accounted bytes, carved out of the
    -- configured staging bank: the accounting model is built with the rest. Every
    -- outstanding snapshot is charged its own restricted backing against it until
    -- its last borrower releases it, so retained old versions of an edited region
    -- stay accounted.
    configRetainedBytes ∷ !Word64
  }

-- | The configuration cannot be built: the limits, with the snapshot bank taken
-- out of the staging bank, do not satisfy the residency model's minimum budgets.
newtype ConfigError = ConfigError LimitError
  deriving stock (Show)

instance Exception ConfigError

-- | The parent session's admission, readable inside the arbitration.
newtype SessionAdmission = SessionAdmission
  { sessionOpen ∷ STM Bool
  }

-- | The supervision capability: how the service starts its owner, and the
-- control it gets back. The owner thread never holds either, and in particular
-- never holds the runtime control.
newtype Supervisor = Supervisor
  { superviseOwner ∷ WorkerDefinition () → IO OwnerControl
  }

-- | What the service may do to the owner it started: ask it to stop. The owner
-- stops only when asked, so that its orderly return after the service closed is
-- never mistaken for an unexpected exit of a supervised service.
data OwnerControl = OwnerControl
  { stopOwner ∷ IO ()
  , -- | Succeeds only once the owner's worker has published its terminal
    -- outcome: the proof that nothing of the owner is still running.
    awaitOwnerEnd ∷ STM ()
  }

-- | Controlled gates and fault points on the owner thread, called outside any
-- transaction. The default does nothing. A gate blocks the owner at a point; an
-- exception injected at a point is a failure of the step it names.
newtype Probe = Probe
  { probePoint ∷ Point → IO ()
  }

noProbe ∷ Probe
noProbe = Probe (\_ → pure ())

-- | The points the owner reports.
data Point
  = -- | A read captured its source and overlay revision.
    PointCaptured !RequestId !ArenaId !Revision
  | -- | Work was staged, before it was published as staged.
    PointStaging !RequestId
  | -- | Staged work is about to be offered to the arbitration.
    PointBeforeCommit !RequestId
  | -- | A commit won and published.
    PointCommitted !RequestId !Revision
  | -- | A load job is about to run.
    PointJob !ArenaId !RegionCoord
  | -- | A changed region's transfer is about to run; an exception is a failed transfer.
    PointHandoff !ArenaId !RegionCoord
  | -- | A transfer was refused for want of capacity (it will be reconsidered).
    PointHandoffBusy !ArenaId !RegionCoord
  | -- | A transfer ended and was reported: whether it succeeded.
    PointHandoffReported !ArenaId !RegionCoord !Bool
  | -- | A victim's detail is about to be discarded.
    PointVictim !ArenaId !RegionCoord
  deriving stock (Eq, Show)

-- | An unexpected defect, kept with bounded context.
-- | A recorded defect and whether the owner has already reported it to supervision
-- (by ending with it, or by being about to throw it).
data DefectRecord = DefectRecord
  { defectSeq ∷ !Word64
  , defectReported ∷ !Bool
  , defectOf ∷ !Defect
  }

data Defect
  = ProviderDefect !Text
  | AccountingDefect !Text
  | OwnerDefect !Text
  deriving stock (Eq, Show)

instance Exception Defect

-- ---------------------------------------------------------------------------
-- The service

-- | The service handle. Its constructor is private.
data Service = Service
  { serviceTag ∷ !Unique
  , serviceState ∷ !(TVar St)
  , serviceConfig ∷ !Config
  , serviceAdmission ∷ !SessionAdmission
  , serviceLogger ∷ !Logger
  , serviceProbe ∷ !Probe
  }

-- ---------------------------------------------------------------------------
-- Commands and requests

-- | A command, with the authority and validated inputs it needs.
data Cmd
  = COpen !Text !Source !Word64
  | CAttach !Text !Word64
  | CCell !TileCoord
  | CColumn !Column !ZRange
  | CSurface !Column
  | CRemove !TileCoord !(Maybe Precondition)

-- | Prepared work, tagged with the incarnation and revision it was built for.
data Staged = Staged
  { stagedArena ∷ !(Maybe ArenaId)
  , stagedRevision ∷ !Revision
  , stagedWork ∷ !StagedWork
  }

data StagedWork
  = StagedAnswer !Answer
  | StagedRemoval !Prepared
  | -- | An open or attach, decided in the arbitration itself.
    StagedControl

data ReqPhase
  = Waiting
  | StagedPhase !Staged
  | -- | Settled, but its accepted result stays charged until retired.
    Done

-- | An accepted request.
data Req = Req
  { reqSeq ∷ !Word64
  , reqCmd ∷ !Cmd
  , reqEndpoint ∷ !Endpoint
  , reqLease ∷ !(Maybe Word64)
  , reqClient ∷ !Word64
  , reqArena ∷ !(Maybe ArenaId)
  , reqPhase ∷ !ReqPhase
  , -- | Whether the accounting model holds this request's record and credits.
    reqModel ∷ !Bool
  , -- | What was demanded of the model, to detect a demand a newer revision changed.
    reqDemand ∷ ![RegionDemand]
  }

-- ---------------------------------------------------------------------------
-- Inspection records
--
-- Everything in this section is a read-only observation, kept for verification.
-- No production decision reads it: not admission, not scheduling, not accounting.
-- The types are abstract outside the package (positional constructors that
-- "Hetoimasia.Terrain.Runtime" does not export, and accessors that are ordinary
-- functions, never field labels), so a client cannot construct, forge or update
-- one, and none carries an authority, a handle or a snapshot.

-- | The work the owner thread is running or holding, recorded where that work
-- starts and where it ends, from the values the work itself holds, and not from the
-- accounting model: the model's ledgers are what a test compares this against.
--
-- Owner and thread: written only by the owner thread (a job at its dispatch and at its
-- report, a preparation between its start and the owner's safe point, a handoff's
-- duplicate between the transfer's admission and its outcome) and emptied by the
-- owner's terminal step. Readers: the inspection function only. Bounded by the
-- single owner: one preparation at a time, one job per dispatch, one handoff per
-- changed region, and every entry ends with the work it describes.
data RunningWork = RunningWork
  { rwJobs ∷ !(Map JobId JobWork)
  , rwPreparation ∷ !(Maybe PreparationWork)
  , rwHandoffs ∷ !(Map RegionKey HandoffWork)
  }

noRunningWork ∷ RunningWork
noRunningWork = RunningWork Map.empty Nothing Map.empty

-- | A load job the owner is running: where, the resident bytes its coverage can
-- store (what it reserves in the resident bank, region metadata not claimed), its
-- scratch, and the job slot it holds.
data JobWork = JobWork !ArenaId !RegionCoord !Word64 !Word64 !Word64
  deriving stock (Eq, Show)

jobWorkArena ∷ JobWork → ArenaId
jobWorkArena (JobWork a _ _ _ _) = a

jobWorkRegion ∷ JobWork → RegionCoord
jobWorkRegion (JobWork _ r _ _ _) = r

jobWorkResident ∷ JobWork → Word64
jobWorkResident (JobWork _ _ n _ _) = n

jobWorkScratch ∷ JobWork → Word64
jobWorkScratch (JobWork _ _ _ n _) = n

jobWorkSlots ∷ JobWork → Word64
jobWorkSlots (JobWork _ _ _ _ n) = n

-- | A preparation the owner is running for a request: the request, its arena, whether it
-- is a removal, the command record it reads under, and, for a removal, the resident
-- growth, staging and retained-edit bytes its buffers and result can hold.
data PreparationWork = PreparationWork !RequestId !(Maybe ArenaId) !Bool !Word64 !Word64 !Word64 !Word64
  deriving stock (Eq, Show)

preparationRequest ∷ PreparationWork → RequestId
preparationRequest (PreparationWork r _ _ _ _ _ _) = r

preparationArena ∷ PreparationWork → Maybe ArenaId
preparationArena (PreparationWork _ a _ _ _ _ _) = a

preparationRemoval ∷ PreparationWork → Bool
preparationRemoval (PreparationWork _ _ r _ _ _ _) = r

preparationRecordBytes ∷ PreparationWork → Word64
preparationRecordBytes (PreparationWork _ _ _ n _ _ _) = n

preparationResident ∷ PreparationWork → Word64
preparationResident (PreparationWork _ _ _ _ n _ _) = n

preparationStaging ∷ PreparationWork → Word64
preparationStaging (PreparationWork _ _ _ _ _ n _) = n

preparationEdit ∷ PreparationWork → Word64
preparationEdit (PreparationWork _ _ _ _ _ _ n) = n

-- | The temporary duplicate of a region's changes the owner holds while it transfers
-- them: where, and how many bytes.
data HandoffWork = HandoffWork !ArenaId !RegionCoord !Word64
  deriving stock (Eq, Show)

handoffWorkArena ∷ HandoffWork → ArenaId
handoffWorkArena (HandoffWork a _ _) = a

handoffWorkRegion ∷ HandoffWork → RegionCoord
handoffWorkRegion (HandoffWork _ r _) = r

handoffWorkDuplicate ∷ HandoffWork → Word64
handoffWorkDuplicate (HandoffWork _ _ n) = n

-- | The jobs, the preparation and the handoff duplicates of a record, oldest first.
runningJobs ∷ RunningWork → [JobWork]
runningJobs = Map.elems . rwJobs

runningPreparation ∷ RunningWork → Maybe PreparationWork
runningPreparation = rwPreparation

runningHandoffs ∷ RunningWork → [HandoffWork]
runningHandoffs = Map.elems . rwHandoffs

-- | One arena as the service holds it: whether it is retiring, the accounted bytes its
-- resident detail holds in each vertical region (from the detail itself), and the
-- bytes of its retained changes.
data ArenaCensus = ArenaCensus !ArenaId !Bool !(Map RegionCoord Word64) !Word64
  deriving stock (Eq, Show)

censusArena ∷ ArenaCensus → ArenaId
censusArena (ArenaCensus a _ _ _) = a

censusRetiring ∷ ArenaCensus → Bool
censusRetiring (ArenaCensus _ r _ _) = r

censusRegionBytes ∷ ArenaCensus → Map RegionCoord Word64
censusRegionBytes (ArenaCensus _ _ m _) = m

censusRetainedBytes ∷ ArenaCensus → Word64
censusRetainedBytes (ArenaCensus _ _ _ n) = n

-- | One request as the service holds it: the regions it demands, whether it is a
-- removal, whether the model still holds its record and credits, whether it has
-- settled (its result waiting to be taken), and whether it was withdrawn behind a
-- running preparation and is still charged.
data RequestCensus = RequestCensus !Int !Bool !Bool !Bool !Bool
  deriving stock (Eq, Show)

censusRegions ∷ RequestCensus → Int
censusRegions (RequestCensus n _ _ _ _) = n

censusRemoval ∷ RequestCensus → Bool
censusRemoval (RequestCensus _ r _ _ _) = r

censusModelRecord ∷ RequestCensus → Bool
censusModelRecord (RequestCensus _ _ m _ _) = m

censusSettled ∷ RequestCensus → Bool
censusSettled (RequestCensus _ _ _ s _) = s

censusGhost ∷ RequestCensus → Bool
censusGhost (RequestCensus _ _ _ _ g) = g

-- | What the service itself holds, read from its own data structures and not from
-- the accounting model: its arenas (live, and retiring while a borrowed snapshot or an
-- unfinished release keeps one), its requests, the number of outstanding snapshots and
-- the record of the work its owner is running.
data Census = Census ![ArenaCensus] ![RequestCensus] !Int !RunningWork

censusArenas ∷ Census → [ArenaCensus]
censusArenas (Census a _ _ _) = a

censusRequests ∷ Census → [RequestCensus]
censusRequests (Census _ r _ _) = r

censusBorrows ∷ Census → Int
censusBorrows (Census _ _ b _) = b

censusRunning ∷ Census → RunningWork
censusRunning (Census _ _ _ w) = w

-- ---------------------------------------------------------------------------
-- State

-- | One live arena incarnation. The contents (the resident detail, palette,
-- retained changes, revision and generation) are written by the owner only.
data Arena = Arena
  { arenaName ∷ !Text
  , arenaSource ∷ !Source
  , arenaPalette ∷ !Palette
  , arenaResident ∷ !Resident
  , -- | The authority: the source's removals, store plus working.
    arenaChanges ∷ !Changes
  , -- | Changes transferred to the retained store.
    arenaStore ∷ !Changes
  , -- | Changes committed since the last transfer, by region.
    arenaWorking ∷ !(Map RegionCoord Changes)
  , arenaRevision ∷ !Revision
  , arenaGeneration ∷ !Word64
  , arenaCreator ∷ !Word64
  , arenaLeases ∷ !(Set Word64)
  }

data LeaseRec = LeaseRec
  { leaseClient ∷ !Word64
  , leaseArena ∷ !ArenaId
  , leaseOwner ∷ !Bool
  , leaseLive ∷ !Bool
  }

data ClientRec = ClientRec
  { clientLeases ∷ !(Set Word64)
  , clientViews ∷ !(Set ViewId)
  }

data ViewRec = ViewRec
  { viewClient ∷ !Word64
  }

data NameClaim = ClaimPending !RequestId | ClaimLive !ArenaId

-- | The four kinds of owner work that take turns: staging, commits, retries and
-- load dispatches. When two or more are ready they are served in rotation, so a
-- continuous supply of any one cannot starve another; within commits the
-- per-arena admission order is kept.
data Turn = TurnPrepare | TurnCommit | TurnRetry | TurnDispatch
  deriving stock (Eq, Show)

data Phase = Running | Closing
  deriving stock (Eq, Show)

data OwnerPhase = OwnerStarting | OwnerRunning | OwnerStopped
  deriving stock (Eq, Show)

-- | The whole mutable state.
data St = St
  { statePhase ∷ !Phase
  , stateOwner ∷ !OwnerPhase
  , stateModel ∷ !Model
  , stateNextClient ∷ !Word64
  , stateNextLease ∷ !Word64
  , stateNextRequest ∷ !Word64
  , stateNextArena ∷ !Word64
  , stateNextView ∷ !Word64
  , stateNextHold ∷ !Word64
  , stateNextSeq ∷ !Word64
  , stateClients ∷ !(Map Word64 ClientRec)
  , stateLeases ∷ !(Map Word64 LeaseRec)
  , stateArenas ∷ !(Map ArenaId Arena)
  , stateRetiring ∷ !(Map ArenaId Arena)
  , stateNames ∷ !(Map Text NameClaim)
  , stateRequests ∷ !(Map RequestId Req)
  , stateVictims ∷ !(Seq RegionKey)
  , stateViews ∷ !(Map ViewId ViewRec)
  , stateBorrowers ∷ !Int
  , -- | The accounted backing bytes each outstanding snapshot holds.
    stateSnapshots ∷ !(Map HoldId Word64)
  , -- | Something that may free capacity happened since the last retry pass.
    stateFreed ∷ !Bool
  , -- | A dispatch found nothing to run since the last time capacity freed.
    stateDispatchIdle ∷ !Bool
  , -- | The generation each region's last transfer was tried at.
    stateTransfers ∷ !(Map RegionKey Word64)
  , stateDefects ∷ ![DefectRecord]
  , stateDefectCount ∷ !Word64
  , -- | Whose quantum is next when several kinds of work are ready.
    stateTurn ∷ !Turn
  , -- | The request whose preparation the owner is running, with its arena. While
    -- it runs, the credits it holds (and its arena's) are not released: a release
    -- that would touch them waits for the owner's safe point.
    stateRunning ∷ !(Maybe (RequestId, Maybe ArenaId))
  , -- | Requests that ended while their preparation was running: the table no
    -- longer has them, but the model still holds their record and every credit it
    -- owns, and the service still holds their reserved record, until the safe point.
    stateGhosts ∷ !(Map RequestId Req)
  , -- | Arenas closed while a preparation of theirs was running: the model retires
    -- them at the safe point.
    stateDeferredRetire ∷ !(Set ArenaId)
  , -- | Advances every time capacity may have been returned.
    stateCapacityEpoch ∷ !Word64
  , -- | The capacity epoch at which a region's transfer was refused for want of
    -- capacity. That is not a failed transfer: the region is reconsidered as soon
    -- as the epoch moves.
    stateHandoffBusy ∷ !(Map RegionKey Word64)
  , -- | The read-only record of the work the owner is running (see 'RunningWork'):
    -- written by the owner where that work starts and ends, read by no decision.
    stateWork ∷ !RunningWork
  }

initialState ∷ Config → Limits → St
initialState config limits =
  St
    { statePhase = Running
    , stateOwner = OwnerStarting
    , stateModel = newModel limits
    , stateNextClient = first
    , stateNextLease = first
    , stateNextRequest = first
    , stateNextArena = first
    , stateNextView = first
    , stateNextHold = first
    , stateNextSeq = 0
    , stateClients = Map.empty
    , stateLeases = Map.empty
    , stateArenas = Map.empty
    , stateRetiring = Map.empty
    , stateNames = Map.empty
    , stateRequests = Map.empty
    , stateVictims = Seq.empty
    , stateViews = Map.empty
    , stateBorrowers = 0
    , stateSnapshots = Map.empty
    , stateFreed = False
    , stateDispatchIdle = False
    , stateTransfers = Map.empty
    , stateDefects = []
    , stateDefectCount = 0
    , stateTurn = TurnPrepare
    , stateRunning = Nothing
    , stateGhosts = Map.empty
    , stateDeferredRetire = Set.empty
    , stateCapacityEpoch = 0
    , stateHandoffBusy = Map.empty
    , stateWork = noRunningWork
    }
  where
    first = configFirstIdentity config
