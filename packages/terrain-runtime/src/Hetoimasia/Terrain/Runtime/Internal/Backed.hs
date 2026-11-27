-- | The terrain owner's backed work (TRA-22): opening an arena (compilation, reservation),
-- pinned reads of removed runs (a request's staging, a load job's detail), the session's one
-- mutating transaction and the drain and close of a closed arena's file.
--
-- == One step at a time
--
-- Every function here is ONE bounded step the owner takes between its waits, called MASKED:
-- it reads the state in one transaction, performs at most one effect of the storage backend
-- (a submission, the taking of an outcome, a cancellation, the one native close) or one pure
-- quantum (a compilation quantum, a planner run), and records the result in the next
-- transaction. Neither transaction blocks, so no asynchronous exception can arrive between an
-- effect and its record. A step never waits: what it waits for is its task's 'Wake', which
-- the owner composes with every other source in its one selection transaction.
--
-- == Ownership
--
-- Each task is a record in the service state ('OpenTask', 'GatherTask', 'SlotTask',
-- 'Closing''). A task whose request or arena has ended is not dropped: it is drained (its job
-- cancelled and waited for, its pin released, its credits returned, a backing an open made
-- anyway closed) and only then removed, so nothing the backend holds for it is orphaned.
module Hetoimasia.Terrain.Runtime.Internal.Backed
  ( -- * Configuration
    gathersPerArena
  , internalTurn
  , internalPlace

    -- * What the owner supplies
  , OwnerOps (..)

    -- * The edit bank
  , pinCredits
  , releaseCredit

    -- * Opening
  , beginOpen
  , stepOpen
  , openOrderAllows
  , openReady
  , preparePalette

    -- * Gathers
  , Gathered (..)
  , ReadWhat (..)
  , canStartGather
  , sameCommittedSTM
  , CommittedMovedOutsideDecision (..)
  , editBankChecked
  , removalStagingParts
  , removalStagingChecked
  , queryKeepChecked
  , keptPinLimit
  , pressureMark
  , markOf
  , notePressure
  , pressureChanged
  , startGatherFor
  , stepGatherTask

    -- * The slot
  , Contender (..)
  , contenders
  , grantSlot
  , stepSlot
  , SlotEnd (..)

    -- * Pause
  , pauseArena

    -- * Closing
  , drainReady
  , closeDrained

    -- * The oracle
  , backedInvariants

    -- * Shared
  , closingOf
  , storeOfArena
  , changeLimitsOf
  , changesOfRuns
  ) where

