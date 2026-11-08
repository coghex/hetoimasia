-- | The terrain owner thread: the sole writer of arena contents.
--
-- The owner loops over bounded quanta. Each quantum chooses one piece of work in
-- a transaction ('nextWork'), does its pure computation outside any transaction,
-- and publishes the result in a second transaction that revalidates what the
-- computation assumed. Waiting for a host's eligibility, for a load or for a
-- caller is waiting in 'nextWork' for a state that changes: the owner never
-- blocks inside a quantum, so other eligible work and closure are always
-- serviced.
--
-- == Commit order
--
-- Among the eligible commands of one arena, the owner commits in admission
-- order. A command that is not yet eligible does not hold up the others, and a
-- command that is eligible but not yet staged holds up the later ones, so the
-- same ordered trace of eligible commands yields the same terrain and the same
-- content revisions however the residency scheduler interleaved the loads.
--
-- == Revalidation
--
-- Staged work is tagged with the incarnation and content revision it was built
-- for. A commit publishes it only if the arena still has that incarnation and
-- revision; otherwise the owner recomputes it against the current revision
-- before it is offered again. Work is never relabeled with a newer revision.
module Hetoimasia.Terrain.Runtime.Internal.Owner
  ( ownerDefinition
  , terrainComponent
  ) where

import Control.Concurrent.STM
import Control.Exception (SomeAsyncException, SomeException, fromException, mask, onException, rethrowIO, throwIO, try, tryWithContext, uninterruptibleMask_)
import Control.Monad (forM, forM_, void, when)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, listToMaybe)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Component, logError, logInfo, unsafeComponent)
import Hetoimasia.Foundation.Resource (Scoped, composeCleanup)
import Hetoimasia.Foundation.Worker (StopToken, WorkerDefinition, stopRequested, workerDefinition)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), changesBytes, emptyChanges, mergeChanges)
import Hetoimasia.Terrain.Coordinate (RegionCoord, decomposeTile)
import Hetoimasia.Terrain.Palette (Palette, emptyPalette, internSourceMaterials)
import qualified Hetoimasia.Terrain.Residency as R
import Hetoimasia.Terrain.Residency (ArenaId (..), RequestId (..), Revision (..))
import Hetoimasia.Terrain.Resident (Resident, discardRegion, emptyResident)
import Hetoimasia.Terrain.Runtime.Internal.Content
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Types

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
    loop = do
      work <- tryNonAsync (atomically (nextWork svc token)) >>= \case
        Right chosen → pure chosen
        Left failure → do
          -- Choosing work reads every host's eligibility: a callback that throws
          -- is a provider defect, recorded, and the owner ends.
          failWith svc (ProviderDefect (Text.pack ("eligibility callback failed: " <> show failure))) []
      continue <- perform svc work
      when continue loop
    -- Whatever ended the loop, every accepted request leaves the table settled
    -- exactly once and the owner is marked stopped. This is non-blocking
    -- bookkeeping, so it is safe under the uninterruptible mask.
    terminal = do
      safePointSTM svc
      closeServiceSTM svc
      retireInFlightSTM svc
      modifySt svc (\st → st {stateOwner = OwnerStopped})

-- | One piece of owner work.
data Work
  = WCloseSession
  | WStop
  | WVictim !R.RegionKey
  | WAck !R.JobId
  | WHandoff !ArenaId !RegionCoord
  | WPrepare !RequestId
  | WCommit !RequestId
  | WRetry
  | WDispatch
  | WReport

