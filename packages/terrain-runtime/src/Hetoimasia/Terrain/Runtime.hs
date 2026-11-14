-- | The scoped, transactional terrain service (TRA-4).
--
-- One dedicated owner thread is the sole writer of arena contents: the resident
-- detail, the retained changes, the content revision. The public port below is
-- bookkeeping: it admits requests without blocking, cancels, releases and closes,
-- and it never mutates terrain. Every accepted request reaches exactly one
-- terminal outcome ('Settlement'), and a removal commits its content change, its
-- revision and its successful settlement in one transaction that also decides
-- cancellation, the parent session's admission and the arena's closure.
--
-- == Using it
--
-- 'withTerrainService' builds the service inside the caller's scopes, starts its
-- owner through the injected 'Supervisor', runs the body, and on every exit
-- closes admission, settles what is pending, and waits until the owner and every
-- outstanding borrow have ended before it returns. A client is registered with
-- 'registerClient'; 'openArena' and 'attachArena' yield leases; 'cellAt',
-- 'columnAt', 'surfaceAt' and 'removeAt' are requests through a lease, each
-- admitted at once or refused with a reason ('Refused'), never blocked.
--
-- See the package README for the state ownership table, the invariants and the
-- bounds.
module Hetoimasia.Terrain.Runtime
  ( -- * The service
    Service
  , Config (..)
  , ConfigError (..)
  , defaultConfig
  , Ports (..)
  , StoragePort
  , storagePort
  , SessionAdmission (..)
  , alwaysAdmitting
  , Supervisor (..)
  , OwnerControl (..)
  , standaloneSupervisor
  , withTerrainService
  , closeService
  , awaitOwnerStopped
  , awaitClosed

    -- * Diagnostics seam
  , Probe (..)
  , Point (..)
  , noProbe
  , Defect (..)

    -- * Authority
  , Client
  , ArenaLease
  , Request
  , registerClient
  , endClient
  , releaseLease

    -- * Requests
  , Pending
  , pendingRequest
  , Settlement (..)
  , Answer (..)
  , CellAnswer (..)
  , ColumnAnswer (..)
  , SurfaceAnswer (..)
  , RemoveAnswer (..)
  , GrowAnswer (..)
  , RetryAnswer (..)
  , StorageFault (..)
  , FullWhy (..)
  , IntegritySource (..)
  , faultCode
  , Failure (..)
  , Refused (..)
  , BusyWhy (..)
  , Precondition (..)
  , CancelResult (..)
  , openArena
  , attachArena
  , cellAt
  , columnAt
  , surfaceAt
  , removeAt
  , knowledgeAt
  , KnowledgeAnswer (..)
  , growArena
  , retryArena
  , arenaStatus
  , arenaStatusSTM
  , ArenaStatus (..)
  , StorageState (..)
  , DiscoveryState (..)
  , inspectEditBankSTM
  , inspectStorageQueuedSTM
  , inspectStoragePressedSTM
  , markOf
  , PressureMark
  , perArenaBound
  , compileAccountFor
  , Condition (..)
  , await
  , cancelPending

    -- * View demand
  , View
  , DemandReceipt (..)
  , openView
  , setViewDemand
  , clearViewDemand
  , closeView

    -- * Snapshots
  , Snapshot
  , SnapshotCell (..)
  , snapshotCell
  , snapshotIncarnation
  , snapshotRevision
  , snapshotGeneration
  , withSnapshot

    -- * Inspection
  , inspectInvariants
  , inspectBacked
  , inspectCompileSTM
  , backedAtRestSTM
  , inspectModel
  , inspectModelSTM
  , inspectDefects
  , inspectSnapshotBytes
  , inspectRetainedChargesSTM
  , inspectLimits
  , inspectConfig
  , LimitRow (..)
  , inspectCensusSTM
  , Census
  , censusArenas
  , censusRequests
  , censusBorrows
  , censusRunning
  , ArenaCensus
  , censusArena
  , censusRetiring
  , censusRegionBytes
  , censusRetainedBytes
  , RequestCensus
  , censusRegions
  , censusRemoval
  , censusModelRecord
  , censusSettled
  , censusGhost
  , RunningWork
  , runningJobs
  , runningPreparation
  , runningHolds
  , runningViews
  , JobWork
  , jobWorkJob
  , jobWorkArena
  , jobWorkRegion
  , jobWorkGrantedResident
  , jobWorkGrantedScratch
  , jobWorkResident
  , jobWorkScratch
  , jobWorkSlots
  , PreparationWork
  , preparationRequest
  , preparationArena
  , preparationRemoval
  , preparationRecordBytes
  , preparationResident
  , preparationStaging
  , preparationEdit
  , inspectReadmissionWaits
  , inspectReadmissionWaitsSTM
  , inspectArena
  , inspectArenaSTM
  , stagedRemovalChanges
  , serviceAdmitting
  , ArenaView (..)
  ) where

