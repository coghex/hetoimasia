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
  , markFreed

    -- * Authorities
  , clientOf
  , leaseOf

    -- * Admission
  , Submission (..)
  , admit
  , readAnswer
  , demandFor
  , pendingEdits

    -- * Settlement
  , terminate
  , terminateWith
  , releaseReq
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
  , bumpGeneration
  , retireInFlightSTM
  , modelLimitsFor
  ) where

import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad (forM_, unless, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Coordinate
import qualified Hetoimasia.Terrain.Query as Q
import qualified Hetoimasia.Terrain.Residency as R
import Hetoimasia.Terrain.Residency (ArenaId (..), HoldId (..), RegionDemand, RequestId (..), Revision (..), ViewId (..))
import Hetoimasia.Terrain.Runtime.Internal.Content
import Hetoimasia.Terrain.Runtime.Internal.Snapshot
import Hetoimasia.Terrain.Resident (ResidentStats (..), discardRegion, residentStats)
import Hetoimasia.Terrain.Runtime.Internal.Types
import Hetoimasia.Terrain.Source (Source, SourceError)

-- ---------------------------------------------------------------------------
-- State access

readSt ∷ Service → STM St
readSt = readTVar . serviceState

modifySt ∷ Service → (St → St) → STM ()
modifySt svc = modifyTVar' (serviceState svc)

-- | Something that may free capacity happened; the owner retries what waits.
markFreed ∷ Service → STM ()
markFreed svc = modifySt svc (\st → st {stateFreed = True, stateDispatchIdle = False})

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
        (if freesCapacity event then \x → x {stateFreed = True, stateDispatchIdle = False} else id)
        st
          { stateModel = model
          , stateVictims = stateVictims st <> Seq.fromList (decisionVictims (R.reportDecision report))
          , stateRetiring = foldr Map.delete (stateRetiring st) (R.reportSettled report)
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

-- | Keep a bounded record of an unexpected defect.
recordDefect ∷ Service → Defect → STM ()
recordDefect svc defect =
  modifySt svc (\st → st {stateDefects = take 16 (defect : stateDefects st), stateDefectCount = stateDefectCount st + 1})

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
    Right st → case allocate (stateNextClient st) of
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

-- | How an admission ended short of a request in the table.
data Short
  = ShortRefused !Refused
  | ShortFailed !Failure

busyWhy ∷ R.Refusal → Short
busyWhy refusal = case refusal of
  R.Busy reason → ShortRefused (RefusedBusy (BusyModel reason))
  R.RetainedEditsExhausted {} → ShortRefused (RefusedBusy BusyRetainedEdits)
  R.Invalid reason → ShortRefused (RefusedInvalid (Text.pack (show reason)))
  R.Stale _ → ShortFailed ArenaClosed
  R.ContractFailure reason → ShortFailed (HostFailure (Text.pack ("accounting: " <> show reason)))

-- | The demand a read puts on the model for the arena as it is now. It is cheap
-- and bounded: a cell, the regions of a bounded range, or the cell holding a
-- column's top.
demandFor ∷ Arena → Cmd → Either String [RegionDemand]
demandFor arena cmd = case cmd of
  CCell tile → Right [tileDemand tile]
  CColumn column range → columnDemands column range
  CSurface column →
    let top = Q.highestOccupied (arenaSource arena) (arenaChanges arena) column
        level = maybe 0 (toInteger . axisValue . Q.occupiedLevel) top
     in do
          tile <- either (Left . show) Right (tileCoord (toInteger (axisValue (columnX column))) (toInteger (axisValue (columnY column))) level)
          Right [tileDemand tile]
  CRemove tile _ → Right [tileDemand tile]
  _ → Left "not a data command"

-- | The answer of a read from an arena's source and overlay, with the demand
-- that answer needs resident. It is pure and is recomputed whenever the
-- revision it was computed at is superseded.
readAnswer ∷ Config → ArenaId → Revision → Arena → Cmd → Either Failure (Answer, [RegionDemand])
readAnswer config aid rev arena cmd = case cmd of
  CCell tile → Right (ACell (CellAnswer aid rev (Q.cellAt source changes tile)), [tileDemand tile])
  CColumn column range → case Q.columnRuns (configQueryLimits config) source changes column range of
    Left err → Left (TooLarge err)
    Right runs → do
      demands <- either (Left . SourceFailure . Text.pack) Right (columnDemands column range)
      Right (AColumn (ColumnAnswer aid rev runs), demands)
  CSurface column → do
    demands <- either (Left . SourceFailure . Text.pack) Right (demandFor arena cmd)
    Right (ASurface (SurfaceAnswer aid rev (Q.highestOccupied source changes column)), demands)
  _ → Left (HostFailure "not a read")
  where
    source = arenaSource arena
    changes = arenaChanges arena

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

isRemoval ∷ Req → Bool
isRemoval req = case reqCmd req of CRemove {} → True; _ → False

isDone ∷ Req → Bool
isDone req = case reqPhase req of Done → True; _ → False

countReqs ∷ (Req → Bool) → St → Int
countReqs p st = Map.size (Map.filter p (stateRequests st))

-- | The removals admitted for an arena and not yet settled.
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
    when (Map.size (stateArenas st) + countReqs isOpenCmd st >= configMaxArenas config) (Left (ShortRefused (RefusedBusy BusyArenas)))
    when (leaseUse >= configMaxLeases config) (Left (ShortRefused (RefusedBusy BusyLeases)))
    Right (Insertion (COpen name source cid) Nothing cid Nothing False [] (Just name))
  SubOpenInvalid client err → pure $ do
    _ <- first' ShortRefused (clientOf svc client st)
    Left (ShortFailed (Definition err))
  SubAttach client name → pure $ do
    cid <- first' ShortRefused (clientOf svc client st)
    checkName name
    when (leaseUse >= configMaxLeases config) (Left (ShortRefused (RefusedBusy BusyLeases)))
    Right (Insertion (CAttach name cid) Nothing cid Nothing False [] Nothing)
  SubCell lease tile → dataCommand lease (CCell tile)
  SubColumn lease column range
    -- Before any region is enumerated: a range of any length is refused here, in
    -- constant time, however many levels it names.
    | zRangeLevels range > toInteger (Q.limitRangeLevels (configQueryLimits config)) →
        pure (Left (ShortRefused (RefusedInvalid "column range exceeds the level limit")))
    | otherwise → dataCommand lease (CColumn column range)
  SubSurface lease column → dataCommand lease (CSurface column)
  SubRemove lease tile precondition → case liveArena lease of
    Left short → pure (Left short)
    Right (lid, ls, aid, arena)
      | stale aid arena precondition → pure (Left (ShortFailed StaleView))
      | revisionExhausted aid arena → pure (Left (ShortRefused RefusedExhausted))
      | otherwise → do
          let cmd = CRemove tile precondition
          outcome <- slotRefusal >>= \case
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
    slotRefusal = do
      let model = stateModel st
          limit = R.limitSlot (R.modelLimits model) R.CommandSlot
          held = R.slotInUse model R.CommandSlot + fromIntegral (retainedResults st)
      pure (if held >= limit then Just (R.Busy (R.SlotFull R.CommandSlot limit held 1)) else Nothing)
    leaseUse = Map.size (stateLeases st) + countReqs isAcquisition st
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
    revisionExhausted aid arena =
      let Revision n = arenaRevision arena
       in toInteger n + toInteger (pendingEdits aid st) + 1 >= toInteger (maxBound ∷ Word64)
    dataCommand lease cmd = case liveArena lease of
      Left short → pure (Left short)
      Right (lid, ls, aid, arena) → case demandFor arena cmd of
        Left why → pure (Left (ShortFailed (SourceFailure (Text.pack why))))
        Right demands → do
          outcome <- slotRefusal >>= \case
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
  when (reqModel req) (() <$ applyEvent svc (R.Withdraw rid))
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
closeArena ∷ Service → ArenaId → STM ()
closeArena svc aid = do
  st <- readSt svc
  forM_ (Map.lookup aid (stateArenas st)) $ \arena → do
    forM_ [rid | (rid, req) <- Map.toList (stateRequests st), reqArena req == Just aid] $ \rid →
      terminate svc rid (Failed ArenaClosed)
    modifySt svc $ \cur →
      cur
        { stateArenas = Map.delete aid (stateArenas cur)
        , stateRetiring = Map.insert aid arena (stateRetiring cur)
        , stateNames = case Map.lookup (arenaName arena) (stateNames cur) of
            Just (ClaimLive claimed) | claimed == aid → Map.delete (arenaName arena) (stateNames cur)
            _ → stateNames cur
        , stateLeases = foldr (Map.adjust (\l → l {leaseLive = False})) (stateLeases cur) (Set.toList (arenaLeases arena))
        , stateTransfers = Map.filterWithKey (\(owner, _) _ → owner /= aid) (stateTransfers cur)
        }
    () <$ applyEvent svc (R.RetireArena aid)

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
                pure $ case outcome of
                  Right report → Right (fromMaybe (DemandReceipt [] [] [] [] []) (receipt (R.reportDecision report)))
                  Left refusal → Left (either id (const RefusedAuthority) (shortRefused refusal))
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
        then Right () <$ applyEvent svc (R.ClearCameraDemand vid)
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
                  outstanding = sum (Map.elems (stateSnapshots st))
              -- Backing is charged conservatively per snapshot (a version two
              -- snapshots share is counted for each) and refused, before the model
              -- is touched, when the snapshot bank cannot hold it.
              if backing > configSnapshotBytes (serviceConfig svc) - min (configSnapshotBytes (serviceConfig svc)) outstanding
                then pure (Left (RefusedBusy BusySnapshots))
                else do
                  outcome <- applyEvent svc (R.AcquireHold (HoldId hid) (leaseArena ls) R.Borrow regions)
                  case outcome of
                    Left refusal → pure (Left (either id (const RefusedAuthority) (case busyWhy refusal of ShortRefused r → Left r; ShortFailed _ → Right ())))
                    Right _ → do
                      modifySt svc (\cur → cur {stateNextHold = hid + 1, stateBorrowers = stateBorrowers cur + 1, stateSnapshots = Map.insert (HoldId hid) backing (stateSnapshots cur)})
                      pure (Right (HoldId hid, snapshot))

-- | Return a borrow. Idempotent.
releaseSnapshotSTM ∷ Service → HoldId → STM ()
releaseSnapshotSTM svc hid =
  applyEvent svc (R.ReleaseHold hid) >>= \case
    Right _ → modifySt svc (\st → st {stateBorrowers = stateBorrowers st - 1, stateSnapshots = Map.delete hid (stateSnapshots st)})
    Left _ → pure ()

-- ---------------------------------------------------------------------------
-- Invariants

-- | Every structural rule that ties the request table, leases, names, arenas
-- and holds to the accounting model. An empty list means the state is coherent.
invariants ∷ Word64 → St → [String]
invariants snapshotBank st =
  map ("model: " <>) (R.modelInvariants model)
    <> map (("charge: " <>) . show) (R.chargeCheck model)
    <> [ "request " <> show rid <> " claims a model record the model lacks"
       | (rid, req) <- Map.toList (stateRequests st)
       , reqModel req
       , rid `notElem` modelIds
       ]
    <> [ "model request " <> show rid <> " has no table entry holding it"
       | rid <- modelIds
       , maybe True (not . reqModel) (Map.lookup rid (stateRequests st))
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
    <> [ "snapshot ledger holds " <> show (sum (Map.elems (stateSnapshots st))) <> " beyond its bank"
       | sum (Map.elems (stateSnapshots st)) > snapshotBank
       ]
    <> [ "borrowers " <> show (stateBorrowers st) <> " but the model holds " <> show borrows
       | stateBorrowers st /= borrows
       ]
  where
    model = stateModel st
    modelIds = [R.requestId info | info <- R.modelRequests model]
    borrows = length [() | (_, _, R.Borrow, _) <- R.modelHolds model]

-- | The accounting model's limits: the configured profile with the snapshot
-- bank taken out of its staging bank. Rebuilt through the validating
-- constructor, so a carve-out that leaves staging below the minimum budgets is a
-- typed configuration error.
modelLimitsFor ∷ Config → Either R.LimitError R.Limits
modelLimitsFor config =
  R.mkLimits
    R.LimitsSpec
      { R.specResidentBytes = bytes R.ResidentBank
      , R.specEditBytes = bytes R.EditBank
      , R.specStagingBytes = bytes R.StagingBank - toInteger (configSnapshotBytes config)
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
  forM_ [(R.regionArena r, R.regionCoord r) | r <- R.modelRegions model, isJust (R.regionHandoff r)] $ \(aid, region) →
    applyEvent svc (R.HandoffFailed aid region)
  victims <- stateVictims <$> readSt svc
  forM_ victims $ \key@(aid, region) → do
    modifySt svc $ \cur →
      cur
        { stateArenas = Map.adjust (discardOf region) aid (stateArenas cur)
        , stateRetiring = Map.adjust (discardOf region) aid (stateRetiring cur)
        , stateTransfers = Map.delete key (stateTransfers cur)
        }
    applyEvent svc (R.VictimReleased aid region)
  modifySt svc (\cur → cur {stateVictims = Seq.empty})
  after <- readSt svc
  forM_ [R.jobId j | j <- R.modelJobs (stateModel after), R.jobPhase j == R.JobCancellingPhase] $ \jid →
    applyEvent svc (R.JobAcknowledged jid)
  markFreed svc
  where
    discardOf region a = a {arenaResident = discardRegion region (arenaResident a), arenaGeneration = bumpGeneration (arenaGeneration a)}