-- | Choose the next quantum, or wait until there is one. A transaction that
-- retries wakes when any state it read changes: a new command, a cancellation,
-- a host's eligibility grant, the parent session's admission, or a stop.
nextWork ∷ Service → StopToken → STM Work
nextWork svc token = do
  st <- readSt svc
  open <- sessionOpen (serviceAdmission svc)
  stopping <- stopRequested token
  let model = stateModel st
      closing = statePhase st == Closing
  if any (not . defectReported) (stateDefects st)
    then pure WReport
    else if (not open || stopping) && not closing
    then pure WCloseSession
    else case Seq.viewl (stateVictims st) of
      key Seq.:< _ → pure (WVictim key)
      Seq.EmptyL → case [R.jobId j | j <- R.modelJobs model, R.jobPhase j == R.JobCancellingPhase] of
        jid : _ → pure (WAck jid)
        [] → case handoffCandidate st of
          Just (aid, region) → pure (WHandoff aid region)
          Nothing
            | closing && stateBorrowers st == 0 && stopping → pure WStop
            | otherwise →
                pickRequestWork st >>= \(prepareWork, commitWork) → do
                  -- THE FAIRNESS RULE. Staging, commits, retries and load
                  -- dispatches take turns whenever two or more are ready: each
                  -- ready kind gets one quantum in every four, whatever the others are being
                  -- fed, so a continuous stream of one (new reads, replacements,
                  -- cache hits elsewhere) cannot starve another. Within commits
                  -- the per-arena admission order is unchanged, and the model's
                  -- own round-robin and aging decide among loads.
                  let retryWork = if stateFreed st && retryUseful st then Just WRetry else Nothing
                      dispatchWork = if not (stateDispatchIdle st) && any ((== R.JobQueued) . R.jobPhase) (R.modelJobs model) then Just WDispatch else Nothing
                      inTurn = case stateTurn st of
                        TurnPrepare → [prepareWork, commitWork, retryWork, dispatchWork]
                        TurnCommit → [commitWork, retryWork, dispatchWork, prepareWork]
                        TurnRetry → [retryWork, dispatchWork, prepareWork, commitWork]
                        TurnDispatch → [dispatchWork, prepareWork, commitWork, retryWork]
                  maybe retry pure (listToMaybe (catMaybes inTurn))

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
  _ → False

needsResubmit ∷ Req → Bool
needsResubmit req = isDataCmd (reqCmd req) && waitingReadmission req

-- | A changed region whose retained changes are not yet transferred, and whose
-- transfer has not already been tried at its current generation.
handoffCandidate ∷ St → Maybe (ArenaId, RegionCoord)
handoffCandidate st =
  listToMaybe
    [ (R.regionArena r, R.regionCoord r)
    | r <- R.modelRegions (stateModel st)
    , R.regionDirty r
    , R.regionHandoff r == Nothing
    , not (R.regionEvicting r)
    , Map.member (R.regionArena r) (stateArenas st)
    , Map.lookup (R.regionArena r, R.regionCoord r) (stateTransfers st) /= Just (R.regionGeneration r)
    , -- refused for want of capacity at this very epoch: reconsidered when it moves
      Map.lookup (R.regionArena r, R.regionCoord r) (stateHandoffBusy st) /= Just (stateCapacityEpoch st)
    ]

-- | Work for the request table: stage whatever has its data, then commit the
-- next eligible command of each arena in admission order.
pickRequestWork ∷ St → STM (Maybe Work, Maybe Work)
pickRequestWork st = do
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
      Waiting → satisfied rid req
      StagedPhase sg → stale sg
      Done → False
    satisfied rid req = case reqCmd req of
      COpen {} → True
      CAttach {} → True
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
      Just aid → maybe False (\a → arenaRevision a /= stagedRevision sg) (Map.lookup aid (stateArenas st))
    firstEligible [] = pure Nothing
    firstEligible ((rid, req) : rest) = do
      eligible <- endpointEligible (reqEndpoint req)
      if not eligible
        then firstEligible rest
        else pure $ case reqPhase req of
          StagedPhase sg | not (stale sg) → Just (reqSeq req, rid)
          _ → Nothing

-- ---------------------------------------------------------------------------
-- Performing work

perform ∷ Service → Work → IO Bool
perform svc = \case
  WStop → pure False
  WCloseSession → atomically (closeServiceSTM svc) >> pure True
  WVictim key → releaseVictim svc key >> pure True
  WAck jid → do
    atomically (void (applyEvent svc (R.JobAcknowledged jid)) >> markFreed svc)
    pure True
  WHandoff aid region → handoff svc aid region >> pure True
  WPrepare rid → takeTurn svc TurnCommit >> prepareReq svc rid >> pure True
  WCommit rid → takeTurn svc TurnRetry >> commitReq svc rid >> pure True
  WRetry → takeTurn svc TurnDispatch >> retryPass svc >> pure True
  WDispatch → takeTurn svc TurnPrepare >> dispatchJob svc >> pure True
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