import Control.Concurrent.STM
import Control.Exception (Exception, ExceptionWithContext, SomeException, mask, rethrowIO, throwIO, try, tryWithContext)
import Control.Monad (when)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Unique (newUnique)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Resource (withResource)
import Hetoimasia.Foundation.Worker (StartOutcome (..), WorkerGroup, awaitCompletion, requestStop, startWorker)
import Hetoimasia.Terrain.Cell (Column (..), ZRange)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Coordinate (RegionCoord, TileCoord (..), decomposeTile)
import Hetoimasia.Terrain.Query (defaultQueryLimits)
import qualified Hetoimasia.Terrain.Residency as R
import Data.Word (Word64)
import Hetoimasia.Terrain.Residency (ArenaId, Model, RegionDemand, Revision)
import Hetoimasia.Terrain.Palette (Palette)
import Hetoimasia.Terrain.Resident (Resident, columnIndexBytes, residentColumns, residentSegments)
import Hetoimasia.Terrain.Segment (segmentMetadataBytes, segmentPayloadBytes, segmentStart)
import Hetoimasia.Terrain.Runtime.Internal.Content (Prepared (..))
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Owner (ownerDefinition)
import Hetoimasia.Terrain.Runtime.Internal.Snapshot
import Hetoimasia.Terrain.Runtime.Internal.Types
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Backed.Port (StoragePort (..), storagePort)
import Hetoimasia.Terrain.Runtime.Backed.Fault (FullWhy (..), IntegritySource (..), StorageFault (..), faultCode)
import Hetoimasia.Terrain.Runtime.Internal.Backed (backedInvariants, editBankChecked, markOf, pressureMark)
import qualified Hetoimasia.Terrain.Runtime.Storage.Internal.Service as Storage
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (EditBankSpec (..), Ledger (..), defaultEditBankSpec, ledgers, mkEditBankConfig, newAdmission)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Condition (..), GrowthView (..), Usage (..), conditions, growthView, storeHeader, usage)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (defaultStoreSpec, mkStoreConfig)
import Hetoimasia.Terrain.Connectivity (defaultConnectivityLimits)
import qualified Hetoimasia.Terrain.Connectivity as C
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Discovery (defaultDiscoveryLimits)
import Hetoimasia.Terrain.Source (SourceSpec, defaultSourceLimits)

-- | The approved host profile: four arenas, 64 leases and eight views, with
-- the residency model's default banks.
defaultConfig ∷ Config
defaultConfig =
  Config
    { configLimits = R.defaultLimits
    , configMaxArenas = 4
    , configMaxLeases = 64
    , configMaxViews = 8
    , configMaxClients = 256
    , configSourceLimits = defaultSourceLimits
    , configQueryLimits = defaultQueryLimits
    , configFirstIdentity = 0
    , configFirstRevision = 0
    , configRetainedBytes = 16 * 1024 * 1024
    , configStore = defaultStoreSpec
    , configEditBank = defaultEditBankSpec
    , configConnectivity = defaultConnectivityLimits
    , configDiscovery = defaultDiscoveryLimits
    }

-- | What the service borrows. Each is narrow: the parent session's admission as
-- a transaction the service can read inside its arbitration, the supervision
-- capability that starts the owner, a logger, and a diagnostics seam.
data Ports = Ports
  { portAdmission ∷ !SessionAdmission
  , portSupervisor ∷ !Supervisor
  , portLogger ∷ !Logger
  , portProbe ∷ !Probe
  , -- | Where and how the arenas' private files are kept: the storage backend runs inside
    -- the service's own scope, its two workers in this port's group.
    portStorage ∷ !StoragePort
  }

-- | A session that is always open.
alwaysAdmitting ∷ SessionAdmission
alwaysAdmitting = SessionAdmission (pure True)

-- | The owner could not be started.
data OwnerNotStarted = OwnerNotStarted
  deriving stock (Show)

instance Exception OwnerNotStarted

