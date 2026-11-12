-- | The storage service: two I/O workers, a bounded queue, the backing files and
-- their accounting.
--
-- = State, owner, thread and lifetime
--
-- All mutable service state is one record ('St') behind one 'TVar'. Every
-- decision that races (admission of a job, its dispatch, its completion, a
-- cancellation, a close) is one transaction on it, together with the shared
-- edit-bank 'Admission' the caller injected, so there is no second slot that can
-- win independently and no credit is taken twice or released twice.
--
-- * __Callers__ (the terrain owner, tests) submit jobs and read outcomes. They
--   run no native call: a submission is a transaction that either creates the
--   job and charges it, or refuses and changes nothing.
-- * __The two workers__ are the only threads that touch a descriptor. A worker
--   takes a queued job in a transaction, runs its native calls with exceptions
--   masked (a @safe@ call is never interrupted, and an asynchronous exception
--   never lands between a native step and the bookkeeping that records it), and
--   completes it in a transaction. The wait for work is the only interruptible
--   point.
-- * __The descriptor__ belongs to its backing entry from the open job's success
--   to 'closeBacking', which closes it once. No other function closes one, and a
--   handle is an opaque number the service resolves: a stale or foreign handle
--   finds no entry and never reaches a descriptor, so a descriptor number reused
--   by a later file cannot be named by an old job.
-- * __Results__ are owned by the service until retired: a read's bytes are
--   charged to the cache until the outcome is taken or discarded, and a finished
--   job's record is charged until then.
--
-- = Jobs and their accounting
--
-- A job carries the arena and source incarnation it was made for, its work class
-- and a validated range or staged write; it is charged at submission one record
-- (the 128-byte queued descriptor of the model plus the measured table entry),
-- all or nothing. A read's transfer buffer and its result are charged when it is
-- dispatched, not when it is queued, so a full queue holds no maximum-size
-- buffers. A write retains the staged pages the transaction already accounts and
-- charges nothing for them.
--
-- = Scheduling
--
-- Explicit work is dispatched before camera prefetch; maintenance (accepted work
-- and reclamation) is served after at most 'fairMaintenance' explicit jobs and
-- camera after at most 'fairCamera' jobs of the other classes, so none starves.
-- There is at most one mutating job (a transaction's write or a growth step) in
-- the session at a time; reads proceed beside it.
module Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( -- * The service
    StorageService
  , StoragePorts (..)
  , StartFailure (..)
  , withStorageService
  , serviceSeam

    -- * Handles
  , Backing (..)
  , backingIdentity
  , Ticket
  , PreparedGrowth (..)
  , preparedFrom
  , preparedTo
  , preparedAllocated

    -- * Jobs
  , OpenSpec (..)
  , ReadMode (..)
  , WriteRefusal (..)
  , stageWrite
  , stagedPages
  , stagedTxn
  , submitOpen
  , submitRead
  , submitWrite
  , submitGrowth
  , submitAbandon
  , submitReleasePending
  , commitBackingGrowth

    -- * Outcomes
  , Outcome (..)
  , Reservation (..)
  , WriteReport (..)
  , PageResult (..)
  , writeOutcomes
  , awaitTicket
  , pollTicket
  , withOutcome
  , discardTicket
  , cancelTicket
  , CancelResult (..)

    -- * Scoped use and closing
  , withUse
  , closeBacking
  , CloseReport (..)
  , backingView
  , BackingView (..)

    -- * Inspection
  , Snapshot (..)
  , JobSnap (..)
  , JobKind (..)
  , BackingSnap (..)
  , SlotTag (..)
  , snapshotOf
  , drainWaitsMessage
  , ServiceView (..)
  , serviceView
  , jobRecordBytes
  , writeEntryBytes
  , writeFailureBytes
  , jobCharge
  , maxHostFailureChars
  , maxKept
  , keepEvidence
  , keptEntryBytes
  , Entry (..)
  , Job (..)
  , JobPhase (..)
  , Work (..)
  , ReadSpec (..)
  , GrowthSlot (..)
  , EntryPhase (..)
  , StagedWrite (..)
  , Kept (..)
  , KeptFailure (..)
  , CloseFailure (..)
  , EvidenceDropped (..)
  , SealedMutation (..)
  , ClosingRec (..)
  , transferBufferBytes
  , resultPageBytes
  , backingRecordBytes
  , fairMaintenance
  , fairCamera
  ) where

import Control.Concurrent (rtsSupportsBoundThreads)
import Control.Concurrent.STM
import Control.Exception
  ( Exception
  , ExceptionWithContext (..)
  , SomeAsyncException
  , SomeException
  , fromException
  , bracket_
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Unsafe as BSU
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Unique (Unique, newUnique)
import Data.Word (Word64)
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (castPtr, plusPtr)
import Hetoimasia.Foundation.Log (Component, Logger, logError, logInfo, logWarning, unsafeComponent)
import Hetoimasia.Foundation.Resource (allocResource, cleanupFailuresInContext, composeCleanup, displayCleanupFailure)
import Hetoimasia.Foundation.Worker
  ( StartOutcome (..)
  , StopToken
  , Worker
  , WorkerDefinition
  , WorkerGroup
  , awaitCompletion
  , awaitStopRequest
  , requestStop
  , startWorker
  , workerDefinition
  )
import Hetoimasia.Terrain.Runtime.Storage.Internal.File
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Storage.Internal.Volume
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), StoreIdentity (..), pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (TxnId, WriteOutcome (..), activePages, storeConfig, storeIdentity, Store)
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (decodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
  ( ConfigError (..)
  , StoreConfig
  , cfgAllowanceBytes
  , allowanceUnitBytes
  , cfgOffsetLimit
  , cfgOverheadBytes
  , cfgTotalPages
  , minAllowanceBytes
  , pageFileOffset
  )

-- ---------------------------------------------------------------------------
-- Constants

-- | The accounted bytes of one job record from submission to retirement: the
-- model's queued descriptor ('A.descriptorRecordBytes') plus the service's own
-- table entry for the same job, which the suite's @Memory@ example measures
-- against the live heap of the largest valid job (every work kind, every field
-- at its largest) and asserts is within this figure.
jobRecordBytes ∷ Word64
jobRecordBytes = 4096

-- | The accounted bytes of a read's transfer buffer of @n@ pages: the pages, the
-- runtime's own accounting of a large object (a descriptor for every 4 KiB block it
-- spans, measured at 1/64 of the object, charged here at 1/32) and one block of
-- slack. Measured by the suite (Memory) against the live heap of held transfers.
transferBufferBytes ∷ Int → Word64
transferBufferBytes n = fromIntegral (n * pageSize) + fromIntegral (n * pageSize) `div` 32 + 4096

-- | The accounted bytes of one page of a held read result: the 4,096 bytes the
-- caller reads and what holds them (the byte string, the pair and the list cell the
-- outcome carries). Measured by the suite against the live heap of a held result.
resultPageBytes ∷ Word64
resultPageBytes = 4864

-- | The accounted bytes of one entry of a write's report (a page number and its result, in a list), which a write
-- builds as it runs and keeps in its finished outcome until retired. Charged at ADMISSION for every staged page
-- (nothing is allocated at result time without a charge); measured by the suite (Memory) at the largest report.
writeEntryBytes ∷ Word64
writeEntryBytes = 112

-- | The accounted bytes of the one failure a write report may carry (the first failed page's record; every page
-- after it is only marked not attempted).
writeFailureBytes ∷ Word64
writeFailureBytes = 512

-- | What a job is charged to the control account from submission to retirement: the record, and for a write the
-- bounded metadata of the report it will build (one entry per staged page and at most one failure).
jobCharge ∷ Work → Word64
jobCharge w = jobRecordBytes + case w of
  WWrite sw → fromIntegral (length (swPages sw)) * writeEntryBytes + writeFailureBytes
  WOpen _ → 0
  WRead _ → 0
  WGrow _ → 0
  WRelease _ _ _ → 0

-- | The accounted bytes of one open backing's record (its entry, its growth and
-- pending-reservation slots at their largest, its place in the volume's ledger),
-- charged to the control account from the open's success to the close. Measured by
-- the suite.
backingRecordBytes ∷ Word64
backingRecordBytes = 4096

-- | Maintenance is served after at most this many explicit jobs while it waits.
fairMaintenance ∷ Int
fairMaintenance = 3

-- | Camera is served after at most this many jobs of the other classes while it
-- waits.
fairCamera ∷ Int
fairCamera = 7

component ∷ Component
component = unsafeComponent "terrain.storage"

-- ---------------------------------------------------------------------------
-- Handles

-- | An opaque authority for one backing file of one arena and source
-- incarnation. It names no descriptor; the service resolves it, and a closed or
-- foreign one is refused before any work.
data Backing = Backing !Unique !Word64 !StoreIdentity

instance Eq Backing where
  Backing u a _ == Backing v b _ = u == v && a == b

instance Show Backing where
  show (Backing _ n _) = "Backing#" <> show n

backingIdentity ∷ Backing → StoreIdentity
backingIdentity (Backing _ _ i) = i

-- | An opaque authority for one job, tied to the incarnation it was made for.
data Ticket = Ticket !Unique !Word64

instance Eq Ticket where
  Ticket u a == Ticket v b = u == v && a == b

instance Show Ticket where
  show (Ticket _ n) = "Ticket#" <> show n

-- | A growth whose extra reservation was obtained and proven but which is not
-- spendable: only the owner's 'commitBackingGrowth', after the model committed,
-- makes the capacity usable.
data PreparedGrowth = PreparedGrowth
  { pgService ∷ !Unique
  -- ^ The service that prepared it: a token of another service is refused.
  , pgAttempt ∷ !Word64
  -- ^ A fresh identity for this preparation (the job that made it): a token of an
  -- earlier, abandoned or committed preparation of the same growth is refused.
  , pgBacking ∷ !Word64
  , pgFrom ∷ !Word64
  , pgTo ∷ !Word64
  , pgAllocated ∷ !Word64
  }
  deriving stock (Eq)

instance Show PreparedGrowth where
  show p = "PreparedGrowth#" <> show (pgAttempt p) <> " backing " <> show (pgBacking p) <> " " <> show (pgFrom p) <> "->" <> show (pgTo p)

preparedFrom, preparedTo, preparedAllocated ∷ PreparedGrowth → Word64
preparedFrom = pgFrom
preparedTo = pgTo
preparedAllocated = pgAllocated

-- ---------------------------------------------------------------------------
-- Jobs

-- | What opening a backing needs: where its private file goes (an explicit
-- directory, never an implicit current one), the incarnation it serves and the
-- store configuration whose allowance it reserves.
data OpenSpec = OpenSpec
  { osDirectory ∷ !ByteString
  , osIdentity ∷ !StoreIdentity
  , osConfig ∷ !StoreConfig
  }

-- | Whether a read validates the pages it returns as pages of this store.
data ReadMode
  = -- | Decode and validate each page (checksum, format, arena, source, place).
    ReadValidated
  | -- | Return the bytes read, for an ownership probe that tolerates garbage.
    ReadProbe
  deriving stock (Eq, Show)

data ReadSpec = ReadSpec !StoreConfig !PageNo !Int !ReadMode

-- | The pages of the active transaction, as the store model holds them: a witness
-- that these pages are the staged pages of that transaction and nothing else.
data StagedWrite = StagedWrite
  { swIdentity ∷ !StoreIdentity
  , swConfig ∷ !StoreConfig
  , swTxn ∷ !TxnId
  , swPages ∷ ![(PageNo, ByteString)]
  }

stagedPages ∷ StagedWrite → [PageNo]
stagedPages = map fst . swPages

stagedTxn ∷ StagedWrite → TxnId
stagedTxn = swTxn

data WriteRefusal = NoActiveTransaction | NothingStaged | PageCount !Int
  deriving stock (Eq, Show)

-- | Witness the staged pages of a transaction. The model holds them and answers
-- only for its one active transaction, so these are never a committed page or a
-- reader's.
stageWrite ∷ Store → TxnId → Either WriteRefusal StagedWrite
stageWrite store tid = case activePages tid store of
  Nothing → Left NoActiveTransaction
  Just [] → Left NothingStaged
  Just ps
    | length ps > maxIoPages → Left (PageCount (length ps))
    | otherwise → Right (StagedWrite (storeIdentity store) (storeConfig store) tid ps)

data GrowSpec = GrowSpec !Word64 !Word64

data Work
  = WOpen !OpenSpec
  | WRead !ReadSpec
  | WWrite !StagedWrite
  | WGrow !GrowSpec
  | -- | Give back the extra reservation of [from, to): an abandoned growth or a
    -- pending release retried.
    WRelease !Word64 !Word64 !(Maybe PreparedGrowth)

-- | The class of work a job is, for scheduling and for the mutation slot.
workMutates ∷ Work → Bool
workMutates w = case w of
  WWrite _ → True
  WGrow _ → True
  WRelease _ _ _ → True
  _ → False

data JobPhase = JQueued | JRunning | JDone !Outcome

data Job = Job
  { jBacking ∷ !(Maybe Word64)
  , jIdent ∷ !StoreIdentity
  , jClass ∷ !WorkClass
  , jWork ∷ !Work
  , jPhase ∷ !JobPhase
  , jCancel ∷ !Bool
  , jControl ∷ !A.Grant
  , jDispatch ∷ !(Maybe A.Grant)
  , jBorrowed ∷ !Int
  , jDiscard ∷ !Bool
  -- ^ The holder discarded the ticket while the job ran: it is retired when it finishes.
  , jDelivered ∷ !Bool
  -- ^ A callback of 'withOutcome' returned normally with the outcome: the caller owns what it carries. A delivery
  -- has three ends: delivered (this mark), failed (the callback raised: nobody owns it) and undelivered.
  }

-- ---------------------------------------------------------------------------
-- Outcomes

-- | What a backing's reservation measured: the model charges the overhead before
-- admission, so it is reported, never discovered as uncharged growth.
data Reservation = Reservation
  { rsAllocated ∷ !Word64
  , rsLength ∷ !Word64
  , rsOverhead ∷ !Word64
  , rsFilesystem ∷ !ByteString
  , rsBlockSize ∷ !Word64
  , rsVolume ∷ !Word64
  }
  deriving stock (Eq, Show)

data PageResult
  = Wrote
  | WriteFailedAt !StorageFailure
  | NotAttempted
  deriving stock (Eq, Show)

-- | The per-page result of a write job, in the order the pages were staged. No
-- outcome publishes a root: the owner reports these to the model and decides.
data WriteReport = WriteReport
  { wrTxn ∷ !TxnId
  , wrPages ∷ ![(PageNo, PageResult)]
  }
  deriving stock (Eq, Show)

-- | The model's outcome for each page.
writeOutcomes ∷ WriteReport → [(PageNo, WriteOutcome)]
writeOutcomes r = [(p, if res == Wrote then WriteDone else WriteFailed) | (p, res) ← wrPages r]

data Outcome
  = Opened !Backing !Reservation
  | Pages ![(PageNo, ByteString)]
  | Written !WriteReport
  | GrowthPrepared !PreparedGrowth !Reservation
  | -- | The requested allowance is the committed one: an idempotent no-op that
    -- reserved nothing and changed nothing.
    GrowthNoChange
  | Released
  | -- | A failure, with the cleanup that also failed beside it.
    Failed !StorageFailure ![CleanupNote]
  | -- | The job ended at a safe point after a cancellation request.
    Cancelled ![CleanupNote]
  deriving stock (Eq)

instance Show Outcome where
  show o = case o of
    Opened b r → "Opened " <> show b <> " " <> show r
    Pages ps → "Pages " <> show (map fst ps)
    Written w → "Written " <> show w
    GrowthPrepared p r → "GrowthPrepared " <> show p <> " " <> show r
    GrowthNoChange → "GrowthNoChange"
    Released → "Released"
    Failed f n → "Failed " <> show f <> " " <> show n
    Cancelled n → "Cancelled " <> show n

-- ---------------------------------------------------------------------------
-- The service

-- | The service's phase. 'Sealed' is the end: the drain has completed (every worker joined, every backing closed, every
-- closing record ended, every record disposed of, the evidence composed), so nothing may commit state or a charge to
-- it any more: a mutator that could is refused or finds nothing, and the one that cannot be refused ('keepEvidence')
-- is a defect.
data Phase = Running | Closing | Stopped | Sealed
  deriving stock (Eq, Show)

