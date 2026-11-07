-- | The pure residency and admission model. See "Hetoimasia.Terrain.Residency"
-- for the contract; this module is its implementation and keeps every
-- constructor private to the package.
module Hetoimasia.Terrain.Internal.Residency.Model
  ( -- * Identities
    ArenaId (..)
  , Revision (..)
  , RequestId (..)
  , ViewId (..)
  , HoldId (..)
  , JobId (..)
  , RegionKey
  , Owner (..)
  , HoldKind (..)
  , RegionDemand (..)

    -- * Events and outcomes
  , Event (..)
  , Refusal (..)
  , BusyReason (..)
  , Blockers (..)
  , InvalidReason (..)
  , StaleReason (..)
  , ContractReason (..)
  , ChargeViolation (..)
  , chargeCheck
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

import Control.Monad (foldM)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Either (isRight)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Coordinate (RegionCoord, TileCoord, composeTile, decomposeTile, mkLocalCoord)
import Hetoimasia.Terrain.Internal.Residency.Coverage
import Hetoimasia.Terrain.Internal.Residency.Limits

-- ---------------------------------------------------------------------------
-- Identities (supplied by the owner; this model allocates only job numbers)

newtype ArenaId = ArenaId Word64 deriving stock (Eq, Ord, Show)

newtype Revision = Revision Word64 deriving stock (Eq, Ord, Show)

newtype RequestId = RequestId Word64 deriving stock (Eq, Ord, Show)

newtype ViewId = ViewId Word64 deriving stock (Eq, Ord, Show)

newtype HoldId = HoldId Word64 deriving stock (Eq, Ord, Show)

newtype JobId = JobId Word64 deriving stock (Eq, Ord, Show)

-- | One region of one arena incarnation.
type RegionKey = (ArenaId, RegionCoord)

-- | Who holds an interest: an explicit request or a view's camera demand.
data Owner = OwnerRequest !RequestId | OwnerView !ViewId
  deriving stock (Eq, Ord, Show)

-- | What a hold protects its regions for.
data HoldKind
  = -- | A reader borrowing resident data.
    Borrow
  | -- | A pinned CPU view revision or reserved publication dependency of a view.
    Pin !ViewId
  deriving stock (Eq, Ord, Show)

-- | A bounded demand: part of one region.
data RegionDemand = RegionDemand
  { demandRegion ∷ !RegionCoord
  , demandCoverage ∷ !Coverage
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Events

-- | Everything that can happen to the model. The owner sequences events; the
-- model never acts by itself.
data Event
  = -- | Register an arena incarnation at a content revision. Incarnations must
    -- increase.
    OpenArena !ArenaId !Revision
  | -- | Begin an arena's end: withdraw its demand, release when acknowledged.
    RetireArena !ArenaId
  | -- | Accept an explicit query for regions at a revision, atomically.
    SubmitQuery !RequestId !ArenaId !Revision [RegionDemand]
  | -- | Accept a whole-cell removal: its cell's demand and its worst-case
    -- reservations, atomically.
    SubmitRemoval !RequestId !ArenaId !Revision !TileCoord
  | -- | Replace a view's latest-value camera demand.
    SetCameraDemand !ViewId !ArenaId [RegionDemand]
  | -- | Withdraw a view's camera demand.
    ClearCameraDemand !ViewId
  | -- | Cancel or settle a request (a query's reply was delivered, a removal
    -- abandoned before commit). Releases its interests and reservations.
    Withdraw !RequestId
  | -- | A service quantum for pending camera demand.
    Service
  | -- | Choose the next queued job.
    Dispatch
  | -- | A running job finished; the cost of what it stored.
    JobCompleted !JobId !Cost
  | -- | A running job failed; nothing was stored.
    JobFailed !JobId
  | -- | A running job whose interests are gone acknowledged its cancellation.
    JobAcknowledged !JobId
  | -- | A removal committed at a new revision, retaining this many edit bytes and
    -- growing the edited region's resident detail by this many bytes (what the
    -- rebuilt segment now accounts beyond the old one, never above the reservation).
    RemovalCommitted !RequestId !Revision !Word64 !Word64
  | -- | Acquire a hold on resident regions.
    AcquireHold !HoldId !ArenaId !HoldKind [RegionCoord]
  | ReleaseHold !HoldId
  | -- | Begin transferring a changed region's detail to the retained store;
    -- the argument is the temporary duplicate's bytes.
    BeginHandoff !ArenaId !RegionCoord !Word64
  | HandoffConfirmed !ArenaId !RegionCoord
  | HandoffFailed !ArenaId !RegionCoord
  | -- | The owner finished discarding a committed victim's detail.
    VictimReleased !ArenaId !RegionCoord
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Refusals

-- | A refusal never changes the model.
data Refusal
  = -- | Temporary pressure: nothing was started or reserved.
    Busy !BusyReason
  | -- | The retained-edit bank (named, always 'EditBank') cannot take this edit
    -- even with every outstanding reservation returned: the bank, its limit, the
    -- committed bytes and the bytes asked. It persists until an arena's teardown
    -- frees retained bytes; it is neither a validation error nor pressure that is
    -- expected to clear.
    RetainedEditsExhausted !Bank !Word64 !Word64 !Word64
  | -- | Permanently invalid: it cannot succeed however long it waits.
    Invalid !InvalidReason
  | -- | Refers to an arena, revision, request, job, hold or region that is not
    -- (or no longer) current; the late event changes nothing.
    Stale !StaleReason
  | -- | The owner broke the protocol or reported impossible accounting.
    ContractFailure !ContractReason
  deriving stock (Eq, Show)

data BusyReason
  = -- | The bank, its limit, the bytes in use (occupied plus reserved) and the
    -- bytes requested.
    BankFull !Bank !Word64 !Word64 !Word64
  | -- | The slot, its limit, the slots in use and the slots requested.
    SlotFull !Slot !Word64 !Word64 !Word64
  | -- | The resident shortfall, the bytes of eligible victims and why the rest
    -- are not eligible.
    NoEligibleEviction !Word64 !Word64 !Blockers
  | -- | The region's detail is being released; retry after its release.
    RegionEvicting !RegionCoord
  deriving stock (Eq, Show)

-- | How many resident regions each condition keeps out of eviction (first
-- matching condition, in this field order).
data Blockers = Blockers
  { blockedEvicting ∷ !Int
  , blockedHandoff ∷ !Int
  , blockedDirty ∷ !Int
  , blockedHeld ∷ !Int
  , blockedInterest ∷ !Int
  , blockedJob ∷ !Int
  , blockedByRequest ∷ !Int
  }
  deriving stock (Eq, Show)

data InvalidReason
  = EmptyDemand
  | -- | Regions named, and the most the request kind allows.
    DemandTooLarge !Int !Word64
  | -- | A region naming a cell outside the configured extent.
    OutsideExtent !RegionCoord
  | -- | A handoff duplicate larger than a region can ever be, and that maximum.
    HandoffTooLarge !Word64 !Word64
  | DuplicateRegion !RegionCoord
  | DuplicateRequest !RequestId
  | DuplicateHold !HoldId
  | -- | A region key naming cells outside the supported coordinate range.
    UnsupportedRegion !RegionCoord
  | ArenaNotIncreasing !ArenaId
  | CostArithmetic
  deriving stock (Eq, Show)

data StaleReason
  = UnknownArena !ArenaId
  | ArenaRetiring !ArenaId
  | -- | The arena's current revision and the revision given.
    RevisionMismatch !Revision !Revision
  | UnknownRequest !RequestId
  | UnknownJob !JobId
  | UnknownHold !HoldId
  | UnknownView !ViewId
  | NotResident !RegionCoord
  | NotEvicting !RegionCoord
  deriving stock (Eq, Show)

data ContractReason
  = -- | A transition that would have broken the charge rules (a defect, never a
    -- result of valid events).
    ChargeBreached !ChargeViolation
  | -- | The bytes a region would occupy and the most the configured extent allows.
    RegionExceedsMaximum !Word64 !Word64
  | -- | Reserved bytes and the larger actual bytes the data layer reported.
    CostExceedsReservation !Word64 !Word64
  | CostOverflow
  | JobNotRunning !JobId
  | JobNotCancelling !JobId
  | NotAnEdit !RequestId
  | EditBeforeResident !RequestId
  | RevisionNotAdvancing !Revision !Revision
  | CommitExceedsReservation !Word64 !Word64
  | -- | The removal's resident growth is still waiting for its victims to be released.
    EditNotFunded !RequestId
  | -- | Reserved and reported resident growth.
    ResidentGrowthExceedsReservation !Word64 !Word64
  | HandoffNotNeeded !RegionCoord
  | HandoffNotPending !RegionCoord
  | JobIdsExhausted
  | ClockExhausted
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Reports

-- | The result of one accepted event.
data Report = Report
  { reportDecision ∷ !Decision
  , -- | Retiring arenas that became fully released by this event.
    reportSettled ∷ ![ArenaId]
  , -- | Jobs whose committed victims were all released by this event.
    reportFunded ∷ ![JobId]
  }
  deriving stock (Eq, Show)

-- | What the owner must now do or know.
data Admission = Admission
  { -- | The jobs created, each with its region.
    admissionJobs ∷ ![(JobId, RegionCoord)]
  , -- | Regions served by resident data or by work already accepted.
    admissionShared ∷ ![RegionCoord]
  , -- | Regions committed as victims of this admission, in LRU order; the
    -- owner discards each and reports 'VictimReleased'.
    admissionVictims ∷ ![RegionKey]
  , -- | The resident bytes whose funding waits for those releases.
    admissionDeferred ∷ !Word64
  }
  deriving stock (Eq, Show)

data Decision
  = ArenaOpened
  | ArenaRetirement ![JobId] ![JobId]
  | Accepted !Admission
  | CameraSet
      { cameraAdmitted ∷ ![Admission]
      , cameraPending ∷ ![RegionCoord]
      , cameraWithdrawn ∷ ![RegionCoord]
      , cameraCancelled ∷ ![JobId]
      , cameraAwaitingAck ∷ ![JobId]
      , -- | Regions of the description left out as unsupported or wholly outside the extent.
        cameraExcluded ∷ ![RegionCoord]
      , -- | Regions cut from the end of the description (the lowest priority) because
        -- it exceeds the structural maximum or the staging the camera may use.
        cameraTruncated ∷ ![RegionCoord]
      }
  | CameraCleared ![RegionCoord] ![JobId] ![JobId]
  | Withdrawn ![JobId] ![JobId]
  | Serviced ![(ViewId, Admission)]
  | Dispatched !JobId !RegionKey !Coverage
  | NothingToDispatch
  | -- | The job, the owners whose interests are now satisfied.
    Published !JobId ![Owner]
  | -- | A late, withdrawn or superseded job's result was dropped; its
    -- reservations were released.
    Discarded !JobId
  | -- | The failed job, the owners whose interests it served (dropped), and the
    -- jobs that dropping them left unneeded: those dropped at once and those
    -- running, awaiting their acknowledgement.
    JobFailedFor !JobId ![Owner] ![JobId] ![JobId]
  | -- | The new revision, the retained bytes returned, the owners whose demand
    -- lost its work to the commit, the queued jobs of the changed region that were
    -- dropped, and the running jobs of it now superseded: they are cancelling, so
    -- their results are discarded and the owner's acknowledgement releases them.
    Committed !Revision !Word64 ![Owner] ![JobId] ![JobId]
  | HoldAcquired
  | HoldReleased
  | HandoffStarted
  | HandoffSettled
  | HandoffAbandoned
  | VictimFreed
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- State

data ArenaPhase = ArenaLive | ArenaRetiringPhase
  deriving stock (Eq, Show)

data Arena = Arena
  { arPhase ∷ !ArenaPhase
  , arRevision ∷ !Revision
  , arRetained ∷ !Word64
  }
  deriving stock (Eq, Show)

data Residence = Residence
  { rsCoverage ∷ !Coverage
  , rsBytes ∷ !Word64
  , rsLastUse ∷ !Word64
  , rsDirty ∷ !Bool
  , -- | Counts the removals committed in this region; a handoff records the
    -- count it transfers, so an older handoff cannot clear a newer change.
    rsGeneration ∷ !Word64
  , -- | A handoff in flight: its duplicate bytes and the generation it transfers.
    rsHandoff ∷ !(Maybe (Word64, Word64))
  , rsEvicting ∷ !Bool
  }
  deriving stock (Eq, Show)

data Interest = Interest
  { inCoverage ∷ !Coverage
  , inServed ∷ !Word64
  }
  deriving stock (Eq, Show)

data Target = Target
  { tgResident ∷ !(Maybe Residence)
  , tgInterests ∷ !(Map Owner Interest)
  }
  deriving stock (Eq, Show)

data JobState = JobPending | JobRunning | JobCancelling
  deriving stock (Eq, Show)

data Job = Job
  { jbArena ∷ !ArenaId
  , jbRevision ∷ !Revision
  , jbRegion ∷ !RegionCoord
  , jbCoverage ∷ !Coverage
  , jbState ∷ !JobState
  , jbActive ∷ !Word64
  , jbDeferred ∷ !Word64
  , jbAwaiting ∷ !(Map RegionKey Word64)
  , jbScratch ∷ !Word64
  , jbSkips ∷ !Word64
  , jbStale ∷ !Bool
  , -- | Created for a camera view: its reservation is charged to the camera share for
    -- as long as it lives, whoever later shares it.
    jbCamera ∷ !Bool
  }
  deriving stock (Eq, Show)

data EditReservation = EditReservation
  { erRegion ∷ !RegionCoord
  , erCoverage ∷ !Coverage
  , erRevision ∷ !Revision
  , erRetained ∷ !Word64
  , erStaging ∷ !Word64
  }
  deriving stock (Eq, Show)

data Request = Request
  { rqArena ∷ !ArenaId
  , rqRegions ∷ ![RegionCoord]
  , rqBytes ∷ !Word64
  , rqEdit ∷ !(Maybe EditReservation)
  , -- | A removal's reserved resident growth, funded like a job's: the bytes
    -- reserved now, the bytes waiting for victims and the victims awaited.
    rqActive ∷ !Word64
  , rqDeferred ∷ !Word64
  , rqAwaiting ∷ !(Map RegionKey Word64)
  }
  deriving stock (Eq, Show)

data View = View
  { vwArena ∷ !ArenaId
  , vwDemand ∷ ![RegionDemand]
  , vwFailed ∷ !(Set RegionCoord)
  }
  deriving stock (Eq, Show)

data Hold = Hold
  { hdArena ∷ !ArenaId
  , hdKind ∷ !HoldKind
  , hdRegions ∷ ![RegionCoord]
  }
  deriving stock (Eq, Show)

-- | The model value. Its constructor is private.
data Model = Model
  { mLimits ∷ !Limits
  , mClock ∷ !Word64
  , mNextJob ∷ !Word64
  , mArenaHigh ∷ !(Maybe ArenaId)
  , mArenas ∷ !(Map ArenaId Arena)
  , mTargets ∷ !(Map RegionKey Target)
  , mJobs ∷ !(Map JobId Job)
  , mRequests ∷ !(Map RequestId Request)
  , mViews ∷ !(Map ViewId View)
  , mHolds ∷ !(Map HoldId Hold)
  }
  deriving stock (Eq, Show)

-- | A model with nothing resident, accepted or reserved.
newModel ∷ Limits → Model
newModel limits =
  Model
    { mLimits = limits
    , mClock = 0
    , mNextJob = 0
    , mArenaHigh = Nothing
    , mArenas = Map.empty
    , mTargets = Map.empty
    , mJobs = Map.empty
    , mRequests = Map.empty
    , mViews = Map.empty
    , mHolds = Map.empty
    }

modelLimits ∷ Model → Limits
modelLimits = mLimits

modelClock ∷ Model → Word64
modelClock = mClock

-- ---------------------------------------------------------------------------
-- Ledgers

-- | One bank's separate figures. Occupied bytes are physically held; reserved
-- bytes are promised to accepted work and not yet occupied; the rest is free.
data Ledger = Ledger
  { ledgerLimit ∷ !Word64
  , ledgerOccupied ∷ !Word64
  , ledgerReserved ∷ !Word64
  }
  deriving stock (Eq, Show)

residentTargets ∷ Model → [(RegionKey, Residence)]
residentTargets m = [(k, r) | (k, Target (Just r) _) ← Map.toAscList (mTargets m)]

interestCount ∷ Model → Word64
interestCount m = fromIntegral (sum [Map.size (tgInterests t) | t ← Map.elems (mTargets m)])

bankLedger ∷ Model → Bank → Ledger
bankLedger m bank = case bank of
  ResidentBank →
    Ledger limit (sum [rsBytes r | (_, r) ← residentTargets m]) (sum [jbActive j | j ← Map.elems (mJobs m)] + sum [rqActive r | r ← Map.elems (mRequests m)])
  EditBank →
    Ledger
      limit
      (sum [arRetained a | a ← Map.elems (mArenas m)])
      (sum [erRetained e | Request {rqEdit = Just e} ← Map.elems (mRequests m)])
  StagingBank →
    Ledger
      limit
      ( sum [rqBytes r | r ← Map.elems (mRequests m)]
          + interestCount m * interestRecordBytes
          + sum [fromIntegral (length (hdRegions h)) * holdRecordBytes | h ← Map.elems (mHolds m)]
          + sum [descriptionBytes (fromIntegral (length (vwDemand v))) | v ← Map.elems (mViews m)]
          + sum [d | (_, Residence {rsHandoff = Just (d, _)}) ← residentTargets m]
      )
      (sum [jbScratch j | j ← Map.elems (mJobs m)] + sum [erStaging e | Request {rqEdit = Just e} ← Map.elems (mRequests m)])
  where
    limit = limitBytes (mLimits m) bank

freeBytes ∷ Ledger → Word64
freeBytes (Ledger l o r) = l - min l (o + r)

-- | Slots in use. 'ViewPinSlot' is counted per view by 'viewPins'; here it is
-- the largest count over views.
slotInUse ∷ Model → Slot → Word64
-- A load-job slot is taken when a job is dispatched and held until it completes or
-- its cancellation is acknowledged; an admitted job waiting its turn holds only its
-- reservation.
slotInUse m LoadJobSlot = fromIntegral (Map.size (Map.filter (\j → jbState j /= JobPending) (mJobs m)))
slotInUse m CommandSlot = fromIntegral (Map.size (mRequests m))
slotInUse m ViewPinSlot = maximum (0 : [viewPins m v | v ← Set.toList (Set.fromList [v' | Hold {hdKind = Pin v'} ← Map.elems (mHolds m)])])

