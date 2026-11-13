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

    -- * Gathers
  , Gathered (..)
  , ReadWhat (..)
  , canStartGather
  , editBankReadsChecked
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
import Control.Exception (evaluate)
import Control.Monad (foldM, forM_, void, when)
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Column (..), mkZRange)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), Changes, changesFromIntervals)
import qualified Hetoimasia.Terrain.Connectivity as C
import Hetoimasia.Terrain.Coordinate (TileCoord)
import qualified Hetoimasia.Terrain.Discovery as D
import qualified Hetoimasia.Terrain.Residency as R
import Hetoimasia.Terrain.Residency (ArenaId (..), RequestId, Revision (..))
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Fault
import Hetoimasia.Terrain.Runtime.Backed.Gather
import Hetoimasia.Terrain.Runtime.Backed.Query
import Hetoimasia.Terrain.Runtime.Backed.Probe
import qualified Hetoimasia.Terrain.Runtime.Backed.Growth as Growth
import Hetoimasia.Terrain.Runtime.Backed.Txn (Done (..), Io (..), Progress (..))
import qualified Hetoimasia.Terrain.Runtime.Backed.Txn as Txn
import Hetoimasia.Terrain.Runtime.Internal.Content (Prepared (..))
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Types hiding (OwnerPhase (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( Backing
  , Snapshot (..)
  , backingRecordBytes
  , keptEntryBytes
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
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (WorkClass (..))
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (Admission)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo, StoreIdentity (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (ActiveView (..), Condition (..), GrowthProposal, Store, activeView, storeConfig, TxnId, conditions, oldestPin, pauseFor, storeFromRoots, storeHeader, storeRoots, storeVersion)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Plan, RamCharge (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Protocol (discoveryPlanner, maintenancePlanner, removalPlanner)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (Roots (..), StoreConfig, emptyRoots, maxReaders)
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
editBankReadsChecked ∷ A.EditBankSpec → Either ConfigError ()
editBankReadsChecked spec
  | cacheNeed > A.ebsCache spec = Left (ConfigEditBankReads "cache" cacheNeed (A.ebsCache spec))
  | stagingNeed > A.ebsStaging spec = Left (ConfigEditBankReads "staging" stagingNeed (A.ebsStaging spec))
  | otherwise = Right ()
  where
    w = A.worstTransactionCharge
    pins = A.ebsArenas spec * min (toInteger maxReaders) (A.ebsReadersPerArena spec)
    cacheNeed = toInteger (ramDecodedCopies w) + pins * toInteger A.readerPinnedCacheBytes + toInteger resultPageBytes
    stagingNeed = toInteger (ramIoBuffers w + ramKeys w + ramScratch w) + toInteger (transferBufferBytes 1)

-- | The fairness rule of the slot: while explicit work waits, internal work (discovery,
-- reclamation) gets one grant after every 'internalTurn' explicit grants.
internalTurn ∷ Int
internalTurn = 3

changeLimitsOf ∷ Config → ChangeLimits
changeLimitsOf config =
  ChangeLimits (fromInteger (min (toInteger (maxBound ∷ Int)) (toInteger (R.limitBytes (configLimits config) R.EditBank `div` 16))))

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
putStore ∷ ArenaId → Store → St → St
putStore aid store st =
  st
    { stateArenas = Map.adjust (\a → a {arenaStore = store}) aid (stateArenas st)
    , stateClosing = Map.adjust (\c → c {closingStore = store}) aid (stateClosing st)
    }

-- | The removals a gather read, as the pure terrain model's changes.
changesOfRuns ∷ Config → [(Column, Int64, Int64)] → Either Text Changes
changesOfRuns config runs = do
  intervals ← traverse interval runs
  either (Left . Text.pack . show) Right (changesFromIntervals (changeLimitsOf config) intervals)
  where
    interval (column, lo, hi) = either (Left . Text.pack . show) (\r → Right (column, r)) (mkZRange (toInteger lo) (toInteger hi))

-- ---------------------------------------------------------------------------
-- Pause

-- | Record a pause of an arena (requirement 8): the store pauses new history for the
-- condition, the fault is kept for the creator's retry, and every uncommitted user mutation
-- of the arena settles once with the fault. The last committed roots, terrain, knowledge and
-- frontier are untouched.
pauseArena ∷ Service → ArenaId → Condition → StorageFault → [PageNo] → STM ()
pauseArena svc aid condition fault pages = do
  st ← readSt svc
  forM_ (Map.lookup aid (stateArenas st)) $ \arena → do
    let record = FaultRecord fault (take faultPagesKept (faultPages fault <> pages))
    modifySt svc $ \s →
      s
        { stateArenas =
            Map.insert
              aid
              arena
                { arenaStore = pauseFor condition (arenaStore arena)
                , arenaFaults = Map.insertWith (\_ old → old) condition record (arenaFaults arena)
                }
              (stateArenas s)
        }
    forM_ [rid | (rid, req) ← Map.toList (stateRequests st), reqArena req == Just aid, isPendingRemoval req] $ \rid →
      terminate svc rid (Failed (StorageFailed fault))
  where
    isPendingRemoval req = case (reqCmd req, reqPhase req) of
      (CRemove {}, Done) → False
      (CRemove {}, _) → True
      _ → False

-- ---------------------------------------------------------------------------
-- Opening

-- | Begin an open: it waits for the session's one compilation.
beginOpen ∷ Service → RequestId → Source → STM ()
beginOpen svc rid source =
  modifySt svc (\st → if Map.member rid (stateOpens st) then st else st {stateOpens = Map.insert rid (OpenTask source OpenQueued) (stateOpens st)})

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
      OpenUnwinding {} → Nothing

-- | An open whose file is reserved and whose store is ready, waiting for its publication: what
-- the open's commit installs.
openReady ∷ St → RequestId → Maybe (ArenaId, D.Env, Word64, Backing, Store)
openReady st rid = case openPhase <$> Map.lookup rid (stateOpens st) of
  Just (OpenPublishable aid env shared backing store) → Just (aid, env, shared, backing, store)
  _ → Nothing

-- | One step of an open.
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
                else do
                  (aid, ident) ← atomically $ do
                    s ← readSt svc
                    let aid = ArenaId (stateNextArena s)
                    writeTVar (serviceState svc) s {stateNextArena = stateNextArena s + 1, stateNextSource = stateNextSource s + 1}
                    pure (aid, StoreIdentity aid (stateNextSource s))
                  submitOpen (serviceStorage svc) ExplicitWork (OpenSpec (serviceDirectory svc) ident (serviceStoreConfig svc)) >>= \case
                    Left failure → finish held (classifyFailure OwnerRunning JkOpen failure)
                    Right ticket → atomically $ do
                      modifySt svc $ \s →
                        s {stateCompiling = Nothing, stateCompileUse = stateCompileUse s - held + shared}
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
                store ← evaluate (initialStore config aid ident (serviceStoreConfig svc))
                atomically (setPhase task (OpenPublishable aid env shared backing store))
                -- the open is staged: the host is told, and its commit installs the arena
                opsStage ops rid Nothing (Revision (configFirstRevision config)) StagedControl
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
      HandleRetryLater busy → failOpen held (Text.pack ("an open was refused as busy: " <> show busy))
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
    GatheredRuns ![(Column, Int64, Int64)] !Revision
  | -- | What is known of the cell, read from one committed version, with its content and knowledge revisions.
    GatheredKnowledge !D.CellKnowledge !Revision !Revision
  | -- | A retry's probe: the conditions it was for, and whether every recorded page read back as it must.
    GatheredProbe ![Condition] !Bool
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
  = ReadRuns ![Column]
  | ReadKnowledge !TileCoord
  | ReadPages ![(PageNo, ReadMode)] ![Condition]

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
          writeTVar (serviceEditBank svc) adm'
          writeTVar (serviceState svc) (putStore aid store' st) {stateGathers = Map.insert key (GatherTask aid run grant (arenaRevision arena) (D.authKnowledge (arenaAuthority arena)) WakeNow) (stateGathers st)}
          pure True
    _ → pure False
  where
    begin arena = case what of
      ReadRuns columns → fmap RunsRead <$> startGather (arenaStore arena) columns
      ReadKnowledge tile → fmap KnowledgeRead <$> startQuery (arenaStore arena) (\provider → D.queryCell (arenaEnv arena) provider tile)
      ReadPages pages conds → Right (arenaStore arena, ProbeRead (startProbe pages) conds)

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
          pure
            ( RunsRead g'
            , case p of
                GMore → Left WakeNow
                GBlocked wait → Left (WakeOn wait)
                GDone runs → Right (GatheredRuns runs (gatherRevision task))
                GFailed handling → Right (GatheredFailed handling)
                GDrained → Right GatheredNothing
            )
        ProbeRead pr conds → do
          (pr', p) ← if wanted then stepProbe io closing (storeConfig store) pr else cancelProbe io pr
          pure
            ( ProbeRead pr' conds
            , case p of
                PMore → Left WakeNow
                PBlocked wait → Left (WakeOn wait)
                PPassed → Right (GatheredProbe conds True)
                -- the cause persists: the retry answers it as remaining (it is not a new pause)
                PFailedWith _ → Right (GatheredProbe conds False)
                PDrained → Right GatheredNothing
            )
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
          atomically $ do
            s ← readSt svc
            forM_ (storeOfArena s aid) $ \(current, _) →
              writeTVar (serviceState svc) (putStore aid (release' current run) s) {stateGathers = Map.delete key (stateGathers s)}
            modifyTVar' (serviceEditBank svc) (releaseCredit (gatherGrant task))
            markFreed svc
          deliver result
  where
    release' current = \case
      RunsRead g → endGather current g
      KnowledgeRead q → endQuery current q
      ProbeRead _ _ → current
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
  deriving stock (Eq, Show)

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
  let internal = concatMap internalOf (Map.toList (stateArenas st))
      turn = stateExplicitRun st >= internalTurn
  pure $ case (explicit, internal) of
    ([], _) | waiting && not turn → []
    ([], _) → internal
    (_, []) → explicit
    (e : _, i : _)
      | turn → [i, e]
      | otherwise → [e, i]
  where
    waitingRemoval (_, req) = case (reqCmd req, reqPhase req, reqArena req >>= \aid → Map.lookup aid (stateArenas st)) of
      (CRemove {}, phase, Just arena)
        | notDone phase
        , null (conditions (arenaStore arena)) →
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
        , null (conditions (arenaStore arena)) → do
            eligible ← endpointEligible (reqEndpoint req)
            pure [ContendRemoval rid aid tile | eligible]
      -- growth is admissible while paused: it is how a capacity pause is cleared (it changes no content)
      (CGrow _, StagedPhase sg, Just (aid, _))
        | StagedGrowth proposal ← stagedWork sg → do
            eligible ← endpointEligible (reqEndpoint req)
            pure [ContendGrowth rid aid proposal | eligible]
      -- so is a retry's release of a pending extra
      (CRetry, StagedPhase sg, Just (aid, _))
        | StagedRelease ← stagedWork sg → do
            eligible ← endpointEligible (reqEndpoint req)
            pure [ContendRelease rid aid | eligible]
      _ → pure []
    internalOf (aid, arena)
      | not (null (conditions (arenaStore arena))) = [ContendReclaim aid | reclaimWanted aid arena, not (integrityPaused arena)]
      | otherwise = [ContendReclaim aid | reclaimWanted aid arena] <> [ContendDiscovery aid | discoveryWanted aid arena]
    integrityPaused arena = CondIntegrity `elem` conditions (arenaStore arena)
    store = arenaStore
    reclaimWanted aid arena =
      Set.member aid (stateNeedsMaintenance st)
        || (rootsRetired (store arena) > 0 && not (idle (aid, True) arena))
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
          writeTVar (serviceState svc) st {stateSlot = Just (SlotTask aid work (SlotTxn (Txn.start (arenaStore arena) planner)) (Just grant) WakeNow False), stateNeedsMaintenance = Set.delete aid (stateNeedsMaintenance st)}
          pure True
      live aid k = case (stateSlot st, Map.lookup aid (stateArenas st)) of
        (Nothing, Just arena) → k arena
        _ → pure False
  case contender of
    -- a growth holds no transaction RAM: its extra is the backend's, charged there
    ContendGrowth rid aid proposal → live aid $ \_ → do
      writeTVar (serviceState svc) st {stateSlot = Just (SlotTask aid (SlotGrowth rid) (SlotGrow (Growth.startGrowth proposal)) Nothing WakeNow False)}
      pure True
    ContendRelease rid aid → live aid $ \_ → do
      writeTVar (serviceState svc) st {stateSlot = Just (SlotTask aid (SlotRelease rid) (SlotGrow Growth.startRelease) Nothing WakeNow False)}
      pure True
    ContendRemoval rid aid tile → live aid $ \arena → txn aid arena (SlotRemoval rid) (removalPlanner (arenaEnv arena) (arenaStore arena) tile)
    ContendDiscovery aid → live aid $ \arena → txn aid arena SlotDiscovery (discoveryPlanner (arenaEnv arena) (arenaStore arena))
    ContendReclaim aid → live aid $ \arena → txn aid arena SlotReclaim (maintenancePlanner (arenaStore arena))

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
            wanted = Map.member aid (stateArenas st) && requestAlive st (slotWork task) && not (slotYield task)
            end store' task' result = do
              atomically $ do
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
            let task' = task {slotRun = SlotTxn run'}
                keep wake = atomically (modifySt svc (\s → (putStore aid store' s) {stateSlot = Just task' {slotWake = wake}}))
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
                keep wake = atomically (modifySt svc (\s → (putStore aid store' s) {stateSlot = Just task' {slotWake = wake}}))
            case progress of
              Growth.GrowthMore → keep WakeNow >> pure SlotGoesOn
              Growth.GrowthBlocked wait → keep (WakeOn wait) >> pure SlotGoesOn
              Growth.GrowthReady prepared → keep WakeNow >> pure (SlotGrowthReady task' prepared)
              Growth.GrowthOver over → end store' task' (\t → SlotGrowthOver t over)
  where
    requestAlive st = \case
      SlotRemoval rid → Map.member rid (stateRequests st)
      SlotGrowth rid → Map.member rid (stateRequests st)
      SlotRelease rid → Map.member rid (stateRequests st)
      SlotDiscovery → True
      SlotReclaim → True
    classOf = \case
      SlotRemoval _ → ExplicitWork
      SlotGrowth _ → ExplicitWork
      SlotRelease _ → ExplicitWork
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
-- * The storage service holds a backing for every live arena and every reserved open, and at most
--   one more for each closing arena (its file closes in one bounded call, after which the owner
--   forgets it) and each open whose reservation has finished untaken.
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
    stores = [(aid, arenaStore a) | (aid, a) ← Map.toList (stateArenas st)] <> [(aid, closingStore c) | (aid, c) ← Map.toList (stateClosing st)]
    held =
      sum (map arenaShared (Map.elems (stateArenas st)))
        + sum (map arenaShared (Map.elems (stateRetiring st)))
        + sum (map (openHeld . openPhase) (Map.elems (stateOpens st)))
    openHeld = \case
      OpenQueued → 0
      OpenCompiling _ n → n
      OpenReserving _ _ _ n _ _ → n
      OpenPublishable _ _ n _ _ → n
      OpenUnwinding n _ _ → n
    wanted = Map.size (stateArenas st) + length [() | OpenPublishable {} ← map openPhase (Map.elems (stateOpens st))]
    reserving = Map.size (stateClosing st) + length [() | p ← map openPhase (Map.elems (stateOpens st)), isReserving p]
    isReserving = \case
      OpenReserving {} → True
      OpenUnwinding {} → True
      _ → False
    backings = length (snBackings sn)
    storageControl =
      fromIntegral (backings + snClosingCharged sn + length (snHeld sn) + length (snOpening sn)) * backingRecordBytes
        + fromIntegral (snEvidence sn) * keptEntryBytes
    idle = Map.null (stateGathers st) && maybe True (const False) (stateSlot st) && Map.null (stateOpens st)
