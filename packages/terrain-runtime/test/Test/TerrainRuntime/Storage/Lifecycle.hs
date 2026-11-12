-- | The invariants of the storage service, one checker, and the lifecycle matrix that closes the class round 2 of
-- review found: every KIND of work crossed with every PHASE of a job (queued, running at a gate, finished and
-- untaken, finished and borrowed) and every EVENT (cancel, discard, take, close its backing, service shutdown, an
-- exception in a cleanup step), each cell ending with the invariants holding.
--
-- 'checkInvariants' is one pure function over the service's snapshot, the shared admission's ledger and the
-- descriptors the seam sees open. It is run by the matrix after every cell and by the sweep and the random property
-- after every step; a state that breaks one fails the example that reached it.
module Test.TerrainRuntime.Storage.Lifecycle (spec, checkInvariants, invariantProblems) where

import Control.Concurrent (myThreadId, yield)
import Control.Concurrent.MVar
import GHC.Conc (BlockReason (..), ThreadStatus (..), threadStatus)
import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), ExceptionWithContext (..), SomeException, finally, throwIO, tryWithContext)
import Control.Monad (forM_, void, when)
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified Foreign.C.Error as C
import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, entryMessage, mkLogger)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, withResource)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (admit)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (pageFileOffset)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec)

mib :: Word64
mib = 1024 * 1024

h0 :: H
h0 = newStoreH smallSpec

eio :: Errno
eio = let C.Errno c = C.eIO in Errno (fromIntegral c)

-- ---------------------------------------------------------------------------
-- The checker

-- | Every way the state can be wrong, as text; empty when every invariant holds.
invariantProblems :: Snapshot -> A.Ledger -> [Int] -> [String]
invariantProblems sn ledger fds = concat
  [ [ "backing " <> show (bsId b) <> ": growth slot " <> show (bsSlot b) <> " but " <> show (length (liveOf b isGrow)) <> " live growth jobs"
    | b <- snBackings sn, (bsSlot b == SlotRunning) /= (length (liveOf b isGrow) == 1) || length (liveOf b isGrow) > 1 ]
  , [ "backing " <> show (bsId b) <> ": slot " <> show (bsSlot b) <> " but " <> show (length (liveOf b isRelease)) <> " live release jobs"
    | b <- snBackings sn, (bsSlot b == SlotReleasing) /= (length (liveOf b isRelease) == 1) || length (liveOf b isRelease) > 1 ]
  , [ "backing " <> show (bsId b) <> ": an untaken preparation exists but the slot is " <> show (bsSlot b)
    | b <- snBackings sn, any ((== Just (bsId b)) . jsPrepared) (snJobs sn), bsSlot b /= SlotPrepared ]
  , [ "descriptors open " <> show (length fds) <> " outside [" <> show nBack <> ", " <> show (nBack + snClosing sn + runningOpens) <> "]"
    | length fds < nBack || length fds > nBack + snClosing sn + runningOpens ]
  , [ "volume " <> show v <> " reserved " <> show r <> " but backings contribute " <> show (contribution v)
    | (v, r) <- Map.toList (snReserved sn), r /= contribution v ]
  , [ "volume " <> show v <> " has backings contributing " <> show c <> " but no reserved figure"
    | v <- map bsVolume (snBackings sn), c <- [contribution v], c /= 0, Map.notMember v (snReserved sn) ]
  , [ "control charges " <> show (A.lgControlReserved ledger) <> " but live records need " <> show controlNeed
    | A.lgControlReserved ledger /= controlNeed ]
  , [ "staging charged " <> show (A.lgStagingForeground ledger + A.lgStagingCamera ledger) <> " but running reads hold " <> show stagingNeed
    | A.lgStagingForeground ledger + A.lgStagingCamera ledger /= stagingNeed ]
  , [ "cache charged " <> show (A.lgCacheBacked ledger + A.lgCacheRamOnly ledger) <> " but held results need " <> show cacheNeed
    | A.lgCacheBacked ledger + A.lgCacheRamOnly ledger /= cacheNeed ]
  , [ "backing " <> show (bsId b) <> ": borrows " <> show (bsBorrows b) <> " but its jobs' borrowers are " <> show (sum [jsBorrowed j | j <- snJobs sn, jsBacking j == Just (bsId b)])
    | b <- snBackings sn, bsBorrows b /= sum [jsBorrowed j | j <- snJobs sn, jsBacking j == Just (bsId b)] ]
  , [ "queued " <> show (snQueued sn) <> " running " <> show (snRunning sn) <> " but the table has " <> show (nPhase 0, nPhase 1)
    | (snQueued sn, snRunning sn) /= (nPhase 0, nPhase 1) ]
  , [ "mutation slot " <> show (snMutation sn) <> " but live mutating jobs are " <> show (length mutating)
    | isJust (snMutation sn) /= (length mutating == 1) || length mutating > 1 ]
  ]
  where
    nBack = length (snBackings sn)
    live j = jsPhase j <= 1
    liveOf b p = [j | j <- snJobs sn, live j, jsBacking j == Just (bsId b), p (jsKind j)]
    isGrow k = k == KGrow
    isRelease k = k == KAbandon || k == KReleasePending
    runningOpens = length [() | j <- snJobs sn, jsKind j == KOpen, jsPhase j == 1]
    contribution v = sum [bsLength b + maybe 0 id (bsPending b) | b <- snBackings sn, bsVolume b == v]
    controlNeed = fromIntegral (length (snJobs sn)) * jobRecordBytes + fromIntegral nBack * backingRecordBytes
    stagingNeed = sum [transferBufferBytes n | j <- snJobs sn, jsPhase j == 1, KRead n <- [jsKind j]]
    cacheNeed = sum [fromIntegral n * resultPageBytes | j <- snJobs sn, KRead n <- [jsKind j], jsPhase j == 1 || jsHoldsResult j]
    nPhase p = length [() | j <- snJobs sn, jsPhase j == p]
    mutating = [j | j <- snJobs sn, live j, jsKind j `elem` [KWrite, KGrow, KGrowNoop, KAbandon, KReleasePending]]