-- | The pinned view revisions of one view.
viewPins ∷ Model → ViewId → Word64
viewPins m v = fromIntegral (length [() | Hold {hdKind = Pin v'} ← Map.elems (mHolds m), v' == v])

-- ---------------------------------------------------------------------------
-- Observation

data ArenaInfo = ArenaInfo
  { arenaId ∷ !ArenaId
  , arenaPhase ∷ !ArenaPhase
  , arenaRevision ∷ !Revision
  , arenaRetainedBytes ∷ !Word64
  }
  deriving stock (Eq, Show)

modelArenas ∷ Model → [ArenaInfo]
modelArenas m = [ArenaInfo a (arPhase x) (arRevision x) (arRetained x) | (a, x) ← Map.toAscList (mArenas m)]

data RegionInfo = RegionInfo
  { regionArena ∷ !ArenaId
  , regionCoord ∷ !RegionCoord
  , regionCoverage ∷ !Coverage
  , regionBytes ∷ !Word64
  , regionLastUse ∷ !Word64
  , regionDirty ∷ !Bool
  , -- | The removals committed in this region so far.
    regionGeneration ∷ !Word64
  , regionHandoff ∷ !(Maybe Word64)
  , regionEvicting ∷ !Bool
  }
  deriving stock (Eq, Show)

modelRegions ∷ Model → [RegionInfo]
modelRegions m =
  [ RegionInfo a r (rsCoverage x) (rsBytes x) (rsLastUse x) (rsDirty x) (rsGeneration x) (fmap fst (rsHandoff x)) (rsEvicting x)
  | ((a, r), x) ← residentTargets m
  ]

data JobPhase = JobWaiting | JobQueued | JobRunningPhase | JobCancellingPhase
  deriving stock (Eq, Show)

data JobInfo = JobInfo
  { jobId ∷ !JobId
  , jobArena ∷ !ArenaId
  , jobRevision ∷ !Revision
  , jobRegion ∷ !RegionCoord
  , jobCoverage ∷ !Coverage
  , jobPhase ∷ !JobPhase
  , jobStale ∷ !Bool
  , jobActive ∷ !Word64
  , jobDeferred ∷ !Word64
  , jobScratch ∷ !Word64
  , jobSkips ∷ !Word64
  }
  deriving stock (Eq, Show)

modelJobs ∷ Model → [JobInfo]
modelJobs m =
  [ JobInfo i (jbArena j) (jbRevision j) (jbRegion j) (jbCoverage j) (phase j) (jbStale j) (jbActive j) (jbDeferred j) (jbScratch j) (jbSkips j)
  | (i, j) ← Map.toAscList (mJobs m)
  ]
  where
    phase j = case jbState j of
      JobRunning → JobRunningPhase
      JobCancelling → JobCancellingPhase
      JobPending | jbDeferred j > 0 → JobWaiting
      JobPending → JobQueued

data InterestInfo = InterestInfo
  { interestOwner ∷ !Owner
  , interestArena ∷ !ArenaId
  , interestRegion ∷ !RegionCoord
  , interestCoverage ∷ !Coverage
  }
  deriving stock (Eq, Show)

modelInterests ∷ Model → [InterestInfo]
modelInterests m =
  [ InterestInfo o a r (inCoverage i)
  | ((a, r), t) ← Map.toAscList (mTargets m)
  , (o, i) ← Map.toAscList (tgInterests t)
  ]

data ViewInfo = ViewInfo
  { viewId ∷ !ViewId
  , viewArena ∷ !ArenaId
  , viewDemand ∷ ![RegionDemand]
  , -- | Regions of the latest demand with no interest of this view yet.
    viewPending ∷ ![RegionCoord]
  , viewFailed ∷ ![RegionCoord]
  }
  deriving stock (Eq, Show)

modelViews ∷ Model → [ViewInfo]
modelViews m =
  [ ViewInfo v (vwArena x) (vwDemand x) pending (Set.toAscList (vwFailed x))
  | (v, x) ← Map.toAscList (mViews m)
  , let pending = [demandRegion d | d ← vwDemand x, not (hasInterest m (vwArena x, demandRegion d) (OwnerView v))]
  ]

-- | An accepted, unsettled request.
data RequestInfo = RequestInfo
  { requestId ∷ !RequestId
  , requestArena ∷ !ArenaId
  , requestRegions ∷ ![RegionCoord]
  , -- | Whether it holds a removal's edit and staging reservations.
    requestRemoval ∷ !Bool
  , -- | The removal's resident growth reserved now and still waiting for victims.
    requestResidentActive ∷ !Word64
  , requestResidentDeferred ∷ !Word64
  , -- | The cell a removal is for.
    requestRemovalCell ∷ !(Maybe Coverage)
  }
  deriving stock (Eq, Show)

modelRequests ∷ Model → [RequestInfo]
modelRequests m = [RequestInfo r (rqArena x) (rqRegions x) (isJust (rqEdit x)) (rqActive x) (rqDeferred x) (fmap erCoverage (rqEdit x)) | (r, x) ← Map.toAscList (mRequests m)]

modelHolds ∷ Model → [(HoldId, ArenaId, HoldKind, [RegionCoord])]
modelHolds m = [(h, hdArena x, hdKind x, hdRegions x) | (h, x) ← Map.toAscList (mHolds m)]

hasInterest ∷ Model → RegionKey → Owner → Bool
hasInterest m key owner = maybe False (Map.member owner . tgInterests) (Map.lookup key (mTargets m))

-- ---------------------------------------------------------------------------
-- Stepping

-- | Apply one event. A refusal returns the model unchanged. After an accepted
-- event, any retiring arena whose in-flight work, holds and handoffs have all
-- acknowledged is released in the same step.
step ∷ Model → Event → (Model, Either Refusal Report)
step m event
  | mClock m == maxBound = (m, Left (ContractFailure ClockExhausted))
  | otherwise = case run m {mClock = mClock m + 1} event of
      Left refusal → (m, Left refusal)
      Right (m1, decision) →
        let (m2, settled) = settleAll m1
            funded = [i | (i, j) ← Map.toAscList (mJobs m), jbDeferred j > 0, Just j' ← [Map.lookup i (mJobs m2)], jbDeferred j' == 0]
         in -- The one gate: no transition's result is returned unless it obeys the
            -- charge rules, so a rule cannot be bypassed by a path that forgot it.
            case chargeCheck m2 of
              [] → (m2, Right (Report decision settled funded))
              (v : _) → (m, Left (ContractFailure (ChargeBreached v)))

type Run = Either Refusal (Model, Decision)

-- | An owner's report is accepted only if the state it produces obeys the charge rules;
-- an impossible figure is a contract failure and changes nothing.
guardCharge ∷ Model → Decision → Run
guardCharge m decision = case chargeCheck m of
  [] → Right (m, decision)
  (RegionOverMaximum _ bytes largest : _) → Left (ContractFailure (RegionExceedsMaximum bytes largest))
  (v : _) → Left (ContractFailure (ChargeBreached v))

run ∷ Model → Event → Run
run m = \case
  OpenArena a rev
    | maybe False (a <=) (mArenaHigh m) → Left (Invalid (ArenaNotIncreasing a))
    | otherwise →
        Right
          ( m {mArenaHigh = Just a, mArenas = Map.insert a (Arena ArenaLive rev 0) (mArenas m)}
          , ArenaOpened
          )
  RetireArena a → do
    arena ← knownArena m a
    case arPhase arena of
      ArenaRetiringPhase → Left (Stale (ArenaRetiring a))
      ArenaLive → do
        let owners =
              [OwnerRequest r | (r, q) ← Map.toList (mRequests m), rqArena q == a]
                <> [OwnerView v | (v, w) ← Map.toList (mViews m), vwArena w == a]
            m1 =
              m
                { mArenas = Map.insert a arena {arPhase = ArenaRetiringPhase} (mArenas m)
                , mRequests = Map.filter ((/= a) . rqArena) (mRequests m)
                , mViews = Map.filter ((/= a) . vwArena) (mViews m)
                }
            (m2, gone, cancelling) = pruneJobs (foldl' (flip withdrawOwner) m1 owners)
        Right (m2, ArenaRetirement gone cancelling)
  SubmitQuery rid a rev demands → submit m rid a rev demands Nothing
  SubmitRemoval rid a rev tile → do
    let (region, local) = decomposeTile tile
        cover = coverageTile local
    submit m rid a rev [RegionDemand region cover] (Just (region, cover))
  SetCameraDemand v a demands → setCamera m v a demands
  ClearCameraDemand v → case Map.lookup v (mViews m) of
    Nothing → Left (Stale (UnknownView v))
    Just w →
      let m1 = withdrawOwner (OwnerView v) m {mViews = Map.delete v (mViews m)}
          (m2, gone, cancelling) = pruneJobs m1
       in Right (m2, CameraCleared (map demandRegion (vwDemand w)) gone cancelling)
  Withdraw rid → case Map.lookup rid (mRequests m) of
    Nothing → Left (Stale (UnknownRequest rid))
    Just _ →
      let m1 = withdrawOwner (OwnerRequest rid) m {mRequests = Map.delete rid (mRequests m)}
          (m2, gone, cancelling) = pruneJobs m1
       in Right (m2, Withdrawn gone cancelling)
  Service → Right (service m)
  Dispatch → Right (dispatch m)
  JobCompleted j cost → completeJob m j cost
  JobFailed j → failJob m j
  JobAcknowledged j → case Map.lookup j (mJobs m) of
    Nothing → Left (Stale (UnknownJob j))
    Just job
      | jbState job == JobCancelling → Right (m {mJobs = Map.delete j (mJobs m)}, Discarded j)
      | otherwise → Left (ContractFailure (JobNotCancelling j))
  RemovalCommitted rid newRev actual growth → commitRemoval m rid newRev actual growth
  AcquireHold h a kind regions → acquireHold m h a kind regions
  ReleaseHold h
    | Map.member h (mHolds m) → Right (m {mHolds = Map.delete h (mHolds m)}, HoldReleased)
    | otherwise → Left (Stale (UnknownHold h))
  BeginHandoff a region dup → beginHandoff m a region dup
  HandoffConfirmed a region → endHandoff m a region True
  HandoffFailed a region → endHandoff m a region False
  VictimReleased a region → case Map.lookup (a, region) (mTargets m) of
    Just t@Target {tgResident = Just r}
      | rsEvicting r → Right (releaseVictim (a, region) (setResident (a, region) Nothing t m), VictimFreed)
    _ → Left (Stale (NotEvicting region))

knownArena ∷ Model → ArenaId → Either Refusal Arena
knownArena m a = maybe (Left (Stale (UnknownArena a))) Right (Map.lookup a (mArenas m))

liveArena ∷ Model → ArenaId → Either Refusal Arena
liveArena m a = do
  arena ← knownArena m a
  case arPhase arena of
    ArenaLive → Right arena
    ArenaRetiringPhase → Left (Stale (ArenaRetiring a))

-- ---------------------------------------------------------------------------
-- Target and job plumbing

setResident ∷ RegionKey → Maybe Residence → Target → Model → Model
setResident key res t m = putTarget key t {tgResident = res} m

putTarget ∷ RegionKey → Target → Model → Model
putTarget key t m
  | isNothing (tgResident t) && Map.null (tgInterests t) = m {mTargets = Map.delete key (mTargets m)}
  | otherwise = m {mTargets = Map.insert key t (mTargets m)}

-- | Drop every interest of an owner everywhere.
withdrawOwner ∷ Owner → Model → Model
withdrawOwner owner m =
  m
    { mTargets =
        Map.filter (\t → isJust (tgResident t) || not (Map.null (tgInterests t))) $
          Map.map (\t → t {tgInterests = Map.delete owner (tgInterests t)}) (mTargets m)
    }

jobsFor ∷ Model → RegionKey → [(JobId, Job)]
jobsFor m (a, r) = [(i, j) | (i, j) ← Map.toAscList (mJobs m), jbArena j == a, jbRegion j == r]

-- | What a region will know without new work: resident detail plus the
-- coverage of every live (not cancelling, not stale) job.
haveCoverage ∷ Model → RegionKey → Coverage
haveCoverage m key =
  foldr
    coverageUnion
    (maybe emptyCover (rsCoverage) (Map.lookup key (mTargets m) >>= tgResident))
    [jbCoverage j | (_, j) ← jobsFor m key, jbState j /= JobCancelling, not (jbStale j)]

emptyCover ∷ Coverage
emptyCover = coverageDifference whole whole
  where
    whole = either (error "emptyCover") id (coverageBox 0 1 0 1 0 1)

-- | A job is needed while some interest of its target intersects its coverage.
neededBy ∷ Model → Job → [(Owner, Interest)]
neededBy m j =
  [ (o, i)
  | Just t ← [Map.lookup (jbArena j, jbRegion j) (mTargets m)]
  , (o, i) ← Map.toList (tgInterests t)
  , coverageIntersects (inCoverage i) (jbCoverage j)
  ]

-- | Remove jobs nobody needs: pending ones are dropped (their reservations
-- return), running ones are marked cancelling and keep their reservations until
-- acknowledged. Returns the dropped and the newly cancelling jobs.
pruneJobs ∷ Model → (Model, [JobId], [JobId])
pruneJobs m =
  let unneeded = [(i, j) | (i, j) ← Map.toAscList (mJobs m), jbState j /= JobCancelling, null (neededBy m j)]
      gone = [i | (i, j) ← unneeded, jbState j == JobPending]
      cancelling = [i | (i, j) ← unneeded, jbState j == JobRunning]
      jobs1 = foldr Map.delete (mJobs m) gone
      jobs2 = foldr (Map.adjust (\j → j {jbState = JobCancelling})) jobs1 cancelling
   in (m {mJobs = jobs2}, gone, cancelling)

-- | Convert a released victim's credit into the funding of the jobs awaiting it.
releaseVictim ∷ RegionKey → Model → Model
releaseVictim key m = m {mJobs = Map.map convert (mJobs m), mRequests = Map.map convertRequest (mRequests m)}
  where
    convert j = case Map.lookup key (jbAwaiting j) of
      Nothing → j
      Just credit →
        j {jbActive = jbActive j + credit, jbDeferred = jbDeferred j - credit, jbAwaiting = Map.delete key (jbAwaiting j)}
    convertRequest q = case Map.lookup key (rqAwaiting q) of
      Nothing → q
      Just credit →
        q {rqActive = rqActive q + credit, rqDeferred = rqDeferred q - credit, rqAwaiting = Map.delete key (rqAwaiting q)}

-- | Release every retiring arena whose in-flight work has all acknowledged.
settleAll ∷ Model → (Model, [ArenaId])
settleAll m0 = foldl' settle (m0, []) [a | (a, x) ← Map.toAscList (mArenas m0), arPhase x == ArenaRetiringPhase]
  where
    settle (m, done) a
      | ready m a =
          let keys = [k | k@(a', _) ← Map.keys (mTargets m), a' == a]
           in (m {mTargets = foldr Map.delete (mTargets m) keys, mArenas = Map.delete a (mArenas m)}, done <> [a])
      | otherwise = (m, done)
    ready m a =
      null (jobsFor' m a)
        && null [() | h ← Map.elems (mHolds m), hdArena h == a]
        && null [() | ((a', _), Target {tgResident = Just Residence {rsHandoff = Just _}}) ← Map.toList (mTargets m), a' == a]
        -- A committed victim's credit funds another admission only once the owner
        -- has reported the physical release: retirement waits for it too.
        && null [() | ((a', _), Target {tgResident = Just Residence {rsEvicting = True}}) ← Map.toList (mTargets m), a' == a]
    jobsFor' m a = [() | j ← Map.elems (mJobs m), jbArena j == a]

-- ---------------------------------------------------------------------------
-- Admission

-- | Why a resident region may not be chosen as a victim, if it may not.
-- | Whether every cell of a region key is a supported tile: its lowest and
-- highest cells both compose into the supported coordinate range.
supportedRegion ∷ RegionCoord → Bool
supportedRegion region = case (mkLocalCoord 0 0 0, mkLocalCoord 15 15 31) of
  (Right low, Right high) → isRight (composeTile region low) && isRight (composeTile region high)
  _ → False

data Block = BlockEvicting | BlockHandoff | BlockDirty | BlockHeld | BlockInterest | BlockJob
  deriving stock (Eq, Show)

-- | The first reason a resident region cannot be a victim. An explicit request may
-- take a region only a camera view has an interest in (camera work is best effort
-- and yields to explicit work; the view's interest is dropped and the region is
-- pending again), while camera work never takes a region anyone has an interest
-- in. A region with a job, a hold, unsettled changes or a handoff is never taken.
blockOf ∷ Bool → Set RegionKey → Set RegionKey → RegionKey → Target → Residence → Maybe Block
blockOf explicit held jobKeys key t r
  | rsEvicting r = Just BlockEvicting
  | isJust (rsHandoff r) = Just BlockHandoff
  | rsDirty r = Just BlockDirty
  | Set.member key held = Just BlockHeld
  | interested = Just BlockInterest
  | Set.member key jobKeys = Just BlockJob
  | otherwise = Nothing
  where
    interested
      | explicit = or [True | OwnerRequest _ ← Map.keys (tgInterests t)]
      | otherwise = not (Map.null (tgInterests t))

-- | A job to create: the cells it loads, its resident reservation and its scratch.
data NewJob = NewJob !Coverage !Word64 !Word64

njNeed, njScratch ∷ NewJob → Word64
njNeed (NewJob _ need _) = need
njScratch (NewJob _ _ scratch) = scratch

data UnitPlan = UnitPlan
  { upDemand ∷ !RegionDemand
  , upNewInterest ∷ !Bool
  , upJob ∷ !(Maybe NewJob)
  }

-- | Extra reservations an admission carries beyond its units.
data Extras = Extras
  { exCommand ∷ !Bool
  , exRequestBytes ∷ !Word64
  , exEdit ∷ !Bool
  , -- | Regions that may not be chosen as victims for this admission, besides the
    -- ones it names: the rest of a camera demand, which it must not evict to load
    -- an earlier region of the same demand.
    exProtect ∷ !(Set RegionKey)
  }

noExtras ∷ Extras
noExtras = Extras False 0 False Set.empty

planUnit ∷ Model → ArenaId → Owner → RegionDemand → Either Refusal UnitPlan
planUnit m arena owner d@(RegionDemand region cover) = do
  let key = (arena, region)
      target = Map.lookup key (mTargets m)
      resident = target >>= tgResident
  case resident of
    Just r | rsEvicting r → Left (Busy (RegionEvicting region))
    _ → Right ()
  let have = haveCoverage m key
      delta = coverageDifference cover have
  job ←
    if coverageIsEmpty delta
      then Right Nothing
      else do
        bytes ← maybe (Left (Invalid CostArithmetic)) Right (costBytes (reserveCost delta))
        need ← maybe (Left (Invalid CostArithmetic)) Right (checkedAdd bytes (if isNothing resident then regionMetadataBytes else 0))
        Right (Just (NewJob delta need (scratchBytes delta)))
  pure (UnitPlan d (maybe True (not . Map.member owner . tgInterests) target) job)

-- | The units, the funding of each new job (active bytes, deferred bytes and the
-- victims it awaits) and the committed victims.
data Plan = Plan ![UnitPlan] ![(Word64, Word64, Map RegionKey Word64)] ![RegionKey]

-- | Plan an admission of units for one owner in one arena: validate it can ever
-- fit, check every slot and bank in a fixed order and fund the resident bytes
-- from free capacity plus a committed eviction set. Nothing is changed.
planAdmission ∷ Model → ArenaId → Owner → [RegionDemand] → Extras → Either Refusal Plan
planAdmission m arena owner demands extras = do
  -- No capacity check can refuse permanently here: a request within its caps
  -- fits an empty model by the minimum budgets 'mkLimits' enforced, so every
  -- shortfall below is pressure (busy), or exhausted retained edits.
  units ← mapM (planUnit m arena owner) demands
  let jobs = [j | UnitPlan {upJob = Just j} ← units]
      newInterests = fromIntegral (length [() | u ← units, upNewInterest u])
      nJobs = fromIntegral (length jobs) ∷ Word64
      nCommands = if exCommand extras then 1 else 0
      growth = if exEdit extras then removalResidentGrowthBytes else 0
      stagingNeed = newInterests * interestRecordBytes + sum (map njScratch jobs) + exRequestBytes extras
      editNeed = if exEdit extras then removalRetainedBytes else 0
  -- Retained edits are exhausted, not merely busy, when the committed bytes
  -- plus this edit cannot fit even with every reservation returned.
  let editLedger = bankLedger m EditBank
  if editNeed > 0 && ledgerOccupied editLedger + editNeed > ledgerLimit editLedger
    then Left (RetainedEditsExhausted EditBank (ledgerLimit editLedger) (ledgerOccupied editLedger) editNeed)
    else Right ()
  slotFree CommandSlot nCommands
  if stagingNeed > 0 then bankFree StagingBank (stagingNeed + stagingHeadroom) else Right ()
  bankFree EditBank editNeed
  if nJobs > maxBound - mNextJob m then Left (ContractFailure JobIdsExhausted) else Right ()
  -- Resident funding: free bytes first, in unit order; the rest from victims.
  let free0 = freeBytes (bankLedger m ResidentBank)
      split _ [] = []
      split free (need : needs) = let active = min free need in (active, need - active) : split (free - active) needs
      -- Each new job is funded in turn, then a removal's resident growth.
      parts = split free0 (map njNeed jobs <> [growth | exEdit extras])
      shortfall = sum (map snd parts)
  (funding, victims) ←
    if shortfall == 0
      then Right ([(a, d, Map.empty) | (a, d) ← parts], [])
      else fundByEviction m explicit (Set.union (exProtect extras) (Set.fromList [(arena, demandRegion d) | d ← demands])) parts shortfall
  -- Camera work draws only on the camera share: the state this admission would produce
  -- must obey the charge rules, or the camera waits (busy) and explicit work keeps its
  -- reserve.
  let plan = Plan units funding victims
  if explicit
    then Right ()
    else
      let (m1, _, _) = applyPlan m arena owner plan
          before = ccTotal (cameraCharge m)
       in case [v | v@(CameraResidentOverShare _ _) ← admissionCheck m1] of
            (CameraResidentOverShare used cap : _) → Left (Busy (BankFull ResidentBank cap before (used - min used before)))
            _ → Right ()
  pure plan
  where
    explicit = case owner of
      OwnerRequest _ → True
      OwnerView _ → False
    -- Camera work is best effort and leaves room for explicit requests: the staging
    -- bytes the largest explicit request needs.
    stagingHeadroom = if explicit then 0 else limitExplicitStagingBytes (mLimits m)
    slotFree slot n =
      let total = limitSlot (mLimits m) slot
          used = slotInUse m slot
       in if n > 0 && used + n > total then Left (Busy (SlotFull slot total used n)) else Right ()
    bankFree bank n =
      let l = bankLedger m bank
       in if n > freeBytes l then Left (Busy (BankFull bank (ledgerLimit l) (ledgerOccupied l + ledgerReserved l) n)) else Right ()

-- | Choose victims, in LRU order, to fund the deferred part of each job.
fundByEviction ∷ Model → Bool → Set RegionKey → [(Word64, Word64)] → Word64 → Either Refusal ([(Word64, Word64, Map RegionKey Word64)], [RegionKey])
fundByEviction m explicit exclude parts shortfall =
  case assign parts [] [] candidates of
    Just (funding, used) → Right (funding, used)
    Nothing →
      Left
        ( Busy
            ( NoEligibleEviction
                shortfall
                (sum (map snd candidates))
                (blockers m explicit exclude held jobKeys)
            )
        )
  where
    held = Set.fromList [(hdArena h, r) | h ← Map.elems (mHolds m), r ← hdRegions h]
    jobKeys = Set.fromList [(jbArena j, jbRegion j) | j ← Map.elems (mJobs m)]
    candidates =
      map (\(k, _, b) → (k, b)) . sortOn (\(k, u, _) → (u, k)) $
        [ (key, rsLastUse r, rsBytes r)
        | (key@(a, _), t@Target {tgResident = Just r}) ← Map.toAscList (mTargets m)
        , maybe False ((== ArenaLive) . arPhase) (Map.lookup a (mArenas m))
        , not (Set.member key exclude)
        , isNothing (blockOf explicit held jobKeys key t r)
        ]
    -- Victims are shared across the jobs of one admission: each job takes the
    -- credit it lacks from the least recently used victims in turn, and a
    -- victim's bytes are never promised twice.
    assign [] acc used _ = Just (reverse acc, used)
    assign ((active, deferred) : rest) acc used pool
      | deferred == 0 = assign rest ((active, 0, Map.empty) : acc) used pool
      | otherwise = do
          (taken, pool') ← takeFor deferred pool
          assign rest ((active, deferred, Map.fromList taken) : acc) (used <> [k | (k, _) ← taken, k `notElem` used]) pool'
    takeFor 0 pool = Just ([], pool)
    takeFor _ [] = Nothing
    takeFor need ((k, remaining) : pool)
      | remaining == 0 = takeFor need pool
      | otherwise =
          let credit = min remaining need
              pool' = if remaining == credit then pool else (k, remaining - credit) : pool
           in fmap (\(t, r) → ((k, credit) : t, r)) (takeFor (need - credit) pool')

blockers ∷ Model → Bool → Set RegionKey → Set RegionKey → Set RegionKey → Blockers
blockers m explicit exclude held jobKeys =
  foldl' count (Blockers 0 0 0 0 0 0 0) [(k, t, r) | (k, t@Target {tgResident = Just r}) ← Map.toAscList (mTargets m)]
  where
    count b (k, t, r)
      | Set.member k exclude = b {blockedByRequest = blockedByRequest b + 1}
      | otherwise = case blockOf explicit held jobKeys k t r of
          Nothing → b
          Just BlockEvicting → b {blockedEvicting = blockedEvicting b + 1}
          Just BlockHandoff → b {blockedHandoff = blockedHandoff b + 1}
          Just BlockDirty → b {blockedDirty = blockedDirty b + 1}
          Just BlockHeld → b {blockedHeld = blockedHeld b + 1}
          Just BlockInterest → b {blockedInterest = blockedInterest b + 1}
          Just BlockJob → b {blockedJob = blockedJob b + 1}

-- | Apply a plan: add the interests, create the jobs funded as planned and
-- commit the victims.
applyPlan ∷ Model → ArenaId → Owner → Plan → (Model, Admission, Maybe (Word64, Word64, Map RegionKey Word64))
applyPlan m arena owner (Plan units funding victims) =
  let clock = mClock m
      revision = maybe (Revision 0) arRevision (Map.lookup arena (mArenas m))
      withInterest mm (UnitPlan (RegionDemand region cover) _ _) =
        let key = (arena, region)
            t = fromMaybe (Target Nothing Map.empty) (Map.lookup key (mTargets mm))
            served = maybe clock inServed (Map.lookup owner (tgInterests t))
            t' =
              t
                { tgInterests = Map.insert owner (Interest cover served) (tgInterests t)
                , tgResident = fmap (\r → r {rsLastUse = clock}) (tgResident t)
                }
         in mm {mTargets = Map.insert key t' (mTargets mm)}
      m1 = foldl' withInterest m units
      m2 = foldl' markVictim m1 victims
      markVictim mm key = case Map.lookup key (mTargets mm) of
        -- A victim loses any camera interest in it (only an explicit request can take a
        -- region a view has an interest in); the view's demand for it is pending again.
        Just t@Target {tgResident = Just r} → mm {mTargets = Map.insert key t {tgResident = Just r {rsEvicting = True}, tgInterests = Map.filterWithKey (\o _ → case o of OwnerRequest _ → True; OwnerView _ → False) (tgInterests t)} (mTargets mm)}
        _ → mm
      newJobs = [(u, j) | u@UnitPlan {upJob = Just j} ← units]
      allocate (mm, acc) ((UnitPlan (RegionDemand region _) _ _, NewJob delta _ scratch), (active, deferred, awaiting)) =
        let jid = JobId (mNextJob mm)
            job = Job arena revision region delta JobPending active deferred awaiting scratch 0 False (case owner of OwnerView _ → True; OwnerRequest _ → False)
         in (mm {mNextJob = mNextJob mm + 1, mJobs = Map.insert jid job (mJobs mm)}, acc <> [(jid, region)])
      (m3, created) = foldl' allocate (m2, []) (zip newJobs funding)
      -- Whatever funding is left after the jobs belongs to a removal's growth.
      requestFunding = listToMaybe (drop (length newJobs) funding)
      shared = [demandRegion (upDemand u) | u ← units, isNothing (upJob u)]
      deferredTotal = sum [d | (_, d, _) ← funding]
   in (m3, Admission created shared victims deferredTotal, requestFunding)

submit ∷ Model → RequestId → ArenaId → Revision → [RegionDemand] → Maybe (RegionCoord, Coverage) → Run
submit m rid a rev demands edit = do
  if Map.member rid (mRequests m) then Left (Invalid (DuplicateRequest rid)) else Right ()
  arena ← liveArena m a
  if arRevision arena /= rev then Left (Stale (RevisionMismatch (arRevision arena) rev)) else Right ()
  checkDemand m (Just (limitQueryRegions (mLimits m))) demands
  let count = fromIntegral (length demands)
      recordBytes = commandRecordBytes count
      extras = Extras True (recordBytes + maybe 0 (const removalStagingBytes) edit) (isJust edit) Set.empty
  plan ← planAdmission m a (OwnerRequest rid) demands extras
  let (m1, admission, funding) = applyPlan m a (OwnerRequest rid) plan
      reservation = fmap (\(r, c) → EditReservation r c rev removalRetainedBytes removalStagingBytes) edit
      (active, deferred, awaiting) = fromMaybe (0, 0, Map.empty) funding
      request = Request a (map demandRegion demands) recordBytes reservation active deferred awaiting
  Right (m1 {mRequests = Map.insert rid request (mRequests m1)}, Accepted admission)

-- | The request-only checks: a nonempty demand of distinct, supported regions
-- within the cap for its kind (an explicit request has one; camera demand is best
-- effort and has none), naming only cells inside the configured extent.
-- Nothing here reads the model's state, so what fails is invalid from every state.
checkDemand ∷ Model → Maybe Word64 → [RegionDemand] → Either Refusal ()
checkDemand m cap demands = do
  if null demands then Left (Invalid EmptyDemand) else Right ()
  case cap of
    Just limit | fromIntegral (length demands) > limit → Left (Invalid (DemandTooLarge (length demands) limit))
    _ → Right ()
  let regions = map demandRegion demands
  case [r | (r, n) ← Map.toList (Map.fromListWith (+) [(r', 1 ∷ Int) | r' ← regions]), n > 1] of
    (r : _) → Left (Invalid (DuplicateRegion r))
    [] → Right ()
  case filter (not . supportedRegion) regions of
    (r : _) → Left (Invalid (UnsupportedRegion r))
    [] → Right ()
  case [demandRegion d | d ← demands, not (coverageWithin (limitExtent (mLimits m)) (demandCoverage d))] of
    (r : _) → Left (Invalid (OutsideExtent r))
    [] → Right ()

-- ---------------------------------------------------------------------------
-- Camera demand

-- | The staging bytes camera work may still use: what is free beyond the headroom
-- kept for explicit requests.
cameraFree ∷ Model → Ledger → Word64
cameraFree m staging =
  let free = freeBytes staging
      headroom = limitExplicitStagingBytes (mLimits m)
   in if free > headroom then free - headroom else 0

-- | Normalize a camera description: unsupported keys are excluded, cells outside the
-- configured extent are clipped away (a region left with none is excluded), and
-- repeated keys coalesce into the first occurrence, which keeps the priority order.
normalizeCamera ∷ (Int, Int, Int) → [RegionDemand] → ([RegionDemand], [RegionCoord])
normalizeCamera extent = foldl' step' ([], [])
  where
    (ex, ey, ez) = extent
    window = either (const Nothing) Just (coverageBox 0 ex 0 ey 0 ez)
    clip cover = case window of
      Just box → coverageDifference cover (coverageDifference cover box)
      Nothing → cover
    step' (kept, excluded) (RegionDemand region cover)
      | not (supportedRegion region) = (kept, excluded <> [region | region `notElem` excluded])
      | coverageIsEmpty clipped = (kept, excluded <> [region | region `notElem` excluded])
      | any ((== region) . demandRegion) kept =
          (map (\d → if demandRegion d == region then d {demandCoverage = coverageUnion (demandCoverage d) clipped} else d) kept, excluded)
      | otherwise = (kept <> [RegionDemand region clipped], excluded)
      where
        clipped = clip cover

-- | Withdraw a view's demand: its interests, description and unneeded jobs.
clearView ∷ Model → ViewId → (Model, [RegionCoord], [JobId], [JobId])
clearView m v = case Map.lookup v (mViews m) of
  Nothing → (m, [], [], [])
  Just w →
    let m1 = withdrawOwner (OwnerView v) m {mViews = Map.delete v (mViews m)}
        (m2, gone, cancelling) = pruneJobs m1
     in (m2, map demandRegion (vwDemand w), gone, cancelling)

setCamera ∷ Model → ViewId → ArenaId → [RegionDemand] → Run
setCamera m v a demands0 = do
  _ ← liveArena m a
  -- Camera demand is best effort and its description is normalized, never refused:
  -- an empty description withdraws the demand, repeated keys coalesce, unsupported
  -- keys and cells outside the extent are excluded and reported. The description is
  -- bounded: its structural maximum, and the staging the camera may use beside the
  -- headroom kept for explicit requests (the replaced description is released first),
  -- cut the end of it, the lowest priority, and the remainder is reported.
  let limits = mLimits m
      (normal, excluded) = normalizeCamera (limitExtent limits) demands0
      oldBytes = maybe 0 (descriptionBytes . fromIntegral . length . vwDemand) (Map.lookup v (mViews m))
      staging = bankLedger m StagingBank
      share = cameraFree m staging + oldBytes
      fitting = if share >= descriptionBytes 0 then (share - descriptionBytes 0) `div` 64 else 0
      keep = fromIntegral (min (min (fromIntegral (length normal)) (limitCameraRegions limits)) fitting) ∷ Int
      demands = take keep normal
      truncated = map demandRegion (drop keep normal)
  if null demands
    then
      let (mCleared, regions, gone, cancelling) = clearView m v
       in Right (mCleared, CameraSet [] [] regions gone cancelling excluded truncated)
    else setCameraNormal m v a demands excluded truncated

setCameraNormal ∷ Model → ViewId → ArenaId → [RegionDemand] → [RegionCoord] → [RegionCoord] → Run
setCameraNormal m v a demands excluded truncated = do
  let wanted = Set.fromList [(a, demandRegion d) | d ← demands]
      owner = OwnerView v
      obsolete =
        [ key
        | (key, t) ← Map.toAscList (mTargets m)
        , Map.member owner (tgInterests t)
        , not (Set.member key wanted)
        ]
      dropInterest mm key = case Map.lookup key (mTargets mm) of
        Nothing → mm
        Just t → putTarget key t {tgInterests = Map.delete owner (tgInterests t)} mm
      m1 = foldl' dropInterest m obsolete
      m2 = m1 {mViews = Map.insert v (View a demands Set.empty) (mViews m1)}
      (m3, gone, cancelling) = pruneJobs m2
      -- Only pressure leaves a region pending; any other refusal fails the event.
      -- A region that stays pending drops this view's interest in the coverage it
      -- replaced, so an obsolete interest never survives a replacement. Whatever a
      -- step leaves without an interest is pruned at once and reported, so the owner
      -- is told to cancel every job the replacement made obsolete.
      -- Regions are admitted strictly in demand order: once one is busy the rest
      -- wait behind it, so a later region never takes room an earlier one needs.
      attempt (mm, done, waiting, replaced, goneAcc, cancelAcc) d = case (if null waiting then planAdmission mm a owner [d] noExtras {exProtect = wanted} else Left (Busy (RegionEvicting (demandRegion d)))) of
        Right plan →
          let (mm', admission, _) = applyPlan mm a owner plan
              (mm'', g, c) = pruneJobs mm'
           in Right (mm'', done <> [admission], waiting, replaced, goneAcc <> g, cancelAcc <> c)
        Left (Busy _) →
          let key = (a, demandRegion d)
              old = Map.lookup key (mTargets mm) >>= Map.lookup owner . tgInterests
           in case old of
                Just i | inCoverage i /= demandCoverage d →
                  let (mm', g, c) = pruneJobs (dropInterest mm key)
                   in Right (mm', done, waiting <> [demandRegion d], replaced <> [demandRegion d], goneAcc <> g, cancelAcc <> c)
                _ → Right (mm, done, waiting <> [demandRegion d], replaced, goneAcc, cancelAcc)
        Left other → Left other
  (m4, admitted, pending, replaced, gone1, cancelling1) ← foldM attempt (m3, [], [], [], gone, cancelling) demands
  -- Dropping an obsolete interest may have freed a slot or bytes: offer them to
  -- the regions that stayed pending, once.
  (m5, admitted2, pending2, _, gone2, cancelling2) ← foldM attempt (m4, admitted, [], [], gone1, cancelling1) [d | d ← demands, demandRegion d `elem` pending]
  Right (m5, CameraSet admitted2 pending2 (map snd obsolete <> replaced) gone2 cancelling2 excluded truncated)

-- | Retry the pending part of every view's latest camera demand, in view order.
service ∷ Model → (Model, Decision)
service m0 =
  let views = Map.toAscList (mViews m0)
      go (m, acc) (v, w) = let (m', acc', _) = foldl' (try v w) (m, acc, False) (vwDemand w) in (m', acc')
      -- In demand order, like the first admission: the first region that cannot
      -- be admitted holds back the regions after it.
      try v w (m, acc, blocked) d
        | Set.member (demandRegion d) (vwFailed w) = (m, acc, blocked)
        | needs m v w d =
            if blocked
              then (m, acc, True)
              else case planAdmission m (vwArena w) (OwnerView v) [d] noExtras {exProtect = Set.fromList [(vwArena w, demandRegion x) | x ← vwDemand w]} of
                Right plan → let (m', admission, _) = applyPlan m (vwArena w) (OwnerView v) plan in (m', acc <> [(v, admission)], False)
                Left _ → (m, acc, True)
        | otherwise = (m, acc, blocked)
      needs m v w d =
        let key = (vwArena w, demandRegion d)
         in case Map.lookup key (mTargets m) >>= Map.lookup (OwnerView v) . tgInterests of
              Nothing → True
              Just _ → not (coverageSubset (demandCoverage d) (haveCoverage m key))
      (m1, admitted) = foldl' go (m0, []) views
   in (m1, Serviced admitted)

-- ---------------------------------------------------------------------------
-- Dispatch, completion and failure

-- | Pick the next queued job. Foreground work (any explicit interest) and jobs
-- passed over at least the aging threshold come first; within a class the job
-- whose interests were arrived or served longest ago comes first, then the
-- lowest job number. Every other queued job ages by one.
dispatch ∷ Model → (Model, Decision)
dispatch m =
  case sortOn rank queued of
    _ | slotInUse m LoadJobSlot >= limitSlot (mLimits m) LoadJobSlot → (m, NothingToDispatch)
    [] → (m, NothingToDispatch)
    ((jid, job, _) : _) →
      let clock = mClock m
          target = (jbArena job, jbRegion job)
          -- Every interest of each owner served is moved to the back, so the
          -- owners take turns however many regions each asked for.
          served = Set.fromList (map fst (neededBy m job))
          touchInterests t =
            t {tgInterests = Map.mapWithKey (\o i → if Set.member o served then i {inServed = clock} else i) (tgInterests t)}
          age j = j {jbSkips = jbSkips j + 1}
          jobs1 = Map.mapWithKey (\i j → if i == jid then j {jbState = JobRunning} else if isQueued j then age j else j) (mJobs m)
          targets1 = Map.map touchInterests (mTargets m)
       in (m {mJobs = jobs1, mTargets = targets1}, Dispatched jid target (jbCoverage job))
  where
    aging = limitAgingQuanta (mLimits m)
    isQueued j = jbState j == JobPending && jbDeferred j == 0
    queued =
      [ (i, j, served)
      | (i, j) ← Map.toAscList (mJobs m)
      , isQueued j
      , let needers = neededBy m j
      , let served = minimum (maxBound : [inServed n | (_, n) ← needers])
      ]
    foreground j = any (\(o, _) → case o of OwnerRequest _ → True; OwnerView _ → False) (neededBy m j)
    rank (i, j, served) = (if foreground j || jbSkips j >= aging then 0 else 1 ∷ Int, served, i)

completeJob ∷ Model → JobId → Cost → Run
completeJob m jid cost = case Map.lookup jid (mJobs m) of
  Nothing → Left (Stale (UnknownJob jid))
  Just job → case jbState job of
    JobPending → Left (ContractFailure (JobNotRunning jid))
    JobCancelling → Right (discard job)
    JobRunning → do
          let key = (jbArena job, jbRegion job)
              target = fromMaybe (Target Nothing Map.empty) (Map.lookup key (mTargets m))
              meta = if isNothing (tgResident target) then regionMetadataBytes else 0
              before = maybe 0 (coverageColumns . rsCoverage) (tgResident target)
              after = maybe (jbCoverage job) (coverageUnion (jbCoverage job) . rsCoverage) (tgResident target)
              -- A region is charged for its own column entries, once each: the
              -- columns its coverage gains, not the columns each job reports, so the
              -- charge of many jobs in one column cannot exceed the region's maximum.
              gained = coverageColumns after - before
          bytes ← maybe (Left (ContractFailure CostOverflow)) Right (costBytes cost {costColumns = gained})
          actual ← maybe (Left (ContractFailure CostOverflow)) Right (checkedAdd bytes meta)
          if actual > jbActive job then Left (ContractFailure (CostExceedsReservation (jbActive job) actual)) else Right ()
          let res = case tgResident target of
                Nothing → Residence (jbCoverage job) actual (mClock m) False 0 Nothing False
                Just r → r {rsCoverage = coverageUnion (rsCoverage r) (jbCoverage job), rsBytes = rsBytes r + actual, rsLastUse = mClock m}
              satisfied =
                [ o
                | (o, i) ← Map.toList (tgInterests target)
                , coverageIntersects (inCoverage i) (jbCoverage job)
                , coverageSubset (inCoverage i) (rsCoverage res)
                ]
              m1 = m {mJobs = Map.delete jid (mJobs m), mTargets = Map.insert key target {tgResident = Just res} (mTargets m)}
          -- (A cost that would take the region past what its extent allows is an
          -- impossible figure from the owner: the charge function refuses it.)
          guardCharge m1 (Published jid satisfied)
  where
    discard _ = (m {mJobs = Map.delete jid (mJobs m)}, Discarded jid)

failJob ∷ Model → JobId → Run
failJob m jid = case Map.lookup jid (mJobs m) of
  Nothing → Left (Stale (UnknownJob jid))
  Just job → case jbState job of
    JobPending → Left (ContractFailure (JobNotRunning jid))
    JobCancelling → Right (m {mJobs = Map.delete jid (mJobs m)}, Discarded jid)
    -- (Work a commit superseded is cancelling, handled above, so a late failure of
    -- it never reaches the running case and cannot touch current demand.)
    JobRunning →
      let key = (jbArena job, jbRegion job)
          owners = [o | (o, _) ← neededBy m job]
          dropFrom t = t {tgInterests = foldr Map.delete (tgInterests t) owners}
          m1 = m {mJobs = Map.delete jid (mJobs m)}
          m2 = case Map.lookup key (mTargets m1) of
            Nothing → m1
            Just t → putTarget key (dropFrom t) m1
          markFailed mm = case [v | OwnerView v ← owners] of
            [] → mm
            vs → mm {mViews = foldr (Map.adjust (\w → w {vwFailed = Set.insert (jbRegion job) (vwFailed w)})) (mViews mm) vs}
          (m3, gone, cancelling) = pruneJobs (markFailed m2)
       in Right (m3, JobFailedFor jid owners gone cancelling)

-- ---------------------------------------------------------------------------
-- Removal commit

commitRemoval ∷ Model → RequestId → Revision → Word64 → Word64 → Run
commitRemoval m rid newRev actual growth = do
  request ← maybe (Left (Stale (UnknownRequest rid))) Right (Map.lookup rid (mRequests m))
  reservation ← maybe (Left (ContractFailure (NotAnEdit rid))) Right (rqEdit request)
  let a = rqArena request
  arena ← liveArena m a
  if arRevision arena /= erRevision reservation then Left (Stale (RevisionMismatch (arRevision arena) (erRevision reservation))) else Right ()
  if newRev <= arRevision arena then Left (ContractFailure (RevisionNotAdvancing (arRevision arena) newRev)) else Right ()
  if actual > erRetained reservation then Left (ContractFailure (CommitExceedsReservation (erRetained reservation) actual)) else Right ()
  -- The rebuilt segment's growth must have been funded, not merely promised.
  if rqDeferred request > 0 then Left (ContractFailure (EditNotFunded rid)) else Right ()
  if growth > rqActive request then Left (ContractFailure (ResidentGrowthExceedsReservation (rqActive request) growth)) else Right ()
  let key = (a, erRegion reservation)
  target ← case Map.lookup key (mTargets m) of
    Just t@Target {tgResident = Just r}
      | not (rsEvicting r) && coverageSubset (erCoverage reservation) (rsCoverage r) → Right (t, r)
    _ → Left (ContractFailure (EditBeforeResident rid))
  let (t, r) = target
      m1 = withdrawOwner (OwnerRequest rid) m {mRequests = Map.delete rid (mRequests m)}
      -- Re-read the target after dropping this request's interest.
      t1 = fromMaybe t (Map.lookup key (mTargets m1))
      r' = r {rsDirty = True, rsGeneration = rsGeneration r + 1, rsBytes = rsBytes r + growth, rsLastUse = mClock m}
      m2 = m1 {mTargets = Map.insert key t1 {tgResident = Just r'} (mTargets m1)}
      m3 =
        m2
          { mArenas = Map.insert a arena {arRevision = newRev, arRetained = arRetained arena + actual} (mArenas m2)
          , mJobs = Map.mapMaybe (restamp a (erRegion reservation) newRev) (mJobs m2)
          }
      editedJobs = [(i, j) | (i, j) ← Map.toAscList (mJobs m2), jbArena j == a, jbRegion j == erRegion reservation]
      droppedJobs = [i | (i, j) ← editedJobs, jbState j == JobPending]
      staleJobs = [i | (i, j) ← editedJobs, jbState j == JobRunning, not (jbStale j)]
      lost =
        [ o
        | (o, i) ← Map.toList (tgInterests t1)
        , not (coverageSubset (inCoverage i) (haveCoverage m3 key))
        ]
  guardCharge m3 (Committed newRev (erRetained reservation - actual) lost droppedJobs staleJobs)
  where
    restamp a region rev j
      | jbArena j /= a = Just j
      | jbRegion j /= region = Just j {jbRevision = rev}
      | jbState j == JobPending = Nothing
      -- Superseded work that is running becomes cancelling: its result is
      -- discarded, and the owner's completion or acknowledgement releases it.
      | otherwise = Just j {jbState = JobCancelling, jbStale = True}

-- ---------------------------------------------------------------------------
-- Holds and handoffs

-- | The regions any hold protects.
heldKeys ∷ Model → Set RegionKey
heldKeys m = Set.fromList [(hdArena h, r) | h ← Map.elems (mHolds m), r ← hdRegions h]

-- ---------------------------------------------------------------------------
-- The charge function
--
-- Every bank total is /derived/ from the records ('bankLedger'); nothing stores or
-- adjusts one. The rules a total must obey are defined once, here, and every
-- transition is held to them: an admission, a hold and an owner's report are each
-- tested against the state they would produce ('admissionCheck', 'chargeCheck'), and
-- 'step' refuses any transition whose result breaks them ('ChargeBreached'). The
-- partition of each bank into an explicit reserve and a camera share, and the stored
-- maximum of a region, are enforced nowhere else.

-- | A breach of the charge rules.
data ChargeViolation
  = -- | A bank's occupied and reserved bytes, and its limit.
    BankOverLimit !Bank !Word64 !Word64
  | -- | A slot's use, and its limit.
    SlotOverLimit !Slot !Word64 !Word64
  | -- | A resident region's bytes, and the most its extent allows.
    RegionOverMaximum !RegionKey !Word64 !Word64
  | -- | What the camera side keeps out of explicit reach in the resident bank, and the
    -- camera share.
    CameraResidentOverShare !Word64 !Word64
  | -- | What the camera side uses of the staging bank, and the camera share.
    CameraStagingOverShare !Word64 !Word64
  deriving stock (Eq, Show)

-- | What the camera side keeps out of explicit reach in the resident bank: every held
-- region at its stored maximum (a pinned region can grow and cannot be evicted), the
-- reservations of the jobs created for camera views (finite work, but not reclaimable
-- while queued or running), and the detail of each other region such a job is in.
data CameraCharge = CameraCharge
  { ccHeld ∷ !Word64
  , ccReserved ∷ !Word64
  , ccDetail ∷ !Word64
  }

-- | The part of a camera charge no other transition can raise; it is held under the
-- camera share at all times. The detail of a region can also grow when an explicit job
-- completes there, which is that request's own footprint, so admission (but not the
-- invariant) counts it too.
ccStable ∷ CameraCharge → Word64
ccStable c = ccHeld c + ccReserved c

ccTotal ∷ CameraCharge → Word64
ccTotal c = ccStable c + ccDetail c

cameraCharge ∷ Model → CameraCharge
cameraCharge m =
  let storedMax = limitRegionStoredBytes (mLimits m)
      held = heldKeys m
      cameraJobs = [j | j ← Map.elems (mJobs m), jbCamera j]
      inJob = Set.fromList [(jbArena j, jbRegion j) | j ← cameraJobs, not (Set.member (jbArena j, jbRegion j) held)]
      detail key = maybe 0 rsBytes (Map.lookup key (mTargets m) >>= tgResident)
   in CameraCharge
        { ccHeld = storedMax * fromIntegral (Set.size held)
        , ccReserved = sum [jbActive j + jbDeferred j | j ← cameraJobs]
        , ccDetail = sum (map detail (Set.toList inJob))
        }

-- | The resident camera share: the bank less the most an explicit request may need.
cameraResidentCap ∷ Model → Word64
cameraResidentCap m =
  let limit = limitBytes (mLimits m) ResidentBank
      reserve = limitExplicitResidentBytes (mLimits m)
   in if limit > reserve then limit - reserve else 0

-- | The staging the camera side uses: view descriptions, the interest records of
-- views, hold records and the scratch of camera jobs.
cameraStagingUsed ∷ Model → Word64
cameraStagingUsed m =
  sum [descriptionBytes (fromIntegral (length (vwDemand v))) | v ← Map.elems (mViews m)]
    + interestRecordBytes * fromIntegral (length [() | t ← Map.elems (mTargets m), OwnerView _ ← Map.keys (tgInterests t)])
    + sum [fromIntegral (length (hdRegions h)) * holdRecordBytes | h ← Map.elems (mHolds m)]
    + sum [jbScratch j | j ← Map.elems (mJobs m), jbCamera j]

-- | The camera share of the staging bank.
cameraStagingCap ∷ Model → Word64
cameraStagingCap m =
  let limit = limitBytes (mLimits m) StagingBank
      reserve = limitExplicitStagingBytes (mLimits m)
   in if limit > reserve then limit - reserve else 0

-- | The charge rules every state obeys: no bank or slot over its limit, no region over
-- the most its extent allows, and what the camera side holds within the camera share of
-- the resident and the staging bank.
chargeCheck ∷ Model → [ChargeViolation]
chargeCheck m =
  [BankOverLimit b (ledgerOccupied l + ledgerReserved l) (ledgerLimit l) | b ← allBanks, let l = bankLedger m b, ledgerOccupied l + ledgerReserved l > ledgerLimit l]
    <> [SlotOverLimit s (slotInUse m s) (limitSlot (mLimits m) s) | s ← [LoadJobSlot, CommandSlot, ViewPinSlot], slotInUse m s > limitSlot (mLimits m) s]
    <> [RegionOverMaximum k (rsBytes r) storedMax | (k, r) ← residentTargets m, rsBytes r > storedMax]
    <> [CameraResidentOverShare (ccStable cc) (cameraResidentCap m) | ccStable cc > cameraResidentCap m]
    <> [CameraStagingOverShare (cameraStagingUsed m) (cameraStagingCap m) | cameraStagingUsed m > cameraStagingCap m]
  where
    storedMax = limitRegionStoredBytes (mLimits m)
    cc = cameraCharge m

-- | The same rules for a state an admission would produce, which also count the detail
-- of the regions camera jobs enter.
admissionCheck ∷ Model → [ChargeViolation]
admissionCheck m =
  chargeCheck m <> [CameraResidentOverShare (ccTotal (cameraCharge m)) (cameraResidentCap m) | ccTotal (cameraCharge m) > cameraResidentCap m, ccStable (cameraCharge m) <= cameraResidentCap m]

acquireHold ∷ Model → HoldId → ArenaId → HoldKind → [RegionCoord] → Run
acquireHold m h a kind regions = do
  if Map.member h (mHolds m) then Left (Invalid (DuplicateHold h)) else Right ()
  _ ← liveArena m a
  if null regions then Left (Invalid EmptyDemand) else Right ()
  case [r | (r, n) ← Map.toList (Map.fromListWith (+) [(r', 1 ∷ Int) | r' ← regions]), n > 1] of
    (r : _) → Left (Invalid (DuplicateRegion r))
    [] → Right ()
  mapM_
    ( \r → case Map.lookup (a, r) (mTargets m) of
        Just Target {tgResident = Just res} | not (rsEvicting res) → Right ()
        _ → Left (Stale (NotResident r))
    )
    regions
  -- A hold is bounded by a static region cap, a typed refusal when exceeded; its
  -- records and the bytes it pins draw on what camera work may use, never on the
  -- headroom kept for explicit requests.
  let holdCap = limitHoldRegions (mLimits m)
  if fromIntegral (length regions) > holdCap then Left (Invalid (DemandTooLarge (length regions) holdCap)) else Right ()
  let bytes = fromIntegral (length regions) * holdRecordBytes
      staging = bankLedger m StagingBank
      held' = Hold a kind regions
      mHeld = m {mHolds = Map.insert h held' (mHolds m)}
      before = ccTotal (cameraCharge m)
  -- A held region can grow while it is pinned, so it is charged at its stored maximum
  -- from the moment it is held, together with the camera's jobs in flight: pins can
  -- never take the room an explicit request may need, however they are re-acquired.
  case [v | v@(CameraResidentOverShare _ _) ← admissionCheck mHeld] of
    (CameraResidentOverShare used cap : _) → Left (Busy (BankFull ResidentBank cap before (used - min used before)))
    _ → Right ()
  case kind of
    Pin v → do
      let total = limitSlot (mLimits m) ViewPinSlot
          used = viewPins m v
      if used + 1 > total then Left (Busy (SlotFull ViewPinSlot total used 1)) else Right ()
    Borrow → Right ()
  if bytes > cameraFree m staging then Left (Busy (BankFull StagingBank (ledgerLimit staging) (ledgerOccupied staging + ledgerReserved staging) bytes)) else Right ()
  let touch key mm = case Map.lookup key (mTargets mm) of
        Just t@Target {tgResident = Just r} → mm {mTargets = Map.insert key t {tgResident = Just r {rsLastUse = mClock mm}} (mTargets mm)}
        _ → mm
      m1 = foldr (\r → touch (a, r)) m regions
  Right (m1 {mHolds = Map.insert h (Hold a kind regions) (mHolds m1)}, HoldAcquired)

beginHandoff ∷ Model → ArenaId → RegionCoord → Word64 → Run
beginHandoff m a region dup = do
  _ ← liveArena m a
  let key = (a, region)
  (t, r) ← case Map.lookup key (mTargets m) of
    Just t@Target {tgResident = Just r} | not (rsEvicting r) → Right (t, r)
    _ → Left (Stale (NotResident region))
  if not (rsDirty r) || isJust (rsHandoff r) then Left (ContractFailure (HandoffNotNeeded region)) else Right ()
  let staging = bankLedger m StagingBank
  -- A duplicate larger than a region can ever be is a contract-size violation by
  -- the owner, independent of the model's state; the minimum budgets guarantee a
  -- region-sized duplicate fits an otherwise empty staging bank.
  let largest = limitRegionStoredBytes (mLimits m)
  if dup > largest then Left (Invalid (HandoffTooLarge dup largest)) else Right ()
  if dup > freeBytes staging then Left (Busy (BankFull StagingBank (ledgerLimit staging) (ledgerOccupied staging + ledgerReserved staging) dup)) else Right ()
  Right (m {mTargets = Map.insert key t {tgResident = Just r {rsHandoff = Just (dup, rsGeneration r)}} (mTargets m)}, HandoffStarted)

-- | Settle a handoff. A confirmed transfer clears the pending changes it
-- transferred (they are already funded in the retained bank) but not a removal
-- committed in the region after the handoff began: the region stays changed, and
-- protected, until that one has been transferred too. A failed transfer keeps
-- every change, and the region stays protected.
endHandoff ∷ Model → ArenaId → RegionCoord → Bool → Run
endHandoff m a region ok = do
  let key = (a, region)
  (t, r) ← case Map.lookup key (mTargets m) of
    Just t@Target {tgResident = Just r} → Right (t, r)
    _ → Left (Stale (NotResident region))
  transferred ← maybe (Left (ContractFailure (HandoffNotPending region))) (Right . snd) (rsHandoff r)
  let r' = r {rsHandoff = Nothing, rsDirty = not ok || transferred /= rsGeneration r}
  Right (m {mTargets = Map.insert key t {tgResident = Just r'} (mTargets m)}, if ok then HandoffSettled else HandoffAbandoned)

-- ---------------------------------------------------------------------------
-- Invariants

-- | The conditions every reachable model satisfies; the empty list means all
-- hold. The suite asserts it after every step and also checks the observable
-- figures independently.
modelInvariants ∷ Model → [String]
modelInvariants m =
  concat
    [ map show (chargeCheck m)
    , [ "job " <> show i <> " deferred bytes disagree with its awaiting victims"
      | (i, j) ← Map.toList (mJobs m)
      , jbDeferred j /= sum (Map.elems (jbAwaiting j))
      ]
    , [ "request " <> show i <> " deferred bytes disagree with its awaiting victims"
      | (i, q) ← Map.toList (mRequests m)
      , rqDeferred q /= sum (Map.elems (rqAwaiting q))
      ]
    , [ "request " <> show i <> " awaits " <> show k <> ", which is not a committed victim"
      | (i, q) ← Map.toList (mRequests m)
      , k ← Map.keys (rqAwaiting q)
      , not (maybe False rsEvicting (Map.lookup k (mTargets m) >>= tgResident))
      ]
    , [ "job " <> show i <> " awaits " <> show k <> ", which is not a committed victim"
      | (i, j) ← Map.toList (mJobs m)
      , k ← Map.keys (jbAwaiting j)
      , not (maybe False (rsEvicting) (Map.lookup k (mTargets m) >>= tgResident))
      ]
    , [ "victim " <> show k <> " is still in use"
      | (k@(a, r), Target (Just res) interests) ← Map.toList (mTargets m)
      , rsEvicting res
      , not (Map.null interests) || isJust (rsHandoff res) || rsDirty res
          || any (\h → hdArena h == a && r `elem` hdRegions h) (Map.elems (mHolds m))
          || any (\j → jbArena j == a && jbRegion j == r) (Map.elems (mJobs m))
      ]
    , ["handoff pending on a clean region " <> show k | (k, Target (Just res) _) ← Map.toList (mTargets m), isJust (rsHandoff res), not (rsDirty res)]
    , [ "job " <> show i <> " is needed by nobody"
      | (i, j) ← Map.toList (mJobs m)
      , jbState j /= JobCancelling
      , null (neededBy m j)
      ]
    , [ "interest of " <> show o <> " has no live owner"
      | InterestInfo o _ _ _ ← modelInterests m
      , not (ownerLive o)
      ]
    , ["request " <> show r <> " has no arena" | (r, q) ← Map.toList (mRequests m), not (Map.member (rqArena q) (mArenas m))]
    , ["hold " <> show h <> " has no arena" | (h, x) ← Map.toList (mHolds m), not (Map.member (hdArena x) (mArenas m))]
    , [ "a hold protects a region that is not resident: " <> show r
      | x ← Map.elems (mHolds m)
      , r ← hdRegions x
      , isNothing (Map.lookup (hdArena x, r) (mTargets m) >>= tgResident)
      ]
    ]
  where
    ownerLive (OwnerRequest r) = Map.member r (mRequests m)
    ownerLive (OwnerView v) = Map.member v (mViews m)