changeLimitsOf ∷ Config → ChangeLimits
changeLimitsOf config =
  ChangeLimits (fromInteger (min (toInteger (maxBound ∷ Int)) (toInteger (R.limitBytes (configLimits config) R.EditBank `div` 16))))

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
        , stateTransfers = Map.delete key (stateTransfers st)
        }
    void (applyEvent svc (R.VictimReleased aid region))
    markFreed svc
  where
    discard a = a {arenaResident = discardRegion region (arenaResident a), arenaGeneration = bumpGeneration (arenaGeneration a)}

regionGeneration ∷ St → ArenaId → RegionCoord → Maybe Word
regionGeneration st aid region =
  listToMaybe [fromIntegral (R.regionGeneration r) | r <- R.modelRegions (stateModel st), R.regionArena r == aid, R.regionCoord r == region]

-- | Transfer a changed region's working changes to the retained store.
--
-- The model reserves the temporary duplicate, the transfer runs (an injected
-- failure here is a failed transfer), and the outcome is reported. A failed
-- transfer keeps the working changes, the protection and the charges; it is not
-- retried until the region changes again. The authority for reads never moves:
-- it is the union of store and working, so a transfer cannot change any answer.
handoff ∷ Service → ArenaId → RegionCoord → IO ()
handoff svc aid region = do
  (busy, started) <- atomically $ do
    st <- readSt svc
    let generation = maybe 0 fromIntegral (regionGeneration st aid region)
        tried = modifySt svc (\s → s {stateTransfers = Map.insert (aid, region) generation (stateTransfers s)})
    case Map.lookup aid (stateArenas st) of
      Nothing → tried >> pure (False, Nothing)
      Just arena → do
        let working = Map.lookup region (arenaWorking arena)
            duplicate = maybe 0 (fromIntegral . changesBytes) working
        applyEvent svc (R.BeginHandoff aid region duplicate) >>= \case
          Right _ → pure (False, Just working)
          -- Capacity pressure is not a failed transfer: the region stays a candidate
          -- and is reconsidered when capacity is returned (R2). Only a refusal that
          -- can never clear ends the attempt.
          Left (R.Busy _) → modifySt svc (\s → s {stateHandoffBusy = Map.insert (aid, region) (stateCapacityEpoch s) (stateHandoffBusy s)}) >> pure (True, Nothing)
          Left _ → tried >> pure (False, Nothing)
  when busy (probe svc (PointHandoffBusy aid region))
  forM_ started $ \working → do
    outcome <- tryNonAsync (probe svc (PointHandoff aid region))
    atomically $ do
      st <- readSt svc
      let generation = maybe 0 fromIntegral (regionGeneration st aid region)
      modifySt svc (\s → s {stateTransfers = Map.insert (aid, region) generation (stateTransfers s)})
      case outcome of
        Right () → do
          modifySt svc $ \s →
            s
              { stateTransfers = Map.delete (aid, region) (stateTransfers s)
              , stateArenas =
                  Map.adjust
                    (\a → a {arenaStore = maybe (arenaStore a) (mergeChanges (arenaStore a)) working, arenaWorking = Map.delete region (arenaWorking a)})
                    aid
                    (stateArenas s)
              }
          void (applyEvent svc (R.HandoffConfirmed aid region))
        Left _ → void (applyEvent svc (R.HandoffFailed aid region))
      markFreed svc
    probe svc (PointHandoffReported aid region (either (const False) (const True) outcome))

-- | Run the next queued load job on real resident detail.
dispatchJob ∷ Service → IO ()
dispatchJob svc = do
  dispatched <- atomically (applyEvent svc R.Dispatch)
  case dispatched of
    Right report
      | R.Dispatched jid (aid, region) cover <- R.reportDecision report → do
          mArena <- atomically (Map.lookup aid . stateArenas <$> readSt svc)
          probe svc (PointJob aid region)
          let result = case mArena of
                Just a → runJob (arenaSource a) (arenaChanges a) (arenaPalette a) (arenaResident a) region cover
                Nothing → Left "arena closed while its load ran"
          defect <- atomically (finishJob svc jid aid result)
          forM_ defect $ \why → throwIO (AccountingDefect why)
    _ → atomically (modifySt svc (\st → st {stateDispatchIdle = True}))

