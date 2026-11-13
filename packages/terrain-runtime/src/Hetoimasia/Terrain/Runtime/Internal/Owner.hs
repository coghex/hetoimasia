-- | The terrain owner thread: the sole writer of arena contents and the only publisher of
-- committed roots, revisions and request results.
--
-- The owner loops over bounded quanta. Each quantum chooses one piece of work in a
-- transaction ('nextWork'), does its pure computation or its one storage effect outside any
-- transaction, and records the result in a transaction that revalidates what the computation
-- assumed. Waiting for a host's eligibility, for a storage job, for a load or for a caller is
-- waiting in 'nextWork' for a state that changes: ONE blocking transaction composes every
-- source (commands, cancellations, closure, eligibility, every storage job a task waits for),
-- and nothing polls or sleeps. The owner never blocks inside a quantum, so other eligible
-- work and closure are always serviced.
--
-- == Commit order
--
-- Among the eligible commands of one arena, the owner commits in admission order. A command
-- that is not yet eligible does not hold up the others, and a command that is eligible but
-- not yet staged holds up the later ones. Mutations that change content take the session's
-- one mutating transaction ('Hetoimasia.Terrain.Runtime.Internal.Backed.contenders'), granted
-- only to work that can publish the moment its writes complete.
--
-- == Revalidation
--
-- Staged work is tagged with the incarnation and content revision it was read at. It is
-- published only if the arena still has that incarnation and revision; otherwise the owner
-- reads and computes it again. Work is never relabelled with a newer revision.
module Hetoimasia.Terrain.Runtime.Internal.Owner
  ( ownerDefinition
  , terrainComponent
  ) where