-- | Check the invariants now (one transaction for the state and the ledger).
checkInvariants :: Env -> IO ()
checkInvariants env = do
  (sn, ledger) <- atomically ((,) <$> snapshotOf (envSvc env) <*> (A.ledgers <$> readTVar (envAdmission env)))
  fds <- openFds (envProbe env)
  invariantProblems sn ledger fds `shouldBe` []

-- ---------------------------------------------------------------------------
-- The lifecycle matrix

data Kind = KindOpen | KindRead | KindWrite | KindGrow | KindAbandon | KindReleasePending
  deriving stock (Eq, Show, Enum, Bounded)

data Phase = PhQueued | PhRunning | PhDone | PhBorrowed
  deriving stock (Eq, Show, Enum, Bounded)

data Event = EvCancel | EvDiscard | EvTake | EvClose | EvShutdown | EvCleanupException
  deriving stock (Eq, Show, Enum, Bounded)

isRd :: Word64 -> NativeOp -> Bool
isRd page op = op == OpReadAt (either (error . show) id (pageFileOffset (hCfg h0) (PageNo page))) pageSize

spec :: Spec
spec = describe "Storage backend: the lifecycle matrix" $ do
  it "keeps every invariant for every kind of work, in every phase, under every event" $ do
    cells <- sequence [expectCleanupEvidence ev (runCell k ph ev) | k <- [minBound .. maxBound], ph <- [minBound .. maxBound], ev <- [minBound .. maxBound]]
    putStrLn ("lifecycle matrix: " <> show (length cells) <> " cells (6 kinds x 4 phases x 6 events), " <> show (length (filter id cells)) <> " exercised an effect, the rest are no-ops by construction")

  it "attempts the descriptor's close even when the unlink cleanup throws (twice), and keeps the evidence" $ do
    withEnv $ \env -> do
      addRule (envProbe env) 2 (== OpUnlinkFile) Throw
      o <- submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)) >>= either (fail . show) pure >>= awaitOutcome env
      o `shouldSatisfy` \x -> case x of Failed (HostFailure t) _ -> "cleanup" `isIn` show t; _ -> False
      openFds (envProbe env) >>= (`shouldBe` [])
      checkInvariants env

  it "keeps the cleanup failures through the worker's failure boundary, in the outcome" $ do
    withEnv $ \env -> do
      addRule (envProbe env) 1 (== OpCloexecFlag) Throw
      addRule (envProbe env) 1 (== OpCloseFile) (FailWith eio)
      o <- submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)) >>= either (fail . show) pure >>= awaitOutcome env
      o `shouldSatisfy` \x -> case x of Failed (HostFailure t) _ -> "cleanup" `isIn` show t; _ -> False
      openFds (envProbe env) >>= (`shouldBe` [])

  it "surfaces the cleanup failure of an open nobody took when the service ends normally" $ do
    r <- (tryWithContext $ withEnv $ \env -> do
      addRule (envProbe env) 1 (\op -> case op of OpReserveRange _ _ -> True; _ -> False) (FailWith (Errno 28))
      addRule (envProbe env) 1 (== OpCloseFile) (FailWith eio)
      t <- submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)) >>= either (fail . show) pure
      bounded (atomically (awaitTicket (envSvc env) t))) :: IO (Either (ExceptionWithContext SomeException) ())
    case r of
      Left (ExceptionWithContext ctx _) -> length (cleanupFailuresInContext ctx) `shouldSatisfy` (>= 1)
      Right () -> expectationFailure "the cleanup failure of an untaken outcome was lost"

  it "joins a close another caller claimed: the service does not return while its native close is in flight" $
    withSystemTempDirectory "hetoimasia-terrain-lifecycle" $ \dir -> do
      cfg <- testConfigFor dir defaultOptions
      probe <- newProbe
      bank <- either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
      admission <- newTVarIO (A.newAdmission bank)
      handoff <- newEmptyMVar
      finish <- newEmptyMVar
      serviceDone <- newEmptyMVar
      serviceThread <- newEmptyMVar
      said <- newTVarIO []
      let quietLogger = mkLogger defaultLogFilter (callbackSink (\e -> atomically (modifyTVar' said (entryMessage e :))))
          runService group =
            withStorageService (StoragePorts admission group quietLogger (seamFor probe) cfg) $ \svc -> do
              t <- submitOpen svc ExplicitWork (OpenSpec (BC.pack dir) ident (hCfg h0)) >>= either (fail . show) pure
              bounded (atomically (awaitTicket svc t))
              o <- withOutcome svc t pure
              case o of
                Just (Opened b _) -> putMVar handoff (svc, b) >> takeMVar finish
                other -> fail (show other)
      withWorkerGroup $ \group ->
        withOwnedThread (myThreadId >>= putMVar serviceThread >> runService group >> putMVar serviceDone ()) $ \_ waitService -> do
          (svc, b) <- takeMVar handoff
          g <- addGate probe (== OpCloseFile)
          -- a failure must be a failure, never a hang: the gate opens whatever happens
          (`finally` openGate g) $ withOwnedThread (void (closeBacking svc b)) $ \_ waitCloser -> do
            awaitReached g 1
            -- the close is claimed and its native call is held: the service body returns, and the drain must wait for
            -- it. The wait is observed, not timed: the drain says so before it waits (a build whose drain does not
            -- wait never says it, and the bounded wait fails at once). After that message nothing else the drain does
            -- can block, so the service thread is then either blocked in the wait (STM) or running on to finish: the
            -- example polls its status (no sleep) until it is one or the other, and a drain that does not wait
            -- finishes, which fails here at once instead of passing by luck of timing
            tid <- readMVar serviceThread
            putMVar finish ()
            bounded (atomically (readTVar said >>= \ms -> check (drainWaitsMessage `elem` ms)))
            status <- bounded (let settle = threadStatus tid >>= \st -> case st of
                                              ThreadRunning -> yield >> settle
                                              ThreadBlocked BlockedOnMVar -> yield >> settle
                                              _ -> pure st
                               in settle)
            status `shouldBe` ThreadBlocked BlockedOnSTM
            tryReadMVar serviceDone >>= (`shouldSatisfy` (not . isJust))
            openGate g
            waitCloser
          waitService
      openFds probe >>= (`shouldBe` [])

  it "completes a close and the service's end when the logger raises on every entry" $
    withSystemTempDirectory "hetoimasia-terrain-lifecycle-log" $ \dir -> do
      cfg <- testConfigFor dir defaultOptions
      probe <- newProbe
      bank <- either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
      admission <- newTVarIO (A.newAdmission bank)
      let raisingLogger = mkLogger defaultLogFilter (callbackSink (\_ -> throwIO (ErrorCall "the sink raised")))
      withWorkerGroup $ \group ->
        bounded $ withStorageService (StoragePorts admission group raisingLogger (seamFor probe) cfg) $ \svc -> do
          t <- submitOpen svc ExplicitWork (OpenSpec (BC.pack dir) ident (hCfg h0)) >>= either (fail . show) pure
          atomically (awaitTicket svc t)
          o <- withOutcome svc t pure
          case o of
            Just (Opened b _) -> closeBacking svc b >>= \r -> crClosed r `shouldBe` True
            other -> fail (show other)
      openFds probe >>= (`shouldBe` [])

  it "keeps a callback's failure and its cleanup failures, with their context, through withOutcome and withUse" $
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      t <- submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= either (fail . show) pure
      bounded (atomically (awaitTicket (envSvc env) t))
      -- a scope inside the callback whose body and release both fail: the failure carries one cleanup failure
      let failing = withResource (pure ()) (\_ -> throwIO (ErrorCall "release")) (\_ -> throwIO (ErrorCall "body"))
      r1 <- tryWithContext (withOutcome (envSvc env) t (\_ -> failing)) :: IO (Either (ExceptionWithContext SomeException) (Maybe ()))
      r2 <- tryWithContext (withUse (envSvc env) b failing) :: IO (Either (ExceptionWithContext SomeException) (Either StorageFailure ()))
      forM_ [either (\(ExceptionWithContext c _) -> length (cleanupFailuresInContext c)) (const 0) r1, either (\(ExceptionWithContext c _) -> length (cleanupFailuresInContext c)) (const 0) r2] $ \n ->
        n `shouldBe` 1

  it "borrows the opened backing for the duration of a callback on its Opened outcome" $
    withEnv $ \env -> do
      t <- submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)) >>= either (fail . show) pure
      bounded (atomically (awaitTicket (envSvc env) t))
      entered <- newEmptyMVar
      withOwnedThread (takeMVar entered >>= \b -> void (closeBacking (envSvc env) b)) $ \_ waitClose -> do
        r <- withOutcome (envSvc env) t $ \o -> case o of
          Opened b _ -> do
            (bvBorrows <$> (atomically (backingView (envSvc env) b) >>= maybe (fail "no backing") pure)) >>= (`shouldBe` 1)
            putMVar entered b
            bounded (atomically (backingView (envSvc env) b >>= \v -> check (maybe False bvClosing v)))
            -- the close waits for this callback: the descriptor is still open inside it
            openFds (envProbe env) >>= (`shouldSatisfy` ((== 1) . length))
          other -> fail (show other)
        r `shouldSatisfy` isJust
        waitClose
      openFds (envProbe env) >>= (`shouldBe` [])
  where
    isIn needle hay = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay]