import Control.Concurrent.STM
import Control.Exception (Exception, evaluate, finally, uninterruptibleMask_)
import Control.Monad (foldM, forM_, void, when)
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Column (..), mkZRange)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), Changes, changeColumnBytes, changesFromReplacements, replacementRunBytes)
import qualified Hetoimasia.Terrain.Query as Q
import Hetoimasia.Terrain.Segment (decodedCellBytes, maxSegmentLevels, maxSegmentPayloadBytes)
import qualified Hetoimasia.Terrain.Connectivity as C
import Hetoimasia.Terrain.Coordinate (RegionCoord, TileCoord)
import qualified Hetoimasia.Terrain.Discovery as D
import qualified Hetoimasia.Terrain.Residency as R
import Hetoimasia.Terrain.Residency (ArenaId (..), RequestId, Revision (..))
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Fault
import Hetoimasia.Terrain.Runtime.Backed.Gather
import Hetoimasia.Terrain.Runtime.Backed.Query
import Hetoimasia.Terrain.Runtime.Backed.Probe
import Hetoimasia.Terrain.Runtime.Backed.RegionCopy (RegionCopy)
import Hetoimasia.Terrain.Runtime.Backed.Regional (BProgress (..), buildDraining, buildRegionsDone, cancelBuild, endBuild, startBuild, stepBuild)
import qualified Hetoimasia.Terrain.Runtime.Backed.Growth as Growth
import Hetoimasia.Terrain.Runtime.Backed.Txn (Done (..), Io (..), Progress (..))
import qualified Hetoimasia.Terrain.Runtime.Backed.Txn as Txn
import qualified Hetoimasia.Terrain.Runtime.Backed.WriteProbe as WriteProbe
import Hetoimasia.Terrain.Palette (Palette, PaletteError, emptyPalette, internSourceMaterials)
import Hetoimasia.Terrain.Runtime.Internal.Content (Prepared (..))
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Types hiding (OwnerPhase (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( Backing
  , Snapshot (..)
  , backingRecordBytes
  , keptEntryBytes
  , maxRecordControlBytes
  , resultPageBytes
  , transferBufferBytes
  , OpenSpec (..)
  , PreparedGrowth
  , ReadMode
  , awaitTicket
  , cancelTicket
  , closeBacking
  , discardTicket
  , pollTicket
  , submitOpen
  , withOutcome
  )
import qualified Hetoimasia.Terrain.Runtime.Storage.Internal.Service as Storage
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (IoFailure (..), IoOp (..), WorkClass (..))
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (Admission)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo, StoreIdentity (..), maxLevel)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (ActiveView (..), Condition (..), GrowthProposal, Store, activeView, storeConfig, TxnId, conditions, oldestPin, pauseFor, storeFromRoots, storeHeader, storeRoots, storeVersion)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Plan, RamCharge (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Protocol (discoveryPlanner, maintenancePlanner, removalPlanner)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (Roots (..), StoreConfig, emptyRoots, maxReaders, windowPageBytes)
import Hetoimasia.Terrain.Source (Source)

-- ---------------------------------------------------------------------------
-- Configuration

-- | The pinned reads one arena may have in flight: the readers per arena the edit bank was
-- validated for (at most the readers its store may pin), so the pins never pass what the bank's
-- proof counts.
gathersPerArena ∷ Config → Int
gathersPerArena config = fromInteger (min (toInteger maxReaders) (A.ebsReadersPerArena (configEditBank config)))

-- | The edit bank must also fund one read beside the worst transaction and every reader pin: the
-- storage service charges a read's result page to the cache and its transfer buffer to staging when
-- it dispatches the job (#663), beside what the transaction's grant and the pins already hold. Each
-- holder (a gather, the slot's transaction, a query or a probe) has at most one one-page read in
-- flight, so room for one read means some read can always be funded: a transaction and the pinned
-- reads never wait on each other. A bank at #662's own minimum (the transaction beside every pin,
-- nothing more) deadlocks the first time both read, so it is refused at construction.
--
-- The control account must also hold the storage service's own records at their most beside the
-- store's minimum (the worst transaction's control records, every reader record, the queued
-- descriptors): the service charges every job's record, every backing's and every kept failure to
-- that account, and the store's minimum counts none of them. Without that room a granted
-- transaction's write cannot be charged, or a removal is never granted. The spec's arenas are the
-- service's arena cap, which bounds its backings.
-- | What the staging a removal reserves for its whole life ('R.removalStagingBytes') holds, each part
-- at its bound: the decoded segment of its cell's column in its region ('decodedCellBytes' a cell over a
-- segment's levels), its rebuilt copy (a segment's worst-case payload, 'maxSegmentPayloadBytes'), the staged overlay (what its preparation keeps: the changes
-- read over the cell and its two neighbours, at most four runs of one column, and the working
-- run, one, each at the tagged run's figure 'replacementRunBytes') and the result settlement (a settled result's record).
removalStagingParts ∷ [(Text, Integer)]
removalStagingParts =
  [ ("decoded segment", decoded)
  , ("rebuilt copy", rebuilt)
  , ("staged overlay", column + 4 * interval + column + interval)
  , ("result settlement", toInteger resultRecordBytes)
  ]
  where
    decoded = toInteger decodedCellBytes * toInteger maxSegmentLevels
    rebuilt = toInteger maxSegmentPayloadBytes
    column = toInteger changeColumnBytes
    interval = toInteger replacementRunBytes

-- | The parts of a removal's staging fit the staging it reserves: refused at construction otherwise,
-- so the constant cannot drift below what it holds.
removalStagingChecked ∷ Either ConfigError ()
removalStagingChecked
  | need > toInteger R.removalStagingBytes = Left (ConfigRemovalStaging need (toInteger R.removalStagingBytes))
  | otherwise = Right ()
  where
    need = sum (map snd removalStagingParts)

editBankChecked ∷ A.EditBankSpec → Either ConfigError ()
editBankChecked spec
  | cacheNeed > A.ebsCache spec = Left (ConfigEditBankReads "cache" cacheNeed (A.ebsCache spec))
  | stagingNeed > A.ebsStaging spec = Left (ConfigEditBankReads "staging" stagingNeed (A.ebsStaging spec))
  | controlNeed > A.ebsControl spec = Left (ConfigEditBankReads "control" controlNeed (A.ebsControl spec))
  | otherwise = Right ()
  where
    w = A.worstTransactionCharge
    pins = A.ebsArenas spec * min (toInteger maxReaders) (A.ebsReadersPerArena spec)
    controlNeed = A.controlNeedOf spec + toInteger (maxRecordControlBytes (fromInteger (A.ebsArenas spec)))
    cacheNeed = toInteger (ramDecodedCopies w) + pins * toInteger A.readerPinnedCacheBytes + toInteger resultPageBytes
    stagingNeed = toInteger (ramIoBuffers w + ramKeys w + ramScratch w) + toInteger (transferBufferBytes 1)

-- | The fairness rule of the slot: while explicit work waits, internal work (discovery,
-- reclamation) gets one grant after every 'internalTurn' explicit grants.
internalTurn ∷ Int
internalTurn = 3

changeLimitsOf ∷ Config → ChangeLimits
changeLimitsOf config =
  ChangeLimits (fromInteger (min (toInteger (maxBound ∷ Int)) (toInteger (R.limitBytes (configLimits config) R.EditBank `div` fromIntegral replacementRunBytes))))

-- | What the owner supplies to the steps here: its staging (which tells the host), and its end
-- with a defect (which records it and reaches supervision).
data OwnerOps = OwnerOps
  { opsStage ∷ RequestId → Maybe ArenaId → Revision → StagedWork → IO ()
  , opsDefect ∷ ∀ a. Defect → IO a
  }

-- ---------------------------------------------------------------------------
-- The edit bank

-- | A gather's pin: the pages one reader may pin, charged to the cache account before the pin
-- is taken.
pinCredits ∷ ArenaId → [A.Credit]
pinCredits aid = [A.CacheCredit aid A.readerPinnedCacheBytes A.Backed True]

-- ---------------------------------------------------------------------------
-- Shared

-- | Whether the owner is closing an arena: a backing that closes or a service that stops is
-- then the owner's own doing, and a defect otherwise.
closingOf ∷ St → ArenaId → Closing
closingOf st aid
  | statePhase st == Closing = OwnerClosing
  | Map.member aid (stateClosing st) = OwnerClosing
  | otherwise = OwnerRunning

-- | The store and backing of an arena, live or closing.
storeOfArena ∷ St → ArenaId → Maybe (Store, Backing)
storeOfArena st aid = case Map.lookup aid (stateArenas st) of
  Just a → Just (arenaStore a, arenaBacking a)
  Nothing → (\c → (closingStore c, closingBacking c)) <$> Map.lookup aid (stateClosing st)

-- | Write an arena's store, live or closing.
-- | THE CHECK OF EVERY OTHER WRITER. Every write of an arena's store outside the publication
-- decision (a gather's pin and its release, the slot's admit/abort and growth state, a pause, a
-- retry's cleared conditions) keeps the committed roots and version: only 'decide' publishes (and an
-- open's adoption makes a new arena's FIRST root). A write that would move them is a defect, thrown
-- inside the owner's transaction before anything is written.
sameCommittedSTM ∷ ArenaId → St → Store → STM ()
sameCommittedSTM aid st new = forM_ (storeOfArena st aid) $ \(old, _) →
  when (storeRoots old /= storeRoots new || storeVersion old /= storeVersion new) $
    throwSTM (CommittedMovedOutsideDecision aid (storeVersion old) (storeVersion new))

-- | A store write outside the decision that would have moved the committed roots or version.
data CommittedMovedOutsideDecision = CommittedMovedOutsideDecision !ArenaId !Word64 !Word64
  deriving stock (Show)

instance Exception CommittedMovedOutsideDecision

putStore ∷ ArenaId → Store → St → St
putStore aid store st =
  st
    { stateArenas = Map.adjust (\a → a {arenaStore = store}) aid (stateArenas st)
    , stateClosing = Map.adjust (\c → c {closingStore = store}) aid (stateClosing st)
    }

-- | The replacements a gather read, air or a corner mask, as the pure terrain model's changes.
changesOfRuns ∷ Config → [GatherRun] → Either Text Changes
changesOfRuns _ runs = do
  replacements ← traverse replacement runs
  -- the read was funded for exactly these runs (its cap held at every step), and coalescing never adds one:
  -- the bound is theirs, not the edit staging's
  either (Left . Text.pack . show) Right (changesFromReplacements (ChangeLimits (length runs)) replacements)
  where
    replacement (column, lo, hi, tag) = either (Left . Text.pack . show) (\r → Right (column, r, tag)) (mkZRange (toInteger lo) (toInteger hi))

-- ---------------------------------------------------------------------------
-- Pause

-- | Record a pause of an arena (requirement 8): the store pauses new history for the
-- condition, the failure is ADDED to the condition's record for the creator's retry (every failing
-- operation and page, bounded; see 'FaultRecord'), and every uncommitted user mutation of the
-- arena settles once with the fault. The last committed roots, terrain, knowledge and frontier are
-- untouched. A failure the record already holds adds nothing and moves no generation.
pauseArena ∷ Service → ArenaId → Condition → StorageFault → STM ()
pauseArena svc aid condition fault = do
  st ← readSt svc
  forM_ (Map.lookup aid (stateArenas st)) $ \arena → do
    let entries = faultEntriesOf fault
        old = Map.lookup condition (arenaFaults arena)
        kept = maybe [] faultEntries old
        fresh = [e | e ← entries, e `notElem` kept]
        merged = take faultPagesKept (kept <> fresh)
        -- a failure with no page, or one past the bound, cannot be re-tested
        incomplete = maybe False faultIncomplete old || null entries || length (kept <> fresh) > faultPagesKept
        added = maybe True (\r → not (null fresh) || (incomplete && not (faultIncomplete r))) old
        epoch = stateFaultEpoch st + 1
        record = case old of
          Just r | not added → r {faultEvents = faultEvents r + 1}
          Just r → r {faultEntries = merged, faultIncomplete = incomplete, faultGeneration = epoch, faultEvents = faultEvents r + 1}
          Nothing → FaultRecord fault merged incomplete epoch 1
    sameCommittedSTM aid st (pauseFor condition (arenaStore arena))
    modifySt svc $ \s →
      s
        { stateArenas =
            Map.insert
              aid
              arena
                { arenaStore = pauseFor condition (arenaStore arena)
                , arenaFaults = Map.insert condition record (arenaFaults arena)
                }
              (stateArenas s)
        , stateFaultEpoch = if added then epoch else stateFaultEpoch s
        }
    forM_ [rid | (rid, req) ← Map.toList (stateRequests st), reqArena req == Just aid, isPendingRemoval req] $ \rid →
      terminate svc rid (Failed (StorageFailed fault))
  where
    -- what failed where: an I/O failure names its operation, an integrity failure is a read
    faultEntriesOf = \case
      FaultIo io → [FaultEntry op page | Just page ← [ioPage io], Just op ← [opOf (ioOp io)]]
      other → [FaultEntry FaultRead page | page ← faultPages other]
    opOf = \case
      IoRead → Just FaultRead
      IoWrite → Just FaultWrite
      _ → Nothing
    isPendingRemoval req = case (reqCmd req, reqPhase req) of
      (CRemove {}, Done) → False
      (CRemove {}, _) → True
      _ → False

-- ---------------------------------------------------------------------------
-- Opening

-- | Begin an open: it waits for the session's one compilation.
beginOpen ∷ Service → RequestId → Source → StoreConfig → STM ()
beginOpen svc rid source store =
  modifySt svc (\st → if Map.member rid (stateOpens st) then st else st {stateOpens = Map.insert rid (OpenTask source store OpenQueued) (stateOpens st)})

-- | Opens publish in the order their incarnations were allocated (the accounting model's
-- incarnations increase): an open waits while an earlier one is still being prepared.
openOrderAllows ∷ St → ArenaId → Bool
openOrderAllows st aid =
  null
    [ ()
    | task ← Map.elems (stateOpens st)
    , Just other ← [openArenaOf (openPhase task)]
    , other < aid
    ]
  where
    openArenaOf = \case
      OpenReserving a _ _ _ _ _ → Just a
      OpenPublishable a _ _ _ _ → Just a
      OpenQueued → Nothing
      OpenCompiling {} → Nothing
      OpenSubmitting a _ _ _ _ _ → Just a
      OpenUnwinding {} → Nothing

-- | An open whose file is reserved and whose store is ready, waiting for its publication: what
-- the open's commit installs.
openReady ∷ St → RequestId → Maybe (ArenaId, D.Env, Word64, Backing, Store)
openReady st rid = case openPhase <$> Map.lookup rid (stateOpens st) of
  Just (OpenPublishable aid env shared backing store) → Just (aid, env, shared, backing, store)
  _ → Nothing

-- | AN OPEN'S PALETTE IS PREPARED OUTSIDE EVERY TRANSACTION: the source's materials interned in
-- authored order, fully evaluated (a palette's fields are strict maps, so its weak head normal form is
-- the whole palette) on the owner, before the open is staged. The chooser and the arbitration read the
-- prepared value and intern nothing, so the commit's transaction does not grow with the definition and
-- cannot be kept restarting by a host whose own transactions outpace a long one. A source whose
-- materials do not fit a palette is prepared as that refusal, which the arbitration settles.
preparePalette ∷ Service → Source → IO (Either PaletteError Palette)
preparePalette svc source = do
  prepared ← evaluate (probeInterning (serviceProbe svc) (internSourceMaterials source emptyPalette))
  either (\_ → pure prepared) (\palette → prepared <$ evaluate palette) prepared

-- | One step of an open.
-- | What the storage service and the edit bank hold now (see 'PressureMark').
pressureMark ∷ Service → STM PressureMark
pressureMark svc = markOf <$> Storage.snapshotOf (serviceStorage svc) <*> (A.ledgers <$> readTVar (serviceEditBank svc))

-- | Every field the storage service's refusals for pressure read, and the edit bank's accounts:
--
-- * 'QueueFull': the queue's length;
-- * 'RecordsFull': the job records (each job's identity, kind, phase, untaken result and charge);
-- * 'MutationActive': the mutation in flight;
-- * 'GrowthActive': each backing's growth slot and pending extra;
-- * 'AccountPressure': the cache's backed, RAM-only and pinned bytes (eviction takes backed,
--   unpinned entries), staging's two classes and control, with every kind of record the service
--   charges to control (closing records, presecured opens, held closes, kept failures).
--
-- Job and backing identities are never reused.
markOf ∷ Storage.Snapshot → A.Ledger → PressureMark
markOf sn l =
  PressureMark $
    [fromIntegral (Storage.snQueued sn), fromIntegral (Storage.snRunning sn), maybe 0 (+ 1) (Storage.snMutation sn)]
      <> concat [[Storage.jsId j, kindCode (Storage.jsKind j), fromIntegral (Storage.jsPhase j), if Storage.jsHoldsResult j then 1 else 0, Storage.jsCharge j] | j <- Storage.snJobs sn]
      <> concat [[Storage.bsId b, slotCode (Storage.bsSlot b), maybe 0 (+ 1) (Storage.bsPending b)] | b <- Storage.snBackings sn]
      <> [fromIntegral (Storage.snClosing sn), fromIntegral (Storage.snClosingCharged sn), fromIntegral (length (Storage.snOpening sn)), fromIntegral (length (Storage.snHeld sn)), fromIntegral (Storage.snEvidence sn)]
      <> [A.lgCacheBacked l, A.lgCacheRamOnly l, A.lgCachePinned l, A.lgStagingForeground l, A.lgStagingCamera l, A.lgControlReserved l]
  where
    kindCode = \case
      Storage.KOpen → 0
      Storage.KRead n → 1 + 8 * fromIntegral n
      Storage.KWrite → 2
      Storage.KGrow → 3
      Storage.KGrowNoop → 4
      Storage.KAbandon → 5
      Storage.KReleasePending → 6
    slotCode = \case
      Storage.SlotIdle → 0
      Storage.SlotRunning → 1
      Storage.SlotPrepared → 2
      Storage.SlotReleasing → 3

-- | A caller was refused for the storage service's temporary pressure: no new storage work starts
-- until what the service and the edit bank hold has changed. Pressure is temporary only while
-- something in flight can change that: a job of the storage service, a pinned read, the slot's work
-- or an open's job (none of which the hold stops). With none, the refusal can never clear (the
-- control account held for good, by held closes): that is not pressure, and it is recorded as a
-- defect instead of holding the owner silently.
notePressure ∷ Service → STM ()
notePressure svc = do
  sn <- Storage.snapshotOf (serviceStorage svc)
  l <- A.ledgers <$> readTVar (serviceEditBank svc)
  st <- readSt svc
  let inFlight =
        not (null (Storage.snJobs sn))
          || not (Map.null (stateGathers st))
          || isJust (stateSlot st)
          || any (openWaits . openPhase) (Map.elems (stateOpens st))
          -- a closed arena whose file is still to close releases its backing's record when it does
          || not (Map.null (stateClosing st))
      openWaits = \case
        OpenReserving {} → True
        OpenUnwinding _ (Just _) _ → True
        _ → False
  if inFlight
    then pressureMark svc >>= \mark → modifySt svc (\s → s {stateStoragePressure = Just mark})
    else
      recordDefect svc . OwnerDefect . Text.pack $
        "the storage service refused work for pressure that nothing in flight can relieve (held closes: "
          <> show (length (Storage.snHeld sn))
          <> ", control reserved: "
          <> show (A.lgControlReserved l)
          <> ")"