import Control.Concurrent.STM
import Control.Exception (SomeAsyncException, SomeException, evaluate, fromException, mask, onException, rethrowIO, throwIO, try, tryWithContext, uninterruptibleMask_)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Int (Int64)
import System.Environment (lookupEnv)
import GHC.Clock (getMonotonicTime)
import System.IO (hPutStrLn, stderr)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isJust, listToMaybe)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Component, logError, logInfo, unsafeComponent)
import Hetoimasia.Foundation.Resource (Scoped, composeCleanup)
import Hetoimasia.Foundation.Worker (StopToken, WorkerDefinition, stopRequested, workerDefinition)
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Coordinate (decomposeTile)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Palette (Palette, emptyPalette, internSourceMaterials)
import qualified Hetoimasia.Terrain.Residency as R
import Hetoimasia.Terrain.Residency (ArenaId (..), RequestId (..), Revision (..))
import Hetoimasia.Terrain.Resident (Resident, discardRegion, emptyResident)
import Hetoimasia.Terrain.Runtime.Backed.Backend (Handling (..))
import Hetoimasia.Terrain.Runtime.Backed.Txn (Done (..), runDraining)
import Hetoimasia.Terrain.Runtime.Backed.Gather (gatherDraining)
import Hetoimasia.Terrain.Runtime.Backed.Query (queryDraining)
import Hetoimasia.Terrain.Runtime.Backed.Probe (probeDraining)
import Hetoimasia.Terrain.Runtime.Backed.Growth (growthDraining)
import Hetoimasia.Terrain.Runtime.Internal.Backed
import Hetoimasia.Terrain.Runtime.Internal.Content
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Publish
import Hetoimasia.Terrain.Runtime.Internal.Types
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import qualified Hetoimasia.Terrain.Runtime.Backed.Growth as Growth
import Hetoimasia.Terrain.Runtime.Backed.Fault (StorageFault (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (ReadMode (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (PreparedGrowth)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Condition (..), GrowthDecision (..), TxnId, clearCondition, conditions, oldestPin, proposeGrowth, storeConfig, storeHeader, storeRoots, storeVersion)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (TxClass (..), availablePages)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgAllowanceBytes, maxClaimPages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Effects (..), Plan, plEffects)

-- | The component every terrain service record is reported under.
terrainComponent ∷ Component
terrainComponent = unsafeComponent "terrain.runtime"

-- ---------------------------------------------------------------------------
-- The worker

-- | The owner as a worker definition. It captures the service and nothing the
-- application thread holds: never the runtime control.
ownerDefinition ∷ Service → WorkerDefinition ()
ownerDefinition svc =
  workerDefinition "terrain.runtime.owner" (\_ → pure () ∷ Scoped ()) $ \token () → ownerMain svc token

ownerMain ∷ Service → StopToken → IO ()
ownerMain svc token = mask $ \restore → do
  -- The cleanup covers the owner's whole execution, startup logging included, and
  -- is the last thing it does: nothing of the owner runs after it publishes that
  -- it stopped, so a logger is never used after the service has returned.
  outcome <-
    tryWithContext @SomeException . restore $ do
      atomically (modifySt svc (\st → st {stateOwner = OwnerRunning}))
      logInfo logger terrainComponent "terrain owner started" []
      loop
      logInfo logger terrainComponent "terrain owner stopped" []
  uninterruptibleMask_ (atomically terminal)
  -- Whatever the owner ended with, any defect the cleanup recorded (a host
  -- callback that failed while every settlement was still being delivered) is
  -- attached to it as cleanup evidence, or becomes the failure itself when the
  -- owner would have returned: supervision sees all of it.
  pending <- atomically (takeUnreportedSTM svc)
  evidence <- forM pending $ \defect →
    tryWithContext @SomeException (throwIO defect) >>= \case
      Left caught → pure ("terrain owner cleanup", caught)
      Right () → throwIO (OwnerDefect "a defect was not thrown")
  combined <- composeCleanup (either Just (const Nothing) outcome) evidence
  forM_ combined rethrowIO
  where
    logger = serviceLogger svc
    -- every step of work is taken masked: a storage effect and its record have no
    -- interruptible instruction between them (neither transaction blocks)
    loop = do
      work <- tryNonAsync (atomically (nextWork svc token)) >>= \case
        Right chosen → pure chosen
        Left failure → do
          -- Choosing work reads every host's eligibility: a callback that throws
          -- is a provider defect, recorded, and the owner ends.
          failWith svc (ProviderDefect (Text.pack ("eligibility callback failed: " <> show failure))) []
      continue <- perform svc work
      when continue loop
    -- Whatever ended the loop, every accepted request leaves the table settled exactly once,
    -- the owner's tasks give their edit-bank credits back and the owner is marked stopped.
    -- Non-blocking bookkeeping, so it is safe under the uninterruptible mask. A job a task
    -- still waited for, and a file a closed arena still held, are the storage service's to
    -- drain and close at the end of its own scope, which outlives the owner.
    terminal = do
      safePointSTM svc
      closeServiceSTM svc
      retireInFlightSTM svc
      retireBackedSTM svc
      modifySt svc (\st → st {stateOwner = OwnerStopped})

-- | The owner's tasks at its terminal step: their credits return to the edit bank and the
-- tasks are forgotten (their windows die with the owner).
retireBackedSTM ∷ Service → STM ()
retireBackedSTM svc = do
  st <- readSt svc
  forM_ (Map.elems (stateGathers st)) $ \task → modifyTVar' (serviceEditBank svc) (releaseCredit (gatherGrant task))
  forM_ (stateSlot st >>= slotCredit) $ \g → modifyTVar' (serviceEditBank svc) (releaseCredit g)
  modifySt svc $ \s →
    s
      { stateGathers = Map.empty
      , stateSlot = Nothing
      , stateOpens = Map.empty
      , stateCompiling = Nothing
      , stateLoadJobs = Map.empty
      }

-- | One piece of owner work.
data Work
  = WCloseSession
  | WStop
  | WVictim !R.RegionKey
  | WAck !R.JobId
  | WPrepare !RequestId
  | WCommit !RequestId
  | WRetry
  | WDispatch
  | WReport
  | WOpen !RequestId
  | WGather !GatherFor
  | WSlot
  | WGrant !Contender
  | WDrain !ArenaId

-- | Choose the next quantum, or wait until there is one. A transaction that retries wakes
-- when any state it read changes: a new command, a cancellation, a host's eligibility grant,
-- the parent session's admission, a stop, or a storage job a task waits for.
nextWork ∷ Service → StopToken → STM Work
nextWork svc token = do
  st <- readSt svc
  open <- sessionOpen (serviceAdmission svc)
  stopping <- stopRequested token
  adm <- readTVar (serviceEditBank svc)
  let model = stateModel st
      closing = statePhase st == Closing
      gathering = Set.fromList [jid | GatherJob jid ← Map.keys (stateGathers st)]
  if any (not . defectReported) (stateDefects st)
    then pure WReport
    else if (not open || stopping) && not closing
    then pure WCloseSession
    else case Seq.viewl (stateVictims st) of
      key Seq.:< _ → pure (WVictim key)
      Seq.EmptyL → case [R.jobId j | j <- R.modelJobs model, R.jobPhase j == R.JobCancellingPhase, not (Set.member (R.jobId j) gathering)] of
        jid : _ → pure (WAck jid)
        []
          | closing && stateBorrowers st == 0 && stopping && backedIdle st → pure WStop
          | otherwise → do
              (prepareWork, commitWork) <- pickRequestWork svc st adm
              grantWork <- if closing || isJust (stateSlot st) then pure Nothing else grantable st adm
              let (backedNow, backedWaits) = backedWork st
                  -- THE FAIRNESS RULE. Staging, commits, retries, load dispatches and the backed
                  -- steps take turns whenever two or more are ready: each ready kind gets one
                  -- quantum in every five, whatever the others are being fed. Within commits the
                  -- per-arena admission order is unchanged, and the model's own round-robin and
                  -- aging decide among loads.
                  retryWork = if stateFreed st && retryUseful st then Just WRetry else Nothing
                  dispatchWork =
                    if not (stateDispatchIdle st) && any ((== R.JobQueued) . R.jobPhase) (R.modelJobs model) && all (canStartGather st adm) (Map.keys (stateArenas st))
                      then Just WDispatch
                      else Nothing
                  backedReady = listToMaybe (catMaybes [grantWork] <> backedNow)
                  inTurn = case stateTurn st of
                    TurnPrepare → [prepareWork, commitWork, retryWork, dispatchWork, backedReady]
                    TurnCommit → [commitWork, retryWork, dispatchWork, backedReady, prepareWork]
                    TurnRetry → [retryWork, dispatchWork, backedReady, prepareWork, commitWork]
                    TurnDispatch → [dispatchWork, backedReady, prepareWork, commitWork, retryWork]
                    TurnBacked → [backedReady, prepareWork, commitWork, retryWork, dispatchWork]
              case listToMaybe (catMaybes inTurn) of
                Just work → pure work
                Nothing → foldr orElse retry [wait >> pure work | (wait, work) ← backedWaits]

-- | Nothing of the owner's backed work remains: no open, gather, transaction or closing file.
backedIdle ∷ St → Bool
backedIdle st = Map.null (stateOpens st) && Map.null (stateGathers st) && not (isJust (stateSlot st)) && Map.null (stateClosing st)

-- | The backed steps that can be taken now, and those that wait for a job.
backedWork ∷ St → ([Work], [(STM (), Work)])
backedWork st = (now, waits)
  where
    tasks =
      [openStep rid task | (rid, task) ← Map.toList (stateOpens st)]
        <> [gatherStep key task | (key, task) ← Map.toList (stateGathers st)]
        <> [slotReady task | Just task ← [stateSlot st]]
        <> [Just (Left (WDrain aid)) | aid ← Map.keys (stateClosing st), drainReady st aid]
    now = [w | Just (Left w) ← tasks]
    waits = [(stm, w) | Just (Right (stm, w)) ← tasks]
    wakeOr wake work = case wake of
      WakeNow → Just (Left work)
      WakeOn stm → Just (Right (stm, work))
    alive rid = Map.member rid (stateRequests st)
    openStep rid task = case openPhase task of
      OpenQueued
        | not (alive rid) → Just (Left (WOpen rid))
        | stateCompiling st == Nothing → Just (Left (WOpen rid))
        | otherwise → Nothing
      OpenCompiling {} → Just (Left (WOpen rid))
      OpenReserving _ _ _ _ _ wake
        | not (alive rid) → Just (Left (WOpen rid))
        | otherwise → wakeOr wake (WOpen rid)
      OpenPublishable {}
        | not (alive rid) → Just (Left (WOpen rid))
        | otherwise → Nothing
      OpenUnwinding _ _ wake → wakeOr wake (WOpen rid)
    -- a task whose owner ended is stepped at once to cancel it; once it drains it waits like any other
    gatherStep key task
      | (not (ownerAlive key) || not (Map.member (gatherArena task) (stateArenas st))) && not (readDraining (gatherRun task)) = Just (Left (WGather key))
      | otherwise = wakeOr (gatherWake task) (WGather key)
    readDraining = \case
      RunsRead g → gatherDraining g
      KnowledgeRead q → queryDraining q
      ProbeRead pr _ → probeDraining pr
    ownerAlive = \case
      GatherRequest rid → alive rid
      GatherJob jid → any (\j → R.jobId j == jid && R.jobPhase j == R.JobRunningPhase) (R.modelJobs (stateModel st))
    slotReady task
      | (slotYield task || not (Map.member (slotArena task) (stateArenas st)) || not (slotAlive (slotWork task))) && not (slotDraining (slotRun task)) = Just (Left WSlot)
      | otherwise = wakeOr (slotWake task) WSlot
    slotDraining = \case
      SlotTxn run → runDraining run
      SlotGrow run → growthDraining run
    slotAlive = \case
      SlotRemoval rid → alive rid
      SlotGrowth rid → alive rid
      SlotDiscovery → True
      SlotReclaim → True

-- | The contender the slot is granted to next, when its credits are available now.
grantable ∷ St → A.Admission → STM (Maybe Work)
grantable st adm = do
  candidates <- contenders st
  pure $ case candidates of
    c : _ | fits c → Just (WGrant c)
    _ → Nothing
  where
    fits c = either (const False) (const True) (A.reserve A.Foreground (A.transactionCredits (arenaOf c) A.worstTransactionCharge) adm)
    arenaOf = \case
      ContendRemoval _ a _ → a
      ContendGrowth _ a _ → a
      ContendDiscovery a → a
      ContendReclaim a → a

retryUseful ∷ St → Bool
retryUseful st =
  any (not . null . R.viewPending) (R.modelViews (stateModel st))
    || any needsResubmit (Map.elems (stateRequests st))

isDataCmd ∷ Cmd → Bool
isDataCmd = \case
  CCell {} → True
  CColumn {} → True
  CSurface {} → True
  CRemove {} → True
  CKnowledge {} → True
  _ → False

needsResubmit ∷ Req → Bool
needsResubmit req = isDataCmd (reqCmd req) && waitingReadmission req

-- | Work for the request table: stage whatever has its data (a read or a removal starts its
-- gather; an open its preparation), then commit the next eligible command of each arena in
-- admission order. A removal that changes content is not committed here: it takes the slot.
pickRequestWork ∷ Service → St → A.Admission → STM (Maybe Work, Maybe Work)
pickRequestWork _ st adm = do
  candidates <- fmap catMaybes (forM (Map.elems groups) firstEligible)
  pure
    ( case filter needsPrepare ordered of (rid, _) : _ → Just (WPrepare rid); [] → Nothing
    , case sortOn fst candidates of (_, rid) : _ → Just (WCommit rid); [] → Nothing
    )
  where
    model = stateModel st
    regionCov = Map.fromList [((R.regionArena r, R.regionCoord r), (R.regionCoverage r, R.regionEvicting r)) | r <- R.modelRegions model]
    reqInfo = Map.fromList [(R.requestId i, i) | i <- R.modelRequests model]
    ordered = sortOn (reqSeq . snd) (Map.toList (stateRequests st))
    live = [(rid, req) | (rid, req) <- ordered, not (isDoneReq req)]
    groups = Map.fromListWith (flip (<>)) [(reqArena req, [(rid, req)]) | (rid, req) <- live]
    isDoneReq req = case reqPhase req of Done → True; _ → False
    needsPrepare (rid, req) = case reqPhase req of
      Waiting → satisfied rid req && notStarted rid req
      StagedPhase sg → stale sg && notStarted rid req
      Done → False
    -- an open has one preparation task; a read or a removal one gather at a time, started only
    -- when its arena has a pin to spare and the edit bank its credit
    notStarted rid req = case reqCmd req of
      COpen {} → not (Map.member rid (stateOpens st))
      CAttach {} → True
      CGrow {} → True
      CRetry → True
      _ → not (Map.member (GatherRequest rid) (stateGathers st)) && maybe False (canStartGather st adm) (reqArena req)
    satisfied rid req = case reqCmd req of
      COpen {} → True
      CAttach {} → True
      CGrow {} → True
      CRetry → True
      cmd →
        reqModel req
          && maybe False (\aid → all (regionOk aid) (reqDemand req)) (reqArena req)
          && case cmd of
            CRemove {} → maybe False ((== 0) . R.requestResidentDeferred) (Map.lookup rid reqInfo)
            _ → True
    regionOk aid d = case Map.lookup (aid, R.demandRegion d) regionCov of
      Just (cover, False) → R.coverageSubset (R.demandCoverage d) cover
      _ → False
    stale sg = case stagedArena sg of
      Nothing → False
      Just aid → maybe False (\a → arenaRevision a /= stagedRevision sg || knowledgeMoved a sg) (Map.lookup aid (stateArenas st))
    knowledgeMoved a sg = case stagedWork sg of
      StagedAnswer (AKnowledge _) → D.authKnowledge (arenaAuthority a) /= stagedKnowledge sg
      _ → False
    firstEligible [] = pure Nothing
    firstEligible ((rid, req) : rest) = do
      eligible <- endpointEligible (reqEndpoint req)
      if not eligible
        then firstEligible rest
        else pure $ case reqPhase req of
          StagedPhase sg
            | not (stale sg)
            , not (takesSlot sg)
            , openMayCommit (reqCmd req) →
                Just (reqSeq req, rid)
          _ → Nothing
    takesSlot sg = case stagedWork sg of
      StagedRemoval prepared → preparedChanged prepared
      StagedGrowth _ → True
      StagedAnswer _ → False
      StagedControl → False
    -- opens publish in the order their incarnations were allocated
    openMayCommit = \case
      COpen {} → True
      _ → True

-- ---------------------------------------------------------------------------
-- Performing work

perform ∷ Service → Work → IO Bool
perform svc w = traceWork svc w >> perform' svc w

traceWork ∷ Service → Work → IO ()
traceWork svc w = do
  on <- lookupEnv "HETOIMASIA_TRACE_OWNER"
  t <- getMonotonicTime
  when (on == Just "1") $ do
    lg <- A.ledgers <$> readTVarIO (serviceEditBank svc)
    hPutStrLn stderr ("bank: cacheB=" <> show (A.lgCacheBacked lg) <> " cacheR=" <> show (A.lgCacheRamOnly lg) <> " pinned=" <> show (A.lgCachePinned lg) <> " stagF=" <> show (A.lgStagingForeground lg) <> " ctl=" <> show (A.lgControlReserved lg))
  when (on == Just "1") $ hPutStrLn stderr ("owner: " <> show (round (t * 1000000) :: Integer) <> " " <> case w of
    WCloseSession → "close"; WStop → "stop"; WVictim k → "victim " <> show k; WAck j → "ack " <> show j
    WPrepare r → "prepare " <> show r; WCommit r → "commit " <> show r; WRetry → "retry"; WDispatch → "dispatch"; WReport → "report"
    WOpen r → "open " <> show r; WGather k → "gather " <> show k; WSlot → "slot"; WGrant c → "grant " <> show c; WDrain a → "drain " <> show a)

perform' ∷ Service → Work → IO Bool
perform' svc = \case
  WStop → pure False
  WCloseSession → atomically (closeServiceSTM svc) >> pure True
  WVictim key → releaseVictim svc key >> pure True
  WAck jid → do
    atomically (void (applyEvent svc (R.JobAcknowledged jid)) >> endJobWork svc jid >> forgetLoad svc jid >> markFreed svc)
    pure True
  WPrepare rid → takeTurn svc TurnCommit >> prepareReq svc rid >> pure True
  WCommit rid → takeTurn svc TurnRetry >> commitReq svc rid >> pure True
  WRetry → takeTurn svc TurnDispatch >> retryPass svc >> pure True
  WDispatch → takeTurn svc TurnBacked >> dispatchJob svc >> pure True
  WOpen rid → do
    takeTurn svc TurnPrepare
    before <- stateCompiling <$> atomically (readSt svc)
    stepOpen svc (ops svc) rid
    after <- stateCompiling <$> atomically (readSt svc)
    -- the session's one compilation was charged to the compile account and starts now
    when (before /= Just rid && after == Just rid) (probe svc (PointCompiling rid))
    pure True
  WGather key → takeTurn svc TurnPrepare >> stepGatherTask svc key (delivered svc key) >> pure True
  WSlot → takeTurn svc TurnPrepare >> slotStep svc >> pure True
  WGrant contender → do
    takeTurn svc TurnPrepare
    granted <- atomically (grantSlot svc contender)
    when granted . probe svc $ case contender of
      ContendRemoval rid aid _ → PointGranted (Just rid) aid
      ContendGrowth rid aid _ → PointGranted (Just rid) aid
      ContendDiscovery aid → PointGranted Nothing aid
      ContendReclaim aid → PointGranted Nothing aid
    pure True
  WDrain aid → takeTurn svc TurnPrepare >> closeDrained svc aid >> pure True
  WReport → do
    -- A defect was recorded where nothing could throw (a host callback that failed
    -- inside a closing transaction). The cleanup is committed; now the owner ends
    -- with it, so supervision sees it.
    pending <- atomically (takeUnreportedSTM svc)
    evidence <- forM pending $ \defect →
      tryWithContext @SomeException (throwIO defect) >>= \case
        Left caught → pure ("terrain owner defect", caught)
        Right () → throwIO (OwnerDefect "a defect was not thrown")
    combined <- composeCleanup Nothing evidence
    forM_ combined rethrowIO
    pure True

-- | What the backed steps need of the owner.
ops ∷ Service → OwnerOps
ops svc =
  OwnerOps
    { opsStage = stage svc
    , opsDefect = \defect → failWith svc defect []
    }

-- | End the owner with a defect of the host or its accounting. The defect is
-- recorded as the one being thrown, the diagnostic is logged under protection,
-- and a failing logger can never replace it: the defect is thrown with the
-- logging failure attached as cleanup evidence.
failWith ∷ Service → Defect → [(Text, Text)] → IO a
failWith svc defect fields = do
  atomically (recordFatalDefect svc defect)
  logged <- tryWithContext @SomeException (logError (serviceLogger svc) terrainComponent "defect" fields)
  thrown <- tryWithContext @SomeException (throwIO defect)
  let primary = either Just (const Nothing) thrown
      evidence = [("diagnostic logging", e) | Left e <- [logged]]
  combined <- composeCleanup primary evidence
  maybe (throwIO defect) rethrowIO combined

-- | Log a diagnostic that must not decide anything: if the logger fails, that is
-- recorded as an unreported defect (so supervision hears of it) and the work goes on.
safeLog ∷ Service → IO () → IO ()
safeLog svc action =
  tryNonAsync action >>= \case
    Right () → pure ()
    Left failure → atomically (recordDefect svc (OwnerDefect (Text.pack ("diagnostic logging failed: " <> show failure))))

-- | Record whose turn is next.
takeTurn ∷ Service → Turn → IO ()
takeTurn svc next = atomically (modifySt svc (\st → st {stateTurn = next}))

probe ∷ Service → Point → IO ()
probe svc = probePoint (serviceProbe svc)

tryNonAsync ∷ IO a → IO (Either SomeException a)
tryNonAsync action =
  try action >>= \case
    Left failure | Just (_ ∷ SomeAsyncException) <- fromException failure → throwIO failure
    result → pure result

-- | Discard a committed victim's detail, then tell the model.
releaseVictim ∷ Service → R.RegionKey → IO ()
releaseVictim svc key@(aid, region) = do
  probe svc (PointVictim aid region)
  atomically $ do
    modifySt svc $ \st →
      st
        { stateVictims = case Seq.viewl (stateVictims st) of
            k Seq.:< rest | k == key → rest
            _ → stateVictims st
        , stateArenas = Map.adjust discard aid (stateArenas st)
        , stateRetiring = Map.adjust discard aid (stateRetiring st)
        }
    void (applyEvent svc (R.VictimReleased aid region))
    markFreed svc
  where
    discard a = a {arenaResident = discardRegion region (arenaResident a), arenaGeneration = bumpGeneration (arenaGeneration a)}

-- ---------------------------------------------------------------------------
-- Load jobs

-- | Start the next queued load job: the model dispatches it (it holds a load-job slot from
-- now to its report) and its region's columns are gathered from the committed store; the
-- job's work runs when they have been read.
dispatchJob ∷ Service → IO ()
dispatchJob svc = do
  started <- atomically $ do
    outcome <- applyEvent svc R.Dispatch
    case outcome of
      Right report
        | R.Dispatched jid (aid, region) cover <- R.reportDecision report → do
            startJobWork svc jid cover
            case realPieces region cover of
              Left why → pure (Just (jid, Left why))
              Right pieces → do
                let columns = Set.toList (Set.fromList [c | (c, _) ← pieces])
                modifySt svc (\st → st {stateLoadJobs = Map.insert jid (aid, region, cover) (stateLoadJobs st)})
                ok <- startGatherFor svc (GatherJob jid) aid (ReadRuns columns)
                pure (Just (jid, if ok then Right () else Left "no pin was available for a dispatched load"))
      _ → modifySt svc (\st → st {stateDispatchIdle = True}) >> pure Nothing
  forM_ started $ \case
    (_, Right ()) → pure ()
    (jid, Left why) → do
      defect <- atomically (finishJob svc jid (Left why))
      forM_ defect $ \text → failWith svc (AccountingDefect text) []

forgetLoad ∷ Service → R.JobId → STM ()
forgetLoad svc jid = modifySt svc (\st → st {stateLoadJobs = Map.delete jid (stateLoadJobs st)})

-- | Report a job's outcome and keep its detail if it was published. Returns an
-- accounting defect when the model refuses what a valid job reported.
finishJob ∷ Service → R.JobId → Either String (Palette, Resident, R.Cost) → STM (Maybe Text)
finishJob svc jid result = do
  -- The job's report ends its record, in the same transaction as the report.
  endJobWork svc jid
  st <- readSt svc
  let aid = maybe Nothing (\(a, _, _) → Just a) (Map.lookup jid (stateLoadJobs st))
      cancelling = not (null [() | j <- R.modelJobs (stateModel st), R.jobId j == jid, R.jobPhase j == R.JobCancellingPhase])
  forgetLoad svc jid
  outcome <-
    if cancelling
      then Nothing <$ applyEvent svc (R.JobAcknowledged jid)
      else case result of
        Left why → do
          applyEvent svc (R.JobFailed jid) >>= \case
            Right report | R.JobFailedFor _ owners _ _ <- R.reportDecision report →
              forM_ [rid | R.OwnerRequest rid <- owners] $ \rid →
                terminate svc rid (Failed (SourceFailure (Text.pack why)))
            _ → pure ()
          pure Nothing
        Right (palette, resident, cost) →
          applyEvent svc (R.JobCompleted jid cost) >>= \case
            Right report
              | R.Published {} <- R.reportDecision report → do
                  forM_ aid $ \a →
                    modifySt svc $ \s →
                      s {stateArenas = Map.adjust (\x → x {arenaPalette = palette, arenaResident = resident, arenaGeneration = bumpGeneration (arenaGeneration x)}) a (stateArenas s)}
                  pure Nothing
              | otherwise → pure Nothing
            Left refusal → do
              let why = Text.pack ("job completion refused: " <> show refusal)
              recordFatalDefect svc (AccountingDefect why)
              pure (Just why)
  markFreed svc
  pure outcome

-- ---------------------------------------------------------------------------
-- Gathers delivered

-- | What a finished gather gives its owner: a request's staging, or a load job's work.
delivered ∷ Service → GatherFor → Gathered → IO ()
delivered svc key gathered = case (key, gathered) of
  (_, GatheredNothing) → case key of
    GatherJob jid → atomically $ do
      -- a cancelled job's gather has drained: only now is its cancellation acknowledged
      st <- readSt svc
      when (any (\j → R.jobId j == jid && R.jobPhase j == R.JobCancellingPhase) (R.modelJobs (stateModel st))) $ do
        void (applyEvent svc (R.JobAcknowledged jid))
        endJobWork svc jid
        forgetLoad svc jid
        markFreed svc
    GatherRequest _ → pure ()
  (GatherRequest rid, GatheredRuns runs revision) → stageFromRuns svc rid runs revision
  (GatherRequest rid, GatheredFailed handling) → handleRequest svc rid handling
  (GatherRequest rid, GatheredKnowledge known content knowledge) → do
    st <- atomically (readSt svc)
    forM_ (Map.lookup rid (stateRequests st) >>= reqArena) $ \aid →
      stageWith svc rid (Just aid) content knowledge (StagedAnswer (AKnowledge (KnowledgeAnswer aid content knowledge known)))
  (GatherJob jid, GatheredKnowledge {}) → failWith svc (OwnerDefect (Text.pack ("a load job's read answered knowledge: " <> show jid))) []
  (GatherJob jid, GatheredProbe {}) → failWith svc (OwnerDefect (Text.pack ("a load job's read answered a probe: " <> show jid))) []
  (GatherRequest rid, GatheredProbe probed passed) → finishRetry svc rid (if passed then probed else [])
  (GatherJob jid, GatheredRuns runs revision) → do
    st <- atomically (readSt svc)
    case Map.lookup jid (stateLoadJobs st) of
      Nothing → pure ()
      Just (aid, region, cover) → do
        -- The runs are those of the version the gather pinned. A commit since then changed only
        -- the columns of its own cell, and the model cancels a job of that cell's region (its
        -- result is then discarded by 'finishJob'); a job of any other region read columns no
        -- commit changed, which the model's restamp says too.
        result <- case Map.lookup aid (stateArenas st) of
          Just arena →
            evaluate $ do
              changes <- either (Left . Text.unpack) Right (changesOfRuns (serviceConfig svc) runs)
              runJob (arenaSource arena) changes (arenaPalette arena) (arenaResident arena) region cover
          Nothing → pure (Left "arena closed while its load ran")
        _ <- pure revision
        probe svc (PointJob aid region)
        defect <- atomically (finishJob svc jid result)
        forM_ defect $ \why → failWith svc (AccountingDefect why) []
  (GatherJob jid, GatheredFailed handling) → do
    st <- atomically (readSt svc)
    let aid = (\(a, _, _) → a) <$> Map.lookup jid (stateLoadJobs st)
    case handling of
      HandlePause condition fault → atomically $ do
        forM_ aid $ \a → pauseArena svc a condition fault []
        void (finishJob svc jid (Left (show fault)))
      HandleClosing → void (atomically (finishJob svc jid (Left "arena closed while its load ran")))
      HandleDefect why → failWith svc (OwnerDefect why) []
      other → failWith svc (OwnerDefect (Text.pack ("a load's read ended unexpectedly: " <> show other))) []

-- | A request's runs were read: compute its staging from the source and those runs, and stage it.
stageFromRuns ∷ Service → RequestId → [(Column, Int64, Int64)] → Revision → IO ()
stageFromRuns svc rid runs revision = do
  st <- atomically (readSt svc)
  forM_ (Map.lookup rid (stateRequests st)) $ \req →
    forM_ (reqArena req >>= \aid → (,) aid <$> Map.lookup aid (stateArenas st)) $ \(aid, arena) →
      -- runs read at a version the arena has moved past are read again
      when (arenaRevision arena == revision) $
        case changesOfRuns config runs of
          Left why → atomically (terminate svc rid (Failed (HostFailure ("the removed runs a read gathered are not valid changes: " <> why))))
          -- The preparation runs under the request's credits (R1): from here to its safe point nothing the
          -- request holds is released, whoever cancels it or closes its arena meanwhile.
          Right changes → case reqCmd req of
            CRemove tile _ →
              running svc rid (tryNonAsync (probe svc (PointStaging rid) >> evaluate (prepareRemoval (changeLimitsOf config) (arenaSource arena) changes tile))) >>= \case
                Nothing → pure ()
                Just (Left failure) → atomically (terminate svc rid (Failed (HostFailure (Text.pack ("preparation failed: " <> show failure)))))
                Just (Right (Left why)) → atomically (terminate svc rid (Failed (HostFailure (Text.pack ("preparation refused: " <> why)))))
                Just (Right (Right prepared)) → stage svc rid (Just aid) revision (StagedRemoval prepared)
            cmd →
              running svc rid (probe svc (PointCaptured rid aid revision) >> evaluate (readAnswer config aid revision (arenaSource arena) changes cmd)) >>= \case
                Nothing → pure ()
                Just (Left failure) → atomically (terminate svc rid (Failed failure))
                Just (Right (answer, demands))
                  -- the demand this answer needs differs from the one admitted (a surface whose top the
                  -- removals lowered): the request is admitted again with the demand its gather found
                  | demands /= reqDemand req → atomically $ do
                      modifySt svc (\s → s {stateRequests = Map.adjust (\q → q {reqDemand = demands}) rid (stateRequests s)})
                      readmitSTM svc rid
                  | otherwise → stage svc rid (Just aid) revision (StagedAnswer answer)
  where
    config = serviceConfig svc

-- | Run one request's preparation under its credits (R1). From here to the safe point at its end,
-- nothing the request holds is released, whoever cancels it, releases its lease or closes its arena
-- meanwhile; those releases are deferred to the safe point, which is also reached when an exception
-- ends the preparation. Nothing when the request was already gone.
running ∷ Service → RequestId → IO a → IO (Maybe a)
running svc rid work = do
  began <- atomically (beginRunning svc rid)
  if not began
    then pure Nothing
    else do
      result <- work `onException` atomically (safePointSTM svc)
      atomically (safePointSTM svc)
      pure (Just result)

-- | What a request's failed read means for it.
handleRequest ∷ Service → RequestId → Handling → IO ()
handleRequest svc rid = \case
  HandlePause condition fault → atomically $ do
    st <- readSt svc
    forM_ (Map.lookup rid (stateRequests st) >>= reqArena) $ \aid → pauseArena svc aid condition fault []
    terminate svc rid (Failed (StorageFailed fault))
  HandleDomain fault → atomically (terminate svc rid (Failed (StorageFailed fault)))
  HandleClosing → pure ()
  HandleRetryLater _ → pure ()
  HandleDefect why → failWith svc (OwnerDefect why) []
  other → failWith svc (OwnerDefect (Text.pack ("a request's read ended unexpectedly: " <> show other))) []

-- ---------------------------------------------------------------------------
-- Staging and committing requests

-- | Start the staging of a request: an open's preparation, an attach's arbitration, or the
-- gather of the runs a read or a removal reads.
prepareReq ∷ Service → RequestId → IO ()
prepareReq svc rid = do
  st <- atomically (readSt svc)
  forM_ (Map.lookup rid (stateRequests st)) $ \req → case reqCmd req of
    COpen _ source _ → atomically (beginOpen svc rid source)
    CAttach {} → stage svc rid Nothing (Revision 0) StagedControl
    CGrow bytes → forM_ (reqArena req >>= \aid → (,) aid <$> Map.lookup aid (stateArenas st)) $ \(aid, arena) →
      -- the store's pure proposal against the allowance as it is now: equal is an idempotent success,
      -- smaller is storage_size_not_increased, larger takes the slot when the host is eligible
      case proposeGrowth (arenaStore arena) (toInteger bytes) of
        GrowthNoOp → stage svc rid (Just aid) (arenaRevision arena) (StagedAnswer (AGrown (GrowAnswer aid bytes False)))
        GrowthNotIncreased → atomically (terminate svc rid (Failed (StorageFailed (FaultSizeNotIncreased (cfgAllowanceBytes (storeConfig (arenaStore arena))) bytes))))
        GrowthInvalid why → atomically (terminate svc rid (Failed (HostFailure (Text.pack ("an admitted growth became invalid: " <> show why)))))
        GrowthProposed proposal → stage svc rid (Just aid) (arenaRevision arena) (StagedGrowth proposal)
    CRetry → forM_ (reqArena req >>= \aid → (,) aid <$> Map.lookup aid (stateArenas st)) $ \(aid, arena) → do
      -- bounded revalidation of what paused the arena: the pages an I/O or integrity pause recorded
      -- are read again (an integrity page must read back valid); a pause that recorded none cannot be
      -- certified and stays. Capacity is checked when the retry finishes.
      let store = arenaStore arena
          probed = [(c, record) | c ← [CondIo, CondIntegrity], c `elem` conditions store, Just record ← [Map.lookup c (arenaFaults arena)], not (null (faultPages' record))]
          pages = [(page, if c == CondIntegrity then ReadValidated else ReadProbe) | (c, record) ← probed, page ← faultPages' record]
          faultPages' = faultRecorded
      if null pages
        then finishRetry svc rid []
        else void (atomically (startGatherFor svc (GatherRequest rid) aid (ReadPages pages (map fst probed))))
    CKnowledge tile → forM_ (reqArena req) $ \aid → void (atomically (startGatherFor svc (GatherRequest rid) aid (ReadKnowledge tile)))
    cmd → forM_ (reqArena req) $ \aid → void (atomically (startGatherFor svc (GatherRequest rid) aid (ReadRuns (commandColumns cmd))))

-- | Publish staged work and tell the host it is ready. Work whose arena has moved
-- on since it was computed is dropped; the owner computes it again. A readiness
-- callback that fails is a provider defect: nothing is staged, the defect is
-- recorded, and the owner ends, settling every request once.
stage ∷ Service → RequestId → Maybe ArenaId → Revision → StagedWork → IO ()
stage svc rid aid rev work = do
  st <- atomically (readSt svc)
  let knowledge = maybe (Revision 0) (D.authKnowledge . arenaAuthority) (aid >>= \a → Map.lookup a (stateArenas st))
  stageWith svc rid aid rev knowledge work

-- | 'stage' with the knowledge revision the work was read at.
stageWith ∷ Service → RequestId → Maybe ArenaId → Revision → Revision → StagedWork → IO ()
stageWith svc rid aid rev knowledge work =
  tryNonAsync (atomically publish') >>= \case
    Right () → pure ()
    Left failure → do
      failWith svc (ProviderDefect (Text.pack ("readiness callback failed: " <> show failure))) [("request", Text.pack (show rid))]
  where
    publish' = do
        st <- readSt svc
        forM_ (Map.lookup rid (stateRequests st)) $ \req → do
          let fresh = case aid of
                Nothing → True
                Just a → maybe False (\x → arenaRevision x == rev && D.authKnowledge (arenaAuthority x) == knowledge) (Map.lookup a (stateArenas st))
              pending = case reqPhase req of Done → False; _ → True
          when (fresh && pending) $ do
            modifySt svc (\s → s {stateRequests = Map.insert rid req {reqPhase = StagedPhase (Staged aid rev knowledge work)} (stateRequests s)})
            -- A failing readiness callback abandons this transaction: the work stays
            -- unstaged and cannot commit. The caller treats it as a provider defect.
            endpointReady (reqEndpoint req)

-- | Offer staged work to the arbitration.
commitReq ∷ Service → RequestId → IO ()
commitReq svc rid = do
  probe svc (PointBeforeCommit rid)
  attempt <- tryNonAsync (atomically (commitTx svc rid))
  case attempt of
    Right (CommitDone aid rev) → do
      forM_ rev (probe svc . PointCommitted rid)
      forM_ aid $ \a → safeLog svc (logInfo (serviceLogger svc) terrainComponent "arena opened" [("arena", Text.pack (show a))])
    Right (CommitDefect why) → do
      atomically (terminate svc rid (Failed (HostFailure why)))
      failWith svc (AccountingDefect why) [("request", Text.pack (show rid))]
    Right CommitWaiting → pure ()
    Left failure → do
      -- A host callback failed inside the arbitration. Nothing was committed
      -- (the transaction was abandoned); the request ends without a second
      -- call into the host and the defect reaches supervision.
      atomically $ do
        st <- readSt svc
        forM_ (Map.lookup rid (stateRequests st)) (releaseReq svc rid)
      failWith svc (ProviderDefect (Text.pack ("settlement callback failed: " <> show failure))) [("request", Text.pack (show rid))]

data CommitResult
  = CommitDone !(Maybe ArenaId) !(Maybe Revision)
  | CommitWaiting
  | CommitDefect !Text

-- | The arbitration of a request that publishes no new store root: a read's answer, an open,
-- an attach, and a removal of air (which changes nothing). One transaction decides the commit
-- and the cancellation, the parent session's admission and the arena's closure that race with
-- it; a host callback runs last, so a failure anywhere abandons the whole transaction.
commitTx ∷ Service → RequestId → STM CommitResult
commitTx svc rid = do
  open <- sessionOpen (serviceAdmission svc)
  st <- readSt svc
  case Map.lookup rid (stateRequests st) of
    Just req | StagedPhase sg <- reqPhase req →
      if statePhase st /= Running || not open
        then pure CommitWaiting
        else do
          eligible <- endpointEligible (reqEndpoint req)
          if eligible then commitStaged svc st rid req sg else pure CommitWaiting
    _ → pure CommitWaiting

commitStaged ∷ Service → St → RequestId → Req → Staged → STM CommitResult
commitStaged svc st rid req sg = case (reqCmd req, stagedWork sg) of
  (COpen name source cid, StagedControl) → commitOpen name source cid
  (CAttach name cid, StagedControl) → commitAttach name cid
  (CRemove _ precondition, StagedRemoval prepared)
    | not (preparedChanged prepared) → withFresh $ \aid arena → commitAir aid arena precondition
    | otherwise → pure CommitWaiting
  (_, StagedAnswer answer) → withFresh $ \aid _ → do
    modifySt svc (\s → s {stateRequests = Map.insert rid req {reqPhase = Done} (stateRequests s)})
    endpointSettle ep (Succeeded answer)
    pure (CommitDone (Just aid) Nothing)
  _ → pure CommitWaiting
  where
    ep = reqEndpoint req
    tag = serviceTag svc
    -- Staged work for a superseded revision is not offered: the owner computes
    -- it again against the current one.
    withFresh k = case stagedArena sg >>= \aid → (,) aid <$> Map.lookup aid (stateArenas st) of
      Just (aid, arena) | arenaRevision arena == stagedRevision sg, knowledgeFresh arena → k aid arena
      _ → pure CommitWaiting
    -- a knowledge answer is current only while the knowledge revision it was read at holds
    knowledgeFresh arena = case stagedWork sg of
      StagedAnswer (AKnowledge _) → D.authKnowledge (arenaAuthority arena) == stagedKnowledge sg
      _ → True
    commitOpen name source cid = case (openReady st rid, internSourceMaterials source emptyPalette) of
      (_, Left why) → settleFailure (SourceFailure (Text.pack (show why)))
      (Nothing, _) → pure CommitWaiting
      (Just (aid, env, shared, backing, store), Right palette)
        | not (openOrderAllows st aid) → pure CommitWaiting
        | stateNextLease st == maxBound → settleFailure (HostFailure "identities exhausted")
        | otherwise → do
            let lid = stateNextLease st
            applyEvent svc (R.OpenArena aid (arenaRevisionOf store)) >>= \case
              Left refusal → pure (CommitDefect (Text.pack ("open refused: " <> show refusal)))
              Right _ → do
                let arena =
                      Arena
                        { arenaName = name
                        , arenaSource = source
                        , arenaPalette = palette
                        , arenaResident = emptyResident
                        , arenaStore = store
                        , arenaBacking = backing
                        , arenaEnv = env
                        , arenaShared = shared
                        , arenaFaults = Map.empty
                        , arenaGeneration = 0
                        , arenaCreator = cid
                        , arenaLeases = Set.singleton lid
                        }
                modifySt svc $ \s →
                  s
                    { stateNextLease = lid + 1
                    , stateArenas = Map.insert aid arena (stateArenas s)
                    , stateLeases = Map.insert lid (LeaseRec cid aid True True) (stateLeases s)
                    , stateClients = Map.adjust (\c → c {clientLeases = Set.insert lid (clientLeases c)}) cid (stateClients s)
                    , stateNames = Map.insert name (ClaimLive aid) (stateNames s)
                    , stateRequests = Map.delete rid (stateRequests s)
                    , stateOpens = Map.delete rid (stateOpens s)
                    }
                endpointSettle ep (Succeeded (AOpened (ArenaLease tag lid)))
                pure (CommitDone (Just aid) Nothing)
    arenaRevisionOf store = D.authContent (D.hAuthority (storeHeader store))
    commitAttach name cid = case Map.lookup name (stateNames st) of
      Just (ClaimLive aid)
        | Just arena <- Map.lookup aid (stateArenas st)
        , Map.member cid (stateClients st)
        , stateNextLease st /= maxBound → do
            let lid = stateNextLease st
            modifySt svc $ \s →
              s
                { stateNextLease = lid + 1
                , stateLeases = Map.insert lid (LeaseRec cid aid (arenaCreator arena == cid) True) (stateLeases s)
                , stateClients = Map.adjust (\c → c {clientLeases = Set.insert lid (clientLeases c)}) cid (stateClients s)
                , stateArenas = Map.adjust (\a → a {arenaLeases = Set.insert lid (arenaLeases a)}) aid (stateArenas s)
                , stateRequests = Map.delete rid (stateRequests s)
                }
            endpointSettle ep (Succeeded (AAttached (ArenaLease tag lid)))
            pure (CommitDone Nothing Nothing)
      -- A pending open is not visible until it has settled, and an absent name is absent.
      _ → settleFailure NotFound
    settleFailure failure = do
      terminateWith False svc rid (Failed failure)
      pure (CommitDone Nothing Nothing)
    -- Removing air changes nothing: no history, no obligation, no revision; the
    -- reservations return and the result is kept until it is taken.
    commitAir aid arena precondition
      | staleView aid arena precondition = settleFailure StaleView
      | otherwise = do
          withdrawRecord svc rid req
          modifySt svc (\s → s {stateRequests = Map.insert rid req {reqPhase = Done, reqModel = False} (stateRequests s)})
          endpointSettle ep (Succeeded (ARemoved (RemoveAnswer aid (arenaRevision arena) False)))
          pure (CommitDone (Just aid) (Just (arenaRevision arena)))
    staleView aid arena = \case
      Just (Precondition pa pr) → pa /= aid || pr /= arenaRevision arena
      Nothing → False

-- | Retry what waits for capacity: pending camera demand, then requests that
-- are waiting to be admitted again, in admission order.
retryPass ∷ Service → IO ()
retryPass svc = atomically $ do
  modifySt svc (\st → st {stateFreed = False})
  void (applyEvent svc R.Service)
  modifySt svc (\st → st {stateDispatchIdle = False})
  st <- readSt svc
  forM_ [rid | (rid, req) <- sortOn (reqSeq . snd) (Map.toList (stateRequests st)), needsResubmit req] (readmitSTM svc)

-- ---------------------------------------------------------------------------
-- The slot

-- | One step of the slot's transaction, and what follows from where it stopped.
slotStep ∷ Service → IO ()
slotStep svc =
  stepSlot svc >>= \case
    SlotGoesOn → pure ()
    SlotEligible task tid plan → publishSlot svc task tid plan
    SlotOver task done → slotOver svc task done
    SlotGrowthReady task prepared → publishGrowth svc task prepared
    SlotGrowthOver task over → growthOver svc task over

-- | Every page of the slot's transaction is written: prepare the decision outside any
-- transaction, force it, and make it.
publishSlot ∷ Service → SlotTask → TxnId → Plan → IO ()
publishSlot svc task tid plan = do
  st <- atomically (readSt svc)
  let aid = slotArena task
  case Map.lookup aid (stateArenas st) of
    -- the arena closed: the next step cancels the run
    Nothing → pure ()
    Just arena → do
      for <- case slotWork task of
        SlotDiscovery → pure (Just ForBatch)
        SlotReclaim → pure (Just ForBatch)
        SlotGrowth _ → failWith svc (OwnerDefect "a growth reached a store transaction's publication") []
        SlotRemoval rid → case Map.lookup rid (stateRequests st) of
          Just req
            | CRemove tile precondition <- reqCmd req
            , StagedPhase sg <- reqPhase req
            , StagedRemoval prepared <- stagedWork sg → do
                let newContent = D.authContent (effAuthority (plEffects plan))
                    (region, _) = decomposeTile tile
                    generation = regionGenerationOf st aid region
                unless (effTerrain (plEffects plan)) $
                  failWith svc (OwnerDefect "a removal staged as a change planned no change of terrain") []
                rebuilt <- evaluate (rebuildCell (arenaSource arena) (preparedChanges prepared) (arenaPalette arena) (arenaResident arena) tile)
                case (rebuilt, generation) of
                  (Right (palette, resident, growth), Just g) → do
                    _ <- evaluate palette
                    _ <- evaluate resident
                    pure (Just (ForRemoval rid tile precondition (RemoveAnswer aid newContent True) g palette resident growth))
                  (Left why, _) → failWith svc (OwnerDefect (Text.pack ("the removed cell's segment could not be rebuilt: " <> why))) []
                  (_, Nothing) → failWith svc (OwnerDefect "a removal's region is not resident at its decision") []
          -- the request ended: the next step cancels the run
          _ → pure Nothing
      forM_ for $ \decisionFor →
        case prepareDecision aid (arenaStore arena) tid plan decisionFor of
          Left why → failWith svc (OwnerDefect why) []
          Right decision → do
            _ <- evaluate (decNext decision)
            forM_ (removalOf (slotWork task)) (probe svc . PointBeforeCommit)
            verdict <- tryNonAsync (atomically (decide svc (slotCredit task) decision))
            case verdict of
              Right (Committed authority) → do
                forM_ (removalOf (slotWork task)) $ \rid → probe svc (PointCommitted rid (D.authContent authority))
              Right LostToEnd → pure ()
              Right NotEligible → yieldSlot Nothing
              Right StagingMoved → yieldSlot (removalOf (slotWork task))
              Left failure → do
                -- a host callback failed inside the decision, or the model refused an event the
                -- checks admitted: nothing was written, and the defect reaches supervision
                forM_ (removalOf (slotWork task)) $ \rid → atomically $ do
                  s <- readSt svc
                  forM_ (Map.lookup rid (stateRequests s)) (releaseReq svc rid)
                failWith svc (ProviderDefect (Text.pack ("the publication decision failed: " <> show failure))) []
  where
    removalOf = \case
      SlotRemoval rid → Just rid
      SlotGrowth rid → Just rid
      SlotDiscovery → Nothing
      SlotReclaim → Nothing
    -- the holder gives the slot up: its transaction is aborted with no write by the next steps,
    -- and a request whose staging moved is staged again
    yieldSlot restage = atomically $ do
      modifySt svc (\s → s {stateSlot = fmap (\t → t {slotYield = True}) (stateSlot s)})
      forM_ restage $ \rid → modifySt svc (\s → s {stateRequests = Map.adjust (\q → q {reqPhase = Waiting}) rid (stateRequests s)})
    regionGenerationOf st aid region =
      case [R.regionGeneration r | r ← R.modelRegions (stateModel st), R.regionArena r == aid, R.regionCoord r == region] of
        g : _ → Just g
        [] → Nothing

-- | The slot's transaction ended without publishing (its slot and credits are already
-- released): what that means for its work.
slotOver ∷ Service → SlotTask → Done → IO ()
slotOver svc task done = do
  let aid = slotArena task
      key reclaim = (aid, reclaim)
      markIdle reclaim = atomically $ modifySt svc $ \s →
        case Map.lookup aid (stateArenas s) of
          Just arena → s {stateInternalIdle = Map.insert (key reclaim) (storeVersion (arenaStore arena), oldestPin (arenaStore arena)) (stateInternalIdle s)}
          Nothing → s
      needsMaintenance = atomically (modifySt svc (\s → s {stateNeedsMaintenance = Set.insert aid (stateNeedsMaintenance s)}))
  case (slotWork task, done) of
    (_, Drained) → pure ()
    (_, Remake) → pure ()
    (_, MaintenanceFirst) → needsMaintenance
    (_, Aborted handling) → aborted aid (slotWork task) handling
    (SlotRemoval rid, NothingToDo) →
      -- the store says the cell is air: the removal is staged again from what the store holds now
      atomically (modifySt svc (\s → s {stateRequests = Map.adjust (\q → q {reqPhase = Waiting}) rid (stateRequests s)}))
    (SlotRemoval _, ReaderBlocks _ _) → failWith svc (OwnerDefect "a removal's plan waited for a reader") []
    (SlotGrowth _, _) → failWith svc (OwnerDefect "a growth reached a store transaction") []
    (SlotDiscovery, NothingToDo) → markIdle False
    (SlotDiscovery, ReaderBlocks _ _) → markIdle False
    (SlotReclaim, NothingToDo) → markIdle True
    (SlotReclaim, ReaderBlocks _ _) → markIdle True
  where
    aborted aid work = \case
      HandlePause condition fault → atomically (pauseArena svc aid condition fault [])
      HandlePausedFor condition → atomically $ do
        s <- readSt svc
        forM_ (removalOf work) $ \rid →
          forM_ (Map.lookup aid (stateArenas s) >>= Map.lookup condition . arenaFaults) $ \record →
            terminate svc rid (Failed (StorageFailed (faultOf record)))
      HandleDomain fault → atomically (forM_ (removalOf work) $ \rid → terminate svc rid (Failed (StorageFailed fault)))
      HandleRetryLater _ → pure ()
      HandleReplan → pure ()
      HandleWaitReclaim _ _ → atomically (modifySt svc (\s → s {stateNeedsMaintenance = Set.insert aid (stateNeedsMaintenance s)}))
      HandleClosing → pure ()
      -- a revision or the store's version would wrap: the arena takes no further history. A removal
      -- that passed admission settles as superseded; internal work of the arena stops (it is offered
      -- again only when the committed version moves, which it can no longer do)
      HandleExhausted → case removalOf work of
        Just rid → atomically (terminate svc rid (Failed (Superseded "the arena's revisions are exhausted")))
        Nothing → atomically $ modifySt svc $ \s → case Map.lookup aid (stateArenas s) of
          Just arena → s {stateInternalIdle = foldr (\k → Map.insert (aid, k) (storeVersion (arenaStore arena), oldestPin (arenaStore arena))) (stateInternalIdle s) [False, True]}
          Nothing → s
      HandleSerialize → failWith svc (OwnerDefect "the slot's transaction was refused for another transaction") []
      HandleDefect why → failWith svc (OwnerDefect why) []
    removalOf = \case
      SlotRemoval rid → Just rid
      SlotGrowth rid → Just rid
      SlotDiscovery → Nothing
      SlotReclaim → Nothing

-- | A growth obtained its extra: the decision commits the store's cap, the backend's cap and the
-- creator's answer in one transaction, or finds the request ended or no longer eligible (the
-- extra is then given back by the next steps).
publishGrowth ∷ Service → SlotTask → PreparedGrowth → IO ()
publishGrowth svc task prepared = do
  st <- atomically (readSt svc)
  forM_ ((,) <$> growthRequest (slotWork task) <*> Map.lookup (slotArena task) (stateArenas st)) $ \(rid, arena) →
    case prepareGrowthDecision (slotArena task) (arenaStore arena) rid prepared of
      Left why → failWith svc (OwnerDefect why) []
      Right decision → do
        _ <- evaluate (decNext decision)
        tryNonAsync (atomically (decide svc Nothing decision)) >>= \case
          Right (Committed _) → pure ()
          Right LostToEnd → pure ()
          Right NotEligible → yield
          Right StagingMoved → yield
          Left failure → do
            atomically $ do
              s <- readSt svc
              forM_ (Map.lookup rid (stateRequests s)) (releaseReq svc rid)
            failWith svc (ProviderDefect (Text.pack ("the publication decision failed: " <> show failure))) []
  where
    growthRequest = \case
      SlotGrowth rid → Just rid
      _ → Nothing
    yield = atomically (modifySt svc (\s → s {stateSlot = fmap (\t → t {slotYield = True}) (stateSlot s)}))

-- | A growth ended without being committed (its slot is already released): its request settles
-- with the failure, or contends again when the owner gave it up for its host's eligibility.
growthOver ∷ Service → SlotTask → Growth.GrowthEnd → IO ()
growthOver svc task over = case slotWork task of
  SlotGrowth rid → case over of
    Growth.GrowthFailedWith handling → case handling of
      HandleDomain fault → atomically (terminate svc rid (Failed (StorageFailed fault)))
      HandleReplan → atomically (modifySt svc (\s → s {stateRequests = Map.adjust (\q → q {reqPhase = Waiting}) rid (stateRequests s)}))
      HandleClosing → pure ()
      HandleDefect why → failWith svc (OwnerDefect why) []
      other → failWith svc (OwnerDefect (Text.pack ("a growth ended unexpectedly: " <> show other))) []
    Growth.GrowthWithdrawn → pure ()
    Growth.GrowthLeftPending _ → pure ()
  _ → failWith svc (OwnerDefect "a growth ended in a slot that was not a growth's") []

-- | Finish an explicit retry: clear the conditions its probe certified gone and, when the supported
-- next transaction fits beside the protected reserve, the capacity pause; then answer what was cleared
-- and what remains. One transaction (the owner is the store's only writer). Never re-runs a failed edit.
finishRetry ∷ Service → RequestId → [Condition] → IO ()
finishRetry svc rid certified = do
  answer <- atomically $ do
    s <- readSt svc
    case Map.lookup rid (stateRequests s) >>= reqArena >>= \aid → (,) aid <$> Map.lookup aid (stateArenas s) of
      Nothing → pure Nothing
      Just (aid, arena) → do
        let store = arenaStore arena
            fits = availablePages (storeConfig store) Ordinary (storeRoots store) >= fromIntegral maxClaimPages
            cleared = [c | c ← conditions store, c `elem` certified || (c == CondCapacity && fits)]
            store' = foldr clearCondition store cleared
        modifySt svc $ \x →
          x {stateArenas = Map.insert aid arena {arenaStore = store', arenaFaults = foldr Map.delete (arenaFaults arena) cleared} (stateArenas x)}
        when (not (null cleared)) (markFreed svc)
        pure (Just (aid, arenaRevision arena, RetryAnswer aid cleared (conditions store')))
  forM_ answer $ \(aid, revision, retried) → stage svc rid (Just aid) revision (StagedAnswer (ARetried retried))
