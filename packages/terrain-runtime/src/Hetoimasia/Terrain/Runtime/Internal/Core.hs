-- | The service's transactions: admission, cancellation, closure, leases,
-- views, holds and the invariants that tie them to the accounting model.
--
-- == Writers
--
-- Every function here is one STM transaction (or a piece of one). The public
-- port runs the admission, cancellation, release and closure functions on the
-- caller's thread: they write the request table, the leases, the names and the
-- accounting model, which is bookkeeping. They never write the contents of an
-- arena. The owner thread, in "Hetoimasia.Terrain.Runtime.Internal.Owner", is
-- the only writer of an arena's resident detail, palette, retained changes,
-- content revision and residency generation.
--
-- A settlement is always delivered by 'terminate' or by a commit in the owner
-- module, inside the transaction that removes the request, so a request is
-- settled once: whoever finds it in the table settles it, and nobody finds it
-- twice.
module Hetoimasia.Terrain.Runtime.Internal.Core
  ( -- * State access
    readSt
  , modifySt
  , applyEvent
  , recordDefect
  , recordFatalDefect
  , takeUnreportedSTM
  , markFreed

    -- * Authorities
  , clientOf
  , leaseOf

    -- * Admission
  , Submission (..)
  , pausedFault
  , readmitSTM
  , releaseCredit
  , admitting
  , admit
  , readAnswer
  , demandFor
  , commandColumns
  , pendingEdits

    -- * The read-only record of the owner's running work
  , startJobWork
  , endJobWork
  , startHandoffWork
  , endHandoffWork

    -- * Settlement
  , terminate
  , terminateWith
  , releaseReq
  , withdrawRecord
  , rememberTried
  , rememberBusy
  , forgetRegionRetry
  , forgetArenaRetry
  , beginRunning
  , safePointSTM
  , cancelRequest
  , retireRequest

    -- * Closure
  , closeArena
  , releaseLeaseSTM
  , endClientSTM
  , closeServiceSTM

    -- * Clients, views and holds
  , registerClientSTM
  , openViewSTM
  , setViewDemandSTM
  , clearViewDemandSTM
  , closeViewSTM
  , acquireSnapshotSTM
  , releaseSnapshotSTM
  , DemandReceipt (..)

    -- * Invariants
  , invariants
  , LimitRow (..)
  , limitRows
  , bumpGeneration
  , waitingReadmission
  , retainedBankUse
  , retireInFlightSTM
  , modelLimitsFor
  , modelLimitsChecked
  , compileBankFor
  , compileBankChecked
  , perArenaShared
  , sharedCharge
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad (forM_, unless, when, void)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes (Changes, emptyChanges)
import Hetoimasia.Terrain.Coordinate
import qualified Hetoimasia.Terrain.Connectivity as C
import qualified Hetoimasia.Terrain.Discovery as D
import qualified Hetoimasia.Terrain.Query as Q
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (Admission, Grant)
import qualified Hetoimasia.Terrain.Residency as R
import Hetoimasia.Terrain.Residency (ArenaId (..), HoldId (..), RegionDemand, RequestId (..), Revision (..), ViewId (..))
import Hetoimasia.Terrain.Runtime.Internal.Content
import Hetoimasia.Terrain.Runtime.Internal.Snapshot
import Hetoimasia.Terrain.Resident (ResidentStats (..), columnIndexBytes, discardRegion, residentStats)
import Hetoimasia.Terrain.Segment (maxSegmentLevels)
import Hetoimasia.Terrain.Runtime.Internal.Types
import Hetoimasia.Terrain.Runtime.Backed.Fault (StorageFault)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (GrowthDecision (..), proposeGrowth)
import Hetoimasia.Terrain.Source (Source, SourceError)

-- ---------------------------------------------------------------------------
-- State access

readSt ∷ Service → STM St
readSt = readTVar . serviceState

modifySt ∷ Service → (St → St) → STM ()
modifySt svc = modifyTVar' (serviceState svc)

-- | Something that may free capacity happened; the owner retries what waits.
markFreed ∷ Service → STM ()
markFreed svc = modifySt svc (\st → st {stateFreed = True, stateDispatchIdle = False, stateCapacityEpoch = stateCapacityEpoch st + 1})

-- | The regions a decision committed as victims, for the owner to discard.
decisionVictims ∷ R.Decision → [R.RegionKey]
decisionVictims (R.Accepted admission) = R.admissionVictims admission
decisionVictims decision@R.CameraSet {} = concatMap R.admissionVictims (R.cameraAdmitted decision)
decisionVictims (R.Serviced served) = concatMap (R.admissionVictims . snd) served
decisionVictims _ = []

-- | Step the accounting model. A refusal leaves it as it was. A report's
-- victims are queued for the owner and the arenas it finished releasing are
-- dropped from the retiring set.
applyEvent ∷ Service → R.Event → STM (Either R.Refusal R.Report)
applyEvent svc event = do
  st <- readSt svc
  let (model, outcome) = R.step (stateModel st) event
  case outcome of
    Left _ → pure outcome
    Right report → do
      writeTVar (serviceState svc) $
        (if freesCapacity event then \x → x {stateFreed = True, stateDispatchIdle = False, stateCapacityEpoch = stateCapacityEpoch x + 1} else id)
        st
          { stateModel = model
          , stateVictims = stateVictims st <> Seq.fromList (decisionVictims (R.reportDecision report))
          , stateRetiring = foldr Map.delete (stateRetiring st) (R.reportSettled report)
            -- a retiring arena's compiled connectivity is dropped with it: its share of the compile
            -- account returns when its retirement completes, not before
          , stateCompileUse = stateCompileUse st - min (stateCompileUse st) (sum [arenaShared a | aid ← R.reportSettled report, Just a ← [Map.lookup aid (stateRetiring st)]])
          , stateWork = syncWork model (stateWork st)
          }
      pure outcome

-- | Events whose acceptance may have returned credits, so that what waits for
-- capacity should be tried again. Every release path goes through 'applyEvent',
-- so none can forget to say so.
freesCapacity ∷ R.Event → Bool
freesCapacity = \case
  R.Withdraw {} → True
  R.RetireArena {} → True
  R.ClearCameraDemand {} → True
  R.SetCameraDemand {} → True
  R.ReleaseHold {} → True
  R.JobCompleted {} → True
  R.JobFailed {} → True
  R.JobAcknowledged {} → True
  R.VictimReleased {} → True
  R.HandoffConfirmed {} → True
  R.HandoffFailed {} → True
  R.RemovalCommitted {} → True
  _ → False

-- | Record a defect that the caller is about to throw itself: it is counted as
-- reported, so the owner does not report it a second time as cleanup evidence.
recordFatalDefect ∷ Service → Defect → STM ()
recordFatalDefect svc = addDefect svc True

-- | The defects recorded and not yet reported, oldest first, now marked reported.
-- Reporting is tracked per defect, so a defect the caller is about to throw never
-- hides another one recorded earlier.
takeUnreportedSTM ∷ Service → STM [Defect]
takeUnreportedSTM svc = do
  st <- readSt svc
  let unreported = [defectOf r | r <- reverse (stateDefects st), not (defectReported r)]
  writeTVar (serviceState svc) st {stateDefects = [r {defectReported = True} | r <- stateDefects st]}
  pure unreported

-- | Keep a bounded record of an unexpected defect.
recordDefect ∷ Service → Defect → STM ()
recordDefect svc = addDefect svc False

-- | Record a defect. Every unreported one is kept; of the reported ones the latest
-- sixteen are.
addDefect ∷ Service → Bool → Defect → STM ()
addDefect svc reported defect =
  modifySt svc $ \st →
    let record = DefectRecord (stateDefectCount st) reported defect
        kept = keep (16 ∷ Int) (record : stateDefects st)
        keep _ [] = []
        keep n (r : rest)
          | not (defectReported r) = r : keep n rest
          | n > 0 = r : keep (n - 1) rest
          | otherwise = keep n rest
     in st {stateDefects = kept, stateDefectCount = stateDefectCount st + 1}

-- ---------------------------------------------------------------------------
-- Authorities

clientOf ∷ Service → Client → St → Either Refused Word64
clientOf svc (Client tag cid) st
  | tag /= serviceTag svc = Left RefusedAuthority
  | Map.member cid (stateClients st) = Right cid
  | otherwise = Left RefusedAuthority

leaseOf ∷ Service → ArenaLease → St → Either Refused (Word64, LeaseRec)
leaseOf svc (ArenaLease tag lid) st
  | tag /= serviceTag svc = Left RefusedAuthority
  | otherwise = maybe (Left RefusedAuthority) (\l → Right (lid, l)) (Map.lookup lid (stateLeases st))

-- | Allocate from a counter without wrap: the last value is never issued.
allocate ∷ Word64 → Either Refused Word64
allocate n = if n == maxBound then Left RefusedExhausted else Right n

-- | Whether the service accepts new admissions, including its parent session.
admitting ∷ Service → STM (Either Refused St)
admitting svc = do
  open <- sessionOpen (serviceAdmission svc)
  st <- readSt svc
  pure (if statePhase st /= Running || not open then Left RefusedClosed else Right st)

registerClientSTM ∷ Service → STM (Either Refused Client)
registerClientSTM svc =
  admitting svc >>= \case
    Left refused → pure (Left refused)
    Right st
      | Map.size (stateClients st) >= configMaxClients (serviceConfig svc) → pure (Left (RefusedBusy BusyClients))
      | otherwise → case allocate (stateNextClient st) of
       Left refused → pure (Left refused)
       Right cid → do
        writeTVar (serviceState svc) st {stateNextClient = cid + 1, stateClients = Map.insert cid (ClientRec Set.empty Set.empty) (stateClients st)}
        pure (Right (Client (serviceTag svc) cid))

-- ---------------------------------------------------------------------------
-- Admission

-- | What a caller asks to admit.
data Submission
  = SubOpen !Client !Text !Source
  | SubOpenInvalid !Client !SourceError
  | SubAttach !Client !Text
  | SubCell !ArenaLease !TileCoord
  | SubColumn !ArenaLease !Column !ZRange
  | SubSurface !ArenaLease !Column
  | SubRemove !ArenaLease !TileCoord !(Maybe Precondition)
  | SubKnowledge !ArenaLease !TileCoord
  | -- | The creator's growth of an arena's allowance to a size in bytes.
    SubGrow !ArenaLease !Integer
  | -- | The creator's explicit retry of a paused arena.
    SubRetry !ArenaLease

-- | The fault a paused arena recorded, the most serious first (integrity, then I/O, then
-- capacity): what a new mutation of it settles with.
pausedFault ∷ Arena → Maybe StorageFault
pausedFault arena = case Map.toDescList (arenaFaults arena) of
  (_, record) : _ → Just (faultOf record)
  [] → Nothing

-- | How an admission ended short of a request in the table.
data Short
  = ShortRefused !Refused
  | ShortFailed !Failure

busyWhy ∷ R.Refusal → Short
busyWhy refusal = case refusal of
  R.Busy reason → ShortRefused (RefusedBusy (BusyModel reason))
  -- the model's edit reservation is sized so that it never refuses (every command slot can hold
  -- one removal's): a refusal is an accounting defect, never busy
  R.RetainedEditsExhausted {} → ShortFailed (HostFailure "accounting: the model's edit reservation refused a removal")
  R.Invalid reason → ShortRefused (RefusedInvalid (Text.pack (show reason)))
  R.Stale _ → ShortFailed ArenaClosed
  R.ContractFailure reason → ShortFailed (HostFailure (Text.pack ("accounting: " <> show reason)))

-- | The demand a read puts on the model, from a source and the removals known for the
-- column (at admission none are read: removals only lower a column's top, so the
-- source's top is where a surface read demands detail until its staging gather says
-- otherwise). Cheap and bounded: a cell, the regions of a bounded range, or the cell
-- holding a column's top.
demandFor ∷ Source → Changes → Cmd → Either String [RegionDemand]
demandFor source changes cmd = case cmd of
  CCell tile → Right [tileDemand tile]
  CColumn column range → columnDemands column range
  CSurface column →
    let top = Q.highestOccupied source changes column
        level = maybe 0 (toInteger . axisValue . Q.occupiedLevel) top
     in do
          tile <- either (Left . show) Right (tileCoord (toInteger (axisValue (columnX column))) (toInteger (axisValue (columnY column))) level)
          Right [tileDemand tile]
  CRemove tile _ → Right [tileDemand tile]
  CKnowledge tile → Right [tileDemand tile]
  _ → Left "not a data command"

-- | The columns a command's answer reads: the runs of these, gathered from one committed
-- version of the arena's store, are all the removals the answer depends on.
commandColumns ∷ Cmd → [Column]
commandColumns = \case
  CCell (TileCoord x y _) → [Column x y]
  CColumn column _ → [column]
  CSurface column → [column]
  CRemove (TileCoord x y _) _ → [Column x y]
  CKnowledge _ → []
  COpen {} → []
  CAttach {} → []
  CGrow {} → []
  CRetry → []

-- | The answer of a read from an arena's source and the removals of the columns it reads
-- (gathered from one committed version), with the demand that answer needs resident. It is
-- pure and is recomputed whenever the content revision it was computed at is superseded.
readAnswer ∷ Config → ArenaId → Revision → Source → Changes → Cmd → Either Failure (Answer, [RegionDemand])
readAnswer config aid rev source changes cmd = case cmd of
  CCell tile → Right (ACell (CellAnswer aid rev (Q.cellAt source changes tile)), [tileDemand tile])
  CColumn column range → case Q.columnRuns (configQueryLimits config) source changes column range of
    Left err → Left (TooLarge err)
    Right runs → do
      demands <- either (Left . SourceFailure . Text.pack) Right (columnDemands column range)
      Right (AColumn (ColumnAnswer aid rev runs), demands)
  CSurface column → do
    demands <- either (Left . SourceFailure . Text.pack) Right (demandFor source changes cmd)
    Right (ASurface (SurfaceAnswer aid rev (Q.highestOccupied source changes column)), demands)
  _ → Left (HostFailure "not a read")

-- | Where an admitted command goes in the request table.
data Insertion = Insertion
  { insCmd ∷ !Cmd
  , insLease ∷ !(Maybe Word64)
  , insClient ∷ !Word64
  , insArena ∷ !(Maybe ArenaId)
  , insModel ∷ !Bool
  , insDemand ∷ ![RegionDemand]
  , insClaim ∷ !(Maybe Text)
  }

isOpenCmd ∷ Req → Bool
isOpenCmd req = case reqCmd req of COpen {} → True; _ → False

isAcquisition ∷ Req → Bool
isAcquisition req = case reqCmd req of COpen {} → True; CAttach {} → True; _ → False

-- | A creator's growth or retry: no model record, a command slot held here until it settles.
isCreatorCommand ∷ Req → Bool
isCreatorCommand req = case reqCmd req of CGrow {} → True; CRetry → True; _ → False

isRemoval ∷ Req → Bool
isRemoval req = case reqCmd req of CRemove {} → True; _ → False

isDone ∷ Req → Bool
isDone req = case reqPhase req of Done → True; _ → False

countReqs ∷ (Req → Bool) → St → Int
countReqs p st = Map.size (Map.filter p (stateRequests st)) + Map.size (Map.filter p (stateGhosts st))

-- | The removals admitted for an arena and not yet settled.
-- | Accounted bytes a settled removal result holds in the retained bank until it is
-- taken: the request, its endpoint and its demand are kept (the size of a one-region
-- command record).
resultRecordBytes ∷ Word64
resultRecordBytes = 160

-- | Bytes the retained bank holds: outstanding snapshots' backing and untaken
-- results.
retainedBankUse ∷ St → Word64
retainedBankUse st = sum (Map.elems (stateSnapshots st)) + resultRecordBytes * fromIntegral (retainedRecords st)

-- | The records the service itself holds for a request, each charged
-- 'resultRecordBytes' in the retained bank from admission to take, discard or
-- cancellation. Every request reserves one when it is admitted, because every
-- request can come to hold a record the model does not charge (a result not yet
-- taken, a wait to be admitted again), and the reservation is then simply kept.
-- Only a settled read, whose record the model still charges, holds none.
retainedRecords ∷ St → Int
retainedRecords = countReqs (\req → not (isDone req && reqModel req))

-- | Command slots the service holds for requests the model has no record of: a
-- settled result not yet taken, and a pending open or attach.
slotsHeldHere ∷ St → Int
slotsHeldHere st = retainedResults st + pendingAcquisitions st + countReqs waitingReadmission st + countReqs (\req → isCreatorCommand req && not (isDone req)) st

-- | Opens and attaches admitted and not yet settled. A settled one holds no
-- acquisition: it either made its arena and lease (and left the table) or failed
-- (and its untaken result is counted as a result).
pendingAcquisitions ∷ St → Int
pendingAcquisitions = countReqs (\req → isAcquisition req && not (isDone req))

-- | Arena incarnations the service holds, for the service-wide arena limit: every
-- live arena, every pending open, and every arena that is closed but still
-- retiring because a snapshot of it is borrowed (its resident detail stays
-- charged until the last borrower returns it). An arena leaves the count only when
-- its retirement has completed.
--
-- An open whose request ended while a job of it was in flight (it unwinds) also counts, and so does a
-- retiring arena: each still holds its share of the compile account, which is sized for at most this
-- many arenas (so valid work can never exhaust it).
arenaUse ∷ St → Int
arenaUse st =
  Map.size (stateArenas st)
    + Map.size (stateRetiring st)
    + countReqs (\req → isOpenCmd req && not (isDone req)) st
    + orphanOpens st

-- | Opens whose request has ended while their task still drains a job or closes a file.
orphanOpens ∷ St → Int
orphanOpens st = Map.size (Map.filterWithKey (\rid _ → not (Map.member rid (stateRequests st)) && not (Map.member rid (stateGhosts st))) (stateOpens st))

-- | Leases the service holds, for the lease limit: every lease record (live or
-- revoked, until released) and every pending acquisition.
leasesInUse ∷ St → Int
leasesInUse st = Map.size (stateLeases st) + pendingAcquisitions st

-- | One service-wide limit, what the admission test counts against it, and what
-- an independent enumeration of the entities holding the resource finds.
data LimitRow = LimitRow
  { limitRowName ∷ !String
  , limitRowMax ∷ !Word64
  , limitRowCounted ∷ !Word64
  , limitRowHeld ∷ !Word64
  }
  deriving stock (Eq, Show)

-- | Every service-wide limit with its count and an enumeration that reads only the service's own
-- structures (its arena maps, name claims, client records, request table and the record of the
-- snapshots it handed out), never the accounting model or the retained-bank ledger.
limitRows ∷ Config → St → [LimitRow]
limitRows config st =
  [ LimitRow "arenas" (w (configMaxArenas config)) (w (arenaUse st)) (w (Map.size (stateArenas st)) + w (length (Map.keys (stateRetiring st))) + w (length [() | ClaimPending _ ← Map.elems (stateNames st)]) + w (orphanOpens st))
  , LimitRow "leases" (w (configMaxLeases config)) (w (leasesInUse st)) (sum [w (Set.size (clientLeases c)) | c ← Map.elems (stateClients st)] + w (length [() | req ← requestsAndGhosts, isAcquisition req, not (isDone req)]))
  , LimitRow "views" (w (configMaxViews config)) (w (Map.size (stateViews st))) (sum [w (Set.size (clientViews c)) | c ← Map.elems (stateClients st)])
  , LimitRow "clients" (w (configMaxClients config)) (w (Map.size (stateClients st))) (w (length (Map.keys (stateClients st))))
  , LimitRow "command slots" slotLimit (fromIntegral (R.slotInUse model R.CommandSlot) + w (slotsHeldHere st)) (w (length [() | req ← requestsAndGhosts, reqModel req]) + sum (map slotOf requestsAndGhosts))
  , LimitRow "retained bank" (configRetainedBytes config) (retainedBankUse st) (sum [bytes | (_, bytes) ← Map.elems (rwHolds (stateWork st))] + sum (map recordOf requestsAndGhosts))
  ]
  where
    model = stateModel st
    slotLimit = fromIntegral (R.limitSlot (R.modelLimits model) R.CommandSlot) ∷ Word64
    requestsAndGhosts = Map.elems (stateRequests st) <> Map.elems (stateGhosts st)
    w ∷ Int → Word64
    w = fromIntegral
    -- The slot a request holds beyond the model's own record of it.
    slotOf ∷ Req → Word64
    slotOf req
      | isDone req = if reqModel req then 0 else 1
      | isAcquisition req = 1
      | isCreatorCommand req = 1
      | waitingReadmission req = 1
      | otherwise = 0
    recordOf req = if isDone req && reqModel req then 0 else resultRecordBytes

-- | Why one more request cannot be admitted for want of command slots or retained
-- bytes, if it cannot. Every admission consults this, so no kind bypasses it.
capacityRefusal ∷ Config → St → Bool → Maybe R.Refusal
capacityRefusal config st producesRecord
  | held >= limit = Just (R.Busy (R.SlotFull R.CommandSlot limit held 1))
  | producesRecord && retainedBankUse st + resultRecordBytes > configRetainedBytes config =
      Just (R.Busy (R.BankFull R.StagingBank (configRetainedBytes config) (retainedBankUse st) resultRecordBytes))
  | otherwise = Nothing
  where
    model = stateModel st
    limit = R.limitSlot (R.modelLimits model) R.CommandSlot
    held = R.slotInUse model R.CommandSlot + fromIntegral (slotsHeldHere st)

-- | A read or removal that was withdrawn from the model to be admitted again at a
-- newer revision and has not been: the service still holds its request, endpoint
-- and demand, so it stays charged, like any record the service holds for a request,
-- until it is readmitted or ends.
waitingReadmission ∷ Req → Bool
waitingReadmission req = case (reqCmd req, reqPhase req) of
  (COpen {}, _) → False
  (CAttach {}, _) → False
  (CGrow {}, _) → False
  (CRetry, _) → False
  (_, Waiting) → not (reqModel req)
  _ → False

-- | Settled results the model no longer records but their holder has not taken.
retainedResults ∷ St → Int
retainedResults = countReqs (\req → isDone req && not (reqModel req))

pendingEdits ∷ ArenaId → St → Int
pendingEdits aid = countReqs (\req → isRemoval req && not (isDone req) && reqArena req == Just aid)

-- | Admit a command, or refuse it. A refusal creates no request, no work and no
-- reservation. A command whose outcome is already known (a name in use, a
-- closed arena) is admitted as a request that is settled at once.
admit ∷ Service → Endpoint → Submission → STM (Either Refused Request)
admit svc ep sub =
  admitting svc >>= \case
    Left refused → pure (Left refused)
    Right st0
      | stateNextRequest st0 == maxBound || stateNextSeq st0 == maxBound → pure (Left RefusedExhausted)
      | otherwise → do
          let rid = stateNextRequest st0
              request = Request (serviceTag svc) (RequestId rid)
          decided <- decide svc st0 (RequestId rid) sub
          case decided of
            Left (ShortRefused refused) → pure (Left refused)
            Left (ShortFailed failure) → do
              modifySt svc (\st → st {stateNextRequest = rid + 1})
              endpointSettle ep (Failed failure)
              pure (Right request)
            Right ins → do
              -- The model may have moved while deciding: insert into the fresh state.
              st <- readSt svc
              let req = Req (stateNextSeq st) (insCmd ins) ep (insLease ins) (insClient ins) (insArena ins) Waiting (insModel ins) (insDemand ins)
                  names = case insClaim ins of
                    Nothing → stateNames st
                    Just name → Map.insert name (ClaimPending (RequestId rid)) (stateNames st)
              writeTVar (serviceState svc) st {stateNextRequest = rid + 1, stateNextSeq = stateNextSeq st + 1, stateRequests = Map.insert (RequestId rid) req (stateRequests st), stateNames = names, stateDispatchIdle = False}
              pure (Right request)

decide ∷ Service → St → RequestId → Submission → STM (Either Short Insertion)
decide svc st rid = \case
  SubOpen client name source → pure $ do
    cid <- first' ShortRefused (clientOf svc client st)
    checkName name
    when (Map.member name (stateNames st)) (Left (ShortFailed NameInUse))
    when (arenaUse st >= configMaxArenas config) (Left (ShortRefused (RefusedBusy BusyArenas)))
    when (leaseUse >= configMaxLeases config) (Left (ShortRefused (RefusedBusy BusyLeases)))
    forM_ (capacityRefusal config st True) (Left . busyWhy)
    Right (Insertion (COpen name source cid) Nothing cid Nothing False [] (Just name))
  SubOpenInvalid client err → pure $ do
    _ <- first' ShortRefused (clientOf svc client st)
    Left (ShortFailed (Definition err))
  SubAttach client name → pure $ do
    cid <- first' ShortRefused (clientOf svc client st)
    checkName name
    when (leaseUse >= configMaxLeases config) (Left (ShortRefused (RefusedBusy BusyLeases)))
    forM_ (capacityRefusal config st True) (Left . busyWhy)
    Right (Insertion (CAttach name cid) Nothing cid Nothing False [] Nothing)
  SubCell lease tile → dataCommand lease (CCell tile)
  SubColumn lease column range
    -- Before any region is enumerated: a range of any length is refused here, in
    -- constant time, however many levels it names.
    | zRangeLevels range > toInteger (Q.limitRangeLevels (configQueryLimits config)) →
        pure (Left (ShortRefused (RefusedInvalid "column range exceeds the level limit")))
    | otherwise → dataCommand lease (CColumn column range)
  SubSurface lease column → dataCommand lease (CSurface column)
  SubKnowledge lease tile → dataCommand lease (CKnowledge tile)
  SubGrow lease bytes → case liveArena lease of
    Left short → pure (Left short)
    Right (_, _, _, arena) → case proposeGrowth (arenaStore arena) bytes of
      GrowthInvalid why → pure (Left (ShortRefused (RefusedInvalid (Text.pack ("an allowance that can never be granted: " <> show why)))))
      GrowthNoOp → creatorCommand lease (CGrow (fromInteger bytes))
      GrowthNotIncreased → creatorCommand lease (CGrow (fromInteger bytes))
      GrowthProposed _ → creatorCommand lease (CGrow (fromInteger bytes))
  SubRetry lease → creatorCommand lease CRetry
  SubRemove lease tile precondition → case liveArena lease of
    Left short → pure (Left short)
    Right (lid, ls, aid, arena)
      | stale aid arena precondition → pure (Left (ShortFailed StaleView))
      -- A paused arena takes no new history: the removal settles at once with the fault its
      -- pause recorded (requirement 8), never left hanging and never repeated after recovery.
      | Just fault ← pausedFault arena → pure (Left (ShortFailed (StorageFailed fault)))
      | revisionExhausted aid arena → pure (Left (ShortRefused RefusedExhausted))
      | otherwise → do
          let cmd = CRemove tile precondition
          outcome <- slotRefusal True >>= \case
            Just refusal → pure (Left refusal)
            Nothing → applyEvent svc (R.SubmitRemoval rid aid (arenaRevision arena) tile)
          pure $ case outcome of
            Left refusal → Left (busyWhy refusal)
            Right _ → Right (Insertion cmd (Just lid) (leaseClient ls) (Just aid) True [tileDemand tile] Nothing)
  where
    config = serviceConfig svc
    -- A settled result that has not been taken occupies a command slot until it is
    -- (a removal's result no longer has a model record, so it is counted here):
    -- admission is busy once accepted commands and untaken results fill the slots.
    slotRefusal producesRecord = pure (capacityRefusal config st producesRecord)
    leaseUse = leasesInUse st
    first' f = either (Left . f) Right
    -- A name is held in the name map, so it is bounded: nonempty, 256 characters.
    checkName name
      | Text.null name = Left (ShortRefused (RefusedInvalid "an arena name is empty"))
      | Text.compareLength name 256 == GT = Left (ShortRefused (RefusedInvalid "an arena name is longer than 256 characters"))
      | otherwise = Right ()
    liveArena lease = do
      (lid, ls) <- first' ShortRefused (leaseOf svc lease st)
      if not (leaseLive ls)
        then Left (ShortFailed ArenaClosed)
        else case Map.lookup (leaseArena ls) (stateArenas st) of
          Nothing → Left (ShortFailed ArenaClosed)
          Just arena → Right (lid, ls, leaseArena ls, arena)
    stale aid arena = \case
      Just (Precondition pa pr) → pa /= aid || pr /= arenaRevision arena
      Nothing → False
    -- each pending removal can advance the content, knowledge and store revisions by one: a removal
    -- that could need the last value of any of them is refused before any work
    revisionExhausted aid arena =
      let auth = arenaAuthority arena
          near (Revision n) = toInteger n + toInteger (pendingEdits aid st) + 1 >= toInteger (maxBound ∷ Word64)
       in near (D.authContent auth) || near (D.authKnowledge auth) || near (D.authStore auth)
    -- Growth and retry are the creator's: an owner lease of a live arena. Their size
    -- rules are the store's own pure proposal, decided here before anything is admitted.
    creatorCommand lease cmd = case liveArena lease of
      Left short → pure (Left short)
      Right (lid, ls, aid, _)
        | not (leaseOwner ls) → pure (Left (ShortRefused RefusedAuthority))
        | otherwise →
            pure $ case capacityRefusal config st True of
              Just refusal → Left (busyWhy refusal)
              Nothing → Right (Insertion cmd (Just lid) (leaseClient ls) (Just aid) False [] Nothing)
    dataCommand lease cmd = case liveArena lease of
      Left short → pure (Left short)
      Right (lid, ls, aid, arena) → case demandFor (arenaSource arena) emptyChanges cmd of
        Left why → pure (Left (ShortFailed (SourceFailure (Text.pack why))))
        Right demands → do
          outcome <- slotRefusal True >>= \case
            Just refusal → pure (Left refusal)
            Nothing → applyEvent svc (R.SubmitQuery rid aid (arenaRevision arena) demands)
          pure $ case outcome of
            Left refusal → Left (busyWhy refusal)
            Right _ → Right (Insertion cmd (Just lid) (leaseClient ls) (Just aid) True demands Nothing)

-- ---------------------------------------------------------------------------
-- Settlement

-- | Remove a request from the table and give back what it holds: its name
-- claim and its model record with every credit that record owns.
releaseReq ∷ Service → RequestId → Req → STM ()
releaseReq svc rid req = do
  modifySt svc $ \st →
    st
      { stateRequests = Map.delete rid (stateRequests st)
      , stateNames = case reqCmd req of
          COpen name _ _ | Just (ClaimPending claimed) <- Map.lookup name (stateNames st), claimed == rid → Map.delete name (stateNames st)
          _ → stateNames st
      }
  when (reqModel req) (withdrawRecord svc rid req)
  markFreed svc

-- | Remember that a region's transfer was tried at a generation, or was refused for want
-- of capacity at an epoch. These two are the only places either is written, and they
-- write only for a region the model still holds in a live arena, so an arena or a
-- region that ended while a transfer was in flight is never given a memory it could not
-- be rid of.
rememberTried ∷ R.RegionKey → Word64 → St → St
rememberTried key generation st
  | remembered st key = st {stateTransfers = Map.insert key generation (stateTransfers st)}
  | otherwise = st

rememberBusy ∷ R.RegionKey → St → St
rememberBusy key st
  | remembered st key = st {stateHandoffBusy = Map.insert key (stateCapacityEpoch st) (stateHandoffBusy st)}
  | otherwise = st

remembered ∷ St → R.RegionKey → Bool
remembered st key@(aid, _) =
  Map.member aid (stateArenas st) && key `elem` [(R.regionArena r, R.regionCoord r) | r <- R.modelRegions (stateModel st)]

-- | Forget everything the owner remembers about retrying one region's transfer: that
-- it was tried at some generation, and that it was refused for want of capacity at
-- some epoch. This and 'forgetArenaRetry' are the only places either is dropped, and
-- every place a region or an arena ends calls one of them, so the memory is bounded
-- by the regions the model holds.
forgetRegionRetry ∷ St → R.RegionKey → St
forgetRegionRetry st key = st {stateTransfers = Map.delete key (stateTransfers st), stateHandoffBusy = Map.delete key (stateHandoffBusy st)}

-- | The same for every region of an arena.
forgetArenaRetry ∷ St → ArenaId → St
forgetArenaRetry st aid =
  st
    { stateTransfers = Map.filterWithKey (\(owner, _) _ → owner /= aid) (stateTransfers st)
    , stateHandoffBusy = Map.filterWithKey (\(owner, _) _ → owner /= aid) (stateHandoffBusy st)
    }

-- | THE ONLY PLACE a request's model record, and every credit it owns, is given back
-- (R1). While the owner is running that request's preparation, which computes with
-- values captured under those credits, the release waits: the request leaves the
-- table (its outcome is already decided) but stays a ghost holding everything, and
-- 'safePointSTM' gives it back once the preparation has ended.
withdrawRecord ∷ Service → RequestId → Req → STM ()
withdrawRecord svc rid req = do
  st <- readSt svc
  case stateRunning st of
    Just (running, _) | running == rid → modifySt svc (\s → s {stateGhosts = Map.insert rid req (stateGhosts s)})
    _ → void (applyEvent svc (R.Withdraw rid))

-- | Retire an arena in the model, which gives back every credit its requests and
-- views hold. Deferred while a preparation of that arena is running (R1).
retireArenaRecord ∷ Service → ArenaId → STM ()
retireArenaRecord svc aid = do
  st <- readSt svc
  case stateRunning st of
    Just (_, Just running) | running == aid → modifySt svc (\s → s {stateDeferredRetire = Set.insert aid (stateDeferredRetire s)})
    _ → void (applyEvent svc (R.RetireArena aid))

-- | What a preparation holds, from the command it runs: the command record it reads
-- under and, for a removal, the resident growth, staging and retained-edit bytes its
-- buffers and its result can hold (a segment's worst case: two bytes a cell, a dense
-- segment of 'maxSegmentLevels' cells). Recorded for inspection only.
preparationWorkOf ∷ RequestId → Req → PreparationWork
preparationWorkOf rid req = case reqCmd req of
  CRemove {} → PreparationWork rid (reqArena req) True recordBytes (2 * fromIntegral maxSegmentLevels - 2) R.removalStagingBytes R.removalRetainedBytes
  _ → PreparationWork rid (reqArena req) False recordBytes 0 0 0
  where
    recordBytes = R.commandRecordBytes (fromIntegral (Set.size (Set.fromList (map R.demandRegion (reqDemand req)))))

-- | Keep the record of accepted load jobs in step with the jobs the model holds, in the
-- transaction of every model event: a job the model has admitted is recorded with the
-- reservation and scratch it was granted at that moment, and with the least its coverage
-- can hold from the data layer's own sizes; a job the model no longer holds is dropped
-- unless the owner is running it (the owner ends that one with its report, so a model
-- that forgets a running job is seen); and a view's description the model no longer holds
-- is dropped. Read-only bookkeeping: nothing decides by it.
syncWork ∷ R.Model → RunningWork → RunningWork
syncWork model rw =
  rw
    { rwJobs = Map.union kept added
    , rwViews = Map.filterWithKey (\view _ → Set.member view liveViews) (rwViews rw)
    }
  where
    jobs = R.modelJobs model
    ids = Set.fromList (map R.jobId jobs)
    kept = Map.filterWithKey (\jid work → Set.member jid ids || jobWorkSlots work > 0) (rwJobs rw)
    added = Map.fromList [(R.jobId j, jobWorkOfModel j) | j ← jobs, not (Map.member (R.jobId j) (rwJobs rw))]
    liveViews = Set.fromList (map R.viewId (R.modelViews model))

-- | A job as granted: what the model reserved for it and its scratch at this moment (so a
-- later reduction is seen). The least the job holds is not claimed here: a job that waits
-- holds nothing the service owns, only a promise. The owner records that when it runs the
-- job ('startJobWork'), from the coverage it is given to load.
jobWorkOfModel ∷ R.JobInfo → JobWork
jobWorkOfModel j = JobWork (R.jobId j) (R.jobArena j) (R.jobRegion j) (R.jobActive j + R.jobDeferred j) (R.jobScratch j) 0 0 0

-- | The owner starts running a load job: it holds a load-job slot from now to its report,
-- and the least it can hold is worked out from the coverage it is given to load (the
-- decision's value, which is also the input of the work itself) and the data layer's own
-- sizes, not the model's cost functions: a column index entry is 'columnIndexBytes' (48), a
-- segment is 32 bytes of metadata and at least two of payload (a uniform one), and the
-- scratch is a 256-byte frame and two bytes a cell.
startJobWork ∷ Service → R.JobId → R.Coverage → STM ()
startJobWork svc jid cover =
  modifySt svc $ \st →
    st {stateWork = (stateWork st) {rwJobs = Map.adjust running jid (rwJobs (stateWork st))}}
  where
    running (JobWork a b c d e _ _ _) =
      JobWork a b c d e (R.coverageColumns cover * fromIntegral columnIndexBytes + R.coverageSegments cover * (32 + 2)) (256 + 2 * R.coverageCells cover) 1

-- | The job's report (completed, failed or acknowledged) ends its record, in the
-- transaction that reports it.
endJobWork ∷ Service → R.JobId → STM ()
endJobWork svc jid = modifySt svc (\st → st {stateWork = (stateWork st) {rwJobs = Map.delete jid (rwJobs (stateWork st))}})

-- | The owner holds the duplicate of a region's changes while it transfers them.
startHandoffWork ∷ Service → ArenaId → RegionCoord → Word64 → STM ()
startHandoffWork svc aid region duplicate =
  modifySt svc $ \st →
    st {stateWork = (stateWork st) {rwHandoffs = Map.insert (aid, region) (HandoffWork aid region duplicate) (rwHandoffs (stateWork st))}}

endHandoffWork ∷ Service → ArenaId → RegionCoord → STM ()
endHandoffWork svc aid region = modifySt svc (\st → st {stateWork = (stateWork st) {rwHandoffs = Map.delete (aid, region) (rwHandoffs (stateWork st))}})

-- | The owner starts running a request's preparation, if the request is still
-- there to prepare: from now until the safe point nothing it holds is released.
beginRunning ∷ Service → RequestId → STM Bool
beginRunning svc rid = do
  st <- readSt svc
  case Map.lookup rid (stateRequests st) of
    Nothing → pure False
    Just req → do
      modifySt svc (\s → s {stateRunning = Just (rid, reqArena req), stateWork = (stateWork s) {rwPreparation = Just (preparationWorkOf rid req)}})
      pure True

-- | The owner's safe point: no preparation is running, so what was deferred is
-- released now, requests first, then arenas.
safePointSTM ∷ Service → STM ()
safePointSTM svc = do
  st <- readSt svc
  modifySt svc (\s → s {stateRunning = Nothing, stateGhosts = Map.empty, stateDeferredRetire = Set.empty, stateWork = (stateWork s) {rwPreparation = Nothing}})
  forM_ (Map.keys (stateGhosts st)) $ \rid → applyEvent svc (R.Withdraw rid)
  forM_ (Set.toList (stateDeferredRetire st)) (applyEvent svc . R.RetireArena)
  markFreed svc

-- | Deliver a request's terminal outcome and give back what it holds. A request
-- already settled (its accepted result is only waiting to be retired) is
-- retired without a second delivery.
terminate ∷ Service → RequestId → Settlement → STM ()
terminate = terminateWith True

-- | 'terminate', with a host settlement callback that fails either kept as a
-- defect (closure paths must reach every request) or let propagate, abandoning
-- the transaction (an explicit cancellation, whose caller owns the host).
terminateWith ∷ Bool → Service → RequestId → Settlement → STM ()
terminateWith guarded svc rid outcome = do
  st <- readSt svc
  forM_ (Map.lookup rid (stateRequests st)) $ \req → do
    releaseReq svc rid req
    unless (isDone req) $
      if guarded
        then
          endpointSettle (reqEndpoint req) outcome `catchSTM` \(failure ∷ SomeException) →
            recordDefect svc (ProviderDefect (Text.pack ("settlement callback failed: " <> show failure)))
        else endpointSettle (reqEndpoint req) outcome

-- | Cancel an unsettled request. Cancellation and every other settlement are
-- decided by the one transaction that finds the request in the table.
cancelRequest ∷ Service → Request → STM CancelResult
cancelRequest svc (Request tag rid)
  | tag /= serviceTag svc = pure CancelForeign
  | otherwise = do
      st <- readSt svc
      case Map.lookup rid (stateRequests st) of
        Just req | not (isDone req) → terminateWith False svc rid Cancelled >> pure CancelWon
        _ → pure AlreadySettled

-- | Retire a settled request's accepted result: its credits return.
retireRequest ∷ Service → Request → STM ()
retireRequest svc (Request tag rid)
  | tag /= serviceTag svc = pure ()
  | otherwise = do
      st <- readSt svc
      forM_ (Map.lookup rid (stateRequests st)) $ \req → when (isDone req) (releaseReq svc rid req)

-- ---------------------------------------------------------------------------
-- Closure

-- | End an arena incarnation: settle every request of it, revoke its leases,
-- free its name and hand it to the model to retire. Its resident detail stays
-- charged, and stays in the retiring set, until the model reports it released.
--
-- Its store and backing move to the closing set in the same transaction: from now on
-- nothing can publish into this incarnation (the decision finds no live arena), and the
-- owner drains what of it is in flight (its transaction, its gathers) and then closes its
-- file ('Closing''). The retiring copy keeps the resident detail only: its store field is
-- never read again.
closeArena ∷ Service → ArenaId → STM ()
closeArena svc aid = do
  st <- readSt svc
  forM_ (Map.lookup aid (stateArenas st)) $ \arena → do
    forM_ [rid | (rid, req) <- Map.toList (stateRequests st), reqArena req == Just aid] $ \rid →
      terminate svc rid (Failed ArenaClosed)
    modifySt svc $ \cur →
      cur
        { stateArenas = Map.delete aid (stateArenas cur)
        , stateClosing = Map.insert aid (Closing' (arenaStore arena) (arenaBacking arena)) (stateClosing cur)
        , stateRetiring = Map.insert aid arena (stateRetiring cur)
        , stateNames = case Map.lookup (arenaName arena) (stateNames cur) of
            Just (ClaimLive claimed) | claimed == aid → Map.delete (arenaName arena) (stateNames cur)
            _ → stateNames cur
        , stateLeases = foldr (Map.adjust (\l → l {leaseLive = False})) (stateLeases cur) (Set.toList (arenaLeases arena))
        }
        `forgetArenaRetry` aid
    retireArenaRecord svc aid

-- | Release a lease. Idempotent. It cancels the requests made through it, and
-- releasing the creator's final owner lease closes the arena.
releaseLeaseSTM ∷ Service → Word64 → STM ()
releaseLeaseSTM svc lid = do
  st <- readSt svc
  forM_ (Map.lookup lid (stateLeases st)) $ \ls → do
    forM_ [rid | (rid, req) <- Map.toList (stateRequests st), reqLease req == Just lid] $ \rid →
      terminate svc rid Cancelled
    modifySt svc $ \cur →
      cur
        { stateLeases = Map.delete lid (stateLeases cur)
        , stateClients = Map.adjust (\c → c {clientLeases = Set.delete lid (clientLeases c)}) (leaseClient ls) (stateClients cur)
        , stateArenas = Map.adjust (\a → a {arenaLeases = Set.delete lid (arenaLeases a)}) (leaseArena ls) (stateArenas cur)
        }
    after <- readSt svc
    when (leaseOwner ls && leaseLive ls) $
      forM_ (Map.lookup (leaseArena ls) (stateArenas after)) $ \arena →
        unless (any (\other → maybe False leaseOwner (Map.lookup other (stateLeases after))) (Set.toList (arenaLeases arena))) $
          closeArena svc (leaseArena ls)

-- | End a client: its pending acquisitions are cancelled, its leases and views
-- released.
endClientSTM ∷ Service → Word64 → STM ()
endClientSTM svc cid = do
  st <- readSt svc
  forM_ (Map.lookup cid (stateClients st)) $ \client → do
    forM_ [rid | (rid, req) <- Map.toList (stateRequests st), reqClient req == cid, reqLease req == Nothing] $ \rid →
      terminate svc rid Cancelled
    forM_ (Set.toList (clientLeases client)) (releaseLeaseSTM svc)
    forM_ (Set.toList (clientViews client)) (closeViewByIdSTM svc)
    modifySt svc (\cur → cur {stateClients = Map.delete cid (stateClients cur)})

-- | Close admission, settle every request exactly once, end every arena and
-- every view demand. Idempotent.
closeServiceSTM ∷ Service → STM ()
closeServiceSTM svc = do
  modifySt svc (\st → st {statePhase = Closing})
  st <- readSt svc
  forM_ (Map.toList (stateRequests st)) $ \(rid, req) →
    terminate svc rid (if isJust (reqArena req) then Failed ArenaClosed else Cancelled)
  after <- readSt svc
  forM_ (Map.keys (stateArenas after)) (closeArena svc)
  forM_ (Map.keys (stateViews after)) (closeViewByIdSTM svc)
  modifySt svc (\cur → cur {stateLeases = fmap (\l → l {leaseLive = False}) (stateLeases cur)})

-- ---------------------------------------------------------------------------
-- Views

-- | What a view demand did, for its producer.
data DemandReceipt = DemandReceipt
  { receiptAdmitted ∷ ![RegionCoord]
  , receiptPending ∷ ![RegionCoord]
  , receiptWithdrawn ∷ ![RegionCoord]
  , receiptExcluded ∷ ![RegionCoord]
  , receiptTruncated ∷ ![RegionCoord]
  }
  deriving stock (Eq, Show)

openViewSTM ∷ Service → Client → STM (Either Refused View)
openViewSTM svc client =
  admitting svc >>= \case
    Left refused → pure (Left refused)
    Right st → case clientOf svc client st of
      Left refused → pure (Left refused)
      Right cid
        | Map.size (stateViews st) >= configMaxViews (serviceConfig svc) → pure (Left (RefusedBusy BusyViews))
        | otherwise → case allocate (stateNextView st) of
            Left refused → pure (Left refused)
            Right vid → do
              writeTVar (serviceState svc) st
                { stateNextView = vid + 1
                , stateViews = Map.insert (ViewId vid) (ViewRec cid) (stateViews st)
                , stateClients = Map.adjust (\c → c {clientViews = Set.insert (ViewId vid) (clientViews c)}) cid (stateClients st)
                }
              pure (Right (View (serviceTag svc) (ViewId vid)))

setViewDemandSTM ∷ Service → View → ArenaLease → [RegionDemand] → STM (Either Refused DemandReceipt)
setViewDemandSTM svc (View tag vid) lease demands =
  admitting svc >>= \case
    Left refused → pure (Left refused)
    Right st
      | tag /= serviceTag svc → pure (Left RefusedAuthority)
      | otherwise → case (Map.lookup vid (stateViews st), leaseOf svc lease st) of
          (Just viewRec, Right (_, ls))
            | viewClient viewRec /= leaseClient ls → pure (Left RefusedAuthority)
            | not (leaseLive ls) → pure (Left RefusedAuthority)
            | otherwise → do
                outcome <- applyEvent svc (R.SetCameraDemand vid (leaseArena ls) demands)
                modifySt svc (\cur → cur {stateDispatchIdle = False})
                case outcome of
                  Right report → do
                    let given = fromMaybe (DemandReceipt [] [] [] [] []) (receipt (R.reportDecision report))
                        described = Set.size (Set.fromList (receiptAdmitted given <> receiptPending given))
                    modifySt svc (\cur → cur {stateWork = (stateWork cur) {rwViews = (if described == 0 then Map.delete vid else Map.insert vid (fromIntegral described)) (rwViews (stateWork cur))}})
                    pure (Right given)
                  Left refusal → pure (Left (either id (const RefusedAuthority) (shortRefused refusal)))
          _ → pure (Left RefusedAuthority)
  where
    receipt = \case
      R.CameraSet adm pending withdrawn _ _ excluded truncated →
        Just
          DemandReceipt
            { receiptAdmitted = concat [map snd (R.admissionJobs a) <> R.admissionShared a | a <- adm]
            , receiptPending = pending
            , receiptWithdrawn = withdrawn
            , receiptExcluded = excluded
            , receiptTruncated = truncated
            }
      _ → Nothing
    shortRefused refusal = case busyWhy refusal of
      ShortRefused refused → Left refused
      ShortFailed _ → Right ()

clearViewDemandSTM ∷ Service → View → STM (Either Refused ())
clearViewDemandSTM svc (View tag vid)
  | tag /= serviceTag svc = pure (Left RefusedAuthority)
  | otherwise = do
      st <- readSt svc
      if Map.member vid (stateViews st)
        then do
          _ <- applyEvent svc (R.ClearCameraDemand vid)
          modifySt svc (\cur → cur {stateWork = (stateWork cur) {rwViews = Map.delete vid (rwViews (stateWork cur))}})
          pure (Right ())
        else pure (Left RefusedAuthority)

closeViewSTM ∷ Service → View → STM ()
closeViewSTM svc (View tag vid) = when (tag == serviceTag svc) (closeViewByIdSTM svc vid)

closeViewByIdSTM ∷ Service → ViewId → STM ()
closeViewByIdSTM svc vid = do
  st <- readSt svc
  forM_ (Map.lookup vid (stateViews st)) $ \viewRec → do
    modifySt svc $ \cur →
      cur
        { stateViews = Map.delete vid (stateViews cur)
        , stateClients = Map.adjust (\c → c {clientViews = Set.delete vid (clientViews c)}) (viewClient viewRec) (stateClients cur)
        , stateWork = (stateWork cur) {rwViews = Map.delete vid (rwViews (stateWork cur))}
        }
    () <$ applyEvent svc (R.ClearCameraDemand vid)

-- ---------------------------------------------------------------------------
-- Holds

-- | Take a borrow of resident regions and the snapshot it protects.
acquireSnapshotSTM ∷ Service → ArenaLease → [RegionCoord] → STM (Either Refused (HoldId, Snapshot))
acquireSnapshotSTM svc lease regions =
  admitting svc >>= \case
    Left refused → pure (Left refused)
    Right st → case leaseOf svc lease st of
      Left refused → pure (Left refused)
      Right (_, ls)
        | not (leaseLive ls) → pure (Left RefusedAuthority)
        | length (take (fromIntegral (R.limitHoldRegions (R.modelLimits (stateModel st))) + 1) regions) > fromIntegral (R.limitHoldRegions (R.modelLimits (stateModel st))) →
            -- Refused before any region is enumerated or restricted.
            pure (Left (RefusedInvalid "a borrow names more regions than a hold may"))
        | otherwise → case (Map.lookup (leaseArena ls) (stateArenas st), allocate (stateNextHold st)) of
            (Nothing, _) → pure (Left RefusedAuthority)
            (_, Left refused) → pure (Left refused)
            (Just arena, Right hid) → do
              let snapshot =
                    Snapshot
                      { snapArena = leaseArena ls
                      , snapRevision = arenaRevision arena
                      , snapGeneration = arenaGeneration arena
                      , snapRegions = regions
                      , snapPalette = arenaPalette arena
                      , snapResident = restrictResident regions (arenaResident arena)
                      }
                  stats = residentStats (snapResident snapshot)
                  backing = fromIntegral (statPayloadBytes stats + statMetadataBytes stats) ∷ Word64
                  outstanding = retainedBankUse st
              -- Backing is charged conservatively per snapshot (a version two
              -- snapshots share is counted for each) and refused, before the model
              -- is touched, when the snapshot bank cannot hold it.
              if backing > configRetainedBytes (serviceConfig svc) - min (configRetainedBytes (serviceConfig svc)) outstanding
                then pure (Left (RefusedBusy BusyRetained))
                else do
                  outcome <- applyEvent svc (R.AcquireHold (HoldId hid) (leaseArena ls) R.Borrow regions)
                  case outcome of
                    Left refusal → pure (Left (either id (const RefusedAuthority) (case busyWhy refusal of ShortRefused r → Left r; ShortFailed _ → Right ())))
                    Right _ → do
                      modifySt svc $ \cur →
                        cur
                          { stateNextHold = hid + 1
                          , stateBorrowers = stateBorrowers cur + 1
                          , stateSnapshots = Map.insert (HoldId hid) backing (stateSnapshots cur)
                          , -- what the snapshot handed out covers, for inspection
                            stateWork = (stateWork cur) {rwHolds = Map.insert (HoldId hid) (fromIntegral (Set.size (Set.fromList (snapRegions snapshot))), snapshotBacking snapshot) (rwHolds (stateWork cur))}
                          }
                      pure (Right (HoldId hid, snapshot))

-- | The accounted bytes a snapshot backs, measured on the snapshot value that was handed out:
-- the payload and segment metadata and column index entries of the resident detail it keeps
-- alive. Read from what the snapshot holds, never from the retained-bank ledger.
snapshotBacking ∷ Snapshot → Word64
snapshotBacking snapshot =
  let stats = residentStats (snapResident snapshot)
   in fromIntegral (statPayloadBytes stats) + fromIntegral (statMetadataBytes stats)

-- | Return a borrow. Idempotent.
releaseSnapshotSTM ∷ Service → HoldId → STM ()
releaseSnapshotSTM svc hid =
  applyEvent svc (R.ReleaseHold hid) >>= \case
    Right _ → modifySt svc (\st → st {stateBorrowers = stateBorrowers st - 1, stateSnapshots = Map.delete hid (stateSnapshots st), stateWork = (stateWork st) {rwHolds = Map.delete hid (rwHolds (stateWork st))}})
    Left _ → pure ()

-- ---------------------------------------------------------------------------
-- Invariants

-- | Every structural rule that ties the request table, leases, names, arenas
-- and holds to the accounting model. An empty list means the state is coherent.
invariants ∷ Config → St → [String]
invariants config st =
  map ("model: " <>) (R.modelInvariants model)
    <> map (("charge: " <>) . show) (R.chargeCheck model)
    <> [ "request " <> show rid <> " claims a model record the model lacks"
       | (rid, req) <- Map.toList (stateRequests st) <> Map.toList (stateGhosts st)
       , reqModel req
       , rid `notElem` modelIds
       ]
    <> [ "model request " <> show rid <> " has no table entry holding it"
       | rid <- modelIds
       , maybe True (not . reqModel) (Map.lookup rid (stateRequests st) <|> Map.lookup rid (stateGhosts st))
       ]
    <> [ "the request " <> show rid <> " is being prepared but the model no longer holds its credits"
       | Just (rid, _) <- [stateRunning st]
       , rid `notElem` modelIds
       ]
    <> [ "transfer-retry memory for " <> show key <> " outlives its region"
       | key <- Map.keys (stateTransfers st) <> Map.keys (stateHandoffBusy st)
       , key `notElem` [(R.regionArena r, R.regionCoord r) | r <- R.modelRegions model]
       ]
    <> [ "a ghost or a deferred retirement exists while no preparation is running"
       | stateRunning st == Nothing
       , not (Map.null (stateGhosts st)) || not (Set.null (stateDeferredRetire st))
       ]
    <> [ "lease " <> show lid <> " is live but its arena is not"
       | (lid, ls) <- Map.toList (stateLeases st)
       , leaseLive ls
       , not (maybe False (Set.member lid . arenaLeases) (Map.lookup (leaseArena ls) (stateArenas st)))
       ]
    <> [ "name " <> Text.unpack name <> " claims a missing arena"
       | (name, ClaimLive aid) <- Map.toList (stateNames st)
       , not (Map.member aid (stateArenas st))
       ]
    <> [ "name " <> Text.unpack name <> " claims a missing open"
       | (name, ClaimPending rid) <- Map.toList (stateNames st)
       , maybe True (not . isOpenCmd) (Map.lookup rid (stateRequests st))
       ]
    <> [ "arena " <> show aid <> " is both live and retiring"
       | aid <- Map.keys (stateArenas st)
       , Map.member aid (stateRetiring st)
       ]
    <> [ "snapshot ledger " <> show (Map.keys (stateSnapshots st)) <> " disagrees with the model's borrows"
       | Set.fromList (Map.keys (stateSnapshots st)) /= Set.fromList [h | (h, _, R.Borrow, _) <- R.modelHolds model]
       ]
    <> [ "command slots " <> show (R.slotInUse model R.CommandSlot) <> " + " <> show (slotsHeldHere st) <> " beyond the limit"
       | fromIntegral (R.slotInUse model R.CommandSlot) + slotsHeldHere st > fromIntegral (R.limitSlot (R.modelLimits model) R.CommandSlot ∷ Word64)
       ]
    <> [ "retained bank holds " <> show (retainedBankUse st) <> " beyond its limit " <> show snapshotBank
       | retainedBankUse st > snapshotBank
       ]
    <> [ "limit " <> limitRowName row' <> ": admission counts " <> show (limitRowCounted row') <> " but the entities holding it number " <> show (limitRowHeld row')
       | row' <- limitRows config st
       , limitRowCounted row' /= limitRowHeld row'
       ]
    <> [ "limit " <> limitRowName row' <> " is exceeded: " <> show (limitRowCounted row') <> " > " <> show (limitRowMax row')
       | row' <- limitRows config st
       , limitRowCounted row' > limitRowMax row'
       ]
    <> [ "borrowers " <> show (stateBorrowers st) <> " but the model holds " <> show borrows
       | stateBorrowers st /= borrows
       ]
  where
    snapshotBank = configRetainedBytes config
    model = stateModel st
    modelIds = [R.requestId info | info <- R.modelRequests model]
    borrows = length [() | (_, _, R.Borrow, _) <- R.modelHolds model]

-- | THE charge of what a compiled arena keeps for its life in the compile account (owner decision
-- 2026-11-13, option B): its compiled connectivity's result bytes and #661's ordered member index
-- over its nodes ('D.envSharedBytes' charges an environment exactly this; an open checks the two
-- agree). One function: the account's size and the per-arena bound are this charge at the
-- compiler's limits, and a real arena is charged this at its own figures.
sharedCharge ∷ Integer → Integer → Word64
sharedCharge resultBytes nodes = fromInteger (resultBytes + memberIndexBytesPerNode * nodes)

-- | #661's per-node charge for the ordered member index ('D.envSharedBytes').
memberIndexBytesPerNode ∷ Integer
memberIndexBytesPerNode = 32

-- | The per-arena bound: 'sharedCharge' at the compiler's result and node limits.
perArenaShared ∷ C.ConnectivityLimits → Word64
perArenaShared limits = sharedCharge (toInteger (C.limitResultBytes limits)) (toInteger (C.limitNodes limits))

-- | The compile account's size: every other arena that may be open at once at its per-arena bound,
-- and the one compilation active in the session at its peak (which includes its result).
compileBankFor ∷ Int → C.ConnectivityLimits → Word64
compileBankFor arenas limits = fromIntegral (max 0 (arenas - 1)) * perArenaShared limits + fromIntegral (C.limitPeakBytes limits)

-- | The compile account, checked: it must hold every arena the cap admits at its per-arena bound
-- (a compilation's peak includes its result, so the active one never needs more than its peak;
-- an open arena keeps its share), and be representable. Computed in 'Integer' first.
compileBankChecked ∷ Int → C.ConnectivityLimits → Either ConfigError Word64
compileBankChecked arenas limits
  | needed > account || account > toInteger (maxBound ∷ Word64) = Left (ConfigCompileBank needed account)
  | otherwise = Right (fromInteger account)
  where
    bound = toInteger (C.limitResultBytes limits) + memberIndexBytesPerNode * toInteger (C.limitNodes limits)
    needed = toInteger (max 0 arenas) * bound
    account = toInteger (max 0 (arenas - 1)) * bound + toInteger (C.limitPeakBytes limits)

-- | The accounting model's limits, checked: the compile account must leave the resident
-- bank something, and the model's own minimum budgets must hold.
modelLimitsChecked ∷ Config → Either ConfigError R.Limits
modelLimitsChecked config = either (Left . ConfigError) Right (modelLimitsFor config)

-- | The accounting model's limits: the configured profile with the snapshot bank taken out
-- of its staging bank and the compile account (every arena's compiled connectivity and the
-- one active compilation's peak, P-15) out of its resident bank, so the two can never overbook
-- the approved banks. The model's edit bank is NOT a second edit bank: it is sized so that every
-- command slot can hold one removal's reservation and never refuse one, and its retained
-- balance is zero at every step (a backed removal commits with nothing retained in RAM; the
-- 64 MiB edit bank is the store's, 'Hetoimasia.Terrain.Runtime.Store.Admission'). Rebuilt
-- through the validating constructor, so a carve-out that leaves a bank below the minimum
-- budgets is a typed configuration error.
modelLimitsFor ∷ Config → Either R.LimitError R.Limits
modelLimitsFor config =
  R.mkLimits
    R.LimitsSpec
      -- the compile account is its own, beside the three banks (owner decision 2026-11-13, option B)
      { R.specResidentBytes = bytes R.ResidentBank
      , R.specEditBytes = slot R.CommandSlot * toInteger R.removalRetainedBytes
      , R.specStagingBytes = bytes R.StagingBank - toInteger (configRetainedBytes config)
      , R.specLoadJobs = slot R.LoadJobSlot
      , R.specQueuedCommands = slot R.CommandSlot
      , R.specPinsPerView = slot R.ViewPinSlot
      , R.specAgingQuanta = toInteger (R.limitAgingQuanta limits)
      , R.specQueryRegions = toInteger (R.limitQueryRegions limits)
      , R.specExtentX = toInteger ex
      , R.specExtentY = toInteger ey
      , R.specExtentZ = toInteger ez
      , R.specHoldRegions = toInteger (R.limitHoldRegions limits)
      , R.specCameraRegions = toInteger (R.limitCameraRegions limits)
      }
  where
    limits = configLimits config
    bytes = toInteger . R.limitBytes limits
    slot = toInteger . R.limitSlot limits
    (ex, ey, ez) = R.limitExtent limits

-- | The next residency generation. It saturates rather than wraps: a generation is
-- only compared for change, and two states are never confused by its end.
bumpGeneration ∷ Word64 → Word64
bumpGeneration g = if g == maxBound then g else g + 1

-- | Retire everything in flight, at the owner's terminal safe point and whatever
-- ended it: acknowledge each cancelling load, abandon each outstanding transfer,
-- and finish each committed victim's release. Non-blocking bookkeeping, safe under
-- the uninterruptible mask. Idempotent. A hold that is still outstanding keeps its
-- arena retiring until its borrower releases it.
retireInFlightSTM ∷ Service → STM ()
retireInFlightSTM svc = do
  st <- readSt svc
  let model = stateModel st
  forM_ [(R.regionArena r, R.regionCoord r) | r <- R.modelRegions model, isJust (R.regionHandoff r)] $ \(aid, region) → do
    void (applyEvent svc (R.HandoffFailed aid region))
    endHandoffWork svc aid region
  victims <- stateVictims <$> readSt svc
  forM_ victims $ \key@(aid, region) → do
    modifySt svc $ \cur →
      cur
        { stateArenas = Map.adjust (discardOf region) aid (stateArenas cur)
        , stateRetiring = Map.adjust (discardOf region) aid (stateRetiring cur)
        }
        `forgetRegionRetry` key
    applyEvent svc (R.VictimReleased aid region)
  modifySt svc (\cur → cur {stateVictims = Seq.empty})
  after <- readSt svc
  forM_ [R.jobId j | j <- R.modelJobs (stateModel after), R.jobPhase j == R.JobCancellingPhase] $ \jid → do
    void (applyEvent svc (R.JobAcknowledged jid))
    endJobWork svc jid
  -- No transfer is outstanding any more, and a job the model no longer holds has ended.
  final <- readSt svc
  let liveJobs = Set.fromList [R.jobId j | j <- R.modelJobs (stateModel final)]
  modifySt svc (\cur → cur {stateWork = (stateWork cur) {rwHandoffs = Map.empty, rwJobs = Map.filterWithKey (\jid _ → Set.member jid liveJobs) (rwJobs (stateWork cur))}})
  markFreed svc
  where
    discardOf region a = a {arenaResident = discardRegion region (arenaResident a), arenaGeneration = bumpGeneration (arenaGeneration a)}

-- | Admit a request's demand to the model again, at the arena's current revision: the
-- request's record is withdrawn and a fresh one made in the same transaction. If the model
-- is busy the request waits, holding nothing, until capacity frees; it is never failed for
-- capacity. Its staging is dropped: it is read again at the new revision.
readmitSTM ∷ Service → RequestId → STM ()
readmitSTM svc rid = do
  st <- readSt svc
  forM_ (Map.lookup rid (stateRequests st)) $ \req →
    forM_ (reqArena req >>= \aid → (,) aid <$> Map.lookup aid (stateArenas st)) $ \(aid, arena) → do
      when (reqModel req) (withdrawRecord svc rid req)
      case demandFor (arenaSource arena) emptyChanges (reqCmd req) of
        Left why → terminate svc rid (Failed (SourceFailure (Text.pack why)))
        Right demands → do
          let demands' = case reqCmd req of
                -- a surface keeps the demand its gather found; a fresh gather corrects it
                CSurface {} → if null (reqDemand req) then demands else reqDemand req
                _ → demands
              event = case reqCmd req of
                CRemove tile _ → R.SubmitRemoval rid aid (arenaRevision arena) tile
                _ → R.SubmitQuery rid aid (arenaRevision arena) demands'
          outcome <- applyEvent svc event
          let admitted = either (const False) (const True) outcome
          modifySt svc $ \s →
            s {stateRequests = Map.insert rid req {reqModel = admitted, reqDemand = demands', reqPhase = Waiting} (stateRequests s)}
          -- Every refusal is either temporary pressure, which keeps the request
          -- waiting (charged) to be admitted again, or permanent, which ends it
          -- with a typed failure; nothing can wait on a refusal that will not clear.
          case outcome of
            Right _ → pure ()
            Left refusal → case refusal of
              R.Busy _ → pure ()
              R.RetainedEditsExhausted {} → do
                recordDefect svc (AccountingDefect "the model's edit reservation refused a removal: it is sized never to")
                terminate svc rid (Failed (HostFailure "the model's edit reservation refused a removal"))
              R.Invalid reason → terminate svc rid (Failed (Superseded (Text.pack ("no longer admissible: " <> show reason))))
              R.Stale _ → terminate svc rid (Failed ArenaClosed)
              R.ContractFailure why → do
                recordDefect svc (AccountingDefect (Text.pack (show why)))
                terminate svc rid (Failed (HostFailure (Text.pack ("resubmission: " <> show why))))

-- | Give a grant back: its staging and control, and its cache entries (unpinned, then dropped).
releaseCredit ∷ Grant → Admission → Admission
releaseCredit g adm0 = foldr dropOne (A.release g adm0) (A.grantEntries g)
  where
    dropOne entry adm = either (const (A.unpinEntry entry adm)) id (A.dropEntry entry (A.unpinEntry entry adm))