-- | A supervisor that starts the owner in a worker group the caller owns and
-- drains. The application supplies its own through the runtime's supervision
-- ("Hetoimasia.Terrain.Runtime.Supervised").
standaloneSupervisor ∷ WorkerGroup → Supervisor
standaloneSupervisor group = Supervisor $ \definition →
  startWorker group definition >>= \case
    Started worker → pure (OwnerControl (atomically (requestStop worker)) (() <$ awaitCompletion worker))
    StartupFailed _ _ → throwIO OwnerNotStarted
    StartRejected _ → throwIO OwnerNotStarted

-- | Run a body with a terrain service.
--
-- The service is built in a 'withResource' scope whose release is non-blocking
-- bookkeeping (closing admission and settling what is pending). The wait for
-- the owner and for every borrower to end is in the protected boundary around
-- the body, outside any uninterruptible release, and it has no deadline: a
-- borrower that never returns keeps the service, and so its dependencies, alive.
withTerrainService ∷ Config → Ports → (Service → IO a) → IO a
withTerrainService config ports body = do
  -- Everything the configuration says is validated before anything starts: the store's
  -- allowance, the edit bank's division (for the configured arenas), the model's banks, and the
  -- compile account beside them (owner decision 2026-11-13, option B).
  storeConfig <- either (throwIO . ConfigStore) pure (mkStoreConfig (configStore config))
  editBank <- either (throwIO . ConfigEditBank) pure (mkEditBankConfig (configEditBank config) {ebsArenas = toInteger (configMaxArenas config)})
  either throwIO pure (editBankChecked (configEditBank config) {ebsArenas = toInteger (configMaxArenas config)})
  limits <- either throwIO pure (modelLimitsChecked config)
  compileBank <- either throwIO pure (compileBankChecked (configMaxArenas config) (configConnectivity config))
  bank <- newTVarIO (newAdmission editBank)
  -- The storage backend's scope encloses the service's: the owner drains and closes its
  -- arenas' files first, then the backend closes whatever is left, joins its workers and
  -- composes its kept failures into this scope's end.
  Storage.withStorageService (Storage.StoragePorts bank (spGroup sp) (portLogger ports) (spSeam sp) (spConfig sp)) $ \storage →
   withResource (acquire limits storage bank storeConfig compileBank) (\svc → atomically (closeServiceSTM svc)) $ \svc →
    -- Everything from the owner's start to the end of the drain is masked, so
    -- there is no window between a started owner and the drain that will join it:
    -- the start's own wait is interruptible, and the foundation's start drains a
    -- worker it could not acknowledge before it propagates.
    mask $ \restore → do
      started <- try (superviseOwner (portSupervisor ports) (ownerDefinition svc))
      owner <- case started of
        Left (failure ∷ SomeException) → do
          atomically (modifySt svc (\st → st {stateOwner = OwnerStopped}))
          throwIO failure
        Right control → pure control
      -- The body runs to its end or its failure; the drain then runs whatever
      -- happened. The body's own failure, with its context, is the one that
      -- propagates; an interruption received while draining is delivered after it.
      outcome <- tryWithContext (restore (body svc))
      late <- drain svc owner
      case outcome of
        Right result → maybe (pure result) rethrowIO late
        Left primary → rethrowIO (primary ∷ ExceptionWithContext SomeException)
  where
    sp = portStorage ports
    acquire limits storage bank storeConfig compileBank = do
      tag <- newUnique
      var <- newTVarIO (initialState config limits)
      pure (Service tag var config (portAdmission ports) (portLogger ports) (portProbe ports) storage bank (spDirectory sp) storeConfig compileBank)
    -- Close admission, ask the owner to stop, and wait for both proofs: the
    -- owner's worker has published its terminal outcome, and no borrower is
    -- outstanding. There is no deadline and no detach. Any exception received
    -- while waiting, of whatever type (a cancellation can deliver any), is
    -- remembered with its context, not obeyed, and returned.
    drain svc owner = do
      atomically (closeServiceSTM svc)
      stopOwner owner
      wait Nothing
      where
        retired = do
          awaitOwnerEnd owner
          st <- readSt svc
          check (stateBorrowers st == 0)
        wait late =
          tryWithContext (atomically retired) >>= \case
            Right () → pure late
            Left (interruption ∷ ExceptionWithContext SomeException) → wait (maybe (Just interruption) Just late)

