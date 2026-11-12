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
  , Backing
  , backingIdentity
  , Ticket
  , PreparedGrowth
  , preparedFrom
  , preparedTo
  , preparedAllocated

    -- * Jobs
  , OpenSpec (..)
  , ReadMode (..)
  , StagedWrite
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
  , ServiceView (..)
  , serviceView
  , jobRecordBytes
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
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Unsafe as BSU
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
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
import Hetoimasia.Foundation.Resource (allocResource, composeCleanup)
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
jobRecordBytes = 2048

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
resultPageBytes = 4608

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
    WRelease !Word64 !Word64

-- | The class of work a job is, for scheduling and for the mutation slot.
workMutates ∷ Work → Bool
workMutates w = case w of
  WWrite _ → True
  WGrow _ → True
  WRelease _ _ → True
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

data Phase = Running | Closing | Stopped
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
  }

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
emptySt = St Running 1 1 Map.empty Map.empty Map.empty Nothing 0 (Fair 0 0) Set.empty Map.empty Nothing

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
startWorkers svc group = go (2 ∷ Int) []
  where
    go 0 acc = pure (reverse acc)
    go n acc = do
      r ← startWorker group (workerDef svc n)
      case r of
        Started w → go (n - 1) (w : acc)
        StartupFailed _ _ → abort acc "storage worker startup failed"
        StartRejected _ → abort acc "storage worker group is closed"
    abort acc why = do
      atomically (modifyTVar' (svState svc) (\s → s {stPhase = Stopped}))
      atomically (mapM_ requestStop acc)
      atomically (mapM_ awaitCompletion acc)
      throwIO (WorkerNotStarted why)

workerDef ∷ StorageService → Int → WorkerDefinition ()
workerDef svc n =
  workerDefinition
    (T.pack ("terrain-storage-io-" <> show n))
    (\_ → allocResource (seamBefore (svSeam svc) (OpWorkerStart n)) (\_ → pure ()))
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
  -- every record still in the table (an outcome nobody took, an opened backing nobody named) is retired once its
  -- borrowers have finished
  (late3, _) ← protectedly . atomically $ do
    s ← readTVar (svState svc)
    check (null [() | j ← Map.elems (stJobs s), jBorrowed j > 0])
    forM_ (Map.keys (stJobs s)) (retireJob svc)
  atomically (modifyTVar' (svState svc) (\s → s {stPhase = Stopped}))
  evidence ← sequence ([(,) "backing close" <$> evidenceOf (BackingCloseFailed (T.pack (show bid)) e) | (bid, (_, report)) ← zip entries closed, Just e ← [crCloseError report]]
    <> [(,) "backing close" <$> evidenceOf (BackingCloseRaised (T.pack (show bid)) t) | (bid, (_, report)) ← zip entries closed, Just t ← [crCloseException report]])
  pure (firstJust ([late0, late1, late2, late3] <> map fst closed), evidence)
  where
    firstJust xs = case [e | Just e ← xs] of
      (e : _) → Just e
      [] → Nothing

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
  modifyTVar' (svState svc) (\s → s {stPhase = Closing})
  withdrawWhere svc (const True)

-- | Complete the queued jobs a predicate names as cancelled, and discard them:
-- nothing is running for them, so nothing is in use.
withdrawWhere ∷ StorageService → (Job → Bool) → STM ()
withdrawWhere svc p = do
  s ← readTVar (svState svc)
  let queued = [(jid, j) | (jid, j) ← Map.toList (stJobs s), isQueued (jPhase j), p j]
  forM_ queued $ \(jid, _) → do
    dequeue svc jid
    void (finishJob svc jid (Cancelled []))
    retireJob svc jid
  -- running jobs of the predicate stop at their next safe point
  forM_ [jid | (jid, j) ← Map.toList (stJobs s), isRunning (jPhase j), p j] $ \jid →
    modifyTVar' (svState svc) (\t → t {stJobs = Map.adjust (\j → j {jCancel = True}) jid (stJobs t)})
  where
    isQueued JQueued = True
    isQueued _ = False
    isRunning JRunning = True
    isRunning _ = False

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
      charged ← withAdmission svc (\a → A.reserve A.Foreground [A.ControlCredit jobRecordBytes] a)
      case charged of
        Left r → pure (Left (mapRefusal r))
        Right grant → do
          let jid = stNextJob s
              job = Job (fmap (\(Backing _ bid _) → bid) mb) ident cls work JQueued False grant Nothing 0 False
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
          t ← admitJob svc (Just b) (backingIdentity b) MaintenanceWork (WRelease (pgFrom p) (pgTo p))
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
          t ← admitJob svc (Just b) (backingIdentity b) MaintenanceWork (WRelease (eCap e) (eCap e + extra))
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
withOutcome ∷ StorageService → Ticket → (Outcome → IO a) → IO (Maybe a)
withOutcome svc t body = mask $ \restore → do
  taken ← atomically $ do
    s ← readTVar (svState svc)
    case lookupTicket svc t s of
      Just (jid, j) | JDone o ← jPhase j → do
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
      r ← try (restore (body o))
      atomically $ do
        modifyTVar' (svState svc) $ \st →
          st
            { stJobs = Map.adjust (\x → x {jBorrowed = jBorrowed x - 1}) jid (stJobs st)
            , stBackings = adjustBorrow (backingOfJob st jid) (-1) (stBackings st)
            }
        retireJob svc jid
      case r of
        Right x → pure (Just x)
        Left (e ∷ SomeException) → throwIO e
  where
    backingOfJob st jid = Map.lookup jid (stJobs st) >>= jBacking

adjustBorrow ∷ Maybe Word64 → Int → Map Word64 Entry → Map Word64 Entry
adjustBorrow Nothing _ m = m
adjustBorrow (Just bid) d m = Map.adjust (\e → e {eBorrows = eBorrows e + d}) bid m

-- | Give up a job's outcome. A finished job is retired (its record and bytes
-- released, and an opened backing it never delivered is closed). A queued job is
-- cancelled. A running job is asked to stop and retired when it ends.
discardTicket ∷ StorageService → Ticket → IO ()
discardTicket svc t = do
  opened ← atomically $ do
    s ← readTVar (svState svc)
    case lookupTicket svc t s of
      Nothing → pure Nothing
      Just (jid, j) → case jPhase j of
        JDone o | jBorrowed j == 0 → do
          retireJob svc jid
          pure (case o of Opened (Backing _ bid _) _ → Just bid; _ → Nothing)
        JDone _ → pure Nothing
        JQueued → do
          dequeue svc jid
          void (finishJob svc jid (Cancelled []))
          retireJob svc jid
          pure Nothing
        JRunning → do
          -- the holder gives the outcome up: the job stops at its next safe point and is retired when it ends
          modifyTVar' (svState svc) (\st → st {stJobs = Map.adjust (\x → x {jCancel = True, jDiscard = True}) jid (stJobs st)})
          pure Nothing
  forM_ opened (void' . closeBackingId svc)
  where
    void' = (>>= \_ → pure ())

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
        dequeue svc jid
        void (finishJob svc jid (Cancelled []))
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
      let j' = j {jPhase = JDone outcome, jDispatch = if holdsResult outcome then jDispatch j else Nothing}
      writeTVar (svState svc) s
        { stJobs = Map.insert jid j' (stJobs s)
        , stRunning = if isRunningPhase (jPhase j) then stRunning s - 1 else stRunning s
        , stMutation = if stMutation s == Just jid then Nothing else stMutation s
        }
      -- a ticket discarded while the job ran: nobody will take the outcome, so it is retired here, and
      -- a backing it opened (which nobody can name) is for the worker to close
      if jDiscard j
        then do
          retireJob svc jid
          pure (case outcome of Opened (Backing _ bid _) _ → Just bid; _ → Nothing)
        else pure Nothing
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

workerLoop ∷ StorageService → StopToken → IO ()
workerLoop svc token = mask $ \restore → loop restore
  where
    loop restore = do
      next ← restore (atomically ((Just <$> dispatchNext svc) `orElse` (awaitStopRequest token >> pure Nothing)))
      case next of
        Nothing → pure ()
        Just jid → runJob svc jid >> loop restore

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
      r ← try (execute svc jid j)
      case r of
        Right outcome → do
          toClose ← atomically (finishJob svc jid outcome)
          forM_ toClose (void . closeBackingId svc)
        Left (e ∷ SomeException) → do
          let why = T.pack (show e)
          logError (svLogger svc) component "Storage worker defect" [("defect", why)]
          atomically $ do
            void (finishJob svc jid (Failed (HostFailure why) []))
            modifyTVar' (svState svc) (\s → s {stDefect = Just why, stPhase = Stopped})
            closeAdmission svc
          throwIO e

cancelled ∷ StorageService → Word64 → IO Bool
cancelled svc jid = atomically (maybe False jCancel . Map.lookup jid . stJobs <$> readTVar (svState svc))

execute ∷ StorageService → Word64 → Job → IO Outcome
execute svc jid j = case jWork j of
  WOpen spec → execOpen svc jid spec
  WRead spec → execRead svc jid j spec
  WWrite w → execWrite svc jid j w
  WGrow (GrowSpec from to) → execGrow svc jid j from to
  WRelease from to → execRelease svc j from to

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
    created ← createPrivate seam (osDirectory spec) unique
    case created of
      Left f → pure (Failed (StorageIo f) [])
      Right c → do
        owned ← newIORef (0 ∷ Int)
        r ← tryWithContext (afterCreate c owned)
        case r of
          Right o → pure o
          Left ewc → do
            state ← readIORef owned
            -- an exception: the descriptor is closed here unless the table already owns it; the name is
            -- unlinked again if it still exists (a second unlink finding none is not a failure)
            -- 0: still ours; 1: the table owns it; 2: its close was already attempted (never repeated)
            notes ← if state /= 0 then pure [] else unwind owned c True
            evidence ← sequence [(,) "open cleanup" <$> evidenceOf (OpenCleanupFailed op e) | CleanupNote op e ← notes, e /= Errno 2]
            final ← composeCleanup (Just ewc) evidence
            rethrowIO (fromMaybe ewc final)
  where
    seam = svSeam svc
    cfg = osConfig spec
    allowance = cfgAllowanceBytes cfg
    -- every failure after the file exists closes the descriptor (which releases
    -- everything it obtained) and keeps what the cleanup could not do
    unwind owned c named = do
      notes1 ← if named then retryUnlink c else pure []
      -- recorded BEFORE the close is attempted, so an exception from it can never lead to a second close
      writeIORef owned 2
      notes2 ← closeNote c
      pure (notes1 <> notes2)
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
                  logInfo (svLogger svc) component "Backing opened" [("backing", T.pack (show b)), ("allocated", T.pack (show (rvAllocated rv)))]
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
          released ← try (releaseExtra seam (eFd e) from to)
          case either (\(_ ∷ SomeException) → Left (Errno 0)) id released of
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
              , stReserved = Map.adjust (\n → n - min n (to - from)) (eVolume e) (stReserved s)
              }
          pure Released
        Right (Left err) → do
          atomically (pendAgain bid)
          pure (Failed (StorageIo (IoFailure IoSetLength (IoErrno err) Nothing Nothing 0 0)) [CleanupNote IoSetLength err])
  where
    pendAgain bid = modifyTVar' (svState svc) $ \s →
      s {stBackings = Map.adjust (\x → x {eGrowth = GIdle, ePending = Just (to - from)}) bid (stBackings s)}

-- ---------------------------------------------------------------------------
-- Scoped use and closing

-- | Borrow a backing for the duration of an action: a close waits for the
-- borrower. The owner holds one for each live reader pin. A closed backing
-- refuses.
withUse ∷ StorageService → Backing → IO a → IO (Either StorageFailure a)
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
      r ← try (restore act)
      atomically (modifyTVar' (svState svc) (\s → s {stBackings = Map.adjust (\e → e {eBorrows = eBorrows e - 1}) bid (stBackings s)}))
      case r of
        Right x → pure (Right x)
        Left (ex ∷ SomeException) → throwIO ex

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

closeBackingId ∷ StorageService → Word64 → IO CloseReport
closeBackingId svc bid = do
  (late, report) ← closeBackingCore svc bid
  forM_ late rethrowIO
  pure report

-- | The close, returning an interruption it remembered instead of obeying, for
-- the caller to deliver once the descriptor is closed.
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
          r ← try (uninterruptibleMask_ (closeFile (svSeam svc) (eFd e)))
          let (err, thrown) = case r of
                Right (Left en) → (Just en, Nothing)
                Right (Right ()) → (Nothing, Nothing)
                Left (ex ∷ SomeException) → (Nothing, Just (T.pack (show ex)))
          forM_ err $ \(Errno n) → logWarning (svLogger svc) component "Backing close failed" [("errno", T.pack (show n))]
          forM_ thrown $ \t → logWarning (svLogger svc) component "Backing close raised" [("exception", t)]
          logInfo (svLogger svc) component "Backing closed" [("backing", T.pack (show bid))]
          pure (late, CloseReport True err (ePending e) thrown)
        _ → pure (late, noClose)
  where
    claim b = do
      s ← readTVar (svState svc)
      case Map.lookup b (stBackings s) of
        Nothing → pure Nothing
        Just e → do
          let active = [() | j ← Map.elems (stJobs s), jBacking j == Just b, activePhase (jPhase j) || jBorrowed j > 0]
          check (null active && eBorrows e == 0)
          forM_ [jid | (jid, j) ← Map.toList (stJobs s), jBacking j == Just b] (retireJob svc)
          releaseGrant svc (eGrant e)
          modifyTVar' (svState svc) $ \t →
            t { stBackings = Map.delete b (stBackings t)
              , stReserved = Map.adjust (\n → n - min n (eLength e)) (eVolume e) (stReserved t)
              }
          pure (Just e)
    activePhase JQueued = True
    activePhase JRunning = True
    activePhase (JDone _) = False

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
  }
  deriving stock (Eq, Show)

serviceView ∷ StorageService → STM ServiceView
serviceView svc = do
  s ← readTVar (svState svc)
  pure ServiceView
    { svQueued = sum (map Seq.length (Map.elems (stQueue s)))
    , svRunning = stRunning s
    , svRecords = Map.size (stJobs s)
    , svBackings = Map.size (stBackings s)
    , svMutating = isJust (stMutation s)
    , svReserved = stReserved s
    , svDefect = stDefect s
    }