-- | Report a job's outcome and keep its detail if it was published. Returns an
-- accounting defect when the model refuses what a valid job reported.
finishJob ∷ Service → R.JobId → ArenaId → Either String (Palette, Resident, R.Cost) → STM (Maybe Text)
finishJob svc jid aid result = do
  st <- readSt svc
  let cancelling = not (null [() | j <- R.modelJobs (stateModel st), R.jobId j == jid, R.jobPhase j == R.JobCancellingPhase])
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
                  modifySt svc $ \s →
                    s {stateArenas = Map.adjust (\a → a {arenaPalette = palette, arenaResident = resident, arenaGeneration = bumpGeneration (arenaGeneration a)}) aid (stateArenas s)}
                  pure Nothing
              | otherwise → pure Nothing
            Left refusal → do
              let why = Text.pack ("job completion refused: " <> show refusal)
              recordFatalDefect svc (AccountingDefect why)
              pure (Just why)
  markFreed svc
  pure outcome

-- | Compute work for a request whose data is resident, and stage it.
prepareReq ∷ Service → RequestId → IO ()
prepareReq svc rid = do
  snapshot <- atomically $ do
    st <- readSt svc
    pure $ do
      req <- Map.lookup rid (stateRequests st)
      pure (req, reqArena req >>= \aid → (,) aid <$> Map.lookup aid (stateArenas st))
  forM_ snapshot $ \(req, current) → case reqCmd req of
    COpen {} → stage svc rid Nothing (Revision 0) StagedControl
    CAttach {} → stage svc rid Nothing (Revision 0) StagedControl
    CRemove tile _ → forM_ current $ \(aid, arena) →
      running svc rid
        ( tryNonAsync $ do
            probe svc (PointStaging rid)
            -- Prepare the content change and prove the rebuild succeeds now; the
            -- rebuild itself is repeated against the residency at commit.
            pure $! prepareRemoval (changeLimitsOf config) (arenaSource arena) (arenaChanges arena) tile >>= \ready →
              ready <$ rebuildCell (arenaSource arena) (preparedChanges ready) (arenaPalette arena) (arenaResident arena) tile
        )
        >>= \case
          Nothing → pure ()
          Just (Left failure) → fail' (HostFailure (Text.pack ("preparation failed: " <> show failure)))
          Just (Right (Left why)) → fail' (HostFailure (Text.pack ("preparation refused: " <> why)))
          Just (Right (Right ready)) → stage svc rid (Just aid) (arenaRevision arena) (StagedRemoval ready)
    cmd → forM_ current $ \(aid, arena) →
      running svc rid (probe svc (PointCaptured rid aid (arenaRevision arena)) >> (pure $! readAnswer config aid (arenaRevision arena) arena cmd)) >>= \case
        Nothing → pure ()
        Just (Left failure) → fail' failure
        Just (Right (answer, demands))
          | demands /= reqDemand req → atomically (resubmitSTM svc rid)
          | otherwise → stage svc rid (Just aid) (arenaRevision arena) (StagedAnswer answer)
  where
    config = serviceConfig svc
    fail' failure = atomically (terminate svc rid (Failed failure))

-- | Run one request's preparation under its credits (R1). From here to the safe
-- point at its end, nothing the request holds is released, whoever cancels it, releases
-- its lease or closes its arena meanwhile; those releases are deferred and happen
-- at the safe point, which is also reached when an exception ends the preparation.
-- Nothing when the request was already gone.
running ∷ Service → RequestId → IO a → IO (Maybe a)
running svc rid work = do
  began <- atomically (beginRunning svc rid)
  if not began
    then pure Nothing
    else do
      result <- work `onException` atomically (safePointSTM svc)
      atomically (safePointSTM svc)
      pure (Just result)

-- | Publish staged work and tell the host it is ready. Work whose arena has moved
-- on since it was computed is dropped; the owner computes it again. A readiness
-- callback that fails is a provider defect: nothing is staged, the defect is
-- recorded, and the owner ends, settling every request once.
stage ∷ Service → RequestId → Maybe ArenaId → Revision → StagedWork → IO ()
stage svc rid aid rev work =
  tryNonAsync (atomically publish) >>= \case
    Right () → pure ()
    Left failure → do
      failWith svc (ProviderDefect (Text.pack ("readiness callback failed: " <> show failure))) [("request", Text.pack (show rid))]
  where
    publish = do
        st <- readSt svc
        forM_ (Map.lookup rid (stateRequests st)) $ \req → do
          let fresh = case aid of
                Nothing → True
                Just a → maybe False ((== rev) . arenaRevision) (Map.lookup a (stateArenas st))
              pending = case reqPhase req of Done → False; _ → True
          when (fresh && pending) $ do
            modifySt svc (\s → s {stateRequests = Map.insert rid req {reqPhase = StagedPhase (Staged aid rev work)} (stateRequests s)})
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
      -- The model refused something a valid commit reported: the previous state
      -- was kept, the request fails, and the defect reaches supervision.
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