-- | Wait until the owner has ended, however it ended. There is no deadline.
awaitOwnerStopped ∷ Service → IO ()
awaitOwnerStopped svc = atomically $ do
  st <- readSt svc
  check (stateOwner st == OwnerStopped)

-- | Wait until the service is closed and every accepted request has reached its
-- terminal outcome. The owner may still be running, waiting to be asked to stop.
awaitClosed ∷ Service → IO ()
awaitClosed svc = atomically $ do
  st <- readSt svc
  check (statePhase st == Closing && Map.null (stateRequests st))

-- | Close admission, settle everything pending and end every arena. Idempotent.
-- It does not wait for borrowers; the end of 'withTerrainService' does.
closeService ∷ Service → IO ()
closeService svc = atomically (closeServiceSTM svc)

-- ---------------------------------------------------------------------------
-- Authority

registerClient ∷ Service → IO (Either Refused Client)
registerClient svc = atomically (registerClientSTM svc)

-- | End a client: its leases and views are released, and releasing the creator's
-- final owner lease closes the arena.
endClient ∷ Service → Client → IO ()
endClient svc (Client tag cid) = when (tag == serviceTag svc) (atomically (endClientSTM svc cid))

-- | Release a lease. Idempotent. The creator's final owner lease closes the
-- arena, even if attached leases remain.
releaseLease ∷ Service → ArenaLease → IO (Either Refused ())
releaseLease svc (ArenaLease tag lid)
  | tag /= serviceTag svc = pure (Left RefusedAuthority)
  | otherwise = Right <$> atomically (releaseLeaseSTM svc lid)

-- ---------------------------------------------------------------------------
-- Requests

-- | An admitted request with the box its outcome is delivered to.
data Pending a = Pending !Request !(TMVar Settlement) (Answer → Maybe a)

pendingRequest ∷ Pending a → Request
pendingRequest (Pending request _ _) = request

arrival ∷ (Answer → Maybe a) → (Endpoint → IO (Either Refused Request)) → IO (Either Refused (Pending a))
arrival project submit = do
  (endpoint, box) <- arrivalEndpoint
  fmap (\request → Pending request box project) <$> submit endpoint

openArena ∷ Service → Client → Text → SourceSpec → IO (Either Refused (Pending ArenaLease))
openArena svc client name spec = arrival (\case AOpened lease → Just lease; _ → Nothing) (\ep → openArenaWith svc ep client name spec)

attachArena ∷ Service → Client → Text → IO (Either Refused (Pending ArenaLease))
attachArena svc client name = arrival (\case AAttached lease → Just lease; _ → Nothing) (\ep → attachArenaWith svc ep client name)

cellAt ∷ Service → ArenaLease → TileCoord → IO (Either Refused (Pending CellAnswer))
cellAt svc lease tile = arrival (\case ACell a → Just a; _ → Nothing) (\ep → cellWith svc ep lease tile)

columnAt ∷ Service → ArenaLease → Column → ZRange → IO (Either Refused (Pending ColumnAnswer))
columnAt svc lease column range = arrival (\case AColumn a → Just a; _ → Nothing) (\ep → columnWith svc ep lease column range)

surfaceAt ∷ Service → ArenaLease → Column → IO (Either Refused (Pending SurfaceAnswer))
surfaceAt svc lease column = arrival (\case ASurface a → Just a; _ → Nothing) (\ep → surfaceWith svc ep lease column)

removeAt ∷ Service → ArenaLease → TileCoord → Maybe Precondition → IO (Either Refused (Pending RemoveAnswer))
removeAt svc lease tile precondition = arrival (\case ARemoved a → Just a; _ → Nothing) (\ep → removeWith svc ep lease tile precondition)

-- | What is known of a cell (a Haskell seam for later consumers; no Lua schema in this slice).
knowledgeAt ∷ Service → ArenaLease → TileCoord → IO (Either Refused (Pending KnowledgeAnswer))
knowledgeAt svc lease tile = arrival (\case AKnowledge a → Just a; _ → Nothing) (\ep → knowledgeWith svc ep lease tile)

-- | The creator's growth of the arena's allowance (a Haskell seam; the Lua schema is TRA-23).
growArena ∷ Service → ArenaLease → Integer → IO (Either Refused (Pending GrowAnswer))
growArena svc lease bytes = arrival (\case AGrown a → Just a; _ → Nothing) (\ep → growWith svc ep lease bytes)