-- | The growth state of a backing. Every event is one transaction on it:
--
-- +----------------------------+------------------------------------------------------------+
-- | state                      | events                                                     |
-- +============================+============================================================+
-- | 'GIdle'                    | submit growth: 'GRunning' (admission); submit release of a |
-- |                            | pending reservation: 'GReleasing' 'Nothing'; commit and   |
-- |                            | abandon: refused                                           |
-- | 'GRunning'                 | prepare publishes (cancellation arbitrated in the same     |
-- |                            | step): 'GPrepared', or the extra is released and 'GIdle'   |
-- |                            | (a failed release leaves a charged pending record);        |
-- |                            | commit, abandon, a second growth: refused                  |
-- | 'GPrepared' p              | commit p (the token must be this service's and this        |
-- |                            | attempt's): 'GIdle' and the cap rises; abandon p:          |
-- |                            | 'GReleasing' (commit authority revoked in the same step);  |
-- |                            | a second growth: refused; close: released with the file    |
-- | 'GReleasing'               | the release finishes: 'GIdle' (or 'GIdle' with the extra  |
-- |                            | pending when the release failed); commit, a second         |
-- |                            | release, a growth: refused                                 |
-- +----------------------------+------------------------------------------------------------+
data GrowthSlot = GIdle | GRunning | GPrepared !PreparedGrowth | GReleasing !(Maybe PreparedGrowth)

data EntryPhase = EOpen | EClosing
  deriving stock (Eq)

data Entry = Entry
  { eFd ∷ !Fd
  , eIdent ∷ !StoreIdentity
  , eVolume ∷ !Word64
  , eCap ∷ !Word64
  , eLength ∷ !Word64
  , eOverheadModel ∷ !Word64
  , eGrowth ∷ !GrowthSlot
  , ePending ∷ !(Maybe Word64)
  , ePhase ∷ !EntryPhase
  , eBorrows ∷ !Int
  , eOffsetLimit ∷ !Word64
  , eGrant ∷ !A.Grant
  -- ^ The control charge of this record, released at the close.
  }

data Fair = Fair {fMaint ∷ !Int, fCamera ∷ !Int}

data St = St
  { stPhase ∷ !Phase
  , stNextJob ∷ !Word64
  , stNextBacking ∷ !Word64
  , stJobs ∷ !(Map Word64 Job)
  , stQueue ∷ !(Map WorkClass (Seq Word64))
  , stBackings ∷ !(Map Word64 Entry)
  , stMutation ∷ !(Maybe Word64)
  , stRunning ∷ !Int
  , stFair ∷ !Fair
  , stBusyVolumes ∷ !(Set Word64)
  , stReserved ∷ !(Map Word64 Word64)
  , stDefect ∷ !(Maybe Text)
  , stClosingRecs ∷ !(Map Word64 ClosingRec)
  -- ^ THE CLOSING RECORD. A backing claimed for close MOVES here whole (its grant, its volume contribution, its
  -- descriptor) and nothing it pays for is released until its native close has returned; ONE transaction then
  -- subtracts the reservation (the space is free) and KEEPS a failing close as evidence, and the record stays,
  -- 'CrReporting', CARRYING THE GRANT, until the close has nothing left to do with the service (its diagnostics are
  -- done); another transaction releases the grant and deletes it. The drain joins the records, so the service cannot end, and its logger cannot be used after its scope, while a
  -- close is in its diagnostics, and nothing is ever added to a drained service.
  , stEvidence ∷ ![Kept]
  -- ^ Cleanup failures that nobody received (an outcome disposed of undelivered, a close nobody waited for), kept
  -- (at most 'maxKept') for the scope that ends the service.
  , stEvidenceDropped ∷ !Int
  -- ^ How many were dropped because the evidence was full: counted, and reported at the end, never silent.
  , stWorkers ∷ !Int
  -- ^ Workers alive (started and not yet ended): admission is open only while both are.
  , stStopReason ∷ !(Maybe Text)
  -- ^ Why the service was stopped by something other than its own drain (the first reason wins).
  }

-- | A backing being closed: still holding everything (the native close has not returned) or reporting (it has: the
-- file is gone and the volume's figure is reduced, the diagnostics are pending). BOTH are charged for as long as they
-- live: a reporting record keeps the control grant of the backing it was (its measured size is under that charge),
-- released by the transaction that deletes it, so the number of records a held logger can accumulate is bounded by the
-- control account like every other record.
data ClosingRec = CrNative !Entry | CrReporting !A.Grant

-- | A failure of a cleanup nobody received, with what it was.
-- | What the service keeps of a failure nobody received, with its identity: a cleanup note, or the failure of a backing's
-- close, typed with the backing's id and the errno or the (bounded) text of the exception the close raised.
data KeptFailure = KeptNote !CleanupNote | KeptClose !Word64 !CloseFailure

-- | How a close failed, fully evaluated when kept (a lazy value would retain what it was made from).
data CloseFailure = CloseErrno !Errno | CloseRaised !Text

data Kept = Kept !Text !KeptFailure !A.Grant

-- | The accounted bytes of one kept failure (its label, its note, its place in the list and its grant), charged to
-- the control account from the moment it is kept until the service's end. Measured by the suite (Memory).
keptEntryBytes ∷ Word64
keptEntryBytes = 2048

-- | A mutator reached a sealed (drained) service: nothing may commit to it any more, and the one that cannot be
-- refused is a defect.
newtype SealedMutation = SealedMutation Text
  deriving stock (Show)

instance Exception SealedMutation

-- | The most failures the service keeps for its end.
maxKept ∷ Int
maxKept = 64

-- | The failures dropped for want of room at the end of the service.
newtype EvidenceDropped = EvidenceDropped Int
  deriving stock (Show)

instance Exception EvidenceDropped

-- | The service.
data StorageService = StorageService
  { svId ∷ !Unique
  , svSeam ∷ !Seam
  , svConfig ∷ !StorageConfig
  , svState ∷ !(TVar St)
  , svAdmission ∷ !(TVar A.Admission)
  , svLogger ∷ !Logger
  , svNames ∷ !(TVar Word64)
  }

serviceSeam ∷ StorageService → Seam
serviceSeam = svSeam

-- | What the service borrows: the shared edit-bank admission (a variable the
-- terrain owner also reserves its transactions' credits from), the worker group
-- that owns the two workers' lifetime, a logger and the native seam.
data StoragePorts = StoragePorts
  { portAdmission ∷ !(TVar A.Admission)
  , portGroup ∷ !WorkerGroup
  , portLogger ∷ !Logger
  , portSeam ∷ !Seam
  , portConfig ∷ !StorageConfig
  }

data StartFailure
  = NotThreaded
  | WorkerNotStarted !Text
  deriving stock (Show)

instance Exception StartFailure

-- | A cleanup step of the service's own close that failed: kept beside the
-- primary failure (or as the failure, when there was none), never replaced by
-- it and never retried.
data StorageCleanupFailure
  = -- | The one close of a backing's descriptor failed.
    BackingCloseFailed !Text !Errno
  | -- | The one close raised an exception.
    BackingCloseRaised !Text !Text
  deriving stock (Show)

instance Exception StorageCleanupFailure

emptySt ∷ St
emptySt = St Running 1 1 Map.empty Map.empty Map.empty Nothing 0 (Fair 0 0) Set.empty Map.empty Nothing Map.empty [] 0 0 Nothing

-- | Run a body with the service. The two workers are started in the group the
-- caller owns; the body runs; then, in the protected boundary and whatever ended
-- the body, admission is closed, queued jobs are withdrawn, every backing is
-- closed (waiting for running calls and borrowers, with no deadline) and both
-- workers are stopped and joined. A cancellation delivered while it drains is
-- remembered and delivered after the drain.
withStorageService ∷ StoragePorts → (StorageService → IO a) → IO a
withStorageService ports body = do
  unless rtsSupportsBoundThreads (throwIO NotThreaded)
  sid ← newUnique
  st ← newTVarIO emptySt
  names ← newTVarIO 0
  let svc = StorageService sid (portSeam ports) (portConfig ports) st (portAdmission ports) (portLogger ports) names
  mask $ \restore → do
    workers ← startWorkers svc (portGroup ports)
    -- the body is the caller's: the service commits nothing inside this unmasked region (every service transaction
    -- is made by a service function the body calls, each complete in itself); everything after it is masked
    outcome ← tryWithContext (restore (body svc))
    (late, caught) ← drainService svc workers
    let primary = case outcome of
          Left e → Just e
          Right _ → late
    final ← composeCleanup primary caught
    case (final, outcome) of
      (Just e, _) → rethrowIO e
      (Nothing, Right r) → pure r
      (Nothing, Left e) → rethrowIO e

-- | Start the two workers, each acknowledged before the next. A worker that
-- cannot start stops the ones already started before the failure propagates.
startWorkers ∷ StorageService → WorkerGroup → IO [Worker ()]
startWorkers svc group = do
  started ← newIORef []
  r ← tryWithContext (go started (2 ∷ Int)) ∷ IO (Either (ExceptionWithContext SomeException) [Worker ()])
  case r of
    Right ws → pure ws
    Left ewc → do
      -- every exit of the start sequence, a typed failure, an exception or a cancellation (the cancellation of the
      -- abort's own join included), stops and joins every worker that was started, in the protected wait the drain
      -- uses: no worker is left without an owner, and the primary failure is the one that propagates
      ws ← readIORef started
      _ ← protectedly (atomically (modifyTVar' (svState svc) (\s → s {stPhase = Stopped}) >> mapM_ requestStop ws))
      _ ← protectedly (atomically (mapM_ awaitCompletion ws))
      rethrowIO ewc
  where
    go started 0 = reverse <$> readIORef started
    go started n = do
      r ← startWorker group (workerDef svc n)
      case r of
        Started w → modifyIORef' started (w :) >> go started (n - 1)
        StartupFailed _ _ → throwIO (WorkerNotStarted "storage worker startup failed")
        StartRejected _ → throwIO (WorkerNotStarted "storage worker group is closed")

workerDef ∷ StorageService → Int → WorkerDefinition ()
workerDef svc n =
  workerDefinition
    (T.pack ("terrain-storage-io-" <> show n))
    (\_ → allocResource (seamBefore (svSeam svc) (OpWorkerStart n) >> atomically (modifyTVar' (svState svc) (\s → s {stWorkers = stWorkers s + 1}))) (\_ → atomically (modifyTVar' (svState svc) (\s → s {stWorkers = stWorkers s - 1})) >> seamBefore (svSeam svc) (OpWorkerStop n)))
    (\token () → workerLoop svc token)

-- | Close admission, withdraw what is queued, close every backing and stop the
-- workers. Returns a cancellation that arrived during the drain, to deliver after
-- it.
drainService ∷ StorageService → [Worker ()] → IO (Maybe (ExceptionWithContext SomeException), [(Text, ExceptionWithContext SomeException)])
drainService svc workers = do
  (late0, _) ← protectedly (atomically (closeAdmission svc))
  -- the workers first: a running job (an open included) finishes, so every backing is registered and no call is in flight
  (late1, _) ← protectedly (atomically (mapM_ requestStop workers))
  (late2, _) ← protectedly (atomically (mapM_ awaitCompletion workers))
  entries ← atomically (Map.keys . stBackings <$> readTVar (svState svc))
  closed ← forM entries $ \bid → closeBackingCore svc bid
  -- a close another caller claimed is still tracked until its native call has returned: the drain joins it, and
  -- says so before it waits (the one observation of the wait that needs no timing)
  inFlight ← atomically (Map.size . stClosingRecs <$> readTVar (svState svc))
  late5 ← if inFlight > 0
    then quietly (logInfo (svLogger svc) component drainWaitsMessage [("closing", T.pack (show inFlight))])
    else pure Nothing
  (late4, _) ← protectedly (atomically (readTVar (svState svc) >>= \s → check (Map.null (stClosingRecs s))))
  -- every record still in the table (an outcome nobody took, an opened backing nobody named) is disposed of once its
  -- borrowers have finished, and the cleanup failures such outcomes carry are kept as evidence
  (late3, _) ← protectedly . atomically $ do
    s ← readTVar (svState svc)
    check (null [() | j ← Map.elems (stJobs s), jBorrowed j > 0])
    forM_ (Map.keys (stJobs s)) (disposeUndelivered svc)
  -- THE SEAL: one transaction, after every closing record has ended, reads the kept failures, releases what they were
  -- charged, clears them and seals the service. After it nothing can commit to the service ('keepEvidence' is a
  -- defect on a sealed one), so nothing is added after the evidence was read.
  (late6, sealed) ← protectedly . atomically $ do
    s ← readTVar (svState svc)
    check (Map.null (stClosingRecs s))
    forM_ (stEvidence s) (\(Kept _ _ g) → releaseGrant svc g)
    modifyTVar' (svState svc) (\t → t {stEvidence = [], stPhase = Sealed})
    pure (stEvidence s, stEvidenceDropped s)
  let (undelivered, dropped) = fromMaybe ([], 0) sealed
  evidence ← sequence ([(,) label <$> keptEvidenceOf k | Kept label k _ ← undelivered]
    <> [(,) "evidence dropped for want of room" <$> evidenceOf (EvidenceDropped dropped) | dropped > 0])
  pure (firstLate ([late0, late1, late2, late3, late4, late5, late6] <> map fst closed), evidence)

-- | The message the drain logs when it waits for closes another caller claimed.
drainWaitsMessage ∷ Text
drainWaitsMessage = "Drain waits for closes in flight"

-- | A diagnostic is never an exit. A logger that raises synchronously is the logger's defect and is dropped. An
-- asynchronous exception (a cancellation delivered at an interruptible point inside a sink that blocks, which every
-- masked caller of this reaches) is NOT rethrown here: that would leave the caller between a state change and the
-- bookkeeping that completes it. It is returned instead, the log entry dropped and not retried, and the caller
-- remembers it and delivers it once its own bookkeeping is done (first one wins, as 'protectedly' does).
quietly ∷ IO () → IO (Maybe (ExceptionWithContext SomeException))
quietly act = do
  r ← tryWithContext act ∷ IO (Either (ExceptionWithContext SomeException) ())
  pure $ case r of
    Right () → Nothing
    Left ewc@(ExceptionWithContext _ e) → case fromException e ∷ Maybe SomeAsyncException of
      Just _ → Just ewc
      Nothing → Nothing

-- | The first remembered exception of several.
firstLate ∷ [Maybe (ExceptionWithContext SomeException)] → Maybe (ExceptionWithContext SomeException)
firstLate xs = case [e | Just e ← xs] of
  (e : _) → Just e
  [] → Nothing

-- | The evidence a kept failure becomes at the end of the service, with its own exception type: a close that failed is
-- 'BackingCloseFailed' (the backing and the errno), one that raised is 'BackingCloseRaised' (the backing and the text).
keptEvidenceOf ∷ KeptFailure → IO (ExceptionWithContext SomeException)
keptEvidenceOf k = case k of
  KeptNote (CleanupNote op e) → evidenceOf (OpenCleanupFailed op e)
  KeptClose bid (CloseErrno en) → evidenceOf (BackingCloseFailed (T.pack (show bid)) en)
  KeptClose bid (CloseRaised t) → evidenceOf (BackingCloseRaised (T.pack (show bid)) t)

-- | An exception with the context a throw would give it, for cleanup evidence.
evidenceOf ∷ Exception e ⇒ e → IO (ExceptionWithContext SomeException)
evidenceOf e = do
  r ← tryWithContext (throwIO e)
  case r of
    Left ewc → pure ewc
    Right () → error "storage: a throw returned"

-- | Run an action that must finish, remembering (not obeying) any exception that
-- is delivered while it waits, and delivering it afterwards.
protectedly ∷ IO a → IO (Maybe (ExceptionWithContext SomeException), Maybe a)
protectedly act = loop Nothing
  where
    loop remembered = do
      r ← tryWithContext act
      case r of
        Right x → pure (remembered, Just x)
        Left ewc@(ExceptionWithContext _ e) → case fromException e ∷ Maybe SomeAsyncException of
          Just _ → loop (Just (fromMaybe ewc remembered))
          Nothing → rethrowIO ewc

-- | Stop accepting work and withdraw every queued job (each settles as
-- cancelled, its record released).
closeAdmission ∷ StorageService → STM ()
closeAdmission svc = do
  -- a sealed service stays sealed: nothing may change it
  modifyTVar' (svState svc) (\s → s {stPhase = if stPhase s == Sealed then Sealed else Closing})
  withdrawWhere svc (const True)

-- | Complete the queued jobs a predicate names as cancelled, and discard them:
-- nothing is running for them, so nothing is in use.
withdrawWhere ∷ StorageService → (Job → Bool) → STM ()
withdrawWhere svc p = do
  s ← readTVar (svState svc)
  forM_ [jid | (jid, j) ← Map.toList (stJobs s), isQueued (jPhase j), p j] (\jid → withdrawQueued svc jid True)
  -- running jobs of the predicate stop at their next safe point
  forM_ [jid | (jid, j) ← Map.toList (stJobs s), isRunning (jPhase j), p j] $ \jid →
    modifyTVar' (svState svc) (\t → t {stJobs = Map.adjust (\j → j {jCancel = True}) jid (stJobs t)})
  where
    isQueued JQueued = True
    isQueued _ = False
    isRunning JRunning = True
    isRunning _ = False

-- | THE ONE WAY A QUEUED JOB LEAVES (a cancellation, a discard, the closing of admission, the close of its
-- backing): it comes out of the queue, what its admission installed is reversed in the same transaction, and it
-- settles as cancelled (and is retired when nobody will take the outcome).
withdrawQueued ∷ StorageService → Word64 → Bool → STM ()
withdrawQueued svc jid retire = do
  s ← readTVar (svState svc)
  forM_ (Map.lookup jid (stJobs s)) $ \j → do
    dequeue svc jid
    undoAdmission svc j
    void (finishJob svc jid (Cancelled []))
    when retire (void (disposeUndelivered svc jid))

-- | What the admission of a kind of work installed, reversed: a growth's slot returns to idle, an
-- abandonment's to prepared with its token valid again, a release of a pending reservation's to idle (the
-- reservation stays pending, recoverable). Only a slot still in the state the admission left is moved.
undoAdmission ∷ StorageService → Job → STM ()
undoAdmission svc j = forM_ (jBacking j) $ \bid → case jWork j of
  WGrow (GrowSpec f t) | f /= t → onSlot bid (\sl → case sl of GRunning → Just GIdle; _ → Nothing)
  WGrow _ → pure ()
  WRelease _ _ (Just p) → onSlot bid (\sl → case sl of GReleasing (Just q) | q == p → Just (GPrepared p); _ → Nothing)
  WRelease _ _ Nothing → onSlot bid (\sl → case sl of GReleasing Nothing → Just GIdle; _ → Nothing)
  WOpen _ → pure ()
  WRead _ → pure ()
  WWrite _ → pure ()
  where
    onSlot bid f = do
      s ← readTVar (svState svc)
      forM_ (Map.lookup bid (stBackings s)) $ \e → forM_ (f (eGrowth e)) (setSlot svc bid)

-- | THE ONE DISPOSAL OF AN OUTCOME NOBODY TOOK (a discard, the close of its backing, the end of the service): the
-- record is retired and what each kind of outcome still owns is settled. Every constructor is handled here, none
-- by a wildcard. The result is the backing an undelivered 'Opened' left that nobody can name (for the caller to
-- close; the native close is not an STM action).
disposeUndelivered ∷ StorageService → Word64 → STM (Maybe Word64)
disposeUndelivered svc jid = do
  s ← readTVar (svState svc)
  case Map.lookup jid (stJobs s) of
    Just j | JDone o ← jPhase j, jBorrowed j == 0 → do
      retireJob svc jid
      case o of
        Opened (Backing _ bid _) _ → pure (Just bid)
        GrowthPrepared p _ → do
          -- the token that could commit or abandon it was never delivered: the preparation becomes an explicit
          -- pending reservation (length and extra unchanged in the volume's figure), recoverable by a release
          forM_ (Map.lookup (pgBacking p) (stBackings s)) $ \e → case eGrowth e of
            GPrepared q | q == p → setEntry (pgBacking p) (\x → x {eGrowth = GIdle, ePending = Just (pgTo p - pgFrom p), eLength = pgFrom p})
            GIdle → pure ()
            GRunning → pure ()
            GPrepared _ → pure ()
            GReleasing _ → pure ()
          pure Nothing
        Failed _ notes → keepEvidence svc "undelivered outcome cleanup" (map KeptNote notes) >> pure Nothing
        Cancelled notes → keepEvidence svc "undelivered outcome cleanup" (map KeptNote notes) >> pure Nothing
        Pages _ → pure Nothing
        Written _ → pure Nothing
        GrowthNoChange → pure Nothing
        Released → pure Nothing
    _ → pure Nothing
  where
    setEntry bid f = modifyTVar' (svState svc) (\t → t {stBackings = Map.adjust f bid (stBackings t)})

-- | THE ONE KEEPER OF A FAILURE NOBODY RECEIVED: the failure goes into the service's evidence, which ends the
-- service's scope as labelled cleanup failures. At most 'maxKept' are kept; one that does not fit is COUNTED, and
-- the count is reported at the end (never dropped silently).
keepEvidence ∷ StorageService → Text → [KeptFailure] → STM ()
keepEvidence svc label notes = do
  sealed ← (== Sealed) . stPhase <$> readTVar (svState svc)
  when sealed (throwSTM (SealedMutation "keepEvidence"))
  mapM_ keepOne notes
  where
    -- every kept failure is CHARGED ('keptEntryBytes', control) while it is kept; one that does not fit, or whose
    -- charge is refused, is counted
    keepOne n = do
      s ← readTVar (svState svc)
      if length (stEvidence s) >= maxKept then dropOne else do
        charged ← withAdmission svc (\a → A.reserve A.Foreground [A.ControlCredit keptEntryBytes] a)
        case charged of
          Left _ → dropOne
          -- evaluated when kept (a lazy entry would hold what it was made from, not what it is)
          Right g → let k = Kept label n g in k `seq` modifyTVar' (svState svc) (\t → t {stEvidence = stEvidence t <> [k]})
    dropOne = modifyTVar' (svState svc) (\t → t {stEvidenceDropped = stEvidenceDropped t + 1})

-- | THE ONE STOP of the service for every way a worker can end other than the cooperative stop its token carries
-- (a defect, a cancellation delivered at any point of its loop, a remembered cancellation delivered after a job):
-- admission closes, queued work settles as cancelled, running work is asked to stop, and the reason is recorded
-- (the first one wins). A worker that is gone while admission is open would accept tickets nobody runs.
stopService ∷ StorageService → Text → STM ()
stopService svc why0 = do
  -- a copy, evaluated: a lazy slice would retain the exception text it was cut from
  let why = T.copy why0
  why `seq` modifyTVar' (svState svc) (\s → s {stStopReason = case stStopReason s of Nothing → Just why; r → r})
  closeAdmission svc

dequeue ∷ StorageService → Word64 → STM ()
dequeue svc jid = modifyTVar' (svState svc) (\s → s {stQueue = Map.map (Seq.filter (/= jid)) (stQueue s)})

-- ---------------------------------------------------------------------------
-- Accounting

-- | Run a pure admission step against the shared variable.
withAdmission ∷ StorageService → (A.Admission → Either r (a, A.Admission)) → STM (Either r a)
withAdmission svc f = do
  a ← readTVar (svAdmission svc)
  case f a of
    Left r → pure (Left r)
    Right (x, a') → writeTVar (svAdmission svc) a' >> pure (Right x)

-- | Release a grant's staging and control charges and its cache entries (a read's
-- result copy), unpinned and dropped.
releaseGrant ∷ StorageService → A.Grant → STM ()
releaseGrant svc g = do
  modifyTVar' (svAdmission svc) $ \a →
    let a1 = A.release g a
        a2 = foldr A.unpinEntry a1 (A.grantEntries g)
     in foldr (\e acc → either (const acc) id (A.dropEntry e acc)) a2 (A.grantEntries g)

-- | Release only the transfer's staging (the cache entries stay, pinned, as the
-- result's charge).
releaseStaging ∷ StorageService → A.Grant → STM ()
releaseStaging svc g = modifyTVar' (svAdmission svc) (A.release g)

-- ---------------------------------------------------------------------------
-- Submission

mapRefusal ∷ A.Refusal → StorageFailure
mapRefusal r = case r of
  A.RefusedBusy w → BusyNow (AccountPressure w)
  A.RefusedInvalid c → InvalidRequest (CreditInvalid c)

-- | The common admission of a job, all or nothing: the phase, the backing it
-- names, the record count, the queue, the mutation slot and the record's charge
-- are checked in this one transaction and nothing changes on a refusal.
admitJob ∷ StorageService → Maybe Backing → StoreIdentity → WorkClass → Work → STM (Either StorageFailure Ticket)
admitJob svc mb ident cls work = do
  s ← readTVar (svState svc)
  let queued = sum (map Seq.length (Map.elems (stQueue s)))
      checks = do
        when (stPhase s /= Running) (Left ServiceStopped)
        _ ← case mb of
          Nothing → Right ()
          Just (Backing u bid bident)
            | u /= svId svc → Left ForeignHandle
            | otherwise → case Map.lookup bid (stBackings s) of
                Nothing → Left BackingClosed
                Just e
                  | ePhase e /= EOpen → Left BackingClosed
                  | eIdent e /= bident || bident /= ident → Left (InvalidRequest IdentityMismatch)
                  | otherwise → Right ()
        when (Map.size (stJobs s) >= maxJobRecords) (Left (BusyNow RecordsFull))
        when (queued >= maxQueuedJobs) (Left (BusyNow QueueFull))
        when (workMutates work && isJust (stMutation s)) (Left (BusyNow MutationActive))
  case checks of
    Left f → pure (Left f)
    Right () → do
      charged ← withAdmission svc (\a → A.reserve A.Foreground [A.ControlCredit (jobCharge work)] a)
      case charged of
        Left r → pure (Left (mapRefusal r))
        Right grant → do
          let jid = stNextJob s
              job = Job (fmap (\(Backing _ bid _) → bid) mb) ident cls work JQueued False grant Nothing 0 False False
          writeTVar (svState svc) s
            { stNextJob = jid + 1
            , stJobs = Map.insert jid job (stJobs s)
            , stQueue = Map.insertWith (flip (<>)) cls (Seq.singleton jid) (stQueue s)
            , stMutation = if workMutates work then Just jid else stMutation s
            }
          pure (Right (Ticket (svId svc) jid))

submitOpen ∷ StorageService → WorkClass → OpenSpec → IO (Either StorageFailure Ticket)
submitOpen svc cls spec
  | BS.null dir || BS.length dir > maxDirectoryBytes || BS.elem 0 dir = pure (Left (InvalidRequest DirectoryInvalid))
  | otherwise = atomically (admitJob svc Nothing (osIdentity spec) cls (WOpen spec))
  where
    dir = osDirectory spec

-- | Queue a read of @count@ contiguous pages (1 to 256) from @start@. The range
-- is validated against the request's configuration before anything is queued.
submitRead ∷ StorageService → Backing → WorkClass → StoreConfig → PageNo → Int → ReadMode → IO (Either StorageFailure Ticket)
submitRead svc b cls cfg start@(PageNo n) count mode
  | count < 1 = pure (Left (InvalidRequest EmptyRequest))
  | count > maxIoPages = pure (Left (InvalidRequest (TooManyPages count)))
  | Left e ← pageFileOffset cfg start = pure (Left (InvalidRequest (PageOutsideFile start e)))
  | Left e ← pageFileOffset cfg lastPage = pure (Left (InvalidRequest (PageOutsideFile lastPage e)))
  | otherwise = atomically $ do
      refused ← capRefusal svc b cfg
      case refused of
        Just f → pure (Left f)
        Nothing → admitJob svc (Just b) (backingIdentity b) cls (WRead (ReadSpec cfg start count mode))
  where
    lastPage = PageNo (n + fromIntegral count - 1)

-- | Queue a transaction's staged pages. Writes are explicit work.
submitWrite ∷ StorageService → Backing → StagedWrite → IO (Either StorageFailure Ticket)
submitWrite svc b w
  | swIdentity w /= backingIdentity b = pure (Left (InvalidRequest IdentityMismatch))
  | length (swPages w) > maxIoPages = pure (Left (InvalidRequest (TooManyPages (length (swPages w)))))
  | otherwise = case firstBad of
      Just f → pure (Left f)
      Nothing → atomically $ do
        refused ← capRefusal svc b (swConfig w)
        grown ← growthBlocks svc b
        case (refused, grown) of
          (Just f, _) → pure (Left f)
          (_, Just f) → pure (Left f)
          _ → admitJob svc (Just b) (backingIdentity b) ExplicitWork (WWrite w)
  where
    firstBad = foldr pick Nothing (checkPages (swConfig w) (swPages w))
    pick x acc = maybe acc Just x

-- | The page-level validation of a write, before any I/O: every page is exactly
-- one page long, inside the file, and named once.
checkPages ∷ StoreConfig → [(PageNo, ByteString)] → [Maybe StorageFailure]
checkPages cfg ps = go Set.empty ps
  where
    go _ [] = []
    go seen ((p, bytes) : rest) =
      let bad
            | BS.length bytes /= pageSize = Just (InvalidRequest (PageWrongSize p (BS.length bytes)))
            | Left e ← pageFileOffset cfg p = Just (InvalidRequest (PageOutsideFile p e))
            | p `Set.member` seen = Just (InvalidRequest (DuplicatePage p))
            | otherwise = Nothing
       in bad : go (Set.insert p seen) rest

-- | A request may not name an allowance the backing has not reserved and
-- committed: a prepared growth is not capacity.
capRefusal ∷ StorageService → Backing → StoreConfig → STM (Maybe StorageFailure)
capRefusal svc (Backing u bid _) cfg
  | u /= svId svc = pure (Just ForeignHandle)
  | otherwise = do
      s ← readTVar (svState svc)
      pure $ case Map.lookup bid (stBackings s) of
        Nothing → Just BackingClosed
        Just e
          | cfgAllowanceBytes cfg > eCap e → Just (InvalidRequest (BeyondCommittedCap (cfgAllowanceBytes cfg) (eCap e)))
          | otherwise → Nothing

growthBlocks ∷ StorageService → Backing → STM (Maybe StorageFailure)
growthBlocks svc (Backing _ bid _) = do
  s ← readTVar (svState svc)
  pure $ case Map.lookup bid (stBackings s) of
    Just e | GIdle ← eGrowth e → Nothing
    Just _ → Just (BusyNow GrowthActive)
    Nothing → Nothing

-- | Queue the execution of a growth to a larger allowance. The size rules were
-- decided by the model (@proposeGrowth@); the backend re-checks what it owns: the
-- base is the committed allowance, the target is larger, no growth is prepared and
-- no earlier extra reservation is still unreleased.
submitGrowth ∷ StorageService → Backing → Word64 → Word64 → IO (Either StorageFailure Ticket)
submitGrowth svc b from to
  | to < from = pure (Left (InvalidRequest (GrowthNotIncreasing from to)))
  | otherwise = atomically $ do
      s ← readTVar (svState svc)
      let Backing u bid _ = b
      case Map.lookup bid (stBackings s) of
        _ | u /= svId svc → pure (Left ForeignHandle)
        Nothing → pure (Left BackingClosed)
        Just e
          | from /= eCap e → pure (Left (InvalidRequest (GrowthStaleBase from (eCap e))))
          | Just bad ← growthSizeError e to → pure (Left (InvalidRequest bad))
          -- an equal size is an idempotent no-op: it needs no reservation, so nothing blocks it
          | from == to → admitJob svc (Just b) (backingIdentity b) MaintenanceWork (WGrow (GrowSpec from to))
          | Just p ← ePending e → pure (Left (ReservationFailed (PendingReservationBlocks p)))
          | GIdle ← eGrowth e → do
              t ← admitJob svc (Just b) (backingIdentity b) MaintenanceWork (WGrow (GrowSpec from to))
              -- the slot moves in the transaction that admits the job, never after it
              when (either (const False) (const True) t) (setSlot svc bid GRunning)
              pure t
          | otherwise → pure (Left (BusyNow GrowthActive))

-- | The size rules at this boundary, the model's own (@proposeGrowth@) re-applied to the number
-- this backend is about to reserve: the minimum, the 1 MiB grid and the native offset limit.
growthSizeError ∷ Entry → Word64 → Maybe InvalidWhy
growthSizeError e to
  | to < minAllowanceBytes = Just (AllowanceInvalid (AllowanceBelowMinimum (toInteger to)))
  | to `mod` allowanceUnitBytes /= 0 = Just (AllowanceInvalid (AllowanceNotAligned (toInteger to)))
  | to > eOffsetLimit e = Just (AllowanceInvalid (AllowanceBeyondOffsetLimit (toInteger to) (toInteger (eOffsetLimit e))))
  | otherwise = Nothing

-- | What a backing holds of its volume: the length of its file and any extra reservation still pending. The
-- volume's reserved figure is the sum of these over its backings, and a close gives back exactly this.
backingContribution ∷ Entry → Word64
backingContribution e = eLength e + fromMaybe 0 (ePending e)

setSlot ∷ StorageService → Word64 → GrowthSlot → STM ()
setSlot svc bid slot = modifyTVar' (svState svc) (\s → s {stBackings = Map.adjust (\x → x {eGrowth = slot}) bid (stBackings s)})

-- | Queue the release of a prepared growth that will not be committed. Accepting it revokes the
-- commit authority in the same transaction.
submitAbandon ∷ StorageService → Backing → PreparedGrowth → IO (Either StorageFailure Ticket)
submitAbandon svc b p = atomically $ do
  s ← readTVar (svState svc)
  let Backing u bid _ = b
  case Map.lookup bid (stBackings s) of
    _ | u /= svId svc → pure (Left ForeignHandle)
    Just e
      | GPrepared q ← eGrowth e, q == p → do
          t ← admitJob svc (Just b) (backingIdentity b) MaintenanceWork (WRelease (pgFrom p) (pgTo p) (Just p))
          when (either (const False) (const True) t) (setSlot svc bid (GReleasing (Just p)))
          pure t
      | otherwise → pure (Left (InvalidRequest NoPreparedGrowth))
    Nothing → pure (Left BackingClosed)

-- | Queue another attempt to release an extra reservation a failed release left
-- pending.
submitReleasePending ∷ StorageService → Backing → IO (Either StorageFailure Ticket)
submitReleasePending svc b = atomically $ do
  s ← readTVar (svState svc)
  let Backing u bid _ = b
  case Map.lookup bid (stBackings s) of
    _ | u /= svId svc → pure (Left ForeignHandle)
    Just e
      | Just extra ← ePending e, GIdle ← eGrowth e → do
          t ← admitJob svc (Just b) (backingIdentity b) MaintenanceWork (WRelease (eCap e) (eCap e + extra) Nothing)
          when (either (const False) (const True) t) (setSlot svc bid (GReleasing Nothing))
          pure t
      | Just _ ← ePending e → pure (Left (BusyNow GrowthActive))
      | otherwise → pure (Left (InvalidRequest NoPreparedGrowth))
    Nothing → pure (Left BackingClosed)

-- | The owner's commit of a prepared growth, after the model committed its own:
-- only now is the larger allowance spendable by this backend. The token must be the one this
-- service's current preparation made.
commitBackingGrowth ∷ StorageService → Backing → PreparedGrowth → IO (Either StorageFailure ())
commitBackingGrowth svc (Backing u bid _) p = atomically $ do
  s ← readTVar (svState svc)
  case Map.lookup bid (stBackings s) of
    _ | u /= svId svc || pgService p /= svId svc → pure (Left ForeignHandle)
    Nothing → pure (Left BackingClosed)
    Just e
      | ePhase e /= EOpen → pure (Left BackingClosed)
      | GPrepared q ← eGrowth e, q == p → do
          writeTVar (svState svc) s {stBackings = Map.insert bid e {eCap = pgTo p, eGrowth = GIdle} (stBackings s)}
          pure (Right ())
      | otherwise → pure (Left (InvalidRequest NoPreparedGrowth))

-- ---------------------------------------------------------------------------
-- Tickets

lookupTicket ∷ StorageService → Ticket → St → Maybe (Word64, Job)
lookupTicket svc (Ticket u jid) s
  | u /= svId svc = Nothing
  | otherwise = (,) jid <$> Map.lookup jid (stJobs s)

-- | Wait until the job has finished (an outcome exists). A ticket that names no
-- job (already taken, discarded or foreign) is finished.
awaitTicket ∷ StorageService → Ticket → STM ()
awaitTicket svc t = do
  s ← readTVar (svState svc)
  case lookupTicket svc t s of
    Nothing → pure ()
    Just (_, j) → case jPhase j of
      JDone _ → pure ()
      _ → retry

-- | Whether a job has finished, without waiting.
pollTicket ∷ StorageService → Ticket → STM Bool
pollTicket svc t = (awaitTicket svc t >> pure True) `orElse` pure False

-- | Run a body over a finished outcome while the service still holds its
-- accounting: a read's bytes stay charged until the body returns, and the record
-- is retired on every exit of the body. The outcome of a ticket that is not
-- finished, was taken, was discarded or is foreign is 'Nothing'.
withOutcome ∷ ∀ a. StorageService → Ticket → (Outcome → IO a) → IO (Maybe a)
withOutcome svc t body = mask $ \restore → do
  taken ← atomically $ do
    s ← readTVar (svState svc)
    case lookupTicket svc t s of
      Just (jid, j) | JDone o ← jPhase j, not (closingBacking s (jBacking j)) → do
        modifyTVar' (svState svc) $ \st →
          st
            { stJobs = Map.adjust (\x → x {jBorrowed = jBorrowed x + 1}) jid (stJobs st)
            , stBackings = adjustBorrow (jBacking j) 1 (stBackings st)
            }
        pure (Just (jid, o))
      _ → pure Nothing
  case taken of
    Nothing → pure Nothing
    Just (jid, o) → do
      -- the borrow was committed above and is released below, both masked: nothing is committed inside this
      -- unmasked region, and an exception delivered anywhere in it (after the body returned too) is caught here, so
      -- the borrow is always released and the delivery counted as failed (the caller sees the exception)
      r ← tryWithContext (restore (body o))
      -- A DELIVERY HAS THREE ENDS. Delivered: the callback returned, the caller owns what the outcome carries (a
      -- token, an opened backing) and the record is retired. Failed: the callback raised or was cancelled and no
      -- borrower received it: nobody owns it, and it goes through the ONE disposal. Undelivered is the discard.
      toClose ← atomically $ do
        modifyTVar' (svState svc) $ \st →
          st
            { stJobs = Map.adjust (\x → x {jBorrowed = jBorrowed x - 1, jDelivered = jDelivered x || either (const False) (const True) r}) jid (stJobs st)
            , stBackings = adjustBorrow (backingOfJob st jid) (-1) (stBackings st)
            }
        finishDelivery svc jid
      case r ∷ Either (ExceptionWithContext SomeException) a of
        Right x → pure (Just x)
        Left e → do
          -- an opened backing nobody can name is closed with its failure kept; the callback's own exception is the
          -- one propagated (a cancellation that reached that close's diagnostics is subsumed by it)
          forM_ toClose (closeUnwaited svc)
          rethrowIO e
  where
    backingOfJob st jid = Map.lookup jid (stJobs st) >>= jBacking
    -- a backing that is closing takes no new borrower: its records are retired by the close, and a caller taking outcomes
    -- must not be able to hold the close open
    closingBacking s mb = case mb >>= \bid → Map.lookup bid (stBackings s) of
      Just e → ePhase e /= EOpen
      Nothing → False

-- | The end of a borrow: once nobody borrows, a delivered outcome is retired (its owner took it) and an outcome no
-- borrower received goes through the one disposal.
finishDelivery ∷ StorageService → Word64 → STM (Maybe Word64)
finishDelivery svc jid = do
  s ← readTVar (svState svc)
  case Map.lookup jid (stJobs s) of
    Just j | JDone _ ← jPhase j, jBorrowed j == 0 →
      if jDelivered j then retireJob svc jid >> pure Nothing else disposeUndelivered svc jid
    _ → pure Nothing

adjustBorrow ∷ Maybe Word64 → Int → Map Word64 Entry → Map Word64 Entry
adjustBorrow Nothing _ m = m
adjustBorrow (Just bid) d m = Map.adjust (\e → e {eBorrows = eBorrows e + d}) bid m

-- | Give up a job's outcome. A finished job is retired (its record and bytes
-- released, and an opened backing it never delivered is closed). A queued job is
-- cancelled. A running job is asked to stop and retired when it ends.
discardTicket ∷ StorageService → Ticket → IO ()
discardTicket svc t = mask_ $ do
  -- masked end to end: the transaction that retires the record and names the backing nobody can name is followed by
  -- the close of that backing with no unmasked point between the effect and its record
  toClose ← atomically $ do
    s ← readTVar (svState svc)
    case lookupTicket svc t s of
      Nothing → pure Nothing
      Just (jid, j) → case jPhase j of
        JDone _ | jBorrowed j == 0 → disposeUndelivered svc jid
        JDone _ → pure Nothing
        JQueued → withdrawQueued svc jid True >> pure Nothing
        JRunning → do
          -- the holder gives the outcome up: the job stops at its next safe point and is disposed of when it ends
          modifyTVar' (svState svc) (\st → st {stJobs = Map.adjust (\x → x {jCancel = True, jDiscard = True}) jid (stJobs st)})
          pure Nothing
  forM_ toClose (\b → closeUnwaited svc b >>= mapM_ rethrowIO)

data CancelResult
  = -- | A queued job was withdrawn and settled as cancelled.
    CancelledBeforeDispatch
  | -- | A running job will stop at its next safe point; nothing is released yet.
    CancelRequested
  | -- | The job had already finished: its outcome stands.
    CancelTooLate
  | CancelUnknown
  deriving stock (Eq, Show)

-- | Request a job's cancellation. It is a request: a running job keeps every
-- resource it uses until it has actually returned.
cancelTicket ∷ StorageService → Ticket → IO CancelResult
cancelTicket svc t = atomically $ do
  s ← readTVar (svState svc)
  case lookupTicket svc t s of
    Nothing → pure CancelUnknown
    Just (jid, j) → case jPhase j of
      JQueued → do
        withdrawQueued svc jid False
        pure CancelledBeforeDispatch
      JRunning → do
        modifyTVar' (svState svc) (\st → st {stJobs = Map.adjust (\x → x {jCancel = True}) jid (stJobs st)})
        pure CancelRequested
      JDone _ → pure CancelTooLate

-- | Record a job's outcome: its resources of the running phase end here (the
-- transfer's staging, the mutation slot), its result stays until retired.
finishJob ∷ StorageService → Word64 → Outcome → STM (Maybe Word64)
finishJob svc jid outcome = do
  s ← readTVar (svState svc)
  case Map.lookup jid (stJobs s) of
    Nothing → pure Nothing
    Just j → do
      forM_ (jDispatch j) $ \g → if holdsResult outcome then releaseStaging svc g else releaseGrant svc g
      let linked = case outcome of Opened (Backing _ bid _) _ → Just bid; _ → jBacking j
          j' = j {jPhase = JDone outcome, jDispatch = if holdsResult outcome then jDispatch j else Nothing, jBacking = linked}
      writeTVar (svState svc) s
        { stJobs = Map.insert jid j' (stJobs s)
        , stRunning = if isRunningPhase (jPhase j) then stRunning s - 1 else stRunning s
        , stMutation = if stMutation s == Just jid then Nothing else stMutation s
        }
      -- a ticket discarded while the job ran: nobody will take the outcome, so it is retired here, and
      -- a backing it opened (which nobody can name) is for the worker to close
      if jDiscard j then disposeUndelivered svc jid else pure Nothing
  where
    isRunningPhase JRunning = True
    isRunningPhase _ = False
    holdsResult o = case o of Pages _ → True; _ → False

-- | Retire a finished job: its record's charge and its result's bytes are
-- released and it leaves the table. A job still borrowed or not finished stays.
retireJob ∷ StorageService → Word64 → STM ()
retireJob svc jid = do
  s ← readTVar (svState svc)
  case Map.lookup jid (stJobs s) of
    Just j | JDone _ ← jPhase j, jBorrowed j == 0 → do
      forM_ (jDispatch j) (releaseGrant svc)
      releaseGrant svc (jControl j)
      modifyTVar' (svState svc) (\st → st {stJobs = Map.delete jid (stJobs st)})
    _ → pure ()

-- ---------------------------------------------------------------------------
-- Scheduling and the workers

-- | The classes in the order they are offered, by the fairness counters.
offerOrder ∷ St → [WorkClass]
offerOrder s
  | waiting MaintenanceWork && fMaint (stFair s) >= fairMaintenance = [MaintenanceWork, ExplicitWork, CameraWork]
  | waiting CameraWork && fCamera (stFair s) >= fairCamera = [CameraWork, ExplicitWork, MaintenanceWork]
  | otherwise = [ExplicitWork, MaintenanceWork, CameraWork]
  where
    waiting c = maybe False (not . Seq.null) (Map.lookup c (stQueue s))

-- | What a dispatched job is charged beyond its record: a read's transfer buffer
-- (staging, camera work limited to the unprotected share) and its result copy
-- (cache, pinned until retired). Nothing else is charged at dispatch.
dispatchCredits ∷ Job → Maybe (A.Class, [A.Credit])
dispatchCredits j = case jWork j of
  WRead (ReadSpec _ _ n _) →
    let cls = if jClass j == CameraWork then A.Camera else A.Foreground
     in Just (cls, [A.StagingCredit (transferBufferBytes n), A.CacheCredit (siArena (jIdent j)) (fromIntegral n * resultPageBytes) A.Backed True])
  _ → Nothing

-- | Take the next dispatchable job: the first queued job, in the offered order,
-- whose dispatch charge is funded. A job that cannot be funded now stays queued
-- and a later one may run; none waits on a job that waits on it.
dispatchNext ∷ StorageService → STM Word64
dispatchNext svc = do
  s ← readTVar (svState svc)
  a ← readTVar (svAdmission svc)
  let candidates = [(c, jid) | c ← offerOrder s, jid ← toList (Map.findWithDefault Seq.empty c (stQueue s))]
      try' [] = Nothing
      try' ((c, jid) : rest) = case Map.lookup jid (stJobs s) of
        Nothing → try' rest
        Just j → case dispatchCredits j of
          Nothing → Just (c, jid, Nothing, a)
          Just (cls, credits) → case A.reserve cls credits a of
            -- the service never evicts what another consumer caches: a dispatch that would need that waits
            -- until the owner has released (dropped) enough, and the reservation made for it is discarded
            Right (g, a') | null (A.grantEvicted g) → Just (c, jid, Just g, a')
            _ → try' rest
  case try' candidates of
    Nothing → retry
    Just (c, jid, grant, a') → do
      writeTVar (svAdmission svc) a'
      let advance (Fair m cm) = case c of
            ExplicitWork → Fair (m + bump MaintenanceWork) (cm + bump CameraWork)
            MaintenanceWork → Fair 0 (cm + bump CameraWork)
            CameraWork → Fair m 0
          bump k = if maybe False (not . Seq.null) (Map.lookup k (stQueue s)) then 1 else 0
      writeTVar (svState svc) s
        { stQueue = Map.adjust (Seq.filter (/= jid)) c (stQueue s)
        , stJobs = Map.adjust (\j → j {jPhase = JRunning, jDispatch = grant}) jid (stJobs s)
        , stRunning = stRunning s + 1
        , stFair = advance (stFair s)
        }
      pure jid

-- | The worker. The cooperative stop its token carries is the ONLY normal way out; every other way out (an exception
-- out of the dispatch wait, a cancellation or a defect out of a job, a remembered cancellation delivered after a job
-- that had finished) runs the one 'stopService' first and then propagates: admission never stays open over a worker
-- that is gone.
workerLoop ∷ StorageService → StopToken → IO ()
workerLoop svc token = mask_ $ do
  r ← tryWithContext loop ∷ IO (Either (ExceptionWithContext SomeException) ())
  case r of
    Right () → pure ()
    Left ewc@(ExceptionWithContext _ e) → do
      atomically (stopService svc ("a storage worker ended: " <> T.take 256 (T.pack (show e))))
      rethrowIO ewc
  where
    -- THE DISPATCH IS MASKED, with no unmasked region around it. Under 'mask', 'atomically' is interruptible exactly
    -- while it is blocked in a retry (the wait for work or for the stop) and at no other point, so the wait can still
    -- be cancelled, and a transaction that committed (the job is running, 'stRunning' counted) is always followed by
    -- 'runJob': an unmasked region around it would let a cancellation land between the commit and the run, leaving a
    -- job running for ever with no worker, a close waiting on it and the service's end hanging.
    loop = do
      next ← atomically ((Just <$> dispatchNext svc) `orElse` (awaitStopRequest token >> pure Nothing))
      case next of
        Nothing → pure ()
        Just jid → runJob svc jid >> loop

-- | Run one dispatched job and record its outcome. A defect (an exception that is
-- not an expected storage result) is recorded, completes the job as a host
-- failure, stops the service and ends the worker with it: it is never reported
-- as an ordinary failure.
runJob ∷ StorageService → Word64 → IO ()
runJob svc jid = do
  job ← atomically (Map.lookup jid . stJobs <$> readTVar (svState svc))
  case job of
    Nothing → pure ()
    Just j → do
      r ← tryWithContext (execute svc jid j)
      case r ∷ Either (ExceptionWithContext SomeException) Outcome of
        Right outcome → do
          toClose ← atomically (finishJob svc jid outcome)
          -- a close nobody waits for: its failure has a keeper, its cancellation is remembered
          lateClose ← maybe (pure Nothing) (closeUnwaited svc) toClose
          -- the job is finished; only now the diagnostic. A cancellation that arrives at the log is delivered
          -- after it, with the close's: the worker ends with it (the one stop of 'workerLoop' runs)
          lateLog ← case outcome of
            Opened b rv → quietly (logInfo (svLogger svc) component "Backing opened" [("backing", T.pack (show b)), ("allocated", T.pack (show (rsAllocated rv)))])
            _ → pure Nothing
          forM_ (firstLate [lateClose, lateLog]) rethrowIO
        Left ewc@(ExceptionWithContext ctx e) → do
          -- the defect keeps its context (the cleanup failures of every scope it crossed) all the way to the
          -- worker's completion, and the job's outcome names them
          let cleanup = map (T.pack . displayCleanupFailure) (cleanupFailuresInContext ctx)
              why = T.intercalate "; " (T.pack (show e) : map ("cleanup: " <>) cleanup)
          -- the bookkeeping first (the job finishes, its record and charge are released, the service stops), the
          -- diagnostic after it: nothing a log does can leave the job running. A cancellation that arrives at the
          -- log is dropped with the entry, because the worker ends with the defect either way
          -- (the outcome's text is bounded: what is retained is charged and measured at its largest)
          -- the bounded text is a COPY, evaluated before it is stored: a lazy slice would retain the whole text
          let bounded = T.copy (T.take maxHostFailureChars why)
          bounded `seq` atomically (do
            void (finishJob svc jid (Failed (HostFailure bounded) []))
            modifyTVar' (svState svc) (\s → s {stDefect = Just bounded})
            stopService svc (T.take 256 why))
          _ ← quietly (logError (svLogger svc) component "Storage worker defect" [("defect", why)])
          rethrowIO ewc

-- | The most characters of a defect's text a job's outcome and the service's record retain.
maxHostFailureChars ∷ Int
maxHostFailureChars = 256

cancelled ∷ StorageService → Word64 → IO Bool
cancelled svc jid = atomically (maybe False jCancel . Map.lookup jid . stJobs <$> readTVar (svState svc))

execute ∷ StorageService → Word64 → Job → IO Outcome
execute svc jid j = case jWork j of
  WOpen spec → execOpen svc jid spec
  WRead spec → execRead svc jid j spec
  WWrite w → execWrite svc jid j w
  WGrow (GrowSpec from to) → execGrow svc jid j from to
  WRelease from to _ → execRelease svc j from to

entryOf ∷ StorageService → Maybe Word64 → STM (Maybe (Word64, Entry))
entryOf svc mb = case mb of
  Nothing → pure Nothing
  Just bid → fmap ((,) bid) . Map.lookup bid . stBackings <$> readTVar (svState svc)

-- ---------------------------------------------------------------------------
-- Reads and writes

execRead ∷ StorageService → Word64 → Job → ReadSpec → IO Outcome
execRead svc jid j (ReadSpec cfg (PageNo first) count mode) = do
  me ← atomically (entryOf svc (jBacking j))
  case me of
    Nothing → pure (Failed BackingClosed [])
    Just (_, e) → do
      let seam = svSeam svc
          ident = jIdent j
      buf ← BSI.mallocByteString (count * pageSize)
      withForeignPtr buf $ \base → go seam e ident base (0 ∷ Int) []
  where
    go seam e ident base i acc
      | i >= count = pure (Pages (reverse acc))
      | otherwise = do
          stop ← cancelled svc jid
          if stop
            then pure (Cancelled [])
            else do
              let page = PageNo (first + fromIntegral i)
              case pageFileOffset cfg page of
                Left off → pure (Failed (InvalidRequest (PageOutsideFile page off)) [])
                Right off → do
                  r ← readFully seam (base `plusPtr` (i * pageSize)) pageSize off (eFd e)
                  case r of
                    Left (ReadFailed f) → pure (Failed (StorageIo f {ioPage = Just page}) [])
                    Left (ReadEnded got want) → pure (Failed (StorageIntegrity (PageTruncated page off got want)) [])
                    Right () → do
                      bytes ← BS.packCStringLen (castPtr (base `plusPtr` (i * pageSize)), pageSize)
                      case mode of
                        ReadProbe → go seam e ident base (i + 1) ((page, bytes) : acc)
                        ReadValidated → case decodePage ident (cfgTotalPages cfg) page bytes of
                          Left err → pure (Failed (StorageIntegrity (PageInvalid page off err)) [])
                          Right _ → go seam e ident base (i + 1) ((page, bytes) : acc)
execWrite ∷ StorageService → Word64 → Job → StagedWrite → IO Outcome
execWrite svc jid j w = do
  me ← atomically (entryOf svc (jBacking j))
  case me of
    Nothing → pure (Written (WriteReport (swTxn w) [(p, WriteFailedAt BackingClosed) | (p, _) ← swPages w]))
    Just (_, e) → do
      results ← go e (swPages w) []
      pure (Written (WriteReport (swTxn w) results))
  where
    go _ [] acc = pure (reverse acc)
    go e ((p, bytes) : rest) acc = do
      stop ← cancelled svc jid
      failedAlready ← pure (any (\(_, r) → r /= Wrote) acc)
      if stop || failedAlready
        then pure (reverse acc <> [(q, NotAttempted) | (q, _) ← (p, bytes) : rest])
        else case pageFileOffset (swConfig w) p of
          Left off → pure (reverse acc <> [(p, WriteFailedAt (InvalidRequest (PageOutsideFile p off)))] <> [(q, NotAttempted) | (q, _) ← rest])
          Right off → do
            r ← BSU.unsafeUseAsCStringLen bytes $ \(ptr, len) → writeFully (svSeam svc) (castPtr ptr) len off (eFd e)
            case r of
              Right () → go e rest ((p, Wrote) : acc)
              Left f → pure (reverse acc <> [(p, WriteFailedAt (StorageIo f {ioPage = Just p}))] <> [(q, NotAttempted) | (q, _) ← rest])

-- ---------------------------------------------------------------------------
-- Opening

-- | Run an action holding the volume's coordination: no other reservation on the
-- same volume runs while it does, so two arenas cannot spend the same observed
-- headroom. Waiting for it is uninterruptible by design: the holder is another
-- worker's native reservation, which cannot wait for this one.
withVolume ∷ StorageService → Word64 → IO a → IO a
withVolume svc dev act =
  seamBefore (svSeam svc) (OpVolumeWait dev) *> bracket_ (uninterruptibleMask_ (atomically acquire)) (atomically release) act
  where
    acquire = do
      s ← readTVar (svState svc)
      check (not (Set.member dev (stBusyVolumes s)))
      writeTVar (svState svc) s {stBusyVolumes = Set.insert dev (stBusyVolumes s)}
    release = modifyTVar' (svState svc) (\s → s {stBusyVolumes = Set.delete dev (stBusyVolumes s)})

-- | A cleanup step of an open that failed while an exception unwound it.
data OpenCleanupFailed = OpenCleanupFailed !IoOp !Errno
  deriving stock (Show)

instance Exception OpenCleanupFailed

data OpenStop = OpenCancelled | OpenFailed !StorageFailure

-- | Open a backing. From the moment the file exists until the backing table owns the descriptor
-- (the one transaction that registers it), THIS function owns it, on every exit: a typed failure
-- unwinds explicitly, and an exception (from any native step, the seam included) closes it too,
-- keeping the cleanup failures beside the primary exception.
execOpen ∷ StorageService → Word64 → OpenSpec → IO Outcome
execOpen svc jid spec = do
  stop0 ← cancelled svc jid
  if stop0 then pure (Cancelled []) else do
    unique ← atomically (stateTVar (svNames svc) (\n → (n, n + 1)))
    -- the descriptor and its name are owned the instant the native create succeeds: 'createPrivate' records them in
    -- this reference BEFORE the seam's after-hook runs, so the handler below finds them whatever the hook did
    created ← newIORef Nothing
    owned ← newIORef (0 ∷ Int)
    r ← tryWithContext $ do
      made ← createPrivate seam (osDirectory spec) unique (writeIORef created . Just)
      case made of
        Left f → pure (Failed (StorageIo f) [])
        Right c → afterCreate c owned
    case r of
      Right o → pure o
      Left ewc → do
        state ← readIORef owned
        mc ← readIORef created
        -- an exception: the descriptor is closed here unless the table already owns it; the name is
        -- unlinked again if it still exists (a second unlink finding none is not a failure)
        -- 0: still ours; 1: the table owns it; 2: its close was already attempted (never repeated)
        notes ← case mc of
          Just c | state == 0 → unwind owned c True
          _ → pure []
        evidence ← sequence [(,) "open cleanup" <$> evidenceOf (OpenCleanupFailed op e) | CleanupNote op e ← notes, e /= Errno 2]
        final ← composeCleanup (Just ewc) evidence
        rethrowIO (fromMaybe ewc final)
  where
    seam = svSeam svc
    cfg = osConfig spec
    allowance = cfgAllowanceBytes cfg
    -- every failure after the file exists closes the descriptor (which releases
    -- everything it obtained) and keeps what the cleanup could not do
    -- the cleanup steps run independently: each is attempted whatever the other does, an exception from one is a
    -- cleanup failure (errno -1) and never prevents the other, and the close is attempted exactly once
    unwind owned c named = do
      notes1 ← if named then step IoUnlink (retryUnlink c) else pure []
      -- recorded BEFORE the close is attempted, so an exception from it can never lead to a second close
      writeIORef owned 2
      notes2 ← step IoClose (closeNote c)
      pure (notes1 <> notes2)
    step op act = do
      r ← tryWithContext act ∷ IO (Either (ExceptionWithContext SomeException) [CleanupNote])
      case r of
        Right ns → pure ns
        Left (ExceptionWithContext _ ex) → do
          -- a cancellation that arrives at this log is one more failure of the step: it is kept as a second note
          -- of it, and the cleanup goes on (the close is still made, once)
          l ← quietly (logWarning (svLogger svc) component "Open cleanup step raised" [("exception", T.pack (show ex))])
          pure (CleanupNote op (Errno (-1)) : [CleanupNote op (Errno (-1)) | Just _ ← [l]])
    retryUnlink c = do
      r ← unlinkFile seam (osDirectory spec) (crName c)
      pure [CleanupNote IoUnlink e | Left e ← [r]]
    closeNote c = do
      r ← uninterruptibleMask_ (closeFile seam (crFd c))
      pure [CleanupNote IoClose e | Left e ← [r]]
    afterCreate c owned = do
      un ← unlinkFile seam (osDirectory spec) (crName c)
      case un of
        Left e → do
          notes ← unwind owned c True
          pure (Failed (StorageIo (IoFailure IoUnlink (IoErrno e) Nothing Nothing 0 0)) notes)
        Right () → do
          v ← verifyPrivate seam (crFd c)
          case v of
            Left f → do
              notes ← unwind owned c False
              pure (Failed (StorageIo f) notes)
            Right st → do
              stop ← cancelled svc jid
              if stop
                then Cancelled <$> unwind owned c False
                else withVolume svc (nsDevice st) (reserveAndRegister c owned st)
    reserveAndRegister c owned st = do
      r ← reserveRange seam (svConfig svc) (cancelled svc jid) (crFd c) 0 allowance
      case r of
        Left (StoppedCancelled _) → Cancelled <$> unwind owned c False
        Left (StoppedFailure f _) → do
          notes ← unwind owned c False
          pure (Failed f notes)
        Right rv
          | rvOverhead rv > cfgOverheadBytes cfg → do
              notes ← unwind owned c False
              pure (Failed (ReservationFailed (OverheadExceedsModel (rvOverhead rv) (cfgOverheadBytes cfg))) notes)
          | otherwise → do
              registered ← atomically (register c st rv)
              case registered of
                Left OpenCancelled → Cancelled <$> unwind owned c False
                Left (OpenFailed f) → do
                  notes ← unwind owned c False
                  pure (Failed f notes)
                Right (b, reservation) → do
                  -- the table owns the descriptor from the transaction above
                  writeIORef owned 1
                  pure (Opened b reservation)
    -- cancellation is arbitrated in the transaction that publishes the backing
    register c st rv = do
      s ← readTVar (svState svc)
      let cancelRequested = maybe False jCancel (Map.lookup jid (stJobs s))
      if stPhase s /= Running
        then pure (Left (OpenFailed ServiceStopped))
        else
          if cancelRequested
            then pure (Left OpenCancelled)
            else do
              charged ← withAdmission svc (\a → A.reserve A.Foreground [A.ControlCredit backingRecordBytes] a)
              case charged of
                Left r → pure (Left (OpenFailed (mapRefusal r)))
                Right grant → do
                  let bid = stNextBacking s
                      ident = osIdentity spec
                      entry = Entry (crFd c) ident (nsDevice st) allowance (rvLength rv) (cfgOverheadBytes cfg) GIdle Nothing EOpen 0 (cfgOffsetLimit cfg) grant
                      prof = rvProfile rv
                  writeTVar (svState svc) s
                    { stNextBacking = bid + 1
                    , stBackings = Map.insert bid entry (stBackings s)
                    , stReserved = Map.insertWith (+) (nsDevice st) (rvLength rv) (stReserved s)
                    }
                  pure (Right (Backing (svId svc) bid ident, Reservation (rvAllocated rv) (rvLength rv) (rvOverhead rv) (vpFilesystem prof) (vpBlockSize prof) (nsDevice st)))

-- ---------------------------------------------------------------------------
-- Growth

-- | Execute a growth: reserve and prove the extra range, then publish it as prepared in ONE transaction that
-- also arbitrates cancellation. Whatever may have been acquired (every stop after the native allocation was
-- attempted, a failed final query included, and an exception from any step) is released before the slot
-- returns to idle, or left as a charged pending reservation when that release fails.
execGrow ∷ StorageService → Word64 → Job → Word64 → Word64 → IO Outcome
execGrow svc jid j from to = do
  me ← atomically (entryOf svc (jBacking j))
  case me of
    Just _ | from == to → pure GrowthNoChange
    Nothing → pure (Failed BackingClosed [])
    Just (bid, e) → withVolume svc (eVolume e) $ do
      r ← tryWithContext (reserveRange seam (svConfig svc) (cancelled svc jid) (eFd e) from (to - from))
      case r of
        Left ewc → do
          notes ← giveBack bid e True
          evidence ← sequence [(,) "growth release" <$> evidenceOf (OpenCleanupFailed op err) | CleanupNote op err ← notes]
          final ← composeCleanup (Just ewc) evidence
          rethrowIO (fromMaybe ewc final)
        Right (Left (StoppedCancelled acquired)) → Cancelled <$> giveBack bid e acquired
        Right (Left (StoppedFailure f acquired)) → (\notes → Failed f notes) <$> giveBack bid e acquired
        Right (Right rv)
          | rvOverhead rv > eOverheadModel e →
              (\notes → Failed (ReservationFailed (OverheadExceedsModel (rvOverhead rv) (eOverheadModel e))) notes) <$> giveBack bid e True
          | otherwise → do
              let p = PreparedGrowth (svId svc) jid bid from to (rvAllocated rv)
              published ← atomically $ do
                s ← readTVar (svState svc)
                let cancelRequested = maybe False jCancel (Map.lookup jid (stJobs s))
                case Map.lookup bid (stBackings s) of
                  Just x | not cancelRequested, GRunning ← eGrowth x → do
                    writeTVar (svState svc) s
                      { stBackings = Map.insert bid x {eGrowth = GPrepared p, eLength = to} (stBackings s)
                      , stReserved = Map.insertWith (+) (eVolume e) (to - from) (stReserved s)
                      }
                    pure True
                  _ → pure False
              if published
                then do
                  let prof = rvProfile rv
                  pure (GrowthPrepared p (Reservation (rvAllocated rv) (rvLength rv) (rvOverhead rv) (vpFilesystem prof) (vpBlockSize prof) (eVolume e)))
                else Cancelled <$> giveBack bid e True
  where
    seam = svSeam svc
    -- give the extra back and return the slot to idle; a release that fails leaves a bounded pending record
    -- that stays charged until an explicit retry or the close
    giveBack bid e acquired
      | not acquired = atomically (setSlot svc bid GIdle) >> pure []
      | otherwise = do
          -- an exception from the release is a release that failed: the extra is then kept as pending
          released ← tryWithContext (releaseExtra seam (eFd e) from to) ∷ IO (Either (ExceptionWithContext SomeException) (Either Errno ()))
          case either (const (Left (Errno (-1)))) id released of
            Right () → atomically (setSlot svc bid GIdle) >> pure []
            Left err → do
              atomically $ modifyTVar' (svState svc) $ \s →
                s { stBackings = Map.adjust (\x → x {ePending = Just (to - from), eGrowth = GIdle}) bid (stBackings s)
                  , stReserved = Map.insertWith (+) (eVolume e) (to - from) (stReserved s)
                  }
              pure [CleanupNote IoSetLength err]

-- | Release an abandoned growth's or a pending extra reservation. The slot is 'GReleasing' from the
-- transaction that admitted the job; it is idle again when this ends, however it ends.
execRelease ∷ StorageService → Job → Word64 → Word64 → IO Outcome
execRelease svc j from to = do
  me ← atomically (entryOf svc (jBacking j))
  case me of
    Nothing → pure (Failed BackingClosed [])
    Just (bid, e) → withVolume svc (eVolume e) $ do
      released ← tryWithContext (releaseExtra (svSeam svc) (eFd e) from to) ∷ IO (Either (ExceptionWithContext SomeException) (Either Errno ()))
      case released of
        Left ewc → do
          -- an exception: what the release did is unknown, so the extra stays accounted as pending
          atomically (pendAgain bid)
          rethrowIO ewc
        Right (Right ()) → do
          atomically $ modifyTVar' (svState svc) $ \s →
            s { stBackings = Map.adjust (\x → x {eGrowth = GIdle, ePending = Nothing, eLength = from}) bid (stBackings s)
              , stReserved = subReserved (eVolume e) (to - from) (stReserved s)
              }
          pure Released
        Right (Left err) → do
          atomically (pendAgain bid)
          pure (Failed (StorageIo (IoFailure IoSetLength (IoErrno err) Nothing Nothing 0 0)) [CleanupNote IoSetLength err])
  where
    pendAgain bid = modifyTVar' (svState svc) $ \s →
      -- the extra is now the pending record's: the length is the committed size again, so a backing's
      -- contribution to the volume's reserved figure is always its length plus its pending extra
      s {stBackings = Map.adjust (\x → x {eGrowth = GIdle, ePending = Just (to - from), eLength = from}) bid (stBackings s)}

-- ---------------------------------------------------------------------------
-- Scoped use and closing

-- | Borrow a backing for the duration of an action: a close waits for the
-- borrower. The owner holds one for each live reader pin. A closed backing
-- refuses.
withUse ∷ ∀ a. StorageService → Backing → IO a → IO (Either StorageFailure a)
withUse svc (Backing u bid _) act = mask $ \restore → do
  entered ← atomically $ do
    s ← readTVar (svState svc)
    case Map.lookup bid (stBackings s) of
      _ | u /= svId svc → pure (Left ForeignHandle)
      Just e | ePhase e == EOpen → do
        writeTVar (svState svc) s {stBackings = Map.insert bid e {eBorrows = eBorrows e + 1} (stBackings s)}
        pure (Right ())
      _ → pure (Left BackingClosed)
  case entered of
    Left f → pure (Left f)
    Right () → do
      -- the borrow was committed above and is released below, both masked: nothing is committed in this region
      r ← tryWithContext (restore act)
      atomically (modifyTVar' (svState svc) (\s → s {stBackings = Map.adjust (\e → e {eBorrows = eBorrows e - 1}) bid (stBackings s)}))
      case r ∷ Either (ExceptionWithContext SomeException) a of
        Right x → pure (Right x)
        Left ex → rethrowIO ex

-- | What closing a backing did.
data CloseReport = CloseReport
  { crClosed ∷ !Bool
  -- ^ This call closed the descriptor (a second close finds nothing to close).
  , crCloseError ∷ !(Maybe Errno)
  -- ^ The platform's error from the one close, kept and never retried.
  , crPendingReservation ∷ !(Maybe Word64)
  -- ^ An extra reservation still pending when the file closed; closing it
  -- released it with the file.
  , crCloseException ∷ !(Maybe Text)
  -- ^ An exception the one close raised (the call was made once and is not repeated).
  }
  deriving stock (Eq, Show)

-- | Close one backing: stop admission to it, withdraw its queued jobs, ask its
-- running jobs to stop, wait (no deadline, no detach) for them and for every
-- borrower to retire, then close the descriptor, once. The wait is in the
-- caller's protected boundary, not in an uninterruptibly masked release; the
-- close itself is a bounded call, made uninterruptibly.
noClose ∷ CloseReport
noClose = CloseReport False Nothing Nothing Nothing

closeBacking ∷ StorageService → Backing → IO CloseReport
closeBacking svc (Backing u bid _)
  | u /= svId svc = pure (noClose)
  | otherwise = closeBackingId svc bid

-- | Close a backing for a caller that receives the report. A failing close is ALWAYS kept by the service (below), so
-- the report is a copy: a cancellation remembered by the close is delivered after it, and nothing is lost behind it.
closeBackingId ∷ StorageService → Word64 → IO CloseReport
closeBackingId svc bid = do
  (late, report) ← closeBackingCore svc bid
  forM_ late rethrowIO
  pure report

-- | A close NOBODY WAITS FOR (a discarded opened backing, one a failed delivery left, one a worker closes): the
-- service keeps its failing report like every other, and the remembered cancellation is for the caller to deliver
-- once its own bookkeeping is done.
closeUnwaited ∷ StorageService → Word64 → IO (Maybe (ExceptionWithContext SomeException))
closeUnwaited svc bid = fst <$> closeBackingCore svc bid

-- | The close, returning an interruption it remembered instead of obeying, for the caller to deliver. THE CLOSE CORE
-- OWNS EVERYTHING UNTIL IT RETURNS: the claim moves the entry into a closing record; the native close is made once;
-- ONE transaction then releases the grant, subtracts the reservation, KEEPS a failing close as labelled evidence (the
-- service always keeps it, whoever asked: a cancellation pending during the uninterruptible close is delivered the
-- moment this mask ends, before any caller could receive the report, so "the caller is the keeper" can never be made
-- safe) and marks the record reporting; the diagnostics follow ('quietly' cannot raise); another transaction deletes
-- the record. The drain joins the records, so the service cannot end while a close is in its diagnostics.
closeBackingCore ∷ StorageService → Word64 → IO (Maybe (ExceptionWithContext SomeException), CloseReport)
closeBackingCore svc bid = mask_ $ do
  started ← atomically $ do
    s ← readTVar (svState svc)
    case Map.lookup bid (stBackings s) of
      Nothing → pure False
      Just e → do
        writeTVar (svState svc) s {stBackings = Map.insert bid e {ePhase = EClosing} (stBackings s)}
        withdrawWhere svc ((== Just bid) . jBacking)
        pure True
  if not started
    then pure (Nothing, noClose)
    else do
      -- the drain check and the claim of the descriptor are ONE transaction: nothing (a job, a borrower, an
      -- outcome taken for a body) can begin between the two, and the wait for it is in the caller's boundary,
      -- every interruption remembered and delivered after the close. The whole hand-off to the native close is
      -- masked, so no exception can fall between the entry leaving the table and the close being made.
      (late, claimed) ← protectedly (atomically (claim bid))
      case claimed of
        Just (Just e) → do
          r ← tryWithContext (uninterruptibleMask_ (closeFile (svSeam svc) (eFd e))) ∷ IO (Either (ExceptionWithContext SomeException) (Either Errno ()))
          let (err, thrown) = case r of
                Right (Left en) → (Just en, Nothing)
                Right (Right ()) → (Nothing, Nothing)
                Left (ExceptionWithContext _ ex) → (Nothing, Just (T.pack (show ex)))
              -- the typed failure of the close: the backing's id and the errno, or the (bounded) text of the exception
              failing = [KeptClose bid (CloseErrno en) | Just en ← [err]] <> [KeptClose bid (CloseRaised (T.copy (T.take maxHostFailureChars t))) | Just t ← [thrown]]
          atomically (finishClosing svc bid e ("close of backing " <> T.pack (show bid)) failing)
          -- the diagnostics, each remembered and not obeyed: the report is still made and the caller (the drain,
          -- which goes on to close the other backings) delivers a cancellation afterwards
          l1 ← maybe (pure Nothing) (\(Errno n) → quietly (logWarning (svLogger svc) component "Backing close failed" [("errno", T.pack (show n))])) err
          l2 ← maybe (pure Nothing) (\t → quietly (logWarning (svLogger svc) component "Backing close raised" [("exception", t)])) thrown
          l3 ← quietly (logInfo (svLogger svc) component "Backing closed" [("backing", T.pack (show bid))])
          -- nothing is left to do with the service: the record ends
          atomically (endClosing svc bid)
          pure (firstLate [late, l1, l2, l3], CloseReport True err (ePending e) thrown)
        _ → pure (late, noClose)
  where
    claim b = do
      s ← readTVar (svState svc)
      case Map.lookup b (stBackings s) of
        Nothing → pure Nothing
        Just e → do
          let active = [() | j ← Map.elems (stJobs s), jBacking j == Just b, activePhase (jPhase j) || jBorrowed j > 0]
          check (null active && eBorrows e == 0)
          -- the records of this backing's jobs are disposed of here (an open outcome's backing is this one: no second close)
          forM_ [jid | (jid, j) ← Map.toList (stJobs s), jBacking j == Just b] (disposeUndelivered svc)
          -- the entry MOVES into the closing record whole: nothing it pays for is released here, because the
          -- descriptor, the file's allocation and the entry are all still live until the native close returns
          modifyTVar' (svState svc) $ \t →
            t { stBackings = Map.delete b (stBackings t)
              , stClosingRecs = Map.insert b (CrNative e) (stClosingRecs t)
              }
          pure (Just e)
    activePhase JQueued = True
    activePhase JRunning = True
    activePhase (JDone _) = False

-- | The native close has returned, so what the file held is gone: in ONE transaction the backing's contribution leaves
-- the volume's reserved figure, a failing close is KEPT as evidence and the record becomes 'CrReporting', still
-- carrying the control grant (a record is charged for as long as it lives: the diagnostics may be held by a logger
-- for as long as that logger likes).
finishClosing ∷ StorageService → Word64 → Entry → Text → [KeptFailure] → STM ()
finishClosing svc bid e label failing = do
  modifyTVar' (svState svc) $ \t →
    t { stReserved = subReserved (eVolume e) (backingContribution e) (stReserved t)
      , stClosingRecs = Map.insert bid (CrReporting (eGrant e)) (stClosingRecs t)
      }
  keepEvidence svc label failing

-- | The close has nothing left to do with the service: the record's charge is released and the record ends, in ONE
-- transaction.
endClosing ∷ StorageService → Word64 → STM ()
endClosing svc bid = do
  s ← readTVar (svState svc)
  case Map.lookup bid (stClosingRecs s) of
    Just (CrReporting g) → releaseGrant svc g
    _ → pure ()
  modifyTVar' (svState svc) (\t → t {stClosingRecs = Map.delete bid (stClosingRecs t)})

-- | A volume's figure less @n@. A volume nothing is reserved on holds no place in the service: its node leaves the
-- map at zero, so a node never outlives the charge of the last record that paid for it.
subReserved ∷ Word64 → Word64 → Map Word64 Word64 → Map Word64 Word64
subReserved dev n = Map.update (\v → let r = v - min v n in if r == 0 then Nothing else Just r) dev

-- ---------------------------------------------------------------------------
-- Inspection

-- | What a backing reports of itself.
data BackingView = BackingView
  { bvCommittedBytes ∷ !Word64
  , bvLengthBytes ∷ !Word64
  , bvPendingReservation ∷ !(Maybe Word64)
  , bvGrowthPrepared ∷ !Bool
  , bvBorrows ∷ !Int
  , bvClosing ∷ !Bool
  }
  deriving stock (Eq, Show)

backingView ∷ StorageService → Backing → STM (Maybe BackingView)
backingView svc (Backing _ bid _) = do
  s ← readTVar (svState svc)
  pure $ flip fmap (Map.lookup bid (stBackings s)) $ \e →
    BackingView (eCap e) (eLength e) (ePending e) (case eGrowth e of GIdle → False; _ → True) (eBorrows e) (ePhase e /= EOpen)

-- | What the service reports of itself: the counts the contract bounds.
data ServiceView = ServiceView
  { svQueued ∷ !Int
  , svRunning ∷ !Int
  , svRecords ∷ !Int
  , svBackings ∷ !Int
  , svMutating ∷ !Bool
  , svReserved ∷ !(Map Word64 Word64)
  , svDefect ∷ !(Maybe Text)
  , svWaitingForCache ∷ !Int
  -- ^ Queued jobs the service refuses to dispatch because it would have to evict a copy another consumer
  -- caches: the owner must drop (release) backed, unpinned copies before they can run. The signal is this count.
  }
  deriving stock (Eq, Show)

serviceView ∷ StorageService → STM ServiceView
serviceView svc = do
  s ← readTVar (svState svc)
  a ← readTVar (svAdmission svc)
  let needsEviction j = case dispatchCredits j of
        Just (cls, credits) → case A.reserve cls credits a of
          Right (g, _) → not (null (A.grantEvicted g))
          Left _ → False
        Nothing → False
      queuedIds = concatMap toList (Map.elems (stQueue s))
      waiting = length [() | jid ← queuedIds, Just j ← [Map.lookup jid (stJobs s)], needsEviction j]
  pure ServiceView
    { svQueued = sum (map Seq.length (Map.elems (stQueue s)))
    , svRunning = stRunning s
    , svRecords = Map.size (stJobs s)
    , svBackings = Map.size (stBackings s)
    , svMutating = isJust (stMutation s)
    , svReserved = stReserved s
    , svDefect = stDefect s
    , svWaitingForCache = waiting
    }

-- ---------------------------------------------------------------------------
-- The snapshot the invariants are checked against

data JobKind = KOpen | KRead !Int | KWrite | KGrow | KGrowNoop | KAbandon | KReleasePending
  deriving stock (Eq, Show)

data SlotTag = SlotIdle | SlotRunning | SlotPrepared | SlotReleasing
  deriving stock (Eq, Show)

-- | One job record, as the invariants need it.
data JobSnap = JobSnap
  { jsId ∷ !Word64
  , jsKind ∷ !JobKind
  , jsPhase ∷ !Int
  -- ^ 0 queued, 1 running, 2 finished
  , jsBacking ∷ !(Maybe Word64)
  , jsBorrowed ∷ !Int
  , jsPrepared ∷ !(Maybe Word64)
  -- ^ A finished growth's untaken preparation: the backing it prepared.
  , jsHoldsResult ∷ !Bool
  -- ^ A finished read that still holds its bytes.
  , jsCharge ∷ !Word64
  -- ^ What the job's record is charged to the control account ('jobCharge').
  , jsDelivered ∷ !Bool
  }
  deriving stock (Eq, Show)

-- | One tracked backing.
data BackingSnap = BackingSnap
  { bsId ∷ !Word64
  , bsSlot ∷ !SlotTag
  , bsPending ∷ !(Maybe Word64)
  , bsLength ∷ !Word64
  , bsVolume ∷ !Word64
  , bsBorrows ∷ !Int
  , bsClosing ∷ !Bool
  }
  deriving stock (Eq, Show)

-- | The whole service state at one instant, read in one transaction.
data Snapshot = Snapshot
  { snJobs ∷ ![JobSnap]
  , snBackings ∷ ![BackingSnap]
  , snClosing ∷ !Int
  , snClosingRecs ∷ ![BackingSnap]
  -- ^ The closing records, each with what it still pays for.
  , snWorkers ∷ !Int
  , snAdmissionOpen ∷ !Bool
  , snStopReason ∷ !(Maybe Text)
  , snEvidence ∷ !Int
  , snEvidenceDropped ∷ !Int
  , snReserved ∷ !(Map Word64 Word64)
  , snQueued ∷ !Int
  , snRunning ∷ !Int
  , snMutation ∷ !(Maybe Word64)
  , snBusyVolumes ∷ !Int
  -- ^ The volumes a worker holds for a reservation right now (at most one per worker).
  }
  deriving stock (Show)

snapshotOf ∷ StorageService → STM Snapshot
snapshotOf svc = do
  s ← readTVar (svState svc)
  let kindOf w = case w of
        WOpen _ → KOpen
        WRead (ReadSpec _ _ n _) → KRead n
        WWrite _ → KWrite
        WGrow (GrowSpec f t) → if f == t then KGrowNoop else KGrow
        WRelease _ _ (Just _) → KAbandon
        WRelease _ _ Nothing → KReleasePending
      jobSnap (jid, j) =
        JobSnap
          { jsId = jid
          , jsKind = kindOf (jWork j)
          , jsPhase = case jPhase j of JQueued → 0; JRunning → 1; JDone _ → 2
          , jsBacking = jBacking j
          , jsBorrowed = jBorrowed j
          , jsPrepared = case jPhase j of JDone (GrowthPrepared p _) → Just (pgBacking p); _ → Nothing
          , jsHoldsResult = case jPhase j of JDone (Pages _) → True; _ → False
          , jsCharge = jobCharge (jWork j)
          , jsDelivered = jDelivered j
          }
      slotTag g = case g of GIdle → SlotIdle; GRunning → SlotRunning; GPrepared _ → SlotPrepared; GReleasing _ → SlotReleasing
      backingSnap (bid, e) = BackingSnap bid (slotTag (eGrowth e)) (ePending e) (eLength e) (eVolume e) (eBorrows e) (ePhase e /= EOpen)
  pure Snapshot
    { snJobs = map jobSnap (Map.toList (stJobs s))
    , snBackings = map backingSnap (Map.toList (stBackings s))
    , snClosing = Map.size (stClosingRecs s)
    , snClosingRecs = [backingSnap (bid, e) | (bid, CrNative e) ← Map.toList (stClosingRecs s)]
    , snWorkers = stWorkers s
    , snAdmissionOpen = stPhase s == Running
    , snStopReason = stStopReason s
    , snEvidence = length (stEvidence s)
    , snEvidenceDropped = stEvidenceDropped s
    , snReserved = stReserved s
    , snQueued = sum (map Seq.length (Map.elems (stQueue s)))
    , snRunning = stRunning s
    , snMutation = stMutation s
    , snBusyVolumes = Set.size (stBusyVolumes s)
    }