-- | Wait until what the storage service and the edit bank hold differs from a mark.
pressureChanged ∷ Service → PressureMark → STM ()
pressureChanged svc mark = pressureMark svc >>= \now → check (now /= mark)

stepOpen ∷ Service → OwnerOps → RequestId → IO ()
stepOpen svc ops rid = do
  st ← atomically (readSt svc)
  let alive = Map.member rid (stateRequests st)
      config = serviceConfig svc
      limits = configConnectivity config
      peak = fromIntegral (C.limitPeakBytes limits) ∷ Word64
      setPhase task phase = modifySt svc (\s → s {stateOpens = Map.insert rid task {openPhase = phase} (stateOpens s)})
  forM_ (Map.lookup rid (stateOpens st)) $ \task → case openPhase task of
    OpenQueued
      | not alive → atomically (dropOpen svc rid 0)
      | stateCompiling st /= Nothing → pure ()
      | stateCompileUse st + peak > serviceCompileBank svc →
          -- the account is sized so that valid work never exhausts it: a charge that does not fit is a defect
          failOpen 0 (Text.pack ("the compile account cannot take a compilation's peak: " <> show (stateCompileUse st) <> " + " <> show peak <> " > " <> show (serviceCompileBank svc)))
      | otherwise → atomically $ do
          modifySt svc (\s → s {stateCompiling = Just rid, stateCompileUse = stateCompileUse s + peak})
          setPhase task (OpenCompiling (C.startPreparation limits (openSource task)) peak)
    OpenCompiling preparation held
      | not alive → atomically (dropOpen svc rid held)
      | otherwise →
          evaluate (C.resumePreparation (C.limitQuantumSteps limits) preparation) >>= \case
            Left why → failOpen held (Text.pack ("a compilation quantum was refused: " <> show why))
            Right (C.Pending next) → atomically (setPhase task (OpenCompiling next held))
            Right (C.Refused (C.Complexity refusal) _) → do
              let fault = FaultComplexity (Text.pack (show (C.refusedResource refusal))) (fromInteger (C.refusedNeeded refusal)) (fromInteger (C.refusedLimit refusal))
              atomically (dropOpen svc rid held >> terminate svc rid (Failed (StorageFailed fault)))
            Right (C.Refused other _) → failOpen held (Text.pack ("the source compiler refused a valid source: " <> show other))
            Right (C.Complete conn _) → do
              env ← evaluate (D.mkEnv (configDiscovery config) (openSource task) conn)
              let stats = C.connectivityStats conn
              shared ← evaluate (sharedCharge (C.statResultBytes stats) (C.statNodes stats))
              if toInteger shared /= D.envSharedBytes env
                then failOpen held (Text.pack ("the compile account's charge disagrees with #661's: " <> show shared <> " against " <> show (D.envSharedBytes env)))
              else if shared > perArenaShared limits
                then
                  -- what the arena would keep (its connectivity and every structure derived from it) passes
                  -- the per-arena bound of the compile account: the expected source_complexity, naming it
                  atomically (dropOpen svc rid held >> terminate svc rid (Failed (StorageFailed (FaultComplexity "compiled arena (connectivity and member index)" shared (perArenaShared limits)))))
                else atomically $ do
                  s ← readSt svc
                  let aid = ArenaId (stateNextArena s)
                      ident = StoreIdentity aid (stateNextSource s)
                  writeTVar (serviceState svc) s {stateNextArena = stateNextArena s + 1, stateNextSource = stateNextSource s + 1}
                  setPhase task (OpenSubmitting aid ident env shared held WakeNow)
    OpenSubmitting aid ident env shared held _
      | not alive → atomically (dropOpen svc rid held)
      | otherwise →
          submitOpen (serviceStorage svc) ExplicitWork (OpenSpec (serviceDirectory svc) ident (openStore task)) >>= \case
            Left failure → case classifyFailure OwnerRunning JkOpen failure of
              -- temporary pressure: the open keeps its place and its compiled result, and submits
              -- again once the storage service's capacity has changed
              HandleRetryLater _ → atomically $ do
                notePressure svc
                mark ← pressureMark svc
                setPhase task (OpenSubmitting aid ident env shared held (WakeOn (pressureChanged svc mark)))
              handling → finish held handling
            Right ticket → atomically $ do
              modifySt svc $ \s →
                s {stateCompiling = if stateCompiling s == Just rid then Nothing else stateCompiling s, stateCompileUse = stateCompileUse s - held + shared}
              setPhase task (OpenReserving aid ident env shared ticket (WakeOn (awaitTicket (serviceStorage svc) ticket)))
    OpenReserving aid ident env shared ticket _
      | not alive → do
          _ ← cancelTicket (serviceStorage svc) ticket
          atomically (setPhase task (OpenUnwinding shared (Just ticket) (WakeOn (awaitTicket (serviceStorage svc) ticket))))
      | otherwise → do
          finished ← atomically (pollTicket (serviceStorage svc) ticket)
          when finished $
            withOutcome (serviceStorage svc) ticket (\outcome → evaluate $! reactTo OwnerRunning JkOpen outcome) >>= \case
              Just (GotBacking backing _) → do
                store ← evaluate (initialStore config aid ident (openStore task))
                -- the arena's palette is interned here, before the open is staged: its commit only installs it
                palette ← preparePalette svc (openSource task)
                atomically (setPhase task (OpenPublishable aid env shared backing store))
                probePoint (serviceProbe svc) (PointPrepared rid)
                -- the open is staged: the host is told, and its commit installs the arena
                opsStage ops rid Nothing (Revision (configFirstRevision config)) (StagedOpen palette)
              Just (GotFailure handling _) → finish shared handling
              Just (GotCancelled _) → finish shared (classifyUnaskedCancel OwnerRunning)
              Just (GotMismatch why) → failOpen shared why
              Just other → failOpen shared (Text.pack ("an open answered " <> show other))
              Nothing → failOpen shared "a finished open named a ticket the service does not hold"
    OpenPublishable _ _ shared backing _
      | alive → pure ()
      | otherwise → do
          -- the request ended before its commit: the reserved file is closed, nothing is published
          _ ← closeBacking (serviceStorage svc) backing
          atomically (dropOpen svc rid shared)
    OpenUnwinding shared ticket _ → case ticket of
      Nothing → atomically (dropOpen svc rid shared)
      Just t → do
        finished ← atomically (pollTicket (serviceStorage svc) t)
        when finished $ do
          late ← withOutcome (serviceStorage svc) t (\outcome → evaluate $! reactTo OwnerClosing JkOpen outcome)
          case late of
            Just (GotBacking backing _) → void (closeBacking (serviceStorage svc) backing)
            Just _ → pure ()
            Nothing → discardTicket (serviceStorage svc) t
          atomically (dropOpen svc rid shared)
  where
    failOpen held why = do
      atomically (dropOpen svc rid held >> terminate svc rid (Failed (HostFailure why)))
      opsDefect ops (OwnerDefect why)
    finish held handling = case handling of
      HandleDomain fault → atomically (dropOpen svc rid held >> terminate svc rid (Failed (StorageFailed fault)))
      HandlePause _ fault → atomically (dropOpen svc rid held >> terminate svc rid (Failed (StorageFailed fault)))
      HandleClosing → atomically (dropOpen svc rid held)
      HandleDefect why → failOpen held why
      HandlePausedFor _ → failOpen held "an open answered a pause"
      -- an open's job secures its backing's record while it runs, so its outcome can carry pressure
      -- for the control account. On a bank the service accepts that needs held closes to have taken
      -- the room (nothing in flight returns it): a recorded defect, naming them, never a wait
      HandleRetryLater busy → do
        heldCloses ← length . Storage.snHeld <$> atomically (Storage.snapshotOf (serviceStorage svc))
        failOpen held (Text.pack ("an open's job was refused for pressure while it ran (" <> show busy <> "), which only held closes can cause (held closes: " <> show heldCloses <> ")"))
      HandleSerialize → failOpen held "an open was serialised"
      HandleReplan → failOpen held "an open answered replan"
      HandleWaitReclaim _ _ → failOpen held "an open answered reclamation"
      HandleExhausted → failOpen held "an open answered an exhausted revision"