-- | The creator's explicit retry of a paused arena (a Haskell seam; the Lua schema is TRA-23).
retryArena ∷ Service → ArenaLease → IO (Either Refused (Pending RetryAnswer))
retryArena svc lease = arrival (\case ARetried a → Just a; _ → Nothing) (\ep → retryWith svc ep lease)

-- | Whether new history of an arena is ready or paused, and why.
data StorageState = StorageReady | StoragePaused ![Condition]
  deriving stock (Eq, Show)

-- | Whether discovery of an arena has unfinished obligations, and whether it may advance.
data DiscoveryState = DiscoveryIdle | DiscoveryPending | DiscoveryPaused
  deriving stock (Eq, Show)

-- | A bounded, coherent, advisory status of an arena (requirement 9), read in one transaction
-- through any valid own lease. It enumerates no history and reserves nothing: every figure is
-- the store's own counters. Used bytes are live, retired, loose and staged pages and overhead,
-- never free preallocated capacity; pending reclaim (the retired pages) is a subset of used.
-- Pending reserved bytes are the arena's own extra reservations not yet spendable: a growth
-- prepared and not committed, and an extra whose release failed.
data ArenaStatus = ArenaStatus
  { statusStorage ∷ !StorageState
  , statusReservedBytes ∷ !Word64
  , statusUsedBytes ∷ !Word64
  , statusPendingReclaimBytes ∷ !Word64
  , statusPendingReservedBytes ∷ !Word64
  , statusDiscovery ∷ !DiscoveryState
  , statusPendingItems ∷ !Word64
  , statusContentRevision ∷ !Revision
  , statusKnowledgeRevision ∷ !Revision
  }
  deriving stock (Eq, Show)

-- | The arena's status, through any of its live leases ('RefusedAuthority' otherwise).
arenaStatus ∷ Service → ArenaLease → IO (Either Refused ArenaStatus)
arenaStatus svc lease = atomically (arenaStatusSTM svc lease)

-- | The same as a transaction, so a wait can be on the status itself.
arenaStatusSTM ∷ Service → ArenaLease → STM (Either Refused ArenaStatus)
arenaStatusSTM svc lease = do
  st <- readSt svc
  case leaseOf svc lease st of
    Left refused → pure (Left refused)
    Right (_, ls)
      | not (leaseLive ls) → pure (Left RefusedAuthority)
      | otherwise → case Map.lookup (leaseArena ls) (stateArenas st) of
          Nothing → pure (Left RefusedAuthority)
          Just arena → do
            view <- Storage.backingView (serviceStorage svc) (arenaBacking arena)
            let store = arenaStore arena
                use = usage store
                growth = growthView store
                paused = conditions store
                pending = D.pendingObligations (storeHeader store)
                backend = maybe 0 id (view >>= Storage.bvPendingReservation)
            pure . Right $
              ArenaStatus
                { statusStorage = if null paused then StorageReady else StoragePaused paused
                , statusReservedBytes = usAllowanceBytes use
                , statusUsedBytes = usUsedBytes use
                , statusPendingReclaimBytes = usRetiredBytes use
                , statusPendingReservedBytes = gvPendingBytes growth + backend
                , statusDiscovery = if pending == 0 then DiscoveryIdle else if null paused then DiscoveryPending else DiscoveryPaused
                , statusPendingItems = pending
                , statusContentRevision = D.authContent (arenaAuthority arena)
                , statusKnowledgeRevision = D.authKnowledge (arenaAuthority arena)
                }

-- | The per-arena bound of the compile account at given compiler limits: what one compiled arena
-- may keep for its life (its connectivity's result bound and #661's member index over the node bound).
perArenaBound ∷ C.ConnectivityLimits → Word64
perArenaBound = perArenaShared

-- | The compile account's size for an arena cap at given compiler limits: every other arena's bound
-- and one compilation's peak.
compileAccountFor ∷ Int → C.ConnectivityLimits → Word64
compileAccountFor = compileBankFor

-- | The compile account: what the arenas, closing files and opens hold of it, and its size
-- (read-only, for verification).
inspectCompileSTM ∷ Service → STM (Word64, Word64)
inspectCompileSTM svc = (\st -> (stateCompileUse st, serviceCompileBank svc)) <$> readSt svc

-- | The edit bank's ledgers (read-only, for verification).
inspectEditBankSTM ∷ Service → STM Ledger
inspectEditBankSTM svc = ledgers <$> readTVar (serviceEditBank svc)

