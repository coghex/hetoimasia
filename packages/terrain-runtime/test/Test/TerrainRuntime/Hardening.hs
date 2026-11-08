-- | Accounting and lifetime hardening: the cases a first review of the service
-- reproduced, each as an example that fails without its fix.
module Test.TerrainRuntime.Hardening (spec) where

import Control.Concurrent (killThread, yield)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), SomeException, catch, throwIO)
import Control.Monad (forM_, void)
import Hetoimasia.Foundation.Log (LogEntry (..), callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Terrain.Cell (zRangeLo)
import Hetoimasia.Terrain.Changes (changesBytes)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), decomposeTile, mkLocalCoord)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Resident (residentCell)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Test.TerrainRuntime.Fixtures

spec ∷ Spec
spec = describe "Accounting and lifetime hardening" $ do
  it "accounts a coalescing removal that shrinks the retained changes without underflow" $
    withService defaultConfig $ \svc → do
      (_, lease) <- openMain svc "main"
      -- Levels 0 and 2 are two intervals; removing 1 joins them into one.
      forM_ [0, 2, 1] $ \z → removeCell' svc lease (tile 0 0 z)
      view <- inspectArena svc lease >>= maybe (fail "arena vanished") pure
      changesBytes (viewChanges view) `shouldBe` 64
      model <- inspectModel svc
      -- The model's retained account never decreases: the saving is not credited.
      [arenaRetainedBytes a | a ← modelArenas model] `shouldBe` [80]
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

  it "charges every outstanding snapshot's backing, across revisions, until it is released" $ do
    let config = (tightConfig (2, 1, 2) 2 4096) {configSnapshotBytes = 100}
    withService config $ \svc → do
      (_, lease) <- openMain svc "main"
      let (held, _) = decomposeTile (tile 0 0 0)
      _ <- readCell svc lease (tile 0 0 0)
      outcome <- withSnapshot svc lease [held] $ \first' → do
        (oneVersion, bank) <- inspectSnapshotBytes svc
        bank `shouldBe` 100
        oneVersion `shouldSatisfy` (> 0)
        removeCell' svc lease (tile 0 0 0) >>= (`shouldSatisfy` removeChangedFlag)
        -- A second borrow, now of revision 1, would retain a second version
        -- beside the first: refused, not silently retained.
        second <- withSnapshot svc lease [held] (\_ → pure ())
        second `shouldBe` Left (RefusedBusy BusySnapshots)
        snapshotRevision first' `shouldBe` Revision 0
        inspectSnapshotBytes svc >>= (`shouldBe` (oneVersion, 100))
      outcome `shouldBe` Right ()
      -- Released: the backing is returned and the new revision can be borrowed.
      inspectSnapshotBytes svc >>= (`shouldBe` (0, 100))
      third <- withSnapshot svc lease [held] $ \s → pure (snapshotRevision s)
      third `shouldBe` Right (Revision 1)
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

  it "keeps draining when it is cancelled while a borrower is outstanding, and delivers the cancellation afterwards" $ do
    events <- newMVar ([] ∷ [String])
    let note e = modifyMVar_ events (pure . (e :))
    boxed <- newEmptyMVar
    holding <- newEmptyMVar
    bodyDone <- newEmptyMVar
    release <- newEmptyMVar
    let served =
          withService defaultConfig (\svc → do
            (_, lease) <- openMain svc "main"
            _ <- readCell svc lease (tile 3 4 5)
            putMVar boxed (svc, lease)
            bounded (readMVar holding)
            putMVar bodyDone svc)
            `finally'` note "service exited"
        finally' action cleanup = action `catchAll` (\e → cleanup >> throwIO e) >> cleanup
        catchAll = catchAny
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
        -- The service is draining behind the borrower; a cancellation arrives.
        killThread thread
        readIORef' events `shouldReturn` []
        putMVar release ()
        bounded waitBorrower
        bounded waitServed
    chronological <- reverse <$> readMVar events
    chronological `shouldBe` ["borrow finished", "service exited"]

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
    readIORef' events = readMVar events
    catchAny = \action handler → action `catch` (\e → handler (e ∷ SomeException))