-- ---------------------------------------------------------------------------
-- One cell

-- | A cell that injects an exception into a cleanup step may end with the service's own end reporting that failure (an
-- outcome nobody took carries it): that is the evidence being kept, and it must carry labelled cleanup failures. Any
-- other exception, and any such exception in another cell, is a failure.
expectCleanupEvidence :: Event -> IO Bool -> IO Bool
expectCleanupEvidence ev cell
  | ev /= EvCleanupException = cell
  | otherwise = do
      r <- tryWithContext cell :: IO (Either (ExceptionWithContext SomeException) Bool)
      case r of
        Right x -> pure x
        Left (ExceptionWithContext ctx e) -> do
          (show e, length (cleanupFailuresInContext ctx)) `shouldSatisfy` \(_, n) -> n >= 1
          pure True

-- | Run one cell; answers whether the event had an effect to check (some cells are no-ops by construction).
runCell :: Kind -> Phase -> Event -> IO Bool
runCell kind phase ev = do
  withEnv $ \env -> do
    let probe = envProbe env
        svc = envSvc env
    b <- openBacking env ident (hCfg h0)
    -- the state a kind of work needs first
    token <- case kind of
      KindAbandon -> Just <$> prepared env b
      _ -> pure Nothing
    when (kind == KindReleasePending) $ do
      addRuleAfter probe 1 1 (== OpStatFile) (OverAllocated (10 * mib))
      addRule probe 1 (== OpSetFileLength (64 * mib)) (FailWith eio)
      void (submitGrowth svc b (64 * mib) (128 * mib) >>= either (fail . show) pure >>= awaitOutcome env)
    -- holders keep both workers busy for the queued phase
    holders <- if phase == PhQueued
      then do
        g1 <- addGate probe (isRd 100)
        g2 <- addGate probe (isRd 101)
        t1 <- submitRead svc b ExplicitWork (hCfg h0) (PageNo 100) 1 ReadProbe >>= either (fail . show) pure
        t2 <- submitRead svc b ExplicitWork (hCfg h0) (PageNo 101) 1 ReadProbe >>= either (fail . show) pure
        awaitReached g1 1
        awaitReached g2 1
        pure [(g1, t1), (g2, t2)]
      else pure []
    -- the gate that holds the job under test at its characteristic native call
    held <- if phase == PhRunning
      then Just <$> addGate probe (heldOp kind)
      else pure Nothing
    -- an exception in a cleanup step, installed before the job runs
    when (ev == EvCleanupException) $ case kind of
      KindOpen -> addRule probe 1 (\op -> case op of OpReserveRange _ _ -> True; _ -> False) (FailWith (Errno 28)) >> addRule probe 1 (== OpCloseFile) Throw
      KindGrow -> addRuleAfter probe 1 1 (== OpStatFile) (OverAllocated (10 * mib)) >> addRule probe 1 (== OpSetFileLength (64 * mib)) Throw
      KindAbandon -> addRule probe 1 (== OpSetFileLength (64 * mib)) Throw
      KindReleasePending -> addRule probe 1 (== OpSetFileLength (64 * mib)) Throw
      _ -> pure ()
    submitted <- submitKind env b token kind
    t <- either (\f -> fail ("submit refused: " <> show f)) pure submitted
    forM_ held $ \g -> awaitReached g 1
    when (phase `elem` [PhDone, PhBorrowed]) (bounded (atomically (awaitTicket svc t)))
    checkInvariants env
    -- the event, in the phase
    let event = case ev of
          EvCancel -> void (cancelTicket svc t)
          EvDiscard -> discardTicket svc t
          EvTake -> void (withOutcome svc t pure)
          EvClose -> closeAndRelease env b holders held
          EvShutdown -> pure ()
          EvCleanupException -> pure ()
    case (phase, ev) of
      -- a close of the backing while its outcome is borrowed waits for the borrower: it runs on a thread of its own,
      -- started from inside the callback, and the callback returns once the close is seen to be waiting
      (PhBorrowed, EvClose) -> do
        signal <- newEmptyMVar
        withOwnedThread (takeMVar signal >> void (closeBacking svc b)) $ \_ waitClose -> do
          void (withOutcome svc t (\_ -> do
            checkInvariants env
            putMVar signal ()
            bounded (atomically (backingView svc b >>= \v -> check (maybe True bvClosing v)))
            checkInvariants env))
          forM_ holders (openGate . fst)
          forM_ held openGate
          waitClose
      (PhBorrowed, _) -> void (withOutcome svc t (\_ -> checkInvariants env >> event))
      _ -> event
    -- everything is let go, the work settles, and the invariants hold
    forM_ holders (openGate . fst)
    forM_ held openGate
    settle env
    checkInvariants env
    -- what the event must have left recoverable (the reviewer's reproductions 1 and 2)
    recovered <- case (kind, phase, ev) of
      (KindGrow, PhQueued, _) | ev `elem` [EvCancel, EvDiscard] -> expectAdmitted (submitGrowth svc b (64 * mib) (128 * mib))
      (KindAbandon, PhQueued, _) | ev `elem` [EvCancel, EvDiscard] -> maybe (pure False) (\p -> (== Right ()) <$> commitBackingGrowth svc b p) token
      (KindReleasePending, PhQueued, _) | ev `elem` [EvCancel, EvDiscard] -> expectAdmitted (submitReleasePending svc b)
      (KindGrow, PhDone, EvDiscard) -> expectAdmitted (submitReleasePending svc b)
      -- a discard of a running growth is also a cancellation: the arbitration cancels it, the extra is released, the slot is idle
      (KindGrow, PhRunning, EvDiscard) -> expectAdmitted (submitGrowth svc b (64 * mib) (128 * mib))
      _ -> pure True
    recovered `shouldBe` True
    settle env
    checkInvariants env
    pure (ev `elem` [EvCancel, EvDiscard, EvClose, EvCleanupException])
  where
    settle env = bounded (atomically (snapshotOf (envSvc env) >>= \sn -> check (snRunning sn == 0 && snQueued sn == 0)))
    expectAdmitted act = either (const False) (const True) <$> act

heldOp :: Kind -> NativeOp -> Bool
heldOp k = case k of
  KindOpen -> \op -> case op of OpReserveRange _ _ -> True; _ -> False
  KindRead -> isRd 200
  KindWrite -> \op -> case op of OpWriteAt _ _ -> True; _ -> False
  KindGrow -> \op -> case op of OpReserveRange _ _ -> True; _ -> False
  KindAbandon -> (== OpSetFileLength (64 * mib))
  KindReleasePending -> (== OpSetFileLength (64 * mib))

submitKind :: Env -> Backing -> Maybe PreparedGrowth -> Kind -> IO (Either StorageFailure Ticket)
submitKind env b token kind = case kind of
  KindOpen -> submitOpen svc ExplicitWork (OpenSpec (BC.pack (envDir env)) ident2 (hCfg h0))
  KindRead -> submitRead svc b ExplicitWork (hCfg h0) (PageNo 200) 1 ReadProbe
  KindWrite -> do
    let plan = either error id (planFor h0 1)
    (tid, s1) <- either (fail . show) pure (admit plan (hStore h0))
    sw <- either (fail . show) pure (stageWrite s1 tid)
    submitWrite svc b sw
  KindGrow -> submitGrowth svc b (64 * mib) (128 * mib)
  KindAbandon -> maybe (fail "no token") (submitAbandon svc b) token
  KindReleasePending -> submitReleasePending svc b
  where
    svc = envSvc env

-- | Close a backing while the work is in whatever phase: in a thread of its own, since it may wait for held work, which
-- is then let go.
closeAndRelease :: Env -> Backing -> [(Gate, Ticket)] -> Maybe Gate -> IO ()
closeAndRelease env b holders held =
  withOwnedThread (void (closeBacking (envSvc env) b)) $ \_ waitClose -> do
    bounded (atomically (backingView (envSvc env) b >>= \v -> check (maybe True bvClosing v)))
    forM_ holders (openGate . fst)
    forM_ held openGate
    waitClose

prepared :: Env -> Backing -> IO PreparedGrowth
prepared env b = do
  o <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= either (fail . show) pure >>= awaitOutcome env
  case o of
    GrowthPrepared p _ -> pure p
    other -> fail ("not prepared: " <> show other)