-- | End an open's task: its compile charge and the session's compilation return.
dropOpen ∷ Service → RequestId → Word64 → STM ()
dropOpen svc rid held = do
  modifySt svc $ \s →
    s
      { stateOpens = Map.delete rid (stateOpens s)
      , stateCompiling = if stateCompiling s == Just rid then Nothing else stateCompiling s
      , stateCompileUse = stateCompileUse s - min held (stateCompileUse s)
      }
  markFreed svc

-- | A new arena's store: empty roots, its content, knowledge and store revisions starting at the
-- configured first revision. The roots are the store's own empty roots with only the header's
-- authority set ('storeFromRoots' checks nothing, and nothing here needs checking: no page exists).
initialStore ∷ Config → ArenaId → StoreIdentity → StoreConfig → Store
initialStore config aid ident cfg =
  let first = Revision (configFirstRevision config)
      roots = emptyRoots aid
   in storeFromRoots cfg ident roots {rHeader = (rHeader roots) {D.hAuthority = D.Authority aid first first first}}

-- ---------------------------------------------------------------------------
-- Gathers

-- | How a gather ended, for its owner. Its pin and credit are already released.
data Gathered
  = -- | Every run of the columns, read from one committed version, with that version's
    -- content revision.
    GatheredRuns ![GatherRun] !Revision !(Int, Int, Int, [(Column, Int64, Int64)])
  | -- | What is known of the cell, read from one committed version, with its content and knowledge revisions.
    GatheredKnowledge !D.CellKnowledge !Revision !Revision
  | -- | A retry's probe: the conditions it was for, and whether every recorded page read back as it must.
    GatheredProbe ![Condition] !Bool !CreatorBasis
  | -- | A regional snapshot's copied regions, read from one committed version, with that version's content
    -- and knowledge revisions and the residency generation read when it was pinned.
    GatheredRegions ![(RegionCoord, RegionCopy)] !Revision !Revision !Word64
  | GatheredFailed !Handling
  | -- | Cancelled and drained: nothing to deliver.
    GatheredNothing

-- | Whether a gather for an arena can start now: the arena is live, it has a pin to spare,
-- and the edit bank grants the pin's credit.
canStartGather ∷ Int → St → Admission → ArenaId → Bool
canStartGather cap st adm aid =
  Map.member aid (stateArenas st)
    && length [() | t ← Map.elems (stateGathers st), gatherArena t == aid] < cap
    && either (const False) (const True) (A.reserve A.Foreground (pinCredits aid) adm)

