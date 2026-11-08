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
  , inspectModel
  , inspectModelSTM
  , inspectDefects
  , inspectSnapshotBytes
  , inspectArena
  , inspectArenaSTM
  , ArenaView (..)
  ) where

import Control.Concurrent.STM
import Control.Exception (Exception, ExceptionWithContext, SomeException, mask, rethrowIO, throwIO, try, tryWithContext)
import Control.Monad (when)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Unique (newUnique)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Resource (withResource)
import Hetoimasia.Foundation.Worker (StartOutcome (..), WorkerGroup, awaitCompletion, requestStop, startWorker)
import Hetoimasia.Terrain.Cell (Column, ZRange)
import Hetoimasia.Terrain.Changes (Changes)
import Hetoimasia.Terrain.Coordinate (RegionCoord, TileCoord)
import Hetoimasia.Terrain.Query (defaultQueryLimits)
import qualified Hetoimasia.Terrain.Residency as R
import Data.Word (Word64)
import Hetoimasia.Terrain.Residency (ArenaId, Model, RegionDemand, Revision)
import Hetoimasia.Terrain.Palette (Palette)
import Hetoimasia.Terrain.Resident (Resident)
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Owner (ownerDefinition)
import Hetoimasia.Terrain.Runtime.Internal.Snapshot
import Hetoimasia.Terrain.Runtime.Internal.Types
import Hetoimasia.Terrain.Runtime.Settlement
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
    , configSourceLimits = defaultSourceLimits
    , configQueryLimits = defaultQueryLimits
    , configFirstIdentity = 0
    , configFirstRevision = 0
    , configRetainedBytes = 16 * 1024 * 1024
    }

-- | What the service borrows. Each is narrow: the parent session's admission as
-- a transaction the service can read inside its arbitration, the supervision
-- capability that starts the owner, a logger, and a diagnostics seam.
data Ports = Ports
  { portAdmission ∷ !SessionAdmission
  , portSupervisor ∷ !Supervisor
  , portLogger ∷ !Logger
  , portProbe ∷ !Probe
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
withTerrainService config ports body =
  withResource acquire (\svc → atomically (closeServiceSTM svc)) $ \svc →
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
    acquire = do
      tag <- newUnique
      limits <- either (throwIO . ConfigError) pure (modelLimitsFor config)
      var <- newTVarIO (initialState config limits)
      pure (Service tag var config (portAdmission ports) (portLogger ports) (portProbe ports))
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
inspectInvariants svc = invariants (configRetainedBytes (serviceConfig svc)) <$> readTVarIO (serviceState svc)

-- | The accounting model as it is now.
inspectModel ∷ Service → IO Model
inspectModel svc = atomically (inspectModelSTM svc)

-- | The same as a transaction, so a wait can be on the accounting itself.
inspectModelSTM ∷ Service → STM Model
inspectModelSTM svc = stateModel <$> readSt svc

-- | The unexpected defects recorded, newest first.
inspectDefects ∷ Service → IO [Defect]
inspectDefects svc = stateDefects <$> readTVarIO (serviceState svc)

-- | The accounted bytes the retained bank holds (outstanding snapshots' backing and
-- untaken removal results), and the bank.
inspectSnapshotBytes ∷ Service → IO (Word64, Word64)
inspectSnapshotBytes svc = do
  st <- readTVarIO (serviceState svc)
  pure (retainedBankUse st, configRetainedBytes (serviceConfig svc))

-- | A read-only view of an arena's contents.
data ArenaView = ArenaView
  { viewIncarnation ∷ !ArenaId
  , viewRevision ∷ !Revision
  , viewGeneration ∷ !Word
  , viewChanges ∷ !Changes
  , viewResident ∷ !Resident
  , viewPalette ∷ !Palette
  , -- | The retained store: changes whose transfer succeeded.
    viewStore ∷ !Changes
  , -- | The regions whose changes are committed but not yet transferred.
    viewWorking ∷ ![RegionCoord]
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
      (\a → ArenaView (leaseArena ls) (arenaRevision a) (fromIntegral (arenaGeneration a)) (arenaChanges a) (arenaResident a) (arenaPalette a) (arenaStore a) (Map.keys (arenaWorking a)))
        <$> Map.lookup (leaseArena ls) (stateArenas st)
    Left _ → Nothing