-- | The arbitration: one transaction decides the commit, and the cancellation,
-- the parent session's admission and the arena's closure that race with it.
-- Everything that could fail runs before the first write that matters, and a
-- host callback runs last, so a failure anywhere abandons the whole transaction.
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
  (CRemove tile precondition, StagedRemoval prepared) → withFresh $ \aid arena → commitRemoval aid arena tile precondition prepared
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
      Just (aid, arena) | arenaRevision arena == stagedRevision sg → k aid arena
      _ → pure CommitWaiting
    commitOpen name source cid = case internSourceMaterials source emptyPalette of
      Left why → settleFailure (SourceFailure (Text.pack (show why)))
      Right palette
        | stateNextArena st == maxBound || stateNextLease st == maxBound → settleFailure (HostFailure "identities exhausted")
        | otherwise → do
            let aid = ArenaId (stateNextArena st)
                lid = stateNextLease st
            applyEvent svc (R.OpenArena aid (Revision (configFirstRevision (serviceConfig svc)))) >>= \case
              Left refusal → pure (CommitDefect (Text.pack ("open refused: " <> show refusal)))
              Right _ → do
                let arena =
                      Arena
                        { arenaName = name
                        , arenaSource = source
                        , arenaPalette = palette
                        , arenaResident = emptyResident
                        , arenaChanges = emptyChanges
                        , arenaStore = emptyChanges
                        , arenaWorking = Map.empty
                        , arenaRevision = Revision (configFirstRevision (serviceConfig svc))
                        , arenaGeneration = 0
                        , arenaCreator = cid
                        , arenaLeases = Set.singleton lid
                        }
                modifySt svc $ \s →
                  s
                    { stateNextArena = stateNextArena s + 1
                    , stateNextLease = lid + 1
                    , stateArenas = Map.insert aid arena (stateArenas s)
                    , stateLeases = Map.insert lid (LeaseRec cid aid True True) (stateLeases s)
                    , stateClients = Map.adjust (\c → c {clientLeases = Set.insert lid (clientLeases c)}) cid (stateClients s)
                    , stateNames = Map.insert name (ClaimLive aid) (stateNames s)
                    , stateRequests = Map.delete rid (stateRequests s)
                    }
                endpointSettle ep (Succeeded (AOpened (ArenaLease tag lid)))
                pure (CommitDone (Just aid) Nothing)
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
    commitRemoval aid arena tile precondition prepared
      | staleView = settleFailure StaleView
      | not (preparedChanged prepared) = do
          -- Removing air changes nothing: the revision is unchanged and the
          -- reservations return.
          retainResult req
          endpointSettle ep (Succeeded (ARemoved (RemoveAnswer aid (arenaRevision arena) False)))
          pure (CommitDone (Just aid) (Just (arenaRevision arena)))
      | Revision n <- arenaRevision arena, n == maxBound = pure (CommitDefect "content revision exhausted after admission")
      | otherwise = case rebuildCell (arenaSource arena) (preparedChanges prepared) (arenaPalette arena) (arenaResident arena) tile of
          Left why → pure (CommitDefect (Text.pack ("resident rebuild refused: " <> why)))
          Right (palette', resident', growth) → do
           let Revision n = arenaRevision arena
               newRevision = Revision (n + 1)
               (region, _) = decomposeTile tile
           applyEvent svc (R.RemovalCommitted rid newRevision (preparedRetained prepared) growth) >>= \case
            Left refusal → pure (CommitDefect (Text.pack ("removal commit refused: " <> show refusal)))
            Right report → do
              modifySt svc $ \s →
                s
                  { stateArenas =
                      Map.adjust
                        ( \a →
                            a
                              { arenaPalette = palette'
                              , arenaResident = resident'
                              , arenaChanges = preparedChanges prepared
                              , arenaWorking = Map.insertWith mergeChanges region (preparedWorking prepared) (arenaWorking a)
                              , arenaRevision = newRevision
                              , arenaGeneration = bumpGeneration (arenaGeneration a)
                              }
                        )
                        aid
                        (stateArenas s)
                  , stateRequests = Map.insert rid req {reqPhase = Done, reqModel = False} (stateRequests s)
                  }
              -- Every other pending removal of the arena carries a reservation
              -- stamped with the old revision, and the readers that lost their
              -- work to the commit have none: admit them again at the new one.
              after <- readSt svc
              let lost = case R.reportDecision report of
                    R.Committed _ _ owners _ _ → [r | R.OwnerRequest r <- owners]
                    _ → []
                  others =
                    [ r
                    | (r, q) <- sortOn (reqSeq . snd) (Map.toList (stateRequests after))
                    , reqArena q == Just aid
                    , case reqPhase q of Done → False; _ → True
                    , isRemoval' q || r `elem` lost
                    ]
              forM_ others (resubmitSTM svc)
              markFreed svc
              endpointSettle ep (Succeeded (ARemoved (RemoveAnswer aid newRevision True)))
              pure (CommitDone (Just aid) (Just newRevision))
      where
        staleView = case precondition of
          Just (Precondition pa pr) → pa /= aid || pr /= arenaRevision arena
          Nothing → False
    isRemoval' q = case reqCmd q of CRemove {} → True; _ → False
    -- A settled result is kept, with its command slot, until its holder takes it.
    retainResult q = do
      withdrawRecord svc rid q
      modifySt svc (\s → s {stateRequests = Map.insert rid q {reqPhase = Done, reqModel = False} (stateRequests s)})

