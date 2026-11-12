-- | The invariants of the storage service, one checker, and the lifecycle matrix that closes the class round 2 of
-- review found: every KIND of work crossed with every PHASE of a job (queued, running at a gate, finished and
-- untaken, finished and borrowed) and every EVENT (cancel, discard, take, close its backing, service shutdown, an
-- exception in a cleanup step), each cell ending with the invariants holding.
--
-- 'checkInvariants' is one pure function over the service's snapshot, the shared admission's ledger and the
-- descriptors the seam sees open. It is run by the matrix after every cell and by the sweep and the random property
-- after every step; a state that breaks one fails the example that reached it.
module Test.TerrainRuntime.Storage.Lifecycle (spec, checkInvariants, invariantProblems, withControlledService, Ctl (..)) where

import Control.Concurrent (ThreadId, myThreadId, throwTo)
import Data.IORef (newIORef, readIORef, writeIORef)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), ExceptionWithContext (..), SomeAsyncException (..), SomeException, fromException, throwIO, toException, tryWithContext)
import Control.Monad (forM_, void, when)
import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate)
import Data.Maybe (isJust, isNothing)
import System.Directory (listDirectory)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified Foreign.C.Error as C
import Hetoimasia.Foundation.Log (LogLevel (..), Logger, callbackSink, defaultLogFilter, entryLevel, entryMessage, mkLogger)
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
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)
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
  , [ "volume " <> show v <> " reserved " <> show r <> " but backings and closing records contribute " <> show (contribution v)
    | (v, r) <- Map.toList (snReserved sn), r /= contribution v ]
  , [ "volume " <> show v <> " has backings contributing " <> show c <> " but no reserved figure"
    | v <- map bsVolume (snBackings sn <> snClosingRecs sn), c <- [contribution v], c /= 0, Map.notMember v (snReserved sn) ]
  , [ "admission is open but " <> show (snWorkers sn) <> " workers are alive"
    | snAdmissionOpen sn, snWorkers sn /= 2 ]
  -- a running job is a worker's: more running jobs than workers alive (and so any running job with no worker) is a
  -- job nobody will ever finish
  , [ show (snRunning sn) <> " jobs are running but " <> show (snWorkers sn) <> " workers are alive"
    | snRunning sn > snWorkers sn ]
  , [ "evidence holds " <> show (snEvidence sn) <> " failures (at most " <> show maxKept <> ")"
    | snEvidence sn > maxKept ]
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
    -- a closing record still pays for everything its backing paid for, until its native close has returned
    contribution v = sum [bsLength b + maybe 0 id (bsPending b) | b <- snBackings sn <> snClosingRecs sn, bsVolume b == v]
    -- only a closing record whose native close has not returned still pays (a reporting one has released its charges)
    controlNeed = sum (map jsCharge (snJobs sn)) + fromIntegral (nBack + length (snClosingRecs sn)) * backingRecordBytes + fromIntegral (snEvidence sn) * keptEntryBytes
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

data Event = EvCancel | EvDiscard | EvTake | EvClose | EvShutdown | EvCleanupException | EvTakeRaises | EvTakeCancelled
  deriving stock (Eq, Show, Enum, Bounded)

isRd :: Word64 -> NativeOp -> Bool
isRd page op = op == OpReadAt (either (error . show) id (pageFileOffset (hCfg h0) (PageNo page))) pageSize