-- | Start a gather of some columns: the pin's credit is secured BEFORE the pin is taken; no
-- credit, no pin. False when nothing was started.
-- | What a pinned read reads.
data ReadWhat
  = -- | The columns' runs over their ranges, keeping at most this many (a load: 'maxBound').
    ReadRuns ![(Column, Int64, Int64)] !Int
  | ReadKnowledge !TileCoord
  | -- | a retry's probe, with the allowance and growth state its preparation read
    ReadPages ![(PageNo, ReadMode)] ![Condition] !CreatorBasis
  | -- | a regional snapshot's build of these regions
    ReadRegions ![RegionCoord]

startGatherFor ∷ Service → GatherFor → ArenaId → ReadWhat → STM Bool
startGatherFor svc key aid what = do
  st ← readSt svc
  adm ← readTVar (serviceEditBank svc)
  case Map.lookup aid (stateArenas st) of
    Just arena
      | not (Map.member key (stateGathers st))
      , canStartGather (gathersPerArena (serviceConfig svc)) st adm aid
      , Right (grant, adm') ← A.reserve A.Foreground (pinCredits aid) adm
      , Right (store', run) ← begin arena → do
          sameCommittedSTM aid st store'
          writeTVar (serviceEditBank svc) adm'
          writeTVar (serviceState svc) (putStore aid store' st) {stateGathers = Map.insert key (GatherTask aid run grant (arenaRevision arena) (D.authKnowledge (arenaAuthority arena)) (arenaGeneration arena) WakeNow) (stateGathers st)}
          pure True
    _ → pure False
  where
    begin arena = case what of
      ReadRuns columns cap → fmap RunsRead <$> startGatherCapped (keptPinLimit cap (length columns)) cap (arenaStore arena) columns
      ReadKnowledge tile → fmap KnowledgeRead <$> startQuery (arenaStore arena) (\provider → D.queryCell (arenaEnv arena) provider tile)
      ReadPages pages conds basis → Right (arenaStore arena, ProbeRead (startProbe pages) conds basis)
      -- ONE ROOT: the build's pin, and the revisions and the generation its snapshot is labelled with, are
      -- taken in this one transaction
      ReadRegions regions → fmap RegionalRead <$> startBuild (arenaStore arena) (arenaEnv arena) regions

-- | WHAT A READ KEEPS IS CONTAINED IN ITS PIN CREDIT: a gather that may keep @cap@ runs of @columns@
-- columns pins at most the reader's pin credit less those runs' bytes (by "Hetoimasia.Terrain.Changes"'s
-- tagged-run figures), in window pages, so its pinned pages and its kept runs never pass the one credit it holds
-- for its whole life. A load ('maxBound') keeps its runs in the scratch its job reserves: it pins the
-- whole credit.
keptPinLimit ∷ Int → Int → Int
keptPinLimit cap columns
  | cap == maxBound = gatherPinLimit
  | otherwise = (fromIntegral A.readerPinnedCacheBytes - keptRunsBytes cap columns) `div` windowPageBytes

-- | The bytes @cap@ runs of @columns@ columns hold, at most.
keptRunsBytes ∷ Int → Int → Int
keptRunsBytes cap columns = cap * replacementRunBytes + columns * changeColumnBytes

-- | The pages one step of a ranged read needs in its window: a path from the root to a leaf (the tree is
-- at most 'maxLevel' + 1 levels) and, when the landing validates its neighbours, the leaves on either side of
-- the target, which need not share a parent.
readStepPages ∷ Int
readStepPages = maxLevel + 3

-- | The query limits leave every read kind the pages one read step needs beside what it keeps: the
-- worst kind (a column query, or a surface's window, over the range limit: 'rangeKeep' of it) is
-- refused at construction otherwise.
queryKeepChecked ∷ Config → Either ConfigError ()
queryKeepChecked config
  | kept > allowed = Left (ConfigQueryKeep kept allowed)
  | otherwise = Right ()
  where
    -- in 'Integer': the public range limit is never multiplied in a fixed width, and the load's
    -- unbounded cap is not this check's
    kept = max 0 (toInteger (Q.limitRangeLevels (configQueryLimits config))) * toInteger replacementRunBytes + toInteger changeColumnBytes
    allowed = toInteger A.readerPinnedCacheBytes - toInteger readStepPages * toInteger windowPageBytes

-- | One step of a pinned read. When it ends, its pin and credit are released in the transaction
-- that removes it, and then its owner is given the result.
stepGatherTask ∷ Service → GatherFor → (Gathered → IO ()) → IO ()
stepGatherTask svc key deliver = do
  st ← atomically (readSt svc)
  forM_ (Map.lookup key (stateGathers st)) $ \task →
    forM_ (storeOfArena st (gatherArena task)) $ \(store, backing) → do
      let aid = gatherArena task
          io = Io (serviceStorage svc) backing ExplicitWork
          wanted = ownerAlive st && Map.member aid (stateArenas st)
          closing = closingOf st aid
      (run, progress) ← case gatherRun task of
        RunsRead g → do
          (g', p) ← if wanted then stepGather io closing store g else cancelGather io g
          case (key, gatherFetching g') of
            (GatherRequest rid, Just page) | gatherFetching g /= Just page → probePoint (serviceProbe svc) (PointGatherPage rid page)
            _ → pure ()
          pure
            ( RunsRead g'
            , case p of
                GMore → Left WakeNow
                GBlocked wait → Left (WakeOn wait)
                GDone runs → Right (GatheredRuns runs (gatherRevision task) (gatherPeakWindow g', gatherPin g', gatherCap g', gatherAsked g'))
                GFailed handling → Right (GatheredFailed handling)
                GDrained → Right GatheredNothing
            )
        ProbeRead pr conds basis → do
          (pr', p) ← if wanted then stepProbe io closing (storeConfig store) pr else cancelProbe io pr
          pure
            ( ProbeRead pr' conds basis
            , case p of
                PMore → Left WakeNow
                PBlocked wait → Left (WakeOn wait)
                PPassed → Right (GatheredProbe conds True basis)
                -- the cause the probe re-tests persists: the retry answers it as remaining (nothing new is
                -- recorded). Anything else keeps its own classification: temporary pressure, a defect,
                -- a closure, or a failure of another cause, which is recorded as its own pause
                PFailedWith handling
                  | persists conds handling → Right (GatheredProbe conds False basis)
                  | otherwise → Right (GatheredFailed handling)
                PDrained → Right GatheredNothing
            )
        RegionalRead b → do
          case key of
            GatherRequest rid | wanted, not (buildDraining b) → probePoint (serviceProbe svc) (PointRegionStep rid (buildRegionsDone b))
            _ → pure ()
          (b', p) ← if wanted then stepBuild io closing store b else cancelBuild io b
          progress ← case p of
            BMore → pure (Left WakeNow)
            -- a page the build could not read: its parts are unavailable, and the arena records the failure
            -- exactly as any failed read's (a pause for its cause); the build goes on
            BNoted handling → do
              case handling of
                HandlePause condition fault → atomically (pauseArena svc aid condition fault)
                _ → pure ()
              pure (Left WakeNow)
            BBlocked wait → pure (Left (WakeOn wait))
            -- temporary pressure keeps the build; its interrupted read starts again once what the storage
            -- service and the edit bank hold has changed
            BPressed _ → do
              mark ← atomically (notePressure svc >> stateStoragePressure <$> readSt svc)
              pure (Left (WakeOn (maybe (pure ()) (pressureChanged svc) mark)))
            BDone copies → pure (Right (GatheredRegions copies (gatherRevision task) (gatherKnowledge task) (gatherGeneration task)))
            BFailed handling → pure (Right (GatheredFailed handling))
            BDrained → pure (Right GatheredNothing)
          pure (RegionalRead b', progress)
        KnowledgeRead q → do
          (q', p) ← if wanted then stepQuery io closing store q else cancelQuery io q
          pure
            ( KnowledgeRead q'
            , case p of
                QMore → Left WakeNow
                QBlocked wait → Left (WakeOn wait)
                QDone known → Right (GatheredKnowledge known (gatherRevision task) (gatherKnowledge task))
                QFailed handling → Right (GatheredFailed handling)
                QDrained → Right GatheredNothing
            )
      case progress of
        Left wake → atomically (modifySt svc (\s → s {stateGathers = Map.adjust (\t → t {gatherRun = run, gatherWake = wake}) key (stateGathers s)}))
        Right result → do
          -- a build's copies stay the request's until their delivery ends: the owner still holds and computes
          -- with them while it builds the snapshot, so a request that ends meanwhile leaves its borrow charged
          -- until then
          let delivering = case (key, result) of
                (GatherRequest rid, GatheredRegions {}) → Just rid
                _ → Nothing
          atomically $ do
            s ← readSt svc
            forM_ (storeOfArena s aid) $ \(current, _) → do
              sameCommittedSTM aid s (release' current run)
              writeTVar (serviceState svc) (putStore aid (release' current run) s) {stateGathers = Map.delete key (stateGathers s)}
            modifyTVar' (serviceEditBank svc) (releaseCredit (gatherGrant task))
            -- a regional borrow whose request ended while this build ran is released now it has drained, or
            -- once its delivery ends
            case (key, delivering) of
              (_, Just rid) → modifySt svc (\s' → s' {stateDelivering = Set.insert rid (stateDelivering s')})
              (GatherRequest rid, Nothing) → releaseOrphanedSTM svc rid
              (GatherJob _, Nothing) → pure ()
            markFreed svc
          deliver result `finally` forM_ delivering (\rid → atomically (endDelivery rid))
  where
    endDelivery rid = do
      modifySt svc (\s → s {stateDelivering = Set.delete rid (stateDelivering s)})
      releaseOrphanedSTM svc rid
      markFreed svc
    persists conds = \case
      HandlePause c _ → c `elem` conds
      HandlePausedFor c → c `elem` conds
      _ → False
    release' current = \case
      RunsRead g → endGather current g
      KnowledgeRead q → endQuery current q
      RegionalRead b → endBuild current b
      ProbeRead {} → current
    ownerAlive st = case key of
      GatherRequest rid → Map.member rid (stateRequests st)
      GatherJob jid → any (\j → R.jobId j == jid && R.jobPhase j == R.JobRunningPhase) (R.modelJobs (stateModel st))

-- ---------------------------------------------------------------------------
-- The slot

-- | Who may take the session's slot.
data Contender
  = ContendRemoval !RequestId !ArenaId !TileCoord
  | ContendGrowth !RequestId !ArenaId !GrowthProposal
  | ContendRelease !RequestId !ArenaId
  | ContendDiscovery !ArenaId
  | ContendReclaim !ArenaId
  | ContendWriteProbe !RequestId !ArenaId ![PageNo]
  deriving stock (Eq, Show)

-- | A piece of internal work's place in the internal rotation: its arena, then reclamation (0) before
-- discovery (1); explicit work has none.
internalPlace ∷ Contender → Maybe (ArenaId, Int)
internalPlace = \case
  ContendReclaim aid → Just (aid, 0)
  ContendDiscovery aid → Just (aid, 1)
  _ → Nothing

-- | The work that may take the slot now, in grant order: the eligible explicit removals (each
-- staged as changing content, staged at the arena's current content revision) in admission
-- order across every arena, and the internal work of every unpaused arena. Reads every
-- explicit removal's 'endpointEligible'. The fairness rule decides between the two lists.
contenders ∷ St → STM [Contender]
contenders st = do
  -- per-arena admission order: a removal takes the slot only when no earlier data request of its
  -- arena, with an eligible host, is still to commit (a later removal never overtakes an earlier
  -- read or removal, so a stream of later removals cannot keep making an earlier read stale)
  firstPending ← foldM firstOf Map.empty (sortOn (reqSeq . snd) (Map.toList (stateRequests st)))
  explicit ← fmap concat . traverse (eligibleRemoval firstPending) $ sortOn (reqSeq . snd) (Map.toList (stateRequests st))
  -- explicit work WAITS while an accepted removal of a live, unpaused arena has an eligible host,
  -- even when none is ready to take the slot this instant: after every commit the others re-stage
  -- against the new revision, and internal work must not take those gaps beyond its turn
  waiting ← or <$> traverse waitingRemoval (Map.toList (stateRequests st))
  -- INTERNAL WORK TAKES ITS TURNS IN ROTATION: over (arena, kind) pairs in a fixed order, starting
  -- after the pair granted last, so reclamation that is always wanted (a stream of removals retires
  -- pages at every commit) cannot keep discovery from its turns, nor one arena's backlog another's
  let ordered = concatMap internalOf (Map.toList (stateArenas st))
      internal = case stateInternalLast st of
        Nothing → ordered
        Just lastPlace → [c | c ← ordered, internalPlace c > Just lastPlace] <> [c | c ← ordered, internalPlace c <= Just lastPlace]
      turn = stateExplicitRun st >= internalTurn
      -- MAINTENANCE THAT ANOTHER TRANSACTION NEEDS FIRST IS ITS PREREQUISITE, NOT A TURN: an arena whose
      -- work answered that maintenance must run first ('MaintenanceFirst', 'HandleWaitReclaim') offers no
      -- other slot work until its maintenance has published, and that maintenance is offered ahead of
      -- every fairness choice
      prerequisite =
        [ ContendReclaim aid
        | (aid, arena) ← Map.toList (stateArenas st)
        , needsMaintenance aid
        , not (integrityPaused arena)
        , not (idle (aid, True) arena)
        ]
  pure . (prerequisite <>) $ case (explicit, internal) of
    ([], _) | waiting && not turn → []
    ([], _) → internal
    (_, []) → explicit
    (e : _, i : _)
      | turn → [i, e]
      | otherwise → [e, i]
  where
    needsMaintenance aid = Set.member aid (stateNeedsMaintenance st)
    waitingRemoval (_, req) = case (reqCmd req, reqPhase req, reqArena req >>= \aid → Map.lookup aid (stateArenas st)) of
      (CRemove {}, phase, Just arena)
        | notDone phase
        , null (conditions (arenaStore arena))
        , maybe True (not . needsMaintenance) (reqArena req) →
            endpointEligible (reqEndpoint req)
      _ → pure False
    notDone = \case
      Done → False
      _ → True
    firstOf acc (rid, req) = case reqArena req of
      Just aid
        | not (Map.member aid acc)
        , dataCmd (reqCmd req)
        , notDone (reqPhase req) → do
            eligible ← endpointEligible (reqEndpoint req)
            pure (if eligible then Map.insert aid rid acc else acc)
      _ → pure acc
    dataCmd = \case
      CCell {} → True
      CColumn {} → True
      CSurface {} → True
      CRemove {} → True
      CKnowledge {} → True
      _ → False
    eligibleRemoval firstPending (rid, req) = case (reqCmd req, reqPhase req, reqArena req >>= \aid → (,) aid <$> Map.lookup aid (stateArenas st)) of
      (CRemove tile _, StagedPhase sg, Just (aid, arena))
        | Map.lookup aid firstPending `elem` [Nothing, Just rid]
        , StagedRemoval prepared ← stagedWork sg
        , preparedChanged prepared
        , stagedRevision sg == arenaRevision arena
        , null (conditions (arenaStore arena))
        , not (needsMaintenance aid) → do
            eligible ← endpointEligible (reqEndpoint req)
            pure [ContendRemoval rid aid tile | eligible]
      -- growth is admissible while paused: it is how a capacity pause is cleared (it changes no content)
      (CGrow _, StagedPhase sg, Just (aid, arena))
        | StagedGrowth proposal ← stagedWork sg
        , creatorFresh arena sg → do
            eligible ← endpointEligible (reqEndpoint req)
            pure [ContendGrowth rid aid proposal | eligible]
      -- so is a retry's release of a pending extra
      (CRetry, StagedPhase sg, Just (aid, arena))
        | StagedRelease ← stagedWork sg
        , creatorFresh arena sg → do
            eligible ← endpointEligible (reqEndpoint req)
            pure [ContendRelease rid aid | eligible]
      -- and a retry's write probe (a maintenance-class transaction), unless the pause is for integrity
      (CRetry, StagedPhase sg, Just (aid, arena))
        | StagedWriteProbe pages ← stagedWork sg
        , creatorFresh arena sg
        , CondIntegrity `notElem` conditions (arenaStore arena) → do
            eligible ← endpointEligible (reqEndpoint req)
            pure [ContendWriteProbe rid aid pages | eligible]
      _ → pure []
    internalOf (aid, arena)
      -- an arena whose maintenance is a prerequisite offers it above and nothing else
      | needsMaintenance aid = []
      | not (null (conditions (arenaStore arena))) = [ContendReclaim aid | reclaimWanted aid arena, not (integrityPaused arena)]
      | otherwise = [ContendReclaim aid | reclaimWanted aid arena] <> [ContendDiscovery aid | discoveryWanted aid arena]
    integrityPaused arena = CondIntegrity `elem` conditions (arenaStore arena)
    store = arenaStore
    reclaimWanted aid arena = rootsRetired (store arena) > 0 && not (idle (aid, True) arena)
    discoveryWanted aid arena =
      D.pendingObligations (storeHeader (store arena)) > 0 && not (idle (aid, False) arena)
    idle key arena = Map.lookup key (stateInternalIdle st) == Just (storeVersion (store arena), oldestPin (store arena))
    rootsRetired s = rRetiredPages (storeRoots s)

-- | Grant the slot: the transaction's worst-case credits are reserved first (Foreground: the
-- protected staging is its own; the cache it needs beside every reader pin is what the edit
-- bank's configuration was validated for), then the run starts planning against the committed
-- store. False when the credits are not available now: the grant waits for the cache the
-- readers' pins hold, which never wait for the slot.
grantSlot ∷ Service → Contender → STM Bool
grantSlot svc contender = do
  st ← readSt svc
  adm ← readTVar (serviceEditBank svc)
  let txn aid arena work planner = case A.reserve A.Foreground (A.transactionCredits aid A.worstTransactionCharge) adm of
        Left _ → pure False
        Right (grant, adm') → do
          writeTVar (serviceEditBank svc) adm'
          writeTVar (serviceState svc) st {stateSlot = Just (SlotTask aid work (SlotTxn (Txn.start (arenaStore arena) planner)) (Just grant) WakeNow False (basisOf arena))}
          pure True
      -- the store the run is given, as internal work's idle mark records it ('slotBasis')
      basisOf arena = (storeVersion (arenaStore arena), oldestPin (arenaStore arena))
      live aid k = case (stateSlot st, Map.lookup aid (stateArenas st)) of
        (Nothing, Just arena) → k arena
        _ → pure False
  case contender of
    -- a growth holds no transaction RAM: its extra is the backend's, charged there
    ContendGrowth rid aid proposal → live aid $ \arena → do
      writeTVar (serviceState svc) st {stateSlot = Just (SlotTask aid (SlotGrowth rid) (SlotGrow (Growth.startGrowth proposal)) Nothing WakeNow False (basisOf arena))}
      pure True
    ContendRelease rid aid → live aid $ \arena → do
      writeTVar (serviceState svc) st {stateSlot = Just (SlotTask aid (SlotRelease rid) (SlotGrow Growth.startRelease) Nothing WakeNow False (basisOf arena))}
      pure True
    ContendRemoval rid aid tile → live aid $ \arena → txn aid arena (SlotRemoval rid) (removalPlanner (arenaEnv arena) (arenaStore arena) tile)
    ContendDiscovery aid → live aid $ \arena → txn aid arena SlotDiscovery (discoveryPlanner (arenaEnv arena) (arenaStore arena))
    ContendReclaim aid → live aid $ \arena → txn aid arena SlotReclaim (maintenancePlanner (arenaStore arena))
    -- a write probe is a transaction: its worst-case credits are reserved like any other's
    ContendWriteProbe rid aid pages → live aid $ \arena → case A.reserve A.Foreground (A.transactionCredits aid A.worstTransactionCharge) adm of
      Left _ → pure False
      Right (grant, adm') → do
        writeTVar (serviceEditBank svc) adm'
        writeTVar (serviceState svc) st {stateSlot = Just (SlotTask aid (SlotWriteProbe rid) (SlotProbe (WriteProbe.startWriteProbe (arenaStore arena) pages)) (Just grant) WakeNow False (basisOf arena))}
        pure True

-- | Where a step left the slot's transaction, for the owner.
data SlotEnd
  = -- | Still running (the slot is recorded with its new wait).
    SlotGoesOn
  | -- | Every page is written: the owner prepares and makes the decision.
    SlotEligible !SlotTask !TxnId !Plan
  | -- | The transaction ended without publishing; its slot and credits are already released.
    SlotOver !SlotTask !Done
  | -- | A growth obtained its extra: the owner makes the decision that commits it.
    SlotGrowthReady !SlotTask !PreparedGrowth
  | -- | A growth ended without being committed; its slot is already released.
    SlotGrowthOver !SlotTask !Growth.GrowthEnd
  | -- | A retry's write probe ended (its transaction abandoned); its slot and credits are already released.
    SlotWriteProbeOver !SlotTask !WriteProbe.WriteResult

-- | One step of the slot's transaction: a step of its run, or, when its request or arena has
-- ended, a step of its cancellation (nothing is released until the job in flight has returned).
-- When it ends without publishing, the slot and its credits are released in the transaction that
-- records the end.
stepSlot ∷ Service → IO SlotEnd
stepSlot svc = do
  st ← atomically (readSt svc)
  case stateSlot st of
    Nothing → pure SlotGoesOn
    Just task → case storeOfArena st (slotArena task) of
      Nothing → pure SlotGoesOn
      Just (store, backing) → do
        let aid = slotArena task
            io = Io (serviceStorage svc) backing (classOf (slotWork task))
            -- ONCE ITS ARENA PAUSES, ORDINARY WORK IN FLIGHT STOPS: a removal's or discovery's transaction
            -- is cancelled and drains; reclamation goes on unless the pause is for integrity; a growth or
            -- a pending extra's release goes on (it is how a pause is cleared)
            wanted = Map.member aid (stateArenas st) && requestAlive st (slotWork task) && not (slotYield task) && maybe False (permittedWhilePaused (slotWork task)) (Map.lookup aid (stateArenas st))
            end store' task' result = do
              atomically $ do
                readSt svc >>= \s0 → sameCommittedSTM aid s0 store'
                modifySt svc (\s → (putStore aid store' s) {stateSlot = Nothing})
                forM_ (slotCredit task) $ \g → modifyTVar' (serviceEditBank svc) (releaseCredit g)
                markFreed svc
              pure (result task')
        case slotRun task of
          SlotTxn run → do
            (store', run', progress) ←
              if wanted
                then Txn.advance io (closingOf st aid) store run
                else Txn.cancel io store run
            uninterruptibleMask_ (probePoint (serviceProbe svc) (PointSlotStepped aid (Txn.runPhaseName run')))
            let task' = task {slotRun = SlotTxn run'}
                keep wake = atomically (readSt svc >>= \s0 → sameCommittedSTM aid s0 store' >> modifySt svc (\s → (putStore aid store' s) {stateSlot = Just task' {slotWake = wake}}))
            case progress of
              More → keep WakeNow >> pure SlotGoesOn
              Blocked wait → keep (WakeOn wait) >> pure SlotGoesOn
              ReadyToPublish tid plan → keep WakeNow >> pure (SlotEligible task' tid plan)
              Finished done → end store' task' (\t → SlotOver t done)
          SlotGrow run → do
            (store', run', progress) ←
              if wanted
                then Growth.advanceGrowth io (closingOf st aid) store run
                else Growth.abandonGrowth io store run
            let task' = task {slotRun = SlotGrow run'}
                keep wake = atomically (readSt svc >>= \s0 → sameCommittedSTM aid s0 store' >> modifySt svc (\s → (putStore aid store' s) {stateSlot = Just task' {slotWake = wake}}))
            case progress of
              Growth.GrowthMore → keep WakeNow >> pure SlotGoesOn
              Growth.GrowthBlocked wait → keep (WakeOn wait) >> pure SlotGoesOn
              Growth.GrowthReady prepared → keep WakeNow >> pure (SlotGrowthReady task' prepared)
              Growth.GrowthOver over → end store' task' (\t → SlotGrowthOver t over)
              -- refused for temporary pressure: the run keeps its place and what the backend holds for it,
              -- and steps again once the storage service's capacity has changed, never at once
              Growth.GrowthPressed → do
                mark ← atomically (notePressure svc >> pressureMark svc)
                keep (WakeOn (pressureChanged svc mark)) >> pure SlotGoesOn
          SlotProbe run → do
            (store', run', progress) ←
              if wanted
                then WriteProbe.advanceWriteProbe io (closingOf st aid) store run
                else WriteProbe.cancelWriteProbe io store run
            let task' = task {slotRun = SlotProbe run'}
                keep wake = atomically (readSt svc >>= \s0 → sameCommittedSTM aid s0 store' >> modifySt svc (\s → (putStore aid store' s) {stateSlot = Just task' {slotWake = wake}}))
            case progress of
              WriteProbe.WMore → keep WakeNow >> pure SlotGoesOn
              WriteProbe.WBlocked wait → keep (WakeOn wait) >> pure SlotGoesOn
              WriteProbe.WOver result → end store' task' (\t → SlotWriteProbeOver t result)
  where
    requestAlive st = \case
      SlotRemoval rid → Map.member rid (stateRequests st)
      SlotGrowth rid → Map.member rid (stateRequests st)
      SlotRelease rid → Map.member rid (stateRequests st)
      SlotWriteProbe rid → Map.member rid (stateRequests st)
      SlotDiscovery → True
      SlotReclaim → True
    classOf = \case
      SlotRemoval _ → ExplicitWork
      SlotGrowth _ → ExplicitWork
      SlotRelease _ → ExplicitWork
      SlotWriteProbe _ → ExplicitWork
      SlotDiscovery → MaintenanceWork
      SlotReclaim → MaintenanceWork

-- ---------------------------------------------------------------------------
-- Closing

-- | A closed arena whose file can be closed now: nothing of it is in flight.
drainReady ∷ St → ArenaId → Bool
drainReady st aid =
  maybe True ((/= aid) . slotArena) (stateSlot st)
    && not (any ((== aid) . gatherArena) (Map.elems (stateGathers st)))

-- | Close a drained arena's file (one bounded native call: nothing of it is in flight, so the
-- close waits for nothing) and return its compile charge. A close that fails is kept by the
-- storage service and reaches the service's end report; a held reservation stays counted on
-- the volume until then.
closeDrained ∷ Service → ArenaId → IO ()
closeDrained svc aid = do
  st ← atomically (readSt svc)
  forM_ (Map.lookup aid (stateClosing st)) $ \c → do
    _ ← closeBacking (serviceStorage svc) (closingBacking c)
    atomically $ do
      modifySt svc $ \s →
        s
          { stateClosing = Map.delete aid (stateClosing s)
          , stateInternalIdle = Map.filterWithKey (\(a, _) _ → a /= aid) (stateInternalIdle s)
          , stateNeedsMaintenance = Set.delete aid (stateNeedsMaintenance s)
          }
      markFreed svc

-- ---------------------------------------------------------------------------
-- The oracle

-- | The backed state's physical truth set beside what is counted, for the suite after every
-- step: an empty list means they agree. It reads the service state, the edit bank and the
-- storage service's own view, never one from the other.
--
-- * Every live arena: the accounting model's revision is the store's committed content revision,
--   and the model retains nothing for it (no history in RAM).
-- * Every arena (live or closing): a reader pin exists exactly when a gather of it does; an
--   active store transaction exists exactly when the session's slot runs one of it.
-- * The compile account's use is the sum of what each arena, closing file and open holds, and
--   never above the account.
-- * The storage service holds a backing for every live arena and every reserved open whose request
--   is live, and at most one more for each closing arena, each reserved open whose request has
--   ended (each closes its file in one bounded call, after which the owner forgets it) and each
--   open whose reservation has finished untaken.
-- * With no task of the owner and no job of the backend, the edit bank's cache and staging hold
--   nothing, and its control holds exactly the storage service's own records: a backing record
--   for each backing, charged closing record, held close and running open, and a kept-failure
--   entry for each kept failure (#663's accounting, read from its snapshot).
backedInvariants ∷ St → Admission → Word64 → Snapshot → [String]
backedInvariants st adm compileBank sn =
  [ "arena " <> show aid <> ": the model's revision " <> show (R.arenaRevision info) <> " is not the store's " <> show (arenaRevision arena)
  | (aid, arena) ← Map.toList (stateArenas st)
  , info ← R.modelArenas (stateModel st)
  , R.arenaId info == aid
  , R.arenaRevision info /= arenaRevision arena
  ]
    <> [ "arena " <> show (R.arenaId info) <> " retains " <> show (R.arenaRetainedBytes info) <> " bytes of history in RAM"
       | info ← R.modelArenas (stateModel st)
       , R.arenaRetainedBytes info /= 0
       ]
    <> [ "arena " <> show aid <> ": " <> show gathers <> " gathers but the oldest pin is " <> show pin
       | (aid, store) ← stores
       , let gathers = length [() | t ← Map.elems (stateGathers st), gatherArena t == aid]
             pin = oldestPin store
       , (gathers == 0) /= (pin == Nothing)
       ]
    <> [ "arena " <> show aid <> ": an active transaction " <> show (fmap avId (activeView store)) <> " that the slot does not run"
       | (aid, store) ← stores
       , activeView store /= Nothing
       , maybe True (\t → slotArena t /= aid || slotTxnId t /= fmap avId (activeView store)) (stateSlot st)
       ]
    <> [ "the slot runs " <> show (slotTxnId t) <> " of arena " <> show (slotArena t) <> " but its store holds " <> show (fmap avId . activeView . fst =<< storeOfArena st (slotArena t))
       | Just t ← [stateSlot st]
       , Just tid ← [slotTxnId t]
       , (fmap avId . activeView . fst =<< storeOfArena st (slotArena t)) /= Just tid
       ]
    <> [ "the compile account holds " <> show (stateCompileUse st) <> " but its holders hold " <> show held
       | stateCompileUse st /= held
       ]
    <> [ "the compile account holds " <> show (stateCompileUse st) <> " of " <> show compileBank
       | stateCompileUse st > compileBank
       ]
    <> [ "the storage service holds " <> show backings <> " backings for " <> show wanted <> " to " <> show (wanted + reserving)
       | backings < wanted || backings > wanted + reserving
       ]
    <> [ "the owner chose " <> Text.unpack w <> " again with nothing changed"
       | w ← stateIdleRepeats st
       ]
    <> [ "the edit bank holds " <> show (A.ledgers adm) <> " with no task and no job; the storage service's records need " <> show storageControl <> " of control"
       | idle
       , null (snJobs sn)
       , let lg = A.ledgers adm
       , A.lgCacheBacked lg + A.lgCacheRamOnly lg + A.lgCachePinned lg + A.lgStagingForeground lg + A.lgStagingCamera lg /= 0
           || A.lgControlReserved lg /= storageControl
       ]
  where
    slotTxnId t = case slotRun t of
      SlotTxn run → Txn.runTxnId run
      SlotGrow _ → Nothing
      SlotProbe run → WriteProbe.writeProbeTxnId run
    stores = [(aid, arenaStore a) | (aid, a) ← Map.toList (stateArenas st)] <> [(aid, closingStore c) | (aid, c) ← Map.toList (stateClosing st)]
    held =
      sum (map arenaShared (Map.elems (stateArenas st)))
        + sum (map arenaShared (Map.elems (stateRetiring st)))
        + sum (map (openHeld . openPhase) (Map.elems (stateOpens st)))
    openHeld = \case
      OpenQueued → 0
      OpenCompiling _ n → n
      OpenSubmitting _ _ _ _ n _ → n
      OpenReserving _ _ _ n _ _ → n
      OpenPublishable _ _ n _ _ → n
      OpenUnwinding n _ _ → n
    wanted = Map.size (stateArenas st) + length [() | (rid, t) ← Map.toList (stateOpens st), isPublishable (openPhase t), live rid]
    reserving = Map.size (stateClosing st) + length [() | (rid, t) ← Map.toList (stateOpens st), isReserving rid (openPhase t)]
    live rid = Map.member rid (stateRequests st)
    isPublishable = \case
      OpenPublishable {} → True
      _ → False
    -- a reserved open whose request ended is closing its file ('stepOpen'), like a closing arena
    isReserving rid = \case
      OpenReserving {} → True
      OpenUnwinding {} → True
      OpenPublishable {} → not (live rid)
      _ → False
    backings = length (snBackings sn)
    storageControl =
      fromIntegral (backings + snClosingCharged sn + length (snHeld sn) + length (snOpening sn)) * backingRecordBytes
        + fromIntegral (snEvidence sn) * keptEntryBytes
    idle = Map.null (stateGathers st) && maybe True (const False) (stateSlot st) && Map.null (stateOpens st)