-- | Wait for a request's terminal outcome and retire its result: the credits an
-- accepted result holds return when it is taken.
await ∷ Service → Pending a → IO (Either Settlement a)
await svc (Pending request box project) = do
  settlement <- atomically (readTMVar box)
  retire svc request
  pure $ case settlement of
    Succeeded answer → maybe (Left (Failed (HostFailure "answer of an unexpected kind"))) Right (project answer)
    other → Left other

cancelPending ∷ Service → Pending a → IO CancelResult
cancelPending svc (Pending request _ _) = cancel svc request

-- ---------------------------------------------------------------------------
-- Views

openView ∷ Service → Client → IO (Either Refused View)
openView svc client = atomically (openViewSTM svc client)

-- | Replace a view's latest-value demand: withdraw the old demand, admit the new
-- one best effort. The producer supplies visibility; nothing here creates a
-- window, view or GPU resource.
setViewDemand ∷ Service → View → ArenaLease → [RegionDemand] → IO (Either Refused DemandReceipt)
setViewDemand svc view lease demands = atomically (setViewDemandSTM svc view lease demands)

clearViewDemand ∷ Service → View → IO (Either Refused ())
clearViewDemand svc view = atomically (clearViewDemandSTM svc view)

closeView ∷ Service → View → IO ()
closeView svc view = atomically (closeViewSTM svc view)

-- ---------------------------------------------------------------------------
-- Snapshots

-- | Borrow an immutable snapshot of resident regions for the body. The borrow
-- is released on every exit, and while it is held the regions stay resident and
-- charged. The snapshot is coherent through later edits, eviction and the
-- arena's closure, and it grants no authority.
withSnapshot ∷ Service → ArenaLease → [RegionCoord] → (Snapshot → IO a) → IO (Either Refused a)
withSnapshot svc lease regions body =
  withResource (atomically (acquireSnapshotSTM svc lease regions)) release $ \case
    Left refused → pure (Left refused)
    Right (_, snapshot) → Right <$> body snapshot
  where
    release = \case
      Left _ → pure ()
      Right (hid, _) → atomically (releaseSnapshotSTM svc hid)

-- ---------------------------------------------------------------------------
-- Inspection

-- | Every structural rule tying the request table, leases, names, arenas and
-- holds to the accounting model; empty when coherent.
inspectInvariants ∷ Service → IO [String]
inspectInvariants svc = invariants (serviceConfig svc) <$> readTVarIO (serviceState svc)

-- | The backed state's physical truth beside what the service counts (the owner's tasks, the
-- stores' pins and transactions, the compile account, the storage service's backings and the
-- edit bank): empty when they agree. Read-only, for verification; see
-- 'Hetoimasia.Terrain.Runtime.Internal.Backed.backedInvariants'.
inspectBacked ∷ Service → IO [String]
inspectBacked svc = atomically (inspectBackedSTM svc)

