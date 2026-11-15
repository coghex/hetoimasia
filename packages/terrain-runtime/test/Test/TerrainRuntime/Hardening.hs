-- | Accounting and lifetime hardening: the cases a first review of the service
-- reproduced, each as an example that fails without its fix.
module Test.TerrainRuntime.Hardening (spec) where

import Control.Concurrent (killThread, throwTo, yield)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), ExceptionWithContext (..), Exception (..), SomeException, asyncExceptionFromException, asyncExceptionToException, catch, finally, fromException, throwIO, try)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Control.Monad (forM, forM_, void, when)
import qualified Data.Text as T
import Hetoimasia.Foundation.Log (LogEntry (..), callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Terrain.Cell (zRangeLo)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), decomposeTile, mkLocalCoord)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Resident (residentCell)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailures)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (checkRuntime, withSupervision)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Supervised (supervisedOwner)
import Hetoimasia.Terrain.Source (SourceSpec)
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Test.TerrainRuntime.Fixtures
import qualified Test.TerrainRuntime.Storage.Harness as H

spec ∷ Spec
spec = describe "Accounting and lifetime hardening" $ do
  it "commits a coalescing removal to the store and retains nothing in RAM" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      -- Levels 0 and 2 are two intervals; removing 1 joins them into one.
      forM_ [0, 2, 1] $ \z → removeCell' svc lease (tile 0 0 z)
      model <- inspectModel svc
      -- The model's retained account stays zero: every removal is the store's.
      [arenaRetainedBytes a | a ← modelArenas model] `shouldBe` [0]
      answers <- mapM (\z → readCell svc lease (tile 0 0 z)) [0, 1, 2, 3]
      map cellIs answers `shouldBe` [True, True, True, False]
      settleChecks svc

  it "keeps the residency that loads and evictions made while a commit waits for its grant" $
    withService (tightConfig (2, 1, 2) 1 4096) $ \svc → do
      (_, lease) <- openMain svc "main"
      host <- newHost False
      _ <- okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 1 0 1) Nothing)
      waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      -- Loads and the evictions they force happen while the removal is staged.
      let others = [(x, 0, z) | x ← [16, 32, -16, 48, -32, 64], z ← [0, 32]]
      forM_ others $ \(x, y, z) → readCell svc lease (tile x y z)
      grant host
      _ <- waitFor (readTVar (hostSettled host) >>= \s → if null s then retry else pure s)
      view <- inspectArena svc lease >>= maybe (fail "arena vanished") pure
      model <- inspectModel svc
      let resident = map regionCoord (modelRegions model)
      -- What is resident agrees with the model for every cell touched: nothing
      -- loaded meanwhile was lost, and nothing evicted meanwhile came back.
      forM_ ((1, 0, 1) : others) $ \(x, y, z) → do
        let at = tile x y z
            (inRegion, _) = decomposeTile at
            known = either (const False) (maybe False (const True)) (residentCell (viewPalette view) (viewResident view) at)
        (at, known) `shouldBe` (at, inRegion `elem` resident)
      settleChecks svc

  it "demands several intervals of one column and measures the load once per column" $
    withService defaultConfig $ \svc → do
      (client, lease) <- openMain svc "main"
      view <- okOf (openView svc client)
      let cellAtLevel z = either (error . show) coverageTile (mkLocalCoord 0 0 z)
          sparse = foldr1 coverageUnion (map cellAtLevel [0, 2, 4])
      _ <- okOf (setViewDemand svc view lease [RegionDemand (RegionCoord 0 0 0) sparse])
      waitFor (inspectModelSTM svc >>= \m → check (null (modelJobs m) && all (null . viewPending) (modelViews m)))
      inspectDefects svc >>= (`shouldBe` [])
      -- The owner survived and still serves explicit work.
      answer <- readCell svc lease (tile 0 0 2)
      cellIs answer `shouldBe` False
      settleChecks svc

  it "refuses a column range past the level limit before enumerating it, and accepts the limit exactly" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      forM_ [range 0 8193, range (-(2 ^ (62 ∷ Int))) (2 ^ (62 ∷ Int)), range 1 8194] $ \wide →
        bounded (columnAt svc lease (column 0 0) wide) >>= \r → refusedWith r `shouldSatisfy` \found → case found of Just (RefusedInvalid _) → True; _ → False
      exact <- okOf (columnAt svc lease (column 0 0) (range 1 8193)) >>= await svc >>= expectSuccess
      length (columnAnswerRuns exact) `shouldSatisfy` (> 0)
      zRangeLo (range 1 8193) `shouldBe` 1
      settleChecks svc

  it "fails a request and ends the owner when a readiness callback fails, committing nothing" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      loaded <- readCell svc lease (tile 1 1 1)
      cellRevision loaded `shouldBe` Revision 0
      let (held, _) = decomposeTile (tile 1 1 1)
      host <- newHost True
      let failing = (hostEndpoint svc Nothing host) {endpointReady = throwSTM (ErrorCall "ready failed")}
      outcome <- withSnapshot svc lease [held] $ \_ → do
        _ <- okOf (removeWith svc failing lease (tile 1 1 1) Nothing)
        awaitOwnerStopped svc
        settledOf host `shouldReturn` [Failed ArenaClosed]
        model <- inspectModel svc
        [(arenaRevision a, arenaRetainedBytes a) | a ← modelArenas model] `shouldBe` [(Revision 0, 0)]
        inspectDefects svc
      case outcome of
        Right (ProviderDefect _ : _) → pure ()
        other → expectationFailure ("expected a provider defect first, got " <> show other)

  it "retries pending camera demand when a borrow is released, without another admission" $
    withService (tightConfig (2, 1, 2) 0 4096) $ \svc → do
      (client, lease) <- openMain svc "main"
      view <- okOf (openView svc client)
      let oneCellOf (x, z) = let (area, local) = decomposeTile (tile x 0 z) in RegionDemand area (coverageTile local)
          held = [(0, 0), (16, 0)]
          wanted = [oneCellOf (x, z) | x ← [32, 48, 64, -16, -32, -48, 80, 96], z ← [0, 32]]
      forM_ held $ \(x, z) → readCell svc lease (tile x 0 z)
      let heldRegions = [fst (decomposeTile (tile x 0 z)) | (x, z) ← held]
      outcome <- withSnapshot svc lease heldRegions $ \_ → do
        receipt <- okOf (setViewDemand svc view lease wanted)
        waitFor (inspectModelSTM svc >>= \m → check (null [() | j ← modelJobs m, jobPhase j /= JobQueued && jobPhase j /= JobWaiting]))
        pendingWhileHeld <- concatMap viewPending . modelViews <$> inspectModel svc
        -- The scenario is only meaningful if the borrow really holds demand back.
        pure (length (receiptPending receipt), pendingWhileHeld)
      case outcome of
        Right (_, stillPending) → stillPending `shouldSatisfy` (not . null)
        Left refused → expectationFailure (show refused)
      -- The borrow is released; nothing else is admitted. The owner retries on its own.
      waitFor (inspectModelSTM svc >>= \m → check (all (null . viewPending) (modelViews m) && null (modelJobs m)))
      inspectDefects svc >>= (`shouldBe` [])
      settleChecks svc

  it "refuses an unbounded name and a borrow that names more regions than a hold may, before enumerating them" $
    withService defaultConfig $ \svc → do
      (client, lease) <- openMain svc "main"
      openArena svc client "" soilOverStone >>= \r → refusedWith r `shouldSatisfy` isInvalid
      openArena svc client (T.replicate 257 "x") soilOverStone >>= \r → refusedWith r `shouldSatisfy` isInvalid
      attachArena svc client (T.replicate 100000 "y") >>= \r → refusedWith r `shouldSatisfy` isInvalid
      okOf (openArena svc client (T.replicate 256 "z") soilOverStone) >>= void . await svc
      let regions = [RegionCoord (fromIntegral x) 0 0 | x ← [0 .. 100000 ∷ Int]]
      withSnapshot svc lease regions (\_ → pure ()) >>= \r → r `shouldSatisfy` either (const True) (const False)
      settleChecks svc

  it "ends the owner and settles everything once when an eligibility callback fails" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      host <- newHost True
      let failing = (hostEndpoint svc Nothing host) {endpointEligible = throwSTM (ErrorCall "eligibility failed")}
      _ <- okOf (cellWith svc failing lease (tile 1 1 1))
      awaitOwnerStopped svc
      settledOf host `shouldReturn` [Failed ArenaClosed]
      inspectDefects svc >>= \d → d `shouldSatisfy` \found → case found of ProviderDefect _ : _ → True; _ → False
      inspectInvariants svc >>= (`shouldBe` [])

  it "charges every outstanding snapshot's backing, across revisions, until it is released" $ do
    -- A one-cell region's backing is 82 accounted bytes; an edit's untaken result 160.
    -- The bank holds three snapshots and the edits between them, not a fourth.
    let config = (tightConfig (2, 1, 2) 2 4096) {configRetainedBytes = 325}
    withService config $ \svc → do
      (_, lease) <- openMain svc "main"
      let (held, _) = decomposeTile (tile 0 0 0)
          borrow k = withSnapshot svc lease [held] k
      _ <- readCell svc lease (tile 0 0 0)
      outcome <- borrow $ \first' → do
        inspectRetained svc >>= (`shouldBe` (82, 325))
        removeCell' svc lease (tile 0 0 0) >>= (`shouldSatisfy` removeChangedFlag)
        _ <- borrow $ \second → do
          inspectRetained svc >>= (`shouldBe` (164, 325))
          removeCell' svc lease (tile 1 0 0) >>= (`shouldSatisfy` removeChangedFlag)
          _ <- borrow $ \third → do
            inspectRetained svc >>= (`shouldBe` (246, 325))
            -- A fourth borrow would retain a further version beside three: refused.
            fourth <- borrow (\_ → pure ())
            fourth `shouldBe` Left (RefusedBusy BusyRetained)
            map snapshotRevision [first', second, third] `shouldBe` [Revision 0, Revision 1, Revision 2]
          pure ()
        pure ()
      outcome `shouldBe` Right ()
      -- Everything released: nothing is charged.
      inspectRetained svc >>= (`shouldBe` (0, 325))
      settleChecks svc

  it "does not return while a borrower holds a snapshot after the owner failed" $ do
    events <- newMVar ([] ∷ [String])
    let note e = modifyMVar_ events (pure . (e :))
    boxed <- newEmptyMVar
    holding <- newEmptyMVar
    bodyDone <- newEmptyMVar
    release <- newEmptyMVar
    exited <- newEmptyMVar
    let served = do
          withService defaultConfig $ \svc → do
            (_, lease) <- openMain svc "main"
            _ <- readCell svc lease (tile 3 4 5)
            putMVar boxed (svc, lease)
            bounded (readMVar holding)
            host <- newHost True
            let failing = (hostEndpoint svc Nothing host) {endpointSettle = \_ → throwSTM (ErrorCall "host defect")}
            _ <- okOf (removeWith svc failing lease (tile 1 1 1) Nothing)
            awaitOwnerStopped svc
            note "body done"
            putMVar bodyDone ()
          note "service returned"
          putMVar exited ()
        borrower = do
          (svc, lease) <- bounded (readMVar boxed)
          let (borrowed, _) = decomposeTile (tile 3 4 5)
          void $ withSnapshot svc lease [borrowed] $ \_ → do
            putMVar holding ()
            readMVar release
            note "borrow finished"
    withOwnedThread served $ \_ waitServed →
      withOwnedThread borrower $ \_ waitBorrower → do
        bounded (readMVar bodyDone)
        tryReadMVar exited `shouldReturn` Nothing
        putMVar release ()
        bounded waitBorrower
        bounded waitServed
    chronological <- reverse <$> readMVar events
    chronological `shouldBe` ["body done", "borrow finished", "service returned"]

  forM_ [("a cancellation (ThreadKilled)", killIt), ("any other asynchronously delivered exception (ErrorCall)", errorIt)] $ \(label, interrupt) →
   it ("keeps draining under " <> label <> " while a borrower is outstanding, and delivers it afterwards") $ do
    events <- newMVar ([] ∷ [String])
    let note e = modifyMVar_ events (pure . (e :))
    boxed <- newEmptyMVar
    holding <- newEmptyMVar
    bodyDone <- newEmptyMVar
    release <- newEmptyMVar
    let served =
          ( withService defaultConfig $ \svc → do
              (_, lease) <- openMain svc "main"
              _ <- readCell svc lease (tile 3 4 5)
              putMVar boxed (svc, lease)
              bounded (readMVar holding)
              putMVar bodyDone svc
          )
            `catch` (\e → note "service exited" >> throwIO (e ∷ SomeException))
        borrower = do
          (svc, lease) <- bounded (readMVar boxed)
          let (borrowed, _) = decomposeTile (tile 3 4 5)
          void $ withSnapshot svc lease [borrowed] $ \_ → do
            putMVar holding ()
            readMVar release
            note "borrow finished"
    withOwnedThread served $ \thread waitServed →
      withOwnedThread borrower $ \_ waitBorrower → do
        svc <- bounded (readMVar bodyDone)
        let closed = registerClient svc >>= \r → case r of
              Left RefusedClosed → pure ()
              Left other → fail ("unexpected refusal " <> show other)
              Right client → endClient svc client >> yield >> closed
        bounded closed
        -- The service is draining behind the borrower; the interruption arrives.
        interrupt thread
        readMVar events `shouldReturn` []
        putMVar release ()
        bounded waitBorrower
        bounded waitServed
    chronological <- reverse <$> readMVar events
    chronological `shouldBe` ["borrow finished", "service exited"]

  it "returns only after the owner's last record when it is cancelled just as the owner has started" $ do
    events <- newMVar ([] ∷ [String])
    let note e = modifyMVar_ events (pure . (e :))
    started <- newEmptyMVar
    let logger = mkLogger defaultLogFilter (callbackSink (\entry → if entryMessage entry == "terrain owner stopped" then note "owner log: stopped" else pure ()))
        served =
          withWorkerGroup $ \group →
            ( withStoragePort $ \port → withTerrainService (smallestStore defaultConfig) (Ports alwaysAdmitting (signalling group started) logger noProbe port) (\_ → atomically retry)
                `catch` (\e → note "service returned" >> throwIO (e ∷ SomeException))
            )
    withOwnedThread served $ \thread waitServed → do
      bounded (readMVar started)
      killThread thread
      bounded waitServed
    chronological <- reverse <$> readMVar events
    chronological `shouldBe` ["owner log: stopped", "service returned"]

  forM_ pointsOfWork $ \(label, selects, scenario) →
   it ("retires every in-flight account when the owner is interrupted " <> label) $ do
    armed <- newTVarIO False
    verdict <- newEmptyMVar
    let probe = Probe $ \point → do
          fire <- atomically (readTVar armed >>= \a → if a && selects point then writeTVar armed False >> pure True else pure False)
          when fire (throwIO OwnerInterrupted)
    -- The interruption ends the owner and the worker group reports it when the
    -- service's scope ends, so the checks run inside it and their verdict is
    -- carried out through a box.
    _ <- try @SomeException $
      withServiceUsing (tightConfig (2, 1, 2) 0 4096) alwaysAdmitting probe $ \svc → do
        checks <- try @SomeException $ do
          (_, lease) <- openMain svc "main"
          bounded (scenario svc lease (atomically (writeTVar armed True)))
          bounded (awaitOwnerStopped svc)
          model <- inspectModel svc
          -- Nothing is left reserved, running, transferring or retiring.
          ( modelJobs model, modelRequests model, [regionCoord r | r ← modelRegions model], [arenaId a | a ← modelArenas model]
            , [ledgerReserved (bankLedger model b) | b ← [ResidentBank, EditBank, StagingBank]], slotInUse model LoadJobSlot )
            `shouldBe` ([], [], [], [], [0, 0, 0], 0)
          inspectInvariants svc >>= (`shouldBe` [])
        putMVar verdict checks
    readMVar verdict >>= either throwIO pure

  it "attaches the cleanup's defects to the failure the owner already has" $ do
    armed <- newTVarIO False
    let probe = Probe $ \point → case point of
          PointJob _ _ → do
            fire <- atomically (readTVar armed >>= \a → writeTVar armed False >> pure a)
            when fire (throwIO (ErrorCall "the owner failed first"))
          _ → pure ()
    outcome <- try $
      withLoggingLifetime quiet $ \lifetime →
        withSupervision lifetime $ \control →
          withStoragePort $ \port → withTerrainService (smallestStore defaultConfig) (Ports alwaysAdmitting (supervisedOwner control) quiet probe port) $ \svc → do
            (_, lease) <- openMain svc "main"
            bad <- newHost False
            let failing = (hostEndpoint svc Nothing bad) {endpointSettle = \_ → throwSTM (ErrorCall "closure callback failed")}
            _ <- okOf (cellWith svc failing lease (tile 1 1 1))
            waitFor (readTVar (hostReady bad) >>= \n → check (n >= 1))
            atomically (writeTVar armed True)
            -- A new load fails the owner; closing then fails the pending request's callback too.
            _ <- okOf (cellAt svc lease (tile 40 40 40))
            awaitOwnerStopped svc
            checkRuntime control
    case outcome of
      Left failure → do
        fromException failure `shouldBe` Just (ErrorCall "the owner failed first")
        let evidence = [fromException inner | f ← cleanupFailures failure, let ExceptionWithContext _ inner = cleanupFailureException f]
        evidence `shouldSatisfy` any (\e → case e of Just (ProviderDefect _) → True; _ → False)
      Right () → expectationFailure "the supervised run ended cleanly although the owner failed"

  it "keeps an untaken removal result's bytes charged in the retained bank until it is taken" $
    withService (defaultConfig {configRetainedBytes = 330}) $ \svc → do
      (_, lease) <- openMain svc "main"
      hostA <- newHost True
      hostB <- newHost True
      a <- okOf (removeWith svc (hostEndpoint svc Nothing hostA) lease (tile 1 1 1) Nothing)
      b <- okOf (removeWith svc (hostEndpoint svc Nothing hostB) lease (tile 1 1 1) Nothing)
      waitFor (readTVar (hostSettled hostA) >>= \x → check (not (null x)))
      waitFor (readTVar (hostSettled hostB) >>= \x → check (not (null x)))
      -- One result changed the cell, one was a no-op: both are held, 160 bytes each.
      inspectSnapshotBytes svc >>= (`shouldBe` (320, 330))
      removeAt svc lease (tile 2 2 2) Nothing >>= \r → fmap isBusy (refusedWith r) `shouldBe` Just True
      model <- inspectModel svc
      -- The model holds nothing for them; the retained bank does.
      slotInUse model CommandSlot `shouldBe` 0
      retire svc a
      inspectSnapshotBytes svc >>= (`shouldBe` (160, 330))
      next' <- okOf (removeAt svc lease (tile 2 2 2) Nothing)
      _ <- await svc next'
      retire svc b
      inspectSnapshotBytes svc >>= (`shouldBe` (0, 330))
      settleChecks svc

  it "gives a result back, and a lease up, inside the caller's own transaction, as retire and releaseLease do" $
    withService (defaultConfig {configRetainedBytes = 330}) $ \svc → do
      (_, lease) <- openMain svc "main"
      host <- newHost True
      request <- okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1) Nothing)
      waitFor (readTVar (hostSettled host) >>= \x → check (not (null x)))
      inspectSnapshotBytes svc >>= (`shouldBe` (160, 330))
      -- one transaction of the caller's: the result is retired and nothing else of the caller's is written
      flag <- newTVarIO False
      atomically (retireSTM svc request >> writeTVar flag True)
      readTVarIO flag `shouldReturn` True
      inspectSnapshotBytes svc >>= (`shouldBe` (0, 330))
      -- the lease: released in a transaction of the caller's, idempotently, and a lease of another service is refused
      leasesBefore <- heldLeases svc
      released <- atomically (releaseArenaLeaseSTM svc lease)
      released `shouldBe` Right ()
      again <- atomically (releaseArenaLeaseSTM svc lease)
      again `shouldBe` Right ()
      heldLeases svc >>= \remaining → (leasesBefore, remaining) `shouldBe` (1, 0)
      settleChecks svc

  it "reserves a removal's result bytes at admission, so pending removals and snapshots cannot overfill the retained bank" $
    withService (defaultConfig {configRetainedBytes = 330}) $ \svc → do
      (_, lease) <- openMain svc "main"
      -- The region is loaded first: every request reserves a record, the read included.
      _ <- readCell svc lease (tile 1 1 100)
      h1 <- newHost False
      h2 <- newHost False
      h3 <- newHost False
      let air (x, y, z) host = removeWith svc (hostEndpoint svc Nothing host) lease (tile x y z) Nothing
      -- Two delayed removals reserve 320 bytes; a third does not fit.
      r1 <- okOf (air (1, 1, 100) h1)
      r2 <- okOf (air (1, 1, 101) h2)
      air (1, 1, 102) h3 >>= \r → fmap isBusy (refusedWith r) `shouldBe` Just True
      inspectSnapshotBytes svc >>= (`shouldBe` (320, 330))
      -- A snapshot cannot take space promised to them.
      let (held, _) = decomposeTile (tile 1 1 100)
      withSnapshot svc lease [held] (\_ → pure ()) >>= (`shouldBe` Left (RefusedBusy BusyRetained))
      -- Granting both settles them; the bank was never over its limit.
      forM_ [h1, h2] grant
      forM_ [h1, h2] $ \host → waitFor (readTVar (hostSettled host) >>= \x → check (not (null x)))
      inspectInvariants svc >>= (`shouldBe` [])
      inspectSnapshotBytes svc >>= (`shouldBe` (320, 330))
      retire svc r1
      retire svc r2
      inspectSnapshotBytes svc >>= (`shouldBe` (0, 330))
      settleChecks svc

  it "charges pending opens and attaches against the command slots and the retained bank" $ do
    -- Command slots: two, held by reads, leave none for an attachment.
    withService (configWith (\limits → limits {specQueuedCommands = 2})) $ \svc → do
      (_, lease) <- openMain svc "main"
      other <- okOf (registerClient svc)
      held1 <- newHost False
      held2 <- newHost False
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing held1) lease (tile 0 0 0))
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing held2) lease (tile 1 0 0))
      attachArena svc (other) "main" >>= \r → fmap isBusy (refusedWith r) `shouldBe` Just True
      settleChecks svc
    -- Delayed attachments hold a slot and a record each: only two fit two slots.
    withService (configWith (\limits → limits {specQueuedCommands = 2})) $ \svc → do
      (_, _) <- openMain svc "main"
      other <- okOf (registerClient svc)
      hosts <- mapM (const (newHost False)) [1 .. 8 ∷ Int]
      results <- mapM (\host → attachArenaWith svc (hostEndpoint svc Nothing host) other "main") hosts
      length [() | Right _ ← results] `shouldBe` 2
      inspectInvariants svc >>= (`shouldBe` [])
      forM_ hosts grant
      settleChecks svc
    -- And bytes: a 330-byte bank holds two records.
    withService (defaultConfig {configRetainedBytes = 330}) $ \svc → do
      (_, _) <- openMain svc "main"
      other <- okOf (registerClient svc)
      hosts <- mapM (const (newHost False)) [1 .. 5 ∷ Int]
      results <- mapM (\host → attachArenaWith svc (hostEndpoint svc Nothing host) other "main") hosts
      length [() | Right _ ← results] `shouldBe` 2
      inspectSnapshotBytes svc >>= (`shouldBe` (320, 330))
      forM_ hosts grant
      settleChecks svc

  it "bounds the registered clients" $
    withService (defaultConfig {configMaxClients = 3}) $ \svc → do
      clients <- mapM (const (registerClient svc)) [1 .. 5 ∷ Int]
      length [() | Right _ ← clients] `shouldBe` 3
      mapM_ (\r → refusedWith r `shouldSatisfy` \found → found == Nothing || found == Just (RefusedBusy BusyClients)) clients
      forM_ [c | Right c ← clients] (endClient svc)
      okOf (registerClient svc) >>= \_ → pure ()
      settleChecks svc

  it "reports an earlier unreported defect beside a later fatal one" $ do
    gate <- newDisarmedGate
    outcome <- try $
      withLoggingLifetime quiet $ \lifetime →
        withSupervision lifetime $ \control →
          withStoragePort $ \port → withTerrainService (smallestStore defaultConfig) (Ports alwaysAdmitting (supervisedOwner control) quiet (gatedProbe (\p → case p of PointStaging _ → True; _ → False) gate) port) (\svc → (do
            (creatorA, leaseA) <- openMain svc "a"
            (_, leaseB) <- openMain svc "b"
            other <- okOf (registerClient svc)
            attachedA <- okOf (attachArena svc other "a") >>= await svc >>= expectSuccess
            badClosure <- newHost False
            let failingClosure = (hostEndpoint svc Nothing badClosure) {endpointSettle = \_ → throwSTM (ErrorCall "closure callback failed")}
            _ <- okOf (cellWith svc failingClosure attachedA (tile 1 1 1))
            waitFor (readTVar (hostReady badClosure) >>= \n → check (n >= 1))
            _ <- pure leaseA
            armGate gate
            badReady <- newHost True
            let failingReady = (hostEndpoint svc Nothing badReady) {endpointReady = throwSTM (ErrorCall "readiness callback failed")}
            _ <- okOf (removeWith svc failingReady leaseB (tile 1 1 1) Nothing)
            awaitReached gate
            -- With the owner held mid-preparation, arena A closes and its callback fails.
            endClient svc creatorA
            openGate gate
            awaitOwnerStopped svc
            checkRuntime control) `finally'` openGate gate)
    case outcome of
      Left failure → do
        let texts = [show inner | f ← cleanupFailures failure, let ExceptionWithContext _ inner = cleanupFailureException f]
        show failure `shouldContain` "readiness callback failed"
        concat texts `shouldContain` "closure callback failed"
      Right () → expectationFailure "the supervised run ended cleanly"

  it "ends a superseded request with a typed failure when its readmission is permanently refused" $
    withService (tightConfig (2, 1, 2) 3 4096) $ \svc → do
      client <- okOf (registerClient svc)
      let definition = layered [(Just (-5), Just 0, "stone", 0), (Just 0, Just 2, "soil", 0)] []
      lease <- okOf (openArena svc client "edge" definition) >>= await svc >>= expectSuccess
      host <- newHost False
      _ <- okOf (surfaceWith svc (hostEndpoint svc Nothing host) lease (column 0 0))
      waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      -- Two edits move the column's top to level -1, outside the configured extent.
      _ <- removeCell' svc lease (tile 0 0 1)
      _ <- removeCell' svc lease (tile 0 0 0)
      grant host
      settled <- waitFor (readTVar (hostSettled host) >>= \x → if null x then retry else pure x)
      case settled of
        [Failed (Superseded _)] → pure ()
        other → expectationFailure ("expected a typed superseded failure, got " <> show other)
      inspectReadmissionWaits svc `shouldReturn` 0
      -- It no longer blocks the arena: a later edit commits.
      later <- removeCell' svc lease (tile 1 0 1)
      removeChangedFlag later `shouldBe` True
      settleChecks svc

  it "keeps a request that waits to be admitted again charged until it is readmitted or ends" $ do
    -- A pending read of the edited region (its host not yet eligible, so it holds no removal back)
    -- keeps that region resident (the baseline kept it protected by failing every transfer; a
    -- backed commit transfers nothing), and the bank holds about one region, so a request that
    -- needs another cannot be admitted again. (Three command slots: the waiting request, the
    -- keeper and one more read; the baseline's two had no keeper.)
    withServiceUsing (microConfigSlots 3) alwaysAdmitting noProbe $ \svc → do
      client <- okOf (registerClient svc)
      let definition = layered [(Just 0, Just 2, "soil", 0), (Just 32, Just 34, "stone", 0)] [] ∷ SourceSpec
      lease <- okOf (openArena svc client "waits" definition) >>= await svc >>= expectSuccess
      surfaceHost <- newHost False
      _ <- okOf (surfaceWith svc (hostEndpoint svc Nothing surfaceHost) lease (column 0 0))
      waitFor (readTVar (hostReady surfaceHost) >>= \n → check (n >= 1))
      keeper <- newHost False
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing keeper) lease (tile 0 0 32))
      waitFor (readTVar (hostReady keeper) >>= \n → check (n >= 1))
      do
        -- Two edits bring the column's top down into the other region.
        _ <- removeCell' svc lease (tile 0 0 33)
        _ <- removeCell' svc lease (tile 0 0 32)
        waitFor (inspectReadmissionWaitsSTM svc >>= \n → check (n == 1))
        -- It is charged: it holds a command slot, so beside the keeper only one more fits
        -- three, and the state is coherent.
        inspectInvariants svc >>= (`shouldBe` [])
        first' <- okOf (cellAt svc lease (tile 0 0 32))
        cellAt svc lease (tile 0 0 33) >>= \r → fmap isBusy (refusedWith r) `shouldBe` Just True
        void (cancelPending svc first')
        -- Ending the arena ends the request once and returns its charge.
        closeService svc
      settledOf surfaceHost `shouldReturn` [Failed ArenaClosed]
      inspectReadmissionWaits svc `shouldReturn` 0
      inspectInvariants svc >>= (`shouldBe` [])

  it "reserves a read's record at admission, so a read that starts waiting to be admitted again cannot overfill the retained bank" $ do
    -- The bank holds two records. The pending surface query holds one from admission and
    -- a removal the other, so a second removal is refused rather than admitted into
    -- room the waiting query will need.
    withServiceUsing ((microConfigSlots 6) {configRetainedBytes = 320}) alwaysAdmitting noProbe $ \svc → do
      client <- okOf (registerClient svc)
      let definition = layered [(Just 0, Just 2, "soil", 0), (Just 32, Just 34, "stone", 0)] [] ∷ SourceSpec
      lease <- okOf (openArena svc client "full" definition) >>= await svc >>= expectSuccess
      surfaceHost <- newHost False
      _ <- okOf (surfaceWith svc (hostEndpoint svc Nothing surfaceHost) lease (column 0 0))
      waitFor (readTVar (hostReady surfaceHost) >>= \n → check (n >= 1))
      first' <- okOf (removeAt svc lease (tile 0 0 33) Nothing)
      removeAt svc lease (tile 0 0 32) Nothing >>= \r → refusedWith r `shouldSatisfy` \case Just (RefusedBusy _) → True; _ → False
      used <- inspectSnapshotBytes svc
      used `shouldSatisfy` \(inUse, bank) → inUse <= bank
      inspectInvariants svc >>= (`shouldBe` [])
      void (cancelPending svc first')
      closeService svc

  it "never lets a failing logger replace the defect it was reporting" $ do
    let sink entry = if entryMessage entry == "defect" then throwIO (ErrorCall "the sink failed") else pure ()
        failingLogger = mkLogger defaultLogFilter (callbackSink sink)
    outcome <- try $
      withLoggingLifetime quiet $ \lifetime →
        withSupervision lifetime $ \control →
          withStoragePort $ \port → withTerrainService (smallestStore defaultConfig) (Ports alwaysAdmitting (supervisedOwner control) failingLogger noProbe port) $ \svc → do
            (_, lease) <- openMain svc "main"
            host <- newHost True
            let failing = (hostEndpoint svc Nothing host) {endpointReady = throwSTM (ErrorCall "readiness callback failed")}
            _ <- okOf (removeWith svc failing lease (tile 1 1 1) Nothing)
            awaitOwnerStopped svc
            checkRuntime control
    case outcome of
      Left failure → do
        show failure `shouldContain` "readiness callback failed"
        let evidence = concat [show inner | f ← cleanupFailures failure, let ExceptionWithContext _ inner = cleanupFailureException f]
        evidence `shouldContain` "the sink failed"
      Right () → expectationFailure "the supervised run ended cleanly"

  -- A granted removal is not overtaken by the requests that keep arriving behind it: while the slot
  -- runs it, no later request of its arena is prepared (what it would stage goes stale at that commit,
  -- and it could not commit first), so the removal waits only for the storage jobs already queued
  -- ahead of its own (at most the eight descriptors). The bound is exact: zero preparations of later
  -- requests before its decision, however many arrive (the baseline's '<= 3' was a property of
  -- RAM-only reads; every read now reads the store).
  forM_ [5, 20, 60 ∷ Int] $ \hits →
   it ("serves a granted removal before any request that arrives behind it is prepared, however many arrive (" <> show hits <> ")") $ do
    counting <- newIORef False
    captured <- newIORef (0 ∷ Int)
    committedAfter <- newIORef (Nothing ∷ Maybe Int)
    granted <- newTVarIO False
    let probe = Probe $ \point → do
          active <- readIORef counting
          when active $ case point of
            PointCaptured {} → modifyIORef' captured (+ 1)
            PointStaging _ → modifyIORef' captured (+ 1)
            PointGranted (Just _) _ → atomically (writeTVar granted True)
            PointBeforeCommit _ → readIORef captured >>= \seen → modifyIORef' committedAfter (Just . maybe seen id)
            _ → pure ()
    withServiceUsing defaultConfig alwaysAdmitting probe $ \svc → do
      (_, lease) <- openMain svc "main"
      _ <- readCell svc lease (tile 1 1 1)
      removal <- newHost False
      _ <- okOf (removeWith svc (hostEndpoint svc Nothing removal) lease (tile 0 1 1) Nothing)
      waitFor (readTVar (hostReady removal) >>= \n → check (n >= 1))
      writeIORef counting True
      grant removal
      waitFor (readTVar granted >>= check)
      -- behind the granted removal, a run of reads of its arena
      readers <- forM [1 .. hits] $ \_ → do
        host <- newHost True
        _ <- okOf (cellWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1))
        pure host
      waitFor (readTVar (hostSettled removal) >>= \x → check (not (null x)))
      readIORef committedAfter `shouldReturn` Just 0
      -- and every read is answered after it, seeing it
      forM_ readers $ \h → waitFor (readTVar (hostSettled h) >>= \x → check (not (null x)))
      settleChecks svc

  -- The window between a removal's eligibility and its grant (the baseline's own shape): the owner is
  -- held in the middle of a read's preparation, the removal becomes eligible, and a stream of reads of
  -- its arena arrives. From eligibility to the decision no further preparation runs, however many
  -- arrive: while an eligible transaction can take the slot no new pinned read starts, and once it has
  -- the slot nothing behind it is prepared.
  forM_ [5, 20, 60 ∷ Int] $ \hits →
   it ("prepares nothing between a removal's eligibility and its decision, however many requests keep arriving (" <> show hits <> ")") $ do
    gate <- newDisarmedGate
    counting <- newIORef False
    captured <- newIORef (0 ∷ Int)
    committedAfter <- newIORef (Nothing ∷ Maybe Int)
    let holding = gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate
        probe = Probe $ \point → do
          active <- readIORef counting
          when active $ case point of
            PointCaptured {} → modifyIORef' captured (+ 1)
            PointStaging _ → modifyIORef' captured (+ 1)
            PointBeforeCommit _ → readIORef captured >>= \seen → modifyIORef' committedAfter (Just . maybe seen id)
            _ → pure ()
          probePoint holding point
    withGatedServiceUsing probe gate $ \svc → do
      (_, lease) <- openMain svc "main"
      _ <- readCell svc lease (tile 1 1 1)
      removal <- newHost False
      _ <- okOf (removeWith svc (hostEndpoint svc Nothing removal) lease (tile 0 1 1) Nothing)
      waitFor (readTVar (hostReady removal) >>= \n → check (n >= 1))
      -- a read holds the owner in the middle of its preparation
      armGate gate
      first' <- newHost True
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing first') lease (tile 1 1 1))
      awaitReached gate
      -- from here: the removal is eligible, and the stream arrives
      writeIORef counting True
      grant removal
      forM_ [1 .. hits] $ \_ → do
        host <- newHost True
        okOf (cellWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1))
      openGate gate
      waitFor (readTVar (hostSettled removal) >>= \x → check (not (null x)))
      readIORef committedAfter `shouldReturn` Just 0
      settleChecks svc

  -- The other direction: a stream of grants must not starve a read. A read
  -- admitted amid accepted removals commits before every removal admitted after it (per-arena admission
  -- order holds for the slot too), so its wait is the removals before it, whatever follows.
  forM_ [5, 20, 60 ∷ Int] $ \later →
   it ("answers a read admitted amid a stream of removals before any removal admitted after it (" <> show later <> " after)") $ do
    probe <- H.newProbe
    withServiceSeam quiet defaultConfig alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
      (_, lease) <- openMain svc "main"
      order <- newTVarIO ([] ∷ [String])
      let noting label = do
            host <- newHost True
            pure (host, (hostEndpoint svc Nothing host) {endpointSettle = \s → modifyTVar' order (label :) >> modifyTVar' (hostSettled host) (s :)})
          removal label x = do
            (host, ep) <- noting label
            _ <- okOf (removeWith svc ep lease (tile x 4 3) Nothing)
            pure host
      before' <- forM [0, 1] (removal "earlier")
      forM_ before' $ \h → waitFor (readTVar (hostSettled h) >>= \x → check (not (null x)))
      waitFor (backedAtRestSTM svc >>= check)
      -- the read's page read is held, so it is still to commit while the later removals stage and
      -- become eligible: none of them may take the slot before it
      gate <- H.addGateOnce probe (\case OpReadAt {} → True; _ → False)
      (reader, readEp) <- noting "read"
      after' <- flip finally (H.openGate gate) $ do
        _ <- okOf (cellWith svc readEp lease (tile 0 9 3))
        H.awaitReached gate 1
        after' <- forM [2 .. fromIntegral later + 1] (removal "later")
        forM_ after' $ \h → waitFor (readTVar (hostReady h) >>= \n → check (n >= 1))
        -- staged and eligible, yet none has committed: the earlier read holds them in admission order
        forM_ after' $ \h → readTVarIO (hostSettled h) `shouldReturn` []
        pure after'
      forM_ (reader : after') $ \h → waitFor (readTVar (hostSettled h) >>= \x → check (not (null x)))
      settledOrder <- reverse <$> readTVarIO order
      -- the read settled before every later removal
      takeWhile (/= "read") settledOrder `shouldSatisfy` all (== "earlier")
      length settledOrder `shouldBe` 3 + later
      settleChecks svc

  it "dispatches a queued load while every preparation is followed by a cancellation and a replacement, with a view registered" $ do
    -- The stream is driven by the owner's own progress: at each preparation a read is
    -- replaced by another and one more is cancelled while still pending, so the retry
    -- flag is set again before every next choice. The owner is held at the first
    -- preparation while the cold query is submitted, so the load is queued before
    -- the stream begins.
    gate <- newDisarmedGate
    stream <- newIORef (Nothing ∷ Maybe (Service, ArenaLease))
    previous <- newIORef (Nothing ∷ Maybe Request)
    steps <- newIORef (0 ∷ Int)
    jobAt <- newIORef (Nothing ∷ Maybe Int)
    let holding = gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate
        probe = Probe $ \point → do
          probePoint holding point
          case point of
            PointCaptured {} → readIORef stream >>= \case
              Nothing → pure ()
              Just (svc, hot) → do
                n <- readIORef steps
                when (n < 60) $ do
                  writeIORef steps (n + 1)
                  host <- newHost True
                  fresh <- cellWith svc (hostEndpoint svc Nothing host) hot (tile 1 1 1)
                  old <- readIORef previous
                  forM_ old (void . cancel svc)
                  writeIORef previous (either (const Nothing) Just fresh)
                  -- A read cancelled while still pending returns its credits, which is
                  -- what sets the retry flag again.
                  ephemeral <- newHost True
                  doomed <- cellWith svc (hostEndpoint svc Nothing ephemeral) hot (tile 1 1 1)
                  forM_ (either (const Nothing) Just doomed) (void . cancel svc)
            PointJob {} → readIORef steps >>= \n → when (n >= 1) (modifyIORef' jobAt (Just . maybe n id))
            _ → pure ()
    withGatedServiceUsing probe gate $ \svc → do
      (client, hot) <- openMain svc "hot"
      cold <- okOf (openArena svc client "cold" soilOverStone) >>= await svc >>= expectSuccess
      _ <- okOf (openView svc client)
      _ <- readCell svc hot (tile 1 1 1)
      armGate gate
      starter <- newHost True
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing starter) hot (tile 1 1 1))
      awaitReached gate
      coldHost <- newHost True
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing coldHost) cold (tile 0 0 0))
      writeIORef stream (Just (svc, hot))
      openGate gate
      waitFor (readTVar (hostSettled coldHost) >>= \x → check (not (null x)))
      -- The load ran within a few preparations of the stream starting, however long it is.
      readIORef jobAt >>= \n → n `shouldSatisfy` maybe False (<= 8)
      settleChecks svc

  it "serves an eligible staged commit while a producer keeps cancelling and replacing cache-hit reads" $ do
    gate <- newDisarmedGate
    counting <- newIORef False
    captured <- newIORef (0 ∷ Int)
    committedAfter <- newIORef (Nothing ∷ Maybe Int)
    stop <- newTVarIO False
    let holding = gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate
        probe = Probe $ \point → do
          active <- readIORef counting
          when active $ case point of
            PointCaptured {} → modifyIORef' captured (+ 1)
            PointBeforeCommit _ → readIORef captured >>= \seen → modifyIORef' committedAfter (Just . maybe seen id)
            _ → pure ()
          probePoint holding point
    withGatedServiceUsing probe gate $ \svc → do
      (_, lease) <- openMain svc "main"
      _ <- readCell svc lease (tile 1 1 1)
      removal <- newHost False
      _ <- okOf (removeWith svc (hostEndpoint svc Nothing removal) lease (tile 0 1 1) Nothing)
      waitFor (readTVar (hostReady removal) >>= \n → check (n >= 1))
      writeIORef counting True
      armGate gate
      first' <- newHost True
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing first') lease (tile 1 1 1))
      awaitReached gate
      grant removal
      -- A producer replaces a cache-hit read with another, over and over, until told to stop.
      let produce previous = do
            stopped <- readTVarIO stop
            if stopped
              then pure ()
              else do
                host <- newHost True
                fresh <- cellWith svc (hostEndpoint svc Nothing host) lease (tile 1 1 1)
                forM_ previous (void . cancel svc)
                yield
                produce (either (const Nothing) Just fresh)
      withOwnedThread (produce Nothing) $ \_ stopProducer -> do
        openGate gate
        waitFor (readTVar (hostSettled removal) >>= \x → check (not (null x)))
        atomically (writeTVar stop True)
        stopProducer
      readIORef committedAfter >>= \c → c `shouldSatisfy` maybe False (<= 3)
      settleChecks svc

  it "gives a queued load its turn while ready requests keep arriving elsewhere" $ do
    gate <- newDisarmedGate
    withGatedService defaultConfig alwaysAdmitting (\p -> case p of PointCaptured {} -> True; _ -> False) gate $ \svc -> do
      (_, hot) <- openMain svc "hot"
      cold <- do
        client <- okOf (registerClient svc)
        okOf (openArena svc client "cold" soilOverStone) >>= await svc >>= expectSuccess
      _ <- readCell svc hot (tile 1 1 1)
      order <- newTVarIO ([] :: [String])
      let noting label = do
            host <- newHost True
            pure (host, (hostEndpoint svc Nothing host) {endpointSettle = \s -> modifyTVar' order (label :) >> modifyTVar' (hostSettled host) (s :)})
      armGate gate
      (_, firstEp) <- noting "hit"
      _ <- okOf (cellWith svc firstEp hot (tile 1 1 1))
      awaitReached gate
      -- The owner is held while it prepares a cache hit. Now the cold query is
      -- admitted, and a long run of further cache hits behind it in another arena.
      (_, coldEp) <- noting "cold"
      _ <- okOf (cellWith svc coldEp cold (tile 0 0 0))
      forM_ [1 .. 40 :: Int] $ \_ -> do
        (_, ep) <- noting "hit"
        okOf (cellWith svc ep hot (tile 1 1 1))
      openGate gate
      waitFor (readTVar order >>= \o -> check (length o >= 42))
      settledOrder <- reverse <$> readTVarIO order
      -- The cold load is dispatched in its turn, not after the whole run of hits.
      length (takeWhile (/= "cold") settledOrder) `shouldSatisfy` (< 41)
      settleChecks svc

  it "reports a defect recorded during closure to supervision, after every request was settled" $ do
    outcome <- try $
      withLoggingLifetime quiet $ \lifetime →
        withSupervision lifetime $ \control →
          withStoragePort $ \port → withTerrainService (smallestStore defaultConfig) (Ports alwaysAdmitting (supervisedOwner control) quiet noProbe port) $ \svc → do
            (creator, _) <- openMain svc "main"
            other <- okOf (registerClient svc)
            attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
            good <- newHost False
            bad <- newHost False
            let failing = (hostEndpoint svc Nothing bad) {endpointSettle = \_ → throwSTM (ErrorCall "cleanup failure")}
            _ <- okOf (cellWith svc failing attached (tile 1 1 1))
            _ <- okOf (cellWith svc (hostEndpoint svc Nothing good) attached (tile 2 2 2))
            waitFor (readTVar (hostReady good) >>= \n → check (n >= 1))
            endClient svc creator
            settledOf good `shouldReturn` [Failed ArenaClosed]
            awaitOwnerStopped svc
            checkRuntime control
    case outcome of
      Left failure → fromException failure `shouldSatisfy` \found → case found of Just (ProviderDefect _) → True; _ → False
      Right () → expectationFailure "the supervised run ended cleanly although a closure callback failed"

  it "keeps a settled removal result charged until it is taken, including a no-op" $
    withService (configWith (\limits → limits {specQueuedCommands = 2})) $ \svc → do
      (_, lease) <- openMain svc "main"
      hostA <- newHost True
      hostB <- newHost True
      a <- okOf (removeWith svc (hostEndpoint svc Nothing hostA) lease (tile 1 1 1) Nothing)
      b <- okOf (removeWith svc (hostEndpoint svc Nothing hostB) lease (tile 1 1 1) Nothing)
      waitFor (readTVar (hostSettled hostA) >>= \x → check (not (null x)))
      waitFor (readTVar (hostSettled hostB) >>= \x → check (not (null x)))
      -- Settled and untaken: the request table still holds both, the model none.
      model <- inspectModel svc
      slotInUse model CommandSlot `shouldBe` 0
      removeAt svc lease (tile 2 2 2) Nothing >>= \r → fmap isBusy (refusedWith r) `shouldBe` Just True
      -- Taking one returns its slot.
      retire svc a
      next' <- okOf (removeAt svc lease (tile 2 2 2) Nothing)
      removed <- await svc next'
      removed `shouldSatisfy` either (const False) (const True)
      retire svc b
      settleChecks svc
  it "never hangs when the owner's startup log fails, and returns only after its last log" $ do
    -- A logger that fails on the owner's first record: the cleanup still runs.
    let failing = mkLogger defaultLogFilter (callbackSink (\entry → if entryMessage entry == "terrain owner started" then throwIO (ErrorCall "sink failed") else pure ()))
    bounded $ withServiceLogged failing defaultConfig alwaysAdmitting noProbe $ \svc → do
      awaitClosed svc
      registerClient svc >>= \r → refusedWith r `shouldBe` Just RefusedClosed
    -- A logger held at the owner's last record: the service cannot return before it.
    arrived <- newEmptyMVar
    releaseLog <- newEmptyMVar
    events <- newMVar ([] ∷ [String])
    let note e = modifyMVar_ events (pure . (e :))
        gated = mkLogger defaultLogFilter (callbackSink (\entry → if entryMessage entry == "terrain owner stopped" then putMVar arrived () >> readMVar releaseLog >> note "owner log done" else pure ()))
        served = do
          withServiceLogged gated defaultConfig alwaysAdmitting noProbe (\_ → pure ())
          note "service returned"
    withOwnedThread served $ \_ waitServed → do
      bounded (readMVar arrived)
      putMVar releaseLog ()
      bounded waitServed
    chronological <- reverse <$> readMVar events
    chronological `shouldBe` ["owner log done", "service returned"]
  where
    finally' action cleanup = (action `catch` (\e → cleanup >> throwIO (e ∷ SomeException))) <* cleanup
    inspectRetained svc = inspectSnapshotBytes svc
    killIt thread = killThread thread
    errorIt thread = throwTo thread (ErrorCall "delivered asynchronously")
    isBusy = \case RefusedBusy _ → True; _ → False
    -- A supervisor that tells the test the owner has started, before returning its control.
    signalling group started = Supervisor $ \definition →
      superviseOwner (standaloneSupervisor group) definition <* tryPutMVar started ()
    pointsOfWork =
      [ ("while a load runs", \p → case p of PointJob _ _ → True; _ → False, \svc lease arm → arm >> void (cellAt svc lease (tile 1 0 1)) >> pure ())
      , ("while it captures a read", \p → case p of PointCaptured {} → True; _ → False, \svc lease arm → arm >> void (cellAt svc lease (tile 1 0 1)) >> pure ())
      , ("while it stages an edit", \p → case p of PointStaging _ → True; _ → False, \svc lease arm → arm >> void (removeAt svc lease (tile 1 0 1) Nothing) >> pure ())
      , ("at the commit boundary", \p → case p of PointBeforeCommit _ → True; _ → False, \svc lease arm → arm >> void (removeAt svc lease (tile 1 0 1) Nothing) >> pure ())
      -- (the baseline's 'while a transfer runs': a backed commit transfers nothing; the work in flight
      -- that holds the most is the slot's transaction, just granted with its credits reserved)
      , ("while it holds the mutation slot, its transaction's credits reserved", \p → case p of PointGranted (Just _) _ → True; _ → False, \svc lease arm → arm >> void (removeAt svc lease (tile 1 0 1) Nothing) >> pure ())
      , ( "while a victim is being released"
        , \p → case p of PointVictim _ _ → True; _ → False
        , \svc lease arm → do
            _ <- arm
            forM_ [(x, z) | x ← [16, 32, -16, 48, -32, 64, 80, -48], z ← [0, 32, -32]] $ \(x, z) →
              cellAt svc lease (tile x 0 z) >>= either (const (pure ())) (void . await svc)
        )
      ]
    isInvalid = \case Just (RefusedInvalid _) → True; _ → False

-- | An asynchronous exception of the test's own, standing for any cancellation of
-- the owner.
data OwnerInterrupted = OwnerInterrupted
  deriving stock (Show)

instance Exception OwnerInterrupted where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | The leases the service holds: its own enumeration of them.
heldLeases ∷ Service → IO Word
heldLeases svc = maybe 0 (fromIntegral . limitRowHeld) . find ((== "leases") . limitRowName) <$> inspectLimits svc
