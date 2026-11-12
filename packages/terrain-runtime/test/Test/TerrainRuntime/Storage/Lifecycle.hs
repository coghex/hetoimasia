-- | The invariants of the storage service, one checker, and the lifecycle matrix that closes the class round 2 of
-- review found: every KIND of work crossed with every PHASE of a job (queued, running at a gate, finished and
-- untaken, finished and borrowed) and every EVENT (cancel, discard, take, close its backing, service shutdown, an
-- exception in a cleanup step), each cell ending with the invariants holding.
--
-- 'checkInvariants' is one pure function over the service's snapshot, the shared admission's ledger and the
-- descriptors the seam sees open. It is run by the matrix after every cell and by the sweep and the random property
-- after every step; a state that breaks one fails the example that reached it.
module Test.TerrainRuntime.Storage.Lifecycle (spec, checkInvariants, invariantProblems) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), ExceptionWithContext (..), SomeAsyncException (..), SomeException, fromException, throwIO, tryWithContext)
import Control.Monad (forM_, void, when)
import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate)
import Data.Maybe (isJust, isNothing)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified Foreign.C.Error as C
import Hetoimasia.Foundation.Log (LogLevel (..), callbackSink, defaultLogFilter, entryLevel, entryMessage, mkLogger)
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
  it "keeps every invariant for every kind of work, in every phase, under every event, as each cell declares" $ do
    forM_ allCells $ \(k, ph, ev) -> case declared k ph ev of
      (NotApplicable, _) -> pure ()
      (applic, _) -> (if ev == EvCleanupException then expectCleanupEvidence else id) (runCell k ph ev applic)
    let (e, r, n) = tally
    e + r + n `shouldBe` length allCells
    mapM_ putStrLn matrixTable
    putStrLn ("lifecycle matrix: " <> show (length allCells) <> " cells (6 kinds x 4 phases x 6 events): " <> show e <> " with an effect, " <> show r <> " refusals, " <> show n <> " not applicable (not run)")

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
          -- both opened (the outcomes are untaken): two descriptors are open when the body ends
          length <$> openFds probe >>= (`shouldBe` 2)
      case r :: Either (ExceptionWithContext SomeException) () of
        Left (ExceptionWithContext _ e) -> (fromException e :: Maybe SomeAsyncException) `shouldSatisfy` isJust
        Right () -> expectationFailure "the cancellation that reached a log was lost"
      openFds probe >>= (`shouldBe` [])
      svc <- readMVar seen
      checkInvariants (Env svc admission probe dir cfg)
      leaked <- A.ledgers <$> readTVarIO admission
      ledgerZero leaked `shouldBe` True

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
    PhQueued -> (Effect, "the job is withdrawn (CancelledBeforeDispatch) and what its admission installed is reversed")
    PhRunning -> (Effect, "stop requested at the next safe point (CancelRequested); the held call finishes first")
    _ -> (Refusal, "CancelTooLate: the outcome stands")
  EvDiscard -> case phase of
    PhQueued -> (Effect, "withdrawn and retired; the admission is reversed")
    PhRunning -> (Effect, "marked: stopped at its next safe point and disposed of when it ends")
    PhDone -> (Effect, "disposed of at once (an opened backing is closed, a prepared growth becomes a pending reservation)")
    PhBorrowed -> (Refusal, "nothing: the borrower holds the outcome and retires it")
  EvTake -> case phase of
    PhQueued -> (Refusal, "no outcome yet: answers Nothing")
    PhRunning -> (Refusal, "no outcome yet: answers Nothing")
    PhDone -> (Effect, "borrowed and retired; a second take answers Nothing")
    PhBorrowed -> (Effect, "a second borrower of the same outcome")
  EvClose -> case (kind, phase) of
    (KindOpen, PhBorrowed) -> (Effect, "closes the backing the open job created: waits for the borrower (observed blocked), then closes")
    (KindOpen, PhDone) -> (NotApplicable, "the created backing's handle is inside the untaken outcome: its discard and the shutdown cell close it")
    (KindOpen, _) -> (NotApplicable, "the backing does not exist yet")
    (_, PhQueued) -> (Effect, "the queued job is withdrawn; the close waits for the running work")
    (_, PhRunning) -> (Effect, "waits for the held call")
    (_, PhDone) -> (Effect, "retires the untaken outcome")
    (_, PhBorrowed) -> (Effect, "waits for the borrower (observed blocked), then closes")
  EvShutdown -> case phase of
    PhQueued -> (Effect, "shutdown with the workers busy: the queued job is withdrawn, the drain waits (observed blocked) for the held calls")
    PhRunning -> (Effect, "shutdown with the job held at its native call: the drain waits (observed blocked)")
    PhDone -> (Effect, "shutdown with the outcome untaken: disposed of, backings closed, evidence kept")
    PhBorrowed -> (Effect, "shutdown while a borrower holds the outcome: the drain waits (observed blocked) for it")
  EvCleanupException
    | kind `elem` [KindOpen, KindGrow, KindAbandon, KindReleasePending] -> (Effect, "an exception in the kind's cleanup step: the cleanup failures are kept as labelled evidence")
    | otherwise -> (NotApplicable, "the kind has no cleanup step to fail")

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
withControlledService body =
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
            >> (tryWithContext (withStorageService (StoragePorts admission group quiet (seamFor probe) cfg) (\svc -> putMVar handoff (Env svc admission probe dir cfg) >> takeMVar finish)) >>= putMVar result)
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

-- | A cell that injects an exception into a cleanup step may end with the service's own end reporting that failure (an
-- outcome nobody took carries it): that is the evidence being kept, and it must carry labelled cleanup failures. Any
-- other exception is a failure.
expectCleanupEvidence :: IO () -> IO ()
expectCleanupEvidence cell = do
  r <- tryWithContext cell :: IO (Either (ExceptionWithContext SomeException) ())
  case r of
    Right () -> pure ()
    Left (ExceptionWithContext ctx e) ->
      (show e, length (cleanupFailuresInContext ctx)) `shouldSatisfy` \(_, n) -> n >= 1

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
              r <- withOutcome svc t pure
              isJust r `shouldBe` (applic == Effect)
              when (phase == PhDone) (withOutcome svc t pure >>= (`shouldSatisfy` isNothing))
            EvClose -> closeAndRelease env b (cHolders cell) (cHeld cell)
            _ -> pure ()
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
        -- a discard of a borrowed outcome is refused: the job is still there, held
        (PhBorrowed, EvDiscard) ->
          void . withOutcome svc t $ \_ -> do
            checkInvariants env
            discardTicket svc t
            sn <- atomically (snapshotOf svc)
            any (\j -> jsPhase j == 2 && jsBorrowed j >= 1) (snJobs sn) `shouldBe` True
            checkInvariants env
        (PhBorrowed, _) -> void (withOutcome svc t (\_ -> checkInvariants env >> event))
        _ -> event
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
        (EvClose, p) | kind /= KindOpen, p /= PhBorrowed -> do
          backingView svc b `atomicallyThen` (`shouldSatisfy` isNothing)
          withOutcome svc t pure >>= (`shouldSatisfy` isNothing)
        _ -> pure ()
      -- an open's created backing: discarded or closed, only the first backing remains, with its one descriptor
      when (kind == KindOpen && ((ev == EvDiscard && phase /= PhBorrowed) || (ev == EvClose && phase == PhBorrowed))) $ do
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
        checkInvariants env
        putMVar release ()
        waitBorrower
    PhDone -> ctlBegin ctl
    _ -> do
      ctlBegin ctl
      awaitBlockedInStm (ctlThread ctl)
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