-- | Whether the owner's backed work is at rest: no open, pinned read, mutating transaction or
-- closing file of the owner's, no job of the storage service, and every row of 'inspectBacked'
-- holds (so the edit bank holds only the storage service's own records). Read-only, for
-- verification: a test waits on it instead of on a figure of the bank.
-- | How many jobs wait in the storage service's queue (it takes at most eight). Read-only, for
-- verification.
inspectStorageQueuedSTM ∷ Service → STM Int
inspectStorageQueuedSTM svc = Storage.snQueued <$> Storage.snapshotOf (serviceStorage svc)

-- | Whether a caller of the storage service was refused for temporary pressure and nothing the
-- service or the edit bank holds has changed since: the owner starts no new storage work until it
-- does. Read-only, for verification.
inspectStoragePressedSTM ∷ Service → STM Bool
inspectStoragePressedSTM svc = do
  st <- readSt svc
  case stateStoragePressure st of
    Nothing → pure False
    Just mark → (== mark) <$> pressureMark svc

backedAtRestSTM ∷ Service → STM Bool
backedAtRestSTM svc = do
  st <- readSt svc
  sn <- Storage.snapshotOf (serviceStorage svc)
  problems <- inspectBackedSTM svc
  pure $
    Map.null (stateOpens st) && Map.null (stateGathers st) && isNothing (stateSlot st) && Map.null (stateClosing st)
      && null (Storage.snJobs sn)
      && null problems

inspectBackedSTM ∷ Service → STM [String]
inspectBackedSTM svc = do
  st <- readSt svc
  adm <- readTVar (serviceEditBank svc)
  sn <- Storage.snapshotOf (serviceStorage svc)
  pure (backedInvariants st adm (serviceCompileBank svc) sn)

-- | Whether the removal this request has staged would change content: @Just True@ for a staged removal that will advance the
-- arena's revision by one, @Just False@ for a staged removal of air, which commits as unchanged at the revision it finds, and
-- @Nothing@ for a request that has staged no removal (a read, an open, an attach, one not yet staged, one settled, or another
-- service's). Read-only, and a transaction so that a host's eligibility callback can use it inside the arbitration: it decides
-- before the commit whether a removal needs a revision the host cannot publish. It stages, admits and commits nothing.
stagedRemovalChanges ∷ Service → Request → STM (Maybe Bool)
stagedRemovalChanges svc (Request tag rid)
  | tag /= serviceTag svc = pure Nothing
  | otherwise = do
      st <- readSt svc
      pure $ case Map.lookup rid (stateRequests st) of
        Just req | StagedPhase sg <- reqPhase req, StagedRemoval prepared <- stagedWork sg → Just (preparedChanged prepared)
        _ → Nothing

-- | Whether the service is admitting new work: it is running (not closing or closed) and its parent session is still open. Read-only,
-- and a transaction, so that a host can ask it where a permanent refusal is decided, before it reserves anything of its own; it is
-- only a precheck. Every admission asks the same question again, atomically with its own effect, so a service that closes between
-- the host's check and the hand-off still refuses it ('RefusedClosed') and leaves nothing behind.
serviceAdmitting ∷ Service → STM Bool
serviceAdmitting svc = either (const False) (const True) <$> admitting svc

-- | The accounting model as it is now.
inspectModel ∷ Service → IO Model
inspectModel svc = atomically (inspectModelSTM svc)

-- | The same as a transaction, so a wait can be on the accounting itself.
inspectModelSTM ∷ Service → STM Model
inspectModelSTM svc = stateModel <$> readSt svc

-- | The unexpected defects recorded, newest first.
inspectDefects ∷ Service → IO [Defect]
inspectDefects svc = map defectOf . stateDefects <$> readTVarIO (serviceState svc)

-- | How many requests are waiting to be admitted again after a commit superseded their
-- revision (each stays charged until it is readmitted or ends).
inspectReadmissionWaits ∷ Service → IO Int
inspectReadmissionWaits svc = atomically (inspectReadmissionWaitsSTM svc)

-- | The same as a transaction, so a wait can be on the count itself.
inspectReadmissionWaitsSTM ∷ Service → STM Int
inspectReadmissionWaitsSTM svc = do
  st <- readSt svc
  pure (Map.size (Map.filter waitingReadmission (stateRequests st)))

-- | The accounted bytes the retained bank holds (outstanding snapshots' backing and
-- untaken removal results), and the bank.
-- | The configuration the service was built with. A pure read of the service's own immutable field: a host that composes over a service
-- asks it, rather than being told a configuration that might differ from the one the service enforces. It reads no state and changes no
-- behaviour.
inspectConfig ∷ Service → Config
inspectConfig = serviceConfig

-- | Every service-wide limit with what admission counts against it and what an
-- independent enumeration of the entities holding the resource finds. The two
-- agree and never exceed the limit (an invariant); a closed arena whose snapshot
-- is still borrowed counts against the arena limit until its retirement completes.
inspectLimits ∷ Service → IO [LimitRow]
inspectLimits svc = limitRows (serviceConfig svc) <$> readTVarIO (serviceState svc)

-- | What the service itself holds, read from its own data structures and not from the
-- accounting model: for every arena it keeps (live, and retiring while a borrowed
-- snapshot or an unfinished release keeps it) the size of its resident detail, its
-- retained changes and the regions that detail covers; every request it holds, in the
-- table or withdrawn behind a running preparation; its outstanding snapshots; and the
-- record of the work its owner is running (each load job with its reservation, scratch
-- and slot, the preparation, each handoff duplicate), written by the owner where that
-- work starts and ends.
--
-- A diagnostic for verification: read-only, it changes nothing, takes no hold, interest
-- or reservation, and no production caller or decision uses it or the record (owner
-- rulings on the issue: a read-only test inspector and a read-only record of the running
-- work are allowed). It returns plain observational data only: counts, byte figures,
-- states and inert identities, never a client, lease or arena authority, a request or
-- settlement handle, an endpoint or a snapshot. Its types are abstract: a client cannot
-- construct, forge or update one. A transaction, so it can be read in one look with the
-- model.
inspectCensusSTM ∷ Service → STM Census
inspectCensusSTM svc = do
  st <- readSt svc
  let arenaRows retiring arenas =
        [ ArenaCensus aid retiring (regionBytesOf (arenaResident a)) 0
        | (aid, a) ← Map.toList arenas
        ]
      -- What the detail itself holds in each vertical region: the fixed metadata of a
      -- region, an index entry for each column it has segments in, and each segment's
      -- metadata and payload. Segments never cross a region boundary.
      regionBytesOf resident =
        Map.map (+ R.regionMetadataBytes) . Map.fromListWith (+) $
          [ (fst (decomposeTile (TileCoord x y (segmentStart segment))), columnShare + fromIntegral (segmentMetadataBytes segment + segmentPayloadBytes segment))
          | column@(Column x y) ← residentColumns resident
          , (index, segment) ← zip [0 ∷ Int ..] (residentSegments resident column)
          , let region' = fst (decomposeTile (TileCoord x y (segmentStart segment)))
                -- An index entry once per column and region: charge it to the first
                -- segment of the column in that region.
                firstInRegion = null [() | earlier ← take index (residentSegments resident column), fst (decomposeTile (TileCoord x y (segmentStart earlier))) == region']
                columnShare = if firstInRegion then fromIntegral columnIndexBytes else 0
          ]
      requestRows ghost reqs =
        [ RequestCensus
            (Set.size (Set.fromList (map R.demandRegion (reqDemand req))))
            (case reqCmd req of CRemove {} → True; _ → False)
            (reqModel req)
            (case reqPhase req of Done → True; _ → False)
            ghost
        | req ← Map.elems reqs
        ]
  pure
    ( Census
        (arenaRows False (stateArenas st) <> arenaRows True (stateRetiring st))
        (requestRows False (stateRequests st) <> requestRows True (stateGhosts st))
        (Map.size (stateSnapshots st))
        (stateWork st)
    )

-- | The retained bank's charge as the service accounts it: the total, and the bytes charged for
-- each outstanding borrow's snapshot. Plain numbers, read-only, for verification: the charged side
-- of a comparison with the backing recorded when each snapshot was handed out.
inspectRetainedChargesSTM ∷ Service → STM (Word64, [(R.HoldId, Word64)])
inspectRetainedChargesSTM svc = do
  st <- readSt svc
  pure (retainedBankUse st, Map.toList (stateSnapshots st))

inspectSnapshotBytes ∷ Service → IO (Word64, Word64)
inspectSnapshotBytes svc = do
  st <- readTVarIO (serviceState svc)
  pure (retainedBankUse st, configRetainedBytes (serviceConfig svc))

-- | A read-only view of an arena's contents: its committed authority (content, knowledge and
-- store revisions), its residency generation, its resident detail and palette, and its store's
-- usage. No history: every removal is in the arena's store, not in RAM.
data ArenaView = ArenaView
  { viewIncarnation ∷ !ArenaId
  , viewRevision ∷ !Revision
  , viewKnowledgeRevision ∷ !Revision
  , viewStoreRevision ∷ !Revision
  , viewGeneration ∷ !Word
  , viewResident ∷ !Resident
  , viewPalette ∷ !Palette
  , viewUsage ∷ !Usage
  , -- | The conditions that pause the arena's new history.
    viewPaused ∷ ![Condition]
  }

inspectArena ∷ Service → ArenaLease → IO (Maybe ArenaView)
inspectArena svc lease = atomically (inspectArenaSTM svc lease)

-- | The same as a transaction, so a host's settlement callback can see the
-- arena as the arbitration leaves it.
inspectArenaSTM ∷ Service → ArenaLease → STM (Maybe ArenaView)
inspectArenaSTM svc lease = do
  st <- readSt svc
  pure $ case leaseOf svc lease st of
    Right (_, ls) →
      (\a → let auth = arenaAuthority a in ArenaView (leaseArena ls) (D.authContent auth) (D.authKnowledge auth) (D.authStore auth) (fromIntegral (arenaGeneration a)) (arenaResident a) (arenaPalette a) (usage (arenaStore a)) (conditions (arenaStore a)))
        <$> Map.lookup (leaseArena ls) (stateArenas st)
    Left _ → Nothing