-- | Admit a request's demand to the model again, at the arena's current
-- revision: the request's record is withdrawn and a fresh one made in the same
-- transaction. If the model is busy the request waits, holding nothing, until
-- capacity frees; it is never failed for capacity.
resubmitSTM ∷ Service → RequestId → STM ()
resubmitSTM svc rid = do
  st <- readSt svc
  forM_ (Map.lookup rid (stateRequests st)) $ \req →
    forM_ (reqArena req >>= \aid → (,) aid <$> Map.lookup aid (stateArenas st)) $ \(aid, arena) → do
      when (reqModel req) (withdrawRecord svc rid req)
      case demandFor arena (reqCmd req) of
        Left why → terminate svc rid (Failed (SourceFailure (Text.pack why)))
        Right demands → do
          let event = case reqCmd req of
                CRemove tile _ → R.SubmitRemoval rid aid (arenaRevision arena) tile
                _ → R.SubmitQuery rid aid (arenaRevision arena) demands
          outcome <- applyEvent svc event
          let admitted = either (const False) (const True) outcome
          modifySt svc $ \s →
            s {stateRequests = Map.insert rid req {reqModel = admitted, reqDemand = demands, reqPhase = Waiting} (stateRequests s)}
          -- Every refusal is either temporary pressure, which keeps the request
          -- waiting (charged) to be admitted again, or permanent, which ends it
          -- with a typed failure; nothing can wait on a refusal that will not clear.
          case outcome of
            Right _ → pure ()
            Left refusal → case refusal of
              R.Busy _ → pure ()
              R.RetainedEditsExhausted {} → terminate svc rid (Failed (Superseded "the retained edits are full"))
              R.Invalid reason → terminate svc rid (Failed (Superseded (Text.pack ("no longer admissible: " <> show reason))))
              R.Stale _ → terminate svc rid (Failed ArenaClosed)
              R.ContractFailure why → do
                recordDefect svc (AccountingDefect (Text.pack (show why)))
                terminate svc rid (Failed (HostFailure (Text.pack ("resubmission: " <> show why))))

-- | Retry what waits for capacity: pending camera demand, then requests that
-- are waiting to be admitted again, in admission order.
retryPass ∷ Service → IO ()
retryPass svc = atomically $ do
  modifySt svc (\st → st {stateFreed = False})
  void (applyEvent svc R.Service)
  modifySt svc (\st → st {stateDispatchIdle = False})
  st <- readSt svc
  forM_ [rid | (rid, req) <- sortOn (reqSeq . snd) (Map.toList (stateRequests st)), needsResubmit req] (resubmitSTM svc)