spec :: Spec
spec = describe "Storage backend: the lifecycle matrix" $ do
  it "keeps every invariant for every kind of work, in every phase, under every event, as each cell declares" $ do
    forM_ allCells $ \(k, ph, ev) -> case declared k ph ev of
      (NotApplicable, _) -> pure ()
      (applic, _) -> if ev == EvCleanupException then runCleanupCell k ph else runCell k ph ev applic
    let (e, r, n) = tally
    e + r + n `shouldBe` length allCells
    mapM_ putStrLn matrixTable
    mapM_ putStrLn chargeTable
    mapM_ putStrLn sealedTable
    putStrLn ("lifecycle matrix: " <> show (length allCells) <> " cells (6 kinds x 4 phases x " <> show (length [minBound .. maxBound :: Event]) <> " events): " <> show e <> " with an effect, " <> show r <> " refusals, " <> show n <> " not applicable (not run)")

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
          -- a failure must be a failure, never a hang: the gate is let go by the thread's own release
          withOwnedThreadOpening (openGate g) (void (closeBacking svc b)) $ \_ waitCloser -> do
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
            awaitBlockedInStm tid
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

  it "still waits for a close in flight when a cancellation reaches the log of that wait, and delivers it afterwards" $
    withSystemTempDirectory "hetoimasia-terrain-lifecycle-wait" $ \dir -> do
      cfg <- testConfigFor dir defaultOptions
      probe <- newProbe
      bank <- either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
      admission <- newTVarIO (A.newAdmission bank)
      handoff <- newEmptyMVar
      finish <- newEmptyMVar
      result <- newEmptyMVar
      serviceThread <- newEmptyMVar
      said <- newTVarIO []
      -- only the log of the drain's wait is "cancelled" (and noted first, so the example can observe that it was reached)
      let waitCancelled = mkLogger defaultLogFilter (callbackSink (\e -> when (entryMessage e == drainWaitsMessage) (atomically (modifyTVar' said (entryMessage e :)) >> throwIO (SomeAsyncException (ErrorCall "the wait log was cancelled")))))
          runService group = tryWithContext $
            withStorageService (StoragePorts admission group waitCancelled (seamFor probe) cfg) $ \svc -> do
              t <- submitOpen svc ExplicitWork (OpenSpec (BC.pack dir) ident (hCfg h0)) >>= either (fail . show) pure
              bounded (atomically (awaitTicket svc t))
              o <- withOutcome svc t pure
              case o of
                Just (Opened b _) -> putMVar handoff (svc, b) >> takeMVar finish
                other -> fail (show other)
      withWorkerGroup $ \group ->
        withOwnedThread (myThreadId >>= putMVar serviceThread >> runService group >>= putMVar result) $ \_ waitService -> do
          (svc, b) <- takeMVar handoff
          g <- addGate probe (== OpCloseFile)
          withOwnedThreadOpening (openGate g) (void (closeBacking svc b)) $ \_ waitCloser -> do
            awaitReached g 1
            putMVar finish ()
            -- the log was cancelled and the drain still waits for the close: it is observed blocked, not finished
            tid <- readMVar serviceThread
            bounded (atomically (readTVar said >>= \ms -> check (drainWaitsMessage `elem` ms)))
            awaitBlockedInStm tid
            openGate g
            waitCloser
          waitService
      r <- takeMVar result
      case r :: Either (ExceptionWithContext SomeException) () of
        Left (ExceptionWithContext _ e) -> (fromException e :: Maybe SomeAsyncException) `shouldSatisfy` isJust
        Right () -> expectationFailure "the cancellation that reached the wait's log was lost"
      openFds probe >>= (`shouldBe` [])

  it "ends the service, closes every backing and delivers only afterwards a cancellation that reached a log" $
    withSystemTempDirectory "hetoimasia-terrain-lifecycle-async" $ \dir -> do
      cfg <- testConfigFor dir defaultOptions
      probe <- newProbe
      bank <- either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
      admission <- newTVarIO (A.newAdmission bank)
      seen <- newEmptyMVar
      -- every entry is "cancelled" in the sink: an exception of the asynchronous type, thrown at a log's own
      -- interruptible point, deterministic and with no throwTo timing
      let cancelling = mkLogger defaultLogFilter (callbackSink (\_ -> throwIO (SomeAsyncException (ErrorCall "the sink was cancelled"))))
      r <- withWorkerGroup $ \group -> tryWithContext $
        withStorageService (StoragePorts admission group cancelling (seamFor probe) cfg) $ \svc -> do
          putMVar seen svc
          ts <- mapM (\i -> submitOpen svc ExplicitWork (OpenSpec (BC.pack dir) i (hCfg h0)) >>= either (fail . show) pure) [ident, ident2]
          forM_ ts (bounded . atomically . awaitTicket svc)
          -- opened and untaken: descriptors are open when the body ends (a worker that ended at the log stopped the
          -- service, which may have refused the other open: at least one backing is open)
          length <$> openFds probe >>= (`shouldSatisfy` (>= 1))
      case r :: Either (ExceptionWithContext SomeException) () of
        Left (ExceptionWithContext _ e) -> (fromException e :: Maybe SomeAsyncException) `shouldSatisfy` isJust
        Right () -> expectationFailure "the cancellation that reached a log was lost"
      openFds probe >>= (`shouldBe` [])
      svc <- readMVar seen
      checkInvariants (Env svc admission probe dir cfg)
      leaked <- A.ledgers <$> readTVarIO admission
      ledgerZero leaked `shouldBe` True

  forM_ [minBound .. maxBound] $ \pt ->
    it ("stops admission when a worker ends at " <> exitPointName pt <> ": later submissions are refused, queued work settles, the other worker's job finishes") (exitPointCase pt)

  -- ---- class B: a charge ends when what it pays for is gone
  it "ends every charge only when what it pays for is gone, each native call held and both ledgers asserted during it" $
    forM_ [minBound .. maxBound] chargeEvidence

  -- ---- class C: no failure without a keeper
  it "keeps the failing close of a finished open that is discarded, and ends the service with it" $
    withControlledService $ \env ctl -> do
      let svc = envSvc env
      t <- submitOpen svc ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)) >>= either (fail . show) pure
      bounded (atomically (awaitTicket svc t))
      addRule (envProbe env) 1 (== OpCloseFile) (FailWith eio)
      discardTicket svc t
      rulesConsumed (envProbe env) >>= (`shouldBe` True)
      checkInvariants env
      sn <- atomically (snapshotOf svc)
      snEvidence sn `shouldBe` 1
      ctlBegin ctl
      ctlResult ctl >>= \r -> case r of
        Left (ExceptionWithContext ctx _) -> length (cleanupFailuresInContext ctx) `shouldSatisfy` (>= 1)
        Right () -> expectationFailure "the failing close of a discarded open was lost: the service ended normally"
      openFds (envProbe env) >>= (`shouldBe` [])

  it "keeps the failing report of a close whose caller receives a cancellation instead" $ do
    let sink e = when (entryMessage e == "Backing close failed") (throwIO (SomeAsyncException (ErrorCall "the close log was cancelled")))
        logger = mkLogger defaultLogFilter (callbackSink sink)
    withControlledServiceWith logger $ \env ctl -> do
      let svc = envSvc env
      b <- openBacking env ident (hCfg h0)
      addRule (envProbe env) 1 (== OpCloseFile) (FailWith eio)
      r <- tryWithContext (closeBacking svc b) :: IO (Either (ExceptionWithContext SomeException) CloseReport)
      case r of
        Left (ExceptionWithContext _ e) -> (fromException e :: Maybe SomeAsyncException) `shouldSatisfy` isJust
        Right _ -> expectationFailure "the remembered cancellation was not delivered"
      -- the caller never received the report, so the service kept its failure
      atomically (snapshotOf svc) >>= \sn -> snEvidence sn `shouldBe` 1
      ctlBegin ctl
      ctlResult ctl >>= \end -> case end of
        Left (ExceptionWithContext ctx _) -> length (cleanupFailuresInContext ctx) `shouldSatisfy` (>= 1)
        Right () -> expectationFailure "the failing close was lost behind the cancellation"
      openFds (envProbe env) >>= (`shouldBe` [])

  it "counts the failures it has no room to keep and reports the count at the end" $
    withControlledService $ \env ctl -> do
      let svc = envSvc env
      atomically (keepEvidence svc "test" (replicate (maxKept + 6) (CleanupNote IoClose eio)))
      sn <- atomically (snapshotOf svc)
      (snEvidence sn, snEvidenceDropped sn) `shouldBe` (maxKept, 6)
      checkInvariants env
      ctlBegin ctl
      ctlResult ctl >>= \end -> case end of
        -- the kept ones and one more, for the dropped
        Left (ExceptionWithContext ctx _) -> length (cleanupFailuresInContext ctx) `shouldBe` maxKept + 1
        Right () -> expectationFailure "kept failures were not reported"

  -- ---- class B (round 4): the close core owns everything until it returns
  it "keeps a close tracked through its post-native diagnostics: shutdown waits for it, and the failure it kept is not lost" $ do
    gate <- newTVarIO False
    reached <- newTVarIO (0 :: Int)
    drainSaid <- newTVarIO False
    -- the log after the native close blocks until the gate opens: the close is held IN ITS DIAGNOSTICS; the drain says
    -- so (a log of its own) before it waits for the record, so the example observes the wait itself and not an earlier
    -- transient block of the drain
    let sink e = do
          when (entryMessage e == drainWaitsMessage) (atomically (writeTVar drainSaid True))
          when (entryMessage e == "Backing closed") (atomically (modifyTVar' reached (+ 1)) >> atomically (readTVar gate >>= check))
        logger = mkLogger defaultLogFilter (callbackSink sink)
    withControlledServiceWith logger $ \env ctl -> do
      let svc = envSvc env
      b <- openBacking env ident (hCfg h0)
      addRule (envProbe env) 1 (== OpCloseFile) (FailWith eio)
      withOwnedThreadOpening (atomically (writeTVar gate True)) (void (closeBacking svc b)) $ \_ waitCloser -> do
        bounded (atomically (readTVar reached >>= \n -> check (n >= 1)))
        -- the native close returned: what the backing paid for is released and the failure kept, but the record stays
        sn <- atomically (snapshotOf svc)
        (snClosing sn, length (snClosingRecs sn), length (snBackings sn), snEvidence sn) `shouldBe` (1, 0, 0, 1)
        A.lgControlReserved <$> (A.ledgers <$> readTVarIO (envAdmission env)) >>= (`shouldBe` keptEntryBytes)
        checkInvariants env
        -- shutdown begins and WAITS for the record (observed blocked, no timer); nothing is added meanwhile
        ctlBegin ctl
        bounded (atomically (readTVar drainSaid >>= check))
        awaitBlockedInStm (ctlThread ctl)
        sn2 <- atomically (snapshotOf svc)
        (snClosing sn2, snEvidence sn2, snAdmissionOpen sn2) `shouldBe` (1, 1, False)
        atomically (writeTVar gate True)
        waitCloser
      ctlResult ctl >>= \r -> case r of
        Left (ExceptionWithContext ctx _) -> length (cleanupFailuresInContext ctx) `shouldBe` 1
        Right () -> expectationFailure "the kept failure of the close was lost: the service ended normally"
      sealed <- atomically (snapshotOf svc)
      (snClosing sealed, snEvidence sealed) `shouldBe` (0, 0)
      openFds (envProbe env) >>= (`shouldBe` [])

  forM_ [("discardTicket of a finished open", \svc t _ -> discardTicket svc t), ("closeBacking", \svc _ b -> void (closeBacking svc b))] $ \(name, close) ->
    it ("keeps a failing close whose caller is cancelled while the native close is held (" <> name <> "): the cancellation is pending, delivered after, and the failure is kept") $
      withControlledService $ \env ctl -> do
        let svc = envSvc env
            probe = envProbe env
        t <- submitOpen svc ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)) >>= either (fail . show) pure
        bounded (atomically (awaitTicket svc t))
        b <- openBacking env ident2 (hCfg h0)
        g <- addGate probe (== OpCloseFile)
        addRule probe 1 (== OpCloseFile) (FailWith eio)
        withOwnedThreadOpening (openGate g) (close svc t b) $ \closer waitClose -> do
          awaitReached g 1
          -- a cancellation sent now is PENDING: the native close is uninterruptible, the sender blocks until it can be
          -- delivered (observed, no timer)
          withOwnedThread (throwTo closer (SomeAsyncException (ErrorCall "the caller was cancelled"))) $ \sender waitSender -> do
            awaitBlockedOnThrowTo sender
            openGate g
            waitSender
          waitClose
        -- the close returned EIO and the caller never received its report: the SERVICE kept it
        sn <- atomically (snapshotOf svc)
        (snEvidence sn, snClosing sn) `shouldBe` (1, 0)
        checkInvariants env
        ctlBegin ctl
        ctlResult ctl >>= \r -> case r of
          Left (ExceptionWithContext ctx _) -> length (cleanupFailuresInContext ctx) `shouldSatisfy` (>= 1)
          Right () -> expectationFailure "a failing close was lost behind a cancellation"

  -- ---- the neighbours (round 4): a drained service accepts nothing, and a blocked hook is cancellable
  it "seals the service at the end of its drain: every mutator then refuses or finds nothing, and nothing commits" $ do
    ref <- newIORef Nothing
    withControlledService $ \env ctl -> do
      let svc = envSvc env
      b <- openBacking env ident (hCfg h0)
      p <- prepared env b
      t <- submitRead svc b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= either (fail . show) pure
      bounded (atomically (awaitTicket svc t))
      sw <- do
        let plan = either error id (planFor h0 1)
        (tid, s1) <- either (fail . show) pure (admit plan (hStore h0))
        either (fail . show) pure (stageWrite s1 tid)
      writeIORef ref (Just (svc, b, t, p, sw, envAdmission env, envProbe env))
      ctlBegin ctl
      ctlResult ctl >>= either (\(ExceptionWithContext _ e) -> expectationFailure ("the service ended with " <> show (e :: SomeException))) pure
    Just (svc, b, t, p, sw, admission, probe) <- readIORef ref
    snapBefore <- atomically (snapshotOf svc)
    sealedPhase <- atomically (snapshotOf svc)
    snAdmissionOpen sealedPhase `shouldBe` False
    forM_ (sealedRows svc b t p sw) $ \(_, _, check') -> check'
    snapAfter <- atomically (snapshotOf svc)
    show snapAfter `shouldBe` show snapBefore
    -- every charge is back: the admission is at its start and no descriptor is open
    ledgerZero . A.ledgers <$> readTVarIO admission >>= (`shouldBe` True)
    openFds probe >>= (`shouldBe` [])

  it "a worker blocked in the after-hook of a create, cancelled while blocked, leaves no descriptor and no name" $
    withControlledService $ \env ctl -> do
      let svc = envSvc env
          probe = envProbe env
      g <- addAfterGate probe (== OpCreateFile)
      t <- submitOpen svc ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)) >>= either (fail . show) pure
      -- the native create succeeded and the worker is blocked in the after-hook, holding the descriptor and the name
      awaitReached g 1
      length <$> openFds probe >>= (`shouldBe` 1)
      tids <- workerThreads probe
      forM_ tids (\tid -> throwTo tid (SomeAsyncException (ErrorCall "the worker was cancelled")))
      bounded (atomically (awaitTicket svc t))
      -- owned from the instant the create succeeded: closed, unlinked, the job finished as a failure, the service stopped
      openFds probe >>= (`shouldBe` [])
      listDirectory (envDir env) >>= (`shouldBe` [])
      withOutcome svc t pure >>= (`shouldSatisfy` \o -> case o of Just (Failed (HostFailure _) _) -> True; _ -> False)
      bounded (atomically (snapshotOf svc >>= \sn -> check (isJust (snStopReason sn))))
      checkInvariants env
      ctlBegin ctl
      ctlResult ctl >>= either (\(ExceptionWithContext _ e) -> expectationFailure ("the service ended with " <> show (e :: SomeException))) pure

  it "finishes a job that fails as a defect when the log of the defect is cancelled: the ticket wakes and the charge is released" $
    withSystemTempDirectory "hetoimasia-terrain-lifecycle-defect" $ \dir -> do
      cfg <- testConfigFor dir defaultOptions
      probe <- newProbe
      bank <- either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
      admission <- newTVarIO (A.newAdmission bank)
      seen <- newEmptyMVar
      let errorsCancelled = mkLogger defaultLogFilter (callbackSink (\e -> when (entryLevel e == Error) (throwIO (SomeAsyncException (ErrorCall "the defect log was cancelled")))))
      _ <- (withWorkerGroup $ \group -> tryWithContext $
        withStorageService (StoragePorts admission group errorsCancelled (seamFor probe) cfg) $ \svc -> do
          putMVar seen svc
          t <- submitOpen svc ExplicitWork (OpenSpec (BC.pack dir) ident (hCfg h0)) >>= either (fail . show) pure
          bounded (atomically (awaitTicket svc t))
          Just (Opened b _) <- withOutcome svc t pure
          addRule probe 1 (isRd 100) Throw
          rt <- submitRead svc b ExplicitWork (hCfg h0) (PageNo 100) 1 ReadProbe >>= either (fail . show) pure
          -- the job finishes as a host failure even though the log of the defect was cancelled
          bounded (atomically (awaitTicket svc rt))
          withOutcome svc rt pure >>= (`shouldSatisfy` \o -> case o of Just (Failed (HostFailure _) _) -> True; _ -> False)
          sn <- atomically (snapshotOf svc)
          snRunning sn `shouldBe` 0
          [j | j <- snJobs sn, jsPhase j == 1] `shouldBe` []) :: IO (Either (ExceptionWithContext SomeException) ())
      openFds probe >>= (`shouldBe` [])
      svc <- readMVar seen
      checkInvariants (Env svc admission probe dir cfg)
      leaked <- A.ledgers <$> readTVarIO admission
      ledgerZero leaked `shouldBe` True

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
-- The declaration: what an event does to a kind of work in a phase

-- | An event either has an effect on the work in that phase, is refused (the call answers and changes nothing), or does
-- not apply (there is nothing for it to act on): a cell that does not apply is not run and is not counted.
data Applic = Effect | Refusal | NotApplicable
  deriving stock (Eq, Show)

allCells :: [(Kind, Phase, Event)]
allCells = [(k, ph, ev) | k <- [minBound .. maxBound], ph <- [minBound .. maxBound], ev <- [minBound .. maxBound]]

-- | THE DECLARATION. The cells run from it and the table in the documentation is generated from it.
declared :: Kind -> Phase -> Event -> (Applic, String)
declared kind phase ev = case ev of
  EvCancel -> case phase of
    PhQueued -> (Effect, "the job is withdrawn at once (CancelledBeforeDispatch; nothing queued, observed) and what its admission installed is reversed")
    PhRunning -> (Effect, "stop requested (CancelRequested); the job keeps running until its held call returns (observed)")
    _ -> (Refusal, "CancelTooLate: the outcome stands")
  EvDiscard -> case phase of
    PhQueued -> (Effect, "withdrawn at once and retired (nothing queued, observed); the admission is reversed")
    PhRunning -> (Effect, "marked: it keeps running until its held call returns (observed), then is disposed of")
    PhDone -> (Effect, "disposed of at once (an opened backing is closed, a prepared growth becomes a pending reservation)")
    PhBorrowed -> (Refusal, "nothing: the borrower holds the outcome and retires it")
  EvTake -> case phase of
    PhQueued -> (Refusal, "no outcome yet: answers Nothing")
    PhRunning -> (Refusal, "no outcome yet: answers Nothing")
    PhDone -> (Effect, "borrowed and retired; a second take answers Nothing")
    PhBorrowed -> (Effect, "a second borrower of the same outcome (two borrows, observed)")
  EvTakeRaises -> takeFails "raises"
  EvTakeCancelled -> takeFails "is cancelled (an exception of the asynchronous type)"
  EvClose -> case (kind, phase) of
    (KindOpen, PhBorrowed) -> (Effect, "closes the backing the open job created: waits for the borrower (observed blocked), then closes")
    (KindOpen, PhDone) -> (NotApplicable, "the created backing's handle is inside the untaken outcome: its discard and the shutdown cell close it")
    (KindOpen, _) -> (NotApplicable, "the backing does not exist yet")
    (_, PhQueued) -> (Effect, "the queued job is withdrawn at once (nothing queued, observed); the close waits (observed blocked) for the running work, then closes")
    (_, PhRunning) -> (Effect, "the close waits (observed blocked) for the held call, then closes")
    (_, PhDone) -> (Effect, "retires the untaken outcome and closes")
    (_, PhBorrowed) -> (Effect, "waits for the borrower (observed blocked), then closes")
  EvShutdown -> case phase of
    PhQueued -> (Effect, "the queued job is withdrawn at once (observed mid-drain: nothing queued, the two busy workers still held); the drain waits (observed blocked) for them")
    PhRunning -> (Effect, "the drain waits (observed blocked) for the held call; the job is still running mid-drain, not detached")
    PhDone -> (Effect, "the untaken outcome is disposed of and every backing closed: nothing is left")
    PhBorrowed -> (Effect, "the drain waits (observed blocked) for the borrower; the job is still borrowed mid-drain")
  EvCleanupException
    | kind `elem` [KindOpen, KindGrow] -> (Effect, "an exception in the cleanup step (injected, observed to fire): a taken outcome carries the cleanup note; an untaken one ends the service with the labelled cleanup failure (a normal end is a failure)")
    | kind `elem` [KindAbandon, KindReleasePending] -> (Effect, "the release raises (injected, observed to fire): a defect: the job finishes as HostFailure, the defect is recorded, the extra stays accounted as a pending reservation")
    | otherwise -> (NotApplicable, "the kind has no cleanup step to fail")

  where
    -- A DELIVERY HAS THREE ENDS: delivered (the callback returned), failed (it raised or was cancelled: nobody owns
    -- what the outcome carries) and undelivered. A failed delivery no borrower received goes through the one disposal.
    takeFails how = case phase of
      PhQueued -> (Refusal, "no outcome yet: the callback never runs")
      PhRunning -> (Refusal, "no outcome yet: the callback never runs")
      PhDone -> (Effect, "the take's callback " <> how <> ": the outcome nobody received is disposed of by the one disposal (an opened backing is closed with its report kept, a prepared growth becomes a recoverable pending reservation, the record is retired)")
      PhBorrowed -> (Effect, "a nested take's callback " <> how <> " while another borrower holds the outcome: nothing is disposed of; the borrower's delivery stands (an opened backing stays open, the growth token stays valid)")

tally :: (Int, Int, Int)
tally = (count Effect, count Refusal, count NotApplicable)
  where
    count a = length [() | (k, ph, ev) <- allCells, fst (declared k ph ev) == a]

-- | The grid, generated from 'declared': E an effect, R a refusal, - not applicable.
matrixTable :: [String]
matrixTable =
  ("| kind / phase | " <> intercalate " | " (map (drop 2 . show) allEvents) <> " |")
    : ("| --- | " <> intercalate " | " (map (const "---") allEvents) <> " |")
    : [ "| " <> drop 4 (show k) <> " / " <> drop 2 (show ph) <> " | " <> intercalate " | " [letter (fst (declared k ph ev)) | ev <- allEvents] <> " |"
      | k <- [minBound .. maxBound :: Kind], ph <- [minBound .. maxBound :: Phase] ]
  where
    allEvents = [minBound .. maxBound :: Event]
    letter Effect = "E"
    letter Refusal = "R"
    letter NotApplicable = "-"

-- ---------------------------------------------------------------------------
-- A service whose end the body controls

-- | The service on a thread of its own, which ends only when told to: the body sets the work up, begins the shutdown
-- when it chooses, observes the drain waiting, and reads how the service ended. Every gate is opened and the service is
-- told to finish by the thread's own release, so a failure is a failure and never a hang.
data Ctl = Ctl
  { ctlThread :: ThreadId
  , ctlBegin :: IO ()
  , ctlResult :: IO (Either (ExceptionWithContext SomeException) ())
  }

withControlledService :: (Env -> Ctl -> IO a) -> IO a
withControlledService = withControlledServiceWith quiet

withControlledServiceWith :: Logger -> (Env -> Ctl -> IO a) -> IO a
withControlledServiceWith logger body =
  withSystemTempDirectory "hetoimasia-terrain-lifecycle-cell" $ \dir -> do
    cfg <- testConfigFor dir defaultOptions
    probe <- newProbe
    bank <- either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
    admission <- newTVarIO (A.newAdmission bank)
    handoff <- newEmptyMVar
    finish <- newEmptyMVar
    result <- newEmptyMVar
    serviceThread <- newEmptyMVar
    out <- withWorkerGroup $ \group ->
      withOwnedThreadOpening (openAllGates probe >> void (tryPutMVar finish ()))
        ( myThreadId >>= putMVar serviceThread
            >> (tryWithContext (withStorageService (StoragePorts admission group logger (seamFor probe) cfg) (\svc -> putMVar handoff (Env svc admission probe dir cfg) >> takeMVar finish)) >>= putMVar result)
        ) $ \_ waitService -> do
          env <- bounded (takeMVar handoff)
          tid <- readMVar serviceThread
          a <- body env (Ctl tid (void (tryPutMVar finish ())) (bounded (readMVar result)))
          waitService
          pure a
    leaked <- A.ledgers <$> readTVarIO admission
    ledgerZero leaked `shouldBe` True
    pure out

-- ---------------------------------------------------------------------------
-- One cell

-- | What a cell works on.
data Cell = Cell
  { cB :: Backing
  , cToken :: Maybe PreparedGrowth
  , cT :: Ticket
  , cHolders :: [(Gate, Ticket)]
  , cHeld :: Maybe Gate
  }

-- | Bring the service to the cell's kind and phase: the job under test submitted and, as the phase says, queued behind two
-- held reads, running at its characteristic native call, finished untaken, or finished (the borrow is the event's).
setupCell :: Env -> Kind -> Phase -> Event -> IO Cell
setupCell env kind phase ev = do
  let probe = envProbe env
      svc = envSvc env
  b <- openBacking env ident (hCfg h0)
  token <- case kind of
    KindAbandon -> Just <$> prepared env b
    _ -> pure Nothing
  when (kind == KindReleasePending) $ do
    addRuleAfter probe 1 1 (== OpStatFile) (OverAllocated (10 * mib))
    addRule probe 1 (== OpSetFileLength (64 * mib)) (FailWith eio)
    void (submitGrowth svc b (64 * mib) (128 * mib) >>= either (fail . show) pure >>= awaitOutcome env)
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
  held <- if phase == PhRunning
    then Just <$> addGate probe (heldOp kind)
    else pure Nothing
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
  pure (Cell b token t holders held)

-- | Run one applicable cell: set it up, apply the event in the phase, assert what the declaration says it does, let the
-- work settle, and check the invariants and what the event must have left recoverable.
runCell :: Kind -> Phase -> Event -> Applic -> IO ()
runCell kind phase ev applic
  | ev == EvShutdown = runShutdownCell kind phase
  | otherwise = withEnv $ \env -> do
      cell <- setupCell env kind phase ev
      let svc = envSvc env
          t = cT cell
          b = cB cell
          releaseAll = forM_ (cHolders cell) (openGate . fst) >> forM_ (cHeld cell) openGate
          expectedCancel = case phase of
            PhQueued -> CancelledBeforeDispatch
            PhRunning -> CancelRequested
            _ -> CancelTooLate
          event = case ev of
            EvCancel -> cancelTicket svc t >>= (`shouldBe` expectedCancel)
            EvDiscard -> discardTicket svc t
            EvTake -> do
              r <- withOutcome svc t (\_ -> atomically (snapshotOf svc))
              isJust r `shouldBe` (applic == Effect)
              -- a take inside a borrow is a second borrower
              when (phase == PhBorrowed) (forM_ r (\sn -> maximum (map jsBorrowed (snJobs sn)) `shouldBe` 2))
              when (phase == PhDone) (withOutcome svc t pure >>= (`shouldSatisfy` isNothing))
            EvClose -> closeAndRelease env b phase (cHolders cell) (cHeld cell)
            EvTakeRaises -> raisingTake (toException (ErrorCall "the take's callback raised"))
            EvTakeCancelled -> raisingTake (toException (SomeAsyncException (ErrorCall "the take's callback was cancelled")))
            _ -> pure ()
          -- a take whose callback fails: a Refusal never runs it, an Effect raises out of it
          raisingTake ex = do
            r <- tryWithContext (withOutcome svc t (\_ -> throwIO ex)) :: IO (Either (ExceptionWithContext SomeException) (Maybe ()))
            case r of
              Left _ -> applic `shouldBe` Effect
              Right Nothing -> applic `shouldBe` Refusal
              Right (Just ()) -> expectationFailure "a callback that raises cannot return"
          takeFails = ev `elem` [EvTakeRaises, EvTakeCancelled]
      case (phase, ev) of
        -- a close while an outcome is borrowed waits for the borrower: it runs on a thread of its own, started from
        -- inside the callback, and the callback returns once the close is OBSERVED waiting (blocked in its transaction,
        -- not finished). For an open the close is of the backing the open job created, whose handle is in the outcome.
        (PhBorrowed, EvClose) -> do
          signal <- newEmptyMVar
          withOwnedThread (takeMVar signal >>= \target -> void (closeBacking svc target)) $ \closer waitClose -> do
            got <- withOutcome svc t $ \o -> do
              checkInvariants env
              target <- case (kind, o) of
                (KindOpen, Opened created _) -> pure created
                (KindOpen, other) -> fail ("not opened: " <> show other)
                _ -> pure b
              putMVar signal target
              awaitBlockedInStm closer
              checkInvariants env
            got `shouldSatisfy` isJust
            releaseAll
            waitClose
        -- a cancel or a discard of a borrowed outcome is refused: the job is still there, held
        (PhBorrowed, e) | e `elem` [EvCancel, EvDiscard] ->
          void . withOutcome svc t $ \_ -> do
            checkInvariants env
            event
            sn <- atomically (snapshotOf svc)
            any (\j -> jsPhase j == 2 && jsBorrowed j >= 1) (snJobs sn) `shouldBe` True
            checkInvariants env
        (PhBorrowed, _) -> void (withOutcome svc t (\_ -> checkInvariants env >> event))
        _ -> do
          event
          -- the state the declaration promises while the work is still held: a cancel or a discard of a queued job has
          -- withdrawn it at once (nothing queued), and one of a running job has not stopped the held call
          when (ev `elem` [EvCancel, EvDiscard] && phase `elem` [PhQueued, PhRunning]) $ do
            sn <- atomically (snapshotOf svc)
            if phase == PhQueued then snQueued sn `shouldBe` 0 else snRunning sn `shouldBe` 1
            checkInvariants env
      -- everything is let go, the work settles, and the invariants hold
      releaseAll
      settle env
      checkInvariants env
      -- what the declared effect must have left behind
      case (ev, phase) of
        (EvCancel, PhQueued) -> withOutcome svc t pure >>= (`shouldSatisfy` \r -> case r of Just (Cancelled _) -> True; _ -> False)
        (EvCancel, PhRunning) -> withOutcome svc t pure >>= (`shouldSatisfy` isJust)
        (EvCancel, PhDone) -> withOutcome svc t pure >>= (`shouldSatisfy` \r -> case r of Just (Cancelled _) -> False; Just _ -> True; Nothing -> False)
        (EvDiscard, p) | p /= PhBorrowed -> withOutcome svc t pure >>= (`shouldSatisfy` isNothing)
        (_, PhDone) | takeFails -> withOutcome svc t pure >>= (`shouldSatisfy` isNothing)
        (EvClose, _) | kind /= KindOpen -> do
          backingView svc b `atomicallyThen` (`shouldSatisfy` isNothing)
          withOutcome svc t pure >>= (`shouldSatisfy` isNothing)
        _ -> pure ()
      -- an open's created backing: discarded or closed, only the first backing remains, with its one descriptor
      -- a failed delivery of an opened backing nobody received closes it (the one disposal); one another borrower
      -- received stays open
      when (kind == KindOpen && takeFails && phase == PhBorrowed) $ do
        sn <- atomically (snapshotOf svc)
        length (snBackings sn) `shouldBe` 2
        length <$> openFds (envProbe env) >>= (`shouldBe` 2)
      when (kind == KindOpen && ((ev == EvDiscard && phase /= PhBorrowed) || (ev == EvClose && phase == PhBorrowed) || (takeFails && phase == PhDone))) $ do
        sn <- atomically (snapshotOf svc)
        length (snBackings sn) `shouldBe` 1
        length <$> openFds (envProbe env) >>= (`shouldBe` 1)
      -- what the event must have left recoverable (the reviewer's reproductions 1 and 2)
      recovered <- case (kind, phase, ev) of
        (KindGrow, PhQueued, _) | ev `elem` [EvCancel, EvDiscard] -> expectAdmitted (submitGrowth svc b (64 * mib) (128 * mib))
        (KindAbandon, PhQueued, _) | ev `elem` [EvCancel, EvDiscard] -> maybe (pure False) (\p -> (== Right ()) <$> commitBackingGrowth svc b p) (cToken cell)
        (KindReleasePending, PhQueued, _) | ev `elem` [EvCancel, EvDiscard] -> expectAdmitted (submitReleasePending svc b)
        (KindGrow, PhDone, EvDiscard) -> expectAdmitted (submitReleasePending svc b)
        -- a discard of a running growth is also a cancellation: the arbitration cancels it, the extra is released, the slot is idle
        (KindGrow, PhRunning, EvDiscard) -> expectAdmitted (submitGrowth svc b (64 * mib) (128 * mib))
        -- a failed delivery of a prepared growth nobody received is a recoverable pending reservation; one another
        -- borrower received keeps its token valid
        (KindGrow, PhDone, _) | takeFails -> expectAdmitted (submitReleasePending svc b)
        (KindGrow, PhBorrowed, _) | takeFails -> maybe False bvGrowthPrepared <$> atomically (backingView svc b)
        _ -> pure True
      recovered `shouldBe` True
      settle env
      checkInvariants env
  where
    settle env = bounded (atomically (snapshotOf (envSvc env) >>= \sn -> check (snRunning sn == 0 && snQueued sn == 0)))
    expectAdmitted act = either (const False) (const True) <$> act
    atomicallyThen act k = atomically act >>= k

-- | A shutdown cell: the service ends with the cell's phase HELD (queued behind busy workers, running at a gate, finished
-- untaken, or borrowed), the drain is observed waiting where it must, then everything is let go and the service ends.
runShutdownCell :: Kind -> Phase -> IO ()
runShutdownCell kind phase = withControlledService $ \env ctl -> do
  cell <- setupCell env kind phase EvShutdown
  let svc = envSvc env
      releaseAll = forM_ (cHolders cell) (openGate . fst) >> forM_ (cHeld cell) openGate
  case phase of
    PhBorrowed -> do
      release <- newEmptyMVar
      withOwnedThreadOpening (void (tryPutMVar release ())) (void (withOutcome svc (cT cell) (\_ -> takeMVar release))) $ \_ waitBorrower -> do
        bounded (atomically (snapshotOf svc >>= \sn -> check (any ((>= 1) . jsBorrowed) (snJobs sn))))
        ctlBegin ctl
        awaitBlockedInStm (ctlThread ctl)
        -- mid-drain: the borrowed job is still there, held
        sn <- atomically (snapshotOf svc)
        any (\j -> jsPhase j == 2 && jsBorrowed j >= 1) (snJobs sn) `shouldBe` True
        checkInvariants env
        putMVar release ()
        waitBorrower
    PhDone -> ctlBegin ctl
    _ -> do
      ctlBegin ctl
      awaitBlockedInStm (ctlThread ctl)
      -- mid-drain, with the work still held at its gates: a queued job has been withdrawn already (nothing queued, the
      -- two busy workers still running, the job's own outcome absent or cancelled); a running job is still running
      sn <- atomically (snapshotOf svc)
      case phase of
        PhQueued -> do
          snQueued sn `shouldBe` 0
          snRunning sn `shouldBe` 2
          withOutcome svc (cT cell) pure >>= (`shouldSatisfy` \r -> case r of Nothing -> True; Just (Cancelled _) -> True; _ -> False)
        _ -> snRunning sn `shouldBe` 1
      checkInvariants env
      releaseAll
  r <- ctlResult ctl
  either (\(ExceptionWithContext _ e) -> expectationFailure ("the service ended with " <> show (e :: SomeException))) pure r
  openFds (envProbe env) >>= (`shouldBe` [])
  sn <- atomically (snapshotOf svc)
  (null (snJobs sn), null (snBackings sn), snClosing sn) `shouldBe` (True, True, 0)
  checkInvariants env
  _ <- pure kind
  pure ()

-- | A cleanup-exception cell: the injected rules must have FIRED, and the evidence must be where the declaration says. For
-- an open or a growth, a taken (borrowed) outcome carries the cleanup note and the service ends normally, an untaken one
-- ends the service with the labelled cleanup failure (a normal end is a failure). For a release the exception is a
-- defect: the job finishes as a host failure, the defect is recorded, the extra stays accounted as pending.
runCleanupCell :: Kind -> Phase -> IO ()
runCleanupCell kind phase = withControlledService $ \env ctl -> do
  cell <- setupCell env kind phase EvCleanupException
  let svc = envSvc env
      t = cT cell
  forM_ (cHolders cell) (openGate . fst)
  forM_ (cHeld cell) openGate
  bounded (atomically (awaitTicket svc t))
  rulesConsumed (envProbe env) >>= (`shouldBe` True)
  checkInvariants env
  let finish = ctlBegin ctl >> ctlResult ctl
  if kind `elem` [KindOpen, KindGrow]
    then
      if phase == PhBorrowed
        then do
          withOutcome svc t pure >>= (`shouldSatisfy` \r -> case r of Just (Failed _ notes) -> not (null notes); _ -> False)
          finish >>= either (\(ExceptionWithContext _ e) -> expectationFailure ("a taken outcome left evidence at the end: " <> show (e :: SomeException))) pure
        else do
          r <- finish
          case r of
            Left (ExceptionWithContext ctx _) -> length (cleanupFailuresInContext ctx) `shouldSatisfy` (>= 1)
            Right () -> expectationFailure "the cleanup failure of an untaken outcome was lost: the service ended normally"
    else do
      view' <- atomically (serviceView svc)
      svDefect view' `shouldSatisfy` isJust
      sn <- atomically (snapshotOf svc)
      any (isJust . bsPending) (snBackings sn) `shouldBe` True
      when (phase == PhBorrowed) (withOutcome svc t pure >>= (`shouldSatisfy` \r -> case r of Just (Failed (HostFailure _) _) -> True; _ -> False))
      finish >>= either (\(ExceptionWithContext _ e) -> expectationFailure ("the service ended with " <> show (e :: SomeException))) pure
  openFds (envProbe env) >>= (`shouldBe` [])
  end <- atomically (snapshotOf svc)
  (null (snJobs end), null (snBackings end), snClosing end) `shouldBe` (True, True, 0)
  checkInvariants env

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
closeAndRelease :: Env -> Backing -> Phase -> [(Gate, Ticket)] -> Maybe Gate -> IO ()
closeAndRelease env b phase holders held =
  withOwnedThread (void (closeBacking (envSvc env) b)) $ \closer waitClose -> do
    bounded (atomically (backingView (envSvc env) b >>= \v -> check (maybe True bvClosing v)))
    -- with work held the close is OBSERVED waiting for it, and a queued job has been withdrawn at once
    when (phase `elem` [PhQueued, PhRunning]) $ do
      awaitBlockedInStm closer
      sn <- atomically (snapshotOf (envSvc env))
      when (phase == PhQueued) (snQueued sn `shouldBe` 0)
      snRunning sn `shouldSatisfy` (>= 1)
      checkInvariants env
    forM_ holders (openGate . fst)
    forM_ held openGate
    waitClose

prepared :: Env -> Backing -> IO PreparedGrowth
prepared env b = do
  o <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= either (fail . show) pure >>= awaitOutcome env
  case o of
    GrowthPrepared p _ -> pure p
    other -> fail ("not prepared: " <> show other)

-- ---------------------------------------------------------------------------
-- The worker exit points (class A): one stop for every way out

-- | Every way a worker can leave other than the cooperative stop its token carries.
data ExitPoint = ExitAtDiagnostic | ExitAtDispatchWait | ExitAtDefect
  deriving stock (Eq, Show, Enum, Bounded)

exitPointName :: ExitPoint -> String
exitPointName pt = case pt of
  ExitAtDiagnostic -> "the diagnostic after a finished job (a cancellation at the Backing opened log)"
  ExitAtDispatchWait -> "its dispatch wait (a cancellation delivered to an idle worker)"
  ExitAtDefect -> "a defect in a job"

-- | The service is KEPT RUNNING. One worker's job is held at a native call; the trigger ends the free worker; the
-- service must then have stopped admission (a typed refusal, the reason recorded), settled what was queued, let the
-- held job of the other worker finish, and kept every invariant, with admission closed whenever a worker is gone.
exitPointCase :: ExitPoint -> IO ()
exitPointCase pt = do
  flag <- newTVarIO False
  let sink e = when (entryMessage e == "Backing opened") (readTVarIO flag >>= \f -> when f (throwIO (SomeAsyncException (ErrorCall "the diagnostic was cancelled"))))
      logger = mkLogger defaultLogFilter (callbackSink sink)
  withControlledServiceWith logger $ \env ctl -> do
    let svc = envSvc env
        probe = envProbe env
        cfg = hCfg h0

    b <- openBacking env ident cfg
    g <- addGate probe (isRd 100)
    held <- submitRead svc b ExplicitWork cfg (PageNo 100) 1 ReadProbe >>= either (fail . show) pure
    awaitReached g 1
    checkInvariants env
    queuedAfter <- case pt of
      ExitAtDiagnostic -> do
        atomically (writeTVar flag True)
        void (submitOpen svc ExplicitWork (OpenSpec (BC.pack (envDir env)) ident2 cfg) >>= either (fail . show) pure)
        Just <$> submitRead svc b ExplicitWork cfg (PageNo 101) 1 ReadProbe
      ExitAtDispatchWait -> do
        tids <- workerThreads probe
        forM_ tids (\tid -> throwTo tid (SomeAsyncException (ErrorCall "the worker was cancelled")))
        pure Nothing
      ExitAtDefect -> do
        addRule probe 1 (isRd 102) Throw
        void (submitRead svc b ExplicitWork cfg (PageNo 102) 1 ReadProbe >>= either (fail . show) pure)
        Just <$> submitRead svc b ExplicitWork cfg (PageNo 101) 1 ReadProbe
    -- the one stop ran: admission is closed and the reason recorded
    bounded (atomically (snapshotOf svc >>= \sn -> check (isJust (snStopReason sn) && not (snAdmissionOpen sn))))
    checkInvariants env
    r <- submitRead svc b ExplicitWork cfg (PageNo 103) 1 ReadProbe
    r `shouldSatisfy` \x -> case x of Left ServiceStopped -> True; _ -> False
    -- what was queued before settles as cancelled (or was refused if it came after the stop)
    forM_ queuedAfter $ \q -> case q of
      Left ServiceStopped -> pure ()
      Left other -> expectationFailure ("refused with " <> show other)
      Right t -> do
        bounded (atomically (awaitTicket svc t))
        -- withdrawn queued work is retired at once (the ticket names nothing), or kept as cancelled
        withOutcome svc t pure >>= (`shouldSatisfy` \o -> case o of Nothing -> True; Just (Cancelled _) -> True; _ -> False)
    -- the other worker's running job finishes
    openGate g
    bounded (atomically (awaitTicket svc held))
    withOutcome svc held pure >>= (`shouldSatisfy` isJust)
    checkInvariants env
    ctlBegin ctl
    end <- ctlResult ctl
    either (\(ExceptionWithContext _ e) -> expectationFailure ("the service ended with " <> show (e :: SomeException))) pure end
    openFds probe >>= (`shouldBe` [])

-- ---------------------------------------------------------------------------
-- Class B: every charge, what it pays for, and the one place it is released

-- | Every charge the service holds. 'chargeRow' is total over it, so a charge added without a row does not compile.
data ChargeKind
  = ChJobRecord
  | ChDispatchStaging
  | ChResultBytes
  | ChBackingRecord
  | ChVolumeReserved
  | ChPendingReservation
  | ChGrowthExtra
  deriving stock (Eq, Show, Enum, Bounded)

-- | What it pays for, where it is released, and why the thing is gone there.
chargeRow :: ChargeKind -> (String, String, String)
chargeRow k = case k of
  ChJobRecord -> ("the job's record (and a write's report metadata)", "retireJob, after the outcome is taken or disposed of", "the record is deleted in the same transaction; no native thing is behind it")
  ChDispatchStaging -> ("a read's transfer buffer", "finishJob, when the job ends", "execute has returned: the native read is over and the buffer is released")
  ChResultBytes -> ("a finished read's result copy (cache, pinned)", "retireJob", "the bytes are dropped with the record when the outcome is taken or discarded")
  ChBackingRecord -> ("a backing's entry, descriptor and file", "finishClosing, one transaction after the native close has returned", "the descriptor is closed: the closing record held the grant until then")
  ChVolumeReserved -> ("the file's length and any pending extra on the volume", "finishClosing (a close), execRelease (a release)", "the native close, or the release's set-length, has returned")
  ChPendingReservation -> ("an extra range a failed release left allocated", "execRelease on success, finishClosing", "the retried release's set-length has returned")
  ChGrowthExtra -> ("an abandoned or failed growth's extra range", "execRelease and giveBack on success", "the set-length that frees it has returned: until then the extra stays counted")

-- | For each charge: the native call that ends it held, and what both ledgers say DURING the call and after it.
chargeEvidence :: ChargeKind -> IO ()
chargeEvidence k = case k of
  ChJobRecord -> withEnv $ \env -> do
    b <- openBacking env ident (hCfg h0)
    t <- submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= either (fail . show) pure
    bounded (atomically (awaitTicket (envSvc env) t))
    ledger env >>= \l -> A.lgControlReserved l `shouldBe` (jobRecordBytes + backingRecordBytes)
    void (withOutcome (envSvc env) t pure)
    ledger env >>= \l -> A.lgControlReserved l `shouldBe` backingRecordBytes
  ChDispatchStaging -> withEnv $ \env -> do
    b <- openBacking env ident (hCfg h0)
    g <- addGate (envProbe env) (isRd 5)
    t <- submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= either (fail . show) pure
    awaitReached g 1
    -- DURING the native read: the buffer is charged
    ledger env >>= \l -> A.lgStagingForeground l `shouldBe` transferBufferBytes 1
    checkInvariants env
    openGate g
    bounded (atomically (awaitTicket (envSvc env) t))
    -- after it: the buffer is released, the result stays charged until taken
    ledger env >>= \l -> (A.lgStagingForeground l, A.lgCacheBacked l) `shouldBe` (0, resultPageBytes)
    void (withOutcome (envSvc env) t pure)
  ChResultBytes -> withEnv $ \env -> do
    b <- openBacking env ident (hCfg h0)
    t <- submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= either (fail . show) pure
    bounded (atomically (awaitTicket (envSvc env) t))
    ledger env >>= \l -> A.lgCacheBacked l `shouldBe` resultPageBytes
    discardTicket (envSvc env) t
    ledger env >>= \l -> A.lgCacheBacked l `shouldBe` 0
  ChBackingRecord -> withEnv $ \env -> do
    b <- openBacking env ident (hCfg h0)
    g <- addGate (envProbe env) (== OpCloseFile)
    withOwnedThreadOpening (openGate g) (void (closeBacking (envSvc env) b)) $ \_ waitClose -> do
      awaitReached g 1
      -- DURING the native close: the entry has moved into the closing record, and nothing it paid for is released
      sn <- atomically (snapshotOf (envSvc env))
      (length (snBackings sn), length (snClosingRecs sn)) `shouldBe` (0, 1)
      ledger env >>= \l -> A.lgControlReserved l `shouldBe` backingRecordBytes
      snReserved sn `shouldBe` Map.fromList [(bsVolume r, bsLength r) | r <- snClosingRecs sn]
      length <$> openFds (envProbe env) >>= (`shouldBe` 1)
      checkInvariants env
      openGate g
      waitClose
    -- after it: everything is released in one transaction
    ledger env >>= \l -> A.lgControlReserved l `shouldBe` 0
    sn <- atomically (snapshotOf (envSvc env))
    (null (snClosingRecs sn), all (== 0) (Map.elems (snReserved sn))) `shouldBe` (True, True)
  ChVolumeReserved -> chargeEvidence ChBackingRecord
  ChPendingReservation -> withEnv $ \env -> do
    b <- openBacking env ident (hCfg h0)
    -- a growth whose rollback release fails leaves the extra pending and charged
    addRuleAfter (envProbe env) 1 1 (== OpStatFile) (OverAllocated (10 * mib))
    addRule (envProbe env) 1 (== OpSetFileLength (64 * mib)) (FailWith eio)
    void (submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= either (fail . show) pure >>= awaitOutcome env)
    reservedOf env `shouldReturn` (128 * mib)
    -- the retry's set-length is held: DURING it the extra is still counted
    g <- addGate (envProbe env) (== OpSetFileLength (64 * mib))
    t <- submitReleasePending (envSvc env) b >>= either (fail . show) pure
    awaitReached g 1
    reservedOf env `shouldReturn` (128 * mib)
    checkInvariants env
    openGate g
    void (awaitOutcome env t)
    reservedOf env `shouldReturn` (64 * mib)
  ChGrowthExtra -> withEnv $ \env -> do
    b <- openBacking env ident (hCfg h0)
    p <- prepared env b
    reservedOf env `shouldReturn` (128 * mib)
    g <- addGate (envProbe env) (== OpSetFileLength (64 * mib))
    t <- submitAbandon (envSvc env) b p >>= either (fail . show) pure
    awaitReached g 1
    -- DURING the release's set-length the prepared extra is still counted
    reservedOf env `shouldReturn` (128 * mib)
    checkInvariants env
    openGate g
    void (awaitOutcome env t)
    reservedOf env `shouldReturn` (64 * mib)
  where
    ledger env = A.ledgers <$> readTVarIO (envAdmission env)
    reservedOf env = (sum . Map.elems . snReserved) <$> atomically (snapshotOf (envSvc env))

-- | The table of charges, generated from 'chargeRow' (total over 'ChargeKind').
chargeTable :: [String]
chargeTable =
  "| Charge | What it pays for | The one release site | Why the thing is gone there |" : "| --- | --- | --- | --- |" :
    [ "| " <> drop 2 (show k) <> " | " <> a <> " | " <> b <> " | " <> c <> " |" | k <- [minBound .. maxBound :: ChargeKind], let (a, b, c) = chargeRow k ]

-- ---------------------------------------------------------------------------
-- A sealed service: every public mutator, and what it does once the drain has completed

-- | Every public function that could commit state or a charge to the service, and what it does on a sealed one. The
-- table in the documentation is generated from it; each row is asserted.
sealedRows :: StorageService -> Backing -> Ticket -> PreparedGrowth -> StagedWrite -> [(String, String, IO ())]
sealedRows svc b t p sw =
  [ ("submitOpen", "refused: ServiceStopped", submitOpen svc ExplicitWork (OpenSpec (BC.pack "/nonexistent") ident (hCfg h0)) >>= (`shouldSatisfy` isStopped))
  , ("submitRead", "refused: BackingClosed (the backing is gone)", submitRead svc b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= (`shouldSatisfy` isClosed))
  , ("submitWrite", "refused: BackingClosed", submitWrite svc b sw >>= (`shouldSatisfy` isClosed))
  , ("submitGrowth", "refused: BackingClosed", submitGrowth svc b (64 * mib) (128 * mib) >>= (`shouldSatisfy` isClosed))
  , ("submitAbandon", "refused: BackingClosed", submitAbandon svc b p >>= (`shouldSatisfy` isClosed))
  , ("submitReleasePending", "refused: BackingClosed", submitReleasePending svc b >>= (`shouldSatisfy` isClosed))
  , ("commitBackingGrowth", "refused: BackingClosed", commitBackingGrowth svc b p >>= (`shouldSatisfy` either (== BackingClosed) (const False)))
  , ("withUse", "refused: BackingClosed, the action never runs", withUse svc b (expectationFailure "the action ran on a sealed service") >>= (`shouldSatisfy` either (== BackingClosed) (const False)))
  , ("withOutcome", "answers Nothing: the ticket names nothing, the callback never runs", withOutcome svc t (\_ -> expectationFailure "the callback ran on a sealed service") >>= (`shouldSatisfy` isNothing))
  , ("discardTicket", "finds nothing: no effect", discardTicket svc t)
  , ("cancelTicket", "answers CancelUnknown", cancelTicket svc t >>= (`shouldBe` CancelUnknown))
  , ("closeBacking", "finds no backing: nothing closed, no native call", closeBacking svc b >>= (`shouldSatisfy` (not . crClosed)))
  , ("keepEvidence", "a defect: SealedMutation is thrown, nothing is kept or charged", do
      r <- tryWithContext (atomically (keepEvidence svc "after the seal" [CleanupNote IoClose eio])) :: IO (Either (ExceptionWithContext SomeException) ())
      case r of
        Left (ExceptionWithContext _ e) -> (fromException e :: Maybe SealedMutation) `shouldSatisfy` isJust
        Right () -> expectationFailure "evidence was kept on a sealed service")
  ]
  where
    isStopped x = case x of Left ServiceStopped -> True; _ -> False
    isClosed x = case x of Left BackingClosed -> True; _ -> False

-- | The table, generated from 'sealedRows'.
sealedTable :: [String]
sealedTable =
  "| Function | On a sealed service |" : "| --- | --- |" :
    [ "| `" <> n <> "` | " <> d' <> " |" | (n, d', _) <- sealedRows undefined undefined undefined undefined undefined ]
